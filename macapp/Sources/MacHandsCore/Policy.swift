import Foundation

/// SPEC §5.2 + §10 的审批策略。UI 无关,所以能被 `swift test` 完整覆盖。
public enum ApprovalMode: String, Codable, CaseIterable {
    /// 逐条审批(v1 行为)。
    case ask
    /// 开发者:全部放行,黑名单直接拒(不弹卡)。SPEC §10.1 推荐值。
    case auto
    /// 只读:读方法放行,写方法直接拒(不弹卡)。
    case readonly
    /// 全拒(暂停时对外呈现为这个)。
    case deny
}

public enum PolicyDecision: Equatable {
    case allow
    /// 需要弹审批卡。
    case ask
    /// 直接拒,`code` 是回给 agent 的 RPC 错误码(DENIED / POLICY / LICENSE)。
    case deny(code: String, reason: String)

    /// `policy.check` 用的字面值。
    public var label: String {
        switch self {
        case .allow: return "allow"
        case .ask: return "ask"
        case .deny: return "deny"
        }
    }
}

/// 可持久化的那部分策略。SettingsStore 存它。
public struct PolicyState: Codable, Equatable {

    public var mode: ApprovalMode
    /// "总是允许这条" 按命令前缀记的白名单。
    public var allow: [String]
    /// 黑名单。内置那些在 `PolicyEngine.defaultDeny` 里,这里是用户加的。
    public var deny: [String]
    /// SPEC §5.2:关闭时读类方法直接放行;打开则一样弹卡(只影响 ask 模式)。
    public var askForReads: Bool
    public var paused: Bool

    public init(mode: ApprovalMode = .ask,
                allow: [String] = [],
                deny: [String] = [],
                askForReads: Bool = false,
                paused: Bool = false) {
        self.mode = mode
        self.allow = allow
        self.deny = deny
        self.askForReads = askForReads
        self.paused = paused
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(ApprovalMode.self, forKey: .mode) ?? .ask
        allow = try c.decodeIfPresent([String].self, forKey: .allow) ?? []
        deny = try c.decodeIfPresent([String].self, forKey: .deny) ?? []
        askForReads = try c.decodeIfPresent(Bool.self, forKey: .askForReads) ?? false
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
    }
}

public final class PolicyEngine {

    /// SPEC §10.5 的内置黑名单。auto / readonly / ask 三种模式下都拦,命中回 POLICY,不弹卡。
    /// 以 `/` 或 `~` 结尾的条目只匹配"整个根/整个家目录"(见 `firstMatch`),
    /// `rm -rf /tmp/x`、`rm -rf ~/build` 这类日常清理不会被误伤。
    public static let defaultDeny: [String] = [
        "rm -rf /",
        "rm -rf ~",
        "rm -rf /*",
        "diskutil erase",
        "diskutil eraseDisk",
        "mkfs",
        "dd if=",
        "sudo",
        "csrutil",
        "launchctl bootout system",
        "security delete-keychain",
        "tccutil reset All",   // 定向的 tccutil reset <服务> <bundle id> 可逆,放行
        "killall MacHands",
        "pkill -f MacHands",
        "osascript -e 'tell application \"System Events\" to keystroke"
    ]

    /// 写方法(SPEC §10.4):ask 模式下一定要问;readonly 模式下直接拒。
    public static let writeMethods: Set<String> = [
        "run", "fs.put", "open", "clip.set",
        "input.where", "input.move", "input.click", "input.drag", "input.scroll", "input.key", "input.type",
        "job.submit", "job.kill",
        "session.open", "session.write", "session.close",
        "mcp.open", "mcp.call", "mcp.close",
        "power.assert", "power.release", "app.relaunch", "verify.run",
        // 换掉 App 自己的二进制,比什么都重。
        "app.update"
    ]

    /// 读方法:"读取也要问"关闭时直接放行;readonly 模式下放行。
    public static let readMethods: Set<String> = [
        "fs.get", "fs.ls", "screen.shot", "screen.list", "screen.window", "screen.record",
        "sys.info", "sys.perms", "sys.which", "clip.get",
        "job.status", "job.tail", "job.result", "job.list",
        "session.read", "mcp.servers", "mcp.list",
        // 自画窗口不碰别的 App,也不需要 TCC;只读模式下也该能用 —— 屏幕录制
        // 授权掉了的时候,它是唯一还能看见界面的路。
        "screen.selfshot", "app.showWindow", "app.doctor"
    ]

