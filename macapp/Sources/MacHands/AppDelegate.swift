import AppKit
import MacHandsCore

/// Free App Store edition. Menu-bar companion + about window.
/// Does not start a relay, an executor, a license check, or the OSS updater.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Always true on this branch. Left so unused executor/sys.info code still compiles.
    static var relayDisabled: Bool { true }

    private var statusItem: StatusItemController?
    private var mainWindow: MainWindowController?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.shared.write("MacHands store edition starting (bundle=\(Bundle.main.bundleIdentifier ?? "none"), v\(StoreEdition.marketingVersion) build \(StoreEdition.buildNumber))")

        let statusItem = StatusItemController()
        statusItem.onOpenWindow = { [weak self] in self?.showMainWindow(activating: true) }
        statusItem.onOpenGitHub = { AppDelegate.openGitHub() }
        statusItem.onCopyGitHub = { AppDelegate.copyGitHubURL() }
        statusItem.onOpenSettings = { [weak self] in self?.showSettingsWindow() }
        statusItem.onQuit = { NSApp.terminate(nil) }
        self.statusItem = statusItem
        statusItem.render()

        SettingsStore.shared.onChange = { [weak self] _ in
            DispatchQueue.main.async { self?.statusItem?.render() }
        }

        let settings = SettingsStore.shared.current
        if settings.launchAtLogin, case .disabled = LoginItem.status() {
            if let problem = LoginItem.set(true) {
                Log.shared.write("launch at login: \(problem)")
            }
        }

        InstallGuard.checkAtLaunch()

        if !settings.seenWelcome {
            SettingsStore.shared.update { $0.seenWelcome = true }
        }
        showMainWindow(activating: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.shared.write("MacHands store edition stopped")
        Log.shared.close()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(activating: true)
        return true
    }

    func showMainWindow(activating: Bool) {
        if mainWindow == nil {
            let window = MainWindowController()
            window.onOpenGitHub = { AppDelegate.openGitHub() }
            window.onCopyGitHub = { AppDelegate.copyGitHubURL() }
            window.onCopyClone = { AppDelegate.copyCloneCommand() }
            window.onSetLaunchAtLogin = { [weak self] on in self?.setLaunchAtLogin(on) }
            window.onOpenSettings = { [weak self] in self?.showSettingsWindow() }
            mainWindow = window
        }
        mainWindow?.render()
        mainWindow?.present(activating: activating)
    }

    private func showSettingsWindow() {
        if settingsWindow == nil {
            let window = SettingsWindowController()
            window.onSave = { [weak self] next in self?.saveSettings(next) }
            settingsWindow = window
        }
        settingsWindow?.present(settings: SettingsStore.shared.current)
    }

    private func saveSettings(_ next: Settings) {
        SettingsStore.shared.update { current in
            current.language = next.language
            current.launchAtLogin = next.launchAtLogin
        }
        settingsWindow?.load(SettingsStore.shared.current)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if let problem = LoginItem.set(enabled) {
            Log.shared.write("launch at login change failed: \(problem)")
            let alert = NSAlert()
            alert.messageText = L("app.name")
            alert.informativeText = problem
            _ = alert.runModal()
        }
        SettingsStore.shared.update { $0.launchAtLogin = enabled }
        mainWindow?.render()
    }

    static func openGitHub() {
        NSWorkspace.shared.open(StoreEdition.githubURLValue)
    }

    @discardableResult
    static func copyGitHubURL() -> Bool {
        return copyText(StoreEdition.githubURL)
    }

    @discardableResult
    static func copyCloneCommand() -> Bool {
        return copyText(StoreEdition.cloneCommand)
    }

    private static func copyText(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
