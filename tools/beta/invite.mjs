#!/usr/bin/env node
// 内测邀请:一条命令给一个人发出「下载链接 + 90 天许可证 + 自建中继的两条命令」。
//
//   node tools/beta/invite.mjs --email someone@example.com
//   node tools/beta/invite.mjs --list
//   node tools/beta/invite.mjs --revoke someone@example.com
//
// 为什么要一人一个链接:B 方案里中继在用户自己手上,你看不到任何运行时数据。
// 每人一个不可猜的下载路径,是这个方案里**唯一**能拿到的信号 ——
// nginx 访问日志能告诉你谁下载了、什么时候下的。挡不住铁了心转发的人,
// 但挡得住随手丢进群,而且想切断某个人的时候有东西可切。
//
// 诚实的边界:
//   - 许可证**吊销不了**。它是离线验签的,发出去就有效到过期为止。
//     `--revoke` 只删下载链接,不影响已经装上的人。
//   - 许可证不绑机器,同一串贴到几台 Mac 上都能用。挡这个的唯一办法是
//     中继侧计数,而 B 方案里中继不是你的。这是选 B 时接受的代价。
import { randomBytes } from 'node:crypto'
import { existsSync, mkdirSync, linkSync, rmSync, appendFileSync, readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { makeLicense } from '../license/sign.mjs'
import { unb64u } from '../../agent/src/crypto.mjs'

const KEY = process.env.MACHANDS_LICENSE_KEY || '/root/.machands-license/key.json'
const WEBROOT = process.env.MACHANDS_WEBROOT || '/var/www/machands'
const LEDGER = process.env.MACHANDS_BETA_LEDGER || '/opt/machands/beta/invites.jsonl'
const SITE = process.env.MACHANDS_SITE || 'https://134.199.230.126.nip.io'
// 内测发的包。要跟着版本走,别写死在别处。
const ASSET = process.env.MACHANDS_BETA_ASSET || 'MacHands-0.3.1.zip'

function parseArgs(argv) {
  const out = { _: [] }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a.startsWith('--')) {
      const [k, inline] = a.slice(2).split('=')
      out[k] = inline ?? (argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : true)
    } else out._.push(a)
  }
  return out
}

function readLedger() {
  if (!existsSync(LEDGER)) return []
  return readFileSync(LEDGER, 'utf8')
    .split('\n')
    .filter(Boolean)
    .map((l) => {
      try { return JSON.parse(l) } catch { return null }
    })
    .filter(Boolean)
}

/// 邮箱在日志和列表里一律打码,免得一屏买家邮箱被截图出去。
function mask(email) {
  const [user, domain] = String(email).split('@')
  if (!domain) return '***'
  return `${user.slice(0, 1)}***@${domain}`
}

function cmdList() {
  const rows = readLedger()
  if (rows.length === 0) {
    console.log('还没发过邀请。')
    return 0
  }
  console.log(`共 ${rows.length} 个内测邀请:\n`)
  console.log('发出时间              到期            下载链接还在吗  邮箱')
  for (const r of rows) {
    const dir = join(WEBROOT, 'b', r.token)
    const alive = existsSync(dir) ? '在' : '已撤销'
    console.log(
      `${r.issuedAt.slice(0, 19).replace('T', ' ')}   ${r.expDate}      ${alive.padEnd(12)}  ${mask(r.email)}`
    )
  }
  return 0
}

function cmdRevoke(email) {
  const rows = readLedger().filter((r) => r.email === email)
  if (rows.length === 0) {
    console.error(`没发过给 ${mask(email)} 的邀请。`)
    return 2
  }
  let n = 0
  for (const r of rows) {
    const dir = join(WEBROOT, 'b', r.token)
    if (existsSync(dir)) {
      rmSync(dir, { recursive: true, force: true })
      n++
    }
  }
  console.log(`已删掉 ${n} 个下载链接(${mask(email)})。`)
  console.log('注意:已经发出去的许可证撤销不了 —— 它离线验签,到期之前一直有效。')
  return 0
}

