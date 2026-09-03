import Foundation

/// 一次性子进程的结果。
struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let launchError: String?

    var ok: Bool {
        return launchError == nil && !timedOut && status == 0
    }

    /// 给人看的一句话。
    var complaint: String {
        if let error = launchError { return error }
        if timedOut { return "timed out" }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed.split(separator: "\n").suffix(3).joined(separator: " / ")
        }
        return "exit status \(status)"
    }

    var trimmedOut: String {
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 短命子进程的阻塞帮手(sw_vers、sips、screencapture 之类)。
///
/// 两根管子各自在自己的队列上抽干,所以话多的子进程填不满 64 KB 管道缓冲、
/// 也就卡不死我们。**不要在主线程上调用它**:它会阻塞。
///
/// 长命的 `run`(要流式输出、要能中途超时杀掉)不走这里,见 Executor。
enum Shell {

    /// SPEC §5.1:PATH 前置这四段。
    static let pathPrefix = "~/.grok/bin:~/.cargo/bin:/opt/homebrew/bin:/usr/local/bin"

    static func expandedPathPrefix() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return pathPrefix.replacingOccurrences(of: "~", with: home)
    }

    /// 子进程用的环境:继承当前环境,PATH 前置。
    static func environment(extra: [String: String]? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = expandedPathPrefix() + ":" + existing
        if let extra = extra {
            for (key, value) in extra { env[key] = value }
        }
        return env
    }

    @discardableResult
    static func run(_ executable: String,
                    _ arguments: [String],
                    environment: [String: String]? = nil,
                    currentDirectory: String? = nil,
                    standardInput: String? = nil,
                    timeout: TimeInterval = 20) -> CommandResult {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment ?? Shell.environment()
        if let directory = currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let lock = NSLock()

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, stdout: "", stderr: "", timedOut: false,
                                 launchError: "cannot run \(executable): \(error.localizedDescription)")
        }

        DispatchQueue.global(qos: .utility).async(group: group) {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); outData = data; lock.unlock()
        }
        DispatchQueue.global(qos: .utility).async(group: group) {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); errData = data; lock.unlock()
        }

        if let input = standardInput, let data = input.data(using: .utf8) {
            try? inPipe.fileHandleForWriting.write(contentsOf: data)
        }
        try? inPipe.fileHandleForWriting.close()

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
        }

        // 孙进程可能还攥着管子,所以等待有上限。
        _ = group.wait(timeout: .now() + 3)

        lock.lock()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        lock.unlock()

        let status = process.isRunning ? -1 : process.terminationStatus
        return CommandResult(status: status, stdout: out, stderr: err,
                             timedOut: timedOut, launchError: nil)
    }

    /// `~` 展开(SPEC §5.1 要求 fs.* 的路径支持 `~`)。
    static func expandPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return (path as NSString).expandingTildeInPath
    }
}
