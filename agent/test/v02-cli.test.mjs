// v0.2 CLI 端到端:真中继 + 假 Mac + 真 CLI 子进程,按 SPEC §12 的命令合同逐条走。
// 合同里没写死的输出形状(--json 给数组还是 {key:[…]}、open 的 id 在哪一行)这里两种都认。
import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdirSync, writeFileSync, readFileSync, existsSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { cli } from './helpers.mjs'
import { pairedRig, sleep, HEX10, jsonList } from './v02-helpers.mjs'

const pickHex = (s) => (s.match(/\b[a-f0-9]{10}\b/) || [])[0]

test('CLI v0.2:use / verify / perms / which / check', async (t) => {
  const { env } = await pairedRig(t)

  const use = await cli(['use', '测试 Mac'], env)
  assert.equal(use.code, 0, use.out + use.err)
  assert.match(use.out, /default mac: 测试 Mac/)

  const verify = await cli(['verify'], env)
  assert.equal(verify.code, 0, verify.out + verify.err)
  const lines = verify.out.split('\n').filter((l) => /^[✓✗] /.test(l))
  // 0.3 起多了 update 那一行(App 会不会自己升级也是"能不能干活"的一部分)
  assert.equal(lines.length, 8, verify.out)
  assert.deepEqual(
    lines.map((l) => l.split(/\s+/)[1]),
    ['run', 'fs', 'screen', 'input', 'notify', 'job', 'mcp', 'update']
  )
  for (const l of lines) assert.match(l, /^✓ \S+  \S/, l)

  const vj = await cli(['verify', '--json'], env)
  assert.equal(vj.code, 0, vj.err)
  const rows = jsonList(JSON.parse(vj.out), 'rows')
  assert.equal(rows.length, 8)
  assert.ok(rows.every((r) => r.ok === true && typeof r.name === 'string'))

  const perms = await cli(['perms'], env)
  assert.equal(perms.code, 0, perms.err)
  assert.match(perms.out, /^screen: yes$/m)
  assert.match(perms.out, /^accessibility: yes$/m)
  assert.match(perms.out, /^notifications: yes$/m)
  const pj = JSON.parse((await cli(['perms', '--json'], env)).out)
  assert.equal(pj.screen, true)
  assert.equal(pj.notifications, 'authorized')

  const which = await cli(['which', 'node', 'godot'], env)
  assert.equal(which.code, 0, which.err)
  assert.match(which.out, /^node: \/usr\/local\/bin\/node$/m)
  assert.match(which.out, /^godot: -$/m)
  const wj = JSON.parse((await cli(['which', 'node', '--json'], env)).out)
  assert.equal(wj.node, '/usr/local/bin/node')
  const whichAll = await cli(['which'], env)
  assert.match(whichAll.out, /^blender: -$/m)

  const ok = await cli(['check', 'echo hi'], env)
  assert.equal(ok.code, 0, ok.out + ok.err)
  assert.match(ok.out, /allow/)
  const bad = await cli(['check', 'rm -rf /'], env)
  assert.notEqual(bad.code, 0, '被拒的命令 check 应该非零退出')
  assert.match(bad.out + bad.err, /deny/)
})

test('CLI v0.2:没授权的 Mac 上 verify 打 ✗ + 修复指引,exit 非 0;perms 说 no', async (t) => {
  const { env } = await pairedRig(t, { perms: { screen: false, accessibility: false, notifications: 'denied' } })
  const v = await cli(['verify'], env)
  assert.notEqual(v.code, 0, 'verify 有项没过应该非零退出')
  const body = v.out + v.err
  assert.match(body, /^✓ run  /m)
  assert.match(body, /^✗ screen  未授权 → 需要在 Mac 上授权屏幕录制$/m)
  assert.match(body, /^✗ input  未授权 → 需要在 Mac 上授权辅助功能$/m)
  assert.match(body, /^✗ notify  denied → 需要在 Mac 上允许 MacHands 发通知$/m)

  const p = await cli(['perms'], env)
  assert.match(p.out, /^screen: no$/m)
  assert.match(p.out, /^accessibility: no$/m)
  assert.match(p.out, /^notifications: no$/m)
})

