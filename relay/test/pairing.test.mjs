import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { startRelay, newIdentity, RawClient, wait } from './helpers.mjs'
import { newToken } from '../../agent/src/crypto.mjs'

async function pairUp(env, { allow = true } = {}) {
  const macIdent = newIdentity('测试 Mac')
  const agentIdent = newIdentity('Claude@vps')
  const mac = new RawClient(env.url('mac'))
  const agent = new RawClient(env.url('agent'))
  assert.equal((await mac.auth(macIdent, 'mac')).reply.t, 'ok')
  assert.equal((await agent.auth(agentIdent, 'agent')).reply.t, 'ok')

  const token = newToken()
  mac.send({ t: 'pair.open', token, ttl: 600 })
  await mac.until('pair.opened')

  agent.send({ t: 'pair.claim', token, macId: macIdent.id })
  const req = await mac.until('pair.request')
  mac.send({ t: 'pair.decide', agentId: req.agentId, allow })
  const result = await agent.until('pair.result')
  return { mac, agent, macIdent, agentIdent, token, req, result }
}

test('配对:正常一条龙,relay 记下配对关系', async (t) => {
  const env = await startRelay()
  t.after(() => env.stop())
  const { mac, agent, macIdent, agentIdent, req, result } = await pairUp(env)
  assert.equal(req.agentName, 'Claude@vps')
  assert.ok(req.agentXPub && req.agentEdPub)
  assert.equal(result.ok, true)
  assert.equal(result.macId, macIdent.id)
  assert.equal(result.macName, '测试 Mac')
  const pairs = JSON.parse(readFileSync(join(env.dataDir, 'pairs.json'), 'utf8'))
  assert.deepEqual(pairs[macIdent.id], [agentIdent.id])
  mac.close()
  agent.close()
})

test('配对:Mac 拒绝 → DENIED,不写配对关系', async (t) => {
  const env = await startRelay()
  t.after(() => env.stop())
  const { mac, agent, macIdent, result } = await pairUp(env, { allow: false })
  assert.equal(result.ok, false)
  assert.equal(result.code, 'DENIED')
  assert.equal(env.relay.pairs[macIdent.id], undefined)
  mac.close()
  agent.close()
})

test('配对:token 过期 → EXPIRED,不打扰 Mac', async (t) => {
  const env = await startRelay()
  t.after(() => env.stop())
  const macIdent = newIdentity('测试 Mac')
  const agentIdent = newIdentity('Claude@vps')
  const mac = new RawClient(env.url('mac'))
  const agent = new RawClient(env.url('agent'))
  await mac.auth(macIdent, 'mac')
  await agent.auth(agentIdent, 'agent')

  const token = newToken()
  mac.send({ t: 'pair.open', token, ttl: 600 })
  await mac.until('pair.opened')
  env.relay.tokens.get(token).exp = Date.now() - 1 // 时间往前拨

  agent.send({ t: 'pair.claim', token, macId: macIdent.id })
  const result = await agent.until('pair.result')
  assert.equal(result.ok, false)
  assert.equal(result.code, 'EXPIRED')
  mac.close()
  agent.close()
})

test('配对:token 只能用一次,第二次 USED', async (t) => {
  const env = await startRelay()
  t.after(() => env.stop())
  const { mac, agent, macIdent, token } = await pairUp(env)

  const second = new RawClient(env.url('agent'))
  await second.auth(newIdentity('另一个 agent'), 'agent')
  second.send({ t: 'pair.claim', token, macId: macIdent.id })
  const result = await second.until('pair.result')
  assert.equal(result.ok, false)
  assert.equal(result.code, 'USED')
  mac.close()
  agent.close()
  second.close()
})

test('配对:没见过的 token → EXPIRED', async (t) => {
  const env = await startRelay()
  t.after(() => env.stop())
  const agent = new RawClient(env.url('agent'))
  await agent.auth(newIdentity('Claude@vps'), 'agent')
  agent.send({ t: 'pair.claim', token: newToken(), macId: 'aaaaaaaaaaaaaaaaaaaaaaaaaa' })
  const result = await agent.until('pair.result')
  assert.equal(result.code, 'EXPIRED')
  agent.close()
})

