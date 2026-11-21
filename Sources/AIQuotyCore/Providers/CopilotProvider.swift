import Foundation

public struct CopilotProvider: QuotaProvider {
    public static let descriptor = ProviderDescriptor(
        id: "copilot",
        displayName: "GitHub Copilot",
        implementationStatus: .implemented,
        authMethods: [.apiKeyInKeychain, .githubDeviceFlow],
        supportedMetricKinds: [.subscriptionQuota],
        notes: "使用用户保存到钥匙串的 GitHub token（read:user）调用 api.github.com/copilot_internal/user。应用内提供 device flow 说明，不自动打开浏览器完成授权以外的操作。"
    )

    public var descriptor: ProviderDescriptor { Self.descriptor }

    private let credentials: CredentialStore
    private let http: HTTPClient
    private let clock: @Sendable () -> Date
    private let demoFixture: Data?

    public init(
        credentials: CredentialStore,
        http: HTTPClient,
        clock: @escaping @Sendable () -> Date = { Date() },
        demoFixture: Data? = nil
    ) {
        self.credentials = credentials
        self.http = http
        self.clock = clock
        self.demoFixture = demoFixture
    }

    public func configuredAccounts() async -> [AccountIdentity] {
        if let token = try? credentials.getSecret(account: CredentialAccount.copilotGitHubToken), !token.isEmpty {
            return [AccountIdentity(id: "copilot.default", providerID: "copilot", displayName: "Copilot")]
        }
        return []
    }

    public func fetch(request: ProviderFetchRequest) async throws -> [AccountSnapshot] {
        let now = request.now
        if request.demoMode, let demoFixture {
            return try [parse(demoFixture, now: now)]
        }
        guard let token = try credentials.getSecret(account: CredentialAccount.copilotGitHubToken), !token.isEmpty else {
            throw ProviderError.notConfigured("未配置 GitHub token。请在设置中粘贴具有 read:user 权限的 token，或按文档完成 device flow 后保存。")
        }
        let url = URL(string: "https://api.github.com/copilot_internal/user")!
        let response = try await http.send(
            HTTPRequest(
                url: url,
                headers: [
                    "Authorization": "token \(token)",
                    "Accept": "application/json",
                    "Editor-Version": "vscode/1.96.2",
                    "Editor-Plugin-Version": "copilot-chat/0.26.7",
                    "User-Agent": "GitHubCopilotChat/0.26.7",
                    "X-Github-Api-Version": "2025-04-01",
                ]
            )
        )
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPStatusMapper.mapFailure(status: response.statusCode, body: response.bodyText, headers: response.headers)
        }
        return try [parse(response.body, now: now)]
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
    public struct DeviceCode: Equatable {
        public var deviceCode: String
        public var userCode: String
        public var verificationURI: String
        public var interval: Int
        public var expiresIn: Int
    }

    /// Starts device flow. Client ID must be a registered OAuth App owned by the user/org.
    /// AIQuoty ships without embedding a public client secret; users can set AIquoty GitHub OAuth client id in settings later.
    public static func requestDeviceCode(
        http: HTTPClient,
        clientID: String,
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
}
