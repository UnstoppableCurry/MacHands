import AppKit
import MacHandsCore

/// 菜单栏那只手(SPEC §7.1)。
///
/// 一眼能看出四件事:有没有 agent、连上没有、是不是暂停了、审批模式是什么。
/// 菜单栏是单色的,所以状态靠**形状**区分,不靠颜色。
final class StatusItemController: NSObject, NSMenuDelegate {

    enum Appearance {
        case unpaired      // 还没有 agent:半透明的空心手
        case waiting       // 配过对但没人在线:空心手
        case connected     // 有 agent 在线:实心手
        case paused        // 暂停:手上打叉
        case problem       // 连不上中继
    }

    struct Model {
        var relayState: RelayClient.State = .idle
        var agents: [AuthorizedAgent] = []
        var online: Set<String> = []
        var mode: ApprovalMode = .ask
        var paused: Bool = false
        /// 试用/许可证那一行;没有话说时是 nil。
        var licenseLine: String?
        /// SPEC §10.2:做过一次授权的时刻(毫秒);nil = 还没做过。
        var authorizedAt: Double?
    }

    var model = Model()

    var onCopyForAgent: (() -> Void)?
    var onSetMode: ((ApprovalMode) -> Void)?
    var onTogglePause: (() -> Void)?
    var onOpenAudit: (() -> Void)?
    var onOpenWindow: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onAuthorize: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onQuit: (() -> Void)?

