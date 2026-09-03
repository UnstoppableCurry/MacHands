// stdio MCP 服务器 · SPEC §6.1,协议版本 2025-06-18。
// JSON-RPC 2.0,一行一条消息(MCP stdio 传输)。没有 SDK,自己拼。
import { connect, loadPairings, humanError, VERSION } from './cli.mjs'

export const PROTOCOL_VERSION = '2025-06-18'

const TOOLS = [
  {
    name: 'mac_info',
    description: '这台 Mac 的基本信息:机型、系统、架构、用户、Xcode/Node/Python 版本。',
    inputSchema: { type: 'object', properties: { mac: { type: 'string', description: '指定哪台 Mac(不填用默认)' } } },
  },
  {
    name: 'mac_run',
    description: '在 Mac 上执行一条命令(默认 /bin/zsh -lc)。返回 stdout、stderr 和退出码。用户可能需要在 Mac 上点允许。',
    inputSchema: {
      type: 'object',
      properties: {
        cmd: { type: 'string', description: '要执行的命令' },
        cwd: { type: 'string', description: '工作目录,支持 ~' },
        timeout: { type: 'number', description: '超时秒数,默认 600' },
        mac: { type: 'string' },
      },
      required: ['cmd'],
    },
  },
  {
    name: 'mac_put',
    description: '往 Mac 上写文件。content 是文本,base64 是二进制,二选一。',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string' },
        content: { type: 'string' },
        base64: { type: 'string' },
        mac: { type: 'string' },
      },
      required: ['path'],
    },
  },
  {
    name: 'mac_get',
    description: '读 Mac 上的文件(≤ 768 KiB;更大的先在 Mac 上压缩)。',
    inputSchema: { type: 'object', properties: { path: { type: 'string' }, mac: { type: 'string' } }, required: ['path'] },
  },
  {
    name: 'mac_ls',
    description: '列出 Mac 上某个目录。',
    inputSchema: {
      type: 'object',
      properties: { path: { type: 'string' }, depth: { type: 'number' }, mac: { type: 'string' } },
      required: ['path'],
    },
  },
  {
    name: 'mac_screenshot',
    description: '给 Mac 屏幕截一张图,直接返回图片。',
    inputSchema: {
      type: 'object',
      properties: { display: { type: 'number' }, scale: { type: 'number' }, mac: { type: 'string' } },
    },
  },
  {
    name: 'mac_open',
    description: '在 Mac 上打开一个网址或文件(等于 open 命令)。',
    inputSchema: { type: 'object', properties: { target: { type: 'string' }, mac: { type: 'string' } }, required: ['target'] },
  },
  {
    name: 'mac_clipboard_get',
    description: '读 Mac 的剪贴板文本。',
    inputSchema: { type: 'object', properties: { mac: { type: 'string' } } },
  },
  {
    name: 'mac_clipboard_set',
    description: '写 Mac 的剪贴板。',
    inputSchema: { type: 'object', properties: { text: { type: 'string' }, mac: { type: 'string' } }, required: ['text'] },
  },
  {
    name: 'mac_notify',
    description: '在 Mac 上弹一条通知给用户看。',
    inputSchema: {
      type: 'object',
      properties: { title: { type: 'string' }, body: { type: 'string' }, mac: { type: 'string' } },
      required: ['title'],
    },
  },
  {
    name: 'mac_list',
    description: '列出已配对的 Mac 和默认是哪台。',
    inputSchema: { type: 'object', properties: {} },
  },
]

const textResult = (text) => ({ content: [{ type: 'text', text }] })
const errResult = (text) => ({ content: [{ type: 'text', text }], isError: true })

async function withMac(mac, fn) {
  const { client, session } = await connect({ mac })
  try {
    return await fn(session)
  } finally {
    client.close()
  }
}

