// 收款渠道适配器 · 三家,一个接口。
//
// 每家做两件事:
//   verify(rawBody, headers, secret) -> {ok, reason?}   验签,必须对**原始字节**做,不能对
//                                                        JSON.parse 再 stringify 的结果做
//   parse(json, headers)             -> {kind, email, order_id, product_id, ...}
//
// kind 只有三种:'paid'(收到钱,该发证)、'refund'(退款/撤单)、'ignore'(其它事件)。
// 不认识的事件一律 'ignore',宁可漏发人工补,也不要乱发。
//
// 关于文档:签名算法按各家 2025-2026 年公开的 webhook 文档写。三家都是
// "HMAC-SHA256 + 十六进制",差别在于头的名字、是否把时间戳拼进签名体。
// 我没有账号,**没有用真实推送验证过**,只用自造密钥算出签名再验(见 test/)。
// 上线前必须用各家后台的"测试推送"走一遍(docs/STORE.md 里写了怎么做)。

import { createHmac, timingSafeEqual } from 'node:crypto'

/** 定长比较,别用 === 比签名(会被计时侧信道量出来)。 */
function safeEqualHex(a, b) {
  const A = Buffer.from(String(a).trim().toLowerCase(), 'utf8')
  const B = Buffer.from(String(b).trim().toLowerCase(), 'utf8')
  if (A.length !== B.length || A.length === 0) return false
  return timingSafeEqual(A, B)
}

function hmacHex(secret, data) {
  return createHmac('sha256', secret).update(data).digest('hex')
}

/** 从嵌套对象里按 'a.b.c' 取值,取不到给 undefined。 */
function pick(obj, path) {
  return path.split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj)
}

