// v0.2 MCP 工具:真中继 + 假 Mac,直接调 callTool;最后再起一次真的 stdio 进程走完协议帧。
import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn, execFileSync } from 'node:child_process'
import { mkdirSync, writeFileSync, readFileSync, existsSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { handleRPC, callTool, TOOLS } from '../src/mcp.mjs'
import { BIN } from './helpers.mjs'
import { pairedRig, useAgentHome, firstJSON, sleep, HEX10 } from './v02-helpers.mjs'

export const NEW_TOOLS = [
  'mac_perms',
  'mac_which',
  'mac_check',
  'mac_verify',
  'mac_job_submit',
  'mac_job_status',
  'mac_job_tail',
  'mac_job_result',
  'mac_job_kill',
  'mac_job_list',
  'mac_session_open',
  'mac_session_write',
  'mac_session_read',
  'mac_session_close',
  'mac_input',
  'mac_window_shot',
  'mac_record',
  'mac_mcp_servers',
  'mac_mcp_open',
  'mac_mcp_call',
  'mac_mcp_close',
  'mac_power',
  'mac_relaunch',
]

const text = (r) => r.content[0].text
const json = (r) => JSON.parse(text(r))

test('MCP v0.2:tools/list 含全部新工具,schema 完整,名字不重复', async () => {
  const list = await handleRPC({ jsonrpc: '2.0', id: 1, method: 'tools/list' })
  const names = list.result.tools.map((x) => x.name)
  for (const want of NEW_TOOLS) assert.ok(names.includes(want), '缺工具 ' + want)
  assert.equal(new Set(names).size, names.length, '工具名重复')
  for (const tool of TOOLS) {
    assert.ok(tool.description.length > 10, tool.name + ' 没说明')
    assert.equal(tool.inputSchema.type, 'object')
    assert.equal(typeof tool.inputSchema.properties, 'object', tool.name + ' 没 properties')
    for (const r of tool.inputSchema.required || []) {
      assert.ok(tool.inputSchema.properties[r], `${tool.name} 的 required ${r} 没在 properties 里`)
    }
  }
})

test('MCP v0.2:perms / which / check / verify', async (t) => {
  const { agentHome } = await pairedRig(t)
  useAgentHome(t, agentHome)

  const perms = json(await callTool('mac_perms', {}))
  assert.deepEqual(perms, { screen: true, accessibility: true, notifications: 'authorized', automation: 'onDemand' })

  const which = json(await callTool('mac_which', { names: ['node', 'godot'] }))
  assert.deepEqual(which, { node: '/usr/local/bin/node', godot: null })
  const all = json(await callTool('mac_which', {}))
  assert.ok('blender' in all && 'xcodebuild' in all, Object.keys(all).join(','))

  const ok = json(await callTool('mac_check', { subject: 'echo hi' }))
  assert.equal(ok.decision, 'allow')
  assert.equal(ok.method, 'run')
  const bad = json(await callTool('mac_check', { subject: 'rm -rf /' }))
  assert.equal(bad.decision, 'deny')
  assert.equal(bad.reason, 'blacklist')
  assert.match(bad.summary, /deny — blacklist/)

  const verify = await callTool('mac_verify', {})
  assert.equal(verify.isError, undefined, text(verify))
  const lines = text(verify).split('\n')
  // 0.3 起多了 update 那一行,末行仍然是结论
  assert.equal(lines.length, 9, text(verify))
  assert.deepEqual(
    lines.slice(0, 8).map((l) => l.split(/\s+/)[1]),
    ['run', 'fs', 'screen', 'input', 'notify', 'job', 'mcp', 'update']
  )
  for (const l of lines.slice(0, 8)) assert.match(l, /^✓ \S+  \S/)
  assert.equal(lines[8], '全部通过')

  const info = json(await callTool('mac_info', {}))
  for (const k of ['mem_gb', 'disk_free_gb', 'cpu', 'gpu', 'displays', 'tools', 'app_version']) assert.ok(k in info, '缺 ' + k)
  assert.equal(info.tools.node, '/usr/local/bin/node')
})

test('MCP v0.2:没授权的 Mac 上 verify 打 ✗ 并给修复指引,isError', async (t) => {
  const { agentHome } = await pairedRig(t, { perms: { screen: false, accessibility: false, notifications: 'denied' } })
  useAgentHome(t, agentHome)
  const verify = await callTool('mac_verify', {})
  assert.equal(verify.isError, true)
  const body = text(verify)
  assert.match(body, /^✓ run  /m)
  assert.match(body, /^✗ screen  未授权 → 需要在 Mac 上授权屏幕录制$/m)
  assert.match(body, /^✗ input  未授权 → 需要在 Mac 上授权辅助功能$/m)
  assert.match(body, /^✗ notify  denied → 需要在 Mac 上允许 MacHands 发通知$/m)
  assert.match(body, /3 项没过$/)
  const perms = json(await callTool('mac_perms', {}))
  assert.equal(perms.screen, false)
  // 没屏幕权限时截图给的是清楚的错,不是空图
  const shot = await callTool('mac_screenshot', {}).catch((e) => e)
  assert.match(shot.message || text(shot), /屏幕录制/)
})

test('MCP v0.2:后台作业 submit → result 拿到真实退出码与输出,kill 杀得掉', async (t) => {
  const { agentHome, mac } = await pairedRig(t)
  useAgentHome(t, agentHome)

  const sub = json(await callTool('mac_job_submit', { cmd: 'printf job-out; echo job-err 1>&2; exit 5' }))
  assert.match(sub.jobId, HEX10)

  const result = await callTool('mac_job_result', { jobId: sub.jobId, wait: 10 })
  assert.equal(result.isError, true, text(result))
  const status = firstJSON(text(result))
  assert.equal(status.state, 'exited')
  assert.equal(status.code, 5)
  assert.equal(status.jobId, sub.jobId)
  assert.equal(status.outBytes, 7)
  assert.match(text(result), /--- stdout ---\njob-out/)
  assert.match(text(result), /--- stderr ---\njob-err/)

  const tail = await callTool('mac_job_tail', { jobId: sub.jobId })
  assert.equal(text(tail), 'job-out\n[offset=7 eof=true]')
  const tailErr = await callTool('mac_job_tail', { jobId: sub.jobId, stream: 'err' })
  assert.equal(text(tailErr), 'job-err\n[offset=8 eof=true]')
  const partial = await callTool('mac_job_tail', { jobId: sub.jobId, offset: 4 })
  assert.equal(text(partial), 'out\n[offset=7 eof=true]')

  const st = json(await callTool('mac_job_status', { jobId: sub.jobId }))
  assert.equal(st.state, 'exited')
  assert.equal(typeof st.ms, 'number')
  assert.equal(typeof st.startedAt, 'number')
  assert.equal(st.cmd, 'printf job-out; echo job-err 1>&2; exit 5')

  const list = json(await callTool('mac_job_list', {}))
  assert.ok(list.some((j) => j.jobId === sub.jobId))

  // 长活:running → kill → killed/137;fake 记录里进程真的没了
  const long = json(await callTool('mac_job_submit', { cmd: 'sleep 30' }))
  const running = json(await callTool('mac_job_status', { jobId: long.jobId }))
  assert.equal(running.state, 'running')
  assert.equal(running.code, undefined)
  assert.match(text(await callTool('mac_job_kill', { jobId: long.jobId })), /已终止作业/)
  const killed = firstJSON(text(await callTool('mac_job_result', { jobId: long.jobId, wait: 5 })))
  assert.equal(killed.state, 'killed')
  assert.equal(killed.code, 137)
  const child = mac.jobs.get(long.jobId).child
  await sleep(150)
  assert.equal(child.exitCode !== null || child.signalCode !== null, true, '子进程还活着')

  // 超时:1 秒后被杀,code 124
  const slow = json(await callTool('mac_job_submit', { cmd: 'sleep 20', timeout: 1 }))
  const timedOut = firstJSON(text(await callTool('mac_job_result', { jobId: slow.jobId, wait: 5 })))
  assert.equal(timedOut.state, 'killed')
  assert.equal(timedOut.code, 124)

  await assert.rejects(callTool('mac_job_status', { jobId: 'zzzz' }), /no such job/)
  await assert.rejects(callTool('mac_job_kill', { jobId: sub.jobId }), /no running job/)
  await assert.rejects(callTool('mac_job_submit', { cmd: 'true', cwd: '/definitely/not/here' }), /no such folder/)
})

test('MCP v0.2:交互会话 open → write → read 回显 → close', async (t) => {
  const { agentHome } = await pairedRig(t)
  useAgentHome(t, agentHome)

  const { sessionId } = json(await callTool('mac_session_open', {}))
  assert.match(sessionId, HEX10)
  assert.match(text(await callTool('mac_session_write', { sessionId, data: 'echo sess-hi; echo sess-err 1>&2' })), /已写入 \d+ 个字符/)

  let body = ''
  for (let i = 0; i < 60; i++) {
    body = text(await callTool('mac_session_read', { sessionId }))
    if (body.includes('sess-hi') && body.includes('sess-err')) break
    await sleep(50)
  }
  assert.match(body, /sess-hi/)
  assert.match(body, /sess-err/)
  assert.match(body, /\[offset=\d+ alive=true eof=false\]$/)

  // 从 offset 续读:没有新输出就只剩状态行
  const offset = Number(body.match(/offset=(\d+)/)[1])
  assert.equal(text(await callTool('mac_session_read', { sessionId, offset })), `[offset=${offset} alive=true eof=false]`)

  // 让进程自己退出,alive 变 false
  await callTool('mac_session_write', { sessionId, data: 'exit 0' })
  let last = ''
  for (let i = 0; i < 60; i++) {
    last = text(await callTool('mac_session_read', { sessionId, offset }))
    if (last.includes('alive=false')) break
    await sleep(50)
  }
  assert.match(last, /alive=false eof=true/)

  assert.match(text(await callTool('mac_session_close', { sessionId })), /已关闭会话/)
  await assert.rejects(callTool('mac_session_read', { sessionId }), /no such session/)

  // 带 cmd 的会话:非 shell 的 REPL 一样能用
  const cat = json(await callTool('mac_session_open', { cmd: 'cat' }))
  await callTool('mac_session_write', { sessionId: cat.sessionId, data: '回声', newline: false })
  let echoed = ''
  for (let i = 0; i < 60 && !echoed.startsWith('回声'); i++) {
    echoed = text(await callTool('mac_session_read', { sessionId: cat.sessionId }))
    if (!echoed.startsWith('回声')) await sleep(50)
  }
  assert.match(echoed, /^回声\n\[offset=6 alive=true/)
  await callTool('mac_session_close', { sessionId: cat.sessionId })
})

test('MCP v0.2:mac_input 的每个 action 参数都原样落到 Mac', async (t) => {
  const { agentHome, mac } = await pairedRig(t)
  useAgentHome(t, agentHome)

  assert.deepEqual(json(await callTool('mac_input', { action: 'where' })), { x: 640, y: 360 })

  await callTool('mac_input', { action: 'click', x: 100, y: 200 })
  assert.deepEqual(mac.inputs.at(-1), { m: 'input.click', x: 100, y: 200, button: 'left', count: 1 })

  await callTool('mac_input', { action: 'click', x: 5, y: 6, button: 'right', count: 2 })
  assert.deepEqual(mac.inputs.at(-1), { m: 'input.click', x: 5, y: 6, button: 'right', count: 2 })

  await callTool('mac_input', { action: 'move', x: 7, y: 8 })
  assert.deepEqual(mac.inputs.at(-1), { m: 'input.move', x: 7, y: 8 })

  await callTool('mac_input', { action: 'drag', x: 1, y: 2, x2: 3, y2: 4, ms: 50 })
  assert.deepEqual(mac.inputs.at(-1), { m: 'input.drag', x1: 1, y1: 2, x2: 3, y2: 4, ms: 50 })

  await callTool('mac_input', { action: 'scroll', x: 1, y: 2, dy: -3 })
  assert.deepEqual(mac.inputs.at(-1), { m: 'input.scroll', x: 1, y: 2, dx: 0, dy: -3 })

  await callTool('mac_input', { action: 'key', key: 'c', mods: ['cmd', 'shift'] })
  assert.deepEqual(mac.inputs.at(-1), { m: 'input.key', key: 'c', mods: ['cmd', 'shift'] })

  await callTool('mac_input', { action: 'type', text: 'héllo 中文' })
  assert.deepEqual(mac.inputs.at(-1), { m: 'input.type', text: 'héllo 中文' })

  const bad = await callTool('mac_input', { action: 'dance' })
  assert.equal(bad.isError, true)
  await assert.rejects(callTool('mac_input', { action: 'click', x: 1 }), /needs x,y/)
  await assert.rejects(callTool('mac_input', { action: 'key' }), /needs key/)
})

test('MCP v0.2:窗口截图返回图片,录屏落盘字节与 Mac 报的一致', async (t) => {
  const { agentHome, mac, work } = await pairedRig(t)
  useAgentHome(t, agentHome)

  const out = join(work, 'win.png')
  const shot = await callTool('mac_window_shot', { app: 'Godot', title: 'Powderline', out })
  assert.equal(shot.content[0].type, 'image')
  assert.equal(shot.content[0].mimeType, 'image/png')
  assert.equal(Buffer.from(shot.content[0].data, 'base64').subarray(1, 4).toString('ascii'), 'PNG')
  assert.match(shot.content[1].text, /已保存到/)
  assert.ok(existsSync(out))
  assert.ok(mac.log.some((x) => x.window?.app === 'Godot' && x.window?.title === 'Powderline'))

  const mov = join(work, 'rec.mov')
  const rec = await callTool('mac_record', { seconds: 2, out: mov })
  assert.equal(rec.isError, undefined, text(rec))
  assert.match(text(rec), /已录 2 秒,\d+ 字节 \.mov 落到 /)
  const reported = mac.log.find((x) => x.record)?.record
  assert.equal(reported.seconds, 2)
  assert.equal(statSync(mov).size, reported.bytes)
  assert.equal(readFileSync(mov).subarray(4, 8).toString('ascii'), 'ftyp')

  // 不给 out 也能落到临时目录
  const auto = await callTool('mac_record', { seconds: 1 })
  const path = text(auto).match(/落到 (.+)$/)[1]
  assert.ok(existsSync(path), path)
  assert.equal(statSync(path).size, 16 + 320)
})

test('MCP v0.2:MCP 桥 servers → open → call 回显 → close', async (t) => {
  const { agentHome, mac } = await pairedRig(t)
  useAgentHome(t, agentHome)

  const servers = json(await callTool('mac_mcp_servers', {}))
  assert.deepEqual(
    servers.map((s) => s.name),
    ['echo', 'remote-http']
  )
  assert.ok(servers.every((s) => !('env' in s)), '不能把 env 值带出来')

  const opened = json(await callTool('mac_mcp_open', { name: 'echo' }))
  assert.match(opened.sessionId, HEX10)
  assert.equal(opened.name, 'echo')
  assert.deepEqual(opened.tools, [{ name: 'echo', description: '原样回显 arguments' }])

  const call = await callTool('mac_mcp_call', { sessionId: opened.sessionId, tool: 'echo', args: { a: 1, s: '中文' } })
  assert.equal(call.isError, undefined)
  assert.equal(call.content[0].type, 'text')
  assert.deepEqual(JSON.parse(call.content[0].text), { a: 1, s: '中文' })
  assert.deepEqual(mac.mcpSessions.get(opened.sessionId).calls, [{ tool: 'echo', args: { a: 1, s: '中文' } }])

  await assert.rejects(callTool('mac_mcp_call', { sessionId: opened.sessionId, tool: 'nope' }), /Unknown tool/)
  await assert.rejects(callTool('mac_mcp_open', { name: 'remote-http' }), /http MCP server/)
  await assert.rejects(callTool('mac_mcp_open', { name: 'ghost' }), /no MCP server named ghost/)
  await assert.rejects(callTool('mac_mcp_open', {}), /needs name or command/)

  // 直接给 command 也行
  const direct = json(await callTool('mac_mcp_open', { command: 'npx', args: ['-y', 'some-mcp'], env: { API_KEY: 'x' } }))
  assert.equal(direct.name, 'npx')
  const rec = mac.log.find((x) => x.mcpOpen?.command === 'npx').mcpOpen
  assert.deepEqual(rec.args, ['-y', 'some-mcp'])
  assert.deepEqual(rec.envKeys, ['API_KEY'])

  assert.match(text(await callTool('mac_mcp_close', { sessionId: opened.sessionId })), /已关闭 MCP 会话/)
  await assert.rejects(callTool('mac_mcp_close', { sessionId: opened.sessionId }), /no such MCP session/)
})

test('MCP v0.2:power / relaunch', async (t) => {
  const { agentHome, mac } = await pairedRig(t)
  useAgentHome(t, agentHome)

  assert.match(text(await callTool('mac_power', { action: 'on', seconds: 60 })), /保持唤醒 60 秒,到 \d{4}-/)
  assert.deepEqual(mac.log.at(-1), { power: { on: true, seconds: 60 } })
  assert.match(text(await callTool('mac_power', { action: 'off' })), /已解除/)
  assert.deepEqual(mac.log.at(-1), { power: { on: false } })
  assert.equal((await callTool('mac_power', { action: 'nap' })).isError, true)

  assert.match(text(await callTool('mac_relaunch', {})), /重启/)
  assert.deepEqual(mac.log.at(-1), { relaunch: true })
})

test('MCP v0.2:mac_get 目录得到 tar.gz + 清单,大文件循环到 eof 字节一致', async (t) => {
  const { agentHome, work } = await pairedRig(t)
  useAgentHome(t, agentHome)

  // 目录
  const tree = join(work, 'tree')
  mkdirSync(join(tree, 'sub'), { recursive: true })
  writeFileSync(join(tree, 'a.txt'), 'alpha')
  const bin = Buffer.alloc(3000)
  for (let i = 0; i < bin.length; i++) bin[i] = (i * 13) & 0xff
  writeFileSync(join(tree, 'sub', 'b.bin'), bin)

  const dl = join(work, 'dl')
  const got = await callTool('mac_get', { path: tree, out: dl })
  const body = text(got)
  assert.match(body, /是目录/)
  const tgz = join(dl, 'tree.tar.gz')
  assert.ok(body.includes(tgz), body)
  assert.ok(existsSync(tgz))
  assert.match(body, /清单:\n[\s\S]*tree\/a\.txt/)
  assert.match(body, /tree\/sub\/b\.bin/)
  const extract = join(work, 'x')
  mkdirSync(extract)
  execFileSync('tar', ['xzf', tgz, '-C', extract])
  assert.equal(readFileSync(join(extract, 'tree', 'a.txt'), 'utf8'), 'alpha')
  assert.ok(readFileSync(join(extract, 'tree', 'sub', 'b.bin')).equals(bin))

  // 1.3 MB 二进制:假 Mac 每次最多给 768 KiB,必须分多次才拿得全
  const big = join(work, 'big.png')
  const bytes = Buffer.alloc(1_363_148)
  for (let i = 0; i < bytes.length; i++) bytes[i] = (i * 7) & 0xff
  writeFileSync(big, bytes)
  const back = join(work, 'big.back')
  const saved = await callTool('mac_get', { path: big, out: back })
  assert.equal(text(saved), `已保存 ${bytes.length} 字节到 ${back}`)
  assert.ok(readFileSync(back).equals(bytes))

  // 不给 out 的大二进制:完整落到临时文件并报路径,不截断、不塞 base64
  const spilled = text(await callTool('mac_get', { path: big }))
  const spilledPath = spilled.match(/完整落到本地:(.+?)\(/)[1]
  assert.ok(readFileSync(spilledPath).equals(bytes))

  // 小二进制:base64 内联,解出来一致
  const small = join(work, 'small.bin')
  writeFileSync(small, bin)
  const inline = text(await callTool('mac_get', { path: small }))
  assert.match(inline, /^二进制文件,3000 字节,base64:\n/)
  assert.ok(Buffer.from(inline.split('\n')[1], 'base64').equals(bin))

  // 文本还是直接给文本
  assert.equal(text(await callTool('mac_get', { path: join(tree, 'a.txt') })), 'alpha')
})

test('MCP v0.2:真起 stdio 进程 initialize → tools/list → tools/call mac_perms / mac_check', async (t) => {
  const { env } = await pairedRig(t)
  const child = spawn(process.execPath, [BIN, 'mcp'], { env: { ...process.env, ...env }, stdio: ['pipe', 'pipe', 'pipe'] })
  const replies = new Map()
  let buf = ''
  let stderr = ''
  child.stderr.on('data', (d) => (stderr += d))
  const gotAll = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('MCP stdio 15 秒没回完\n' + stderr)), 15_000)
    child.stdout.on('data', (d) => {
      buf += d
      let nl
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl)
        buf = buf.slice(nl + 1)
        if (!line.trim()) continue
        const msg = JSON.parse(line)
        replies.set(msg.id, msg)
        if (replies.size === 4) {
          clearTimeout(timer)
          resolve()
        }
      }
    })
    child.on('error', reject)
  })
  const send = (m) => child.stdin.write(JSON.stringify(m) + '\n')
  send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 't', version: '0' } } })
  send({ jsonrpc: '2.0', method: 'notifications/initialized' })
  send({ jsonrpc: '2.0', id: 2, method: 'tools/list' })
  send({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'mac_perms', arguments: {} } })
  send({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'mac_check', arguments: { subject: 'rm -rf /' } } })
  await gotAll
  child.stdin.end()
  await new Promise((r) => child.on('close', r))

  assert.equal(replies.get(1).result.protocolVersion, '2025-06-18')
  assert.equal(replies.get(1).result.serverInfo.name, 'machands')
  const names = replies.get(2).result.tools.map((x) => x.name)
  for (const want of NEW_TOOLS) assert.ok(names.includes(want), '缺工具 ' + want)
  const perms = JSON.parse(replies.get(3).result.content[0].text)
  assert.equal(perms.screen, true)
  assert.equal(replies.get(3).result.isError, undefined)
  const check = JSON.parse(replies.get(4).result.content[0].text)
  assert.equal(check.decision, 'deny')
  assert.equal(check.reason, 'blacklist')
})
