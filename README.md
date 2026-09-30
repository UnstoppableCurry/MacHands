# MacHands

给你的云端 AI 代理一双 Mac 上的手，每一下都经你同意。

[English](#english)

**完全免费 · [MIT](LICENSE) 开源 · 没有付费档 · 不用买许可证**

- **官网：** <https://machands.pages.dev>
- **源码：** <https://github.com/UnstoppableCurry/MacHands>

本仓库是 **agent 桥**：菜单栏里的 Mac App，加上 CLI / MCP。不是外置磁盘管理工具。

---

## 这是什么

Claude Code、Codex、Cursor 跑在云端时，碰不到你这台机器上的 Xcode、模拟器、Safari、公证。MacHands 让它们用你自己的 Mac 干活——不用租云端 Mac，不用开「远程登录」，也不用懂 SSH。

每一条命令都经你同意。危险操作有黑名单；你可以随时暂停或撤销授权。

## 截图与演示

![一次性授权窗口](docs/media/authorize.png)

一次性授权窗口。范围、系统权限和自检都在这一页完成。窗口里的「连不上中继、稍后重试」是连**自建中继**时的状态，不是公共中继地址。本仓库不发布默认中继 URL。

<video src="docs/media/authorize.mp4" controls muted playsinline width="572">
<a href="docs/media/authorize.mp4">authorize.mp4</a>
</video>

约 9 秒，同一扇授权窗口。账号邮箱已裁掉。

## 怎么拿到

这个仓库就是入口。

| 你要什么 | 怎么拿 |
|---|---|
| **MacHands.app** | 在 Mac 上从源码构建（见下方）。签名包会在 [GitHub Releases](https://github.com/UnstoppableCurry/MacHands/releases) **有附件之后**提供。现在还没有 Release 资源，请不要去找不存在的下载地址。 |
| **CLI / MCP** | 在 agent 那台机器上：`npx -y machands`（npm 包名 [`machands`](https://www.npmjs.com/package/machands)） |

不上 Mac App Store：沙盒禁止执行任意命令、注入键鼠、截其他 App 的屏，而这些正是 MacHands 要做的事。

## 三步开始

1. 自建中继（见下方），在 MacHands 里填入它打印的地址。
2. 打开 **MacHands.app**，菜单栏出现一只手。点 **复制给 agent**。
3. 把复制到的文字贴给你的云端 agent。它会自己执行里面那一行，几秒后菜单栏显示「已连接」。

配对成功后会弹出**授权页**，只做一次：选范围（**开发者** / **只读** / **逐条审批**）→ 勾三项系统权限（通知、屏幕录制、辅助功能）→ 点 **授权并验证**。7 项自检全绿就完了。

「逐条审批」时每张卡先说**代理要干什么**，原始命令收在「详情」里。`rm -rf /`、`sudo`、`diskutil erase` 这类命令在任何模式下都会被拦住。

## 它保证什么

- 不需要打开「远程登录」，没有 sshd 暴露。执行命令的是 App 本身。
- agent 与 Mac 之间端到端加密（X25519 + ChaCha20-Poly1305），中继只见密文。
- 每条命令与你的决定都写进 `~/Library/Logs/MacHands/audit.log`。
- 授权可撤销；配对码 10 分钟有效、只能用一次。

## 中继：只走自建

没有公共托管中继。你必须自己起一台，并把地址填进 App。

```bash
sudo sh relay/install.sh
```

也可以 `npm i -g machands && machands relay start --port 8443`。起来之后它会打印要填进 Mac 的 `ws://` / `wss://` 地址。说明见 [`relay/README.md`](relay/README.md)。

## 仓库结构

| 目录 | 内容 |
|---|---|
| [`SPEC.md`](SPEC.md) | 产品与协议契约（真源） |
| [`macapp/`](macapp/) | macOS 菜单栏 App（SwiftPM, AppKit），见 [`macapp/BUILD.md`](macapp/BUILD.md) |
| [`agent/`](agent/) | npm 包 `machands`：CLI + MCP 服务器，见 [`agent/README.md`](agent/README.md) |
| [`relay/`](relay/) | 中继服务（Node + ws），自建见 [`relay/README.md`](relay/README.md) |
| [`shared/`](shared/) | 加密互通测试向量，Node 与 Swift 两边都要通过 |
| [`tools/license/`](tools/license/) | 协议里的许可证令牌工具（产品本身免费，无需购买） |
| [`site/`](site/) | 官网静态样例，不是现成的签名包 |
| [`docs/RELEASE.md`](docs/RELEASE.md) | 维护者发布手册 |
| [`docs/media/`](docs/media/) | 真机授权窗口截图与短演示 |

## 构建与测试

```bash
node --test relay/test agent/test        # Linux / Mac 都行
cd macapp && swift build && swift test   # 需要 Mac + Xcode 命令行工具
cd macapp && ./scripts/build-app.sh      # 产出 MacHands.app
open dist/MacHands.app --args --no-relay # 只起界面、不连中继
machands verify                          # 装机后自检
```

签名发布需要你自己的 Developer ID，见 [`macapp/BUILD.md`](macapp/BUILD.md) 与 [`docs/RELEASE.md`](docs/RELEASE.md)。本仓库不提供现成安装包。

## 接入 agent

配对成功后 CLI 会打印这一段；也可以随时手抄：

```
Claude Code:  claude mcp add machands -- npx -y machands mcp
Codex:        ~/.codex/config.toml 加 [mcp_servers.machands] command="npx" args=["-y","machands","mcp"]
Cursor:       Settings → MCP → Add: npx -y machands mcp
命令行:       machands run -- xcodebuild -version
```

## 许可

源码以 [MIT](LICENSE) 开源。Copyright © 2026 UnstoppableCurry。

MacHands 不是 Apple、Anthropic、OpenAI 或 xAI 的产品。

---

## English

Give your cloud AI agent a pair of hands on your Mac.

**Free. [MIT](LICENSE) licensed. No paid tier. No license to buy.**

- **Website:** <https://machands.pages.dev>
- **Source:** <https://github.com/UnstoppableCurry/MacHands>

This repository is an **agent bridge**: a menu-bar Mac app plus a CLI / MCP server. It is not a disk-relocation tool.

### What it is

Cloud agents (Claude Code, Codex, Cursor) cannot reach Xcode, simulators, Safari, or notarization on your machine. MacHands lets them use **your** Mac — no rented cloud Mac, no Remote Login, no SSH.

Every command goes through your approval. Dangerous operations are blacklisted. You can pause or revoke access at any time.

### Screenshot and demo

![One-time authorization window](docs/media/authorize.png)

One-time authorization window. Scope, system permissions, and self-checks live on this page. The “cannot reach relay, retrying” line is the app talking to **your self-hosted relay**, not a public default. This repository does not publish a default relay URL.

<video src="docs/media/authorize.mp4" controls muted playsinline width="572">
<a href="docs/media/authorize.mp4">authorize.mp4</a>
</video>

About 9 seconds, the same window. The account email was cropped out.

### How to get it

This repository is the distribution entry.

| You want | How |
|---|---|
| **MacHands.app** | Build from source on a Mac (below). Signed binaries will appear on [GitHub Releases](https://github.com/UnstoppableCurry/MacHands/releases) **when an asset is published**. None exist yet — do not look for a download URL that is not there. |
| **CLI / MCP** | On the agent machine: `npx -y machands` (npm package [`machands`](https://www.npmjs.com/package/machands)) |

There is no Mac App Store build. The sandbox forbids arbitrary commands, input injection, and capturing other apps — which is the whole product.

### Three steps

1. Self-host a relay (below) and paste the address it prints into MacHands.
2. Open **MacHands.app**. A hand appears in the menu bar. Click **Copy for agent**.
3. Paste that block into your cloud agent. It runs the one-liner inside. The menu bar shows **Connected**.

After pairing, an **authorization page** appears once: pick a scope (Developer / Read-only / Ask every time) → grant Notifications, Screen Recording, and Accessibility → **Authorize & verify**. Seven self-checks should go green.

In Ask mode, each card leads with **what the agent wants to do**; the raw command sits under Details. Commands like `rm -rf /`, `sudo`, and `diskutil erase` are blocked in every mode.

### What it guarantees

- Remote Login / sshd is not required. The app itself runs commands.
- Agent ↔ Mac traffic is end-to-end encrypted (X25519 + ChaCha20-Poly1305). The relay sees ciphertext only.
- Every command and your decision is written to `~/Library/Logs/MacHands/audit.log`.
- Authorization is revocable. Pairing codes last 10 minutes and work once.

### Relay: self-host only

There is no public hosted relay. You must run your own and set that URL in the app.

```bash
sudo sh relay/install.sh
```

Or `npm i -g machands && machands relay start --port 8443`. The process prints the `ws://` / `wss://` address to paste into MacHands. Details: [`relay/README.md`](relay/README.md).

### Build and test

```bash
node --test relay/test agent/test
cd macapp && swift build && swift test
cd macapp && ./scripts/build-app.sh
```

Signed releases need your own Developer ID. See [`macapp/BUILD.md`](macapp/BUILD.md) and [`docs/RELEASE.md`](docs/RELEASE.md). This repository does not ship a ready-made installer.

### Connect an agent

```
Claude Code:  claude mcp add machands -- npx -y machands mcp
Codex:        ~/.codex/config.toml → [mcp_servers.machands] command="npx" args=["-y","machands","mcp"]
Cursor:       Settings → MCP → Add: npx -y machands mcp
CLI:          machands run -- xcodebuild -version
```

### License

[MIT](LICENSE). Copyright © 2026 UnstoppableCurry.

MacHands is not a product of Apple, Anthropic, OpenAI, or xAI.
