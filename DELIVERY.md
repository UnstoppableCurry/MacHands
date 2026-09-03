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
| `machands shot`(授权屏幕录制后) | 通过,得到真实桌面 PNG;发现并修复 Retina 缩放只画四分之一的 bug(提交 `screen.shot: draw whole source rep`),修复版待重新编译验证 |
| MCP stdio(`initialize` / `tools/list` / `mac_run`) | 通过,11 个工具,`mac_run` 返回真实结果 |
| 暂停 → 命令被拒(77) | 待用户点暂停后验证 |
| 撤销授权 → 未配对(66) | 待用户在设置里撤销后验证 |

## 发布前只有你能做的三件事

1. **Developer ID 证书**:Xcode → Settings → Accounts → 你的团队 → Manage Certificates → `+` → Developer ID Application。
   验证:`security find-identity -v -p codesigning` 里出现 `Developer ID Application: 你的名字 (TEAMID)`。
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
