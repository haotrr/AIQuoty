#if os(macOS)
import SwiftUI
import AIQuotyCore

struct SettingsRootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var claudeToken: String = ""
    @State private var cursorCookie: String = ""
    @State private var copilotToken: String = ""
    @State private var openRouterKey: String = ""
    @State private var anthropicAdminKey: String = ""
    @State private var saveMessage: String = ""

    var body: some View {
        TabView {
            generalTab.tabItem { Label("通用", systemImage: "gearshape") }
            connectionsTab.tabItem { Label("连接", systemImage: "link") }
            coverageTab.tabItem { Label("覆盖矩阵", systemImage: "tablecells") }
            aboutTab.tabItem { Label("关于", systemImage: "info.circle") }
        }
        .padding(16)
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
                Toggle("演示模式（合成夹具，非真实用量）", isOn: $model.preferences.demoMode)
            }
            Section("本地日志（需明确同意）") {
                Toggle("导入本机 Claude JSONL（估算 token）", isOn: $model.preferences.enableLocalClaudeLogs)
                Toggle("导入本机 Codex JSONL（估算 token）", isOn: $model.preferences.enableLocalCodexLogs)
                Text("本地日志绝不会被显示为订阅剩余配额。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("保存并重新加载") {
                model.savePreferences()
                saveMessage = "已保存"
            }
            if !saveMessage.isEmpty {
                Text(saveMessage).foregroundStyle(.secondary)
            }
        }
    }

    private var connectionsTab: some View {
        Form {
            Section("安全提示") {
                Text("请在本机粘贴密钥。不要把密钥发到聊天、邮件或截图。密钥仅写入 macOS 钥匙串。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Claude OAuth（可选覆盖）") {
                SecureField("Claude OAuth access token（需 user:profile）", text: $claudeToken)
                Text("推荐：先用 Claude Code 登录，应用会读取 ~/.claude/.credentials.json。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("写入钥匙串") { saveSecret(claudeToken, account: CredentialAccount.claudeOAuthOverride) }
            }
            Section("Cursor") {
                SecureField("Cursor Cookie 或 WorkosCursorSessionToken", text: $cursorCookie)
                Text("从已登录的 cursor.com 开发者工具复制 Cookie 头；应用不会自动提取浏览器会话。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("写入钥匙串") { saveSecret(cursorCookie, account: CredentialAccount.cursorSessionCookie) }
            }
            Section("GitHub Copilot") {
                SecureField("GitHub token（read:user）", text: $copilotToken)
                Text("也可用 GitHub device flow 自行生成 token 后粘贴。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("写入钥匙串") { saveSecret(copilotToken, account: CredentialAccount.copilotGitHubToken) }
            }
            Section("OpenRouter / Anthropic Admin") {
                SecureField("OpenRouter API Key", text: $openRouterKey)
                Button("保存 OpenRouter") { saveSecret(openRouterKey, account: CredentialAccount.openRouterAPIKey) }
                SecureField("Anthropic Admin Key (sk-ant-admin…)", text: $anthropicAdminKey)
                Button("保存 Admin Key") { saveSecret(anthropicAdminKey, account: CredentialAccount.anthropicAdminKey) }
            }
            Section("CLI 凭证路径（只读）") {
                labeledPath("Claude", "~/.claude/.credentials.json")
                labeledPath("Codex", "~/.codex/auth.json")
                labeledPath("Gemini", "~/.gemini/oauth_creds.json")
                labeledPath("Cursor Agent", "~/.config/cursor/auth.json")
            }
        }
    }

    private var coverageTab: some View {
        List(ProviderRegistry.allDescriptors) { d in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(d.displayName).font(.headline)
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

    private func saveSecret(_ value: String, account: String) {
        #if os(macOS)
        let store = KeychainCredentialStore()
        do {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            try store.setSecret(trimmed.isEmpty ? nil : trimmed, account: account)
            saveMessage = "已写入钥匙串（\(account)）"
            // Clear field so secret doesn't linger in UI state longer than needed.
            switch account {
            case CredentialAccount.claudeOAuthOverride: claudeToken = ""
            case CredentialAccount.cursorSessionCookie: cursorCookie = ""
            case CredentialAccount.copilotGitHubToken: copilotToken = ""
            case CredentialAccount.openRouterAPIKey: openRouterKey = ""
            case CredentialAccount.anthropicAdminKey: anthropicAdminKey = ""
            default: break
            }
        } catch {
            saveMessage = "钥匙串写入失败：\(error.localizedDescription)"
        }
        #endif
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AIQuoty")
                    .font(.system(.title, design: .serif).weight(.semibold))
                Text("仪表盘")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("刷新") { Task { await model.refresh(force: true) } }
                    .keyboardShortcut("r", modifiers: [.command])
            }
            .padding()
            Divider()
            List {
                ForEach(model.state.snapshots) { snap in
                    AccountCard(snapshot: snap) {
                        model.togglePin(snap.account.id)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
            }
            .listStyle(.inset)
        }
        .background(Palette.popoverBackground)
    }
}
#endif
