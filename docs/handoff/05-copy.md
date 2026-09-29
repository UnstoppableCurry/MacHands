# 作业 5：各家后台要填的标准文案（可直接粘贴）

> 这份文档给**自动化浏览器助手**执行。
> 这不是一个"去某个网站做某件事"的作业，而是**给作业 2 和作业 3 用的素材库**。当那些后台要求你填商品简介、退款政策、支持邮箱之类的内容时，回来这里复制。


## 🚫 红线（每份作业都适用，违反就停下来交回给人）

1. **不许花钱**，除了本作业里明确写出的那一笔。任何加购、增值服务、更长年限的预付，一律不买。
2. **不许把密钥、API key、密码、签名密钥贴进聊天记录**、在线文档、截图或代码仓库。按文末「安全交接」处理。
3. **不许改动已有的 Apple 证书**（不新建、不撤销、不下载、不删除）。
4. **遇到要身份证件、护照、银行卡号、人脸识别、活体检测的步骤，立刻停下**交回给人。不要代填，不要上传证件。
5. **不许注册与本作业无关的账号**；能取消的营销邮件勾选一律取消。
6. **两步验证卡住就停**，把页面停在那里交回给人，不要试图绕过。
7. 页面改版、入口换了名字时，**按含义找相近入口**，并在回填表里写明"实际路径是什么"。**不要编造一个不存在的按钮名当作已完成。**

## 这是什么产品（一句话）

MacHands 是一个 macOS 菜单栏软件，让云端 AI 助手在用户自己的 Mac 上执行命令、读写文件、截屏、控制键鼠。只在官网卖，49 美元买断。我们的服务器 IP 是 `134.199.230.126`。

---

## 使用规则

1. **原样复制，不要改写、不要自己发挥、不要翻译成第三种语言。** 后台是英文界面就用英文版，中文界面就用中文版。
2. 遇到字数上限，从**后面**往前删整段，不要删前面的句子。每段都是独立的，删掉不影响前面。
3. 凡是 `<域名>` 的地方，替换成作业 1 拿到的真实域名。
4. 凡是**方括号里的内容**（例如 `[老板的邮箱]`）是占位，要么由老板提供，要么停下来问，**不要自己编一个填进去**。
5. 如果官网上的《服务条款》《隐私政策》与这里的文案有出入，**以官网为准**，并把不一致的地方写进回填表告诉我们。

---

## 一、商品简介（短，一句话）

**中文**

```
MacHands 让云端 AI 助手在你自己的 Mac 上干活：执行命令、读写文件、截屏、控制键鼠。端到端加密，每一条都由你说了算。
```

**English**

```
MacHands lets a cloud AI assistant work on your own Mac: run commands, read and write files, take screenshots, control the keyboard and mouse. End-to-end encrypted, and every action is yours to approve.
```

---

## 二、商品简介（长，用于商品详情页）

**中文**

```
MacHands 是一个 macOS 菜单栏应用，把你的 Mac 接给云端的 AI 助手用。

它能做什么：
· 在你的 Mac 上执行命令、编译项目、跑测试
· 读写文件，在本机与远端之间传目录
· 截屏、录屏、截取指定窗口
· 控制键盘鼠标，替你点按钮、试手感
· 跑后台作业，桥接你本机已经装好的 MCP 服务器

它怎么保证安全：
· 端到端加密，中转服务器只看得到密文
· 三种授权范围，一次选定：全部允许、只读、或每条命令都问你
· 危险命令黑名单在任何模式下都生效
· 每条命令和你的每次决定都写进本机的审计日志
· 随时可以暂停

不需要开启"远程登录"，不暴露 SSH。执行命令的是这个应用本身。

系统要求：macOS 13 或更高，Apple Silicon 与 Intel 都支持。
本软件不在 Mac App Store 上架——App Store 要求应用运行在沙盒中，而沙盒禁止上述全部能力。请从官网下载。

49 美元买断，含一年更新，内置 7 天试用。
```

**English**

```
MacHands is a macOS menu-bar app that hands your Mac to a cloud AI assistant.

What it does:
· Runs commands, builds projects, and runs tests on your Mac
· Reads and writes files, and moves whole directories between machines
· Takes screenshots and screen recordings, including a single window
· Controls the keyboard and mouse to click buttons and try things out
· Runs background jobs and bridges the MCP servers already installed on your Mac

How it stays safe:
· End-to-end encrypted — the relay only ever sees ciphertext
· Three access scopes, chosen once: allow everything, read-only, or ask about every command
· A denylist of dangerous commands applies in every mode
· Every command and every decision you make is written to a local audit log
· Pause at any time

You do not turn on Remote Login, and no SSH is exposed. The app itself runs the commands.

Requires macOS 13 or later. Apple Silicon and Intel both supported.
Not on the Mac App Store — the App Store requires sandboxing, and the sandbox forbids every capability above. Download from the official site.

49 USD, one-time. Includes one year of updates. Comes with a 7-day trial.
```

