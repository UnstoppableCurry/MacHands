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

## 一次授权(0.2 起,只做一次)

配对成功后 Mac 上的 MacHands 窗口会自己弹出授权页,只需要点一次:

1. agent 这边:`machands pair "MH1.…"`。
2. Mac 上:在弹出的窗口里选一个范围 —— **开发者**(全部允许,危险命令仍被黑名单拦下,推荐)/ **只读** / **逐条审批**,
   按窗口里的三行提示把 **屏幕录制、辅助功能、通知** 三个系统权限勾上,点 **授权并验证**。
3. agent 这边再跑一次验证,全部 ✓ 就完事了,以后不再打扰:

   ```
   machands verify
   ✓ run     machands-ok
   ✓ fs      write+read 23 bytes
   ✓ screen  1728×1117
   ✓ input   move → (640,400)
   ✓ notify  authorized
   ✓ job     code=0 out=hi
   ✓ mcp     3 servers configured
   全部通过:agent 可以在这台 Mac 上干活了。
   ```

   有 ✗ 的项后面跟着 → 修复指引(通常是系统设置里某个开关),处理完再跑 `machands verify`;全过退出码 0。
   `machands perms` 单看三个系统权限,`machands check -- <命令>` 问一句会不会被放行而不执行。

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
| `machands use <mac>` | 设默认 Mac,之后不用再写 `--mac`;打印 `default mac: <名字>` |
| `machands verify [--json]` | 一次授权后的验证:每项 `✓ 名字  细节` / `✗ 名字  细节 → 修法`;全过退出 0 |
| `machands perms [--json]` | 系统权限状态,每行 `screen/accessibility/notifications: yes\|no\|unknown`,没过的在 stderr 给修法 |
| `machands info` | 开工体检:机型、系统、内存、磁盘、CPU/GPU、显示器、常用工具在不在、App 版本;拿不到的显示 `—` |
| `machands which [工具...]` | 工具路径,每行 `名字: 路径\|-`;不给名字就查默认那一串(godot blender xcodebuild swift node python3 brew cliclick ffmpeg git) |
| `machands check -- <命令>` | 只问这条命令会 `allow` / `ask` / `deny`,不执行;deny 时附原因并退出 77 |
| `machands policy [--json]` | Mac 当前审批模式与黑白名单 |
| `machands run [--cwd D] [--timeout S] -- <命令...>` | 在 Mac 上执行,输出实时透传,退出码原样返回;超时回 124(整棵进程树一起杀) |
| `machands job submit [--cwd D] [--timeout S] -- <命令>` | 后台作业,stdout 只有一行 jobId。默认 1 小时超时 |
| `machands job status <id>` / `job list` | 一行:`jobId 状态 code=… 毫秒 命令`;状态 running / exited / killed / orphaned |
| `machands job tail <id> [--err] [--follow]` | 原样写出 stdout(`--err` 看 stderr);`--follow` 每秒轮询直到读完且作业结束 |
| `machands job result <id> [--wait S]` | 等作业结束并打印状态;进程退出码 = 作业退出码(超出 0–255 归 1)。不给 `--wait` 就一直等 |
| `machands job kill <id>` | 终止作业及其子进程 |
| `machands session open [命令] [--cwd D]` | 交互式会话(默认 zsh),stdout 只有 sessionId |
| `machands session write <id> <文本>` | 往会话 stdin 写;`\n` 会变成回车,`--raw` 不转义 |
| `machands session read <id> [--offset N]` | stdout 是会话输出,stderr 一行 `offset=N eof=… alive=…` |
| `machands session close <id>` | 关会话 |
| `machands put <本地> <远端>` | 上传。给的是目录就自动打包再在 Mac 上解开 |
| `machands get <远端> [-o 本地] [--no-extract]` | 下载,自动分块;远端是目录就打成 tar.gz 传回并解到 `-o`(目录名保留,和 put 一致) |
| `machands ls [路径] [--depth N]` | 看目录 |
| `machands shot [-o out.png] [--scale 0.5] [--display 0]` | 截屏,存成真 PNG |
| `machands window-shot [--app 名] [--title 标题] [-o out.png] [--scale 1] [--format png\|jpg]` | 只截一个窗口:前台的,或按 App 名 / 标题匹配 |
| `machands record [--seconds 5] [--display 0] -o out.mov` | 录屏(≤120 秒),.mov |
| `machands input where` | 鼠标现在在哪,打印 `X Y` |
| `machands input move X Y` / `click X Y [--right] [--double]` | 移动、点按(坐标是屏幕像素,左上角为原点) |
| `machands input drag X1 Y1 X2 Y2 [--ms 300]` / `scroll X Y DX DY` | 拖拽、滚动 |
| `machands input key <键> [--mods cmd,shift,alt,ctrl]` / `type <文本>` | 按键(也认 `cmd+shift+s`)、敲字 |
| `machands open <网址或路径>` | 等于在 Mac 上敲 `open` |
| `machands clip [get \| set <文本>]` | 读写 Mac 剪贴板 |
| `machands notify <标题> [正文]` | 在 Mac 上弹一条通知 |
| `machands power on [--seconds 3600] \| off` | 让 Mac 保持唤醒(caffeinate),跑长任务前开 |
| `machands relaunch` | 让 MacHands.app 自己重启(升级后用) |
| `machands mcp` | 以 stdio MCP 服务器运行(协议 2025-06-18) |
| `machands mcp servers` | Mac 上各家 agent 已配置的 MCP 服务器(名字 / 来源 / 命令,不含 env 值) |
| `machands mcp open <名字>` / `open --command CMD [--args '["…"]']` | 借 Mac 的手起一个 MCP 服务器,stdout 只有 sid,工具名在 stderr |
| `machands mcp list <sid>` / `call <sid> <工具> ['{…}']` / `close <sid>` | 列工具、调工具(文本内容直接打印,`isError` 时退出 1)、关 |
| `machands forget <mac>` | 本地删掉这台 Mac 的配对(Mac 上的授权要在 App 设置里撤销) |
| `machands doctor` | 自检:身份文件、中继可达、Mac 在不在线 |