test('CLI v0.2:job submit → result 退出码 = 作业退出码,tail 有内容,kill 杀得掉', async (t) => {
  const { env } = await pairedRig(t)

  const sub = await cli(['job', 'submit', 'printf job-hi; echo job-err 1>&2; exit 4'], env)
  assert.equal(sub.code, 0, sub.out + sub.err)
  const jobId = sub.out.trim()
  assert.match(jobId, HEX10, 'stdout 应只有 jobId 一行:' + JSON.stringify(sub.out))

  const result = await cli(['job', 'result', jobId, '--wait', '10'], env)
  assert.equal(result.code, 4, result.out + result.err)

  const rj = await cli(['job', 'result', jobId, '--wait', '10', '--json'], env)
  assert.equal(rj.code, 4, rj.out + rj.err)
  const status = JSON.parse(rj.out)
  assert.equal(status.state, 'exited')
  assert.equal(status.code, 4)
  assert.equal(status.jobId, jobId)

  const tail = await cli(['job', 'tail', jobId], env)
  assert.equal(tail.code, 0, tail.err)
  assert.match(tail.out, /job-hi/)
  assert.doesNotMatch(tail.out, /job-err/)
  const tailErr = await cli(['job', 'tail', jobId, '--err'], env)
  assert.match(tailErr.out, /job-err/)

  const st = JSON.parse((await cli(['job', 'status', jobId, '--json'], env)).out)
  assert.equal(st.state, 'exited')
  assert.equal(st.outBytes, 6)

  const list = await cli(['job', 'list', '--json'], env)
  assert.equal(list.code, 0, list.err)
  assert.ok(jsonList(JSON.parse(list.out), 'jobs').some((j) => j.jobId === jobId))
  const plain = await cli(['job', 'list'], env)
  assert.match(plain.out, new RegExp(jobId))

  const long = (await cli(['job', 'submit', 'sleep 30'], env)).out.trim()
  assert.match(long, HEX10)
  assert.equal(JSON.parse((await cli(['job', 'status', long, '--json'], env)).out).state, 'running')
  const kill = await cli(['job', 'kill', long], env)
  assert.equal(kill.code, 0, kill.out + kill.err)
  const killed = JSON.parse((await cli(['job', 'result', long, '--wait', '5', '--json'], env)).out)
  assert.equal(killed.state, 'killed')
  assert.equal(killed.code, 137)
})

test('CLI v0.2:session open → write → read 回显 → close', async (t) => {
  const { env } = await pairedRig(t)

  const open = await cli(['session', 'open'], env)
  assert.equal(open.code, 0, open.out + open.err)
  const sid = open.out.trim()
  assert.match(sid, HEX10, 'stdout 应只有 sessionId 一行:' + JSON.stringify(open.out))

  // CLI 的合同(--help):文本里的 \n 会变成回车;所以这里传的是字面的反斜杠 n
  const write = await cli(['session', 'write', sid, 'echo sess-ok\\n'], env)
  assert.equal(write.code, 0, write.out + write.err)

  let read = { out: '' }
  for (let i = 0; i < 30 && !/sess-ok/.test(read.out); i++) {
    read = await cli(['session', 'read', sid], env)
    if (!/sess-ok/.test(read.out)) await sleep(100)
  }
  assert.equal(read.code, 0, read.err)
  assert.match(read.out, /sess-ok/)

  const rj = await cli(['session', 'read', sid, '--json'], env)
  const j = JSON.parse(rj.out)
  assert.equal(typeof j.offset, 'number')
  assert.equal(j.alive, true)
  assert.match(j.data, /sess-ok/)
  const again = JSON.parse((await cli(['session', 'read', sid, '--offset', String(j.offset), '--json'], env)).out)
  assert.equal(again.data, '')
  assert.equal(again.offset, j.offset)

  const close = await cli(['session', 'close', sid], env)
  assert.equal(close.code, 0, close.out + close.err)
  assert.notEqual((await cli(['session', 'read', sid], env)).code, 0)
})

test('CLI v0.2:input 的坐标/按键/文本原样落到 Mac', async (t) => {
  const { env, mac } = await pairedRig(t)

  const where = await cli(['input', 'where'], env)
  assert.equal(where.code, 0, where.err)
  assert.match(where.out, /640/)
  assert.match(where.out, /360/)

  assert.equal((await cli(['input', 'click', '100', '200'], env)).code, 0)
  assert.deepEqual(mac.inputs.at(-1), { m: 'input.click', x: 100, y: 200, button: 'left', count: 1 })

  assert.equal((await cli(['input', 'click', '5', '6', '--right', '--double'], env)).code, 0)
  assert.deepEqual(mac.inputs.at(-1), { m: 'input.click', x: 5, y: 6, button: 'right', count: 2 })

  assert.equal((await cli(['input', 'move', '7', '8'], env)).code, 0)
  assert.deepEqual(mac.inputs.at(-1), { m: 'input.move', x: 7, y: 8 })

  assert.equal((await cli(['input', 'drag', '1', '2', '3', '4', '--ms', '50'], env)).code, 0)
  assert.deepEqual(mac.inputs.at(-1), { m: 'input.drag', x1: 1, y1: 2, x2: 3, y2: 4, ms: 50 })

  assert.equal((await cli(['input', 'scroll', '1', '2', '0', '3'], env)).code, 0)
  assert.deepEqual(mac.inputs.at(-1), { m: 'input.scroll', x: 1, y: 2, dx: 0, dy: 3 })

  assert.equal((await cli(['input', 'key', 'c', '--mods', 'cmd,shift'], env)).code, 0)
  assert.deepEqual(mac.inputs.at(-1), { m: 'input.key', key: 'c', mods: ['cmd', 'shift'] })

  assert.equal((await cli(['input', 'key', 'enter'], env)).code, 0)
  assert.deepEqual(mac.inputs.at(-1), { m: 'input.key', key: 'enter', mods: [] })

  assert.equal((await cli(['input', 'type', 'héllo 中文'], env)).code, 0)
  assert.deepEqual(mac.inputs.at(-1), { m: 'input.type', text: 'héllo 中文' })
})

