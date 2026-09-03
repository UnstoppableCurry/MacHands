#!/usr/bin/env node
// 验一张 MacHands 许可证 · SPEC §7.5
//
//   node tools/license/verify.mjs "MHL1.…" --pub <公钥base64url>
//   node tools/license/verify.mjs "MHL1.…" --key ~/.machands-license/key.json
//
// 退出码:0 有效;1 过期(签名是真的);2 签名不对或格式不对。
import { readFileSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { unb64u, canonicalJSON, verifyPayload } from '../../agent/src/crypto.mjs'
import { parseArgs } from './sign.mjs'

export const OK = 0
export const EXPIRED = 1
export const BAD = 2

export function verifyLicense(line, edPub, now = Date.now()) {
  const parts = String(line).trim().replace(/^["']|["']$/g, '').split('.')
  if (parts.length !== 3 || parts[0] !== 'MHL1') {
    return { status: BAD, reason: '格式不对:应当是 MHL1.<payload>.<签名> 三段' }
  }
  let payload
  try {
    payload = JSON.parse(unb64u(parts[1]).toString('utf8'))
  } catch {
    return { status: BAD, reason: 'payload 不是合法 JSON' }
  }
  // payload 必须本来就是规范形式,不然签名对不上
  if (unb64u(parts[1]).toString('utf8') !== canonicalJSON(payload)) {
    return { status: BAD, reason: 'payload 不是规范 JSON(键要按字典序、无空白)' }
  }
  if (!verifyPayload(edPub, payload, parts[2])) {
    return { status: BAD, reason: '签名验不过:要么不是我们签的,要么被改过' }
  }
  if (payload.exp) {
    const exp = Date.parse(payload.exp.length <= 10 ? payload.exp + 'T23:59:59Z' : payload.exp)
    if (Number.isNaN(exp)) return { status: BAD, reason: 'exp 不是合法日期' }
    if (exp < now) return { status: EXPIRED, payload, reason: `已于 ${payload.exp} 过期` }
  }
  return { status: OK, payload }
}

const USAGE = `验一张 MacHands 许可证

  node tools/license/verify.mjs "MHL1.…" --pub <公钥 base64url>
  node tools/license/verify.mjs "MHL1.…" --key <私钥文件>   (从文件里取公钥)`

export function main(argv = process.argv.slice(2)) {
  const args = parseArgs(argv)
  const line = argv.find((a) => a.startsWith('MHL1.'))
  if (!line) {
    console.log(USAGE)
    return BAD
  }
  let pub
  if (args.pub && args.pub !== true) pub = unb64u(String(args.pub))
  else if (args.key && args.key !== true) pub = unb64u(JSON.parse(readFileSync(resolve(String(args.key)), 'utf8')).ed25519_pub)
  else {
    console.error('要有 --pub <公钥> 或 --key <私钥文件>')
    return BAD
  }
  const r = verifyLicense(line, pub)
  if (r.status === OK) {
    console.log(`有效  邮箱 ${r.payload.email}  席位 ${r.payload.seats}  到期 ${r.payload.exp ?? '永久'}`)
  } else if (r.status === EXPIRED) {
    console.log(`已过期  邮箱 ${r.payload.email}  ${r.reason}`)
  } else {
    console.error(`无效:${r.reason}`)
  }
  return r.status
}

const isMain = process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))
if (isMain) process.exitCode = main()