/** 一串候选路径里取第一个非空字符串。 */
function firstString(obj, paths) {
  for (const p of paths) {
    const v = pick(obj, p)
    if (typeof v === 'string' && v.trim()) return v.trim()
    if (typeof v === 'number') return String(v)
  }
  return ''
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

export function looksLikeEmail(s) {
  return typeof s === 'string' && s.length <= 254 && EMAIL_RE.test(s)
}

// --------------------------------------------------------------------------
// Lemon Squeezy
// 文档:Webhooks → "Signing requests"。头 X-Signature 是 hex(HMAC-SHA256(rawBody, secret)),
// 事件名在头 X-Event-Name 里。订单对象是 JSON:API 形状(data.attributes.…)。
// --------------------------------------------------------------------------
export const lemonsqueezy = {
  id: 'lemonsqueezy',
  secretEnv: 'LS_WEBHOOK_SECRET',

  verify(rawBody, headers, secret) {
    const got = headers['x-signature']
    if (!got) return { ok: false, reason: 'missing_x_signature' }
    if (!safeEqualHex(hmacHex(secret, rawBody), got)) return { ok: false, reason: 'bad_signature' }
    return { ok: true }
  },

  parse(json, headers) {
    const event = String(headers['x-event-name'] || pick(json, 'meta.event_name') || '')
    const attrs = pick(json, 'data.attributes') || {}
    const email = firstString(json, [
      'meta.custom_data.email',
      'data.attributes.user_email',
      'data.attributes.customer_email'
    ])
    const orderId = firstString(json, ['data.id', 'data.attributes.identifier', 'data.attributes.order_number'])
    const productId = firstString(json, [
      'data.attributes.first_order_item.product_id',
      'data.attributes.product_id',
      'meta.custom_data.product_id'
    ])
    const status = String(attrs.status || '')

    let kind = 'ignore'
    // order_created 也可能是 pending / failed,只有 paid 才算收到钱。
    if (event === 'order_created' && status === 'paid') kind = 'paid'
    else if (event === 'order_refunded' || status === 'refunded') kind = 'refund'

    return { kind, event, email, order_id: orderId, product_id: productId, status }
  }
}

// --------------------------------------------------------------------------
// Paddle(Billing,也就是 v2/新版)
// 文档:"Verify webhook signatures"。头 Paddle-Signature 形如 `ts=1671552777;h1=<hex>`,
// 被签的是 `${ts}:${rawBody}`,密钥是通知目标的 secret(pdl_ntfset_…)。
//
// 没法验证的一点:transaction.completed 的负载里**不一定有买家邮箱**。Paddle 常把
// 客户信息放在 data.customer(要在 API 里 include 才有)或只给 data.customer_id。
// 所以这里按多条路径找,找不到就当没有邮箱交给上层去人工处理;
// docs/STORE.md 里让老板在 checkout 时把邮箱塞进 custom_data,这是最稳的做法。
// --------------------------------------------------------------------------
export const paddle = {
  id: 'paddle',
  secretEnv: 'PADDLE_WEBHOOK_SECRET',
  /** 时间戳超出这个秒数就当重放,拒掉。 */
  toleranceSeconds: 5 * 60,

  verify(rawBody, headers, secret, now = Date.now()) {
    const header = headers['paddle-signature']
    if (!header) return { ok: false, reason: 'missing_paddle_signature' }
    const parts = Object.fromEntries(
      String(header)
        .split(';')
        .map((kv) => {
          const i = kv.indexOf('=')
          return i < 0 ? [kv.trim(), ''] : [kv.slice(0, i).trim(), kv.slice(i + 1).trim()]
        })
    )
    const ts = parts.ts
    const h1 = parts.h1
    if (!ts || !h1) return { ok: false, reason: 'malformed_paddle_signature' }
    const skew = Math.abs(now / 1000 - Number(ts))
    if (!Number.isFinite(skew) || skew > paddle.toleranceSeconds) return { ok: false, reason: 'stale_timestamp' }
    const signed = Buffer.concat([Buffer.from(`${ts}:`, 'utf8'), Buffer.isBuffer(rawBody) ? rawBody : Buffer.from(rawBody)])
    if (!safeEqualHex(hmacHex(secret, signed), h1)) return { ok: false, reason: 'bad_signature' }
    return { ok: true }
  },

  parse(json) {
    const event = String(json.event_type || '')
    const email = firstString(json, [
      'data.custom_data.email',
      'data.customer.email',
      'data.billing_details.email',
      'data.payments.0.customer.email'
    ])
    const orderId = firstString(json, ['data.id', 'data.transaction_id', 'event_id'])
    const productId = firstString(json, [
      'data.items.0.price.product_id',
      'data.details.line_items.0.product.id',
      'data.items.0.product.id'
    ])

    let kind = 'ignore'
    if (event === 'transaction.completed' || event === 'transaction.paid') kind = 'paid'
    // 退款在 Paddle 里是一条 adjustment,action=refund;credit 是账面冲抵,也按退处理。
    else if (event === 'adjustment.created' || event === 'adjustment.updated') {
      const action = String(pick(json, 'data.action') || '')
      if (action === 'refund' || action === 'chargeback' || action === 'credit') kind = 'refund'
    }

    return { kind, event, email, order_id: orderId, product_id: productId, status: String(pick(json, 'data.status') || '') }
  }
}

// --------------------------------------------------------------------------
// Creem
// 文档:Webhooks。头 creem-signature 是 hex(HMAC-SHA256(rawBody, secret)),
// 事件名在负载的 eventType 字段。订单对象在 object 里。
// --------------------------------------------------------------------------
export const creem = {
  id: 'creem',
  secretEnv: 'CREEM_WEBHOOK_SECRET',

  verify(rawBody, headers, secret) {
    const got = headers['creem-signature'] || headers['x-creem-signature']
    if (!got) return { ok: false, reason: 'missing_creem_signature' }
    if (!safeEqualHex(hmacHex(secret, rawBody), got)) return { ok: false, reason: 'bad_signature' }
    return { ok: true }
  },

  parse(json) {
    const event = String(json.eventType || json.event_type || json.type || '')
    const email = firstString(json, [
      'object.metadata.email',
      'object.customer.email',
      'object.order.customer.email',
      'object.email'
    ])
    const orderId = firstString(json, ['object.order.id', 'object.id', 'id'])
    const productId = firstString(json, ['object.product.id', 'object.order.product', 'object.product'])

    let kind = 'ignore'
    if (event === 'checkout.completed' || event === 'subscription.paid') kind = 'paid'
    else if (event === 'refund.created' || event === 'dispute.created') kind = 'refund'

    return { kind, event, email, order_id: orderId, product_id: productId, status: String(pick(json, 'object.status') || '') }
  }
}

export const PROVIDERS = { lemonsqueezy, paddle, creem }

/** 配了 secret 的渠道才算启用。没配的直接 404,免得空 secret 变成"谁都能发单"。 */
export function enabledProviders(env = process.env) {
  return Object.values(PROVIDERS)
    .filter((p) => typeof env[p.secretEnv] === 'string' && env[p.secretEnv].length >= 8)
    .map((p) => p.id)
}
