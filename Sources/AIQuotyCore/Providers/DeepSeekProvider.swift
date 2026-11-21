import Foundation

public struct DeepSeekProvider: QuotaProvider {
    public static let descriptor = ProviderDescriptor(
        id: "deepseek",
        displayName: "DeepSeek / DeepSeek Harness",
        implementationStatus: .implemented,
        authMethods: [.localCLICredentials, .apiKeyInKeychain],
        supportedMetricKinds: [.apiSpend],
        notes: "自动读取 DeepSeek Harness（~/.dsh/.credentials.yaml 中的 deepseek-account-platform 令牌，使用 x-dsh-auth-token），也支持钥匙串 DeepSeek API Key 或 ~/.deepseek/config.json，调用官方 GET api.deepseek.com/user/balance 查询账户余额。"
    )

    public var descriptor: ProviderDescriptor { Self.descriptor }

    private let credentials: CredentialStore
    private let http: HTTPClient
    private let fileSystem: FileSystemReading
    private let clock: @Sendable () -> Date
    private let configPaths: [String]
    private let dshCredentialsPath: String
    private let demoFixture: Data?

    public init(
        credentials: CredentialStore,
        http: HTTPClient,
        fileSystem: FileSystemReading,
        clock: @escaping @Sendable () -> Date = { Date() },
        configPaths: [String] = ["~/.deepseek/config.json", "~/.config/deepseek/config.json"],
        dshCredentialsPath: String = "~/.dsh/.credentials.yaml",
        demoFixture: Data? = nil
    ) {
        self.credentials = credentials
        self.http = http
        self.fileSystem = fileSystem
        self.clock = clock
        self.configPaths = configPaths
        self.dshCredentialsPath = dshCredentialsPath
        self.demoFixture = demoFixture
    }

    public func configuredAccounts() async -> [AccountIdentity] {
        guard let auth = resolveAuth() else { return [] }
        switch auth {
        case .apiKey:
            return [AccountIdentity(id: "deepseek.default", providerID: "deepseek", displayName: "DeepSeek")]
        case .dshGrant:
            return [AccountIdentity(id: "deepseek.dsh", providerID: "deepseek", displayName: "DeepSeek Harness")]
        }
    }

    public func fetch(request: ProviderFetchRequest) async throws -> [AccountSnapshot] {
        let now = request.now
        if request.demoMode, let demoFixture {
            return try [DeepSeekBalanceParser.parse(json: demoFixture, accountID: "deepseek.demo", displayName: "DeepSeek", now: now)]
        }
        guard let auth = resolveAuth() else {
            throw ProviderError.notConfigured("未找到 DeepSeek Harness 登录态（~/.dsh/.credentials.yaml）或 DeepSeek API Key。")
        }

        var headers: [String: String] = [
            "Accept": "application/json",
            "User-Agent": "AIQuoty/0.1",
        ]
        let accountID: String
        let displayName: String
        switch auth {
        case .apiKey(let key):
            headers["Authorization"] = "Bearer \(key)"
            accountID = "deepseek.default"
            displayName = "DeepSeek"
        case .dshGrant(let token):
            headers["x-dsh-auth-token"] = token
            accountID = "deepseek.dsh"
            displayName = "DeepSeek Harness"
        }

        let url = URL(string: "https://api.deepseek.com/user/balance")!
        let response = try await http.send(HTTPRequest(url: url, headers: headers))
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPStatusMapper.mapFailure(status: response.statusCode, body: response.bodyText, headers: response.headers)
        }
        return try [DeepSeekBalanceParser.parse(json: response.body, accountID: accountID, displayName: displayName, now: now)]
    }

    private enum ResolvedAuth {
        case apiKey(String)
        case dshGrant(String)
    }

    private func resolveAuth() -> ResolvedAuth? {
        if let key = try? credentials.getSecret(account: CredentialAccount.deepSeekAPIKey), !key.isEmpty {
            return .apiKey(key)
        }
        for path in configPaths {
            if fileSystem.fileExists(at: path),
               let data = try? fileSystem.readData(at: path),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let key = (obj["api_key"] as? String) ?? (obj["apiKey"] as? String), !key.isEmpty {
                    return .apiKey(key)
                }
            }
        }
        // Check DeepSeek Harness local credential store (`$DSH_HOME/.credentials.yaml` or `~/.dsh/.credentials.yaml`).
        var dshPaths = [dshCredentialsPath]
        if let envHome = ProcessInfo.processInfo.environment["DSH_HOME"], !envHome.isEmpty {
            dshPaths.insert((envHome as NSString).appendingPathComponent(".credentials.yaml"), at: 0)
        }
        for path in dshPaths {
            if fileSystem.fileExists(at: path),
               let text = try? fileSystem.readUTF8(at: path),
               let token = Self.parseDSHPlatformToken(yaml: text), !token.isEmpty {
                return .dshGrant(token)
            }
        }
        return nil
    }

    /// Parses the `deepseek-account-platform/default` (or any `deepseek-account-platform/*`) grant token
    /// from DeepSeek Harness's `~/.dsh/.credentials.yaml`.
    public static func parseDSHPlatformToken(yaml: String) -> String? {
        let lines = yaml.components(separatedBy: .newlines)
        var inPlatformRecord = false
        var recordIndent = Int.max

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = rawLine.prefix { $0 == " " }.count

            if trimmed.hasPrefix("deepseek-account-platform/") && trimmed.hasSuffix(":") {
                // Skip device id record; match account grant records (e.g. default).
                if trimmed == "deepseek-account-platform/device:" {
                    inPlatformRecord = false
                    continue
                }
                inPlatformRecord = true
                recordIndent = indent
                continue
            }

            if inPlatformRecord {
                if indent <= recordIndent {
                    inPlatformRecord = false
                    continue
                }
                if trimmed.hasPrefix("token:") {
                    let val = trimmed.dropFirst("token:".count)
                        .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
                    if !val.isEmpty {
                        return val
                    }
                }
            }
        }
        return nil
    }
}

