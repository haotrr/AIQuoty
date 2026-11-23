import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct FactoryDroidProvider: QuotaProvider {
    public static let descriptor = ProviderDescriptor(
        id: "factory-droid",
        displayName: "Factory / Droid",
        implementationStatus: .implemented,
        authMethods: [.apiKeyInKeychain, .localCLICredentials],
        supportedMetricKinds: [.subscriptionQuota],
        notes: "使用钥匙串中的 Factory API Key (fk-...)、Droid CLI 加密登录态（~/.factory/auth.v2.loginkeychain + 钥匙串「Factory CLI」）或 ~/.factory/auth.json，调用 api.factory.ai/api/organization/members/chat-usage 查询订阅配额。"
    )

    public var descriptor: ProviderDescriptor { Self.descriptor }

    private let credentials: CredentialStore
    private let http: HTTPClient
    private let fileSystem: FileSystemReading
    private let externalKeychain: ExternalKeychainReading
    private let clock: @Sendable () -> Date
    private let authPath: String
    private let encryptedAuthPath: String
    private let demoFixture: Data?

    public init(
        credentials: CredentialStore,
        http: HTTPClient,
        fileSystem: FileSystemReading,
        externalKeychain: ExternalKeychainReading = DefaultExternalKeychain.make(),
        clock: @escaping @Sendable () -> Date = { Date() },
        authPath: String = "~/.factory/auth.json",
        encryptedAuthPath: String = "~/.factory/auth.v2.loginkeychain",
        demoFixture: Data? = nil
    ) {
        self.credentials = credentials
        self.http = http
        self.fileSystem = fileSystem
        self.externalKeychain = externalKeychain
        self.clock = clock
        self.authPath = authPath
        self.encryptedAuthPath = encryptedAuthPath
        self.demoFixture = demoFixture
    }

    public func configuredAccounts() async -> [AccountIdentity] {
        if resolveToken() != nil {
            return [AccountIdentity(id: "factory.default", providerID: "factory-droid", displayName: "Factory / Droid")]
        }
        return []
    }

    public func fetch(request: ProviderFetchRequest) async throws -> [AccountSnapshot] {
        let now = request.now
        if request.demoMode, let demoFixture {
            return try [FactoryUsageParser.parse(json: demoFixture, accountID: "factory.demo", now: now)]
        }
        guard let token = resolveToken(), !token.isEmpty else {
            throw ProviderError.notConfigured("未配置 Factory API Key，且未检测到有效的 Droid CLI 登录态。")
        }

        let url = URL(string: "https://api.factory.ai/api/organization/members/chat-usage")!
        let resp = try await http.send(
            HTTPRequest(
                url: url,
                headers: [
                    "Authorization": "Bearer \(token)",
                    "Accept": "application/json",
                    "User-Agent": "AIQuoty/0.1",
                ]
            )
        )
        guard (200..<300).contains(resp.statusCode) else {
            throw HTTPStatusMapper.mapFailure(status: resp.statusCode, body: resp.bodyText, headers: resp.headers)
        }
        return try [FactoryUsageParser.parse(json: resp.body, accountID: "factory.default", now: now)]
    }

    private func resolveToken() -> String? {
        if let key = try? credentials.getSecret(account: CredentialAccount.factoryAPIKey), !key.isEmpty {
            return key
        }
        if fileSystem.fileExists(at: authPath),
           let data = try? fileSystem.readData(at: authPath),
           let tok = extractToken(from: data) {
            return tok
        }
        if fileSystem.fileExists(at: encryptedAuthPath),
           let encryptedData = try? fileSystem.readData(at: encryptedAuthPath),
           let payload = String(data: encryptedData, encoding: .utf8),
           let keyData = externalKeychain.readGenericPassword(
               service: "Factory CLI",
               account: "auth-encryption-key-security-cli"
           ),
           let decrypted = FactoryAuthDecryptor.decrypt(payload: payload, keyData: keyData),
           let tok = extractToken(from: decrypted) {
            return tok
        }
        return nil
    }

    private func extractToken(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let tok = (obj["access_token"] as? String) ?? (obj["accessToken"] as? String) ?? (obj["apiKey"] as? String),
           !tok.isEmpty {
            return tok
        }
        return nil
    }
}

