// 发信 · 三个后端,一个接口:send({to, subject, text}) -> {ok, backend, id?, error?}
//
//   MAIL_BACKEND=resend   走 Resend 的 HTTPS API(最省事,不用管 SMTP)
//   MAIL_BACKEND=smtp     自己说 SMTP(支持 STARTTLS 与隐式 TLS、AUTH LOGIN)
//   MAIL_BACKEND=none     不发信,只落盘,人工补发(默认)
//
// 所有密钥只从 process.env 读,代码里没有任何默认值。没配全就退回 none 并说明原因,
// 绝不静默地"假装发出去了"——发没发出去关系到买家能不能拿到证。

import { connect as netConnect } from 'node:net'
import { connect as tlsConnect } from 'node:tls'

export function backendName(env = process.env) {
  const want = String(env.MAIL_BACKEND || 'none').toLowerCase()
  return ['resend', 'smtp', 'none'].includes(want) ? want : 'none'
}

/** 配置齐不齐。缺什么直接说,别让老板猜。 */
export function backendReady(env = process.env) {
  const b = backendName(env)
  if (b === 'resend') {
    const missing = ['RESEND_API_KEY', 'MAIL_FROM'].filter((k) => !env[k])
    return { backend: b, ready: missing.length === 0, missing }
  }
  if (b === 'smtp') {
    const missing = ['SMTP_HOST', 'SMTP_USER', 'SMTP_PASS', 'MAIL_FROM'].filter((k) => !env[k])
    return { backend: b, ready: missing.length === 0, missing }
  }
  return { backend: 'none', ready: true, missing: [] }
}

// --------------------------------------------------------------------------
// 邮件正文 · 中英双语。买家可能是任何地方的人,两种语言都给,中文在前。
// --------------------------------------------------------------------------
export function licenseEmail({ license, email, siteOrigin = '__SITE_ORIGIN__', orderId = '' }) {
  const subject = 'MacHands 许可证 / Your MacHands license'
  const text = `你好,

谢谢购买 MacHands。下面这一行就是你的许可证:

${license}

怎么用:
  1. 打开 MacHands,点菜单栏那只手 → 设置…
  2. 把上面那一行整个粘进"许可证"框,回车。
  3. 标题栏下面的"试用中"会变成"已激活"。

下载与安装:${siteOrigin}
换电脑、重装系统都可以再粘一次,这一行不会过期作废。请把这封邮件存好。

发票:回复这封邮件,写上抬头和税号,我们会补开。
退款:购买后 14 天内不满意可全额退款,回复这封邮件即可。
订单号:${orderId || '(无)'}

——————————————————————————————

Hi,

Thanks for buying MacHands. This line is your license:

${license}

How to use it:
  1. Open MacHands, click the hand in the menu bar, then Settings…
  2. Paste the whole line into the License field and press Return.
  3. "Trial" under the title turns into "Activated".

Download and install: ${siteOrigin}
You can paste it again on a new Mac or after reinstalling — it does not expire.
Please keep this email.

Invoice: reply to this email with your company name and tax id.
Refund: full refund within 14 days, just reply to this email.
Order: ${orderId || '(none)'}
`
  return { subject, text }
}

// --------------------------------------------------------------------------
// Resend
// --------------------------------------------------------------------------
async function sendResend({ to, subject, text }, env) {
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      authorization: `Bearer ${env.RESEND_API_KEY}`,
      'content-type': 'application/json'
    },
    body: JSON.stringify({ from: env.MAIL_FROM, to: [to], subject, text })
  })
  const body = await res.text()
  if (!res.ok) return { ok: false, backend: 'resend', error: `resend ${res.status}: ${body.slice(0, 200)}` }
  let id = ''
  try {
    id = JSON.parse(body).id || ''
  } catch {}
  return { ok: true, backend: 'resend', id }
}

// --------------------------------------------------------------------------
// 最小 SMTP · 只用 node 内置模块
// 够用就好:EHLO → (STARTTLS) → AUTH LOGIN → MAIL FROM → RCPT TO → DATA → QUIT
// --------------------------------------------------------------------------
class SmtpSession {
  constructor(socket) {
    this.socket = socket
    this.buffer = ''
    this.waiter = null
    socket.setEncoding('utf8')
    socket.on('data', (chunk) => {
      this.buffer += chunk
      this.drain()
    })
  }

