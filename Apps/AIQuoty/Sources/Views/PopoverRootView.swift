#if os(macOS)
import SwiftUI
import AppKit
import AIQuotyCore

struct PopoverRootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var showMenuBarPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showMenuBarPicker {
                Divider().opacity(0.35)
                MenuBarAccountPickerPanel()
            }
            Divider().opacity(0.35)
            searchBar
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.activeSignIn != .idle || !model.signInNotice.isEmpty {
                        SignInProgressBanner()
                    }
                    if visibleSnapshots.isEmpty && visibleDetectedAgents.isEmpty {
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
                                AccountCard(
                                    snapshot: snap,
                                    inMenuBar: model.isShownInMenuBar(snap.account.id),
                                    onToggleMenuBar: {
                                        model.toggleMenuBarAccount(snap.account.id)
                                    },
                                    onPin: {
                                        model.togglePin(snap.account.id)
                                    }
                                )
                            }
                        }

                        if !model.preferences.demoMode && !visibleDetectedAgents.isEmpty {
                            Text("本机已检测到（待连接）")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, visibleSnapshots.isEmpty ? 0 : 6)

                            ForEach(visibleDetectedAgents) { agent in
                                DetectedAgentCard(
                                    agent: agent,
                                    oneClickTitle: oneClickLabel(for: agent.providerID),
                                    onOneClick: {
                                        model.startOneClickSignIn(providerID: agent.providerID)
                                    },
                                    onConfigure: {
                                        openSettingsAndActivate()
                                    }
                                )
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
        .preferredColorScheme(model.preferredColorScheme)
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

    private var visibleDetectedAgents: [DetectedLocalAgent] {
        let activeProviderIDs = Set(model.state.snapshots.map(\.account.providerID))
        let unconfigured = model.detectedAgents.filter { !activeProviderIDs.contains($0.providerID) }
        let q = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return unconfigured }
        return unconfigured.filter {
            $0.displayName.lowercased().contains(q)
                || $0.providerID.lowercased().contains(q)
                || $0.category.lowercased().contains(q)
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

    private func oneClickLabel(for providerID: String) -> String? {
        if model.supportsOneClickSignIn(providerID: providerID) {
            return "一键登录"
        }
        if CLILoginSpec.entry(for: providerID) != nil {
            return "终端登录"
        }
        return nil
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AIQuoty")
                    .font(.system(.title3, design: .serif).weight(.semibold))
                Text(model.preferences.demoMode ? "演示模式 · 合成数据" : "本机配额一览")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showMenuBarPicker.toggle()
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "menubar.rectangle")
                    if !model.preferences.menuBarAccountIDs.isEmpty && !model.preferences.menuBarIconOnly {
                        Text("\(model.preferences.menuBarAccountIDs.count)")
                            .font(.caption2.monospacedDigit())
                    }
                }
            }
            .foregroundStyle(showMenuBarPicker ? Color.accentColor : Color.primary)
            .help("选择顶部菜单栏展示的账号")
            .accessibilityLabel("选择菜单栏展示账号")

            Button {
                Task { await model.refresh(force: true) }
            } label: {
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(model.isRefreshing)
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
            Text("在设置中配置 Claude / Codex / Cursor / Antigravity / OpenCode / DeepSeek / Kimi 等主流 Agent 来源。密钥仅写入钥匙串。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("打开设置") { openSettingsAndActivate() }
                .keyboardShortcut(",", modifiers: [.command])
        }
        .padding(.vertical, 24)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(statusLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("仪表盘") { openDashboardAndActivate() }
                .controlSize(.small)
            Button("设置") { openSettingsAndActivate() }
                .controlSize(.small)
            Button("退出") { NSApp.terminate(nil) }
                .controlSize(.small)
                .keyboardShortcut("q", modifiers: [.command])
        }
        .padding(10)
    }

    private func openDashboardAndActivate() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "dashboard")
        AppWindowActivator.activateWindow(matchingTitle: "仪表盘", identifierHint: "dashboard")
    }

    private func openSettingsAndActivate() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        AppWindowActivator.activateWindow(matchingTitle: "设置", identifierHint: "Settings")
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

