# 发布手册

MacHands 是免费的 [MIT](../LICENSE) 开源项目：**不上 Mac App Store，也不卖许可证。**
对外网站目前是 <https://machands.pages.dev>（预定域名 `machands.app` 尚未解析）。
签名包通过 [GitHub Releases](https://github.com/UnstoppableCurry/MacHands/releases) 发布；在 Release 附件出现之前，请从源码构建，不要编造下载地址。

这一页讲维护者怎么签名、公证、生成 appcast，以及只有证书持有人能做的那几步。

---

## 0. 为什么不上架

Mac App Store 要求 App 跑在沙盒里。沙盒禁止的恰好是 MacHands 的全部功能:

| 沙盒禁止 | MacHands 靠它做什么 |
|---|---|
| 执行任意 shell 命令 | `run` / `job.*` / `session.*` —— 代理在 Mac 上编译、跑测试 |
| 用 CGEvent 注入键鼠 | `input.*` —— 点按钮、试手感 |
| 截别的 App 的屏 | `screen.shot` / `screen.window` / `screen.record` |
| 读用户主目录里的任意路径 | `fs.*` —— 拉日志、传源码 |

这些不是"申请一下就能开"的例外,是沙盒的设计边界。所以:GitHub Releases 分发 + App 自动更新。

---

## 1. 为什么必须是 Developer ID 证书(这是权限反复丢失的根因)

macOS 用 TCC 管"屏幕录制""辅助功能"这类授权。**TCC 记住的不是路径,是代码签名的「指定要求」(designated requirement, DR)。**
下次同一个 bundle id 的 App 来要权限,系统拿它的签名去套那条 DR;套得上 = 还是它,权限继续有效;套不上 = 陌生 App,重新授权。

看两种证书签出来的 DR 差在哪:

```
# Apple Development(现在 0.2.0 用的,错的)
designated => identifier "app.machands.MacHands" and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: wang tianxin (4CBL3R2MCH)"
              and certificate 1[field.1.2.840.113635.100.6.2.1]

# Developer ID Application(对的)
designated => identifier "app.machands.MacHands" and anchor apple generic
              and certificate 1[field.1.2.840.113635.100.6.2.6]
              and certificate leaf[field.1.2.840.113635.100.6.1.13]
              and certificate leaf[subject.OU] = "3PW7WV39F5"
```

差别在最后一行:Developer ID 认的是 **team id**(`3PW7WV39F5`),一个不会变的东西;
开发证书认的是那张证书的名字,证书一年一换、换机重签就变。再加上开发证书签的包**根本过不了公证**
(`spctl -a -vv` = rejected),别人的 Mac 双击打不开。

> 你钥匙串里现在这三张,只有第一张不存在:
>
> | 证书 | 用途 | 能不能官网发 |
> |---|---|---|
> | **Developer ID Application** | 官网/自行分发 | ✅ **需要新建这一张** |
> | Apple Distribution | 上架 App Store / TestFlight | ❌ |
> | 3rd Party Mac Developer Application | 上架 Mac App Store | ❌ |
> | Apple Development | 自己机器上开发调试 | ❌ |

**一句话**:换成 Developer ID + 公证 + App 内原地更新之后,升级不再重置系统权限。
(macOS 15 起苹果自己会**定期**提醒你确认屏幕录制,那是苹果的策略,和升级无关。)

---

## 2. 只有你本人能做的三件事

### 2.1 申请 Developer ID Application 证书(约 5 分钟,一次)

1. 打开 <https://developer.apple.com/account/resources/certificates/list>
2. 点 **+** → 选 **Developer ID Application** → Continue
   (选项在列表最下面一组"Software";不要选 Apple Distribution)
3. 它要一个 CSR。在 Mac 上开「钥匙串访问」→ 菜单 **钥匙串访问 → 证书助理 → 从证书颁发机构请求证书**,
   邮箱填你的 Apple ID,选 **存储到磁盘**,得到 `CertificateSigningRequest.certSigningRequest`
4. 上传这个 CSR → 下载生成的 `.cer` → **双击**装进钥匙串
5. 验一下:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

看到 `Developer ID Application: wang tianxin (3PW7WV39F5)` 就成了。

> 一个账号最多 5 张 Developer ID Application 证书,且**私钥只在生成它的那台 Mac 上**。
> 在 mini 上生成,就在 mini 上发布;想换机器发布,要从钥匙串导出 `.p12` 带过去。

### 2.2 存一次公证凭据(一次)

先去 <https://account.apple.com/account/manage> 生成一个 **App 专用密码**(App-Specific Password),然后:

```bash
xcrun notarytool store-credentials machands-notary \
  --apple-id 你的AppleID邮箱 \
  --team-id 3PW7WV39F5 \
  --password 那个App专用密码
```

存进钥匙串之后,发布脚本再也不需要密码 —— 它只传 profile 名字。
(脚本**从不**接受密码作为参数或环境变量:`ps` 能看见 argv。)

验一下:

```bash
xcrun notarytool history --keychain-profile machands-notary
```

### 2.3 生成发布签名密钥(一次)

这把钥匙和苹果证书是两回事,它管的是"App 自动更新时怎么确认这个包是我们发的":

```bash
cd macapp && ./scripts/keygen-release.sh
```

- 私钥落在 `~/.machands/release-key.pem`(600),**不进仓库、不进 CI**。
- 它打印一行 base64 公钥,把它填进 `macapp/Sources/MacHands/Updater.swift` 的 `releasePublicKey`,再编一版。
  只有内置了这个公钥的 App,才认得出以后发布的包。
- **备份这个私钥**(密码管理器)。丢了就得换公钥重发一版,老用户只能手动重装一次。
- 想再看一次公钥:`./scripts/keygen-release.sh --show`

---

## 2.5 bundle id 不可改(硬约束)

正式发布包的 bundle id **永远是 `app.machands.MacHands`**。`release.sh` 会对 Info.plist 与代码签名
两处都做断言,不等就退出 8、不产出任何包;它也不接受 `--bundle-id` 参数。

起因:2026-09-06 那天 mini 上一度同时存在 5 份同 bundle id 的拷贝(`/Applications`、`~/Applications`、
ThunderSSD 上的开发副本…),其中一份 0.1.0 抢走了中继身份,别的 agent 收到 `unknown method`,
系统权限面板里出现同名条目,用户以为"权限勾了没生效"。

要做界面调试副本,用另一个 id、并且别走发布流程:

```bash
./scripts/build-app.sh --bundle-id app.machands.MacHands.dev --sign adhoc
open dist/MacHands.app --args --no-relay      # 只起界面,不抢中继身份
```

开发副本永不自动更新(SPEC §15.5)。

---

## 3. 发布一版

```bash
cd macapp
./scripts/release.sh \
  --sign "Developer ID Application: wang tianxin (3PW7WV39F5)" \
  --keychain-profile machands-notary \
  --version 0.3.0 \
  --host https://machands.app \
  --notes-zh "内置自动更新;审批卡先说要干什么。" \
  --notes-en "Built-in updates; approval cards lead with intent."
```

它按顺序做六件事,任何一步失败都会停下来并告诉你下一步:

| 步 | 做什么 | 失败常见原因 |
|---|---|---|
| 1/6 预检 | 证书、公证凭据、发布私钥、版本号一致、git 干净 | `macapp/VERSION` 和 `--version` 不一致;工作区脏(要发就加 `--allow-dirty`) |
| 2/6 构建签名 | `build-app.sh --sign … --hardened-runtime --universal` | 编译错误;证书名字打错一个字 |
| 3/6 打包 | `ditto -c -k --keepParent` → `MacHands-<版本>.zip` | — |
| 4/6 公证 | `notarytool submit --wait` → `stapler staple` .app → **用钉好票据的 .app 重打 zip** | 苹果拒收(看 `notarytool log`);忘了强化运行时 |
| 5/6 Gatekeeper | `spctl -a -vv -t exec` 必须 **accepted** | 票据没钉上;证书不是 Developer ID |
| 6/6 appcast | sha256 + Ed25519 签名 → `appcast.json` | 没有发布私钥;macOS 自带 LibreSSL(装 `brew install openssl@3`) |

> **票据钉在 .app 上,钉不到 zip 上。** 所以流程是"打 zip → 公证 → 钉 .app → 重打 zip",
> 最后那个 zip 才是发出去的那一个。顺序错了,用户离线第一次打开会被拦。

### 把两个文件发到用户找得到的地方

公开渠道是 **GitHub Releases**（有附件之后才算发布）。`appcast.json` 里的 `url` 必须指向那个真实存在的 zip，不要写一个还不存在的地址。

若你另外有静态站，两个文件的对应关系是：

```
dist/MacHands-0.3.0.zip   →  <站点根>/downloads/MacHands-0.3.0.zip
dist/appcast.json         →  <站点根>/appcast.json
```

`--host` 填你实际上传 appcast 的根地址。预定域名 `https://machands.app` 目前无法解析；对外说明请指向 <https://machands.pages.dev>。
`site/download.html` 是样例页，不是现成的签名包下载入口。

### 发完自查

```bash
# 用你真正发布 appcast 的那个 URL，不要假设 machands.app 已经能解析
curl -s "$APPCAST_URL" | head
shasum -a 256 dist/MacHands-0.3.0.zip          # 要和 appcast 里的 sha256 一致
spctl -a -vv -t exec dist/MacHands.app          # accepted
xcrun stapler validate dist/MacHands.app        # The validate action worked!
```

老用户那边:App 自己发现新版 → 下载 → 验 sha256 与 Ed25519 签名 → 原地替换 → 重启。
**不需要重新授权系统权限**(前提是这一版和上一版都用同一张 Developer ID 证书签)。

---

## 4. appcast.json 长什么样

下面是字段格式。`url` 必须是发布后真实存在的 zip（GitHub Releases 附件或你的静态站），不要写一个打不开的地址。

```json
{
  "version": "0.3.0",
  "build": 21,
  "url": "<发布后真实存在的 zip URL>",
  "sha256": "60a9c10f…",
  "sig": "6qAhL7gK…",
  "notes_zh": "…",
  "notes_en": "…",
  "min_os": "13.0",
  "published": "2026-09-06T11:44:56Z"
}
```

`sig` 是用发布私钥对 **`sha256` 那串十六进制文本**做的 Ed25519 签名(base64url,解码后 64 字节)。
App 端校验链:下载 zip → 自己算 sha256 → 和 `sha256` 字段比对 → 用内置公钥验 `sig` → 才允许替换。
三者任一对不上就拒绝安装 —— 官网被人改了也换不动用户的 App。

字段与校验规则的完整定义在 `SPEC.md` §15。

---

## 5. 出问题时

| 现象 | 原因 | 怎么办 |
|---|---|---|
| `钥匙串里找不到「…」` | 证书名字不是一字不差 | `security find-identity -v -p codesigning` 复制粘贴,含括号里的 team id |
| `钥匙串里没有名为…的公证凭据` | 没跑过 store-credentials,或钥匙串锁了 | 见 §2.2;先解锁钥匙串 |
| 苹果拒收 | 多半是没开强化运行时,或用了错的证书 | `xcrun notarytool log <id> --keychain-profile machands-notary` |
| `spctl` 不是 accepted | 票据没钉上 / 证书不对 | 重跑;或单独 `xcrun stapler staple dist/MacHands.app` |
| `找不到 OpenSSL 3` | macOS 自带的是 LibreSSL,签不了 Ed25519 | `brew install openssl@3`(或设 `MACHANDS_OPENSSL`) |
| 用户升级后还是要重新勾权限 | 这一版或上一版不是 Developer ID 签的 | 两版都必须同一张 Developer ID 证书;`codesign -d -r-` 看 DR 里有没有 `subject.OU` |
| 版本号对不上、更新反复触发 | `macapp/VERSION`、`--version`、appcast 三处不一致 | 以 `macapp/VERSION` 为准,脚本已经会拦 |
