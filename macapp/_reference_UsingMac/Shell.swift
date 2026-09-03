import Foundation

/// Result of a one-shot child process.
struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let launchError: String?

    var ok: Bool {
        return launchError == nil && !timedOut && status == 0
    }

    /// The most useful single sentence to show a human.
    var complaint: String {
        if let e = launchError { return e }
        if timedOut { return "timed out" }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed.split(separator: "\n").suffix(3).joined(separator: " / ")
        }
        return "exit status \(status)"
    }
}

/// Blocking helper for short-lived children (ssh probes, launchctl, scutil).
///
/// Both pipes are drained on their own queues, so a chatty child can never
/// deadlock us by filling a 64 KB pipe buffer. Foundation's `Process` reaps the
/// child itself, so nothing is left as a zombie.
///
/// Never call this on the main thread: it blocks.
enum Shell {

    static func run(_ executable: String,
                    _ arguments: [String],
                    environment: [String: String]? = nil,
                    standardInput: String? = nil,
                    timeout: TimeInterval = 20) -> CommandResult {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment = environment {
            process.environment = environment
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
            return CommandResult(status: -1, stdout: "", stderr: "",
                                 timedOut: false,
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

        if let standardInput = standardInput, let data = standardInput.data(using: .utf8) {
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

        // Readers end when the child's pipe ends close. Bounded, because a
        // grandchild holding the pipe open must not hang the app forever.
        _ = group.wait(timeout: .now() + 3)

        lock.lock()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        lock.unlock()

        let status = process.isRunning ? -1 : process.terminationStatus
        return CommandResult(status: status, stdout: out, stderr: err,
                             timedOut: timedOut, launchError: nil)
    }

    /// Single-quote a string for a remote /bin/sh, the same way lib/remote.sh's
    /// `shq` does. Anything we send to the server goes through this.
    static func shellQuote(_ value: String) -> String {
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
