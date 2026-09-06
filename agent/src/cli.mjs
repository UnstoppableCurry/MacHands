// machands CLI · SPEC §6
// 输出全是人话;只有 --json 时才打 JSON。错误一律说下一步该做什么。
import { readFileSync, writeFileSync, mkdirSync, existsSync, chmodSync, statSync, renameSync, unlinkSync } from 'node:fs'
import { homedir, hostname, tmpdir } from 'node:os'
import { join, basename, resolve as pathResolve } from 'node:path'
import { spawn } from 'node:child_process'
import { RelayClient } from './relay.mjs'
import { RpcSession, RpcError, attach } from './rpc.mjs'
import { t } from './i18n.mjs'
import { b64u, unb64u, genEd25519, genX25519, newId, parsePairingCode } from './crypto.mjs'

export const VERSION = '0.2.0'
export const EXIT = { OK: 0, NOT_PAIRED: 66, OFFLINE: 69, LICENSE: 75, DENIED: 77, TIMEOUT: 78, FAIL: 1 }
const CHUNK = 384 * 1024 // 上传分块(base64 后仍远小于 1 MiB)
const GET_CHUNK = 512 * 1024 // ≤ 768 KiB/次

// ---------- 本地状态 ~/.machands ----------

export function homeDir() {
  return process.env.MACHANDS_HOME || join(homedir(), '.machands')
}

function ensureHome() {
  const dir = homeDir()
  mkdirSync(dir, { recursive: true, mode: 0o700 })
  try {
    chmodSync(dir, 0o700)
  } catch {}
  return dir
}

function writeSecret(file, obj) {
  const tmp = file + '.tmp'
  writeFileSync(tmp, JSON.stringify(obj, null, 2) + '\n', { mode: 0o600 })
  renameSync(tmp, file)
  chmodSync(file, 0o600)
}

export function defaultAgentName() {
  return process.env.MACHANDS_NAME || `${process.env.USER || process.env.LOGNAME || 'agent'}@${hostname()}`
}

export function loadIdentity() {
  const file = join(ensureHome(), 'identity.json')
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
  const name = defaultAgentName()
  writeSecret(file, {
    id,
    name,
    edPriv: b64u(ed.priv),
    edPub: b64u(ed.pub),
    xPriv: b64u(x.priv),
    xPub: b64u(x.pub),
    created: new Date().toISOString(),
  })
  return { id, name, edPriv: ed.priv, edPub: ed.pub, xPriv: x.priv, xPub: x.pub }
}

export function pairingsFile() {
  return join(ensureHome(), 'pairings.json')
}

export function loadPairings() {
  try {
    return JSON.parse(readFileSync(pairingsFile(), 'utf8'))
  } catch {
    return { macs: [] }
  }
}

export function savePairings(store) {
  writeSecret(pairingsFile(), store)
}

export function resolveMac(store, wanted) {
  const macs = store.macs || []
  if (macs.length === 0) throw new CliError(t('noPairs'), EXIT.NOT_PAIRED)
  const want = wanted || process.env.MACHANDS_MAC
  if (want) {
    const hit = macs.find((m) => m.macName === want || m.macId === want || m.macName.toLowerCase().includes(want.toLowerCase()))
    if (!hit) throw new CliError(t('noSuchMac', want), EXIT.NOT_PAIRED)
    return hit
  }
  if (macs.length === 1) return macs[0]
  const def = macs.find((m) => m.default)
  if (def) return def
  throw new CliError(t('manyMacs'), EXIT.NOT_PAIRED)
}

export class CliError extends Error {
  constructor(msg, code = EXIT.FAIL) {
    super(msg)
    this.exitCode = code
  }
}

export function exitCodeFor(err) {
  const c = err?.code
  if (c === 'DENIED' || c === 'POLICY') return EXIT.DENIED
  if (c === 'TIMEOUT') return EXIT.TIMEOUT
  if (c === 'OFFLINE') return EXIT.OFFLINE
  if (c === 'NOT_PAIRED') return EXIT.NOT_PAIRED
  if (c === 'LICENSE') return EXIT.LICENSE
  return err?.exitCode ?? EXIT.FAIL
}

export function humanError(err) {
  switch (err?.code) {
    case 'DENIED':
      return t('denied')
    case 'TIMEOUT':
      return t('timeout')
    case 'POLICY':
      return t('policy', err.message)
    case 'LICENSE':
      return t('license')
    case 'OFFLINE':
      return err.message
    default:
      return err?.message || String(err)
  }
}

// ---------- 连接 ----------

export async function connect({ mac, waitMs = 4000 } = {}) {
  const identity = loadIdentity()
  const store = loadPairings()
  const pairing = resolveMac(store, mac)
  const client = new RelayClient({
    host: pairing.relay.host,
    port: pairing.relay.port,
    tls: pairing.relay.tls,
    role: 'agent',
    identity,
    name: identity.name,
    relayPub: pairing.relay.pub,
    reconnect: false,
  })
  try {
    await client.connect()
  } catch (err) {
    throw new CliError(t('errRelay', pairing.relay.host, pairing.relay.port, err.message), EXIT.OFFLINE)
  }
  const session = RpcSession.fromPairing({
    identity,
    pairing: { macId: pairing.macId, agentId: identity.id, xPub: unb64u(pairing.macXPub) },
    role: 'agent',
    send: (body) => client.sendBody(pairing.macId, body),
  })
  attach(client, session)
  client.on('relay-error', (m) => {
    if (m.code === 'OFFLINE') session.fail(new RpcError('OFFLINE', t('offline', pairing.macName)))
    if (m.code === 'NOT_PAIRED') session.fail(new RpcError('NOT_PAIRED', t('noPairs')))
  })
  if (!client.isOnline(pairing.macId)) {
    const online = await client.waitOnline(pairing.macId, waitMs)
    if (!online) {
      client.close()
      throw new CliError(t('offline', pairing.macName), EXIT.OFFLINE)
    }
  }
  return { client, session, pairing, identity }
}

// ---------- 参数 ----------

// 这些开关从不带值,后面紧跟的词是位置参数(machands input click --right 10 20)。
const BOOL_FLAGS = new Set(['json', 'help', 'version', 'default', 'tls', 'right', 'double', 'follow', 'err', 'raw', 'no-extract'])

