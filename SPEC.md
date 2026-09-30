# MacHands · 产品与协议契约 v1(2026-09-03 定稿)

一句话:**给你的云端 AI 代理一双 Mac 上的手,每一下都经你同意。**

用户全程三步,再多一步都算 bug:
1. 下载并打开 MacHands.app(菜单栏出现一只手)。
2. 点"复制给 agent",得到一段文字。
3. 把这段文字贴给云端 agent(Claude Code / Codex / Cursor / 任何能跑命令的 agent)。
   agent 自己会执行里面的一行命令,几秒后 Mac 菜单栏变成"已连接 · Claude@vps"。

从此 agent 可以:在 Mac 上执行命令、传文件、截屏、打开网址、读写剪贴板、跑 Xcode 构建和模拟器。
每一条命令都经过审批策略;默认"逐条问",一键可切"自动"。

---

## 0. 铁律

1. **不需要打开"远程登录"**,不需要 sshd。App 自己执行命令,自己就是隧道端。
2. **中继看不见内容**:agent ↔ Mac 之间的每一帧都用 X25519 + ChaCha20-Poly1305 端到端加密。中继只转发密文。
3. **任何面向用户的字符串走 i18n**(zh / en 两种,zh 兜底),不写裸中文进逻辑。
4. **不编造状态**:连不上就说连不上、在等什么;拿不到的值显示"—"。
5. **不抢焦点**:审批卡是浮动面板 + 通知,不激活 App、不切换 Space。
6. Node 侧只用 Node ≥ 20 内置模块 + `ws`;Swift 侧只用 Foundation/AppKit/Network/CryptoKit/ServiceManagement/UserNotifications。
7. 每个部件都要能独立测试:relay 与 agent 有 `node --test`;Swift 有 `swift test` 覆盖协议层。

---

## 1. 三个部件

| 部件 | 位置 | 语言 | 谁跑 |
|---|---|---|---|
| **App** | `macapp/` | Swift 5.9,SwiftPM,AppKit 菜单栏 | 用户的 Mac |
| **Agent CLI** | `agent/` | Node ESM,npm 包名 `machands` | 云端 agent 所在机器(VPS、Claude Code 网页沙箱、CI) |
| **Relay** | `relay/` | Node ESM | 用户自建 |

传输:全部 WebSocket。Relay 监听 `ws://0.0.0.0:8443`(有域名与证书时 `wss://:443`,由 `relay/config.json` 决定)。
不依赖 TLS 保密,因为有端到端加密;但 relay 自身身份用 Ed25519 密钥签名,App 与 agent 都固定(pin)它。

---

## 2. 身份与密钥

- 每个 Mac:`macId`(16 字节随机,base32 小写 26 字符)+ Ed25519 签名密钥 + X25519 加密密钥。首启生成,存 Keychain(App)。
- 每个 agent:`agentId` + 同样两对密钥。`machands pair` 时生成,存 `~/.machands/identity.json`(0600)。
- Relay:Ed25519 密钥,`relay/data/relay.key`。公钥出现在配对块里,客户端首次连接即 pin,不一致直接拒。
- 编码:所有二进制字段 **base64url 无填充**。

签名格式(通用):`sig = Ed25519.sign(key, utf8(canonicalJSON(payload)))`,canonicalJSON = 键按字典序、无空白。
挑战:relay 在 `hello` 阶段给 32 字节随机 `nonce`,客户端签 `{id, nonce, ts}`。

---

## 3. 配对块(用户唯一会看到并复制的东西)

App 点"复制给 agent"后剪贴板内容(纯文本,可整段贴进任何聊天框):

```
把下面这一行在你的机器上执行,然后告诉我结果:

npx -y machands@latest pair "MH1.<relayHost>:<port>.<relayPubkey>.<macId>.<macPubkeyX25519>.<macPubkeyEd25519>.<token>.<macName>"

(这是 MacHands 配对码,10 分钟内有效,只能用一次。)
```

- `MH1` 版本前缀;字段用 `.` 分隔;每个字段 base64url 或纯 ASCII,`macName` 用 base64url 编码 UTF-8。
- `token`:16 字节随机,App 生成,通过 `pair.open` 登记到 relay,TTL 600 秒,单次有效。
- 同一段文字既是给人看的说明,也是给 agent 的指令。agent 只要执行那一行。

**为什么 agent 侧用 npx**:用户不装任何东西;agent 机器一般有 Node。没有 Node 时 CLI 也提供 `curl -fsSL https://<relayHost>/install | sh`(v1 可后做)。

---

## 4. Relay 协议(WebSocket,文本帧,JSON,一行一消息)

端点:`/v1/mac`(App)、`/v1/agent`(CLI)。所有消息 `{ "t": "<type>", ...}`。

