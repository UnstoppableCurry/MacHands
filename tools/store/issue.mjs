// 签发一张许可证 · 只是把现成的 sign.mjs 包一层,算法一行都不重写。
//
// 私钥的处理:只用 readFileSync 读进内存交给 makeLicense,**不打印、不落盘到别处、
// 不进日志**。默认路径可以用 LICENSE_KEY_FILE 覆盖。
//
// 关于有效期:49 美元是买断,所以许可证是**永久**的(exp = null)。
// "含一年更新"是承诺,不是技术限制——真按 exp 卡死,一年后买家的 App 会直接罢工,
// 那不是买断。要做"更新到期"得在 appcast 侧按购买日期判断,不在这里。

import { readFileSync } from 'node:fs'
import { makeLicense } from '../license/sign.mjs'
import { unb64u } from '../../agent/src/crypto.mjs'

export const DEFAULT_KEY_FILE = '/root/.machands-license/key.json'

export function keyFilePath(env = process.env) {
  return env.LICENSE_KEY_FILE || DEFAULT_KEY_FILE
}

/**
 * @returns {string} MHL1.… 那一行
 */
export function issueLicense({ email, seats = 1, exp = null }, env = process.env) {
  if (!email) throw new Error('签证要有邮箱')
  const path = keyFilePath(env)
  let priv
  try {
    // 只取私钥字段,整个文件不外传。
    priv = unb64u(JSON.parse(readFileSync(path, 'utf8')).ed25519_priv)
  } catch (err) {
    throw new Error(`读不到签发私钥(${path}):${err.code || err.message}`)
  }
  return makeLicense(priv, { email, exp, seats })
}

/** 日志里的邮箱要打码:a***@b.com。别把买家邮箱整个写进 journald。 */
export function maskEmail(email) {
  const s = String(email || '')
  const at = s.indexOf('@')
  if (at <= 0) return s ? '***' : ''
  const name = s.slice(0, at)
  const domain = s.slice(at + 1)
  const head = name.slice(0, 1)
  return `${head}***@${domain}`
}
