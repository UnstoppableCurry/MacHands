import Foundation
import Darwin

/// SPEC §11.1:超时和 kill 对整棵进程树生效。
/// 只杀掉 zsh 而留下 Godot / Blender 继续吃 GPU,是 0.1 版实测过的坑。
enum ProcessTree {

    /// 所有后代 pid(不含自己),用 `ps` 一次读全表再在内存里遍历。
    static func descendants(of root: pid_t) -> [pid_t] {
        let result = Shell.run("/bin/ps", ["-axo", "pid=,ppid="], timeout: 5)
        var children: [pid_t: [pid_t]] = [:]
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).filter { !$0.isEmpty }
            guard parts.count >= 2, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            children[ppid, default: []].append(pid)
        }
        var out: [pid_t] = []
        var stack: [pid_t] = [root]
        var seen: Set<pid_t> = [root]
        while let current = stack.popLast() {
            for child in children[current] ?? [] where !seen.contains(child) {
                seen.insert(child)
                out.append(child)
                stack.append(child)
            }
        }
        return out
    }

    /// 先 SIGTERM 整棵树(叶子先),等一会儿,还活着的 SIGKILL。阻塞调用,别放主线程。
    static func terminate(tree root: pid_t, grace: TimeInterval = 2.0) {
        guard root > 0 else { return }
        let everyone = descendants(of: root).reversed() + [root]
        for pid in everyone { _ = Darwin.kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if everyone.allSatisfy({ Darwin.kill($0, 0) != 0 }) { return }
            usleep(100_000)
        }
        for pid in everyone where Darwin.kill(pid, 0) == 0 {
            _ = Darwin.kill(pid, SIGKILL)
        }
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        return pid > 0 && Darwin.kill(pid, 0) == 0
    }
}
