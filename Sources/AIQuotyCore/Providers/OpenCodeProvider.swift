import Foundation

public struct OpenCodeProvider: QuotaProvider {
    public static let descriptor = ProviderDescriptor(
        id: "opencode",
        displayName: "OpenCode",
        implementationStatus: .implemented,
        authMethods: [.localCLICredentials, .apiKeyInKeychain, .userPastedToken],
        supportedMetricKinds: [.subscriptionQuota, .apiSpend],
        notes: "支持读取 ~/.local/share/opencode/auth.json 或钥匙串中的 OpenCode API Key / Console Cookie，查询 OpenCode Zen/Go 订阅窗口与余额；也可在通用设置开启 OpenCode 本地会话日志估算。"
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
        authPath: String = "~/.local/share/opencode/auth.json",
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
        if resolveAuth() != nil {
            return [AccountIdentity(id: "opencode.default", providerID: "opencode", displayName: "OpenCode")]
        }
        return []
    }

    public func fetch(request: ProviderFetchRequest) async throws -> [AccountSnapshot] {
        let now = request.now
        if request.demoMode, let demoFixture {
            return try [OpenCodeUsageParser.parse(json: demoFixture, accountID: "opencode.demo", now: now)]
        }
        guard let auth = resolveAuth() else {
            throw ProviderError.notConfigured("未配置 OpenCode。请在设置中保存 OpenCode API Key / Console Cookie，或通过 opencode auth login 生成 ~/.local/share/opencode/auth.json。")
        }

        var headers: [String: String] = [
            "Accept": "application/json",
            "User-Agent": "AIQuoty/0.1",
        ]
        switch auth {
        case .apiKey(let key):
            headers["Authorization"] = "Bearer \(key)"
        case .cookie(let cookie):
            headers["Cookie"] = cookie.hasPrefix("Cookie:") ? String(cookie.dropFirst(7)).trimmingCharacters(in: .whitespaces) : cookie
        }

        let endpoints = [
            "https://opencode.ai/zen/go/v1/usage",
            "https://opencode.ai/console/api/go/status",
        ]
        var lastError: ProviderError?
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            let resp = try await http.send(HTTPRequest(url: url, headers: headers))
            if (200..<300).contains(resp.statusCode) {
                return try [OpenCodeUsageParser.parse(json: resp.body, accountID: "opencode.default", now: now)]
            }
            let mapped = HTTPStatusMapper.mapFailure(status: resp.statusCode, body: resp.bodyText, headers: resp.headers)
            lastError = mapped
            if resp.statusCode == 401 || resp.statusCode == 403 || resp.statusCode == 429 {
                throw mapped
            }
        }
        throw lastError ?? ProviderError.network("OpenCode 配额请求失败")
    }

    private enum ResolvedAuth {
        case apiKey(String)
        case cookie(String)
    }

    private func resolveAuth() -> ResolvedAuth? {
        if let key = try? credentials.getSecret(account: CredentialAccount.openCodeAPIKey), !key.isEmpty {
            return .apiKey(key)
        }
        if let cookie = try? credentials.getSecret(account: CredentialAccount.openCodeSessionCookie), !cookie.isEmpty {
            return .cookie(cookie)
        }
        if fileSystem.fileExists(at: authPath),
           let data = try? fileSystem.readData(at: authPath),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for providerKey in ["opencode", "opencode-go", "opencode-zen"] {
                if let entry = root[providerKey] as? [String: Any] {
                    if let key = (entry["key"] as? String) ?? (entry["apiKey"] as? String) ?? (entry["access"] as? String), !key.isEmpty {
                        return .apiKey(key)
                    }
                }
            }
        }
        return nil
    }
}

public enum OpenCodeUsageParser {
    public static let source = SourceAttribution(
        id: "opencode.usage",
        label: "OpenCode Console / Go",
        detail: "GET opencode.ai/zen/go/v1/usage"
    )

    public static func parse(json: Data, accountID: String, now: Date = Date()) throws -> AccountSnapshot {
        let obj = try JSONSerialization.jsonObject(with: json)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decode("OpenCode 响应不是 JSON 对象")
        }
        let body = (root["data"] as? [String: Any]) ?? root
        let plan = (body["plan"] as? String) ?? (body["tier"] as? String) ?? (body["subscription"] as? String)
        let email = body["email"] as? String

        var windows: [QuotaWindow] = []
        let windowSpecs: [(key: String, title: String, seconds: Int?)] = [
            ("fiveHour", "5 小时", 18_000),
            ("five_hour", "5 小时", 18_000),
            ("rolling5h", "5 小时", 18_000),
            ("weekly", "7 天", 604_800),
            ("seven_day", "7 天", 604_800),
            ("monthly", "30 天", 2_592_000),
        ]
        var seenTitles = Set<String>()
        for spec in windowSpecs {
            guard !seenTitles.contains(spec.title),
                  let dict = body[spec.key] as? [String: Any] else { continue }
            if let w = makeWindow(id: "\(accountID).\(spec.key)", title: spec.title, seconds: spec.seconds, dict: dict, now: now) {
                windows.append(w)
                seenTitles.insert(spec.title)
            }
        }

        var spend: [MetricValue] = []
        if let balance = number(body["balance"] ?? body["balanceUsd"] ?? body["balance_usd"]) {
            spend.append(
                MetricValue(
                    kind: .apiSpend,
                    precision: .exact,
                    unit: .usd,
                    value: balance,
                    display: String(format: "$%.2f 余额", balance),
                    source: source,
                    capturedAt: now,
                    freshness: .fresh
                )
            )
        }
        if let spent = number(body["monthlySpend"] ?? body["spend_usd"]) {
            spend.append(
                MetricValue(
                    kind: .apiSpend,
                    precision: .exact,
                    unit: .usd,
                    value: spent,
                    display: String(format: "$%.2f 已消费", spent),
                    source: source,
                    capturedAt: now,
                    freshness: .fresh
                )
            )
        }

        return AccountSnapshot(
            account: AccountIdentity(
                id: accountID,
                providerID: "opencode",
                displayName: "OpenCode",
                email: email,
                planLabel: plan
            ),
            connection: .connected,
            windows: windows,
            spendMetrics: spend,
            lastSuccessAt: now,
            lastAttemptAt: now
        )
    }

    private static func makeWindow(id: String, title: String, seconds: Int?, dict: [String: Any], now: Date) -> QuotaWindow? {
        let used: Double?
        if let pct = number(dict["usedPercent"] ?? dict["used_percent"] ?? dict["percentUsed"]) {
            used = min(max(pct / 100.0, 0), 1)
        } else if let util = number(dict["utilization"]) {
            used = min(max(util > 1 ? util / 100.0 : util, 0), 1)
        } else if let u = number(dict["used"]), let limit = number(dict["limit"]), limit > 0 {
            used = min(max(u / limit, 0), 1)
        } else {
            used = nil
        }
        let reset = parseDate(dict["resetAt"] ?? dict["reset_at"] ?? dict["resetsAt"])
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
            windowSeconds: seconds,
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
