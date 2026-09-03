#!/usr/bin/env node
// MacHands Relay · SPEC §4
// 只转发密文,不看内容。状态只有两个 JSON 文件:ids.json、pairs.json。
import { createServer } from 'node:http'
import { createServer as createTLSServer } from 'node:https'
import { readFileSync, writeFileSync, renameSync, mkdirSync, existsSync, chmodSync } from 'node:fs'
import { resolve, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { WebSocketServer } from 'ws'
import {
  b64u,
  unb64u,
  genEd25519,
  importPriv,
  rawPub,
  signPayload,
  verifyPayload,
  randomBytes,
} from '../agent/src/crypto.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
export const VER = 1
export const MAX_FRAME = 1024 * 1024 // 1 MiB
export const PING_MS = 25_000
export const DEAD_MS = 60_000
export const PAIR_TTL_MAX = 600
export const PAIR_DECIDE_MS = 120_000
export const RATE_BYTES_PER_SEC = 10 * 1024 * 1024

// ---------- 配置 ----------

export function loadConfig(pathOrObject) {
  const base = { host: '0.0.0.0', port: 8443, dataDir: resolve(HERE, 'data'), tls: null }
  if (pathOrObject && typeof pathOrObject === 'object') return { ...base, ...pathOrObject }
  const p = pathOrObject || process.env.MACHANDS_RELAY_CONFIG || resolve(HERE, 'config.json')
  if (existsSync(p)) {
    const cfg = JSON.parse(readFileSync(p, 'utf8'))
    if (cfg.dataDir) cfg.dataDir = resolve(dirname(p), cfg.dataDir)
    return { ...base, ...cfg }
  }
  return base
}

// ---------- 小工具 ----------

function writeJSONAtomic(file, value, mode) {
  const tmp = file + '.tmp'
  writeFileSync(tmp, JSON.stringify(value, null, 2) + '\n', { mode: mode ?? 0o644 })
  renameSync(tmp, file)
}

function readJSONOr(file, fallback) {
  try {
    return JSON.parse(readFileSync(file, 'utf8'))
  } catch {
    return fallback
  }
}

const now = () => Date.now()

// ---------- 中继身份 ----------

export function loadOrCreateRelayKey(dataDir) {
  mkdirSync(dataDir, { recursive: true })
  const file = join(dataDir, 'relay.key')
  if (existsSync(file)) {
    const j = JSON.parse(readFileSync(file, 'utf8'))
    const priv = unb64u(j.ed25519_priv)
    return { priv, pub: unb64u(j.ed25519_pub), file }
  }
  const kp = genEd25519()
  writeJSONAtomic(file, { ed25519_priv: b64u(kp.priv), ed25519_pub: b64u(kp.pub), created: new Date().toISOString() }, 0o600)
  chmodSync(file, 0o600)
  return { priv: kp.priv, pub: kp.pub, file }
}

// ---------- 服务器 ----------

export function createRelay(config = {}) {
  const cfg = { ...loadConfig(config.configPath), ...config }
  mkdirSync(cfg.dataDir, { recursive: true })

  const key = loadOrCreateRelayKey(cfg.dataDir)
  const relayId = b64u(key.pub)

  const idsFile = join(cfg.dataDir, 'ids.json')
  const pairsFile = join(cfg.dataDir, 'pairs.json')
  const ids = readJSONOr(idsFile, {}) // id -> {role, edPub, name, lastSeen}
  const pairs = readJSONOr(pairsFile, {}) // macId -> [agentId]

  let idsDirty = false
  let pairsDirty = false
  const flush = () => {
    if (idsDirty) {
      writeJSONAtomic(idsFile, ids)
      idsDirty = false
    }
    if (pairsDirty) {
      writeJSONAtomic(pairsFile, pairs)
      pairsDirty = false
    }
  }
  const flushTimer = setInterval(flush, 2000)
  flushTimer.unref?.()

  const live = new Map() // id -> conn
  const tokens = new Map() // token -> {macId, exp}
  const usedTokens = new Map() // token -> exp(用于区分 USED / EXPIRED)
  const pending = new Map() // agentId -> {macId, timer}

  const log = cfg.quiet ? () => {} : (...a) => console.log(new Date().toISOString(), ...a)

  function isPaired(a, b) {
    for (const [macId, list] of Object.entries(pairs)) {
      if (macId === a && list.includes(b)) return true
      if (macId === b && list.includes(a)) return true
    }
    return false
  }

  function peersOf(id) {
    const out = new Set()
    for (const [macId, list] of Object.entries(pairs)) {
      if (macId === id) list.forEach((x) => out.add(x))
      else if (list.includes(id)) out.add(macId)
    }
    return [...out]
  }

  function addPair(macId, agentId) {
    const list = pairs[macId] || (pairs[macId] = [])
    if (!list.includes(agentId)) list.push(agentId)
    pairsDirty = true
    flush()
  }

  function removePair(macId, agentId) {
    if (!pairs[macId]) return
    pairs[macId] = pairs[macId].filter((x) => x !== agentId)
    if (pairs[macId].length === 0) delete pairs[macId]
    pairsDirty = true
    flush()
  }

  const httpServer = cfg.tls
    ? createTLSServer({ cert: readFileSync(cfg.tls.cert), key: readFileSync(cfg.tls.key) }, onRequest)
    : createServer(onRequest)

  function onRequest(req, res) {
    const url = (req.url || '/').split('?')[0]
    if (req.method === 'GET' && url === '/health') {
      const macs = [...live.values()].filter((c) => c.role === 'mac').length
      const agents = [...live.values()].filter((c) => c.role === 'agent').length
      res.writeHead(200, { 'content-type': 'application/json; charset=utf-8' })
      res.end(
        JSON.stringify({
          ok: true,
          ver: VER,
          relayId,
          online: { macs, agents },
          knownIds: Object.keys(ids).length,
          pairs: Object.keys(pairs).length,
          uptime: Math.round(process.uptime()),
        })
      )
      return
    }
    if (req.method === 'GET' && url === '/install') {
      res.writeHead(200, { 'content-type': 'text/x-shellscript; charset=utf-8' })
      res.end(INSTALL_SCRIPT)
      return
    }
    if (req.method === 'GET' && url === '/') {
      res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' })
      res.end(`MacHands relay ver ${VER}\nrelayId ${relayId}\n端点:/v1/mac  /v1/agent  /health  /install\n`)
      return
    }
    res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' })
    res.end('没有这个路径\n')
  }

  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_FRAME })

  httpServer.on('upgrade', (req, socket, head) => {
    const path = (req.url || '').split('?')[0]
    const role = path === '/v1/mac' ? 'mac' : path === '/v1/agent' ? 'agent' : null
    if (!role) {
      socket.write('HTTP/1.1 404 Not Found\r\n\r\n')
      socket.destroy()
      return
    }
    wss.handleUpgrade(req, socket, head, (ws) => onSocket(ws, role, req))
  })

  function onSocket(ws, role, req) {
    const ip = (req.headers['x-forwarded-for']?.split(',')[0] || req.socket.remoteAddress || '').replace(/^::ffff:/, '')
    const conn = {
      ws,
      role,
      ip,
      id: null,
      authed: false,
      nonce: b64u(randomBytes(32)),
      lastPong: now(),
      bytes: 0,
      windowStart: now(),
    }

    const send = (obj) => {
      if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(obj))
    }
    conn.send = send

    const helloTs = now()
    send({
      t: 'hello',
      relayId,
      nonce: conn.nonce,
      ts: helloTs,
      ver: VER,
      // 额外字段:中继用自己的 Ed25519 私钥签 {nonce, relayId, ts},客户端 pin 公钥后可验。
      sig: signPayload(key.priv, { nonce: conn.nonce, relayId, ts: helloTs }),
    })

    const ping = setInterval(() => {
      if (now() - conn.lastPong > DEAD_MS) {
        log('掉线(无 pong)', conn.id || ip)
        ws.close()
        return
      }
      send({ t: 'ping' })
    }, PING_MS)
    ping.unref?.()

    ws.on('message', (data, isBinary) => {
      if (isBinary) return send({ t: 'err', code: 'BAD_PARAMS', msg: '只收文本帧' })
      const raw = data.toString('utf8')
      if (raw.length > MAX_FRAME) return send({ t: 'err', code: 'RATE', msg: '单帧超过 1 MiB' })
      // 软限速:10 MB/s
      const t = now()
      if (t - conn.windowStart >= 1000) {
        conn.windowStart = t
        conn.bytes = 0
      }
      conn.bytes += raw.length
      if (conn.bytes > RATE_BYTES_PER_SEC) return send({ t: 'err', code: 'RATE', msg: '超过 10 MB/s' })

      let msg
      try {
        msg = JSON.parse(raw)
      } catch {
        return send({ t: 'err', code: 'BAD_PARAMS', msg: '不是 JSON' })
      }
      handle(conn, msg)
    })

    ws.on('close', () => {
      clearInterval(ping)
      if (conn.id && live.get(conn.id) === conn) {
        live.delete(conn.id)
        broadcastPresence(conn.id, false)
        if (ids[conn.id]) {
          ids[conn.id].lastSeen = now()
          idsDirty = true
        }
      }
    })
    ws.on('error', () => {})
  }

  function broadcastPresence(id, online) {
    for (const peerId of peersOf(id)) {
      const peer = live.get(peerId)
      if (peer?.authed) peer.send({ t: 'presence', id, online })
    }
  }

  function handle(conn, msg) {
    const t = msg?.t
    if (t === 'pong') {
      conn.lastPong = now()
      return
    }
    if (t === 'ping') return conn.send({ t: 'pong' })

    if (t === 'auth') return handleAuth(conn, msg)
    if (!conn.authed) return conn.send({ t: 'err', code: 'BAD_SIG', msg: '还没通过 auth' })

    switch (t) {
      case 'pair.open':
        return handlePairOpen(conn, msg)
      case 'pair.claim':
        return handlePairClaim(conn, msg)
      case 'pair.decide':
        return handlePairDecide(conn, msg)
      case 'pair.revoke':
        return handlePairRevoke(conn, msg)
      case 'send':
        return handleSend(conn, msg)
      default:
        return conn.send({ t: 'err', code: 'BAD_PARAMS', msg: '不认识的消息类型:' + t })
    }
  }

  function handleAuth(conn, msg) {
    const { role, id, edPub, xPub, name, sig } = msg
    if (conn.authed) return conn.send({ t: 'err', code: 'BAD_PARAMS', msg: '重复 auth' })
    if (role !== conn.role || typeof id !== 'string' || !/^[a-z2-7]{26}$/.test(id) || typeof edPub !== 'string') {
      return conn.send({ t: 'err', code: 'BAD_SIG', msg: 'auth 字段不合法' })
    }
    const ts = Number(msg.ts ?? 0)
    const known = ids[id]
    if (known && known.edPub !== edPub) {
      return conn.send({ t: 'err', code: 'BAD_SIG', msg: '这个 id 之前用的是另一把签名密钥' })
    }
    if (known && known.role !== role) {
      return conn.send({ t: 'err', code: 'BAD_SIG', msg: '这个 id 之前是另一种角色' })
    }
    if (!verifyPayload(unb64u(edPub), { id, nonce: conn.nonce, ts }, sig)) {
      return conn.send({ t: 'err', code: 'BAD_SIG', msg: '签名验不过' })
    }
    if (Math.abs(now() - ts) > 300_000) {
      return conn.send({ t: 'err', code: 'BAD_SIG', msg: '时间戳偏差超过 5 分钟,请校时' })
    }

    const old = live.get(id)
    if (old && old !== conn) {
      old.send({ t: 'err', code: 'BUSY', msg: '同一个 id 在别处登录,这条连接被顶下线' })
      try {
        old.ws.close()
      } catch {}
    }

    conn.id = id
    conn.edPub = edPub
    conn.xPub = xPub
    conn.name = typeof name === 'string' ? name.slice(0, 128) : id
    conn.authed = true
    const isNew = !known
    ids[id] = { role, edPub, name: conn.name, lastSeen: now() }
    idsDirty = true
    if (isNew) flush() // 第一次见到的 id 立刻落盘,后面的 lastSeen 交给定时器
    live.set(id, conn)
    conn.send({ t: 'ok', id, ts: now() })
    log('上线', role, id, conn.name, conn.ip)

    // 双向 presence
    for (const peerId of peersOf(id)) {
      const peer = live.get(peerId)
      conn.send({ t: 'presence', id: peerId, online: Boolean(peer?.authed) })
      if (peer?.authed) peer.send({ t: 'presence', id, online: true })
    }
  }

  function handlePairOpen(conn, msg) {
    if (conn.role !== 'mac') return conn.send({ t: 'err', code: 'BAD_PARAMS', msg: '只有 Mac 能开配对码' })
    const token = String(msg.token || '')
    if (token.length < 8) return conn.send({ t: 'err', code: 'BAD_PARAMS', msg: 'token 太短' })
    const ttl = Math.min(Number(msg.ttl) || PAIR_TTL_MAX, PAIR_TTL_MAX)
    tokens.set(token, { macId: conn.id, exp: now() + ttl * 1000 })
    conn.send({ t: 'pair.opened', token, ttl })
  }

  function sweepTokens() {
    const t = now()
    for (const [k, v] of tokens) if (v.exp < t) tokens.delete(k)
    for (const [k, exp] of usedTokens) if (exp < t) usedTokens.delete(k)
  }

  function handlePairClaim(conn, msg) {
    if (conn.role !== 'agent') return conn.send({ t: 'err', code: 'BAD_PARAMS', msg: '只有 agent 能认领配对码' })
    sweepTokens()
    const token = String(msg.token || '')
    const fail = (code) => conn.send({ t: 'pair.result', ok: false, code, macId: msg.macId ?? null })

    const rec = tokens.get(token)
    if (!rec) return fail(usedTokens.has(token) ? 'USED' : 'EXPIRED')
    if (rec.exp < now()) {
      tokens.delete(token)
      return fail('EXPIRED')
    }
    if (msg.macId && msg.macId !== rec.macId) return fail('EXPIRED')

    const mac = live.get(rec.macId)
    if (!mac?.authed) return fail('OFFLINE')

    // 单次有效:认领的一刻就消耗掉
    tokens.delete(token)
    usedTokens.set(token, now() + PAIR_TTL_MAX * 1000)

    const timer = setTimeout(() => {
      if (pending.get(conn.id)?.timer === timer) {
        pending.delete(conn.id)
        conn.send({ t: 'pair.result', ok: false, code: 'DENIED', macId: rec.macId, msg: 'Mac 一直没回应' })
      }
    }, PAIR_DECIDE_MS)
    timer.unref?.()
    pending.set(conn.id, { macId: rec.macId, timer, agentConn: conn })

    mac.send({
      t: 'pair.request',
      agentId: conn.id,
      agentEdPub: conn.edPub,
      agentXPub: conn.xPub,
      agentName: conn.name,
      from: conn.ip,
    })
  }

  function handlePairDecide(conn, msg) {
    if (conn.role !== 'mac') return conn.send({ t: 'err', code: 'BAD_PARAMS', msg: '只有 Mac 能决定配对' })
    const agentId = String(msg.agentId || '')
    const req = pending.get(agentId)
    if (!req || req.macId !== conn.id) return conn.send({ t: 'err', code: 'BAD_PARAMS', msg: '没有等待中的配对请求' })
    clearTimeout(req.timer)
    pending.delete(agentId)
    const agent = req.agentConn
    if (!msg.allow) {
      agent.send({ t: 'pair.result', ok: false, code: 'DENIED', macId: conn.id })
      return
    }
    addPair(conn.id, agentId)
    agent.send({
      t: 'pair.result',
      ok: true,
      macId: conn.id,
      macEdPub: conn.edPub,
      macXPub: conn.xPub,
      macName: conn.name,
    })
    agent.send({ t: 'presence', id: conn.id, online: true })
    conn.send({ t: 'presence', id: agentId, online: true })
    log('配对成功', conn.id, '↔', agentId)
  }

  function handlePairRevoke(conn, msg) {
    if (conn.role !== 'mac') return conn.send({ t: 'err', code: 'BAD_PARAMS', msg: '只有 Mac 能撤销配对' })
    const agentId = String(msg.agentId || '')
    removePair(conn.id, agentId)
    conn.send({ t: 'pair.revoked', agentId })
    const agent = live.get(agentId)
    if (agent?.authed) agent.send({ t: 'presence', id: conn.id, online: false })
    log('撤销配对', conn.id, '↔', agentId)
  }

  function handleSend(conn, msg) {
    const to = String(msg.to || '')
    if (!isPaired(conn.id, to)) return conn.send({ t: 'err', code: 'NOT_PAIRED', to })
    const peer = live.get(to)
    if (!peer?.authed) return conn.send({ t: 'err', code: 'OFFLINE', to })
    peer.send({ t: 'recv', from: conn.id, body: msg.body, n: msg.n })
  }

  return {
    cfg,
    relayId,
    relayPub: key.pub,
    httpServer,
    wss,
    ids,
    pairs,
    live,
    tokens,
    flush,
    listen(port = cfg.port, host = cfg.host) {
      return new Promise((res) => httpServer.listen(port, host, () => res(httpServer.address())))
    },
    address() {
      return httpServer.address()
    },
    async close() {
      clearInterval(flushTimer)
      flush()
      for (const c of live.values()) {
        try {
          c.ws.close()
        } catch {}
      }
      wss.close()
      await new Promise((res) => httpServer.close(res))
    },
  }
}

const INSTALL_SCRIPT = `#!/bin/sh
# MacHands agent 安装脚本(占位版)
# 正式版会在这里下载 Node 运行时和 machands CLI。现在先给出人话步骤:
echo "MacHands · agent 侧安装"
echo
echo "1) 确认有 Node >= 20:  node --version"
echo "2) 直接跑,不用装:      npx -y machands@latest pair \\"<配对码>\\""
echo "3) 想常驻就全局装:      npm i -g machands"
echo
echo "没有 Node?先装 Node 20+(nvm / apt / brew 都行),再回到第 2 步。"
`

// ---------- 直接运行 ----------

const isMain = process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))
if (isMain) {
  const relay = createRelay({ configPath: process.argv[2] })
  await relay.listen()
  const a = relay.address()
  console.log(`MacHands relay 已启动 ${relay.cfg.tls ? 'wss' : 'ws'}://${a.address}:${a.port}`)
  console.log(`relayId ${relay.relayId}`)
  console.log(`数据目录 ${relay.cfg.dataDir}`)
  const bye = async () => {
    await relay.close()
    process.exit(0)
  }
  process.on('SIGINT', bye)
  process.on('SIGTERM', bye)
}
