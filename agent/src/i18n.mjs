// 面向用户的字符串都从这里取(铁律 3):zh 为准,en 兜底回 zh。
// 语言:MACHANDS_LANG=en 或 LANG 里带 en_ 时用英文。

const zh = {
  connected: (name) => `已连接 ${name}`,
  pairing: (host, port) => `正在连接中继 ${host}:${port} …`,
  pairWaiting: '正在等 Mac 确认(Mac 上不用点任何东西,几秒就好)…',
  pairOk: (name) => `已连接 ${name}`,
  pairDefault: (name) => `${name} 已设为默认 Mac。`,
  needCode: '用法:machands pair "<配对码>"(配对码在 Mac 上点“复制给 agent”得到)',
  badCode: (why) => `配对码看不懂:${why}`,
  errExpired: '这个配对码过期了。回 Mac 上点一次“复制给 agent”,拿一段新的。',
  errUsed: '这个配对码已经用过了(只能用一次)。回 Mac 上再点一次“复制给 agent”。',
  errDenied: 'Mac 上拒绝了这次连接。',
  errOfflineMac: 'Mac 现在不在线。确认 MacHands.app 开着,菜单栏有那只手。',
  errRelay: (host, port, why) => `连不上中继 ${host}:${port}:${why}`,
  noPairs: '还没有配对过的 Mac。先在 Mac 上点“复制给 agent”,把那一行贴过来执行。',
  noSuchMac: (name) => `没有叫 “${name}” 的 Mac。用 machands macs 看看都有哪些。`,
  manyMacs: '配对了多台 Mac,用 --mac <名字> 指定一台,或设 MACHANDS_MAC 环境变量。',
  offline: (name) => `${name} 不在线。确认那台 Mac 开着并且 MacHands.app 在跑。`,
  denied: '这条命令在 Mac 上被拒绝了。',
  timeout: 'Mac 上 120 秒没人点允许,这次算超时。',
  policy: (msg) => `被 Mac 的黑名单挡下了:${msg}`,
  license: '试用已结束,Mac 上需要填许可证才能继续执行命令。',
  online: '在线',
  offlineWord: '离线',
  unknown: '—',
  forgot: (name) => `已忘掉 ${name}(Mac 上的授权还在,想彻底断开就在 Mac 的设置里撤销这个 agent)。`,
  doctorHead: 'MacHands 自检',
  uploaded: (n, path) => `已上传 ${n} 字节 → ${path}`,
  downloaded: (n, path) => `已下载 ${n} 字节 → ${path}`,
  shotSaved: (path, w, h) => `截屏已保存 ${path}(${w}×${h})`,
  clipSet: '已写入 Mac 剪贴板。',
  hintHead: '接下来可以这样用:',
}

const en = {
  connected: (name) => `Connected to ${name}`,
  pairing: (host, port) => `Connecting to relay ${host}:${port} ...`,
  pairWaiting: 'Waiting for the Mac to confirm (nothing to click there, a few seconds)...',
  pairOk: (name) => `Connected to ${name}`,
  pairDefault: (name) => `${name} is now the default Mac.`,
  needCode: 'Usage: machands pair "<pairing code>" (get it from "Copy for agent" on the Mac)',
  badCode: (why) => `Cannot read that pairing code: ${why}`,
  errExpired: 'That pairing code expired. Click "Copy for agent" on the Mac again.',
  errUsed: 'That pairing code was already used (single use). Click "Copy for agent" again.',
  errDenied: 'The Mac refused this connection.',
  errOfflineMac: 'The Mac is offline. Make sure MacHands.app is running (hand icon in the menu bar).',
  errRelay: (host, port, why) => `Cannot reach relay ${host}:${port}: ${why}`,
  noPairs: 'No paired Mac yet. Click "Copy for agent" on the Mac and run the line it gives you.',
  noSuchMac: (name) => `No Mac named "${name}". Run machands macs to list them.`,
  manyMacs: 'Several Macs paired. Pick one with --mac <name> or set MACHANDS_MAC.',
  offline: (name) => `${name} is offline. Make sure that Mac is awake and MacHands.app is running.`,
  denied: 'The Mac denied this command.',
  timeout: 'Nobody approved it on the Mac within 120s.',
  policy: (msg) => `Blocked by the Mac's denylist: ${msg}`,
  license: 'Trial is over; enter a license on the Mac to keep running commands.',
  online: 'online',
  offlineWord: 'offline',
  unknown: '-',
  forgot: (name) => `Forgot ${name} (the Mac still lists this agent; revoke it there to fully cut access).`,
  doctorHead: 'MacHands self-check',
  uploaded: (n, path) => `Uploaded ${n} bytes to ${path}`,
  downloaded: (n, path) => `Downloaded ${n} bytes to ${path}`,
  shotSaved: (path, w, h) => `Screenshot saved to ${path} (${w}x${h})`,
  clipSet: 'Written to the Mac clipboard.',
  hintHead: 'Next:',
}

function pickLang() {
  const explicit = process.env.MACHANDS_LANG
  if (explicit) return explicit.toLowerCase().startsWith('en') ? 'en' : 'zh'
  const sys = process.env.LC_ALL || process.env.LC_MESSAGES || process.env.LANG || ''
  return /^en[_-]/i.test(sys) ? 'en' : 'zh'
}

export function t(key, ...args) {
  const table = pickLang() === 'en' ? en : zh
  const v = table[key] ?? zh[key]
  if (v === undefined) return key
  return typeof v === 'function' ? v(...args) : v
}
