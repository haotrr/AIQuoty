import Foundation

public struct DetectedLocalAgent: Codable, Sendable, Equatable, Identifiable {
    public var id: String { providerID }
    public var providerID: String
    public var displayName: String
    public var category: String
    public var matchedPaths: [String]
    public var setupHint: String

    public init(
        providerID: String,
        displayName: String,
        category: String,
        matchedPaths: [String],
        setupHint: String
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.category = category
        self.matchedPaths = matchedPaths
        self.setupHint = setupHint
    }
}

/// Detects locally installed AI Agent desktop apps, CLIs, and IDE extensions
/// via read-only path existence checks (never reads browser cookies or decrypts secrets).
public enum LocalAgentDetector {
    private struct Rule {
        let providerID: String
        let displayName: String
        let category: String
        let paths: [String]
        let setupHint: String
    }

    private static let rules: [Rule] = [
        Rule(
            providerID: "claude",
            displayName: "Claude / Claude Code",
            category: "主力订阅 / IDE Agent",
            paths: [
                "/Applications/Claude.app",
                "~/.claude",
                "~/Library/Application Support/Claude",
            ],
            setupHint: "运行 claude 登录（自动读取钥匙串或 ~/.claude/.credentials.json），或在设置中填入 OAuth Token。"
        ),
        Rule(
            providerID: "codex",
            displayName: "Codex",
            category: "主力订阅 / IDE Agent",
            paths: [
                "/Applications/Codex.app",
                "~/.codex",
                "~/Library/Application Support/Codex",
                "~/Library/Application Support/com.openai.codex",
            ],
            setupHint: "运行 codex login 生成 ~/.codex/auth.json 即可自动读取。"
        ),
        Rule(
            providerID: "cursor",
            displayName: "Cursor",
            category: "主力订阅 / IDE Agent",
            paths: [
                "/Applications/Cursor.app",
                "~/.cursor",
                "~/Library/Application Support/Cursor",
                "~/.config/cursor",
            ],
            setupHint: "点「终端登录」运行 cursor-agent login（自动读钥匙串 cursor-access-token），或点「配置」粘贴 Cookie。"
        ),
        Rule(
            providerID: "antigravity",
            displayName: "Antigravity",
            category: "主力订阅 / IDE Agent",
            paths: [
                "/Applications/Antigravity.app",
                "/Applications/Antigravity IDE.app",
                "~/.gemini/antigravity",
                "~/Library/Application Support/Antigravity",
                "~/Library/Application Support/antigravity",
            ],
            setupHint: "登录 Antigravity 桌面端即可自动读取 state.vscdb，无需填写 Key；也支持在设置中配置 OAuth。"
        ),
        Rule(
            providerID: "gemini",
            displayName: "Gemini / Gemini CLI",
            category: "主力订阅 / IDE Agent",
            paths: [
                "/Applications/Gemini.app",
                "~/.gemini/oauth_creds.json",
                "~/Library/Application Support/com.google.GeminiMacOS",
            ],
            setupHint: "点「一键登录」通过浏览器授权（自动续期），或运行 gemini CLI 登录。"
        ),
        Rule(
            providerID: "opencode",
            displayName: "OpenCode",
            category: "主力订阅 / IDE Agent",
            paths: [
                "/Applications/OpenCode.app",
                "~/.local/share/opencode",
                "~/.config/opencode",
                "~/.opencode",
            ],
            setupHint: "支持读取 ~/.local/share/opencode/auth.json、OpenCode Console Key 及本地会话日志。"
        ),
        Rule(
            providerID: "deepseek",
            displayName: "DeepSeek / DeepSeek Harness",
            category: "国产 / 编程套餐 & API",
            paths: [
                "/Applications/DeepSeek Harness.app",
                "~/.dsh",
                "~/Library/Application Support/@deepseek-ai",
                "~/.deepseek",
                "~/.config/deepseek",
            ],
            setupHint: "登录 DeepSeek Harness 后自动读取 ~/.dsh/.credentials.yaml 余额，也支持在设置中填入 DeepSeek API Key。"
        ),
        Rule(
            providerID: "copilot",
            displayName: "GitHub Copilot",
            category: "主力订阅 / IDE Agent",
            paths: [
                "~/.copilot",
                "~/.config/github-copilot",
                "~/.config/gh/hosts.yml",
            ],
            setupHint: "点「一键登录」通过 GitHub Device Flow 授权，或登录 Copilot CLI。"
        ),
        Rule(
            providerID: "windsurf",
            displayName: "Windsurf",
            category: "主力订阅 / IDE Agent",
            paths: [
                "/Applications/Windsurf.app",
                "~/.codeium/windsurf",
                "~/Library/Application Support/Windsurf",
            ],
            setupHint: "在设置中填入 Windsurf / Codeium API Key 或配置文件路径。"
        ),
        Rule(
            providerID: "kimi-code",
            displayName: "Kimi Code / Moonshot",
            category: "国产 / 编程套餐 & API",
            paths: [
                "/Applications/Kimi.app",
                "~/.kimi",
                "~/.config/kimi",
            ],
            setupHint: "在设置中填入 Kimi Code 订阅 Token 或 Moonshot API Key。"
        ),
        Rule(
            providerID: "factory-droid",
            displayName: "Factory / Droid",
            category: "主力订阅 / IDE Agent",
            paths: [
                "/Applications/Factory.app",
                "~/.factory",
                "~/.config/factory",
            ],
            setupHint: "在设置中填入 Factory API Key (fk-...) 或使用 ~/.factory/auth.json。"
        ),
        Rule(
            providerID: "grok",
            displayName: "Grok / xAI",
            category: "主力订阅 / IDE Agent",
            paths: [
                "/Applications/Grok Bot.app",
                "~/Library/Application Support/Grok Bot",
                "~/.grok",
                "~/.config/grok",
            ],
            setupHint: "在设置中填入 xAI API Key 或使用 ~/.grok/auth.json。"
        ),
        Rule(
            providerID: "cline-roo",
            displayName: "Cline / Roo Code",
            category: "本地日志（估算）",
            paths: [
                "~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev",
                "~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline",
                "~/Library/Application Support/Cursor/User/globalStorage/saoudrizwan.claude-dev",
                "~/Library/Application Support/Cursor/User/globalStorage/rooveterinaryinc.roo-cline",
            ],
            setupHint: "在设置 → 通用 中开启「导入本机 Cline / Roo 任务日志（估算 token）」。"
        ),
        Rule(
            providerID: "trae-qoder",
            displayName: "Trae / Qoder",
            category: "主力订阅 / IDE Agent",
            paths: [
                "/Applications/Trae.app",
                "/Applications/Qoder.app",
                "~/Library/Application Support/Trae",
                "~/Library/Application Support/Qoder",
                "~/.trae",
                "~/.qoder",
            ],
            setupHint: "已检测到本机安装；暂无公开稳定配额 API，后续官方开放后自动接入。"
        ),
        Rule(
            providerID: "zed",
            displayName: "Zed AI",
            category: "主力订阅 / IDE Agent",
            paths: [
                "/Applications/Zed.app",
                "~/Library/Application Support/Zed",
                "~/.config/zed",
            ],
            setupHint: "已检测到本机安装 Zed；Zed 订阅配额暂未开放公开 API，可配合各模型 API Key 监控。"
        ),
    ]

    public static func detect(fileSystem: FileSystemReading = LocalFileSystem()) -> [DetectedLocalAgent] {
        var found: [DetectedLocalAgent] = []
        for rule in rules {
            let matched = rule.paths.filter { fileSystem.fileExists(at: $0) }
            if !matched.isEmpty {
                found.append(
                    DetectedLocalAgent(
                        providerID: rule.providerID,
                        displayName: rule.displayName,
                        category: rule.category,
                        matchedPaths: matched,
                        setupHint: rule.setupHint
                    )
                )
            }
        }
        return found
    }
}
