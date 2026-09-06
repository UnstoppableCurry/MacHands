#if DEBUG
import AppKit
import MacHandsCore

/// 只在 DEBUG 构建里存在的预览入口(`scripts/build-app.sh --debug`)。Release 里
/// 这个文件整个不编译,下面的参数会被当作没看见。
///
/// 为什么需要它:审批卡只在 agent 真的发来一条要审批的命令时才弹,改界面时每看
/// 一眼都要拉一个真 agent 来触发,太慢。所以让副本一启动就弹几张假卡:
///
///   open -n MacHands.app --args --no-relay --preview-approval          一张 run(会写盘那档)
///   open -n MacHands.app --args --no-relay --preview-approval=read     只读那档(fs.get)
///   open -n MacHands.app --args --no-relay --preview-approval=delete   删除那档(rm -rf …)
///   open -n MacHands.app --args --no-relay --preview-approval=long     十几行的命令,看"展开全部"
///   open -n MacHands.app --args --no-relay --preview-approval=queue    三张排队,看"还有 N 条"
///
/// `--no-relay` 是必须的:副本和正式版共用一份身份,中继对同一身份只留一条连接,
/// 副本一连上就把正式版顶下线。带了 --preview-approval 时 AppDelegate 也会强制不连中继,
/// 双保险。卡上的按钮照常能点,结果只进 app.log,不执行任何东西、不改白名单、不记 1 小时授权。
enum DebugPreview {

    enum Approval: String {
        case write
        case read
        case delete
        case long
        case queue
    }

    struct Options {
        var approval: Approval?
        var isActive: Bool { return approval != nil }
    }

    static let options: Options = parse(ProcessInfo.processInfo.arguments)

    static func parse(_ arguments: [String]) -> Options {
        var out = Options()
        for argument in arguments {
            if argument == "--preview-approval" {
                out.approval = .write
            } else if argument.hasPrefix("--preview-approval=") {
                let raw = String(argument.dropFirst("--preview-approval=".count))
                out.approval = Approval(rawValue: raw) ?? .write
            }
        }
        return out
    }

    // MARK: - 假数据

    static let fakeAgentId = "2vyy5n6gpreviewagent0000"
    static let fakeAgentName = "Claude Code"
    static let fakeIP = "134.199.230.126"

    static func requests(_ kind: Approval) -> [ApprovalRequest] {
        func make(_ id: String, _ method: String, _ subject: String, cwd: String?) -> ApprovalRequest {
            return ApprovalRequest(requestId: id, agentId: fakeAgentId, agentName: fakeAgentName,
                                   method: method, subject: subject, cwd: cwd, fromIP: fakeIP)
        }
        let write = make("preview-write", "run",
                         "cd ~/Projects/site && npm run build && cp -R dist/ ~/Sites/live/",
                         cwd: "~/Projects/site")
        let read = make("preview-read", "fs.get", "~/Documents/notes/2026-09-plan.md", cwd: nil)
        let delete = make("preview-delete", "run",
                          "rm -rf ~/Projects/site/node_modules && rm -f ~/Downloads/*.dmg",
                          cwd: "~/Projects/site")
        let longLines = (1...14).map { "echo \"step \($0): checking ~/Projects/site/src/module-\($0).ts\"" }
        let long = make("preview-long", "run", longLines.joined(separator: "\n"), cwd: "~/Projects/site")
        switch kind {
        case .write:  return [write]
        case .read:   return [read]
        case .delete: return [delete]
        case .long:   return [long]
        case .queue:  return [write, read, delete]
        }
    }

    // MARK: - 启动

    /// 在 applicationDidFinishLaunching 的末尾调一次;没带参数就什么都不做。
    static func launch() {
        guard let kind = options.approval else { return }
        Log.shared.write("preview: --preview-approval=\(kind.rawValue) — fake cards only, nothing will be executed")
        for request in requests(kind) {
            ApprovalPanelController.shared.ask(request) { outcome in
                Log.shared.write("preview: \(request.requestId) → \(outcome) (not executed)")
            }
        }
    }
}
#endif
