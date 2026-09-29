#!/usr/bin/env node
// MacHands 收单服务 · 付款推送进来,许可证发出去。
//
//   POST /api/store/webhook/:provider   lemonsqueezy | paddle | creem
//   GET  /api/store/health
//
// 只监听 127.0.0.1,外面由 nginx 反代(见 nginx-store.conf)。
//
// 三条不能破的规矩:
//   1. 验签用**原始字节**。JSON.parse 再 stringify 出来的东西签名对不上,也不安全。
//   2. 同一个 order_id 只发一次证。靠 O_EXCL 占坑,不靠"先查再写"(那有竞态)。
//   3. 先落盘再回 200。信可以后发、可以补发,证丢了就找不回来了。

import { createServer } from 'node:http'
import { PROVIDERS, enabledProviders, looksLikeEmail } from './providers.mjs'
import { OrderStore } from './orders.mjs'
import { issueLicense, maskEmail } from './issue.mjs'
import { send, licenseEmail, backendReady } from './mailer.mjs'

const MAX_BODY = 512 * 1024

/** 一行一个 JSON,systemd 收走。绝不写进邮箱全文、许可证、任何密钥。 */
export function log(event, fields = {}) {
  process.stdout.write(JSON.stringify({ ts: new Date().toISOString(), event, ...fields }) + '\n')
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let size = 0
    req.on('data', (c) => {
      size += c.length
      if (size > MAX_BODY) {
        reject(new Error('body_too_large'))
        req.destroy()
        return
      }
      chunks.push(c)
    })
    req.on('end', () => resolve(Buffer.concat(chunks)))
    req.on('error', reject)
  })
}

function json(res, code, obj) {
  const text = JSON.stringify(obj)
  res.writeHead(code, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text) })
  res.end(text)
}

/**
 * 处理一条已验签的事件。
 * 返回给 provider 的 HTTP 状态一律 200(除非我们自己炸了)——
 * 让它别再重推,该人工的进人工队列。
 */
async function handleEvent({ providerId, parsed, store, env, mail }) {
  const { kind, email, order_id: orderId, product_id: productId, event } = parsed

  if (kind === 'ignore') {
    log('event.ignored', { provider: providerId, event })
    return { ok: true, action: 'ignored' }
  }

  if (!orderId) {
    log('event.no_order_id', { provider: providerId, event })
    return { ok: true, action: 'no_order_id' }
  }

  if (kind === 'refund') {
    // 作废只是记一笔:App 没有吊销机制,已经发出去的证仍然能用。
    // 这是有意的边界,写在 docs/STORE.md 里,别在这里假装能收回。
    const patched = store.patch(providerId, orderId, { state: 'refunded', refunded_at: new Date().toISOString(), refund_event: event })
    log('order.refunded', { provider: providerId, order: orderId, known: Boolean(patched), revoked: false })
    return { ok: true, action: 'refunded', revoked: false }
  }

  // ---- kind === 'paid' ----
  const existing = store.get(providerId, orderId)
  if (existing && existing.state && existing.state !== 'claimed') {
    log('order.duplicate', { provider: providerId, order: orderId, state: existing.state })
    return { ok: true, action: 'duplicate' }
  }

  const seed = { provider: providerId, order_id: orderId, product_id: productId || '', event, created_at: new Date().toISOString() }
  if (!store.claim(providerId, orderId, seed)) {
    log('order.duplicate', { provider: providerId, order: orderId, state: 'claimed' })
    return { ok: true, action: 'duplicate' }
  }

  if (!looksLikeEmail(email)) {
    // 拿不到邮箱就不签证:签了也不知道发给谁,而且邮箱是许可证的一部分。
    store.put({ ...seed, state: 'needs_email', email: String(email || ''), note: '推送里没有可用邮箱,需要人工用 admin.mjs issue 补' })
    log('order.needs_email', { provider: providerId, order: orderId })
    return { ok: true, action: 'needs_email' }
  }

  let license
  try {
    license = issueLicense({ email, seats: 1, exp: null }, env)
  } catch (err) {
    store.put({ ...seed, state: 'issue_failed', email, error: String(err.message || err) })
    log('order.issue_failed', { provider: providerId, order: orderId, email: maskEmail(email), error: String(err.message || err) })
    return { ok: false, action: 'issue_failed' }
  }

  const record = { ...seed, state: 'issued', email, license, issued_at: new Date().toISOString() }
  store.put(record)
  log('order.issued', { provider: providerId, order: orderId, email: maskEmail(email) })

  // 信慢慢发,别把 provider 的连接吊在那儿。发失败也不影响证已经在盘上。
  const deliver = async () => {
    const { subject, text } = licenseEmail({
      license,
      email,
      siteOrigin: env.SITE_ORIGIN || '__SITE_ORIGIN__',
      orderId
    })
    const result = await mail({ to: email, subject, text }, env)
    // MAIL_BACKEND=none 不是"发信失败",是"按配置不发,等人工"。两者要分开,
    // 否则老板看着一屏 failed 会以为系统坏了。
    const held = !result.ok && result.error === 'mail_backend_none'
    store.patch(providerId, orderId, {
      state: result.ok ? 'sent' : held ? 'issued_hold' : 'issued_mail_failed',
      mail_backend: result.backend,
      mail_error: result.ok || held ? undefined : result.error,
      sent_at: result.ok ? new Date().toISOString() : undefined
    })
    log(result.ok ? 'mail.sent' : held ? 'mail.held' : 'mail.failed', {
      provider: providerId,
      order: orderId,
      email: maskEmail(email),
      backend: result.backend,
      error: result.ok || held ? undefined : result.error,
      hint: held ? 'MAIL_BACKEND=none,用 admin.mjs resend 补发' : undefined
    })
  }

  return { ok: true, action: 'issued', deliver }
}

