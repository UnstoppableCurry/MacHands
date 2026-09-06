import AppKit
import CoreGraphics
import UserNotifications
import MacHandsCore

/// 通知。裸二进制(没有 bundle id)里 `UNUserNotificationCenter.current()` 会崩,
/// 所以每一处都先问一句"我是不是 .app"。
enum Notifier {

    static var isAvailable: Bool {
        return Bundle.main.bundleIdentifier != nil
    }

    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error = error {
                    Log.shared.write("notification authorization failed: \(error.localizedDescription)")
                } else if !granted {
                    Log.shared.write("notifications not allowed by the user")
                }
            }
    }

    static func post(title: String, body: String) {
        guard isAvailable else {
            Log.shared.write("notification (no bundle): \(title) — \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Log.shared.write("notification failed: \(error.localizedDescription)")
            }
        }
    }
}

/// SPEC §5.1 + §11 的全部方法。
///
/// 每一条请求都先过策略,再执行,最后写一行审计日志。执行在自己的并发队列上,
/// 所以一条跑十分钟的 `run` 不会挡住别的 agent 的 `sys.info`。
final class Executor {

    struct AgentContext {
        let id: String
        let name: String
        let fromIP: String?
    }

    typealias Emit = (RPCOutbound) -> Void

    /// 一次 fs.get / screen.shot 的分块上限。
    /// 单帧 ≤ 1 MiB(SPEC §4.5),密文再 base64 一次会涨 4/3,所以取 96 KiB 原始字节。
    static let chunkBytes = 96 * 1024
    /// fs.get / job.tail 单次上限。原始字节 base64 进 JSON(×4/3),整条明文再加密、再
    /// base64url 一次(又 ×4/3),512 KiB 算下来约 911 KiB,留得住余量。
    static let maxRead = 512 * 1024
    static let defaultTimeout: TimeInterval = 600
    static let defaultTools = ["godot", "blender", "xcodebuild", "swift", "node", "python3", "brew", "cliclick", "ffmpeg", "git"]

    private let policy: PolicyEngine
    private let audit: AuditLog
    private let work = DispatchQueue(label: "app.machands.exec",
                                     qos: .userInitiated,
                                     attributes: .concurrent)

    /// 每执行一条就报一次,菜单栏用它显示"最近一次命令 · 几秒前"。
    var onActivity: ((String, String) -> Void)?
    /// 屏幕录制没授权时弹一次引导(SPEC §7.4)。
    private var screenGuidanceShown = false
    /// `power.assert` 起的 caffeinate。
    private static var caffeinate: Process?
    private static let caffeinateLock = NSLock()

    init(policy: PolicyEngine, audit: AuditLog = AuditLog.shared) {
        self.policy = policy
        self.audit = audit
    }

    // MARK: - 入口

    func handle(_ request: RPCRequest, agent: AgentContext, emit: @escaping Emit) {
        let subject = PolicyEngine.subject(method: request.method, params: request.params)
        let decision = policy.decide(agentId: agent.id, method: request.method, subject: subject)

        switch decision {
        case .allow:
            start(request, agent: agent, subject: subject, decision: "allow", emit: emit)

        case .deny(let code, let reason):
            finishDenied(request, agent: agent, subject: subject,
                         decision: "deny:\(reason)", code: code,
                         message: reason, emit: emit)

        case .ask:
            let card = ApprovalRequest(requestId: request.id,
                                       agentId: agent.id,
                                       agentName: agent.name,
                                       method: request.method,
                                       subject: subject.isEmpty ? request.method : subject,
                                       cwd: request.string("cwd"),
                                       fromIP: agent.fromIP)
            ApprovalPanelController.shared.ask(card) { [weak self] outcome in
                guard let self = self else { return }
                switch outcome {
                case .once:
                    self.start(request, agent: agent, subject: subject, decision: "once", emit: emit)
                case .hour:
                    self.policy.grantHour(agentId: agent.id)
                    self.start(request, agent: agent, subject: subject, decision: "hour", emit: emit)
                case .always:
                    if !subject.isEmpty { self.policy.alwaysAllow(prefix: subject) }
                    self.start(request, agent: agent, subject: subject, decision: "always", emit: emit)
                case .deny:
                    self.finishDenied(request, agent: agent, subject: subject,
                                      decision: "deny", code: RPCErrorCode.denied.rawValue,
                                      message: "refused on the Mac", emit: emit)
                case .timeout:
                    self.finishDenied(request, agent: agent, subject: subject,
                                      decision: "timeout", code: RPCErrorCode.timeout.rawValue,
                                      message: "nobody answered on the Mac", emit: emit)
                }
            }
        }
    }

    private func finishDenied(_ request: RPCRequest, agent: AgentContext, subject: String,
                              decision: String, code: String, message: String, emit: @escaping Emit) {
        emit(.failure(id: request.id, code: code, message: message))
        audit.write(AuditLog.Entry(agentId: agent.id, agentName: agent.name,
                                   method: request.method,
                                   summary: subject.isEmpty ? request.method : subject,
                                   decision: decision, code: code, milliseconds: 0))
    }

