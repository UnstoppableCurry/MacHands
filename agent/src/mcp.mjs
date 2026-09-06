// stdio MCP 服务器 · SPEC §6.1 / §12.1,协议版本 2025-06-18。
// JSON-RPC 2.0,一行一条消息(MCP stdio 传输)。没有 SDK,自己拼。
import { writeFileSync, mkdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, basename, dirname } from 'node:path'
import { execFile } from 'node:child_process'
import { connect, loadPairings, humanError, VERSION } from './cli.mjs'

export const PROTOCOL_VERSION = '2025-06-18'

// 与 Executor.maxRead 一致:Mac 端每次最多给 512 KiB,多要也只给这么多,所以 mac_get 必须循环到 eof。
const GET_CHUNK = 512 * 1024
// 二进制文件不带 out 时,超过这个尺寸就落盘报路径,不往对话里塞 base64
const INLINE_BINARY_MAX = 256 * 1024

const macProp = { mac: { type: 'string', description: '指定哪台 Mac(不填用默认)' } }
// 审批卡上人要看懂的是"这个 agent 想干什么",不是一条 shell 命令。
const whyProp = {
  why: {
    type: 'string',
    description:
      '用一句人话说明你要达成什么目的,会显示给 Mac 前的人看;不要复述命令。' +
      '好:"确认雪场地形改完之后的样子";坏:"运行 screencapture"。',
  },
}
const withWhy = (args, params) => (args?.why ? { ...params, why: String(args.why).slice(0, 120) } : params)
const idProp = (name, description) => ({ [name]: { type: 'string', description } })

