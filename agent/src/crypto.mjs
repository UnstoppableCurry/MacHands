// MacHands 加密层 · SPEC §2 §5
// 只用 node:crypto 内置实现:X25519 / HKDF-SHA256 / ChaCha20-Poly1305 / Ed25519。
import {
  createPrivateKey,
  createPublicKey,
  createCipheriv,
  createDecipheriv,
  diffieHellman,
  generateKeyPairSync,
  hkdfSync,
  randomBytes,
  sign as edSign,
  verify as edVerify,
  timingSafeEqual,
} from 'node:crypto'

// ---------- base64url(无填充) ----------

export function b64u(buf) {
  return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

export function unb64u(str) {
  if (typeof str !== 'string') throw new TypeError('base64url 期望字符串')
  return Buffer.from(str.replace(/-/g, '+').replace(/_/g, '/'), 'base64')
}

// ---------- base32(小写,RFC4648 字母表,无填充) ----------

const B32 = 'abcdefghijklmnopqrstuvwxyz234567'

export function b32(buf) {
  const bytes = Buffer.from(buf)
  let bits = 0
  let value = 0
  let out = ''
  for (const byte of bytes) {
    value = (value << 8) | byte
    bits += 8
    while (bits >= 5) {
      out += B32[(value >>> (bits - 5)) & 31]
      bits -= 5
    }
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31]
  return out
}

// ---------- 规范 JSON:键按字典序、无空白 ----------

export function canonicalJSON(value) {
  if (value === null || typeof value === 'number' || typeof value === 'boolean') return JSON.stringify(value)
  if (typeof value === 'string') return JSON.stringify(value)
  if (Array.isArray(value)) return '[' + value.map(canonicalJSON).join(',') + ']'
  if (typeof value === 'object') {
    const keys = Object.keys(value).filter((k) => value[k] !== undefined).sort()
    return '{' + keys.map((k) => JSON.stringify(k) + ':' + canonicalJSON(value[k])).join(',') + '}'
  }
  throw new TypeError('canonicalJSON 不支持的类型:' + typeof value)
}

// ---------- 原始密钥 ↔ KeyObject ----------
// node 只吃 DER/PEM,所以用固定前缀在 raw 32 字节和 DER 之间转换。

const SPKI_PREFIX = {
  x25519: Buffer.from('302a300506032b656e032100', 'hex'),
  ed25519: Buffer.from('302a300506032b6570032100', 'hex'),
}
const PKCS8_PREFIX = {
  x25519: Buffer.from('302e020100300506032b656e04220420', 'hex'),
  ed25519: Buffer.from('302e020100300506032b657004220420', 'hex'),
}

function checkRaw(raw, what) {
  const buf = Buffer.from(raw)
  if (buf.length !== 32) throw new Error(`${what} 必须是 32 字节,收到 ${buf.length}`)
  return buf
}

export function importPub(rawPub, kind) {
  return createPublicKey({
    key: Buffer.concat([SPKI_PREFIX[kind], checkRaw(rawPub, '公钥')]),
    format: 'der',
    type: 'spki',
  })
}

export function importPriv(rawPriv, kind) {
  return createPrivateKey({
    key: Buffer.concat([PKCS8_PREFIX[kind], checkRaw(rawPriv, '私钥')]),
    format: 'der',
    type: 'pkcs8',
  })
}

export function rawPub(keyObject) {
  return keyObject.export({ type: 'spki', format: 'der' }).subarray(-32)
}

export function rawPriv(keyObject) {
  return keyObject.export({ type: 'pkcs8', format: 'der' }).subarray(-32)
}

// ---------- 生成身份 ----------

function genPair(kind) {
  const { publicKey, privateKey } = generateKeyPairSync(kind)
  return { priv: rawPriv(privateKey), pub: rawPub(publicKey) }
}

export const genX25519 = () => genPair('x25519')
export const genEd25519 = () => genPair('ed25519')

export function newId() {
  // 16 字节随机 → base32 小写 26 字符(SPEC §2)
  return b32(randomBytes(16)).slice(0, 26)
}

export function newToken() {
  return b64u(randomBytes(16))
}

// ---------- Ed25519 签名 ----------

export function signPayload(rawEdPriv, payload) {
  const msg = Buffer.from(canonicalJSON(payload), 'utf8')
  return b64u(edSign(null, msg, importPriv(rawEdPriv, 'ed25519')))
}

export function verifyPayload(rawEdPub, payload, sigB64u) {
  try {
    const msg = Buffer.from(canonicalJSON(payload), 'utf8')
    return edVerify(null, msg, importPub(rawEdPub, 'ed25519'), unb64u(sigB64u))
  } catch {
    return false
  }
}

// ---------- 会话密钥 ----------

export const HKDF_SALT = 'machands-v1'

export function sharedSecret(myRawXPriv, theirRawXPub) {
  return diffieHellman({
    privateKey: importPriv(myRawXPriv, 'x25519'),
    publicKey: importPub(theirRawXPub, 'x25519'),
  })
}

export function sessionInfo(macId, agentId) {
  return [macId, agentId].sort().join('|')
}

export function deriveKey(myRawXPriv, theirRawXPub, macId, agentId) {
  const ss = sharedSecret(myRawXPriv, theirRawXPub)
  const out = hkdfSync('sha256', ss, Buffer.from(HKDF_SALT, 'utf8'), Buffer.from(sessionInfo(macId, agentId), 'utf8'), 32)
  return Buffer.from(out)
}

// ---------- 帧 ----------

export const DIR_M2A = 'm2a' // Mac → agent
export const DIR_A2M = 'a2m' // agent → Mac

export function makeNonce(dir, counter) {
  if (dir !== DIR_M2A && dir !== DIR_A2M) throw new Error('方向标记只能是 m2a 或 a2m')
  const nonce = Buffer.alloc(12)
  // 前 4 字节:方向标记 ASCII,不足 4 字节补 0x00
  nonce.write(dir, 0, 'ascii')
  // 后 8 字节:大端计数器
  nonce.writeBigUInt64BE(BigInt(counter), 4)
  return nonce
}

export function nonceDir(nonce) {
  return Buffer.from(nonce).subarray(0, 4).toString('ascii').replace(/\0+$/, '')
}

export function nonceCounter(nonce) {
  return Buffer.from(nonce).readBigUInt64BE(4)
}

export function aadFor(from, to) {
  return Buffer.from(`${from}>${to}`, 'utf8')
}

// 加密一帧:body = base64url(nonce ‖ ct ‖ tag)
export function seal(key, dir, counter, plaintext, from, to) {
  const nonce = makeNonce(dir, counter)
  const cipher = createCipheriv('chacha20-poly1305', key, nonce, { authTagLength: 16 })
  cipher.setAAD(aadFor(from, to))
  const ct = Buffer.concat([cipher.update(Buffer.from(plaintext)), cipher.final()])
  return b64u(Buffer.concat([nonce, ct, cipher.getAuthTag()]))
}

// 解密一帧,返回 { dir, counter, plaintext }
export function openFrame(key, body, from, to) {
  const raw = typeof body === 'string' ? unb64u(body) : Buffer.from(body)
  if (raw.length < 12 + 16) throw new Error('帧太短')
  const nonce = raw.subarray(0, 12)
  const tag = raw.subarray(raw.length - 16)
  const ct = raw.subarray(12, raw.length - 16)
  const decipher = createDecipheriv('chacha20-poly1305', key, nonce, { authTagLength: 16 })
  decipher.setAAD(aadFor(from, to))
  decipher.setAuthTag(tag)
  const plaintext = Buffer.concat([decipher.update(ct), decipher.final()])
  return { dir: nonceDir(nonce), counter: nonceCounter(nonce), plaintext }
}

export function sealJSON(key, dir, counter, obj, from, to) {
  return seal(key, dir, counter, Buffer.from(JSON.stringify(obj), 'utf8'), from, to)
}

export function openJSON(key, body, from, to) {
  const f = openFrame(key, body, from, to)
  return { ...f, msg: JSON.parse(f.plaintext.toString('utf8')) }
}

// ---------- 配对码 · SPEC §3 ----------
// MH1.<relayHost>:<port>.<relayPubkey>.<macId>.<macXPub>.<macEdPub>.<token>.<macName>
// 主机名里可能带点(例如 IPv4),所以解析时从尾部数 6 个字段,中间的一律拼回 endpoint。

export function encodePairingCode({ host, port, relayPub, macId, macXPub, macEdPub, token, macName }) {
  return [
    'MH1',
    `${host}:${port}`,
    typeof relayPub === 'string' ? relayPub : b64u(relayPub),
    macId,
    typeof macXPub === 'string' ? macXPub : b64u(macXPub),
    typeof macEdPub === 'string' ? macEdPub : b64u(macEdPub),
    token,
    b64u(Buffer.from(macName, 'utf8')),
  ].join('.')
}

export function parsePairingCode(code) {
  const text = String(code).trim().replace(/^["']|["']$/g, '')
  const parts = text.split('.')
  if (parts.length < 8 || parts[0] !== 'MH1') {
    throw new Error('配对码格式不对:应当以 MH1. 开头,并且有 8 个字段')
  }
  const tail = parts.slice(-6)
  const endpoint = parts.slice(1, parts.length - 6).join('.')
  const [relayPub, macId, macXPub, macEdPub, token, macNameB64] = tail
  const colon = endpoint.lastIndexOf(':')
  if (colon < 1) throw new Error('配对码里的中继地址应当是 host:port')
  const host = endpoint.slice(0, colon)
  const port = Number(endpoint.slice(colon + 1))
  if (!Number.isInteger(port) || port <= 0 || port > 65535) throw new Error('配对码里的中继端口不合法')
  const macName = unb64u(macNameB64).toString('utf8')
  if (!/^[a-z2-7]{26}$/.test(macId)) throw new Error('配对码里的 macId 不合法')
  if (unb64u(macXPub).length !== 32 || unb64u(macEdPub).length !== 32) throw new Error('配对码里的 Mac 公钥长度不对')
  return { host, port, relayPub, macId, macXPub, macEdPub, token, macName }
}

export function equalBytes(a, b) {
  const x = Buffer.from(a)
  const y = Buffer.from(b)
  return x.length === y.length && timingSafeEqual(x, y)
}

export { randomBytes }
