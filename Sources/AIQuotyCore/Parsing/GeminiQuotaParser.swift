import Foundation

public enum GeminiQuotaParser {
    public static let source = SourceAttribution(
        id: "gemini.retrieveUserQuota",
        label: "Gemini Code Assist Quota",
        detail: "POST cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
    )

    public struct Parsed: Equatable {
        public var email: String?
        public var planLabel: String?
        public var buckets: [Bucket]

        public struct Bucket: Equatable {
            public var modelID: String
            public var remainingFraction: Double?
            public var resetsAt: Date?
            public var resetKnown: Bool
        }
    }

    public static func parseQuota(json: Data, now: Date = Date()) throws -> Parsed {
        let obj = try JSONSerialization.jsonObject(with: json)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decode("Gemini quota 无效")
        }
        let bucketsRaw = (root["buckets"] as? [[String: Any]])
            ?? (root["quotaBuckets"] as? [[String: Any]])
            ?? []
        var buckets: [Parsed.Bucket] = []
        for item in bucketsRaw {
            let model = item["modelId"] as? String ?? item["model_id"] as? String ?? "model"
            let remaining: Double?
            if let f = number(item["remainingFraction"] ?? item["remaining_fraction"]) {
                remaining = min(max(f, 0), 1)
            } else {
                remaining = nil
            }
            let reset = parseReset(item["resetTime"] ?? item["reset_time"], now: now)
            buckets.append(
                Parsed.Bucket(
                    modelID: model,
                    remainingFraction: remaining,
                    resetsAt: reset.date,
                    resetKnown: reset.known
                )
            )
        }
        return Parsed(email: nil, planLabel: nil, buckets: buckets)
    }

    public static func parseTier(json: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            return nil
        }
        if let paid = root["paidTier"] as? [String: Any], let name = paid["name"] as? String {
            return name
        }
        if let current = root["currentTier"] as? [String: Any], let id = current["id"] as? String {
            switch id {
            case "standard-tier": return "Paid"
            case "free-tier": return "Free"
            case "legacy-tier": return "Legacy"
            default: return id
            }
        }
        return nil
    }

    public static func collapsedWindows(from parsed: Parsed, accountID: String, capturedAt: Date) -> [QuotaWindow] {
        // Group by model family: Pro / Flash / Flash Lite — take lowest remaining.
        let groups: [(String, (String) -> Bool)] = [
            ("Pro", { $0.lowercased().contains("pro") && !$0.lowercased().contains("flash") }),
            ("Flash", { $0.lowercased().contains("flash") && !$0.lowercased().contains("lite") }),
            ("Flash Lite", { $0.lowercased().contains("lite") }),
        ]
        var windows: [QuotaWindow] = []
        for (title, pred) in groups {
            let matching = parsed.buckets.filter { pred($0.modelID) }
            guard !matching.isEmpty else { continue }
            let lowestRemaining = matching.compactMap(\.remainingFraction).min()
            let reset = matching.compactMap(\.resetsAt).min()
            let resetKnown = matching.contains(where: \.resetKnown)
            let used = ResetMath.remainingFromUsed(lowestRemaining).map { 1 - $0 } ?? (lowestRemaining.map { 1 - $0 })
            // Fix: used = 1 - remaining
            let usedFraction = lowestRemaining.map { 1 - $0 }
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
            if let lowestRemaining {
                remainingDisplay = MetricValue(
                    kind: .subscriptionQuota,
                    precision: .reported,
                    unit: .percentRemaining,
                    value: lowestRemaining * 100,
                    display: String(format: "%.0f%%", lowestRemaining * 100),
                    source: source,
                    capturedAt: capturedAt,
                    freshness: .fresh
                )
            } else {
                remainingDisplay = .unknown(kind: .subscriptionQuota, unit: .percentRemaining, source: source)
            }
            _ = used
            windows.append(
                QuotaWindow(
                    id: "\(accountID).gemini.\(title)",
                    title: title,
                    usedFraction: usedFraction,
                    remainingFraction: lowestRemaining,
                    usedDisplay: usedDisplay,
                    remainingDisplay: remainingDisplay,
                    resetsAt: reset,
                    resetKnown: resetKnown,
                    source: source,
                    capturedAt: capturedAt
                )
            )
        }
        if windows.isEmpty, !parsed.buckets.isEmpty {
            // Fall back to per-model rows without inventing aggregates.
            for bucket in parsed.buckets {
                let usedFraction = bucket.remainingFraction.map { 1 - $0 }
                let usedDisplay: MetricValue = usedFraction.map {
                    MetricValue(
                        kind: .subscriptionQuota,
                        precision: .reported,
                        unit: .percentUsed,
                        value: $0 * 100,
                        display: String(format: "%.0f%%", $0 * 100),
                        source: source,
                        capturedAt: capturedAt,
                        freshness: .fresh
                    )
                } ?? .unknown(kind: .subscriptionQuota, unit: .percentUsed, source: source)
                let remainingDisplay: MetricValue = bucket.remainingFraction.map {
                    MetricValue(
                        kind: .subscriptionQuota,
                        precision: .reported,
                        unit: .percentRemaining,
                        value: $0 * 100,
                        display: String(format: "%.0f%%", $0 * 100),
                        source: source,
                        capturedAt: capturedAt,
                        freshness: .fresh
                    )
                } ?? .unknown(kind: .subscriptionQuota, unit: .percentRemaining, source: source)
                windows.append(
                    QuotaWindow(
                        id: "\(accountID).gemini.\(bucket.modelID)",
                        title: bucket.modelID,
                        usedFraction: usedFraction,
                        remainingFraction: bucket.remainingFraction,
                        usedDisplay: usedDisplay,
                        remainingDisplay: remainingDisplay,
                        resetsAt: bucket.resetsAt,
                        resetKnown: bucket.resetKnown,
                        source: source,
                        capturedAt: capturedAt
                    )
                )
            }
        }
        return windows
    }

    private static func number(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    private static func parseReset(_ raw: Any?, now: Date) -> (date: Date?, known: Bool) {
        if let s = raw as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) ?? ISO8601DateFormatter().date(from: s) {
                return (d, true)
            }
        }
        if let unix = raw as? Int {
            return (Date(timeIntervalSince1970: TimeInterval(unix)), true)
        }
        _ = now
        return (nil, false)
    }
}

public enum GeminiOAuthParser {
    public struct Creds: Equatable {
        public var accessToken: String
        public var refreshToken: String?
        public var expiryDate: Date?
        public var email: String?
    }

    public static func parse(json: Data) throws -> Creds {
        let obj = try JSONSerialization.jsonObject(with: json)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decode("gemini oauth_creds 无效")
        }
        guard let access = root["access_token"] as? String, !access.isEmpty else {
            throw ProviderError.authRequired("缺少 access_token；请先运行 gemini 登录")
        }
        var expiry: Date?
        if let ms = root["expiry_date"] as? Double {
            expiry = Date(timeIntervalSince1970: ms > 1_000_000_000_000 ? ms / 1000 : ms)
        } else if let ms = root["expiry_date"] as? Int {
            let v = Double(ms)
            expiry = Date(timeIntervalSince1970: v > 1_000_000_000_000 ? v / 1000 : v)
        }
        let email = (root["id_token"] as? String).flatMap(JWTClaims.email(from:))
        return Creds(
            accessToken: access,
            refreshToken: root["refresh_token"] as? String,
            expiryDate: expiry,
            email: email
        )
    }
}
