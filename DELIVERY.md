# MacHands 交付说明(2026-09-03)

## 已交付且已验证

| 部件 | 状态 | 验证 |
|---|---|---|
| 中继 `relay/` | 已部署在 134.199.230.126:8443,systemd 开机自启,用户 `machands`,数据在 `/opt/machands/relay/data` | `curl http://134.199.230.126:8443/health` |
| agent CLI + MCP `agent/` | 完成 | `node --test relay/test agent/test` 60/60;真中继上 假 Mac → pair → run 闭环 |
| Mac App `macapp/` | 完成,在 MacBook Air(macOS 26.3.1,Xcode 26.2)一次编译通过 | `swift test` 66/66(含与 Node 的加密互通向量);`/Applications/MacHands.app` 已装、已连上中继 |
| 许可证 | 签发公钥已编进 App;私钥在服务器 `/root/.machands-license/key.json`(不在仓库) | `node tools/license/sign.mjs` / `verify.mjs` |

中继公钥(relayId):`5ESYS7nKfs6VOBsQX3hf0jFYZ4u1f9X1fuOXsZLQgZw`。App 默认指向它。

## 联调步骤(你 + 任意云端 agent)

1. Mac 上打开 MacHands,点「复制给 agent」。
2. 把文字贴给 agent。agent 执行其中的 `npx -y machands@latest pair "MH1…"`。
   包已发布,任何有 Node 的机器直接跑这一句即可。
3. 菜单栏变成「已连接 · <agent 名>」。
4. agent 侧依次试:
   ```
   machands info
   machands run -- sw_vers            # Mac 右上角弹审批卡,按 1 允许
   machands shot -o /tmp/mac.png      # 第一次会引导授权"屏幕录制"
   machands put ./a.txt '~/a.txt' && machands get '~/a.txt' ./b.txt
   machands clip set hello && machands clip get
   ```
5. 菜单里点「暂停」,再 `machands run -- true` 应得到 `DENIED`(退出码 77)。
6. 设置 → 已授权 agent → 撤销,再执行应得到未配对(退出码 66)。

Claude Code 接入:`claude mcp add machands -- npx -y machands mcp`(包已发布,不必再用仓库路径)。


## 真机联调记录(2026-09-03,MacBook Air + 托管中继 + 本服务器作为 agent)

| 步骤 | 结果 |
|---|---|
| App 点「复制给 agent」→ 贴给 agent → `machands pair` | 通过,约 20 秒变为"已连接" |
| `machands info` | 通过(Mac14,2 / macOS 26.3.1 / Xcode 26.2 / 电量) |
| `machands run`(自动放行模式) | 通过,0.7 秒 |
| `machands run`(逐条问模式,用户按 1) | 通过,等待 30 秒后执行 |
| `machands run`(逐条问,120 秒无人点) | 返回 TIMEOUT,退出码 78,符合契约 |
| `machands put` / `get` 往返 | 通过,内容一致 |
| `machands clip set/get` | 通过 |
| `machands notify` | 通过,通知中心收到 |
| `machands shot`(授权屏幕录制后) | 通过,得到真实桌面 PNG;发现并修复 Retina 缩放只画四分之一的 bug,修复版已在真机验证(1024×576 满幅) |
| MCP stdio(`initialize` / `tools/list` / `mac_run`) | 通过,11 个工具,`mac_run` 返回真实结果 |
| 身份跨重编译存活 | 通过:改为文件存储后,用真证书重签的新版从钥匙串迁移一次,macId 不变、配对不丢(`~/Library/Application Support/MacHands/secrets/identity.v1`,0600) |
| Apple Development 证书签名 | 通过:`build-app.sh --sign "Apple Development: wang tianxin (4CBL3R2MCH)"`,TeamIdentifier 3PW7WV39F5;之后重编译授权与钥匙串都稳定 |
| 暂停 → 命令被拒(77) | 未验证(需要用户点菜单「暂停」;逻辑有单元测试覆盖) |
| 撤销授权 → 未配对(66) | 未验证(需要用户在设置里撤销;relay 与 CLI 侧有测试覆盖) |

