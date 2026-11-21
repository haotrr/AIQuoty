import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

public struct AntigravityProvider: QuotaProvider {
    public static let descriptor = ProviderDescriptor(
        id: "antigravity",
        displayName: "Antigravity",
        implementationStatus: .implemented,
        authMethods: [.localCLICredentials, .userPastedToken],
        supportedMetricKinds: [.subscriptionQuota],
        notes: "优先自动只读复用本机 Antigravity 桌面端登录态（state.vscdb），无需手动填 Key；也支持应用内 Google OAuth 或钥匙串 Token。"
    )

    public var descriptor: ProviderDescriptor { Self.descriptor }

    private let credentials: CredentialStore
    private let http: HTTPClient
    private let fileSystem: FileSystemReading
    private let stateReader: AntigravityStateReading
    private let clock: @Sendable () -> Date
    private let demoFixture: Data?

    public init(
        credentials: CredentialStore,
        http: HTTPClient,
        fileSystem: FileSystemReading,
        stateReader: AntigravityStateReading = SQLiteAntigravityStateReader(),
        clock: @escaping @Sendable () -> Date = { Date() },
        demoFixture: Data? = nil
    ) {
        self.credentials = credentials
        self.http = http
        self.fileSystem = fileSystem
        self.stateReader = stateReader
        self.clock = clock
        self.demoFixture = demoFixture
    }

    public func configuredAccounts() async -> [AccountIdentity] {
        if let token = try? credentials.getSecret(account: CredentialAccount.antigravityOAuthToken), !token.isEmpty {
            return [AccountIdentity(id: "antigravity.token", providerID: "antigravity", displayName: "Antigravity")]
        }
        if let local = stateReader.readLocalState() {
            return [AccountIdentity(id: "antigravity.desktop", providerID: "antigravity", displayName: "Antigravity", email: local.email)]
        }
        if let bundle = GoogleOAuthBundle.load(from: credentials, account: CredentialAccount.antigravityOAuthBundle) {
            return [AccountIdentity(id: "antigravity.oauth", providerID: "antigravity", displayName: "Antigravity", email: bundle.email)]
        }
        return []
    }

    public func fetch(request: ProviderFetchRequest) async throws -> [AccountSnapshot] {
        let now = request.now
        if request.demoMode, let demoFixture {
            return try [parseQuota(demoFixture, accountID: "antigravity.demo", fallbackEmail: nil, plan: "Pro", now: now)]
        }
        let token: String
        var email: String?
        var accountID = "antigravity.desktop"
        if let manual = try credentials.getSecret(account: CredentialAccount.antigravityOAuthToken), !manual.isEmpty {
            token = manual
            accountID = "antigravity.token"
        } else if let local = stateReader.readLocalState() {
            token = local.accessToken
            email = local.email
            accountID = "antigravity.desktop"
        } else if let oauth = try await GoogleOAuthFlow.validAccessToken(
            http: http,
            app: .antigravity,
            credentials: credentials,
            now: now
        ) {
            token = oauth.accessToken
            email = oauth.email
            accountID = "antigravity.oauth"
        } else {
            throw ProviderError.notConfigured("未检测到本机 Antigravity 登录态。请先打开 Antigravity 桌面端登录，或在设置中配置 OAuth / Access Token。")
        }

        let headers: [String: String] = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": Self.userAgent,
        ]

        // Step 1: Discover project & plan via loadCodeAssist on prod cloudcode-pa.
        let loadInfo = try await loadCodeAssist(headers: headers)

        // Step 2: Query fetchAvailableModels on daily-cloudcode-pa with project (and paid entitlement if available).
        let fetchURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")!
        var tierAttempts: [String?] = []
        for t in [loadInfo.paidTierID, loadInfo.currentTierID] {
            if let t, !t.isEmpty, t != "free-tier", t != "legacy-tier", !tierAttempts.contains(t) {
                tierAttempts.append(t)
            }
        }
        tierAttempts.append(nil)

