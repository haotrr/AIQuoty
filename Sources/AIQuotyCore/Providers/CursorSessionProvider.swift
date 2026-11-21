import Foundation

public struct CursorSessionProvider: QuotaProvider {
    public static let descriptor = ProviderDescriptor(
        id: "cursor",
        displayName: "Cursor",
        implementationStatus: .implemented,
        authMethods: [.userPastedToken, .localCLICredentials],
        supportedMetricKinds: [.subscriptionQuota],
        notes: "优先使用用户粘贴到钥匙串的 Cookie/Bearer；否则只读 cursor-agent 的 auth.json。不解密 Cursor.app Safe Storage，不提取浏览器会话。"
    )

    public var descriptor: ProviderDescriptor { Self.descriptor }

    private let credentials: CredentialStore
    private let http: HTTPClient
    private let fileSystem: FileSystemReading
    private let clock: @Sendable () -> Date
    private let agentAuthPath: String
    private let demoFixture: Data?

    public init(
        credentials: CredentialStore,
        http: HTTPClient,
        fileSystem: FileSystemReading,
        clock: @escaping @Sendable () -> Date = { Date() },
        agentAuthPath: String = "~/.config/cursor/auth.json",
        demoFixture: Data? = nil
    ) {
        self.credentials = credentials
        self.http = http
        self.fileSystem = fileSystem
        self.clock = clock
        self.agentAuthPath = agentAuthPath
        self.demoFixture = demoFixture
    }

    public func configuredAccounts() async -> [AccountIdentity] {
        if let cookie = try? credentials.getSecret(account: CredentialAccount.cursorSessionCookie), !cookie.isEmpty {
            return [AccountIdentity(id: "cursor.keychain", providerID: "cursor", displayName: "Cursor (钥匙串)")]
        }
        if let bearer = try? credentials.getSecret(account: CredentialAccount.cursorBearer), !bearer.isEmpty {
            return [AccountIdentity(id: "cursor.bearer", providerID: "cursor", displayName: "Cursor (Bearer)")]
        }
        if fileSystem.fileExists(at: agentAuthPath) {
            return [AccountIdentity(id: "cursor.agent", providerID: "cursor", displayName: "Cursor Agent")]
        }
        // Also check common alternate path
        if fileSystem.fileExists(at: "~/.cursor/auth.json") {
            return [AccountIdentity(id: "cursor.agent", providerID: "cursor", displayName: "Cursor Agent")]
        }
        return []
    }

    public func fetch(request: ProviderFetchRequest) async throws -> [AccountSnapshot] {
        let now = request.now
        if request.demoMode, let demoFixture {
            return try [snapshot(from: demoFixture, accountID: "cursor.demo", now: now)]
        }

        var headers: [String: String] = [
            "Accept": "application/json",
            "User-Agent": "AIQuoty/0.1",
            "Origin": "https://cursor.com",
        ]
        var accountID = "cursor.keychain"

        if let cookie = try credentials.getSecret(account: CredentialAccount.cursorSessionCookie), !cookie.isEmpty {
            headers["Cookie"] = cookie.hasPrefix("Cookie:") ? String(cookie.dropFirst(7)).trimmingCharacters(in: .whitespaces) : cookie
            accountID = "cursor.keychain"
        } else if let bearer = try credentials.getSecret(account: CredentialAccount.cursorBearer), !bearer.isEmpty {
            headers["Authorization"] = bearer.hasPrefix("Bearer ") ? bearer : "Bearer \(bearer)"
            accountID = "cursor.bearer"
        } else {
            let path = fileSystem.fileExists(at: agentAuthPath) ? agentAuthPath : "~/.cursor/auth.json"
            guard fileSystem.fileExists(at: path) else {
                throw ProviderError.notConfigured(
                    "未配置 Cursor。请在设置中粘贴 cursor.com 的 Cookie（WorkosCursorSessionToken），或先运行 cursor-agent login。"
                )
            }
            let data = try fileSystem.readData(at: path)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let token = obj?["accessToken"] as? String ?? obj?["access_token"] as? String, !token.isEmpty else {
                throw ProviderError.authRequired("cursor auth.json 缺少 accessToken")
            }
            headers["Authorization"] = "Bearer \(token)"
            accountID = "cursor.agent"
        }

        let url = URL(string: "https://cursor.com/api/usage-summary")!
        let response = try await http.send(HTTPRequest(url: url, headers: headers))
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPStatusMapper.mapFailure(status: response.statusCode, body: response.bodyText, headers: response.headers)
        }
        return try [snapshot(from: response.body, accountID: accountID, now: now)]
    }

    private func snapshot(from data: Data, accountID: String, now: Date) throws -> AccountSnapshot {
        let parsed = try CursorUsageParser.parseSummary(json: data, now: now)
        let account = AccountIdentity(
            id: accountID,
            providerID: "cursor",
            displayName: "Cursor",
            email: parsed.email,
            planLabel: parsed.planName
        )
        let windows = CursorUsageParser.quotaWindows(from: parsed, accountID: accountID, capturedAt: now)
        var notes: [String] = []
        if windows.isEmpty {
            notes.append("usage-summary 未返回可识别配额桶；保持未知。")
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
