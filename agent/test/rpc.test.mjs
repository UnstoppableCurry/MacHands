import test from 'node:test'
import assert from 'node:assert/strict'
import { RpcSession, RpcError, ReplayError } from '../src/rpc.mjs'
import { deriveKey, genX25519, newId, DIR_A2M } from '../src/crypto.mjs'

function makePair(handlers) {
  const macId = newId()
  const agentId = newId()
  const macX = genX25519()
  const agentX = genX25519()
  const macKey = deriveKey(macX.priv, agentX.pub, macId, agentId)
  const agentKey = deriveKey(agentX.priv, macX.pub, macId, agentId)
  assert.equal(macKey.toString('hex'), agentKey.toString('hex'))

  const wire = { a2m: [], m2a: [] }
  const mac = new RpcSession({
    key: macKey,
    myId: macId,
    peerId: agentId,
    role: 'mac',
    send: (b) => {
      wire.m2a.push(b)
      agent.onRecv(b)
    },
    handlers,
  })
  const agent = new RpcSession({
    key: agentKey,
    myId: agentId,
    peerId: macId,
    role: 'agent',
    send: (b) => {
      wire.a2m.push(b)
      mac.onRecv(b)
    },
  })
  return { mac, agent, wire, macId, agentId, macKey }
}

test('RPC:请求 → 响应', async () => {
  const { agent } = makePair({ 'sys.info': async () => ({ name: '假 Mac', arch: 'arm64' }) })
  const r = await agent.request('sys.info')
  assert.deepEqual(r, { name: '假 Mac', arch: 'arm64' })
})

test('RPC:流式 + 最后的结果', async () => {
  const { agent } = makePair({
    run: async (p, ctx) => {
      ctx.stream({ o: 'hello ' })
      ctx.stream({ o: p.cmd })
      ctx.stream({ e: '一点点 stderr' })
      return { code: 0, ms: 3 }
    },
  })
  let out = ''
  let err = ''
  const r = await agent.request('run', { cmd: 'world' }, {
    onStream: (s) => {
      if (s.o) out += s.o
      if (s.e) err += s.e
    },
  })
  assert.equal(out, 'hello world')
  assert.equal(err, '一点点 stderr')
  assert.deepEqual(r, { code: 0, ms: 3 })
})

test('RPC:Mac 端抛错就变成带错误码的响应', async () => {
  const { agent } = makePair({
    run: async () => {
      const e = new Error('用户拒绝了')
      e.code = 'DENIED'
      throw e
    },
  })
  await assert.rejects(agent.request('run', { cmd: 'x' }), (err) => {
    assert.ok(err instanceof RpcError)
    assert.equal(err.code, 'DENIED')
    return true
  })
})

test('RPC:没有的方法回 BAD_PARAMS', async () => {
  const { agent } = makePair({})
  await assert.rejects(agent.request('不存在的方法'), (err) => err.code === 'BAD_PARAMS')
})

test('RPC:计数器只增不减,方向标记固定,新进程不会从头来', async () => {
  const t0 = BigInt(Date.now()) * 1000n
  const { agent, wire, macKey, macId, agentId } = makePair({ ping: async () => ({}) })
  await agent.request('ping')
  await agent.request('ping')
  const { openFrame } = await import('../src/crypto.mjs')
  const f1 = openFrame(macKey, wire.a2m[0], agentId, macId)
  const f2 = openFrame(macKey, wire.a2m[1], agentId, macId)
  assert.equal(f1.dir, DIR_A2M)
  assert.ok(f1.counter >= t0, '计数器跟时钟走,不会从 1 重来')
  assert.ok(f2.counter > f1.counter)
})

test('RPC:进程重启(新会话)接着往上走,不会被当成重放', async () => {
  const { agent, mac, macId, agentId } = makePair({ ping: async () => ({}) })
  await agent.request('ping')
  const lastIn = mac.lastIn
  // 同一台 Mac,新起一个 agent 进程:计数器按时钟继续,不会回到 1
  const fresh = new RpcSession({
    key: agent.key,
    myId: agentId,
    peerId: macId,
    role: 'agent',
    send: (b) => mac.onRecv(b),
  })
  await new Promise((r) => setTimeout(r, 3))
  fresh.request('ping', {}, { timeoutMs: 50 }).catch(() => {}) // 回包发给的是上一个会话,这里不等它
  await new Promise((r) => setTimeout(r, 10))
  assert.ok(mac.lastIn > lastIn, '新进程的帧应当被接受')
})

test('RPC:重放同一帧会被拒', async () => {
  const { agent, mac, wire } = makePair({ ping: async () => ({ ok: 1 }) })
  await agent.request('ping')
  const replayed = wire.a2m[0]
  assert.throws(() => mac.onRecv(replayed), (err) => {
    assert.ok(err instanceof ReplayError)
    assert.equal(err.code, 'REPLAY')
    return true
  })
})

test('RPC:计数器回退也会被拒', async () => {
  const { agent, mac, wire } = makePair({ ping: async () => ({}) })
  await agent.request('ping')
  await agent.request('ping')
  assert.throws(() => mac.onRecv(wire.a2m[0]), ReplayError)
})

test('RPC:方向标记反了会被拒', async () => {
  const { mac, wire } = makePair({ ping: async () => ({}) })
  const { sealJSON, DIR_M2A } = await import('../src/crypto.mjs')
  // 用 Mac 自己的方向标记伪造一帧发给 Mac
  const bogus = sealJSON(mac.key, DIR_M2A, 99n, { id: 'x', m: 'ping', p: {} }, mac.peerId, mac.myId)
  assert.throws(() => mac.onRecv(bogus), /方向标记/)
  assert.equal(wire.m2a.length, 0)
})

test('RPC:超时会失败,并且不再占着 id', async () => {
  const { agent } = makePair({ slow: () => new Promise(() => {}) })
  await assert.rejects(agent.request('slow', {}, { timeoutMs: 40 }), (err) => err.code === 'TIMEOUT')
  assert.equal(agent.pending.size, 0)
})

test('RPC:连接断了在飞的请求都失败', async () => {
  const { agent } = makePair({ slow: () => new Promise(() => {}) })
  const p = agent.request('slow', {}, { timeoutMs: 5000 })
  agent.fail(new RpcError('OFFLINE', '断了'))
  await assert.rejects(p, (err) => err.code === 'OFFLINE')
})
