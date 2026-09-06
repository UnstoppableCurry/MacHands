// v0.3 CLI:版本协商、update、doctor 的 App 段、--why 透传、selfshot / show。
// 都用本地中继 + 假 Mac(v02-helpers 的 pairedRig),不碰任何真中继。
import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, existsSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { cli } from './helpers.mjs'
import { pairedRig } from './v02-helpers.mjs'
import { VERSION } from '../src/cli.mjs'

const countOf = (haystack, needle) => haystack.split(needle).length - 1

test('v0.3:App 比 CLI 旧 → stderr 一句提示,且只说一次', async (t) => {
  const rig = await pairedRig(t, { appVersion: '0.1.0' })
  const r = await cli(['run', '--', 'echo', 'hi'], rig.env)
  assert.equal(r.code, 0, r.err)
  assert.match(r.out, /hi/)
  assert.match(r.err, /0\.1\.0/)
  assert.match(r.err, new RegExp(VERSION.replace(/\./g, '\\.')))
  assert.match(r.err, /machands update/)
  assert.equal(countOf(r.err, 'machands update'), 1, '同一个进程里提示重复了:\n' + r.err)
})

test('v0.3:App 比 CLI 新 → 提示升级 npm 包', async (t) => {
  const rig = await pairedRig(t, { appVersion: '9.9.9' })
  const r = await cli(['run', '--', 'echo', 'hi'], rig.env)
  assert.equal(r.code, 0, r.err)
  assert.match(r.err, /9\.9\.9/)
  assert.match(r.err, /npm i -g machands@latest/)
})

test('v0.3:版本一致 → stderr 不提版本', async (t) => {
  const rig = await pairedRig(t)
  const r = await cli(['run', '--', 'echo', 'hi'], rig.env)
  assert.equal(r.code, 0, r.err)
  assert.doesNotMatch(r.err, /machands update|npm i -g/)
})

test('v0.3:方法不存在 → 说清是 App 太旧,不是把原始错误抛出来', async (t) => {
  const rig = await pairedRig(t, { appVersion: '0.1.0', omit: ['sys.perms'] })
  const r = await cli(['perms'], rig.env)
  assert.notEqual(r.code, 0)
  assert.match(r.err, /还不支持 sys\.perms/)
  assert.match(r.err, /0\.1\.0/)
  assert.match(r.err, /machands update/)
  assert.doesNotMatch(r.err, /没有这个方法/)
})

test('v0.3:doctor 报出装了多份 App,给出建议,并且退出码非零', async (t) => {
  const rig = await pairedRig(t, {
    duplicates: ['/Applications/MacHands.app', '/Users/money/Applications/MacHands.app'],
  })
  const r = await cli(['doctor'], rig.env)
  assert.notEqual(r.code, 0, '装了多份应该算不健康')
  assert.match(r.out, /装了 2 份/)
  assert.match(r.out, /\/Users\/money\/Applications\/MacHands\.app/)
  assert.match(r.out, /只保留 \/Applications/)
  assert.match(r.out, /App {2,}/)
})

test('v0.3:doctor --json 带 app 段;干净的 Mac 退出 0', async (t) => {
  const rig = await pairedRig(t)
  const r = await cli(['doctor', '--json'], rig.env)
  assert.equal(r.code, 0, r.out + r.err)
  const j = JSON.parse(r.out)
  assert.equal(j.app.version, VERSION)
  assert.equal(j.app.translocated, false)
  assert.equal(typeof j.app.perms, 'object')
  assert.equal(j.app.auto_update, true)
})

test('v0.3:doctor 对太旧的 App 说清楚,而不是报错', async (t) => {
  const rig = await pairedRig(t, { appVersion: '0.2.0', omit: ['app.doctor'] })
  const r = await cli(['doctor'], rig.env)
  assert.equal(r.code, 0, r.out + r.err)
  assert.match(r.out, /版本太旧|app\.doctor/)
})

test('v0.3:update --check 只看不装', async (t) => {
  const rig = await pairedRig(t, { appVersion: '0.2.0', latest: '0.4.0' })
  const r = await cli(['update', '--check'], rig.env)
  assert.equal(r.code, 0, r.err)
  assert.match(r.out, /0\.2\.0/)
  assert.match(r.out, /0\.4\.0/)
  assert.equal(rig.mac.log.filter((x) => x.update).length, 0, '--check 不该真的更新')
})

