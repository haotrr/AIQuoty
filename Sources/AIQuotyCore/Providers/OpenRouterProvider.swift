import Foundation

public struct OpenRouterProvider: QuotaProvider {
    public static let descriptor = ProviderDescriptor(
        id: "openrouter",
        displayName: "OpenRouter",
        implementationStatus: .implemented,
        authMethods: [.apiKeyInKeychain],
        supportedMetricKinds: [.apiSpend],
        notes: "钥匙串中的 OpenRouter API Key → GET openrouter.ai/api/v1/key（余额/限额）。此为 API 余额，不是订阅配额。"
    )

    public var descriptor: ProviderDescriptor { Self.descriptor }

    private let credentials: CredentialStore
    private let http: HTTPClient
    private let clock: @Sendable () -> Date
    private let demoFixture: Data?

    public init(
        credentials: CredentialStore,
        http: HTTPClient,
        clock: @escaping @Sendable () -> Date = { Date() },
        demoFixture: Data? = nil
    ) {
        self.credentials = credentials
        self.http = http
        self.clock = clock
        self.demoFixture = demoFixture
    }

    public func configuredAccounts() async -> [AccountIdentity] {
        if let key = try? credentials.getSecret(account: CredentialAccount.openRouterAPIKey), !key.isEmpty {
            return [AccountIdentity(id: "openrouter.default", providerID: "openrouter", displayName: "OpenRouter")]
        }
        return []
    }

    public func fetch(request: ProviderFetchRequest) async throws -> [AccountSnapshot] {
        let now = request.now
        if request.demoMode, let demoFixture {
            return try [parse(demoFixture, now: now)]
        }
        guard let key = try credentials.getSecret(account: CredentialAccount.openRouterAPIKey), !key.isEmpty else {
            throw ProviderError.notConfigured("未配置 OpenRouter API Key")
        }
        let url = URL(string: "https://openrouter.ai/api/v1/key")!
        let response = try await http.send(
            HTTPRequest(
                url: url,
                headers: [
                    "Authorization": "Bearer \(key)",
                    "Accept": "application/json",
                    "User-Agent": "AIQuoty/0.1",
                ]
            )
        )
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPStatusMapper.mapFailure(status: response.statusCode, body: response.bodyText, headers: response.headers)
        }
        return try [parse(response.body, now: now)]
    }

    private func parse(_ data: Data, now: Date) throws -> AccountSnapshot {
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let dataObj = obj?["data"] as? [String: Any] ?? obj
        let source = SourceAttribution(id: "openrouter.key", label: "OpenRouter Key API", detail: "GET /api/v1/key")
        var spend: [MetricValue] = []
        if let limit = number(dataObj?["limit"]) {
            spend.append(
                MetricValue(
                    kind: .apiSpend,
                    precision: .exact,
                    unit: .usd,
                    value: limit,
                    display: String(format: "$%.2f limit", limit),
                    source: source,
                    capturedAt: now,
                    freshness: .fresh
                )
            )
        }
        if let usage = number(dataObj?["usage"]) {
            spend.append(
                MetricValue(
                    kind: .apiSpend,
                    precision: .exact,
                    unit: .usd,
                    value: usage,
                    display: String(format: "$%.4f used", usage),
                    source: source,
                    capturedAt: now,
                    freshness: .fresh
                )
            )
        }
        if let limitRemaining = number(dataObj?["limit_remaining"]) {
            spend.append(
                MetricValue(
                    kind: .apiSpend,
                    precision: .exact,
                    unit: .usd,
                    value: limitRemaining,
                    display: String(format: "$%.4f remaining", limitRemaining),
                    source: source,
                    capturedAt: now,
                    freshness: .fresh
                )
            )
        }
        return AccountSnapshot(
            account: AccountIdentity(id: "openrouter.default", providerID: "openrouter", displayName: "OpenRouter"),
            connection: .connected,
            spendMetrics: spend,
            lastSuccessAt: now,
            lastAttemptAt: now,
            notes: ["OpenRouter 数字属于 API 余额/限额，不是订阅配额窗口。"]
        )
    }

    private func number(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let s = raw as? String { return Double(s) }
        return nil
    }
}
