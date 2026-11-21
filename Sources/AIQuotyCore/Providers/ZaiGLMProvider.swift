import Foundation

public struct ZaiGLMProvider: QuotaProvider {
    public static let descriptor = ProviderDescriptor(
        id: "zai",
        displayName: "智谱 GLM / Z.ai",
        implementationStatus: .implemented,
        authMethods: [.apiKeyInKeychain],
        supportedMetricKinds: [.subscriptionQuota],
        notes: "使用钥匙串中的智谱 BigModel / Z.ai Coding Plan Key 调用 api.z.ai 或 open.bigmodel.cn 的 /api/monitor/usage/quota/limit 查询配额窗口。"
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
        if let key = try? credentials.getSecret(account: CredentialAccount.zaiAPIKey), !key.isEmpty {
            return [AccountIdentity(id: "zai.default", providerID: "zai", displayName: "智谱 GLM / Z.ai")]
        }
        return []
    }

    public func fetch(request: ProviderFetchRequest) async throws -> [AccountSnapshot] {
        let now = request.now
        if request.demoMode, let demoFixture {
            return try [ZaiQuotaParser.parse(json: demoFixture, accountID: "zai.demo", now: now)]
        }
        guard let key = try credentials.getSecret(account: CredentialAccount.zaiAPIKey), !key.isEmpty else {
            throw ProviderError.notConfigured("未配置智谱 GLM / Z.ai API Key。")
        }

        let headers: [String: String] = [
            "Authorization": "Bearer \(key)",
            "Accept": "application/json",
            "User-Agent": "AIQuoty/0.1",
        ]
        let endpoints = [
            "https://open.bigmodel.cn/api/monitor/usage/quota/limit",
            "https://api.z.ai/api/monitor/usage/quota/limit",
        ]
        var lastError: ProviderError?
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            let resp = try await http.send(HTTPRequest(url: url, headers: headers))
            if (200..<300).contains(resp.statusCode) {
                if let snap = try? ZaiQuotaParser.parse(json: resp.body, accountID: "zai.default", now: now),
                   !snap.windows.isEmpty {
                    return [snap]
                }
            }
            lastError = HTTPStatusMapper.mapFailure(status: resp.statusCode, body: resp.bodyText, headers: resp.headers)
            if resp.statusCode == 429 { throw lastError! }
        }
        throw lastError ?? ProviderError.network("智谱 GLM / Z.ai 配额请求失败")
    }
}

public enum ZaiQuotaParser {
    public static let source = SourceAttribution(
        id: "zai.quota.limit",
        label: "Z.ai / BigModel Quota API",
        detail: "GET /api/monitor/usage/quota/limit"
    )

    public static func parse(json: Data, accountID: String, now: Date = Date()) throws -> AccountSnapshot {
        let obj = try JSONSerialization.jsonObject(with: json)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decode("Z.ai / BigModel 响应不是 JSON 对象")
        }
        let dataObj = (root["data"] as? [String: Any]) ?? root
        let limits = (dataObj["limits"] as? [[String: Any]]) ?? []
        let plan = (dataObj["planName"] as? String) ?? (dataObj["level"] as? String) ?? "GLM Coding"

        var windows: [QuotaWindow] = []
        for (idx, item) in limits.enumerated() {
            let type = (item["type"] as? String) ?? "QUOTA"
            let title: String
            switch type {
            case "TOKENS_LIMIT": title = "Token 配额"
            case "TIME_LIMIT": title = "MCP / 时长配额"
            case "CREDIT_LIMIT": title = "Credits 配额"
            default: title = type
            }
            let usedFraction: Double?
            if let pct = number(item["percentage"]) {
                usedFraction = min(max(pct / 100.0, 0), 1)
            } else if let cur = number(item["currentValue"]), let total = number(item["usage"]), total > 0 {
                usedFraction = min(max(cur / total, 0), 1)
            } else {
                usedFraction = nil
            }
            let reset = parseDate(item["nextResetTime"])
            let remFraction = ResetMath.remainingFromUsed(usedFraction)
            windows.append(
                QuotaWindow(
                    id: "\(accountID).\(type.lowercased()).\(idx)",
                    title: title,
                    usedFraction: usedFraction,
                    remainingFraction: remFraction,
                    usedDisplay: usedFraction.map {
                        MetricValue(
                            kind: .subscriptionQuota, precision: .reported, unit: .percentUsed,
                            value: $0 * 100, display: String(format: "%.0f%%", $0 * 100),
                            source: source, capturedAt: now, freshness: .fresh
                        )
                    } ?? .unknown(kind: .subscriptionQuota, unit: .percentUsed, source: source),
                    remainingDisplay: remFraction.map {
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
            )
        }

        return AccountSnapshot(
            account: AccountIdentity(id: accountID, providerID: "zai", displayName: "智谱 GLM / Z.ai", planLabel: plan),
            connection: .connected,
            windows: windows,
            lastSuccessAt: now,
            lastAttemptAt: now
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