    private func start(_ request: RPCRequest, agent: AgentContext, subject: String,
                       decision: String, emit: @escaping Emit) {
        let began = Date()
        onActivity?(agent.id, subject.isEmpty ? request.method : subject)
        work.async { [weak self] in
            guard let self = self else { return }
            let outcome = self.perform(request, agent: agent, emit: emit)
            let elapsed = Int(Date().timeIntervalSince(began) * 1000)
            emit(outcome)
            var code: String? = nil
            if case .failure(_, let failureCode, _) = outcome { code = failureCode }
            if case .response(_, let body) = outcome, let status = body["code"]?.intValue {
                code = String(status)
            }
            self.audit.write(AuditLog.Entry(agentId: agent.id, agentName: agent.name,
                                            method: request.method,
                                            summary: subject.isEmpty ? request.method : subject,
                                            decision: decision, code: code,
                                            milliseconds: elapsed))
        }
    }

    // MARK: - 分发

    /// 返回的是这次 RPC 的**最后一条**(response 或 failure);流式帧在方法内部
    /// 自己 emit。
    private func perform(_ request: RPCRequest, agent: AgentContext, emit: @escaping Emit) -> RPCOutbound {
        switch request.method {
        case "sys.info":      return systemInfo(request)
        case "sys.perms":     return .response(id: request.id, body: Permissions.snapshot().json)
        case "sys.which":     return whichTools(request)
        case "run":           return runCommand(request, emit: emit)
        case "fs.put":        return filePut(request)
        case "fs.get":        return fileGet(request, emit: emit)
        case "fs.ls":         return fileList(request)
        case "screen.shot":   return screenShot(request, emit: emit)
        case "screen.list":   return .response(id: request.id, body: .object(["displays": displaysJSON()]))
        case "screen.window": return screenWindow(request, emit: emit)
        case "screen.record": return screenRecord(request, emit: emit)
        case "open":          return openTarget(request)
        case "clip.get":      return clipboardGet(request)
        case "clip.set":      return clipboardSet(request)
        case "notify":        return notifyUser(request)
        case "policy.get":    return .response(id: request.id, body: policy.publicSnapshot())
        case "policy.check":  return policyCheck(request, agent: agent)
        case "input.where", "input.move", "input.click", "input.drag", "input.scroll", "input.key", "input.type":
            return inputMethod(request)
        case "job.submit", "job.status", "job.tail", "job.result", "job.kill", "job.list":
            return jobMethod(request)
        case "session.open", "session.write", "session.read", "session.close":
            return sessionMethod(request)
        case "mcp.servers", "mcp.open", "mcp.list", "mcp.call", "mcp.close":
            return mcpMethod(request)
        case "power.assert", "power.release":
            return powerMethod(request)
        case "app.relaunch":  return relaunch(request)
        case "verify.run":
            return .response(id: request.id, body: .object(["rows": .array(Verifier.run().map { $0.json })]))
        default:
            return RPCOutbound.fail(request.id, .badParams, "unknown method \(request.method)")
        }
    }

    /// 新模块统一抛 `InputController.Failure`;这里翻译成 RPC 错误。
    private func fail(_ request: RPCRequest, _ error: Error) -> RPCOutbound {
        if let failure = error as? InputController.Failure {
            return RPCOutbound.fail(request.id, failure.code, failure.message)
        }
        return RPCOutbound.fail(request.id, .eio, error.localizedDescription)
    }

    // MARK: - sys.*

