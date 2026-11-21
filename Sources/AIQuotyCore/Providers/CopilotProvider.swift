import Foundation

public enum DefaultGHTokenProvider {
    public static func read() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let ghPath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghPath)
        process.arguments = ["auth", "token"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (token?.isEmpty == false) ? token : nil
        } catch {
            return nil
        }
    }
}

public struct CopilotProvider: QuotaProvider {
    public static let descriptor = ProviderDescriptor(
        id: "copilot",
        displayName: "GitHub Copilot",
        implementationStatus: .implemented,
        authMethods: [.githubDeviceFlow, .localCLICredentials, .apiKeyInKeychain],
        supportedMetricKinds: [.subscriptionQuota],
        notes: "支持应用内一键 GitHub Device Flow 登录，自动兼容独立 Copilot CLI（~/.copilot/config.json 与钥匙串 copilot-cli）、~/.config/github-copilot/apps.json 及本机 gh auth token。"
    )

    public var descriptor: ProviderDescriptor { Self.descriptor }

    private let credentials: CredentialStore
    private let http: HTTPClient
    private let fileSystem: FileSystemReading
    private let externalKeychain: ExternalKeychainReading
    private let ghTokenProvider: @Sendable () -> String?
    private let clock: @Sendable () -> Date
    private let demoFixture: Data?

    public init(
        credentials: CredentialStore,
        http: HTTPClient,
        fileSystem: FileSystemReading = LocalFileSystem(),
        externalKeychain: ExternalKeychainReading = DefaultExternalKeychain.make(),
        ghTokenProvider: @escaping @Sendable () -> String? = { DefaultGHTokenProvider.read() },
        clock: @escaping @Sendable () -> Date = { Date() },
        demoFixture: Data? = nil
    ) {
        self.credentials = credentials
        self.http = http
        self.fileSystem = fileSystem
        self.externalKeychain = externalKeychain
        self.ghTokenProvider = ghTokenProvider
        self.clock = clock
        self.demoFixture = demoFixture
    }

    public func configuredAccounts() async -> [AccountIdentity] {
        if resolveToken() != nil {
            return [AccountIdentity(id: "copilot.default", providerID: "copilot", displayName: "GitHub Copilot")]
        }
        return []
    }

    public func fetch(request: ProviderFetchRequest) async throws -> [AccountSnapshot] {
        let now = request.now
        if request.demoMode, let demoFixture {
            return try [parse(demoFixture, now: now)]
        }
        guard let resolved = resolveToken(), !resolved.token.isEmpty else {
            throw ProviderError.notConfigured("未配置 GitHub Copilot。可在设置中一键登录 GitHub，或登录 Copilot CLI。")
        }
        let url = URL(string: "https://api.github.com/copilot_internal/user")!
        let response = try await http.send(
            HTTPRequest(
                url: url,
                headers: [
                    "Authorization": "token \(resolved.token)",
                    "Accept": "application/json",
                    "Editor-Version": "vscode/1.96.2",
                    "Editor-Plugin-Version": "copilot-chat/0.26.7",
                    "User-Agent": "GitHubCopilotChat/0.26.7",
                    "X-Github-Api-Version": "2025-04-01",
                ]
            )
        )
        if resolved.isImplicitGHFallback && (response.statusCode == 401 || response.statusCode == 403 || response.statusCode == 404) {
            throw ProviderError.notConfigured("本机 gh CLI 令牌未开通 Copilot 权限，请使用一键 GitHub Device Flow 登录。")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPStatusMapper.mapFailure(status: response.statusCode, body: response.bodyText, headers: response.headers)
        }
        return try [parse(response.body, now: now)]
    }

    private struct ResolvedCopilotToken {
        let token: String
        let isImplicitGHFallback: Bool
    }

