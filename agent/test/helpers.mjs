// 测试用:起一套真中继 + 假 Mac,并且用子进程跑真 CLI。
import { spawn } from 'node:child_process'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createRelay } from '../../relay/server.mjs'
import { startFakeMac } from './fake-mac.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
export const BIN = join(HERE, '../bin/machands.mjs')

export function cli(args, env, { timeoutMs = 20_000 } = {}) {
  return new Promise((resolve, reject) => {
    const p = spawn(process.execPath, [BIN, ...args], {
      env: { ...process.env, ...env },
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    let out = ''
    let err = ''
    p.stdout.on('data', (d) => (out += d))
    p.stderr.on('data', (d) => (err += d))
    const timer = setTimeout(() => {
      p.kill('SIGKILL')
      reject(new Error(`CLI 超时:machands ${args.join(' ')}\n${out}\n${err}`))
    }, timeoutMs)
    p.on('error', reject)
    p.on('close', (code) => {
      clearTimeout(timer)
      resolve({ code, out, err })
    })
  })
}

// t 是 node:test 的上下文,用来登记清理
export async function setupRig(t, opts = {}) {
  const dataDir = mkdtempSync(join(tmpdir(), 'machands-t-relay-'))
  const macHome = mkdtempSync(join(tmpdir(), 'machands-t-mac-'))
  const agentHome = mkdtempSync(join(tmpdir(), 'machands-t-agent-'))
  const work = mkdtempSync(join(tmpdir(), 'machands-t-work-'))
  const relay = createRelay({ dataDir, host: '127.0.0.1', port: 0, quiet: true })
  await relay.listen(0, '127.0.0.1')
  const port = relay.address().port
  const mac = await startFakeMac({
    relay: `127.0.0.1:${port}`,
    name: opts.name || '测试 Mac',
    home: macHome,
    auto: opts.auto !== false,
    deny: Boolean(opts.deny),
  })
  const env = { MACHANDS_HOME: agentHome, MACHANDS_LANG: 'zh' }
  t.after(async () => {
    mac.close()
    await relay.close()
    for (const d of [dataDir, macHome, agentHome, work]) rmSync(d, { recursive: true, force: true })
  })
  return { relay, port, mac, env, agentHome, work, dataDir }
}
