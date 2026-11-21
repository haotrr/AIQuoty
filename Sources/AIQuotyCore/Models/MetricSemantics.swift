import Foundation

/// What a number represents. These categories must never be mixed or summed.
public enum MetricKind: String, Codable, Sendable, CaseIterable {
    /// Provider-reported subscription quota (percent / request pools).
    case subscriptionQuota
    /// Provider billing API spend or prepaid balance.
    case apiSpend
    /// Tokens observed from local logs on this machine only.
    case locallyObservedTokens
}

/// How precise the value is.
public enum MetricPrecision: String, Codable, Sendable, CaseIterable {
    /// Provider gave an exact countable remainder (e.g. credits remaining).
    case exact
    /// Provider reported a percentage / window utilization.
    case reported
    /// Derived from local observation; not subscription remaining.
    case estimated
    /// Intentionally unknown — never coerce to 0 or 100%.
    case unknown
}

public enum Freshness: String, Codable, Sendable, CaseIterable {
    case never
    case fresh
    case stale
}

public enum ConnectionState: String, Codable, Sendable, CaseIterable {
    case disconnected
    case connecting
    case connected
    case authRequired
    case rateLimited
    case error
    case unsupported
}

public enum QuotaUnit: String, Codable, Sendable, CaseIterable {
    case percentUsed
    case percentRemaining
    case requests
    case tokens
    case usd
    case credits
    case characters
    case unknown
}

public struct SourceAttribution: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var label: String
    public var detail: String?

    public init(id: String, label: String, detail: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

public struct MetricValue: Codable, Sendable, Equatable {
    public var kind: MetricKind
    public var precision: MetricPrecision
    public var unit: QuotaUnit
    /// Numeric magnitude when known. Nil means unknown (display as "未知").
    public var value: Double?
    public var display: String
    public var source: SourceAttribution
    public var capturedAt: Date?
    public var freshness: Freshness

    public init(
        kind: MetricKind,
        precision: MetricPrecision,
        unit: QuotaUnit,
        value: Double?,
        display: String,
        source: SourceAttribution,
        capturedAt: Date? = nil,
        freshness: Freshness = .never
    ) {
        self.kind = kind
        self.precision = precision
        self.unit = unit
        self.value = value
        self.display = display
        self.source = source
        self.capturedAt = capturedAt
        self.freshness = freshness
    }

    public static func unknown(
        kind: MetricKind,
        unit: QuotaUnit = .unknown,
        source: SourceAttribution,
        reason: String = "未知"
    ) -> MetricValue {
        MetricValue(
            kind: kind,
            precision: .unknown,
            unit: unit,
            value: nil,
            display: reason,
            source: source,
            freshness: .never
        )
    }
}