export async function callTool(name, args = {}) {
  switch (name) {
    case 'mac_list': {
      const macs = (loadPairings().macs || []).map((m) => ({ macId: m.macId, macName: m.macName, default: !!m.default }))
      return textResult(macs.length ? JSON.stringify(macs, null, 2) : '还没有配对过的 Mac。先在 Mac 上点“复制给 agent”。')
    }
    case 'mac_info':
      return withMac(args.mac, async (s) => textResult(JSON.stringify(await s.request('sys.info', {}, { timeoutMs: 30_000 }), null, 2)))
    case 'mac_run':
      return withMac(args.mac, async (s) => {
        let out = ''
        let err = ''
        const timeout = Number(args.timeout) || 600
        const r = await s.request(
          'run',
          { cmd: args.cmd, cwd: args.cwd, timeout },
          {
            timeoutMs: timeout * 1000 + 130_000,
            onStream: (x) => {
              if (x.o) out += x.o
              if (x.e) err += x.e
            },
          }
        )
        const body = [out, err && `[stderr]\n${err}`, `[退出码 ${r.code}${r.ms != null ? `,用时 ${r.ms} ms` : ''}]`]
          .filter(Boolean)
          .join('\n')
        return r.code === 0 ? textResult(body) : errResult(body)
      })
    case 'mac_put':
      return withMac(args.mac, async (s) => {
        const data = args.base64 ?? Buffer.from(args.content ?? '', 'utf8').toString('base64')
        const r = await s.request('fs.put', { path: args.path, data }, { timeoutMs: 180_000 })
        return textResult(`已写入 ${args.path}(${r.bytes ?? '?'} 字节)`)
      })
    case 'mac_get':
      return withMac(args.mac, async (s) => {
        const r = await s.request('fs.get', { path: args.path, offset: 0, length: 768 * 1024 }, { timeoutMs: 120_000 })
        const buf = Buffer.from(r.data || '', 'base64')
        const text = buf.toString('utf8')
        const looksBinary = text.includes('\u0000')
        return textResult(looksBinary ? `二进制文件,${buf.length} 字节,base64:\n${buf.toString('base64')}` : text)
      })
    case 'mac_ls':
      return withMac(args.mac, async (s) => {
        const r = await s.request('fs.ls', { path: args.path, depth: args.depth ?? 1 }, { timeoutMs: 60_000 })
        const lines = (r.entries || []).map((e) => `${e.type === 'dir' ? 'd' : '-'} ${String(e.size ?? 0).padStart(9)}  ${e.name}`)
        return textResult(lines.join('\n') || '(空目录)')
      })
    case 'mac_screenshot':
      return withMac(args.mac, async (s) => {
        const parts = []
        const r = await s.request(
          'screen.shot',
          { display: args.display ?? 0, scale: args.scale ?? 0.5, format: 'png' },
          { timeoutMs: 180_000, onStream: (x) => x.data && parts.push(Buffer.from(x.data, 'base64')) }
        )
        const png = Buffer.concat(parts)
        if (png.length === 0) return errResult('没拿到图像数据。可能是 Mac 上还没授权屏幕录制。')
        return {
          content: [
            { type: 'image', data: png.toString('base64'), mimeType: 'image/png' },
            { type: 'text', text: `${r.width ?? '?'}×${r.height ?? '?'},${png.length} 字节` },
          ],
        }
      })
    case 'mac_open':
      return withMac(args.mac, async (s) => {
        await s.request('open', { target: args.target }, { timeoutMs: 130_000 })
        return textResult(`已在 Mac 上打开 ${args.target}`)
      })
    case 'mac_clipboard_get':
      return withMac(args.mac, async (s) => textResult((await s.request('clip.get', {}, { timeoutMs: 130_000 })).text ?? ''))
    case 'mac_clipboard_set':
      return withMac(args.mac, async (s) => {
        await s.request('clip.set', { text: args.text }, { timeoutMs: 130_000 })
        return textResult('已写入 Mac 剪贴板。')
      })
    case 'mac_notify':
      return withMac(args.mac, async (s) => {
        await s.request('notify', { title: args.title, body: args.body ?? '' }, { timeoutMs: 60_000 })
        return textResult('已发到 Mac 的通知中心。')
      })
    default:
      return errResult(`没有 ${name} 这个工具。`)
  }
}

// ---------- JSON-RPC 帧 ----------

export async function handleRPC(msg) {
  const { id, method, params } = msg
  const reply = (result) => ({ jsonrpc: '2.0', id, result })
  const fail = (code, message) => ({ jsonrpc: '2.0', id, error: { code, message } })

  switch (method) {
    case 'initialize':
      return reply({
        protocolVersion: PROTOCOL_VERSION,
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: 'machands', version: VERSION },
        instructions: '这些工具作用在用户的 Mac 上。用户可能会看到审批卡,被拒绝时会返回 DENIED。',
      })
    case 'notifications/initialized':
    case 'notifications/cancelled':
      return null
    case 'ping':
      return reply({})
    case 'tools/list':
      return reply({ tools: TOOLS })
    case 'tools/call': {
      const name = params?.name
      try {
        return reply(await callTool(name, params?.arguments || {}))
      } catch (err) {
        return reply(errResult(humanError(err)))
      }
    }
    case 'resources/list':
      return reply({ resources: [] })
    case 'prompts/list':
      return reply({ prompts: [] })
    default:
      if (id === undefined) return null
      return fail(-32601, `没有 ${method} 这个方法`)
  }
}

export function serveMCP({ input = process.stdin, output = process.stdout } = {}) {
  return new Promise((resolve) => {
    let buf = ''
    let chain = Promise.resolve() // 一条一条处理,保证顺序
    input.setEncoding('utf8')
    input.on('data', (chunk) => {
      buf += chunk
      let nl
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl).trim()
        buf = buf.slice(nl + 1)
        if (!line) continue
        let msg
        try {
          msg = JSON.parse(line)
        } catch {
          chain = chain.then(() =>
            output.write(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: '不是合法 JSON' } }) + '\n')
          )
          continue
        }
        chain = chain.then(async () => {
          const res = await handleRPC(msg).catch((err) => ({
            jsonrpc: '2.0',
            id: msg.id ?? null,
            error: { code: -32603, message: err?.message || String(err) },
          }))
          if (res) output.write(JSON.stringify(res) + '\n')
        })
      }
    })
    input.on('end', resolve)
    input.on('close', resolve)
  })
}

export { TOOLS }
