import Foundation

public struct FactoryDroidProvider: QuotaProvider {
    public static let descriptor = ProviderDescriptor(
        id: "factory-droid",
        displayName: "Factory / Droid",
        implementationStatus: .implemented,
        authMethods: [.apiKeyInKeychain, .localCLICredentials],
        supportedMetricKinds: [.subscriptionQuota],
        notes: "使用钥匙串中的 Factory API Key (fk-...) 或 ~/.factory/auth.json，调用 api.factory.ai/api/organization/members/chat-usage 查询订阅配额。"
    )

    public var descriptor: ProviderDescriptor { Self.descriptor }

    private let credentials: CredentialStore
    private let http: HTTPClient
    private let fileSystem: FileSystemReading
    private let clock: @Sendable () -> Date
    private let authPath: String
    private let demoFixture: Data?

    public init(
        credentials: CredentialStore,
        http: HTTPClient,
        fileSystem: FileSystemReading,
        clock: @escaping @Sendable () -> Date = { Date() },
        authPath: String = "~/.factory/auth.json",
        demoFixture: Data? = nil
    ) {
        self.credentials = credentials
        self.http = http
        self.fileSystem = fileSystem
        self.clock = clock
        self.authPath = authPath
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
            throw ProviderError.notConfigured("未配置 Factory API Key 或 ~/.factory/auth.json。")
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
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let tok = (obj["access_token"] as? String) ?? (obj["accessToken"] as? String) ?? (obj["apiKey"] as? String), !tok.isEmpty {
                return tok
            }
        }
        return nil
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

        var windows: [QuotaWindow] = []
        if let std = usage["standard"] as? [String: Any] {
            if let w = makeWindow(id: "\(accountID).standard", title: "Standard 配额", dict: std, now: now) {
                windows.append(w)
            }
        }
        if let prem = usage["premium"] as? [String: Any] {
            if let w = makeWindow(id: "\(accountID).premium", title: "Premium 配额", dict: prem, now: now) {
                windows.append(w)
            }
        }
        if windows.isEmpty, let w = makeWindow(id: "\(accountID).usage", title: "Droid 配额", dict: usage, now: now) {
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

    private static func makeWindow(id: String, title: String, dict: [String: Any], now: Date) -> QuotaWindow? {
        let usedFraction: Double?
        if let ratio = number(dict["usedRatio"] ?? dict["used_ratio"]) {
            usedFraction = min(max(ratio > 1 ? ratio / 100.0 : ratio, 0), 1)
        } else if let used = number(dict["used"] ?? dict["userTokens"]),
                  let allowance = number(dict["allowance"] ?? dict["totalAllowance"]), allowance > 0 {
            usedFraction = min(max(used / allowance, 0), 1)
        } else {
            usedFraction = nil
        }
        let reset = parseDate(dict["endDate"] ?? dict["resetAt"] ?? dict["billingPeriodEnd"])
        guard usedFraction != nil || reset != nil else { return nil }
        let rem = ResetMath.remainingFromUsed(usedFraction)
        return QuotaWindow(
            id: id,
            title: title,
            usedFraction: usedFraction,
            remainingFraction: rem,
            usedDisplay: usedFraction.map {
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
