#if os(macOS)
import SwiftUI
import AppKit
import AIQuotyCore

// MARK: - Settings root

struct SettingsRootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("通用", systemImage: "gearshape") }
            ConnectionsSettingsTab()
                .tabItem { Label("连接", systemImage: "link") }
            CoverageSettingsTab()
                .tabItem { Label("覆盖矩阵", systemImage: "tablecells") }
            AboutSettingsTab()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 780, height: 580)
        .preferredColorScheme(model.preferredColorScheme)
        .onAppear {
            AppWindowActivator.activateWindow(identifierHint: "Settings")
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var model: AppModel

    private static let intervalOptions: [TimeInterval] = [60, 120, 300, 600, 900, 1800]

    private var intervalChoices: [TimeInterval] {
        let current = model.preferences.refreshIntervalSeconds
        return Self.intervalOptions.contains(current)
            ? Self.intervalOptions
            : (Self.intervalOptions + [current]).sorted()
    }

    var body: some View {
        Form {
            Section {
                Toggle("登录时启动 AIQuoty", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                if let error = model.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Palette.bad)
                }
                Picker("外观", selection: $model.preferences.appearance) {
                    Text("跟随系统").tag(AppPreferences.Appearance.system)
                    Text("浅色").tag(AppPreferences.Appearance.light)
                    Text("深色").tag(AppPreferences.Appearance.dark)
                }
                Picker("自动刷新", selection: $model.preferences.refreshIntervalSeconds) {
                    ForEach(intervalChoices, id: \.self) { seconds in
                        Text(Self.intervalLabel(seconds)).tag(seconds)
                    }
                }
            }

            Section {
                LabeledContent("预览") {
                    HStack(spacing: 4) {
                        Image(systemName: "gauge.with.dots.needle.33percent")
                        Text(model.menuBarSummary.isEmpty ? "仅图标" : model.menuBarSummary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                }
                Toggle("仅显示图标", isOn: Binding(
                    get: { model.preferences.menuBarIconOnly },
                    set: { model.setMenuBarIconOnly($0) }
                ))
                if model.state.snapshots.isEmpty {
                    Text("连接服务后，可在这里选择要常驻菜单栏的账号。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.state.snapshots) { snap in
                        Toggle(isOn: Binding(
                            get: { model.isShownInMenuBar(snap.account.id) },
                            set: { _ in model.toggleMenuBarAccount(snap.account.id) }
                        )) {
                            HStack {
                                Text(snap.account.displayName)
                                Spacer()
                                Text(MenuBarFormatter.itemText(for: snap))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(model.preferences.menuBarIconOnly)
                    }
                    HStack {
                        Button("自动（跟随置顶）") { model.resetMenuBarToAuto() }
                        Button("全部选择") { model.selectAllMenuBarAccounts() }
                    }
                    .disabled(model.preferences.menuBarIconOnly)
                }
            } header: {
                Text("菜单栏")
            } footer: {
                SectionFooter("菜单栏最多显示 \(MenuBarFormatter.maxItems) 个账号，其余合并为 +N，避免在刘海屏上被系统隐藏。")
            }

            Section {
                if model.state.snapshots.isEmpty {
                    Text("连接服务后，可在这里选择要在主页显示的账号。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.state.snapshots) { snap in
                        Toggle(isOn: Binding(
                            get: { model.isShownOnHome(snap.account.id) },
                            set: { model.setShownOnHome(snap.account.id, shown: $0) }
                        )) {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(snap.account.displayName)
                                    let subtitle = [snap.account.planLabel, snap.account.email].compactMap { $0 }
                                    if !subtitle.isEmpty {
                                        Text(subtitle.joined(separator: " · "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(MenuBarFormatter.itemText(for: snap))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack {
                        Button("全部显示") { model.showAllHomeAccounts() }
                            .disabled(model.state.snapshots.allSatisfy { model.isShownOnHome($0.account.id) })
                        Button("全部隐藏") { model.hideAllHomeAccounts() }
                            .disabled(model.state.snapshots.allSatisfy { !model.isShownOnHome($0.account.id) })
                    }
                }
            } header: {
                Text("主页显示")
            } footer: {
                SectionFooter("选择在主页（菜单栏弹窗）中展示的已连接账号，不影响后台刷新、菜单栏展示与仪表盘。")
            }

            Section {
                Toggle("Claude Code（~/.claude/projects）", isOn: $model.preferences.enableLocalClaudeLogs)
                Toggle("Codex（~/.codex/sessions）", isOn: $model.preferences.enableLocalCodexLogs)
                Toggle("OpenCode（~/.local/share/opencode/storage）", isOn: $model.preferences.enableLocalOpenCodeLogs)
                Toggle("Cline / Roo Code 任务日志", isOn: $model.preferences.enableLocalClineLogs)
            } header: {
                Text("本地日志")
            } footer: {
                SectionFooter("读取本机日志估算 Token 用量，只作估算参考，绝不会显示为订阅剩余配额。")
            }

            Section {
                Toggle("演示模式", isOn: $model.preferences.demoMode)
            } footer: {
                SectionFooter("使用合成数据预览全部 Agent 的界面效果，不读取真实账号。")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func intervalLabel(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        if Int(seconds) % 60 != 0 || minutes == 0 { return "\(Int(seconds)) 秒" }
        return "每 \(minutes) 分钟"
    }
}

// MARK: - Connections

private struct SecretFieldSpec: Identifiable {
    var id: String { account }
    let label: String
    let placeholder: String
    let hint: String
    let account: String
}

private struct ProviderConnectionSpec: Identifiable {
    enum OAuth {
        case github
        case google(GoogleOAuthAppConfig, bundleAccount: String)
    }

    enum Group: String, CaseIterable {
        case agents = "订阅 / IDE Agent"
        case plans = "编程套餐与 API 余额"
    }

    let id: String
    let title: String
    let group: Group
    var summary: String
    var oauth: OAuth? = nil
    var oauthNote: String? = nil
    var cliLogin: Bool = false
    var desktopAppLogin: Bool = false
    var secrets: [SecretFieldSpec] = []
    var detectPaths: [String] = []

    var secretAccounts: [String] {
        var all = secrets.map(\.account)
        switch oauth {
        case .github: all.append(CredentialAccount.copilotGitHubToken)
        case .google(_, let bundle): all.append(bundle)
        case nil: break
        }
        return all
    }
}

private enum ProviderCatalog {
    static let all: [ProviderConnectionSpec] = [
        ProviderConnectionSpec(
            id: "claude", title: "Claude Code", group: .agents,
            summary: "订阅 5 小时 / 7 天配额窗口。",
            cliLogin: true,
            secrets: [
                SecretFieldSpec(
                    label: "OAuth Access Token（可选覆盖）",
                    placeholder: "需包含 user:profile 权限",
                    hint: "留空时自动读取钥匙串「Claude Code-credentials」或 ~/.claude/.credentials.json。",
                    account: CredentialAccount.claudeOAuthOverride
                ),
            ],
            detectPaths: ["钥匙串「Claude Code-credentials」", "~/.claude/.credentials.json"]
        ),
        ProviderConnectionSpec(
            id: "codex", title: "Codex", group: .agents,
            summary: "ChatGPT 订阅下的 Codex 配额窗口。",
            cliLogin: true,
            detectPaths: ["~/.codex/auth.json"]
        ),
        ProviderConnectionSpec(
            id: "cursor", title: "Cursor", group: .agents,
            summary: "Cursor 订阅请求与用量。",
            cliLogin: true,
            secrets: [
                SecretFieldSpec(
                    label: "会话 Cookie（可选覆盖）",
                    placeholder: "WorkosCursorSessionToken",
                    hint: "留空时自动复用钥匙串「cursor-access-token」、~/.cursor/auth.json 或桌面端登录态。",
                    account: CredentialAccount.cursorSessionCookie
                ),
            ],
            detectPaths: ["钥匙串「cursor-access-token」", "~/.cursor/auth.json"]
        ),
        ProviderConnectionSpec(
            id: "antigravity", title: "Antigravity", group: .agents,
            summary: "自动复用本机 Antigravity 桌面端登录态（state.vscdb）。",
            desktopAppLogin: true,
            detectPaths: [
                "~/Library/Application Support/Antigravity/User/globalStorage/state.vscdb",
                "~/Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb",
            ]
        ),
        ProviderConnectionSpec(
            id: "gemini", title: "Gemini CLI", group: .agents,
            summary: "Gemini Code Assist 配额。",
            oauth: .google(.gemini, bundleAccount: CredentialAccount.geminiOAuthBundle),
            oauthNote: "在浏览器中完成 Google 授权，之后自动续期。",
            secrets: [
                SecretFieldSpec(
                    label: "OAuth Client ID（可选）",
                    placeholder: "Gemini OAuth Client ID",
                    hint: "推荐直接运行 gemini 登录生成 ~/.gemini/oauth_creds.json。",
                    account: CredentialAccount.geminiOAuthClientID
                ),
                SecretFieldSpec(
                    label: "OAuth Client Secret（可选）",
                    placeholder: "Gemini OAuth Client Secret",
                    hint: "配合 Client ID 使用。",
                    account: CredentialAccount.geminiOAuthClientSecret
                ),
                SecretFieldSpec(
                    label: "Access Token（可选覆盖）",
                    placeholder: "Gemini OAuth Access Token",
                    hint: "手动覆盖自动读取的凭证。",
                    account: CredentialAccount.geminiOAuthOverride
                ),
            ],
            detectPaths: ["~/.gemini/oauth_creds.json"]
        ),
        ProviderConnectionSpec(
            id: "opencode", title: "OpenCode", group: .agents,
            summary: "OpenCode Go / Zen 订阅窗口与余额。",
            cliLogin: true,
            secrets: [
                SecretFieldSpec(
                    label: "API Key（可选）",
                    placeholder: "OpenCode API Key",
                    hint: "留空时自动读取 ~/.local/share/opencode/auth.json。本地会话 Token 估算可在「通用」中开启。",
                    account: CredentialAccount.openCodeAPIKey
                ),
            ],
            detectPaths: ["~/.local/share/opencode/auth.json"]
        ),
        ProviderConnectionSpec(
            id: "copilot", title: "GitHub Copilot", group: .agents,
            summary: "Copilot 高级请求配额。",
            oauth: .github,
            oauthNote: "通过 GitHub 设备授权在浏览器中确认，令牌自动存入钥匙串；也会自动复用本机 gh / Copilot CLI 登录态。",
            secrets: [
                SecretFieldSpec(
                    label: "GitHub Token（手动）",
                    placeholder: "需包含 read:user 权限",
                    hint: "自动兼容 ~/.config/github-copilot/apps.json，也可以粘贴个人 GitHub Token。",
                    account: CredentialAccount.copilotGitHubToken
                ),
            ],
            detectPaths: ["钥匙串「copilot-cli」", "~/.copilot/config.json", "gh auth token"]
        ),
        ProviderConnectionSpec(
            id: "factory-droid", title: "Factory / Droid", group: .agents,
            summary: "Factory Droid 用量。",
            secrets: [
                SecretFieldSpec(
                    label: "API Key",
                    placeholder: "fk-...",
                    hint: "留空时自动读取 ~/.factory/auth.json。",
                    account: CredentialAccount.factoryAPIKey
                ),
            ],
            detectPaths: ["~/.factory/auth.json"]
        ),
        ProviderConnectionSpec(
            id: "windsurf", title: "Windsurf", group: .agents,
            summary: "Prompt / Flex Credits。",
            secrets: [
                SecretFieldSpec(
                    label: "API Key",
                    placeholder: "Windsurf / Codeium API Key",
                    hint: "留空时自动读取 ~/.codeium/windsurf/auth.json。",
                    account: CredentialAccount.windsurfAPIKey
                ),
            ],
            detectPaths: ["~/.codeium/windsurf/auth.json"]
        ),
        ProviderConnectionSpec(
            id: "deepseek", title: "DeepSeek", group: .plans,
            summary: "DeepSeek API 余额（兼容 DeepSeek Harness）。",
            secrets: [
                SecretFieldSpec(
                    label: "API Key（可选覆盖）",
                    placeholder: "sk-...",
                    hint: "留空时自动读取 ~/.dsh/.credentials.yaml；手动填写时调用 api.deepseek.com/user/balance。",
                    account: CredentialAccount.deepSeekAPIKey
                ),
            ],
            detectPaths: ["~/.dsh/.credentials.yaml"]
        ),
        ProviderConnectionSpec(
            id: "kimi-code", title: "Kimi / Moonshot", group: .plans,
            summary: "Kimi Code 订阅配额与 Moonshot API 余额，分开显示。",
            secrets: [
                SecretFieldSpec(
                    label: "Kimi Code 订阅 Token",
                    placeholder: "Kimi Code Token",
                    hint: "查询 api.kimi.com 订阅窗口；留空时自动读取 ~/.kimi/credentials.json。",
                    account: CredentialAccount.kimiCodeToken
                ),
                SecretFieldSpec(
                    label: "Moonshot API Key",
                    placeholder: "sk-...",
                    hint: "查询 api.moonshot.cn 账户余额。",
                    account: CredentialAccount.moonshotAPIKey
                ),
            ],
            detectPaths: ["~/.kimi/credentials.json"]
        ),
        ProviderConnectionSpec(
            id: "minimax", title: "MiniMax", group: .plans,
            summary: "MiniMax Coding Plan 剩余额度。",
            secrets: [
                SecretFieldSpec(
                    label: "Coding Plan API Key",
                    placeholder: "MiniMax API Key",
                    hint: "自动尝试国际站 api.minimax.io 与国内站 api.minimaxi.com。",
                    account: CredentialAccount.miniMaxAPIKey
                ),
            ]
        ),
        ProviderConnectionSpec(
            id: "zai", title: "智谱 GLM / Z.ai", group: .plans,
            summary: "GLM Coding Plan 配额。",
            secrets: [
                SecretFieldSpec(
                    label: "API Key",
                    placeholder: "BigModel / Z.ai API Key",
                    hint: "自动尝试 open.bigmodel.cn 与 api.z.ai。",
                    account: CredentialAccount.zaiAPIKey
                ),
            ]
        ),
        ProviderConnectionSpec(
            id: "grok", title: "Grok / xAI", group: .plans,
            summary: "xAI API Key 状态。",
            secrets: [
                SecretFieldSpec(
                    label: "API Key",
                    placeholder: "xai-...",
                    hint: "留空时自动读取 ~/.grok/auth.json。",
                    account: CredentialAccount.grokAPIKey
                ),
            ],
            detectPaths: ["~/.grok/auth.json"]
        ),
        ProviderConnectionSpec(
            id: "openrouter", title: "OpenRouter", group: .plans,
            summary: "API 余额与限额。",
            secrets: [
                SecretFieldSpec(
                    label: "API Key",
                    placeholder: "sk-or-...",
                    hint: "调用 openrouter.ai/api/v1/key。",
                    account: CredentialAccount.openRouterAPIKey
                ),
            ]
        ),
        ProviderConnectionSpec(
            id: "anthropic-admin", title: "Anthropic Admin", group: .plans,
            summary: "组织 API 花费，与 Claude 订阅配额分开显示。",
            secrets: [
                SecretFieldSpec(
                    label: "Admin Key",
                    placeholder: "sk-ant-admin...",
                    hint: "调用组织 cost_report 接口。",
                    account: CredentialAccount.anthropicAdminKey
                ),
            ]
        ),
    ]

    static var allSecretAccounts: [String] {
        Array(Set(all.flatMap(\.secrets).map(\.account)))
    }
}

private struct ConnectionsSettingsTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: String? = Self.overviewID
    @State private var savedAccounts: Set<String> = []
    @State private var googleEmails: [String: String] = [:]

    static let overviewID = "__overview"

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)
            Divider()
            Group {
                if let id = selection, let spec = ProviderCatalog.all.first(where: { $0.id == id }) {
                    ProviderDetailView(
                        spec: spec,
                        status: status(for: spec),
                        savedAccounts: savedAccounts,
                        googleEmail: googleEmail(for: spec),
                        onChanged: reloadSavedFlags
                    )
                    .id(spec.id)
                } else {
                    ConnectionsOverview()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: reloadSavedFlags)
        .onChange(of: model.activeSignIn) { _, _ in reloadSavedFlags() }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Label("概览", systemImage: "lock.shield")
                .tag(Self.overviewID)
            ForEach(ProviderConnectionSpec.Group.allCases, id: \.self) { group in
                Section(group.rawValue) {
                    ForEach(ProviderCatalog.all.filter { $0.group == group }) { spec in
                        HStack(spacing: 8) {
                            ConnectionStatusDot(status: status(for: spec))
                            Text(spec.title)
                                .lineLimit(1)
                        }
                        .tag(spec.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func googleEmail(for spec: ProviderConnectionSpec) -> String? {
        guard case .google(_, let bundle) = spec.oauth else { return nil }
        return googleEmails[bundle]
    }

    private func status(for spec: ProviderConnectionSpec) -> ConnectionStatus {
        let snaps = model.state.snapshots.filter { $0.account.providerID == spec.id }
        if snaps.contains(where: { $0.connection == .connected }) { return .connected }
        let configured = spec.secretAccounts.contains { savedAccounts.contains($0) || googleEmails[$0] != nil }
        if !snaps.isEmpty || configured {
            if snaps.contains(where: { $0.connection == .authRequired }) { return .needsAttention("需授权") }
            if snaps.contains(where: { $0.connection == .error }) { return .needsAttention("错误") }
            if configured { return .configured }
        }
        if model.detectedAgents.contains(where: { $0.providerID == spec.id }) { return .detected }
        return .none
    }

    /// Reads Keychain once (not on every redraw) and caches flags / signed-in emails.
    private func reloadSavedFlags() {
        let store = KeychainCredentialStore()
        var flags = Set<String>()
        for account in ProviderCatalog.allSecretAccounts {
            if let v = try? store.getSecret(account: account), !v.isEmpty {
                flags.insert(account)
            }
        }
        var emails: [String: String] = [:]
        for bundleAccount in [CredentialAccount.geminiOAuthBundle] {
            if let bundle = GoogleOAuthBundle.load(from: store, account: bundleAccount) {
                emails[bundleAccount] = bundle.email ?? "已授权"
            }
        }
        savedAccounts = flags
        googleEmails = emails
    }
}

private enum ConnectionStatus: Equatable {
    case connected
    case configured
    case needsAttention(String)
    case detected
    case none

    var label: String {
        switch self {
        case .connected: return "已连接"
        case .configured: return "已配置"
        case .needsAttention(let text): return text
        case .detected: return "本机已检测"
        case .none: return "未配置"
        }
    }

    var tint: Color {
        switch self {
        case .connected: return Palette.good
        case .configured: return Palette.spend
        case .needsAttention: return Palette.warn
        case .detected: return Palette.spend
        case .none: return .secondary
        }
    }
}

private struct ConnectionStatusDot: View {
    let status: ConnectionStatus
    var body: some View {
        Group {
            if status == .none {
                Circle().strokeBorder(.tertiary, lineWidth: 1)
            } else {
                Circle().fill(status.tint)
            }
        }
        .frame(width: 8, height: 8)
        .help(status.label)
        .accessibilityLabel(status.label)
    }
}

private struct ConnectionsOverview: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            if model.activeSignIn != .idle || !model.signInNotice.isEmpty {
                Section("登录进度") {
                    SignInProgressBanner()
                }
            }
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("密钥只保存在本机")
                            .font(.headline)
                        Text("所有密钥与 OAuth 令牌只写入 macOS 钥匙串，不上传云端，也不写入偏好设置文件。")
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(Palette.good)
                        .font(.title2)
                }
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("自动复用本机登录态")
                            .font(.headline)
                        Text("Claude Code、Codex、Cursor Agent、Gemini CLI、OpenCode、Copilot CLI 和 gh 登录后无需额外配置，AIQuoty 会自动读取。")
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(Palette.spend)
                        .font(.title2)
                }
            }
            Section {
                Text("在左侧选择一个服务，进行登录或填写密钥。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProviderDetailView: View {
    @EnvironmentObject private var model: AppModel
    let spec: ProviderConnectionSpec
    let status: ConnectionStatus
    let savedAccounts: Set<String>
    let googleEmail: String?
    let onChanged: () -> Void

    @State private var drafts: [String: String] = [:]
    @State private var feedback: Feedback?

    private struct Feedback {
        let message: String
        let isError: Bool
    }

    private var latestProviderError: String? {
        if let snapErr = model.state.snapshots
            .first(where: { $0.account.providerID == spec.id && ($0.lastError?.isEmpty == false) })?
            .lastError {
            return snapErr
        }
        if let err = model.state.providerErrors[spec.id], !err.isEmpty {
            return err
        }
        return nil
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(spec.title)
                            .font(.title3.weight(.semibold))
                        Text(spec.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(text: status.label, tint: status.tint)
                }
            }

            if let errMsg = latestProviderError {
                Section {
                    Label(errMsg, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Palette.warn)
                        .textSelection(.enabled)
                }
            }

            if model.activeSignIn != .idle || !model.signInNotice.isEmpty {
                Section {
                    SignInProgressBanner()
                }
            }

            if let oauth = spec.oauth {
                Section {
                    oauthRow(oauth)
                } header: {
                    Text("一键登录")
                } footer: {
                    if let note = spec.oauthNote {
                        SectionFooter(note)
                    }
                }
            }

            if spec.cliLogin {
                Section {
                    LabeledContent {
                        Button("在终端中登录") { model.launchCLILogin(providerID: spec.id) }
                    } label: {
                        Text("官方 CLI 登录")
                        Text("登录完成后自动读取。未安装 CLI 时会复制安装与登录命令。")
                    }
                }
            }

            if spec.desktopAppLogin {
                Section {
                    LabeledContent {
                        HStack(spacing: 6) {
                            Button("刷新读取") {
                                Task { await model.refresh(force: true) }
                            }
                            .disabled(model.isRefreshing)
                            Button("打开桌面端") {
                                model.startOneClickSignIn(providerID: spec.id)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } label: {
                        Text("复用本机桌面端登录态")
                        Text("自动只读解析 state.vscdb（优先读取最新同步令牌），无需通过 AIQuoty 授权。")
                    }
                } header: {
                    Text("自动同步")
                }
            }

            if !spec.secrets.isEmpty {
                if spec.oauth != nil {
                    Section {
                        DisclosureGroup("高级选项（自定义 OAuth / 手动 Token）") {
                            ForEach(spec.secrets) { secretRow($0) }
                        }
                    } footer: {
                        SectionFooter("仅保存在本机钥匙串；也可在 ~/.aiquoty/oauth.json 中配置。")
                    }
                } else {
                    Section {
                        ForEach(spec.secrets) { secretRow($0) }
                    } header: {
                        Text("手动填写")
                    } footer: {
                        SectionFooter("仅保存在本机钥匙串。")
                    }
                }
            }

            if !spec.detectPaths.isEmpty {
                Section {
                    DisclosureGroup("自动探测路径") {
                        ForEach(spec.detectPaths, id: \.self) { path in
                            Text(path)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if let feedback {
                Section {
                    Label(feedback.message, systemImage: feedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(feedback.isError ? Palette.bad : Palette.good)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func oauthRow(_ oauth: ProviderConnectionSpec.OAuth) -> some View {
        let signedIn: String? = {
            switch oauth {
            case .github:
                return savedAccounts.contains(CredentialAccount.copilotGitHubToken) ? "已授权" : nil
            case .google:
                return googleEmail
            }
        }()
        LabeledContent {
            HStack(spacing: 6) {
                if signedIn != nil {
                    Button("退出登录") { signOut(oauth) }
                }
                Button(signedIn == nil ? signInTitle(oauth) : "重新登录") { signIn(oauth) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.activeSignIn != .idle)
            }
        } label: {
            Text(signedIn.map { "已登录：\($0)" } ?? "未登录")
        }
    }

    private func signInTitle(_ oauth: ProviderConnectionSpec.OAuth) -> String {
        switch oauth {
        case .github: return "使用 GitHub 登录"
        case .google: return "使用 Google 登录"
        }
    }

    private func signIn(_ oauth: ProviderConnectionSpec.OAuth) {
        switch oauth {
        case .github: model.startGitHubCopilotSignIn()
        case .google(let app, _): model.startGoogleSignIn(app: app)
        }
    }

    private func signOut(_ oauth: ProviderConnectionSpec.OAuth) {
        switch oauth {
        case .github:
            model.signOutOAuth(account: CredentialAccount.copilotGitHubToken, label: spec.title)
        case .google(_, let bundle):
            model.signOutOAuth(account: bundle, label: spec.title)
        }
        onChanged()
    }

    @ViewBuilder
    private func secretRow(_ field: SecretFieldSpec) -> some View {
        let saved = savedAccounts.contains(field.account)
        let draft = drafts[field.account] ?? ""
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(field.label)
                Spacer()
                if saved {
                    StatusBadge(text: "已存入钥匙串", tint: Palette.good)
                }
            }
            HStack(spacing: 6) {
                SecureField(saved ? "已保存（输入新值以替换）" : field.placeholder, text: Binding(
                    get: { drafts[field.account] ?? "" },
                    set: { drafts[field.account] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit { save(draft, account: field.account, label: field.label) }
                Button("保存") { save(draft, account: field.account, label: field.label) }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if saved {
                    Button("移除", role: .destructive) { save("", account: field.account, label: field.label) }
                }
            }
            Text(field.hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func save(_ value: String, account: String, label: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try KeychainCredentialStore().setSecret(trimmed.isEmpty ? nil : trimmed, account: account)
            drafts[account] = ""
            onChanged()
            feedback = Feedback(
                message: trimmed.isEmpty ? "已移除「\(label)」" : "已保存「\(label)」，正在刷新…",
                isError: false
            )
            Task { await model.refresh(force: true) }
        } catch {
            feedback = Feedback(message: "钥匙串操作失败：\(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - Coverage

private struct CoverageSettingsTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(ProviderRegistry.allDescriptors) { d in
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(d.displayName).font(.callout.weight(.semibold))
                    if model.detectedAgents.contains(where: { $0.providerID == d.id }) {
                        StatusBadge(text: "本机已检测", tint: Palette.spend)
                    }
                    let kinds = d.supportedMetricKinds.map(\.displayLabel)
                    if !kinds.isEmpty {
                        Text(kinds.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    StatusBadge(text: statusLabel(d.implementationStatus), tint: statusColor(d.implementationStatus))
                }
                Text(d.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusLabel(_ s: ProviderDescriptor.ImplementationStatus) -> String {
        switch s {
        case .implemented: return "已实现"
        case .partial: return "部分"
        case .unimplemented: return "未实现"
        }
    }

    private func statusColor(_ s: ProviderDescriptor.ImplementationStatus) -> Color {
        switch s {
        case .implemented: return Palette.good
        case .partial: return Palette.warn
        case .unimplemented: return .secondary
        }
    }
}

// MARK: - About

private struct AboutSettingsTab: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "开发版"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "版本 \(short)（\($0)）" } ?? "版本 \(short)"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .padding(.top, 8)
            Text("AIQuoty")
                .font(.title.weight(.semibold))
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("本机优先的 AI Agent 配额监视器。无云账号、无遥测、无需注册。")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
            Text("灵感来自 AI Stats 与 CUStats；实现与界面为原创。部分数据路径参考了 MIT 许可的 CodexBar 文档（见 THIRD_PARTY.md）。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
            Spacer()
            Text("需要 macOS 14 或更高版本")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var filter: SnapshotFilter = .all
    @State private var query: String = ""

    private let gridColumns = [
        GridItem(.adaptive(minimum: 270, maximum: 380), spacing: 8, alignment: .top),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.state.snapshots.isEmpty {
                dashboardHeader
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.activeSignIn != .idle || !model.signInNotice.isEmpty {
                        SignInProgressBanner()
                    }
                    if !filteredSnapshots.isEmpty {
                        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 8) {
                            ForEach(filteredSnapshots) { snap in
                                AccountCard(
                                    snapshot: snap,
                                    inMenuBar: model.isShownInMenuBar(snap.account.id),
                                    onToggleMenuBar: { model.toggleMenuBarAccount(snap.account.id) },
                                    onPin: { model.togglePin(snap.account.id) },
                                    reauthTitle: model.signInActionTitle(for: snap.account.providerID),
                                    onReauth: { model.startOneClickSignIn(providerID: snap.account.providerID) },
                                    onRetry: { Task { await model.refresh(force: true) } },
                                    onOpenSettings: openSettingsAndActivate,
                                    alwaysExpanded: true
                                )
                                .frame(maxHeight: .infinity, alignment: .top)
                            }
                        }
                    } else if !model.state.snapshots.isEmpty {
                        Text("当前筛选条件下没有匹配的服务")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                    }
                }
                .padding(12)
            }
        }
        .overlay {
            if model.state.snapshots.isEmpty && model.activeSignIn == .idle {
                ContentUnavailableView {
                    Label("尚未连接任何服务", systemImage: "gauge.with.dots.needle.33percent")
                } description: {
                    Text("在设置中连接 Claude、Codex、Cursor 等 Agent 后，用量会显示在这里。")
                } actions: {
                    Button("打开设置…", action: openSettingsAndActivate)
                }
            }
        }
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.refresh(force: true) }
                } label: {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isRefreshing)
                .keyboardShortcut("r", modifiers: [.command])
                .help("立即刷新（⌘R）")

                Button(action: openSettingsAndActivate) {
                    Label("设置", systemImage: "gearshape")
                }
                .help("设置（⌘,）")
            }
        }
        .preferredColorScheme(model.preferredColorScheme)
        .onAppear {
            AppWindowActivator.activateWindow(identifierHint: "dashboard")
        }
    }

    private var dashboardHeader: some View {
        let all = model.state.snapshots
        let connectedCount = all.filter { $0.connection == .connected }.count
        let quotaWindows = all.flatMap { snap in snap.windows.map { (snap.account.displayName, $0) } }
        let peak = quotaWindows.max { ($0.1.usedFraction ?? -1) < ($1.1.usedFraction ?? -1) }
        let alertCount = quotaWindows.filter { ($0.1.usedFraction ?? 0) >= 0.80 }.count
        let spendCount = all.filter { !$0.spendMetrics.isEmpty }.count
        let localCount = all.filter { !$0.localTokenMetrics.isEmpty }.count

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DashboardKPITile(
                    title: "已连接",
                    value: "\(connectedCount)/\(all.count)",
                    detail: "服务",
                    tint: connectedCount == all.count ? Palette.good : Palette.warn
                )
                DashboardKPITile(
                    title: "峰值占用",
                    value: peak.flatMap { $0.1.usedFraction }.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                    detail: peak?.0 ?? "暂无配额窗口",
                    tint: peak.flatMap { $0.1.usedFraction }.map { Palette.usageColor(usedFraction: $0) } ?? .secondary
                )
                DashboardKPITile(
                    title: "高占用预警",
                    value: "\(alertCount)",
                    detail: alertCount > 0 ? "窗口 ≥ 80%" : "全部充裕",
                    tint: alertCount > 0 ? Palette.warn : Palette.good
                )
                DashboardKPITile(
                    title: "数据源分布",
                    value: "\(quotaWindows.count) 窗口",
                    detail: "\(spendCount) API · \(localCount) 日志",
                    tint: Palette.spend
                )
            }

            HStack(spacing: 8) {
                Picker("分类", selection: $filter) {
                    ForEach(SnapshotFilter.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)

                Spacer(minLength: 8)

                SearchField(text: $query)
                    .frame(maxWidth: 220)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var filteredSnapshots: [AccountSnapshot] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = model.state.snapshots
            .filter { filter.matches($0) }
            .sorted { lhs, rhs in
                if lhs.account.pinned != rhs.account.pinned { return lhs.account.pinned && !rhs.account.pinned }
                let lu = lhs.windows.compactMap(\.usedFraction).max() ?? -1
                let ru = rhs.windows.compactMap(\.usedFraction).max() ?? -1
                if lu != ru { return lu > ru }
                return lhs.account.displayName.localizedStandardCompare(rhs.account.displayName) == .orderedAscending
            }
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.account.displayName.lowercased().contains(q)
                || ($0.account.email?.lowercased().contains(q) ?? false)
                || $0.account.providerID.lowercased().contains(q)
                || ($0.account.group?.lowercased().contains(q) ?? false)
        }
    }

    private var subtitle: String {
        guard let last = model.state.lastRefreshAt else { return model.preferences.demoMode ? "演示模式" : "" }
        let updated = "更新于 \(last.formatted(date: .omitted, time: .shortened))"
        return model.preferences.demoMode ? "演示模式 · \(updated)" : updated
    }

    private func openSettingsAndActivate() {
        openSettings()
        AppWindowActivator.activateWindow(identifierHint: "Settings")
    }
}

private struct DashboardKPITile: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(.headline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Palette.cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
}

private struct SectionFooter: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