    private func resolveToken() -> ResolvedCopilotToken? {
        if let token = try? credentials.getSecret(account: CredentialAccount.copilotGitHubToken), !token.isEmpty {
            return ResolvedCopilotToken(token: token, isImplicitGHFallback: false)
        }
        // Standalone Copilot CLI macOS Keychain (`copilot-cli`)
        if let kcData = externalKeychain.readGenericPassword(service: "copilot-cli"),
           let tok = String(data: kcData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tok.isEmpty {
            return ResolvedCopilotToken(token: tok, isImplicitGHFallback: false)
        }
        // Standalone Copilot CLI plaintext config (`~/.copilot/config.json`)
        let copilotConfig = "~/.copilot/config.json"
        if fileSystem.fileExists(at: copilotConfig),
           let data = try? fileSystem.readData(at: copilotConfig),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["oauth_token", "token", "github_token"] {
                if let tok = root[key] as? String, !tok.isEmpty {
                    return ResolvedCopilotToken(token: tok, isImplicitGHFallback: false)
                }
            }
        }
        // Editor Copilot configs (`~/.config/github-copilot/apps.json` / `hosts.json`)
        for path in ["~/.config/github-copilot/apps.json", "~/.config/github-copilot/hosts.json"] {
            if fileSystem.fileExists(at: path),
               let data = try? fileSystem.readData(at: path),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (_, value) in root {
                    if let dict = value as? [String: Any],
                       let token = dict["oauth_token"] as? String, !token.isEmpty {
                        return ResolvedCopilotToken(token: token, isImplicitGHFallback: false)
                    }
                }
            }
        }
        // ~/.config/gh/hosts.yml plaintext token if present
        let ghHosts = "~/.config/gh/hosts.yml"
        if fileSystem.fileExists(at: ghHosts),
           let text = try? fileSystem.readUTF8(at: ghHosts) {
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("oauth_token:") {
                    let value = trimmed.dropFirst("oauth_token:".count)
                        .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
                    if !value.isEmpty {
                        return ResolvedCopilotToken(token: value, isImplicitGHFallback: true)
                    }
                }
            }
        }
        // Official `gh auth token` CLI fallback
        if let ghTok = ghTokenProvider(), !ghTok.isEmpty {
            return ResolvedCopilotToken(token: ghTok, isImplicitGHFallback: true)
        }
        return nil
    }

    private func parse(_ data: Data, now: Date) throws -> AccountSnapshot {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decode("Copilot user 响应无效")
        }
        if (root["access_type_sku"] as? String) == "subscription_ended" {
            throw ProviderError.authRequired("Copilot 订阅已结束")
        }
        let plan = root["copilot_plan"] as? String ?? root["copilotPlan"] as? String
        let snapshots = (root["quota_snapshots"] as? [String: Any])
            ?? (root["quotaSnapshots"] as? [String: Any])
            ?? [:]
        let resetDate = CopilotUsageParser.parseReset(root["quota_reset_date"] ?? root["quotaResetDate"])
        var windows: [QuotaWindow] = []
        if let premium = snapshots["premium_interactions"] as? [String: Any]
            ?? snapshots["premiumInteractions"] as? [String: Any] {
            windows.append(contentsOf: CopilotUsageParser.window(
                id: "copilot.premium",
                title: "Premium 请求",
                dict: premium,
                reset: resetDate,
                now: now
            ))
        }
        if let chat = snapshots["chat"] as? [String: Any] {
            windows.append(contentsOf: CopilotUsageParser.window(
                id: "copilot.chat",
                title: "Chat",
                dict: chat,
                reset: resetDate,
                now: now
            ))
        }
        return AccountSnapshot(
            account: AccountIdentity(
                id: "copilot.default",
                providerID: "copilot",
                displayName: "Copilot",
                planLabel: plan
            ),
            connection: .connected,
            windows: windows,
            lastSuccessAt: now,
            lastAttemptAt: now
        )
    }
}

public enum CopilotUsageParser {
    public static let source = SourceAttribution(
        id: "copilot.internal.user",
        label: "GitHub Copilot Internal Usage",
        detail: "GET api.github.com/copilot_internal/user"
    )