公共参数:`--mac <名字>` 指定哪台 Mac、`--json` 输出机器可读的 JSON、`--help`、`--version`。

**默认 Mac**:只配了一台就是它;多台用 `machands use <mac>`、`--mac` 或环境变量 `MACHANDS_MAC`。

**退出码**:0 成功;`run` / `job result` 原样返回 Mac 上命令的退出码(超时 124);被拒绝 77(含只读模式下的写操作、`check` 的 deny),审批超时 78,Mac 离线 69,还没配对 66。

## MCP 工具

`machands mcp` 暴露这些工具:`mac_info`、`mac_run`、`mac_put`、`mac_get`(循环分块到 eof,目录返回解包后的清单)、`mac_ls`、
`mac_screenshot`(直接返回 PNG 图片)、`mac_open`、`mac_clipboard_get`、`mac_clipboard_set`、
`mac_notify`、`mac_list`;0.2 新增 `mac_verify`、`mac_perms`、`mac_check`、`mac_job_*`、`mac_input_*`、
`mac_record`、`mac_window_shot`、`mac_mcp_*`、`mac_power_assert`、`mac_policy_check`(以 `tools/list` 返回的为准)。

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

**Authorize once (0.2+)**: after `pair`, the MacHands window on the Mac shows an authorization page —
pick a scope (Developer / Read-only / Ask), tick Screen Recording, Accessibility and Notifications,
click **Authorize & verify**. Then run `machands verify` here: every row `✓`, exit 0, and it never asks again.
New in 0.2: `use`, `verify`, `perms`, `which`, `check`, `policy`, background `job …`, interactive `session …`,
`input …` (mouse/keyboard), `record`, `window-shot`, `mcp servers|open|list|call|close`, `power on|off`, `relaunch`,
and `get` of a whole folder.

Every frame between agent and Mac is end-to-end encrypted (X25519 + ChaCha20-Poly1305);
the relay only forwards ciphertext. Identity lives in `~/.machands/` with mode 0600.
Exit codes: 0 ok, the command's own code for `run`, 77 denied, 78 approval timeout,
69 Mac offline, 66 not paired. Set `MACHANDS_LANG=en` for English output.
