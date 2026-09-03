// 许可证签发与校验 · SPEC §7.5
import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, readFileSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { makeLicense, main as signMain } from '../../tools/license/sign.mjs'
import { verifyLicense, main as verifyMain, OK, EXPIRED, BAD } from '../../tools/license/verify.mjs'
import { genEd25519, b64u, unb64u } from '../src/crypto.mjs'

test('许可证:签出来能验回去', () => {
  const kp = genEd25519()
  const line = makeLicense(kp.priv, { email: 'kai@example.com', exp: '2099-01-01', seats: 3 })
  assert.match(line, /^MHL1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/)
  const r = verifyLicense(line, kp.pub)
  assert.equal(r.status, OK)
  assert.deepEqual(r.payload, { email: 'kai@example.com', exp: '2099-01-01', seats: 3 })
})

test('许可证:永久证 exp 是 null', () => {
  const kp = genEd25519()
  const r = verifyLicense(makeLicense(kp.priv, { email: 'a@b.c' }), kp.pub)
  assert.equal(r.status, OK)
  assert.equal(r.payload.exp, null)
  assert.equal(r.payload.seats, 1)
})

test('许可证:过期的报过期,不是报假', () => {
  const kp = genEd25519()
  const r = verifyLicense(makeLicense(kp.priv, { email: 'a@b.c', exp: '2020-01-01' }), kp.pub)
  assert.equal(r.status, EXPIRED)
  assert.match(r.reason, /过期/)
})

test('许可证:换把公钥、改一个字都验不过', () => {
  const kp = genEd25519()
  const other = genEd25519()
  const line = makeLicense(kp.priv, { email: 'a@b.c', exp: null, seats: 1 })
  assert.equal(verifyLicense(line, other.pub).status, BAD)

  const parts = line.split('.')
  const tampered = JSON.stringify({ email: 'a@b.c', exp: null, seats: 99 })
  assert.equal(verifyLicense(`MHL1.${b64u(Buffer.from(tampered, 'utf8'))}.${parts[2]}`, kp.pub).status, BAD)
  assert.equal(verifyLicense('随便一段话', kp.pub).status, BAD)
  assert.equal(verifyLicense('MHL1.a.b', kp.pub).status, BAD)
})

test('许可证:--gen-key 写到仓库外,权限 0600,不写进仓库', (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'machands-lic-'))
  t.after(() => rmSync(dir, { recursive: true, force: true }))
  const out = []
  const log = console.log
  const errLog = console.error
  console.log = (...a) => out.push(a.join(' '))
  console.error = (...a) => out.push(a.join(' '))
  try {
    const file = join(dir, 'key.json')
    assert.equal(signMain(['--gen-key', file]), 0)
    assert.equal(statSync(file).mode & 0o777, 0o600)
    const kp = JSON.parse(readFileSync(file, 'utf8'))
    assert.equal(unb64u(kp.ed25519_pub).length, 32)
    assert.ok(out.join('\n').includes(`static let licensePublicKey = "${kp.ed25519_pub}"`), ' 要打印能贴进 Swift 的公钥')
    assert.ok(!out.join('\n').includes(kp.ed25519_priv), '绝不能把私钥打出来')

    // 同一个路径再来一次要拒绝,免得把老密钥盖掉
    assert.notEqual(signMain(['--gen-key', file]), 0)
    // 仓库里的路径要拒绝
    assert.notEqual(signMain(['--gen-key', join(process.cwd(), 'tools/license/key.json')]), 0)

    // 签一张再用 verify 的命令行验
    const lic = makeLicense(unb64u(kp.ed25519_priv), { email: 'x@y.z', exp: null, seats: 1 })
    assert.equal(verifyMain([lic, '--pub', kp.ed25519_pub]), OK)
    assert.equal(verifyMain([lic, '--key', file]), OK)
  } finally {
    console.log = log
    console.error = errLog
  }
})
