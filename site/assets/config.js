/* MacHands 官网 · 唯一需要在发版时改动的文件
 * ---------------------------------------------------------------------------
 * 发新版时只改这里的 version 与 downloads 三个文件名,其余页面都从这里读。
 * 下载页还会再读一次 /appcast.json —— 那份是 release.sh 生成的,以它为准;
 * 这里的值是拿不到 appcast 时的兜底,页面永远不会因此空着。
 *
 * __SITE_ORIGIN__ / __CHECKOUT_URL__ / __REFUND_POLICY__ 是部署时替换的占位符。
 */
window.MH = {
  version: '0.3.0',
  minOS: '13',
  minOSName: 'macOS 13 Ventura',

  // 三个包都放在 /dl/ 下。通用包同时含 Apple 芯片与 Intel。
  downloads: {
    universal: '/dl/MacHands-0.3.0.dmg',
    arm64: '/dl/MacHands-0.3.0-apple-silicon.dmg',
    intel: '/dl/MacHands-0.3.0-intel.dmg'
  },

  // 定价:一次性买断,含一年更新,内置 7 天试用。
  price: { amount: 49, currency: 'USD', display: '$49', trialDays: 7, updateYears: 1 },

  // 支付渠道接好之后替换这一个值,全站购买按钮跟着变。
  checkoutUrl: '__CHECKOUT_URL__',

  // 绑定域名之后替换,用于 og:url 与文档里的绝对地址。
  siteOrigin: '__SITE_ORIGIN__',

  npm: 'machands'
}
