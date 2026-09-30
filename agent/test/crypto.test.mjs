import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import * as C from '../src/crypto.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const V = JSON.parse(readFileSync(join(HERE, '../../shared/PROTOCOL-VECTORS.json'), 'utf8'))

test('向量:X25519 + HKDF 两端算出同一把会话密钥', () => {
  const macPriv = C.unb64u(V.mac.x25519_priv)
  const agentPriv = C.unb64u(V.agent.x25519_priv)
  const macPub = C.unb64u(V.mac.x25519_pub)
  const agentPub = C.unb64u(V.agent.x25519_pub)

  const ssA = C.sharedSecret(macPriv, agentPub)
  const ssB = C.sharedSecret(agentPriv, macPub)
  assert.equal(ssA.toString('hex'), ssB.toString('hex'))
  assert.equal(ssA.toString('hex'), V.session.shared_secret_hex)

  const k1 = C.deriveKey(macPriv, agentPub, V.mac.id, V.agent.id)
  const k2 = C.deriveKey(agentPriv, macPub, V.mac.id, V.agent.id)
  assert.equal(k1.toString('hex'), V.session.key_hex)
  assert.equal(k2.toString('hex'), V.session.key_hex)
  assert.equal(C.sessionInfo(V.mac.id, V.agent.id), V.session.hkdf_info_utf8)
  // 换个参数顺序算出来必须一样(info 是排过序的)
  assert.equal(C.sessionInfo(V.agent.id, V.mac.id), V.session.hkdf_info_utf8)
})

test('向量:每一帧都能解回原文,nonce 和 aad 都对得上', () => {
  const key = Buffer.from(V.session.key_hex, 'hex')
  for (const list of [V.frames.agent_to_mac, V.frames.mac_to_agent]) {
    for (const f of list) {
      const got = C.openFrame(key, f.body_base64url, f.from, f.to)
      assert.equal(got.plaintext.toString('utf8'), f.plaintext_utf8)
      assert.equal(got.dir, f.dir)
      assert.equal(Number(got.counter), f.counter)
      assert.equal(C.makeNonce(f.dir, f.counter).toString('hex'), f.nonce_hex)
      assert.equal(C.aadFor(f.from, f.to).toString('utf8'), f.aad_utf8)
      // 自己封一遍必须逐字节一样
      assert.equal(C.seal(key, f.dir, f.counter, Buffer.from(f.plaintext_utf8, 'utf8'), f.from, f.to), f.body_base64url)
    }
  }
})

test('帧:aad 不对就解不开', () => {
  const key = Buffer.from(V.session.key_hex, 'hex')
  const f = V.frames.agent_to_mac[0]
  assert.throws(() => C.openFrame(key, f.body_base64url, f.to, f.from))
})

test('帧:改一个字节就解不开', () => {
  const key = Buffer.from(V.session.key_hex, 'hex')
  const f = V.frames.agent_to_mac[1]
  const raw = C.unb64u(f.body_base64url)
  raw[20] ^= 1
  assert.throws(() => C.openFrame(key, C.b64u(raw), f.from, f.to))
})

test('向量:auth 签名验得过,签名内容就是 canonicalJSON', () => {
  for (const a of V.auth) {
    const edPub = C.unb64u(a.auth_message.edPub)
    assert.equal(C.canonicalJSON(a.signed_payload), a.canonical_json_utf8)
    assert.ok(C.verifyPayload(edPub, a.signed_payload, a.signature_base64url))
    assert.equal(C.signPayload(C.unb64u(a.who === 'mac' ? V.mac.ed25519_priv : V.agent.ed25519_priv), a.signed_payload), a.signature_base64url)
    // 改一个字段就验不过
    assert.equal(C.verifyPayload(edPub, { ...a.signed_payload, ts: a.signed_payload.ts + 1 }, a.signature_base64url), false)
  }
})

test('canonicalJSON:键按字典序、无空白、嵌套也一样', () => {
  assert.equal(C.canonicalJSON({ b: 1, a: 2 }), '{"a":2,"b":1}')
  assert.equal(C.canonicalJSON({ a: [3, { y: 1, x: 2 }] }), '{"a":[3,{"x":2,"y":1}]}')
  assert.equal(C.canonicalJSON({ z: null, a: true }), '{"a":true,"z":null}')
  assert.equal(C.canonicalJSON({ u: '中文"引号' }), '{"u":"中文\\"引号"}')
  assert.equal(C.canonicalJSON({ a: 1, b: undefined }), '{"a":1}')
  for (const c of V.canonical_json) assert.equal(C.canonicalJSON(c.value), c.canonical)
})

test('base64url 无填充,能来回转', () => {
  for (const s of ['', 'a', 'ab', 'abc', '中文一句话', '\u0000\u00ff']) {
    const buf = Buffer.from(s, 'utf8')
    const enc = C.b64u(buf)
    assert.ok(!enc.includes('='), '不该有填充')
    assert.ok(!/[+/]/.test(enc), '不该有 + 或 /')
    assert.equal(C.unb64u(enc).toString('utf8'), s)
  }
})

test('id 是 26 个字符的小写 base32', () => {
  for (let i = 0; i < 20; i++) assert.match(C.newId(), /^[a-z2-7]{26}$/)
  assert.equal(C.b32(Buffer.from([0, 0, 0, 0, 0])), 'aaaaaaaa')
  assert.equal(C.b32(Buffer.from([255, 255, 255, 255, 255])), '77777777')
})

test('向量:配对码解出来和登记的一致', () => {
  const p = C.parsePairingCode(V.pairing.code)
  assert.deepEqual(p, V.pairing.decoded)
  assert.equal(p.host, '192.0.2.1') // 主机名里带点也要解得对
  assert.equal(p.port, 8443)
  assert.equal(p.macName, V.mac.name)
  assert.equal(p.macId, V.mac.id)
  assert.equal(C.encodePairingCode({ ...p, relayPub: p.relayPub }), V.pairing.code)
})

test('配对码:坏码给的是人能看懂的错', () => {
  assert.throws(() => C.parsePairingCode('随便一段话'), /MH1/)
  assert.throws(() => C.parsePairingCode('MH1.a.b.c'), /MH1/)
  const parts = V.pairing.code.split('.')
  parts[parts.length - 4] = 'AAAA' // 把 macXPub 弄短
  assert.throws(() => C.parsePairingCode(parts.join('.')), /公钥长度/)
})

test('配对码:带引号或前后空格也认', () => {
  const p = C.parsePairingCode(`  "${V.pairing.code}"  `)
  assert.equal(p.macId, V.mac.id)
})
