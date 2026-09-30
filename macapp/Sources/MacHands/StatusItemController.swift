import AppKit
import MacHandsCore

/// Menu-bar hand for the free App Store edition.
/// No pairing, approval mode, pause, audit log, or self-update.
final class StatusItemController: NSObject, NSMenuDelegate {

    var onOpenWindow: (() -> Void)?
    var onOpenGitHub: (() -> Void)?
    var onCopyGitHub: (() -> Void)?
    var onOpenSettings: (() -> Void)?
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

    func render() {
        guard let button = statusItem.button else { return }
        if let image = NSImage(systemSymbolName: "hand.raised.fill",
                               accessibilityDescription: L("store.menu.status")) {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "MH"
        }
        button.toolTip = L("store.menu.status")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(disabledItem(L("store.menu.status")))
        menu.addItem(disabledItem(L("store.menu.notAgent")))
        menu.addItem(NSMenuItem.separator())

        let window = NSMenuItem(title: L("menu.window"), action: #selector(openWindow), keyEquivalent: "o")
        window.target = self
        menu.addItem(window)

        let github = NSMenuItem(title: L("store.menu.openGitHub"),
                                action: #selector(openGitHub), keyEquivalent: "g")
        github.target = self
        menu.addItem(github)

        let copy = NSMenuItem(title: L("store.menu.copyGitHub"),
                              action: #selector(copyGitHub), keyEquivalent: "c")
        copy.target = self
        menu.addItem(copy)

        let settings = NSMenuItem(title: L("menu.settings"),
                                  action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

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

    @objc private func openWindow() { onOpenWindow?() }
    @objc private func openGitHub() { onOpenGitHub?() }
    @objc private func copyGitHub() { onCopyGitHub?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func quit() { onQuit?() }
}
