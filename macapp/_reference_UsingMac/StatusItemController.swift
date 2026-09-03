import AppKit

/// The menu-bar item: one glanceable icon, and a menu that answers "is it
/// working, and if not, what do I do about it" without any further clicks.
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private var state: TunnelSupervisor.State = .idle

    /// Set by the AppDelegate.
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        render(state: .idle)
    }

    // MARK: - the icon

    func render(state: TunnelSupervisor.State) {
        self.state = state
        guard let button = statusItem.button else { return }

        let symbol = symbolName(for: state.appearance)
        let description = statusLine()

        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description) {
            image.isTemplate = true          // monochrome, follows the menu bar
            button.image = image
            button.title = ""
        } else {
            // Ancient or stripped systems: never show an empty menu-bar slot.
            button.image = nil
            button.title = "UM"
        }
        button.toolTip = statusLine()
    }

    /// Four shapes, no colour: the menu bar is monochrome by design and a
    /// coloured dot is unreadable for a large minority of people.
    private func symbolName(for appearance: TunnelSupervisor.State.Appearance) -> String {
        switch appearance {
        case .connected: return "link"
        case .working:   return "arrow.triangle.2.circlepath"
        case .stopped:   return "pause.circle"
        case .problem:   return "exclamationmark.triangle"
        }
    }

    // MARK: - the menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let config = ConfigStore.shared.current

        // Line 1: the state, with the same symbol as the icon so the two read
        // as one thing.
        let status = disabledItem(statusLine())
        if let image = NSImage(systemSymbolName: symbolName(for: state.appearance),
                               accessibilityDescription: nil) {
            status.image = image
        }
        menu.addItem(status)

        // Line 2: who this Mac is on the server, in one line.
        if config.enrolled {
            let address = config.serverSSHPort == Config.defaultServerSSHPort
                ? config.serverHost
                : "\(config.serverHost):\(config.serverSSHPort)"
            menu.addItem(disabledItem(Lf("menu.port", config.macName, address, config.tunnelPort)))
            let proxy = config.proxyCommand.trimmingCharacters(in: .whitespaces)
            if !proxy.isEmpty {
                menu.addItem(disabledItem("\(L("setup.proxyCommand"))  \(proxy)"))
            }
        }

        // Then, only when something is wrong: what to do about it.
        if case .failed(let failure) = state {
            menu.addItem(NSMenuItem.separator())
            for line in wrap(failure.nextStep(config: config), width: 44) {
                menu.addItem(disabledItem(line))
            }
            if failure == .remoteLoginOff {
                let open = NSMenuItem(title: L("setup.openSharing"),
                                      action: #selector(openSharing),
                                      keyEquivalent: "")
                open.target = self
                menu.addItem(open)
            }
        }

        menu.addItem(NSMenuItem.separator())

        if config.enrolled {
            let isPaused: Bool
            if case .paused = state { isPaused = true } else { isPaused = config.paused }
            let toggle = NSMenuItem(title: isPaused ? L("menu.resume") : L("menu.pause"),
                                    action: #selector(togglePause),
                                    keyEquivalent: "")
            toggle.target = self
            menu.addItem(toggle)

            let reconnect = NSMenuItem(title: L("menu.reconnectNow"),
                                       action: #selector(reconnectNow),
                                       keyEquivalent: "r")
            reconnect.target = self
            reconnect.isEnabled = !isPaused
            menu.addItem(reconnect)

            menu.addItem(NSMenuItem.separator())
        }

        let settings = NSMenuItem(title: config.enrolled ? L("menu.settings") : L("menu.setUp"),
                                  action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let log = NSMenuItem(title: L("menu.openLog"), action: #selector(openLog), keyEquivalent: "l")
        log.target = self
        menu.addItem(log)

        if config.enrolled {
            let copy = NSMenuItem(title: L("menu.copyServerCommands"),
                                  action: #selector(copyServerCommands),
                                  keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
        }

        let login = NSMenuItem(title: L("menu.launchAtLogin"),
                               action: #selector(toggleLaunchAtLogin),
                               keyEquivalent: "")
        login.target = self
        switch LoginItem.status() {
        case .enabled:
            login.state = .on
        case .requiresApproval:
            login.state = .mixed
        case .disabled:
            login.state = .off
        case .unavailable:
            login.state = .off
            login.isEnabled = false
        }
        menu.addItem(login)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: L("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func statusLine() -> String {
        return StatusItemController.statusLine(for: state)
    }

    /// One sentence for a state; the icon tooltip, the menu's first line and
    /// the window's headline all say exactly the same thing.
    static func statusLine(for state: TunnelSupervisor.State) -> String {
        switch state {
        case .idle:
            return L("menu.status.idle")
        case .paused:
            return L("menu.status.paused")
        case .checking:
            return L("menu.status.checking")
        case .connecting:
            return L("menu.status.connecting")
        case .connected(let since):
            return Lf("menu.status.connected", StatusItemController.duration(since: since))
        case .retrying(let attempt, let resumeAt):
            let seconds = max(0, Int(resumeAt.timeIntervalSinceNow.rounded()))
            return Lf("menu.status.retrying", attempt, Lf("time.seconds", seconds))
        case .failed(let failure):
            return Lf("menu.status.failed", failure.summary)
        }
    }

    static func duration(since: Date) -> String {
        let total = Int(max(0, Date().timeIntervalSince(since)))
        if total < 60 { return Lf("time.seconds", total) }
        if total < 3600 { return Lf("time.minutes", total / 60) }
        if total < 86400 { return Lf("time.hours", total / 3600, (total % 3600) / 60) }
        return Lf("time.days", total / 86400, (total % 86400) / 3600)
    }

    /// Crude word wrap: a menu item does not wrap by itself, and a 200-character
    /// line of advice is advice nobody reads.
    private func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        // Chinese text has no spaces, so fall back to hard chunks.
        if lines.count == 1 && lines[0].count > width {
            let chars = Array(lines[0])
            var chunks: [String] = []
            var index = 0
            while index < chars.count {
                let end = min(index + width, chars.count)
                chunks.append(String(chars[index..<end]))
                index = end
            }
            return chunks
        }
        return lines
    }

    // MARK: - actions

    @objc private func togglePause() {
        if ConfigStore.shared.current.paused {
            TunnelSupervisor.shared.resume()
        } else {
            TunnelSupervisor.shared.pause()
        }
    }

    @objc private func reconnectNow() {
        TunnelSupervisor.shared.reconnectNow()
    }

    @objc private func openLog() {
        let url = Log.shared.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            Log.shared.write("log opened before anything was written")
        }
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.selectFile(url.path,
                                          inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        }
    }

    @objc private func copyServerCommands() {
        let config = ConfigStore.shared.current
        let name = config.macName
        let text = """
        mac check \(name)
        mac run \(name) -- uname -a
        mac shot \(name)
        mac setup \(name)                 # a fresh pairing code, if this Mac has to re-pair
        mac setup \(name) --server-port 443   # when the network blocks the usual port
        mac uninstall \(name)
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc private func toggleLaunchAtLogin() {
        let enabling: Bool
        switch LoginItem.status() {
        case .enabled, .requiresApproval:
            enabling = false
        default:
            enabling = true
        }
        if let problem = LoginItem.set(enabling) {
            Log.shared.write("launch at login change failed: \(problem)")
            let alert = NSAlert()
            alert.messageText = L("app.name")
            alert.informativeText = problem
            alert.runModal()
            return
        }
        ConfigStore.shared.update { $0.launchAtLogin = enabling }
    }

    @objc private func openSharing() {
        RemoteLoginCheck.openSharingSettings()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func quit() {
        onQuit?()
    }
}
