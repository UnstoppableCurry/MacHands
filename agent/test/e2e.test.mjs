// 端到端:真中继 + 假 Mac + 真 CLI 子进程,走完 pair → info → run → put → get。
import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, writeFileSync, readFileSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { cli, setupRig } from './helpers.mjs'

const setup = setupRig

test('端到端:pair → info → run → put → get', async (t) => {
  const { mac, env, work } = await setup(t)

  // 1. 配对:agent 执行的就是配对块里那一行
  const paired = await cli(['pair', mac.code], env)
  assert.equal(paired.code, 0, paired.out + paired.err)
  assert.match(paired.out, /已连接 测试 Mac/)
  assert.match(paired.out, /claude mcp add machands -- npx -y machands mcp/)
  assert.match(paired.out, /~\/\.codex\/config\.toml/)
  assert.match(paired.out, /Cursor:\s+Settings → MCP → Add: npx -y machands mcp/)
  assert.match(paired.out, /machands run -- xcodebuild -version/)
  assert.match(paired.out, /已设为默认 Mac/) // 只有一台就是默认
  assert.ok(existsSync(join(env.MACHANDS_HOME, 'identity.json')))
  assert.ok(existsSync(join(env.MACHANDS_HOME, 'pairings.json')))

  // 2. 列表
  const macs = await cli(['macs'], env)
  assert.equal(macs.code, 0)
  assert.match(macs.out, /测试 Mac\s+在线/)

  // 3. sys.info
  const info = await cli(['info', '--json'], env)
  assert.equal(info.code, 0, info.err)
  const parsed = JSON.parse(info.out)
  assert.equal(parsed.arch, process.arch)
  assert.equal(parsed.model, 'FakeMac1,1')

  // 4. run:输出实时透传,退出码原样返回
  const run = await cli(['run', '--', 'echo', 'hello-machands'], env)
  assert.equal(run.code, 0, run.err)
  assert.match(run.out, /hello-machands/)

  const failed = await cli(['run', '--', 'sh -c "echo 到了 stderr 1>&2; exit 7"'], env)
  assert.equal(failed.code, 7)
  assert.match(failed.err, /到了 stderr/)

  // 5. put:上传一个文件
  const local = join(work, 'up.txt')
  const remote = join(work, 'remote.txt')
  const payload = '一段中文 + binary ' + 'x'.repeat(5000)
  writeFileSync(local, payload)
  const put = await cli(['put', local, remote], env)
  assert.equal(put.code, 0, put.err)
  assert.match(put.out, /已上传/)
  assert.equal(readFileSync(remote, 'utf8'), payload)

  // 6. get:再拉回来,内容一致
  const back = join(work, 'down.txt')
  const got = await cli(['get', remote, back], env)
  assert.equal(got.code, 0, got.err)
  assert.match(got.out, /已下载/)
  assert.equal(readFileSync(back, 'utf8'), payload)

  // 7. 剪贴板与通知
  assert.equal((await cli(['clip', 'set', '剪贴板测试'], env)).code, 0)
  const clip = await cli(['clip'], env)
  assert.equal(clip.out.trim(), '剪贴板测试')
  assert.equal(mac.getClipboard(), '剪贴板测试')

  // 8. 截屏:拿到真 PNG 头
  const shotPath = join(work, 'shot.png')
  const shot = await cli(['shot', '-o', shotPath], env)
  assert.equal(shot.code, 0, shot.err)
  const png = readFileSync(shotPath)
  assert.equal(png.subarray(1, 4).toString('ascii'), 'PNG')

  // 9. doctor
  const doctor = await cli(['doctor', '--json'], env)
  assert.equal(doctor.code, 0, doctor.err)
  assert.equal(JSON.parse(doctor.out).macs[0].online, true)

  // 10. forget 之后就没有 Mac 了
  const forget = await cli(['forget', '测试 Mac'], env)
  assert.equal(forget.code, 0)
  const after = await cli(['info'], env)
  assert.equal(after.code, 66)
  assert.match(after.err, /还没有配对过的 Mac/)
})

