# AIQuoty

本机优先的 **macOS 菜单栏** AI Agent 配额 / 用量监视器。

- 无 AIQuoty 云账号、无注册、无遥测
- 订阅配额 · API 花费 · 本地日志 token **三类指标严格分列**，互不伪造
- 密钥仅存 **钥匙串**；推荐复用本机已登录的 CLI 凭证
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

# 打包 .app + zip
chmod +x Scripts/build_macos.sh
Scripts/build_macos.sh
open dist/AIQuoty.app
```

首次使用：菜单栏图标 → 设置 → 连接。优先登录 Claude Code / `codex login` / Gemini CLI / `cursor-agent login`；或将 Cookie/Token **在本机**写入钥匙串（勿发到聊天）。

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