### 联调中发现、排进 v1.1 的两件事
- **agent 无法安全地远程重启 App**:`kill` App 后它派生出来的重启脚本一起被结束,Mac 离线,只能人手重开。v1.1 加 RPC `app.relaunch`(App 自己用 `open -n` 拉起新实例后退出)和 `app.update`(下载 DMG、校验、替换、重启)。
- **临时(ad-hoc)签名下,每次重新编译都会让"屏幕录制"授权和钥匙串条目失效**(TCC 与钥匙串 ACL 都按代码签名识别 App;ad-hoc 的要求是按 cdhash 钉死的),表现为 `could not create image from display`、设置里开关显示开着但无效、App"失忆"成新 Mac。**已解决**:开发期用 Apple Development 证书签(`build-app.sh --sign "Apple Development: …"`),发布用 Developer ID;身份改为文件存储。若已出现过期条目:`tccutil reset ScreenCapture app.machands.MacHands`,再在设置里用「+」加回并完整重启 App。
- 另:进程名是完整路径,`pkill -x MacHands` 匹配不到;用 `pgrep -f MacHands.app/Contents/MacOS/MacHands`。

## 发布前只有你能做的三件事(三件都已完成)

1. ~~**Developer ID 证书**~~ **已完成(2026-09-04)**:`Developer ID Application: wang tianxin (3PW7WV39F5)`。
2. ~~**公证凭据**~~ **已完成(2026-09-04)**:profile `machands-notary` 已存进 Mac 钥匙串。全部 3 个 DMG(通用/Apple Silicon/Intel)已重新签名、提交公证、`spctl` 验证通过("source=Notarized Developer ID"),已上线 `/dl/`,官网文案同步改成"已通过苹果公证",不再提右键打开。
3. ~~**发布 npm 包**~~ **已完成(2026-09-06)**:`machands@0.1.0` 已在 npm 上,
   `npm view machands version` 返回 0.1.0,shasum `c9e2fca2…` 与本地打包一致。
   配对码里那句 `npx -y machands@latest pair "MH1…"` 已在干净环境实测跑通,不必再用仓库路径代替。

   **发布过程踩到的坑,下次发版直接照做:**
   - 老板的 Mac 在国内直连 registry.npmjs.org **上传**时稳定 ECONNRESET(TLS 握手前被重置),重试无用;
     但这台云服务器连 npm 正常。所以**发布走云端**。
   - 云端没有浏览器**不妨碍**登录:`npm login --auth-type=web` 会打印一个登录 URL,
     那个 URL 在任何浏览器打开都算数。做法:云端后台跑
     `printf '\n' | npm login --auth-type=web > log 2>&1 &`,从 log 里取 URL 交给老板,
     他在 Mac 上用指纹登一次,云端会话即激活。
   - 发布时仍会要 2FA,且无人值守环境下 npm 只接受 `--otp=`,不走 WebAuthn 网页流(报 EOTP)。
     老板的 2FA 是 Touch ID 没有 6 位码,**用 npm 恢复码当 `--otp` 可以通过**(已验证)。恢复码一次性。
   - Safari 下载 `.tgz` 会自动解压成 `.tar`,导致 npm 报 ENOENT/corrupted;用 `curl -fL -o` 取才是原始字节。
   - 发布完立刻 `npm logout` 清掉云端 `~/.npmrc`,不把老板的 npm 会话留在服务器上。

做完 1 和 2 后,在 Mac 上:
```
cd ~/machands/macapp
./scripts/release.sh --sign "Developer ID Application: 你的名字 (TEAMID)" --keychain-profile machands-notary --version 0.1.0
```
产物:`dist/MacHands-0.1.0.dmg`(已签名、已公证、已 staple)。放到下载页即可。

## 售卖

- 定价建议:49 美元买断含一年更新;7 天试用内置。
- 签发许可证:`node tools/license/sign.mjs --key /root/.machands-license/key.json --email 买家邮箱 --seats 1`(永久)或加 `--exp 2027-09-03`。
  Lemon Squeezy / Paddle 的 webhook 收到订单后调这条命令并邮件发给买家;v1 可以手动。
