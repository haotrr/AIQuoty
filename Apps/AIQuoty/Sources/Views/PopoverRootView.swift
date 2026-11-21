#if os(macOS)
import SwiftUI
import AIQuotyCore

struct PopoverRootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.35)
            searchBar
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if visibleSnapshots.isEmpty {
                        emptyState
                    } else {
                        ForEach(groupedKeys, id: \.self) { group in
                            if let title = groupTitle(group) {
                                Text(title.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                            }
                            ForEach(snapshots(in: group)) { snap in
                                AccountCard(snapshot: snap) {
                                    model.togglePin(snap.account.id)
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
            Divider().opacity(0.35)
            footer
        }
        .frame(width: 360, height: 480)
        .background(Palette.popoverBackground)
        .preferredColorScheme(colorScheme)
    }

    private var colorScheme: ColorScheme? {
        switch model.preferences.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private var visibleSnapshots: [AccountSnapshot] {
        let q = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = model.state.snapshots
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.account.displayName.lowercased().contains(q)
                || ($0.account.email?.lowercased().contains(q) ?? false)
                || $0.account.providerID.lowercased().contains(q)
                || ($0.account.group?.lowercased().contains(q) ?? false)
        }
    }

    private var groupedKeys: [String] {
        let keys = Set(visibleSnapshots.map { $0.account.group ?? "" })
        // Named groups first (A–Z), then ungrouped ("").
        return keys.sorted { a, b in
            if a.isEmpty { return false }
            if b.isEmpty { return true }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    private func snapshots(in group: String) -> [AccountSnapshot] {
        visibleSnapshots.filter { ($0.account.group ?? "") == group }
            .sorted { lhs, rhs in
                if lhs.account.pinned != rhs.account.pinned { return lhs.account.pinned && !rhs.account.pinned }
                return lhs.account.displayName < rhs.account.displayName
            }
    }

    private func groupTitle(_ group: String) -> String? {
        group.isEmpty ? nil : group
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AIQuoty")
                    .font(.system(.title3, design: .serif).weight(.semibold))
                Text(model.preferences.demoMode ? "演示模式 · 合成数据" : "本机配额一览")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("立即刷新")
            .keyboardShortcut("r", modifiers: [.command])
            .accessibilityLabel("刷新")
        }
        .padding(12)
    }

    private var searchBar: some View {
        TextField("筛选账号 / 服务", text: $model.searchText)
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .accessibilityLabel("筛选")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.preferences.demoMode ? "演示数据加载中…" : "尚未连接任何服务")
                .font(.headline)
            Text("在设置中配置 Claude / Codex / Cursor / Gemini 等来源。密钥只写入钥匙串，不要粘贴到聊天里。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("打开设置") { openSettings() }
                .keyboardShortcut(",", modifiers: [.command])
        }
        .padding(.vertical, 24)
    }

    private var footer: some View {
        HStack {
            Text(statusLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("仪表盘") { openWindow(id: "dashboard") }
            Button("设置") { openSettings() }
        }
        .padding(10)
    }

    private var statusLine: String {
        var parts: [String] = [model.statusMessage]
        if let last = model.state.lastRefreshAt {
            parts.append("更新于 \(relative(last))")
        }
        if model.preferences.demoMode {
            parts.append("演示")
        }
        return parts.joined(separator: " · ")
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

struct AccountCard: View {
    let snapshot: AccountSnapshot
    var onPin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.account.displayName)
                        .font(.system(.body, design: .default).weight(.semibold))
                    HStack(spacing: 6) {
                        ConnectionBadge(state: snapshot.connection)
                        if let plan = snapshot.account.planLabel {
                            Text(plan).font(.caption2).foregroundStyle(.secondary)
                        }
                        if let email = snapshot.account.email {
                            Text(email).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                }
                Spacer()
                Button(action: onPin) {
                    Image(systemName: snapshot.account.pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(snapshot.account.pinned ? "取消置顶" : "置顶")
            }

            if snapshot.windows.isEmpty && snapshot.spendMetrics.isEmpty && snapshot.localTokenMetrics.isEmpty {
                Text(snapshot.lastError ?? "无可用指标（保持未知）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(snapshot.windows) { window in
                QuotaBar(window: window)
            }
            ForEach(Array(snapshot.spendMetrics.enumerated()), id: \.offset) { _, metric in
                MetricRow(metric: metric, tint: Palette.spend)
            }
            ForEach(Array(snapshot.localTokenMetrics.enumerated()), id: \.offset) { _, metric in
                MetricRow(metric: metric, tint: Palette.local)
            }
            if snapshot.freshnessHint != nil {
                Text(snapshot.freshnessHint!)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(Palette.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private extension AccountSnapshot {
    var freshnessHint: String? {
        if windows.contains(where: { $0.freshness == .stale }) {
            return "显示上次成功数据（已过期）"
        }
        return lastError
    }
}

struct QuotaBar: View {
    let window: QuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.title)
                    .font(.caption.weight(.medium))
                Spacer()
                Text(window.usedDisplay.precision == .unknown ? "未知" : window.usedDisplay.display)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(window.freshness == .stale ? .secondary : .primary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if let used = window.usedFraction {
                        Capsule()
                            .fill(Palette.usageColor(usedFraction: used))
                            .frame(width: max(4, geo.size.width * used))
                            .animation(.easeInOut(duration: 0.35), value: used)
                    }
                }
            }
            .frame(height: 6)
            HStack {
                Text(window.resetKnown ? "重置 \(CountdownFormatter.format(seconds: window.secondsUntilReset()))" : "重置未知")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(window.source.label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.title) 已用 \(window.usedDisplay.display)，\(window.resetKnown ? CountdownFormatter.format(seconds: window.secondsUntilReset()) : "重置未知")")
    }
}

struct MetricRow: View {
    let metric: MetricValue
    var tint: Color

    var body: some View {
        HStack {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(metric.display)
                .font(.caption)
            Spacer()
            Text(metric.kind.rawValue)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

struct ConnectionBadge: View {
    let state: ConnectionState
    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch state {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .authRequired: return "需授权"
        case .rateLimited: return "限流"
        case .error: return "错误"
        case .disconnected: return "未连接"
        case .unsupported: return "未实现"
        }
    }

    private var color: Color {
        switch state {
        case .connected: return Palette.good
        case .connecting: return .secondary
        case .authRequired: return Palette.warn
        case .rateLimited: return Palette.warn
        case .error: return Palette.bad
        case .disconnected, .unsupported: return .secondary
        }
    }
}

enum Palette {
    static let popoverBackground = Color(nsColor: .windowBackgroundColor)
    static let cardFill = Color.primary.opacity(0.04)
    static let good = Color(red: 0.20, green: 0.55, blue: 0.40)
    static let caution = Color(red: 0.75, green: 0.55, blue: 0.15)
    static let warn = Color(red: 0.85, green: 0.40, blue: 0.15)
    static let bad = Color(red: 0.75, green: 0.22, blue: 0.20)
    static let spend = Color(red: 0.25, green: 0.40, blue: 0.65)
    static let local = Color(red: 0.45, green: 0.40, blue: 0.55)

    static func usageColor(usedFraction: Double) -> Color {
        switch usedFraction {
        case ..<0.60: return good
        case ..<0.80: return caution
        case ..<0.90: return warn
        default: return bad
        }
    }
}
#endif
