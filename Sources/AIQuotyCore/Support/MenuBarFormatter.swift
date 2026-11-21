import Foundation

/// Formats selected account snapshots into a concise macOS menu bar summary.
public enum MenuBarFormatter {
    public static func summary(
        snapshots: [AccountSnapshot],
        selectedAccountIDs: [String],
        iconOnly: Bool = false,
        demoMode: Bool = false
    ) -> String {
        if iconOnly {
            return ""
        }
        if demoMode && selectedAccountIDs.isEmpty {
            return "演示"
        }

        let chosen: [AccountSnapshot]
        if !selectedAccountIDs.isEmpty {
            let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.account.id, $0) })
            chosen = selectedAccountIDs.compactMap { byID[$0] }
        } else {
            let pinned = snapshots.filter(\.account.pinned)
            if let first = pinned.first ?? snapshots.first {
                chosen = [first]
            } else {
                chosen = []
            }
        }

        guard !chosen.isEmpty else {
            return demoMode ? "演示" : "AIQuoty"
        }
        // Keep the menu bar extra narrow: on notched displays the system hides
        // extras that overflow. Show at most `maxItems`, then a compact "+N".
        let limit = max(1, maxItems)
        let visible = chosen.prefix(limit).map(itemText(for:))
        let overflow = chosen.count - visible.count
        let joined = visible.joined(separator: " · ")
        return overflow > 0 ? "\(joined) +\(overflow)" : joined
    }

    /// Maximum number of accounts rendered as text in the menu bar.
    public static let maxItems = 3

    public static func itemText(for snapshot: AccountSnapshot) -> String {
        let name = shortName(for: snapshot.account)
        if let value = metricSummary(for: snapshot) {
            return "\(name) \(value)"
        }
        return name
    }

    public static func shortName(for account: AccountIdentity) -> String {
        switch account.providerID {
        case "antigravity": return "AGY"
        case "codex": return "Codex"
        case "copilot": return "Copilot"
        case "cursor": return "Cursor"
        case "claude": return "Claude"
        case "deepseek": return "DS"
        case "gemini": return "Gemini"
        case "opencode": return "OC"
        case "kimi-code":
            return account.id.contains("moonshot") ? "Moonshot" : "Kimi"
        case "minimax": return "MiniMax"
        case "zai": return "GLM"
        case "factory-droid": return "Droid"
        case "windsurf": return "WS"
        case "grok": return "Grok"
        case "openrouter": return "OR"
        case "anthropic-admin": return "Anthropic"
        default:
            return account.displayName
        }
    }

    private static func metricSummary(for snapshot: AccountSnapshot) -> String? {
        // 1. Subscription quota: show the highest-utilized window so tight limits surface first.
        let knownWindows = snapshot.windows.compactMap(\.usedFraction)
        if let peakUsed = knownWindows.max() {
            let pct = String(format: "%.0f%%", peakUsed * 100)
            if snapshot.windows.contains(where: { $0.freshness == .stale }) {
                return "\(pct)*"
            }
            return pct
        }

        // 2. API balance / spend: show compact currency amount from the primary metric.
        if let firstSpend = snapshot.spendMetrics.first {
            if let val = firstSpend.value {
                if firstSpend.display.contains("¥") || firstSpend.display.contains("CNY") {
                    return formatCurrency(symbol: "¥", value: val)
                }
                if firstSpend.unit == .usd || firstSpend.display.contains("$") {
                    return formatCurrency(symbol: "$", value: val)
                }
                return String(format: "%.1f", val)
            }
        }

        // 3. Local observed tokens (estimated).
        if let firstLocal = snapshot.localTokenMetrics.first, let val = firstLocal.value {
            if val >= 1_000_000 {
                return String(format: "%.1fM", val / 1_000_000)
            }
            if val >= 1_000 {
                return String(format: "%.0fk", val / 1_000)
            }
            return "\(Int(val))"
        }

        // 4. Connection status fallback.
        switch snapshot.connection {
        case .authRequired: return "授权"
        case .rateLimited: return "限流"
        case .error: return "异常"
        default: return nil
        }
    }

    private static func formatCurrency(symbol: String, value: Double) -> String {
        if value >= 100 {
            return String(format: "%@%.0f", symbol, value)
        }
        return String(format: "%@%.1f", symbol, value)
    }
}
