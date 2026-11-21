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
        AntigravityProvider.descriptor,
        GeminiCLIProvider.descriptor,
        OpenCodeProvider.descriptor,
        DeepSeekProvider.descriptor,
        CopilotProvider.descriptor,
        KimiCodeProvider.descriptor,
        MiniMaxProvider.descriptor,
        ZaiGLMProvider.descriptor,
        FactoryDroidProvider.descriptor,
        WindsurfProvider.descriptor,
        GrokProvider.descriptor,
        OpenRouterProvider.descriptor,
        AnthropicAdminSpendProvider.descriptor,
        LocalClaudeLogProvider.descriptor,
        LocalCodexLogProvider.descriptor,
        LocalOpenCodeLogProvider.descriptor,
        LocalClineRooLogProvider.descriptor,
        UnimplementedProviders.traeQoder,
        UnimplementedProviders.zed,
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
            AntigravityProvider(http: http, clock: clock),
            GeminiCLIProvider(credentials: credentials, http: http, fileSystem: fileSystem, clock: clock),
            OpenCodeProvider(credentials: credentials, http: http, fileSystem: fileSystem, clock: clock),
            DeepSeekProvider(credentials: credentials, http: http, fileSystem: fileSystem, clock: clock),
            CopilotProvider(credentials: credentials, http: http, fileSystem: fileSystem, clock: clock),
            KimiCodeProvider(credentials: credentials, http: http, fileSystem: fileSystem, clock: clock),
            MiniMaxProvider(credentials: credentials, http: http, clock: clock),
            ZaiGLMProvider(credentials: credentials, http: http, clock: clock),
            FactoryDroidProvider(credentials: credentials, http: http, fileSystem: fileSystem, clock: clock),
            WindsurfProvider(credentials: credentials, http: http, fileSystem: fileSystem, clock: clock),
            GrokProvider(credentials: credentials, http: http, fileSystem: fileSystem, clock: clock),
            OpenRouterProvider(credentials: credentials, http: http, clock: clock),
            AnthropicAdminSpendProvider(credentials: credentials, http: http, clock: clock),
            LocalClaudeLogProvider(fileSystem: fileSystem, clock: clock),
            LocalCodexLogProvider(fileSystem: fileSystem, clock: clock),
            LocalOpenCodeLogProvider(fileSystem: fileSystem, clock: clock),
            LocalClineRooLogProvider(fileSystem: fileSystem, clock: clock),
        ]
    }
}

public enum UnimplementedProviders {
    public static let traeQoder = ProviderDescriptor(
        id: "trae-qoder",
        displayName: "Trae / Qoder",
        implementationStatus: .unimplemented,
        authMethods: [.none],
        supportedMetricKinds: [],
        notes: "支持检测本机安装，但官方暂未公开稳定配额 API；不做浏览器会话窃取。"
    )
    public static let zed = ProviderDescriptor(
        id: "zed",
        displayName: "Zed AI",
        implementationStatus: .unimplemented,
        authMethods: [.none],
        supportedMetricKinds: [],
        notes: "支持检测本机安装；Zed Pro 配额接口暂未公开，可配合各模型 API Key 监控。"
    )
}