    private func systemInfo(_ request: RPCRequest) -> RPCOutbound {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osText = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        var body: [String: JSONValue] = [:]
        body["name"] = .string(Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
        body["model"] = optional(Shell.run("/usr/sbin/sysctl", ["-n", "hw.model"], timeout: 5).trimmedOut)
        body["os"] = .string(osText)
        body["arch"] = optional(Shell.run("/usr/bin/uname", ["-m"], timeout: 5).trimmedOut)
        body["user"] = .string(NSUserName())
        body["home"] = .string(home)
        body["cwd"] = .string(home)
        body["uptime"] = .number(ProcessInfo.processInfo.systemUptime.rounded())
        body["battery"] = batteryPercent()
        body["xcode"] = optional(firstLine(Shell.run("/usr/bin/xcodebuild", ["-version"], timeout: 15).stdout))
        body["node"] = optional(firstLine(Shell.run("/bin/zsh", ["-lc", "node -v"], timeout: 15).stdout))
        body["python"] = optional(firstLine(Shell.run("/bin/zsh", ["-lc", "python3 -V"], timeout: 15).stdout))

        // SPEC §11:开工体检一次拿全
        let memGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        body["mem_gb"] = .number((memGB * 10).rounded() / 10)
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: home),
           let free = (attributes[.systemFreeSize] as? NSNumber)?.doubleValue {
            body["disk_free_gb"] = .number((free / 1_000_000_000 * 10).rounded() / 10)
        } else {
            body["disk_free_gb"] = .null
        }
        body["cpu"] = optional(Shell.run("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"], timeout: 5).trimmedOut)
        body["gpu"] = gpuName()
        body["displays"] = displaysJSON()
        body["tools"] = whichMap(Executor.defaultTools)
        body["app_version"] = .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
        return .response(id: request.id, body: .object(body))
    }

    private func gpuName() -> JSONValue {
        let result = Shell.run("/usr/sbin/system_profiler", ["SPDisplaysDataType", "-json"], timeout: 25)
        guard result.ok, let data = result.stdout.data(using: .utf8),
              let root = JSONValue.parse(data)?.objectValue,
              let first = root["SPDisplaysDataType"]?.arrayValue?.first?.objectValue else { return .null }
        guard let name = first["sppci_model"]?.stringValue ?? first["_name"]?.stringValue else { return .null }
        return .string(name)
    }

    private func whichMap(_ names: [String]) -> JSONValue {
        let safe = names.filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." || $0 == "+" } }
        guard !safe.isEmpty else { return .object([:]) }
        let script = "for t in \(safe.joined(separator: " ")); do printf '%s=%s\\n' \"$t\" \"$(command -v $t 2>/dev/null)\"; done"
        let result = Shell.run("/bin/zsh", ["-lc", script], timeout: 20)
        var out: [String: JSONValue] = [:]
        for name in safe { out[name] = .null }
        for line in result.stdout.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<equals])
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            out[key] = value.isEmpty ? .null : .string(value)
        }
        return .object(out)
    }

    private func whichTools(_ request: RPCRequest) -> RPCOutbound {
        let names = request.param("names")?.arrayValue?.compactMap { $0.stringValue } ?? Executor.defaultTools
        return .response(id: request.id, body: whichMap(names))
    }

    private func policyCheck(_ request: RPCRequest, agent: AgentContext) -> RPCOutbound {
        let method = request.string("method") ?? "run"
        let subject = request.string("subject") ?? ""
        let decision = policy.check(agentId: agent.id, method: method, subject: subject)
        var body: [String: JSONValue] = ["decision": .string(decision.label), "method": .string(method)]
        if case .deny(let code, let reason) = decision {
            body["reason"] = .string(reason)
            body["code"] = .string(code)
        }
        return .response(id: request.id, body: .object(body))
    }

    /// 拿不到的值是 null,不是空串(铁律 4:不编造状态)。
    private func optional(_ text: String) -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .null : .string(trimmed)
    }

    private func firstLine(_ text: String) -> String {
        guard let line = text.split(separator: "\n", omittingEmptySubsequences: true).first else { return "" }
        return String(line)
    }

    private func batteryPercent() -> JSONValue {
        let result = Shell.run("/usr/bin/pmset", ["-g", "batt"], timeout: 5)
        guard result.launchError == nil else { return .null }
        for piece in result.stdout.split(whereSeparator: { $0 == "\t" || $0 == ";" || $0 == " " }) {
            if piece.hasSuffix("%"), let value = Int(piece.dropLast()) {
                return .int(value)
            }
        }
        return .null
    }

    // MARK: - run

    private func runCommand(_ request: RPCRequest, emit: @escaping Emit) -> RPCOutbound {
        guard let command = request.string("cmd"), !command.isEmpty else {
            return RPCOutbound.fail(request.id, .badParams, "run needs cmd")
        }
        let shell = request.string("shell") ?? "zsh"
        let shellPath = shell == "bash" ? "/bin/bash" : "/bin/zsh"
        let timeout = max(1.0, request.double("timeout") ?? Executor.defaultTimeout)

        var directory = FileManager.default.homeDirectoryForCurrentUser.path
        if let requested = request.string("cwd"), !requested.isEmpty {
            let expanded = Shell.expandPath(requested)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
                return RPCOutbound.fail(request.id, .enoent, "no such folder: \(requested)")
            }
            directory = expanded
        }

        let extra = envDictionary(request)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-lc", command]
        process.environment = Shell.environment(extra: extra)
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let requestId = request.id
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            Executor.emitChunks(data, key: "o", id: requestId, emit: emit)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            Executor.emitChunks(data, key: "e", id: requestId, emit: emit)
        }

        let began = Date()
        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return RPCOutbound.fail(request.id, .eio,
                                    "cannot start \(shellPath): \(error.localizedDescription)")
        }

        // SPEC §11.1:超时杀整棵树,不只杀 zsh。
        let pid = process.processIdentifier
        let timedOut = LockedBox(false)
        let killer = DispatchWorkItem {
            timedOut.value = true
            ProcessTree.terminate(tree: pid)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)

        process.waitUntilExit()
        killer.cancel()

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        // 进程退出后管子里可能还有最后一口。
        let restOut = outPipe.fileHandleForReading.availableData
        if !restOut.isEmpty { Executor.emitChunks(restOut, key: "o", id: requestId, emit: emit) }
        let restErr = errPipe.fileHandleForReading.availableData
        if !restErr.isEmpty { Executor.emitChunks(restErr, key: "e", id: requestId, emit: emit) }

        let wasKilled = timedOut.value
        if wasKilled {
            emit(.stream(id: requestId,
                         body: .object(["e": .string("\n[machands] timed out after \(Int(timeout))s\n")])))
        }

        let milliseconds = Int(Date().timeIntervalSince(began) * 1000)
        // 超时按 GNU timeout 的约定回 124,免得和命令自己的退出码混淆。
        let status = wasKilled ? 124 : Int(process.terminationStatus)
        return .response(id: requestId, body: .object(["code": .int(status),
                                                       "ms": .int(milliseconds)]))
    }

    private func envDictionary(_ request: RPCRequest) -> [String: String] {
        var extra: [String: String] = [:]
        if let environment = request.param("env")?.objectValue {
            for (key, value) in environment {
                if let text = value.stringValue { extra[key] = text }
            }
        }
        return extra
    }

    private static func emitChunks(_ data: Data, key: String, id: String, emit: Emit) {
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            let end = min(index + Executor.chunkBytes, bytes.count)
            let slice = Data(bytes[index..<end])
            let text = String(decoding: slice, as: UTF8.self)
            emit(.stream(id: id, body: .object([key: .string(text)])))
            index = end
        }
    }

    /// 把一个文件按块流出去(截图、录屏、目录包)。
    private static func streamFile(_ url: URL, id: String, emit: Emit) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        var total = 0
        while let chunk = try? handle.read(upToCount: Executor.chunkBytes), !chunk.isEmpty {
            total += chunk.count
            emit(.stream(id: id, body: .object(["data": .string(chunk.base64EncodedString())])))
        }
        return total
    }

    // MARK: - fs.*

    /// `data` 字段:发出去用标准 base64(SPEC §5.1 写的就是 base64);
    /// 收进来两种都认,免得对面按 §2 的通则用了 base64url。
    private static func decodeBinary(_ text: String) -> Data? {
        if text.contains("-") || text.contains("_") { return Base64URL.decode(text) }
        if let data = Data(base64Encoded: text, options: [.ignoreUnknownCharacters]) { return data }
        return Base64URL.decode(text)
    }

    private func filePut(_ request: RPCRequest) -> RPCOutbound {
        guard let rawPath = request.string("path"), !rawPath.isEmpty else {
            return RPCOutbound.fail(request.id, .badParams, "fs.put needs path")
        }
        guard let encoded = request.string("data"),
              let data = Executor.decodeBinary(encoded) else {
            return RPCOutbound.fail(request.id, .badParams, "fs.put needs base64 data")
        }
        let path = Shell.expandPath(rawPath)
        let append = request.bool("append") ?? false
        let fm = FileManager.default
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty, !fm.fileExists(atPath: parent) {
            try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }

        do {
            if append, fm.fileExists(atPath: path) {
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        } catch {
            return RPCOutbound.fail(request.id, .eio,
                                    "cannot write \(rawPath): \(error.localizedDescription)")
        }

        if let mode = request.int("mode") {
            try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        }
        return .response(id: request.id, body: .object(["bytes": .int(data.count)]))
    }

    private func fileGet(_ request: RPCRequest, emit: @escaping Emit) -> RPCOutbound {
        guard let rawPath = request.string("path"), !rawPath.isEmpty else {
            return RPCOutbound.fail(request.id, .badParams, "fs.get needs path")
        }
        let path = Shell.expandPath(rawPath)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            return RPCOutbound.fail(request.id, .enoent, "no such file: \(rawPath)")
        }
        if isDir.boolValue {
            // SPEC §11:目录自动打包成 tar.gz 流回去,agent 端解包。
            let temporary = fm.temporaryDirectory.appendingPathComponent("machands-\(UUID().uuidString).tar.gz")
            defer { try? fm.removeItem(at: temporary) }
            let parent = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            let result = Shell.run("/usr/bin/tar", ["-czf", temporary.path, "--no-mac-metadata", "--no-xattrs", "-C", parent, name], timeout: 900)
            guard result.ok else {
                return RPCOutbound.fail(request.id, .eio, "tar failed: \(result.complaint)")
            }
            let bytes = Executor.streamFile(temporary, id: request.id, emit: emit)
            return .response(id: request.id, body: .object(["archive": .bool(true),
                                                            "name": .string(name),
                                                            "bytes": .int(bytes),
                                                            "size": .int(bytes),
                                                            "eof": .bool(true)]))
        }
        guard let attributes = try? fm.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.intValue else {
            return RPCOutbound.fail(request.id, .eio, "cannot stat \(rawPath)")
        }

        let offset = max(0, request.int("offset") ?? 0)
        let wanted = min(request.int("length") ?? Executor.maxRead, Executor.maxRead)
        guard offset <= size else {
            return .response(id: request.id, body: .object(["data": .string(""),
                                                            "size": .int(size),
                                                            "eof": .bool(true)]))
        }
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: wanted) ?? Data()
            let eof = offset + data.count >= size
            return .response(id: request.id, body: .object([
                "data": .string(data.base64EncodedString()),
                "size": .int(size),
                "eof": .bool(eof)
            ]))
        } catch {
            return RPCOutbound.fail(request.id, .eio,
                                    "cannot read \(rawPath): \(error.localizedDescription)")
        }
    }

    private func fileList(_ request: RPCRequest) -> RPCOutbound {
        guard let rawPath = request.string("path"), !rawPath.isEmpty else {
            return RPCOutbound.fail(request.id, .badParams, "fs.ls needs path")
        }
        let root = Shell.expandPath(rawPath)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir) else {
            return RPCOutbound.fail(request.id, .enoent, "no such folder: \(rawPath)")
        }
        guard isDir.boolValue else {
            return RPCOutbound.fail(request.id, .badParams, "\(rawPath) is a file — use fs.get")
        }

        let depth = max(1, min(request.int("depth") ?? 1, 5))
        var entries: [JSONValue] = []
        var frontier: [(String, String, Int)] = [(root, "", 1)]
        var guardCount = 0

        while !frontier.isEmpty {
            let (directory, prefix, level) = frontier.removeFirst()
            guard let names = try? fm.contentsOfDirectory(atPath: directory) else { continue }
            for name in names.sorted() {
                guardCount += 1
                if guardCount > 5000 { break }
                let full = (directory as NSString).appendingPathComponent(name)
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                var childIsDir: ObjCBool = false
                _ = fm.fileExists(atPath: full, isDirectory: &childIsDir)
                let attributes = try? fm.attributesOfItem(atPath: full)
                let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
                let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let type: String
                if let fileType = attributes?[.type] as? FileAttributeType, fileType == .typeSymbolicLink {
                    type = "link"
                } else {
                    type = childIsDir.boolValue ? "dir" : "file"
                }
                entries.append(.object(["name": .string(relative),
                                        "type": .string(type),
                                        "size": .int(size),
                                        "mtime": .number((modified * 1000).rounded())]))
                if childIsDir.boolValue && level < depth {
                    frontier.append((full, relative, level + 1))
                }
            }
            if guardCount > 5000 { break }
        }
        return .response(id: request.id, body: .object(["entries": .array(entries)]))
    }

    // MARK: - screen.*

    private func requireScreenAccess(_ request: RPCRequest) -> RPCOutbound? {
        if Permissions.screenRecording() { return nil }
        Permissions.requestScreenRecording()
        showScreenGuidanceOnce()
        return RPCOutbound.fail(request.id, .eio, L("perm.screen.rpc"))
    }

    private func screenShot(_ request: RPCRequest, emit: @escaping Emit) -> RPCOutbound {
        if let denied = requireScreenAccess(request) { return denied }
        let format = (request.string("format") ?? "png").lowercased() == "jpg" ? "jpg" : "png"
        let display = max(0, request.int("display") ?? 0)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("machands-\(UUID().uuidString).\(format)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        // `-x` 不发快门声;`-D` 是 1 起数的显示器序号。
        let result = Shell.run("/usr/sbin/screencapture",
                               ["-x", "-t", format, "-D", String(display + 1), temporary.path],
                               timeout: 30)
        return deliverImage(from: temporary, capture: result, request: request, format: format, emit: emit)
    }

    /// SPEC §11 `screen.window`:前台窗口,或按 App 名 / 标题匹配的窗口。
    private func screenWindow(_ request: RPCRequest, emit: @escaping Emit) -> RPCOutbound {
        if let denied = requireScreenAccess(request) { return denied }
        let wantedApp = request.string("app")?.lowercased()
        let wantedTitle = request.string("title")?.lowercased()
        var frontName = ""
        let readFront = { frontName = (NSWorkspace.shared.frontmostApplication?.localizedName ?? "").lowercased() }
        if Thread.isMainThread { readFront() } else { DispatchQueue.main.sync(execute: readFront) }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return RPCOutbound.fail(request.id, .eio, "cannot list windows")
        }
        var chosen: Int? = nil
        for info in windows {
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }
            let owner = (info[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            let title = (info[kCGWindowName as String] as? String ?? "").lowercased()
            if let wanted = wantedApp, !wanted.isEmpty {
                guard owner.contains(wanted) else { continue }
            } else if !frontName.isEmpty {
                guard owner == frontName else { continue }
            }
            if let wanted = wantedTitle, !wanted.isEmpty, !title.contains(wanted) { continue }
            if let number = info[kCGWindowNumber as String] as? Int {
                chosen = number
                break
            }
        }
        guard let windowNumber = chosen else {
            return RPCOutbound.fail(request.id, .enoent, "no matching window" + (wantedApp.map { " for \($0)" } ?? ""))
        }
        let format = (request.string("format") ?? "png").lowercased() == "jpg" ? "jpg" : "png"
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("machands-\(UUID().uuidString).\(format)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let result = Shell.run("/usr/sbin/screencapture",
                               ["-x", "-o", "-t", format, "-l", String(windowNumber), temporary.path],
                               timeout: 30)
        return deliverImage(from: temporary, capture: result, request: request, format: format, emit: emit)
    }

    /// SPEC §11 `screen.record`:`screencapture -v -V <秒>`,录成 .mov 分块流回。
    private func screenRecord(_ request: RPCRequest, emit: @escaping Emit) -> RPCOutbound {
        if let denied = requireScreenAccess(request) { return denied }
        let seconds = min(120, max(1, request.int("seconds") ?? 5))
        let display = max(0, request.int("display") ?? 0)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("machands-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let result = Shell.run("/usr/sbin/screencapture",
                               ["-x", "-v", "-V", String(seconds), "-D", String(display + 1), temporary.path],
                               timeout: TimeInterval(seconds) + 40)
        guard result.launchError == nil else {
            return RPCOutbound.fail(request.id, .eio, result.complaint)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path))?[.size] as? NSNumber
        guard (size?.intValue ?? 0) > 0 else {
            return RPCOutbound.fail(request.id, .eio,
                                    result.status == 0 ? "screencapture produced no video" : result.complaint)
        }
        let bytes = Executor.streamFile(temporary, id: request.id, emit: emit)
        return .response(id: request.id, body: .object(["bytes": .int(bytes),
                                                        "seconds": .int(seconds),
                                                        "format": .string("mov")]))
    }

    private func deliverImage(from temporary: URL, capture result: CommandResult,
                              request: RPCRequest, format: String, emit: @escaping Emit) -> RPCOutbound {
        guard result.launchError == nil else {
            return RPCOutbound.fail(request.id, .eio, result.complaint)
        }
        guard let original = try? Data(contentsOf: temporary), !original.isEmpty else {
            return RPCOutbound.fail(request.id, .eio,
                                    result.status == 0 ? "screencapture produced nothing"
                                                       : result.complaint)
        }
        guard let rep = NSBitmapImageRep(data: original) else {
            return RPCOutbound.fail(request.id, .eio, "the screenshot is not readable as an image")
        }
        let scale = min(1.0, max(0.05, request.double("scale") ?? 1.0))
        let quality = min(1.0, max(0.1, Double(request.int("quality") ?? 80) / 100.0))

        var payload = original
        var width = rep.pixelsWide
        var height = rep.pixelsHigh
        if scale < 0.999 {
            if let resized = Executor.resize(rep, scale: scale, format: format, quality: quality) {
                payload = resized.0
                width = resized.1
                height = resized.2
            }
        } else if format == "jpg" {
            if let data = rep.representation(using: .jpeg,
                                             properties: [.compressionFactor: quality]) {
                payload = data
            }
        }

        let bytes = [UInt8](payload)
        var index = 0
        while index < bytes.count {
            let end = min(index + Executor.chunkBytes, bytes.count)
            let chunk = Data(bytes[index..<end])
            emit(.stream(id: request.id,
                         body: .object(["data": .string(chunk.base64EncodedString())])))
            index = end
        }
        return .response(id: request.id, body: .object(["width": .int(width),
                                                        "height": .int(height),
                                                        "bytes": .int(payload.count)]))
    }

    private static func resize(_ rep: NSBitmapImageRep,
                               scale: Double,
                               format: String,
                               quality: Double) -> (Data, Int, Int)? {
        let width = max(1, Int(Double(rep.pixelsWide) * scale))
        let height = max(1, Int(Double(rep.pixelsHigh) * scale))
        guard let target = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: width,
                                            pixelsHigh: height,
                                            bitsPerSample: 8,
                                            samplesPerPixel: 4,
                                            hasAlpha: true,
                                            isPlanar: false,
                                            colorSpaceName: NSColorSpaceName.deviceRGB,
                                            bytesPerRow: 0,
                                            bitsPerPixel: 0) else { return nil }
        target.size = NSSize(width: width, height: height)
        guard let context = NSGraphicsContext(bitmapImageRep: target) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        _ = rep.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                     from: .zero,
                     operation: .copy,
                     fraction: 1.0,
                     respectFlipped: false,
                     hints: nil)
        NSGraphicsContext.restoreGraphicsState()

        let data: Data?
        if format == "jpg" {
            data = target.representation(using: .jpeg, properties: [.compressionFactor: quality])
        } else {
            data = target.representation(using: .png, properties: [:])
        }
        guard let out = data else { return nil }
        return (out, width, height)
    }

    private func displaysJSON() -> JSONValue {
        var count: UInt32 = 0
        _ = CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return .array([]) }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        _ = CGGetActiveDisplayList(count, &ids, &count)
        var displays: [JSONValue] = []
        for (index, identifier) in ids.prefix(Int(count)).enumerated() {
            displays.append(.object([
                "id": .int(index),
                "cgId": .number(Double(identifier)),
                "w": .int(CGDisplayPixelsWide(identifier)),
                "h": .int(CGDisplayPixelsHigh(identifier)),
                "main": .bool(CGDisplayIsMain(identifier) != 0)
            ]))
        }
        return .array(displays)
    }

    private func showScreenGuidanceOnce() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.screenGuidanceShown else { return }
            self.screenGuidanceShown = true
            let alert = NSAlert()
            alert.messageText = L("perm.screen.title")
            alert.informativeText = L("perm.screen.body")
            alert.addButton(withTitle: L("perm.screen.open"))
            alert.addButton(withTitle: L("perm.later"))
            if alert.runModal() == .alertFirstButtonReturn {
                Permissions.open(.screen)
            }
        }
    }

    // MARK: - input.*

    private func inputMethod(_ request: RPCRequest) -> RPCOutbound {
        func point(_ xKey: String, _ yKey: String) -> CGPoint? {
            guard let x = request.double(xKey), let y = request.double(yKey) else { return nil }
            return CGPoint(x: x, y: y)
        }
        do {
            switch request.method {
            case "input.where":
                let here = InputController.currentLocation()
                return .response(id: request.id, body: .object(["x": .number(here.x.rounded()),
                                                                "y": .number(here.y.rounded())]))
            case "input.move":
                guard let target = point("x", "y") else { return RPCOutbound.fail(request.id, .badParams, "input.move needs x,y") }
                try InputController.move(to: target)
            case "input.click":
                guard let target = point("x", "y") else { return RPCOutbound.fail(request.id, .badParams, "input.click needs x,y") }
                try InputController.click(at: target, button: request.string("button") ?? "left",
                                          count: request.int("count") ?? 1)
            case "input.drag":
                guard let start = point("x1", "y1"), let end = point("x2", "y2") else {
                    return RPCOutbound.fail(request.id, .badParams, "input.drag needs x1,y1,x2,y2")
                }
                try InputController.drag(from: start, to: end, milliseconds: request.int("ms") ?? 300)
            case "input.scroll":
                guard let target = point("x", "y") else { return RPCOutbound.fail(request.id, .badParams, "input.scroll needs x,y") }
                try InputController.scroll(at: target, dx: request.int("dx") ?? 0, dy: request.int("dy") ?? 0)
            case "input.key":
                guard let key = request.string("key"), !key.isEmpty else {
                    return RPCOutbound.fail(request.id, .badParams, "input.key needs key")
                }
                let mods = request.param("mods")?.arrayValue?.compactMap { $0.stringValue } ?? []
                try InputController.key(key, modifiers: mods)
            case "input.type":
                guard let text = request.string("text") else {
                    return RPCOutbound.fail(request.id, .badParams, "input.type needs text")
                }
                try InputController.type(text)
            default:
                return RPCOutbound.fail(request.id, .badParams, "unknown method \(request.method)")
            }
            return .ok(id: request.id)
        } catch {
            return fail(request, error)
        }
    }

    // MARK: - job.*

    private func jobMethod(_ request: RPCRequest) -> RPCOutbound {
        let jobs = JobManager.shared
        switch request.method {
        case "job.submit":
            guard let cmd = request.string("cmd"), !cmd.isEmpty else {
                return RPCOutbound.fail(request.id, .badParams, "job.submit needs cmd")
            }
            let timeout = min(86_400.0, max(1.0, request.double("timeout") ?? 3600))
            do {
                let job = try jobs.submit(cmd: cmd, cwd: request.string("cwd"), env: envDictionary(request), timeout: timeout)
                return .response(id: request.id, body: .object(["jobId": .string(job.id)]))
            } catch {
                return fail(request, error)
            }
        case "job.status", "job.result":
            guard let id = request.string("jobId"), !id.isEmpty else {
                return RPCOutbound.fail(request.id, .badParams, "\(request.method) needs jobId")
            }
            let wait = request.method == "job.result" ? min(600.0, max(0.0, request.double("wait") ?? 0)) : 0
            guard let status = jobs.result(id: id, wait: wait) else {
                return RPCOutbound.fail(request.id, .enoent, "no such job: \(id)")
            }
            return .response(id: request.id, body: status)
        case "job.tail":
            guard let id = request.string("jobId"), !id.isEmpty else {
                return RPCOutbound.fail(request.id, .badParams, "job.tail needs jobId")
            }
            let stream = request.string("stream") ?? "out"
            let offset = max(0, request.int("offset") ?? 0)
            guard let (data, next, eof) = jobs.tail(id: id, stream: stream, offset: offset, limit: Executor.maxRead) else {
                return RPCOutbound.fail(request.id, .enoent, "no such job: \(id)")
            }
            return .response(id: request.id, body: .object(["data": .string(data.base64EncodedString()),
                                                            "offset": .int(next),
                                                            "eof": .bool(eof)]))
        case "job.kill":
            guard let id = request.string("jobId"), !id.isEmpty else {
                return RPCOutbound.fail(request.id, .badParams, "job.kill needs jobId")
            }
            guard jobs.kill(id: id) else {
                return RPCOutbound.fail(request.id, .enoent, "no running job: \(id)")
            }
            return .ok(id: request.id)
        default:
            return .response(id: request.id, body: .object(["jobs": .array(jobs.list())]))
        }
    }

    // MARK: - session.*

    private func sessionMethod(_ request: RPCRequest) -> RPCOutbound {
        let sessions = SessionManager.shared
        do {
            switch request.method {
            case "session.open":
                let session = try sessions.open(cmd: request.string("cmd"), cwd: request.string("cwd"),
                                                env: envDictionary(request))
                return .response(id: request.id, body: .object(["sessionId": .string(session.id)]))
            case "session.write":
                guard let id = request.string("sessionId"), let text = request.string("data") else {
                    return RPCOutbound.fail(request.id, .badParams, "session.write needs sessionId, data")
                }
                try sessions.write(id: id, text: text)
                return .ok(id: request.id)
            case "session.read":
                guard let id = request.string("sessionId") else {
                    return RPCOutbound.fail(request.id, .badParams, "session.read needs sessionId")
                }
                let (data, next, eof, alive) = try sessions.read(id: id, offset: max(0, request.int("offset") ?? 0),
                                                                limit: Executor.maxRead)
                return .response(id: request.id, body: .object(["data": .string(String(decoding: data, as: UTF8.self)),
                                                                "offset": .int(next),
                                                                "eof": .bool(eof),
                                                                "alive": .bool(alive)]))
            default:
                guard let id = request.string("sessionId") else {
                    return RPCOutbound.fail(request.id, .badParams, "session.close needs sessionId")
                }
                guard sessions.close(id: id) else {
                    return RPCOutbound.fail(request.id, .enoent, "no such session: \(id)")
                }
                return .ok(id: request.id)
            }
        } catch {
            return fail(request, error)
        }
    }

    // MARK: - mcp.*

    private func mcpMethod(_ request: RPCRequest) -> RPCOutbound {
        let bridge = McpBridge.shared
        do {
            switch request.method {
            case "mcp.servers":
                return .response(id: request.id, body: .object(["servers": .array(bridge.servers())]))
            case "mcp.open":
                let args = request.param("args")?.arrayValue?.compactMap { $0.stringValue } ?? []
                let session = try bridge.open(name: request.string("name"), command: request.string("command"),
                                              args: args, env: envDictionary(request), cwd: request.string("cwd"))
                session.lock.lock(); let tools = session.tools; session.lock.unlock()
                return .response(id: request.id, body: .object(["sessionId": .string(session.id),
                                                                "name": .string(session.name),
                                                                "tools": .array(tools)]))
            case "mcp.list":
                guard let id = request.string("sessionId"), let session = bridge.session(id) else {
                    return RPCOutbound.fail(request.id, .enoent, "no such MCP session")
                }
                session.lock.lock(); let tools = session.tools; session.lock.unlock()
                return .response(id: request.id, body: .object(["tools": .array(tools)]))
            case "mcp.call":
                guard let id = request.string("sessionId"), let tool = request.string("tool") else {
                    return RPCOutbound.fail(request.id, .badParams, "mcp.call needs sessionId, tool")
                }
                let timeout = min(600.0, max(5.0, request.double("timeout") ?? 120))
                let result = try bridge.call(sessionId: id, tool: tool,
                                             args: request.param("args") ?? .object([:]), timeout: timeout)
                return .response(id: request.id, body: result)
            default:
                guard let id = request.string("sessionId"), bridge.close(sessionId: id) else {
                    return RPCOutbound.fail(request.id, .enoent, "no such MCP session")
                }
                return .ok(id: request.id)
            }
        } catch {
            return fail(request, error)
        }
    }

    // MARK: - power.* / app.relaunch

    private func powerMethod(_ request: RPCRequest) -> RPCOutbound {
        Executor.caffeinateLock.lock()
        defer { Executor.caffeinateLock.unlock() }
        if let running = Executor.caffeinate, running.isRunning { running.terminate() }
        Executor.caffeinate = nil
        guard request.method == "power.assert" else { return .ok(id: request.id) }
        let seconds = min(14_400, max(1, request.int("seconds") ?? 3600))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-dims", "-t", String(seconds)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return RPCOutbound.fail(request.id, .eio, "cannot start caffeinate: \(error.localizedDescription)")
        }
        Executor.caffeinate = process
        let until = Date().addingTimeInterval(TimeInterval(seconds)).timeIntervalSince1970 * 1000
        return .response(id: request.id, body: .object(["until": .number(until.rounded()), "seconds": .int(seconds)]))
    }

    /// DELIVERY v1.1 项:App 自己用 `open -n` 拉起新实例后退出。中继会把老连接顶下线。
    private func relaunch(_ request: RPCRequest) -> RPCOutbound {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else {
            return RPCOutbound.fail(request.id, .eio, "not running from an .app bundle")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let opener = Process()
            opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            opener.arguments = ["-n", bundlePath]
            try? opener.run()
            Log.shared.write("relaunch: new instance requested, quitting")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { NSApp.terminate(nil) }
        }
        return .ok(id: request.id)
    }

    // MARK: - open / clip / notify

    private func openTarget(_ request: RPCRequest) -> RPCOutbound {
        guard let target = request.string("target"), !target.isEmpty else {
            return RPCOutbound.fail(request.id, .badParams, "open needs target")
        }
        let expanded = target.hasPrefix("~") ? Shell.expandPath(target) : target
        let result = Shell.run("/usr/bin/open", [expanded], timeout: 15)
        guard result.ok else {
            return RPCOutbound.fail(request.id, .eio, result.complaint)
        }
        return .ok(id: request.id)
    }

    private func clipboardGet(_ request: RPCRequest) -> RPCOutbound {
        var text = ""
        if Thread.isMainThread {
            text = NSPasteboard.general.string(forType: .string) ?? ""
        } else {
            DispatchQueue.main.sync {
                text = NSPasteboard.general.string(forType: .string) ?? ""
            }
        }
        return .response(id: request.id, body: .object(["text": .string(text)]))
    }

    private func clipboardSet(_ request: RPCRequest) -> RPCOutbound {
        guard let text = request.string("text") else {
            return RPCOutbound.fail(request.id, .badParams, "clip.set needs text")
        }
        let write = {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            _ = pasteboard.setString(text, forType: .string)
        }
        if Thread.isMainThread { write() } else { DispatchQueue.main.sync(execute: write) }
        return .ok(id: request.id)
    }

    private func notifyUser(_ request: RPCRequest) -> RPCOutbound {
        let title = request.string("title") ?? L("app.name")
        let body = request.string("body") ?? ""
        Notifier.post(title: title, body: body)
        return .ok(id: request.id)
    }
}
