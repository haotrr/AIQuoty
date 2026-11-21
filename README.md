# AIQuoty

本机优先的 **macOS 菜单栏** AI Agent 配额 / 用量监视器。

- 无 AIQuoty 云账号、无注册、无遥测
- 订阅配额 · API 花费 · 本地日志 token **三类指标严格分列**，互不伪造
- 覆盖主流 Agent：Claude Code、Codex、Cursor、Antigravity、Gemini CLI、OpenCode、DeepSeek / DeepSeek Harness、GitHub Copilot、Kimi Code、MiniMax、智谱 GLM / Z.ai、Factory / Droid、Windsurf、Grok / xAI、Cline / Roo Code、OpenRouter 等
- 支持在菜单栏自定义选择要展示的账号（自动 / 多选 / 仅图标）
- 密钥仅存 **钥匙串**（合并 vault 存储减少授权弹窗）；推荐复用本机已登录的 CLI 凭证
- 灵感来自 [AI Stats](https://aistats.coursion.studio/) 与 [CUStats](https://custats.info/)；实现与 UI 为原创
- 数据路径参考 MIT 许可的 [CodexBar](https://github.com/steipete/CodexBar) 公开文档（见 `THIRD_PARTY.md`）

## 架构选型（简）

1. **单体 MenuBarController**：UI 直接拥有网络与刷新 — 难测、边界糊。
2. **`AIQuotyCore` + 薄 App 壳（采用）**：Core 拥有模型 / Provider / **唯一** `RefreshCoordinator`；App 只负责 MenuBarExtra、设置与钥匙串录入。可在 Linux 上跑 Core 测试。

## 要求

- 应用：macOS 14+，Xcode 15+ / Swift 5.9+
- 本仓库可在 Linux 验证 Core + CLI（当前云环境即为 Linux）

## 快速开始（macOS）

```bash
# 核心测试
swift test

# 打包 .app + zip（自动选用本机 Apple Development 签名）
chmod +x Scripts/build_macos.sh
Scripts/build_macos.sh
open dist/AIQuoty.app

# 或直接使用 Xcode 打开
open AIQuoty.xcodeproj
```

首次使用：菜单栏图标 → 设置 → 连接。支持自动探测并复用 Claude Code / `codex login` / `cursor-agent login` / `gh auth login` / DeepSeek Harness (`~/.dsh/.credentials.yaml`) / Gemini CLI / OpenCode 等本机登录态；也支持 GitHub / Google 一键登录或在设置中将密钥写入本机钥匙串。

可选：打开「演示模式」查看合成夹具 UI（非真实用量）。

## Linux / CI 验证

```bash
chmod +x Scripts/test_linux.sh
Scripts/test_linux.sh
```

## 文档

| 文档 | 说明 |
| --- | --- |
| [docs/覆盖矩阵.md](docs/覆盖矩阵.md) | 已实现指标 / 鉴权 / 测试状态 / 限制 |
| [docs/架构.md](docs/架构.md) | Provider 边界与刷新所有权 |
| [docs/设置指南.md](docs/设置指南.md) | 安全配置步骤 |
| [docs/验证报告.md](docs/验证报告.md) | 本环境实测证据与缺口 |
| [THIRD_PARTY.md](THIRD_PARTY.md) | 致谢与许可 |

## 许可

MIT（见 `LICENSE`）