public enum DeepSeekBalanceParser {
    public static let source = SourceAttribution(
        id: "deepseek.user.balance",
        label: "DeepSeek Balance API",
        detail: "GET api.deepseek.com/user/balance"
    )

    public static func parse(json: Data, accountID: String, displayName: String = "DeepSeek", now: Date = Date()) throws -> AccountSnapshot {
        let obj = try JSONSerialization.jsonObject(with: json)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decode("DeepSeek balance 响应不是 JSON 对象")
        }
        let isAvailable = root["is_available"] as? Bool ?? true
        let infos = root["balance_infos"] as? [[String: Any]] ?? []

        var metrics: [MetricValue] = []
        for info in infos {
            let currency = (info["currency"] as? String ?? "CNY").uppercased()
            let symbol = currency == "USD" ? "$" : (currency == "CNY" ? "¥" : "\(currency) ")
            let unit: QuotaUnit = currency == "USD" ? .usd : .credits

            if let total = number(info["total_balance"]) {
                metrics.append(
                    MetricValue(
                        kind: .apiSpend,
                        precision: .exact,
                        unit: unit,
                        value: total,
                        display: String(format: "%@%.2f 总余额 (%@)", symbol, total, currency),
                        source: source,
                        capturedAt: now,
                        freshness: .fresh
                    )
                )
            }
            if let topped = number(info["topped_up_balance"]), topped > 0 {
                metrics.append(
                    MetricValue(
                        kind: .apiSpend,
                        precision: .exact,
                        unit: unit,
                        value: topped,
                        display: String(format: "%@%.2f 充值余额", symbol, topped),
                        source: source,
                        capturedAt: now,
                        freshness: .fresh
                    )
                )
            }
            if let granted = number(info["granted_balance"]), granted > 0 {
                metrics.append(
                    MetricValue(
                        kind: .apiSpend,
                        precision: .exact,
                        unit: unit,
                        value: granted,
                        display: String(format: "%@%.2f 赠送余额", symbol, granted),
                        source: source,
                        capturedAt: now,
                        freshness: .fresh
                    )
                )
            }
        }

        var notes = ["DeepSeek 余额属于 API 预付余额，非订阅配额窗口。"]
        if !isAvailable {
            notes.append("账户当前标记为余额不足（is_available = false）。")
        }
        return AccountSnapshot(
            account: AccountIdentity(
                id: accountID,
                providerID: "deepseek",
                displayName: displayName,
                planLabel: isAvailable ? "API 可用" : "余额不足"
            ),
            connection: .connected,
            spendMetrics: metrics,
            lastSuccessAt: now,
            lastAttemptAt: now,
            notes: notes
        )
    }

    private static func number(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let s = raw as? String { return Double(s) }
        return nil
    }
}