test('CLI v0.2:record 落盘字节与 Mac 报的一致,window-shot 是 PNG', async (t) => {
  const { env, mac, work } = await pairedRig(t)

  const mov = join(work, 'rec.mov')
  const rec = await cli(['record', '--seconds', '1', '-o', mov], env)
  assert.equal(rec.code, 0, rec.out + rec.err)
  const reported = mac.log.find((x) => x.record)?.record
  assert.ok(reported, '假 Mac 没收到 screen.record')
  assert.equal(reported.seconds, 1)
  assert.equal(statSync(mov).size, reported.bytes)

  const png = join(work, 'win.png')
  const ws = await cli(['window-shot', '--app', 'Godot', '--title', 'Powderline', '-o', png], env)
  assert.equal(ws.code, 0, ws.out + ws.err)
  assert.equal(readFileSync(png).subarray(1, 4).toString('ascii'), 'PNG')
  assert.ok(mac.log.some((x) => x.window?.app === 'Godot' && x.window?.title === 'Powderline'))
})

test('CLI v0.2:mcp servers → open → list → call 回显 → close', async (t) => {
  const { env } = await pairedRig(t)

  const servers = await cli(['mcp', 'servers'], env)
  assert.equal(servers.code, 0, servers.err)
  assert.match(servers.out, /echo/)
  const sj = jsonList(JSON.parse((await cli(['mcp', 'servers', '--json'], env)).out), 'servers')
  assert.deepEqual(
    sj.map((s) => s.name),
    ['echo', 'remote-http']
  )

  const open = await cli(['mcp', 'open', 'echo'], env)
  assert.equal(open.code, 0, open.out + open.err)
  const sid = pickHex(open.out)
  assert.ok(sid, 'open 的输出里找不到 sessionId:' + JSON.stringify(open.out))

  const list = await cli(['mcp', 'list', sid], env)
  assert.equal(list.code, 0, list.err)
  assert.match(list.out, /echo/)

  const call = await cli(['mcp', 'call', sid, 'echo', '{"a":1,"s":"中文"}'], env)
  assert.equal(call.code, 0, call.out + call.err)
  assert.match(call.out, /"a":\s*1/)
  assert.match(call.out, /中文/)

  assert.equal((await cli(['mcp', 'close', sid], env)).code, 0)
  assert.notEqual((await cli(['mcp', 'open', 'remote-http'], env)).code, 0, 'http 服务还没桥接,应该报错')
})

test('CLI v0.2:power on/off 与 relaunch', async (t) => {
  const { env, mac } = await pairedRig(t)
  const on = await cli(['power', 'on', '--seconds', '60'], env)
  assert.equal(on.code, 0, on.out + on.err)
  assert.ok(mac.log.some((x) => x.power?.on === true && x.power?.seconds === 60))
  assert.equal((await cli(['power', 'off'], env)).code, 0)
  assert.ok(mac.log.some((x) => x.power?.on === false))
  const relaunch = await cli(['relaunch'], env)
  assert.equal(relaunch.code, 0, relaunch.out + relaunch.err)
  assert.ok(mac.log.some((x) => x.relaunch))
})

test('CLI v0.2:get 远端目录 → 本地解包后内容一致', async (t) => {
  const { env, work } = await pairedRig(t)
  const src = join(work, 'src')
  mkdirSync(join(src, 'sub'), { recursive: true })
  writeFileSync(join(src, 'a.txt'), 'alpha')
  const bin = Buffer.alloc(3000)
  for (let i = 0; i < bin.length; i++) bin[i] = (i * 13) & 0xff
  writeFileSync(join(src, 'sub', 'b.bin'), bin)

  const dst = join(work, 'dst')
  const got = await cli(['get', src, '-o', dst], env)
  assert.equal(got.code, 0, got.out + got.err)
  // 解包后顶层带不带目录名,合同没说死,两种都认
  const a = [join(dst, 'src', 'a.txt'), join(dst, 'a.txt')].find(existsSync)
  assert.ok(a, `dst 里没有 a.txt:${got.out}`)
  assert.equal(readFileSync(a, 'utf8'), 'alpha')
  const b = [join(dst, 'src', 'sub', 'b.bin'), join(dst, 'sub', 'b.bin')].find(existsSync)
  assert.ok(b, 'dst 里没有 sub/b.bin')
  assert.ok(readFileSync(b).equals(bin))
})
