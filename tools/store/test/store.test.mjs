// 收单服务的测试 · 全离线,不连任何外网,不碰真的签发私钥。
// 每个用例自己造一把测试密钥和一个临时订单目录。

import test from 'node:test'
import assert from 'node:assert/strict'
import { createHmac } from 'node:crypto'
import { mkdtempSync, writeFileSync, mkdirSync, readdirSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { createStoreServer } from '../server.mjs'
import { OrderStore } from '../orders.mjs'
import { lemonsqueezy, paddle, creem, enabledProviders, looksLikeEmail } from '../providers.mjs'
import { backendName, backendReady, send, licenseEmail } from '../mailer.mjs'
import { maskEmail } from '../issue.mjs'
import { genEd25519, b64u } from '../../../agent/src/crypto.mjs'

// --------------------------------------------------------------------------
// 脚手架
// --------------------------------------------------------------------------

/** 一次性的测试环境:临时订单目录 + 临时签发密钥(不是线上那把)。 */
function rig(extra = {}) {
  const root = mkdtempSync(join(tmpdir(), 'machands-store-'))
  const keyFile = join(root, 'test-key.json')
  const kp = genEd25519()
  writeFileSync(keyFile, JSON.stringify({ ed25519_priv: b64u(kp.priv), ed25519_pub: b64u(kp.pub) }), { mode: 0o600 })
  mkdirSync(join(root, 'store'), { recursive: true })
  const env = {
    STORE_DIR: join(root, 'store'),
    LICENSE_KEY_FILE: keyFile,
    MAIL_BACKEND: 'none',
    SITE_ORIGIN: 'https://example.test',
    LS_WEBHOOK_SECRET: 'ls_secret_for_tests',
    PADDLE_WEBHOOK_SECRET: 'pdl_secret_for_tests',
    CREEM_WEBHOOK_SECRET: 'creem_secret_for_tests',
    ...extra
  }
  return { root, env, store: new OrderStore(env.STORE_DIR) }
}

/** 起服务,拿一个 post/get 函数,记下所有发信调用。 */
async function serve(env, store) {
  const mails = []
  const mail = async ({ to, subject, text }) => {
    mails.push({ to, subject, text })
    return { ok: true, backend: 'test', id: 'test-1' }
  }
  const server = createStoreServer({ env, store, mail })
  await new Promise((r) => server.listen(0, '127.0.0.1', r))
  const base = `http://127.0.0.1:${server.address().port}`
  return {
    mails,
    base,
    async post(path, rawBody, headers) {
      return await fetch(base + path, { method: 'POST', headers, body: rawBody })
    },
    async get(path) {
      return await fetch(base + path)
    },
    close: () => new Promise((r) => server.close(r))
  }
}

const hex = (secret, data) => createHmac('sha256', secret).update(data).digest('hex')

function lsBody(orderId, email, event = 'order_created', status = 'paid') {
  return JSON.stringify({
    meta: { event_name: event },
    data: { id: orderId, attributes: { user_email: email, status, first_order_item: { product_id: 'prod_1' } } }
  })
}

function paddleBody(orderId, email, event = 'transaction.completed') {
  return JSON.stringify({
    event_type: event,
    data: { id: orderId, status: 'completed', custom_data: { email }, items: [{ price: { product_id: 'pro_1' } }] }
  })
}

function creemBody(orderId, email, event = 'checkout.completed') {
  return JSON.stringify({
    eventType: event,
    object: { id: orderId, status: 'paid', customer: { email }, product: { id: 'prod_c' } }
  })
}

// --------------------------------------------------------------------------
// 验签
// --------------------------------------------------------------------------

test('Lemon Squeezy:签名对了才放行', () => {
  const secret = 's3cret-ls'
  const raw = Buffer.from(lsBody('o1', 'a@b.com'))
  assert.equal(lemonsqueezy.verify(raw, { 'x-signature': hex(secret, raw) }, secret).ok, true)
  assert.equal(lemonsqueezy.verify(raw, { 'x-signature': hex('wrong', raw) }, secret).ok, false)
  assert.equal(lemonsqueezy.verify(raw, {}, secret).reason, 'missing_x_signature')
  // 改一个字节就该挂
  const tampered = Buffer.from(lsBody('o1', 'evil@b.com'))
  assert.equal(lemonsqueezy.verify(tampered, { 'x-signature': hex(secret, raw) }, secret).ok, false)
})

test('Paddle:签的是 ts:body,时间戳太旧要拒', () => {
  const secret = 's3cret-pdl'
  const raw = Buffer.from(paddleBody('t1', 'a@b.com'))
  const ts = Math.floor(Date.now() / 1000)
  const good = hex(secret, Buffer.concat([Buffer.from(`${ts}:`), raw]))
  assert.equal(paddle.verify(raw, { 'paddle-signature': `ts=${ts};h1=${good}` }, secret).ok, true)

  // 少了 h1
  assert.equal(paddle.verify(raw, { 'paddle-signature': `ts=${ts}` }, secret).reason, 'malformed_paddle_signature')

  // 一小时前的推送:签名再对也不收(防重放)
  const oldTs = ts - 3600
  const oldSig = hex(secret, Buffer.concat([Buffer.from(`${oldTs}:`), raw]))
  assert.equal(paddle.verify(raw, { 'paddle-signature': `ts=${oldTs};h1=${oldSig}` }, secret).reason, 'stale_timestamp')

  // 不把 ts 拼进去算的签名(常见的实现错误)也要拒
  assert.equal(paddle.verify(raw, { 'paddle-signature': `ts=${ts};h1=${hex(secret, raw)}` }, secret).ok, false)
})

test('Creem:签名对了才放行', () => {
  const secret = 's3cret-creem'
  const raw = Buffer.from(creemBody('c1', 'a@b.com'))
  assert.equal(creem.verify(raw, { 'creem-signature': hex(secret, raw) }, secret).ok, true)
  assert.equal(creem.verify(raw, { 'creem-signature': 'deadbeef' }, secret).ok, false)
  assert.equal(creem.verify(raw, {}, secret).reason, 'missing_creem_signature')
})

test('三家都能从各自的负载里挖出邮箱、订单号、事件类型', () => {
  const ls = lemonsqueezy.parse(JSON.parse(lsBody('o9', 'buyer@x.com')), { 'x-event-name': 'order_created' })
  assert.deepEqual([ls.kind, ls.email, ls.order_id, ls.product_id], ['paid', 'buyer@x.com', 'o9', 'prod_1'])

  const pd = paddle.parse(JSON.parse(paddleBody('t9', 'buyer@x.com')))
  assert.deepEqual([pd.kind, pd.email, pd.order_id, pd.product_id], ['paid', 'buyer@x.com', 't9', 'pro_1'])

  const cr = creem.parse(JSON.parse(creemBody('c9', 'buyer@x.com')))
  assert.deepEqual([cr.kind, cr.email, cr.order_id, cr.product_id], ['paid', 'buyer@x.com', 'c9', 'prod_c'])
})

test('没付成的 order_created 不算 paid,不认识的事件一律 ignore', () => {
  const pending = lemonsqueezy.parse(JSON.parse(lsBody('o8', 'a@b.com', 'order_created', 'pending')), {
    'x-event-name': 'order_created'
  })
  assert.equal(pending.kind, 'ignore')
  const other = creem.parse(JSON.parse(creemBody('c8', 'a@b.com', 'subscription.trialing')))
  assert.equal(other.kind, 'ignore')
})

test('只有配了 secret 的渠道才算启用', () => {
  assert.deepEqual(enabledProviders({ LS_WEBHOOK_SECRET: 'x'.repeat(10) }), ['lemonsqueezy'])
  assert.deepEqual(enabledProviders({ LS_WEBHOOK_SECRET: 'short' }), [])
  assert.deepEqual(enabledProviders({}), [])
})

// --------------------------------------------------------------------------
// 端到端
// --------------------------------------------------------------------------

test('一单付款:签证、落盘、发信', async (t) => {
  const { env, store } = rig()
  const s = await serve(env, store)
  t.after(() => s.close())

  const raw = lsBody('order-1', 'buyer@example.com')
  const res = await s.post('/api/store/webhook/lemonsqueezy', raw, {
    'content-type': 'application/json',
    'x-event-name': 'order_created',
    'x-signature': hex(env.LS_WEBHOOK_SECRET, Buffer.from(raw))
  })
  assert.equal(res.status, 200)
  assert.equal((await res.json()).action, 'issued')

  const rec = store.get('lemonsqueezy', 'order-1')
  assert.equal(rec.email, 'buyer@example.com')
  assert.match(rec.license, /^MHL1\./)

  // 发信是回了 200 之后异步做的,等它一下
  await new Promise((r) => setTimeout(r, 60))
  assert.equal(s.mails.length, 1)
  assert.equal(s.mails[0].to, 'buyer@example.com')
  assert.ok(s.mails[0].text.includes(rec.license), '邮件正文里得真的有那一行证')
  assert.equal(store.get('lemonsqueezy', 'order-1').state, 'sent')
})

test('同一个订单号推两次,只签一张证', async (t) => {
  const { env, store } = rig()
  const s = await serve(env, store)
  t.after(() => s.close())

  const raw = lsBody('dup-1', 'buyer@example.com')
  const headers = {
    'content-type': 'application/json',
    'x-event-name': 'order_created',
    'x-signature': hex(env.LS_WEBHOOK_SECRET, Buffer.from(raw))
  }
  const first = await (await s.post('/api/store/webhook/lemonsqueezy', raw, headers)).json()
  const second = await (await s.post('/api/store/webhook/lemonsqueezy', raw, headers)).json()

  assert.equal(first.action, 'issued')
  assert.equal(second.action, 'duplicate')
  assert.equal(store.count(), 1)

  await new Promise((r) => setTimeout(r, 60))
  assert.equal(s.mails.length, 1, '重复推送不该让买家收到第二封信')
})

test('签名不对的推送:401,一个字节都不落盘', async (t) => {
  const { env, store } = rig()
  const s = await serve(env, store)
  t.after(() => s.close())

  const raw = lsBody('evil-1', 'attacker@example.com')
  const res = await s.post('/api/store/webhook/lemonsqueezy', raw, {
    'content-type': 'application/json',
    'x-event-name': 'order_created',
    'x-signature': hex('not-the-secret', Buffer.from(raw))
  })
  assert.equal(res.status, 401)
  assert.equal(store.count(), 0)
})

test('没配 secret 的渠道 = 不存在(404),不是"谁都能发单"', async (t) => {
  const { env, store } = rig({ CREEM_WEBHOOK_SECRET: '' })
  const s = await serve(env, store)
  t.after(() => s.close())

  const raw = creemBody('c-1', 'a@b.com')
  const res = await s.post('/api/store/webhook/creem', raw, {
    'content-type': 'application/json',
    'creem-signature': hex('', Buffer.from(raw))
  })
  assert.equal(res.status, 404)
  assert.equal(store.count(), 0)
})

test('退款:记一笔作废,但不吊销已经发出去的证', async (t) => {
  const { env, store } = rig()
  const s = await serve(env, store)
  t.after(() => s.close())

  const paid = lsBody('ref-1', 'buyer@example.com')
  await s.post('/api/store/webhook/lemonsqueezy', paid, {
    'content-type': 'application/json',
    'x-event-name': 'order_created',
    'x-signature': hex(env.LS_WEBHOOK_SECRET, Buffer.from(paid))
  })
  const licenseBefore = store.get('lemonsqueezy', 'ref-1').license

  const refund = lsBody('ref-1', 'buyer@example.com', 'order_refunded', 'refunded')
  const res = await s.post('/api/store/webhook/lemonsqueezy', refund, {
    'content-type': 'application/json',
    'x-event-name': 'order_refunded',
    'x-signature': hex(env.LS_WEBHOOK_SECRET, Buffer.from(refund))
  })
  const body = await res.json()
  assert.equal(body.action, 'refunded')
  assert.equal(body.revoked, undefined)

  const rec = store.get('lemonsqueezy', 'ref-1')
  assert.equal(rec.state, 'refunded')
  assert.equal(rec.license, licenseBefore, 'App 没有吊销机制,证还在记录里,这是有意的边界')
})

test('推送里没有邮箱:不签证,标成待人工', async (t) => {
  const { env, store } = rig()
  const s = await serve(env, store)
  t.after(() => s.close())

  const raw = JSON.stringify({ event_type: 'transaction.completed', data: { id: 'no-mail-1', items: [] } })
  const ts = Math.floor(Date.now() / 1000)
  const res = await s.post('/api/store/webhook/paddle', raw, {
    'content-type': 'application/json',
    'paddle-signature': `ts=${ts};h1=${hex(env.PADDLE_WEBHOOK_SECRET, Buffer.concat([Buffer.from(`${ts}:`), Buffer.from(raw)]))}`
  })
  assert.equal((await res.json()).action, 'needs_email')
  const rec = store.get('paddle', 'no-mail-1')
  assert.equal(rec.state, 'needs_email')
  assert.equal(rec.license, undefined, '没邮箱就不该签出证来')
})

test('Paddle 一路走通', async (t) => {
  const { env, store } = rig()
  const s = await serve(env, store)
  t.after(() => s.close())

  const raw = paddleBody('txn-1', 'p@example.com')
  const ts = Math.floor(Date.now() / 1000)
  const res = await s.post('/api/store/webhook/paddle', raw, {
    'content-type': 'application/json',
    'paddle-signature': `ts=${ts};h1=${hex(env.PADDLE_WEBHOOK_SECRET, Buffer.concat([Buffer.from(`${ts}:`), Buffer.from(raw)]))}`
  })
  assert.equal((await res.json()).action, 'issued')
  assert.match(store.get('paddle', 'txn-1').license, /^MHL1\./)
})

test('Creem 一路走通', async (t) => {
  const { env, store } = rig()
  const s = await serve(env, store)
  t.after(() => s.close())

  const raw = creemBody('ord-1', 'c@example.com')
  const res = await s.post('/api/store/webhook/creem', raw, {
    'content-type': 'application/json',
    'creem-signature': hex(env.CREEM_WEBHOOK_SECRET, Buffer.from(raw))
  })
  assert.equal((await res.json()).action, 'issued')
  assert.match(store.get('creem', 'ord-1').license, /^MHL1\./)
})

test('health:说清楚谁开着、信怎么发、多少单,不吐密钥', async (t) => {
  const { env, store } = rig()
  const s = await serve(env, store)
  t.after(() => s.close())

  const body = await (await s.get('/api/store/health')).json()
  assert.equal(body.ok, true)
  assert.deepEqual(body.providers.sort(), ['creem', 'lemonsqueezy', 'paddle'])
  assert.equal(body.mailer, 'none')
  assert.equal(body.orders, 0)
  const text = JSON.stringify(body)
  for (const secret of [env.LS_WEBHOOK_SECRET, env.PADDLE_WEBHOOK_SECRET, env.CREEM_WEBHOOK_SECRET]) {
    assert.equal(text.includes(secret), false, 'health 不能把 secret 漏出去')
  }
})

// --------------------------------------------------------------------------
// 发信与杂项
// --------------------------------------------------------------------------

test('MAIL_BACKEND=none 时订单标成待人工,不是"发信失败"', async (t) => {
  const { env, store } = rig()
  // 用真的 send(none 后端),不用测试替身
  const server = createStoreServer({ env, store })
  await new Promise((r) => server.listen(0, '127.0.0.1', r))
  t.after(() => new Promise((r) => server.close(r)))
  const base = `http://127.0.0.1:${server.address().port}`

  const raw = lsBody('hold-1', 'buyer@example.com')
  await fetch(base + '/api/store/webhook/lemonsqueezy', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-event-name': 'order_created',
      'x-signature': hex(env.LS_WEBHOOK_SECRET, Buffer.from(raw))
    },
    body: raw
  })
  await new Promise((r) => setTimeout(r, 80))
  const rec = store.get('lemonsqueezy', 'hold-1')
  assert.equal(rec.state, 'issued_hold')
  assert.equal(rec.mail_error, undefined, '没配发信不算错误,不该留 error')
  assert.match(rec.license, /^MHL1\./, '证还是要签出来的')
})