    private let statusItem: NSStatusItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        render()
    }

    // MARK: - 图标

    func render() {
        guard let button = statusItem.button else { return }
        let look = appearance()
        let symbol: String
        switch look {
        case .unpaired, .waiting: symbol = "hand.raised"
        case .connected:          symbol = "hand.raised.fill"
        case .paused:             symbol = "hand.raised.slash.fill"
        case .problem:            symbol = "exclamationmark.triangle"
        }
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: statusLine()) {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "MH"
        }
        // 还没配对时整只手淡下去 —— 一眼就知道"它还没开始工作"。
        button.alphaValue = (look == .unpaired) ? 0.45 : 1.0
        button.toolTip = statusLine()
    }

    private func appearance() -> Appearance {
        if model.paused { return .paused }
        switch model.relayState {
        case .failed:
            return .problem
        case .idle, .connecting, .retrying:
            return model.agents.isEmpty ? .unpaired : .waiting
        case .online:
            if model.agents.isEmpty { return .unpaired }
            return model.online.isEmpty ? .waiting : .connected
        }
    }

    func statusLine() -> String {
        if model.paused { return L("menu.state.paused") }
        switch model.relayState {
        case .failed(let reason):
            return Lf("menu.state.offline", reason)
        case .connecting:
            return L("menu.state.connecting")
        case .retrying(_, let seconds):
            return Lf("menu.state.offline", Lf("fail.retry", Lf("time.seconds", seconds)))
        case .idle:
            return model.agents.isEmpty ? L("menu.state.unpaired") : L("menu.state.waiting")
        case .online:
            if model.agents.isEmpty { return L("menu.state.unpaired") }
            let live = model.agents.filter { model.online.contains($0.id) }
            guard let first = live.first else { return L("menu.state.waiting") }
            let name = live.count > 1 ? "\(first.displayName) +\(live.count - 1)" : first.displayName
            return Lf("menu.state.connected", name)
        }
    }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = disabledItem(statusLine())
        menu.addItem(status)
        if model.authorizedAt != nil {
            menu.addItem(disabledItem(Lf("menu.authorized", StatusItemController.modeName(model.mode))))
        }
        // 有新版本时明说。装不装由「检查更新…」那一项决定,这里只是告诉他有。
        if let newer = Updater.shared.newerVersionAvailable {
            menu.addItem(disabledItem(Lf("menu.updateAvailable", newer)))
        }

        if model.agents.isEmpty {
            let copy = NSMenuItem(title: L("menu.copyForAgent"),
                                  action: #selector(copyForAgent), keyEquivalent: "c")
            copy.target = self
            menu.addItem(copy)
        } else {
            for agent in model.agents {
                menu.addItem(disabledItem("   " + agentLine(agent)))
            }
            let copy = NSMenuItem(title: L("menu.copyForAgent"),
                                  action: #selector(copyForAgent), keyEquivalent: "c")
            copy.target = self
            menu.addItem(copy)
        }

        if let line = model.licenseLine {
            menu.addItem(disabledItem(line))
        }

        menu.addItem(NSMenuItem.separator())

        let modeItem = NSMenuItem(title: L("menu.mode"), action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for mode in [ApprovalMode.auto, ApprovalMode.readonly, ApprovalMode.ask] {
            let title = StatusItemController.modeName(mode)
            let item = NSMenuItem(title: title, action: #selector(pickMode(_:)), keyEquivalent: "")
            item.target = self
            item.state = (model.mode == mode) ? .on : .off
            item.representedObject = mode.rawValue
            modeMenu.addItem(item)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        let pause = NSMenuItem(title: model.paused ? L("menu.resume") : L("menu.pause"),
                               action: #selector(togglePause), keyEquivalent: "p")
        pause.target = self
        menu.addItem(pause)

        // SPEC §10.2:一次授权的入口。配对后主窗口会自动弹;这里是之后再找它的地方。
        let authorize = NSMenuItem(title: L("menu.authorize"), action: #selector(authorizePressed), keyEquivalent: "a")
        authorize.target = self
        menu.addItem(authorize)

        menu.addItem(NSMenuItem.separator())

        let window = NSMenuItem(title: L("menu.window"), action: #selector(openWindow), keyEquivalent: "o")
        window.target = self
        menu.addItem(window)

        let audit = NSMenuItem(title: L("menu.openAudit"), action: #selector(openAudit), keyEquivalent: "l")
        audit.target = self
        menu.addItem(audit)

        let settings = NSMenuItem(title: L("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let update = NSMenuItem(title: L("menu.checkUpdates"),
                                action: #selector(checkUpdatesPressed), keyEquivalent: "u")
        update.target = self
        menu.addItem(update)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: L("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// 审批模式的短名字。菜单与主窗口的「已授权 · %@」都用它,两处永远是同一个词。
    static func modeName(_ mode: ApprovalMode) -> String {
        switch mode {
        case .ask: return L("menu.mode.ask")
        case .auto: return L("menu.mode.auto")
        case .readonly: return L("menu.mode.readonly")
        case .deny: return L("menu.state.paused")
        }
    }

    private func agentLine(_ agent: AuthorizedAgent) -> String {
        guard let command = agent.lastCommand, let when = agent.lastCommandAt else {
            return Lf("menu.agentIdle", agent.displayName)
        }
        let since = Date().timeIntervalSince1970 - when
        return Lf("menu.agentLine",
                  agent.displayName,
                  StatusItemController.shorten(command, to: 28),
                  StatusItemController.relative(seconds: since))
    }

    static func shorten(_ text: String, to limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        if flat.count <= limit { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }

    static func relative(seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        if total < 5 { return L("time.now") }
        if total < 60 { return Lf("time.seconds", total) }
        if total < 3600 { return Lf("time.minutes", total / 60) }
        if total < 86400 { return Lf("time.hours", total / 3600) }
        return Lf("time.days", total / 86400)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - 动作

    @objc private func copyForAgent() { onCopyForAgent?() }
    @objc private func togglePause() { onTogglePause?() }
    @objc private func openAudit() { onOpenAudit?() }
    @objc private func openWindow() { onOpenWindow?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func authorizePressed() { onAuthorize?() }
    @objc private func checkUpdatesPressed() { onCheckForUpdates?() }
    @objc private func quit() { onQuit?() }

    @objc private func pickMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ApprovalMode(rawValue: raw) else { return }
        onSetMode?(mode)
    }
}