### 4.1 握手(两端相同)
```
S→C  {t:"hello", relayId, nonce, ts, ver:1}
C→S  {t:"auth", role:"mac"|"agent", id, edPub, xPub, name, sig}       // sig 签 {id, nonce, ts}
S→C  {t:"ok", id, ts}   |   {t:"err", code:"BAD_SIG"|"BUSY"|"BANNED", msg}
```
relay 用 `edPub` 验签;首次见到某 id 就记住其 `edPub`,以后 id 与 edPub 不一致 → `BAD_SIG`。
心跳:relay 每 25s 发 `{t:"ping"}`,对端回 `{t:"pong"}`;60s 无 pong 断开。

### 4.2 配对
```
Mac→S    {t:"pair.open", token, ttl:600}
Agent→S  {t:"pair.claim", token, macId}                         // agent 已在 auth 里给过自己的 edPub/xPub/name
S→Mac    {t:"pair.request", agentId, agentEdPub, agentXPub, agentName, from:"<ip>"}
Mac→S    {t:"pair.decide", agentId, allow:true|false}
S→Agent  {t:"pair.result", ok, macId, macEdPub, macXPub, macName}   // ok=false 带 code: EXPIRED|USED|DENIED|OFFLINE
```
App 策略:token 未过期 → **自动允许**并弹通知"Claude@vps 已连接";同时把 agent 记入"已授权 agent"列表(可撤销)。
token 过期/已用 → relay 直接回 `EXPIRED|USED`,不打扰 Mac。

### 4.3 数据通道
```
任一端→S  {t:"send", to:"<id>", body:"<base64url 密文>", n:<seq>}
S→对端    {t:"recv", from:"<id>", body, n}
S→发送方  {t:"err", code:"OFFLINE"|"NOT_PAIRED", to}
```
relay 只在**双方已配对**时转发(配对关系 relay 持久化:`data/pairs.json`,`{macId: [agentId...]}`)。
Mac 端 `revoke` 会让 relay 删除配对:`{t:"pair.revoke", agentId}`。

### 4.4 在线状态
```
S→Agent  {t:"presence", id:"<macId>", online:true|false}
S→Mac    {t:"presence", id:"<agentId>", online:true|false}
```

### 4.5 限制
- 单帧 ≤ 1 MiB(大文件分块)。
- relay 对每连接 10 MB/s 软限;超出 `{t:"err", code:"RATE"}`。
- relay 无状态到极致:只存 `ids.json`(id→edPub,name,lastSeen)与 `pairs.json`。

---

## 5. 端到端层(agent ↔ Mac,在 `body` 里)

- 共享密钥:`ss = X25519(myPriv, theirPub)`;`key = HKDF-SHA256(ss, salt="machands-v1", info=sort(macId,agentId).join("|"), 32)`。
- 每帧:`nonce(12 字节)= 4 字节方向标记("m2a"/"a2m" 的前 4 字节 ASCII)+ 8 字节大端计数器`;
  `ct = ChaCha20-Poly1305(key, nonce, plaintext, aad=utf8(from+">"+to))`;`body = base64url(nonce ‖ ct)`。
- 计数器单调递增,接收方拒绝重复或回退。
- 明文是 JSON RPC:

```
请求  {id:"<uuid>", m:"<method>", p:{...}}
响应  {id, r:{...}}  |  {id, e:{code, msg}}
流式  {id, s:{...}}   // 同 id 多条,最后以响应结束
```

### 5.1 方法(Mac 端实现,agent 端调用)

| m | p | 返回 | 说明 |
|---|---|---|---|
| `sys.info` | — | `{name, model, os, arch, user, home, cwd, uptime, battery, xcode, node, python}` | 拿不到的值为 null |
| `run` | `{cmd, cwd?, env?, timeout?:秒, shell?:"zsh"}` | 流 `{o:"…"}`/`{e:"…"}` 分块,结束 `{code, ms}` | 默认 `/bin/zsh -lc`,PATH 前置 `~/.grok/bin:~/.cargo/bin:/opt/homebrew/bin:/usr/local/bin`;默认超时 600s |
| `fs.put` | `{path, data:base64, mode?, append?}` | `{bytes}` | 大文件分块用 `append:true`;路径 `~` 展开 |
| `fs.get` | `{path, offset?, length?}` | `{data:base64, size, eof}` | ≤ 768 KiB/次 |
| `fs.ls` | `{path, depth?}` | `{entries:[{name,type,size,mtime}]}` | |
| `screen.shot` | `{display?:0, scale?:0.5, format?:"png"|"jpg", quality?}` | 流 `{data}` 分块 + `{width,height,bytes}` | 用 `/usr/sbin/screencapture -x`,App 是 TCC 责任进程 |
| `screen.list` | — | `{displays:[{id,w,h,main}]}` | |
| `open` | `{target}` | `{}` | `open` 命令:URL 或路径 |
| `clip.get` / `clip.set` | — / `{text}` | `{text}` / `{}` | |
| `notify` | `{title, body}` | `{}` | 给用户看 |
| `policy.get` | — | `{mode:"ask"|"auto"|"deny", allow:[…], deny:[…]}` | agent 可提前知道会不会被问 |

