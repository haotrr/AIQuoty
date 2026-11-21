import Foundation

public struct AnthropicAdminSpendProvider: QuotaProvider {
    public static let descriptor = ProviderDescriptor(
        id: "anthropic-admin",
        displayName: "Anthropic Admin API Spend",
        implementationStatus: .partial,
        authMethods: [.apiKeyInKeychain],
        supportedMetricKinds: [.apiSpend],
        notes: "sk-ant-admin… 调用组织 cost_report。这是 API 花费，与 Claude 订阅配额完全分离显示。"
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
        if let key = try? credentials.getSecret(account: CredentialAccount.anthropicAdminKey), !key.isEmpty {
            return [AccountIdentity(id: "anthropic-admin.default", providerID: "anthropic-admin", displayName: "Anthropic Admin")]
        }
        return []
    }

    public func fetch(request: ProviderFetchRequest) async throws -> [AccountSnapshot] {
        let now = request.now
        if request.demoMode, let demoFixture {
            return try [parse(demoFixture, now: now)]
        }
        guard let key = try credentials.getSecret(account: CredentialAccount.anthropicAdminKey), !key.isEmpty else {
            throw ProviderError.notConfigured("未配置 Anthropic Admin API Key（sk-ant-admin…）")
        }
        // Documented Admin cost report; use a short recent window ending today UTC.
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd"
        let end = df.string(from: now)
        let startDate = Calendar(identifier: .gregorian).date(byAdding: .day, value: -30, to: now) ?? now
        let start = df.string(from: startDate)
        var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
        components.queryItems = [
            URLQueryItem(name: "starting_at", value: start),
            URLQueryItem(name: "ending_at", value: end),
        ]
        let response = try await http.send(
            HTTPRequest(
                url: components.url!,
                headers: [
                    "x-api-key": key,
                    "anthropic-version": "2023-06-01",
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
        let source = SourceAttribution(
            id: "anthropic.admin.cost_report",
            label: "Anthropic Admin Cost Report",
            detail: "GET /v1/organizations/cost_report"
        )
        var totalCents: Double = 0
        var sawAmount = false
        if let items = obj?["data"] as? [[String: Any]] {
            for item in items {
                if let amount = number(item["amount"] ?? (item["results"] as? [String: Any])?["amount"]) {
                    totalCents += amount
                    sawAmount = true
                }
            }
        }
        var spend: [MetricValue] = []
        if sawAmount {
            let usd = totalCents / 100.0
            spend.append(
                MetricValue(
                    kind: .apiSpend,
                    precision: .reported,
                    unit: .usd,
                    value: usd,
                    display: String(format: "$%.2f (30d)", usd),
                    source: source,
                    capturedAt: now,
                    freshness: .fresh
                )
            )
        } else {
            spend.append(.unknown(kind: .apiSpend, unit: .usd, source: source, reason: "报告中无金额字段"))
        }
        return AccountSnapshot(
            account: AccountIdentity(
                id: "anthropic-admin.default",
                providerID: "anthropic-admin",
                displayName: "Anthropic Admin Spend"
            ),
            connection: .connected,
            spendMetrics: spend,
            lastSuccessAt: now,
            lastAttemptAt: now,
            notes: ["Admin 花费 ≠ Claude 订阅剩余配额。"]
        )
    }

    private func number(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let s = raw as? String { return Double(s) }
        return nil
    }
}