struct SignInProgressBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.activeSignIn {
            case .githubDevice(let userCode, let uri):
                HStack {
                    ProgressView().controlSize(.small)
                    Text("GitHub 授权码：").font(.caption.weight(.semibold))
                    Text(userCode)
                        .font(.system(.callout, design: .monospaced).weight(.bold))
                        .textSelection(.enabled)
                    Spacer()
                    Button("复制") { CLILoginSpec.copyToClipboard(userCode) }
                        .controlSize(.mini)
                    if let url = URL(string: uri) {
                        Button("打开") { NSWorkspace.shared.open(url) }
                            .controlSize(.mini)
                    }
                    Button("取消") { model.cancelSignIn() }
                        .controlSize(.mini)
                }
            case .googleBrowser(let name):
                HStack {
                    ProgressView().controlSize(.small)
                    Text("等待浏览器完成 \(name) 授权…")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("取消") { model.cancelSignIn() }
                        .controlSize(.mini)
                }
            case .idle:
                EmptyView()
            }
            if !model.signInNotice.isEmpty {
                HStack(alignment: .top) {
                    Text(model.signInNotice)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if model.activeSignIn == .idle {
                        Button {
                            model.signInNotice = ""
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(10)
        .background(Palette.spend.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct DetectedAgentCard: View {
    let agent: DetectedLocalAgent
    var oneClickTitle: String? = nil
    var onOneClick: (() -> Void)? = nil
    var onConfigure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.displayName)
                        .font(.system(.callout, design: .default).weight(.semibold))
                    HStack(spacing: 6) {
                        Text("已检测")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Palette.spend.opacity(0.14), in: Capsule())
                            .foregroundStyle(Palette.spend)
                        Text(agent.category)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let oneClickTitle, let onOneClick {
                    Button(oneClickTitle, action: onOneClick)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Button("配置", action: onConfigure)
                    .controlSize(.small)
            }
            Text(agent.setupHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Palette.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct MenuBarAccountPickerPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("菜单栏展示账号")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("自动") { model.resetMenuBarToAuto() }
                    .controlSize(.mini)
                    .disabled(!model.preferences.menuBarIconOnly && model.preferences.menuBarAccountIDs.isEmpty)
                Button("全选") { model.selectAllMenuBarAccounts() }
                    .controlSize(.mini)
                    .disabled(model.state.snapshots.isEmpty)
                Button(model.preferences.menuBarIconOnly ? "显示文字" : "仅图标") {
                    model.setMenuBarIconOnly(!model.preferences.menuBarIconOnly)
                }
                .controlSize(.mini)
            }

            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.caption2)
                Text(model.menuBarSummary.isEmpty ? "（仅显示图标）" : model.menuBarSummary)
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.cardFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            if model.state.snapshots.isEmpty {
                Text("暂无已连接账号")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.state.snapshots) { snap in
                        Toggle(isOn: Binding(
                            get: { model.isShownInMenuBar(snap.account.id) },
                            set: { _ in model.toggleMenuBarAccount(snap.account.id) }
                        )) {
                            HStack {
                                Text(snap.account.displayName)
                                    .font(.caption)
                                Spacer()
                                Text(MenuBarFormatter.itemText(for: snap))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Palette.cardFill.opacity(0.6))
    }
}

struct AccountCard: View {
    let snapshot: AccountSnapshot
    var inMenuBar: Bool = false
    var onToggleMenuBar: (() -> Void)? = nil
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
                if let onToggleMenuBar {
                    Button(action: onToggleMenuBar) {
                        Image(systemName: "menubar.rectangle")
                            .foregroundStyle(inMenuBar ? Color.accentColor : Color.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help(inMenuBar ? "已显示在顶部菜单栏（点击取消）" : "在顶部菜单栏显示此账号")
                    .accessibilityLabel(inMenuBar ? "从菜单栏移除" : "显示在菜单栏")
                }
                Button(action: onPin) {
                    Image(systemName: snapshot.account.pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(snapshot.account.pinned ? "取消置顶" : "置顶")
            }

            let hasMetrics = !snapshot.windows.isEmpty || !snapshot.spendMetrics.isEmpty || !snapshot.localTokenMetrics.isEmpty
            if !hasMetrics {
                Text(snapshot.lastError ?? "无可用指标（保持未知）")
                    .font(.caption)
                    .foregroundStyle(snapshot.lastError != nil ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            if hasMetrics, let hint = snapshot.freshnessHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