错误码:`DENIED`(用户拒绝)、`TIMEOUT`(用户 120s 没答)、`POLICY`(黑名单命中)、`EIO`、`ENOENT`、`EBUSY`、`BAD_PARAMS`。

### 5.2 审批策略(App 内,按 agent 分别记)

- `ask`(默认):`run`/`fs.put`/`open`/`clip.set` 弹卡;`fs.get`/`fs.ls`/`screen.*`/`sys.info`/`clip.get` 在"读取也要问"关闭时直接放行。
- `auto`:全部放行,但黑名单(默认含 `rm -rf /`、`diskutil erase`、`sudo`、`osascript -e 'tell application "System Events" to keystroke`)仍拦,命中即 `POLICY`。
- 审批卡按钮:**允许一次** / **允许 1 小时** / **总是允许这条**(按命令前缀记白名单) / **拒绝**。数字键 1-4。
- 卡片显示:agent 名、命令原文(等宽、最多 6 行、可展开)、cwd、来源 IP。
- 120s 无操作 → `TIMEOUT` 并返回 agent,卡消失。
- 一切审批与执行写审计日志 `~/Library/Logs/MacHands/audit.log`(JSONL:ts、agent、method、summary、decision、code、ms)。

---

## 6. Agent CLI(`npm i -g machands` 或 `npx machands`)

```
machands pair "<配对码>"            连接并配对;成功打印 "已连接 <macName>";写 ~/.machands/
machands macs                      列出已配对 Mac 与在线状态
machands run [--mac <name>] [--cwd <dir>] [--timeout <s>] -- <cmd...>   实时透传输出,退出码同 Mac
machands put <local> <remote>      上传(文件或目录,目录自动 tar)
machands get <remote> <local>      下载
machands shot [-o out.png] [--scale 0.5] [--display 0]   截屏
machands open <url|path>
machands clip [get|set <text>]
machands info                      sys.info
machands mcp                       以 stdio MCP 服务器运行(见 6.1)
machands forget <mac>              本地删除配对
machands doctor                    诊断:relay 可达、身份文件、已配对 Mac 在线
```
- 默认 Mac:只有一台就是它;多台用 `--mac` 或 `MACHANDS_MAC` 环境变量;配对时可 `--default`。
- 退出码:0 成功;命令本身的退出码原样返回;`DENIED`=77,`TIMEOUT`=78,离线=69,未配对=66。
- 输出全部人话,不要打 JSON 到 stderr(`--json` 时才打)。

### 6.1 MCP 服务器(stdio,协议 2025-06-18)
工具:`mac_info`、`mac_run`(cmd, cwd?, timeout?)、`mac_put`(path, content|base64)、`mac_get`(path)、`mac_ls`、`mac_screenshot`(返回 image content)、`mac_open`、`mac_clipboard_get/set`、`mac_notify`、`mac_list`。
`machands pair` 成功后打印一段可直接复制的接入提示:
```
Claude Code:  claude mcp add machands -- npx -y machands mcp
Codex:        在 ~/.codex/config.toml 加 [mcp_servers.machands] command="npx" args=["-y","machands","mcp"]
Cursor:       Settings → MCP → Add: npx -y machands mcp
也可以直接用命令行:machands run -- xcodebuild -version
```

---

## 7. App(菜单栏)

### 7.1 状态与菜单
菜单栏图标:手形 SF Symbol `hand.raised`。
- 未配对:图标半透明;菜单第一行"还没有 agent 连接",第二行按钮 **复制给 agent**。
- 已配对离线:图标带小点;"等待 agent…"。
- 已连接:实心;"已连接 · Claude@vps",下面每个 agent 一行(名字、最近一次命令、几秒前)。
- 常驻项:审批模式(逐条问 / 自动)切换、**暂停**(所有命令直接 `DENIED`,图标打叉)、打开审计日志、设置…、退出。

### 7.2 唯一的主窗口(首启自动打开)
```
┌ MacHands ─────────────────────────────┐
│  🖐  把这台 Mac 交给你的 agent          │
│                                       │
│  [ 复制给 agent ]   ← 一个大按钮        │
│  已复制。贴给你的 agent,让它执行那一行。 │
│                                       │
│  等待 agent 连接…  ◌                   │
│  ─────────────────────────────────── │
│  ▸ 详细信息(中继地址、这台 Mac 的名字)   │
└───────────────────────────────────────┘
```
agent 连上后同一窗口切到:"✓ Claude@vps 已连接。可以关掉这个窗口了。" + 审批模式选择 + "开机自动启动"开关(默认开)。
设置窗口(次要):中继地址(默认我们的;可改自建)、已授权 agent 列表与撤销、黑/白名单、"读取也要问"、许可证。

