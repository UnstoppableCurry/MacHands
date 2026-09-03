import AppKit
import MacHandsCore

/// SPEC §7.2 的唯一主窗口。首启自动打开一次,之后只在用户要求时出现。
///
/// 一个大按钮,一句话说明,一行状态。别的都折起来。
/// agent 连上后同一个窗口换一张脸:确认 + 审批模式 + 开机自启。
final class MainWindowController: NSWindowController, NSWindowDelegate {

    struct Model {
        var relayState: RelayClient.State = .idle
        var agents: [AuthorizedAgent] = []
        var online: Set<String> = []
        var mode: ApprovalMode = .ask
        var paused: Bool = false
        var relayURL: String = ""
        var macName: String = ""
        var macId: String = ""
        var licenseLine: String?
    }

    var onCopy: (() -> Void)?
    var onSetMode: ((ApprovalMode) -> Void)?
    var onSetLaunchAtLogin: ((Bool) -> Void)?
    var onOpenSettings: (() -> Void)?

    private static let contentWidth: CGFloat = 460
    private static let bodyWidth: CGFloat = 412

    private let root = NSStackView()
    private let iconView = NSImageView()
    private let headline = NSTextField(labelWithString: "")
    private let lead = NSTextField(wrappingLabelWithString: "")

    private let copyButton = NSButton()
    private let copyStatus = NSTextField(wrappingLabelWithString: "")

    private let waitingRow = NSStackView()
    private let spinner = NSProgressIndicator()
    private let waitingLabel = NSTextField(labelWithString: "")

    private let connectedBox = NSStackView()
    private let modeTitle = NSTextField(labelWithString: "")
    private let askRadio = NSButton()
    private let autoRadio = NSButton()
    private let launchCheckbox = NSButton()

    private let detailsToggle = NSButton()
    private let detailsGrid = NSGridView()
    private let relayValue = NSTextField(labelWithString: "")
    private let nameValue = NSTextField(labelWithString: "")
    private let idValue = NSTextField(labelWithString: "")

    private let licenseLabel = NSTextField(wrappingLabelWithString: "")
    private let settingsButton = NSButton()

