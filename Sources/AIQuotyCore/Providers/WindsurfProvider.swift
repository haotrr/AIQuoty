import Foundation

public struct WindsurfProvider: QuotaProvider {
    public static let descriptor = ProviderDescriptor(
        id: "windsurf",
        displayName: "Windsurf",
        implementationStatus: .partial,
        authMethods: [.apiKeyInKeychain, .localCLICredentials],
        supportedMetricKinds: [.subscriptionQuota],
        notes: "支持钥匙串中的 Windsurf / Codeium API Key 或 ~/.codeium/windsurf/auth.json 查询 Prompt / Flex Credits；不绕过 IDE 进程边界或提取浏览器会话。"
    )

    public var descriptor: ProviderDescriptor { Self.descriptor }

    private let credentials: CredentialStore
    private let http: HTTPClient
    private let fileSystem: FileSystemReading
    private let clock: @Sendable () -> Date
    private let demoFixture: Data?

    public init(
        credentials: CredentialStore,
        http: HTTPClient,
        fileSystem: FileSystemReading,
        clock: @escaping @Sendable () -> Date = { Date() },
        demoFixture: Data? = nil
    ) {
        self.credentials = credentials
        self.http = http
        self.fileSystem = fileSystem
        self.clock = clock
        self.demoFixture = demoFixture
    }

    public func configuredAccounts() async -> [AccountIdentity] {
        if resolveKey() != nil {
            return [AccountIdentity(id: "windsurf.default", providerID: "windsurf", displayName: "Windsurf")]
        }
        return []
    }

    public func fetch(request: ProviderFetchRequest) async throws -> [AccountSnapshot] {
        let now = request.now
        if request.demoMode, let demoFixture {
            return try [WindsurfStatusParser.parse(json: demoFixture, accountID: "windsurf.demo", now: now)]
        }
        guard let apiKey = resolveKey(), !apiKey.isEmpty else {
            throw ProviderError.notConfigured("未配置 Windsurf API Key。")
        }

        let url = URL(string: "https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetPlanStatus")!
        let body = try JSONSerialization.data(withJSONObject: [
            "auth_token": apiKey,
        ])
        let resp = try await http.send(
            HTTPRequest(
                method: "POST",
                url: url,
                headers: [
                    "Content-Type": "application/json",
                    "Accept": "application/json",
                    "User-Agent": "AIQuoty/0.1",
                ],
                body: body
            )
        )
        guard (200..<300).contains(resp.statusCode) else {
            throw HTTPStatusMapper.mapFailure(status: resp.statusCode, body: resp.bodyText, headers: resp.headers)
        }
        return try [WindsurfStatusParser.parse(json: resp.body, accountID: "windsurf.default", now: now)]
    }

    private func resolveKey() -> String? {
        if let key = try? credentials.getSecret(account: CredentialAccount.windsurfAPIKey), !key.isEmpty {
            return key
        }
        for path in ["~/.codeium/windsurf/auth.json", "~/.windsurf/auth.json"] {
            if fileSystem.fileExists(at: path),
               let data = try? fileSystem.readData(at: path),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let key = (obj["apiKey"] as? String) ?? (obj["api_key"] as? String) ?? (obj["token"] as? String), !key.isEmpty {
                    return key
                }
            }
        }
        return nil
    }
}

public enum WindsurfStatusParser {
    public static let source = SourceAttribution(
        id: "windsurf.plan_status",
        label: "Windsurf Plan Status",
        detail: "POST server.codeium.com/.../GetPlanStatus"
    )

    public static func parse(json: Data, accountID: String, now: Date = Date()) throws -> AccountSnapshot {
        let obj = try JSONSerialization.jsonObject(with: json)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decode("Windsurf 响应不是 JSON 对象")
        }
        let status = (root["planStatus"] as? [String: Any]) ?? root
        let planInfo = (status["planInfo"] as? [String: Any]) ?? [:]
        let plan = (planInfo["planName"] as? String) ?? (status["planName"] as? String)
        let reset = parseDate(status["planEnd"] ?? status["billingCycleEnd"])

        var windows: [QuotaWindow] = []
        if let used = number(status["usedPromptCredits"]),
           let avail = number(status["availablePromptCredits"]), avail > 0 {
            windows.append(makeWindow(id: "\(accountID).prompt", title: "Prompt Credits", used: used, total: avail, reset: reset, now: now))
        }
        if let used = number(status["usedFlexCredits"]),
           let avail = number(status["availableFlexCredits"]), avail > 0 {
            windows.append(makeWindow(id: "\(accountID).flex", title: "Flex Credits", used: used, total: avail, reset: reset, now: now))
        }

        return AccountSnapshot(
            account: AccountIdentity(id: accountID, providerID: "windsurf", displayName: "Windsurf", planLabel: plan),
            connection: .connected,
            windows: windows,
            lastSuccessAt: now,
            lastAttemptAt: now
        )
    }

    private static func makeWindow(id: String, title: String, used: Double, total: Double, reset: Date?, now: Date) -> QuotaWindow {
        let frac = min(max(used / total, 0), 1)
        let rem = ResetMath.remainingFromUsed(frac)
        return QuotaWindow(
            id: id,
            title: title,
            usedFraction: frac,
            remainingFraction: rem,
            usedDisplay: MetricValue(
                kind: .subscriptionQuota, precision: .reported, unit: .percentUsed,
                value: frac * 100, display: String(format: "%.0f%%", frac * 100),
                source: source, capturedAt: now, freshness: .fresh
            ),
            remainingDisplay: rem.map {
                MetricValue(
                    kind: .subscriptionQuota, precision: .reported, unit: .percentRemaining,
                    value: $0 * 100, display: String(format: "%.0f%%", $0 * 100),
                    source: source, capturedAt: now, freshness: .fresh
                )
            } ?? .unknown(kind: .subscriptionQuota, unit: .percentRemaining, source: source),
            resetsAt: reset,
            resetKnown: reset != nil,
            source: source,
            capturedAt: now
        )
    }

    private static func number(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