        var lastFailure: ProviderError?
        for tier in tierAttempts {
            var payload: [String: Any] = [:]
            if let project = loadInfo.projectID, !project.isEmpty {
                payload["project"] = project
            }
            if let tier {
                payload["entitlement"] = ["userTier": tier]
            }
            let body = try JSONSerialization.data(withJSONObject: payload)
            let response = try await http.send(HTTPRequest(method: "POST", url: fetchURL, headers: headers, body: body))
            if (200..<300).contains(response.statusCode) {
                return try [parseQuota(response.body, accountID: accountID, fallbackEmail: email, plan: loadInfo.planName, now: now)]
            }
            let detail = Self.extractGoogleErrorMessage(from: response.body)
            let mapped: ProviderError
            if response.statusCode == 401 || response.statusCode == 403 {
                mapped = .authRequired(detail.map { "HTTP \(response.statusCode)：\($0)" } ?? "HTTP \(response.statusCode)")
            } else {
                mapped = HTTPStatusMapper.mapFailure(status: response.statusCode, body: response.bodyText, headers: response.headers)
            }
            lastFailure = mapped
            if response.statusCode == 400 && tier != nil {
                // Google rejects paid entitlement on some accounts; retry without entitlement.
                continue
            }
            if response.statusCode == 401 || response.statusCode == 429 {
                throw mapped
            }
            if response.statusCode == 403 && tier == nil {
                throw mapped
            }
        }
        throw lastFailure ?? ProviderError.network("Antigravity 配额请求失败")
    }

    struct LoadCodeAssistInfo {
        var projectID: String?
        var planName: String?
        var currentTierID: String?
        var paidTierID: String?
    }

    private func loadCodeAssist(headers: [String: String]) async throws -> LoadCodeAssistInfo {
        let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
        let body = try JSONSerialization.data(withJSONObject: [
            "metadata": ["ideType": "ANTIGRAVITY"],
        ])
        let resp = try await http.send(HTTPRequest(method: "POST", url: url, headers: headers, body: body))
        guard (200..<300).contains(resp.statusCode) else {
            // If loadCodeAssist itself is unavailable or mocked without it, allow proceeding only on 404/network.
            if resp.statusCode == 401 || resp.statusCode == 403 {
                let detail = Self.extractGoogleErrorMessage(from: resp.body)
                throw ProviderError.authRequired(detail.map { "HTTP \(resp.statusCode)：\($0)" } ?? "HTTP \(resp.statusCode)")
            }
            return LoadCodeAssistInfo()
        }
        return Self.parseLoadCodeAssist(resp.body)
    }

    static func parseLoadCodeAssist(_ data: Data) -> LoadCodeAssistInfo {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return LoadCodeAssistInfo()
        }
        var projectID: String?
        if let s = root["cloudaicompanionProject"] as? String, !s.isEmpty {
            projectID = s
        } else if let obj = root["cloudaicompanionProject"] as? [String: Any],
                  let s = obj["id"] as? String, !s.isEmpty {
            projectID = s
        }
        let currentTier = root["currentTier"] as? [String: Any]
        let paidTier = root["paidTier"] as? [String: Any]
        let currentTierID = currentTier?["id"] as? String
        let paidTierID = paidTier?["id"] as? String
        let planName = (paidTier?["name"] as? String)
            ?? (currentTier?["name"] as? String)
            ?? paidTierID
            ?? currentTierID
        return LoadCodeAssistInfo(
            projectID: projectID,
            planName: planName,
            currentTierID: currentTierID,
            paidTierID: paidTierID
        )
    }

    static func extractGoogleErrorMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String, !msg.isEmpty {
            return msg
        }
        return nil
    }

    private static var userAgent: String {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        #if os(macOS)
        let osName = "darwin"
        #else
        let osName = "linux"
        #endif
        return "antigravity/hub/2.9.1 \(osName)/\(arch)"
    }

    public func parseQuota(_ data: Data, accountID: String, fallbackEmail: String? = nil, plan: String?, now: Date) throws -> AccountSnapshot {
        let parsed = try AntigravityQuotaParser.parse(json: data, now: now)
        let windows = AntigravityQuotaParser.quotaWindows(from: parsed, accountID: accountID, capturedAt: now)
        var notes: [String] = []
        if windows.isEmpty {
            notes.append("未返回可识别的 Antigravity 模型配额桶；保持未知。")
        }
        return AccountSnapshot(
            account: AccountIdentity(
                id: accountID,
                providerID: "antigravity",
                displayName: "Antigravity",
                email: parsed.email ?? fallbackEmail,
                planLabel: parsed.planName ?? plan
            ),
            connection: .connected,
            windows: windows,
            lastSuccessAt: now,
            lastAttemptAt: now,
            notes: notes
        )
    }
}

