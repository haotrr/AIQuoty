import Foundation

public struct CodexOAuthProvider: QuotaProvider {
    public static let descriptor = ProviderDescriptor(
        id: "codex",
        displayName: "Codex",
        implementationStatus: .implemented,
        authMethods: [.localCLICredentials],
        supportedMetricKinds: [.subscriptionQuota, .apiSpend],
        notes: "读取 ~/.codex/auth.json（codex login），调用 chatgpt.com/backend-api/wham/usage。不覆盖 ChatGPT 普通聊天限额。"
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
        authPath: String = "~/.codex/auth.json",
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
        if fileSystem.fileExists(at: authPath) {
            return [AccountIdentity(id: "codex.default", providerID: "codex", displayName: "Codex")]
        }
        return []
    }

    public func fetch(request: ProviderFetchRequest) async throws -> [AccountSnapshot] {
        let now = request.now
        if request.demoMode, let demoFixture {
            return try [snapshot(from: demoFixture, accountID: "codex.demo", now: now)]
        }
        guard fileSystem.fileExists(at: authPath) else {
            throw ProviderError.notConfigured("未找到 ~/.codex/auth.json。请先运行 `codex login`。")
        }
        let auth = try CodexAuthParser.parse(json: try fileSystem.readData(at: authPath))
        var headers = [
            "Authorization": "Bearer \(auth.accessToken)",
            "Accept": "application/json",
            "User-Agent": "AIQuoty/0.1",
        ]
        if let accountID = auth.accountID {
            headers["ChatGPT-Account-Id"] = accountID
        }
        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let response = try await http.send(HTTPRequest(url: url, headers: headers))
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPStatusMapper.mapFailure(status: response.statusCode, body: response.bodyText, headers: response.headers)
        }
        var snap = try snapshot(from: response.body, accountID: "codex.default", now: now)
        if snap.account.email == nil {
            snap.account.email = auth.email
        }
        return [snap]
    }

    private func snapshot(from data: Data, accountID: String, now: Date) throws -> AccountSnapshot {
        let parsed = try CodexUsageParser.parse(json: data, now: now)
        let account = AccountIdentity(
            id: accountID,
            providerID: "codex",
            displayName: "Codex",
            email: parsed.email,
            planLabel: parsed.planType
        )
        let windows = CodexUsageParser.quotaWindows(from: parsed, accountID: accountID, capturedAt: now)
        var spend: [MetricValue] = []
        if let balance = parsed.creditsBalance {
            spend.append(
                MetricValue(
                    kind: .apiSpend,
                    precision: .reported,
                    unit: .credits,
                    value: Double(balance.replacingOccurrences(of: "$", with: "")),
                    display: balance,
                    source: CodexUsageParser.source,
                    capturedAt: now,
                    freshness: .fresh
                )
            )
        }
        return AccountSnapshot(
            account: account,
            connection: .connected,
            windows: windows,
            spendMetrics: spend,
            lastSuccessAt: now,
            lastAttemptAt: now
        )
    }
}
