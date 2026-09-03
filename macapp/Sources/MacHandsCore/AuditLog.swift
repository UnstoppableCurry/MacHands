import Foundation

/// SPEC §5.2:一切审批与执行都写 `~/Library/Logs/MacHands/audit.log`,
/// JSONL,一行一条:ts、agent、method、summary、decision、code、ms。
///
/// 这份日志是用户唯一能事后查"到底谁让我的 Mac 干了什么"的东西,所以:
///   * 一行一条,`grep` 与 `jq` 都能直接读;
///   * 写失败绝不抛出 —— 审计写不进去不该让一条命令失败,但会在 app.log 里留痕;
///   * 5 MB 轮转,留 3 代。
public final class AuditLog {

    public struct Entry {
        public var timestamp: Date
        public var agentId: String
        public var agentName: String
        public var method: String
        public var summary: String
        public var decision: String
        public var code: String?
        public var milliseconds: Int?

        public init(timestamp: Date = Date(),
                    agentId: String,
                    agentName: String,
                    method: String,
                    summary: String,
                    decision: String,
                    code: String? = nil,
                    milliseconds: Int? = nil) {
            self.timestamp = timestamp
            self.agentId = agentId
            self.agentName = agentName
            self.method = method
            self.summary = summary
            self.decision = decision
            self.code = code
            self.milliseconds = milliseconds
        }

        public var json: JSONValue {
            var object: [String: JSONValue] = [
                "ts": .string(AuditLog.timestampFormatter.string(from: timestamp)),
                "agent": .string(agentId),
                "agentName": .string(agentName),
                "method": .string(method),
                "summary": .string(AuditLog.clip(summary)),
                "decision": .string(decision)
            ]
            object["code"] = code.map { JSONValue.string($0) } ?? JSONValue.null
            object["ms"] = milliseconds.map { JSONValue.int($0) } ?? JSONValue.null
            return .object(object)
        }
    }

    public static let shared = AuditLog()

    public static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

    public static var directory: URL {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacHands", isDirectory: true)
    }

    public static var fileURL: URL {
        return directory.appendingPathComponent("audit.log")
    }

    private let queue = DispatchQueue(label: "app.machands.audit")
    private let url: URL
    private let maxBytes: UInt64 = 5 * 1024 * 1024
    private let generations = 3

    /// 写失败时的去处。AppDelegate 把它接到 app.log 上。
    public var onProblem: ((String) -> Void)?

    public init(url: URL = AuditLog.fileURL) {
        self.url = url
    }

    public var location: URL { return url }

    public func write(_ entry: Entry) {
        let line = CanonicalJSON.string(entry.json) + "\n"
        queue.async { [weak self] in
            self?.appendOnQueue(line)
        }
    }

    /// 只给测试与"退出前冲一下"用。
    public func flush() {
        queue.sync { }
    }

    // MARK: - private

    private func appendOnQueue(_ line: String) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        rotateIfNeeded()
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            onProblem?("audit log not writable at \(url.path)")
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            onProblem?("audit log write failed: \(error.localizedDescription)")
        }
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64,
              size >= maxBytes else { return }

        let oldest = url.appendingPathExtension("\(generations)")
        try? fm.removeItem(at: oldest)
        var index = generations - 1
        while index >= 1 {
            let from = url.appendingPathExtension("\(index)")
            let to = url.appendingPathExtension("\(index + 1)")
            if fm.fileExists(atPath: from.path) {
                try? fm.removeItem(at: to)
                try? fm.moveItem(at: from, to: to)
            }
            index -= 1
        }
        try? fm.removeItem(at: url.appendingPathExtension("1"))
        try? fm.moveItem(at: url, to: url.appendingPathExtension("1"))
    }

    static func clip(_ text: String) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ⏎ ")
        if flattened.count <= 400 { return flattened }
        return String(flattened.prefix(400)) + "…"
    }
}
