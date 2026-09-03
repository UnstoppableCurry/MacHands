#!/usr/bin/env node
// 假 Mac:在 Linux 上冒充 MacHands.app,用来跑端到端测试,也可以手工跑着玩。
//
//   node agent/test/fake-mac.mjs --relay 127.0.0.1:8443 --name "假 Mac" --print-code
//
// 它会打印一段真实可用的配对码,然后另开一个终端:
//   MACHANDS_HOME=/tmp/agent-home node agent/bin/machands.mjs pair "<配对码>"
//   MACHANDS_HOME=/tmp/agent-home node agent/bin/machands.mjs run -- uname -a
//
// 参数:--relay host:port  --name 名字  --home 目录  --token 固定 token
//       --deny 一律拒绝 run  --no-auto 收到配对请求不自动同意
import { spawn } from 'node:child_process'
import { readFileSync, writeFileSync, appendFileSync, mkdirSync, existsSync, statSync, readdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { join, resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { RelayClient } from '../src/relay.mjs'
import { RpcSession, attach } from '../src/rpc.mjs'
import {
  b64u,
  unb64u,
  genEd25519,
  genX25519,
  newId,
  newToken,
  encodePairingCode,
  deriveKey,
} from '../src/crypto.mjs'

export function parse(argv) {
  const o = { relay: '127.0.0.1:8443', name: '假 Mac', home: null, token: null, deny: false, auto: true, print: false }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--relay') o.relay = argv[++i]
    else if (a === '--name') o.name = argv[++i]
    else if (a === '--home') o.home = argv[++i]
    else if (a === '--token') o.token = argv[++i]
    else if (a === '--deny') o.deny = true
    else if (a === '--no-auto') o.auto = false
    else if (a === '--print-code') o.print = true
  }
  return o
}

function loadIdentity(dir) {
  mkdirSync(dir, { recursive: true, mode: 0o700 })
  const file = join(dir, 'mac-identity.json')
  if (existsSync(file)) {
    const j = JSON.parse(readFileSync(file, 'utf8'))
    return {
      id: j.id,
      name: j.name,
      edPriv: unb64u(j.edPriv),
      edPub: unb64u(j.edPub),
      xPriv: unb64u(j.xPriv),
      xPub: unb64u(j.xPub),
    }
  }
  const ed = genEd25519()
  const x = genX25519()
  const id = newId()
  writeFileSync(
    file,
    JSON.stringify(
      { id, edPriv: b64u(ed.priv), edPub: b64u(ed.pub), xPriv: b64u(x.priv), xPub: b64u(x.pub) },
      null,
      2
    ),
    { mode: 0o600 }
  )
  return { id, edPriv: ed.priv, edPub: ed.pub, xPriv: x.priv, xPub: x.pub }
}

const expand = (p) => (p?.startsWith('~') ? join(homedir(), p.slice(1)) : p)

// 一张 1×1 的透明 PNG,截屏用得着
const TINY_PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64'
)

export function makeHandlers(opts = {}) {
  let clipboard = ''
  const log = []
  const handlers = {
    'sys.info': async () => ({
      name: opts.name || '假 Mac',
      model: 'FakeMac1,1',
      os: `${process.platform} ${process.version}`,
      arch: process.arch,
      user: process.env.USER || 'nobody',
      home: homedir(),
      cwd: process.cwd(),
      uptime: Math.round(process.uptime()),
      battery: null,
      xcode: null,
      node: process.version,
      python: null,
    }),
    run: (p, ctx) =>
      new Promise((res, rej) => {
        if (opts.deny) {
          const e = new Error('用户拒绝了')
          e.code = 'DENIED'
          return rej(e)
        }
        const t0 = Date.now()
        const child = spawn('/bin/sh', ['-c', p.cmd], { cwd: expand(p.cwd) || process.cwd(), env: { ...process.env, ...p.env } })
        const killer = setTimeout(() => child.kill('SIGKILL'), (Number(p.timeout) || 600) * 1000)
        killer.unref?.()
        child.stdout.on('data', (d) => ctx.stream({ o: d.toString('utf8') }))
        child.stderr.on('data', (d) => ctx.stream({ e: d.toString('utf8') }))
        child.on('error', rej)
        child.on('close', (code) => {
          clearTimeout(killer)
          res({ code: code ?? 0, ms: Date.now() - t0 })
        })
      }),
    'fs.put': async (p) => {
      const path = expand(p.path)
      mkdirSync(dirname(path), { recursive: true })
      const buf = Buffer.from(p.data || '', 'base64')
      if (p.append) appendFileSync(path, buf)
      else writeFileSync(path, buf, p.mode ? { mode: Number(p.mode) } : undefined)
      return { bytes: buf.length }
    },
    'fs.get': async (p) => {
      const path = expand(p.path)
      if (!existsSync(path)) {
        const e = new Error('没有这个文件:' + p.path)
        e.code = 'ENOENT'
        throw e
      }
      const all = readFileSync(path)
      const offset = Number(p.offset) || 0
      const length = Math.min(Number(p.length) || 768 * 1024, 768 * 1024)
      const slice = all.subarray(offset, offset + length)
      return { data: slice.toString('base64'), size: all.length, eof: offset + slice.length >= all.length }
    },
    'fs.ls': async (p) => {
      const path = expand(p.path)
      if (!existsSync(path)) {
        const e = new Error('没有这个目录:' + p.path)
        e.code = 'ENOENT'
        throw e
      }
      const entries = readdirSync(path).map((name) => {
        const st = statSync(join(path, name))
        return { name, type: st.isDirectory() ? 'dir' : 'file', size: st.size, mtime: Math.round(st.mtimeMs) }
      })
      return { entries }
    },
    'screen.shot': async (p, ctx) => {
      ctx.stream({ data: TINY_PNG.toString('base64') })
      return { width: 1, height: 1, bytes: TINY_PNG.length }
    },
    'screen.list': async () => ({ displays: [{ id: 0, w: 1, h: 1, main: true }] }),
    open: async (p) => {
      log.push({ open: p.target })
      return {}
    },
    'clip.get': async () => ({ text: clipboard }),
    'clip.set': async (p) => {
      clipboard = String(p.text ?? '')
      return {}
    },
    notify: async (p) => {
      process.stderr.write(`[通知] ${p.title}${p.body ? ' · ' + p.body : ''}\n`)
      log.push({ notify: p })
      return {}
    },
    'policy.get': async () => ({ mode: opts.deny ? 'deny' : 'auto', allow: [], deny: ['rm -rf /', 'diskutil erase', 'sudo'] }),
  }
  return { handlers, log, getClipboard: () => clipboard }
}

