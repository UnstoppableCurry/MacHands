import Foundation

/// SPEC §5.2 的审批策略。UI 无关,所以能被 `swift test` 完整覆盖。
public enum ApprovalMode: String, Codable, CaseIterable {
    case ask
    case auto
    case deny
}

public enum PolicyDecision: Equatable {
    case allow
    /// 需要弹审批卡。
    case ask
    /// 直接拒,`code` 是回给 agent 的 RPC 错误码(DENIED / POLICY / LICENSE)。
    case deny(code: String, reason: String)
}

/// 可持久化的那部分策略。SettingsStore 存它。
public struct PolicyState: Codable, Equatable {

    public var mode: ApprovalMode
    /// "总是允许这条" 按命令前缀记的白名单。
    public var allow: [String]
    /// 黑名单。默认那四条在 `PolicyEngine.defaultDeny` 里,这里是用户加的。
    public var deny: [String]
    /// SPEC §5.2:关闭时读类方法直接放行;打开则一样弹卡。
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

    /// SPEC §5.2 的默认黑名单。auto 模式下也拦。
    public static let defaultDeny: [String] = [
        "rm -rf /",
        "diskutil erase",
        "sudo",
        "osascript -e 'tell application \"System Events\" to keystroke"
    ]

    /// ask 模式下一定要问的方法(SPEC §5.2)。
    public static let writeMethods: Set<String> = ["run", "fs.put", "open", "clip.set"]

    /// "读取也要问" 关闭时直接放行的方法。
    public static let readMethods: Set<String> = [
        "fs.get", "fs.ls", "screen.shot", "screen.list", "sys.info", "clip.get"
    ]

    /// 从不需要审批:一个是给用户看的通知,一个是让 agent 提前知道规则。
    public static let alwaysAllowedMethods: Set<String> = ["notify", "policy.get"]

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

        // 黑名单先于一切模式:auto 也拦(SPEC §5.2)。
        let denyList = PolicyEngine.defaultDeny + current.deny
        if let hit = PolicyEngine.firstMatch(in: subject, patterns: denyList) {
            return .deny(code: RPCErrorCode.policy.rawValue, reason: hit)
        }

        if PolicyEngine.alwaysAllowedMethods.contains(method) {
            return .allow
        }

        if licenseBlocked && (method == "run" || method == "fs.put") {
            return .deny(code: RPCErrorCode.license.rawValue, reason: "trial ended")
        }

        switch current.mode {
        case .deny:
            return .deny(code: RPCErrorCode.denied.rawValue, reason: "mode=deny")
        case .auto:
            return .allow
        case .ask:
            break
        }

        let isRead = PolicyEngine.readMethods.contains(method)
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

    // MARK: - 匹配

    /// 黑名单匹配。单词型的条目(`sudo`)要求两侧是非字母数字,免得 `sudoku`
    /// 被当成 `sudo`;带空格的短语按子串匹配。
    public static func firstMatch(in subject: String, patterns: [String]) -> String? {
        guard !subject.isEmpty else { return nil }
        let haystack = Array(subject.lowercased())
        for pattern in patterns {
            let needle = Array(pattern.lowercased().trimmingCharacters(in: .whitespaces))
            if needle.isEmpty || needle.count > haystack.count { continue }
            let wordish = !needle.contains(" ")
            var index = 0
            while index + needle.count <= haystack.count {
                if Array(haystack[index..<(index + needle.count)]) == needle {
                    if !wordish {
                        return pattern
                    }
                    let beforeOK = index == 0 || !isWordCharacter(haystack[index - 1])
                    let afterIndex = index + needle.count
                    let afterOK = afterIndex >= haystack.count || !isWordCharacter(haystack[afterIndex])
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

    /// 从一条 RPC 里取出用来匹配的那段文字。
    public static func subject(method: String, params: JSONValue) -> String {
        switch method {
        case "run":
            return params["cmd"]?.stringValue ?? ""
        case "fs.put", "fs.get", "fs.ls":
            return params["path"]?.stringValue ?? ""
        case "open":
            return params["target"]?.stringValue ?? ""
        case "clip.set":
            return params["text"]?.stringValue ?? ""
        default:
            return ""
        }
    }
}