public enum FactoryAuthDecryptor {
    /// Decrypts Factory CLI v2 auth file (`<base64_iv>:<base64_tag>:<base64_ciphertext>`)
    /// using the AES-256 key stored in macOS Keychain (either raw 32 bytes or base64-encoded 32 bytes).
    public static func decrypt(payload: String, keyData: Data) -> Data? {
        #if canImport(CryptoKit)
        let rawKey: Data
        if keyData.count == 32 {
            rawKey = keyData
        } else if let keyString = String(data: keyData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let decoded = Data(base64Encoded: keyString),
            decoded.count == 32 {
            rawKey = decoded
        } else {
            return nil
        }

        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let iv = Data(base64Encoded: parts[0]),
              let tag = Data(base64Encoded: parts[1]),
              let ciphertext = Data(base64Encoded: parts[2]) else {
            return nil
        }

        do {
            let key = SymmetricKey(data: rawKey)
            let nonce = try AES.GCM.Nonce(data: iv)
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}

public enum FactoryUsageParser {
    public static let source = SourceAttribution(
        id: "factory.chat_usage",
        label: "Factory API",
        detail: "GET api.factory.ai/api/organization/members/chat-usage"
    )

    public static func parse(json: Data, accountID: String, now: Date = Date()) throws -> AccountSnapshot {
        let obj = try JSONSerialization.jsonObject(with: json)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decode("Factory 响应不是 JSON 对象")
        }
        let usage = (root["usage"] as? [String: Any]) ?? root
        let plan = (root["plan"] as? String) ?? (usage["plan"] as? String)
        let email = root["email"] as? String
        let usageReset = parseDate(usage["endDate"] ?? usage["resetAt"] ?? usage["billingPeriodEnd"])

        var windows: [QuotaWindow] = []
        if let std = usage["standard"] as? [String: Any] {
            if let w = makeWindow(id: "\(accountID).standard", title: "Standard 配额", dict: std, fallbackReset: usageReset, now: now) {
                windows.append(w)
            }
        }
        if let prem = usage["premium"] as? [String: Any] {
            if let w = makeWindow(id: "\(accountID).premium", title: "Premium 配额", dict: prem, fallbackReset: usageReset, now: now) {
                windows.append(w)
            }
        }
        if windows.isEmpty, let w = makeWindow(id: "\(accountID).usage", title: "Droid 配额", dict: usage, fallbackReset: usageReset, now: now) {
            windows.append(w)
        }

        return AccountSnapshot(
            account: AccountIdentity(
                id: accountID,
                providerID: "factory-droid",
                displayName: "Factory / Droid",
                email: email,
                planLabel: plan
            ),
            connection: .connected,
            windows: windows,
            lastSuccessAt: now,
            lastAttemptAt: now
        )
    }

    private static func makeWindow(
        id: String,
        title: String,
        dict: [String: Any],
        fallbackReset: Date?,
        now: Date
    ) -> QuotaWindow? {
        let used = number(dict["used"] ?? dict["userTokens"] ?? dict["orgTotalTokensUsed"])
        let allowance = number(dict["allowance"] ?? dict["totalAllowance"] ?? dict["basicAllowance"])
        let ratio = number(dict["usedRatio"] ?? dict["used_ratio"])

        // Skip unallocated / zero-allowance empty buckets (e.g. premium with totalAllowance == 0 and 0 usage).
        if let allowance, allowance <= 0, (used ?? 0) <= 0, (ratio ?? 0) <= 0 {
            return nil
        }

        let rawRatio: Double?
        if let used, let allowance, allowance > 0 {
            rawRatio = max(used / allowance, 0)
        } else if let ratio {
            // Factory's usedRatio is always a decimal ratio (1.0 = 100%, >1.0 = overage).
            rawRatio = max(ratio, 0)
        } else {
            rawRatio = nil
        }

        let usedFraction = rawRatio.map { min(max($0, 0), 1) }
        let reset = parseDate(dict["endDate"] ?? dict["resetAt"] ?? dict["billingPeriodEnd"]) ?? fallbackReset
        guard usedFraction != nil || reset != nil else { return nil }
        let rem = ResetMath.remainingFromUsed(usedFraction)
        return QuotaWindow(
            id: id,
            title: title,
            usedFraction: usedFraction,
            remainingFraction: rem,
            usedDisplay: rawRatio.map {
                MetricValue(
                    kind: .subscriptionQuota, precision: .reported, unit: .percentUsed,
                    value: $0 * 100, display: String(format: "%.0f%%", $0 * 100),
                    source: source, capturedAt: now, freshness: .fresh
                )
            } ?? .unknown(kind: .subscriptionQuota, unit: .percentUsed, source: source),
            remainingDisplay: rem.map {
                MetricValue(
                    kind: .subscriptionQuota, precision: .reported, unit: .percentRemaining,
                    value: $0 * 100, display: String(format: "%.0f%%", $0 * 100),
                    source: source, capturedAt: now, freshness: .fresh
                )
            } ?? .unknown(kind: .subscriptionQuota, unit: .percentRemaining, source: source),
            resetsAt: reset,
            resetKnown: reset != nil,
            source: source,
            capturedAt: now
        )
    }

    private static func number(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        if let i = raw as? Int { return Date(timeIntervalSince1970: i > 10_000_000_000 ? Double(i) / 1000.0 : Double(i)) }
        if let d = raw as? Double { return Date(timeIntervalSince1970: d > 10_000_000_000 ? d / 1000.0 : d) }
        if let s = raw as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        return nil
    }
}
