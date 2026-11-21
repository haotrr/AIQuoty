import Foundation

public enum CursorUsageParser {
    public static let source = SourceAttribution(
        id: "cursor.usage-summary",
        label: "cursor.com usage-summary",
        detail: "GET cursor.com/api/usage-summary"
    )

    public struct Parsed: Equatable {
        public var email: String?
        public var planName: String?
        public var windows: [Window]
        public var billingCycleEnd: Date?

        public struct Window: Equatable {
            public var id: String
            public var title: String
            public var usedFraction: Double?
            public var resetsAt: Date?
            public var resetKnown: Bool
        }
    }

    public static func parseSummary(json: Data, now: Date = Date()) throws -> Parsed {
        let obj = try JSONSerialization.jsonObject(with: json)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decode("Cursor usage-summary 无效")
        }
        var windows: [Parsed.Window] = []

        if let individual = root["individualUsage"] as? [String: Any] {
            windows.append(contentsOf: parsePlanBuckets(individual, prefix: "individual", now: now))
        }
        if let team = root["teamUsage"] as? [String: Any] {
            windows.append(contentsOf: parsePlanBuckets(team, prefix: "team", now: now))
        }
        // Flat percent fields seen in some responses
        if windows.isEmpty {
            if let pct = number(root["planUsagePercent"] ?? root["usagePercent"]) {
                windows.append(
                    Parsed.Window(
                        id: "plan",
                        title: "Plan",
                        usedFraction: min(max(pct / 100.0, 0), 1),
                        resetsAt: parseDate(root["billingCycleEnd"] ?? root["nextReset"]),
                        resetKnown: parseDate(root["billingCycleEnd"] ?? root["nextReset"]) != nil
                    )
                )
            }
        }

        let membership = root["membershipType"] as? String ?? root["plan"] as? String
        return Parsed(
            email: root["email"] as? String,
            planName: membership,
            windows: windows,
            billingCycleEnd: parseDate(root["billingCycleEnd"])
        )
    }

    /// Legacy request-count usage: GET /api/usage?user=
    public static func parseLegacyUsage(json: Data, now: Date = Date()) throws -> [Parsed.Window] {
        let obj = try JSONSerialization.jsonObject(with: json)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decode("Cursor legacy usage 无效")
        }
        var windows: [Parsed.Window] = []
        if let gpt = root["gpt-4"] as? [String: Any] {
            windows.append(legacyWindow(id: "premium", title: "Premium 请求", dict: gpt, now: now))
        }
        if let start = root["start-of-month"] as? String {
            _ = start
        }
        return windows.filter { $0.usedFraction != nil || $0.resetKnown }
    }

    public static func quotaWindows(from parsed: Parsed, accountID: String, capturedAt: Date) -> [QuotaWindow] {
        parsed.windows.map { window in
            let remaining = ResetMath.remainingFromUsed(window.usedFraction)
            let usedDisplay: MetricValue
            if let used = window.usedFraction {
                usedDisplay = MetricValue(
                    kind: .subscriptionQuota,
                    precision: .reported,
                    unit: .percentUsed,
                    value: used * 100,
                    display: String(format: "%.0f%%", used * 100),
                    source: source,
                    capturedAt: capturedAt,
                    freshness: .fresh
                )
            } else {
                usedDisplay = .unknown(kind: .subscriptionQuota, unit: .percentUsed, source: source)
            }
            let remainingDisplay: MetricValue
            if let remaining {
                remainingDisplay = MetricValue(
                    kind: .subscriptionQuota,
                    precision: .reported,
                    unit: .percentRemaining,
                    value: remaining * 100,
                    display: String(format: "%.0f%%", remaining * 100),
                    source: source,
                    capturedAt: capturedAt,
                    freshness: .fresh
                )
            } else {
                remainingDisplay = .unknown(kind: .subscriptionQuota, unit: .percentRemaining, source: source)
            }
            return QuotaWindow(
                id: "\(accountID).\(window.id)",
                title: window.title,
                usedFraction: window.usedFraction,
                remainingFraction: remaining,
                usedDisplay: usedDisplay,
                remainingDisplay: remainingDisplay,
                resetsAt: window.resetsAt ?? parsed.billingCycleEnd,
                resetKnown: window.resetKnown || parsed.billingCycleEnd != nil,
                source: source,
                capturedAt: capturedAt
            )
        }
    }

    private static func parsePlanBuckets(_ dict: [String: Any], prefix: String, now: Date) -> [Parsed.Window] {
        var windows: [Parsed.Window] = []
        let mapping: [(String, String)] = [
            ("plan", "Plan"),
            ("total", "Total"),
            ("auto", "Auto"),
            ("api", "API"),
            ("included", "Included"),
            ("onDemand", "On-demand"),
        ]
        for (key, title) in mapping {
            guard let bucket = dict[key] as? [String: Any] else { continue }
            let used = fraction(from: bucket)
            let reset = parseDate(bucket["billingCycleEnd"] ?? bucket["resetDate"] ?? bucket["nextResetDate"])
            if used == nil && reset == nil { continue }
            windows.append(
                Parsed.Window(
                    id: "\(prefix).\(key)",
                    title: title,
                    usedFraction: used,
                    resetsAt: reset,
                    resetKnown: reset != nil
                )
            )
        }
        _ = now
        return windows
    }

    private static func legacyWindow(id: String, title: String, dict: [String: Any], now: Date) -> Parsed.Window {
        let numRequests = number(dict["numRequests"])
        let maxRequestUsage = number(dict["maxRequestUsage"])
        let used: Double?
        if let numRequests, let maxRequestUsage, maxRequestUsage > 0 {
            used = min(max(numRequests / maxRequestUsage, 0), 1)
        } else {
            used = nil
        }
        _ = now
        return Parsed.Window(
            id: id,
            title: title,
            usedFraction: used,
            resetsAt: nil,
            resetKnown: false
        )
    }

    private static func fraction(from bucket: [String: Any]) -> Double? {
        if let pct = number(bucket["usedPercent"] ?? bucket["usagePercent"] ?? bucket["percentUsed"]) {
            return min(max(pct / 100.0, 0), 1)
        }
        if let used = number(bucket["used"]), let limit = number(bucket["limit"]), limit > 0 {
            return min(max(used / limit, 0), 1)
        }
        if let remaining = number(bucket["remaining"]), let limit = number(bucket["limit"]), limit > 0 {
            return min(max(1 - remaining / limit, 0), 1)
        }
        return nil
    }

    private static func number(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        if let unix = raw as? Int { return Date(timeIntervalSince1970: TimeInterval(unix)) }
        if let unix = raw as? Double { return Date(timeIntervalSince1970: unix) }
        if let s = raw as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) ?? ISO8601DateFormatter().date(from: s) { return d }
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = "yyyy-MM-dd"
            return df.date(from: s)
        }
        return nil
    }
}
