import Foundation

/// 把可能是密钥或口令的东西从日志行里抹掉。
///
/// 这是"腰带加背带":没有任何调用点**打算**把秘密交给日志,但子进程的 stderr
/// 和用户的误粘贴都会流到这里,所以日志器不信任它的调用者。
enum Redactor {

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
    }

    private static let rules: [Rule] = {
        let specs: [(String, String)] = [
            ("-----BEGIN[^-]*PRIVATE KEY-----[\\s\\S]*?-----END[^-]*PRIVATE KEY-----",
             "<redacted private key>"),
            ("-----(BEGIN|END)[^-]*PRIVATE KEY-----", "<redacted private key marker>"),
            ("(?i)(password|passphrase|passwd|secret|token|apikey|api_key)([\"']?\\s*[:=]\\s*)\\S+",
             "$1$2<redacted>"),
            ("[A-Za-z0-9+/_-]{60,}={0,2}", "<redacted-blob>")
        ]
        var out: [Rule] = []
        for (pattern, template) in specs {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                out.append(Rule(regex: regex, template: template))
            }
        }
        return out
    }()

    static func scrub(_ text: String) -> String {
        var current = text
        for rule in rules {
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            current = rule.regex.stringByReplacingMatches(in: current,
                                                          options: [],
                                                          range: range,
                                                          withTemplate: rule.template)
        }
        return current
    }
}

/// SPEC §7.6:`~/Library/Logs/MacHands/app.log`,自动轮转(5 MB × 3 代)。
///
/// 写入都串在一条队列上,所以中继、执行器与窗口可以同时记日志而不会串行到
/// 半行中间。
final class Log {

    static let shared = Log()

    private let queue = DispatchQueue(label: "app.machands.log")
    private let maxBytes: UInt64 = 5 * 1024 * 1024
    private let generations = 3
    private var handle: FileHandle?
    private let url: URL

    /// 不用 `lazy`:两个线程可能同时第一次碰它,那就是数据竞争。
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }()

    private init() {
        self.url = Paths.appLog
    }

    var fileURL: URL { return url }

    func write(_ message: String) {
        let stamp = formatter.string(from: Date())
        let safe = Redactor.scrub(message).replacingOccurrences(of: "\r", with: "")
        queue.async { [weak self] in
            guard let self = self else { return }
            for line in safe.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.isEmpty { continue }
                self.appendOnQueue("\(stamp) \(line)\n")
            }
        }
    }

    func close() {
        queue.sync {
            try? handle?.close()
            handle = nil
        }
    }

    // MARK: - 只在 queue 上跑

    private func appendOnQueue(_ line: String) {
        rotateIfNeeded()
        guard let fileHandle = openedHandle() else { return }
        guard let data = line.data(using: .utf8) else { return }
        do {
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: data)
        } catch {
            // 磁盘满,或者文件被人删了。丢掉句柄让下次重开;绝不为一行日志崩。
            try? handle?.close()
            handle = nil
        }
    }

    private func openedHandle() -> FileHandle? {
        if let existing = handle { return existing }
        let fm = FileManager.default
        if !fm.fileExists(atPath: Paths.logDir.path) {
            try? fm.createDirectory(at: Paths.logDir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: url.path) {
            _ = fm.createFile(atPath: url.path, contents: nil,
                              attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: url)
        return handle
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64,
              size >= maxBytes else { return }

        try? handle?.close()
        handle = nil

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
        let first = url.appendingPathExtension("1")
        try? fm.removeItem(at: first)
        try? fm.moveItem(at: url, to: first)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: first.path)
    }
}