---

## 三、交付说明（后台问"买家怎么拿到商品"时填）

**中文**

```
付款成功后，系统会自动把许可证发送到买家的付款邮箱，通常在一分钟内送达。
买家在软件的设置窗口粘贴该许可证即可激活。
软件本身从 https://<域名>/ 免费下载，未激活时有 7 天完整功能试用。
如果超过 10 分钟仍未收到许可证邮件，请联系 [支持邮箱]。
```

**English**

```
After payment, the license is emailed automatically to the address used at checkout, usually within a minute.
The buyer pastes it into the app's Settings window to activate.
The app itself is a free download from https://<域名>/ and includes a full 7-day trial before activation.
If the license has not arrived within 10 minutes, contact [支持邮箱].
```

---

## 四、退款政策

> ⚠️ **这一段的具体条款必须由老板拍板。** 下面是一个常见的、对买家友好的版本，作为草稿。
> **在老板确认之前，不要把它填进任何收款后台。** 如果后台强制要求填写才能保存，把这一步停下来交回给人。

**中文（草稿，待老板确认）**

```
本软件提供 7 天完整功能试用，请在购买前先试用，确认它能在你的机器上正常工作。

购买后 14 天内，如果软件无法在你的机器上正常工作，且我们无法为你解决，可以全额退款。请发邮件到 [支持邮箱]，说明你遇到的问题。

因"买错了""不想要了"提出的退款，我们同样会受理，但请理解这属于我们的善意而非义务。
```

**English (draft, pending owner's approval)**

```
This software comes with a full-featured 7-day trial. Please try it before buying and confirm it works on your machine.

Within 14 days of purchase, if the software does not work on your machine and we cannot fix it for you, you can have a full refund. Email [支持邮箱] and tell us what went wrong.

Refunds for "bought it by mistake" or "changed my mind" are also honoured, though please understand that this is goodwill rather than an obligation.
```

---

## 五、卖家 / 支持信息

后台要求填这些时，用下面的对应关系。**方括号里的内容必须由老板提供**，不要编造。

| 后台字段（各家叫法不同） | 填什么 |
|---|---|
| 商家名称 / Business name | `[老板决定：个人姓名 或 品牌名]` |
| 商家类型 | 个人 / Individual |
| 国家 / 地区 | `[老板提供]` |
| 支持邮箱 / Support email | `[支持邮箱]`（建议是 `support@<域名>`，需老板确认已开通收信） |
| 网站 / Website | `https://<域名>/` |
| 商品类别 | 软件 / Software，若可细分选 开发者工具 / Developer Tools |
| 商品是否为数字商品 | 是 |
| 是否需要发货 | 否 |
| 隐私政策链接 | `https://<域名>/privacy.html` |
| 服务条款链接 | `https://<域名>/terms.html` |

> 注意：隐私政策与服务条款这两个页面**可能还没上线**。填之前先在浏览器打开确认能访问；打不开就先不要填，在回填表里注明"待页面上线后补填"。

---

## 六、隐私要点（后台要一段简短说明时用）

**中文**

```
我们不收集、不存储你在 Mac 上执行的任何内容。命令与文件在你的 Mac 和你的 AI 助手之间端到端加密传输，中转服务器只经手密文，无法解密。审计日志只保存在你自己的 Mac 上，不上传。购买时我们只接触收款渠道提供的邮箱，用于发送许可证。
```

**English**

```
We do not collect or store anything you run on your Mac. Commands and files travel end-to-end encrypted between your Mac and your AI assistant; the relay only ever handles ciphertext and cannot decrypt it. The audit log stays on your own Mac and is never uploaded. At purchase time we only ever see the email address supplied by the payment provider, and we use it to send you the license.
```

---

## 回填表

| 项目 | 值 |
|---|---|
| 用到了这里的哪几段（列出章节号） | |
| 因字数上限删掉了哪些段落 | |
| `[方括号]` 占位里，哪些老板还没给你 | |
| 官网 privacy.html / terms.html 当时能否打开 | |
| 官网条款与本文档不一致的地方 | |
| 退款政策是否已由老板确认（未确认则应为"未填"） | |
