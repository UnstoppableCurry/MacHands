#!/usr/bin/env node
// MacHands 许可证签发 · SPEC §7.5
// 许可证是一行:MHL1.<base64url(payload)>.<base64url(sig)>
// payload = {email, exp, seats},exp 是 ISO 日期或 null(永久),Ed25519 签的是
// utf8(canonicalJSON(payload)) —— 和握手签名同一套规则。
//
//   生成密钥(私钥绝不进仓库):
//     node tools/license/sign.mjs --gen-key ~/.machands-license/key.json
//   签一张:
//     node tools/license/sign.mjs --key ~/.machands-license/key.json \
//       --email someone@example.com --exp 2027-01-01 --seats 1
//
import { readFileSync, writeFileSync, mkdirSync, existsSync, chmodSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { b64u, unb64u, canonicalJSON, genEd25519, signPayload } from '../../agent/src/crypto.mjs'

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '../..')

export function parseArgs(argv) {
  const o = {}
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a.startsWith('--')) {
      const k = a.slice(2)
      const v = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : true
      o[k] = v
    }
  }
  return o
}

/// `--exp 2027-01-01` 这种人写的日期转成 Unix 秒。
///
/// **必须是数字。** App 端 `LicensePayload.exp` 声明的是 `Double?`,给它一个字符串
/// `JSONDecoder` 直接抛错,整张证被判成 malformed —— 不是"到期失效",是第一天就用不了。
/// 这个坑 2026-09-09 实测踩到过:带 `--exp` 签出来的证在 Mac 上一律显示无效。
///
/// 光秃秃的 `YYYY-MM-DD` 按那一天的 23:59:59 UTC 算,这样"到 1 月 1 日到期"符合人的直觉。
export function expToEpochSeconds(exp) {
  if (exp === null || exp === undefined || exp === '' || exp === 'none') return null
  if (typeof exp === 'number') {
    if (!Number.isFinite(exp)) throw new Error('--exp 不是合法日期')
    return Math.floor(exp)
  }
  const text = String(exp).trim()
  const ms = Date.parse(/^\d{4}-\d{2}-\d{2}$/.test(text) ? `${text}T23:59:59Z` : text)
  if (Number.isNaN(ms)) throw new Error(`--exp 不是合法日期:${text}`)
  return Math.floor(ms / 1000)
}

export function makeLicense(edPriv, { email, exp = null, seats = 1 }) {
  if (!email) throw new Error('要有 --email')
  const seconds = expToEpochSeconds(exp)
  // 再挡一道:任何非数字非 null 的 exp 都不许签出去,免得以后又悄悄回到字符串。
  if (seconds !== null && !Number.isInteger(seconds)) throw new Error('exp 必须是整数秒或 null')
  const payload = { email: String(email), exp: seconds, seats: Number(seats) || 1 }
  const sig = signPayload(edPriv, payload)
  return `MHL1.${b64u(Buffer.from(canonicalJSON(payload), 'utf8'))}.${sig}`
}

function genKey(pathArg) {
  const out = resolve(String(pathArg))
  if (out.startsWith(REPO + '/')) {
    console.error('私钥不能写进仓库。挑一个仓库外面的路径,比如 ~/.machands-license/key.json')
    return 2
  }
  if (existsSync(out)) {
    console.error(`${out} 已经有东西了。换个路径,或者先把老密钥收好再删。`)
    return 2
  }
  const kp = genEd25519()
  mkdirSync(dirname(out), { recursive: true, mode: 0o700 })
  writeFileSync(
    out,
    JSON.stringify({ ed25519_priv: b64u(kp.priv), ed25519_pub: b64u(kp.pub), created: new Date().toISOString() }, null, 2) + '\n',
    { mode: 0o600 }
  )
  chmodSync(out, 0o600)
  console.log(`私钥已写到 ${out}(权限 0600)。备份好,丢了就签不了新证。`)
  console.log('')
  console.log('把下面这一行粘进 Swift(公钥,base64url):')
  console.log('')
  console.log(`static let licensePublicKey = "${b64u(kp.pub)}"`)
  console.log('')
  return 0
}

const USAGE = `MacHands 许可证签发

  node tools/license/sign.mjs --gen-key <私钥路径>        生成一对密钥(路径必须在仓库外)
  node tools/license/sign.mjs --key <私钥路径> --email <邮箱> [--exp 2027-01-01|none] [--seats 1]

  --exp 不写或写 none 表示永久。`

export function main(argv = process.argv.slice(2)) {
  const args = parseArgs(argv)
  if (args.help || argv.length === 0) {
    console.log(USAGE)
    return argv.length === 0 ? 1 : 0
  }
  if (args['gen-key']) {
    if (args['gen-key'] === true) {
      console.error('用法:--gen-key <私钥路径>')
      return 2
    }
    return genKey(args['gen-key'])
  }
  if (!args.key) {
    console.error('要有 --key <私钥路径>。还没有密钥就先跑 --gen-key。')
    return 2
  }
  const keyFile = JSON.parse(readFileSync(resolve(String(args.key)), 'utf8'))
  const exp = !args.exp || args.exp === 'none' ? null : String(args.exp)
  try {
    // makeLicense 里会转成 Unix 秒;这里先转一次只为把日期写错的情况提前报出来。
    expToEpochSeconds(exp)
    const line = makeLicense(unb64u(keyFile.ed25519_priv), { email: args.email, exp, seats: args.seats })
    console.log(line)
    return 0
  } catch (err) {
    console.error(err.message)
    return 2
  }
}

const isMain = process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))
if (isMain) process.exitCode = main()
