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
        "power.assert", "power.release", "app.relaunch", "verify.run"
    ]

    /// 读方法:"读取也要问"关闭时直接放行;readonly 模式下放行。
    public static let readMethods: Set<String> = [
        "fs.get", "fs.ls", "screen.shot", "screen.list", "screen.window", "screen.record",
        "sys.info", "sys.perms", "sys.which", "clip.get",
        "job.status", "job.tail", "job.result", "job.list",
        "session.read", "mcp.servers", "mcp.list"
    ]

    /// 从不需要审批:给用户看的通知、让 agent 提前知道规则的两条。
    public static let alwaysAllowedMethods: Set<String> = ["notify", "policy.get", "policy.check"]

    private let lock = NSLock()
    private var state: PolicyState
    /// agentId → "1 小时授权" 到期时间。
    private var grants: [String: Date] = [:]
    /// 许可证过期时,run / fs.put 要回 LICENSE(SPEC §7.5)。
    private var licenseBlocksWrites = false

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
