// machands CLI · SPEC §6
// 输出全是人话;只有 --json 时才打 JSON。错误一律说下一步该做什么。
import { readFileSync, writeFileSync, mkdirSync, existsSync, chmodSync, statSync, renameSync } from 'node:fs'
import { homedir, hostname, tmpdir } from 'node:os'
import { join, basename, resolve as pathResolve } from 'node:path'
import { spawn } from 'node:child_process'
import { RelayClient } from './relay.mjs'
import { RpcSession, RpcError, attach } from './rpc.mjs'
import { t } from './i18n.mjs'
import { b64u, unb64u, genEd25519, genX25519, newId, parsePairingCode } from './crypto.mjs'

export const VERSION = '0.1.0'
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
      else if (a[0] && !a[0].startsWith('-')) out.flags[k] = a.shift()
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

export async function cmdGet(args) {
  const [remote, localArg] = args._
  if (!remote) throw new CliError('用法:machands get <Mac 上的路径> [本地路径]', EXIT.FAIL)
  const local = localArg || basename(remote)
  const { client, session } = await connect({ mac: args.flags.mac })
  try {
    const chunks = []
    let offset = 0
    for (;;) {
      const r = await session.request('fs.get', { path: remote, offset, length: GET_CHUNK }, { timeoutMs: 120_000 })
      const buf = Buffer.from(r.data || '', 'base64')
      chunks.push(buf)
      offset += buf.length
      if (r.eof || buf.length === 0) break
    }
    const all = Buffer.concat(chunks)
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

const USAGE = `machands ${VERSION} · 给你的云端 agent 一双 Mac 上的手

  machands pair "<配对码>"                    连接并配对(配对码来自 Mac 上的“复制给 agent”)
  machands macs                              列出已配对的 Mac 与在线状态
  machands run [--mac N] [--cwd D] [--timeout S] -- <命令...>
  machands put <本地> <远端>                  上传(目录自动打包)
  machands get <远端> [本地]                  下载
  machands ls [路径] [--depth N]              看目录
  machands shot [-o out.png] [--scale 0.5] [--display 0]
  machands open <网址或路径>
  machands clip [get | set <文本>]
  machands notify <标题> [正文]
  machands info                              这台 Mac 的基本信息
  machands mcp                               以 stdio MCP 服务器运行
  machands forget <mac>                      本地删除配对
  machands doctor                            自检:中继可达、身份文件、Mac 在线

  公共参数:--mac <名字>  --json  --help  --version
  退出码:0 成功;run 原样返回命令退出码;拒绝 77,超时 78,离线 69,未配对 66。`

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
  }
  if (cmd === 'mcp') {
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
