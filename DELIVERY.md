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
   **npm 包还没发布之前**,agent 机器上用仓库路径代替:
   `node /root/wtx/machands/agent/bin/machands.mjs pair "MH1…"`。
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

Claude Code 接入:`claude mcp add machands -- node /root/wtx/machands/agent/bin/machands.mjs mcp`(发布后换成 `npx -y machands mcp`)。


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

## 发布前只有你能做的三件事

1. ~~**Developer ID 证书**~~ **已完成(2026-09-04)**:`Developer ID Application: wang tianxin (3PW7WV39F5)`,已用它重新签名、打包了全部 3 个 DMG(通用/Apple Silicon/Intel),已上线 `/dl/`。
2. **公证凭据**:在 App Store Connect 生成 App 专用密码或 API Key,然后
   `xcrun notarytool store-credentials machands-notary --apple-id <你的 Apple ID> --team-id <TEAMID> --password <app 专用密码>`。
3. **发布 npm 包**(配对码里的 `npx -y machands@latest` 依赖它):
   `cd agent && npm login && npm publish --access public`。包名 `machands` 若被占用,改 `agent/package.json` 的 `name` 并同步改 `macapp/Sources/MacHandsCore/PairingCode.swift` 里的那一行命令。

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
