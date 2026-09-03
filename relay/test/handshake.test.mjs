import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { startRelay, newIdentity, RawClient } from './helpers.mjs'
import { b64u, unb64u, genEd25519, signPayload, verifyPayload } from '../../agent/src/crypto.mjs'

test('握手:hello 带中继身份和随机 nonce,签名验得过', async (t) => {
  const env = await startRelay()
  t.after(() => env.stop())
  const c = new RawClient(env.url('agent'))
  await c.open()
  const hello = await c.until('hello')
  assert.equal(hello.ver, 1)
  assert.equal(hello.relayId, env.relay.relayId)
  assert.equal(unb64u(hello.nonce).length, 32)
  assert.ok(verifyPayload(env.relay.relayPub, { nonce: hello.nonce, relayId: hello.relayId, ts: hello.ts }, hello.sig))
  c.close()
})

test('握手:签名对了给 ok,签名错了给 BAD_SIG', async (t) => {
  const env = await startRelay()
  t.after(() => env.stop())

  const me = newIdentity('agent-1')
  const a = new RawClient(env.url('agent'))
  const { reply } = await a.auth(me, 'agent')
  assert.equal(reply.t, 'ok')
  assert.equal(reply.id, me.id)
  a.close()

  const bad = new RawClient(env.url('agent'))
  await bad.open()
  const hello = await bad.until('hello')
  const other = newIdentity('骗子')
  bad.send({
    t: 'auth',
    role: 'agent',
    id: other.id,
    edPub: b64u(other.ed.pub),
    xPub: b64u(other.x.pub),
    name: 'x',
    ts: Date.now(),
    sig: signPayload(other.ed.priv, { id: other.id, nonce: 'ZmFrZQ', ts: 1 }),
  })
  const err = await bad.next()
  assert.equal(err.t, 'err')
  assert.equal(err.code, 'BAD_SIG')
  bad.close()
})

test('握手:同一个 id 换了签名密钥就拒(id ↔ edPub 绑定)', async (t) => {
  const env = await startRelay()
  t.after(() => env.stop())

  const me = newIdentity('agent-1')
  const first = new RawClient(env.url('agent'))
  assert.equal((await first.auth(me, 'agent')).reply.t, 'ok')
  first.close()

  const stolen = { ...me, ed: genEd25519() }
  const second = new RawClient(env.url('agent'))
  const { reply } = await second.auth(stolen, 'agent')
  assert.equal(reply.t, 'err')
  assert.equal(reply.code, 'BAD_SIG')
  second.close()

  const ids = JSON.parse(readFileSync(join(env.dataDir, 'ids.json'), 'utf8'))
  assert.equal(ids[me.id].edPub, b64u(me.ed.pub))
})

test('握手:时间戳偏太多也拒', async (t) => {
  const env = await startRelay()
  t.after(() => env.stop())
  const me = newIdentity('agent-1')
  const c = new RawClient(env.url('agent'))
  const { reply } = await c.auth(me, 'agent', { ts: Date.now() - 3_600_000 })
  assert.equal(reply.code, 'BAD_SIG')
  c.close()
})

test('没 auth 就发别的消息 → BAD_SIG', async (t) => {
  const env = await startRelay()
  t.after(() => env.stop())
  const c = new RawClient(env.url('agent'))
  await c.open()
  await c.until('hello')
  c.send({ t: 'send', to: 'x', body: 'y' })
  const err = await c.next()
  assert.equal(err.code, 'BAD_SIG')
  c.close()
})

test('/health 和 /install 是活的', async (t) => {
  const env = await startRelay()
  t.after(() => env.stop())
  const health = await fetch(`http://127.0.0.1:${env.port}/health`).then((r) => r.json())
  assert.equal(health.ok, true)
  assert.equal(health.relayId, env.relay.relayId)
  const install = await fetch(`http://127.0.0.1:${env.port}/install`)
  assert.equal(install.status, 200)
  const body = await install.text()
  assert.match(body, /machands/)
  assert.match(install.headers.get('content-type') || '', /shellscript/)
})

test('中继密钥第一次启动就生成,并且是 0600', async (t) => {
  const env = await startRelay()
  t.after(() => env.stop())
  const { statSync } = await import('node:fs')
  const st = statSync(join(env.dataDir, 'relay.key'))
  assert.equal(st.mode & 0o777, 0o600)
})
