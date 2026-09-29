// 订单落盘 · 一单一个 JSON 文件,外加一个 order_id → 文件名的索引。
//
// 为什么不用数据库:一天几十单的量,文件就够了,而且出事时人能直接 cat 出来看。
// 幂等靠"先占坑再干活":claim() 用 O_EXCL 建文件,同一个 order_id 第二次推送会失败,
// 于是第二次推送直接读回第一次的结果,不会再签一张证。
//
// 目录结构(默认 /opt/machands/store):
//   orders/<provider>-<安全化的 order_id>.json   一单一文件
//   index.json                                   order_id → 文件名,给 list/resend 用

import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, renameSync, openSync, closeSync } from 'node:fs'
import { join, dirname } from 'node:path'

export const DEFAULT_ROOT = '/opt/machands/store'

/**
 * 文件名里只留安全字符,别让 provider 传来的 id 把我们写到别的目录去。
 *
 * 光换掉 `/` 还不够:连续的点(`..`)即使去了斜杠也该清掉——一是防着以后有人把这个名字
 * 拼进别的路径,二是 `..json` 这种名字纯属自找麻烦。所以点只允许单个出现。
 */
export function safeName(provider, orderId) {
  const clean = (s) =>
    String(s)
      .replace(/[^A-Za-z0-9._-]/g, '_')
      .replace(/\.{2,}/g, '_')
      .replace(/^[.]+/, '_')
      .slice(0, 120) || '_'
  return `${clean(provider)}-${clean(orderId)}.json`
}

/** 原子写:先写临时文件再 rename,断电也不会留下半个 JSON。 */
export function writeAtomic(path, text) {
  mkdirSync(dirname(path), { recursive: true })
  const tmp = `${path}.tmp-${process.pid}-${Date.now()}`
  writeFileSync(tmp, text, { mode: 0o600 })
  renameSync(tmp, path)
}

export class OrderStore {
  constructor(root = process.env.STORE_DIR || DEFAULT_ROOT) {
    this.root = root
    this.dir = join(root, 'orders')
    mkdirSync(this.dir, { recursive: true, mode: 0o700 })
  }

  path(provider, orderId) {
    return join(this.dir, safeName(provider, orderId))
  }

  /**
   * 占坑。抢到返回 true,已经有人抢过返回 false。
   * O_EXCL 是内核层面的原子操作,同一秒来两个重复推送也只有一个能进。
   */
  claim(provider, orderId, seed) {
    const p = this.path(provider, orderId)
    try {
      const fd = openSync(p, 'wx', 0o600)
      closeSync(fd)
    } catch (err) {
      if (err.code === 'EEXIST') return false
      throw err
    }
    // 占坑成功后立刻写进"处理中"的状态,中途崩了也看得出这单卡在哪。
    writeAtomic(p, JSON.stringify({ ...seed, state: 'claimed', claimed_at: new Date().toISOString() }, null, 2) + '\n')
    return true
  }

  get(provider, orderId) {
    const p = this.path(provider, orderId)
    if (!existsSync(p)) return null
    try {
      return JSON.parse(readFileSync(p, 'utf8'))
    } catch {
      return null
    }
  }

  put(record) {
    writeAtomic(this.path(record.provider, record.order_id), JSON.stringify(record, null, 2) + '\n')
    return record
  }

  /** 在已有记录上打补丁。记录不存在时返回 null(不凭空造单)。 */
  patch(provider, orderId, fields) {
    const cur = this.get(provider, orderId)
    if (!cur) return null
    return this.put({ ...cur, ...fields, updated_at: new Date().toISOString() })
  }

  list({ since = null } = {}) {
    const out = []
    for (const name of readdirSync(this.dir)) {
      if (!name.endsWith('.json') || name.includes('.tmp-')) continue
      try {
        const rec = JSON.parse(readFileSync(join(this.dir, name), 'utf8'))
        if (since && rec.created_at && rec.created_at < since) continue
        out.push(rec)
      } catch {
        // 半截文件不该让整个列表挂掉
      }
    }
    out.sort((a, b) => String(a.created_at || '').localeCompare(String(b.created_at || '')))
    return out
  }

  count() {
    return readdirSync(this.dir).filter((n) => n.endsWith('.json') && !n.includes('.tmp-')).length
  }
}
