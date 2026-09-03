import Foundation

/// Every user-visible string lives in this one table.
///
/// Adding a language = adding one more entry per row (and one more case to
/// `resolveLanguage`). Nothing else in the app hard-codes prose, so a missing
/// translation can only ever fall back to English, never crash.
enum Lang: String {
    case en
    case zh
}

struct Strings {

    static let shared = Strings()

    let lang: Lang

    private init() {
        self.lang = Strings.resolveLanguage()
    }

    private static func resolveLanguage() -> Lang {
        // Follow the system's preferred language list, not the region.
        for tag in Locale.preferredLanguages {
            let lower = tag.lowercased()
            if lower.hasPrefix("zh") { return .zh }
            if lower.hasPrefix("en") { return .en }
        }
        return .en
    }

    func s(_ key: String) -> String {
        guard let row = Strings.table[key] else {
            // A missing key is a bug, but it must not look like a crash to the
            // user: show the key so it is obvious in a screenshot.
            return key
        }
        return row[lang.rawValue] ?? row["en"] ?? key
    }

    func f(_ key: String, _ args: [CVarArg]) -> String {
        return String(format: s(key), arguments: args)
    }

    // MARK: - the table

    private static let table: [String: [String: String]] = [

        // --- app / menu ------------------------------------------------------
        "app.name": [
            "en": "Using Mac",
            "zh": "Using Mac"],
        "menu.status.idle": [
            "en": "Stopped",
            "zh": "已停止"],
        "menu.status.paused": [
            "en": "Paused",
            "zh": "已暂停"],
        "menu.status.checking": [
            "en": "Checking this Mac…",
            "zh": "正在自检…"],
        "menu.status.connecting": [
            "en": "Connecting…",
            "zh": "连接中…"],
        "menu.status.connected": [
            "en": "Connected · %@",
            "zh": "已连接 · %@"],
        "menu.status.retrying": [
            "en": "Reconnecting · attempt %d, retry in %@",
            "zh": "重连中 · 第 %d 次,%@ 后重试"],
        "menu.status.failed": [
            "en": "Problem: %@",
            "zh": "出错:%@"],
        "menu.port": [
            "en": "%@  ·  %@  ·  port %d",
            "zh": "%@  ·  %@  ·  端口 %d"],
        "menu.pause": [
            "en": "Pause tunnel",
            "zh": "暂停隧道"],
        "menu.resume": [
            "en": "Resume tunnel",
            "zh": "恢复隧道"],
        "menu.reconnectNow": [
            "en": "Reconnect now",
            "zh": "立即重连"],
        "menu.openLog": [
            "en": "Open log…",
            "zh": "打开日志…"],
        "menu.copyServerCommands": [
            "en": "Copy server-side commands",
            "zh": "复制服务器侧要跑的命令"],
        "menu.settings": [
            "en": "Show Window…",
            "zh": "打开窗口…"],
        "menu.setUp": [
            "en": "Set up…",
            "zh": "开始设置…"],
        "menu.quit": [
            "en": "Quit Using Mac",
            "zh": "退出 Using Mac"],
        "menu.launchAtLogin": [
            "en": "Open at login",
            "zh": "开机自启"],

        // --- failures --------------------------------------------------------
        "fail.notEnrolled": [
            "en": "not set up yet",
            "zh": "还没完成设置"],
        "fail.missingIdentity": [
            "en": "the tunnel key is missing",
            "zh": "隧道密钥不见了"],
        "fail.sshMissing": [
            "en": "/usr/bin/ssh is missing",
            "zh": "找不到 /usr/bin/ssh"],
        "fail.remoteLoginOff": [
            "en": "Remote Login is off",
            "zh": "这台 Mac 的「远程登录」没开"],
        "fail.authRejected": [
            "en": "the server rejected this Mac's key",
            "zh": "服务器不认这台 Mac 的密钥"],
        "fail.portInUse": [
            "en": "port %d is already taken on the server",
            "zh": "服务器上的端口 %d 被占住了"],
        "fail.hostKeyChanged": [
            "en": "the server's host key changed",
            "zh": "服务器的主机密钥变了"],
        "fail.serverUnreachable": [
            "en": "nothing answers on the server's port %d",
            "zh": "服务器的 %d 端口没人应答"],
        "fail.proxyFailed": [
            "en": "the proxy did not put the connection through",
            "zh": "代理没能把连接接出去"],
        "fail.network": [
            "en": "cannot reach the server",
            "zh": "连不上服务器"],
        "fail.unknown": [
            "en": "ssh stopped unexpectedly",
            "zh": "ssh 意外退出了"],

        // --- next steps (always paired with a failure) -----------------------
        "next.notEnrolled": [
            "en": "Open the window and paste what mac setup <name> printed on the server.",
            "zh": "打开窗口,把服务器上 mac setup <名字> 打印的那一块粘进去。"],
        "next.missingIdentity": [
            "en": "Run setup again — the key file at %@ is gone. A new key pair will be made here and paired with a fresh code.",
            "zh": "重新走一遍设置 —— %@ 这个密钥文件没了。会在本机重新生成一对密钥,用新的配对码登记。"],
        "next.sshMissing": [
            "en": "Install the Xcode Command Line Tools: xcode-select --install",
            "zh": "装一下 Xcode 命令行工具:xcode-select --install"],
        "next.remoteLoginOff": [
            "en": "System Settings → General → Sharing → Remote Login. Nothing works until it is on.",
            "zh": "系统设置 → 通用 → 共享 → 远程登录。不打开它,什么都跑不起来。"],
        "next.authRejected": [
            "en": "The key is fine but the server has not authorised it. On the server run: mac setup %@ — then paste the new pairing code here.",
            "zh": "钥匙本身没问题,是服务器没授权它。在服务器上跑:mac setup %@ —— 把新的配对码粘进来重配一次。"],
        "next.portInUse": [
            "en": "An old tunnel is still holding it. It usually frees itself within a minute; otherwise re-run mac setup %@.",
            "zh": "是旧隧道还占着,一般一分钟内自己会放。再不行就重跑 mac setup %@。"],
        "next.hostKeyChanged": [
            "en": "Either the server was rebuilt, or something is impersonating it. Verify first, then remove the old entry from the app's known_hosts.",
            "zh": "要么服务器重装了,要么有人在冒充它。先确认清楚,再删掉 app 的 known_hosts 里那条旧记录。"],
        "next.serverUnreachable": [
            "en": "Port %d is not getting through — many campus and office networks block it. Two ways out: have the server listen elsewhere (mac setup %@ --server-port 443) and put that port in Settings, or fill in a ProxyCommand under \"Network options\".",
            "zh": "%d 端口过不去 —— 校园网/公司网经常封它。两条路:让服务器换个端口听(mac setup %@ --server-port 443),然后在设置里把端口改过来;或者在「网络选项」里填一条 ProxyCommand。"],
        "next.proxyFailed": [
            "en": "The ProxyCommand ran but the connection did not come up. Try it by hand in Terminal with the same command, or clear it and use an alternate server port instead.",
            "zh": "ProxyCommand 跑起来了但连接没建成。用同一条命令在「终端」里手动试一次;或者清掉它,改用服务器的备用端口。"],
        "next.network": [
            "en": "Retrying automatically whenever the network comes back.",
            "zh": "网络一恢复就会自动重试。"],
        "next.unknown": [
            "en": "Open the log to see what ssh said.",
            "zh": "打开日志看看 ssh 说了什么。"],

        // --- setup window ----------------------------------------------------
        "setup.headline": [
            "en": "Connect this Mac",
            "zh": "把这台 Mac 接上服务器"],
        "setup.repairHeadline": [
            "en": "Pair again",
            "zh": "重新配对"],
        "setup.lead": [
            "en": "On the server run  mac setup <name>  and paste what it prints below.",
            "zh": "在服务器上跑  mac setup <名字>,把它打印出来的那一块粘到下面。"],
        "setup.inputPlaceholder": [
            "en": "Paste the block, or just the 32-character pairing code",
            "zh": "粘贴那一整块,或者只粘 32 位配对码"],
        "setup.recognisedBlock": [
            "en": "Got it: %@ → %@, port %d",
            "zh": "已识别:%@ → %@,端口 %d"],
        "setup.recognisedCode": [
            "en": "Pairing code recognised. Will register as %@ on %@.",
            "zh": "已识别配对码。将以 %@ 的名字登记到 %@。"],
        "setup.tookClipboard": [
            "en": "Taken from the clipboard.",
            "zh": "已从剪贴板读入。"],
        "setup.details": [
            "en": "Details",
            "zh": "详细信息"],
        "setup.remoteLoginBanner": [
            "en": "Remote Login is off — the tunnel would reach a closed door.",
            "zh": "远程登录没开 —— 隧道通了也是一扇关着的门。"],
        "setup.repair": [
            "en": "Pair again…",
            "zh": "重新配对…"],
        "setup.cancel": [
            "en": "Cancel",
            "zh": "取消"],
        "status.name": [
            "en": "Name",
            "zh": "名字"],
        "status.server": [
            "en": "Server",
            "zh": "服务器"],
        "status.port": [
            "en": "Tunnel port",
            "zh": "隧道端口"],
        "status.lead.connected": [
            "en": "The server can reach this Mac. You can close this window.",
            "zh": "服务器随时能到这台 Mac。可以关掉这个窗口了。"],
        "status.lead.paused": [
            "en": "Paused by you. The server cannot reach this Mac until you resume.",
            "zh": "你暂停了它。恢复之前服务器到不了这台 Mac。"],
        "status.lead.failed": [
            "en": "Something is in the way. What to do is written below.",
            "zh": "有东西挡着。下面写了该做什么。"],
        "status.lead.working": [
            "en": "Working on it. This usually takes a few seconds.",
            "zh": "正在处理,一般几秒钟。"],
        "setup.serverHost": [
            "en": "Server address",
            "zh": "服务器地址"],
        "setup.macName": [
            "en": "Name for this Mac",
            "zh": "这台 Mac 的名字"],
        "setup.noPassword": [
            "en": "No password is ever asked for. The key is made on this Mac and never leaves it.",
            "zh": "不需要任何口令。密钥在本机生成,私钥不离开这台 Mac。"],
        "setup.serverSSHPort": [
            "en": "SSH port",
            "zh": "SSH 端口"],
        "setup.proxyCommand": [
            "en": "ProxyCommand",
            "zh": "ProxyCommand"],
        "setup.openSharing": [
            "en": "Open Sharing settings",
            "zh": "打开共享设置"],
        "setup.connect": [
            "en": "Connect",
            "zh": "连接"],
        "setup.launchAtLogin": [
            "en": "Open Using Mac at login",
            "zh": "开机自动启动 Using Mac"],
        "setup.working": [
            "en": "Making a key pair here, then registering the public half…",
            "zh": "正在本机生成密钥,然后把公钥登记上去…"],
        "setup.installedAs": [
            "en": "Registered as %@, port %d. Bringing the tunnel up…",
            "zh": "已登记为 %@,端口 %d。正在拉起隧道…"],
        "setup.blockedByRemoteLogin": [
            "en": "Turn Remote Login on first — the tunnel would only reach a closed door.",
            "zh": "先把远程登录打开 —— 隧道通了也是一扇关着的门。"],
        "setup.legacyAgentFound": [
            "en": "An older shell-script installation was found and has been switched off, so the two do not fight over the same port.",
            "zh": "发现了旧的脚本版安装,已经关掉它,免得两边抢同一个端口。"],

        // --- enrolment errors -------------------------------------------------
        "err.badName": [
            "en": "\"%@\" is not a usable name. Use letters, digits, - and _ only.",
            "zh": "「%@」这个名字不能用。只能有字母、数字、- 和 _。"],
        "err.emptyHost": [
            "en": "The server address is empty.",
            "zh": "服务器地址是空的。"],
        "err.badHost": [
            "en": "\"%@\" does not look like a server address.",
            "zh": "「%@」不像一个服务器地址。"],
        "err.badSSHPort": [
            "en": "\"%@\" is not a port number (1–65535).",
            "zh": "「%@」不是端口号(1–65535)。"],
        "err.badProxy": [
            "en": "The ProxyCommand must be a single line, under 512 characters.",
            "zh": "ProxyCommand 只能写一行,且不超过 512 个字符。"],
        "err.pairingUnparsable": [
            "en": "That is not something mac setup printed. Paste the whole block it printed, or just the 32-character pairing code.",
            "zh": "这不是 mac setup 打印出来的东西。把它打印的那一整块粘进来,或者只粘那 32 位配对码。"],
        "err.pairingBadCode": [
            "en": "The pairing code should be 32 characters. If it got cut off, run mac setup <name> on the server again for a fresh one.",
            "zh": "配对码应该是 32 位。要是复制少了,在服务器上重跑一次 mac setup <名字> 拿个新的。"],
        "err.pairingBadPort": [
            "en": "The tunnel port in the block is not a number between %d and %d.",
            "zh": "配对块里的隧道端口不是 %d 到 %d 之间的数字。"],
        "err.pairingBadURL": [
            "en": "\"%@\" is not a usable enrolment address (http:// or https:// only).",
            "zh": "「%@」不是可用的登记地址(只支持 http:// 或 https://)。"],
        "err.pairingCarriesKey": [
            "en": "That block contains a private key, which means the server has not been updated. A key that has been through a terminal must be treated as burned: update the server, revoke that key, then run `mac setup <name>` again for a code-only block.",
            "zh": "这一块里带着私钥 —— 说明服务器还是旧版。凡是在终端里露过面的私钥都当作已泄漏:先升级服务器、吊销那把钥匙,再重新 `mac setup <名字>` 拿只含配对码的块。"],
        "err.keygen": [
            "en": "ssh-keygen could not make the tunnel key: %@",
            "zh": "ssh-keygen 没能生成隧道密钥:%@"],
        "err.writeKey": [
            "en": "Could not write the tunnel key to %@ (%@).",
            "zh": "隧道密钥写不进 %@(%@)。"],
        "err.writeAuthorizedKeys": [
            "en": "Could not update ~/.ssh/authorized_keys (%@). The server will not be able to log back in.",
            "zh": "改不了 ~/.ssh/authorized_keys(%@)。服务器就没法反过来登录这台 Mac。"],
        "err.writeConf": [
            "en": "Could not write ~/.using-mac-tunnel.conf (%@).",
            "zh": "写不了 ~/.using-mac-tunnel.conf(%@)。"],
        "err.enrollUnreachable": [
            "en": "Could not reach the enrolment endpoint %@ (%@). Is the server up, and is that port open?",
            "zh": "连不上登记端点 %@(%@)。服务器活着吗?那个端口放行了吗?"],
        "err.enrollRefused": [
            "en": "The server refused the pairing code: %@",
            "zh": "服务器不接受这个配对码:%@"],
        "err.enrollBadAnswer": [
            "en": "The enrolment endpoint answered with something unexpected (%@).",
            "zh": "登记端点回了一个看不懂的答复(%@)。"],
        "err.badServerPubkey": [
            "en": "The server did not send back a usable public key, so it could never ssh in. Nothing was changed.",
            "zh": "服务器没回一把能用的公钥,那它就永远连不回来。什么都没改。"],
        "err.portMismatch": [
            "en": "The server allocated port %d, which is outside the expected range (the block said %d).",
            "zh": "服务器分配的端口是 %d,不在预期范围内(配对块里写的是 %d)。"],
        "err.timeout": [
            "en": "Timed out after %d seconds.",
            "zh": "%d 秒还没结果,超时了。"],
        "err.verifyTimeout": [
            "en": "Registered, but the tunnel did not come up within %d seconds. Check the log.",
            "zh": "登记好了,但 %d 秒内隧道没起来。看看日志。"],

        // --- misc ------------------------------------------------------------
        "time.seconds": ["en": "%ds", "zh": "%d 秒"],
        "time.minutes": ["en": "%dm", "zh": "%d 分"],
        "time.hours": ["en": "%dh %dm", "zh": "%d 小时 %d 分"],
        "time.days": ["en": "%dd %dh", "zh": "%d 天 %d 小时"]
    ]
}

/// Shorthand for a plain lookup.
func L(_ key: String) -> String {
    return Strings.shared.s(key)
}

/// Shorthand for a formatted lookup. Deliberately a *different* name from `L`:
/// one overloaded variadic function would be ambiguous at every call site.
func Lf(_ key: String, _ args: CVarArg...) -> String {
    return Strings.shared.f(key, args)
}