    private var model = Model()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                                  width: MainWindowController.contentWidth,
                                                  height: 320),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = L("app.name")
        window.isReleasedWhenClosed = false
        window.center()
        // 存储属性在 super.init 之前不能读回来,所以这里没有任何 self.xxx。
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("MainWindowController is code-only")
    }

    // MARK: - 布局

    private func build() {
        guard let window = self.window else { return }

        iconView.image = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: nil)
        iconView.contentTintColor = NSColor.controlAccentColor
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        iconView.imageScaling = .scaleProportionallyUpOrDown

        headline.font = NSFont.systemFont(ofSize: 19, weight: .semibold)
        headline.stringValue = L("main.headline")
        lead.font = NSFont.systemFont(ofSize: 12)
        lead.textColor = NSColor.secondaryLabelColor
        lead.maximumNumberOfLines = 3
        lead.stringValue = L("app.tagline")

        let headerText = NSStackView(views: [headline, lead])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 3

        let header = NSStackView(views: [iconView, headerText])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 14

        // --- 一个大按钮 -------------------------------------------------------
        copyButton.title = L("main.copy")
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .large
        copyButton.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        copyButton.keyEquivalent = "\r"
        copyButton.target = self
        copyButton.action = #selector(copyPressed)

        copyStatus.font = NSFont.systemFont(ofSize: 12)
        copyStatus.textColor = NSColor.secondaryLabelColor
        copyStatus.maximumNumberOfLines = 3
        copyStatus.stringValue = ""

        // --- 等待 --------------------------------------------------------------
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        waitingLabel.font = NSFont.systemFont(ofSize: 12)
        waitingLabel.textColor = NSColor.secondaryLabelColor
        waitingRow.orientation = .horizontal
        waitingRow.alignment = .centerY
        waitingRow.spacing = 8
        waitingRow.addArrangedSubview(spinner)
        waitingRow.addArrangedSubview(waitingLabel)

        // --- 连上之后 -----------------------------------------------------------
        modeTitle.stringValue = L("main.mode")
        modeTitle.font = NSFont.systemFont(ofSize: 12, weight: .medium)

        askRadio.setButtonType(.radio)
        askRadio.title = L("main.mode.ask")
        askRadio.font = NSFont.systemFont(ofSize: 12)
        askRadio.target = self
        askRadio.action = #selector(modePressed(_:))

        autoRadio.setButtonType(.radio)
        autoRadio.title = L("main.mode.auto")
        autoRadio.font = NSFont.systemFont(ofSize: 12)
        autoRadio.target = self
        autoRadio.action = #selector(modePressed(_:))

        launchCheckbox.setButtonType(.switch)
        launchCheckbox.title = L("main.launchAtLogin")
        launchCheckbox.font = NSFont.systemFont(ofSize: 12)
        launchCheckbox.target = self
        launchCheckbox.action = #selector(launchToggled)

        connectedBox.orientation = .vertical
        connectedBox.alignment = .leading
        connectedBox.spacing = 4
        connectedBox.addArrangedSubview(modeTitle)
        connectedBox.addArrangedSubview(askRadio)
        connectedBox.addArrangedSubview(autoRadio)
        connectedBox.addArrangedSubview(launchCheckbox)
        connectedBox.setCustomSpacing(10, after: autoRadio)
        connectedBox.isHidden = true

        // --- 折起来的详细信息 -----------------------------------------------------
        detailsToggle.setButtonType(.onOff)
        detailsToggle.bezelStyle = .disclosure
        detailsToggle.title = ""
        detailsToggle.state = .off
        detailsToggle.target = self
        detailsToggle.action = #selector(toggleDetails)
        let detailsTitle = NSTextField(labelWithString: L("main.details"))
        detailsTitle.font = NSFont.systemFont(ofSize: 12)
        detailsTitle.textColor = NSColor.secondaryLabelColor
        let detailsHeader = NSStackView(views: [detailsToggle, detailsTitle])
        detailsHeader.orientation = .horizontal
        detailsHeader.alignment = .centerY
        detailsHeader.spacing = 2

        for value in [relayValue, nameValue, idValue] {
            value.font = NSFont.systemFont(ofSize: 12)
            value.isSelectable = true
            value.lineBreakMode = .byTruncatingMiddle
        }
        idValue.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        detailsGrid.addRow(with: [gridLabel(L("main.relay")), relayValue])
        detailsGrid.addRow(with: [gridLabel(L("main.macName")), nameValue])
        detailsGrid.addRow(with: [gridLabel(L("main.macId")), idValue])
        detailsGrid.rowSpacing = 6
        detailsGrid.columnSpacing = 10
        detailsGrid.column(at: 0).xPlacement = .trailing
        detailsGrid.isHidden = true

        licenseLabel.font = NSFont.systemFont(ofSize: 11)
        licenseLabel.textColor = NSColor.tertiaryLabelColor
        licenseLabel.maximumNumberOfLines = 2

        settingsButton.title = L("main.openSettings")
        settingsButton.bezelStyle = .rounded
        settingsButton.controlSize = .small
        settingsButton.target = self
        settingsButton.action = #selector(openSettingsPressed)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.addView(licenseLabel, in: .leading)
        footer.addView(settingsButton, in: .trailing)

        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        // 显式标注 [NSView]:元素类型不齐(NSStackView / NSButton / NSTextField /
        // NSGridView),别让类型检查器自己去猜公共父类。
        let stacked: [NSView] = [header, copyButton, copyStatus, waitingRow, connectedBox,
                                 detailsHeader, detailsGrid, footer]
        for view in stacked {
            root.addArrangedSubview(view)
        }
        root.setCustomSpacing(8, after: copyButton)
        root.setCustomSpacing(6, after: detailsHeader)

        let content = NSView()
        content.addSubview(root)
        window.contentView = content

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: MainWindowController.contentWidth),
            iconView.widthAnchor.constraint(equalToConstant: 38),
            iconView.heightAnchor.constraint(equalToConstant: 38),
            lead.widthAnchor.constraint(equalToConstant: 350),
            copyButton.widthAnchor.constraint(equalToConstant: MainWindowController.bodyWidth),
            copyStatus.widthAnchor.constraint(equalToConstant: MainWindowController.bodyWidth),
            licenseLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            footer.widthAnchor.constraint(equalToConstant: MainWindowController.bodyWidth),
            relayValue.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
            nameValue.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
            idValue.widthAnchor.constraint(lessThanOrEqualToConstant: 300)
        ])
    }

    private func gridLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = NSColor.secondaryLabelColor
        label.alignment = .right
        return label
    }

    // MARK: - 显示

    func present(activating: Bool) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // 审批卡从不 activate;主窗口是用户自己叫出来的,不给焦点反而像没打开。
        if activating { NSApp.activate(ignoringOtherApps: true) }
    }

    func render(_ model: Model) {
        self.model = model
        guard self.window != nil else { return }

        relayValue.stringValue = model.relayURL.isEmpty ? L("value.unknown") : model.relayURL
        nameValue.stringValue = model.macName.isEmpty ? L("value.unknown") : model.macName
        idValue.stringValue = model.macId.isEmpty ? L("value.unknown") : model.macId
        licenseLabel.stringValue = model.licenseLine ?? ""
        licenseLabel.isHidden = (model.licenseLine == nil)

        askRadio.state = (model.mode == .ask) ? .on : .off
        autoRadio.state = (model.mode == .auto) ? .on : .off
        switch LoginItem.status() {
        case .enabled:
            launchCheckbox.state = .on
            launchCheckbox.isEnabled = true
        case .requiresApproval:
            launchCheckbox.state = .mixed
            launchCheckbox.isEnabled = true
        case .disabled:
            launchCheckbox.state = .off
            launchCheckbox.isEnabled = true
        case .unavailable:
            launchCheckbox.state = .off
            launchCheckbox.isEnabled = false
        }

        let live = model.agents.filter { model.online.contains($0.id) }
        if let first = live.first {
            iconView.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                     accessibilityDescription: nil)
            iconView.contentTintColor = NSColor.systemGreen
            headline.stringValue = Lf("main.connectedHeadline", first.displayName)
            lead.stringValue = ""
            lead.isHidden = true
            waitingRow.isHidden = true
            spinner.stopAnimation(nil)
            connectedBox.isHidden = false
        } else {
            iconView.image = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: nil)
            iconView.contentTintColor = NSColor.controlAccentColor
            headline.stringValue = L("main.headline")
            lead.stringValue = L("app.tagline")
            lead.isHidden = false
            connectedBox.isHidden = model.agents.isEmpty
            waitingRow.isHidden = false
            waitingLabel.stringValue = waitingText()
            spinner.startAnimation(nil)
        }

        fitWindow()
    }

    private func waitingText() -> String {
        switch model.relayState {
        case .failed(let reason):
            return Lf("main.relayDown", reason)
        case .retrying(_, let seconds):
            return Lf("main.relayDown", Lf("fail.retry", Lf("time.seconds", seconds)))
        case .connecting, .idle:
            return L("menu.state.connecting")
        case .online:
            return L("main.waiting")
        }
    }

    func showCopied(success: Bool) {
        copyStatus.stringValue = success ? L("main.copied") : L("main.copyFailed")
        fitWindow()
    }

    private func fitWindow() {
        guard let window = window else { return }
        root.layoutSubtreeIfNeeded()
        let height = root.fittingSize.height
        window.setContentSize(NSSize(width: MainWindowController.contentWidth, height: height))
    }

    // MARK: - 动作

    @objc private func copyPressed() { onCopy?() }

    @objc private func modePressed(_ sender: NSButton) {
        let mode: ApprovalMode = (sender === autoRadio) ? .auto : .ask
        askRadio.state = (mode == .ask) ? .on : .off
        autoRadio.state = (mode == .auto) ? .on : .off
        onSetMode?(mode)
    }

    @objc private func launchToggled() {
        onSetLaunchAtLogin?(launchCheckbox.state == .on)
    }

    @objc private func openSettingsPressed() { onOpenSettings?() }

    @objc private func toggleDetails() {
        detailsGrid.isHidden = (detailsToggle.state != .on)
        fitWindow()
    }
}