test('端到端:一个大文件分块上传下载,前后一致', async (t) => {
  const { mac, env, work } = await setup(t)
  assert.equal((await cli(['pair', mac.code], env)).code, 0)

  const local = join(work, 'big.bin')
  const remote = join(work, 'big-remote.bin')
  const bytes = Buffer.alloc(900 * 1024)
  for (let i = 0; i < bytes.length; i++) bytes[i] = (i * 7) & 0xff
  writeFileSync(local, bytes)

  assert.equal((await cli(['put', local, remote], env, { timeoutMs: 40_000 })).code, 0)
  assert.equal(readFileSync(remote).equals(bytes), true)

  const back = join(work, 'big-back.bin')
  assert.equal((await cli(['get', remote, back], env, { timeoutMs: 40_000 })).code, 0)
  assert.equal(readFileSync(back).equals(bytes), true)
})

test('端到端:Mac 拒绝时退出码 77,话说得清楚', async (t) => {
  const { mac, env } = await setup(t, { deny: true })
  assert.equal((await cli(['pair', mac.code], env)).code, 0)
  const r = await cli(['run', '--', 'echo', 'x'], env)
  assert.equal(r.code, 77)
  assert.match(r.err, /拒绝/)
})

test('端到端:配对码用第二次会被拒,并告诉用户去哪儿再拿一个', async (t) => {
  const { mac, env, agentHome } = await setup(t)
  assert.equal((await cli(['pair', mac.code], env)).code, 0)
  // 换一个干净的 agent 身份,拿同一个配对码再来一次
  const second = mkdtempSync(join(tmpdir(), 'machands-e2e-agent2-'))
  const r = await cli(['pair', mac.code], { ...env, MACHANDS_HOME: second })
  rmSync(second, { recursive: true, force: true })
  assert.notEqual(r.code, 0)
  assert.match(r.err, /用过了|复制给 agent/)
  assert.ok(existsSync(join(agentHome, 'pairings.json')))
})

test('端到端:没配对时说人话,退出码 66', async (t) => {
  const home = mkdtempSync(join(tmpdir(), 'machands-e2e-empty-'))
  t.after(() => rmSync(home, { recursive: true, force: true }))
  const r = await cli(['run', '--', 'echo', 'x'], { MACHANDS_HOME: home, MACHANDS_LANG: 'zh' })
  assert.equal(r.code, 66)
  assert.match(r.err, /还没有配对过的 Mac/)
})

test('端到端:Mac 离线时退出码 69', async (t) => {
  const { mac, env } = await setup(t)
  assert.equal((await cli(['pair', mac.code], env)).code, 0)
  mac.close()
  await new Promise((r) => setTimeout(r, 120))
  const r = await cli(['info'], env)
  assert.equal(r.code, 69)
  assert.match(r.err, /不在线/)
})

test('端到端:中继连不上时说清楚是连不上中继,退出码 69', async (t) => {
  const { mac, env, relay } = await setupRig(t)
  assert.equal((await cli(['pair', mac.code], env)).code, 0)
  mac.close()
  await relay.close() // 中继整个没了
  const r = await cli(['info'], env)
  assert.equal(r.code, 69)
  assert.match(r.err, /连不上中继/)
})

test('CLI:--help 和 --version 不用连网', async (t) => {
  const home = mkdtempSync(join(tmpdir(), 'machands-e2e-help-'))
  t.after(() => rmSync(home, { recursive: true, force: true }))
  const env = { MACHANDS_HOME: home }
  const v = await cli(['--version'], env)
  assert.equal(v.out.trim(), JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).version)
  const h = await cli(['help'], env)
  assert.equal(h.code, 0)
  for (const sub of ['pair', 'macs', 'run', 'put', 'get', 'shot', 'open', 'clip', 'info', 'mcp', 'forget', 'doctor']) {
    assert.match(h.out, new RegExp(`machands ${sub}`))
  }
})
