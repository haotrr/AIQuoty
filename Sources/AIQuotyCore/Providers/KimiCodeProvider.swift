import Foundation

public struct KimiCodeProvider: QuotaProvider {
    public static let descriptor = ProviderDescriptor(
        id: "kimi-code",
        displayName: "Kimi Code / Moonshot",
        implementationStatus: .implemented,
        authMethods: [.apiKeyInKeychain, .localCLICredentials],
        supportedMetricKinds: [.subscriptionQuota, .apiSpend],
        notes: "严格分列两类凭证：Kimi Code 订阅 Token（api.kimi.com/coding/v1/usages）显示订阅配额窗口；Moonshot 开放平台 API Key（api.moonshot.cn/v1/users/me/balance）显示 API 余额。"
    )

    public var descriptor: ProviderDescriptor { Self.descriptor }

    private let credentials: CredentialStore
    private let http: HTTPClient
    private let fileSystem: FileSystemReading
    private let clock: @Sendable () -> Date
    private let demoSubscriptionFixture: Data?
    private let demoBalanceFixture: Data?

    public init(
        credentials: CredentialStore,
        http: HTTPClient,
        fileSystem: FileSystemReading,
        clock: @escaping @Sendable () -> Date = { Date() },
        demoSubscriptionFixture: Data? = nil,
        demoBalanceFixture: Data? = nil
    ) {
        self.credentials = credentials
        self.http = http
        self.fileSystem = fileSystem
        self.clock = clock
        self.demoSubscriptionFixture = demoSubscriptionFixture
        self.demoBalanceFixture = demoBalanceFixture
    }

    public func configuredAccounts() async -> [AccountIdentity] {
        var accounts: [AccountIdentity] = []
        if resolveKimiCodeToken() != nil {
            accounts.append(AccountIdentity(id: "kimi.code", providerID: "kimi-code", displayName: "Kimi Code"))
        }
        if let key = try? credentials.getSecret(account: CredentialAccount.moonshotAPIKey), !key.isEmpty {
            accounts.append(AccountIdentity(id: "moonshot.api", providerID: "kimi-code", displayName: "Moonshot API"))
        }
        return accounts
    }

    public func fetch(request: ProviderFetchRequest) async throws -> [AccountSnapshot] {
        let now = request.now
        if request.demoMode {
            var snaps: [AccountSnapshot] = []
            if let sub = demoSubscriptionFixture {
                snaps.append(try KimiUsageParser.parseCodingUsage(json: sub, accountID: "kimi.demo", now: now))
            }
            if let bal = demoBalanceFixture {
                snaps.append(try KimiUsageParser.parseMoonshotBalance(json: bal, accountID: "moonshot.demo", now: now))
            }
            if !snaps.isEmpty { return snaps }
        }

        let kimiToken = resolveKimiCodeToken()
        let moonshotKey = try? credentials.getSecret(account: CredentialAccount.moonshotAPIKey)
        let hasKimi = kimiToken != nil && !(kimiToken?.isEmpty ?? true)
        let hasMoonshot = moonshotKey != nil && !(moonshotKey?.isEmpty ?? true)

        guard hasKimi || hasMoonshot else {
            throw ProviderError.notConfigured("未配置 Kimi Code Token 或 Moonshot API Key。")
        }

        var results: [AccountSnapshot] = []

        if let token = kimiToken, !token.isEmpty {
            let url = URL(string: "https://api.kimi.com/coding/v1/usages")!
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
            results.append(try KimiUsageParser.parseCodingUsage(json: resp.body, accountID: "kimi.code", now: now))
        }

        if let key = moonshotKey, !key.isEmpty {
            let url = URL(string: "https://api.moonshot.cn/v1/users/me/balance")!
            let resp = try await http.send(
                HTTPRequest(
                    url: url,
                    headers: [
                        "Authorization": "Bearer \(key)",
                        "Accept": "application/json",
                        "User-Agent": "AIQuoty/0.1",
                    ]
                )
            )
            guard (200..<300).contains(resp.statusCode) else {
                throw HTTPStatusMapper.mapFailure(status: resp.statusCode, body: resp.bodyText, headers: resp.headers)
            }
            results.append(try KimiUsageParser.parseMoonshotBalance(json: resp.body, accountID: "moonshot.api", now: now))
        }

        return results
    }

    private func resolveKimiCodeToken() -> String? {
        if let token = try? credentials.getSecret(account: CredentialAccount.kimiCodeToken), !token.isEmpty {
            return token
        }
        for path in ["~/.kimi/credentials.json", "~/.config/kimi/auth.json"] {
            if fileSystem.fileExists(at: path),
               let data = try? fileSystem.readData(at: path),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let tok = (obj["access_token"] as? String) ?? (obj["api_key"] as? String) ?? (obj["token"] as? String), !tok.isEmpty {
                    return tok
                }
            }
        }
        return nil
    }
}

public enum KimiUsageParser {
    public static let codingSource = SourceAttribution(
        id: "kimi.coding.usages",
        label: "Kimi Code Usages",
        detail: "GET api.kimi.com/coding/v1/usages"
    )
    public static let moonshotSource = SourceAttribution(
        id: "moonshot.balance",
        label: "Moonshot Balance API",
        detail: "GET api.moonshot.cn/v1/users/me/balance"
    )