const TOOLS = [
  {
    name: 'mac_info',
    description: '这台 Mac 的开工体检:机型、系统、内存、磁盘、CPU/GPU、显示器、装了哪些工具(godot/blender/xcodebuild…)。',
    inputSchema: { type: 'object', properties: { ...macProp } },
  },
  {
    name: 'mac_run',
    description: '在 Mac 上执行一条命令(默认 /bin/zsh -lc)并等它结束。返回 stdout、stderr 和退出码。要跑很久的用 mac_job_submit。',
    inputSchema: {
      type: 'object',
      properties: {
        cmd: { type: 'string', description: '要执行的命令' },
        cwd: { type: 'string', description: '工作目录,支持 ~' },
        timeout: { type: 'number', description: '超时秒数,默认 600;超时会杀整棵进程树' },
        ...macProp,
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
        ...macProp,
      },
      required: ['path'],
    },
  },
  {
    name: 'mac_get',
    description:
      '读 Mac 上的文件或目录,分块循环到读完,绝不截断。文本直接返回;二进制给 out 就落盘到 out,否则小的给 base64、大的落到临时文件报路径;目录打成 tar.gz 落到 <out|临时目录>/<名>.tar.gz 并附文件清单。',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'Mac 上的路径,支持 ~' },
        out: { type: 'string', description: '本地保存路径(可选)。目录时是 tar.gz 的落点' },
        ...macProp,
      },
      required: ['path'],
    },
  },
  {
    name: 'mac_ls',
    description: '列出 Mac 上某个目录。',
    inputSchema: {
      type: 'object',
      properties: { path: { type: 'string' }, depth: { type: 'number' }, ...macProp },
      required: ['path'],
    },
  },
  {
    name: 'mac_screenshot',
    description: '给 Mac 整个屏幕截一张图,直接返回图片。只要某个窗口用 mac_window_shot。',
    inputSchema: {
      type: 'object',
      properties: { display: { type: 'number' }, scale: { type: 'number' }, ...macProp },
    },
  },
  {
    name: 'mac_window_shot',
    description: '只截一个窗口:不给 app 就截前台窗口,给 app(和可选 title)按名字匹配。直接返回图片,给 out 也落盘。',
    inputSchema: {
      type: 'object',
      properties: {
        app: { type: 'string', description: 'App 名,子串匹配,不区分大小写' },
        title: { type: 'string', description: '窗口标题子串(可选)' },
        scale: { type: 'number', description: '缩放,默认 0.5' },
        format: { type: 'string', enum: ['png', 'jpg'] },
        out: { type: 'string', description: '本地保存路径(可选)' },
        ...macProp,
      },
    },
  },
  {
    name: 'mac_record',
    description: '录一段 Mac 屏幕(≤120 秒,.mov)落到本地文件,返回路径与字节数。看动态效果、手感测试用。',
    inputSchema: {
      type: 'object',
      properties: {
        seconds: { type: 'number', description: '录多少秒,1–120,默认 5' },
        display: { type: 'number', description: '显示器序号,默认 0' },
        out: { type: 'string', description: '本地 .mov 路径,默认放临时目录' },
        ...macProp,
      },
    },
  },
  {
    name: 'mac_input',
    description:
      '在 Mac 上动键盘鼠标(需要辅助功能权限)。action: where(光标在哪) move click drag scroll key type;坐标与截图同一套(顶左原点,像素)。',
    inputSchema: {
      type: 'object',
      properties: {
        action: { type: 'string', enum: ['where', 'move', 'click', 'drag', 'scroll', 'key', 'type'] },
        x: { type: 'number' },
        y: { type: 'number' },
        x2: { type: 'number', description: 'drag 的终点' },
        y2: { type: 'number', description: 'drag 的终点' },
        button: { type: 'string', enum: ['left', 'right'], description: 'click 用,默认 left' },
        count: { type: 'number', description: 'click 次数,2 = 双击' },
        ms: { type: 'number', description: 'drag 用时,默认 300' },
        dx: { type: 'number', description: 'scroll 横向' },
        dy: { type: 'number', description: 'scroll 纵向,正数向下' },
        key: { type: 'string', description: 'key 用:单字符或 enter tab esc space up down left right f1..f12 delete' },
        mods: { type: 'array', items: { type: 'string', enum: ['cmd', 'shift', 'alt', 'ctrl'] } },
        text: { type: 'string', description: 'type 用:要敲进去的文本' },
        ...macProp,
      },
      required: ['action'],
    },
  },
  {
    name: 'mac_open',
    description: '在 Mac 上打开一个网址或文件(等于 open 命令)。',
    inputSchema: { type: 'object', properties: { target: { type: 'string' }, ...macProp }, required: ['target'] },
  },
  {
    name: 'mac_clipboard_get',
    description: '读 Mac 的剪贴板文本。',
    inputSchema: { type: 'object', properties: { ...macProp } },
  },
  {
    name: 'mac_clipboard_set',
    description: '写 Mac 的剪贴板。',
    inputSchema: { type: 'object', properties: { text: { type: 'string' }, ...macProp }, required: ['text'] },
  },
  {
    name: 'mac_notify',
    description: '在 Mac 上弹一条通知给用户看。',
    inputSchema: {
      type: 'object',
      properties: { title: { type: 'string' }, body: { type: 'string' }, ...macProp },
      required: ['title'],
    },
  },
  {
    name: 'mac_list',
    description: '列出已配对的 Mac 和默认是哪台。',
    inputSchema: { type: 'object', properties: {} },
  },
  // ---- v0.2:一次授权 / 自检 / 预判 ----
  {
    name: 'mac_perms',
    description: '看 Mac 上三项系统权限(屏幕录制、辅助功能、通知)有没有授。截图或键鼠失败时先查这个。',
    inputSchema: { type: 'object', properties: { ...macProp } },
  },
  {
    name: 'mac_which',
    description: '查 Mac 上装了哪些命令行工具(路径或 null)。不给 names 就查 godot/blender/xcodebuild/swift/node/python3/brew/cliclick/ffmpeg/git。',
    inputSchema: {
      type: 'object',
      properties: { names: { type: 'array', items: { type: 'string' } }, ...macProp },
    },
  },
  {
    name: 'mac_check',
    description: '干跑:问 Mac 的策略某条命令会 allow、ask 还是 deny,不执行也不记审计。会被拒的命令别再试,换个写法。',
    inputSchema: {
      type: 'object',
      properties: {
        subject: { type: 'string', description: '要检查的命令(method=run 时)或路径' },
        method: { type: 'string', description: 'RPC 方法名,默认 run' },
        ...macProp,
      },
      required: ['subject'],
    },
  },
  {
    name: 'mac_verify',
    description: '在 Mac 上跑一遍授权自检(执行命令、读写文件、截屏、键鼠、通知、后台作业、MCP 桥),✓/✗ 加修复指引。开工前或出怪问题时用。',
    inputSchema: { type: 'object', properties: { ...macProp } },
  },
  // ---- v0.2:后台作业 ----
  {
    name: 'mac_job_submit',
    description: '提交一个后台作业立刻返回 jobId(构建、渲染、跑测试这类几分钟到几小时的活)。输出落在 Mac 上,断线不丢;超时杀整棵进程树。',
    inputSchema: {
      type: 'object',
      properties: {
        cmd: { type: 'string' },
        cwd: { type: 'string' },
        env: { type: 'object', additionalProperties: { type: 'string' } },
        timeout: { type: 'number', description: '秒,默认 3600' },
        ...macProp,
      },
      required: ['cmd'],
    },
  },
  {
    name: 'mac_job_status',
    description: '看一个后台作业的状态:running/exited/killed/orphaned、退出码、已用时间、输出字节数。',
    inputSchema: { type: 'object', properties: { ...idProp('jobId', '作业 id'), ...macProp }, required: ['jobId'] },
  },
  {
    name: 'mac_job_tail',
    description: '从 offset 起读一个后台作业的 stdout(或 stderr),一次最多 512 KiB;返回里有下一次的 offset 和是否读完。',
    inputSchema: {
      type: 'object',
      properties: {
        ...idProp('jobId', '作业 id'),
        stream: { type: 'string', enum: ['out', 'err'], description: '默认 out' },
        offset: { type: 'number', description: '从哪个字节开始,默认 0' },
        ...macProp,
      },
      required: ['jobId'],
    },
  },
  {
    name: 'mac_job_result',
    description: '等一个后台作业结束(最多 wait 秒,默认 60)并返回状态与 stdout/stderr 尾部。没结束就返回当前状态,不算错。',
    inputSchema: {
      type: 'object',
      properties: { ...idProp('jobId', '作业 id'), wait: { type: 'number', description: '最多等几秒,≤600' }, ...macProp },
      required: ['jobId'],
    },
  },
  {
    name: 'mac_job_kill',
    description: '终止一个正在跑的后台作业(整棵进程树)。',
    inputSchema: { type: 'object', properties: { ...idProp('jobId', '作业 id'), ...macProp }, required: ['jobId'] },
  },
  {
    name: 'mac_job_list',
    description: '列出 Mac 上所有后台作业(含 App 重启前的)。',
    inputSchema: { type: 'object', properties: { ...macProp } },
  },
  // ---- v0.2:交互会话 ----
  {
    name: 'mac_session_open',
    description: '在 Mac 上开一个有 stdin 的长命进程(默认交互 shell,也可以是 python3 / godot 这类 REPL),返回 sessionId。',
    inputSchema: {
      type: 'object',
      properties: {
        cmd: { type: 'string', description: '不填就是登录 shell' },
        cwd: { type: 'string' },
        env: { type: 'object', additionalProperties: { type: 'string' } },
        ...macProp,
      },
    },
  },
  {
    name: 'mac_session_write',
    description: '往会话的 stdin 写一行(自动补换行,除非 newline=false)。',
    inputSchema: {
      type: 'object',
      properties: {
        ...idProp('sessionId', '会话 id'),
        data: { type: 'string' },
        newline: { type: 'boolean', description: '默认 true' },
        ...macProp,
      },
      required: ['sessionId', 'data'],
    },
  },
  {
    name: 'mac_session_read',
    description: '从 offset 起读会话的合并输出(stdout+stderr),返回文本、下一次 offset、进程是否还活着。',
    inputSchema: {
      type: 'object',
      properties: { ...idProp('sessionId', '会话 id'), offset: { type: 'number' }, ...macProp },
      required: ['sessionId'],
    },
  },
  {
    name: 'mac_session_close',
    description: '关掉一个会话(关 stdin,进程还活着就杀整棵树)。',
    inputSchema: { type: 'object', properties: { ...idProp('sessionId', '会话 id'), ...macProp }, required: ['sessionId'] },
  },
  // ---- v0.2:MCP 桥 ----
  {
    name: 'mac_mcp_servers',
    description: '列出 Mac 上各家 agent(Claude Code / Codex / Cursor / Claude Desktop)配置里的 MCP 服务(不含 env 值)。',
    inputSchema: { type: 'object', properties: { ...macProp } },
  },
  {
    name: 'mac_mcp_open',
    description: '在 Mac 上启动一个 stdio MCP 服务(按配置里的 name,或直接给 command/args)并完成握手,返回 sessionId 和它的工具表。',
    inputSchema: {
      type: 'object',
      properties: {
        name: { type: 'string', description: 'mac_mcp_servers 里的名字' },
        command: { type: 'string', description: '不用配置时直接给可执行文件' },
        args: { type: 'array', items: { type: 'string' } },
        env: { type: 'object', additionalProperties: { type: 'string' } },
        cwd: { type: 'string' },
        ...macProp,
      },
    },
  },
  {
    name: 'mac_mcp_call',
    description: '调用 Mac 上已打开的 MCP 服务的一个工具,结果(文本/图片)原样透传。',
    inputSchema: {
      type: 'object',
      properties: {
        ...idProp('sessionId', 'mac_mcp_open 返回的 id'),
        tool: { type: 'string' },
        args: { type: 'object', additionalProperties: true },
        timeout: { type: 'number', description: '秒,默认 120' },
        ...macProp,
      },
      required: ['sessionId', 'tool'],
    },
  },
  {
    name: 'mac_mcp_close',
    description: '关掉 Mac 上一个 MCP 服务会话。',
    inputSchema: { type: 'object', properties: { ...idProp('sessionId', 'mac_mcp_open 返回的 id'), ...macProp }, required: ['sessionId'] },
  },
  // ---- v0.2:自救 ----
  {
    name: 'mac_power',
    description: '让 Mac 别睡:action=on 保持唤醒 seconds 秒(默认 3600,≤14400),action=off 解除。跑长任务前用。',
    inputSchema: {
      type: 'object',
      properties: { action: { type: 'string', enum: ['on', 'off'] }, seconds: { type: 'number' }, ...macProp },
      required: ['action'],
    },
  },
  {
    name: 'mac_relaunch',
    description: '让 Mac 上的 MacHands App 自己重启(装了新版本之后用)。几秒后它会重新上线。',
    inputSchema: { type: 'object', properties: { ...macProp } },
  },
  // ---- v0.3:自更新 / 体检 / 看自己的界面 ----
  {
    name: 'mac_doctor',
    description:
      '查 Mac 上 MacHands 这个 App 本身:版本、装在哪、是不是从 DMG 直接跑的、签名、公证、三项权限、会不会自己更新,以及**是不是装了多份**。'
      + '命令时灵时不灵、方法忽然不存在、权限反复要重授,先跑这个。',
    inputSchema: { type: 'object', properties: { ...macProp } },
  },
  {
    name: 'mac_update',
    description:
      '让 Mac 上的 MacHands 自己就地升级(不是重新下载装到别处 —— 那样系统权限会丢)。check=true 只看有没有新版本。'
      + '升级后 App 自己重启,几秒内会重新上线。',
    inputSchema: { type: 'object', properties: { check: { type: 'boolean', description: '只看不装' }, ...macProp } },
  },
  {
    name: 'mac_selfshot',
    description:
      '截 MacHands 自己的界面(主窗口 / 审批卡),不需要屏幕录制权限 —— 屏幕录制没授权时也能看。'
      + '要看整个桌面用 mac_screenshot。',
    inputSchema: {
      type: 'object',
      properties: {
        window: { type: 'string', enum: ['main', 'approval', 'all'], description: '截哪个,默认 main' },
        scale: { type: 'number' },
        format: { type: 'string', enum: ['png', 'jpg'] },
        out: { type: 'string', description: '本地保存路径(可选)' },
        ...macProp,
      },
    },
  },
  {
    name: 'mac_show_window',
    description: '打开并激活 Mac 上 MacHands 的主窗口(要让用户去点授权页时用)。',
    inputSchema: { type: 'object', properties: { ...macProp } },
  },
]