    public static func window(
        id: String,
        title: String,
        dict: [String: Any],
        reset: Date?,
        now: Date
    ) -> [QuotaWindow] {
        // percent_remaining preferred
        let remainingPercent = number(dict["percent_remaining"] ?? dict["percentRemaining"])
        let remainingFraction = remainingPercent.map { min(max($0 / 100.0, 0), 1) }
        let usedFraction = remainingFraction.map { 1 - $0 }
        let usedDisplay: MetricValue
        if let usedFraction {
            usedDisplay = MetricValue(
                kind: .subscriptionQuota,
                precision: .reported,
                unit: .percentUsed,
                value: usedFraction * 100,
                display: String(format: "%.0f%%", usedFraction * 100),
                source: source,
                capturedAt: now,
                freshness: .fresh
            )
        } else {
            usedDisplay = .unknown(kind: .subscriptionQuota, unit: .percentUsed, source: source)
        }
        let remainingDisplay: MetricValue
        if let remainingFraction {
            remainingDisplay = MetricValue(
                kind: .subscriptionQuota,
                precision: .reported,
                unit: .percentRemaining,
                value: remainingFraction * 100,
                display: String(format: "%.0f%%", remainingFraction * 100),
                source: source,
                capturedAt: now,
                freshness: .fresh
            )
        } else {
            remainingDisplay = .unknown(kind: .subscriptionQuota, unit: .percentRemaining, source: source)
        }
        return [
            QuotaWindow(
                id: id,
                title: title,
                usedFraction: usedFraction,
                remainingFraction: remainingFraction,
                usedDisplay: usedDisplay,
                remainingDisplay: remainingDisplay,
                resetsAt: reset,
                resetKnown: reset != nil,
                source: source,
                capturedAt: now
            ),
        ]
    }

    public static func parseReset(_ raw: Any?) -> Date? {
        if let s = raw as? String {
            let iso = ISO8601DateFormatter()
            if let d = iso.date(from: s) { return d }
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = "yyyy-MM-dd"
            return df.date(from: s)
        }
        return nil
    }

    private static func number(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let s = raw as? String { return Double(s) }
        return nil
    }
}

public enum GitHubDeviceFlow {
    /// Public GitHub Copilot OAuth App client ID used by Copilot CLI / editors for RFC 8628 device flow.
    public static let defaultCopilotClientID = "Iv1.b507a08c87ecfe98"

    public struct DeviceCode: Equatable, Sendable {
        public var deviceCode: String
        public var userCode: String
        public var verificationURI: String
        public var interval: Int
        public var expiresIn: Int
    }

    public static func requestDeviceCode(
        http: HTTPClient,
        clientID: String = defaultCopilotClientID,
        scope: String = "read:user"
    ) async throws -> DeviceCode {
        let url = URL(string: "https://github.com/login/device/code")!
        let body = "client_id=\(clientID)&scope=\(scope)".data(using: .utf8)
        let response = try await http.send(
            HTTPRequest(
                method: "POST",
                url: url,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/x-www-form-urlencoded",
                ],
                body: body
            )
        )
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPStatusMapper.mapFailure(status: response.statusCode, body: response.bodyText)
        }
        let obj = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        guard let device = obj?["device_code"] as? String,
              let user = obj?["user_code"] as? String,
              let uri = obj?["verification_uri"] as? String else {
            throw ProviderError.decode("device code 响应不完整")
        }
        return DeviceCode(
            deviceCode: device,
            userCode: user,
            verificationURI: uri,
            interval: obj?["interval"] as? Int ?? 5,
            expiresIn: obj?["expires_in"] as? Int ?? 900
        )
    }

    public static func pollAccessToken(
        http: HTTPClient,
        clientID: String = defaultCopilotClientID,
        deviceCode: DeviceCode
    ) async throws -> String {
        let url = URL(string: "https://github.com/login/oauth/access_token")!
        let deadline = Date().addingTimeInterval(TimeInterval(max(deviceCode.expiresIn, 60)))
        var interval = max(deviceCode.interval, 5)

        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            try Task.checkCancellation()

            let body = "client_id=\(clientID)&device_code=\(deviceCode.deviceCode)&grant_type=urn:ietf:params:oauth:grant-type:device_code".data(using: .utf8)
            let response = try await http.send(
                HTTPRequest(
                    method: "POST",
                    url: url,
                    headers: [
                        "Accept": "application/json",
                        "Content-Type": "application/x-www-form-urlencoded",
                    ],
                    body: body
                )
            )
            guard (200..<300).contains(response.statusCode),
                  let obj = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
                throw HTTPStatusMapper.mapFailure(status: response.statusCode, body: response.bodyText)
            }
            if let token = obj["access_token"] as? String, !token.isEmpty {
                return token
            }
            let err = obj["error"] as? String ?? ""
            switch err {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
                continue
            case "expired_token":
                throw ProviderError.authRequired("GitHub 授权码已过期，请重新点击登录。")
            case "access_denied":
                throw ProviderError.cancelled
            default:
                let desc = (obj["error_description"] as? String) ?? err
                throw ProviderError.authRequired("GitHub 授权失败：\(desc)")
            }
        }
        throw ProviderError.authRequired("GitHub 授权超时，请重试。")
    }
}
