#if os(macOS)
import SwiftUI
import AppKit
import AIQuotyCore

// MARK: - Popover

enum SnapshotFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case quota = "配额"
    case spend = "API"
    case local = "日志"

    var id: String { rawValue }

    func matches(_ snap: AccountSnapshot) -> Bool {
        switch self {
        case .all: return true
        case .quota: return !snap.windows.isEmpty
        case .spend: return !snap.spendMetrics.isEmpty
        case .local: return !snap.localTokenMetrics.isEmpty
        }
    }
}

struct PopoverRootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var contentHeight: CGFloat = 0
    @State private var filter: SnapshotFilter = .all

    /// Search is only useful once the list gets long; below this it's noise.
    private static let searchThreshold = 5
    private static let maxScrollHeight: CGFloat = 600

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showsFilterBar || showsSearch {
                filterAndSearchBar
            }
            Divider()
            ScrollView {
                content
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
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
        .frame(width: 396)
        .preferredColorScheme(model.preferredColorScheme)
        .background(hiddenShortcuts)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 5) {
            if model.activeSignIn != .idle || !model.signInNotice.isEmpty {
                SignInProgressBanner()
            }
            if visibleSnapshots.isEmpty {
                if model.searchText.isEmpty && filter == .all {
                    emptyState
                } else {
                    Text(model.searchText.isEmpty ? "当前分类下暂无账号" : "没有匹配“\(model.searchText)”的账号")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
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
                            onHideFromHome: { model.setShownOnHome(snap.account.id, shown: false) },
                            onPin: { model.togglePin(snap.account.id) },
                            reauthTitle: model.signInActionTitle(for: snap.account.providerID),
                            onReauth: { model.startOneClickSignIn(providerID: snap.account.providerID) },
                            onRetry: { Task { await model.refresh(force: true) } },
                            onOpenSettings: openSettingsAndActivate
                        )
                    }
                }
            }
        }
    }

    private var availableFilters: [SnapshotFilter] {
        let base = model.homeSnapshots
        var result: [SnapshotFilter] = [.all]
        if base.contains(where: { !$0.windows.isEmpty }) { result.append(.quota) }
        if base.contains(where: { !$0.spendMetrics.isEmpty }) { result.append(.spend) }
        if base.contains(where: { !$0.localTokenMetrics.isEmpty }) { result.append(.local) }
        return result
    }

    private var showsFilterBar: Bool {
        availableFilters.count > 2
    }

    private var showsSearch: Bool {
        !model.searchText.isEmpty
            || model.homeSnapshots.count >= Self.searchThreshold
    }

    private var filterAndSearchBar: some View {
        HStack(spacing: 6) {
            if showsFilterBar {
                HStack(spacing: 2) {
                    ForEach(availableFilters) { item in
                        let selected = filter == item
                        Button {
                            filter = item
                        } label: {
                            Text(item.rawValue)
                                .font(.caption2.weight(selected ? .semibold : .regular))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    selected ? Color.accentColor.opacity(0.18) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                                )
                                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            if showsSearch {
                SearchField(text: $model.searchText)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private var visibleSnapshots: [AccountSnapshot] {
        let q = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = model.homeSnapshots.filter { filter.matches($0) }
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
                return lhs.account.displayName.localizedStandardCompare(rhs.account.displayName) == .orderedAscending
            }
    }

    // MARK: Header / Footer

    private var header: some View {
        let total = model.homeSnapshots.count
        let hotCount = model.homeSnapshots.filter { snap in
            snap.windows.contains { ($0.usedFraction ?? 0) >= 0.80 }
        }.count
        let peakFraction = model.homeSnapshots
            .flatMap(\.windows)
            .compactMap(\.usedFraction)
            .max()

        return HStack(alignment: .center, spacing: 6) {
            Text("AIQuoty")
                .font(.subheadline.weight(.semibold))
            if model.preferences.demoMode {
                StatusBadge(text: "演示", tint: Palette.spend)
            } else if total > 0 {
                HStack(spacing: 4) {
                    Text("\(total) 项")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if hotCount > 0 {
                        StatusBadge(text: "\(hotCount) 预警", tint: Palette.warn)
                    } else if let peak = peakFraction {
                        Text("峰值 \(Int((peak * 100).rounded()))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Palette.usageColor(usedFraction: peak))
                    }
                }
            }
            Spacer(minLength: 4)
            menuBarPickerMenu
            Button {
                openDashboardAndActivate()
            } label: {
                Image(systemName: "rectangle.grid.2x2")
                    .font(.caption)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("打开仪表盘（⌘D）")
            .accessibilityLabel("打开仪表盘")
            Button {
                Task { await model.refresh(force: true) }
            } label: {
                Group {
                    if model.isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                }
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(model.isRefreshing)
            .help("立即刷新（⌘R）")
            .keyboardShortcut("r", modifiers: [.command])
            .accessibilityLabel("刷新")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var menuBarPickerMenu: some View {
        let isAuto = !model.preferences.menuBarIconOnly && model.preferences.menuBarAccountIDs.isEmpty
        let customCount = model.preferences.menuBarIconOnly ? 0 : model.preferences.menuBarAccountIDs.count

        return Menu {
            Section("菜单栏展示") {
                if model.state.snapshots.isEmpty {
                    Text("暂无已连接账号")
                } else {
                    ForEach(model.state.snapshots) { snap in
                        Toggle(isOn: Binding(
                            get: { model.isShownInMenuBar(snap.account.id) },
                            set: { _ in model.toggleMenuBarAccount(snap.account.id) }
                        )) {
                            Text("\(snap.account.displayName) · \(MenuBarFormatter.itemText(for: snap))")
                        }
                    }
                }
            }
            Divider()
            Toggle("自动（跟随置顶）", isOn: Binding(
                get: { isAuto },
                set: { if $0 { model.resetMenuBarToAuto() } }
            ))
            Button("全部选择") { model.selectAllMenuBarAccounts() }
                .disabled(model.state.snapshots.isEmpty)
            Toggle("仅显示图标", isOn: Binding(
                get: { model.preferences.menuBarIconOnly },
                set: { model.setMenuBarIconOnly($0) }
            ))
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "menubar.rectangle")
                if customCount > 0 {
                    Text("\(customCount)")
                        .font(.caption.monospacedDigit())
                }
            }
            .foregroundStyle(customCount > 0 ? Color.accentColor : Color.primary)
            .frame(minWidth: 22, minHeight: 22)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("选择菜单栏展示的 Agent 信息")
        .accessibilityLabel("选择菜单栏展示的 Agent")
    }

    private var hasHiddenItems: Bool {
        !model.state.snapshots.isEmpty
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: hasHiddenItems ? "eye.slash" : "gauge.with.dots.needle.33percent")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            if hasHiddenItems {
                Text("主页已隐藏所有账号")
                    .font(.headline)
                Text("可在「设置 → 通用 → 主页显示」中重新勾选要在主页展示的账号。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("显示全部") {
                        model.showAllHomeAccounts()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("打开设置…") { openSettingsAndActivate() }
                }
                .padding(.top, 2)
            } else {
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
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 8)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(statusLine(now: context.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            Button {
                openSettingsAndActivate()
            } label: {
                Image(systemName: "gearshape")
                    .font(.caption)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("设置（⌘,）")
            .accessibilityLabel("设置")
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
                    .font(.caption)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多")
            .accessibilityLabel("更多操作")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.top, 3)
            .padding(.leading, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("筛选", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除")
                .accessibilityLabel("清除筛选")
            }
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
    var onHideFromHome: (() -> Void)? = nil
    var onPin: () -> Void
    var reauthTitle: String? = nil
    var onReauth: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    /// Dashboard shows every window; the popover shows up to 2 inline (e.g. 5h + 7d) before collapsing.
    var alwaysExpanded: Bool = false

    private static let collapsedWindowLimit = 2

    @State private var isHovering = false
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            headerRow

            if !hasMetrics {
                problemView
            } else {
                if !displayedWindows.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(displayedWindows) { window in
                            QuotaBar(window: window)
                        }
                    }
                }
                if hiddenWindowCount > 0 || (isExpanded && snapshot.windows.count > Self.collapsedWindowLimit && !alwaysExpanded) {
                    expandToggle
                }
                if !snapshot.spendMetrics.isEmpty || !snapshot.localTokenMetrics.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(snapshot.spendMetrics.enumerated()), id: \.offset) { _, metric in
                            MetricRow(metric: metric)
                        }
                        ForEach(Array(snapshot.localTokenMetrics.enumerated()), id: \.offset) { _, metric in
                            MetricRow(metric: metric)
                        }
                    }
                }
                freshnessFooter
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Palette.cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(isHovering ? 0.12 : 0.06), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .contextMenu { contextMenuItems }
        .accessibilityElement(children: .contain)
    }

    private var hasMetrics: Bool {
        !snapshot.windows.isEmpty || !snapshot.spendMetrics.isEmpty || !snapshot.localTokenMetrics.isEmpty
    }

    private var statusDotColor: Color {
        switch snapshot.connection {
        case .error: return Palette.bad
        case .authRequired, .rateLimited: return Palette.warn
        case .disconnected, .unsupported, .connecting: return .secondary
        case .connected:
            if let maxUsed = snapshot.windows.compactMap(\.usedFraction).max() {
                return Palette.usageColor(usedFraction: maxUsed)
            }
            if !snapshot.spendMetrics.isEmpty { return Palette.spend }
            if !snapshot.localTokenMetrics.isEmpty { return Palette.local }
            return Palette.good
        }
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 5) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)

            Text(snapshot.account.displayName)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .layoutPriority(2)

            if let plan = snapshot.account.planLabel, !plan.isEmpty {
                Text(plan)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.fill.tertiary, in: Capsule())
                    .lineLimit(1)
                    .layoutPriority(1)
            }

            if let email = snapshot.account.email, !email.isEmpty {
                Text(email)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(email)
            }

            // "Connected" is the normal state — only surface a badge when something is off.
            if snapshot.connection != .connected {
                ConnectionBadge(state: snapshot.connection)
                    .layoutPriority(2)
            }

            Spacer(minLength: 2)

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
        if let onHideFromHome {
            Button("从主页隐藏", action: onHideFromHome)
        }
        if let onRetry {
            Divider()
            Button("刷新", action: onRetry)
        }
    }

    // MARK: Windows

    /// Highest-utilisation window first so the tightest limits are always surfaced first.
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
        return Array(sortedWindows.prefix(Self.collapsedWindowLimit))
    }

    private var hiddenWindowCount: Int {
        max(0, snapshot.windows.count - displayedWindows.count)
    }

    private var expandToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 3) {
                Text(isExpanded ? "收起多余窗口" : "展开其余 \(hiddenWindowCount) 个窗口（共 \(snapshot.windows.count)）")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .font(.caption2)
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
                .font(.caption)
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 18, height: 18)
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
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let resetLabel = compactResetText(now: context.date)
            let pace = elapsedFraction(now: context.date)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(window.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    if let resetLabel {
                        Text(resetLabel)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    if let symbol = severitySymbol {
                        Image(systemName: symbol)
                            .font(.caption2)
                            .foregroundStyle(usageTint)
                            .accessibilityHidden(true)
                    }

                    Text(valueText)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(window.freshness == .stale ? Color.secondary : valueTint)
                        .lineLimit(1)
                }

                slimProgressBar(paceFraction: pace)
            }
            .help(tooltipText(now: context.date))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(window.title)
            .accessibilityValue("已用 \(valueText)，\(fullResetText(now: context.date))")
        }
    }

    @ViewBuilder
    private func slimProgressBar(paceFraction: Double?) -> some View {
        if let used = window.usedFraction {
            let clamped = min(max(used, 0), 1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.09))
                    Capsule()
                        .fill(usageTint)
                        .frame(width: max(clamped > 0 ? 3 : 0, geo.size.width * clamped))
                        .animation(.easeInOut(duration: 0.3), value: clamped)
                    if let paceFraction, paceFraction > 0.02, paceFraction < 0.98 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.45))
                            .frame(width: 1.5, height: 6)
                            .offset(x: geo.size.width * paceFraction - 0.75)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(height: 5)
        } else {
            Capsule()
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(.tertiary)
                .frame(height: 5)
        }
    }

    private var valueText: String {
        window.usedDisplay.precision == .unknown ? "未知" : window.usedDisplay.display
    }

    private var usageTint: Color {
        Palette.usageColor(usedFraction: window.usedFraction ?? 0)
    }

    private var valueTint: Color {
        guard let used = window.usedFraction else { return .primary }
        return used >= 0.80 ? usageTint : .primary
    }

    /// Never rely on colour alone: critical usage always gets a glyph; with
    /// "Differentiate without colour" every elevated level does.
    private var severitySymbol: String? {
        guard let used = window.usedFraction else { return nil }
        if used >= 0.9 { return "exclamationmark.triangle.fill" }
        if differentiateWithoutColor && used >= 0.6 { return "exclamationmark.circle" }
        return nil
    }

    private func elapsedFraction(now: Date) -> Double? {
        guard window.resetKnown,
              let total = window.windowSeconds, total > 0,
              let remaining = window.secondsUntilReset(now: now) else { return nil }
        let elapsed = 1.0 - (remaining / Double(total))
        return min(max(elapsed, 0), 1)
    }

    private func compactResetText(now: Date) -> String? {
        guard window.resetKnown, let seconds = window.secondsUntilReset(now: now) else { return nil }
        if seconds <= 0 { return "即将重置" }
        return "↻ \(CountdownFormatter.format(seconds: seconds))"
    }

    private func fullResetText(now: Date) -> String {
        guard window.resetKnown, let seconds = window.secondsUntilReset(now: now) else { return "重置时间未知" }
        if seconds <= 0 { return "已到重置时间，等待刷新" }
        return "\(CountdownFormatter.format(seconds: seconds)) 后重置"
    }

    private func tooltipText(now: Date) -> String {
        var parts = [fullResetText(now: now), "来源：\(window.source.label)"]
        if window.remainingDisplay.precision != .unknown {
            parts.insert("剩余 \(window.remainingDisplay.display)", at: 0)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Metric row

struct MetricRow: View {
    let metric: MetricValue

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(tint)
                .frame(width: 13)
                .accessibilityHidden(true)
            Text(metric.display)
                .font(.caption.monospacedDigit().weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(tagLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 0.5)
                .background(tint.opacity(0.12), in: Capsule())
        }
        .help("\(metric.kind.displayLabel) · 来源：\(metric.source.label)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.kind.displayLabel)：\(metric.display)")
    }

    private var tagLabel: String {
        switch metric.kind {
        case .apiSpend: return metric.precision == .estimated ? "API 估算" : "API"
        case .locallyObservedTokens: return "本地估算"
        case .subscriptionQuota: return "配额"
        }
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
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
            .lineLimit(1)
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
