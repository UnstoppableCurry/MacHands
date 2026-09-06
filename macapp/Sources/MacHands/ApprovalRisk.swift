import Foundation

// 审批卡(ApprovalPanel.swift)上那颗风险胶囊的判档逻辑。只依赖 Foundation,
// 所以能直接 `cat ApprovalRisk.swift 测试.swift | swift -` 跑断言(这台机器没有 XCTest)。

/// 审批卡上的风险档位:只读 / 会写盘 / 删除。
///
/// 这是给**人**看的一眼提示,不是策略判定(策略在 PolicyEngine,黑名单在那里拦)。
/// 判错的代价不对称:把只读的判成"会写盘"只是多提醒一句;把 `rm -rf` 判成只读
/// 会让人闭着眼睛点允许。所以拿不准的一律往重了判,只有**每一段**都能认出来是
/// 只读命令、而且没有任何写盘的重定向时,才给绿色。
enum ApprovalRiskLevel: String, Equatable {
    case readOnly = "read"
    case writes = "write"
    case deletes = "delete"
}

enum ApprovalRisk {

    // MARK: - 方法

    /// SPEC §5.1 里只读的方法(跟 PolicyEngine.readMethods 一致,外加两个从不审批的)。
    static let readOnlyMethods: Set<String> = [
        "fs.get", "fs.ls", "screen.shot", "screen.list", "sys.info", "clip.get",
        "policy.get", "notify"
    ]

    // MARK: - run 的启发式

    /// 一段(按 `|`、`&&`、`||`、`;`、换行切开)以这些命令开头就算只读候选。
    /// 有意不收 curl / wget / xargs / python / node:它们默认就能写盘。
    static let readOnlyCommands: Set<String> = [
        "ls", "cat", "head", "tail", "less", "more", "wc", "grep", "egrep", "fgrep", "rg", "ag",
        "fd", "pwd", "cd", "echo", "printf", "true", "false", "test", "[",
        "whoami", "id", "uname", "sw_vers", "sysctl", "hostname", "uptime", "date", "cal",
        "env", "printenv", "which", "whereis", "type", "command", "file", "stat", "du", "df",
        "ps", "pgrep", "top", "lsof", "netstat", "ifconfig", "ipconfig", "ping", "dig", "nslookup",
        "tree", "diff", "cmp", "md5", "shasum", "sort", "uniq", "cut", "tr", "awk", "sed",
        "basename", "dirname", "realpath", "readlink", "xxd", "hexdump", "strings", "jq",
        "git", "find", "swift", "xcodebuild", "node", "npm", "brew", "python3", "ruby", "defaults",
        "sleep", "wait", "exit", "export", "set", "unset", "alias", "history", "man", "tldr",
        "otool", "codesign", "spctl", "plutil", "mdls", "mdfind", "system_profiler", "pmset",
        "launchctl"
    ]

    /// 上面那张表里,只有**第一个参数**是这些之一时才算只读的几个
    /// (`git status` 是,`git -C x status` 不是——宁可多问)。
    static let readOnlySubcommands: [String: Set<String>] = [
        "git": ["status", "log", "diff", "show", "blame", "branch", "rev-parse", "ls-files",
                "describe", "shortlog", "reflog", "remote", "cat-file", "grep", "count-objects",
                "fetch", "--version"],
        "swift": ["--version", "-version"],
        "xcodebuild": ["-version", "-showsdks", "-list"],
        "node": ["-v", "--version"],
        "npm": ["ls", "list", "view", "info", "outdated", "-v", "--version", "root", "prefix"],
        "brew": ["list", "info", "--version", "-v", "doctor", "outdated", "deps", "search"],
        "python3": ["--version", "-V"],
        "ruby": ["--version", "-v"],
        "defaults": ["read"],
        "launchctl": ["list", "print"],
        "pmset": ["-g"],
        "codesign": ["-d", "-dv", "-dvv", "--display", "--verify"],
        "sysctl": ["-n", "-a", "hw.model", "hw.ncpu", "hw.memsize", "machdep.cpu.brand_string"],
        "set": ["-e", "-x", "-u", "-o", "-eu", "-ex", "-eux", "-euo", "-euxo"]
    ]

