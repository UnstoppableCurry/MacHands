import AppKit
import MacHandsCore

/// About + capability board for the free App Store edition.
/// Agent pairing, relay, shell, and approval UI are not shown — those
/// features are not in this binary.
final class MainWindowController: NSWindowController, NSWindowDelegate {

    var onOpenGitHub: (() -> Void)?
    var onCopyGitHub: (() -> Void)?
    var onCopyClone: (() -> Void)?
    var onSetLaunchAtLogin: ((Bool) -> Void)?
    var onOpenSettings: (() -> Void)?

    private static let contentWidth: CGFloat = 500
    private static let bodyWidth: CGFloat = contentWidth - 48
    private static let innerWidth: CGFloat = bodyWidth - 28

    private let root = NSStackView()
    private let badge = GradientBadge(symbolName: "hand.raised.fill", size: 40)
    private let headline = NSTextField(wrappingLabelWithString: "")
    private let editionPill = PillLabel()
    private let lead = NSTextField(wrappingLabelWithString: "")
    private let aboutCard = CardView()
    private let canCard = CardView()
    private let cannotCard = CardView()
    private let openGitHub = StyledButton(title: "", kind: .filled(Theme.accentA), size: 14)
    private let copyGitHub = StyledButton(title: "", kind: .outline, size: 12, weight: .medium)
    private let copyClone = StyledButton(title: "", kind: .outline, size: 12, weight: .medium)
    private let copyStatus = NSTextField(wrappingLabelWithString: "")
    private let launchRow = NSStackView()
    private let launchLabel = NSTextField(labelWithString: "")
    private let launchSwitch = NSSwitch()
    private let footer = NSTextField(wrappingLabelWithString: "")
    private let settingsButton = StyledButton(title: "", kind: .outline, size: 11.5, weight: .medium)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                                  width: MainWindowController.contentWidth,
                                                  height: 640),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = L("app.name")
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("MainWindowController is code-only")
    }

    private func build() {
        guard let window = self.window else { return }
        let bodyWidth = MainWindowController.bodyWidth
        let inner = MainWindowController.innerWidth

        headline.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        headline.maximumNumberOfLines = 2
        headline.preferredMaxLayoutWidth = bodyWidth - 54
        headline.stringValue = L("app.name")

        editionPill.set(text: L("store.pill"), tint: Theme.accentB)

        let titleCol = NSStackView(views: [headline, editionPill])
        titleCol.orientation = .vertical
        titleCol.alignment = .leading
        titleCol.spacing = 6

        let header = NSStackView(views: [badge, titleCol])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 14

        lead.font = NSFont.systemFont(ofSize: 12.5)
        lead.textColor = NSColor.secondaryLabelColor
        lead.maximumNumberOfLines = 0
        lead.preferredMaxLayoutWidth = bodyWidth
        lead.stringValue = L("store.lead")

        fillCard(aboutCard, title: L("store.about.title"), body: L("store.about.body"), width: inner)
        fillCard(canCard, title: L("store.can.title"), body: L("store.can.body"), width: inner)
        fillCard(cannotCard, title: L("store.cannot.title"), body: L("store.cannot.body"), width: inner)
        cannotCard.setTint(background: Theme.warning.withAlphaComponent(0.10),
                           border: Theme.warning.withAlphaComponent(0.35))

        openGitHub.title = L("store.openGitHub")
        openGitHub.target = self
        openGitHub.action = #selector(openGitHubPressed)
        copyGitHub.title = L("store.copyGitHub")
        copyGitHub.target = self
        copyGitHub.action = #selector(copyGitHubPressed)
        copyClone.title = L("store.copyClone")
        copyClone.target = self
        copyClone.action = #selector(copyClonePressed)

        let actions = NSStackView(views: [copyGitHub, copyClone])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.distribution = .fillEqually

        copyStatus.font = NSFont.systemFont(ofSize: 11.5)
        copyStatus.textColor = NSColor.secondaryLabelColor
        copyStatus.maximumNumberOfLines = 2
        copyStatus.stringValue = ""

        launchLabel.stringValue = L("main.launchAtLogin")
        launchLabel.font = NSFont.systemFont(ofSize: 12)
        launchSwitch.target = self
        launchSwitch.action = #selector(launchChanged)
        launchRow.orientation = .horizontal
        launchRow.alignment = .centerY
        launchRow.spacing = 8
        launchRow.addArrangedSubview(launchLabel)
        launchRow.addArrangedSubview(launchSwitch)

        footer.font = NSFont.systemFont(ofSize: 10.5)
        footer.textColor = NSColor.tertiaryLabelColor
        footer.maximumNumberOfLines = 3
        footer.preferredMaxLayoutWidth = bodyWidth - 110
        footer.stringValue = L("store.footer")

        settingsButton.title = L("main.openSettings")
        settingsButton.target = self
        settingsButton.action = #selector(settingsPressed)

        let bottom = NSStackView()
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.spacing = 10
        bottom.addView(footer, in: .leading)
        bottom.addView(settingsButton, in: .trailing)

        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 18, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        for view in [header, lead, aboutCard, canCard, cannotCard,
                     openGitHub, actions, copyStatus, launchRow, bottom] {
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
            root.widthAnchor.constraint(equalToConstant: MainWindowController.contentWidth),
            openGitHub.widthAnchor.constraint(equalToConstant: bodyWidth),
            actions.widthAnchor.constraint(equalToConstant: bodyWidth),
            copyStatus.widthAnchor.constraint(equalToConstant: bodyWidth),
            aboutCard.widthAnchor.constraint(equalToConstant: bodyWidth),
            canCard.widthAnchor.constraint(equalToConstant: bodyWidth),
            cannotCard.widthAnchor.constraint(equalToConstant: bodyWidth),
            bottom.widthAnchor.constraint(equalToConstant: bodyWidth)
        ])
    }

    private func fillCard(_ card: CardView, title: String, body: String, width: CGFloat) {
        let titleField = NSTextField(labelWithString: title)
        titleField.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        let bodyField = NSTextField(wrappingLabelWithString: body)
        bodyField.font = NSFont.systemFont(ofSize: 12)
        bodyField.textColor = NSColor.secondaryLabelColor
        bodyField.maximumNumberOfLines = 0
        bodyField.preferredMaxLayoutWidth = width
        let stack = NSStackView(views: [titleField, bodyField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)
        ])
    }

    func present(activating: Bool) {
        render()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if activating { NSApp.activate(ignoringOtherApps: true) }
        fitWindow()
    }

    func render() {
        launchSwitch.state = SettingsStore.shared.current.launchAtLogin ? .on : .off
        fitWindow()
    }

    private func fitWindow() {
        guard let window = window else { return }
        root.layoutSubtreeIfNeeded()
        let height = max(root.fittingSize.height, 520)
        window.setContentSize(NSSize(width: MainWindowController.contentWidth, height: height))
    }

    @objc private func openGitHubPressed() { onOpenGitHub?() }

    @objc private func copyGitHubPressed() {
        onCopyGitHub?()
        copyStatus.stringValue = L("store.copiedGitHub")
    }

    @objc private func copyClonePressed() {
        onCopyClone?()
        copyStatus.stringValue = L("store.copiedClone")
    }

    @objc private func launchChanged() {
        onSetLaunchAtLogin?(launchSwitch.state == .on)
    }

    @objc private func settingsPressed() { onOpenSettings?() }
}
