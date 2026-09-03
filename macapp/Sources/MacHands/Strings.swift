import Foundation

/// 铁律 3:任何面向用户的字符串走 i18n(zh / en 两种,**zh 兜底**)。
/// 逻辑里不写裸中文,只写 key。
enum Lang: String {
    case zh
    case en
}

struct Strings {

    static let shared = Strings()

    let lang: Lang

    private init() {
        self.lang = Strings.resolveLanguage()
    }

    private static func resolveLanguage() -> Lang {
        for tag in Locale.preferredLanguages {
            let lower = tag.lowercased()
            if lower.hasPrefix("zh") { return .zh }
            if lower.hasPrefix("en") { return .en }
        }
        return .zh
    }

    func s(_ key: String) -> String {
        guard let row = Strings.table[key] else { return key }
        return row[lang.rawValue] ?? row["zh"] ?? key
    }

    func f(_ key: String, _ args: [CVarArg]) -> String {
        return String(format: s(key), arguments: args)
    }

    private static let table: [String: [String: String]] = [

        // --- app ------------------------------------------------------------
        "app.name": ["zh": "MacHands", "en": "MacHands"],
        "app.tagline": [
            "zh": "给你的云端 AI 代理一双 Mac 上的手,每一下都经你同意。",
            "en": "Hands on your Mac for your cloud AI agent — every move needs your yes."],
        "value.unknown": ["zh": "—", "en": "—"],

        // --- 菜单栏 (SPEC §7.1) -----------------------------------------------
        "menu.state.unpaired": ["zh": "还没有 agent 连接", "en": "No agent connected yet"],
        "menu.state.waiting": ["zh": "等待 agent…", "en": "Waiting for an agent…"],
        "menu.state.connected": ["zh": "已连接 · %@", "en": "Connected · %@"],
        "menu.state.connecting": ["zh": "正在连接中继…", "en": "Connecting to the relay…"],
        "menu.state.offline": ["zh": "连不上中继 · %@", "en": "Cannot reach the relay · %@"],
        "menu.state.paused": ["zh": "已暂停 · 所有命令都会被拒绝", "en": "Paused · every command is refused"],
        "menu.copyForAgent": ["zh": "复制给 agent", "en": "Copy for your agent"],
        "menu.mode": ["zh": "审批模式", "en": "Approval"],
        "menu.mode.ask": ["zh": "逐条问", "en": "Ask every time"],
        "menu.mode.auto": ["zh": "自动", "en": "Automatic"],
        "menu.pause": ["zh": "暂停", "en": "Pause"],
        "menu.resume": ["zh": "恢复", "en": "Resume"],
        "menu.openAudit": ["zh": "打开审计日志", "en": "Open the audit log"],
        "menu.window": ["zh": "打开主窗口…", "en": "Open the window…"],
        "menu.settings": ["zh": "设置…", "en": "Settings…"],
        "menu.quit": ["zh": "退出 MacHands", "en": "Quit MacHands"],
        "menu.agentLine": ["zh": "%@ · %@ · %@前", "en": "%@ · %@ · %@ ago"],
        "menu.agentIdle": ["zh": "%@ · 还没执行过命令", "en": "%@ · nothing run yet"],

        // --- 主窗口 (SPEC §7.2) -----------------------------------------------
        "main.headline": ["zh": "把这台 Mac 交给你的 agent", "en": "Hand this Mac to your agent"],
        "main.copy": ["zh": "复制给 agent", "en": "Copy for your agent"],
        "main.copied": [
            "zh": "已复制。贴给你的 agent,让它执行那一行。",
            "en": "Copied. Paste it to your agent and let it run that line."],
        "main.copyFailed": ["zh": "复制失败,下面的文字可以手动选。", "en": "Copy failed — select the text below by hand."],
        "main.waiting": ["zh": "等待 agent 连接…", "en": "Waiting for an agent…"],
        "main.connectedHeadline": [
            "zh": "✓ %@ 已连接。可以关掉这个窗口了。",
            "en": "✓ %@ is connected. You can close this window."],
        "main.relayDown": [
            "zh": "还连不上中继。%@",
            "en": "Still cannot reach the relay. %@"],
        "main.details": ["zh": "详细信息", "en": "Details"],
        "main.relay": ["zh": "中继地址", "en": "Relay"],
        "main.macName": ["zh": "这台 Mac 的名字", "en": "This Mac's name"],
        "main.macId": ["zh": "Mac ID", "en": "Mac ID"],
        "main.mode": ["zh": "审批模式", "en": "Approval mode"],
        "main.mode.ask": ["zh": "逐条问(推荐)", "en": "Ask every time (recommended)"],
        "main.mode.auto": ["zh": "自动放行(黑名单仍然拦)", "en": "Automatic (the denylist still blocks)"],
        "main.launchAtLogin": ["zh": "开机自动启动", "en": "Open at login"],
        "main.openSettings": ["zh": "设置…", "en": "Settings…"],

        // --- 配对块 (SPEC §3) --------------------------------------------------
        // 这两行会原样进用户的剪贴板,既是给人看的说明,也是给 agent 的指令。
        "pair.lead": [
            "zh": "把下面这一行在你的机器上执行,然后告诉我结果:",
            "en": "Run this one line on your machine and tell me what it says:"],
        "pair.note": [
            "zh": "(这是 MacHands 配对码,10 分钟内有效,只能用一次。)",
            "en": "(A MacHands pairing code — good for 10 minutes, once.)"],

        // --- 审批卡 (SPEC §5.2 / §7.3) ----------------------------------------
        "approve.title": ["zh": "%@ 想执行", "en": "%@ wants to run"],
        "approve.titleGeneric": ["zh": "%@ 请求 %@", "en": "%@ is asking for %@"],
        "approve.once": ["zh": "允许一次", "en": "Allow once"],
        "approve.hour": ["zh": "允许 1 小时", "en": "Allow for an hour"],
        "approve.always": ["zh": "总是允许这条", "en": "Always allow this"],
        "approve.deny": ["zh": "拒绝", "en": "Refuse"],
        "approve.more": ["zh": "还有 %d 条", "en": "%d more waiting"],
        "approve.cwd": ["zh": "目录", "en": "Folder"],
        "approve.from": ["zh": "来源", "en": "From"],
        "approve.expand": ["zh": "展开全部", "en": "Show all"],
        "approve.collapse": ["zh": "收起", "en": "Collapse"],
        "approve.timeout": ["zh": "%d 秒后自动拒绝", "en": "refused automatically in %ds"],

        // --- 设置窗口 (SPEC §7.2 末) -------------------------------------------
        "settings.title": ["zh": "MacHands 设置", "en": "MacHands Settings"],
        "settings.relay": ["zh": "中继地址", "en": "Relay address"],
        "settings.relayHint": [
            "zh": "改了要重连。留空恢复默认。",
            "en": "Changing this reconnects. Empty restores the default."],
        "settings.agents": ["zh": "已授权的 agent", "en": "Authorised agents"],
        "settings.noAgents": ["zh": "还没有。", "en": "None yet."],
        "settings.revoke": ["zh": "撤销", "en": "Revoke"],
        "settings.allow": ["zh": "白名单(命令前缀,一行一条)", "en": "Allowlist (command prefixes, one per line)"],
        "settings.deny": ["zh": "黑名单(一行一条)", "en": "Denylist (one per line)"],
        "settings.denyBuiltin": [
            "zh": "内置黑名单永远生效:%@",
            "en": "These are always blocked: %@"],
        "settings.askForReads": ["zh": "读取也要问", "en": "Ask before reads too"],
        "settings.license": ["zh": "许可证", "en": "Licence"],
        "settings.licensePlaceholder": ["zh": "MHL1.…", "en": "MHL1.…"],
        "settings.save": ["zh": "保存", "en": "Save"],
        "settings.saved": ["zh": "已保存。", "en": "Saved."],
        "settings.badRelay": [
            "zh": "中继地址要以 ws:// 或 wss:// 开头。",
            "en": "The relay address must start with ws:// or wss://."],

        // --- 许可证 (SPEC §7.5) -----------------------------------------------
        "license.trial": ["zh": "试用中,还剩 %d 天", "en": "Trial · %d days left"],
        "license.ok": ["zh": "已授权 · %@", "en": "Licensed · %@"],
        "license.expired": ["zh": "许可证已过期 · %@", "en": "Licence expired · %@"],
        "license.invalid": ["zh": "许可证无效", "en": "Licence is not valid"],
        "license.blocked": [
            "zh": "试用结束:执行命令与写文件已停用,配对和查看还能用。",
            "en": "Trial over: running and writing are off; pairing and viewing still work."],

        // --- 通知 --------------------------------------------------------------
        "notify.paired.title": ["zh": "%@ 已连接", "en": "%@ is connected"],
        "notify.paired.body": [
            "zh": "它现在可以在这台 Mac 上执行命令了。每一条都会先问你。",
            "en": "It can act on this Mac now. Every command asks you first."],
        "notify.approval.title": ["zh": "%@ 在等你批准", "en": "%@ is waiting for you"],

        // --- 权限引导 (SPEC §7.4) ----------------------------------------------
        "perm.screen.title": ["zh": "agent 想截屏,需要你授权一次", "en": "The agent wants a screenshot — one-time permission"],
        "perm.screen.body": [
            "zh": "在「隐私与安全性 → 屏幕录制」里勾上 MacHands,然后回来重试。",
            "en": "Tick MacHands under Privacy & Security → Screen Recording, then try again."],
        "perm.screen.open": ["zh": "打开设置", "en": "Open Settings"],
        "perm.screen.rpc": ["zh": "需要在 Mac 上授权屏幕录制", "en": "screen recording must be allowed on the Mac"],
        "perm.later": ["zh": "以后再说", "en": "Later"],

        // --- 连接失败 ------------------------------------------------------------
        "fail.dns": ["zh": "找不到中继的地址", "en": "cannot resolve the relay's address"],
        "fail.refused": ["zh": "中继没有应答", "en": "the relay does not answer"],
        "fail.badSig": ["zh": "中继不认这台 Mac 的签名", "en": "the relay rejected this Mac's signature"],
        "fail.banned": ["zh": "这台 Mac 被中继拒绝了", "en": "the relay refuses this Mac"],
        "fail.network": ["zh": "网络不通", "en": "no network"],
        "fail.retry": ["zh": "%@ 后重试", "en": "retrying in %@"],

        // --- 时间 ---------------------------------------------------------------
        "time.now": ["zh": "刚刚", "en": "just now"],
        "time.seconds": ["zh": "%d 秒", "en": "%ds"],
        "time.minutes": ["zh": "%d 分", "en": "%dm"],
        "time.hours": ["zh": "%d 小时", "en": "%dh"],
        "time.days": ["zh": "%d 天", "en": "%dd"]
    ]
}

func L(_ key: String) -> String {
    return Strings.shared.s(key)
}

/// 故意与 `L` 不同名:一个变参重载会让每个调用点都歧义。
func Lf(_ key: String, _ args: CVarArg...) -> String {
    return Strings.shared.f(key, args)
}
