import Foundation

public struct AntigravityProvider: QuotaProvider {
    public static let descriptor = ProviderDescriptor(
        id: "antigravity",
        displayName: "Antigravity",
        implementationStatus: .implemented,
        authMethods: [.userPastedToken, .localCLICredentials],
        supportedMetricKinds: [.subscriptionQuota],
        notes: "支持应用内一键 Google OAuth 登录（自动续期）或钥匙串 OAuth Token，通过 loadCodeAssist + fetchAvailableModels 查询各模型族配额。"
    )

    public var descriptor: ProviderDescriptor { Self.descriptor }

    private let credentials: CredentialStore
    private let http: HTTPClient
    private let fileSystem: FileSystemReading
    private let clock: @Sendable () -> Date
    private let demoFixture: Data?

    public init(
        credentials: CredentialStore,
        http: HTTPClient,
        fileSystem: FileSystemReading,
        clock: @escaping @Sendable () -> Date = { Date() },
        demoFixture: Data? = nil
    ) {
        self.credentials = credentials
        self.http = http
        self.fileSystem = fileSystem
        self.clock = clock
        self.demoFixture = demoFixture
    }

    public func configuredAccounts() async -> [AccountIdentity] {
        if let bundle = GoogleOAuthBundle.load(from: credentials, account: CredentialAccount.antigravityOAuthBundle) {
            return [AccountIdentity(id: "antigravity.oauth", providerID: "antigravity", displayName: "Antigravity", email: bundle.email)]
        }
        if let token = try? credentials.getSecret(account: CredentialAccount.antigravityOAuthToken), !token.isEmpty {
            return [AccountIdentity(id: "antigravity.token", providerID: "antigravity", displayName: "Antigravity")]
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
        var accountID = "antigravity.oauth"
        if let oauth = try await GoogleOAuthFlow.validAccessToken(
            http: http,
            app: .antigravity,
            credentials: credentials,
            now: now
        ) {
            token = oauth.accessToken
            email = oauth.email
            accountID = "antigravity.oauth"
        } else if let manual = try credentials.getSecret(account: CredentialAccount.antigravityOAuthToken), !manual.isEmpty {
            token = manual
            accountID = "antigravity.token"
        } else {
            throw ProviderError.notConfigured("未配置 Antigravity。可在设置或弹窗中一键 Google 登录。")
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