    /// 从不需要审批:给用户看的通知、让 agent 提前知道规则的两条。
    public static let alwaysAllowedMethods: Set<String> = ["notify", "policy.get", "policy.check"]

    private let lock = NSLock()
    private var state: PolicyState
    /// agentId → "1 小时授权" 到期时间。
    private var grants: [String: Date] = [:]
    /// 许可证过期时,run / fs.put 要回 LICENSE(SPEC §7.5)。
    private var licenseBlocksWrites = false
    /// 本次运行里"没问就放行了"的条数,按类别记。审批卡底部那行灰字用它,
    /// 让用户知道自动模式下**替他决定了多少次** —— 不显示,就等于没说。
    private var autoAllowed: [String: Int] = [:]

    public var onChange: ((PolicyState) -> Void)?

    public init(state: PolicyState = PolicyState()) {
        self.state = state
    }

    // MARK: - 读写状态

    public var snapshot: PolicyState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public func update(_ body: (inout PolicyState) -> Void) {
        lock.lock()
        var next = state
        body(&next)
        state = next
        lock.unlock()
        onChange?(next)
    }

    public var paused: Bool {
        get { return snapshot.paused }
        set { update { $0.paused = newValue } }
    }

    public var mode: ApprovalMode {
        get { return snapshot.mode }
        set { update { $0.mode = newValue } }
    }

    public func setLicenseBlocksWrites(_ blocked: Bool) {
        lock.lock(); licenseBlocksWrites = blocked; lock.unlock()
    }

    /// "允许 1 小时"。
    public func grantHour(agentId: String, now: Date = Date()) {
        lock.lock()
        grants[agentId] = now.addingTimeInterval(3600)
        lock.unlock()
    }

    public func revokeGrant(agentId: String) {
        lock.lock(); grants.removeValue(forKey: agentId); lock.unlock()
    }

    public func grantExpiry(agentId: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return grants[agentId]
    }

    /// "总是允许这条":按命令前缀记白名单。
    public func alwaysAllow(prefix: String) {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update { current in
            if !current.allow.contains(trimmed) { current.allow.append(trimmed) }
        }
    }

    /// SPEC §5.1 `policy.get` 的返回体。
    public func publicSnapshot() -> JSONValue {
        let current = snapshot
        return .object([
            "mode": .string(current.paused ? ApprovalMode.deny.rawValue : current.mode.rawValue),
            "allow": .strings(current.allow),
            "deny": .strings(PolicyEngine.defaultDeny + current.deny)
        ])
    }

    // MARK: - 判定

    /// `subject` 是要匹配黑白名单的那段文字:`run` 用命令原文,`fs.put` / `open`
    /// 用路径,其它方法给空串。
    public func decide(agentId: String,
                       method: String,
                       subject: String,
                       now: Date = Date()) -> PolicyDecision {

        lock.lock()
        let current = state
        let grantedUntil = grants[agentId]
        let licenseBlocked = licenseBlocksWrites
        lock.unlock()

        if current.paused {
            return .deny(code: RPCErrorCode.denied.rawValue, reason: "paused")
        }

        // 免审方法(notify / policy.get / policy.check)什么都不执行,先放行——
        // 否则 policy.check 问"sudo ls 能不能跑"会被黑名单把问题本身拒掉,而不是回答 deny。
        if PolicyEngine.alwaysAllowedMethods.contains(method) {
            return .allow
        }

        // 黑名单先于一切模式:auto / readonly 也拦(SPEC §10.5)。
        let denyList = PolicyEngine.defaultDeny + current.deny
        if let hit = PolicyEngine.firstMatch(in: subject, patterns: denyList) {
            return .deny(code: RPCErrorCode.policy.rawValue, reason: hit)
        }

        let isRead = PolicyEngine.readMethods.contains(method)

        if licenseBlocked && (method == "run" || method == "fs.put" || method == "job.submit") {
            return .deny(code: RPCErrorCode.license.rawValue, reason: "trial ended")
        }

        switch current.mode {
        case .deny:
            return .deny(code: RPCErrorCode.denied.rawValue, reason: "mode=deny")
        case .auto:
            return .allow
        case .readonly:
            // 读放行,其余(含未知方法)直接拒,不弹卡。
            return isRead ? .allow : .deny(code: RPCErrorCode.denied.rawValue, reason: "readonly")
        case .ask:
            break
        }

        if isRead && !current.askForReads {
            return .allow
        }
        // 既不在读表也不在写表的方法(SPEC 加了新方法而这张表没跟上)按写处理:
        // 宁可多问一次,也不要默默放行。
        if let until = grantedUntil, until > now {
            return .allow
        }
        if PolicyEngine.matchesPrefix(subject, prefixes: current.allow) {
            return .allow
        }
        return .ask
    }