### 7.3 审批卡
`NSPanel`,`.nonactivatingPanel`,`level = .floating`,出现在主屏右上;同时发 `UNUserNotification`(点通知打开面板)。
多条排队显示计数"还有 2 条"。

### 7.4 权限引导
首次 `screen.shot` 若 TCC 未授权:返回 agent `EIO "需要在 Mac 上授权屏幕录制"`,同时 App 弹一次引导:"agent 想截屏,需要你授权一次" + 按钮直达 `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`。用 `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()`。

### 7.5 许可证(v1 最简)
- 7 天试用从首启算(存 Keychain,删 App 不重置)。
- 许可证是一行 `MHL1.<base64url(payload)>.<base64url(sig)>`,payload `{email, exp|null, seats}`,Ed25519 签名,公钥编进 App。签发工具在 `tools/license/`(私钥不进仓库)。
- 过期后:仍可配对与查看,但 `run/fs.put` 返回 `LICENSE`,卡片提示"试用结束"。不锁死,不删数据。

### 7.6 工程
- SwiftPM 可执行包 + `scripts/build-app.sh` 打成 `MacHands.app`(Info.plist:`LSUIElement=true`,bundle id `app.machands.MacHands`,`NSUserNotificationsUsageDescription`,`NSAppleEventsUsageDescription`,`NSAppTransportSecurity` 允许 ws 明文)。
- `scripts/release.sh`:codesign(Developer ID Application,hardened runtime,entitlements 无沙箱)→ 打 DMG(`hdiutil`)→ `notarytool submit --wait` → `stapler`。凭据从 Keychain profile `machands-notary` 读。
- 开机自启 `SMAppService.mainApp`。
- 日志 `~/Library/Logs/MacHands/app.log`,自动轮转。
- 目标 macOS 13+;Apple Silicon 与 Intel 都编(`arch -x86_64` 或 universal)。

---

## 8. 目录

```
machands/
  SPEC.md                 本文件
  README.md               用户看的三步说明 + 开发者说明
  relay/   server.mjs  config.example.json  install.sh(systemd)  test/
  agent/   package.json  bin/machands.mjs  src/{crypto,relay,rpc,cli,mcp}.mjs  test/
  shared/  PROTOCOL-VECTORS.json   加密测试向量(agent 生成,Swift 测试读取,两边必须互通)
  macapp/  Package.swift  Sources/MacHands/*.swift  Tests/  Resources/Info.plist  scripts/
  tools/license/  sign.mjs verify.mjs
  site/    index.html(下载页,后做)
```

## 9. 验收(缺一不算完成)

1. 服务器:`node relay/server.mjs` 启动;`node --test relay/test agent/test` 全绿。
2. 在 Linux 上用两个 Node 进程模拟 Mac 与 agent 走完 pair → run → put → get(agent 测试里带一个 `fake-mac.mjs`)。
3. Mac 上:`swift build` 通过;`swift test` 用 `shared/PROTOCOL-VECTORS.json` 验证加解密与 Node 互通。
4. 真机:App 首启 → 复制 → 在服务器 `npx machands pair` → 菜单栏"已连接" → `machands run -- sw_vers` 弹卡 → 允许 → 输出回到服务器;`machands shot` 得到真 PNG;`machands put/get` 往返一致;暂停后命令得 `DENIED`。
5. `claude mcp add machands -- npx -y machands mcp` 后,Claude Code 能调用 `mac_run`。

---

# v0.2 修订(2026-09-06)· 一次授权 + 开发者便利标准

> 所有者指令(原话):"授权这个是最麻烦的我希望授权一次即可 不然太麻烦 而且需要引导。
> 授权后需要进行验证 没问题就好。就是开发方便的标准你来定义后 完善整个app 和 npm依赖等。"
>
> 本节是 v1 契约之上的**增量**,与 v1 冲突处以本节为准。三个部件仍是 App / Agent CLI / Relay;
> **Relay 协议不变**(全部新能力都在端到端层 §5 的 RPC 里),0.1 的 relay 继续可用。

## 10. 一次授权(取代"逐条弹卡"作为默认体验)

### 10.1 授权范围(`ApprovalMode` 增加 `readonly`)

| 范围 | 语义 | 卡片 |
|---|---|---|
| `auto`(开发者,**推荐**) | 全部方法放行;内置黑名单命中直接回 `POLICY`,**不弹卡** | 永不弹 |
| `readonly`(只读) | 只放行读方法(§10.4);写方法回 `DENIED reason=readonly`,不弹卡 | 永不弹 |
| `ask`(逐条审批,v1 行为) | 写方法弹卡,读方法按"读取也要问"决定 | 会弹 |

用户在**配对完成的那一刻**选一次;之后除了黑名单命中,再不打扰。`policy.get` 的 `mode` 原样返回三者之一。

### 10.2 授权流程(App 主窗口,配对成功后自动切到这一页)

