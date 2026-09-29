# 开卖手册

MacHands 卖 49 美元买断,含一年更新,内置 7 天试用。这份文档讲**怎么从零到收第一笔钱**。

链路是这样的:

```
买家点"购买" → 收款渠道的结账页 → 付款成功 → 渠道推 webhook 到我们服务器
             → 验签 → 查重 → 签一张许可证 → 落盘 → 发邮件给买家
```

你要做的只有一次性的配置。之后每一单都是自动的。

---

## 一、选哪家收款渠道

**结论:先用 Creem,做大了再考虑 Paddle。**

这个结论对你(个人开发者、人在中国大陆、卖 49 美元的 Mac 软件)成立,理由按重要性排:

**1. 必须是 merchant of record(MoR),不能是普通支付网关。**
MoR 的意思是"渠道自己是法律上的卖家",欧盟增值税、美国各州销售税、日本消费税全由它申报缴纳,你只管收净额。
不是 MoR 的话(比如直接接 Stripe),你要自己处理几十个税区的申报——一个人做不了,而且做错了是真会被追缴的。
Creem、Paddle、Lemon Squeezy **三家都是 MoR**,这一关三家都过。

**2. 你能不能真的把钱提出来。这一条淘汰了 Lemon Squeezy。**
Lemon Squeezy 被 Stripe 收购后,提现逐步并到 Stripe 的账户体系里,而 Stripe 至今不向中国大陆个人开放收款账户。
你很可能能注册、能收到订单,却在提现那一步卡死。**钱进得来出不去,是最糟的失败方式**,因为你已经把软件卖出去了。
Creem 和 Paddle 都支持通过 Wise / PayPal / 境外银行账户结算,对大陆个人可行(仍需你自己有其中一个渠道)。

**3. 开户门槛。这一条决定了先用 Creem。**
Paddle 的风控是按 B2B SaaS 设计的,要审网站、审公司主体、审产品说明,个人开发者被拒或被反复要材料很常见,快则几天慢则两三周。
Creem 是专门做独立开发者这一块的,注册基本是当天到几天,要的材料少。
你现在的状态是"想尽快卖出第一份",Creem 的摩擦最小。

**4. 费率。三家都在 5% + 固定手续费这个量级(Creem 与 Lemon Squeezy 约 5% + $0.5,Paddle 约 5% + $0.5,大额分档)。**
49 美元一单,手续费差异不到一美元。**不要为了零点几个百分点去选一个你提不出钱的渠道。**

**什么时候该换成 Paddle:** 开始有公司客户要正规发票和采购流程、月流水到几千美元、或者要做订阅和多档定价。Paddle 在这些场景更成熟,那时候你也扛得住它的开户审核了。

**费率和政策会变。** 上面这些是写这份文档时的情况,注册前请自己去各家定价页和支持文档确认一遍,特别是"中国大陆能不能提现"这一条,直接问客服并留下书面回复。

---

## 二、一次性配置

### 1. 建产品

在渠道后台建一个产品:

- 名字:MacHands
- 价格:49 USD,一次性(不是订阅)
- 交付方式:选"数字商品 / 无需发货"。**不要**上传文件,许可证由我们自己发邮件。
- 描述里写清楚:买断、含一年更新、7 天试用、支持 macOS 13 以上。

拿到产品的 checkout 链接,填到官网的购买按钮上。

**Paddle 用户注意:** 在 checkout 配置里把买家邮箱透传到 `custom_data.email`。
Paddle 的 `transaction.completed` 推送里不保证带邮箱,不透传的话我们收到单却不知道发给谁,
会被标成 `needs_email` 等你人工处理。Creem 和 Lemon Squeezy 的推送自带邮箱,不用管这条。

### 2. 配 webhook

后台找到 webhook / notifications 设置,新建一条,地址填:

| 渠道 | 地址 |
|---|---|
| Creem | `https://你的域名/api/store/webhook/creem` |
| Paddle | `https://你的域名/api/store/webhook/paddle` |
| Lemon Squeezy | `https://你的域名/api/store/webhook/lemonsqueezy` |

订阅的事件:

| 渠道 | 付款成功 | 退款 |
|---|---|---|
| Creem | `checkout.completed` | `refund.created` |
| Paddle | `transaction.completed` | `adjustment.created` |
| Lemon Squeezy | `order_created` | `order_refunded` |

**地址必须是 https。** 没绑域名之前不要上线收钱——http 下 webhook 的签名密钥会在链路上裸奔。

建完会给你一个 signing secret,复制下来,下一步要用。

### 3. 填服务器配置

```bash
sudo mkdir -p /etc/machands
sudo cp tools/store/store.env.example /etc/machands/store.env
sudo chmod 600 /etc/machands/store.env
sudo nano /etc/machands/store.env
```

至少要填:

- `SITE_ORIGIN` — 你的域名,买家邮件里的下载地址用它
- 你用的那一家的 `*_WEBHOOK_SECRET` — **其它两家留空**。留空的渠道会直接返回 404,
  空密钥永远不会变成"谁都能伪造订单"