    /// `policy.check` 的干跑:同 `decide`,只是明确它不产生副作用。
    public func check(agentId: String, method: String, subject: String) -> PolicyDecision {
        return decide(agentId: agentId, method: method, subject: subject)
    }

    // MARK: - 自动放行计数(审批卡底部那行灰字)

    /// 执行器在**没弹卡就放行**时调一次。`decide` 自己不记 —— 它同时服务
    /// `policy.check` 的干跑,在那里加计数会把"问一句"记成"干了一次"。
    public func noteAutoAllowed(area: Intent.Area) {
        lock.lock()
        autoAllowed[area.rawValue, default: 0] += 1
        lock.unlock()
    }

    public func autoAllowedCount(area: Intent.Area) -> Int {
        lock.lock(); defer { lock.unlock() }
        return autoAllowed[area.rawValue] ?? 0
    }

    // MARK: - 匹配

    /// 黑名单匹配。
    /// - 单词型条目(`sudo`)要求两侧是非字母数字,免得 `sudoku` 被当成 `sudo`;
    /// - 带空格的短语按子串匹配;
    /// - 以 `/` 或 `~` 结尾的短语(`rm -rf /`、`rm -rf ~`)后面**不能紧跟路径字符**,
    ///   否则 `rm -rf /tmp/x` 也会被拦——那是日常清理,不是灾难。
    public static func firstMatch(in subject: String, patterns: [String]) -> String? {
        guard !subject.isEmpty else { return nil }
        let haystack = Array(subject.lowercased())
        for pattern in patterns {
            let trimmedPattern = pattern.lowercased().trimmingCharacters(in: .whitespaces)
            let needle = Array(trimmedPattern)
            if needle.isEmpty || needle.count > haystack.count { continue }
            let wordish = !needle.contains(" ")
            let rootish = trimmedPattern.hasSuffix("/") || trimmedPattern.hasSuffix("~")
            var index = 0
            while index + needle.count <= haystack.count {
                if Array(haystack[index..<(index + needle.count)]) == needle {
                    let afterIndex = index + needle.count
                    let after: Character? = afterIndex < haystack.count ? haystack[afterIndex] : nil
                    if rootish {
                        // `rm -rf /` 之后只能是结尾、空白或 `*`;`rm -rf ~` 之后只能是结尾或空白。
                        if let next = after, !(next == " " || next == "*" || next == ";" || next == "&" || next == "|") {
                            index += 1
                            continue
                        }
                        return pattern
                    }
                    if !wordish {
                        return pattern
                    }
                    let beforeOK = index == 0 || !isWordCharacter(haystack[index - 1])
                    let afterOK = after == nil || !isWordCharacter(after!)
                    if beforeOK && afterOK { return pattern }
                }
                index += 1
            }
        }
        return nil
    }

    public static func matchesPrefix(_ subject: String, prefixes: [String]) -> Bool {
        guard !subject.isEmpty else { return false }
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in prefixes {
            let candidate = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.isEmpty { continue }
            if trimmed == candidate || trimmed.hasPrefix(candidate) { return true }
        }
        return false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        return character.isLetter || character.isNumber || character == "_"
    }

