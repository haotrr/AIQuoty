import Foundation

public struct ProviderDescriptor: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var implementationStatus: ImplementationStatus
    public var authMethods: [AuthMethod]
    public var supportedMetricKinds: [MetricKind]
    public var notes: String

    public enum ImplementationStatus: String, Codable, Sendable {
        case implemented
        case partial
        case unimplemented
    }

    public enum AuthMethod: String, Codable, Sendable {
        case localCLICredentials
        case userPastedToken
        case apiKeyInKeychain
        case githubDeviceFlow
        case localLogImport
        case none
    }

    public init(
        id: String,
        displayName: String,
        implementationStatus: ImplementationStatus,
        authMethods: [AuthMethod],
        supportedMetricKinds: [MetricKind],
        notes: String
    ) {
        self.id = id
        self.displayName = displayName
        self.implementationStatus = implementationStatus
        self.authMethods = authMethods
        self.supportedMetricKinds = supportedMetricKinds
        self.notes = notes
    }
}

public struct ProviderFetchRequest: Sendable {
    public var accountID: String?
    public var force: Bool
    public var now: Date
    public var demoMode: Bool

    public init(accountID: String? = nil, force: Bool = false, now: Date = Date(), demoMode: Bool = false) {
        self.accountID = accountID
        self.force = force
        self.now = now
        self.demoMode = demoMode
    }
}

public enum ProviderError: Error, Sendable, Equatable {
    case notConfigured(String)
    case authRequired(String)
    case httpStatus(Int, body: String)
    case rateLimited(retryAfter: TimeInterval?)
    case decode(String)
    case network(String)
    case unsupported(String)
    case cancelled

    public var userMessage: String {
        switch self {
        case .notConfigured(let s): return "未配置：\(s)"
        case .authRequired(let s): return "需要授权：\(s)"
        case .httpStatus(let code, _): return "HTTP \(code)"
        case .rateLimited: return "请求过于频繁（429）"
        case .decode(let s): return "解析失败：\(s)"
        case .network(let s): return "网络错误：\(s)"
        case .unsupported(let s): return "未实现：\(s)"
        case .cancelled: return "已取消"
        }
    }
}

/// Boundary for every quota source. Implementations must not invent precise
/// subscription remaining from local token logs alone.
public protocol QuotaProvider: Sendable {
    var descriptor: ProviderDescriptor { get }
    func configuredAccounts() async -> [AccountIdentity]
    func fetch(request: ProviderFetchRequest) async throws -> [AccountSnapshot]
}

public enum ProviderRegistry {
    public static let allDescriptors: [ProviderDescriptor] = [
        ClaudeOAuthProvider.descriptor,
        CodexOAuthProvider.descriptor,
        CursorSessionProvider.descriptor,
        GeminiCLIProvider.descriptor,
        CopilotProvider.descriptor,
        OpenRouterProvider.descriptor,
        AnthropicAdminSpendProvider.descriptor,
        LocalClaudeLogProvider.descriptor,
        LocalCodexLogProvider.descriptor,
        UnimplementedProviders.windsurf,
        UnimplementedProviders.antigravity,
        UnimplementedProviders.factoryDroid,
        UnimplementedProviders.kimiCode,
        UnimplementedProviders.openCode,
        UnimplementedProviders.clineRoo,
        UnimplementedProviders.traeQoder,
        UnimplementedProviders.grok,
    ]

    public static func makeLiveProviders(
        credentials: CredentialStore,
        http: HTTPClient,
        fileSystem: FileSystemReading,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) -> [any QuotaProvider] {
        [
            ClaudeOAuthProvider(credentials: credentials, http: http, fileSystem: fileSystem, clock: clock),
            CodexOAuthProvider(credentials: credentials, http: http, fileSystem: fileSystem, clock: clock),
            CursorSessionProvider(credentials: credentials, http: http, fileSystem: fileSystem, clock: clock),
            GeminiCLIProvider(credentials: credentials, http: http, fileSystem: fileSystem, clock: clock),
            CopilotProvider(credentials: credentials, http: http, clock: clock),
            OpenRouterProvider(credentials: credentials, http: http, clock: clock),
            AnthropicAdminSpendProvider(credentials: credentials, http: http, clock: clock),
            LocalClaudeLogProvider(fileSystem: fileSystem, clock: clock),
            LocalCodexLogProvider(fileSystem: fileSystem, clock: clock),
        ]
    }
}

public enum UnimplementedProviders {
    public static let windsurf = ProviderDescriptor(
        id: "windsurf",
        displayName: "Windsurf",
        implementationStatus: .unimplemented,
        authMethods: [.none],
        supportedMetricKinds: [],
        notes: "首版未实现。需要经用户同意的会话导入或官方 API；不做浏览器会话提取。"
    )
    public static let antigravity = ProviderDescriptor(
        id: "antigravity",
        displayName: "Antigravity",
        implementationStatus: .unimplemented,
        authMethods: [.none],
        supportedMetricKinds: [],
        notes: "首版未实现。可后续对接 Google OAuth / 本地 language server（文档化路径）。"
    )
    public static let factoryDroid = ProviderDescriptor(
        id: "factory-droid",
        displayName: "Factory / Droid",
        implementationStatus: .unimplemented,
        authMethods: [.apiKeyInKeychain],
        supportedMetricKinds: [.subscriptionQuota],
        notes: "首版未实现。规划：用户粘贴 Factory API Key → api.factory.ai（需核实文档）。"
    )
    public static let kimiCode = ProviderDescriptor(
        id: "kimi-code",
        displayName: "Kimi Code",
        implementationStatus: .unimplemented,
        authMethods: [.none],
        supportedMetricKinds: [],
        notes: "首版未实现。"
    )
    public static let openCode = ProviderDescriptor(
        id: "opencode",
        displayName: "OpenCode",
        implementationStatus: .unimplemented,
        authMethods: [.none],
        supportedMetricKinds: [],
        notes: "首版未实现。"
    )
    public static let clineRoo = ProviderDescriptor(
        id: "cline-roo",
        displayName: "Cline / Roo",
        implementationStatus: .unimplemented,
        authMethods: [.none],
        supportedMetricKinds: [],
        notes: "首版未实现。可能依赖各模型供应商密钥的本地用量，而非统一订阅配额。"
    )
    public static let traeQoder = ProviderDescriptor(
        id: "trae-qoder",
        displayName: "Trae / Qoder",
        implementationStatus: .unimplemented,
        authMethods: [.none],
        supportedMetricKinds: [],
        notes: "首版未实现。"
    )
    public static let grok = ProviderDescriptor(
        id: "grok",
        displayName: "Grok",
        implementationStatus: .unimplemented,
        authMethods: [.localCLICredentials],
        supportedMetricKinds: [.subscriptionQuota],
        notes: "首版未实现。规划：用户同意后读取 Grok CLI auth.json（不自动提取浏览器会话）。"
    )
}
