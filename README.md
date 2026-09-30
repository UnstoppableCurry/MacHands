# MacHands

Give your cloud AI agent a pair of hands on your Mac.

**给你的云端 AI 代理一双 Mac 上的手，每一下都经你同意。**

MacHands 是开源的 **agent 桥**：菜单栏里的 Mac App，加上 CLI / MCP。云端的 Claude Code、Codex、Cursor 碰不到你这台机器上的 Xcode、模拟器、Safari、公证；装上之后，它们用的是你自己的 Mac——不用租云端 Mac，不用开「远程登录」，也不用懂 SSH。

本仓库就是这套桥，不是外置磁盘管理工具。

**完全免费，以 [MIT](LICENSE) 开源。没有付费档，不用买许可证。**

- **官网：** <https://machands.pages.dev>
- **源码：** <https://github.com/UnstoppableCurry/MacHands>

预定域名 `machands.app` 目前无法解析，请用上面的官网。镜像：<https://unstoppablecurry.github.io/machands-site/>。

## 怎么拿到

这个仓库就是入口。

| 你要什么 | 怎么拿 |
|---|---|
| **MacHands.app** | 在 Mac 上从源码构建（见下方）。签名包会在 [GitHub Releases](https://github.com/UnstoppableCurry/MacHands/releases) **有资源之后**提供；现在还没有 Release 附件，请不要去找不存在的下载地址。 |
| **CLI / MCP** | 在 agent 那台机器上：`npx -y machands`（npm 包名 [`machands`](https://www.npmjs.com/package/machands)） |

不上 Mac App Store：沙盒禁止执行任意命令、注入键鼠、截其他 App 的屏，而这些正是 MacHands 要做的事。

## 用户只做三步

1. 打开 **MacHands.app**，菜单栏出现一只手。
2. 点 **复制给 agent**。
3. 把复制到的文字贴给你的云端 agent。它会自己执行里面那一行，几秒后菜单栏显示「已连接」。

配对成功后 MacHands 会弹出**授权页**，只需要做一次：选范围（**开发者** 全部允许、**只读** 只能看、**逐条审批** 每条都问）→
三项系统权限（通知 / 屏幕录制 / 辅助功能）各有「打开设置」→ 点 **授权并验证**，7 项自检全绿就完了。
之后不再打扰；危险命令黑名单（`rm -rf /`、`sudo`、`diskutil erase`…）在任何模式下都生效，随时可以「暂停」。
「逐条审批」模式下每条命令弹一张卡：卡上先说**代理要干什么**，原始命令收在「详情」里。

## 它保证什么

- 不需要打开「远程登录」，没有 sshd 暴露。执行命令的是 App 本身。
- agent 与 Mac 之间端到端加密（X25519 + ChaCha20-Poly1305），中继只见密文。
- 每条命令与你的决定都写进 `~/Library/Logs/MacHands/audit.log`。
- 授权可撤销；配对码 10 分钟有效、只能用一次。

## 仓库结构

| 目录 | 内容 |
|---|---|
| [`SPEC.md`](SPEC.md) | 产品与协议契约（真源） |
| [`macapp/`](macapp/) | macOS 菜单栏 App（SwiftPM, AppKit），见 [`macapp/BUILD.md`](macapp/BUILD.md) |
| [`agent/`](agent/) | npm 包 `machands`：CLI + MCP 服务器，见 [`agent/README.md`](agent/README.md) |
| [`relay/`](relay/) | 中继服务（Node + ws），自建见 [`relay/README.md`](relay/README.md) |
| [`shared/`](shared/) | 加密互通测试向量，Node 与 Swift 两边都要通过 |
| [`tools/license/`](tools/license/) | 协议里的许可证令牌签发 / 校验（产品本身免费，无需购买） |
| [`site/`](site/) | 官网静态样例（下载页与 `appcast.json` 格式），不是现成的签名包 |
| [`docs/RELEASE.md`](docs/RELEASE.md) | 维护者发布手册（证书、公证、appcast） |

## 构建与测试

```bash
node --test relay/test agent/test        # Linux / Mac 都行
cd macapp && swift build && swift test   # 需要 Mac + Xcode 命令行工具
cd macapp && ./scripts/build-app.sh      # 产出 MacHands.app
open dist/MacHands.app --args --no-relay # 只起界面、不连中继（界面调试副本；或 MACHANDS_NO_RELAY=1）
machands verify                          # 装机后自检：run/fs/screen/input/notify/job/mcp 七项
```

维护者签名发布（需要你自己的 Developer ID，**不会**在本仓库提供现成安装包）：

```bash
cd macapp && ./scripts/keygen-release.sh # 一次：生成发布签名密钥（自动更新验签用）
cd macapp && ./scripts/release.sh \
  --sign "Developer ID Application: 名字 (TEAMID)" \
  --keychain-profile machands-notary
```

细节见 [`macapp/BUILD.md`](macapp/BUILD.md) 与 [`docs/RELEASE.md`](docs/RELEASE.md)。协议见 `SPEC.md`。

## 接入 agent

配对成功后 CLI 会打印这一段；也可以随时手抄：

```
Claude Code:  claude mcp add machands -- npx -y machands mcp
Codex:        ~/.codex/config.toml 加 [mcp_servers.machands] command="npx" args=["-y","machands","mcp"]
Cursor:       Settings → MCP → Add: npx -y machands mcp
命令行:       machands run -- xcodebuild -version
```

## 中继

托管中继：`ws://134.199.230.126:8443`（`GET /health` 看状态）。自建：`sudo sh relay/install.sh`，说明见 [`relay/README.md`](relay/README.md)。

## 许可

源码以 [MIT](LICENSE) 开源。Copyright © 2026 UnstoppableCurry。

MacHands 不是 Apple、Anthropic、OpenAI 或 xAI 的产品。