- 用户在 MacHands 设置窗口粘贴 `MHL1.…` 即可。

## 已知边界(写进产品说明,不要藏)

- 中继是明文 WebSocket(8443)但内容端到端加密。有域名后把 `relay/config.json` 的 `tls` 填上证书即可改为 wss/443,App 的中继地址改成 `wss://…`。
- 会话密钥由静态密钥派生;4096 计数器滑动窗口挡重放。真正的前向保密要临时密钥握手,排在 v1.1。
- 截屏依赖用户在 Mac 上授一次"屏幕录制"权限;审批卡数字键需要先点一下卡片(不抢焦点是铁律)。
- Claude Code 网页版沙箱若不放行 8443 出站,需要 wss/443 + 域名。

## 仓库

`/root/wtx/machands`(git,master)。真源:`SPEC.md`。Mac 上的副本:`~/machands`。

## 官网 + 通用二进制 + 自主接管进展(2026-09-03 下午)

| 项 | 状态 |
|---|---|
| Intel/Apple Silicon 通用二进制 | **已验证**:`swift build -c release --arch arm64 --arch x86_64` 在你的 Mac 上编译成功,`lipo -archs` 输出 `x86_64 arm64`。`build-app.sh` 早就支持 `--universal` 参数,以后打包默认加上就行。 |
| 官网 | **已上线**:`http://134.199.230.126/`(nginx,本服务器)。深色开发者工具风格,含 Hero/使用三步/审批卡演示/功能网格/对比表/定价/邮件占位/FAQ/合规免责声明。因为没有域名,暂时是 IP 直连 HTTP,浏览器会显示"不安全"——见下方"你要做的事"。 |
| 邮件收集 | **已上线**:`/api/waitlist`(systemd 服务 `machands-waitlist`,数据在 `/opt/machands/site/data/waitlist.json`),因为收款渠道还没开,首页"Get MacHands"暂时收邮件占位下载入口。 |
| Developer ID 证书 / 公证 / npm 发布 | **仍然卡住,只有你能做**。我试了用 GUI 自动化在 Xcode 里自己点「Manage Certificates → + → Developer ID Application」,但这需要你先手动批准一次"辅助功能"权限,而且这一步涉及 Apple 账号的信任操作,我判断不该在你正开着其它工作的桌面上盲点鼠标,已停手。npm 发布同理:`npm login` 大概率要走一次性验证码,只有你本人能过。 |

### 你要做的事(按优先级)

1. **(可选但强烈建议)买个域名**,比如 `machands.app` 或 `machands.dev`(Namecheap/Cloudflare 约 12-20 美元/年)。买完把域名的 A 记录指向 `134.199.230.126`,告诉我域名,我十分钟内配好 Let's Encrypt 证书,官网就有真正的绿锁小锁头,商业观感完全不同。我没有支付方式,这一步只能你来。
2. **Developer ID 证书**:打开 Xcode → 设置(⌘,)→ Accounts → 选中你的账号 → Manage Certificates → 左下角「+」→ Developer ID Application。做完后回我,我立刻用它重编译签名并生成正式 DMG。
3. **公证凭据**:App Store Connect 生成一个"App 专用密码",在 Mac 终端跑一次:
   `xcrun notarytool store-credentials machands-notary --apple-id <你的 Apple ID 邮箱> --team-id <上一步看到的 TEAMID> --password <App 专用密码>`
4. **npm 账号**:如果你还没有,`npm adduser` 注册一个(建议用户名 `machands` 或你自己的);做完告诉我账号名,我来发布 `agent/` 那个包。
5. 做完 2、3 后回我一句,我会自动跑 `release.sh` 出正式 DMG,放到官网 `/dl/` 下,把首页"Get MacHands"从收邮件切换成真下载,再帮你在 Lemon Squeezy 或 Paddle 建店铺收款(那两家的开店本身需要你自己的身份/银行信息,我没法代劳,但页面文案、产品配置我可以先写好)。

---

# 0.2.0 交付说明(2026-09-06):一次授权 + 授权后自检 + 开发者便利

用户的原话是三句:授权只做一次、要有引导;授权后要验证;"开发方便的标准你来定义"。合同在 SPEC.md §10–§14。