    /// 命中即"删除"。`\b` 边界,大小写不敏感;短语按顺序整体匹配。
    static let deletePatterns: [String] = [
        #"(^|[\s;&|(`$])(rm|rmdir|unlink|shred|trash|srm)(\s|$)"#,
        #"\bgit\s+(clean|reset\s+--hard|checkout\s+--\s|branch\s+-[dD]\b|push\b[^\n|;&]*(--force|-f\b|--delete|\+))"#,
        #"\bfind\b[^\n|;&]*(-delete\b|-exec\s+rm\b)"#,
        #"\bdiskutil\s+(erase|reformat|partition|secureErase)"#,
        #"\b(mkfs|newfs)\b"#,
        #"\bdd\b[^\n|;&]*\bof=/dev/"#,
        #"\brsync\b[^\n|;&]*--delete"#,
        #"\btruncate\s+-s\s*0"#,
        #"\bdrop\s+(table|database|schema)\b"#,
        #"\bdocker\s+(system\s+prune|rm|rmi|volume\s+rm)"#,
        #"\bnpm\s+uninstall\b"#,
        #"\bbrew\s+(uninstall|remove|rm)\b"#,
        #"\bosascript\b[^\n]*\b(delete|empty the trash)"#,
        #"(^|[\s;&|])>\s*/dev/(disk|rdisk)"#
    ]

    // MARK: - 判定

    static func classify(method: String, subject: String) -> ApprovalRiskLevel {
        if readOnlyMethods.contains(method) { return .readOnly }
        if method == "run" {
            let command = subject.trimmingCharacters(in: .whitespacesAndNewlines)
            if command.isEmpty { return .writes }
            if matchesDelete(command) { return .deletes }
            return isReadOnlyCommand(command) ? .readOnly : .writes
        }
        // fs.put / open / clip.set / 没见过的方法:都算会改东西。
        return .writes
    }

    static func matchesDelete(_ command: String) -> Bool {
        for pattern in deletePatterns {
            if command.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    /// 每一段都只读、且没有写文件的重定向,才算只读。
    static func isReadOnlyCommand(_ command: String) -> Bool {
        // `2>&1`、`2>/dev/null`、`&>/dev/null`、`>/dev/null` 不算写盘;别的 `>`、`>>` 都算。
        var scrubbed = command
        for harmless in ["2>&1", "2>/dev/null", "2> /dev/null", "&>/dev/null", "&> /dev/null",
                         ">/dev/null", "> /dev/null", "1>&2", "<<<", "<<"] {
            scrubbed = scrubbed.replacingOccurrences(of: harmless, with: " ")
        }
        if scrubbed.contains(">") { return false }
        if scrubbed.range(of: #"\btee\b"#, options: .regularExpression) != nil { return false }
        if scrubbed.range(of: #"\bsed\b[^\n|;&]*\s-[a-zA-Z]*i"#, options: .regularExpression) != nil { return false }
        if scrubbed.range(of: #"\bfind\b[^\n|;&]*-(exec|execdir|ok|delete)\b"#, options: .regularExpression) != nil { return false }
        if scrubbed.range(of: #"\bgit\b[^\n|;&]*\s(-d|-D|-m|--delete|--move)\b"#, options: .regularExpression) != nil { return false }

        let segments = scrubbed
            .replacingOccurrences(of: "&&", with: "\n")
            .replacingOccurrences(of: "||", with: "\n")
            .split(whereSeparator: { $0 == "|" || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if segments.isEmpty { return false }

        for segment in segments {
            var words = segment.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // 去掉前面的 FOO=bar 环境变量赋值;整段都是赋值(`X=1`)按只读。
            while let first = words.first, first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil {
                words.removeFirst()
            }
            guard let head = words.first else { continue }
            // `(cd x && ls)`、`{ ls; }` 这种去掉括号。
            let name = head.trimmingCharacters(in: CharacterSet(charactersIn: "({}) "))
            if name.isEmpty { continue }
            guard readOnlyCommands.contains(name) else { return false }
            if let allowed = readOnlySubcommands[name] {
                guard words.count >= 2, allowed.contains(words[1]) else { return false }
            }
        }
        return true
    }
}
