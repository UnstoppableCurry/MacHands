import AppKit

/// Start-up, shutdown, and the wiring between the three long-lived objects:
/// the status item (what the user sees), the supervisor (what actually runs),
/// and the setup window (used once, then forgotten).
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: StatusItemController?
    private var setupWindow: SetupWindowController?
    private var tickTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // R4: the log is ~/Library/Logs/using-mac-tunnel-<name>.log, so the
        // logger has to be told the name before anything is written.
        Log.shared.use(name: ConfigStore.shared.current.macName)
        Log.shared.write("UsingMac starting (bundle=\(LoginItem.isBundled ? "yes" : "no"))")

        let statusItem = StatusItemController()
        statusItem.onOpenSettings = { [weak self] in self?.showSetupWindow() }
        statusItem.onQuit = { NSApp.terminate(nil) }
        self.statusItem = statusItem

        TunnelSupervisor.shared.onStateChange = { [weak self] state in
            self?.statusItem?.render(state: state)
            self?.setupWindow?.render(state: state)
        }
        TunnelSupervisor.shared.beginWatchingNetwork()

        installSignalHandlers()

        // The menu shows a live "connected for 3m" / "retrying in 12s", so the
        // icon's tooltip and the menu title need a slow heartbeat.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let state = TunnelSupervisor.shared.currentState
            self.statusItem?.render(state: state)
            self.setupWindow?.render(state: state)
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer

        // Reading the older install's config and booting out its LaunchAgent
        // both touch the disk and launchctl, so they happen off the main
        // thread — the menu bar item must appear instantly either way.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var config = ConfigStore.shared.current
            var adopted = false
            if !config.enrolled {
                adopted = Enroller.adoptExistingShellInstall()
                config = ConfigStore.shared.current
            }
            // Two ssh clients asking for the same remote port cancel each other
            // out forever, so the shell installer's agent has to stand down
            // whenever this app is the one in charge.
            if config.enrolled {
                Enroller.standDownLegacyAgent(macName: config.macName)
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                if config.enrolled {
                    if adopted {
                        Log.shared.write("taking over from the shell install; no setup needed")
                    }
                    if config.paused {
                        Log.shared.write("starting paused (the user's choice, remembered)")
                        self.statusItem?.render(state: .paused)
                    } else {
                        TunnelSupervisor.shared.start()
                    }
                } else {
                    self.showSetupWindow()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tickTimer?.invalidate()
        tickTimer = nil
        // Blocking on purpose: the ssh child must be gone before we are.
        TunnelSupervisor.shared.shutdown()
        Log.shared.write("UsingMac stopped")
        Log.shared.close()
    }

    /// A status-bar app has no windows to reopen, but launching it a second
    /// time (Finder, Spotlight, Dock) should still surface the one window it
    /// has — a launch that visibly does nothing reads as "it did not start".
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        showSetupWindow()
        return true
    }

    private func showSetupWindow() {
        if setupWindow == nil {
            setupWindow = SetupWindowController()
        }
        setupWindow?.present()
    }

    /// `kill` and `launchctl bootout` send SIGTERM; without this the app dies
    /// without running `applicationWillTerminate`, leaving ssh behind.
    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT] {
            _ = signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
