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
//
// v0.2(SPEC §11)的方法全都有:返回的字段名以 macapp/Sources/MacHands/Executor.swift
// 为准 —— 这里是 Swift 真值的 Linux 影子,不是另一套合同。
import { spawn, execFile } from 'node:child_process'
import {
  readFileSync,
  writeFileSync,
  appendFileSync,
  mkdirSync,
  existsSync,
  statSync,
  readdirSync,
  rmSync,
  mkdtempSync,
} from 'node:fs'
import { homedir, tmpdir, totalmem, freemem, cpus } from 'node:os'
import { join, resolve, dirname, basename } from 'node:path'
import { fileURLToPath } from 'node:url'
import { randomBytes } from 'node:crypto'
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

// 默认冒充"和这个 CLI 同版本"的 App;测试要模拟旧 App 就传 appVersion
const PKG_VERSION = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../package.json'), 'utf8')).version

const cmpV = (a, b) => {
  const na = String(a ?? '').split('.').map((x) => parseInt(x, 10) || 0)
  const nb = String(b ?? '').split('.').map((x) => parseInt(x, 10) || 0)
  for (let i = 0; i < 3; i++) if ((na[i] || 0) !== (nb[i] || 0)) return (na[i] || 0) < (nb[i] || 0) ? -1 : 1
  return 0
}

// 与 Executor.chunkBytes / Executor.maxRead 一致
const STREAM_CHUNK = 96 * 1024
const MAX_READ = 512 * 1024

// 一张 1×1 的透明 PNG,截屏用得着
const TINY_PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64'
)

// 假录屏:QuickTime 的 ftyp 头 + 确定性的填充,每秒 320 字节
function fakeMovie(seconds) {
  const head = Buffer.from('00000014667479707174202000000000', 'hex') // ....ftypqt  ....
  const body = Buffer.alloc(seconds * 320)
  for (let i = 0; i < body.length; i++) body[i] = (i * 31 + 7) & 0xff
  return Buffer.concat([head, body])
}

const rpcError = (code, msg) => {
  const e = new Error(msg)
  e.code = code
  return e
}
const shortId = () => randomBytes(5).toString('hex') // 10 个十六进制字符,与 Swift 的 prefix(10) 同形
const clamp = (v, lo, hi, dflt) => {
  const n = Number(v)
  if (!Number.isFinite(n)) return dflt
  return Math.min(hi, Math.max(lo, n))
}
const num = (v) => (v === undefined || v === null || v === '' ? NaN : Number(v))

function streamBuffer(ctx, buf) {
  for (let off = 0; off < buf.length; off += STREAM_CHUNK) {
    ctx.stream({ data: buf.subarray(off, Math.min(off + STREAM_CHUNK, buf.length)).toString('base64') })
  }
  return buf.length
}

function tarDirectory(path) {
  const out = join(mkdtempSync(join(tmpdir(), 'fake-mac-tar-')), basename(path) + '.tar.gz')
  return new Promise((res, rej) => {
    execFile('tar', ['czf', out, '-C', dirname(path), basename(path)], (err) => (err ? rej(rpcError('EIO', 'tar failed: ' + err.message)) : res(out)))
  })
}