## 做了什么(改前 → 改后)

| 项 | 0.1.0 | 0.2.0 |
|---|---|---|
| 审批模式 | ask / auto | ask / auto / **readonly** / deny;黑名单 15 条,含 rootish 规则(`rm -rf /` 拦、`rm -rf /tmp/x` 放) |
| 授权流程 | 每条命令弹卡 | 配对成功自动弹**授权页**:选一次范围 → 三项系统权限各带「打开设置」→「授权并验证」→ 7 项自检结果 |
| RPC | 15 个 | **43 个**:sys.perms/which、policy.check、fs.get 目录(tar.gz)、screen.window/record、input.*×7、job.*×6、session.*×4、mcp.*×5、power.*×2、app.relaunch、verify.run;`run` 超时杀整棵进程树回 124 |
| CLI 命令 | 12 | **26**(use/verify/perms/which/check/policy/job/session/input/record/window-shot/mcp/power/relaunch;get 支持目录) |
| MCP 工具 | 8 | **31**;mac_get 按块循环到 eof,大二进制落文件不塞 base64 |
| 测试 | 38 | **58**(node --test test,58/58,28.7 s);Swift 侧新增 PolicyV2Tests 15 项 |
| 开发者便利 | — | `--no-relay` / `MACHANDS_NO_RELAY=1` 只起界面不连中继(界面调试副本用,免得同身份顶掉正式版) |

## 证据(工具 + 输入 + 数值 + 阈值)

- 构建(mini,macOS 26.2,Apple M4,Swift 6.2.4 命令行工具):`swift build -c release` 43.95 s 全量 / 6.33 s 增量,error 0(阈值 0)。
- 签名:`build-app.sh --sign "Apple Development: wang tianxin (4CBL3R2MCH)"`,`codesign --verify --strict` 通过,Team 3PW7WV39F5(与 0.1.0 相同)。
- 安装:`/Applications/MacHands.app` 0.2.0(build 20),老版保留为 `MacHands.app.old`(回滚边界);重启后配对保持,`machands macs` 两台在线。
- 装机冒烟(`node agent/bin/machands.mjs … --mac "牛马的Mac mini"`):
  - `check rm -rf /` → deny;`check ls -la ~/Desktop` → allow
  - `which godot blender ffmpeg` → 两个路径 + blender 缺失
  - `job submit 'echo out-1; sleep 1; echo err-1 >&2; exit 3'` → `job result` code=3,1051 ms;`job tail` out-1 / `--err` err-1
  - `session open` → `write 'echo hi-from-zsh $((6*7))\n'` → `read` 含 `hi-from-zsh 42`
  - `mcp servers` → 列出 mini 上 6 个已配置 MCP 服务器(只有名字与命令,不含 env)
  - `power on --seconds 60` / `power off` 正常
  - `run --timeout 3 -- 'sleep 30 & sleep 30'` → 3 s 后远端无残留 `sleep 30`(进程树杀干净)
  - `get <目录>` → tar.gz 7501 字节自动解包
  - `verify` → run ✓ fs ✓ job ✓ mcp ✓;screen ✗ input ✗ notify ✗(三项都是系统权限,提示里给了要点的路径)
- Node:`node --test test` 58/58;`npm pack --dry-run` 9 个文件 39.2 kB,version 0.2.0。

## 升级说明(以后每次发版都会遇到)

1. **macOS 26 在 App 更新后重置「屏幕录制」授权**(TCC 按代码签名匹配,二进制一换就掉)。升级后用户要重新勾一次;辅助功能与通知一般保留。发版说明里必须写这一句。
2. **同一 agent 身份的两条连接互相顶下线**(中继 `server.mjs` 对同 id 新连接发 BUSY 并关旧连接)。两个会话共用一台 Mac 时会频繁看到"和中继的连接断了"。下一版中继允许同 id 多连接,按连接路由回包。
3. `run` 的黑名单是对**整条命令**判定,命中则整条一个都不执行;CLI 提示已写明。黑名单只拦不可逆/越权动作:`tccutil reset All` 拦,定向的 `tccutil reset <服务> <bundle id>` 放。