```
✓ <agent 名> 已连接
授权范围(只需选一次)
  (•) 开发者 — 全部允许;危险命令仍被黑名单拦下        推荐
  ( ) 只读   — 只能看,不能改
  ( ) 逐条审批 — 每条命令都问我
需要的系统权限                                  状态      
  通知           agent 提醒你时用                 ✓ 已授权
  屏幕录制       截屏 / 录屏                      ✗ 未授权  [打开设置]
  辅助功能       键盘鼠标(手感测试、点按钮)        ✗ 未授权  [打开设置]
[ 授权并验证 ]
验证结果  执行命令 ✓  读写文件 ✓  截屏 ✓  键鼠 ✓  通知 ✓  作业 ✓
```

- 「授权并验证」= 写入范围 → 依次触发系统权限请求(`CGRequestScreenCaptureAccess`、
  `AXIsProcessTrustedWithOptions(prompt)`、`UNUserNotificationCenter.requestAuthorization`)
  → 跑本机自检(§10.3)→ 逐行显示 ✓/✗ 与修复指引。
- 权限状态每 1 秒轮询一次,用户在系统设置里勾上后**不用回来点任何东西**,行自动变绿。
- 「打开设置」直达对应面板:`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`
  / `?Privacy_Accessibility` / `?Notifications`。
- 授权完成写 `settings.authorizedAt`,菜单栏第二行显示"已授权 · 开发者"。
- 此页面**随时可从菜单「授权与验证…」再打开**,重跑自检。

### 10.3 自检(两端同一张表)

| 行 | 怎么验 | 失败时的指引 |
|---|---|---|
| 执行命令 | `run` `printf machands-ok` 回显一致、退出码 0 | 看审计日志 |
| 读写文件 | `fs.put` 临时文件 → `fs.get` 字节一致 → 删除 | 磁盘/权限 |
| 截屏 | `screen.shot scale=0.1` 得到非空 PNG | 屏幕录制未授权 → 打开设置 |
| 键鼠 | `input.where` 取当前光标 → `input.move` 到同一位置(无可见效果) | 辅助功能未授权 → 打开设置 |
| 通知 | `notify` 一条"MacHands 验证通过" | 通知被关 → 打开设置 |
| 作业 | `job.submit sleep 1; echo done` → `job.result` 为 0 | 见审计日志 |
| MCP 桥 | `mcp.servers` 能列出配置(0 个也算过);有则 `mcp.list` 第一个 | 配置文件格式 |

App 端:`Verifier`(本机直接调 Executor 同一套实现)。Agent 端:`machands verify` 走 RPC 跑同一张表。
新增 RPC `verify.run` 让 agent 拿到 App 自检的原始结果。

### 10.4 方法分类(策略用)

- 读:`fs.get` `fs.ls` `screen.shot` `screen.list` `screen.window` `screen.record` `sys.info` `sys.perms`
  `sys.which` `clip.get` `job.status` `job.tail` `job.result` `job.list` `session.read` `mcp.servers` `mcp.list`
- 写:`run` `fs.put` `open` `clip.set` `input.*` `job.submit` `job.kill` `session.open` `session.write`
  `session.close` `mcp.open` `mcp.call` `mcp.close` `power.assert` `power.release` `app.relaunch` `verify.run`
- 永不审批:`notify` `policy.get` `policy.check`

### 10.5 内置黑名单(v1 四条 → 以下;auto 模式同样拦,命中回 `POLICY` 不弹卡)

```
rm -rf /        rm -rf ~        rm -rf /*       diskutil erase      diskutil eraseDisk
mkfs            dd if=          sudo            csrutil             launchctl bootout system
security delete-keychain        tccutil reset All   killall MacHands    pkill -f MacHands
osascript -e 'tell application "System Events" to keystroke        ← 键鼠走 input.*,不走 osascript
```

## 11. 新增 RPC(§5.1 的增量)

