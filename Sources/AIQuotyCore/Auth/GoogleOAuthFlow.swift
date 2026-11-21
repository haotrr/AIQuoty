import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct GoogleOAuthAppConfig: Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var clientID: String
    public var clientSecret: String
    public var scopes: [String]
    public var callbackPath: String
    public var loopbackHost: String
    public var keychainAccount: String
    public var clientIDAccount: String
    public var clientSecretAccount: String
    public var envClientIDKey: String
    public var envClientSecretKey: String
    public var infoPlistClientIDKey: String
    public var infoPlistClientSecretKey: String
    public var riskNotice: String?

    public init(
        id: String,
        displayName: String,
        clientID: String = "",
        clientSecret: String = "",
        scopes: [String],
        callbackPath: String,
        loopbackHost: String,
        keychainAccount: String,
        clientIDAccount: String,
        clientSecretAccount: String,
        envClientIDKey: String,
        envClientSecretKey: String,
        infoPlistClientIDKey: String = "",
        infoPlistClientSecretKey: String = "",
        riskNotice: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
        self.callbackPath = callbackPath
        self.loopbackHost = loopbackHost
        self.keychainAccount = keychainAccount
        self.clientIDAccount = clientIDAccount
        self.clientSecretAccount = clientSecretAccount
        self.envClientIDKey = envClientIDKey
        self.envClientSecretKey = envClientSecretKey
        self.infoPlistClientIDKey = infoPlistClientIDKey
        self.infoPlistClientSecretKey = infoPlistClientSecretKey
        self.riskNotice = riskNotice
    }

    public var isConfigured: Bool {
        !clientID.isEmpty
    }

    /// Default local config file paths checked for user-supplied OAuth client config.
    public static let defaultConfigPaths: [String] = [
        "~/.aiquoty/oauth.json",
        "~/.aiquoty/config.json",
    ]

    /// Resolves OAuth Client ID and Client Secret in order:
    /// 1. Keychain  2. Runtime environment  3. `~/.aiquoty/oauth.json`  4. App bundle `Info.plist` (build-time injected).
    /// No OAuth client credentials are hardcoded in source control.
    public func resolved(
        credentials: CredentialStore,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileSystem: FileSystemReading = LocalFileSystem(),
        configPaths: [String] = GoogleOAuthAppConfig.defaultConfigPaths,
        bundleInfo: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> GoogleOAuthAppConfig {
        var copy = self
        let fileEntry = (copy.clientID.isEmpty || copy.clientSecret.isEmpty)
            ? Self.loadFromConfigFiles(providerID: id, fileSystem: fileSystem, paths: configPaths)
            : nil
        if copy.clientID.isEmpty {
            if let savedID = try? credentials.getSecret(account: clientIDAccount), !savedID.isEmpty {
                copy.clientID = savedID
            } else if let envID = environment[envClientIDKey], !envID.isEmpty {
                copy.clientID = envID
            } else if let fileID = fileEntry?.clientID, !fileID.isEmpty {
                copy.clientID = fileID
            } else if !infoPlistClientIDKey.isEmpty,
                      let plistID = bundleInfo[infoPlistClientIDKey] as? String,
                      !plistID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                copy.clientID = plistID.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if copy.clientSecret.isEmpty {
            if let savedSecret = try? credentials.getSecret(account: clientSecretAccount), !savedSecret.isEmpty {
                copy.clientSecret = savedSecret
            } else if let envSecret = environment[envClientSecretKey], !envSecret.isEmpty {
                copy.clientSecret = envSecret
            } else if let fileSecret = fileEntry?.clientSecret, !fileSecret.isEmpty {
                copy.clientSecret = fileSecret
            } else if !infoPlistClientSecretKey.isEmpty,
                      let plistSecret = bundleInfo[infoPlistClientSecretKey] as? String,
                      !plistSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                copy.clientSecret = plistSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return copy
    }

    private struct FileOAuthEntry {
        var clientID: String?
        var clientSecret: String?
    }

    /// Parses `~/.aiquoty/oauth.json` (or `config.json`) supporting:
    /// `{ "antigravity": { "client_id": "...", "client_secret": "..." } }`
    /// or `{ "oauth": { "antigravity": { ... } } }` (both snake_case and camelCase).
    private static func loadFromConfigFiles(
        providerID: String,
        fileSystem: FileSystemReading,
        paths: [String]
    ) -> FileOAuthEntry? {
        for path in paths {
            guard fileSystem.fileExists(at: path),
                  let data = try? fileSystem.readData(at: path),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let section = (root[providerID] as? [String: Any])
                ?? ((root["oauth"] as? [String: Any])?[providerID] as? [String: Any])
            guard let section else { continue }
            let cid = firstNonEmpty(section, keys: ["client_id", "clientId", "clientID"])
            let csec = firstNonEmpty(section, keys: ["client_secret", "clientSecret"])
            if cid != nil || csec != nil {
                return FileOAuthEntry(clientID: cid, clientSecret: csec)
            }
        }
        return nil
    }

    private static func firstNonEmpty(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    public static let gemini = GoogleOAuthAppConfig(
        id: "gemini",
        displayName: "Gemini CLI / Code Assist",
        scopes: [
            "https://www.googleapis.com/auth/cloud-platform",
            "https://www.googleapis.com/auth/userinfo.email",
            "https://www.googleapis.com/auth/userinfo.profile",
        ],
        callbackPath: "/oauth2callback",
        loopbackHost: "127.0.0.1",
        keychainAccount: CredentialAccount.geminiOAuthBundle,
        clientIDAccount: CredentialAccount.geminiOAuthClientID,
        clientSecretAccount: CredentialAccount.geminiOAuthClientSecret,
        envClientIDKey: "AIQUOTY_GEMINI_OAUTH_CLIENT_ID",
        envClientSecretKey: "AIQUOTY_GEMINI_OAUTH_CLIENT_SECRET",
        infoPlistClientIDKey: "AIQuotyGeminiOAuthClientID",
        infoPlistClientSecretKey: "AIQuotyGeminiOAuthClientSecret",
        riskNotice: nil
    )

    public static let antigravity = GoogleOAuthAppConfig(
        id: "antigravity",
        displayName: "Antigravity",
        scopes: [
            "https://www.googleapis.com/auth/cloud-platform",
            "https://www.googleapis.com/auth/userinfo.email",
            "https://www.googleapis.com/auth/userinfo.profile",
            "https://www.googleapis.com/auth/cclog",
            "https://www.googleapis.com/auth/experimentsandconfigs",
        ],
        callbackPath: "/oauth-callback",
        loopbackHost: "localhost",
        keychainAccount: CredentialAccount.antigravityOAuthBundle,
        clientIDAccount: CredentialAccount.antigravityOAuthClientID,
        clientSecretAccount: CredentialAccount.antigravityOAuthClientSecret,
        envClientIDKey: "AIQUOTY_ANTIGRAVITY_OAUTH_CLIENT_ID",
        envClientSecretKey: "AIQUOTY_ANTIGRAVITY_OAUTH_CLIENT_SECRET",
        infoPlistClientIDKey: "AIQuotyAntigravityOAuthClientID",
        infoPlistClientSecretKey: "AIQuotyAntigravityOAuthClientSecret",
        riskNotice: "提示：请先在下方填写 OAuth Client ID / Secret（仅存本机钥匙串，不写入源码）后再使用一键浏览器登录。"
    )
}

public struct GoogleOAuthBundle: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiryDate: Date?
    public var email: String?
    public var clientID: String?

    public init(
        accessToken: String,
        refreshToken: String,
        expiryDate: Date? = nil,
        email: String? = nil,
        clientID: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiryDate = expiryDate
        self.email = email
        self.clientID = clientID
    }

    public func isValid(at now: Date, leeway: TimeInterval = 120) -> Bool {
        guard !accessToken.isEmpty else { return false }
        guard let expiryDate else { return true }
        return expiryDate.timeIntervalSince(now) > leeway
    }

    public static func load(from credentials: CredentialStore, account: String) -> GoogleOAuthBundle? {
        guard let raw = try? credentials.getSecret(account: account),
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let bundle = try? JSONDecoder().decode(GoogleOAuthBundle.self, from: data) else {
            return nil
        }
        return bundle
    }

    public func save(to credentials: CredentialStore, account: String) throws {
        let data = try JSONEncoder().encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ProviderError.decode("无法编码 Google OAuth 凭证")
        }
        try credentials.setSecret(json, account: account)
    }
}

public enum GoogleOAuthFlow {
    public struct PKCEPair: Sendable, Equatable {
        public var verifier: String
        public var challenge: String
        public var method: String
    }

    public static func generatePKCE() -> PKCEPair {
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let verifier = base64URL(Data(bytes))
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URL(Data(digest))
        return PKCEPair(verifier: verifier, challenge: challenge, method: "S256")
        #else
        return PKCEPair(verifier: verifier, challenge: verifier, method: "plain")
        #endif
    }

    public static func generateState() -> String {
        let bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        return base64URL(Data(bytes))
    }

    public static func authorizationURL(
        app: GoogleOAuthAppConfig,
        redirectURI: String,
        state: String,
        pkce: PKCEPair
    ) -> URL {
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: app.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: app.scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
        ]
        return comps.url!
    }

    public static func exchangeCode(
        http: HTTPClient,
        app: GoogleOAuthAppConfig,
        code: String,
        redirectURI: String,
        codeVerifier: String,
        now: Date = Date()
    ) async throws -> GoogleOAuthBundle {
        guard app.isConfigured else {
            throw ProviderError.notConfigured("尚未配置 \(app.displayName) OAuth Client ID，请在设置 → 连接中填写。")
        }
        var form: [(String, String)] = [
            ("client_id", app.clientID),
            ("code", code),
            ("code_verifier", codeVerifier),
            ("grant_type", "authorization_code"),
            ("redirect_uri", redirectURI),
        ]
        if !app.clientSecret.isEmpty {
            form.append(("client_secret", app.clientSecret))
        }
        let response = try await http.send(
            HTTPRequest(
                method: "POST",
                url: URL(string: "https://oauth2.googleapis.com/token")!,
                headers: [
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Accept": "application/json",
                ],
                body: formEncode(form)
            )
        )
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPStatusMapper.mapFailure(status: response.statusCode, body: response.bodyText, headers: response.headers)
        }
        guard let obj = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let accessToken = obj["access_token"] as? String, !accessToken.isEmpty else {
            throw ProviderError.decode("Google OAuth 未返回 access_token")
        }
        let refreshToken = (obj["refresh_token"] as? String) ?? ""
        let expiresIn = number(obj["expires_in"])
        let expiry = expiresIn.map { now.addingTimeInterval($0) }
        let email = await fetchEmail(http: http, accessToken: accessToken)
        return GoogleOAuthBundle(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiryDate: expiry,
            email: email,
            clientID: app.clientID
        )
    }

    public static func refreshAccessToken(
        http: HTTPClient,
        app: GoogleOAuthAppConfig,
        bundle: GoogleOAuthBundle,
        now: Date = Date()
    ) async throws -> GoogleOAuthBundle {
        guard !bundle.refreshToken.isEmpty else {
            throw ProviderError.authRequired("\(app.displayName) 缺少 refresh_token，请重新登录。")
        }
        let effectiveClientID = app.clientID.isEmpty ? (bundle.clientID ?? "") : app.clientID
        guard !effectiveClientID.isEmpty else {
            throw ProviderError.authRequired("\(app.displayName) 令牌已过期，请在设置中配置 OAuth Client ID/Secret 后刷新或重新登录。")
        }
        var form: [(String, String)] = [
            ("client_id", effectiveClientID),
            ("refresh_token", bundle.refreshToken),
            ("grant_type", "refresh_token"),
        ]
        if !app.clientSecret.isEmpty {
            form.append(("client_secret", app.clientSecret))
        }
        let response = try await http.send(
            HTTPRequest(
                method: "POST",
                url: URL(string: "https://oauth2.googleapis.com/token")!,
                headers: [
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Accept": "application/json",
                ],
                body: formEncode(form)
            )
        )
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPStatusMapper.mapFailure(status: response.statusCode, body: response.bodyText, headers: response.headers)
        }
        guard let obj = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let accessToken = obj["access_token"] as? String, !accessToken.isEmpty else {
            throw ProviderError.decode("Google OAuth 刷新未返回 access_token")
        }
        let expiresIn = number(obj["expires_in"])
        let expiry = expiresIn.map { now.addingTimeInterval($0) }
        var updated = bundle
        updated.accessToken = accessToken
        updated.expiryDate = expiry
        if let newRefresh = obj["refresh_token"] as? String, !newRefresh.isEmpty {
            updated.refreshToken = newRefresh
        }
        if updated.email == nil {
            updated.email = await fetchEmail(http: http, accessToken: accessToken)
        }
        return updated
    }

    public static func validAccessToken(
        http: HTTPClient,
        app: GoogleOAuthAppConfig,
        credentials: CredentialStore,
        now: Date = Date()
    ) async throws -> (accessToken: String, email: String?)? {
        guard let bundle = GoogleOAuthBundle.load(from: credentials, account: app.keychainAccount) else {
            return nil
        }
        if bundle.isValid(at: now) {
            return (bundle.accessToken, bundle.email)
        }
        let resolvedApp = app.resolved(credentials: credentials)
        let refreshed = try await refreshAccessToken(http: http, app: resolvedApp, bundle: bundle, now: now)
        try? refreshed.save(to: credentials, account: app.keychainAccount)
        return (refreshed.accessToken, refreshed.email)
    }

    private static func fetchEmail(http: HTTPClient, accessToken: String) async -> String? {
        guard let url = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo") else { return nil }
        guard let resp = try? await http.send(
            HTTPRequest(url: url, headers: ["Authorization": "Bearer \(accessToken)", "Accept": "application/json"])
        ), (200..<300).contains(resp.statusCode),
        let obj = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            return nil
        }
        return obj["email"] as? String
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ items: [(String, String)]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=/?:")
        let encoded = items.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func number(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let s = raw as? String { return Double(s) }
        return nil
    }
}
