import Foundation

public enum ClaudeUsageParser {
    public static let source = SourceAttribution(
        id: "claude.oauth.usage",
        label: "Anthropic OAuth Usage API",
        detail: "GET api.anthropic.com/api/oauth/usage"
    )

    public struct Parsed: Equatable {
        public var fiveHour: Window?
        public var sevenDay: Window?
        public var sonnetWeekly: Window?
        public var opusWeekly: Window?
        public var extraUsageEnabled: Bool?
        public var planHint: String?

        public struct Window: Equatable {
            public var utilization: Double?
            public var resetsAt: Date?
            public var resetKnown: Bool
        }
    }

    /// Accepts both OAuth (`utilization` 0-1 or 0-100) and web org usage shapes.
    public static func parse(json: Data, now: Date = Date()) throws -> Parsed {
        let obj = try JSONSerialization.jsonObject(with: json)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decode("Claude usage 根节点不是对象")
        }
        return Parsed(
            fiveHour: parseWindow(root["five_hour"], now: now),
            sevenDay: parseWindow(root["seven_day"] ?? root["seven_day_oauth_apps"], now: now),
            sonnetWeekly: parseWindow(root["seven_day_sonnet"], now: now),
            opusWeekly: parseWindow(root["seven_day_opus"], now: now),
            extraUsageEnabled: (root["extra_usage"] as? [String: Any])?["is_enabled"] as? Bool,
            planHint: root["subscriptionType"] as? String ?? root["rate_limit_tier"] as? String
        )
    }

    public static func windows(
        from parsed: Parsed,
        accountID: String,
        capturedAt: Date
    ) -> [QuotaWindow] {
        var result: [QuotaWindow] = []
        if let w = parsed.fiveHour {
            result.append(makeWindow(id: "\(accountID).five_hour", title: "5 小时", window: w, capturedAt: capturedAt))
        }
        if let w = parsed.sevenDay {
            result.append(makeWindow(id: "\(accountID).seven_day", title: "7 天", window: w, capturedAt: capturedAt))
        }
        if let w = parsed.sonnetWeekly {
            result.append(makeWindow(id: "\(accountID).sonnet_weekly", title: "Sonnet 周限额", window: w, capturedAt: capturedAt))
        }
        if let w = parsed.opusWeekly {
            result.append(makeWindow(id: "\(accountID).opus_weekly", title: "Opus 周限额", window: w, capturedAt: capturedAt))
        }
        return result
    }

    private static func parseWindow(_ raw: Any?, now: Date) -> Parsed.Window? {
        guard let dict = raw as? [String: Any] else { return nil }
        let utilization = normalizeUtilization(dict["utilization"] ?? dict["percent"])
        let (reset, known) = parseReset(dict, now: now)
        // Missing utilization stays nil — never invent 0.
        return Parsed.Window(utilization: utilization, resetsAt: reset, resetKnown: known)
    }

    private static func normalizeUtilization(_ raw: Any?) -> Double? {
        if let d = raw as? Double {
            return d > 1.0 ? min(d / 100.0, 1) : min(max(d, 0), 1)
        }
        if let i = raw as? Int {
            let d = Double(i)
            return d > 1.0 ? min(d / 100.0, 1) : min(max(d, 0), 1)
        }
        if let s = raw as? String, let d = Double(s) {
            return d > 1.0 ? min(d / 100.0, 1) : min(max(d, 0), 1)
        }
        return nil
    }

    private static func parseReset(_ dict: [String: Any], now: Date) -> (Date?, Bool) {
        if let unix = dict["resetsAt"] as? Int {
            return (Date(timeIntervalSince1970: TimeInterval(unix)), true)
        }
        if let unix = dict["resetsAt"] as? Double {
            return (Date(timeIntervalSince1970: unix), true)
        }
        if let iso = dict["resets_at"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) {
                return (date, true)
            }
        }
        _ = now
        return (nil, false)
    }

    private static func makeWindow(
        id: String,
        title: String,
        window: Parsed.Window,
        capturedAt: Date
    ) -> QuotaWindow {
        let used = window.utilization
        let remaining = ResetMath.remainingFromUsed(used)
        let usedDisplay: MetricValue
        if let used {
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
            id: id,
            title: title,
            usedFraction: used,
            remainingFraction: remaining,
            usedDisplay: usedDisplay,
            remainingDisplay: remainingDisplay,
            resetsAt: window.resetsAt,
            resetKnown: window.resetKnown,
            source: source,
            capturedAt: capturedAt,
            freshness: .fresh
        )
    }
}

public enum ClaudeCredentialsParser {
    public struct Credentials: Equatable {
        public var accessToken: String
        public var expiresAt: Date?
        public var email: String?
    }

    /// Reads Claude Code `~/.claude/.credentials.json` shape (claudeAiOauth).
    public static func parse(json: Data) throws -> Credentials {
        let obj = try JSONSerialization.jsonObject(with: json)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decode("credentials 根节点无效")
        }
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let token = oauth["accessToken"] as? String ?? oauth["access_token"] as? String, !token.isEmpty else {
            if root["mcpOAuth"] != nil {
                throw ProviderError.authRequired("仅有 MCP OAuth，缺少 user:profile 订阅用量令牌")
            }
            throw ProviderError.authRequired("未找到 Claude OAuth accessToken")
        }
        var expiresAt: Date?
        if let ms = oauth["expiresAt"] as? Double {
            expiresAt = Date(timeIntervalSince1970: ms > 1_000_000_000_000 ? ms / 1000 : ms)
        } else if let ms = oauth["expiresAt"] as? Int {
            let v = Double(ms)
            expiresAt = Date(timeIntervalSince1970: v > 1_000_000_000_000 ? v / 1000 : v)
        }
        return Credentials(
            accessToken: token,
            expiresAt: expiresAt,
            email: oauth["email"] as? String
        )
    }
}