test('配对:Mac 不在线 → OFFLINE', async (t) => {
  const env = await startRelay()
  t.after(() => env.stop())
  const macIdent = newIdentity('测试 Mac')
  const mac = new RawClient(env.url('mac'))
  await mac.auth(macIdent, 'mac')
  const token = newToken()
  mac.send({ t: 'pair.open', token, ttl: 600 })
  await mac.until('pair.opened')
  mac.close()
  await wait(60)

  const agent = new RawClient(env.url('agent'))
  await agent.auth(newIdentity('Claude@vps'), 'agent')
  agent.send({ t: 'pair.claim', token, macId: macIdent.id })
  const result = await agent.until('pair.result')
  assert.equal(result.code, 'OFFLINE')
  agent.close()
})

test('转发:配对过才转发,没配对就 NOT_PAIRED', async (t) => {
  const env = await startRelay()
  t.after(() => env.stop())

  const macIdent = newIdentity('测试 Mac')
  const strangerIdent = newIdentity('陌生 agent')
  const mac = new RawClient(env.url('mac'))
  const stranger = new RawClient(env.url('agent'))
  await mac.auth(macIdent, 'mac')
  await stranger.auth(strangerIdent, 'agent')

  stranger.send({ t: 'send', to: macIdent.id, body: 'AAAA', n: 1 })
  const err = await stranger.until('err')
  assert.equal(err.code, 'NOT_PAIRED')
  assert.equal(err.to, macIdent.id)
  mac.close()
  stranger.close()
})

test('转发:配对后原样转发密文,并且给出 presence', async (t) => {
  const env = await startRelay()
  t.after(() => env.stop())
  const { mac, agent, macIdent, agentIdent } = await pairUp(env)

  const presence = await agent.until('presence')
  assert.equal(presence.id, macIdent.id)
  assert.equal(presence.online, true)

  agent.send({ t: 'send', to: macIdent.id, body: 'aGVsbG8', n: 1 })
  const got = await mac.until('recv')
  assert.equal(got.from, agentIdent.id)
  assert.equal(got.body, 'aGVsbG8')
  assert.equal(got.n, 1)

  mac.send({ t: 'send', to: agentIdent.id, body: 'd29ybGQ', n: 1 })
  const back = await agent.until('recv')
  assert.equal(back.from, macIdent.id)
  assert.equal(back.body, 'd29ybGQ')

  mac.close()
  agent.close()
})

test('转发:对端离线 → OFFLINE', async (t) => {
  const env = await startRelay()
  t.after(() => env.stop())
  const { mac, agent, macIdent } = await pairUp(env)
  mac.close()
  await wait(60)
  agent.send({ t: 'send', to: macIdent.id, body: 'AAAA', n: 2 })
  const err = await agent.until('err')
  assert.equal(err.code, 'OFFLINE')
  agent.close()
})

test('撤销:Mac 撤了以后就不再转发', async (t) => {
  const env = await startRelay()
  t.after(() => env.stop())
  const { mac, agent, agentIdent, macIdent } = await pairUp(env)
  mac.send({ t: 'pair.revoke', agentId: agentIdent.id })
  await mac.until('pair.revoked')
  agent.send({ t: 'send', to: macIdent.id, body: 'AAAA', n: 3 })
  const err = await agent.until('err')
  assert.equal(err.code, 'NOT_PAIRED')
  mac.close()
  agent.close()
})

test('限制:超过 1 MiB 的帧不会被转发', async (t) => {
  const env = await startRelay()
  t.after(() => env.stop())
  const { mac, agent, macIdent } = await pairUp(env)
  agent.send({ t: 'send', to: macIdent.id, body: 'A'.repeat(1024 * 1024 + 64), n: 9 })
  await wait(150)
  assert.equal(mac.queue.filter((m) => m.t === 'recv').length, 0)
  mac.close()
  agent.close()
})

test('配对关系重启后还在(pairs.json)', async (t) => {
  const env = await startRelay()
  const { mac, agent, macIdent, agentIdent } = await pairUp(env)
  mac.close()
  agent.close()
  await env.relay.close()

  const { createRelay } = await import('../server.mjs')
  const again = createRelay({ dataDir: env.dataDir, host: '127.0.0.1', port: 0, quiet: true })
  t.after(async () => {
    await again.close()
    await env.stop()
  })
  assert.deepEqual(again.pairs[macIdent.id], [agentIdent.id])
})
