import Foundation
import MacHandsCore

/// SPEC §11 `job.*`:提交即返回的后台作业。输出落文件,agent 断线不丢;
/// App 重启后原进程失联,记 `orphaned`,文件仍在。
final class JobManager {

    static let shared = JobManager()

    static var root: URL {
        return Paths.supportDir.appendingPathComponent("jobs", isDirectory: true)
    }

    final class Job {
        let id: String
        let cmd: String
        let cwd: String
        let startedAt: Date
        let timeout: TimeInterval
        let dir: URL
        var process: Process?
        var state: String = "running"      // running | exited | killed | orphaned
        var code: Int?
        var endedAt: Date?
        var killer: DispatchWorkItem?
        var outHandle: FileHandle?
        var errHandle: FileHandle?

        init(id: String, cmd: String, cwd: String, timeout: TimeInterval, dir: URL) {
            self.id = id
            self.cmd = cmd
            self.cwd = cwd
            self.startedAt = Date()
            self.timeout = timeout
            self.dir = dir
        }

        var outURL: URL { return dir.appendingPathComponent("stdout.log") }
        var errURL: URL { return dir.appendingPathComponent("stderr.log") }
        var metaURL: URL { return dir.appendingPathComponent("meta.json") }
    }

    private let lock = NSLock()
    private var jobs: [String: Job] = [:]

    private init() {}

    // MARK: - 提交

    func submit(cmd: String, cwd: String?, env: [String: String], timeout: TimeInterval) throws -> Job {
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
        let dir = JobManager.root.appendingPathComponent(id, isDirectory: true)
        Paths.ensureDirectory(JobManager.root, permissions: 0o700)
        Paths.ensureDirectory(dir, permissions: 0o700)

        var directory = FileManager.default.homeDirectoryForCurrentUser.path
        if let requested = cwd, !requested.isEmpty {
            let expanded = Shell.expandPath(requested)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
                throw InputController.Failure(code: .enoent, message: "no such folder: \(requested)")
            }
            directory = expanded
        }

        let job = Job(id: id, cmd: cmd, cwd: directory, timeout: timeout, dir: dir)
        let fm = FileManager.default
        _ = fm.createFile(atPath: job.outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        _ = fm.createFile(atPath: job.errURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        guard let out = try? FileHandle(forWritingTo: job.outURL),
              let err = try? FileHandle(forWritingTo: job.errURL) else {
            throw InputController.Failure(code: .eio, message: "cannot open job log files")
        }
        job.outHandle = out
        job.errHandle = err

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", cmd]
        process.environment = Shell.environment(extra: env)
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            self?.finish(id: id, status: Int(finished.terminationStatus))
        }
        job.process = process
        writeMeta(job)

        do {
            try process.run()
        } catch {
            try? out.close(); try? err.close()
            throw InputController.Failure(code: .eio, message: "cannot start job: \(error.localizedDescription)")
        }

        let killer = DispatchWorkItem { [weak self] in
            self?.kill(id: id, reason: "timeout")
        }
        job.killer = killer
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)

        lock.lock(); jobs[id] = job; lock.unlock()
        return job
    }

    private func finish(id: String, status: Int) {
        lock.lock()
        guard let job = jobs[id] else { lock.unlock(); return }
        job.killer?.cancel()
        if job.state == "running" { job.state = "exited" }
        if job.code == nil { job.code = status }
        job.endedAt = Date()
        try? job.outHandle?.close(); try? job.errHandle?.close()
        job.outHandle = nil; job.errHandle = nil
        lock.unlock()
        writeMeta(job)
    }

    // MARK: - 查询

    func status(id: String) -> JSONValue? {
        lock.lock()
        if let job = jobs[id] {
            lock.unlock()
            return describe(job)
        }
        lock.unlock()
        // 不在内存里:可能是 App 重启前提交的,读 meta.json。
        let dir = JobManager.root.appendingPathComponent(id, isDirectory: true)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              var meta = JSONValue.parse(data)?.objectValue else { return nil }
        if meta["state"]?.stringValue == "running" { meta["state"] = .string("orphaned") }
        meta["outBytes"] = .int(fileSize(dir.appendingPathComponent("stdout.log")))
        meta["errBytes"] = .int(fileSize(dir.appendingPathComponent("stderr.log")))
        return .object(meta)
    }

    func result(id: String, wait: TimeInterval) -> JSONValue? {
        let deadline = Date().addingTimeInterval(max(0, wait))
        // `while true` 编译器认得是不落空的循环;`repeat … while true` 未必。
        while true {
            guard let current = status(id: id) else { return nil }
            if current["state"]?.stringValue != "running" { return current }
            if Date() >= deadline { return current }
            usleep(200_000)
        }
    }

    func tail(id: String, stream: String, offset: Int, limit: Int) -> (Data, Int, Bool)? {
        let dir = JobManager.root.appendingPathComponent(id, isDirectory: true)
        let url = dir.appendingPathComponent(stream == "err" ? "stderr.log" : "stdout.log")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = fileSize(url)
        let start = max(0, min(offset, size))
        try? handle.seek(toOffset: UInt64(start))
        let data = (try? handle.read(upToCount: limit)) ?? Data()
        let next = start + data.count
        let finished: Bool
        lock.lock()
        let running = jobs[id]?.state == "running"
        lock.unlock()
        finished = !running && next >= size
        return (data, next, finished)
    }

    @discardableResult
    func kill(id: String, reason: String = "killed") -> Bool {
        lock.lock()
        guard let job = jobs[id], let process = job.process else { lock.unlock(); return false }
        let wasRunning = job.state == "running"
        if wasRunning {
            job.state = "killed"
            job.code = reason == "timeout" ? 124 : 137
        }
        let pid = process.processIdentifier
        lock.unlock()
        guard wasRunning else { return false }
        ProcessTree.terminate(tree: pid)
        return true
    }

    func list() -> [JSONValue] {
        var seen: Set<String> = []
        var out: [JSONValue] = []
        lock.lock()
        let live = Array(jobs.values).sorted { $0.startedAt > $1.startedAt }
        lock.unlock()
        for job in live {
            seen.insert(job.id)
            out.append(describe(job))
        }
        if let names = try? FileManager.default.contentsOfDirectory(atPath: JobManager.root.path) {
            for name in names.sorted() where !seen.contains(name) {
                if let described = status(id: name) { out.append(described) }
            }
        }
        return out
    }

    // MARK: - 内部

    private func describe(_ job: Job) -> JSONValue {
        lock.lock()
        let state = job.state
        let code = job.code
        let ended = job.endedAt
        lock.unlock()
        let ms = Int(((ended ?? Date()).timeIntervalSince(job.startedAt)) * 1000)
        var body: [String: JSONValue] = [
            "jobId": .string(job.id),
            "cmd": .string(job.cmd),
            "cwd": .string(job.cwd),
            "state": .string(state),
            "ms": .int(ms),
            "startedAt": .number(job.startedAt.timeIntervalSince1970 * 1000),
            "outBytes": .int(fileSize(job.outURL)),
            "errBytes": .int(fileSize(job.errURL))
        ]
        if let code = code { body["code"] = .int(code) }
        return .object(body)
    }

    private func writeMeta(_ job: Job) {
        let data = CanonicalJSON.data(describe(job))
        try? data.write(to: job.metaURL, options: .atomic)
    }

    private func fileSize(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }
}
