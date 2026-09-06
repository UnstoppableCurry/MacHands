# MacHands

**给你的云端 AI 代理一双 Mac 上的手,每一下都经你同意。**

Claude Code、Codex、Cursor 这些代理跑在云端时碰不到 Xcode、模拟器、Safari、公证。
MacHands 让它们用你自己的 Mac 干这些活,不用租 Mac,不用开远程登录,不用懂 SSH。

## 用户只做三步

1. 下载并打开 **MacHands.app**,菜单栏出现一只手。
2. 点 **复制给 agent**。
3. 把复制到的文字贴给你的云端 agent。它会自己执行里面那一行,几秒后菜单栏显示"已连接"。

配对成功后 MacHands 会弹出**授权页**,只需要做一次:选范围(**开发者** 全部允许、**只读** 只能看、**逐条审批** 每条都问)→
三项系统权限(通知 / 屏幕录制 / 辅助功能)各有「打开设置」→ 点 **授权并验证**,7 项自检全绿就完了。
之后不再打扰;危险命令黑名单(`rm -rf /`、`sudo`、`diskutil erase`…)在任何模式下都生效,随时可以"暂停"。
"逐条审批"模式下每条命令弹一张卡:**允许一次 / 允许 1 小时 / 总是允许这条 / 拒绝**(数字键 1-4)。
注意:macOS 在 App **更新后会重置「屏幕录制」授权**,升级后重新勾一次即可。

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
open dist/MacHands.app --args --no-relay # 只起界面、不连中继(界面调试副本;或 MACHANDS_NO_RELAY=1)
machands verify                          # 装机后自检:run/fs/screen/input/notify/job/mcp 七项
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
