// v0.2 测试的公共小件:能给假 Mac 传额外选项的 rig、配对好的 rig、几个断言用的常量。
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createRelay } from '../../relay/server.mjs'
import { startFakeMac } from './fake-mac.mjs'
import { cli, setupRig } from './helpers.mjs'

export const HEX10 = /^[a-f0-9]{10}$/
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// 与 helpers.setupRig 一样,只是把 extra(perms 等)原样传给假 Mac
export async function setupRigWith(t, extra = {}) {
  const dataDir = mkdtempSync(join(tmpdir(), 'machands-t-relay-'))
  const macHome = mkdtempSync(join(tmpdir(), 'machands-t-mac-'))
  const agentHome = mkdtempSync(join(tmpdir(), 'machands-t-agent-'))
  const work = mkdtempSync(join(tmpdir(), 'machands-t-work-'))
  const relay = createRelay({ dataDir, host: '127.0.0.1', port: 0, quiet: true })
  await relay.listen(0, '127.0.0.1')
  const port = relay.address().port
  const mac = await startFakeMac({
    relay: `127.0.0.1:${port}`,
    name: extra.name || '测试 Mac',
    home: macHome,
    auto: extra.auto !== false,
    deny: Boolean(extra.deny),
    ...extra,
  })
  const env = { MACHANDS_HOME: agentHome, MACHANDS_LANG: 'zh' }
  t.after(async () => {
    mac.close()
    await relay.close()
    for (const d of [dataDir, macHome, agentHome, work]) rmSync(d, { recursive: true, force: true })
  })
  return { relay, port, mac, env, agentHome, work, dataDir }
}

// 起好中继 + 假 Mac,并用真 CLI 配对完
export async function pairedRig(t, extra) {
  const rig = extra ? await setupRigWith(t, extra) : await setupRig(t)
  const paired = await cli(['pair', rig.mac.code], rig.env)
  assert.equal(paired.code, 0, paired.out + paired.err)
  return rig
}

// MCP 的 callTool 走 process.env.MACHANDS_HOME,用完还回去
export function useAgentHome(t, agentHome) {
  const old = process.env.MACHANDS_HOME
  process.env.MACHANDS_HOME = agentHome
  t.after(() => {
    if (old === undefined) delete process.env.MACHANDS_HOME
    else process.env.MACHANDS_HOME = old
  })
}

// mac_job_result 的文本是 "JSON\n--- stdout ---\n…",只取 JSON 那段
export const firstJSON = (text) => JSON.parse(text.split('\n---')[0])
// CLI --json 可能给数组,也可能给 {rows|jobs|servers:[…]},两种都认
export const jsonList = (j, key) => (Array.isArray(j) ? j : j[key])