function cmdInvite(email, days) {
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    console.error(`--email 看着不像邮箱:${email}`)
    return 2
  }
  const src = join(WEBROOT, 'downloads', ASSET)
  if (!existsSync(src)) {
    console.error(`找不到安装包 ${src}`)
    console.error('先把这一版的 zip 放到 downloads/ 下,或者用 MACHANDS_BETA_ASSET 指定别的文件名。')
    return 2
  }
  if (!existsSync(KEY)) {
    console.error(`找不到签发私钥 ${KEY}`)
    return 2
  }

  const expMs = Date.now() + days * 86400_000
  const expDate = new Date(expMs).toISOString().slice(0, 10)
  const keyFile = JSON.parse(readFileSync(KEY, 'utf8'))
  const license = makeLicense(unb64u(keyFile.ed25519_priv), { email, exp: expDate, seats: 1 })

  // 硬链接:不复制一份 2 MB,删链接也不动原文件。
  const token = randomBytes(16).toString('base64url')
  const dir = join(WEBROOT, 'b', token)
  mkdirSync(dir, { recursive: true })
  linkSync(src, join(dir, ASSET))

  mkdirSync(join(LEDGER, '..'), { recursive: true })
  appendFileSync(
    LEDGER,
    JSON.stringify({ email, token, expDate, asset: ASSET, issuedAt: new Date().toISOString() }) + '\n'
  )

  const url = `${SITE}/b/${token}/${ASSET}`
  console.log(`已为 ${mask(email)} 生成邀请,${days} 天,到 ${expDate} 到期。`)
  console.log(`记录写进 ${LEDGER}`)
  console.log('')
  console.log('─'.repeat(72))
  console.log(`把下面整段发给他:

MacHands 内测邀请

1) 下载并装上(拖进「应用程序」):
   ${url}

2) 打开 MacHands → 设置 → 许可证,粘这一行:
   ${license}

3) 你需要一台自己的公网服务器(VPS)来当中继。在上面跑:
   npm i -g machands
   machands relay start --port 8443

   它会打印一个 ws:// 地址。注意:云厂商的安全组默认拦掉所有入站端口,
   要去控制台放行 8443,否则外面连不进来。在别的机器上
   curl -s http://<你的公网IP>:8443/health 通了才算真的通了。

4) 回到 MacHands → 设置 → 中继地址,填第 3 步打印的那个 ws:// 地址,保存。

5) 点主界面的「复制给 agent」,把复制到的那段文字贴给你的 AI agent
   (Claude Code / Codex / Cursor 都行),它会自己执行里面那一行完成配对。

许可证 ${expDate} 到期。到期后 App 不会变砖:截屏、读文件、键鼠这些还能用,
只是不能再替 agent 执行命令和传文件。

有任何问题直接回我。`)
  console.log('─'.repeat(72))
  return 0
}

const USAGE = `内测邀请

  node tools/beta/invite.mjs --email <邮箱> [--days 90]   发一个邀请
  node tools/beta/invite.mjs --list                       看发过谁(邮箱打码)
  node tools/beta/invite.mjs --revoke <邮箱>              删掉他的下载链接

  环境变量:MACHANDS_BETA_ASSET(发哪个包,默认 ${ASSET})
           MACHANDS_SITE / MACHANDS_WEBROOT / MACHANDS_LICENSE_KEY / MACHANDS_BETA_LEDGER`

export function main(argv = process.argv.slice(2)) {
  const args = parseArgs(argv)
  if (args.help || argv.length === 0) {
    console.log(USAGE)
    return argv.length === 0 ? 1 : 0
  }
  if (args.list) return cmdList()
  if (args.revoke && args.revoke !== true) return cmdRevoke(String(args.revoke))
  if (args.email && args.email !== true) {
    const days = Number(args.days) > 0 ? Number(args.days) : 90
    return cmdInvite(String(args.email), days)
  }
  console.log(USAGE)
  return 1
}

if (process.argv[1] && process.argv[1].endsWith('invite.mjs')) process.exitCode = main()