    /// 从一条 RPC 里取出用来匹配黑白名单、并写进审计日志摘要的那段文字。
    public static func subject(method: String, params: JSONValue) -> String {
        func text(_ key: String) -> String { return params[key]?.stringValue ?? "" }
        func num(_ key: String) -> String {
            if let value = params[key]?.doubleValue {
                return value == value.rounded() ? String(Int(value)) : String(value)
            }
            return "?"
        }
        switch method {
        case "run", "job.submit", "session.open":
            return text("cmd")
        case "fs.put", "fs.get", "fs.ls":
            return text("path")
        case "open":
            return text("target")
        case "clip.set":
            return text("text")
        case "input.move":
            return "move \(num("x")),\(num("y"))"
        case "input.click":
            return "click \(num("x")),\(num("y"))"
        case "input.drag":
            return "drag \(num("x1")),\(num("y1")) → \(num("x2")),\(num("y2"))"
        case "input.scroll":
            return "scroll \(num("dx")),\(num("dy")) @ \(num("x")),\(num("y"))"
        case "input.key":
            let mods = params["mods"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            return (mods + [text("key")]).joined(separator: "+")
        case "input.type":
            let value = text("text")
            return value.count > 60 ? String(value.prefix(60)) + "…" : value
        case "job.status", "job.tail", "job.result", "job.kill":
            return text("jobId")
        case "session.write", "session.read", "session.close", "mcp.list", "mcp.close":
            return text("sessionId")
        case "mcp.open":
            return text("name").isEmpty ? text("command") : text("name")
        case "mcp.call":
            return text("tool")
        case "power.assert":
            return "\(num("seconds"))s"
        case "screen.record":
            return "\(num("seconds"))s"
        case "screen.window":
            return text("app")
        case "sys.which":
            return params["names"]?.arrayValue?.compactMap { $0.stringValue }.joined(separator: " ") ?? ""
        case "policy.check":
            return text("subject")
        default:
            return ""
        }
    }
}

// MARK: - 意图(审批卡上给人看的那句话)

/// 一条请求"想干什么",而不是"怎么干"。
///
/// 为什么要有这个:用户的原话是**"让用户知道他申请干什么,而不是给用户看命令"**。
/// 一行 `cd /x && godot --headless --script res://tests/a.gd 2>&1 | tail -5` 对
/// 非工程师是噪音,对工程师也要读三秒;"跑一遍 Godot 里的测试"是一秒。
/// 原始命令没有被藏起来 —— 它进 `detail`,卡片上折叠着,想看点一下就有。
///
/// 这里**只产出 key + 参数,不产出成品句子**:Core 不许 import 界面层,也拿不到
/// `L()`。界面那边用 `Intent.headlineKey` 查文案表再填 `headlineArgs`。
/// agent 自己传了 `why` 的时候走 `literalHeadline` —— 它已经是人话了,照抄。
public struct Intent: Equatable {

    /// **它动的是 Mac 的哪一块**,不是"有多危险"。
    ///
    /// 危险分档是另一根轴,由 App 层的 `ApprovalRisk.classify` 负责(只读/写/删)。
    /// 两根轴故意不重叠:这里回答"终端还是文件还是屏幕",那里回答"要不要紧"。
    /// 卡片上一枚徽标 + 一个危险药丸,两条信息各占一处,不互相翻译。
    public enum Area: String, CaseIterable, Equatable {
        case terminal
        case files
        case screen
        case input
        case clipboard
        case web
        case tools
        case mac

        /// SF Symbol 名。不是面向用户的文字,可以写在 Core 里。
        public var symbol: String {
            switch self {
            case .terminal:  return "terminal"
            case .files:     return "folder"
            case .screen:    return "camera.viewfinder"
            case .input:     return "cursorarrow.click"
            case .clipboard: return "doc.on.clipboard"
            case .web:       return "globe"
            case .tools:     return "wrench.and.screwdriver"
            case .mac:       return "desktopcomputer"
            }
        }

        /// 面向用户的短名走文案表,别在 Core 里写中文(铁律 3)。
        public var localizationKey: String { return "intent.area." + rawValue }
    }

    /// 文案表里的 key。`literalHeadline` 非空时忽略它。
    public let headlineKey: String
    /// 填进 headline 里 `%@` 的参数,已经截断好。
    public let headlineArgs: [String]
    /// agent 传来的 `why`。有就直接用,不查表。
    public let literalHeadline: String?
    public let area: Area
    /// 受影响的东西:路径 / App / 网址 / 坐标。一行,已截断。
    public let scope: String
    /// 原始命令或参数。卡片默认折叠。
    public let detail: String

    public init(headlineKey: String,
                headlineArgs: [String] = [],
                literalHeadline: String? = nil,
                area: Area,
                scope: String = "",
                detail: String = "") {
        self.headlineKey = headlineKey
        self.headlineArgs = headlineArgs
        self.literalHeadline = literalHeadline
        self.area = area
        self.scope = scope
        self.detail = detail
    }

    /// 不查文案表也能拿到的一串字 —— 审计与测试用,别拿它当界面文字。
    public var headlineSeed: String {
        if let literal = literalHeadline { return literal }
        return ([headlineKey] + headlineArgs).joined(separator: " ")
    }
}

extension PolicyEngine {

