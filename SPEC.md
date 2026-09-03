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
| **Relay** | `relay/` | Node ESM | 我们托管(v1:134.199.230.126:8443);可自建 |

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