    public static func parseCodingUsage(json: Data, accountID: String, now: Date = Date()) throws -> AccountSnapshot {
        let obj = try JSONSerialization.jsonObject(with: json)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decode("Kimi Code 响应不是 JSON 对象")
        }
        let body = (root["data"] as? [String: Any]) ?? root
        let plan = (body["plan"] as? String) ?? (body["membership"] as? String)
        var windows: [QuotaWindow] = []

        if let limits = body["limits"] as? [[String: Any]] {
            for (idx, item) in limits.enumerated() {
                let title = (item["window"] as? String) ?? (item["name"] as? String) ?? (item["type"] as? String) ?? "配额 \(idx + 1)"
                let detail = (item["detail"] as? [String: Any]) ?? item
                if let w = makeWindow(id: "\(accountID).limit.\(idx)", title: title, dict: detail, now: now) {
                    windows.append(w)
                }
            }
        } else if let usage = body["usage"] as? [String: Any] {
            if let w = makeWindow(id: "\(accountID).usage", title: "Coding 配额", dict: usage, now: now) {
                windows.append(w)
            }
        }

        return AccountSnapshot(
            account: AccountIdentity(id: accountID, providerID: "kimi-code", displayName: "Kimi Code", planLabel: plan),
            connection: .connected,
            windows: windows,
            lastSuccessAt: now,
            lastAttemptAt: now
        )
    }

    public static func parseMoonshotBalance(json: Data, accountID: String, now: Date = Date()) throws -> AccountSnapshot {
        let obj = try JSONSerialization.jsonObject(with: json)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decode("Moonshot balance 响应不是 JSON 对象")
        }
        let dataObj = (root["data"] as? [String: Any]) ?? root
        var metrics: [MetricValue] = []
        if let avail = number(dataObj["available_balance"]) {
            metrics.append(
                MetricValue(
                    kind: .apiSpend, precision: .exact, unit: .credits,
                    value: avail, display: String(format: "¥%.2f 可用余额", avail),
                    source: moonshotSource, capturedAt: now, freshness: .fresh
                )
            )
        }
        if let cash = number(dataObj["cash_balance"]), cash > 0 {
            metrics.append(
                MetricValue(
                    kind: .apiSpend, precision: .exact, unit: .credits,
                    value: cash, display: String(format: "¥%.2f 现金余额", cash),
                    source: moonshotSource, capturedAt: now, freshness: .fresh
                )
            )
        }
        if let voucher = number(dataObj["voucher_balance"]), voucher > 0 {
            metrics.append(
                MetricValue(
                    kind: .apiSpend, precision: .exact, unit: .credits,
                    value: voucher, display: String(format: "¥%.2f 代金券", voucher),
                    source: moonshotSource, capturedAt: now, freshness: .fresh
                )
            )
        }
        return AccountSnapshot(
            account: AccountIdentity(id: accountID, providerID: "kimi-code", displayName: "Moonshot API", planLabel: "API 余额"),
            connection: .connected,
            spendMetrics: metrics,
            lastSuccessAt: now,
            lastAttemptAt: now,
            notes: ["Moonshot 开放平台余额属于 API 预付余额，与 Kimi Code 订阅配额相互独立。"]
        )
    }

    private static func makeWindow(id: String, title: String, dict: [String: Any], now: Date) -> QuotaWindow? {
        let used: Double?
        if let u = number(dict["used"]), let limit = number(dict["limit"]), limit > 0 {
            used = min(max(u / limit, 0), 1)
        } else if let rem = number(dict["remaining"]), let limit = number(dict["limit"]), limit > 0 {
            used = min(max(1 - rem / limit, 0), 1)
        } else if let pct = number(dict["used_percent"] ?? dict["usedPercent"]) {
            used = min(max(pct / 100.0, 0), 1)
        } else {
            used = nil
        }
        let reset = parseDate(dict["resetTime"] ?? dict["reset_time"] ?? dict["resetAt"])
        guard used != nil || reset != nil else { return nil }
        let rem = ResetMath.remainingFromUsed(used)
        return QuotaWindow(
            id: id,
            title: title,
            usedFraction: used,
            remainingFraction: rem,
            usedDisplay: used.map {
                MetricValue(
                    kind: .subscriptionQuota, precision: .reported, unit: .percentUsed,
                    value: $0 * 100, display: String(format: "%.0f%%", $0 * 100),
                    source: codingSource, capturedAt: now, freshness: .fresh
                )
            } ?? .unknown(kind: .subscriptionQuota, unit: .percentUsed, source: codingSource),
            remainingDisplay: rem.map {
                MetricValue(
                    kind: .subscriptionQuota, precision: .reported, unit: .percentRemaining,
                    value: $0 * 100, display: String(format: "%.0f%%", $0 * 100),
                    source: codingSource, capturedAt: now, freshness: .fresh
                )
            } ?? .unknown(kind: .subscriptionQuota, unit: .percentRemaining, source: codingSource),
            resetsAt: reset,
            resetKnown: reset != nil,
            source: codingSource,
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
