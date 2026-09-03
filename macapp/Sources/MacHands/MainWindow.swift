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

    private static let contentWidth: CGFloat = 420

    private let root = NSStackView()
    private let badge = GradientBadge(symbolName: "hand.raised.fill", size: 40)
    private let headline = NSTextField(labelWithString: "")
    private let lead = NSTextField(wrappingLabelWithString: "")

    private let copyButton = StyledButton(title: "", kind: .filled(Theme.accentA), size: 14)
    private let copyStatus = NSTextField(wrappingLabelWithString: "")

    private let waitingRow = NSStackView()
    private let spinner = NSProgressIndicator()
    private let waitingLabel = NSTextField(labelWithString: "")

    private let pausedBanner = CardView()
    private let pausedLabel = NSTextField(labelWithString: "")

    private let connectedCard = CardView()
    private let connectedBox = NSStackView()
    private let modeTitle = NSTextField(labelWithString: "")
    private let modeSwitcher = NSSegmentedControl()
    private let modeHint = NSTextField(labelWithString: "")
    private let launchRow = NSStackView()
    private let launchLabel = NSTextField(labelWithString: "")
    private let launchSwitch = NSSwitch()

    private let detailsToggle = NSButton()
    private let detailsCard = CardView()
    private let detailsGrid = NSGridView()
    private let relayValue = NSTextField(labelWithString: "")
    private let nameValue = NSTextField(labelWithString: "")
    private let idValue = NSTextField(labelWithString: "")

    private let licenseLabel = NSTextField(wrappingLabelWithString: "")
    private let settingsButton = StyledButton(title: "", kind: .outline, size: 11.5, weight: .medium)

    private var model = Model()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                                  width: MainWindowController.contentWidth,
                                                  height: 320),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = L("app.name")
        window.titlebarAppearsTransparent = true
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

        headline.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        headline.stringValue = L("main.headline")
        lead.font = NSFont.systemFont(ofSize: 12.5)
        lead.textColor = NSColor.secondaryLabelColor
        lead.maximumNumberOfLines = 3
        lead.stringValue = L("app.tagline")

        let headerText = NSStackView(views: [headline, lead])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 4

        let header = NSStackView(views: [badge, headerText])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 14

        // --- 一个大按钮 -------------------------------------------------------
        copyButton.title = L("main.copy")
        copyButton.target = self
        copyButton.action = #selector(copyPressed)

        copyStatus.font = NSFont.systemFont(ofSize: 11.5)
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

        // --- 暂停横幅 -----------------------------------------------------------
        pausedLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        pausedLabel.textColor = Theme.danger
        pausedLabel.stringValue = "⏸  " + L("main.pausedBanner")
        pausedBanner.setTint(background: Theme.danger.withAlphaComponent(0.1),
                             border: Theme.danger.withAlphaComponent(0.35))
        pausedBanner.addSubview(pausedLabel)
        pausedLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pausedLabel.leadingAnchor.constraint(equalTo: pausedBanner.leadingAnchor, constant: 12),
            pausedLabel.trailingAnchor.constraint(equalTo: pausedBanner.trailingAnchor, constant: -12),
            pausedLabel.topAnchor.constraint(equalTo: pausedBanner.topAnchor, constant: 9),
            pausedLabel.bottomAnchor.constraint(equalTo: pausedBanner.bottomAnchor, constant: -9)
        ])
        pausedBanner.isHidden = true

        // --- 连上之后:一张卡 -----------------------------------------------------
        modeTitle.stringValue = L("main.mode")
        modeTitle.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        modeTitle.textColor = .secondaryLabelColor

        modeSwitcher.segmentStyle = .rounded
        modeSwitcher.segmentCount = 2
        modeSwitcher.setLabel(L("main.mode.ask"), forSegment: 0)
        modeSwitcher.setLabel(L("main.mode.auto"), forSegment: 1)
        modeSwitcher.target = self
        modeSwitcher.action = #selector(modeChanged)

        let modeRow = NSStackView(views: [modeTitle, modeSwitcher])
        modeRow.orientation = .horizontal
        modeRow.alignment = .centerY
        modeRow.distribution = .equalSpacing

        modeHint.font = NSFont.systemFont(ofSize: 11)
        modeHint.textColor = .tertiaryLabelColor

        launchLabel.stringValue = L("main.launchAtLogin")
        launchLabel.font = NSFont.systemFont(ofSize: 12)
        launchSwitch.target = self
        launchSwitch.action = #selector(launchToggled)
        launchRow.orientation = .horizontal
        launchRow.alignment = .centerY
        launchRow.distribution = .equalSpacing
        launchRow.addArrangedSubview(launchLabel)
        launchRow.addArrangedSubview(launchSwitch)

        let divider = NSBox()
        divider.boxType = .separator

        connectedBox.orientation = .vertical
        connectedBox.alignment = .leading
        connectedBox.spacing = 12
        connectedBox.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        connectedBox.addArrangedSubview(modeRow)
        connectedBox.setCustomSpacing(4, after: modeRow)
        connectedBox.addArrangedSubview(modeHint)
        connectedBox.addArrangedSubview(divider)
        connectedBox.addArrangedSubview(launchRow)
        connectedCard.addSubview(connectedBox)
        connectedBox.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            connectedBox.leadingAnchor.constraint(equalTo: connectedCard.leadingAnchor),
            connectedBox.trailingAnchor.constraint(equalTo: connectedCard.trailingAnchor),
            connectedBox.topAnchor.constraint(equalTo: connectedCard.topAnchor),
            connectedBox.bottomAnchor.constraint(equalTo: connectedCard.bottomAnchor)
        ])
        connectedCard.isHidden = true

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
            value.font = NSFont.systemFont(ofSize: 11.5)
            value.isSelectable = true
            value.lineBreakMode = .byTruncatingMiddle
        }
        idValue.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        detailsGrid.addRow(with: [gridLabel(L("main.relay")), relayValue])
        detailsGrid.addRow(with: [gridLabel(L("main.macName")), nameValue])
        detailsGrid.addRow(with: [gridLabel(L("main.macId")), idValue])
        detailsGrid.rowSpacing = 7
        detailsGrid.columnSpacing = 10
        detailsGrid.column(at: 0).xPlacement = .trailing
        detailsCard.addSubview(detailsGrid)
        detailsGrid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            detailsGrid.leadingAnchor.constraint(equalTo: detailsCard.leadingAnchor, constant: 14),
            detailsGrid.trailingAnchor.constraint(lessThanOrEqualTo: detailsCard.trailingAnchor, constant: -14),
            detailsGrid.topAnchor.constraint(equalTo: detailsCard.topAnchor, constant: 12),
            detailsGrid.bottomAnchor.constraint(equalTo: detailsCard.bottomAnchor, constant: -12)
        ])
        detailsCard.isHidden = true

        licenseLabel.font = NSFont.systemFont(ofSize: 10.5)
        licenseLabel.textColor = NSColor.tertiaryLabelColor
        licenseLabel.maximumNumberOfLines = 2

        settingsButton.title = L("main.openSettings")
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
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 22, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        // 显式标注 [NSView]:元素类型不齐(NSStackView / NSButton / NSTextField /
        // NSGridView / CardView),别让类型检查器自己去猜公共父类。
        let stacked: [NSView] = [header, pausedBanner, copyButton, copyStatus, waitingRow, connectedCard,
                                 detailsHeader, detailsCard, footer]
        for view in stacked {
            root.addArrangedSubview(view)
        }
        root.setCustomSpacing(4, after: copyButton)
        root.setCustomSpacing(10, after: detailsHeader)

        let content = NSView()
        content.addSubview(root)
        window.contentView = content

        let bodyWidth = MainWindowController.contentWidth - 48
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: MainWindowController.contentWidth),
            lead.widthAnchor.constraint(equalToConstant: bodyWidth - 54),
            pausedBanner.widthAnchor.constraint(equalToConstant: bodyWidth),
            copyButton.widthAnchor.constraint(equalToConstant: bodyWidth),
            copyButton.heightAnchor.constraint(equalToConstant: 40),
            copyStatus.widthAnchor.constraint(equalToConstant: bodyWidth),
            connectedCard.widthAnchor.constraint(equalToConstant: bodyWidth),
            modeRow.widthAnchor.constraint(equalToConstant: bodyWidth - 28),
            launchRow.widthAnchor.constraint(equalToConstant: bodyWidth - 28),
            divider.widthAnchor.constraint(equalToConstant: bodyWidth - 28),
            modeSwitcher.widthAnchor.constraint(equalToConstant: 170),
            detailsCard.widthAnchor.constraint(equalToConstant: bodyWidth),
            licenseLabel.widthAnchor.constraint(lessThanOrEqualToConstant: bodyWidth - 110),
            footer.widthAnchor.constraint(equalToConstant: bodyWidth),
            relayValue.widthAnchor.constraint(lessThanOrEqualToConstant: bodyWidth - 90),
            nameValue.widthAnchor.constraint(lessThanOrEqualToConstant: bodyWidth - 90),
            idValue.widthAnchor.constraint(lessThanOrEqualToConstant: bodyWidth - 90)
        ])
    }

    private func gridLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11.5)
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

        modeSwitcher.selectedSegment = (model.mode == .auto) ? 1 : 0
        modeHint.stringValue = (model.mode == .auto) ? L("main.mode.hint.auto") : L("main.mode.hint.ask")
        pausedBanner.isHidden = !model.paused

        switch LoginItem.status() {
        case .enabled:
            launchSwitch.state = .on
            launchSwitch.isEnabled = true
        case .requiresApproval:
            launchSwitch.state = .off
            launchSwitch.isEnabled = true
        case .disabled:
            launchSwitch.state = .off
            launchSwitch.isEnabled = true
        case .unavailable:
            launchSwitch.state = .off
            launchSwitch.isEnabled = false
        }

        let live = model.agents.filter { model.online.contains($0.id) }
        if let first = live.first {
            badge.setSymbol("checkmark")
            headline.stringValue = Lf("main.connectedHeadline", first.displayName)
            lead.stringValue = ""
            lead.isHidden = true
            waitingRow.isHidden = true
            spinner.stopAnimation(nil)
            connectedCard.isHidden = false
        } else {
            badge.setSymbol("hand.raised.fill")
            headline.stringValue = L("main.headline")
            lead.stringValue = L("app.tagline")
            lead.isHidden = false
            connectedCard.isHidden = model.agents.isEmpty
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

    @objc private func modeChanged() {
        let mode: ApprovalMode = (modeSwitcher.selectedSegment == 1) ? .auto : .ask
        modeHint.stringValue = (mode == .auto) ? L("main.mode.hint.auto") : L("main.mode.hint.ask")
        onSetMode?(mode)
    }

    @objc private func launchToggled() {
        onSetLaunchAtLogin?(launchSwitch.state == .on)
    }

    @objc private func openSettingsPressed() { onOpenSettings?() }

    @objc private func toggleDetails() {
        detailsCard.isHidden = (detailsToggle.state != .on)
        fitWindow()
    }
}