  drain() {
    if (!this.waiter) return
    // SMTP 的多行回复是 "250-xxx" 连续若干行,最后一行是 "250 xxx"(第四个字符是空格)。
    const lines = this.buffer.split(/\r?\n/)
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i]
      if (/^\d{3} /.test(line)) {
        const consumed = lines.slice(0, i + 1).join('\r\n')
        this.buffer = this.buffer.slice(consumed.length).replace(/^\r?\n/, '')
        const w = this.waiter
        this.waiter = null
        w.resolve({ code: Number(line.slice(0, 3)), text: consumed })
        return
      }
    }
  }

  read(timeoutMs = 20000) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiter = null
        reject(new Error('SMTP 服务器超时没回话'))
      }, timeoutMs)
      this.waiter = {
        resolve: (v) => {
          clearTimeout(timer)
          resolve(v)
        }
      }
      this.drain()
    })
  }

  write(line) {
    this.socket.write(line + '\r\n')
  }

  async command(line, expect) {
    this.write(line)
    const res = await this.read()
    if (expect && !expect.includes(res.code)) {
      // 命令本身可能含密码(AUTH 的 base64),报错里只说命令的第一个词。
      throw new Error(`SMTP ${line.split(' ')[0]} 被拒:${res.text.slice(0, 160)}`)
    }
    return res
  }
}

function socketFor(host, port, useTLS) {
  return new Promise((resolve, reject) => {
    const sock = useTLS
      ? tlsConnect({ host, port, servername: host }, () => resolve(sock))
      : netConnect({ host, port }, () => resolve(sock))
    sock.setTimeout(20000)
    sock.once('error', reject)
    sock.once('timeout', () => {
      sock.destroy()
      reject(new Error(`连不上 SMTP ${host}:${port}`))
    })
  })
}

/** 邮件正文里以 "." 开头的行要变成 "..",否则会被当成结束标记。 */
function dotStuff(text) {
  return text.replace(/\r?\n/g, '\r\n').replace(/^\./gm, '..')
}

async function sendSmtp({ to, subject, text }, env) {
  const host = env.SMTP_HOST
  const port = Number(env.SMTP_PORT || 587)
  const implicitTLS = String(env.SMTP_TLS || '').toLowerCase() === 'implicit' || port === 465
  const from = env.MAIL_FROM
  let sock = await socketFor(host, port, implicitTLS)
  let s = new SmtpSession(sock)

  try {
    const hello = await s.read()
    if (hello.code !== 220) throw new Error(`SMTP 招呼不对:${hello.text.slice(0, 120)}`)

    const ehloName = env.SMTP_EHLO || 'machands.local'
    let caps = await s.command(`EHLO ${ehloName}`, [250])

    if (!implicitTLS && /STARTTLS/i.test(caps.text)) {
      await s.command('STARTTLS', [220])
      // 在同一条 TCP 连接上套 TLS,然后必须重新 EHLO。
      const upgraded = await new Promise((resolve, reject) => {
        const t = tlsConnect({ socket: sock, servername: host }, () => resolve(t))
        t.once('error', reject)
      })
      sock = upgraded
      s = new SmtpSession(sock)
      caps = await s.command(`EHLO ${ehloName}`, [250])
    }

    // AUTH LOGIN:两步,各发一个 base64。用户名密码永远不进日志。
    await s.command('AUTH LOGIN', [334])
    await s.command(Buffer.from(env.SMTP_USER, 'utf8').toString('base64'), [334])
    await s.command(Buffer.from(env.SMTP_PASS, 'utf8').toString('base64'), [235])

    await s.command(`MAIL FROM:<${from.replace(/.*</, '').replace(/>.*/, '') || from}>`, [250])
    await s.command(`RCPT TO:<${to}>`, [250, 251])
    await s.command('DATA', [354])

    const headers = [
      `From: ${from}`,
      `To: ${to}`,
      `Subject: =?UTF-8?B?${Buffer.from(subject, 'utf8').toString('base64')}?=`,
      'MIME-Version: 1.0',
      'Content-Type: text/plain; charset=UTF-8',
      'Content-Transfer-Encoding: 8bit',
      `Date: ${new Date().toUTCString()}`,
      ''
    ].join('\r\n')
    s.socket.write(headers + '\r\n' + dotStuff(text) + '\r\n.\r\n')
    const done = await s.read(60000)
    if (done.code !== 250) throw new Error(`SMTP 收信失败:${done.text.slice(0, 160)}`)

    try {
      await s.command('QUIT', [221])
    } catch {
      // 对面直接关连接也算发出去了,不用为 QUIT 报错
    }
    return { ok: true, backend: 'smtp', id: '' }
  } finally {
    try {
      sock.destroy()
    } catch {}
  }
}

// --------------------------------------------------------------------------

export async function send({ to, subject, text }, env = process.env) {
  const status = backendReady(env)
  if (status.backend === 'none') return { ok: false, backend: 'none', error: 'mail_backend_none' }
  if (!status.ready) {
    return { ok: false, backend: status.backend, error: `缺配置:${status.missing.join(', ')}` }
  }
  try {
    if (status.backend === 'resend') return await sendResend({ to, subject, text }, env)
    return await sendSmtp({ to, subject, text }, env)
  } catch (err) {
    return { ok: false, backend: status.backend, error: String(err && err.message ? err.message : err) }
  }
}