- `MAIL_BACKEND` — 先填 `none` 也行,这样订单照收、证照签,只是不自动发信,你用 `admin.mjs resend` 手动补。
  等邮件配好了再改成 `resend` 或 `smtp`

### 4. 装服务

```bash
sudo cp tools/store/machands-store.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now machands-store
systemctl status machands-store
curl -s http://127.0.0.1:8790/api/store/health
```

health 应该回:

```json
{"ok":true,"providers":["creem"],"mailer":"none","mailer_ready":true,"orders":0}
```

`providers` 里出现的就是真正启用了的渠道。如果是空数组,说明 secret 没填对。

### 5. 开 nginx 入口

把 `tools/store/nginx-store.conf` 的内容粘进 `/etc/nginx/sites-enabled/machands` 的 `server {}` 里,
放在 `location /api/ {` 那一段**前面**,然后:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

---

## 三、上线前必须走一遍的测试单

**不要用真信用卡当第一次测试。** 每家都有测试模式:

1. 后台切到 test / sandbox 模式,拿测试模式的 webhook secret 填进 `store.env`,重启服务。
2. 用测试卡号走一遍完整结账(各家文档里都有测试卡号,通常是 `4242 4242 4242 4242`)。
3. 看服务器:

```bash
journalctl -u machands-store -n 30 --no-pager
node tools/store/admin.mjs list
```

应该看到一条 `order.issued`,`list` 里有一单,状态是 `sent`(配了邮件)或 `issued_hold`(还是 none)。

4. 检查买家那封信真的收到了,而且**许可证粘进 MacHands 能激活**。这一步必须亲眼看到,
   不能只看日志说发出去了。
5. 在渠道后台把这笔测试订单退款,确认服务器收到 `order.refunded` 日志。
6. 切回 live 模式,把 live 的 secret 换进 `store.env`,重启服务,再 `curl` 一次 health。

---

## 四、日常运维

### 看单

```bash
node tools/store/admin.mjs list                    # 最近所有订单
node tools/store/admin.mjs list --since 2026-09-01
node tools/store/admin.mjs show --order <订单号>    # 详情,默认不打印许可证
node tools/store/admin.mjs show --order <订单号> --license   # 要看证才加这个
```

`list` 和 `show` 默认都不吐许可证,因为终端历史会留、截图会外传。要用时才显式要。

### 买家说没收到信

```bash
node tools/store/admin.mjs resend --order <订单号>
```

先去 `show` 看一眼 `state`:

| state | 意思 | 怎么办 |
|---|---|---|
| `sent` | 已发出 | 让买家翻垃圾箱;还没有就 `resend` |
| `issued_hold` | 证签好了,按配置没发信 | `resend`(先把 `MAIL_BACKEND` 配好) |
| `issued_mail_failed` | 发信真的失败了 | 看 `mail_error`,修好再 `resend` |
| `needs_email` | 推送里没有买家邮箱 | 去渠道后台查到邮箱,用 `issue --email … --order 同一个订单号 --send` |
| `issue_failed` | 签证失败(多半是私钥读不到) | 看 `error`,修好后 `issue` |

### 手工补一张证

```bash
node tools/store/admin.mjs issue --email buyer@example.com --send
```

用于:线下收款、补偿、送人、朋友价。加 `--order <号>` 可以挂到某笔真实订单上。

### 退款

退款事件进来后,订单会被标成 `refunded` 并记下时间,**但已经发出去的许可证仍然有效**。

这是有意的,不是漏做:MacHands 目前没有吊销机制——App 是离线校验签名的,不联网问服务器。
要做吊销就得让 App 每次启动都联网,那会带来更糟的问题(断网不能用、隐私、单点故障)。

对 49 美元的产品,这个取舍是对的:退款率本来就低,少数人白拿一份,好过让所有正常用户忍受联网校验。
如果哪天真被批量滥用,再考虑在 appcast 里下发一份吊销名单,让更新时生效。

### 备份

**两样东西丢了就完蛋:**

1. `/root/.machands-license/key.json` — 签发私钥。丢了以后再也签不出新证,老证还能用。
   **现在就离线备份一份**(U 盘、密码管理器附件都行),不要只放在服务器上。
2. `/opt/machands/store/` — 所有订单和已发的证。丢了就不知道谁买过、补发不了。

```bash
tar czf ~/machands-orders-$(date +%F).tgz /opt/machands/store
```

---

## 五、边界(照实写进产品页,不要藏)

- 许可证是**永久**的,不会到期。"含一年更新"是承诺,技术上没有卡死——一年后你仍然能用,
  只是新版本我们可能不再免费给。这样写是因为买断就该是买断。
- 一张证不绑机器,换 Mac、重装系统都能再粘一次。我们靠的是诚信,不是加密狗。
- 退款不吊销证(理由见上)。
- 邮件可能进垃圾箱,尤其是 QQ 邮箱和企业邮箱。产品页上留一句"没收到就联系我们",
  比什么反垃圾配置都管用。
