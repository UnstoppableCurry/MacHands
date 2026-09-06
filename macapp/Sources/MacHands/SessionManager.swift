import Foundation
import MacHandsCore

/// SPEC §11 `session.*`:有 stdin 的长命进程,输出合并落文件,agent 轮询读。
final class SessionManager {

    static let shared = SessionManager()

    final class Session {
        let id: String
        let process: Process
        let stdin: FileHandle
        let outURL: URL
        var alive: Bool = true
        init(id: String, process: Process, stdin: FileHandle, outURL: URL) {
            self.id = id; self.process = process; self.stdin = stdin; self.outURL = outURL
        }
    }

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]

    static var root: URL {
        return Paths.supportDir.appendingPathComponent("sessions", isDirectory: true)
    }

    func open(cmd: String?, cwd: String?, env: [String: String]) throws -> Session {
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
        Paths.ensureDirectory(SessionManager.root, permissions: 0o700)
        let outURL = SessionManager.root.appendingPathComponent("\(id).log")
        _ = FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        guard let out = try? FileHandle(forWritingTo: outURL) else {
            throw InputController.Failure(code: .eio, message: "cannot open session log")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        if let cmd = cmd, !cmd.isEmpty {
            process.arguments = ["-lc", cmd]
        } else {
            process.arguments = ["-l", "-i"]
        }
        process.environment = Shell.environment(extra: env)
        var directory = FileManager.default.homeDirectoryForCurrentUser.path
        if let requested = cwd, !requested.isEmpty { directory = Shell.expandPath(requested) }
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = out
        process.standardError = out
        let session = Session(id: id, process: process, stdin: input.fileHandleForWriting, outURL: outURL)
        process.terminationHandler = { [weak self] _ in
            self?.lock.lock()
            session.alive = false
            self?.lock.unlock()
            try? out.close()
        }
        try process.run()
        lock.lock(); sessions[id] = session; lock.unlock()
        return session
    }

    func write(id: String, text: String) throws {
        lock.lock(); let session = sessions[id]; lock.unlock()
        guard let live = session, live.alive else {
            throw InputController.Failure(code: .enoent, message: "no such session: \(id)")
        }
        guard let data = text.data(using: .utf8) else { return }
        try live.stdin.write(contentsOf: data)
    }

    func read(id: String, offset: Int, limit: Int) throws -> (Data, Int, Bool, Bool) {
        lock.lock(); let session = sessions[id]; lock.unlock()
        guard let live = session else {
            throw InputController.Failure(code: .enoent, message: "no such session: \(id)")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: live.outURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let start = max(0, min(offset, size))
        guard let handle = try? FileHandle(forReadingFrom: live.outURL) else {
            return (Data(), start, !live.alive, live.alive)
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(start))
        let data = (try? handle.read(upToCount: limit)) ?? Data()
        let next = start + data.count
        return (data, next, !live.alive && next >= size, live.alive)
    }

    func close(id: String) -> Bool {
        lock.lock(); let session = sessions.removeValue(forKey: id); lock.unlock()
        guard let live = session else { return false }
        try? live.stdin.close()
        if live.alive { ProcessTree.terminate(tree: live.process.processIdentifier, grace: 1.0) }
        return true
    }
}

/// SPEC §11 `mcp.*`:把 Mac 上任一 stdio MCP 服务透传给云端 agent。
/// 一条会话 = 一个子进程 + 一条 JSON-RPC(按行)通道。协议 2025-06-18。
final class McpBridge {

    static let shared = McpBridge()
    static let protocolVersion = "2025-06-18"

    final class Session {
        let id: String
        let name: String
        let process: Process
        let stdin: FileHandle
        var buffer = Data()
        var nextId = 1
        var pending: [Int: (JSONValue?, String?) -> Void] = [:]
        var tools: [JSONValue] = []
        var alive = true
        let lock = NSLock()
        init(id: String, name: String, process: Process, stdin: FileHandle) {
            self.id = id; self.name = name; self.process = process; self.stdin = stdin
        }
    }

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]

    // MARK: - 发现

    /// 读各家 agent 的 MCP 配置,只返回名字/命令/参数/url,**不返回 env 的值**(可能含密钥)。
    func servers() -> [JSONValue] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var found: [String: JSONValue] = [:]
        var order: [String] = []

        func add(name: String, source: String, command: String?, args: [String], url: String?) {
            guard !name.isEmpty, found[name] == nil else { return }
            var body: [String: JSONValue] = ["name": .string(name), "source": .string(source)]
            if let command = command, !command.isEmpty { body["command"] = .string(command) }
            if !args.isEmpty { body["args"] = .strings(args) }
            if let url = url, !url.isEmpty { body["url"] = .string(url) }
            found[name] = .object(body)
            order.append(name)
        }

        func addJSONServers(_ object: [String: JSONValue]?, source: String) {
            guard let servers = object else { return }
            for (name, value) in servers.sorted(by: { $0.key < $1.key }) {
                let entry = value.objectValue ?? [:]
                let args = entry["args"]?.arrayValue?.compactMap { $0.stringValue } ?? []
                add(name: name, source: source,
                    command: entry["command"]?.stringValue, args: args,
                    url: entry["url"]?.stringValue)
            }
        }

        // Claude Code:顶层 + 每个项目
        if let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
           let root = JSONValue.parse(data)?.objectValue {
            addJSONServers(root["mcpServers"]?.objectValue, source: "claude-code")
            if let projects = root["projects"]?.objectValue {
                for (_, project) in projects.sorted(by: { $0.key < $1.key }) {
                    addJSONServers(project["mcpServers"]?.objectValue, source: "claude-code")
                }
            }
        }
        // Codex(TOML,只认 [mcp_servers.X] 下的 command / args / url)
        if let text = try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8) {
            var current: String? = nil
            var command: String? = nil
            var args: [String] = []
            var url: String? = nil
            func flush() {
                if let name = current { add(name: name, source: "codex", command: command, args: args, url: url) }
                current = nil; command = nil; args = []; url = nil
            }
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") {
                    flush()
                    if line.hasPrefix("[mcp_servers."), line.hasSuffix("]") {
                        let inner = line.dropFirst("[mcp_servers.".count).dropLast()
                        current = String(inner).replacingOccurrences(of: "\"", with: "")
                    }
                    continue
                }
                guard current != nil else { continue }
                if line.hasPrefix("command"), let value = McpBridge.tomlString(line) { command = value }
                else if line.hasPrefix("url"), let value = McpBridge.tomlString(line) { url = value }
                else if line.hasPrefix("args") { args = McpBridge.tomlArray(line) }
            }
            flush()
        }
        // Cursor / Claude Desktop
        if let data = try? Data(contentsOf: home.appendingPathComponent(".cursor/mcp.json")),
           let root = JSONValue.parse(data)?.objectValue {
            addJSONServers(root["mcpServers"]?.objectValue, source: "cursor")
        }
        if let data = try? Data(contentsOf: home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")),
           let root = JSONValue.parse(data)?.objectValue {
            addJSONServers(root["mcpServers"]?.objectValue, source: "claude-desktop")
        }
        return order.compactMap { found[$0] }
    }

    private static func tomlString(_ line: String) -> String? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
        return String(value.dropFirst().dropLast())
    }

    private static func tomlArray(_ line: String) -> [String] {
        guard let open = line.firstIndex(of: "["), let close = line.lastIndex(of: "]"), open < close else { return [] }
        let inner = line[line.index(after: open)..<close]
        return inner.split(separator: ",").compactMap { piece in
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return nil }
            return String(trimmed.dropFirst().dropLast())
        }
    }

    // MARK: - 会话

    func open(name: String?, command: String?, args: [String], env: [String: String], cwd: String?) throws -> Session {
        var resolvedName = name ?? command ?? "mcp"
        var resolvedCommand = command
        var resolvedArgs = args
        if let wanted = name, !wanted.isEmpty, resolvedCommand == nil {
            guard let entry = servers().first(where: { $0["name"]?.stringValue == wanted })?.objectValue else {
                throw InputController.Failure(code: .enoent, message: "no MCP server named \(wanted)")
            }
            guard let cmd = entry["command"]?.stringValue else {
                throw InputController.Failure(code: .badParams, message: "\(wanted) is an http MCP server — not bridged yet")
            }
            resolvedCommand = cmd
            resolvedArgs = entry["args"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            resolvedName = wanted
        }
        guard let executable = resolvedCommand, !executable.isEmpty else {
            throw InputController.Failure(code: .badParams, message: "mcp.open needs name or command")
        }

        let process = Process()
        // 走 /usr/bin/env 让 PATH 前置生效(npx / node / 自编译二进制都能找到)。
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [Shell.expandPath(executable)] + resolvedArgs
        process.environment = Shell.environment(extra: env)
        if let requested = cwd, !requested.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: Shell.expandPath(requested))
        }
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
        let session = Session(id: id, name: resolvedName, process: process, stdin: input.fileHandleForWriting)
        output.fileHandleForReading.readabilityHandler = { [weak session] handle in
            guard let session = session else { return }
            let data = handle.availableData
            if data.isEmpty { return }
            McpBridge.consume(session, data: data)
        }
        process.terminationHandler = { [weak session] _ in
            guard let session = session else { return }
            session.lock.lock()
            session.alive = false
            let waiting = session.pending
            session.pending.removeAll()
            session.lock.unlock()
            for (_, callback) in waiting { callback(nil, "MCP server exited") }
        }
        try process.run()
        lock.lock(); sessions[id] = session; lock.unlock()

        // 握手
        let initResult = try request(session, method: "initialize", params: .object([
            "protocolVersion": .string(McpBridge.protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("machands"), "version": .string("0.2.0")])
        ]), timeout: 60)
        _ = initResult
        try notify(session, method: "notifications/initialized")
        let listed = try request(session, method: "tools/list", params: .object([:]), timeout: 60)
        session.lock.lock()
        session.tools = listed["tools"]?.arrayValue ?? []
        session.lock.unlock()
        return session
    }

    func session(_ id: String) -> Session? {
        lock.lock(); defer { lock.unlock() }
        return sessions[id]
    }

    func call(sessionId: String, tool: String, args: JSONValue, timeout: TimeInterval) throws -> JSONValue {
        guard let live = session(sessionId), live.alive else {
            throw InputController.Failure(code: .enoent, message: "no such MCP session: \(sessionId)")
        }
        return try request(live, method: "tools/call",
                           params: .object(["name": .string(tool), "arguments": args]),
                           timeout: timeout)
    }

    func close(sessionId: String) -> Bool {
        lock.lock(); let live = sessions.removeValue(forKey: sessionId); lock.unlock()
        guard let session = live else { return false }
        try? session.stdin.close()
        if session.alive { ProcessTree.terminate(tree: session.process.processIdentifier, grace: 1.0) }
        return true
    }

    // MARK: - JSON-RPC

    private static func consume(_ session: Session, data: Data) {
        session.lock.lock()
        session.buffer.append(data)
        var lines: [Data] = []
        while let newline = session.buffer.firstIndex(of: 0x0A) {
            lines.append(session.buffer.subdata(in: 0..<newline))
            session.buffer.removeSubrange(0...newline)
        }
        session.lock.unlock()
        for line in lines {
            guard !line.isEmpty, let message = JSONValue.parse(line)?.objectValue else { continue }
            guard let idValue = message["id"], let id = idValue.intValue else { continue }   // 通知/服务端请求:忽略
            session.lock.lock()
            let callback = session.pending.removeValue(forKey: id)
            session.lock.unlock()
            if let error = message["error"]?.objectValue {
                callback?(nil, error["message"]?.stringValue ?? "MCP error")
            } else {
                callback?(message["result"] ?? .object([:]), nil)
            }
        }
    }

    private func request(_ session: Session, method: String, params: JSONValue, timeout: TimeInterval) throws -> JSONValue {
        session.lock.lock()
        let id = session.nextId
        session.nextId += 1
        let box = LockedBox<(JSONValue?, String?)?>(nil)
        let done = DispatchSemaphore(value: 0)
        session.pending[id] = { result, error in
            box.value = (result, error)
            done.signal()
        }
        session.lock.unlock()
        let frame = CanonicalJSON.string(.object([
            "jsonrpc": .string("2.0"), "id": .int(id), "method": .string(method), "params": params
        ])) + "\n"
        try session.stdin.write(contentsOf: Data(frame.utf8))
        if done.wait(timeout: .now() + timeout) == .timedOut {
            session.lock.lock(); session.pending.removeValue(forKey: id); session.lock.unlock()
            throw InputController.Failure(code: .timeout, message: "MCP \(method) timed out")
        }
        guard let outcome = box.value else { throw InputController.Failure(code: .eio, message: "MCP empty reply") }
        if let error = outcome.1 { throw InputController.Failure(code: .eio, message: error) }
        return outcome.0 ?? .object([:])
    }

    private func notify(_ session: Session, method: String) throws {
        let frame = CanonicalJSON.string(.object(["jsonrpc": .string("2.0"), "method": .string(method)])) + "\n"
        try session.stdin.write(contentsOf: Data(frame.utf8))
    }
}