export function parseArgs(argv) {
  const out = { _: [], flags: {}, rest: [] }
  const a = [...argv]
  while (a.length) {
    const x = a.shift()
    if (x === '--') {
      out.rest = a.splice(0)
      break
    }
    if (x.startsWith('--')) {
      const [k, inline] = x.slice(2).split('=')
      if (inline !== undefined) out.flags[k] = inline
      else if (!BOOL_FLAGS.has(k) && a[0] && !a[0].startsWith('-')) out.flags[k] = a.shift()
      else out.flags[k] = true
    } else if (/^-[a-zA-Z]$/.test(x)) {
      out.flags[x.slice(1)] = a[0] && !a[0].startsWith('-') ? a.shift() : true
    } else {
      out._.push(x)
    }
  }
  return out
}

const say = (s) => process.stdout.write(s + '\n')
const warn = (s) => process.stderr.write(s + '\n')

// ---------- 子命令 ----------

const HINT_BLOCK = [
  'Claude Code:  claude mcp add machands -- npx -y machands mcp',
  'Codex:        在 ~/.codex/config.toml 加 [mcp_servers.machands] command="npx" args=["-y","machands","mcp"]',
  'Cursor:       Settings → MCP → Add: npx -y machands mcp',
  '也可以直接用命令行:machands run -- xcodebuild -version',
].join('\n')

export async function cmdPair(args) {
  const code = args._[0]
  if (!code) throw new CliError(t('needCode'), EXIT.FAIL)
  let p
  try {
    p = parsePairingCode(code)
  } catch (err) {
    throw new CliError(t('badCode', err.message), EXIT.FAIL)
  }
  const identity = loadIdentity()
  if (!args.flags.json) say(t('pairing', p.host, p.port))

  const client = new RelayClient({
    host: p.host,
    port: p.port,
    tls: Boolean(args.flags.tls),
    role: 'agent',
    identity,
    name: identity.name,
    relayPub: p.relayPub,
    reconnect: false,
  })
  try {
    await client.connect()
  } catch (err) {
    throw new CliError(t('errRelay', p.host, p.port, err.message), EXIT.OFFLINE)
  }

  const result = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new CliError('等 Mac 回应超时,过一会儿再试一次。', EXIT.TIMEOUT)), 130_000)
    timer.unref?.()
    client.once('pair.result', (m) => {
      clearTimeout(timer)
      resolve(m)
    })
    client.sendRaw({ t: 'pair.claim', token: p.token, macId: p.macId })
    if (!args.flags.json) say(t('pairWaiting'))
  })
  client.close()

  if (!result.ok) {
    const map = { EXPIRED: t('errExpired'), USED: t('errUsed'), DENIED: t('errDenied'), OFFLINE: t('errOfflineMac') }
    throw new CliError(map[result.code] || `配对失败:${result.code || '未知原因'}`, EXIT.FAIL)
  }

  const store = loadPairings()
  store.macs = (store.macs || []).filter((m) => m.macId !== result.macId)
  const isOnly = store.macs.length === 0
  const entry = {
    macId: result.macId,
    macName: result.macName || p.macName,
    macXPub: result.macXPub || p.macXPub,
    macEdPub: result.macEdPub || p.macEdPub,
    relay: { host: p.host, port: p.port, pub: p.relayPub, tls: Boolean(args.flags.tls) },
    agentId: identity.id,
    pairedAt: new Date().toISOString(),
    default: isOnly || Boolean(args.flags.default),
  }
  if (entry.default) store.macs.forEach((m) => (m.default = false))
  store.macs.push(entry)
  savePairings(store)

  if (args.flags.json) {
    say(JSON.stringify({ ok: true, macId: entry.macId, macName: entry.macName, default: entry.default }))
    return EXIT.OK
  }
  say('')
  say(t('pairOk', entry.macName))
  if (entry.default) say(t('pairDefault', entry.macName))
  say('')
  say(HINT_BLOCK)
  return EXIT.OK
}

export async function cmdMacs(args) {
  const store = loadPairings()
  const macs = store.macs || []
  if (macs.length === 0) {
    if (args.flags.json) say(JSON.stringify({ macs: [] }))
    else say(t('noPairs'))
    return EXIT.NOT_PAIRED
  }
  const rows = []
  for (const m of macs) {
    let online = null
    try {
      const { client } = await connect({ mac: m.macId, waitMs: 1500 })
      online = true
      client.close()
    } catch {
      online = false
    }
    rows.push({ ...m, online })
  }
  if (args.flags.json) {
    say(JSON.stringify({ macs: rows.map((r) => ({ macId: r.macId, macName: r.macName, online: r.online, default: !!r.default })) }))
    return EXIT.OK
  }
  for (const r of rows) {
    say(`${r.default ? '*' : ' '} ${r.macName}  ${r.online ? t('online') : t('offlineWord')}  ${r.macId}`)
  }
  if (rows.length > 1) say('\n(带 * 的是默认;用 --mac <名字> 指定别的一台)')
  return EXIT.OK
}

export async function cmdInfo(args) {
  const { client, session, pairing } = await connect({ mac: args.flags.mac })
  try {
    const info = await session.request('sys.info', {}, { timeoutMs: 30_000 })
    if (args.flags.json) {
      say(JSON.stringify(info))
      return EXIT.OK
    }
    const dash = t('unknown')
    const line = (k, v) => say(`${k.padEnd(8)} ${v ?? dash}`)
    say(pairing.macName)
    line('机型', info.model)
    line('系统', info.os)
    line('架构', info.arch)
    line('用户', info.user)
    line('目录', info.cwd || info.home)
    if (info.uptime != null) line('已开机', `${Math.round(info.uptime / 3600)} 小时`)
    if (info.battery != null) line('电量', `${info.battery}%`)
    line('Xcode', info.xcode)
    line('Node', info.node)
    line('Python', info.python)
    // v0.2 开工体检字段(旧 App 没有,就不显示)
    if (info.mem_gb != null) line('内存', `${info.mem_gb} GB`)
    if (info.disk_free_gb != null) line('磁盘', `${info.disk_free_gb} GB 可用`)
    if (info.cpu != null) line('CPU', info.cpu)
    if (info.gpu != null) line('GPU', info.gpu)
    if (Array.isArray(info.displays) && info.displays.length) {
      line('显示器', info.displays.map((d) => `${d.w}×${d.h}${d.main ? '*' : ''}`).join(', '))
    }
    if (info.tools && typeof info.tools === 'object') {
      const have = Object.entries(info.tools).filter(([, v]) => v).map(([k]) => k)
      const miss = Object.entries(info.tools).filter(([, v]) => !v).map(([k]) => k)
      line('工具', `${have.join(' ')}${miss.length ? `  (没有: ${miss.join(' ')})` : ''}`.trim() || dash)
    }
    if (info.app_version != null) line('App', info.app_version)
    return EXIT.OK
  } finally {
    client.close()
  }
}

