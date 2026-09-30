import AppKit
import MacHandsCore

/// 次要窗口(SPEC §7.2 末):中继地址、已授权 agent 与撤销、黑/白名单、
/// "读取也要问"、许可证。
///
/// 全部字段只在按"保存"时落盘 —— 边打字边保存会把一半的中继地址存进去。
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    var onSave: ((Settings) -> Void)?
    var onRevoke: ((String) -> Void)?

    private static let width: CGFloat = 520
    private static let bodyWidth: CGFloat = 472

    private let root = NSStackView()
    private let relayField = NSTextField()
    private let relayHint = NSTextField(wrappingLabelWithString: "")
    private let agentsTitle = NSTextField(labelWithString: "")
    private let agentsBox = NSStackView()
    private let allowTitle = NSTextField(labelWithString: "")
    private let allowScroll: NSScrollView
    private let allowText: NSTextView
    private let denyTitle = NSTextField(labelWithString: "")
    private let denyScroll: NSScrollView
    private let denyText: NSTextView
    private let denyBuiltin = NSTextField(wrappingLabelWithString: "")
    private let askForReads = NSButton()
    private let licenseTitle = NSTextField(labelWithString: "")
    private let licenseField = NSTextField()
    private let licenseStatus = NSTextField(wrappingLabelWithString: "")
    private let languageTitle = NSTextField(labelWithString: "")
    private let languagePopup = NSPopUpButton()
    private let languageHint = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton()
    private let savedLabel = NSTextField(labelWithString: "")

    /// popup 的行序;`load`/`save` 都按这个表来回,别让下拉框的顺序和存盘的
    /// 语言代码悄悄错位。
    private static let languageCodes = ["auto", "zh", "en", "ja", "ko"]

    private var licenseLine: String = ""

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                                  width: SettingsWindowController.width,
                                                  height: 560),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = L("settings.title")
        window.isReleasedWhenClosed = false
        window.center()

        // 本地变量先建好再赋给存储属性:super.init 之前读不回存储属性。
        let allow = NSTextView.scrollableTextView()
        allowScroll = allow
        allowText = allow.documentView as! NSTextView
        let deny = NSTextView.scrollableTextView()
        denyScroll = deny
        denyText = deny.documentView as! NSTextView

        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is code-only")
    }

    // MARK: - 布局

    private func build() {
        guard let window = self.window else { return }
        let width = SettingsWindowController.bodyWidth

        relayField.placeholderString = "ws://1.2.3.4:8443"
        relayField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        relayHint.stringValue = L("settings.relayHint")
        relayHint.font = NSFont.systemFont(ofSize: 11)
        relayHint.textColor = NSColor.tertiaryLabelColor
        relayHint.maximumNumberOfLines = 2

        agentsTitle.stringValue = L("settings.agents")
        agentsTitle.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        agentsBox.orientation = .vertical
        agentsBox.alignment = .leading
        agentsBox.spacing = 4

        allowTitle.stringValue = L("settings.allow")
        allowTitle.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        denyTitle.stringValue = L("settings.deny")
        denyTitle.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        for view in [allowText, denyText] {
            view.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            view.isRichText = false
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            view.isAutomaticTextReplacementEnabled = false
            view.isAutomaticSpellingCorrectionEnabled = false
            view.textContainerInset = NSSize(width: 6, height: 6)
            view.isVerticallyResizable = true
            view.isHorizontallyResizable = false
            view.textContainer?.widthTracksTextView = true
        }
        for scroll in [allowScroll, denyScroll] {
            scroll.hasVerticalScroller = true
            scroll.borderType = .noBorder
            scroll.wantsLayer = true
            scroll.layer?.cornerRadius = 6
            scroll.layer?.masksToBounds = true
            scroll.layer?.borderWidth = 1
            scroll.layer?.borderColor = NSColor.separatorColor.cgColor
            scroll.translatesAutoresizingMaskIntoConstraints = false
        }

        denyBuiltin.stringValue = Lf("settings.denyBuiltin",
                                     PolicyEngine.defaultDeny.joined(separator: " · "))
        denyBuiltin.font = NSFont.systemFont(ofSize: 11)
        denyBuiltin.textColor = NSColor.tertiaryLabelColor
        denyBuiltin.maximumNumberOfLines = 3

        askForReads.setButtonType(.switch)
        askForReads.title = L("settings.askForReads")
        askForReads.font = NSFont.systemFont(ofSize: 12)

        licenseTitle.stringValue = L("settings.license")
        licenseTitle.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        licenseField.placeholderString = L("settings.licensePlaceholder")
        licenseField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        licenseStatus.font = NSFont.systemFont(ofSize: 11)
        licenseStatus.textColor = NSColor.secondaryLabelColor
        licenseStatus.maximumNumberOfLines = 2

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
        let views: [NSView] = [sectionLabel(L("settings.relay")), relayField, relayHint,
                               agentsTitle, agentsBox,
                               allowTitle, allowScroll,
                               denyTitle, denyScroll, denyBuiltin,
                               askForReads,
                               licenseTitle, licenseField, licenseStatus,
                               languageTitle, languagePopup, languageHint,
                               footer]
        for view in views { root.addArrangedSubview(view) }

        let content = NSView()
        content.addSubview(root)
        window.contentView = content

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: SettingsWindowController.width),
            relayField.widthAnchor.constraint(equalToConstant: width),
            relayHint.widthAnchor.constraint(equalToConstant: width),
            allowScroll.widthAnchor.constraint(equalToConstant: width),
            allowScroll.heightAnchor.constraint(equalToConstant: 64),
            denyScroll.widthAnchor.constraint(equalToConstant: width),
            denyScroll.heightAnchor.constraint(equalToConstant: 64),
            denyBuiltin.widthAnchor.constraint(equalToConstant: width),
            licenseField.widthAnchor.constraint(equalToConstant: width),
            licenseStatus.widthAnchor.constraint(equalToConstant: width),
            languageHint.widthAnchor.constraint(equalToConstant: width),
            footer.widthAnchor.constraint(equalToConstant: width)
        ])
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        return label
    }

    // MARK: - 显示

    func present(settings: Settings, licenseLine: String) {
        self.licenseLine = licenseLine
        load(settings)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func load(_ settings: Settings) {
        relayField.stringValue = settings.relayURL
        allowText.string = settings.policy.allow.joined(separator: "\n")
        denyText.string = settings.policy.deny.joined(separator: "\n")
        askForReads.state = settings.policy.askForReads ? .on : .off
        licenseField.stringValue = settings.license
        licenseStatus.stringValue = licenseLine
        let index = SettingsWindowController.languageCodes.firstIndex(of: settings.language) ?? 0
        languagePopup.selectItem(at: index)
        savedLabel.stringValue = ""
        renderAgents(settings.agents)
        fitWindow()
    }

    private func renderAgents(_ agents: [AuthorizedAgent]) {
        for view in agentsBox.arrangedSubviews {
            agentsBox.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !agents.isEmpty else {
            let empty = NSTextField(labelWithString: L("settings.noAgents"))
            empty.font = NSFont.systemFont(ofSize: 12)
            empty.textColor = NSColor.secondaryLabelColor
            agentsBox.addArrangedSubview(empty)
            return
        }
        for agent in agents {
            let label = NSTextField(labelWithString: "\(agent.displayName)  ·  \(agent.id)")
            label.font = NSFont.systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
            let button = NSButton()
            button.title = L("settings.revoke")
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = #selector(revokePressed(_:))
            button.identifier = NSUserInterfaceItemIdentifier(agent.id)
            let row = NSStackView(views: [label, button])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            agentsBox.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                label.widthAnchor.constraint(equalToConstant: 350)
            ])
        }
    }

    private func fitWindow() {
        guard let window = window else { return }
        root.layoutSubtreeIfNeeded()
        let height = root.fittingSize.height
        window.setContentSize(NSSize(width: SettingsWindowController.width, height: height))
    }

    // MARK: - 动作

    @objc private func save() {
        var relay = relayField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if relay.isEmpty { relay = Settings.defaultRelayURL }
        guard relay.hasPrefix("ws://") || relay.hasPrefix("wss://") else {
            savedLabel.stringValue = L("settings.badRelay")
            return
        }
        let current = SettingsStore.shared.current
        var next = current
        next.relayURL = relay
        next.policy.allow = SettingsWindowController.lines(allowText.string)
        next.policy.deny = SettingsWindowController.lines(denyText.string)
        next.policy.askForReads = (askForReads.state == .on)
        next.license = licenseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = languagePopup.indexOfSelectedItem
        if index >= 0 && index < SettingsWindowController.languageCodes.count {
            next.language = SettingsWindowController.languageCodes[index]
        }
        savedLabel.stringValue = L("settings.saved")
        onSave?(next)
    }

    @objc private func revokePressed(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue else { return }
        onRevoke?(identifier)
    }

    static func lines(_ text: String) -> [String] {
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
