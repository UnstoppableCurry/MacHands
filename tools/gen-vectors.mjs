#!/usr/bin/env node
// 生成 shared/PROTOCOL-VECTORS.json。
// 私钥是写死的测试用密钥,只用于互通测试,绝不用于真实身份。
// 用法:node tools/gen-vectors.mjs [输出路径]
import { writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import * as C from '../agent/src/crypto.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const out = resolve(process.argv[2] || resolve(here, '../shared/PROTOCOL-VECTORS.json'))

// 私钥 = SHA-256(标签),写死且可复现。
const { createHash, createPublicKey } = await import('node:crypto')
function kp(kind, label) {
  const priv = createHash('sha256').update(label, 'utf8').digest()
  const pub = C.rawPub(createPublicKey(C.importPriv(priv, kind)))
  return { priv, pub, label }
}

const macX = kp('x25519', 'machands-vector:mac-x25519')
const macEd = kp('ed25519', 'machands-vector:mac-ed25519')
const agentX = kp('x25519', 'machands-vector:agent-x25519')
const agentEd = kp('ed25519', 'machands-vector:agent-ed25519')
const relayEd = kp('ed25519', 'machands-vector:relay-ed25519')

const idOf = (label) => C.b32(createHash('sha256').update(label, 'utf8').digest().subarray(0, 16)).slice(0, 26)
const macId = idOf('machands-vector:mac-id')
const agentId = idOf('machands-vector:agent-id')
const macName = 'Kai 的 MacBook Pro'
const agentName = 'Claude@vps'

const ss = C.sharedSecret(macX.priv, agentX.pub)
const ssCheck = C.sharedSecret(agentX.priv, macX.pub)
if (!ss.equals(ssCheck)) throw new Error('X25519 双向共享密钥不一致')
const key = C.deriveKey(agentX.priv, macX.pub, macId, agentId)

function frame(dir, counter, obj) {
  const from = dir === C.DIR_A2M ? agentId : macId
  const to = dir === C.DIR_A2M ? macId : agentId
  const plaintext = JSON.stringify(obj)
  const body = C.seal(key, dir, counter, Buffer.from(plaintext, 'utf8'), from, to)
  const opened = C.openFrame(key, body, from, to)
  if (opened.plaintext.toString('utf8') !== plaintext) throw new Error('自检失败:密文解不回原文')
  return {
    dir,
    from,
    to,
    counter,
    nonce_hex: C.makeNonce(dir, counter).toString('hex'),
    aad_utf8: `${from}>${to}`,
    plaintext_utf8: plaintext,
    body_base64url: body,
  }
}

const frames = {
  agent_to_mac: [
    frame(C.DIR_A2M, 1, { id: '5b0f3f2e-0b2a-4f6c-9f21-8f2b1c7d4e01', m: 'sys.info', p: {} }),
    frame(C.DIR_A2M, 2, {
      id: '5b0f3f2e-0b2a-4f6c-9f21-8f2b1c7d4e02',
      m: 'run',
      p: { cmd: 'sw_vers', cwd: '~', timeout: 600 },
    }),
    frame(C.DIR_A2M, 3, {
      id: '5b0f3f2e-0b2a-4f6c-9f21-8f2b1c7d4e03',
      m: 'fs.put',
      p: { path: '~/Desktop/hello.txt', data: Buffer.from('你好,MacHands\n', 'utf8').toString('base64') },
    }),
  ],
  mac_to_agent: [
    frame(C.DIR_M2A, 1, {
      id: '5b0f3f2e-0b2a-4f6c-9f21-8f2b1c7d4e01',
      r: { name: macName, model: 'Mac15,7', os: 'macOS 15.5', arch: 'arm64', user: 'kai' },
    }),
    frame(C.DIR_M2A, 2, { id: '5b0f3f2e-0b2a-4f6c-9f21-8f2b1c7d4e02', s: { o: 'ProductName:\t\tmacOS\n' } }),
    frame(C.DIR_M2A, 3, { id: '5b0f3f2e-0b2a-4f6c-9f21-8f2b1c7d4e02', r: { code: 0, ms: 42 } }),
  ],
}

// auth 握手签名向量(SPEC §4.1:sig 签 {id, nonce, ts})
function authVector(who, edKey, xKey, id, name, nonceB64u, ts, role) {
  const payload = { id, nonce: nonceB64u, ts }
  const canonical = C.canonicalJSON(payload)
  const sig = C.signPayload(edKey.priv, payload)
  if (!C.verifyPayload(edKey.pub, payload, sig)) throw new Error('自检失败:签名验不过')
  return {
    who,
    auth_message: {
      t: 'auth',
      role,
      id,
      edPub: C.b64u(edKey.pub),
      xPub: C.b64u(xKey.pub),
      name,
      sig,
    },
    signed_payload: payload,
    canonical_json_utf8: canonical,
    signature_base64url: sig,
  }
}

const nonce1 = C.b64u(Buffer.from('0123456789abcdef0123456789abcdef', 'utf8'))
const nonce2 = C.b64u(Buffer.from('fedcba9876543210fedcba9876543210', 'utf8'))

const pairingToken = C.b64u(Buffer.from('machands-token01', 'utf8'))
const pairing_code = C.encodePairingCode({
  host: '134.199.230.126',
  port: 8443,
  relayPub: C.b64u(relayEd.pub),
  macId,
  macXPub: C.b64u(macX.pub),
  macEdPub: C.b64u(macEd.pub),
  token: pairingToken,
  macName,
})
const decoded = C.parsePairingCode(pairing_code)

const vectors = {
  _doc: {
    version: 1,
    生成方式:
      'node tools/gen-vectors.mjs;私钥 = SHA-256(标签) 写死,仅用于测试互通,绝不作为真实身份。',
    编码: '除非字段名以 _hex 结尾,所有二进制字段都是 base64url 无填充(RFC 4648 §5,去掉 =)。',
    id: 'macId / agentId 是 16 字节随机数的 base32(小写字母表 abcdefghijklmnopqrstuvwxyz234567,无填充)前 26 个字符。',
    x25519: '原始私钥/公钥都是 32 字节。Node 侧用 PKCS8/SPKI 前缀包一层,CryptoKit 侧直接用 rawRepresentation。',
    共享密钥: 'ss = X25519(myPriv, theirPub),32 字节;两端算出来必须一致。',
    会话密钥: 'key = HKDF-SHA256(ikm = ss, salt = utf8("machands-v1"), info = utf8([macId, agentId].sort().join("|")), L = 32)。注意 salt 是 HKDF-Extract 的 salt,info 是 Expand 的 info。',
    nonce: '12 字节 = 前 4 字节方向标记 + 后 8 字节大端无符号计数器。方向标记是 "a2m"(agent→Mac)或 "m2a"(Mac→agent)的 ASCII,只有 3 字节,第 4 字节补 0x00。',
    计数器:
      '发送方:counter = max(上一帧 + 1, 毫秒时间戳 × 1000 + 0..999 的随机数)。不要每个进程都从 1 重新开始——同一把会话密钥下 nonce 重复会直接毁掉 ChaCha20-Poly1305,而且接收方会把新进程的第一帧当成重放。CLI 每次调用都是新进程,Mac 端 App 重启同理。本文件里的示例帧用 1/2/3 只是为了给出稳定的测试向量。',
    重放窗口:
      '接收方记住见过的最大计数器 lastIn 和最近 4096 个计数器:counter <= lastIn - 4096 一律丢(太老),已经见过的也丢(重放),其余接受。用窗口而不是死盯最大值,是为了让同一个 agent 可以同时开几条命令。',
    aad: 'utf8(from + ">" + to),from/to 是发送方与接收方的 id。',
    帧: 'body = base64url(nonce ‖ ciphertext ‖ tag16)。算法 ChaCha20-Poly1305(IETF,12 字节 nonce,16 字节 tag)。CryptoKit 的 ChaChaPoly.seal 输出 combined = nonce ‖ ct ‖ tag,与本格式逐字节相同。',
    签名: 'sig = base64url(Ed25519.sign(edPriv, utf8(canonicalJSON(payload))));canonicalJSON = 键按字典序升序、无空白、字符串按 JSON 转义。',
    握手: 'relay 在 hello 里给 32 字节随机 nonce(base64url);客户端签 {id, nonce, ts} 三个键。ts 是毫秒时间戳整数。',
    配对码:
      'MH1.<relayHost>:<port>.<relayPubkey>.<macId>.<macXPub>.<macEdPub>.<token>.<base64url(utf8(macName))>,字段用 "." 分隔。主机名里可能带点(IPv4),所以解析时从尾部数 6 个字段,第 1 个字段之后、尾部 6 个字段之前的一律拼回 host:port。',
  },
  relay: {
    ed25519_priv: C.b64u(relayEd.priv),
    ed25519_pub: C.b64u(relayEd.pub),
  },
  mac: {
    id: macId,
    name: macName,
    x25519_priv: C.b64u(macX.priv),
    x25519_pub: C.b64u(macX.pub),
    ed25519_priv: C.b64u(macEd.priv),
    ed25519_pub: C.b64u(macEd.pub),
  },
  agent: {
    id: agentId,
    name: agentName,
    x25519_priv: C.b64u(agentX.priv),
    x25519_pub: C.b64u(agentX.pub),
    ed25519_priv: C.b64u(agentEd.priv),
    ed25519_pub: C.b64u(agentEd.pub),
  },
  session: {
    hkdf_salt_utf8: C.HKDF_SALT,
    hkdf_info_utf8: C.sessionInfo(macId, agentId),
    shared_secret_hex: ss.toString('hex'),
    key_hex: key.toString('hex'),
    key_base64url: C.b64u(key),
  },
  frames,
  auth: [
    authVector('agent', agentEd, agentX, agentId, agentName, nonce1, 1756800000000, 'agent'),
    authVector('mac', macEd, macX, macId, macName, nonce2, 1756800001000, 'mac'),
  ],
  canonical_json: [
    { value: { b: 1, a: 2 }, canonical: C.canonicalJSON({ b: 1, a: 2 }) },
    {
      value: { z: [3, { y: 1, x: 2 }], nested: { k: '值', n: null, t: true } },
      canonical: C.canonicalJSON({ z: [3, { y: 1, x: 2 }], nested: { k: '值', n: null, t: true } }),
    },
  ],
  pairing: {
    code: pairing_code,
    decoded,
    token_ttl_seconds: 600,
    clipboard_block: [
      '把下面这一行在你的机器上执行,然后告诉我结果:',
      '',
      `npx -y machands@latest pair "${pairing_code}"`,
      '',
      '(这是 MacHands 配对码,10 分钟内有效,只能用一次。)',
      '',
    ].join('\n'),
  },
}

writeFileSync(out, JSON.stringify(vectors, null, 2) + '\n')
console.log('已写入 ' + out)
