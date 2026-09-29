/* MacHands 官网脚本 · 只做三件事:切语言、填版本与链接、下载页读 appcast。
   没有依赖,没有统计,不发任何请求到第三方。 */
(function () {
  'use strict'

  var MH = window.MH || {}
  var LANG_KEY = 'mh-lang'

  // ── 语言 ──────────────────────────────────────────────────────────────
  // 首屏那次切换由每页 <head> 里的内联脚本完成(避免闪),这里只管按钮和后续切换。
  function currentLang () {
    return document.documentElement.getAttribute('data-lang') === 'zh' ? 'zh' : 'en'
  }

  function applyLang (lang) {
    var html = document.documentElement
    html.setAttribute('data-lang', lang)
    html.lang = lang === 'zh' ? 'zh-CN' : 'en'
    try { localStorage.setItem(LANG_KEY, lang) } catch (e) {}
    // 按钮上写的是"切到另一种语言",不是当前语言
    Array.prototype.forEach.call(document.querySelectorAll('[data-langbtn]'), function (b) {
      b.textContent = lang === 'zh' ? 'English' : '中文'
      b.setAttribute('aria-label', lang === 'zh' ? 'Switch to English' : '切换到中文')
    })
    // 少数放在属性里的文案(占位符等)也要跟着切
    Array.prototype.forEach.call(document.querySelectorAll('[data-ph-zh][data-ph-en]'), function (el) {
      el.setAttribute('placeholder', el.getAttribute(lang === 'zh' ? 'data-ph-zh' : 'data-ph-en'))
    })
  }

  document.addEventListener('click', function (e) {
    var btn = e.target.closest ? e.target.closest('[data-langbtn]') : null
    if (!btn) return
    e.preventDefault()
    applyLang(currentLang() === 'zh' ? 'en' : 'zh')
  })

  // ── 版本号与价格:全站从 config.js 来,发版只改那一个文件 ────────────────
  function fillText () {
    var map = {
      version: MH.version || '',
      minos: MH.minOS || '',
      minosname: MH.minOSName || '',
      price: (MH.price && MH.price.display) || '',
      trial: String((MH.price && MH.price.trialDays) || ''),
      updateyears: String((MH.price && MH.price.updateYears) || ''),
      npm: MH.npm || 'machands'
    }
    Array.prototype.forEach.call(document.querySelectorAll('[data-mh]'), function (el) {
      var key = el.getAttribute('data-mh')
      if (map[key] !== undefined && map[key] !== '') el.textContent = map[key]
    })
  }

  // ── 链接 ──────────────────────────────────────────────────────────────
  var PLACEHOLDER = /^__[A-Z_]+__$/

  function fillLinks () {
    var d = MH.downloads || {}
    Array.prototype.forEach.call(document.querySelectorAll('[data-mh-href]'), function (el) {
      var key = el.getAttribute('data-mh-href')
      var href = key === 'checkout' ? MH.checkoutUrl : d[key]
      if (!href) return

      // 支付渠道还没接好时,按钮不该指向一个死链接:降级成"即将开放"并停用。
      if (key === 'checkout' && PLACEHOLDER.test(href)) {
        el.removeAttribute('href')
        el.setAttribute('aria-disabled', 'true')
        el.style.opacity = '.55'
        el.style.cursor = 'not-allowed'
        el.innerHTML =
          '<span lang="zh">购买通道即将开放</span><span lang="en">Checkout opens soon</span>'
        return
      }
      el.setAttribute('href', href)
    })
  }

  // ── 下载页:以 appcast.json 为准 ───────────────────────────────────────
  // release.sh 每次发版都会重写 appcast.json。页面读它,这样发版不用动 HTML。
  function syncFromAppcast () {
    if (!document.querySelector('[data-appcast]')) return
    fetch('/appcast.json', { cache: 'no-store' })
      .then(function (r) { return r.ok ? r.json() : null })
      .then(function (a) {
        if (!a || !a.version) return
        Array.prototype.forEach.call(document.querySelectorAll('[data-mh="version"]'), function (el) {
          el.textContent = a.version
        })
        if (a.url) {
          var el = document.querySelector('[data-mh-href="universal"]')
          if (el) el.setAttribute('href', a.url)
        }
      })
      .catch(function () { /* 拿不到就用 config.js 里的兜底,页面照常 */ })
  }

  // ── 启动 ──────────────────────────────────────────────────────────────
  function boot () {
    applyLang(currentLang())
    fillText()
    fillLinks()
    syncFromAppcast()
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot)
  } else {
    boot()
  }
})()