| m | p | 返回 | 说明 |
|---|---|---|---|
| `sys.info` | — | v1 字段 + `mem_gb, disk_free_gb, cpu, gpu, displays:[{id,w,h,main}], tools:{godot,blender,xcodebuild,swift,node,python3,brew,cliclick,ffmpeg,git}` | tools 值是路径或 null。**开工体检一次拿全** |
| `sys.perms` | — | `{screen:bool, accessibility:bool, notifications:"authorized"\|"denied"\|"notDetermined"\|"unknown", automation:"onDemand"}` | |
| `sys.which` | `{names:[…]}` | `{name: path\|null}` | 走 `zsh -lc command -v` |
| `policy.check` | `{method, subject}` | `{decision:"allow"\|"ask"\|"deny", reason?}` | 干跑,不执行、不记审计 |
| `fs.get` | 同 v1;`path` 为目录时 | 流 `{data}` + `{archive:true, bytes, entries}` | 目录自动 `tar czf`,agent 端解包 |
| `screen.window` | `{app?, title?, scale?, format?}` | 同 `screen.shot` | 前台窗口或按 App 名匹配的窗口;`screencapture -l <id>` |
| `screen.record` | `{seconds(≤120), display?, fps?}` | 流 `{data}` 分块 + `{bytes, path, seconds}` | `screencapture -v -V <s>`;需要屏幕录制权限 |
| `input.where` | — | `{x,y}`(顶左原点,与截图同坐标) | 需辅助功能 |
| `input.move` | `{x,y}` | `{}` | |
| `input.click` | `{x,y, button?:"left"\|"right", count?:1}` | `{}` | |
| `input.drag` | `{x1,y1,x2,y2, ms?:300}` | `{}` | 插值 20 步 |
| `input.scroll` | `{x,y,dx,dy}` | `{}` | |
| `input.key` | `{key, mods?:["cmd","shift","alt","ctrl"]}` | `{}` | key 为单字符或 `enter tab esc space up down left right f1..f12 delete` |
| `input.type` | `{text}` | `{}` | Unicode 直接注入,不依赖键盘布局 |
| `job.submit` | `{cmd, cwd?, env?, timeout?:秒(默认 3600)}` | `{jobId}` | 立刻返回;输出落 `~/Library/Application Support/MacHands/jobs/<id>/` |
| `job.status` | `{jobId}` | `{state:"running"\|"exited"\|"killed"\|"orphaned", code?, ms, outBytes, errBytes, cmd, startedAt}` | App 重启后原进程失联记 `orphaned`,文件仍在 |
| `job.tail` | `{jobId, stream:"out"\|"err", offset?}` | `{data:base64, offset, eof}` | ≤512 KiB/次 |
| `job.result` | `{jobId, wait?:秒}` | 同 status;`wait` 内结束就早返 | |
| `job.kill` | `{jobId}` | `{}` | 杀整棵进程树(见 §11.1) |
| `job.list` | — | `{jobs:[status…]}` | |
| `session.open` | `{cmd?, cwd?, env?}` | `{sessionId}` | 有 stdin 的长命进程;默认 `zsh -l` |
| `session.write` | `{sessionId, data}` | `{}` | 文本写 stdin |
| `session.read` | `{sessionId, offset?}` | `{data, offset, eof, alive}` | 轮询读合并后的输出 |
| `session.close` | `{sessionId}` | `{}` | |
| `mcp.servers` | — | `{servers:[{name, source, command?, args?, url?}]}` | 读 `~/.claude.json` `~/.codex/config.toml` `~/.cursor/mcp.json` `~/Library/Application Support/Claude/claude_desktop_config.json`;**不返回 env 值** |
| `mcp.open` | `{name}` 或 `{command,args?,env?}` | `{sessionId, tools:[…]}` | 起 stdio MCP 服务并完成 initialize;工具表随手返回 |
| `mcp.list` | `{sessionId}` | `{tools}` | |
| `mcp.call` | `{sessionId, tool, args, timeout?}` | MCP 的 `result` 原样 | |
| `mcp.close` | `{sessionId}` | `{}` | |
| `power.assert` | `{seconds(≤14400)}` | `{until}` | `caffeinate -dims -t` |
| `power.release` | — | `{}` | |
| `app.relaunch` | — | `{}` | `open -n` 新实例后退出(DELIVERY v1.1 项) |
| `verify.run` | — | `{rows:[{name, ok, detail, fix?}]}` | §10.3 那张表 |

### 11.1 超时与进程树
`run` / `job.*` / `session.*` 的超时和 kill 都对**整棵进程树**生效:先 SIGTERM 全部后代,2 秒后 SIGKILL 残留。
不再出现"杀了 zsh,Godot 还在吃 GPU"。

## 12. Agent CLI 增量(§6)

```
machands use <mac> [--default]          设默认 Mac;只有一台在线时自动用它
machands verify [--mac]                 授权后验证(§10.3 那张表,✓/✗ + 修复指引);全过退出 0
machands perms  [--mac]                 系统权限状态 + 修复指引
machands check  [--mac]                 开工体检:sys.info 扩展字段,一屏看完
machands job submit|status|tail|result|kill|list …
machands session open|write|read|close …
machands input where|move|click|drag|scroll|key|type …
machands record <秒> [-o out.mov]
machands window-shot [--app 名] [-o out.png]
machands mcp servers | tools <server> | call <server> <tool> [json]
machands policy check -- <命令>
machands power assert <秒> | release
machands get <远端目录> <本地目录>          目录自动打包/解包
```
退出码新增:`readonly` 拒绝 = 77(同 DENIED)。

### 12.1 MCP 服务器增量(§6.1)
新增工具:`mac_verify` `mac_perms` `mac_check` `mac_job_submit` `mac_job_status` `mac_job_tail` `mac_job_result`
`mac_job_kill` `mac_input_where` `mac_input_click` `mac_input_drag` `mac_input_key` `mac_input_type` `mac_record`
`mac_window_shot` `mac_mcp_servers` `mac_mcp_tools` `mac_mcp_call` `mac_power_assert` `mac_policy_check`。
`mac_get` 改为**循环分块到 eof**,目录返回解包后的文件清单;绝不静默截断。

