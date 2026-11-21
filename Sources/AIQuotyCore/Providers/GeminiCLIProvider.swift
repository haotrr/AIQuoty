import Foundation

public struct GeminiCLIProvider: QuotaProvider {
    public static let descriptor = ProviderDescriptor(
        id: "gemini",
        displayName: "Gemini CLI / Code Assist",
        implementationStatus: .implemented,
        authMethods: [.localCLICredentials, .userPastedToken],
        supportedMetricKinds: [.subscriptionQuota],
        notes: "支持应用内一键 Google OAuth 登录（自动续期），或自动读取 ~/.gemini/oauth_creds.json，调用 cloudcode-pa.googleapis.com retrieveUserQuota。"
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
        if let bundle = GoogleOAuthBundle.load(from: credentials, account: CredentialAccount.geminiOAuthBundle) {
            return [AccountIdentity(id: "gemini.oauth", providerID: "gemini", displayName: "Gemini", email: bundle.email)]
        }
        if let override = try? credentials.getSecret(account: CredentialAccount.geminiOAuthOverride), !override.isEmpty {
            return [AccountIdentity(id: "gemini.keychain", providerID: "gemini", displayName: "Gemini (钥匙串)")]
        }
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
        let token: String
        var email: String?
        var accountID = "gemini.cli"
        if let oauth = try await GoogleOAuthFlow.validAccessToken(
            http: http,
            app: .gemini,
            credentials: credentials,
            now: now
        ) {
            token = oauth.accessToken
            email = oauth.email
            accountID = "gemini.oauth"
        } else if let override = try credentials.getSecret(account: CredentialAccount.geminiOAuthOverride), !override.isEmpty {
            token = override
            accountID = "gemini.keychain"
        } else if fileSystem.fileExists(at: credsPath) {
            let rawData = try fileSystem.readData(at: credsPath)
            let creds = try GeminiOAuthParser.parse(json: rawData)
            email = creds.email
            if let expiry = creds.expiryDate, expiry < now {
                let resolvedGemini = GoogleOAuthAppConfig.gemini.resolved(credentials: credentials)
                if resolvedGemini.isConfigured,
                   let obj = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
                   let refreshTok = obj["refresh_token"] as? String, !refreshTok.isEmpty {
                    let refreshed = try await GoogleOAuthFlow.refreshAccessToken(
                        http: http,
                        app: resolvedGemini,
                        bundle: GoogleOAuthBundle(accessToken: creds.accessToken, refreshToken: refreshTok, expiryDate: expiry, email: creds.email),
                        now: now
                    )
                    try? refreshed.save(to: credentials, account: CredentialAccount.geminiOAuthBundle)
                    token = refreshed.accessToken
                    email = refreshed.email ?? email
                } else {
                    throw ProviderError.authRequired("Gemini access_token 已过期；请重新登录 Gemini CLI 或在设置中配置 OAuth Client 后登录。")
                }
            } else {
                token = creds.accessToken
            }
        } else {
            throw ProviderError.notConfigured("未配置 Gemini。可在设置中一键 Google 登录，或运行 gemini CLI 登录。")
        }

        let headers: [String: String] = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": Self.userAgent,
        ]

        // Step 1: Resolve cloudaicompanionProject & tier via loadCodeAssist (required by retrieveUserQuota).
        var plan: String?
        var projectID = readEnvProjectID()
        var ineligibleReason: String?
        if let loadURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist") {
            var meta: [String: Any] = [
                "ideType": "IDE_UNSPECIFIED",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
            ]
            var loadPayload: [String: Any] = [:]
            if let projectID, !projectID.isEmpty {
                meta["duetProject"] = projectID
                loadPayload["cloudaicompanionProject"] = projectID
            }
            loadPayload["metadata"] = meta
            let body = try JSONSerialization.data(withJSONObject: loadPayload)
            let loadResp = try await http.send(HTTPRequest(method: "POST", url: loadURL, headers: headers, body: body))
            if (200..<300).contains(loadResp.statusCode) {
                let info = AntigravityProvider.parseLoadCodeAssist(loadResp.body)
                plan = info.planName ?? GeminiQuotaParser.parseTier(json: loadResp.body)
                if let p = info.projectID, !p.isEmpty {
                    projectID = p
                }
                if let root = try? JSONSerialization.jsonObject(with: loadResp.body) as? [String: Any],
                   let ineligible = root["ineligibleTiers"] as? [[String: Any]] {
                    ineligibleReason = ineligible.compactMap { $0["reasonMessage"] as? String }.first(where: { !$0.isEmpty })
                }
            } else if loadResp.statusCode == 401 || loadResp.statusCode == 403 {
                let detail = AntigravityProvider.extractGoogleErrorMessage(from: loadResp.body)
                throw ProviderError.authRequired(detail.map { "HTTP \(loadResp.statusCode)：\($0)" } ?? "HTTP \(loadResp.statusCode)")
            }
        }

        let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
        var quotaPayload: [String: Any] = [:]
        if let projectID, !projectID.isEmpty {
            quotaPayload["project"] = projectID
        }
        let body = try JSONSerialization.data(withJSONObject: quotaPayload)
        let response = try await http.send(
            HTTPRequest(
                method: "POST",
                url: url,
                headers: headers,
                body: body
            )
        )
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 403 {
                let detail = AntigravityProvider.extractGoogleErrorMessage(from: response.body)
                if projectID == nil {
                    let hint = ineligibleReason ?? detail ?? "该账号未绑定 Gemini Code Assist 项目（个人 Google 账号请使用 Antigravity，或在 ~/.gemini/.env 配置 GOOGLE_CLOUD_PROJECT）。"
                    throw ProviderError.authRequired(hint)
                }
                if let detail {
                    throw ProviderError.authRequired("HTTP 403：\(detail)")
                }
            }
            throw HTTPStatusMapper.mapFailure(status: response.statusCode, body: response.bodyText, headers: response.headers)
        }
        let parsed = try GeminiQuotaParser.parseQuota(json: response.body, now: now)
        let account = AccountIdentity(
            id: accountID,
            providerID: "gemini",
            displayName: "Gemini CLI",
            email: email,
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

    private func readEnvProjectID() -> String? {
        let envPath = "~/.gemini/.env"
        guard fileSystem.fileExists(at: envPath),
              let text = try? fileSystem.readUTF8(at: envPath) else {
            return nil
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("GOOGLE_CLOUD_PROJECT=") {
                let val = trimmed.dropFirst("GOOGLE_CLOUD_PROJECT=".count)
                    .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
                if !val.isEmpty { return val }
            }
        }
        return nil
    }

    private static var userAgent: String {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x64"
        #endif
        #if os(macOS)
        let osName = "darwin"
        #else
        let osName = "linux"
        #endif
        return "GeminiCLI/0.61.0/gemini-2.5-pro (\(osName); \(arch); terminal)"
    }
}