test('mailer 的 none 后端:如实说没发,不假装成功', async () => {
  assert.equal(backendName({ MAIL_BACKEND: 'none' }), 'none')
  assert.equal(backendName({}), 'none')
  assert.equal(backendName({ MAIL_BACKEND: '瞎写' }), 'none')
  const r = await send({ to: 'a@b.com', subject: 's', text: 't' }, { MAIL_BACKEND: 'none' })
  assert.deepEqual([r.ok, r.backend, r.error], [false, 'none', 'mail_backend_none'])
})

test('配不全的后端要点名缺什么,而不是默默降级', async () => {
  const st = backendReady({ MAIL_BACKEND: 'resend' })
  assert.equal(st.ready, false)
  assert.deepEqual(st.missing, ['RESEND_API_KEY', 'MAIL_FROM'])
  const r = await send({ to: 'a@b.com', subject: 's', text: 't' }, { MAIL_BACKEND: 'resend' })
  assert.equal(r.ok, false)
  assert.match(r.error, /RESEND_API_KEY/)
})

test('邮件正文中英双语,带证、带下载地址', () => {
  const { subject, text } = licenseEmail({ license: 'MHL1.aaa.bbb', email: 'a@b.com', siteOrigin: 'https://x.test', orderId: 'o1' })
  assert.match(subject, /许可证/)
  assert.match(subject, /license/)
  assert.ok(text.includes('MHL1.aaa.bbb'))
  assert.ok(text.includes('https://x.test'))
  assert.ok(text.includes('菜单栏'))
  assert.ok(text.includes('menu bar'))
})

