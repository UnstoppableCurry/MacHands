import AppKit
import MacHandsCore

/// SPEC §7.2 的唯一主窗口;agent 连上之后它就是 §10.2 的授权页。
/// 首启自动打开一次,配对成功再自动弹一次,之后只在用户要求时出现。
///
/// 没连上:一个大按钮,一句话说明,一行状态。别的都折起来。
/// 连上了:授权范围(只选一次)+ 三项系统权限 + 「授权并验证」+ 自检结果 + 开机自启。
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
        /// SPEC §10.2:点过「授权并验证」的时刻(毫秒);nil = 还没做过。
        var authorizedAt: Double?
    }

    var onCopy: (() -> Void)?
    var onSetMode: ((ApprovalMode) -> Void)?
    var onSetLaunchAtLogin: ((Bool) -> Void)?
    var onOpenSettings: (() -> Void)?
    /// 「授权并验证」:参数是用户选的范围。自检由本窗口自己在后台跑并渲染。
    var onAuthorize: ((ApprovalMode) -> Void)?

    private static let contentWidth: CGFloat = 460
    private static let bodyWidth: CGFloat = contentWidth - 48
    /// 卡片内边距 14 × 2 之后的可用宽度。
    private static let innerWidth: CGFloat = bodyWidth - 28
    /// 授权页三个单选的顺序;推荐项排第一(SPEC §10.1)。
    private static let scopes: [ApprovalMode] = [.auto, .readonly, .ask]
    private static let scopeKeys = ["auth.scope.auto", "auth.scope.readonly", "auth.scope.ask"]
    /// 三行系统权限的顺序:通知 / 屏幕录制 / 辅助功能。
    private static let panes: [Permissions.Pane] = [.notifications, .screen, .accessibility]
    private static let permKeys = ["perm.notify", "perm.screen", "perm.ax"]

    private let root = NSStackView()
    private let badge = GradientBadge(symbolName: "hand.raised.fill", size: 40)
    private let headline = NSTextField(wrappingLabelWithString: "")
    private let lead = NSTextField(wrappingLabelWithString: "")

    private let copyButton = StyledButton(title: "", kind: .filled(Theme.accentA), size: 14)
    private let copyStatus = NSTextField(wrappingLabelWithString: "")

    private let waitingRow = NSStackView()
    private let spinner = NSProgressIndicator()
    private let waitingLabel = NSTextField(labelWithString: "")

    private let pausedBanner = CardView()
    private let pausedLabel = NSTextField(labelWithString: "")

    // --- 授权页(SPEC §10.2)---------------------------------------------------
    private let authCard = CardView()
    private let authBox = NSStackView()
    private let scopeTitle = NSTextField(labelWithString: "")
    private let scopeButtons: [NSButton] = MainWindowController.scopes.map { _ in
        NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    }
    private let scopeHints: [NSTextField] = MainWindowController.scopes.map { _ in
        NSTextField(wrappingLabelWithString: "")
    }
    private let recommendedBadge = NSTextField(labelWithString: "")
    private let permsTitle = NSTextField(labelWithString: "")
    private let permsGrid = NSGridView()
    private let permStates: [NSTextField] = MainWindowController.panes.map { _ in
        NSTextField(labelWithString: "")
    }
    private let permButtons: [StyledButton] = MainWindowController.panes.map { _ in
        StyledButton(title: "", kind: .outline, size: 11, weight: .medium)
    }
    private let verifySpinner = NSProgressIndicator()
    private let authStatus = NSTextField(labelWithString: "")
    private let statusRow = NSStackView()
    private let resultsTitle = NSTextField(labelWithString: "")
    private let resultsStack = NSStackView()
    private let resultsSummary = NSTextField(wrappingLabelWithString: "")
    private let authDone = NSTextField(labelWithString: "")
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
    private var renderedOnce = false
    /// 自检正在后台跑:期间 render 不许碰按钮的标题和可用状态。
    private var verifying = false
    private var lastPermissions: Permissions.Snapshot?
    private var permTimer: Timer?
    private var permPollInFlight = false

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
        // `screen.selfshot` 靠这个标认出主窗口(标题会被本地化,不能拿来认)。
        window.identifier = SelfShot.mainWindowIdentifier
        window.center()
        // 存储属性在 super.init 之前不能读回来,所以这里没有任何 self.xxx。
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("MainWindowController is code-only")
    }

    deinit {
        permTimer?.invalidate()
    }

    // MARK: - 布局

    private func build() {
        guard let window = self.window else { return }
        let bodyWidth = MainWindowController.bodyWidth

        headline.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        headline.maximumNumberOfLines = 2
        headline.preferredMaxLayoutWidth = bodyWidth - 54
        headline.stringValue = L("main.headline")
        lead.font = NSFont.systemFont(ofSize: 12.5)
        lead.textColor = NSColor.secondaryLabelColor
        lead.maximumNumberOfLines = 3
        lead.preferredMaxLayoutWidth = bodyWidth - 54
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
        // 转圈不转的两个老原因,一次堵掉:
        //  1. 在 NSStackView 里没有固有尺寸约束时会被压成 0×0 —— 画面上就是"静止的一点";
        //  2. 动画跟着主 run loop 走,主线程一忙就停 —— 换成独立线程驱动。
        spinner.usesThreadedAnimation = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16)
        ])
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

        // --- 连上之后:授权页 -----------------------------------------------------
        buildAuthCard(inner: MainWindowController.innerWidth)

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
        let stacked: [NSView] = [header, pausedBanner, copyButton, copyStatus, waitingRow, authCard,
                                 detailsHeader, detailsCard, footer]
        for view in stacked {
            root.addArrangedSubview(view)
        }
        root.setCustomSpacing(4, after: copyButton)
        root.setCustomSpacing(10, after: detailsHeader)

        let content = NSView()
        content.addSubview(root)
        window.contentView = content

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: MainWindowController.contentWidth),
            headline.widthAnchor.constraint(equalToConstant: bodyWidth - 54),
            lead.widthAnchor.constraint(equalToConstant: bodyWidth - 54),
            pausedBanner.widthAnchor.constraint(equalToConstant: bodyWidth),
            copyButton.widthAnchor.constraint(equalToConstant: bodyWidth),
            copyButton.heightAnchor.constraint(equalToConstant: 40),
            copyStatus.widthAnchor.constraint(equalToConstant: bodyWidth),
            authCard.widthAnchor.constraint(equalToConstant: bodyWidth),
            detailsCard.widthAnchor.constraint(equalToConstant: bodyWidth),
            licenseLabel.widthAnchor.constraint(lessThanOrEqualToConstant: bodyWidth - 110),
            footer.widthAnchor.constraint(equalToConstant: bodyWidth),
            relayValue.widthAnchor.constraint(lessThanOrEqualToConstant: bodyWidth - 90),
            nameValue.widthAnchor.constraint(lessThanOrEqualToConstant: bodyWidth - 90),
            idValue.widthAnchor.constraint(lessThanOrEqualToConstant: bodyWidth - 90)
        ])
    }

    /// SPEC §10.2 的授权页,从上到下:范围三选一 → 三项系统权限 → 授权并验证 →
    /// 自检结果 → 已授权时刻 → 开机自启。
    private func buildAuthCard(inner: CGFloat) {
        scopeTitle.stringValue = L("auth.title")
        scopeTitle.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        scopeTitle.textColor = NSColor.secondaryLabelColor

        recommendedBadge.stringValue = L("auth.recommended")
        recommendedBadge.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        recommendedBadge.textColor = Theme.accentB

        authBox.orientation = .vertical
        authBox.alignment = .leading
        authBox.spacing = 12
        authBox.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        authBox.addArrangedSubview(scopeTitle)
        authBox.setCustomSpacing(6, after: scopeTitle)

        for (index, button) in scopeButtons.enumerated() {
            // 文案形如「开发者 — 全部允许;…」:破折号前是单选的标题,后面是灰色的一行说明。
            // 拆开来放,英文那句长说明才不会把单选撑出卡片。
            let parts = L(MainWindowController.scopeKeys[index]).components(separatedBy: " — ")
            button.title = parts.first ?? ""
            button.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
            button.tag = index
            button.target = self
            button.action = #selector(scopeChanged(_:))

            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.addView(button, in: .leading)
            if MainWindowController.scopes[index] == .auto {
                row.addView(recommendedBadge, in: .leading)
            }

            let hint = scopeHints[index]
            hint.stringValue = parts.dropFirst().joined(separator: " — ")
            hint.font = NSFont.systemFont(ofSize: 11)
            hint.textColor = NSColor.tertiaryLabelColor
            hint.maximumNumberOfLines = 2
            hint.preferredMaxLayoutWidth = inner - 20
            hint.isHidden = hint.stringValue.isEmpty
            let hintWrap = NSStackView(views: [hint])
            hintWrap.orientation = .vertical
            hintWrap.alignment = .leading
            hintWrap.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

            let block = NSStackView(views: [row, hintWrap])
            block.orientation = .vertical
            block.alignment = .leading
            block.spacing = 1
            authBox.addArrangedSubview(block)
            authBox.setCustomSpacing(8, after: block)
            NSLayoutConstraint.activate([
                block.widthAnchor.constraint(equalToConstant: inner),
                hint.widthAnchor.constraint(lessThanOrEqualToConstant: inner - 20)
            ])
        }

        authBox.addArrangedSubview(separator(width: inner))

        permsTitle.stringValue = L("auth.perms.title")
        permsTitle.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        permsTitle.textColor = NSColor.secondaryLabelColor
        authBox.addArrangedSubview(permsTitle)
        authBox.setCustomSpacing(8, after: permsTitle)

        // 三列:名称+说明 | 状态 | 打开设置。宽度写死,免得英文说明把列挤散。
        let stateWidth: CGFloat = 62
        let buttonWidth: CGFloat = 84
        let textWidth = inner - stateWidth - buttonWidth - 20
        for (index, key) in MainWindowController.permKeys.enumerated() {
            let name = NSTextField(labelWithString: L(key + ".name"))
            name.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            let desc = NSTextField(wrappingLabelWithString: L(key + ".desc"))
            desc.font = NSFont.systemFont(ofSize: 11)
            desc.textColor = NSColor.tertiaryLabelColor
            desc.maximumNumberOfLines = 2
            desc.preferredMaxLayoutWidth = textWidth
            let text = NSStackView(views: [name, desc])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 1

            let state = permStates[index]
            state.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
            state.stringValue = L("perm.state.unknown")
            state.textColor = NSColor.secondaryLabelColor

            let open = permButtons[index]
            open.title = L("perm.open")
            open.tag = index
            open.target = self
            open.action = #selector(openPanePressed(_:))

            permsGrid.addRow(with: [text, state, open])
            NSLayoutConstraint.activate([
                text.widthAnchor.constraint(equalToConstant: textWidth),
                desc.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth),
                open.widthAnchor.constraint(equalToConstant: buttonWidth),
                open.heightAnchor.constraint(equalToConstant: 24)
            ])
        }
        permsGrid.rowSpacing = 10
        permsGrid.columnSpacing = 10
        permsGrid.yPlacement = .center
        permsGrid.column(at: 1).width = stateWidth
        permsGrid.column(at: 2).xPlacement = .trailing
        authBox.addArrangedSubview(permsGrid)

        authBox.addArrangedSubview(separator(width: inner))

        // 用户读数 2026-09-06:"不要有 重新验证 这个环节,用户使用的时候就是点击就生效,越简单越好"。
        // 所以卡片上不再有按钮:选范围点了就生效,自检自己跑(开窗、换范围、权限变动各跑一次)。

        verifySpinner.style = .spinning
        verifySpinner.controlSize = .small
        verifySpinner.isDisplayedWhenStopped = false
        authStatus.font = NSFont.systemFont(ofSize: 11.5)
        authStatus.textColor = NSColor.secondaryLabelColor
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusRow.addArrangedSubview(verifySpinner)
        statusRow.addArrangedSubview(authStatus)
        statusRow.isHidden = true
        authBox.addArrangedSubview(statusRow)

        resultsTitle.stringValue = L("verify.title")
        resultsTitle.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        resultsTitle.textColor = NSColor.secondaryLabelColor
        resultsTitle.isHidden = true
        resultsStack.orientation = .vertical
        resultsStack.alignment = .leading
        resultsStack.spacing = 6
        resultsStack.isHidden = true
        resultsSummary.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        resultsSummary.maximumNumberOfLines = 3
        resultsSummary.preferredMaxLayoutWidth = inner
        resultsSummary.isHidden = true
        authBox.addArrangedSubview(resultsTitle)
        authBox.setCustomSpacing(6, after: resultsTitle)
        authBox.addArrangedSubview(resultsStack)
        authBox.addArrangedSubview(resultsSummary)

        authDone.font = NSFont.systemFont(ofSize: 11)
        authDone.textColor = NSColor.secondaryLabelColor
        authDone.isHidden = true
        authBox.addArrangedSubview(authDone)

        authBox.addArrangedSubview(separator(width: inner))

        launchLabel.stringValue = L("main.launchAtLogin")
        launchLabel.font = NSFont.systemFont(ofSize: 12)
        launchSwitch.target = self
        launchSwitch.action = #selector(launchToggled)
        launchRow.orientation = .horizontal
        launchRow.alignment = .centerY
        launchRow.distribution = .equalSpacing
        launchRow.addArrangedSubview(launchLabel)
        launchRow.addArrangedSubview(launchSwitch)
        authBox.addArrangedSubview(launchRow)

        authCard.addSubview(authBox)
        authBox.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            authBox.leadingAnchor.constraint(equalTo: authCard.leadingAnchor),
            authBox.trailingAnchor.constraint(equalTo: authCard.trailingAnchor),
            authBox.topAnchor.constraint(equalTo: authCard.topAnchor),
            authBox.bottomAnchor.constraint(equalTo: authCard.bottomAnchor),
            permsGrid.widthAnchor.constraint(lessThanOrEqualToConstant: inner),
            statusRow.widthAnchor.constraint(lessThanOrEqualToConstant: inner),
            resultsStack.widthAnchor.constraint(equalToConstant: inner),
            resultsSummary.widthAnchor.constraint(equalToConstant: inner),
            authDone.widthAnchor.constraint(lessThanOrEqualToConstant: inner),
            launchRow.widthAnchor.constraint(equalToConstant: inner)
        ])
        authCard.isHidden = true
    }

    private func separator(width: CGFloat) -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: width).isActive = true
        return box
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
        // render 往往在窗口还没上屏时就跑过了,那时 startAnimation 不生效。
        // 窗口摆出来之后再踢一脚,这样"等待中"的圈是真的在转。
        if !waitingRow.isHidden { spinner.startAnimation(nil) }
        startPermissionPolling()
    }

    func windowWillClose(_ notification: Notification) {
        stopPermissionPolling()
    }

    func render(_ model: Model) {
        let previousMode = self.model.mode
        let firstRender = !renderedOnce
        self.model = model
        guard self.window != nil else { return }
        renderedOnce = true

        relayValue.stringValue = model.relayURL.isEmpty ? L("value.unknown") : model.relayURL
        nameValue.stringValue = model.macName.isEmpty ? L("value.unknown") : model.macName
        idValue.stringValue = model.macId.isEmpty ? L("value.unknown") : model.macId
        licenseLabel.stringValue = model.licenseLine ?? ""
        licenseLabel.isHidden = (model.licenseLine == nil)
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

        // 单选只在模式真的变了时跟着改,免得 5 秒一次的刷新把用户刚点的选择顶回去。
        if firstRender || previousMode != model.mode {
            selectScope(model.mode)
        }
        if firstRender && !authCard.isHidden {
            // 开窗就自检一次,用户不用找按钮
            DispatchQueue.main.async { [weak self] in self?.authorizePressed() }
        }
        if let stamp = model.authorizedAt {
            let when = MainWindowController.dateText(milliseconds: stamp)
            authDone.stringValue = Lf("auth.done", "\(StatusItemController.modeName(model.mode)) · \(when)")
            authDone.isHidden = false
        } else {
            authDone.isHidden = true
        }

        let live = model.agents.filter { model.online.contains($0.id) }
        if let connected = live.first {
            badge.setSymbol("checkmark")
            headline.stringValue = (model.authorizedAt == nil)
                ? Lf("auth.headline", connected.displayName)
                : Lf("main.connectedHeadline", connected.displayName)
            lead.stringValue = ""
            lead.isHidden = true
            waitingRow.isHidden = true
            spinner.stopAnimation(nil)
            authCard.isHidden = false
        } else {
            badge.setSymbol("hand.raised.fill")
            headline.stringValue = L("main.headline")
            lead.stringValue = L("app.tagline")
            lead.isHidden = false
            authCard.isHidden = model.agents.isEmpty
            waitingRow.isHidden = false
            waitingLabel.stringValue = waitingText()
            spinner.startAnimation(nil)
        }
        if !authCard.isHidden { pollPermissions() }

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

    private static func dateText(milliseconds: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }

    // MARK: - 授权范围

    private func selectScope(_ mode: ApprovalMode) {
        for (index, button) in scopeButtons.enumerated() {
            button.state = (MainWindowController.scopes[index] == mode) ? .on : .off
        }
    }

    private func selectedScope() -> ApprovalMode {
        for (index, button) in scopeButtons.enumerated() where button.state == .on {
            return MainWindowController.scopes[index]
        }
        return .auto
    }

    @objc private func scopeChanged(_ sender: NSButton) {
        // 三个单选不在同一个父视图里(每个带自己的说明行),AppKit 不会自动成组,互斥自己管。
        for button in scopeButtons {
            button.state = (button === sender) ? .on : .off
        }
        // 点了就生效(用户读数 2026-09-06:"用户使用的时候应当点击就直接切换模式")。
        // 以前要再点一次「授权并验证」才提交,界面上的选中项和实际策略会同时矛盾;
        // 更糟的是远程 agent 一旦被切进逐条审批就出不来——改模式的命令本身也要审批。
        onSetMode?(selectedScope())
        authorizePressed()      // 换了范围就把自检重跑一遍,结果永远跟着当前设置走
    }

    // MARK: - 系统权限

    private enum PermState {
        case granted
        case missing
        case unknown
    }

    private func startPermissionPolling() {
        stopPermissionPolling()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollPermissions()
        }
        RunLoop.main.add(timer, forMode: .common)
        permTimer = timer
        pollPermissions()
    }

    private func stopPermissionPolling() {
        permTimer?.invalidate()
        permTimer = nil
    }

    /// 通知那一项要等系统回调,别在主线程上等;查完再 hop 回来改字。
    private func pollPermissions() {
        guard !permPollInFlight, !authCard.isHidden else { return }
        permPollInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = Permissions.snapshot()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.permPollInFlight = false
                self.applyPermissions(snapshot)
            }
        }
    }

    private func applyPermissions(_ snapshot: Permissions.Snapshot) {
        guard snapshot != lastPermissions else { return }
        lastPermissions = snapshot
        let notify: PermState
        switch snapshot.notifications {
        case "authorized": notify = .granted
        case "unknown": notify = .unknown
        default: notify = .missing
        }
        setPermState(0, notify)
        setPermState(1, snapshot.screen ? .granted : .missing)
        setPermState(2, snapshot.accessibility ? .granted : .missing)

        // 权限刚变过,上面三行已经是新的,下面那份验证结果就成了旧闻。
        // 真机上见过:三行都写"已授权",结果区还在说"键鼠 未授权",用户会以为坏了。
        // 与其显示矛盾,不如自己重跑一次。
        if !verifying, !statusRow.isHidden || !resultsStack.arrangedSubviews.isEmpty {
            authorizePressed()
        }
    }

    private func setPermState(_ index: Int, _ state: PermState) {
        let label = permStates[index]
        switch state {
        case .granted:
            label.stringValue = L("perm.state.ok")
            label.textColor = NSColor.systemGreen
        case .missing:
            label.stringValue = L("perm.state.no")
            label.textColor = NSColor.systemOrange
        case .unknown:
            label.stringValue = L("perm.state.unknown")
            label.textColor = NSColor.secondaryLabelColor
        }
        // 已经给了的权限不用再去设置里找;按钮只留给还缺的那几项。
        permButtons[index].isHidden = (state == .granted)
    }

    @objc private func openPanePressed(_ sender: NSButton) {
        let index = sender.tag
        guard MainWindowController.panes.indices.contains(index) else { return }
        Permissions.open(MainWindowController.panes[index])
    }

    // MARK: - 授权并验证

    /// 跑一次自检。没有按钮了,由三件事触发:窗口打开、换授权范围、系统权限发生变化。
    @objc private func authorizePressed() {
        guard !verifying else { return }
        // 模式在点单选那一刻已经生效;这里再传一次是幂等的,顺便记下"做过一次授权"的时刻。
        let mode = selectedScope()
        verifying = true
        authStatus.stringValue = L("auth.verifying")
        statusRow.isHidden = false
        verifySpinner.startAnimation(nil)
        fitWindow()
        onAuthorize?(mode)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let rows = Verifier.run()
            DispatchQueue.main.async { self?.showResults(rows) }
        }
    }

    private func showResults(_ rows: [Verifier.Row]) {
        verifying = false
        verifySpinner.stopAnimation(nil)
        authStatus.stringValue = ""
        statusRow.isHidden = true

        for view in resultsStack.arrangedSubviews {
            resultsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for row in rows {
            resultsStack.addArrangedSubview(resultRow(row))
            if !row.ok, let fix = row.fix, !fix.isEmpty {
                resultsStack.addArrangedSubview(fixRow(fix))
            }
        }
        let failed = rows.filter { !$0.ok }.count
        resultsSummary.stringValue = failed == 0 ? L("verify.allPass") : Lf("verify.someFail", failed)
        resultsSummary.textColor = failed == 0 ? NSColor.systemGreen : NSColor.labelColor
        resultsTitle.isHidden = false
        resultsStack.isHidden = false
        resultsSummary.isHidden = false

        lastPermissions = nil        // 强制重刷三行状态
        pollPermissions()
        fitWindow()
    }

    private func resultRow(_ row: Verifier.Row) -> NSView {
        let inner = MainWindowController.innerWidth
        let mark = NSTextField(labelWithString: row.ok ? "✓" : "✗")
        mark.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        mark.textColor = row.ok ? NSColor.systemGreen : Theme.danger
        let name = NSTextField(labelWithString: L("verify.\(row.key)"))
        name.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let detail = NSTextField(labelWithString: row.detail)
        detail.font = NSFont.systemFont(ofSize: 11)
        detail.textColor = NSColor.secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let line = NSStackView(views: [mark, name, detail])
        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.spacing = 6
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 14),
            line.widthAnchor.constraint(lessThanOrEqualToConstant: inner)
        ])
        return line
    }

    private func fixRow(_ fix: String) -> NSView {
        let inner = MainWindowController.innerWidth
        let hint = NSTextField(wrappingLabelWithString: fix)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = NSColor.tertiaryLabelColor
        hint.maximumNumberOfLines = 3
        hint.preferredMaxLayoutWidth = inner - 20
        let wrap = NSStackView(views: [hint])
        wrap.orientation = .vertical
        wrap.alignment = .leading
        wrap.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        hint.widthAnchor.constraint(lessThanOrEqualToConstant: inner - 20).isActive = true
        return wrap
    }

    // MARK: - 动作

    @objc private func copyPressed() { onCopy?() }

    @objc private func launchToggled() {
        onSetLaunchAtLogin?(launchSwitch.state == .on)
    }

    @objc private func openSettingsPressed() { onOpenSettings?() }

    @objc private func toggleDetails() {
        detailsCard.isHidden = (detailsToggle.state != .on)
        fitWindow()
    }
}