## 你要做的事(只有你能做)

1. mini:系统设置 → 隐私与安全性 → **屏幕录制** 勾上 MacHands;**辅助功能** 勾上 MacHands;**通知** 允许 MacHands。
2. 菜单栏那只手 → **授权与验证…** → 选「开发者」→ **授权并验证** → 应见 7 项全 ✓(也可以在这台服务器上跑 `machands verify`)。
3. `cd agent && npm publish`(需要你的 OTP)。

## 诚实残差

- Swift 单元测试(PolicyV2Tests 15 项)在 mini 上**没跑**:命令行工具没有 XCTest。需要装了 Xcode 的机器,或改成 swift-testing。
- 界面截图与"真点击"交互测试要等屏幕录制 + 辅助功能勾上之后补;`--no-relay` 调试副本自己也截不了自己(候选:把自家窗口渲染成 PNG 的调试开关,注:画不出系统材质)。
- Air 尚未升级到 0.2.0:等 mini 的交互验证过了再推(同一份 .app 拷过去即可)。
- `perms` / `which` 恒 exit 0(信息类命令);`session read` 会把 zsh 提示符一起读回来。

---

# 0.3.0 发布准备(2026-09-06):从"重新下载"改成"App 自己更新"

用户原话:「app应该内置自动更新 而不是 重新下载这种更新方式导致的权限混乱
其他agent用machands的时候就一直申请权限 还不知道什么问题了」。

## 根因(已取证,不是猜的)

在 mini 上查到两件事,合起来就是"权限一直要重新申请"的全部原因:

1. **签名方式不对。** 0.1.0 与 0.2.0 都是 `Apple Development` 证书签的,`spctl -a -vv` = **rejected**。
   macOS 的 TCC 按代码签名的**指定要求**认 App;开发证书的指定要求写死在那张证书的名字上,
   一换二进制/一换证书就对不上,屏幕录制与辅助功能全部作废。实测:
   ```
   designated => identifier "app.machands.MacHands" and anchor apple generic
                 and certificate leaf[subject.CN] = "Apple Development: wang tianxin (4CBL3R2MCH)" …
   ```
   Developer ID 的指定要求锚在 `subject.OU`(team id `3PW7WV39F5`),跨版本不变。

2. **更新方式不对。** "下载新包 → 拖进 /Applications"每次都产生一次身份变更,
   而且当天 mini 上一度同时存在 **5 份**同 bundle id 的拷贝(`/Applications`、`~/Applications`、
   ThunderSSD 上的开发副本…),其中一份 **0.1.0 抢走了中继身份** —— 别的 agent 因此收到
   `unknown method`,用户在权限面板里看到同名条目,以为"勾了没用"。

## 这一轮做了什么(发布管线部分)

| 文件 | 作用 |
|---|---|
| `macapp/scripts/release.sh`(重写) | 一条命令:预检 → Developer ID 签名 + 强化运行时 → zip → 公证 → 钉票据 → 重打 zip → `spctl` 必须 accepted → 生成 appcast |
| `macapp/scripts/make-appcast.sh`(新) | sha256 + Ed25519 签名 → `appcast.json`;签完自验,不过就不出文件 |
| `macapp/scripts/keygen-release.sh`(新) | 一次性生成发布密钥,私钥 600 存 `~/.machands/`,只打印公钥 |
| `macapp/scripts/build-app.sh` | 加 `--hardened-runtime`;签完打印**指定要求**,让"会不会掉权限"当场看得见 |
| `site/download.html`(新) | 官网下载页,中英双语,零外部依赖,自己读 `appcast.json` 显示最新版 |
| `site/appcast.json`(新) | 样例(用测试密钥生成,发布时被真的覆盖) |
| `docs/RELEASE.md`(新) | 发布手册,含"只有你能做"的三步 |
| `SPEC.md` §15 | appcast 字段表、校验链、原地替换规则、版本协商、v0.3 验收 |

**硬约束(写进脚本)**:正式包的 bundle id 只能是 `app.machands.MacHands`;
`release.sh` 对 Info.plist 与签名两处硬断言,不等就退出 8,且不接受 `--bundle-id` 透传。
开发副本用 `app.machands.MacHands.dev`。

