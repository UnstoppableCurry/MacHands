import AppKit
import CoreGraphics
import MacHandsCore

/// SPEC §10.3 的自检表。App 的授权页与 RPC `verify.run` 用的是同一份实现,
/// 所以两端看到的结果永远一致。阻塞调用,在后台队列跑。
enum Verifier {

    struct Row {
        let key: String          // 文案 key 后缀,也是 JSON 里的 name
        let ok: Bool
        let detail: String
        let fix: String?

        var json: JSONValue {
            var body: [String: JSONValue] = [
                "name": .string(key), "ok": .bool(ok), "detail": .string(detail)
            ]
            if let fix = fix { body["fix"] = .string(fix) }
            return .object(body)
        }
    }

    static func run() -> [Row] {
        var rows: [Row] = []
        let perms = Permissions.snapshot()

        // 1. 执行命令
        let echo = Shell.run("/bin/zsh", ["-lc", "printf machands-ok"], timeout: 20)
        rows.append(Row(key: "run", ok: echo.trimmedOut == "machands-ok",
                        detail: echo.ok ? "printf → machands-ok" : echo.complaint, fix: nil))

        // 2. 读写文件
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("machands-verify-\(UUID().uuidString).txt")
        let payload = "机器之手 " + UUID().uuidString
        var fsOK = false
        var fsDetail = ""
        do {
            try payload.write(to: temp, atomically: true, encoding: .utf8)
            let back = try String(contentsOf: temp, encoding: .utf8)
            fsOK = (back == payload)
            fsDetail = fsOK ? "\(payload.utf8.count) bytes round-trip" : "content mismatch"
            try? FileManager.default.removeItem(at: temp)
        } catch {
            fsDetail = error.localizedDescription
        }
        rows.append(Row(key: "fs", ok: fsOK, detail: fsDetail, fix: nil))

        // 3. 截屏
        if perms.screen {
            let shot = FileManager.default.temporaryDirectory.appendingPathComponent("machands-verify-\(UUID().uuidString).png")
            let result = Shell.run("/usr/sbin/screencapture", ["-x", "-t", "png", "-R", "0,0,24,24", shot.path], timeout: 20)
            let size = (try? FileManager.default.attributesOfItem(atPath: shot.path))?[.size] as? NSNumber
            let ok = result.launchError == nil && (size?.intValue ?? 0) > 0
            try? FileManager.default.removeItem(at: shot)
            rows.append(Row(key: "screen", ok: ok,
                            detail: ok ? "24×24 png, \(size?.intValue ?? 0) bytes" : result.complaint,
                            fix: ok ? nil : L("perm.screen.rpc")))
        } else {
            rows.append(Row(key: "screen", ok: false, detail: L("perm.state.no"), fix: L("perm.screen.rpc")))
        }

        // 4. 键鼠:把光标移到它现在的位置 —— 走一遍真实的 CGEvent 路径,肉眼看不出变化。
        if perms.accessibility {
            let here = InputController.currentLocation()
            do {
                try InputController.move(to: here)
                rows.append(Row(key: "input", ok: true, detail: "move → (\(Int(here.x)),\(Int(here.y)))", fix: nil))
            } catch let failure as InputController.Failure {
                rows.append(Row(key: "input", ok: false, detail: failure.message, fix: L("perm.ax.rpc")))
            } catch {
                rows.append(Row(key: "input", ok: false, detail: error.localizedDescription, fix: L("perm.ax.rpc")))
            }
        } else {
            rows.append(Row(key: "input", ok: false, detail: L("perm.state.no"), fix: L("perm.ax.rpc")))
        }

        // 5. 通知
        let notifyOK = perms.notifications == "authorized"
        if notifyOK { Notifier.post(title: L("app.name"), body: L("verify.notify.body")) }
        rows.append(Row(key: "notify", ok: notifyOK, detail: perms.notifications,
                        fix: notifyOK ? nil : L("perm.notify.rpc")))

        // 6. 作业
        do {
            let job = try JobManager.shared.submit(cmd: "sleep 0.3; printf job-ok", cwd: nil, env: [:], timeout: 30)
            let result = JobManager.shared.result(id: job.id, wait: 10)
            let code = result?["code"]?.intValue
            let tail = JobManager.shared.tail(id: job.id, stream: "out", offset: 0, limit: 64)
            let text = tail.map { String(decoding: $0.0, as: UTF8.self) } ?? ""
            let ok = code == 0 && text == "job-ok"
            let codeText = code.map { String($0) } ?? "?"
            rows.append(Row(key: "job", ok: ok, detail: "code=\(codeText) out=\(text)", fix: nil))
        } catch {
            rows.append(Row(key: "job", ok: false, detail: error.localizedDescription, fix: nil))
        }

        // 7. MCP 桥:能读出配置就算通(0 个也算)
        let servers = McpBridge.shared.servers()
        let names = servers.compactMap { $0["name"]?.stringValue }
        rows.append(Row(key: "mcp", ok: true,
                        detail: names.isEmpty ? "0 servers configured" : names.prefix(6).joined(separator: ", "),
                        fix: nil))
        return rows
    }
}