export async function cmdRun(args) {
  const cmd = args.rest.join(' ').trim()
  if (!cmd) throw new CliError('用法:machands run -- <命令>(注意 -- 后面才是要在 Mac 上跑的命令)', EXIT.FAIL)
  const { client, session } = await connect({ mac: args.flags.mac })
  const timeout = Number(args.flags.timeout) || 600
  try {
    const res = await session.request(
      'run',
      { cmd, cwd: args.flags.cwd, timeout, shell: args.flags.shell },
      {
        timeoutMs: timeout * 1000 + 130_000,
        onStream: (s) => {
          if (s.o) process.stdout.write(s.o)
          if (s.e) process.stderr.write(s.e)
        },
      }
    )
    if (args.flags.json) say(JSON.stringify(res))
    return res.code ?? EXIT.OK
  } finally {
    client.close()
  }
}

function tarDir(dir) {
  const out = join(tmpdir(), `machands-${Date.now()}.tar.gz`)
  return new Promise((res, rej) => {
    const p = spawn('tar', ['czf', out, '-C', pathResolve(dir, '..'), basename(pathResolve(dir))], { stdio: 'inherit' })
    p.on('error', rej)
    p.on('exit', (code) => (code === 0 ? res(out) : rej(new CliError('打包目录失败,tar 退出码 ' + code))))
  })
}

export async function cmdPut(args) {
  const [local, remote] = args._
  if (!local || !remote) throw new CliError('用法:machands put <本地文件或目录> <Mac 上的路径>', EXIT.FAIL)
  if (!existsSync(local)) throw new CliError(`本地没有这个文件:${local}`, EXIT.FAIL)
  const isDir = statSync(local).isDirectory()
  const { client, session } = await connect({ mac: args.flags.mac })
  try {
    const source = isDir ? await tarDir(local) : local
    const target = isDir ? `/tmp/${basename(source)}` : remote
    const data = readFileSync(source)
    let sent = 0
    for (let off = 0; off < data.length || off === 0; off += CHUNK) {
      const slice = data.subarray(off, Math.min(off + CHUNK, data.length))
      const r = await session.request(
        'fs.put',
        { path: target, data: slice.toString('base64'), append: off > 0, mode: args.flags.mode },
        { timeoutMs: 180_000 }
      )
      sent += r?.bytes ?? slice.length
      if (data.length === 0) break
    }
    if (isDir) {
      const r = await session.request(
        'run',
        { cmd: `mkdir -p ${shq(remote)} && tar xzf ${shq(target)} -C ${shq(remote)} && rm -f ${shq(target)}`, timeout: 300 },
        { timeoutMs: 320_000 }
      )
      if (r.code !== 0) throw new CliError('文件传上去了,但在 Mac 上解包失败,退出码 ' + r.code)
    }
    if (args.flags.json) say(JSON.stringify({ bytes: sent, path: remote }))
    else say(t('uploaded', sent, remote))
    return EXIT.OK
  } finally {
    client.close()
  }
}

