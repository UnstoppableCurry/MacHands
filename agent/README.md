# machands · 给你的云端 agent 一双 Mac 上的手

装在**云端 agent 所在的机器**上(VPS、Claude Code 的沙箱、CI)。Mac 上跑的是 MacHands.app,不是这个包。

## 三步

1. 在 Mac 上打开 MacHands.app,点 **复制给 agent**。
2. 把复制到的那段文字整段贴给你的 agent(Claude Code / Codex / Cursor,谁都行)。
3. agent 执行里面那一行:

   ```
   npx -y machands@latest pair "MH1.…"
   ```

   几秒后它会打印 `已连接 <你的 Mac 名字>`,Mac 菜单栏那只手变成实心。

从此 agent 可以在这台 Mac 上执行命令、传文件、截屏、开网址、读写剪贴板。
每一条命令都按 Mac 上的审批策略走;默认逐条问你,一键可切自动。

配对成功后 CLI 会打印一段可以直接复制的接入提示:

```
Claude Code:  claude mcp add machands -- npx -y machands mcp
Codex:        在 ~/.codex/config.toml 加 [mcp_servers.machands] command="npx" args=["-y","machands","mcp"]
Cursor:       Settings → MCP → Add: npx -y machands mcp
也可以直接用命令行:machands run -- xcodebuild -version
```

## 命令一览

| 命令 | 干什么 |
|---|---|
| `machands pair "<配对码>"` | 连接并配对,写 `~/.machands/`。配对码 10 分钟有效、只能用一次。加 `--default` 把这台设为默认 |
| `machands macs` | 列出已配对的 Mac 和在线状态,带 `*` 的是默认那台 |
| `machands run [--cwd D] [--timeout S] -- <命令...>` | 在 Mac 上执行,输出实时透传,退出码原样返回 |
| `machands put <本地> <远端>` | 上传。给的是目录就自动打包再在 Mac 上解开 |
| `machands get <远端> [本地]` | 下载,自动分块 |
| `machands ls [路径] [--depth N]` | 看目录 |
| `machands shot [-o out.png] [--scale 0.5] [--display 0]` | 截屏,存成真 PNG |
| `machands open <网址或路径>` | 等于在 Mac 上敲 `open` |
| `machands clip [get \| set <文本>]` | 读写 Mac 剪贴板 |
| `machands notify <标题> [正文]` | 在 Mac 上弹一条通知 |
| `machands info` | 机型、系统、架构、Xcode / Node / Python 版本,拿不到的显示 `—` |
| `machands mcp` | 以 stdio MCP 服务器运行(协议 2025-06-18) |
| `machands forget <mac>` | 本地删掉这台 Mac 的配对(Mac 上的授权要在 App 设置里撤销) |
| `machands doctor` | 自检:身份文件、中继可达、Mac 在不在线 |

公共参数:`--mac <名字>` 指定哪台 Mac、`--json` 输出机器可读的 JSON、`--help`、`--version`。

**默认 Mac**:只配了一台就是它;多台用 `--mac` 或环境变量 `MACHANDS_MAC`。

**退出码**:0 成功;`run` 原样返回 Mac 上命令的退出码;被拒绝 77,审批超时 78,Mac 离线 69,还没配对 66。

## MCP 工具

`machands mcp` 暴露这些工具:`mac_info`、`mac_run`、`mac_put`、`mac_get`、`mac_ls`、
`mac_screenshot`(直接返回 PNG 图片)、`mac_open`、`mac_clipboard_get`、`mac_clipboard_set`、
`mac_notify`、`mac_list`。

## 文件与隐私

- `~/.machands/identity.json`(0600):这台 agent 的 Ed25519 + X25519 密钥,首次 `pair` 时生成。
- `~/.machands/pairings.json`(0600):配对过的 Mac、它们的公钥和中继地址。
- 换一个 `MACHANDS_HOME` 就能开一份干净的身份(测试很有用)。
- agent ↔ Mac 之间每一帧都是 X25519 + ChaCha20-Poly1305 端到端加密,**中继只转发密文**,看不见内容。

## 出了问题

| 现象 | 怎么办 |
|---|---|
| `连不上中继` | 网络不通或中继没开。`machands doctor` 看一眼;自建中继确认 `/health` 有响应 |
| `Mac 不在线` | 那台 Mac 睡着了,或者 MacHands.app 没在跑(菜单栏没有那只手) |
| `这个配对码已经用过了` | 配对码只能用一次。回 Mac 上再点一次「复制给 agent」 |
| `这个配对码过期了` | 超过 10 分钟了,同上 |
| 命令返回 77 | Mac 上点了拒绝,或者命中了黑名单 |
| 命令返回 78 | 审批卡 120 秒没人理 |

## 开发

```bash
npm install            # 只有一个依赖:ws
node --test test       # 需要仓库里的 relay/ 一起在
```

`test/fake-mac.mjs` 是一个能在 Linux 上跑的假 Mac,手工玩也行:

```bash
node ../relay/server.mjs &                       # 起一个本地中继
node test/fake-mac.mjs --relay 127.0.0.1:8443    # 打印一段真配对码
MACHANDS_HOME=/tmp/a node bin/machands.mjs pair "MH1.…"
MACHANDS_HOME=/tmp/a node bin/machands.mjs run -- uname -a
```

---

## English

`machands` runs on the machine where your **cloud agent** lives, not on the Mac.

1. On the Mac, open MacHands.app and click **复制给 agent** (Copy for agent).
2. Paste the whole blob to your agent.
3. The agent runs `npx -y machands@latest pair "MH1.…"` and is connected.

Then: `machands run -- xcodebuild -version`, `machands put/get`, `machands shot`,
or wire it up as an MCP server with `claude mcp add machands -- npx -y machands mcp`.

Every frame between agent and Mac is end-to-end encrypted (X25519 + ChaCha20-Poly1305);
the relay only forwards ciphertext. Identity lives in `~/.machands/` with mode 0600.
Exit codes: 0 ok, the command's own code for `run`, 77 denied, 78 approval timeout,
69 Mac offline, 66 not paired. Set `MACHANDS_LANG=en` for English output.