public enum AntigravityQuotaParser {
    public static let source = SourceAttribution(
        id: "antigravity.cloudcode",
        label: "Antigravity Cloud Code",
        detail: "POST daily-cloudcode-pa/v1internal:fetchAvailableModels"
    )

    private static let hiddenModelIDs: Set<String> = [
        "chat_20706", "chat_23310", "tab_flash_lite_preview", "tab_jump_flash_lite_preview",
        "gemini-2.5-flash-thinking", "gemini-2.5-pro",
    ]

    public struct Bucket: Equatable, Sendable {
        public var family: String
        public var remainingFraction: Double
        public var resetAt: Date?
    }

    public struct Parsed: Equatable, Sendable {
        public var email: String?
        public var planName: String?
        public var buckets: [Bucket]
    }

    public static func parse(json: Data, now: Date = Date()) throws -> Parsed {
        let obj = try JSONSerialization.jsonObject(with: json)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decode("Antigravity 响应不是 JSON 对象")
        }

        var byFamily: [String: Bucket] = [:]

        // Shape A: fetchAvailableModels -> { "models": { "<modelId>": { "displayName": "...", "disabled": false, "quotaInfo": { "remainingFraction": 0.6, "resetTime": "..." } } } }
        if let models = root["models"] as? [String: Any] {
            for (modelID, rawVal) in models {
                if hiddenModelIDs.contains(modelID) || modelID.hasPrefix("chat_") || modelID.hasPrefix("tab_") {
                    continue
                }
                guard let info = rawVal as? [String: Any] else { continue }
                if (info["disabled"] as? Bool) == true { continue }
                guard let quota = info["quotaInfo"] as? [String: Any] else { continue }
                // Antigravity omits remainingFraction once 0% remains while quotaInfo is present.
                let rem = fraction(quota["remainingFraction"] ?? quota["remaining_fraction"]) ?? 0.0
                let reset = parseISO(quota["resetTime"] ?? quota["reset_time"])
                let displayName = (info["displayName"] as? String) ?? modelID
                merge(family: familyName(for: modelID, displayName: displayName), remaining: rem, reset: reset, into: &byFamily)
            }
        }

        // Shape B: { "buckets": [ { "modelId": "...", "remainingFraction": 0.7, "resetTime": "..." } ] }
        if let rawBuckets = root["buckets"] as? [[String: Any]] {
            for item in rawBuckets {
                let model = (item["modelId"] as? String) ?? (item["model"] as? String) ?? "unknown"
                guard let rem = fraction(item["remainingFraction"] ?? item["remaining_fraction"]) else { continue }
                let reset = parseISO(item["resetTime"] ?? item["reset_time"])
                merge(family: familyName(for: model, displayName: model), remaining: rem, reset: reset, into: &byFamily)
            }
        }