// 会弹审批卡的工具:schema 里把 why 标成必填,模型自然会写上目的。
// 运行时是宽松的(老客户端不填也不报错),App 那边会退回显示命令本身。
const NEEDS_WHY = new Set([
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
])
for (const tool of TOOLS) {
  if (!NEEDS_WHY.has(tool.name)) continue
  tool.inputSchema.properties = { ...tool.inputSchema.properties, ...whyProp }
  tool.inputSchema.required = [...new Set([...(tool.inputSchema.required || []), 'why'])]
  tool.description += ' 必须填 why:一句人话说明你要达成什么,Mac 前的人看到的是它。'
}

const textResult = (text) => ({ content: [{ type: 'text', text }] })
const errResult = (text) => ({ content: [{ type: 'text', text }], isError: true })
const pretty = (x) => JSON.stringify(x, null, 2)

async function withMac(mac, fn) {
  const { client, session } = await connect({ mac })
  try {
    return await fn(session)
  } finally {
    client.close()
  }
}

// 收一条"流块 + 结束帧"型的二进制回应(截图、录屏、目录包)
async function collectStream(s, method, params, timeoutMs) {
  const parts = []
  const r = await s.request(method, params, { timeoutMs, onStream: (x) => x.data && parts.push(Buffer.from(x.data, 'base64')) })
  return { r, buf: Buffer.concat(parts) }
}