test('v0.3:update 装完等 App 回来并打印新版本', async (t) => {
  const rig = await pairedRig(t, { appVersion: '0.2.0', latest: '0.4.0' })
  const r = await cli(['update'], rig.env, { timeoutMs: 60_000 })
  assert.equal(r.code, 0, r.out + r.err)
  assert.match(r.out, /正在更新 0\.2\.0 → 0\.4\.0/)
  assert.match(r.out, /0\.4\.0/)
  assert.equal(rig.mac.log.filter((x) => x.update).length, 1)
})

test('v0.3:update 已是最新', async (t) => {
  const rig = await pairedRig(t)
  const r = await cli(['update'], rig.env)
  assert.equal(r.code, 0, r.err)
  assert.match(r.out, /已是最新/)
})

test('v0.3:update 失败要说原因并退出非零', async (t) => {
  const rig = await pairedRig(t, { appVersion: '0.2.0', latest: '0.4.0', updateFails: '下载校验没过' })
  const r = await cli(['update'], rig.env)
  assert.notEqual(r.code, 0)
  assert.match(r.err, /更新失败/)
  assert.match(r.err, /下载校验没过/)
})

test('v0.3:App 不会自更新时,update 说人话', async (t) => {
  const rig = await pairedRig(t, { appVersion: '0.2.0', omit: ['app.update'] })
  const r = await cli(['update'], rig.env)
  assert.notEqual(r.code, 0)
  assert.match(r.err, /还不会自己更新|官网/)
})

test('v0.3:--why 会跟着请求一起到 Mac', async (t) => {
  const rig = await pairedRig(t)
  const r = await cli(['run', '--why', '确认雪场地形改完之后的样子', '--', 'echo', 'ok'], rig.env)
  assert.equal(r.code, 0, r.err)
  const call = rig.mac.calls.find((c) => c.m === 'run')
  assert.ok(call, '假 Mac 没收到 run')
  assert.equal(call.why, '确认雪场地形改完之后的样子')
})

test('v0.3:--why 超过 120 字会截断,不会把卡片撑爆', async (t) => {
  const rig = await pairedRig(t)
  const long = '为'.repeat(200)
  const r = await cli(['input', 'click', '10', '20', '--why', long], rig.env)
  assert.equal(r.code, 0, r.err)
  const call = rig.mac.calls.find((c) => c.m === 'input.click')
  assert.equal(call.why.length, 120)
})

test('v0.3:--why 不给内容就说清用法', async (t) => {
  const rig = await pairedRig(t)
  const r = await cli(['run', '--why', '--', 'echo', 'hi'], rig.env)
  assert.notEqual(r.code, 0)
  assert.match(r.err, /--why 要跟一句人话/)
})

test('v0.3:selfshot 落盘;--window all 还会列出每个窗口', async (t) => {
  const rig = await pairedRig(t, { perms: { screen: false } })
  const out = join(rig.work, 'ui.png')
  const r = await cli(['selfshot', '-o', out], rig.env)
  assert.equal(r.code, 0, r.err)
  assert.ok(existsSync(out) && statSync(out).size > 0, 'selfshot 没写出文件')
  assert.equal(readFileSync(out).subarray(1, 4).toString(), 'PNG')
  assert.equal(rig.mac.log.filter((x) => x.selfshot === 'main').length, 1)

  const all = await cli(['selfshot', '--window', 'all', '-o', join(rig.work, 'all.png'), '--json'], rig.env)
  assert.equal(all.code, 0, all.err)
  assert.equal(JSON.parse(all.out).windows.length, 2)
})

test('v0.3:屏幕录制没授权时,提示里要指路 selfshot', async (t) => {
  const rig = await pairedRig(t, { perms: { screen: false } })
  const r = await cli(['shot', '-o', join(rig.work, 'x.png')], rig.env)
  assert.notEqual(r.code, 0)
  assert.match(r.err, /屏幕录制/)
  assert.match(r.err, /machands selfshot/)
})

test('v0.3:show 打开 Mac 上的主窗口', async (t) => {
  const rig = await pairedRig(t)
  const r = await cli(['show'], rig.env)
  assert.equal(r.code, 0, r.err)
  assert.match(r.out, /主窗口/)
  assert.equal(rig.mac.log.filter((x) => x.showWindow).length, 1)
})

test('v0.3:verify 多出 update 一行', async (t) => {
  const rig = await pairedRig(t)
  const r = await cli(['verify', '--json'], rig.env)
  const rows = JSON.parse(r.out).rows
  assert.ok(rows.some((x) => x.name === 'update'), '没有 update 那一行:' + r.out)
})
