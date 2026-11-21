import Foundation

public struct ClaudeOAuthProvider: QuotaProvider {
    public static let descriptor = ProviderDescriptor(
        id: "claude",
        displayName: "Claude / Claude Code",
        implementationStatus: .implemented,
        authMethods: [.localCLICredentials, .userPastedToken],
        supportedMetricKinds: [.subscriptionQuota],
        notes: "读取 ~/.claude/.credentials.json 或 Keychain 中的 OAuth token；调用 api.anthropic.com/api/oauth/usage。不提取浏览器 Cookie。"
    )

    public var descriptor: ProviderDescriptor { Self.descriptor }

    private let credentials: CredentialStore
    private let http: HTTPClient
    private let fileSystem: FileSystemReading
    private let clock: @Sendable () -> Date
    private let credentialsPath: String
    private let demoFixture: Data?

    public init(
        credentials: CredentialStore,
        http: HTTPClient,
        fileSystem: FileSystemReading,
        clock: @escaping @Sendable () -> Date = { Date() },
        credentialsPath: String = "~/.claude/.credentials.json",
        demoFixture: Data? = nil
    ) {
        self.credentials = credentials
        self.http = http
        self.fileSystem = fileSystem
        self.clock = clock
        self.credentialsPath = credentialsPath
        self.demoFixture = demoFixture
    }

    public func configuredAccounts() async -> [AccountIdentity] {
        if let override = try? credentials.getSecret(account: CredentialAccount.claudeOAuthOverride), !override.isEmpty {
            return [AccountIdentity(id: "claude.override", providerID: "claude", displayName: "Claude (Keychain)")]
        }
        if fileSystem.fileExists(at: credentialsPath) {
            return [AccountIdentity(id: "claude.cli", providerID: "claude", displayName: "Claude Code")]
        }
        return []
    }

    public func fetch(request: ProviderFetchRequest) async throws -> [AccountSnapshot] {
        let now = request.now
        if request.demoMode, let demoFixture {
            return try [snapshot(from: demoFixture, accountID: "claude.demo", displayName: "Claude Demo", email: "demo@example.com", now: now)]
        }
        let token: String
        let accountID: String
        var email: String?
        if let override = try credentials.getSecret(account: CredentialAccount.claudeOAuthOverride), !override.isEmpty {
            token = override
            accountID = "claude.override"
        } else if fileSystem.fileExists(at: credentialsPath) {
            let data = try fileSystem.readData(at: credentialsPath)
            let parsed = try ClaudeCredentialsParser.parse(json: data)
            token = parsed.accessToken
            accountID = "claude.cli"
            email = parsed.email
            if let expires = parsed.expiresAt, expires < now {
                throw ProviderError.authRequired("Claude OAuth 已过期，请在 Claude Code 中重新登录")
            }
        } else {
            throw ProviderError.notConfigured("未找到 Claude 凭证。请登录 Claude Code，或在设置中粘贴带 user:profile 范围的 OAuth token 到钥匙串。")
        }

        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        let response = try await http.send(
            HTTPRequest(
                url: url,
                headers: [
                    "Authorization": "Bearer \(token)",
                    "anthropic-beta": "oauth-2025-04-20",
                    "Accept": "application/json",
                    "User-Agent": "AIQuoty/0.1",
                ]
            )
        )
        if response.statusCode == 429 {
            throw HTTPStatusMapper.mapFailure(status: 429, body: response.bodyText, headers: response.headers)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPStatusMapper.mapFailure(status: response.statusCode, body: response.bodyText, headers: response.headers)
        }
        return try [snapshot(from: response.body, accountID: accountID, displayName: "Claude", email: email, now: now)]
    }

    private func snapshot(from data: Data, accountID: String, displayName: String, email: String?, now: Date) throws -> AccountSnapshot {
        let parsed = try ClaudeUsageParser.parse(json: data, now: now)
        let account = AccountIdentity(
            id: accountID,
            providerID: "claude",
            displayName: displayName,
            email: email,
            planLabel: parsed.planHint
        )
        let windows = ClaudeUsageParser.windows(from: parsed, accountID: accountID, capturedAt: now)
        var notes: [String] = []
        if windows.isEmpty {
            notes.append("响应中未包含可显示的订阅配额窗口（可能是 Free / 企业无窗口）。保持未知，不显示为 0%。")
        }
        return AccountSnapshot(
            account: account,
            connection: .connected,
            windows: windows,
            lastSuccessAt: now,
            lastAttemptAt: now,
            notes: notes
        )
    }
}
