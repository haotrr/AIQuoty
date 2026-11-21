import Foundation

public struct MiniMaxProvider: QuotaProvider {
    public static let descriptor = ProviderDescriptor(
        id: "minimax",
        displayName: "MiniMax Coding Plan",
        implementationStatus: .implemented,
        authMethods: [.apiKeyInKeychain],
        supportedMetricKinds: [.subscriptionQuota],
        notes: "使用钥匙串中的 MiniMax Coding Plan Key 调用 api.minimax.io / api.minimaxi.com coding_plan/remains 查询滚动 5 小时与周配额窗口。"
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
        if let key = try? credentials.getSecret(account: CredentialAccount.miniMaxAPIKey), !key.isEmpty {
            return [AccountIdentity(id: "minimax.default", providerID: "minimax", displayName: "MiniMax")]
        }
        return []
    }

    public func fetch(request: ProviderFetchRequest) async throws -> [AccountSnapshot] {
        let now = request.now
        if request.demoMode, let demoFixture {
            return try [MiniMaxQuotaParser.parse(json: demoFixture, accountID: "minimax.demo", now: now)]
        }
        guard let key = try credentials.getSecret(account: CredentialAccount.miniMaxAPIKey), !key.isEmpty else {
            throw ProviderError.notConfigured("未配置 MiniMax API Key。")
        }

        let headers: [String: String] = [
            "Authorization": "Bearer \(key)",
            "Accept": "application/json",
            "User-Agent": "AIQuoty/0.1",
        ]
        let endpoints = [
            "https://api.minimax.io/v1/api/openplatform/coding_plan/remains",
            "https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains",
        ]
        var lastError: ProviderError?
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            let resp = try await http.send(HTTPRequest(url: url, headers: headers))
            if (200..<300).contains(resp.statusCode) {
                if let snap = try? MiniMaxQuotaParser.parse(json: resp.body, accountID: "minimax.default", now: now),
                   !snap.windows.isEmpty {
                    return [snap]
                }
            }
            lastError = HTTPStatusMapper.mapFailure(status: resp.statusCode, body: resp.bodyText, headers: resp.headers)
            if resp.statusCode == 429 { throw lastError! }
        }
        throw lastError ?? ProviderError.network("MiniMax Coding Plan 请求失败")
    }
}

public enum MiniMaxQuotaParser {
    public static let source = SourceAttribution(
        id: "minimax.coding_plan",
        label: "MiniMax Coding Plan",
        detail: "GET /v1/api/openplatform/coding_plan/remains"
    )

    public static func parse(json: Data, accountID: String, now: Date = Date()) throws -> AccountSnapshot {
        let obj = try JSONSerialization.jsonObject(with: json)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decode("MiniMax 响应不是 JSON 对象")
        }
        if let baseResp = root["base_resp"] as? [String: Any],
           let code = baseResp["status_code"] as? Int, code != 0 {
            let msg = baseResp["status_msg"] as? String ?? "status_code \(code)"
            if code == 1004 || code == 2049 {
                throw ProviderError.authRequired("MiniMax 鉴权失败：\(msg)")
            }
            throw ProviderError.decode("MiniMax 返回错误：\(msg)")
        }

        let remains = (root["model_remains"] as? [[String: Any]]) ?? []
        var windows: [QuotaWindow] = []
        for (idx, item) in remains.enumerated() {
            let modelName = (item["model_name"] as? String) ?? "MiniMax"
            let total = number(item["current_interval_total_count"])
            let remainingCount = number(item["current_interval_usage_count"])
            // Note: MiniMax's `current_interval_usage_count` in coding_plan/remains represents remaining count in some versions
            // or used count when `current_interval_remaining_count` is absent; support explicit remaining_count first.
            let usedFraction: Double?
            if let total, total > 0 {
                if let remExplicit = number(item["current_interval_remaining_count"]) {
                    usedFraction = min(max(1 - remExplicit / total, 0), 1)
                } else if let remainingCount {
                    usedFraction = min(max(1 - remainingCount / total, 0), 1)
                } else {
                    usedFraction = nil
                }
            } else {
                usedFraction = nil
            }
            let resetAt: Date?
            if let endTime = number(item["end_time"]) {
                resetAt = Date(timeIntervalSince1970: endTime > 10_000_000_000 ? endTime / 1000.0 : endTime)
            } else if let remainsMs = number(item["remains_time"]), remainsMs > 0 {
                resetAt = now.addingTimeInterval(remainsMs / 1000.0)
            } else {
                resetAt = nil
            }
            let remFraction = ResetMath.remainingFromUsed(usedFraction)
            windows.append(
                QuotaWindow(
                    id: "\(accountID).\(idx)",
                    title: "\(modelName) (5 小时)",
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
                    resetsAt: resetAt,
                    resetKnown: resetAt != nil,
                    windowSeconds: 18_000,
                    source: source,
                    capturedAt: now
                )
            )
        }

        return AccountSnapshot(
            account: AccountIdentity(id: accountID, providerID: "minimax", displayName: "MiniMax", planLabel: "Coding Plan"),
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
}
