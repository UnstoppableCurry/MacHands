// 测试用的小工具:起一个临时中继,和一个手写的原始 WebSocket 客户端。
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import WebSocket from 'ws'
import { createRelay } from '../server.mjs'
import { b64u, genEd25519, genX25519, newId, signPayload } from '../../agent/src/crypto.mjs'

export async function startRelay() {
  const dataDir = mkdtempSync(join(tmpdir(), 'machands-relay-test-'))
  const relay = createRelay({ dataDir, host: '127.0.0.1', port: 0, quiet: true })
  await relay.listen(0, '127.0.0.1')
  const { port } = relay.address()
  return {
    relay,
    port,
    dataDir,
    url: (role) => `ws://127.0.0.1:${port}/v1/${role}`,
    async stop() {
      await relay.close()
      rmSync(dataDir, { recursive: true, force: true })
    },
  }
}

export function newIdentity(name = 'test') {
  const ed = genEd25519()
  const x = genX25519()
  return { id: newId(), name, ed, x }
}

// 一个只会说协议、不带任何自动逻辑的客户端,方便测试异常路径
export class RawClient {
  constructor(url) {
    this.ws = new WebSocket(url)
    this.queue = []
    this.waiters = []
    this.closed = false
    this.closeInfo = null
    this.ws.on('message', (d) => {
      const msg = JSON.parse(d.toString('utf8'))
      if (msg.t === 'ping') return this.send({ t: 'pong' })
      const w = this.waiters.shift()
      if (w) w(msg)
      else this.queue.push(msg)
    })
    this.ws.on('close', (code) => {
      this.closed = true
      this.closeInfo = code
      while (this.waiters.length) this.waiters.shift()(null)
    })
    this.ws.on('error', () => {})
  }

  open() {
    return new Promise((res, rej) => {
      if (this.ws.readyState === WebSocket.OPEN) return res()
      this.ws.once('open', res)
      this.ws.once('error', rej)
    })
  }

  next(timeoutMs = 4000) {
    if (this.queue.length) return Promise.resolve(this.queue.shift())
    return new Promise((res, rej) => {
      const timer = setTimeout(() => rej(new Error('等消息超时')), timeoutMs)
      this.waiters.push((m) => {
        clearTimeout(timer)
        res(m)
      })
    })
  }

  async until(type, timeoutMs = 4000) {
    const deadline = Date.now() + timeoutMs
    for (;;) {
      const m = await this.next(Math.max(50, deadline - Date.now()))
      if (!m) throw new Error('连接关了')
      if (m.t === type) return m
    }
  }

  send(obj) {
    this.ws.send(JSON.stringify(obj))
  }

  // 完整握手:hello → auth → ok
  async auth(identity, role, { edPub, ts } = {}) {
    await this.open()
    const hello = await this.until('hello')
    const stamp = ts ?? Date.now()
    this.send({
      t: 'auth',
      role,
      id: identity.id,
      edPub: edPub ?? b64u(identity.ed.pub),
      xPub: b64u(identity.x.pub),
      name: identity.name,
      ts: stamp,
      sig: signPayload(identity.ed.priv, { id: identity.id, nonce: hello.nonce, ts: stamp }),
    })
    return { hello, reply: await this.next() }
  }

  close() {
    try {
      this.ws.close()
    } catch {}
  }
}

export const wait = (ms) => new Promise((r) => setTimeout(r, ms))
