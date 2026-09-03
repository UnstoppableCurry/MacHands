// MCP 服务器:协议帧 + 真的调用一次工具(中继 + 假 Mac 都是真的)。
import test from 'node:test'
import assert from 'node:assert/strict'
import { join } from 'node:path'
import { PassThrough } from 'node:stream'
import { handleRPC, callTool, TOOLS, PROTOCOL_VERSION, serveMCP } from '../src/mcp.mjs'
import { cli, setupRig } from './helpers.mjs'

test('MCP:initialize / tools/list / ping 的帧都对', async () => {
  const init = await handleRPC({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} })
  assert.equal(init.jsonrpc, '2.0')
  assert.equal(init.id, 1)
  assert.equal(init.result.protocolVersion, PROTOCOL_VERSION)
  assert.equal(PROTOCOL_VERSION, '2025-06-18')
  assert.equal(init.result.serverInfo.name, 'machands')
  assert.ok(init.result.capabilities.tools)

  assert.equal(await handleRPC({ jsonrpc: '2.0', method: 'notifications/initialized' }), null)
  assert.deepEqual((await handleRPC({ jsonrpc: '2.0', id: 2, method: 'ping' })).result, {})

  const list = await handleRPC({ jsonrpc: '2.0', id: 3, method: 'tools/list' })
  const names = list.result.tools.map((x) => x.name)
  for (const want of [
    'mac_info',
    'mac_run',
    'mac_put',
    'mac_get',
    'mac_ls',
    'mac_screenshot',
    'mac_open',
    'mac_clipboard_get',
    'mac_clipboard_set',
    'mac_notify',
    'mac_list',
  ]) {
    assert.ok(names.includes(want), '缺工具 ' + want)
  }
  for (const tool of TOOLS) {
    assert.equal(typeof tool.description, 'string')
    assert.equal(tool.inputSchema.type, 'object')
  }

  const bad = await handleRPC({ jsonrpc: '2.0', id: 4, method: '没有这个' })
  assert.equal(bad.error.code, -32601)
})

test('MCP:stdio 一行一条,回的也是一行一条', async () => {
  const input = new PassThrough()
  const chunks = []
  const output = { write: (s) => chunks.push(s) }
  const done = serveMCP({ input, output })
  input.write(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize' }) + '\n')
  input.write('{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n')
  input.write('不是 JSON\n')
  input.end()
  await done
  await new Promise((r) => setTimeout(r, 50))
  const lines = chunks.join('').trim().split('\n').map((l) => JSON.parse(l))
  assert.equal(lines.length, 3)
  assert.equal(lines[0].result.protocolVersion, PROTOCOL_VERSION)
  assert.equal(lines[1].result.tools.length, TOOLS.length)
  assert.equal(lines[2].error.code, -32700)
})

test('MCP:真的调用 mac_run / mac_put / mac_get / mac_screenshot', async (t) => {
  const { mac, env, agentHome, work } = await setupRig(t)

  // 先用真 CLI 配对,然后让 MCP 工具用同一个 ~/.machands
  const paired = await cli(['pair', mac.code], env)
  assert.equal(paired.code, 0, paired.out + paired.err)
  const oldHome = process.env.MACHANDS_HOME
  process.env.MACHANDS_HOME = agentHome
  t.after(() => {
    process.env.MACHANDS_HOME = oldHome
  })

  const list = await callTool('mac_list', {})
  assert.match(list.content[0].text, /测试 Mac/)

  const run = await callTool('mac_run', { cmd: 'echo mcp-ok' })
  assert.equal(run.isError, undefined)
  assert.match(run.content[0].text, /mcp-ok/)
  assert.match(run.content[0].text, /退出码 0/)

  const failed = await callTool('mac_run', { cmd: 'exit 3' })
  assert.equal(failed.isError, true)
  assert.match(failed.content[0].text, /退出码 3/)

  const file = join(work, 'mcp.txt')
  await callTool('mac_put', { path: file, content: '来自 MCP 的一行字' })
  const got = await callTool('mac_get', { path: file })
  assert.equal(got.content[0].text, '来自 MCP 的一行字')

  const shot = await callTool('mac_screenshot', {})
  assert.equal(shot.content[0].type, 'image')
  assert.equal(shot.content[0].mimeType, 'image/png')
  assert.equal(Buffer.from(shot.content[0].data, 'base64').subarray(1, 4).toString('ascii'), 'PNG')

  await callTool('mac_clipboard_set', { text: 'mcp 剪贴板' })
  assert.equal(mac.getClipboard(), 'mcp 剪贴板')
  const clip = await callTool('mac_clipboard_get', {})
  assert.equal(clip.content[0].text, 'mcp 剪贴板')

  await callTool('mac_notify', { title: '来自 agent', body: '干完了' })
  assert.ok(mac.log.some((x) => x.notify?.title === '来自 agent'))

  const ls = await callTool('mac_ls', { path: work })
  assert.match(ls.content[0].text, /mcp\.txt/)
})
