// 中继 WebSocket 客户端 · SPEC §4
// 负责:握手(hello/auth)、心跳、断线重连(退避)、send/recv、presence。
// 只搬运密文,不认识里面的内容。
import { EventEmitter } from 'node:events'
import WebSocket from 'ws'
import { b64u, unb64u, signPayload, verifyPayload } from './crypto.mjs'

export const MAX_FRAME = 1024 * 1024

export class RelayClient extends EventEmitter {
  // opts: {host, port, tls, role, identity:{id, edPriv, edPub, xPub}, name, relayPub?, reconnect?}
  constructor(opts) {
    super()
    this.opts = opts
    this.role = opts.role || 'agent'
    this.id = opts.identity.id
    this.name = opts.name || opts.identity.name || opts.identity.id
    this.relayPub = opts.relayPub || null // 固定住的中继公钥(base64url)
    this.reconnect = opts.reconnect !== false
    this.ws = null
    this.ready = false
    this.closed = false
    this.attempt = 0
    this.presence = new Map()
    this.seq = 0
    // EventEmitter 的规矩:'error' 没人听就直接抛。连不上中继是家常便饭,
    // 不该把整个进程掀翻——错误照样从 connect() 的 Promise 出去。
    this.on('error', () => {})
  }

  get url() {
    const scheme = this.opts.tls ? 'wss' : 'ws'
    const path = this.role === 'mac' ? '/v1/mac' : '/v1/agent'
    return `${scheme}://${this.opts.host}:${this.opts.port}${path}`
  }

  connect() {
    this.closed = false
    return new Promise((resolve, reject) => {
      let settled = false
      const done = (err, v) => {
        if (settled) return
        settled = true
        err ? reject(err) : resolve(v)
      }

      const ws = new WebSocket(this.url, { maxPayload: MAX_FRAME, handshakeTimeout: 15_000 })
      this.ws = ws

      ws.on('open', () => {
        this.emit('open')
      })

      ws.on('message', (data) => {
        let msg
        try {
          msg = JSON.parse(data.toString('utf8'))
        } catch {
          return
        }
        this._onMessage(msg, done)
      })

      ws.on('error', (err) => {
        this.emit('error', err)
        done(err)
      })

      ws.on('close', () => {
        const wasReady = this.ready
        this.ready = false
        this.ws = null
        this.emit('close')
        if (wasReady) for (const id of this.presence.keys()) this.presence.set(id, false)
        done(new Error('连接被关闭'))
        if (this.reconnect && !this.closed) this._scheduleReconnect()
      })
    })
  }

  _scheduleReconnect() {
    this.attempt += 1
    const base = Math.min(500 * 2 ** (this.attempt - 1), 30_000)
    const wait = Math.round(base * (0.7 + Math.random() * 0.6))
    this.emit('reconnecting', { attempt: this.attempt, wait })
    this._timer = setTimeout(() => {
      if (this.closed) return
      this.connect().catch(() => {})
    }, wait)
    this._timer.unref?.()
  }

  _onMessage(msg, done) {
    switch (msg.t) {
      case 'hello': {
        if (this.relayPub && msg.relayId !== this.relayPub) {
          const err = new Error('中继身份和配对码里记的不一样,已断开(可能是中间人,或者中继换了密钥)')
          err.code = 'RELAY_PIN'
          this.close()
          this.emit('error', err)
          return done?.(err)
        }
        if (this.relayPub && msg.sig) {
          const ok = verifyPayload(unb64u(this.relayPub), { nonce: msg.nonce, relayId: msg.relayId, ts: msg.ts }, msg.sig)
          if (!ok) {
            const err = new Error('中继签名验不过,已断开')
            err.code = 'RELAY_PIN'
            this.close()
            this.emit('error', err)
            return done?.(err)
          }
        }
        this.relayId = msg.relayId
        const ts = Date.now()
        const sig = signPayload(this.opts.identity.edPriv, { id: this.id, nonce: msg.nonce, ts })
        this.sendRaw({
          t: 'auth',
          role: this.role,
          id: this.id,
          edPub: b64u(this.opts.identity.edPub),
          xPub: b64u(this.opts.identity.xPub),
          name: this.name,
          sig,
          ts,
        })
        return
      }
      case 'ok':
        this.ready = true
        this.attempt = 0
        this.emit('ready', msg)
        return done?.(null, msg)
      case 'ping':
        return this.sendRaw({ t: 'pong' })
      case 'pong':
        return
      case 'presence':
        this.presence.set(msg.id, Boolean(msg.online))
        return this.emit('presence', msg)
      case 'recv':
        return this.emit('recv', msg)
      case 'pair.request':
        return this.emit('pair.request', msg)
      case 'pair.result':
        return this.emit('pair.result', msg)
      case 'pair.opened':
        return this.emit('pair.opened', msg)
      case 'pair.revoked':
        return this.emit('pair.revoked', msg)
      case 'err': {
        this.emit('relay-error', msg)
        if (!this.ready) {
          const err = new Error(msg.msg || msg.code)
          err.code = msg.code
          if (msg.code === 'BAD_SIG' || msg.code === 'BANNED') this.close()
          return done?.(err)
        }
        return
      }
      default:
        return this.emit('message', msg)
    }
  }

  sendRaw(obj) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) throw new Error('中继连接不在了')
    const text = JSON.stringify(obj)
    if (Buffer.byteLength(text) > MAX_FRAME) throw new Error('单帧超过 1 MiB,请分块')
    this.ws.send(text)
  }

  // 发一帧密文给对端
  sendBody(to, body) {
    this.seq += 1
    this.sendRaw({ t: 'send', to, body, n: this.seq })
  }

  isOnline(id) {
    return this.presence.get(id) === true
  }

  // 等某个 id 上线,超时返回 false
  waitOnline(id, ms = 5000) {
    if (this.isOnline(id)) return Promise.resolve(true)
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.off('presence', on)
        resolve(false)
      }, ms)
      const on = (p) => {
        if (p.id === id && p.online) {
          clearTimeout(timer)
          this.off('presence', on)
          resolve(true)
        }
      }
      this.on('presence', on)
    })
  }

  close() {
    this.closed = true
    this.reconnect = false
    clearTimeout(this._timer)
    try {
      this.ws?.close()
    } catch {}
    this.ws = null
    this.ready = false
  }
}
