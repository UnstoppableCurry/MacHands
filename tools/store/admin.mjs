#!/usr/bin/env node
// 收单的人工台 · 补发、查单、重发信。
//
//   node tools/store/admin.mjs issue --email a@b.com [--seats 1] [--exp 2027-01-01] [--send]
//   node tools/store/admin.mjs list [--since 2026-09-01] [--json]
//   node tools/store/admin.mjs show --order <订单号> [--license]
//   node tools/store/admin.mjs resend --order <订单号>
//
// 默认**不打印许可证**——终端会留在历史里、会被贴进聊天。要看就显式加 --license。

import { OrderStore } from './orders.mjs'
import { issueLicense, maskEmail } from './issue.mjs'
import { send, licenseEmail, backendReady } from './mailer.mjs'
import { looksLikeEmail } from './providers.mjs'

function parseArgs(argv) {
  const o = { _: [] }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a.startsWith('--')) {
      const k = a.slice(2)
      const v = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : true
      o[k] = v
    } else o._.push(a)
  }
  return o
}

const USAGE = `MacHands 收单人工台

  issue  --email <邮箱> [--seats 1] [--exp 2027-01-01] [--order <号>] [--send]
         手工签一张证。--send 才会发信,不然只落盘。
  list   [--since 2026-09-01] [--json]
         列订单。默认不显示许可证。
  show   --order <订单号> [--license]
         看一单的详情。--license 才打印许可证本身。
  resend --order <订单号>
         把已经签好的证再发一次信。

  环境:STORE_DIR(默认 /opt/machands/store)、LICENSE_KEY_FILE、MAIL_BACKEND 及其配置。`

function findOrder(store, orderId, provider) {
  if (provider) return store.get(provider, orderId)
  return store.list().find((r) => r.order_id === orderId) || null
}

async function cmdIssue(args, store, env) {
  const email = String(args.email || '')
  if (!looksLikeEmail(email)) {
    console.error('要有一个像样的 --email')
    return 2
  }
  const exp = !args.exp || args.exp === 'none' ? null : String(args.exp)
  const seats = Number(args.seats) || 1
  let license
  try {
    license = issueLicense({ email, seats, exp }, env)
  } catch (err) {
    console.error(err.message)
    return 1
  }

  const orderId = String(args.order || `manual-${Date.now()}`)
  const provider = 'manual'
  store.claim(provider, orderId, { provider, order_id: orderId, created_at: new Date().toISOString() })
  store.put({
    provider,
    order_id: orderId,
    email,
    license,
    seats,
    exp,
    state: 'issued',
    created_at: new Date().toISOString(),
    issued_at: new Date().toISOString()
  })
  console.log(`已签发并记在 ${provider}/${orderId}(${maskEmail(email)})`)

  if (args.send) {
    const { subject, text } = licenseEmail({ license, email, siteOrigin: env.SITE_ORIGIN || '__SITE_ORIGIN__', orderId })
    const r = await send({ to: email, subject, text }, env)
    store.patch(provider, orderId, { state: r.ok ? 'sent' : 'issued_mail_failed', mail_backend: r.backend, mail_error: r.ok ? undefined : r.error })
    console.log(r.ok ? `信已发出(${r.backend})` : `信没发出去:${r.error}`)
    return r.ok ? 0 : 1
  }
  console.log('没有加 --send,所以只落了盘。要看证:show --order ' + orderId + ' --license')
  return 0
}

function cmdList(args, store) {
  const rows = store.list({ since: args.since ? String(args.since) : null })
  if (args.json) {
    // JSON 输出里也不带许可证,要证走 show --license
    console.log(JSON.stringify(rows.map(({ license, ...rest }) => rest), null, 2))
    return 0
  }
  if (rows.length === 0) {
    console.log('还没有订单。')
    return 0
  }
  for (const r of rows) {
    const when = (r.created_at || '').slice(0, 19).replace('T', ' ')
    console.log(`${when}  ${String(r.provider).padEnd(13)} ${String(r.order_id).padEnd(24)} ${String(r.state).padEnd(18)} ${maskEmail(r.email)}`)
  }
  console.log(`\n共 ${rows.length} 单。`)
  return 0
}

function cmdShow(args, store) {
  const orderId = String(args.order || '')
  if (!orderId) {
    console.error('要有 --order <订单号>')
    return 2
  }
  const rec = findOrder(store, orderId, args.provider ? String(args.provider) : null)
  if (!rec) {
    console.error(`找不到订单 ${orderId}`)
    return 1
  }
  const { license, ...rest } = rec
  console.log(JSON.stringify({ ...rest, license: license ? '(有,加 --license 才显示)' : null }, null, 2))
  if (args.license && license) {
    console.log('')
    console.log(license)
  }
  return 0
}

async function cmdResend(args, store, env) {
  const orderId = String(args.order || '')
  if (!orderId) {
    console.error('要有 --order <订单号>')
    return 2
  }
  const rec = findOrder(store, orderId, args.provider ? String(args.provider) : null)
  if (!rec) {
    console.error(`找不到订单 ${orderId}`)
    return 1
  }
  if (!rec.license) {
    console.error(`这一单还没签证(state=${rec.state})。先 issue --email ${rec.email || '<邮箱>'} --order ${orderId}`)
    return 1
  }
  if (!looksLikeEmail(rec.email)) {
    console.error('这一单没有可用邮箱,补不了。')
    return 1
  }
  const { subject, text } = licenseEmail({ license: rec.license, email: rec.email, siteOrigin: env.SITE_ORIGIN || '__SITE_ORIGIN__', orderId })
  const r = await send({ to: rec.email, subject, text }, env)
  store.patch(rec.provider, rec.order_id, { state: r.ok ? 'sent' : 'issued_mail_failed', mail_backend: r.backend, mail_error: r.ok ? undefined : r.error })
  console.log(r.ok ? `已重发给 ${maskEmail(rec.email)}(${r.backend})` : `没发出去:${r.error}`)
  return r.ok ? 0 : 1
}

export async function main(argv = process.argv.slice(2), env = process.env) {
  const args = parseArgs(argv)
  const cmd = args._[0]
  if (!cmd || args.help) {
    console.log(USAGE)
    const st = backendReady(env)
    console.log(`\n当前发信后端:${st.backend}${st.ready ? '' : `(缺 ${st.missing.join(', ')})`}`)
    return cmd ? 0 : 1
  }
  const store = new OrderStore(env.STORE_DIR)
  switch (cmd) {
    case 'issue':
      return await cmdIssue(args, store, env)
    case 'list':
      return cmdList(args, store)
    case 'show':
      return cmdShow(args, store)
    case 'resend':
      return await cmdResend(args, store, env)
    default:
      console.error(`不认识的命令:${cmd}`)
      console.log(USAGE)
      return 2
  }
}

const isMain = process.argv[1] && process.argv[1].endsWith('admin.mjs')
if (isMain) {
  main().then((code) => {
    process.exitCode = code
  })
}
