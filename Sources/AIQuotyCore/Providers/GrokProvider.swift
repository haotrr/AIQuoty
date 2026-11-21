import Foundation

public struct GrokProvider: QuotaProvider {
    public static let descriptor = ProviderDescriptor(
        id: "grok",
        displayName: "Grok / xAI",
        implementationStatus: .partial,
        authMethods: [.apiKeyInKeychain, .localCLICredentials],
        supportedMetricKinds: [.apiSpend],
        notes: "支持钥匙串中的 xAI API Key 或 ~/.grok/auth.json，调用官方 api.x.ai/v1/api-key 校验状态；若接口未返回余额则保持未知，不自动提取浏览器会话。"
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
        if resolveAPIKey() != nil {
            return [AccountIdentity(id: "grok.default", providerID: "grok", displayName: "Grok / xAI")]
        }
        return []
    }

    public func fetch(request: ProviderFetchRequest) async throws -> [AccountSnapshot] {
        let now = request.now
        if request.demoMode, let demoFixture {
            return try [parseKeyInfo(demoFixture, accountID: "grok.demo", now: now)]
        }
        guard let key = resolveAPIKey(), !key.isEmpty else {
            throw ProviderError.notConfigured("未配置 xAI API Key 或 ~/.grok/auth.json。")
        }

        let url = URL(string: "https://api.x.ai/v1/api-key")!
        let resp = try await http.send(
            HTTPRequest(
                url: url,
                headers: [
                    "Authorization": "Bearer \(key)",
                    "Accept": "application/json",
                    "User-Agent": "AIQuoty/0.1",
                ]
            )
        )
        guard (200..<300).contains(resp.statusCode) else {
            throw HTTPStatusMapper.mapFailure(status: resp.statusCode, body: resp.bodyText, headers: resp.headers)
        }
        return try [parseKeyInfo(resp.body, accountID: "grok.default", now: now)]
    }

    private func resolveAPIKey() -> String? {
        if let key = try? credentials.getSecret(account: CredentialAccount.grokAPIKey), !key.isEmpty {
            return key
        }
        for path in ["~/.grok/auth.json", "~/.config/grok/auth.json"] {
            if fileSystem.fileExists(at: path),
               let data = try? fileSystem.readData(at: path),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let key = (obj["apiKey"] as? String) ?? (obj["api_key"] as? String) ?? (obj["xai_api_key"] as? String), !key.isEmpty {
                    return key
                }
            }
        }
        return nil
    }

    private func parseKeyInfo(_ data: Data, accountID: String, now: Date) throws -> AccountSnapshot {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decode("xAI api-key 响应不是 JSON 对象")
        }
        let name = (root["name"] as? String) ?? "xAI API Key"
        let disabled = (root["api_key_disabled"] as? Bool) ?? false
        let blocked = (root["api_key_blocked"] as? Bool) ?? false
        let teamBlocked = (root["team_blocked"] as? Bool) ?? false
        let active = !disabled && !blocked && !teamBlocked
        let source = SourceAttribution(id: "xai.api_key", label: "xAI API Key Info", detail: "GET api.x.ai/v1/api-key")

        return AccountSnapshot(
            account: AccountIdentity(
                id: accountID,
                providerID: "grok",
                displayName: "Grok / xAI",
                planLabel: active ? name : "Key 已停用"
            ),
            connection: active ? .connected : .authRequired,
            spendMetrics: [
                MetricValue.unknown(
                    kind: .apiSpend,
                    unit: .usd,
                    source: source,
                    reason: active ? "密钥有效（余额需在 console.x.ai 查看）" : "密钥已禁用或受限"
                ),
            ],
            lastSuccessAt: now,
            lastAttemptAt: now,
            notes: ["xAI /v1/api-key 不返回账单余额；保持未知，不伪造数字。"]
        )
    }
}