    /// 一条请求 → 一句人话的意图。纯函数,`swift test` 里能完整覆盖。
    public static func intent(method: String, params: JSONValue) -> Intent {
        let why = RPCRequest.cleanWhy(params["why"]?.stringValue)
        let subject = PolicyEngine.subject(method: method, params: params)
        let area = PolicyEngine.area(method: method, params: params)
        let scope = PolicyEngine.scopeText(method: method, params: params, subject: subject)
        let detail = PolicyEngine.detailText(method: method, params: params, subject: subject)
        let (key, args) = PolicyEngine.headline(method: method, params: params, subject: subject)
        return Intent(headlineKey: key,
                      headlineArgs: args,
                      literalHeadline: why,
                      area: area,
                      scope: scope,
                      detail: detail)
    }

    /// 方法 → 它动的是哪一块。跟"危不危险"无关(那是 ApprovalRisk 的活)。
    public static func area(method: String, params: JSONValue) -> Intent.Area {
        switch method {
        case "run", "job.submit", "job.status", "job.tail", "job.result", "job.kill", "job.list",
             "session.open", "session.write", "session.read", "session.close", "verify.run":
            return .terminal
        case "fs.put", "fs.get", "fs.ls":
            return .files
        case "screen.shot", "screen.list", "screen.window", "screen.record", "screen.selfshot":
            return .screen
        case "input.where", "input.move", "input.click", "input.drag",
             "input.scroll", "input.key", "input.type":
            return .input
        case "clip.get", "clip.set":
            return .clipboard
        case "mcp.servers", "mcp.open", "mcp.list", "mcp.call", "mcp.close":
            return .tools
        case "open":
            // `open` 既能开网址也能开文件,按 target 长相分。
            let target = params["target"]?.stringValue ?? ""
            return PolicyEngine.looksLikeURL(target) ? .web : .files
        default:
            // sys.* / notify / policy.* / power.* / app.*,以及没登记的新方法。
            // 认错了只影响徽标好不好看,不影响放行判定。
            return .mac
        }
    }

    /// 命令里那个"工具词":`cd /x && npm test` → `npm`。
    /// 前面的 `cd`、`FOO=bar` 这类前缀跳过,绝对路径只留最后一段。
    public static func toolWord(inCommand command: String) -> String {
        let segments = command.split(whereSeparator: { $0 == ";" || $0 == "\n" })
            .flatMap { $0.components(separatedBy: "&&") }
            .flatMap { $0.components(separatedBy: "|") }
        for segment in segments {
            let tokens = segment.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            for token in tokens {
                if token == "cd" { break }              // 这一段只是换目录,看下一段
                if token.contains("=") { continue }     // FOO=bar 前缀
                if token.hasPrefix("(") || token.hasPrefix("{") { continue }
                let last = token.split(separator: "/").last.map(String.init) ?? token
                let cleaned = last.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()"))
                if cleaned.isEmpty { continue }
                return cleaned
            }
        }
        return ""
    }

    /// 工具词 → 文案 key 后缀。认不出就返回 nil,由调用方落到"执行一条命令"。
    private static let toolKeys: [String: String] = [
        "git": "git", "gh": "git",
        "npm": "npm", "npx": "npm", "pnpm": "npm", "yarn": "npm", "bun": "npm",
        "swift": "swift", "xcodebuild": "xcodebuild", "xcrun": "xcodebuild",
        "godot": "godot", "blender": "blender",
        "python": "python", "python3": "python", "pytest": "test",
        "node": "node", "deno": "node",
        "brew": "brew", "ffmpeg": "ffmpeg",
        "make": "make", "cargo": "cargo", "docker": "docker",
        "ls": "ls", "cat": "ls", "rg": "search", "grep": "search", "find": "search",
        "curl": "net", "wget": "net", "scp": "net", "rsync": "net"
    ]

    private static func headline(method: String,
                                 params: JSONValue,
                                 subject: String) -> (String, [String]) {
        func fileName(_ raw: String) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return "?" }
            let last = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
            return last.isEmpty ? trimmed : last
        }

