#if os(macOS)
import SwiftUI
import AppKit
import AIQuotyCore

struct SettingsRootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var secrets: [String: String] = [:]
    @State private var savedAccounts: Set<String> = []
    @State private var saveMessage: String = ""

    private struct SecretFieldSpec: Identifiable {
        var id: String { account }
        let providerID: String
        let title: String
        let placeholder: String
        let hint: String
        let account: String
        let buttonTitle: String
    }

    private var primaryAgentFields: [SecretFieldSpec] {
        [
            SecretFieldSpec(
                providerID: "claude",
                title: "Claude / Claude Code",
                placeholder: "Claude OAuth access token（可选覆盖，需 user:profile）",
                hint: "自动读取 macOS 钥匙串「Claude Code-credentials」或 ~/.claude/.credentials.json。",
                account: CredentialAccount.claudeOAuthOverride,
                buttonTitle: "保存 Claude Token"
            ),
            SecretFieldSpec(
                providerID: "cursor",
                title: "Cursor",
                placeholder: "Cursor Cookie（WorkosCursorSessionToken）",
                hint: "自动只读 Cursor 桌面端 state.vscdb 的登录态，也支持在此手动覆盖 Cookie。",
                account: CredentialAccount.cursorSessionCookie,
                buttonTitle: "保存 Cursor Cookie"
            ),
            SecretFieldSpec(
                providerID: "antigravity",
                title: "Antigravity OAuth Client ID",
                placeholder: "Google OAuth Client ID（用于一键浏览器登录与自动续期）",
                hint: "仅存本机钥匙串，也可通过环境变量 AIQUOTY_ANTIGRAVITY_OAUTH_CLIENT_ID 提供。",
                account: CredentialAccount.antigravityOAuthClientID,
                buttonTitle: "保存 Client ID"
            ),
            SecretFieldSpec(
                providerID: "antigravity",
                title: "Antigravity OAuth Client Secret",
                placeholder: "Google OAuth Client Secret（配合上方 Client ID 使用）",
                hint: "仅存本机钥匙串，也可通过环境变量 AIQUOTY_ANTIGRAVITY_OAUTH_CLIENT_SECRET 提供。",
                account: CredentialAccount.antigravityOAuthClientSecret,
                buttonTitle: "保存 Secret"
            ),
            SecretFieldSpec(
                providerID: "antigravity",
                title: "Antigravity（手动 Access Token）",
                placeholder: "Antigravity / Google Cloud Code OAuth Access Token",
                hint: "如不配置 OAuth Client，也可直接在此粘贴 Access Token。",
                account: CredentialAccount.antigravityOAuthToken,
                buttonTitle: "保存 Token"
            ),
            SecretFieldSpec(
                providerID: "gemini",
                title: "Gemini OAuth Client ID / Secret（可选）",
                placeholder: "Gemini OAuth Client ID",
                hint: "推荐运行 gemini 登录生成 ~/.gemini/oauth_creds.json，或填入自定义 OAuth Client ID。",
                account: CredentialAccount.geminiOAuthClientID,
                buttonTitle: "保存 Client ID"
            ),
            SecretFieldSpec(
                providerID: "gemini",
                title: "Gemini OAuth Client Secret（可选）",
                placeholder: "Gemini OAuth Client Secret",
                hint: "配合上方 Gemini OAuth Client ID 使用，仅存本机钥匙串。",
                account: CredentialAccount.geminiOAuthClientSecret,
                buttonTitle: "保存 Secret"
            ),
            SecretFieldSpec(
                providerID: "gemini",
                title: "Gemini CLI / Code Assist（手动 Token）",
                placeholder: "Gemini OAuth access token（可选覆盖）",
                hint: "推荐运行 gemini 登录生成 ~/.gemini/oauth_creds.json，也可在此覆盖。",
                account: CredentialAccount.geminiOAuthOverride,
                buttonTitle: "保存 Gemini Token"
            ),
            SecretFieldSpec(
                providerID: "opencode",
                title: "OpenCode (Zen / Go)",
                placeholder: "OpenCode API Key（可选，留空自动读 ~/.local/share/opencode/auth.json）",
                hint: "支持 OpenCode Go/Zen 订阅窗口与余额查询；本地会话 token 估算可在「通用」开启。",
                account: CredentialAccount.openCodeAPIKey,
                buttonTitle: "保存 OpenCode Key"
            ),
            SecretFieldSpec(
                providerID: "copilot",
                title: "GitHub Copilot",
                placeholder: "GitHub Token（read:user）",
                hint: "自动兼容 ~/.config/github-copilot/apps.json，也可粘贴个人 GitHub Token。",
                account: CredentialAccount.copilotGitHubToken,
                buttonTitle: "保存 Copilot Token"
            ),
            SecretFieldSpec(
                providerID: "factory-droid",
                title: "Factory / Droid",
                placeholder: "Factory API Key (fk-...)",
                hint: "支持钥匙串 API Key 或自动读取 ~/.factory/auth.json。",
                account: CredentialAccount.factoryAPIKey,
                buttonTitle: "保存 Factory Key"
            ),
            SecretFieldSpec(
                providerID: "windsurf",
                title: "Windsurf",
                placeholder: "Windsurf / Codeium API Key",
                hint: "支持钥匙串 API Key 或 ~/.codeium/windsurf/auth.json 查询 Prompt / Flex Credits。",
                account: CredentialAccount.windsurfAPIKey,
                buttonTitle: "保存 Windsurf Key"
            ),
        ]
    }

    private var modelAndCodingPlanFields: [SecretFieldSpec] {
        [
            SecretFieldSpec(
                providerID: "deepseek",
                title: "DeepSeek / DeepSeek Harness",
                placeholder: "DeepSeek API Key（可选覆盖；留空自动读 ~/.dsh/.credentials.yaml）",
                hint: "自动复用 DeepSeek Harness 登录态，也支持手动填写 API Key 调用官方 api.deepseek.com/user/balance。",
                account: CredentialAccount.deepSeekAPIKey,
                buttonTitle: "保存 DeepSeek Key"
            ),
            SecretFieldSpec(
                providerID: "kimi-code",
                title: "Kimi Code（订阅配额）",
                placeholder: "Kimi Code 订阅 Token",
                hint: "调用 api.kimi.com/coding/v1/usages 查询订阅窗口，或自动读 ~/.kimi/credentials.json。",
                account: CredentialAccount.kimiCodeToken,
                buttonTitle: "保存 Kimi Code Token"
            ),
            SecretFieldSpec(
                providerID: "kimi-code",
                title: "Moonshot 开放平台（API 余额）",
                placeholder: "Moonshot API Key (sk-...)",
                hint: "调用 api.moonshot.cn/v1/users/me/balance，与 Kimi Code 订阅配额分列。",
                account: CredentialAccount.moonshotAPIKey,
                buttonTitle: "保存 Moonshot Key"
            ),
            SecretFieldSpec(
                providerID: "minimax",
                title: "MiniMax Coding Plan",
                placeholder: "MiniMax Coding Plan API Key",
                hint: "自动尝试国际 (api.minimax.io) 与国内 (api.minimaxi.com) coding_plan/remains。",
                account: CredentialAccount.miniMaxAPIKey,
                buttonTitle: "保存 MiniMax Key"
            ),
            SecretFieldSpec(
                providerID: "zai",
                title: "智谱 GLM / Z.ai Coding Plan",
                placeholder: "智谱 BigModel / Z.ai API Key",
                hint: "自动尝试 open.bigmodel.cn 与 api.z.ai 的 /api/monitor/usage/quota/limit。",
                account: CredentialAccount.zaiAPIKey,
                buttonTitle: "保存智谱 / Z.ai Key"
            ),
            SecretFieldSpec(
                providerID: "grok",
                title: "Grok / xAI",
                placeholder: "xAI API Key (xai-...)",
                hint: "调用 api.x.ai/v1/api-key 校验状态，或读取 ~/.grok/auth.json。",
                account: CredentialAccount.grokAPIKey,
                buttonTitle: "保存 xAI Key"
            ),
            SecretFieldSpec(
                providerID: "openrouter",
                title: "OpenRouter（API 余额）",
                placeholder: "OpenRouter API Key (sk-or-...)",
                hint: "调用 openrouter.ai/api/v1/key，显示为 API 余额/限额。",
                account: CredentialAccount.openRouterAPIKey,
                buttonTitle: "保存 OpenRouter Key"
            ),
            SecretFieldSpec(
                providerID: "anthropic-admin",
                title: "Anthropic Admin（组织花费）",
                placeholder: "Anthropic Admin Key (sk-ant-admin...)",
                hint: "调用组织 cost_report，与 Claude 订阅配额完全分列显示。",
                account: CredentialAccount.anthropicAdminKey,
                buttonTitle: "保存 Admin Key"
            ),
        ]
    }

    var body: some View {
        TabView {
            generalTab.tabItem { Label("通用", systemImage: "gearshape") }
            connectionsTab.tabItem { Label("连接", systemImage: "link") }
            coverageTab.tabItem { Label("覆盖矩阵", systemImage: "tablecells") }
            aboutTab.tabItem { Label("关于", systemImage: "info.circle") }
        }
        .padding(16)
        .onAppear {
            reloadSavedFlags()
            AppWindowActivator.activateWindow(matchingTitle: "设置", identifierHint: "Settings")
        }
    }

    private var generalTab: some View {
        Form {
            Section("外观与刷新") {
                Picker("外观", selection: $model.preferences.appearance) {
                    Text("跟随系统").tag(AppPreferences.Appearance.system)
                    Text("浅色").tag(AppPreferences.Appearance.light)
                    Text("深色").tag(AppPreferences.Appearance.dark)
                }
                Stepper(
                    value: $model.preferences.refreshIntervalSeconds,
                    in: 60...1800,
                    step: 60
                ) {
                    Text("刷新间隔 \(Int(model.preferences.refreshIntervalSeconds)) 秒")
                }
                Toggle("演示模式（合成夹具，预览全部主流 Agent）", isOn: $model.preferences.demoMode)
            }
            Section("顶部菜单栏展示") {
                HStack(spacing: 6) {
                    Text("当前预览")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "gauge.with.dots.needle.33percent")
                    Text(model.menuBarSummary.isEmpty ? "（仅显示图标）" : model.menuBarSummary)
                        .font(.callout.monospacedDigit())
                }
                Toggle("仅显示图标（不展示文字）", isOn: Binding(
                    get: { model.preferences.menuBarIconOnly },
                    set: { model.setMenuBarIconOnly($0) }
                ))
                if !model.state.snapshots.isEmpty {
                    ForEach(model.state.snapshots) { snap in
                        Toggle(isOn: Binding(
                            get: { model.isShownInMenuBar(snap.account.id) },
                            set: { _ in model.toggleMenuBarAccount(snap.account.id) }
                        )) {
                            HStack {
                                Text(snap.account.displayName)
                                Spacer()
                                Text(MenuBarFormatter.itemText(for: snap))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack {
                        Button("自动（跟随置顶）") { model.resetMenuBarToAuto() }
                        Button("全部展示") { model.selectAllMenuBarAccounts() }
                    }
                } else {
                    Text("连接服务后可在此勾选需要常驻顶部菜单栏的账号。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("本地日志（需明确同意，仅估算 Token）") {
                Toggle("导入本机 Claude Code JSONL（~/.claude/projects）", isOn: $model.preferences.enableLocalClaudeLogs)
                Toggle("导入本机 Codex JSONL（~/.codex/sessions）", isOn: $model.preferences.enableLocalCodexLogs)
                Toggle("导入本机 OpenCode 会话（~/.local/share/opencode/storage）", isOn: $model.preferences.enableLocalOpenCodeLogs)
                Toggle("导入本机 Cline / Roo Code 任务日志", isOn: $model.preferences.enableLocalClineLogs)
                Text("本地日志绝不会被显示为订阅剩余配额。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("保存并重新加载") {
                model.savePreferences()
                saveMessage = "已保存并刷新"
            }
            if !saveMessage.isEmpty {
                Text(saveMessage).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var connectionsTab: some View {
        Form {
            if model.activeSignIn != .idle || !model.signInNotice.isEmpty {
                Section("登录进度") {
                    SignInProgressBanner()
                }
            }

            Section("一键授权登录（免手动复制 Token）") {
                oauthSignInRow(
                    title: "GitHub Copilot",
                    subtitle: "通过 GitHub Device Flow 浏览器确认授权，自动保存至钥匙串（同时自动兼容本机 gh / Copilot CLI）。",
                    signedInLabel: savedAccounts.contains(CredentialAccount.copilotGitHubToken) ? "已授权" : nil,
                    buttonTitle: "一键登录 GitHub",
                    onSignIn: { model.startGitHubCopilotSignIn() },
                    onSignOut: {
                        model.signOutOAuth(account: CredentialAccount.copilotGitHubToken, label: "GitHub Copilot")
                        reloadSavedFlags()
                    }
                )
                oauthSignInRow(
                    title: "Gemini / Code Assist",
                    subtitle: "浏览器完成 Google OAuth 授权并自动续期，无需手动抓取 Token。",
                    signedInLabel: googleSignedInEmail(account: CredentialAccount.geminiOAuthBundle),
                    buttonTitle: "一键 Google 登录",
                    onSignIn: { model.startGoogleSignIn(app: .gemini) },
                    onSignOut: {
                        model.signOutOAuth(account: CredentialAccount.geminiOAuthBundle, label: "Gemini")
                        reloadSavedFlags()
                    }
                )
                oauthSignInRow(
                    title: "Antigravity",
                    subtitle: GoogleOAuthAppConfig.antigravity.riskNotice ?? "通过 Google OAuth 登录并自动续期。",
                    signedInLabel: googleSignedInEmail(account: CredentialAccount.antigravityOAuthBundle),
                    buttonTitle: "一键 Google 登录",
                    onSignIn: { model.startGoogleSignIn(app: .antigravity) },
                    onSignOut: {
                        model.signOutOAuth(account: CredentialAccount.antigravityOAuthBundle, label: "Antigravity")
                        reloadSavedFlags()
                    }
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text("官方 CLI 终端登录（登录完成即自动读取）")
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 8) {
                        Button("Claude Code") { model.launchCLILogin(providerID: "claude") }
                        Button("Codex") { model.launchCLILogin(providerID: "codex") }
                        Button("Cursor Agent") { model.launchCLILogin(providerID: "cursor") }
                        Button("OpenCode") { model.launchCLILogin(providerID: "opencode") }
                    }
                    .controlSize(.small)
                    Text("若本机已安装对应 CLI 将直接打开终端登录；若未安装将自动复制安装并登录命令到剪贴板。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("安全说明") {
                Text("所有密钥与 OAuth 令牌仅保存在本机 macOS 钥匙串，不上传云端、不写入偏好文件。Codex / Cursor Agent / Claude Code / Gemini CLI / OpenCode / Copilot CLI / gh 均支持自动复用本机登录态。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !saveMessage.isEmpty {
                    Text(saveMessage)
                        .font(.caption)
                        .foregroundStyle(Palette.good)
                }
            }

            Section("主力订阅 / IDE Agent（手动覆盖）") {
                ForEach(primaryAgentFields) { spec in
                    secretRow(spec)
                }
            }

            Section("国产 / 编程套餐 & API 余额") {
                ForEach(modelAndCodingPlanFields) { spec in
                    secretRow(spec)
                }
            }

            Section("本机自动探测路径（只读）") {
                labeledPath("Codex", "~/.codex/auth.json")
                labeledPath("Cursor Agent", "钥匙串「cursor-access-token」 / ~/.cursor/auth.json")
                labeledPath("Claude Code", "钥匙串「Claude Code-credentials」 / ~/.claude/.credentials.json")
                labeledPath("Gemini CLI", "~/.gemini/oauth_creds.json")
                labeledPath("OpenCode", "~/.local/share/opencode/auth.json")
                labeledPath("Copilot / gh CLI", "钥匙串「copilot-cli」 / ~/.copilot/config.json / gh auth token")
                labeledPath("DeepSeek Harness", "~/.dsh/.credentials.yaml")
                labeledPath("Kimi / Factory / Grok", "~/.kimi · ~/.factory · ~/.grok")
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.activeSignIn) { _, _ in reloadSavedFlags() }
    }

    @ViewBuilder
    private func oauthSignInRow(
        title: String,
        subtitle: String,
        signedInLabel: String?,
        buttonTitle: String,
        onSignIn: @escaping () -> Void,
        onSignOut: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                if let signedInLabel {
                    Text(signedInLabel)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Palette.good.opacity(0.15), in: Capsule())
                        .foregroundStyle(Palette.good)
                }
                Spacer()
                Button(buttonTitle, action: onSignIn)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                if signedInLabel != nil {
                    Button("退出", action: onSignOut)
                        .controlSize(.small)
                }
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func googleSignedInEmail(account: String) -> String? {
        guard let bundle = GoogleOAuthBundle.load(from: KeychainCredentialStore(), account: account) else {
            return nil
        }
        return bundle.email ?? "已授权"
    }

    @ViewBuilder
    private func secretRow(_ spec: SecretFieldSpec) -> some View {
        let detected = model.detectedAgents.contains { $0.providerID == spec.providerID }
        let saved = savedAccounts.contains(spec.account)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(spec.title).font(.headline)
                if detected {
                    Text("本机已检测")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Palette.spend.opacity(0.14), in: Capsule())
                        .foregroundStyle(Palette.spend)
                }
                if saved {
                    Text("已存钥匙串")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Palette.good.opacity(0.15), in: Capsule())
                        .foregroundStyle(Palette.good)
                }
                Spacer()
            }
            HStack {
                SecureField(spec.placeholder, text: binding(for: spec.account))
                    .textFieldStyle(.roundedBorder)
                Button(spec.buttonTitle) {
                    saveSecret(secrets[spec.account] ?? "", account: spec.account)
                }
                if saved {
                    Button("清除") {
                        saveSecret("", account: spec.account)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            Text(spec.hint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func binding(for account: String) -> Binding<String> {
        Binding(
            get: { secrets[account] ?? "" },
            set: { secrets[account] = $0 }
        )
    }

    private var coverageTab: some View {
        List(ProviderRegistry.allDescriptors) { d in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(d.displayName).font(.headline)
                    if model.detectedAgents.contains(where: { $0.providerID == d.id }) {
                        Text("本机已检测")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Palette.spend.opacity(0.14), in: Capsule())
                            .foregroundStyle(Palette.spend)
                    }
                    Spacer()
                    Text(statusLabel(d.implementationStatus))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor(d.implementationStatus))
                }
                Text(d.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("指标：\(d.supportedMetricKinds.map(\.rawValue).joined(separator: ", ").ifEmpty("无"))")
                    .font(.caption2)
            }
            .padding(.vertical, 4)
        }
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AIQuoty")
                .font(.system(.largeTitle, design: .serif).weight(.semibold))
            Text("本机优先的 macOS 菜单栏 AI Agent 配额监视器。无云账号、无遥测、无强制注册。")
                .foregroundStyle(.secondary)
            Text("覆盖 Claude Code、Codex、Cursor、Antigravity、Gemini CLI、OpenCode、DeepSeek / DeepSeek Harness、GitHub Copilot、Kimi Code、MiniMax、智谱 GLM / Z.ai、Factory / Droid、Windsurf、Grok / xAI、Cline / Roo Code、OpenRouter 等主流 AI Agent。")
                .font(.callout)
            Text("灵感来自公开产品 AI Stats 与 CUStats 的能力描述；实现与 UI 为原创。Codex/Claude 等数据路径参考了 MIT 许可的 CodexBar 文档（见 THIRD_PARTY.md）。")
                .font(.callout)
            Text("macOS 14+ · 本地优先")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func labeledPath(_ name: String, _ path: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }

    private func reloadSavedFlags() {
        let store = KeychainCredentialStore()
        var flags = Set<String>()
        for spec in primaryAgentFields + modelAndCodingPlanFields {
            if let v = try? store.getSecret(account: spec.account), !v.isEmpty {
                flags.insert(spec.account)
            }
        }
        savedAccounts = flags
    }

    private func saveSecret(_ value: String, account: String) {
        let store = KeychainCredentialStore()
        do {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            try store.setSecret(trimmed.isEmpty ? nil : trimmed, account: account)
            secrets[account] = ""
            reloadSavedFlags()
            saveMessage = trimmed.isEmpty ? "已清除钥匙串项（\(account)）" : "已写入钥匙串（\(account)），正在刷新…"
            Task { await model.refresh(force: true) }
        } catch {
            saveMessage = "钥匙串操作失败：\(error.localizedDescription)"
        }
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
        case .partial: return Palette.caution
        case .unimplemented: return .secondary
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings

    private var unconfiguredDetected: [DetectedLocalAgent] {
        let activeIDs = Set(model.state.snapshots.map(\.account.providerID))
        return model.detectedAgents.filter { !activeIDs.contains($0.providerID) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AIQuoty")
                    .font(.system(.title, design: .serif).weight(.semibold))
                Text("仪表盘")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("设置") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                    AppWindowActivator.activateWindow(matchingTitle: "设置", identifierHint: "Settings")
                }
                Button("刷新") { Task { await model.refresh(force: true) } }
                    .keyboardShortcut("r", modifiers: [.command])
            }
            .padding()
            Divider()
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
                                onToggleMenuBar: {
                                    model.toggleMenuBarAccount(snap.account.id)
                                },
                                onPin: {
                                    model.togglePin(snap.account.id)
                                }
                            )
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        }
                    }
                }
                if !model.preferences.demoMode && !unconfiguredDetected.isEmpty {
                    Section("本机已检测到（待连接）") {
                        ForEach(unconfiguredDetected) { agent in
                            DetectedAgentCard(
                                agent: agent,
                                oneClickTitle: model.supportsOneClickSignIn(providerID: agent.providerID)
                                    ? "一键登录"
                                    : (CLILoginSpec.entry(for: agent.providerID) != nil ? "终端登录" : nil),
                                onOneClick: {
                                    model.startOneClickSignIn(providerID: agent.providerID)
                                },
                                onConfigure: {
                                    NSApp.activate(ignoringOtherApps: true)
                                    openSettings()
                                    AppWindowActivator.activateWindow(matchingTitle: "设置", identifierHint: "Settings")
                                }
                            )
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .background(Palette.popoverBackground)
        .onAppear {
            AppWindowActivator.activateWindow(matchingTitle: "仪表盘", identifierHint: "dashboard")
        }
    }
}
#endif