export async function startFakeMac(input) {
  // 默认自动同意配对(App 的策略就是:token 没过期就自动允许)
  const opts = { auto: input.auto !== false, deny: false, name: '假 Mac', ...input }
  opts.auto = input.auto !== false
  const home = opts.home || join(process.env.TMPDIR || '/tmp', 'machands-fake-mac')
  const identity = loadIdentity(home)
  identity.name = opts.name
  const [host, portStr] = String(opts.relay).split(':')
  const port = Number(portStr || 8443)

  const client = new RelayClient({ host, port, role: 'mac', identity, name: opts.name, reconnect: false })
  await client.connect()

  const { handlers, log, getClipboard } = makeHandlers(opts)
  const sessions = new Map()

  function sessionFor(agentId, agentXPub) {
    if (sessions.has(agentId)) return sessions.get(agentId)
    const key = deriveKey(identity.xPriv, unb64u(agentXPub), identity.id, agentId)
    const s = new RpcSession({
      key,
      myId: identity.id,
      peerId: agentId,
      role: 'mac',
      send: (body) => client.sendBody(agentId, body),
      handlers,
    })
    attach(client, s)
    sessions.set(agentId, s)
    return s
  }

  client.on('pair.request', (m) => {
    sessionFor(m.agentId, m.agentXPub)
    if (opts.auto) client.sendRaw({ t: 'pair.decide', agentId: m.agentId, allow: true })
    else if (opts.deny) client.sendRaw({ t: 'pair.decide', agentId: m.agentId, allow: false })
  })

  // 开一个新配对码(等于 App 上点一次“复制给 agent”)
  async function newCode(tok) {
    const token = tok || newToken()
    const opened = new Promise((res) => client.once('pair.opened', res))
    client.sendRaw({ t: 'pair.open', token, ttl: 600 })
    await opened
    return {
      token,
      code: encodePairingCode({
        host,
        port,
        relayPub: client.relayId,
        macId: identity.id,
        macXPub: b64u(identity.xPub),
        macEdPub: b64u(identity.edPub),
        token,
        macName: opts.name,
      }),
    }
  }

  const { token, code } = await newCode(opts.token)

  return {
    client,
    identity,
    token,
    code,
    log,
    sessions,
    getClipboard,
    newCode,
    decide: (agentId, allow) => client.sendRaw({ t: 'pair.decide', agentId, allow }),
    close: () => client.close(),
  }
}

const isMain = process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))
if (isMain) {
  const opts = parse(process.argv.slice(2))
  const mac = await startFakeMac(opts)
  console.log(`假 Mac 已上线:${opts.name}  id ${mac.identity.id}  中继 ${opts.relay}`)
  console.log('')
  console.log('把下面这一行在你的机器上执行,然后告诉我结果:')
  console.log('')
  console.log(`npx -y machands@latest pair "${mac.code}"`)
  console.log('')
  console.log('(这是 MacHands 配对码,10 分钟内有效,只能用一次。)')
  if (opts.print) console.log('PAIRING_CODE ' + mac.code)
  process.on('SIGINT', () => {
    mac.close()
    process.exit(0)
  })
}