function shq(s) {
  return `'${String(s).replace(/'/g, `'\\''`)}'`
}

function untar(file, dir) {
  return new Promise((res, rej) => {
    const p = spawn('tar', ['xzf', file, '-C', dir], { stdio: ['ignore', 'inherit', 'inherit'] })
    p.on('error', rej)
    p.on('exit', (code) => (code === 0 ? res() : rej(new CliError(t('untarFailed', code)))))
  })
}

function isDirectory(path) {
  try {
    return statSync(path).isDirectory()
  } catch {
    return false
  }
}

// 文件:按 offset/length 分块拉;目录:Mac 端打成 tar.gz 流回来(response.archive === true),这边解开。
export async function cmdGet(args) {
  const [remote, positionalLocal] = args._
  if (!remote) throw new CliError(t('getUsage'), EXIT.FAIL)
  const localArg = args.flags.o || args.flags.out || positionalLocal
  const { client, session } = await connect({ mac: args.flags.mac })
  try {
    const chunks = []
    const streamed = []
    let offset = 0
    let archive = null
    for (;;) {
      const r = await session.request(
        'fs.get',
        { path: remote, offset, length: GET_CHUNK },
        { timeoutMs: 600_000, onStream: (s) => s.data && streamed.push(Buffer.from(s.data, 'base64')) }
      )
      if (r.archive === true) {
        archive = r
        break
      }
      const buf = Buffer.from(r.data || '', 'base64')
      chunks.push(buf)
      offset += buf.length
      if (r.eof || buf.length === 0) break
    }

    if (archive) {
      const tgz = Buffer.concat(streamed)
      const name = archive.name || basename(remote)
      if (args.flags['no-extract']) {
        const file = localArg && !isDirectory(localArg) ? localArg : join(localArg || '.', `${name}.tar.gz`)
        writeFileSync(file, tgz)
        if (args.flags.json) say(JSON.stringify({ bytes: tgz.length, path: file, archive: true, extracted: false }))
        else say(t('downloaded', tgz.length, file))
        return EXIT.OK
      }
      const dir = localArg || '.'
      mkdirSync(dir, { recursive: true })
      const tmp = join(tmpdir(), `machands-get-${process.pid}-${Date.now()}.tar.gz`)
      writeFileSync(tmp, tgz)
      try {
        await untar(tmp, dir)
      } finally {
        try {
          unlinkSync(tmp)
        } catch {}
      }
      // 包里带着目录自己的名字(和 put 一致),所以落地在 <dir>/<name>
      const landed = join(dir, name)
      if (args.flags.json) say(JSON.stringify({ bytes: tgz.length, path: landed, archive: true, extracted: true }))
      else say(t('dirDownloaded', tgz.length, landed))
      return EXIT.OK
    }

    const all = Buffer.concat(chunks)
    let local = localArg || basename(remote)
    if (isDirectory(local)) local = join(local, basename(remote))
    writeFileSync(local, all)
    if (args.flags.json) say(JSON.stringify({ bytes: all.length, path: local }))
    else say(t('downloaded', all.length, local))
    return EXIT.OK
  } finally {
    client.close()
  }
}

export async function cmdLs(args) {
  const path = args._[0] || '~'
  const { client, session } = await connect({ mac: args.flags.mac })
  try {
    const r = await session.request('fs.ls', { path, depth: Number(args.flags.depth) || 1 }, { timeoutMs: 60_000 })
    if (args.flags.json) {
      say(JSON.stringify(r))
      return EXIT.OK
    }
    for (const e of r.entries || []) {
      say(`${e.type === 'dir' ? 'd' : '-'} ${String(e.size ?? 0).padStart(9)}  ${e.name}`)
    }
    return EXIT.OK
  } finally {
    client.close()
  }
}

export async function cmdShot(args) {
  const out = args.flags.o || args.flags.out || 'screen.png'
  const { client, session } = await connect({ mac: args.flags.mac })
  try {
    const parts = []
    const r = await session.request(
      'screen.shot',
      {
        display: Number(args.flags.display) || 0,
        scale: args.flags.scale ? Number(args.flags.scale) : 0.5,
        format: args.flags.format || 'png',
      },
      { timeoutMs: 180_000, onStream: (s) => s.data && parts.push(Buffer.from(s.data, 'base64')) }
    )
    const png = Buffer.concat(parts)
    writeFileSync(out, png)
    if (args.flags.json) say(JSON.stringify({ path: out, width: r.width, height: r.height, bytes: png.length }))
    else say(t('shotSaved', out, r.width ?? '?', r.height ?? '?'))
    return EXIT.OK
  } finally {
    client.close()
  }
}

export async function cmdOpen(args) {
  const target = args._[0]
  if (!target) throw new CliError('用法:machands open <网址或路径>', EXIT.FAIL)
  const { client, session } = await connect({ mac: args.flags.mac })
  try {
    await session.request('open', { target }, { timeoutMs: 130_000 })
    say(`已在 Mac 上打开 ${target}`)
    return EXIT.OK
  } finally {
    client.close()
  }
}

export async function cmdClip(args) {
  const sub = args._[0] || 'get'
  const { client, session } = await connect({ mac: args.flags.mac })
  try {
    if (sub === 'set') {
      const text = args._.slice(1).join(' ')
      if (!text) throw new CliError('用法:machands clip set <文本>', EXIT.FAIL)
      await session.request('clip.set', { text }, { timeoutMs: 130_000 })
      say(t('clipSet'))
      return EXIT.OK
    }
    const r = await session.request('clip.get', {}, { timeoutMs: 130_000 })
    if (args.flags.json) say(JSON.stringify(r))
    else process.stdout.write((r.text ?? '') + '\n')
    return EXIT.OK
  } finally {
    client.close()
  }
}

export async function cmdNotify(args) {
  const title = args._[0]
  const body = args._.slice(1).join(' ')
  if (!title) throw new CliError('用法:machands notify <标题> [正文]', EXIT.FAIL)
  const { client, session } = await connect({ mac: args.flags.mac })
  try {
    await session.request('notify', { title, body }, { timeoutMs: 60_000 })
    say('已发到 Mac 的通知中心。')
    return EXIT.OK
  } finally {
    client.close()
  }
}

export async function cmdForget(args) {
  const want = args._[0]
  const store = loadPairings()
  const mac = resolveMac(store, want)
  store.macs = (store.macs || []).filter((m) => m.macId !== mac.macId)
  if (store.macs.length === 1) store.macs[0].default = true
  savePairings(store)
  say(t('forgot', mac.macName))
  return EXIT.OK
}

export async function cmdDoctor(args) {
  const lines = []
  const identity = loadIdentity()
  lines.push(`身份文件  ${join(homeDir(), 'identity.json')}  id ${identity.id}  名字 ${identity.name}`)
  const store = loadPairings()
  const macs = store.macs || []
  if (macs.length === 0) {
    lines.push(`配对      还没有。${t('noPairs')}`)
  }
  const results = []
  for (const m of macs) {
    let relayOk = false
    let online = false
    let why = ''
    try {
      const { client } = await connect({ mac: m.macId, waitMs: 2000 })
      relayOk = true
      online = true
      client.close()
    } catch (err) {
      why = err.message
      relayOk = !/连不上中继/.test(err.message)
      online = false
    }
    results.push({ macId: m.macId, macName: m.macName, relay: `${m.relay.host}:${m.relay.port}`, relayOk, online, why })
    lines.push(
      `Mac       ${m.macName}  中继 ${m.relay.host}:${m.relay.port} ${relayOk ? '可达' : '不可达'}  ${online ? t('online') : t('offlineWord')}${why && !online ? '  · ' + why : ''}`
    )
  }
  if (args.flags.json) {
    say(JSON.stringify({ home: homeDir(), id: identity.id, name: identity.name, macs: results }))
    return macs.length && results.every((r) => r.online) ? EXIT.OK : EXIT.OFFLINE
  }
  say(t('doctorHead'))
  lines.forEach((l) => say('  ' + l))
  if (macs.length && results.every((r) => r.online)) say('  一切正常。')
  return macs.length && results.every((r) => r.online) ? EXIT.OK : EXIT.OFFLINE
}

// ---------- v0.2:一次授权 / 体检 / 作业 / 会话 / 键鼠 / 录屏 / MCP 桥(SPEC §11–§13) ----------

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** 位置参数 + `--` 之后的词拼成一句(命令、要敲的文本)。 */
function joinWords(args, from = 0) {
  return [...args._.slice(from), ...args.rest].join(' ').trim()
}

/** 数字参数;没给用 fallback,给了但不是数就说清楚。 */
function num(v, fallback) {
  if (v === undefined || v === null || v === true) return fallback
  const n = Number(v)
  if (!Number.isFinite(n)) throw new CliError(t('notANumber', v), EXIT.FAIL)
  return n
}

function parseJsonArg(raw, kind) {
  let value
  try {
    value = JSON.parse(raw)
  } catch (err) {
    throw new CliError(t('badJson', err.message), EXIT.FAIL)
  }
  if (kind === 'array' && !Array.isArray(value)) throw new CliError(t('badJson', 'expected an array'), EXIT.FAIL)
  if (kind === 'object' && (typeof value !== 'object' || value === null || Array.isArray(value))) {
    throw new CliError(t('badJson', 'expected an object'), EXIT.FAIL)
  }
  return value
}

/** 收一个流式二进制回包(截屏/录屏)并落盘。 */
async function pullBinary(session, method, params, timeoutMs) {
  const parts = []
  const r = await session.request(method, params, {
    timeoutMs,
    onStream: (s) => s.data && parts.push(Buffer.from(s.data, 'base64')),
  })
  return { r, buf: Buffer.concat(parts) }
}

export async function cmdUse(args) {
  const want = args._[0]
  if (!want) throw new CliError(t('useUsage'), EXIT.FAIL)
  const store = loadPairings()
  const mac = resolveMac(store, want)
  for (const m of store.macs) m.default = m.macId === mac.macId
  savePairings(store)
  if (args.flags.json) say(JSON.stringify({ macId: mac.macId, macName: mac.macName, default: true }))
  else say(`default mac: ${mac.macName}`)
  return EXIT.OK
}

export async function cmdVerify(args) {
  const { client, session } = await connect({ mac: args.flags.mac })
  try {
    // Mac 端真的会跑命令、截屏、动一下鼠标、起作业、发通知,给足时间
    const r = await session.request('verify.run', {}, { timeoutMs: 300_000 })
    const rows = (Array.isArray(r?.rows) ? r.rows : []).map((row) => ({
      name: row.name ?? row.key ?? '?',
      ok: row.ok === true,
      detail: row.detail ?? '',
      ...(row.fix ? { fix: row.fix } : {}),
    }))
    const failed = rows.filter((row) => !row.ok).length
    const allOk = rows.length > 0 && failed === 0
    if (args.flags.json) {
      say(JSON.stringify({ ok: allOk, rows }))
      return allOk ? EXIT.OK : EXIT.FAIL
    }
    for (const row of rows) {
      say(row.ok ? `✓ ${row.name}  ${row.detail}` : `✗ ${row.name}  ${row.detail}${row.fix ? ` → ${row.fix}` : ''}`)
    }
    if (rows.length === 0) warn(t('verifyEmpty'))
    else say(allOk ? t('verifyAllPass') : t('verifySomeFail', failed))
    return allOk ? EXIT.OK : EXIT.FAIL
  } finally {
    client.close()
  }
}

const PERM_ORDER = ['screen', 'accessibility', 'notifications']
const PERM_FIX = { screen: 'permFixScreen', accessibility: 'permFixAx', notifications: 'permFixNotify' }

function permWord(v) {
  if (v === true || v === 'authorized') return 'yes'
  if (v === false || v === 'denied') return 'no'
  return 'unknown'
}

export async function cmdPerms(args) {
  const { client, session } = await connect({ mac: args.flags.mac })
  try {
    const r = await session.request('sys.perms', {}, { timeoutMs: 30_000 })
    if (args.flags.json) {
      say(JSON.stringify(r))
      return EXIT.OK
    }
    const names = [...PERM_ORDER.filter((k) => k in r), ...Object.keys(r).filter((k) => !PERM_ORDER.includes(k))]
    for (const name of names) say(`${name}: ${permWord(r[name])}`)
    // 修复指引走 stderr,stdout 保持一行一项好解析
    for (const name of names) {
      if (permWord(r[name]) !== 'yes' && PERM_FIX[name]) warn(`  ${name} → ${t(PERM_FIX[name])}`)
    }
    return EXIT.OK
  } finally {
    client.close()
  }
}

export async function cmdWhich(args) {
  const names = args._.filter(Boolean)
  const { client, session } = await connect({ mac: args.flags.mac })
  try {
    const r = (await session.request('sys.which', names.length ? { names } : {}, { timeoutMs: 60_000 })) || {}
    if (args.flags.json) {
      say(JSON.stringify(r))
      return EXIT.OK
    }
    const order = names.length ? names : Object.keys(r).sort()
    for (const name of order) say(`${name}: ${r[name] ?? '-'}`)
    return EXIT.OK
  } finally {
    client.close()
  }
}

export async function cmdCheck(args) {
  const subject = joinWords(args)
  if (!subject) throw new CliError(t('checkUsage'), EXIT.FAIL)
  const { client, session } = await connect({ mac: args.flags.mac })
  try {
    const method = typeof args.flags.method === 'string' ? args.flags.method : 'run'
    const r = (await session.request('policy.check', { method, subject }, { timeoutMs: 30_000 })) || {}
    const decision = r.decision || 'unknown'
    if (args.flags.json) say(JSON.stringify(r))
    else say(decision === 'deny' && r.reason ? `${decision}  ${r.reason}` : decision)
    return decision === 'deny' ? EXIT.DENIED : EXIT.OK
  } finally {
    client.close()
  }
}

export async function cmdPolicy(args) {
  if (args._[0] === 'check') {
    args._.shift()
    return cmdCheck(args)
  }
  const { client, session } = await connect({ mac: args.flags.mac })
  try {
    const r = (await session.request('policy.get', {}, { timeoutMs: 30_000 })) || {}
    if (args.flags.json) {
      say(JSON.stringify(r))
      return EXIT.OK
    }
    for (const [k, v] of Object.entries(r)) {
      if (Array.isArray(v)) {
        if (v.length === 0) say(`${k}: (none)`)
        for (const x of v) say(`${k}: ${typeof x === 'string' ? x : JSON.stringify(x)}`)
      } else {
        say(`${k}: ${typeof v === 'object' && v !== null ? JSON.stringify(v) : v}`)
      }
    }
    return EXIT.OK
  } finally {
    client.close()
  }
}

// ---- job ----

function jobLine(j) {
  const code = j.code === undefined || j.code === null ? '-' : j.code
  return `${j.jobId}  ${j.state ?? '?'}  code=${code}  ${j.ms ?? 0} ms  ${j.cmd ?? ''}`.trimEnd()
}

/** 进程退出码 = 作业退出码;还在跑或没有码算失败;超出 0–255 归 1。 */
function exitFromJob(j) {
  if (!j || j.state === 'running') return EXIT.FAIL
  const c = Number(j.code)
  if (!Number.isInteger(c)) return EXIT.FAIL
  return c >= 0 && c <= 255 ? c : 1
}

export async function cmdJob(args) {
  const sub = args._.shift()
  const id = args._[0]
  const usage = () => new CliError(t('jobUsage'), EXIT.FAIL)
  if (!['submit', 'status', 'tail', 'result', 'kill', 'list'].includes(sub)) throw usage()
  if (['status', 'tail', 'result', 'kill'].includes(sub) && !id) throw usage()
  const { client, session } = await connect({ mac: args.flags.mac })
  try {
    switch (sub) {
      case 'submit': {
        const cmd = joinWords(args)
        if (!cmd) throw usage()
        const p = { cmd }
        if (args.flags.cwd) p.cwd = args.flags.cwd
        if (args.flags.timeout !== undefined) p.timeout = num(args.flags.timeout, 3600)
        const r = await session.request('job.submit', p, { timeoutMs: 60_000 })
        if (args.flags.json) say(JSON.stringify(r))
        else say(r.jobId)
        return EXIT.OK
      }
      case 'status': {
        const r = await session.request('job.status', { jobId: id }, { timeoutMs: 30_000 })
        say(args.flags.json ? JSON.stringify(r) : jobLine(r))
        return EXIT.OK
      }
      case 'result': {
        // --wait S:最多等 S 秒;没给就等到作业结束(Mac 端单次上限 600 秒,分段续等)
        let remaining = args.flags.wait !== undefined ? Math.max(0, num(args.flags.wait, 0)) : Infinity
        let r
        do {
          const chunk = remaining === Infinity ? 60 : Math.min(remaining, 600)
          r = await session.request('job.result', { jobId: id, wait: chunk }, { timeoutMs: chunk * 1000 + 130_000 })
          remaining -= chunk
        } while (r && r.state === 'running' && remaining > 0)
        say(args.flags.json ? JSON.stringify(r) : jobLine(r))
        if (r && r.state === 'running') warn(t('jobStillRunning', id))
        return exitFromJob(r)
      }
      case 'tail': {
        const stream = args.flags.err ? 'err' : 'out'
        let offset = Math.max(0, num(args.flags.offset, 0))
        // 读到没有新东西为止;返回 true 表示这一轮读空了
        const pull = async () => {
          const r = await session.request('job.tail', { jobId: id, stream, offset }, { timeoutMs: 60_000 })
          const buf = Buffer.from(r.data || '', 'base64')
          if (buf.length) process.stdout.write(buf)
          offset = typeof r.offset === 'number' ? r.offset : offset + buf.length
          return r.eof === true || buf.length === 0
        }
        for (;;) {
          const drained = await pull()
          if (!drained) continue
          if (!args.flags.follow) break
          const st = await session.request('job.status', { jobId: id }, { timeoutMs: 30_000 })
          if (st.state !== 'running') {
            while (!(await pull())) {
              /* 把最后一口读完 */
            }
            break
          }
          await sleep(1000)
        }
        return EXIT.OK
      }
      case 'kill': {
        await session.request('job.kill', { jobId: id }, { timeoutMs: 30_000 })
        if (args.flags.json) say(JSON.stringify({ jobId: id, killed: true }))
        else say(t('jobKilled', id))
        return EXIT.OK
      }
      default: {
        const r = (await session.request('job.list', {}, { timeoutMs: 30_000 })) || {}
        const jobs = Array.isArray(r.jobs) ? r.jobs : []
        if (args.flags.json) say(JSON.stringify({ jobs }))
        else if (jobs.length === 0) warn(t('noJobs'))
        else for (const j of jobs) say(jobLine(j))
        return EXIT.OK
      }
    }
  } finally {
    client.close()
  }
}

// ---- session ----

function unescapeText(s) {
  return s.replace(/\\(n|r|t|\\)/g, (_, c) => ({ n: '\n', r: '\r', t: '\t', '\\': '\\' })[c])
}

export async function cmdSession(args) {
  const sub = args._.shift()
  const id = args._[0]
  const usage = () => new CliError(t('sessionUsage'), EXIT.FAIL)
  if (!['open', 'write', 'read', 'close'].includes(sub)) throw usage()
  if (sub !== 'open' && !id) throw usage()
  const { client, session } = await connect({ mac: args.flags.mac })
  try {
    switch (sub) {
      case 'open': {
        const cmd = joinWords(args)
        const p = {}
        if (cmd) p.cmd = cmd
        if (args.flags.cwd) p.cwd = args.flags.cwd
        const r = await session.request('session.open', p, { timeoutMs: 60_000 })
        if (args.flags.json) say(JSON.stringify(r))
        else say(r.sessionId)
        return EXIT.OK
      }
      case 'write': {
        let text = joinWords(args, 1)
        if (!text) throw usage()
        if (!args.flags.raw) text = unescapeText(text)
        await session.request('session.write', { sessionId: id, data: text }, { timeoutMs: 30_000 })
        if (args.flags.json) say(JSON.stringify({ sessionId: id, bytes: Buffer.byteLength(text) }))
        return EXIT.OK
      }
      case 'read': {
        const offset = Math.max(0, num(args.flags.offset, 0))
        const r = (await session.request('session.read', { sessionId: id, offset }, { timeoutMs: 30_000 })) || {}
        if (args.flags.json) {
          say(JSON.stringify(r))
          return EXIT.OK
        }
        if (r.data) process.stdout.write(r.data)
        warn(`offset=${r.offset ?? offset} eof=${r.eof === true} alive=${r.alive === true}`)
        return EXIT.OK
      }
      default: {
        await session.request('session.close', { sessionId: id }, { timeoutMs: 30_000 })
        if (args.flags.json) say(JSON.stringify({ sessionId: id, closed: true }))
        else say(t('sessionClosed', id))
        return EXIT.OK
      }
    }
  } finally {
    client.close()
  }
}

// ---- input ----

export async function cmdInput(args) {
  const sub = args._.shift()
  const usage = () => new CliError(t('inputUsage'), EXIT.FAIL)
  const coords = (n) => {
    const vals = args._.slice(0, n).map((v) => num(v))
    if (vals.length < n || vals.some((v) => v === undefined)) throw usage()
    return vals
  }
  const ops = {
    where: () => ['input.where', {}],
    move: () => {
      const [x, y] = coords(2)
      return ['input.move', { x, y }]
    },
    click: () => {
      const [x, y] = coords(2)
      const button = args.flags.right ? 'right' : typeof args.flags.button === 'string' ? args.flags.button : 'left'
      const count = args.flags.double ? 2 : Math.max(1, Math.round(num(args.flags.count, 1)))
      return ['input.click', { x, y, button, count }]
    },
    drag: () => {
      const [x1, y1, x2, y2] = coords(4)
      return ['input.drag', { x1, y1, x2, y2, ms: Math.max(0, Math.round(num(args.flags.ms, 300))) }]
    },
    scroll: () => {
      const [x, y, dx, dy] = coords(4)
      return ['input.scroll', { x, y, dx: Math.round(dx), dy: Math.round(dy) }]
    },
    key: () => {
      let key = args._[0]
      if (!key) throw usage()
      let mods = typeof args.flags.mods === 'string' ? args.flags.mods.split(',').map((s) => s.trim()).filter(Boolean) : []
      // 也认 cmd+shift+s 这种写法
      if (key.length > 1 && key.includes('+')) {
        const parts = key.split('+').filter(Boolean)
        key = parts.pop()
        mods = [...mods, ...parts]
      }
      return ['input.key', { key, mods }]
    },
    type: () => {
      const text = joinWords(args)
      if (!text) throw usage()
      return ['input.type', { text }]
    },
  }
  const op = ops[sub]
  if (!op) throw usage()
  const [method, params] = op()
  const { client, session } = await connect({ mac: args.flags.mac })
  try {
    const r = (await session.request(method, params, { timeoutMs: 60_000 })) || {}
    if (args.flags.json) say(JSON.stringify(r))
    else if (method === 'input.where') say(`${Math.round(r.x ?? 0)} ${Math.round(r.y ?? 0)}`)
    return EXIT.OK
  } finally {
    client.close()
  }
}

// ---- record / window-shot ----

export async function cmdRecord(args) {
  const out = args.flags.o || args.flags.out || 'screen.mov'
  const positional = args._[0] !== undefined ? num(args._[0]) : undefined
  const seconds = Math.min(120, Math.max(1, Math.round(num(args.flags.seconds, positional ?? 5))))
  const display = Math.max(0, Math.round(num(args.flags.display, 0)))
  const { client, session } = await connect({ mac: args.flags.mac })
  try {
    const { r, buf } = await pullBinary(session, 'screen.record', { seconds, display }, seconds * 1000 + 130_000)
    writeFileSync(out, buf)
    if (args.flags.json) say(JSON.stringify({ path: out, bytes: buf.length, seconds: r.seconds ?? seconds, format: r.format ?? 'mov' }))
    else say(t('recordSaved', out, r.seconds ?? seconds, buf.length))
    return EXIT.OK
  } finally {
    client.close()
  }
}

export async function cmdWindowShot(args) {
  const out = args.flags.o || args.flags.out || 'window.png'
  const p = { format: args.flags.format || 'png', scale: args.flags.scale ? num(args.flags.scale) : 1 }
  if (typeof args.flags.app === 'string') p.app = args.flags.app
  if (typeof args.flags.title === 'string') p.title = args.flags.title
  if (args.flags.quality !== undefined) p.quality = Math.round(num(args.flags.quality, 80))
  const { client, session } = await connect({ mac: args.flags.mac })
  try {
    const { r, buf } = await pullBinary(session, 'screen.window', p, 180_000)
    writeFileSync(out, buf)
    if (args.flags.json) say(JSON.stringify({ path: out, width: r.width, height: r.height, bytes: buf.length }))
    else say(t('shotSaved', out, r.width ?? '?', r.height ?? '?'))
    return EXIT.OK
  } finally {
    client.close()
  }
}

// ---- mcp 桥(Mac 上已配置的 MCP 服务器,借 Mac 的手调) ----

function firstLine(s) {
  return String(s ?? '').split('\n')[0].trim()
}

export async function cmdMcpBridge(args) {
  const sub = args._.shift()
  const sid = args._[0]
  const usage = () => new CliError(t('mcpUsage'), EXIT.FAIL)
  if (!['servers', 'open', 'list', 'tools', 'call', 'close'].includes(sub)) throw usage()
  if (['list', 'tools', 'call', 'close'].includes(sub) && !sid) throw usage()
  const { client, session } = await connect({ mac: args.flags.mac })
  try {
    switch (sub) {
      case 'servers': {
        const r = (await session.request('mcp.servers', {}, { timeoutMs: 30_000 })) || {}
        const servers = Array.isArray(r.servers) ? r.servers : []
        if (args.flags.json) say(JSON.stringify({ servers }))
        else if (servers.length === 0) warn(t('noMcpServers'))
        else {
          for (const s of servers) {
            const how = s.command ? [s.command, ...(s.args || [])].join(' ') : s.url || ''
            say(`${s.name}  ${s.source ?? ''}  ${how}`.trimEnd())
          }
        }
        return EXIT.OK
      }
      case 'open': {
        const p = {}
        if (typeof args.flags.command === 'string') {
          p.command = args.flags.command
          if (typeof args.flags.args === 'string') p.args = parseJsonArg(args.flags.args, 'array')
        } else {
          if (!sid) throw usage()
          p.name = sid
        }
        if (args.flags.cwd) p.cwd = args.flags.cwd
        const r = await session.request('mcp.open', p, { timeoutMs: 120_000 })
        if (args.flags.json) say(JSON.stringify(r))
        else {
          say(r.sessionId)
          warn(t('mcpTools', (r.tools || []).map((tool) => tool.name).join(', ') || '-'))
        }
        return EXIT.OK
      }
      case 'list':
      case 'tools': {
        const r = (await session.request('mcp.list', { sessionId: sid }, { timeoutMs: 60_000 })) || {}
        const tools = Array.isArray(r.tools) ? r.tools : []
        if (args.flags.json) say(JSON.stringify({ tools }))
        else for (const tool of tools) say(`${tool.name}  ${firstLine(tool.description)}`.trimEnd())
        return EXIT.OK
      }
      case 'call': {
        const tool = args._[1]
        if (!tool) throw usage()
        const raw = [...args._.slice(2), ...args.rest].join(' ').trim() || '{}'
        const callArgs = parseJsonArg(raw, 'object')
        const timeout = Math.min(600, Math.max(5, num(args.flags.timeout, 120)))
        const r = (await session.request('mcp.call', { sessionId: sid, tool, args: callArgs, timeout }, { timeoutMs: timeout * 1000 + 130_000 })) || {}
        if (args.flags.json) say(JSON.stringify(r))
        else {
          for (const c of Array.isArray(r.content) ? r.content : []) {
            if (c.type === 'text') say(c.text ?? '')
            else if (c.type === 'image') say(`[image ${c.mimeType || ''} ${Buffer.from(c.data || '', 'base64').length} bytes]`)
            else say(JSON.stringify(c))
          }
        }
        return r.isError ? EXIT.FAIL : EXIT.OK
      }
      default: {
        await session.request('mcp.close', { sessionId: sid }, { timeoutMs: 30_000 })
        if (args.flags.json) say(JSON.stringify({ sessionId: sid, closed: true }))
        else say(t('mcpClosed', sid))
        return EXIT.OK
      }
    }
  } finally {
    client.close()
  }
}

// ---- power / relaunch ----

export async function cmdPower(args) {
  const sub = args._[0]
  const on = sub === 'on' || sub === 'assert'
  const off = sub === 'off' || sub === 'release'
  if (!on && !off) throw new CliError(t('powerUsage'), EXIT.FAIL)
  const { client, session } = await connect({ mac: args.flags.mac })
  try {
    if (off) {
      await session.request('power.release', {}, { timeoutMs: 30_000 })
      if (args.flags.json) say(JSON.stringify({ awake: false }))
      else say(t('powerOff'))
      return EXIT.OK
    }
    const positional = args._[1] !== undefined ? num(args._[1]) : undefined
    const seconds = Math.min(14_400, Math.max(1, Math.round(num(args.flags.seconds, positional ?? 3600))))
    const r = (await session.request('power.assert', { seconds }, { timeoutMs: 30_000 })) || {}
    if (args.flags.json) say(JSON.stringify({ awake: true, seconds: r.seconds ?? seconds, until: r.until }))
    else say(t('powerOn', r.seconds ?? seconds))
    return EXIT.OK
  } finally {
    client.close()
  }
}

export async function cmdRelaunch(args) {
  const { client, session } = await connect({ mac: args.flags.mac })
  try {
    await session.request('app.relaunch', {}, { timeoutMs: 30_000 })
    if (args.flags.json) say(JSON.stringify({ relaunching: true }))
    else say(t('relaunching'))
    return EXIT.OK
  } finally {
    client.close()
  }
}

const USAGE = `machands ${VERSION} · 给你的云端 agent 一双 Mac 上的手

  连接
  machands pair "<配对码>"                    连接并配对(配对码来自 Mac 上的“复制给 agent”)
  machands macs                              列出已配对的 Mac 与在线状态
  machands use <mac>                         设默认 Mac(之后不用再写 --mac)
  machands verify                            一次授权后的验证:✓/✗ 每项 + 修复指引;全过退出 0
  machands perms                             系统权限状态(屏幕录制 / 辅助功能 / 通知)
  machands info                              这台 Mac 的体检:机型、内存、磁盘、GPU、工具在不在
  machands which [工具...]                    工具的路径(godot blender xcodebuild node …)
  machands check -- <命令>                    问一句这条命令会 allow / ask / deny,不执行
  machands policy                            Mac 当前的审批模式与黑白名单
  machands doctor                            自检:中继可达、身份文件、Mac 在线
  machands forget <mac>                      本地删除配对

  执行
  machands run [--cwd D] [--timeout S] -- <命令...>     前台执行,输出实时透传,退出码原样返回
  machands job submit [--cwd D] [--timeout S] -- <命令>  后台作业,只打印 jobId
  machands job status|tail|result|kill <id>  tail 加 --err / --follow;result 加 --wait S,退出码 = 作业退出码
  machands job list
  machands session open [命令] [--cwd D]      交互式会话(默认 zsh),只打印 sessionId
  machands session write <id> <文本>          \\n 会变成回车;--raw 不转义
  machands session read <id> [--offset N]     stdout 是输出,stderr 一行 offset/eof/alive
  machands session close <id>
  machands power on [--seconds N] | off      让 Mac 保持唤醒(caffeinate)
  machands relaunch                          让 MacHands.app 自己重启(升级后用)

  文件
  machands put <本地> <远端>                  上传(目录自动打包)
  machands get <远端> [-o 本地] [--no-extract]  下载;远端是目录就打包传回并解开
  machands ls [路径] [--depth N]              看目录

  看与动
  machands shot [-o out.png] [--scale 0.5] [--display 0]
  machands window-shot [--app 名] [--title 标题] [-o out.png] [--scale 1]
  machands record [--seconds 5] [--display 0] -o out.mov
  machands input where | move X Y | click X Y [--right] [--double] | drag X1 Y1 X2 Y2 [--ms 300]
  machands input scroll X Y DX DY | key <键> [--mods cmd,shift,alt,ctrl] | type <文本>
  machands open <网址或路径>
  machands clip [get | set <文本>]
  machands notify <标题> [正文]

  MCP
  machands mcp                               以 stdio MCP 服务器运行(给 Claude Code / Codex / Cursor)
  machands mcp servers                       Mac 上已配置的 MCP 服务器
  machands mcp open <名字> | open --command CMD [--args '["…"]']   借 Mac 的手起一个,打印 sid
  machands mcp list <sid> | call <sid> <工具> ['{…}'] | close <sid>

  公共参数:--mac <名字>  --json  --help  --version
  退出码:0 成功;run/job result 原样返回命令退出码(超时 124);拒绝 77,超时 78,离线 69,未配对 66。`

export async function main(argv = process.argv.slice(2)) {
  const args = parseArgs(argv)
  const cmd = args._.shift()
  if (args.flags.version || cmd === 'version') {
    say(VERSION)
    return EXIT.OK
  }
  if (!cmd || args.flags.help || cmd === 'help') {
    say(USAGE)
    return cmd ? EXIT.OK : EXIT.FAIL
  }
  const table = {
    pair: cmdPair,
    macs: cmdMacs,
    use: cmdUse,
    info: cmdInfo,
    run: cmdRun,
    put: cmdPut,
    get: cmdGet,
    ls: cmdLs,
    shot: cmdShot,
    open: cmdOpen,
    clip: cmdClip,
    notify: cmdNotify,
    forget: cmdForget,
    doctor: cmdDoctor,
    // v0.2
    verify: cmdVerify,
    perms: cmdPerms,
    which: cmdWhich,
    check: cmdCheck,
    policy: cmdPolicy,
    job: cmdJob,
    session: cmdSession,
    input: cmdInput,
    record: cmdRecord,
    'window-shot': cmdWindowShot,
    power: cmdPower,
    relaunch: cmdRelaunch,
  }
  if (cmd === 'mcp') {
    // 不带子命令 = 自己当 MCP 服务器;带子命令 = 去调 Mac 上的 MCP 服务器
    if (args._.length > 0) return await cmdMcpBridge(args)
    const { serveMCP } = await import('./mcp.mjs')
    await serveMCP()
    return EXIT.OK
  }
  const fn = table[cmd]
  if (!fn) {
    warn(`没有 ${cmd} 这个子命令。\n`)
    say(USAGE)
    return EXIT.FAIL
  }
  return await fn(args)
}

export async function run(argv) {
  try {
    const code = await main(argv)
    return typeof code === 'number' ? code : EXIT.OK
  } catch (err) {
    warn(humanError(err))
    return exitCodeFor(err)
  }
}
