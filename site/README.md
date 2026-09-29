# MacHands 官网

这个目录就是 `http://<域名>/` 的内容。线上根目录是 `/var/www/machands`。

零外部依赖:没有 CDN、没有网络字体、没有统计脚本。页面加载的每个文件都来自本站,
`grep -ohE 'https?://[^"]+' *.html assets/*` 的结果应当为空。

## 文件

| 文件 | 干什么 |
|---|---|
| `index.html` | 首页。是什么 → 三个能力 → 安全 → 三步上手 → 为什么不上架 → 定价 → 常见问题 |
| `download.html` | 下载页。三个包怎么选、装好之后三步、三项系统权限、升级由 App 自己完成 |
| `pricing.html` | 定价页。价格卡、试用到期拦什么、怎么激活、购买相关问答 |
| `docs.html` | 文档页。配对三步、三种授权范围、常用命令表、`--why` 规范、许可证、排障 |
| `privacy.html` | 隐私。加密边界、中继记什么、审计日志只在本机、网站不装统计 |
| `terms.html` | 条款。授权范围、试用、退款、责任、商标 |
| `assets/config.js` | **发版只改这一个文件**:版本号、三个包的文件名、价格、结账链接 |
| `assets/site.css` | 全站样式。深浅色两套变量,语言切换规则也在里面 |
| `assets/site.js` | 切语言、填版本与链接、下载页读 `appcast.json` |
| `appcast.json` | 自动更新用的清单,由 `macapp/scripts/release.sh` 生成,不要手改 |

## 发版要改什么

1. `macapp/scripts/release.sh` 跑完会生成新的 `appcast.json` 和三个 DMG。
2. DMG 放进 `/var/www/machands/dl/`。
3. 改 `assets/config.js` 里的 `version` 和 `downloads` 三个文件名。**只有这一处**,页面上的版本号和下载链接都从它来。
4. `appcast.json` 覆盖到站点根目录。

下载页会在运行时再读一次 `/appcast.json` 并以它为准,所以第 3 步忘了也不会显示成旧版本;
但首页和文档页读的是 `config.js`,还是要改。

## 上线前必须替换的占位符

页面里故意留了三个大写占位符,**上线前必须全部替换**,否则用户会看到它们:

| 占位符 | 出现在 | 换成什么 |
|---|---|---|
| `__SITE_ORIGIN__` | 6 个页面的 `og:url` | 站点根地址,例如 `https://machands.app`,**结尾不带斜杠** |
| `__CHECKOUT_URL__` | `assets/config.js`、`index.html`、`pricing.html` | 支付渠道给的结账链接 |
| `__REFUND_POLICY__` | `pricing.html`、`terms.html` | 退款政策正文 |

替换命令(先备份):

```sh
cd /var/www/machands
sed -i 's|__SITE_ORIGIN__|https://你的域名|g' *.html
sed -i 's|__CHECKOUT_URL__|https://结账链接|g' *.html assets/config.js
```

`__CHECKOUT_URL__` 没替换时不会留死链接:`site.js` 认得出这个占位符,
会把购买按钮变成「购买通道即将开放 / Checkout opens soon」并停用。这是有意的兜底。

`__REFUND_POLICY__` 是纯文本占位,替换时**要自己写中英两份**并包进 lang 标签,格式照抄旁边的句子:

```html
<span lang="zh">中文退款政策。</span><span lang="en">English refund policy.</span>
```

## 部署

```sh
rsync -a --delete site/ /var/www/machands/ \
  --exclude dl --exclude datadance --exclude '*.png' --exclude '*.ico'
```

排除项是站点上已有、不归这个目录管的东西:下载包 `dl/`、另一个产品的目录 `datadance/`、
以及图标与 og 图(`favicon*.png`、`favicon.ico`、`apple-touch-icon.png`、`icon-512.png`、`og-image.png`)。
页面引用的就是这些既有文件,不要删。

部署完自测:

```sh
for p in / /download.html /pricing.html /docs.html /privacy.html /terms.html; do
  curl -s -o /dev/null -w "$p %{http_code}\n" http://127.0.0.1$p
done
```

## 中英切换怎么实现的

不做两套 URL。每段文案写成一对相邻元素:

```html
<span lang="zh">中文</span><span lang="en">English</span>
```

`<html>` 上的 `data-lang` 决定显示哪一边,规则在 `site.css` 顶部:

```css
html[data-lang="zh"] [lang="en"] { display: none !important; }
html[data-lang="en"] [lang="zh"] { display: none !important; }
```

每页 `<head>` 里有一小段内联脚本,在首屏绘制前就把 `data-lang` 定好,所以不会出现中英文闪一下。
默认跟随浏览器语言,用户点过语言按钮之后记在 `localStorage` 的 `mh-lang`。
没有 JS 时页面停在英文,内容仍然完整。

**加新文案时**:两种语言都要写,而且要挨着放。可以用这条命令检查有没有漏:

```sh
for f in *.html; do
  printf "%s zh=%s en=%s\n" "$f" \
    "$(grep -o '<span lang="zh">' $f | wc -l)" "$(grep -o '<span lang="en">' $f | wc -l)"
done
```

两个数必须相等。

## 深浅色

`site.css` 里 `:root` 是浅色,`@media (prefers-color-scheme: dark)` 是深色,两套都调过。
品牌色是薄荷绿:深色下用亮的 `#4ee1a0`,浅色下换成对比度够的 `#0a7f55`,
直接把亮薄荷色放在白底上会看不清。

## 还没做的

- **域名**:nginx 现在是 `server_name _`,只能用 IP 访问。绑域名和证书之后再替换 `__SITE_ORIGIN__`。
- **支付**:结账链接还是占位符,购买按钮处于「即将开放」的停用状态。
- **等待名单**:旧首页有个 `/api/waitlist` 表单(后端在 `127.0.0.1:8767`,仍在跑)。
  新首页没有放它 —— 定价页有购买按钮就够了。如果希望在结账通道开放前先收邮箱,
  可以把表单加回定价页,接口是现成的。