## 你要做的事(只有你能做,约 15 分钟)

1. **申请 Developer ID Application 证书**。现有三张(Apple Development / Apple Distribution /
   3rd Party Mac Developer)都不行 —— 后两张是上架 App Store 用的。
   步骤见 `docs/RELEASE.md` §2.1(钥匙串访问生成 CSR → developer.apple.com 换 `.cer` → 双击装上)。
2. **存一次公证凭据**:
   ```bash
   xcrun notarytool store-credentials machands-notary \
     --apple-id 你的AppleID --team-id 3PW7WV39F5 --password <App专用密码>
   ```
3. **生成发布密钥**:`cd macapp && ./scripts/keygen-release.sh`,把打印的公钥交给我填进 `Updater.swift`。
4. `cd agent && npm publish`(需要你的 OTP)。

做完 1–3,以后每次发版就是一条 `release.sh`,用户端零操作、零重新授权。

## 诚实残差(发布管线部分)

- 整条流水线**没有在 Mac 上跑过** —— 缺 Developer ID 证书,跑不到第 2 步。
  在 Linux 上验证过的只有:四个脚本 `bash -n` 通过、`keygen-release.sh` 与 `make-appcast.sh`
  全流程实跑(签名自验通过、JSON 合法)、`release.sh` 的参数校验与拒绝路径。
- "升级后权限不丢"是**按 TCC 的机制推断**的,要等第一次 Developer ID 发版后实测确认(SPEC §15.7 第 4 条)。
- macOS 15 起苹果会**定期**提醒确认屏幕录制,那是苹果的策略,和我们的更新无关,别误判成回归。
- 官网还没绑域名(nginx `server_name _`),`--host` 暂时要传 IP;`/var/www/machands/downloads/` 目录还没建。

---

## 授权纪律（2026-09-06 立，用户原话：「以后不要让我手动点了」）

一晚上让用户手动授权三轮（0.1.0 → 0.2.0 → 0.3.1），每次重签都把 TCC 清一遍。这是我们造成的，不是 macOS 的锅。以后按下面四条办：

1. **不在用户正在用的 Mac 上做发布验证。** 牛马的 Mac mini 是四条开发线共用的开发机，版本已冻结在 0.3.1，`autoUpdate` 已关。
   发布验证要么换机器，要么用 `build-app.sh --bundle-id app.machands.MacHands.dev` 编一个独立 bundle id 的副本——
   独立 id 在 TCC 里是另一条记录，怎么折腾都不动正式版的授权。

2. **签名身份一旦定下就不许再换。** TCC 按代码签名的指定要求匹配，换身份 = 所有授权作废。
   现在的身份是 `Developer ID Application: wang tianxin (3PW7WV39F5)`，指定要求绑的是团队 ID 而非证书名，跨版本稳定。
   这是最后一次因换身份导致的重新授权。

3. **引导由 App 做，不由聊天里的 agent 做。** App 启动时自检三项权限（完全磁盘访问 / 屏幕录制 / 辅助功能），
   缺哪项就在授权页里直接给「打开设置」的深链。用户被自己的 App 提醒，而不是被 agent 反复叫。

4. **「更新后三项授权仍在」是发布门槛的一条**，不是事后才发现的事。下一次真机更新必须验它，验不过不发。

### 一条要记住的坑

macOS 拒绝文件访问时给的是 **EINTR** 而不是 EPERM，`ls` 只说「Interrupted system call」，命令甚至会卡到超时（系统在等一个后台 App 弹不出来的对话框）。
表现得完全像硬盘坏了——同事查了 SMART 和 I/O 日志才排除。CLI 已经会认出这种情况并直接指到「完全磁盘访问权限」。

### 推荐用户只勾一次的那一项

**完全磁盘访问权限**一条顶下载、桌面、文稿、影片、音乐、图片、外置卷全部。
本产品的定位就是替 agent 在整台 Mac 上干活，逐项勾既繁琐又容易漏。屏幕录制与辅助功能仍需单独勾，系统不允许合并。
