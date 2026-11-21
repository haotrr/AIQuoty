import Foundation

public enum CodexUsageParser {
    public static let source = SourceAttribution(
        id: "codex.wham.usage",
        label: "Codex wham/usage",
        detail: "GET chatgpt.com/backend-api/wham/usage"
    )

    public struct Parsed: Equatable {
        public var email: String?
        public var planType: String?
        public var windows: [Window]
        public var creditsBalance: String?
        public var hasCredits: Bool?

        public struct Window: Equatable {
            public var title: String
            public var usedPercent: Double?
            public var windowSeconds: Int?
            public var resetsAt: Date?
            public var resetKnown: Bool
        }
    }

    public static func parse(json: Data, now: Date = Date()) throws -> Parsed {
        let obj = try JSONSerialization.jsonObject(with: json)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decode("Codex usage 根节点无效")
        }
        let rate = root["rate_limit"] as? [String: Any]
        var windows: [Parsed.Window] = []
        if let primary = rate?["primary_window"] as? [String: Any] {
            windows.append(mapWindow(primary, now: now))
        }
        if let secondary = rate?["secondary_window"] as? [String: Any] {
            windows.append(mapWindow(secondary, now: now))
        }
        if let additional = root["additional_rate_limits"] as? [[String: Any]] {
            for item in additional {
                let title = item["title"] as? String ?? item["id"] as? String ?? "额外限额"
                if let p = item["primary_window"] as? [String: Any] {
                    var w = mapWindow(p, now: now)
                    w = Parsed.Window(
                        title: title,
                        usedPercent: w.usedPercent,
                        windowSeconds: w.windowSeconds,
                        resetsAt: w.resetsAt,
                        resetKnown: w.resetKnown
                    )
                    windows.append(w)
                }
            }
        }
        let credits = root["credits"] as? [String: Any]
        return Parsed(
            email: root["email"] as? String,
            planType: root["plan_type"] as? String,
            windows: windows,
            creditsBalance: credits?["balance"] as? String,
            hasCredits: credits?["has_credits"] as? Bool
        )
    }

    public static func quotaWindows(from parsed: Parsed, accountID: String, capturedAt: Date) -> [QuotaWindow] {
        parsed.windows.enumerated().map { index, window in
            let usedFraction = ResetMath.fractionFromPercent(window.usedPercent)
            let remaining = ResetMath.remainingFromUsed(usedFraction)
            let title = window.title.isEmpty
                ? ResetMath.codexWindowTitle(seconds: window.windowSeconds)
                : window.title
            let usedDisplay: MetricValue
            if let usedFraction {
                usedDisplay = MetricValue(
                    kind: .subscriptionQuota,
                    precision: .reported,
                    unit: .percentUsed,
                    value: usedFraction * 100,
                    display: String(format: "%.0f%%", usedFraction * 100),
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
                id: "\(accountID).window.\(index).\(window.windowSeconds ?? 0)",
                title: title,
                usedFraction: usedFraction,
                remainingFraction: remaining,
                usedDisplay: usedDisplay,
                remainingDisplay: remainingDisplay,
                resetsAt: window.resetsAt,
                resetKnown: window.resetKnown,
                windowSeconds: window.windowSeconds,
                source: source,
                capturedAt: capturedAt
            )
        }
    }

    private static func mapWindow(_ dict: [String: Any], now: Date) -> Parsed.Window {
        let used: Double?
        if let d = dict["used_percent"] as? Double { used = d }
        else if let i = dict["used_percent"] as? Int { used = Double(i) }
        else { used = nil }
        let seconds = dict["limit_window_seconds"] as? Int
        let resetUnix = dict["reset_at"] as? Int
        let resetAfter = dict["reset_after_seconds"] as? Int
        let (date, known) = ResetMath.resolveReset(
            resetAtUnix: resetUnix,
            resetAfterSeconds: resetAfter,
            now: now
        )
        return Parsed.Window(
            title: ResetMath.codexWindowTitle(seconds: seconds),
            usedPercent: used,
            windowSeconds: seconds,
            resetsAt: date,
            resetKnown: known
        )
    }
}

public enum CodexAuthParser {
    public struct Auth: Equatable {
        public var accessToken: String
        public var accountID: String?
        public var email: String?
    }

    public static func parse(json: Data) throws -> Auth {
        let obj = try JSONSerialization.jsonObject(with: json)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decode("auth.json 无效")
        }
        if root["OPENAI_API_KEY"] != nil, root["tokens"] == nil {
            throw ProviderError.unsupported("仅有 API Key，无法读取 ChatGPT/Codex 订阅配额")
        }
        let tokens = root["tokens"] as? [String: Any] ?? root
        guard let access = tokens["access_token"] as? String, !access.isEmpty else {
            throw ProviderError.authRequired("auth.json 缺少 access_token；请运行 codex login")
        }
        let accountID = tokens["account_id"] as? String ?? root["account_id"] as? String
        var email: String?
        if let idToken = tokens["id_token"] as? String {
            email = JWTClaims.email(from: idToken)
        }
        return Auth(accessToken: access, accountID: accountID, email: email)
    }
}

public enum JWTClaims {
    public static func email(from jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let email = obj["email"] as? String { return email }
        if let auth = obj["https://api.openai.com/auth"] as? [String: Any] {
            return auth["chatgpt_user_email"] as? String ?? auth["email"] as? String
        }
        return nil
    }

    public static func subject(from jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj["sub"] as? String
    }
}
