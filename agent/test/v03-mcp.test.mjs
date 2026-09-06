// v0.3 MCP:受审批工具必填 why、why 真的透传、mac_doctor / mac_update / mac_selfshot / mac_show_window。
import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { handleRPC, callTool, TOOLS } from '../src/mcp.mjs'
import { BIN } from './helpers.mjs'
import { pairedRig, useAgentHome } from './v02-helpers.mjs'

const APPROVAL_TOOLS = [
  'mac_run',
  'mac_put',
  'mac_get',
  'mac_screenshot',
  'mac_window_shot',
  'mac_record',
  'mac_input',
  'mac_open',
  'mac_clipboard_set',
  'mac_job_submit',
  'mac_session_open',
  'mac_session_write',
  'mac_mcp_call',
]

const text = (r) => r.content.find((c) => c.type === 'text')?.text ?? ''

test('MCP v0.3:会弹审批卡的工具都必填 why,说明里给了正反例', async () => {
  const list = await handleRPC({ jsonrpc: '2.0', id: 1, method: 'tools/list' })
  const byName = new Map(list.result.tools.map((x) => [x.name, x]))
  for (const name of APPROVAL_TOOLS) {
    const tool = byName.get(name)
    assert.ok(tool, '缺工具 ' + name)
    assert.ok((tool.inputSchema.required || []).includes('why'), `${name} 没把 why 标成必填`)
    assert.match(tool.inputSchema.properties.why.description, /人话/)
    assert.match(tool.inputSchema.properties.why.description, /不要复述命令/)
    assert.match(tool.description, /必须填 why/)
  }
  // 只读、不弹卡的工具不该被强加 why
  assert.ok(!(byName.get('mac_info').inputSchema.required || []).includes('why'))
  assert.ok(!(byName.get('mac_doctor').inputSchema.required || []).includes('why'))
})

test('MCP v0.3:新工具都在,且 initialize 的说明提到 why / doctor / selfshot', async () => {
  const list = await handleRPC({ jsonrpc: '2.0', id: 1, method: 'tools/list' })
  const names = list.result.tools.map((x) => x.name)
  for (const want of ['mac_doctor', 'mac_update', 'mac_selfshot', 'mac_show_window']) {
    assert.ok(names.includes(want), '缺工具 ' + want)
  }
  assert.equal(new Set(names).size, names.length, '工具名重复')
  const init = await handleRPC({ jsonrpc: '2.0', id: 2, method: 'initialize', params: {} })
  const ins = init.result.instructions
  for (const kw of ['why', 'mac_doctor', 'mac_update', 'mac_selfshot']) assert.match(ins, new RegExp(kw))
})

test('MCP v0.3:why 从工具参数一路走到 Mac', async (t) => {
  const rig = await pairedRig(t)
  useAgentHome(t, rig.agentHome)
  const r = await callTool('mac_run', { cmd: 'echo hi', why: '看一眼构建产物在不在' })
  assert.match(text(r), /hi/)
  const call = rig.mac.calls.find((c) => c.m === 'run')
  assert.equal(call.why, '看一眼构建产物在不在')
})

test('MCP v0.3:没填 why 也不报错,只是 Mac 上看不到目的', async (t) => {
  const rig = await pairedRig(t)
  useAgentHome(t, rig.agentHome)
  const r = await callTool('mac_run', { cmd: 'echo hi' })
  assert.equal(r.isError, undefined)
  assert.equal(rig.mac.calls.find((c) => c.m === 'run').why, undefined)
})

test('MCP v0.3:mac_doctor 把"装了多份"讲成人能懂的话', async (t) => {
  const rig = await pairedRig(t, {
    duplicates: ['/Applications/MacHands.app', '/Users/money/Applications/MacHands.app'],
  })
  useAgentHome(t, rig.agentHome)
  const body = text(await callTool('mac_doctor', {}))
  assert.match(body, /不止一份/)
  assert.match(body, /\/Users\/money\/Applications\/MacHands\.app/)
  assert.match(body, /时灵时不灵|不存在/)
})

test('MCP v0.3:mac_update check / 真更新 / 已最新', async (t) => {
  const rig = await pairedRig(t, { appVersion: '0.2.0', latest: '0.4.0' })
  useAgentHome(t, rig.agentHome)
  assert.match(text(await callTool('mac_update', { check: true })), /0\.2\.0 → 0\.4\.0/)
  assert.equal(rig.mac.log.filter((x) => x.update).length, 0)
  assert.match(text(await callTool('mac_update', {})), /升级到 0\.4\.0/)
  assert.equal(rig.mac.log.filter((x) => x.update).length, 1)
})

test('MCP v0.3:屏幕录制没授权时 mac_selfshot 仍然给得出图', async (t) => {
  const rig = await pairedRig(t, { perms: { screen: false } })
  useAgentHome(t, rig.agentHome)
  // 真客户端走 tools/call,错误会被包成 isError 的文本 —— 顺带验证提示里指路 selfshot
  const shot = await handleRPC({
    jsonrpc: '2.0',
    id: 9,
    method: 'tools/call',
    params: { name: 'mac_screenshot', arguments: { why: '看桌面' } },
  })
  assert.equal(shot.result.isError, true, '没授权时整屏截图应该失败')
  assert.match(shot.result.content[0].text, /屏幕录制/)
  assert.match(shot.result.content[0].text, /machands selfshot/)

  const self = await callTool('mac_selfshot', { window: 'all' })
  assert.equal(self.isError, undefined, text(self))
  const image = self.content.find((c) => c.type === 'image')
  assert.ok(image && image.data.length > 0, '没返回图片')
  assert.equal(image.mimeType, 'image/png')
  assert.match(text(self), /MacHands/)
})

test('MCP v0.3:mac_show_window', async (t) => {
  const rig = await pairedRig(t)
  useAgentHome(t, rig.agentHome)
  assert.match(text(await callTool('mac_show_window', {})), /主窗口/)
  assert.equal(rig.mac.log.filter((x) => x.showWindow).length, 1)
})

test('MCP v0.3:真起 stdio 进程,tools/list 带 why,tools/call mac_doctor', async (t) => {
  const rig = await pairedRig(t, { duplicates: ['/Applications/MacHands.app', '/tmp/MacHands.app'] })
  const child = spawn(process.execPath, [BIN, 'mcp'], { env: { ...process.env, ...rig.env }, stdio: ['pipe', 'pipe', 'pipe'] })
  t.after(() => child.kill('SIGKILL'))
  const seen = []
  let stderr = ''
  child.stderr.on('data', (d) => (stderr += d))
  const done = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('MCP stdio 20 秒没回完\n' + stderr)), 20_000)
    let buf = ''
    child.stdout.on('data', (d) => {
      buf += d
      let nl
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl).trim()
        buf = buf.slice(nl + 1)
        if (!line) continue
        seen.push(JSON.parse(line))
        if (seen.length === 3) {
          clearTimeout(timer)
          resolve()
        }
      }
    })
  })
  const send = (m) => child.stdin.write(JSON.stringify(m) + '\n')
  send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 't', version: '0' } } })
  send({ jsonrpc: '2.0', method: 'notifications/initialized' })
  send({ jsonrpc: '2.0', id: 2, method: 'tools/list' })
  send({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'mac_doctor', arguments: {} } })
  await done

  const list = seen.find((m) => m.id === 2)
  const run = list.result.tools.find((x) => x.name === 'mac_run')
  assert.ok(run.inputSchema.required.includes('why'))
  const doctor = seen.find((m) => m.id === 3)
  assert.match(doctor.result.content[0].text, /不止一份/)
})