function saveTo(path, buf) {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, buf)
  return path
}

function listArchive(path) {
  return new Promise((res) => {
    execFile('tar', ['tzf', path], { maxBuffer: 8 * 1024 * 1024 }, (err, stdout) => res(err ? null : stdout.split('\n').filter(Boolean)))
  })
}

function imageResult(buf, r, format, note) {
  if (buf.length === 0) return errResult('没拿到图像数据。可能是 Mac 上还没授权屏幕录制(用 mac_perms 查)。')
  return {
    content: [
      { type: 'image', data: buf.toString('base64'), mimeType: format === 'jpg' ? 'image/jpeg' : 'image/png' },
      { type: 'text', text: `${r.width ?? '?'}×${r.height ?? '?'},${buf.length} 字节${note ? ',' + note : ''}` },
    ],
  }
}

function verifyLines(rows) {
  return rows.map((row) => (row.ok ? `✓ ${row.name}  ${row.detail ?? ''}` : `✗ ${row.name}  ${row.detail ?? ''}${row.fix ? ' → ' + row.fix : ''}`))
}

const b64text = (data) => Buffer.from(data || '', 'base64').toString('utf8')

export async function callTool(name, args = {}) {
  switch (name) {
    case 'mac_list': {
      const macs = (loadPairings().macs || []).map((m) => ({ macId: m.macId, macName: m.macName, default: !!m.default }))
      return textResult(macs.length ? pretty(macs) : '还没有配对过的 Mac。先在 Mac 上点“复制给 agent”。')
    }
    case 'mac_info':
      return withMac(args.mac, async (s) => textResult(pretty(await s.request('sys.info', {}, { timeoutMs: 60_000 }))))
    case 'mac_run':
      return withMac(args.mac, async (s) => {
        let out = ''
        let err = ''
        const timeout = Number(args.timeout) || 600
        const r = await s.request(
          'run',
          withWhy(args, { cmd: args.cmd, cwd: args.cwd, timeout }),
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
        const r = await s.request('fs.put', withWhy(args, { path: args.path, data }), { timeoutMs: 180_000 })
        return textResult(`已写入 ${args.path}(${r.bytes ?? '?'} 字节)`)
      })
    case 'mac_get':
      return withMac(args.mac, async (s) => {
        const parts = []
        let offset = 0
        let archive = null
        for (;;) {
          const r = await s.request(
            'fs.get',
            withWhy(args, { path: args.path, offset, length: GET_CHUNK }),
            { timeoutMs: 300_000, onStream: (x) => x.data && parts.push(Buffer.from(x.data, 'base64')) }
          )
          if (r.archive) {
            archive = r
            break
          }
          const buf = Buffer.from(r.data || '', 'base64')
          parts.push(buf)
          offset += buf.length
          if (r.eof || buf.length === 0) break
        }
        const all = Buffer.concat(parts)
        const remoteName = basename(String(args.path).replace(/\/+$/, '')) || 'download'
        if (archive) {
          const target = args.out
            ? args.out.endsWith('.tar.gz') || args.out.endsWith('.tgz')
              ? args.out
              : join(args.out, `${archive.name || remoteName}.tar.gz`)
            : join(tmpdir(), `machands-get-${Date.now()}`, `${archive.name || remoteName}.tar.gz`)
          saveTo(target, all)
          const entries = await listArchive(target)
          const listing = entries
            ? entries.length > 200
              ? entries.slice(0, 200).join('\n') + `\n… 共 ${entries.length} 项`
              : entries.join('\n')
            : '(本机没有 tar,列不出清单)'
          return textResult(`${args.path} 在 Mac 上是目录,已打包成 ${all.length} 字节的 tar.gz 落到本地:\n${target}\n解包:tar xzf ${target} -C <目标目录>\n\n清单:\n${listing}`)
        }
        if (args.out) {
          saveTo(args.out, all)
          return textResult(`已保存 ${all.length} 字节到 ${args.out}`)
        }
        const text = all.toString('utf8')
        const looksBinary = text.includes('\u0000')
        if (!looksBinary) return textResult(text)
        if (all.length <= INLINE_BINARY_MAX) return textResult(`二进制文件,${all.length} 字节,base64:\n${all.toString('base64')}`)
        const target = join(tmpdir(), `machands-get-${Date.now()}`, remoteName)
        saveTo(target, all)
        return textResult(`二进制文件,${all.length} 字节,完整落到本地:${target}(给 out 参数可以指定路径)`)
      })
    case 'mac_ls':
      return withMac(args.mac, async (s) => {
        const r = await s.request('fs.ls', { path: args.path, depth: args.depth ?? 1 }, { timeoutMs: 60_000 })
        const lines = (r.entries || []).map((e) => `${e.type === 'dir' ? 'd' : '-'} ${String(e.size ?? 0).padStart(9)}  ${e.name}`)
        return textResult(lines.join('\n') || '(空目录)')
      })
    case 'mac_screenshot':
      return withMac(args.mac, async (s) => {
        const { r, buf } = await collectStream(s, 'screen.shot', withWhy(args, { display: args.display ?? 0, scale: args.scale ?? 0.5, format: 'png' }), 180_000)
        return imageResult(buf, r, 'png')
      })
    case 'mac_window_shot':
      return withMac(args.mac, async (s) => {
        const format = args.format === 'jpg' ? 'jpg' : 'png'
        const { r, buf } = await collectStream(
          s,
          'screen.window',
          withWhy(args, { app: args.app, title: args.title, scale: args.scale ?? 0.5, format }),
          180_000
        )
        let note = ''
        if (args.out && buf.length) note = `已保存到 ${saveTo(args.out, buf)}`
        return imageResult(buf, r, format, note)
      })
    case 'mac_record':
      return withMac(args.mac, async (s) => {
        const seconds = Math.min(120, Math.max(1, Number(args.seconds) || 5))
        const { r, buf } = await collectStream(s, 'screen.record', withWhy(args, { seconds, display: args.display ?? 0 }), seconds * 1000 + 180_000)
        if (buf.length === 0) return errResult('没拿到视频数据。可能是 Mac 上还没授权屏幕录制(用 mac_perms 查)。')
        const target = saveTo(args.out || join(tmpdir(), `machands-record-${Date.now()}.mov`), buf)
        if (r.bytes != null && r.bytes !== buf.length) return errResult(`录屏不完整:Mac 说 ${r.bytes} 字节,收到 ${buf.length} 字节。文件在 ${target}`)
        return textResult(`已录 ${r.seconds ?? seconds} 秒,${buf.length} 字节 .mov 落到 ${target}`)
      })
    case 'mac_input':
      return withMac(args.mac, async (s) => {
        const t = 60_000
        switch (args.action) {
          case 'where': {
            const r = await s.request('input.where', withWhy(args, {}), { timeoutMs: t })
            return textResult(JSON.stringify({ x: r.x, y: r.y }))
          }
          case 'move':
            await s.request('input.move', withWhy(args, { x: args.x, y: args.y }), { timeoutMs: t })
            return textResult(`光标已移到 (${args.x},${args.y})`)
          case 'click':
            await s.request('input.click', withWhy(args, { x: args.x, y: args.y, button: args.button || 'left', count: args.count || 1 }), { timeoutMs: t })
            return textResult(`已${args.count > 1 ? '双' : ''}击 (${args.x},${args.y})${args.button === 'right' ? ' 右键' : ''}`)
          case 'drag':
            await s.request('input.drag', withWhy(args, { x1: args.x, y1: args.y, x2: args.x2, y2: args.y2, ms: args.ms || 300 }), { timeoutMs: t })
            return textResult(`已从 (${args.x},${args.y}) 拖到 (${args.x2},${args.y2})`)
          case 'scroll':
            await s.request('input.scroll', withWhy(args, { x: args.x, y: args.y, dx: args.dx || 0, dy: args.dy || 0 }), { timeoutMs: t })
            return textResult(`已在 (${args.x},${args.y}) 滚动 dx=${args.dx || 0} dy=${args.dy || 0}`)
          case 'key':
            await s.request('input.key', withWhy(args, { key: args.key, mods: args.mods || [] }), { timeoutMs: t })
            return textResult(`已按 ${(args.mods || []).concat([args.key]).join('+')}`)
          case 'type':
            await s.request('input.type', withWhy(args, { text: args.text ?? '' }), { timeoutMs: t })
            return textResult(`已输入 ${(args.text ?? '').length} 个字符`)
          default:
            return errResult(`action 只能是 where/move/click/drag/scroll/key/type,不是 ${args.action}`)
        }
      })
    case 'mac_open':
      return withMac(args.mac, async (s) => {
        await s.request('open', withWhy(args, { target: args.target }), { timeoutMs: 130_000 })
        return textResult(`已在 Mac 上打开 ${args.target}`)
      })
    case 'mac_clipboard_get':
      return withMac(args.mac, async (s) => textResult((await s.request('clip.get', {}, { timeoutMs: 130_000 })).text ?? ''))
    case 'mac_clipboard_set':
      return withMac(args.mac, async (s) => {
        await s.request('clip.set', withWhy(args, { text: args.text }), { timeoutMs: 130_000 })
        return textResult('已写入 Mac 剪贴板。')
      })
    case 'mac_notify':
      return withMac(args.mac, async (s) => {
        await s.request('notify', { title: args.title, body: args.body ?? '' }, { timeoutMs: 60_000 })
        return textResult('已发到 Mac 的通知中心。')
      })
    // ---- v0.2 ----
    case 'mac_perms':
      return withMac(args.mac, async (s) => textResult(pretty(await s.request('sys.perms', {}, { timeoutMs: 30_000 }))))
    case 'mac_which':
      return withMac(args.mac, async (s) => {
        const p = Array.isArray(args.names) && args.names.length ? { names: args.names } : {}
        return textResult(pretty(await s.request('sys.which', p, { timeoutMs: 60_000 })))
      })
    case 'mac_check':
      return withMac(args.mac, async (s) => {
        const r = await s.request('policy.check', { method: args.method || 'run', subject: args.subject ?? '' }, { timeoutMs: 30_000 })
        const line = r.decision === 'allow' ? 'allow' : `${r.decision}${r.reason ? ' — ' + r.reason : ''}`
        return textResult(pretty({ decision: r.decision, method: r.method ?? args.method ?? 'run', reason: r.reason, summary: line }))
      })
    case 'mac_verify':
      return withMac(args.mac, async (s) => {
        const r = await s.request('verify.run', {}, { timeoutMs: 180_000 })
        const rows = r.rows || []
        const failed = rows.filter((x) => !x.ok).length
        const body = verifyLines(rows).join('\n') + `\n${failed ? `${failed} 项没过` : '全部通过'}`
        return failed ? errResult(body) : textResult(body)
      })
    case 'mac_job_submit':
      return withMac(args.mac, async (s) => {
        const r = await s.request('job.submit', withWhy(args, { cmd: args.cmd, cwd: args.cwd, env: args.env, timeout: args.timeout }), { timeoutMs: 60_000 })
        return textResult(pretty({ jobId: r.jobId }))
      })
    case 'mac_job_status':
      return withMac(args.mac, async (s) => textResult(pretty(await s.request('job.status', { jobId: args.jobId }, { timeoutMs: 30_000 }))))
    case 'mac_job_tail':
      return withMac(args.mac, async (s) => {
        const r = await s.request('job.tail', { jobId: args.jobId, stream: args.stream || 'out', offset: args.offset || 0 }, { timeoutMs: 60_000 })
        const text = b64text(r.data)
        return textResult(`${text}${text && !text.endsWith('\n') ? '\n' : ''}[offset=${r.offset} eof=${r.eof}]`)
      })
    case 'mac_job_result':
      return withMac(args.mac, async (s) => {
        const wait = Math.min(600, Math.max(0, Number(args.wait) || 60))
        const r = await s.request('job.result', { jobId: args.jobId, wait }, { timeoutMs: wait * 1000 + 60_000 })
        const tails = []
        for (const stream of ['out', 'err']) {
          const size = stream === 'out' ? r.outBytes : r.errBytes
          if (!size) continue
          const t = await s.request('job.tail', { jobId: args.jobId, stream, offset: Math.max(0, size - 64 * 1024) }, { timeoutMs: 60_000 })
          tails.push(`--- ${stream === 'out' ? 'stdout' : 'stderr'}${size > 64 * 1024 ? '(最后 64 KiB)' : ''} ---\n${b64text(t.data)}`)
        }
        const body = [pretty(r), ...tails].join('\n')
        const bad = r.state !== 'running' && r.code !== 0
        return bad ? errResult(body) : textResult(body)
      })
    case 'mac_job_kill':
      return withMac(args.mac, async (s) => {
        await s.request('job.kill', { jobId: args.jobId }, { timeoutMs: 60_000 })
        return textResult(`已终止作业 ${args.jobId}`)
      })
    case 'mac_job_list':
      return withMac(args.mac, async (s) => textResult(pretty((await s.request('job.list', {}, { timeoutMs: 30_000 })).jobs || [])))
    case 'mac_session_open':
      return withMac(args.mac, async (s) => {
        const r = await s.request('session.open', withWhy(args, { cmd: args.cmd, cwd: args.cwd, env: args.env }), { timeoutMs: 60_000 })
        return textResult(pretty({ sessionId: r.sessionId }))
      })
    case 'mac_session_write':
      return withMac(args.mac, async (s) => {
        const data = args.newline === false ? String(args.data ?? '') : String(args.data ?? '') + '\n'
        await s.request('session.write', withWhy(args, { sessionId: args.sessionId, data }), { timeoutMs: 60_000 })
        return textResult(`已写入 ${data.length} 个字符`)
      })
    case 'mac_session_read':
      return withMac(args.mac, async (s) => {
        const r = await s.request('session.read', { sessionId: args.sessionId, offset: args.offset || 0 }, { timeoutMs: 60_000 })
        const text = r.data ?? ''
        return textResult(`${text}${text && !text.endsWith('\n') ? '\n' : ''}[offset=${r.offset} alive=${r.alive} eof=${r.eof}]`)
      })
    case 'mac_session_close':
      return withMac(args.mac, async (s) => {
        await s.request('session.close', { sessionId: args.sessionId }, { timeoutMs: 60_000 })
        return textResult(`已关闭会话 ${args.sessionId}`)
      })
    case 'mac_mcp_servers':
      return withMac(args.mac, async (s) => textResult(pretty((await s.request('mcp.servers', {}, { timeoutMs: 60_000 })).servers || [])))
    case 'mac_mcp_open':
      return withMac(args.mac, async (s) => {
        const r = await s.request(
          'mcp.open',
          { name: args.name, command: args.command, args: args.args, env: args.env, cwd: args.cwd },
          { timeoutMs: 180_000 }
        )
        return textResult(pretty({ sessionId: r.sessionId, name: r.name, tools: (r.tools || []).map((t) => ({ name: t.name, description: t.description })) }))
      })
    case 'mac_mcp_call':
      return withMac(args.mac, async (s) => {
        const timeout = Math.min(600, Math.max(5, Number(args.timeout) || 120))
        const r = await s.request(
          'mcp.call',
          withWhy(args, { sessionId: args.sessionId, tool: args.tool, args: args.args || {}, timeout }),
          { timeoutMs: timeout * 1000 + 60_000 }
        )
        // MCP 的 result 原样透传:content 是数组就直接给(文本/图片都能过),否则整个包成文本
        if (Array.isArray(r?.content)) return r.isError ? { content: r.content, isError: true } : { content: r.content }
        return textResult(pretty(r))
      })
    case 'mac_mcp_close':
      return withMac(args.mac, async (s) => {
        await s.request('mcp.close', { sessionId: args.sessionId }, { timeoutMs: 60_000 })
        return textResult(`已关闭 MCP 会话 ${args.sessionId}`)
      })
    case 'mac_power':
      return withMac(args.mac, async (s) => {
        if (args.action === 'off') {
          await s.request('power.release', {}, { timeoutMs: 30_000 })
          return textResult('已解除保持唤醒。')
        }
        if (args.action !== 'on') return errResult(`action 只能是 on 或 off,不是 ${args.action}`)
        const r = await s.request('power.assert', { seconds: args.seconds || 3600 }, { timeoutMs: 30_000 })
        return textResult(`Mac 将保持唤醒 ${r.seconds ?? args.seconds ?? 3600} 秒${r.until ? `,到 ${new Date(r.until).toISOString()}` : ''}`)
      })
    case 'mac_relaunch':
      return withMac(args.mac, async (s) => {
        await s.request('app.relaunch', {}, { timeoutMs: 30_000 })
        return textResult('MacHands 正在重启,几秒后重新上线;这期间的调用会报离线。')
      })
    // ---- v0.3 ----
    case 'mac_doctor':
      return withMac(args.mac, async (s) => {
        const d = await s.request('app.doctor', {}, { timeoutMs: 60_000 })
        const copies = (Array.isArray(d.duplicates) ? d.duplicates : []).filter(Boolean)
        const extra = copies.filter((c) => c !== d.path)
        const notes = []
        if (extra.length) {
          notes.push(
            `⚠ 这台 Mac 上装了不止一份 MacHands,它们抢同一个中继身份 —— 命令会时灵时不灵、方法会忽然"不存在"。` +
              `只留 /Applications 里那份,其余删掉后重开:\n` +
              [d.path, ...extra].filter(Boolean).map((c) => '  ' + c).join('\n')
          )
        }
        if (d.translocated) notes.push('⚠ App 是从 DMG/下载目录直接跑的,路径每次都变,系统权限每次都要重勾。把它拖进 /Applications。')
        if (d.auto_update === false) notes.push('自动更新是关的:升级要人工重装,而重装会让系统权限掉一次。')
        return textResult([pretty(d), ...notes].join('\n\n'))
      })
    case 'mac_update':
      return withMac(args.mac, async (s) => {
        const r = (await s.request('app.update', { check: Boolean(args.check) }, { timeoutMs: 300_000 })) || {}
        if (r.status === 'failed') return errResult(`更新失败:${r.reason || '没说原因'}(当前 ${r.current})`)
        if (r.status === 'updating') {
          return textResult(`MacHands 正在从 ${r.current} 升级到 ${r.latest},它会自己重启;等几秒再调 mac_info 确认版本。`)
        }
        if (r.latest && r.latest !== r.current) return textResult(`有新版本:${r.current} → ${r.latest}(check=false 就装)`)
        return textResult(`已是最新:${r.current}`)
      })
    case 'mac_selfshot':
      return withMac(args.mac, async (s) => {
        const format = args.format === 'jpg' ? 'jpg' : 'png'
        const { r, buf } = await collectStream(
          s,
          'screen.selfshot',
          { window: args.window || 'main', scale: args.scale ?? 1, format },
          120_000
        )
        if (buf.length === 0) return errResult('没拿到图像。这台 Mac 上的 MacHands 可能还不支持 screen.selfshot(0.3 起才有)。')
        const note = args.out ? `已保存到 ${saveTo(args.out, buf)}` : ''
        const windows = Array.isArray(r.windows) ? r.windows.map((w) => `${w.title}(${w.w}×${w.h})`).join('、') : ''
        return imageResult(buf, r, format, [note, windows].filter(Boolean).join(';'))
      })
    case 'mac_show_window':
      return withMac(args.mac, async (s) => {
        await s.request('app.showWindow', {}, { timeoutMs: 30_000 })
        return textResult('MacHands 主窗口已打开并激活。')
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
        instructions:
          '这些工具作用在用户的 Mac 上。会弹审批卡的工具都要填 why —— 一句人话说明你想达成什么,' +
          '用户看到的是这句话而不是命令本身;不要在 why 里复述命令。' +
          '被拒绝时返回 DENIED,先用 mac_check 干跑可以预判。长任务用 mac_job_submit,别用 mac_run 干等。' +
          '出现"方法不存在"、权限反复要重授、或者命令时灵时不灵,先跑 mac_doctor(多半是那台 Mac 上装了多份 App),' +
          '需要升级就用 mac_update。屏幕录制没授权时,mac_selfshot 仍然能看到 MacHands 自己的界面。',
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