export function makeHandlers(opts = {}) {
  let clipboard = ''
  let appVer = opts.appVersion || PKG_VERSION
  const log = []
  const calls = [] // 每次调用记一条 {m, why},测 --why 有没有透传
  // 三项系统权限;测试可以传 perms:{screen:false,...} 模拟没授权的 Mac
  const perms = { screen: true, accessibility: true, notifications: 'authorized', ...(opts.perms || {}) }
  const inputs = [] // 每次 input.* 调用记一条 {m, ...p}
  const jobs = new Map()
  const sessions = new Map()
  const mcpSessions = new Map()

  // ---- 作业 ----
  const describeJob = (job) => {
    const body = {
      jobId: job.id,
      cmd: job.cmd,
      cwd: job.cwd,
      state: job.state,
      ms: (job.endedAt ?? Date.now()) - job.startedAt,
      startedAt: job.startedAt,
      outBytes: job.out.length,
      errBytes: job.err.length,
    }
    if (job.code !== undefined && job.code !== null) body.code = job.code
    return body
  }
  const jobOr404 = (id) => {
    const job = jobs.get(String(id ?? ''))
    if (!job) throw rpcError('ENOENT', 'no such job: ' + id)
    return job
  }
  // 作业/会话都 detached 起成自己的进程组,杀 -pid 就是杀整棵树(SPEC §11.1 的 Linux 影子)
  const signalTree = (child, sig) => {
    try {
      process.kill(-child.pid, sig)
    } catch {
      try {
        child.kill(sig)
      } catch {}
    }
  }
  const killTree = (child) => {
    signalTree(child, 'SIGTERM')
    const later = setTimeout(() => signalTree(child, 'SIGKILL'), 2000)
    later.unref?.()
  }

  // ---- MCP 桥的假服务器 ----
  const FAKE_SERVERS = [
    { name: 'echo', source: 'fake', command: 'fake-echo-mcp', args: ['--stdio'] },
    { name: 'remote-http', source: 'fake', url: 'http://127.0.0.1:1/mcp' },
  ]
  const ECHO_TOOLS = [
    {
      name: 'echo',
      description: '原样回显 arguments',
      inputSchema: { type: 'object', properties: {}, additionalProperties: true },
    },
  ]
  const mcpOr404 = (id) => {
    const s = mcpSessions.get(String(id ?? ''))
    if (!s) throw rpcError('ENOENT', 'no such MCP session: ' + id)
    return s
  }

  const requirePoint = (p, xKey, yKey, m) => {
    const x = num(p[xKey])
    const y = num(p[yKey])
    if (!Number.isFinite(x) || !Number.isFinite(y)) throw rpcError('BAD_PARAMS', `${m} needs ${xKey},${yKey}`)
    return { x, y }
  }
  const requireAccessibility = () => {
    if (!perms.accessibility) throw rpcError('EIO', '需要在 Mac 上授权辅助功能')
  }
  const requireScreen = () => {
    if (!perms.screen) throw rpcError('EIO', '需要在 Mac 上授权屏幕录制')
  }

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
      // v0.2 增量(SPEC §11)
      mem_gb: Math.round((totalmem() / 1073741824) * 10) / 10,
      disk_free_gb: Math.round((freemem() / 1e9) * 10) / 10,
      cpu: cpus()[0]?.model || 'fake-cpu',
      gpu: 'Fake GPU 1G',
      displays: [{ id: 0, cgId: 1, w: 1, h: 1, main: true }],
      tools: await handlers['sys.which']({}),
      app_version: appVer,
    }),
    'sys.perms': async () => ({
      screen: Boolean(perms.screen),
      accessibility: Boolean(perms.accessibility),
      notifications: String(perms.notifications),
      automation: 'onDemand',
    }),
    'sys.which': async (p) => {
      const names = Array.isArray(p?.names) && p.names.length
        ? p.names.map(String)
        : ['godot', 'blender', 'xcodebuild', 'swift', 'node', 'python3', 'brew', 'cliclick', 'ffmpeg', 'git']
      const out = {}
      for (const n of names) out[n] = n === 'node' ? '/usr/local/bin/node' : null
      return out
    },
    'policy.check': async (p) => {
      const method = p.method || 'run'
      const subject = String(p.subject ?? '')
      if (opts.deny) return { decision: 'deny', method, reason: 'deny', code: 'DENIED' }
      if (subject.startsWith('rm -rf /')) return { decision: 'deny', method, reason: 'blacklist', code: 'POLICY' }
      return { decision: 'allow', method }
    },
    run: (p, ctx) =>
      new Promise((res, rej) => {
        if (opts.deny) return rej(rpcError('DENIED', '用户拒绝了'))
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
    'fs.get': async (p, ctx) => {
      const path = expand(p.path)
      if (!existsSync(path)) throw rpcError('ENOENT', '没有这个文件:' + p.path)
      if (statSync(path).isDirectory()) {
        // 目录:真 tar czf,再按块流回(与 Executor.fileGet 一致)
        const archive = await tarDirectory(path)
        try {
          const bytes = streamBuffer(ctx, readFileSync(archive))
          return { archive: true, name: basename(path), bytes, size: bytes, eof: true }
        } finally {
          rmSync(dirname(archive), { recursive: true, force: true })
        }
      }
      const all = readFileSync(path)
      const offset = Number(p.offset) || 0
      const length = Math.min(Number(p.length) || 768 * 1024, 768 * 1024)
      const slice = all.subarray(offset, offset + length)
      return { data: slice.toString('base64'), size: all.length, eof: offset + slice.length >= all.length }
    },
    'fs.ls': async (p) => {
      const path = expand(p.path)
      if (!existsSync(path)) throw rpcError('ENOENT', '没有这个目录:' + p.path)
      const entries = readdirSync(path).map((name) => {
        const st = statSync(join(path, name))
        return { name, type: st.isDirectory() ? 'dir' : 'file', size: st.size, mtime: Math.round(st.mtimeMs) }
      })
      return { entries }
    },
    'screen.shot': async (p, ctx) => {
      requireScreen()
      ctx.stream({ data: TINY_PNG.toString('base64') })
      return { width: 1, height: 1, bytes: TINY_PNG.length }
    },
    'screen.list': async () => ({ displays: [{ id: 0, cgId: 1, w: 1, h: 1, main: true }] }),
    'screen.window': async (p, ctx) => {
      requireScreen()
      log.push({ window: { app: p.app, title: p.title, scale: p.scale, format: p.format } })
      ctx.stream({ data: TINY_PNG.toString('base64') })
      return { width: 1, height: 1, bytes: TINY_PNG.length }
    },
    'screen.record': async (p, ctx) => {
      requireScreen()
      const seconds = clamp(p.seconds, 1, 120, 5)
      const movie = fakeMovie(seconds)
      const bytes = streamBuffer(ctx, movie)
      log.push({ record: { seconds, display: Number(p.display) || 0, bytes } })
      return { bytes, seconds, format: 'mov' }
    },
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

    // ---- input.* ----
    'input.where': async () => {
      requireAccessibility()
      inputs.push({ m: 'input.where' })
      return { x: 640, y: 360 }
    },
    'input.move': async (p) => {
      requireAccessibility()
      const { x, y } = requirePoint(p, 'x', 'y', 'input.move')
      inputs.push({ m: 'input.move', x, y })
      return {}
    },
    'input.click': async (p) => {
      requireAccessibility()
      const { x, y } = requirePoint(p, 'x', 'y', 'input.click')
      inputs.push({ m: 'input.click', x, y, button: p.button || 'left', count: Number(p.count) || 1 })
      return {}
    },
    'input.drag': async (p) => {
      requireAccessibility()
      const a = requirePoint(p, 'x1', 'y1', 'input.drag')
      const b = requirePoint(p, 'x2', 'y2', 'input.drag')
      inputs.push({ m: 'input.drag', x1: a.x, y1: a.y, x2: b.x, y2: b.y, ms: Number(p.ms) || 300 })
      return {}
    },
    'input.scroll': async (p) => {
      requireAccessibility()
      const { x, y } = requirePoint(p, 'x', 'y', 'input.scroll')
      inputs.push({ m: 'input.scroll', x, y, dx: Number(p.dx) || 0, dy: Number(p.dy) || 0 })
      return {}
    },
    'input.key': async (p) => {
      requireAccessibility()
      if (!p.key) throw rpcError('BAD_PARAMS', 'input.key needs key')
      inputs.push({ m: 'input.key', key: String(p.key), mods: Array.isArray(p.mods) ? p.mods.map(String) : [] })
      return {}
    },
    'input.type': async (p) => {
      requireAccessibility()
      if (typeof p.text !== 'string') throw rpcError('BAD_PARAMS', 'input.type needs text')
      inputs.push({ m: 'input.type', text: p.text })
      return {}
    },

    // ---- job.* ----
    'job.submit': async (p) => {
      if (!p.cmd) throw rpcError('BAD_PARAMS', 'job.submit needs cmd')
      const cwd = expand(p.cwd) || homedir()
      if (!existsSync(cwd) || !statSync(cwd).isDirectory()) throw rpcError('ENOENT', 'no such folder: ' + p.cwd)
      const id = shortId()
      const job = { id, cmd: String(p.cmd), cwd, state: 'running', code: undefined, startedAt: Date.now(), endedAt: null, out: Buffer.alloc(0), err: Buffer.alloc(0) }
      const child = spawn('/bin/sh', ['-c', job.cmd], { cwd, env: { ...process.env, ...(p.env || {}) }, stdio: ['ignore', 'pipe', 'pipe'], detached: true })
      job.child = child
      child.stdout.on('data', (d) => (job.out = Buffer.concat([job.out, d])))
      child.stderr.on('data', (d) => (job.err = Buffer.concat([job.err, d])))
      child.on('error', (err) => {
        job.state = 'exited'
        job.code = 127
        job.endedAt = Date.now()
        job.err = Buffer.concat([job.err, Buffer.from(err.message)])
      })
      child.on('close', (code, signal) => {
        clearTimeout(job.killer)
        if (job.state === 'running') {
          job.state = 'exited'
          job.code = code ?? (signal ? 128 : 0)
        }
        job.endedAt = Date.now()
      })
      const timeout = clamp(p.timeout, 1, 86400, 3600)
      job.killer = setTimeout(() => {
        if (job.state !== 'running') return
        job.state = 'killed'
        job.code = 124
        killTree(child)
      }, timeout * 1000)
      job.killer.unref?.()
      jobs.set(id, job)
      return { jobId: id }
    },
    'job.status': async (p) => describeJob(jobOr404(p.jobId)),
    'job.result': async (p) => {
      const job = jobOr404(p.jobId)
      const deadline = Date.now() + clamp(p.wait, 0, 600, 0) * 1000
      while (job.state === 'running' && Date.now() < deadline) await new Promise((r) => setTimeout(r, 50))
      return describeJob(job)
    },
    'job.tail': async (p) => {
      const job = jobOr404(p.jobId)
      const buf = p.stream === 'err' ? job.err : job.out
      const start = Math.max(0, Math.min(Number(p.offset) || 0, buf.length))
      const slice = buf.subarray(start, start + MAX_READ)
      const next = start + slice.length
      return { data: slice.toString('base64'), offset: next, eof: job.state !== 'running' && next >= buf.length }
    },
    'job.kill': async (p) => {
      const job = jobs.get(String(p.jobId ?? ''))
      if (!job || job.state !== 'running') throw rpcError('ENOENT', 'no running job: ' + p.jobId)
      job.state = 'killed'
      job.code = 137
      clearTimeout(job.killer)
      killTree(job.child)
      return {}
    },
    'job.list': async () => ({ jobs: [...jobs.values()].sort((a, b) => b.startedAt - a.startedAt).map(describeJob) }),

    // ---- session.* ----
    'session.open': async (p) => {
      const id = shortId()
      const cwd = expand(p.cwd) || homedir()
      const args = p.cmd ? ['-c', String(p.cmd)] : []
      const child = spawn('/bin/sh', args, { cwd, env: { ...process.env, ...(p.env || {}) }, stdio: ['pipe', 'pipe', 'pipe'], detached: true })
      const session = { id, child, out: Buffer.alloc(0), alive: true }
      child.stdout.on('data', (d) => (session.out = Buffer.concat([session.out, d])))
      child.stderr.on('data', (d) => (session.out = Buffer.concat([session.out, d])))
      child.on('close', () => (session.alive = false))
      child.on('error', () => (session.alive = false))
      sessions.set(id, session)
      return { sessionId: id }
    },
    'session.write': async (p) => {
      const s = sessions.get(String(p.sessionId ?? ''))
      if (!s || !s.alive) throw rpcError('ENOENT', 'no such session: ' + p.sessionId)
      if (typeof p.data !== 'string') throw rpcError('BAD_PARAMS', 'session.write needs data')
      await new Promise((res, rej) => s.child.stdin.write(p.data, (err) => (err ? rej(rpcError('EIO', err.message)) : res())))
      return {}
    },
    'session.read': async (p) => {
      const s = sessions.get(String(p.sessionId ?? ''))
      if (!s) throw rpcError('ENOENT', 'no such session: ' + p.sessionId)
      const start = Math.max(0, Math.min(Number(p.offset) || 0, s.out.length))
      const slice = s.out.subarray(start, start + MAX_READ)
      const next = start + slice.length
      return { data: slice.toString('utf8'), offset: next, eof: !s.alive && next >= s.out.length, alive: s.alive }
    },
    'session.close': async (p) => {
      const s = sessions.get(String(p.sessionId ?? ''))
      if (!s) throw rpcError('ENOENT', 'no such session: ' + p.sessionId)
      sessions.delete(s.id)
      try {
        s.child.stdin.end()
      } catch {}
      if (s.alive) killTree(s.child)
      return {}
    },

    // ---- mcp.* ----
    'mcp.servers': async () => ({ servers: FAKE_SERVERS.map((s) => ({ ...s })) }),
    'mcp.open': async (p) => {
      let name = p.name || p.command || 'mcp'
      if (p.name && !p.command) {
        const entry = FAKE_SERVERS.find((s) => s.name === p.name)
        if (!entry) throw rpcError('ENOENT', 'no MCP server named ' + p.name)
        if (!entry.command) throw rpcError('BAD_PARAMS', `${p.name} is an http MCP server — not bridged yet`)
        name = entry.name
      } else if (!p.command) {
        throw rpcError('BAD_PARAMS', 'mcp.open needs name or command')
      }
      const id = shortId()
      mcpSessions.set(id, { id, name, tools: ECHO_TOOLS, calls: [] })
      log.push({ mcpOpen: { name, command: p.command, args: p.args, cwd: p.cwd, envKeys: Object.keys(p.env || {}) } })
      return { sessionId: id, name, tools: ECHO_TOOLS }
    },
    'mcp.list': async (p) => ({ tools: mcpOr404(p.sessionId).tools }),
    'mcp.call': async (p) => {
      const s = mcpOr404(p.sessionId)
      if (!p.tool) throw rpcError('BAD_PARAMS', 'mcp.call needs sessionId, tool')
      if (!s.tools.some((tool) => tool.name === p.tool)) throw rpcError('EIO', 'Unknown tool: ' + p.tool)
      s.calls.push({ tool: p.tool, args: p.args ?? {} })
      return { content: [{ type: 'text', text: JSON.stringify(p.args ?? {}) }] }
    },
    'mcp.close': async (p) => {
      mcpOr404(p.sessionId)
      mcpSessions.delete(String(p.sessionId))
      return {}
    },

    // ---- power.* / app.relaunch / verify.run ----
    'power.assert': async (p) => {
      const seconds = clamp(p.seconds, 1, 14400, 3600)
      log.push({ power: { on: true, seconds } })
      return { until: Date.now() + seconds * 1000, seconds }
    },
    'power.release': async () => {
      log.push({ power: { on: false } })
      return {}
    },
    'app.relaunch': async () => {
      log.push({ relaunch: true })
      return {}
    },
    // 自窗口截图:App 自己渲染,不碰屏幕录制权限,所以 perms.screen=false 也照样能用
    'screen.selfshot': async (p, ctx) => {
      const which = ['main', 'approval', 'all'].includes(p?.window) ? p.window : 'main'
      const bytes = streamBuffer(ctx, TINY_PNG)
      const body = { width: 1, height: 1, bytes }
      if (which === 'all') {
        body.windows = [
          { title: 'MacHands', w: 1, h: 1, bytes },
          { title: '审批', w: 1, h: 1, bytes },
        ]
      }
      log.push({ selfshot: which })
      return body
    },
    'app.showWindow': async () => {
      log.push({ showWindow: true })
      return {}
    },
    'app.doctor': async () => ({
      version: appVer,
      path: opts.appPath || '/Applications/MacHands.app',
      translocated: Boolean(opts.translocated),
      duplicates: Array.isArray(opts.duplicates) ? opts.duplicates : [],
      signed_by: opts.signedBy || 'Apple Development: fake (TEAMID)',
      notarized: opts.notarized === undefined ? false : opts.notarized,
      dr: 'identifier "app.machands.MacHands" and anchor apple generic',
      perms: {
        screen: Boolean(perms.screen),
        accessibility: Boolean(perms.accessibility),
        notifications: String(perms.notifications),
      },
      auto_update: opts.autoUpdate !== false,
    }),
    'app.update': async (p) => {
      const latest = opts.latest || appVer
      if (cmpV(latest, appVer) <= 0) return { status: 'up-to-date', current: appVer, latest }
      if (opts.updateFails) return { status: 'failed', current: appVer, latest, reason: String(opts.updateFails) }
      if (p?.check) return { status: 'available', current: appVer, latest }
      log.push({ update: { from: appVer, to: latest } })
      const from = appVer
      // 真 App 在这里换二进制再重启;假 Mac 只是过一会儿改口说自己是新版本
      const timer = setTimeout(() => {
        appVer = latest
      }, 200)
      timer.unref?.()
      return { status: 'updating', current: from, latest }
    },
    'verify.run': async () => {
      const row = (name, ok, detail, fix) => (ok || !fix ? { name, ok, detail } : { name, ok, detail, fix })
      const notifyOK = perms.notifications === 'authorized'
      return {
        rows: [
          row('run', true, 'printf → machands-ok'),
          row('fs', true, '42 bytes round-trip'),
          row('screen', Boolean(perms.screen), perms.screen ? '24×24 png, 1900 bytes' : '未授权', '需要在 Mac 上授权屏幕录制'),
          row('input', Boolean(perms.accessibility), perms.accessibility ? 'move → (640,360)' : '未授权', '需要在 Mac 上授权辅助功能'),
          row('notify', notifyOK, String(perms.notifications), '需要在 Mac 上允许 MacHands 发通知'),
          row('job', true, 'code=0 out=job-ok'),
          row('mcp', true, FAKE_SERVERS.map((s) => s.name).join(', ')),
          row('update', opts.autoUpdate !== false, opts.autoUpdate !== false ? `自动更新已开(${appVer})` : '自动更新关着', '在 MacHands 设置里打开自动更新'),
        ],
      }
    },
  }
  // 包一层:记下每次调用带没带 why(测意图透传);opts.omit 里的方法当作"这个 App 太旧还没有"
  const omit = new Set(Array.isArray(opts.omit) ? opts.omit : [])
  const wrapped = {}
  for (const [name, fn] of Object.entries(handlers)) {
    if (omit.has(name)) continue
    wrapped[name] = (p = {}, ctx) => {
      calls.push({ m: name, why: p?.why })
      return fn(p, ctx)
    }
  }
  return { handlers: wrapped, log, calls, inputs, jobs, sessions, mcpSessions, perms, getClipboard: () => clipboard }
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

  const { handlers, log, calls, inputs, jobs, sessions: shellSessions, mcpSessions, perms, getClipboard } = makeHandlers(opts)
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

  // 关掉时把假 Mac 上还活着的子进程(作业、会话)一起收掉,免得测试进程挂着不退
  function close() {
    const kill = (child) => {
      try {
        process.kill(-child.pid, 'SIGKILL')
      } catch {
        try {
          child.kill('SIGKILL')
        } catch {}
      }
    }
    for (const job of jobs.values()) if (job.state === 'running' && job.child) kill(job.child)
    for (const s of shellSessions.values()) if (s.alive) kill(s.child)
    client.close()
  }

  return {
    client,
    identity,
    token,
    code,
    log,
    calls,
    inputs,
    jobs,
    shellSessions,
    mcpSessions,
    perms,
    sessions,
    getClipboard,
    newCode,
    decide: (agentId, allow) => client.sendRaw({ t: 'pair.decide', agentId, allow }),
    close,
  }
}

// `node --test` 会把 test/ 下每个 .mjs 都当测试文件起一遍;这时绝不能真的去连 127.0.0.1:8443
// (开发机上那就是生产中继),所以在测试运行器的子进程里不当自己是入口。
const underTestRunner = Boolean(process.env.NODE_TEST_CONTEXT)
const isMain = !underTestRunner && process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))
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
