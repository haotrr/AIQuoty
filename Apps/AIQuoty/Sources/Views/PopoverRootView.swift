#if os(macOS)
import SwiftUI
import AppKit
import AIQuotyCore

// MARK: - Popover

struct PopoverRootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var contentHeight: CGFloat = 0

    /// Search is only useful once the list gets long; below this it's noise.
    private static let searchThreshold = 5
    private static let maxScrollHeight: CGFloat = 520

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showsSearch {
                SearchField(text: $model.searchText)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            Divider()
            ScrollView {
                content
                    .padding(12)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                        }
                    )
            }
            .frame(height: min(max(contentHeight, 120), Self.maxScrollHeight))
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            Divider()
            footer
        }
        .frame(width: 360)
        .preferredColorScheme(model.preferredColorScheme)
        .background(hiddenShortcuts)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.activeSignIn != .idle || !model.signInNotice.isEmpty {
                SignInProgressBanner()
            }
            if visibleSnapshots.isEmpty && visibleDetectedAgents.isEmpty {
                if model.searchText.isEmpty {
                    emptyState
                } else {
                    Text("没有匹配“\(model.searchText)”的账号")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            } else {
                ForEach(groupedKeys, id: \.self) { group in
                    if !group.isEmpty {
                        SectionHeader(title: group)
                    }
                    ForEach(snapshots(in: group)) { snap in
                        AccountCard(
                            snapshot: snap,
                            inMenuBar: model.isShownInMenuBar(snap.account.id),
                            onToggleMenuBar: { model.toggleMenuBarAccount(snap.account.id) },
                            onPin: { model.togglePin(snap.account.id) },
                            reauthTitle: model.signInActionTitle(for: snap.account.providerID),
                            onReauth: { model.startOneClickSignIn(providerID: snap.account.providerID) },
                            onRetry: { Task { await model.refresh(force: true) } },
                            onOpenSettings: openSettingsAndActivate
                        )
                    }
                }

                if !model.preferences.demoMode && !visibleDetectedAgents.isEmpty {
                    SectionHeader(title: "本机已检测到（待连接）")
                        .padding(.top, visibleSnapshots.isEmpty ? 0 : 4)
                    ForEach(visibleDetectedAgents) { agent in
                        DetectedAgentCard(
                            agent: agent,
                            oneClickTitle: model.signInActionTitle(for: agent.providerID),
                            onOneClick: { model.startOneClickSignIn(providerID: agent.providerID) },
                            onConfigure: openSettingsAndActivate
                        )
                    }
                }
            }
        }
    }

    private var showsSearch: Bool {
        !model.searchText.isEmpty
            || model.state.snapshots.count + unconfiguredDetectedAgents.count >= Self.searchThreshold
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

    private var unconfiguredDetectedAgents: [DetectedLocalAgent] {
        let activeProviderIDs = Set(model.state.snapshots.map(\.account.providerID))
        return model.detectedAgents.filter { !activeProviderIDs.contains($0.providerID) }
    }

    private var visibleDetectedAgents: [DetectedLocalAgent] {
        let q = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return unconfiguredDetectedAgents }
        return unconfiguredDetectedAgents.filter {
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
                return lhs.account.displayName.localizedStandardCompare(rhs.account.displayName) == .orderedAscending
            }
    }

    // MARK: Header / Footer

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("AIQuoty")
                    .font(.headline)
                Text(model.preferences.demoMode ? "演示模式 · 合成数据" : "本机配额一览")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.refresh(force: true) }
            } label: {
                Group {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(model.isRefreshing)
            .help("立即刷新（⌘R）")
            .keyboardShortcut("r", modifiers: [.command])
            .accessibilityLabel("刷新")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(model.preferences.demoMode ? "演示数据加载中…" : "尚未连接任何服务")
                .font(.headline)
            Text("连接 Claude、Codex、Cursor、Antigravity 等 Agent 后即可在这里查看配额。密钥只保存在钥匙串中。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("打开设置…") { openSettingsAndActivate() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 8)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(statusLine(now: context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Menu {
                Button("打开仪表盘…") { openDashboardAndActivate() }
                    .keyboardShortcut("d", modifiers: [.command])
                Button("设置…") { openSettingsAndActivate() }
                    .keyboardShortcut(",", modifiers: [.command])
                Divider()
                Button("退出 AIQuoty") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: [.command])
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多")
            .accessibilityLabel("更多操作")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Keeps ⌘D / ⌘, / ⌘Q working while the popover is key, even when the menu is closed.
    private var hiddenShortcuts: some View {
        Group {
            Button("") { openDashboardAndActivate() }.keyboardShortcut("d", modifiers: [.command])
            Button("") { openSettingsAndActivate() }.keyboardShortcut(",", modifiers: [.command])
            Button("") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: [.command])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func statusLine(now: Date) -> String {
        var parts: [String] = []
        if !model.statusMessage.isEmpty { parts.append(model.statusMessage) }
        if let last = model.state.lastRefreshAt {
            parts.append("更新于 \(last.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
        }
        return parts.joined(separator: " · ")
    }

    private func openDashboardAndActivate() {
        openWindow(id: "dashboard")
        AppWindowActivator.activateWindow(identifierHint: "dashboard")
    }

    private func openSettingsAndActivate() {
        openSettings()
        AppWindowActivator.activateWindow(identifierHint: "Settings")
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .padding(.leading, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("筛选账号或服务", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除")
                .accessibilityLabel("清除筛选")
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("筛选")
    }
}

// MARK: - Sign-in banner

struct SignInProgressBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.activeSignIn {
            case .githubDevice(let userCode, let uri):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("GitHub 授权码").font(.callout.weight(.medium))
                    Text(userCode)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                    Spacer()
                    Button("复制") { CLILoginSpec.copyToClipboard(userCode) }
                    if let url = URL(string: uri) {
                        Button("打开网页") { NSWorkspace.shared.open(url) }
                    }
                    Button("取消") { model.cancelSignIn() }
                }
                .controlSize(.small)
            case .googleBrowser(let name):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在等待浏览器完成 \(name) 授权…")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button("取消") { model.cancelSignIn() }
                        .controlSize(.small)
                }
            case .idle:
                EmptyView()
            }
            if !model.signInNotice.isEmpty {
                HStack(alignment: .top) {
                    Text(model.signInNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer()
                    if model.activeSignIn == .idle {
                        Button {
                            model.signInNotice = ""
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("关闭")
                        .accessibilityLabel("关闭提示")
                    }
                }
            }
        }
        .padding(10)
        .background(Palette.spend.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Detected agent

struct DetectedAgentCard: View {
    let agent: DetectedLocalAgent
    var oneClickTitle: String? = nil
    var onOneClick: (() -> Void)? = nil
    var onConfigure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.displayName)
                        .font(.body.weight(.semibold))
                    Text(agent.category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let oneClickTitle, let onOneClick {
                    Button(oneClickTitle, action: onOneClick)
                        .buttonStyle(.borderedProminent)
                }
                Button("配置…", action: onConfigure)
            }
            .controlSize(.small)
            Text(agent.setupHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Palette.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Account card

struct AccountCard: View {
    let snapshot: AccountSnapshot
    var inMenuBar: Bool = false
    var onToggleMenuBar: (() -> Void)? = nil
    var onPin: () -> Void
    var reauthTitle: String? = nil
    var onReauth: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    /// Dashboard shows every window; the popover collapses to the tightest one.
    var alwaysExpanded: Bool = false

    @State private var isHovering = false
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow

            if !hasMetrics {
                problemView
            } else {
                ForEach(displayedWindows) { window in
                    QuotaBar(window: window)
                }
                if hiddenWindowCount > 0 || (isExpanded && snapshot.windows.count > 1 && !alwaysExpanded) {
                    expandToggle
                }
                ForEach(Array(snapshot.spendMetrics.enumerated()), id: \.offset) { _, metric in
                    MetricRow(metric: metric)
                }
                ForEach(Array(snapshot.localTokenMetrics.enumerated()), id: \.offset) { _, metric in
                    MetricRow(metric: metric)
                }
                freshnessFooter
            }
        }
        .padding(10)
        .background(Palette.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovering = $0 }
        .contextMenu { contextMenuItems }
        .accessibilityElement(children: .contain)
    }

    private var hasMetrics: Bool {
        !snapshot.windows.isEmpty || !snapshot.spendMetrics.isEmpty || !snapshot.localTokenMetrics.isEmpty
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(snapshot.account.displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    // "Connected" is the normal state — only surface a badge when something is off.
                    if snapshot.connection != .connected {
                        ConnectionBadge(state: snapshot.connection)
                    }
                }
                let subtitle = [snapshot.account.planLabel, snapshot.account.email].compactMap { $0 }
                if !subtitle.isEmpty {
                    Text(subtitle.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                if let onToggleMenuBar, isHovering || inMenuBar {
                    CardIconButton(
                        systemName: "menubar.rectangle",
                        isActive: inMenuBar,
                        help: inMenuBar ? "已显示在菜单栏（点击移除）" : "在菜单栏中显示",
                        action: onToggleMenuBar
                    )
                }
                if isHovering || snapshot.account.pinned {
                    CardIconButton(
                        systemName: snapshot.account.pinned ? "pin.fill" : "pin",
                        isActive: snapshot.account.pinned,
                        help: snapshot.account.pinned ? "取消置顶" : "置顶",
                        action: onPin
                    )
                }
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button(snapshot.account.pinned ? "取消置顶" : "置顶", action: onPin)
        if let onToggleMenuBar {
            Button(inMenuBar ? "从菜单栏移除" : "在菜单栏中显示", action: onToggleMenuBar)
        }
        if let onRetry {
            Divider()
            Button("刷新", action: onRetry)
        }
    }

    // MARK: Windows

    /// Highest-utilisation window first so the tightest limit is what you see collapsed.
    private var sortedWindows: [QuotaWindow] {
        snapshot.windows.enumerated().sorted { a, b in
            let ua = a.element.usedFraction ?? -1
            let ub = b.element.usedFraction ?? -1
            if ua != ub { return ua > ub }
            return a.offset < b.offset
        }.map(\.element)
    }

    private var displayedWindows: [QuotaWindow] {
        if alwaysExpanded || isExpanded { return snapshot.windows }
        return Array(sortedWindows.prefix(1))
    }

    private var hiddenWindowCount: Int {
        snapshot.windows.count - displayedWindows.count
    }

    private var expandToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(isExpanded ? "收起" : "显示全部 \(snapshot.windows.count) 个配额窗口")
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Problems

    @ViewBuilder
    private var problemView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(problemTitle, systemImage: problemSymbol)
                .font(.callout)
                .foregroundStyle(problemTint)
            if let detail = snapshot.lastError, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(detail)
                    .textSelection(.enabled)
            }
            problemActions
        }
    }

    @ViewBuilder
    private var problemActions: some View {
        HStack(spacing: 6) {
            switch snapshot.connection {
            case .authRequired:
                if let reauthTitle, let onReauth {
                    Button(reauthTitle == "一键登录" ? "重新授权" : "终端登录", action: onReauth)
                        .buttonStyle(.borderedProminent)
                }
                if let onOpenSettings {
                    Button("打开设置…", action: onOpenSettings)
                }
            case .error, .rateLimited:
                if let onRetry {
                    Button("重试", action: onRetry)
                }
            case .disconnected:
                if let onOpenSettings {
                    Button("配置…", action: onOpenSettings)
                }
            default:
                EmptyView()
            }
        }
        .controlSize(.small)
    }

    private var problemTitle: String {
        switch snapshot.connection {
        case .authRequired: return "登录已失效，需要重新授权"
        case .rateLimited: return "请求过于频繁，稍后会自动重试"
        case .error: return "暂时无法获取用量"
        case .unsupported: return "该服务暂不支持用量查询"
        case .disconnected: return "尚未连接"
        case .connecting: return "正在连接…"
        case .connected: return "暂无可用指标"
        }
    }

    private var problemSymbol: String {
        switch snapshot.connection {
        case .authRequired: return "person.crop.circle.badge.exclamationmark"
        case .rateLimited: return "hourglass"
        case .error: return "exclamationmark.triangle"
        default: return "info.circle"
        }
    }

    private var problemTint: Color {
        switch snapshot.connection {
        case .authRequired, .rateLimited: return Palette.warn
        case .error: return Palette.bad
        default: return .secondary
        }
    }

    @ViewBuilder
    private var freshnessFooter: some View {
        let isStale = snapshot.windows.contains { $0.freshness == .stale }
        if isStale || snapshot.lastError != nil {
            HStack(spacing: 4) {
                Image(systemName: isStale ? "clock.arrow.circlepath" : "exclamationmark.triangle")
                Text(isStale ? "显示的是上次成功获取的数据" : "最近一次刷新失败")
                if let onRetry {
                    Spacer()
                    Button("重试", action: onRetry)
                        .buttonStyle(.link)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(snapshot.lastError ?? "数据已过期")
        }
    }
}

struct CardIconButton: View {
    let systemName: String
    var isActive: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.callout)
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Quota bar

struct QuotaBar: View {
    let window: QuotaWindow
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(window.title)
                    .font(.callout)
                Spacer()
                if let symbol = severitySymbol {
                    Image(systemName: symbol)
                        .font(.caption)
                        .foregroundStyle(usageTint)
                        .accessibilityHidden(true)
                }
                Text(valueText)
                    .font(.callout.monospacedDigit().weight(.medium))
                    .foregroundStyle(window.freshness == .stale ? .secondary : .primary)
            }
            if let used = window.usedFraction {
                ProgressView(value: min(max(used, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(usageTint)
                    .animation(.easeInOut(duration: 0.35), value: used)
            } else {
                Capsule()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.tertiary)
                    .frame(height: 5)
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(resetText(now: context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help("来源：\(window.source.label)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.title)
        .accessibilityValue("已用 \(valueText)，\(resetText(now: Date()))")
    }

    private var valueText: String {
        window.usedDisplay.precision == .unknown ? "未知" : window.usedDisplay.display
    }

    private var usageTint: Color {
        Palette.usageColor(usedFraction: window.usedFraction ?? 0)
    }

    /// Never rely on colour alone: critical usage always gets a glyph; with
    /// "Differentiate without colour" every elevated level does.
    private var severitySymbol: String? {
        guard let used = window.usedFraction else { return nil }
        if used >= 0.9 { return "exclamationmark.triangle.fill" }
        if differentiateWithoutColor && used >= 0.6 { return "exclamationmark.circle" }
        return nil
    }

    private func resetText(now: Date) -> String {
        guard window.resetKnown, let seconds = window.secondsUntilReset(now: now) else { return "重置时间未知" }
        if seconds <= 0 { return "已到重置时间，等待刷新" }
        return "\(CountdownFormatter.format(seconds: seconds)) 后重置"
    }
}

// MARK: - Metric row

struct MetricRow: View {
    let metric: MetricValue

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(metric.display)
                .font(.callout.monospacedDigit())
            Spacer()
            if metric.precision == .estimated {
                Text("估算")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help("\(metric.kind.displayLabel) · 来源：\(metric.source.label)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.kind.displayLabel)：\(metric.display)")
    }

    private var symbol: String {
        switch metric.kind {
        case .apiSpend: return "creditcard"
        case .locallyObservedTokens: return "internaldrive"
        case .subscriptionQuota: return "gauge.with.dots.needle.33percent"
        }
    }

    private var tint: Color {
        switch metric.kind {
        case .apiSpend: return Palette.spend
        case .locallyObservedTokens: return Palette.local
        case .subscriptionQuota: return .secondary
        }
    }
}

extension MetricKind {
    var displayLabel: String {
        switch self {
        case .apiSpend: return "API 花费 / 余额"
        case .locallyObservedTokens: return "本机日志估算 Token"
        case .subscriptionQuota: return "订阅配额"
        }
    }
}

// MARK: - Badges & palette

struct ConnectionBadge: View {
    let state: ConnectionState
    var body: some View {
        StatusBadge(text: label, tint: color)
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

struct StatusBadge: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// Semantic system colours so light / dark / Increase Contrast all adapt automatically.
enum Palette {
    static let cardFill = Color(nsColor: .quaternarySystemFill)
    static let good = Color.green
    static let caution = Color.yellow
    static let warn = Color.orange
    static let bad = Color.red
    static let spend = Color.blue
    static let local = Color.purple

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