        switch method {
        case "run", "job.submit":
            let tool = toolWord(inCommand: params["cmd"]?.stringValue ?? subject)
            let base = method == "job.submit" ? "intent.job.submit." : "intent.run."
            if let suffix = toolKeys[tool.lowercased()] {
                return (base + suffix, [])
            }
            return (base + "other", [tool.isEmpty ? "?" : clip(tool, 24)])
        case "fs.put":
            return ("intent.fs.put", [clip(fileName(params["path"]?.stringValue ?? ""), 40)])
        case "fs.get":
            return ("intent.fs.get", [clip(fileName(params["path"]?.stringValue ?? ""), 40)])
        case "fs.ls":
            return ("intent.fs.ls", [clip(fileName(params["path"]?.stringValue ?? ""), 40)])
        case "screen.shot", "screen.list":
            return ("intent.screen.shot", [])
        case "screen.selfshot":
            return ("intent.screen.selfshot", [])
        case "screen.window":
            let app = params["app"]?.stringValue ?? ""
            return app.isEmpty ? ("intent.screen.frontWindow", [])
                               : ("intent.screen.window", [clip(app, 30)])
        case "screen.record":
            return ("intent.screen.record", [])
        case "clip.get":
            return ("intent.clip.get", [])
        case "clip.set":
            return ("intent.clip.set", [])
        case "open":
            let target = params["target"]?.stringValue ?? ""
            return looksLikeURL(target) ? ("intent.open.url", [clip(host(of: target), 40)])
                                        : ("intent.open.file", [clip(fileName(target), 40)])
        case "input.where":
            return ("intent.input.where", [])
        case "input.move":
            return ("intent.input.move", [])
        case "input.click":
            return ("intent.input.click", [])
        case "input.drag":
            return ("intent.input.drag", [])
        case "input.scroll":
            return ("intent.input.scroll", [])
        case "input.key":
            return ("intent.input.key", [clip(subject, 24)])
        case "input.type":
            return ("intent.input.type", [])
        case "job.status", "job.result":
            return ("intent.job.status", [])
        case "job.tail":
            return ("intent.job.tail", [])
        case "job.kill":
            return ("intent.job.kill", [])
        case "job.list":
            return ("intent.job.list", [])
        case "session.open":
            return ("intent.session.open", [])
        case "session.write":
            return ("intent.session.write", [])
        case "session.read":
            return ("intent.session.read", [])
        case "session.close":
            return ("intent.session.close", [])
        case "mcp.servers":
            return ("intent.mcp.servers", [])
        case "mcp.open":
            return ("intent.mcp.open", [clip(subject, 30)])
        case "mcp.list":
            return ("intent.mcp.list", [])
        case "mcp.call":
            return ("intent.mcp.call", [clip(params["tool"]?.stringValue ?? "?", 30)])
        case "mcp.close":
            return ("intent.mcp.close", [])
        case "sys.info":
            return ("intent.sys.info", [])
        case "sys.perms":
            return ("intent.sys.perms", [])
        case "sys.which":
            return ("intent.sys.which", [])
        case "notify":
            return ("intent.notify", [])
        case "power.assert":
            return ("intent.power.assert", [])
        case "power.release":
            return ("intent.power.release", [])
        case "policy.get", "policy.check":
            return ("intent.policy", [])
        case "verify.run":
            return ("intent.verify", [])
        case "app.relaunch":
            return ("intent.app.relaunch", [])
        case "app.update":
            return ("intent.app.update", [])
        case "app.doctor":
            return ("intent.app.doctor", [])
        case "app.showWindow":
            return ("intent.app.showWindow", [])
        default:
            return ("intent.generic", [clip(method, 40)])
        }
    }

    private static func scopeText(method: String, params: JSONValue, subject: String) -> String {
        func text(_ key: String) -> String { return params[key]?.stringValue ?? "" }
        switch method {
        case "run", "job.submit", "session.open":
            return clip(text("cwd"), 64)
        case "fs.put", "fs.get", "fs.ls":
            return clip(text("path"), 64)
        case "open":
            return clip(text("target"), 64)
        case "screen.window":
            return clip(text("app"), 64)
        case "mcp.call", "mcp.open":
            return clip(subject, 64)
        case "input.move", "input.click", "input.drag", "input.scroll", "input.key", "input.type":
            return clip(subject, 64)
        default:
            return clip(subject, 64)
        }
    }

    private static func detailText(method: String, params: JSONValue, subject: String) -> String {
        var detail = subject
        if let cwd = params["cwd"]?.stringValue, !cwd.isEmpty,
           method == "run" || method == "job.submit" || method == "session.open" {
            detail += "\n(cwd: \(cwd))"
        }
        return detail
    }

    static func looksLikeURL(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
            || lower.hasPrefix("mailto:") || lower.hasPrefix("x-apple")
    }

    private static func host(of target: String) -> String {
        guard let url = URL(string: target), let host = url.host else { return target }
        return host
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.count <= limit { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }
}
