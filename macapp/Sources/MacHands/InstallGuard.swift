import AppKit
import MacHandsCore

/// 同一个 bundle id 在磁盘上有几份?
///
/// 真事:mini 上同时存在 `/Applications/MacHands.app`(0.2.0)、
/// `~/Applications/MacHands.app`(0.1.0)和一份开发副本,三份共用一个 bundle id
/// 与一份身份文件。用户从 Spotlight 随手拉起了旧的那份,它抢走了中继身份,
/// 于是所有 agent 看到的是 0.1.0 的行为 —— "unknown method"、反复要权限,
/// 而 /Applications 里那份新的根本没在跑。查了很久才查到。
///
/// 一份 TCC 授权也是按 bundle id + 签名要求记的,多份拷贝会互相顶掉对方的授权状态。
///
/// 所以:启动时数一数,发现多份就明说,**但绝不自动删任何东西** —— 删 App 是用户的事,
/// 我们只负责让他看见。
enum InstallGuard {

    /// 除自己以外的同 id 拷贝路径。按路径排序,输出稳定。
    static func duplicates() -> [String] {
        let myPath = Bundle.main.bundlePath
        let myID = Bundle.main.bundleIdentifier ?? "app.machands.MacHands"

        let result = Shell.run("/usr/bin/mdfind",
                               ["kMDItemCFBundleIdentifier == '\(myID)'"],
                               timeout: 20)
        guard result.launchError == nil else { return [] }

        var found: Set<String> = []
        for line in result.stdout.split(separator: "\n") {
            let path = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, path.hasSuffix(".app") else { continue }
            guard standardized(path) != standardized(myPath) else { continue }
            found.insert(path)
        }
        return found.sorted()
    }

    /// `app.doctor` 用:自己 + 其它拷贝,自己排第一。
    static func snapshot() -> [String] {
        return [Bundle.main.bundlePath] + duplicates()
    }

    /// 启动时检查。发现多份就写日志 + 弹一次对话框(每次启动最多一次)。
    /// 只在 .app 里跑时才有意义 —— 裸二进制没有 bundle,mdfind 什么也找不到。
    static func checkAtLaunch() {
        guard LoginItem.isBundled else { return }
        DispatchQueue.global(qos: .utility).async {
            let others = duplicates()
            guard !others.isEmpty else { return }
            Log.shared.write("duplicate installs found: " + others.joined(separator: ", "))
            DispatchQueue.main.async { presentAlert(others) }
        }
    }

    private static func presentAlert(_ others: [String]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("install.dup.title")
        alert.informativeText = Lf("install.dup.body", Bundle.main.bundlePath)
            + "\n\n" + others.joined(separator: "\n")
        alert.addButton(withTitle: L("install.dup.reveal"))
        alert.addButton(withTitle: L("perm.later"))
        if alert.runModal() == .alertFirstButtonReturn {
            let urls = others.map { URL(fileURLWithPath: $0) }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    private static func standardized(_ path: String) -> String {
        var text = URL(fileURLWithPath: path).standardizedFileURL.path
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
