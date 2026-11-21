import Foundation

/// Non-secret preferences only. Secrets must use CredentialStore.
public struct AppPreferences: Codable, Sendable, Equatable {
    public var demoMode: Bool
    public var refreshIntervalSeconds: TimeInterval
    public var enableLocalClaudeLogs: Bool
    public var enableLocalCodexLogs: Bool
    public var enableLocalOpenCodeLogs: Bool
    public var enableLocalClineLogs: Bool
    public var pinnedAccountIDs: [String]
    public var menuBarAccountIDs: [String]
    public var menuBarIconOnly: Bool
    public var accountGroups: [String: String]
    public var appearance: Appearance
    public var githubOAuthClientID: String?

    public enum Appearance: String, Codable, Sendable {
        case system
        case light
        case dark
    }

    public init(
        demoMode: Bool = false,
        refreshIntervalSeconds: TimeInterval = 300,
        enableLocalClaudeLogs: Bool = false,
        enableLocalCodexLogs: Bool = false,
        enableLocalOpenCodeLogs: Bool = false,
        enableLocalClineLogs: Bool = false,
        pinnedAccountIDs: [String] = [],
        menuBarAccountIDs: [String] = [],
        menuBarIconOnly: Bool = false,
        accountGroups: [String: String] = [:],
        appearance: Appearance = .system,
        githubOAuthClientID: String? = nil
    ) {
        self.demoMode = demoMode
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.enableLocalClaudeLogs = enableLocalClaudeLogs
        self.enableLocalCodexLogs = enableLocalCodexLogs
        self.enableLocalOpenCodeLogs = enableLocalOpenCodeLogs
        self.enableLocalClineLogs = enableLocalClineLogs
        self.pinnedAccountIDs = pinnedAccountIDs
        self.menuBarAccountIDs = menuBarAccountIDs
        self.menuBarIconOnly = menuBarIconOnly
        self.accountGroups = accountGroups
        self.appearance = appearance
        self.githubOAuthClientID = githubOAuthClientID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.demoMode = try c.decodeIfPresent(Bool.self, forKey: .demoMode) ?? false
        self.refreshIntervalSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .refreshIntervalSeconds) ?? 300
        self.enableLocalClaudeLogs = try c.decodeIfPresent(Bool.self, forKey: .enableLocalClaudeLogs) ?? false
        self.enableLocalCodexLogs = try c.decodeIfPresent(Bool.self, forKey: .enableLocalCodexLogs) ?? false
        self.enableLocalOpenCodeLogs = try c.decodeIfPresent(Bool.self, forKey: .enableLocalOpenCodeLogs) ?? false
        self.enableLocalClineLogs = try c.decodeIfPresent(Bool.self, forKey: .enableLocalClineLogs) ?? false
        self.pinnedAccountIDs = try c.decodeIfPresent([String].self, forKey: .pinnedAccountIDs) ?? []
        self.menuBarAccountIDs = try c.decodeIfPresent([String].self, forKey: .menuBarAccountIDs) ?? []
        self.menuBarIconOnly = try c.decodeIfPresent(Bool.self, forKey: .menuBarIconOnly) ?? false
        self.accountGroups = try c.decodeIfPresent([String: String].self, forKey: .accountGroups) ?? [:]
        self.appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .system
        self.githubOAuthClientID = try c.decodeIfPresent(String.self, forKey: .githubOAuthClientID)
    }

    public static let `default` = AppPreferences()
}

public protocol PreferencesStore: Sendable {
    func load() throws -> AppPreferences
    func save(_ preferences: AppPreferences) throws
}

public final class JSONPreferencesStore: PreferencesStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public convenience init(filename: String = "preferences.json") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("AIQuoty", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.init(url: dir.appendingPathComponent(filename))
    }

    public func load() throws -> AppPreferences {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .default
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AppPreferences.self, from: data)
    }

    public func save(_ preferences: AppPreferences) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try JSONEncoder().encode(preferences)
        try data.write(to: url, options: .atomic)
    }
}
