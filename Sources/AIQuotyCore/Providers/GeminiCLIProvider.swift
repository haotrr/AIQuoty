import Foundation

public struct GeminiCLIProvider: QuotaProvider {
    public static let descriptor = ProviderDescriptor(
        id: "gemini",
        displayName: "Gemini CLI / Code Assist",
        implementationStatus: .implemented,
        authMethods: [.localCLICredentials],
        supportedMetricKinds: [.subscriptionQuota],
        notes: "读取 ~/.gemini/oauth_creds.json，调用 cloudcode-pa.googleapis.com retrieveUserQuota。不做 Gemini App 浏览器 Cookie。"
    )

    public var descriptor: ProviderDescriptor { Self.descriptor }

    private let credentials: CredentialStore
    private let http: HTTPClient
    private let fileSystem: FileSystemReading
    private let clock: @Sendable () -> Date
    private let credsPath: String
    private let demoFixture: Data?

    public init(
        credentials: CredentialStore,
        http: HTTPClient,
        fileSystem: FileSystemReading,
        clock: @escaping @Sendable () -> Date = { Date() },
        credsPath: String = "~/.gemini/oauth_creds.json",
        demoFixture: Data? = nil
    ) {
        self.credentials = credentials
        self.http = http
        self.fileSystem = fileSystem
        self.clock = clock
        self.credsPath = credsPath
        self.demoFixture = demoFixture
    }

    public func configuredAccounts() async -> [AccountIdentity] {
        if fileSystem.fileExists(at: credsPath) {
            return [AccountIdentity(id: "gemini.cli", providerID: "gemini", displayName: "Gemini CLI")]
        }
        return []
    }

    public func fetch(request: ProviderFetchRequest) async throws -> [AccountSnapshot] {
        let now = request.now
        if request.demoMode, let demoFixture {
            let parsed = try GeminiQuotaParser.parseQuota(json: demoFixture, now: now)
            return [
                AccountSnapshot(
                    account: AccountIdentity(id: "gemini.demo", providerID: "gemini", displayName: "Gemini Demo"),
                    connection: .connected,
                    windows: GeminiQuotaParser.collapsedWindows(from: parsed, accountID: "gemini.demo", capturedAt: now),
                    lastSuccessAt: now,
                    lastAttemptAt: now
                ),
            ]
        }
        guard fileSystem.fileExists(at: credsPath) else {
            throw ProviderError.notConfigured("未找到 ~/.gemini/oauth_creds.json。请先登录 Gemini CLI。")
        }
        let creds = try GeminiOAuthParser.parse(json: try fileSystem.readData(at: credsPath))
        if let expiry = creds.expiryDate, expiry < now {
            throw ProviderError.authRequired("Gemini access_token 已过期；请重新运行 gemini 登录（本应用不自动刷新 Google client secret）。")
        }
        let token = try credentials.getSecret(account: CredentialAccount.geminiOAuthOverride) ?? creds.accessToken

        // Best-effort tier
        var plan: String?
        if let tierURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist") {
            let body = try JSONSerialization.data(withJSONObject: [
                "metadata": ["ideType": "GEMINI_CLI", "pluginType": "GEMINI"],
            ])
            let tierResp = try? await http.send(
                HTTPRequest(
                    method: "POST",
                    url: tierURL,
                    headers: [
                        "Authorization": "Bearer \(token)",
                        "Content-Type": "application/json",
                        "User-Agent": "AIQuoty/0.1",
                    ],
                    body: body
                )
            )
            if let tierResp, (200..<300).contains(tierResp.statusCode) {
                plan = GeminiQuotaParser.parseTier(json: tierResp.body)
            }
        }

        let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
        let body = try JSONSerialization.data(withJSONObject: [:] as [String: Any])
        let response = try await http.send(
            HTTPRequest(
                method: "POST",
                url: url,
                headers: [
                    "Authorization": "Bearer \(token)",
                    "Content-Type": "application/json",
                    "User-Agent": "AIQuoty/0.1",
                ],
                body: body
            )
        )
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPStatusMapper.mapFailure(status: response.statusCode, body: response.bodyText, headers: response.headers)
        }
        let parsed = try GeminiQuotaParser.parseQuota(json: response.body, now: now)
        let account = AccountIdentity(
            id: "gemini.cli",
            providerID: "gemini",
            displayName: "Gemini CLI",
            email: creds.email,
            planLabel: plan
        )
        return [
            AccountSnapshot(
                account: account,
                connection: .connected,
                windows: GeminiQuotaParser.collapsedWindows(from: parsed, accountID: account.id, capturedAt: now),
                lastSuccessAt: now,
                lastAttemptAt: now
            ),
        ]
    }
}
