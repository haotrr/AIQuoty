import Foundation

public struct AccountIdentity: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var providerID: String
    public var displayName: String
    public var email: String?
    public var planLabel: String?
    public var group: String?
    public var pinned: Bool

    public init(
        id: String,
        providerID: String,
        displayName: String,
        email: String? = nil,
        planLabel: String? = nil,
        group: String? = nil,
        pinned: Bool = false
    ) {
        self.id = id
        self.providerID = providerID
        self.displayName = displayName
        self.email = email
        self.planLabel = planLabel
        self.group = group
        self.pinned = pinned
    }
}

public struct AccountSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var id: String { account.id }
    public var account: AccountIdentity
    public var connection: ConnectionState
    public var windows: [QuotaWindow]
    public var spendMetrics: [MetricValue]
    public var localTokenMetrics: [MetricValue]
    public var lastSuccessAt: Date?
    public var lastAttemptAt: Date?
    public var lastError: String?
    public var notes: [String]

    public init(
        account: AccountIdentity,
        connection: ConnectionState,
        windows: [QuotaWindow] = [],
        spendMetrics: [MetricValue] = [],
        localTokenMetrics: [MetricValue] = [],
        lastSuccessAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        lastError: String? = nil,
        notes: [String] = []
    ) {
        self.account = account
        self.connection = connection
        self.windows = windows
        self.spendMetrics = spendMetrics
        self.localTokenMetrics = localTokenMetrics
        self.lastSuccessAt = lastSuccessAt
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
        self.notes = notes
    }

    /// Keep last-success windows but mark them stale on failure.
    public func markingStale(error: String, at: Date = Date()) -> AccountSnapshot {
        var copy = self
        copy.connection = .error
        copy.lastError = error
        copy.lastAttemptAt = at
        copy.windows = windows.map { $0.withFreshness(.stale) }
        copy.spendMetrics = spendMetrics.map {
            var m = $0
            m.freshness = .stale
            return m
        }
        return copy
    }

    public func markingRateLimited(retryAfter: TimeInterval?, at: Date = Date()) -> AccountSnapshot {
        var copy = markingStale(error: "HTTP 429 限流", at: at)
        copy.connection = .rateLimited
        if let retryAfter {
            copy.notes.append("建议退避 \(Int(retryAfter)) 秒后再刷新")
        }
        return copy
    }
}