test('日志里的邮箱要打码', () => {
  assert.equal(maskEmail('buyer@example.com'), 'b***@example.com')
  assert.equal(maskEmail(''), '')
  assert.equal(maskEmail('没有at号'), '***')
})

test('订单文件名里的怪字符不会把我们写到别的目录去', () => {
  const { env } = rig()
  const store = new OrderStore(env.STORE_DIR)
  store.claim('lemonsqueezy', '../../etc/passwd', { provider: 'lemonsqueezy', order_id: '../../etc/passwd' })
  const names = readdirSync(join(env.STORE_DIR, 'orders'))
  assert.equal(names.length, 1)
  assert.equal(names[0].includes('..'), false)
  assert.equal(names[0].includes('/'), false)
})

test('落盘的订单文件是完整 JSON(原子写)', () => {
  const { env } = rig()
  const store = new OrderStore(env.STORE_DIR)
  store.claim('creem', 'x1', { provider: 'creem', order_id: 'x1' })
  store.put({ provider: 'creem', order_id: 'x1', state: 'issued', email: 'a@b.com', created_at: new Date().toISOString() })
  const file = join(env.STORE_DIR, 'orders', 'creem-x1.json')
  assert.equal(JSON.parse(readFileSync(file, 'utf8')).state, 'issued')
})

test('邮箱格式:太长的、缺 @ 的都不算', () => {
  assert.equal(looksLikeEmail('a@b.com'), true)
  assert.equal(looksLikeEmail('a@b'), false)
  assert.equal(looksLikeEmail('x'.repeat(250) + '@b.com'), false)
  assert.equal(looksLikeEmail(''), false)
})
