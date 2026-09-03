// 端到端 RPC · SPEC §5
// 在中继的 body 里跑:请求 {id,m,p} / 响应 {id,r} / 错误 {id,e} / 流 {id,s}。
// 计数器单调递增,收到重复或回退的帧直接拒。
import { EventEmitter } from 'node:events'
import { randomUUID } from 'node:crypto'
import { deriveKey, openJSON, sealJSON, DIR_A2M, DIR_M2A } from './crypto.mjs'

export class RpcError extends Error {
  constructor(code, msg) {
    super(msg || code)
    this.code = code
  }
}

export class ReplayError extends Error {
  constructor(counter, last) {
    super(`帧计数器回退或重复(收到 ${counter},已见过 ${last}),这一帧丢弃`)
    this.code = 'REPLAY'
    this.counter = counter
    this.last = last
  }
}

export const DEFAULT_TIMEOUT_MS = 620_000

// 计数器不能每个进程都从 1 重来:同一把会话密钥下 nonce 重复是致命的,
// 而且接收方会把新进程的第 1 帧当成重放。所以计数器取
//   max(上一帧 + 1, 毫秒时间戳 × 1000)
// 这样进程重启、CLI 一次次被调用,计数器都只增不减,且不用落盘。
// 接收方用一个滑动窗口(而不是死盯最大值)判重,允许同一个 agent 同时开几条命令。
export const REPLAY_WINDOW = 4096

export function nextCounter(last) {
  // 毫秒 × 1000 再加一点随机,免得同一毫秒里起的两个进程撞到同一个计数器
  const byClock = BigInt(Date.now()) * 1000n + BigInt(Math.floor(Math.random() * 1000))
  return last + 1n > byClock ? last + 1n : byClock
}

export class RpcSession extends EventEmitter {
  // opts: {key, myId, peerId, role:'agent'|'mac', send(bodyString), handlers?}
  constructor({ key, myId, peerId, role = 'agent', send, handlers = null }) {
    super()
    this.key = key
    this.myId = myId
    this.peerId = peerId
    this.role = role
    this.outDir = role === 'agent' ? DIR_A2M : DIR_M2A
    this.inDir = role === 'agent' ? DIR_M2A : DIR_A2M
    this._send = send
    this.handlers = handlers
    this.outCounter = 0n
    this.lastIn = 0n
    this.seenIn = new Set()
    this.pending = new Map()
  }

  static fromPairing({ identity, pairing, role = 'agent', send, handlers }) {
    const key = deriveKey(identity.xPriv, pairing.xPub, pairing.macId, pairing.agentId)
    return new RpcSession({
      key,
      myId: role === 'agent' ? pairing.agentId : pairing.macId,
      peerId: role === 'agent' ? pairing.macId : pairing.agentId,
      role,
      send,
      handlers,
    })
  }

  _emit(obj) {
    this.outCounter = nextCounter(this.outCounter)
    const body = sealJSON(this.key, this.outDir, this.outCounter, obj, this.myId, this.peerId)
    this._send(body)
  }

  // 收到中继转发的一帧
  onRecv(body) {
    const { dir, counter, msg } = openJSON(this.key, body, this.peerId, this.myId)
    if (dir !== this.inDir) throw new RpcError('BAD_PARAMS', `方向标记不对:${dir}`)
    this._checkCounter(counter)
    this._dispatch(msg)
    return msg
  }

  // 判重:窗口之外(太老)或窗口之内见过的,一律拒
  _checkCounter(counter) {
    const window = BigInt(REPLAY_WINDOW)
    if (counter <= this.lastIn - window) throw new ReplayError(counter, this.lastIn)
    if (this.seenIn.has(counter)) throw new ReplayError(counter, this.lastIn)
    this.seenIn.add(counter)
    if (counter > this.lastIn) this.lastIn = counter
    if (this.seenIn.size > REPLAY_WINDOW) {
      const floor = this.lastIn - window
      for (const c of this.seenIn) if (c <= floor) this.seenIn.delete(c)
    }
  }

  _dispatch(msg) {
    if (msg.m) return this._serve(msg)
    const call = this.pending.get(msg.id)
    if (!call) return this.emit('orphan', msg)
    if (msg.s !== undefined) {
      call.onStream?.(msg.s)
      return
    }
    clearTimeout(call.timer)
    this.pending.delete(msg.id)
    if (msg.e) call.reject(new RpcError(msg.e.code || 'EIO', msg.e.msg))
    else call.resolve(msg.r ?? {})
  }

  async _serve(msg) {
    const handler = this.handlers?.[msg.m]
    if (!handler) {
      this._emit({ id: msg.id, e: { code: 'BAD_PARAMS', msg: '没有这个方法:' + msg.m } })
      return
    }
    const ctx = {
      id: msg.id,
      stream: (s) => this._emit({ id: msg.id, s }),
      peerId: this.peerId,
    }
    try {
      const r = await handler(msg.p || {}, ctx)
      this._emit({ id: msg.id, r: r ?? {} })
    } catch (err) {
      this._emit({ id: msg.id, e: { code: err.code || 'EIO', msg: err.message || String(err) } })
    }
  }

  request(m, p = {}, { onStream, timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
    const id = randomUUID()
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new RpcError('TIMEOUT', `等 ${m} 的回应超时`))
      }, timeoutMs) // 故意不 unref:有请求在飞的时候进程就该活着
      this.pending.set(id, { resolve, reject, onStream, timer })
      try {
        this._emit({ id, m, p })
      } catch (err) {
        clearTimeout(timer)
        this.pending.delete(id)
        reject(err)
      }
    })
  }

  // 连接断了:把在飞的请求都失败掉
  fail(err) {
    for (const [id, call] of this.pending) {
      clearTimeout(call.timer)
      call.reject(err)
      this.pending.delete(id)
    }
  }
}

// 把一个 RelayClient 和一个 RpcSession 接起来
export function attach(client, session, { onReplay } = {}) {
  const onRecv = (msg) => {
    if (msg.from !== session.peerId) return
    try {
      session.onRecv(msg.body)
    } catch (err) {
      if (err instanceof ReplayError) {
        session.emit('replay', err)
        onReplay?.(err)
        return
      }
      session.emit('bad-frame', err)
    }
  }
  client.on('recv', onRecv)
  client.on('close', () => session.fail(new RpcError('OFFLINE', '和中继的连接断了')))
  return () => client.off('recv', onRecv)
}