## 13. 开发者便利标准 v1(我定义的"方便";每条都有验证)

| # | 标准 | 验证 |
|---|---|---|
| 1 | **一次授权**:配对后选一次范围,之后零弹卡(黑名单直接拒) | `machands verify` 连续 20 条命令,审计日志里 `decision` 无 `once/hour/always/timeout` |
| 2 | **引导式权限**:授权页一次性列出全部需要的系统权限,每项有状态灯与直达按钮,勾上后自动变绿 | 在未授权的 Mac 上走一遍,不需要看文档 |
| 3 | **授权后自检**:App 与 CLI 同一张表,✓/✗ + 修复指引 | `machands verify` 与 App 页面结果一致 |
| 4 | **默认 Mac**:多台时 `use` 一次;只有一台在线时不用指定 | `machands info` 不带 `--mac` 不报错 |
| 5 | **长活不阻塞**:`job.*` 提交即返回,断线不丢,超时杀干净 | 提交 `sleep 30`,断开 CLI,30 秒后 `job.result` 拿到 0;`job.kill` 后 `pgrep` 无残留 |
| 6 | **交互与桥接**:`session.*` 有 stdin;`mcp.*` 能透传 Mac 上任一 stdio MCP 服务 | `mcp.open claudex-computer-use` → `mcp.list` 非空 |
| 7 | **看得见动得了**:窗口截图、录屏、键鼠 | `record 3` 得到可播放的 .mov;`input.key c` 在游戏里切了视角 |
| 8 | **开工体检**:一条命令知道内存/GPU/磁盘/装了什么 | `machands check` 输出含 `godot`/`blender` 路径或 null |
| 9 | **不静默截断**:大文件、目录、长输出全部完整或明确报错 | 1.3 MB 截图经 MCP `mac_get` 字节一致 |
| 10 | **可预判**:`policy check` 干跑告诉 agent 会不会被拒 | 对黑名单命令返回 `deny` |
| 11 | **自救**:`app.relaunch`、`power.assert` | 重启后 30 秒内 `machands macs` 在线 |
| 12 | **文档即代码**:README/agent README/SPEC 的命令表与 `--help` 逐条一致 | 测试比对 USAGE 与 SPEC 表 |

## 14. 验收(v0.2,缺一不算完成)

1. `node --test relay/test agent/test` 全绿(含新方法的假 Mac 实现与 e2e)。
2. `swift build` / `swift test` 全绿(策略新增 readonly、黑名单、方法分类都有断言)。
3. 真机(Mac mini,mode 从 ask 起):配对 → 授权页出现 → 选"开发者"→ 授权并验证 → 全 ✓
   (屏幕录制/辅助功能各授权一次)。
4. 从 VPS:`machands verify` 全 ✓;`machands job submit -- sleep 20; echo ok` → 断开 → `job.result` = 0。
5. `machands mcp servers` 列出 Mac 上已配置的 MCP;`machands mcp tools claudex-computer-use` 非空。
6. `machands record 3` 拉回 .mov;`machands input key c` 在 Godot 里切视角(人眼确认)。
7. 全程审计日志无一条 `once/hour/always/timeout`。

---

# v0.3 修订(2026-09-06)· 发布与自动更新

起因(用户原话):「app应该内置自动更新 而不是 重新下载这种更新方式导致的权限混乱
其他agent用machands的时候就一直申请权限 还不知道什么问题了」。

## 15. 发布与自动更新

### 15.0 铁律(补 §0)

| # | 铁律 |
|---|---|
| A | **正式包的 bundle id 永远是 `app.machands.MacHands`**,不可配置。开发副本用 `app.machands.MacHands.dev`。`release.sh` 对 Info.plist 与签名两处都硬断言,不等就退出 8。 |
| B | **一台 Mac 上同一时刻只应有一份正式 App。** 多份同 bundle id 的拷贝会互抢中继身份、在系统权限面板里出现同名条目,用户以为"权限没生效"。更新走原地替换,不产生第二份。 |
| C | **官网分发只用 Developer ID Application 证书 + 公证。** 开发证书签的包 `spctl` 拒绝,且 TCC 的指定要求绑在证书名上,每次升级掉权限。 |
| D | 发布私钥只在发布者机器上(`~/.machands/release-key.pem`,600),不进仓库、不进 CI、不打印。 |

### 15.1 为什么升级会掉系统权限

TCC 记的是代码签名的**指定要求**(designated requirement),不是路径:

| 签名方式 | 指定要求锚定在 | 升级后 |
|---|---|---|
| ad-hoc | cdhash(每次编译都变) | 必掉 |
| Apple Development | 那张开发证书的 CN(换机/换证就变),且过不了公证 | 必掉 |
| **Developer ID Application** | **team id `subject.OU`(不变)** | **保留** |

