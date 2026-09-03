# MacHands

**给你的云端 AI 代理一双 Mac 上的手,每一下都经你同意。**

Claude Code、Codex、Cursor 这些代理跑在云端时碰不到 Xcode、模拟器、Safari、公证。
MacHands 让它们用你自己的 Mac 干这些活,不用租 Mac,不用开远程登录,不用懂 SSH。

## 用户只做三步

1. 下载并打开 **MacHands.app**,菜单栏出现一只手。
2. 点 **复制给 agent**。
3. 把复制到的文字贴给你的云端 agent。它会自己执行里面那一行,几秒后菜单栏显示"已连接"。

之后 agent 每次要在 Mac 上执行命令、写文件、打开网址,你的 Mac 右上角都会弹一张卡:
**允许一次 / 允许 1 小时 / 总是允许这条 / 拒绝**(数字键 1-4)。
不想被问就在菜单里切到"自动",危险命令黑名单仍然生效。随时可以"暂停"。

## 它保证什么

- 不需要打开"远程登录",没有 sshd 暴露。执行命令的是 App 本身。
- agent 与 Mac 之间端到端加密(X25519 + ChaCha20-Poly1305),中继只见密文。
- 每条命令与你的决定都写进 `~/Library/Logs/MacHands/audit.log`。
- 授权可撤销;配对码 10 分钟有效、只能用一次。

## 仓库结构

| 目录 | 内容 |
|---|---|
| `SPEC.md` | 产品与协议契约(真源) |
| `macapp/` | macOS 菜单栏 App(SwiftPM,AppKit),见 `macapp/BUILD.md` |
| `agent/` | npm 包 `machands`:CLI + MCP 服务器,见 `agent/README.md` |
| `relay/` | 中继服务(Node + ws),自建见 `relay/README.md` |
| `shared/` | 加密互通测试向量,Node 与 Swift 两边都要通过 |
| `tools/license/` | 许可证签发与校验 |

## 开发者

```bash
node --test relay/test agent/test        # Linux/Mac 都行,约 12 秒
cd macapp && swift build && swift test   # 需要 Mac + Xcode 命令行工具
cd macapp && ./scripts/build-app.sh      # 产出 MacHands.app
cd macapp && ./scripts/release.sh        # Developer ID 签名 + 公证 + DMG
```

托管中继:`ws://134.199.230.126:8443`(`GET /health` 看状态)。自建:`sudo sh relay/install.sh`。

## 接入 agent

配对成功后 CLI 会打印这一段;也可以随时手抄:

```
Claude Code:  claude mcp add machands -- npx -y machands mcp
Codex:        ~/.codex/config.toml 加 [mcp_servers.machands] command="npx" args=["-y","machands","mcp"]
Cursor:       Settings → MCP → Add: npx -y machands mcp
命令行:      machands run -- xcodebuild -version
```

MacHands 不是 Apple、Anthropic、OpenAI 或 xAI 的产品。
