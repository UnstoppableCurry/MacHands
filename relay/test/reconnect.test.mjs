// 客户端断线重连 + 中继身份 pin
import test from 'node:test'
import assert from 'node:assert/strict'
import { startRelay, newIdentity } from './helpers.mjs'
import { RelayClient } from '../../agent/src/relay.mjs'
import { b64u, genEd25519 } from '../../agent/src/crypto.mjs'

function toClientIdentity(i) {
  return { id: i.id, name: i.name, edPriv: i.ed.priv, edPub: i.ed.pub, xPriv: i.x.priv, xPub: i.x.pub }
}

test('客户端:被中继踢掉之后会自己退避重连', async (t) => {
  const env = await startRelay()
  t.after(() => env.stop())
  const ident = newIdentity('Claude@vps')
  const client = new RelayClient({
    host: '127.0.0.1',
    port: env.port,
    role: 'agent',
    identity: toClientIdentity(ident),
    name: ident.name,
    reconnect: true,
  })
  t.after(() => client.close())
  await client.connect()
  assert.equal(client.ready, true)

  const readyAgain = new Promise((res) => client.once('ready', res))
  const reconnecting = new Promise((res) => client.once('reconnecting', res))
  env.relay.live.get(ident.id).ws.close() // 中继那边把连接掐了

  const info = await reconnecting
  assert.ok(info.wait > 0 && info.wait < 2000, '第一次重连要很快')
  await readyAgain
  assert.equal(client.ready, true)
  assert.equal(env.relay.live.has(ident.id), true)
})

test('客户端:中继公钥对不上就断开,不把身份交出去', async (t) => {
  const env = await startRelay()
  t.after(() => env.stop())
  const ident = newIdentity('Claude@vps')
  const client = new RelayClient({
    host: '127.0.0.1',
    port: env.port,
    role: 'agent',
    identity: toClientIdentity(ident),
    name: ident.name,
    relayPub: b64u(genEd25519().pub), // pin 了另一把公钥
    reconnect: false,
  })
  await assert.rejects(client.connect(), /中继身份|签名/)
  assert.equal(env.relay.live.has(ident.id), false)
  assert.equal(env.relay.ids[ident.id], undefined)
  client.close()
})

test('客户端:pin 对了就正常连上', async (t) => {
  const env = await startRelay()
  t.after(() => env.stop())
  const ident = newIdentity('Claude@vps')
  const client = new RelayClient({
    host: '127.0.0.1',
    port: env.port,
    role: 'agent',
    identity: toClientIdentity(ident),
    name: ident.name,
    relayPub: env.relay.relayId,
    reconnect: false,
  })
  t.after(() => client.close())
  await client.connect()
  assert.equal(client.ready, true)
  assert.equal(client.relayId, env.relay.relayId)
})
