import AppKit
import MacHandsCore

/// Store-edition settings: language and open-at-login only.
/// No relay, license, agent list, or command policy.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    var onSave: ((Settings) -> Void)?

    private static let width: CGFloat = 440
    private static let bodyWidth: CGFloat = 392
    private static let languageCodes = ["en", "zh", "auto"]

    private let root = NSStackView()
    private let about = NSTextField(wrappingLabelWithString: "")
    private let languageTitle = NSTextField(labelWithString: "")
    private let languagePopup = NSPopUpButton()
    private let languageHint = NSTextField(wrappingLabelWithString: "")
    private let launchButton = NSButton()
    private let saveButton = NSButton()
    private let savedLabel = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                                  width: SettingsWindowController.width,
                                                  height: 280),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = L("settings.title")
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is code-only")
    }

    private func build() {
        guard let window = self.window else { return }
        let width = SettingsWindowController.bodyWidth

        about.stringValue = L("store.settings.about")
        about.font = NSFont.systemFont(ofSize: 12)
        about.textColor = NSColor.secondaryLabelColor
        about.maximumNumberOfLines = 0
        about.preferredMaxLayoutWidth = width

        languageTitle.stringValue = L("main.language")
        languageTitle.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        languagePopup.removeAllItems()
        for code in SettingsWindowController.languageCodes {
            languagePopup.addItem(withTitle: L("lang.\(code)"))
        }
        languageHint.stringValue = L("settings.languageHint")
        languageHint.font = NSFont.systemFont(ofSize: 11)
        languageHint.textColor = NSColor.tertiaryLabelColor
        languageHint.maximumNumberOfLines = 2

        launchButton.setButtonType(.switch)
        launchButton.title = L("main.launchAtLogin")
        launchButton.font = NSFont.systemFont(ofSize: 12)

        saveButton.title = L("settings.save")
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save)
        savedLabel.font = NSFont.systemFont(ofSize: 11)
        savedLabel.textColor = NSColor.secondaryLabelColor

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.addView(savedLabel, in: .leading)
        footer.addView(saveButton, in: .trailing)

        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        for view in [about, languageTitle, languagePopup, languageHint, launchButton, footer] {
            root.addArrangedSubview(view)
        }

        let content = NSView()
        content.addSubview(root)
        window.contentView = content
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: SettingsWindowController.width),
            about.widthAnchor.constraint(equalToConstant: width),
            languageHint.widthAnchor.constraint(equalToConstant: width),
            footer.widthAnchor.constraint(equalToConstant: width)
        ])
    }

    func present(settings: Settings) {
        load(settings)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func load(_ settings: Settings) {
        let index = SettingsWindowController.languageCodes.firstIndex(of: settings.language) ?? 0
        languagePopup.selectItem(at: index)
        launchButton.state = settings.launchAtLogin ? .on : .off
        savedLabel.stringValue = ""
        fitWindow()
    }

    private func fitWindow() {
        guard let window = window else { return }
        root.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: SettingsWindowController.width,
                                     height: root.fittingSize.height))
    }

    @objc private func save() {
        var next = SettingsStore.shared.current
        let index = languagePopup.indexOfSelectedItem
        if index >= 0 && index < SettingsWindowController.languageCodes.count {
            next.language = SettingsWindowController.languageCodes[index]
        }
        next.launchAtLogin = (launchButton.state == .on)
        if let problem = LoginItem.set(next.launchAtLogin) {
            savedLabel.stringValue = problem
        } else {
            savedLabel.stringValue = L("settings.saved")
        }
        onSave?(next)
    }
}