所以修法是"换证书 + 原地替换",不是"让用户少更新"。

### 15.2 appcast(官网 `/appcast.json`)

| 字段 | 类型 | 说明 |
|---|---|---|
| `version` | string | marketing 版本,`1.2.3` 形状。与 `macapp/VERSION`、Info.plist 三处必须一致 |
| `build` | number | `CFBundleVersion`,单调递增(git 提交数) |
| `url` | string | `<host>/downloads/MacHands-<version>.zip`,必须 https(除非 host 本身是 http) |
| `sha256` | string | zip 的 sha256,小写十六进制 |
| `sig` | string | 用发布私钥对 **`sha256` 那串十六进制文本**做的 Ed25519 签名,**base64url**(无补位),解码后 64 字节 |
| `notes_zh` / `notes_en` | string | 这一版的更新说明,App 里按当前语言显示 |
| `min_os` | string | 最低 macOS,如 `13.0`。低于它不提示更新 |
| `published` | string | ISO8601 UTC |

生成:`macapp/scripts/make-appcast.sh`。签名自检(签完立刻用公钥验一遍)不过就不出文件。

### 15.3 校验链(App 端,`Updater.swift`)

按顺序,任一步失败即放弃本次更新并保留现有版本:

1. 取 `/appcast.json`(不带缓存)。解析失败 → 放弃。
2. `version` 或 `build` 不高于当前 → 无更新(不是错误)。
3. `min_os` 高于当前系统 → 不提示,记一行日志。
4. 下载 `url` 到临时目录。大小上限 200 MB。
5. 自己算下载文件的 sha256,与 `sha256` 字段**逐字节比对**。
6. 用**内置的** `releasePublicKey`(编译期常量,base64url,不从网上取)验 `sig` 对 `sha256` 文本的签名。
7. 解包,对解出的 `.app` 跑 `codesign --verify --strict`,并断言其 bundle id == `app.machands.MacHands`、
   team id 与当前运行版本相同。**team id 变了一律拒绝**(换证书要用户手动装一次)。
8. 原地替换(§15.4),重启。

第 6 步是防"官网被写入"的那一道:攻击者能改 `sha256` 与 zip,但改不出对应的 `sig`。

### 15.4 原地替换规则

- 目标路径 = 当前运行的 bundle 路径(`Bundle.main.bundleURL`),**不换位置**。换位置 = TCC 里换了一个条目。
- 用 `NSFileManager.replaceItemAt`(底层 `renamex_np(RENAME_SWAP)`)做原子替换;不允许"先删后拷"。
- 替换前:如果 bundle 路径在只读卷、或当前用户没有写权限(比如装在 `/Applications` 但用户非管理员),
  → 不做替换,提示用户手动下载。**不提权、不调 osascript 要密码。**
- 替换后 `open -n` 新实例 → 老实例退出(复用 `app.relaunch` 的做法)。
- 失败回滚:替换动作本身是原子的;解包、校验都在临时目录完成,失败不触碰已装版本。

### 15.5 什么时候不更新

| 情形 | 行为 |
|---|---|
| 有正在跑的 `job.*` / `session.*` | 推迟到它们结束;`--force` 才立刻更新 |
| 处于"暂停"状态 | 照常更新(不执行 agent 命令不代表不能升级) |
| 从 `.dev` bundle id 启动(开发副本) | **永不自动更新** |
| 用户在设置里关了自动更新 | 只检查、只提示,不下载 |

### 15.6 版本协商(CLI ↔ App)

`sys.info` 回的 `app_version` 是真源。CLI 拿到后:

- CLI 主版本.次版本 **高于** App → 提示 `你的 Mac 上是 0.2.0,这个 CLI 是 0.3.0;在 Mac 上点「检查更新」或跑 machands update`。
- App 高于 CLI → 提示升级 npm 包:`npm i -g machands@latest`。
- 调用了 App 不认识的方法 → App 回 `BAD_PARAMS: unknown method X`,CLI 把它翻译成版本不匹配的人话,而不是原样抛错。

### 15.7 验收(v0.3)

1. `./scripts/release.sh --sign "Developer ID Application: …" --keychain-profile …` 一条命令跑到底,`spctl` = accepted。
2. `curl https://<host>/appcast.json` 的 `sha256` 与 `shasum -a 256` 本地算的一致。
3. 把 appcast 里的 `sha256` 改一个字符 → App 拒绝更新并记日志;把 `sig` 改一个字符 → 同样拒绝。
4. 从 0.3.0 升到 0.3.1:升级后 `machands verify` 的 screen / input 两项**仍为 ✓**,用户没有重新勾过权限。
5. 升级后 `/Applications/MacHands.app` 只有一份,`pgrep -fl MacHands` 只有一个正式进程。
6. bundle id 被改成别的 → `release.sh` 退出 8,不产出任何包。
