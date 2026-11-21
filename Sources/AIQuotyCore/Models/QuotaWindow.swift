import Foundation

/// A single distinct quota window. Windows across services must not be summed.
public struct QuotaWindow: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    /// Used fraction 0...1 when reported. Nil = unknown (not zero).
    public var usedFraction: Double?
    /// Remaining fraction 0...1 when reported. Nil = unknown.
    public var remainingFraction: Double?
    public var usedDisplay: MetricValue
    public var remainingDisplay: MetricValue
    public var resetsAt: Date?
    public var resetKnown: Bool
    public var windowSeconds: Int?
    public var source: SourceAttribution
    public var capturedAt: Date
    public var freshness: Freshness

    public init(
        id: String,
        title: String,
        usedFraction: Double?,
        remainingFraction: Double?,
        usedDisplay: MetricValue,
        remainingDisplay: MetricValue,
        resetsAt: Date?,
        resetKnown: Bool,
        windowSeconds: Int? = nil,
        source: SourceAttribution,
        capturedAt: Date,
        freshness: Freshness = .fresh
    ) {
        self.id = id
        self.title = title
        self.usedFraction = usedFraction
        self.remainingFraction = remainingFraction
        self.usedDisplay = usedDisplay
        self.remainingDisplay = remainingDisplay
        self.resetsAt = resetsAt
        self.resetKnown = resetKnown
        self.windowSeconds = windowSeconds
        self.source = source
        self.capturedAt = capturedAt
        self.freshness = freshness
    }

    public func withFreshness(_ freshness: Freshness) -> QuotaWindow {
        var copy = self
        copy.freshness = freshness
        copy.usedDisplay.freshness = freshness
        copy.remainingDisplay.freshness = freshness
        return copy
    }

    /// Seconds until reset from `now`. Nil when reset is unknown.
    public func secondsUntilReset(now: Date = Date()) -> TimeInterval? {
        guard resetKnown, let resetsAt else { return nil }
        return resetsAt.timeIntervalSince(now)
    }
}

public enum ResetMath {
    /// Prefer absolute `resetAt`; else derive from `resetAfterSeconds` relative to `now`.
    public static func resolveReset(
        resetAtUnix: Int?,
        resetAfterSeconds: Int?,
        now: Date = Date()
    ) -> (date: Date?, known: Bool) {
        if let resetAtUnix {
            return (Date(timeIntervalSince1970: TimeInterval(resetAtUnix)), true)
        }
        if let resetAfterSeconds {
            return (now.addingTimeInterval(TimeInterval(resetAfterSeconds)), true)
        }
        return (nil, false)
    }

    /// Classify Codex-style window duration. Unknown durations stay unlabeled.
    public static func codexWindowTitle(seconds: Int?) -> String {
        switch seconds {
        case 18_000: return "5 小时"
        case 604_800: return "7 天"
        case 2_592_000: return "30 天"
        case .some(let s) where s > 0:
            let hours = s / 3600
            if hours >= 24, hours % 24 == 0 {
                return "\(hours / 24) 天"
            }
            return "\(hours) 小时"
        default:
            return "配额窗口"
        }
    }

    public static func fractionFromPercent(_ percent: Double?) -> Double? {
        guard let percent else { return nil }
        return min(max(percent / 100.0, 0), 1)
    }

    public static func remainingFromUsed(_ used: Double?) -> Double? {
        guard let used else { return nil }
        return min(max(1 - used, 0), 1)
    }
}
