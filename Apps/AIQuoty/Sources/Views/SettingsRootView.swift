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
                Text("菜单栏最多显示 \(MenuBarFormatter.maxItems) 个账号，其余合并为 +N，避免在刘海屏上被系统隐藏。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Claude Code（~/.claude/projects）", isOn: $model.preferences.enableLocalClaudeLogs)
                Toggle("Codex（~/.codex/sessions）", isOn: $model.preferences.enableLocalCodexLogs)
                Toggle("OpenCode（~/.local/share/opencode/storage）", isOn: $model.preferences.enableLocalOpenCodeLogs)
                Toggle("Cline / Roo Code 任务日志", isOn: $model.preferences.enableLocalClineLogs)
            } header: {
                Text("本地日志")
            } footer: {
                Text("读取本机日志估算 Token 用量，只作估算参考，绝不会显示为订阅剩余配额。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("演示模式", isOn: $model.preferences.demoMode)
            } footer: {
                Text("使用合成数据预览全部 Agent 的界面效果，不读取真实账号。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 600)
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
            summary: "Google Antigravity 模型配额。",
            oauth: .google(.antigravity, bundleAccount: CredentialAccount.antigravityOAuthBundle),
            oauthNote: GoogleOAuthAppConfig.antigravity.riskNotice ?? "通过 Google OAuth 登录并自动续期。",
            secrets: [
                SecretFieldSpec(
                    label: "OAuth Client ID",
                    placeholder: "Google OAuth Client ID",
                    hint: "用于一键浏览器登录与自动续期。也可通过环境变量 AIQUOTY_ANTIGRAVITY_OAUTH_CLIENT_ID 提供。",
                    account: CredentialAccount.antigravityOAuthClientID
                ),
                SecretFieldSpec(
                    label: "OAuth Client Secret",
                    placeholder: "Google OAuth Client Secret",
                    hint: "配合 Client ID 使用。也可通过环境变量 AIQUOTY_ANTIGRAVITY_OAUTH_CLIENT_SECRET 提供。",
                    account: CredentialAccount.antigravityOAuthClientSecret
                ),
                SecretFieldSpec(
                    label: "Access Token（手动）",
                    placeholder: "Google Cloud Code OAuth Access Token",
                    hint: "不配置 OAuth Client 时，也可以直接粘贴 Access Token。",
                    account: CredentialAccount.antigravityOAuthToken
                ),
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
        .frame(width: 800, height: 600)
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
        for bundleAccount in [CredentialAccount.geminiOAuthBundle, CredentialAccount.antigravityOAuthBundle] {
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
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

            if !spec.secrets.isEmpty {
                Section {
                    ForEach(spec.secrets) { secretRow($0) }
                } header: {
                    Text("手动填写")
                } footer: {
                    Text("仅保存在本机钥匙串。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(d.displayName).font(.headline)
                    if model.detectedAgents.contains(where: { $0.providerID == d.id }) {
                        StatusBadge(text: "本机已检测", tint: Palette.spend)
                    }
                    Spacer()
                    StatusBadge(text: statusLabel(d.implementationStatus), tint: statusColor(d.implementationStatus))
                }
                Text(d.notes)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                let kinds = d.supportedMetricKinds.map(\.displayLabel)
                Text("指标：\(kinds.isEmpty ? "无" : kinds.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .frame(width: 580, height: 560)
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
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 8)
            Text("AIQuoty")
                .font(.title.weight(.semibold))
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("本机优先的 AI Agent 配额监视器。无云账号、无遥测、无需注册。")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("灵感来自 AI Stats 与 CUStats；实现与界面为原创。部分数据路径参考了 MIT 许可的 CodexBar 文档（见 THIRD_PARTY.md）。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Text("需要 macOS 14 或更高版本")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 580, height: 380)
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings

    private var unconfiguredDetected: [DetectedLocalAgent] {
        let activeIDs = Set(model.state.snapshots.map(\.account.providerID))
        return model.detectedAgents.filter { !activeIDs.contains($0.providerID) }
    }

    var body: some View {
        List {
            if model.activeSignIn != .idle || !model.signInNotice.isEmpty {
                Section("登录进度") {
                    SignInProgressBanner()
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }
            }
            if !model.state.snapshots.isEmpty {
                Section("已连接服务") {
                    ForEach(model.state.snapshots) { snap in
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
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .listRowSeparator(.hidden)
                    }
                }
            }
            if !model.preferences.demoMode && !unconfiguredDetected.isEmpty {
                Section("本机已检测到（待连接）") {
                    ForEach(unconfiguredDetected) { agent in
                        DetectedAgentCard(
                            agent: agent,
                            oneClickTitle: model.signInActionTitle(for: agent.providerID),
                            onOneClick: { model.startOneClickSignIn(providerID: agent.providerID) },
                            onConfigure: openSettingsAndActivate
                        )
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.state.snapshots.isEmpty && unconfiguredDetected.isEmpty && model.activeSignIn == .idle {
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
#endif