export function createStoreServer({ env = process.env, store = new OrderStore(env.STORE_DIR), mail = send } = {}) {
  const server = createServer(async (req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1')
    const path = url.pathname

    if (req.method === 'GET' && path === '/api/store/health') {
      const mailStatus = backendReady(env)
      return json(res, 200, {
        ok: true,
        providers: enabledProviders(env),
        mailer: mailStatus.backend,
        mailer_ready: mailStatus.ready,
        orders: store.count()
      })
    }

    const hook = path.match(/^\/api\/store\/webhook\/([a-z0-9_-]+)\/?$/)
    if (hook && req.method === 'POST') {
      const providerId = hook[1]
      const provider = PROVIDERS[providerId]
      const secret = provider ? env[provider.secretEnv] : undefined
      if (!provider || !secret || secret.length < 8) {
        // 没配 secret 的渠道当作不存在。空 secret 绝不能变成"谁都能发单"。
        log('webhook.unknown_provider', { provider: providerId })
        return json(res, 404, { ok: false, error: 'unknown_provider' })
      }

      let raw
      try {
        raw = await readBody(req)
      } catch (err) {
        log('webhook.body_error', { provider: providerId, error: String(err.message || err) })
        return json(res, 413, { ok: false, error: 'body_too_large' })
      }

      const verdict = provider.verify(raw, req.headers, secret)
      if (!verdict.ok) {
        log('webhook.rejected', { provider: providerId, reason: verdict.reason })
        return json(res, 401, { ok: false, error: verdict.reason })
      }

      let payload
      try {
        payload = JSON.parse(raw.toString('utf8'))
      } catch {
        log('webhook.bad_json', { provider: providerId })
        return json(res, 400, { ok: false, error: 'bad_json' })
      }

      let parsed
      try {
        parsed = provider.parse(payload, req.headers)
      } catch (err) {
        log('webhook.parse_failed', { provider: providerId, error: String(err.message || err) })
        return json(res, 200, { ok: true, action: 'unparsable' })
      }

      let outcome
      try {
        outcome = await handleEvent({ providerId, parsed, store, env, mail })
      } catch (err) {
        log('webhook.handler_error', { provider: providerId, error: String(err.message || err) })
        return json(res, 500, { ok: false, error: 'handler_error' })
      }

      json(res, outcome.ok ? 200 : 500, { ok: outcome.ok, action: outcome.action })
      if (outcome.deliver) {
        outcome.deliver().catch((err) => log('mail.crashed', { provider: providerId, error: String(err.message || err) }))
      }
      return
    }

    json(res, 404, { ok: false, error: 'not_found' })
  })
  return server
}

const isMain = process.argv[1] && process.argv[1].endsWith('server.mjs')
if (isMain) {
  const port = Number(process.env.STORE_PORT || 8790)
  const host = process.env.STORE_HOST || '127.0.0.1'
  const server = createStoreServer()
  server.listen(port, host, () => {
    const mailStatus = backendReady(process.env)
    log('store.listening', {
      host,
      port,
      providers: enabledProviders(process.env),
      mailer: mailStatus.backend,
      mailer_ready: mailStatus.ready
    })
    if (!mailStatus.ready) {
      log('store.mailer_incomplete', { backend: mailStatus.backend, missing: mailStatus.missing })
    }
  })
}
