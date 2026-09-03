import Foundation

/// Strips anything that could be key material or a password out of a line
/// before it ever reaches the log.
///
/// This is a belt-and-braces layer: no call site is *supposed* to hand secrets
/// to the logger, but ssh's own stderr and a mistyped paste both end up here,
/// so the logger refuses to trust its callers.
enum Redactor {

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
    }

    private static let rules: [Rule] = {
        let specs: [(String, String)] = [
            // A pasted private key, in full.
            ("-----BEGIN[^-]*PRIVATE KEY-----[\\s\\S]*?-----END[^-]*PRIVATE KEY-----",
             "<redacted private key>"),
            // Half a pasted private key (log lines are written one at a time).
            ("-----(BEGIN|END)[^-]*PRIVATE KEY-----", "<redacted private key marker>"),
            // key=value shaped secrets, however they are spelled.
            ("(?i)(password|passphrase|passwd|secret|token|TUNNEL_KEY_B64)([\"']?\\s*[:=]\\s*)\\S+",
             "$1$2<redacted>"),
            // Any long base64 run: covers key blobs we did not anticipate.
            ("[A-Za-z0-9+/]{60,}={0,2}", "<redacted-blob>")
        ]
        var out: [Rule] = []
        for (pattern, template) in specs {
            if let re = try? NSRegularExpression(pattern: pattern, options: []) {
                out.append(Rule(regex: re, template: template))
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

/// Append-only log at ~/Library/Logs/using-mac-tunnel-<name>.log (R4), rotated
/// at 5 MB with three generations kept (…log.1 … …log.3).
///
/// The name in the filename is the Mac's registered name, so `logrotate.sh`'s
/// `using-mac-tunnel*.log` glob and `uninstall.sh`'s per-name cleanup both find
/// it, whether the tunnel was installed by this app or by the shell script.
///
/// Writes are serialised on one queue, so ssh's stderr, the supervisor's state
/// changes and the setup window can all log without interleaving mid-line.
final class Log {

    static let shared = Log()

    private let queue = DispatchQueue(label: "com.using-mac.log")
    private let maxBytes: UInt64 = 5 * 1024 * 1024
    private let generations = 3
    private var handle: FileHandle?
    /// Cached rather than read from ConfigStore on every line: the logger must
    /// never reach back into a component that might, one day, log.
    private var name: String
    private var currentURL: URL

    /// Not `lazy`: `write()` stamps the time on the caller's thread while the
    /// queue may be formatting a line of its own, and a lazy property that two
    /// threads can be the first to touch is a data race.
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f
    }()

    private init() {
        // No ConfigStore here: it is constructed lazily and may itself log.
        // `use(name:)` is called once the configuration is known.
        self.name = ""
        self.currentURL = Paths.logFile(name: "unnamed")
    }

    var fileURL: URL {
        return queue.sync { currentURL }
    }

    /// Point the log at this Mac's registered name. Safe to call repeatedly;
    /// a rename leaves a breadcrumb in both files.
    func use(name newName: String) {
        let resolved = Config.isValid(name: newName) ? newName : "unnamed"
        queue.async { [weak self] in
            guard let self = self else { return }
            guard resolved != self.name else { return }
            let old = self.name
            let newURL = Paths.logFile(name: resolved)
            if !old.isEmpty && newURL != self.currentURL {
                self.appendLocked("\(self.formatter.string(from: Date())) log continues in \(newURL.lastPathComponent)\n")
            }
            try? self.handle?.close()
            self.handle = nil
            self.name = resolved
            self.currentURL = newURL
            if !old.isEmpty {
                self.appendLocked("\(self.formatter.string(from: Date())) log continued from using-mac-tunnel-\(old).log\n")
            }
        }
    }

    func write(_ message: String) {
        let stamp = formatter.string(from: Date())
        let safe = Redactor.scrub(message)
            .replacingOccurrences(of: "\r", with: "")
        queue.async { [weak self] in
            guard let self = self else { return }
            for line in safe.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.isEmpty { continue }
                self.appendLocked("\(stamp) \(line)\n")
            }
        }
    }

    /// Flush and close; called on quit so the last lines are not lost.
    func close() {
        queue.sync {
            try? handle?.close()
            handle = nil
        }
    }

    // MARK: - private, always on `queue`

    private func appendLocked(_ line: String) {
        rotateIfNeededLocked()
        guard let fh = openedHandleLocked() else { return }
        guard let data = line.data(using: .utf8) else { return }
        do {
            try fh.seekToEnd()
            try fh.write(contentsOf: data)
        } catch {
            // Disk full, or the file was deleted under us. Drop the handle and
            // let the next write reopen; never crash for a log line.
            try? handle?.close()
            handle = nil
        }
    }

    private func openedHandleLocked() -> FileHandle? {
        if let fh = handle { return fh }
        let fm = FileManager.default
        // ~/Library/Logs belongs to the system, not to us: create it if it is
        // somehow missing, but never re-chmod one that is already there.
        if !fm.fileExists(atPath: Paths.logDir.path) {
            try? fm.createDirectory(at: Paths.logDir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: currentURL.path) {
            fm.createFile(atPath: currentURL.path,
                          contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: currentURL)
        return handle
    }

    private func rotateIfNeededLocked() {
        let fm = FileManager.default
        let fileURL = currentURL
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? UInt64,
              size >= maxBytes else { return }

        try? handle?.close()
        handle = nil

        // …log.3 falls off the end; .2 -> .3, .1 -> .2, live -> .1
        let oldest = fileURL.appendingPathExtension("\(generations)")
        try? fm.removeItem(at: oldest)
        var index = generations - 1
        while index >= 1 {
            let from = fileURL.appendingPathExtension("\(index)")
            let to = fileURL.appendingPathExtension("\(index + 1)")
            if fm.fileExists(atPath: from.path) {
                try? fm.removeItem(at: to)
                try? fm.moveItem(at: from, to: to)
            }
            index -= 1
        }
        let first = fileURL.appendingPathExtension("1")
        try? fm.removeItem(at: first)
        try? fm.moveItem(at: fileURL, to: first)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: first.path)
    }
}
