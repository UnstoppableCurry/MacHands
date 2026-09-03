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

/// SPEC §5.1 的全部方法。
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
    /// SPEC §5.1:fs.get ≤ 768 KiB/次。
    static let maxRead = 768 * 1024
    static let defaultTimeout: TimeInterval = 600

    private let policy: PolicyEngine
    private let audit: AuditLog
    private let work = DispatchQueue(label: "app.machands.exec",
                                     qos: .userInitiated,
                                     attributes: .concurrent)

    /// 每执行一条就报一次,菜单栏用它显示"最近一次命令 · 几秒前"。
    var onActivity: ((String, String) -> Void)?
    /// 屏幕录制没授权时弹一次引导(SPEC §7.4)。
    private var screenGuidanceShown = false

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
        case "sys.info":    return systemInfo(request)
        case "run":         return runCommand(request, emit: emit)
        case "fs.put":      return filePut(request)
        case "fs.get":      return fileGet(request)
        case "fs.ls":       return fileList(request)
        case "screen.shot": return screenShot(request, emit: emit)
        case "screen.list": return screenList(request)
        case "open":        return openTarget(request)
        case "clip.get":    return clipboardGet(request)
        case "clip.set":    return clipboardSet(request)
        case "notify":      return notifyUser(request)
        case "policy.get":  return .response(id: request.id, body: policy.publicSnapshot())
        default:
            return RPCOutbound.fail(request.id, .badParams, "unknown method \(request.method)")
        }
    }

    // MARK: - sys.info

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
        // "…	100%; charged; 0:00 remaining present: true"
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

        var extra: [String: String] = [:]
        if let environment = request.param("env")?.objectValue {
            for (key, value) in environment {
                if let text = value.stringValue { extra[key] = text }
            }
        }

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

        var timedOut = false
        let killLock = NSLock()
        let killer = DispatchWorkItem {
            killLock.lock(); timedOut = true; killLock.unlock()
            if process.isRunning { process.terminate() }
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

        killLock.lock()
        let wasKilled = timedOut
        killLock.unlock()
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

    // MARK: - fs.*

    /// `data` 字段:发出去用标准 base64(SPEC §5.1 写的就是 base64);
    /// 收进来两种都认,免得对面按 §2 的通则用了 base64url。
    private static func decodeBinary(_ text: String) -> Data? {
        // 顺序有讲究:`.ignoreUnknownCharacters` 会把 base64url 的 `-` 和 `_`
        // 当成噪声**丢掉**,于是安静地解出一段错的字节。所以先看有没有这两个字符。
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

    private func fileGet(_ request: RPCRequest) -> RPCOutbound {
        guard let rawPath = request.string("path"), !rawPath.isEmpty else {
            return RPCOutbound.fail(request.id, .badParams, "fs.get needs path")
        }
        let path = Shell.expandPath(rawPath)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            return RPCOutbound.fail(request.id, .enoent, "no such file: \(rawPath)")
        }
        guard !isDir.boolValue else {
            return RPCOutbound.fail(request.id, .badParams, "\(rawPath) is a folder — use fs.ls")
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
        var frontier: [(String, String, Int)] = [(root, "", 1)]   // 绝对路径、相对名、层
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
                // mtime 是**毫秒**:agent/test/fake-mac.mjs 用的是 `st.mtimeMs`,
                // 真假两个 Mac 实现必须给出同一个量纲。
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

    private func screenShot(_ request: RPCRequest, emit: @escaping Emit) -> RPCOutbound {
        // SPEC §7.4:TCC 没授权就明确说出来,并弹一次引导。
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            showScreenGuidanceOnce()
            return RPCOutbound.fail(request.id, .eio, L("perm.screen.rpc"))
        }

        let format = (request.string("format") ?? "png").lowercased() == "jpg" ? "jpg" : "png"
        let display = max(0, request.int("display") ?? 0)
        let scale = min(1.0, max(0.05, request.double("scale") ?? 1.0))
        let quality = min(1.0, max(0.1, Double(request.int("quality") ?? 80) / 100.0))

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("machands-\(UUID().uuidString).\(format)")
        defer { try? FileManager.default.removeItem(at: temporary) }

        // `-x` 不发快门声;`-D` 是 1 起数的显示器序号。
        let result = Shell.run("/usr/sbin/screencapture",
                               ["-x", "-t", format, "-D", String(display + 1), temporary.path],
                               timeout: 30)
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
            // JPEG 的压缩率由我们说了算,不然 screencapture 给的默认值大得离谱。
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
                     from: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh),
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

    private func screenList(_ request: RPCRequest) -> RPCOutbound {
        var count: UInt32 = 0
        _ = CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else {
            return .response(id: request.id, body: .object(["displays": .array([])]))
        }
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
        return .response(id: request.id, body: .object(["displays": .array(displays)]))
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
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                if let url = url { _ = NSWorkspace.shared.open(url) }
            }
        }
    }

    // MARK: - open / clip / notify

    private func openTarget(_ request: RPCRequest) -> RPCOutbound {
        guard let target = request.string("target"), !target.isEmpty else {
            return RPCOutbound.fail(request.id, .badParams, "open needs target")
        }
        // `/usr/bin/open` 对 URL 与路径都行,而且行为与用户自己在终端里敲的一样。
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