        // Shape C: { "modelConfigs": [ { "label": "...", "quotaInfo": { "remainingFraction": 0.6, "resetTime": "..." } } ] }
        if let configs = (root["modelConfigs"] as? [[String: Any]])
            ?? (root["clientModelConfigs"] as? [[String: Any]])
            ?? ((root["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"] as? [[String: Any]]) {
            for cfg in configs {
                let label = (cfg["label"] as? String)
                    ?? (cfg["modelId"] as? String)
                    ?? ((cfg["modelOrAlias"] as? [String: Any])?["model"] as? String)
                    ?? "unknown"
                let quota = cfg["quotaInfo"] as? [String: Any] ?? cfg
                guard let rem = fraction(quota["remainingFraction"] ?? quota["remaining_fraction"]) else { continue }
                let reset = parseISO(quota["resetTime"] ?? quota["reset_time"])
                merge(family: familyName(for: label, displayName: label), remaining: rem, reset: reset, into: &byFamily)
            }
        }

        let ordered = byFamily.values.sorted { $0.family < $1.family }
        let email = (root["email"] as? String) ?? ((root["userStatus"] as? [String: Any])?["email"] as? String)
        let plan = (root["planName"] as? String)
            ?? (root["tier"] as? String)
            ?? ((root["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any])?["planName"] as? String
        _ = now
        return Parsed(email: email, planName: plan, buckets: ordered)
    }

    public static func quotaWindows(from parsed: Parsed, accountID: String, capturedAt: Date) -> [QuotaWindow] {
        parsed.buckets.map { b in
            let used = min(max(1 - b.remainingFraction, 0), 1)
            let slug = b.family.lowercased().replacingOccurrences(of: " ", with: "-")
            return QuotaWindow(
                id: "\(accountID).\(slug)",
                title: b.family,
                usedFraction: used,
                remainingFraction: b.remainingFraction,
                usedDisplay: MetricValue(
                    kind: .subscriptionQuota,
                    precision: .reported,
                    unit: .percentUsed,
                    value: used * 100,
                    display: String(format: "%.0f%%", used * 100),
                    source: source,
                    capturedAt: capturedAt,
                    freshness: .fresh
                ),
                remainingDisplay: MetricValue(
                    kind: .subscriptionQuota,
                    precision: .reported,
                    unit: .percentRemaining,
                    value: b.remainingFraction * 100,
                    display: String(format: "%.0f%%", b.remainingFraction * 100),
                    source: source,
                    capturedAt: capturedAt,
                    freshness: .fresh
                ),
                resetsAt: b.resetAt,
                resetKnown: b.resetAt != nil,
                source: source,
                capturedAt: capturedAt
            )
        }
    }

    private static func merge(family: String, remaining: Double, reset: Date?, into map: inout [String: Bucket]) {
        let clamped = min(max(remaining, 0), 1)
        if let existing = map[family] {
            let bestRem = min(existing.remainingFraction, clamped)
            let bestReset = [existing.resetAt, reset].compactMap { $0 }.min()
            map[family] = Bucket(family: family, remainingFraction: bestRem, resetAt: bestReset)
        } else {
            map[family] = Bucket(family: family, remainingFraction: clamped, resetAt: reset)
        }
    }

    private static func familyName(for modelID: String, displayName: String) -> String {
        let lower = "\(modelID) \(displayName)".lowercased()
        if lower.contains("claude") { return "Claude" }
        if lower.contains("flash-lite") || lower.contains("flash lite") { return "Gemini Flash-Lite" }
        if lower.contains("flash") { return "Gemini Flash" }
        if lower.contains("pro") { return "Gemini Pro" }
        if lower.contains("gpt") { return "GPT" }
        return displayName.isEmpty ? modelID : displayName
    }

    private static func fraction(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d > 1 ? d / 100.0 : d }
        if let i = raw as? Int { return i > 1 ? Double(i) / 100.0 : Double(i) }
        if let s = raw as? String, let d = Double(s) { return d > 1 ? d / 100.0 : d }
        return nil
    }

    private static func parseISO(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

// MARK: - Local desktop state reader (read-only SQLite, never decrypts Safe Storage)

public struct AntigravityLocalState: Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var email: String?

    public init(accessToken: String, refreshToken: String? = nil, email: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.email = email
    }
}

public protocol AntigravityStateReading: Sendable {
    func readLocalState() -> AntigravityLocalState?
}

public struct NullAntigravityStateReader: AntigravityStateReading {
    public init() {}
    public func readLocalState() -> AntigravityLocalState? { nil }
}

/// Parses Antigravity desktop `state.vscdb` ItemTable entries into a local OAuth state.
public enum AntigravityStateParser {
    public static func parse(authStatusJSON: String?, oauthStateValues: [String]) -> AntigravityLocalState? {
        var accessToken: String?
        var refreshToken: String?
        var email: String?

        if let authStatusJSON, let data = authStatusJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let e = obj["email"] as? String, isLikelyEmail(e) {
                email = e
            }
            for key in ["apiKey", "accessToken", "access_token", "oauthToken"] {
                if let tok = obj[key] as? String, isGoogleAccessToken(tok) {
                    accessToken = tok
                    break
                }
            }
        }

        for raw in oauthStateValues where !raw.isEmpty {
            var foundAccess: String?
            var foundRefresh: String?
            var foundEmail: String?
            extractFromEncodedValue(raw, depth: 0, accessToken: &foundAccess, refreshToken: &foundRefresh, email: &foundEmail)
            if accessToken == nil, let foundAccess { accessToken = foundAccess }
            if refreshToken == nil, let foundRefresh { refreshToken = foundRefresh }
            if email == nil, let foundEmail { email = foundEmail }
            if accessToken != nil && email != nil { break }
        }

        guard let accessToken else { return nil }
        return AntigravityLocalState(accessToken: accessToken, refreshToken: refreshToken, email: email)
    }

    private static func extractFromEncodedValue(
        _ raw: String,
        depth: Int,
        accessToken: inout String?,
        refreshToken: inout String?,
        email: inout String?
    ) {
        guard depth <= 6 else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isGoogleAccessToken(trimmed) {
            if accessToken == nil { accessToken = trimmed }
            return
        }
        if isGoogleRefreshToken(trimmed) {
            if refreshToken == nil { refreshToken = trimmed }
            return
        }
        if email == nil && isLikelyEmail(trimmed) {
            email = trimmed
            return
        }

        if let decoded = decodeBase64Flexible(trimmed) {
            walkProtobuf(decoded, depth: depth + 1, accessToken: &accessToken, refreshToken: &refreshToken, email: &email)
            scanASCIITokens(in: decoded, accessToken: &accessToken, refreshToken: &refreshToken, email: &email)
        }
    }

    private static func walkProtobuf(
        _ data: Data,
        depth: Int,
        accessToken: inout String?,
        refreshToken: inout String?,
        email: inout String?
    ) {
        guard depth <= 6, !data.isEmpty else { return }
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            guard let (tag, nextAfterTag) = readVarint(bytes, from: i) else { break }
            i = nextAfterTag
            let wireType = Int(tag & 0x7)
            switch wireType {
            case 0: // varint
                guard let (_, next) = readVarint(bytes, from: i) else { return }
                i = next
            case 1: // 64-bit
                guard i + 8 <= bytes.count else { return }
                i += 8
            case 2: // length-delimited
                guard let (len, start) = readVarint(bytes, from: i) else { return }
                let count = Int(len)
                guard count >= 0, start + count <= bytes.count else { return }
                let slice = Data(bytes[start..<(start + count)])
                i = start + count
                if let text = String(data: slice, encoding: .utf8) {
                    if isGoogleAccessToken(text) {
                        if accessToken == nil { accessToken = text }
                    } else if isGoogleRefreshToken(text) {
                        if refreshToken == nil { refreshToken = text }
                    } else if email == nil && isLikelyEmail(text) {
                        email = text
                    } else if text.count >= 16, looksLikeBase64(text), let nested = decodeBase64Flexible(text) {
                        walkProtobuf(nested, depth: depth + 1, accessToken: &accessToken, refreshToken: &refreshToken, email: &email)
                        scanASCIITokens(in: nested, accessToken: &accessToken, refreshToken: &refreshToken, email: &email)
                    }
                }
                if count >= 4 {
                    walkProtobuf(slice, depth: depth + 1, accessToken: &accessToken, refreshToken: &refreshToken, email: &email)
                }
            case 5: // 32-bit
                guard i + 4 <= bytes.count else { return }
                i += 4
            default:
                return
            }
        }
    }

    private static func readVarint(_ bytes: [UInt8], from start: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var idx = start
        while idx < bytes.count && shift < 64 {
            let b = bytes[idx]
            result |= UInt64(b & 0x7F) << shift
            idx += 1
            if (b & 0x80) == 0 {
                return (result, idx)
            }
            shift += 7
        }
        return nil
    }

    private static func scanASCIITokens(
        in data: Data,
        accessToken: inout String?,
        refreshToken: inout String?,
        email: inout String?
    ) {
        // Extract printable token-like ASCII runs as a safe fallback for non-standard framing.
        var current: [UInt8] = []
        func flush() {
            guard current.count >= 12, let s = String(bytes: current, encoding: .utf8) else {
                current.removeAll(keepingCapacity: true)
                return
            }
            if accessToken == nil, let range = s.range(of: "ya29.") {
                let candidate = String(s[range.lowerBound...])
                if isGoogleAccessToken(candidate) { accessToken = candidate }
            }
            if refreshToken == nil, let range = s.range(of: "1//") {
                let candidate = String(s[range.lowerBound...])
                if isGoogleRefreshToken(candidate) { refreshToken = candidate }
            }
            if email == nil && isLikelyEmail(s) {
                email = s
            }
            current.removeAll(keepingCapacity: true)
        }
        for b in data {
            let isTokenChar = (b >= 0x30 && b <= 0x39) // 0-9
                || (b >= 0x41 && b <= 0x5A) // A-Z
                || (b >= 0x61 && b <= 0x7A) // a-z
                || b == 0x2D || b == 0x2E || b == 0x5F || b == 0x2F || b == 0x40 || b == 0x2B // - . _ / @ +
            if isTokenChar {
                current.append(b)
            } else {
                flush()
            }
        }
        flush()
    }

    private static func decodeBase64Flexible(_ raw: String) -> Data? {
        var s = raw
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = s.count % 4
        if rem != 0 { s += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: s, options: .ignoreUnknownCharacters)
    }

    private static func looksLikeBase64(_ s: String) -> Bool {
        s.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "+" || ch == "/" || ch == "=" || ch == "-" || ch == "_")
        }
    }

    private static func isGoogleAccessToken(_ s: String) -> Bool {
        s.hasPrefix("ya29.") && s.count >= 20 && !s.contains(where: \.isWhitespace)
    }

    private static func isGoogleRefreshToken(_ s: String) -> Bool {
        s.hasPrefix("1//") && s.count >= 20 && !s.contains(where: \.isWhitespace)
    }

    private static func isLikelyEmail(_ s: String) -> Bool {
        guard s.count >= 5, s.count <= 128, !s.contains(where: \.isWhitespace) else { return false }
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
    }
}

