#!/usr/bin/env node
// 中继的实现挪到了 agent/src/relay-server.mjs —— 那里才会被打进 npm 包
// (agent/package.json 的 files 里有 src/),内测用户才装得到。
// 这个文件保留成薄壳:仓库里所有 `node relay/server.mjs`、install.sh、
// 以及测试里的 `from '../server.mjs'` 全都原样可用,不用改。
export * from '../agent/src/relay-server.mjs'

import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createRelay } from '../agent/src/relay-server.mjs'

const isMain = process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))
if (isMain) {
  const relay = createRelay({ configPath: process.argv[2] })
  await relay.listen()
  const a = relay.address()
  console.log(`MacHands relay 已启动 ${relay.cfg.tls ? 'wss' : 'ws'}://${a.address}:${a.port}`)
  console.log(`relayId ${relay.relayId}`)
  console.log(`数据目录 ${relay.cfg.dataDir}`)
  const bye = async () => { await relay.close(); process.exit(0) }
  process.on('SIGINT', bye)
  process.on('SIGTERM', bye)
}
