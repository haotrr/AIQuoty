import Foundation

public struct CursorSessionProvider: QuotaProvider {
    public static let descriptor = ProviderDescriptor(
        id: "cursor",
        displayName: "Cursor",
        implementationStatus: .implemented,
        authMethods: [.localCLICredentials, .userPastedToken],
        supportedMetricKinds: [.subscriptionQuota],
        notes: "支持自动读取 cursor-agent 钥匙串（cursor-access-token）、~/.cursor/auth.json、桌面端明文 JWT state.vscdb，以及钥匙串 Cookie/Bearer。不解密 Safe Storage，不提取浏览器会话。"
    )

    public var descriptor: ProviderDescriptor { Self.descriptor }

    private let credentials: CredentialStore
    private let http: HTTPClient
    private let fileSystem: FileSystemReading
    private let cursorStateReader: CursorStateReading
    private let externalKeychain: ExternalKeychainReading
    private let clock: @Sendable () -> Date
    private let agentAuthPath: String
    private let demoFixture: Data?

    public init(
        credentials: CredentialStore,
        http: HTTPClient,
        fileSystem: FileSystemReading,
        cursorStateReader: CursorStateReading = SQLiteCursorStateReader(),
        externalKeychain: ExternalKeychainReading = DefaultExternalKeychain.make(),
        clock: @escaping @Sendable () -> Date = { Date() },
        agentAuthPath: String = "~/.config/cursor/auth.json",
        demoFixture: Data? = nil
    ) {
        self.credentials = credentials
        self.http = http
        self.fileSystem = fileSystem
        self.cursorStateReader = cursorStateReader
        self.externalKeychain = externalKeychain
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
        if readCursorAgentKeychainToken() != nil {
            return [AccountIdentity(id: "cursor.agent.keychain", providerID: "cursor", displayName: "Cursor Agent")]
        }
        if fileSystem.fileExists(at: agentAuthPath) || fileSystem.fileExists(at: "~/.cursor/auth.json") {
            return [AccountIdentity(id: "cursor.agent", providerID: "cursor", displayName: "Cursor Agent")]
        }
        if let local = cursorStateReader.readLocalState() {
            return [
                AccountIdentity(
                    id: "cursor.desktop",
                    providerID: "cursor",
                    displayName: "Cursor",
                    email: local.email,
                    planLabel: local.membershipType
                ),
            ]
        }
        return []
    }

    public func fetch(request: ProviderFetchRequest) async throws -> [AccountSnapshot] {
        let now = request.now
        if request.demoMode, let demoFixture {
            return try [snapshot(from: demoFixture, accountID: "cursor.demo", fallbackEmail: nil, fallbackPlan: nil, now: now)]
        }

        var headers: [String: String] = [
            "Accept": "application/json",
            "User-Agent": "AIQuoty/0.1",
            "Origin": "https://cursor.com",
        ]
        var accountID = "cursor.keychain"
        var fallbackEmail: String?
        var fallbackPlan: String?
        var workosUserID: String?

        if let cookie = try credentials.getSecret(account: CredentialAccount.cursorSessionCookie), !cookie.isEmpty {
            headers["Cookie"] = cookie.hasPrefix("Cookie:") ? String(cookie.dropFirst(7)).trimmingCharacters(in: .whitespaces) : cookie
            accountID = "cursor.keychain"
        } else if let bearer = try credentials.getSecret(account: CredentialAccount.cursorBearer), !bearer.isEmpty {
            headers["Authorization"] = bearer.hasPrefix("Bearer ") ? bearer : "Bearer \(bearer)"
            accountID = "cursor.bearer"
        } else if let agentToken = readCursorAgentKeychainToken() {
            if let uid = CursorLocalState.extractUserID(fromJWT: agentToken) {
                workosUserID = uid
                headers["Cookie"] = "WorkosCursorSessionToken=\(uid)%3A%3A\(agentToken)"
            } else {
                headers["Authorization"] = "Bearer \(agentToken)"
            }
            accountID = "cursor.agent.keychain"
        } else if fileSystem.fileExists(at: agentAuthPath) || fileSystem.fileExists(at: "~/.cursor/auth.json") {
            let path = fileSystem.fileExists(at: agentAuthPath) ? agentAuthPath : "~/.cursor/auth.json"
            let data = try fileSystem.readData(at: path)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let token = obj?["accessToken"] as? String ?? obj?["access_token"] as? String, !token.isEmpty else {
                throw ProviderError.authRequired("cursor auth.json 缺少 accessToken")
            }
            if let uid = CursorLocalState.extractUserID(fromJWT: token) {
                workosUserID = uid
                headers["Cookie"] = "WorkosCursorSessionToken=\(uid)%3A%3A\(token)"
            } else {
                headers["Authorization"] = "Bearer \(token)"
            }
            accountID = "cursor.agent"
        } else if let local = cursorStateReader.readLocalState() {
            fallbackEmail = local.email
            fallbackPlan = local.membershipType
            workosUserID = local.workosUserID
            if let cookieHeader = local.sessionCookieHeader {
                headers["Cookie"] = cookieHeader
            } else {
                headers["Authorization"] = "Bearer \(local.accessToken)"
            }
            accountID = "cursor.desktop"
        } else {
            throw ProviderError.notConfigured(
                "未配置 Cursor。请运行 cursor-agent login，或在设置中粘贴 cursor.com 的 Cookie（WorkosCursorSessionToken）。"
            )
        }

        let url = URL(string: "https://cursor.com/api/usage-summary")!
        let response = try await http.send(HTTPRequest(url: url, headers: headers))
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPStatusMapper.mapFailure(status: response.statusCode, body: response.bodyText, headers: response.headers)
        }
        var snap = try snapshot(
            from: response.body,
            accountID: accountID,
            fallbackEmail: fallbackEmail,
            fallbackPlan: fallbackPlan,
            now: now
        )
        if snap.windows.isEmpty, let uid = workosUserID,
           let legacyURL = URL(string: "https://cursor.com/api/usage?user=\(uid)") {
            if let legacyResp = try? await http.send(HTTPRequest(url: legacyURL, headers: headers)),
               (200..<300).contains(legacyResp.statusCode),
               let legacyWindows = try? CursorUsageParser.parseLegacyUsage(json: legacyResp.body, now: now),
               !legacyWindows.isEmpty {
                let parsed = CursorUsageParser.Parsed(
                    email: snap.account.email,
                    planName: snap.account.planLabel,
                    windows: legacyWindows,
                    billingCycleEnd: nil
                )
                snap.windows = CursorUsageParser.quotaWindows(from: parsed, accountID: accountID, capturedAt: now)
                snap.notes = []
            }
        }
        return [snap]
    }

    private func readCursorAgentKeychainToken() -> String? {
        guard let data = externalKeychain.readGenericPassword(service: "cursor-access-token", account: "cursor-user"),
              let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private func snapshot(
        from data: Data,
        accountID: String,
        fallbackEmail: String?,
        fallbackPlan: String?,
        now: Date
    ) throws -> AccountSnapshot {
        let parsed = try CursorUsageParser.parseSummary(json: data, now: now)
        let account = AccountIdentity(
            id: accountID,
            providerID: "cursor",
            displayName: "Cursor",
            email: parsed.email ?? fallbackEmail,
            planLabel: parsed.planName ?? fallbackPlan
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