public struct SQLiteAntigravityStateReader: AntigravityStateReading {
    public let dbPaths: [String]

    public init(
        dbPaths: [String] = [
            "~/Library/Application Support/Antigravity/User/globalStorage/state.vscdb",
            "~/Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb",
            "~/.config/Antigravity/User/globalStorage/state.vscdb",
            "~/.config/Antigravity IDE/User/globalStorage/state.vscdb",
        ]
    ) {
        self.dbPaths = dbPaths
    }

    public func readLocalState() -> AntigravityLocalState? {
        #if canImport(SQLite3)
        for rawPath in dbPaths {
            let path = (rawPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if let state = readSQLite(at: path) {
                return state
            }
        }
        #endif
        return nil
    }

    #if canImport(SQLite3)
    private func readSQLite(at path: String) -> AntigravityLocalState? {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)

        let authStatus = queryValue(db: db, key: "antigravityAuthStatus")
        let candidateKeys = [
            "antigravityUnifiedStateSync.oauthToken",
            "jetskiStateSync.agentManagerInitState",
        ]
        var encodedValues = candidateKeys.compactMap { queryValue(db: db, key: $0) }
        if encodedValues.isEmpty {
            encodedValues = queryValuesLike(db: db, pattern: "%oauthToken%")
        }
        return AntigravityStateParser.parse(authStatusJSON: authStatus, oauthStateValues: encodedValues)
    }

    private func queryValue(db: OpaquePointer, key: String) -> String? {
        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW, let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        let value = String(cString: cStr).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func queryValuesLike(db: OpaquePointer, pattern: String) -> [String] {
        let sql = "SELECT value FROM ItemTable WHERE key LIKE ? LIMIT 5"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, transient)
        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                let value = String(cString: cStr).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { results.append(value) }
            }
        }
        return results
    }
    #endif
}
