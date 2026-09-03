import AppKit

/// The one window this app has. Built in code — no storyboard, no nib.
///
/// It has two faces and shows exactly one:
///
///   * **pairing** — this Mac is not enrolled (or the user asked to re-pair).
///     One box, one button. The box takes whatever `mac setup` printed — the
///     whole block or just the 32-character code — and the window fills in the
///     rest itself: the Mac's name from the system, the server from last time.
///     Address, name, port and proxy sit behind a disclosure and open on their
///     own only when one of them is the thing that failed.
///
///   * **status** — this Mac is enrolled. What state the tunnel is in, the
///     three facts that identify it on the server, and what to do if it is
///     broken. Nothing to fill in.
///
/// RULINGS.md R8: there is **no password field of any kind**. The pairing code
/// carries no secret; the key pair is made here and the private half never
/// leaves the machine.
final class SetupWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {

    private enum Face { case pairing, status }

    private static let contentWidth: CGFloat = 520
    private static let bodyWidth: CGFloat = 472

    // MARK: - shared chrome

    private let root = NSStackView()
    private let iconView = NSImageView()
    private let headline = NSTextField(labelWithString: "")
    private let lead = NSTextField(wrappingLabelWithString: "")

    private let pairingFace = NSStackView()
    private let statusFace = NSStackView()

    // MARK: - pairing face

    private let inputScroll: NSScrollView
    private let input: NSTextView
    private let inputPlaceholder = NSTextField(labelWithString: "")
    private let recognisedLabel = NSTextField(wrappingLabelWithString: "")

    private let detailsToggle = NSButton()
    private let detailsGrid = NSGridView()
    private let serverField = NSTextField()
    private let nameField = NSTextField()
    private let sshPortField = NSTextField()
    private let proxyField = NSTextField()

    private let remoteLoginBanner = NSStackView()
    private let remoteLoginText = NSTextField(wrappingLabelWithString: "")
    private let openSharingButton = NSButton()

    private let noPasswordNote = NSTextField(wrappingLabelWithString: "")
    private let pairingStatus = NSTextField(wrappingLabelWithString: "")
    private let launchAtLoginCheckbox = NSButton()
    private let spinner = NSProgressIndicator()
    private let connectButton = NSButton()
    private let cancelRepairButton = NSButton()

    // MARK: - status face

    private let statusGrid = NSGridView()
    private let statusNameValue = NSTextField(labelWithString: "")
    private let statusServerValue = NSTextField(labelWithString: "")
    private let statusPortValue = NSTextField(labelWithString: "")
    private let statusProxyValue = NSTextField(labelWithString: "")
    private var statusProxyRow: NSGridRow!
    private let statusAdvice = NSTextField(wrappingLabelWithString: "")
    private let statusSharingButton = NSButton()
    private let repairButton = NSButton()
    private let pauseButton = NSButton()
    private let logButton = NSButton()

    // MARK: - state

    private var face: Face = .pairing
    private var busy = false
    private var remoteLoginOn = false
    private var recognised: Pairing.Recognised = .nothing
    private var lastState: TunnelSupervisor.State = .idle
    /// The last clipboard text we auto-read, so a window that regains focus
    /// does not keep re-offering the same stale clipboard.
    private var clipboardSeen = ""

    // MARK: - construction

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                                  width: SetupWindowController.contentWidth,
                                                  height: 420),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = L("app.name")
        window.isReleasedWhenClosed = false
        window.center()

        // Local first: a stored property cannot be read back before super.init.
        let scroll = NSTextView.scrollableTextView()
        inputScroll = scroll
        input = scroll.documentView as! NSTextView

        super.init(window: window)
        window.delegate = self
        buildContent()
        loadFromConfig()
    }

    required init?(coder: NSCoder) {
        fatalError("SetupWindowController is code-only")
    }

    // MARK: - layout

    private func buildContent() {
        guard let window = self.window else { return }

        // --- header: icon + headline + one line of lead ---------------------
        iconView.image = NSImage(systemSymbolName: "link.circle.fill", accessibilityDescription: nil)
        iconView.contentTintColor = .controlAccentColor
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        iconView.imageScaling = .scaleProportionallyUpOrDown

        headline.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        lead.font = NSFont.systemFont(ofSize: 12)
        lead.textColor = .secondaryLabelColor
        lead.maximumNumberOfLines = 2

        let headerText = NSStackView(views: [headline, lead])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 3

        let header = NSStackView(views: [iconView, headerText])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 14

        buildPairingFace()
        buildStatusFace()

        root.addArrangedSubview(header)
        root.addArrangedSubview(pairingFace)
        root.addArrangedSubview(statusFace)
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(root)
        window.contentView = content
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: SetupWindowController.contentWidth),
            iconView.widthAnchor.constraint(equalToConstant: 44),
            iconView.heightAnchor.constraint(equalToConstant: 44),
            lead.widthAnchor.constraint(equalToConstant: 410),
            pairingFace.widthAnchor.constraint(equalToConstant: SetupWindowController.bodyWidth),
            statusFace.widthAnchor.constraint(equalToConstant: SetupWindowController.bodyWidth)
        ])
    }

    private func buildPairingFace() {
        let width = SetupWindowController.bodyWidth
        pairingFace.orientation = .vertical
        pairingFace.alignment = .leading
        pairingFace.spacing = 12

        // --- the one box -----------------------------------------------------
        input.delegate = self
        input.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        input.isRichText = false
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        input.isAutomaticTextReplacementEnabled = false
        input.isAutomaticSpellingCorrectionEnabled = false
        input.textContainerInset = NSSize(width: 8, height: 8)
        input.isVerticallyResizable = true
        input.isHorizontallyResizable = false
        input.textContainer?.widthTracksTextView = true
        inputScroll.hasVerticalScroller = true
        inputScroll.borderType = .noBorder
        inputScroll.wantsLayer = true
        inputScroll.layer?.cornerRadius = 8
        inputScroll.layer?.masksToBounds = true
        inputScroll.layer?.borderWidth = 1
        inputScroll.layer?.borderColor = NSColor.separatorColor.cgColor
        inputScroll.translatesAutoresizingMaskIntoConstraints = false

        inputPlaceholder.stringValue = L("setup.inputPlaceholder")
        inputPlaceholder.textColor = .placeholderTextColor
        inputPlaceholder.font = NSFont.systemFont(ofSize: 13)
        inputPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        inputScroll.addSubview(inputPlaceholder)

        recognisedLabel.font = NSFont.systemFont(ofSize: 12)
        recognisedLabel.textColor = .secondaryLabelColor
        recognisedLabel.maximumNumberOfLines = 3

        // --- details, folded ----------------------------------------------------
        detailsToggle.setButtonType(.onOff)
        detailsToggle.bezelStyle = .disclosure
        detailsToggle.title = ""
        detailsToggle.state = .off
        detailsToggle.target = self
        detailsToggle.action = #selector(toggleDetails)
        let detailsTitle = NSTextField(labelWithString: L("setup.details"))
        detailsTitle.font = NSFont.systemFont(ofSize: 12)
        detailsTitle.textColor = .secondaryLabelColor
        let detailsHeader = NSStackView(views: [detailsToggle, detailsTitle])
        detailsHeader.orientation = .horizontal
        detailsHeader.alignment = .centerY
        detailsHeader.spacing = 2

        serverField.placeholderString = Config.defaultServerHost
        nameField.placeholderString = "mbp"
        nameField.target = self
        nameField.action = #selector(nameEdited)
        sshPortField.placeholderString = "22"
        proxyField.placeholderString = "nc -X connect -x proxy:8080 %h %p"
        proxyField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        detailsGrid.addRow(with: [gridLabel(L("setup.serverHost")), serverField])
        detailsGrid.addRow(with: [gridLabel(L("setup.macName")), nameField])
        detailsGrid.addRow(with: [gridLabel(L("setup.serverSSHPort")), sshPortField])
        detailsGrid.addRow(with: [gridLabel(L("setup.proxyCommand")), proxyField])
        detailsGrid.rowSpacing = 8
        detailsGrid.columnSpacing = 10
        detailsGrid.column(at: 0).xPlacement = .trailing
        detailsGrid.column(at: 1).xPlacement = .fill
        detailsGrid.column(at: 1).width = 330
        detailsGrid.cell(atColumnIndex: 1, rowIndex: 2).xPlacement = .leading
        detailsGrid.isHidden = true

        // --- Remote Login, shown only when it is the problem ---------------------
        remoteLoginText.font = NSFont.systemFont(ofSize: 12)
        remoteLoginText.maximumNumberOfLines = 2
        remoteLoginText.stringValue = L("setup.remoteLoginBanner")
        openSharingButton.title = L("setup.openSharing")
        openSharingButton.bezelStyle = .rounded
        openSharingButton.controlSize = .small
        openSharingButton.target = self
        openSharingButton.action = #selector(openSharing)
        let warning = NSImageView()
        warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        warning.contentTintColor = .systemOrange
        remoteLoginBanner.addArrangedSubview(warning)
        remoteLoginBanner.addArrangedSubview(remoteLoginText)
        remoteLoginBanner.addArrangedSubview(openSharingButton)
        remoteLoginBanner.orientation = .horizontal
        remoteLoginBanner.alignment = .centerY
        remoteLoginBanner.spacing = 8
        remoteLoginBanner.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        remoteLoginBanner.wantsLayer = true
        remoteLoginBanner.layer?.cornerRadius = 8
        remoteLoginBanner.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
        remoteLoginBanner.isHidden = true

        // --- footer -------------------------------------------------------------
        noPasswordNote.stringValue = L("setup.noPassword")
        noPasswordNote.font = NSFont.systemFont(ofSize: 11)
        noPasswordNote.textColor = .tertiaryLabelColor
        noPasswordNote.maximumNumberOfLines = 2

        pairingStatus.font = NSFont.systemFont(ofSize: 12)
        pairingStatus.textColor = .secondaryLabelColor
        pairingStatus.maximumNumberOfLines = 5
        pairingStatus.isHidden = true

        launchAtLoginCheckbox.setButtonType(.switch)
        launchAtLoginCheckbox.title = L("setup.launchAtLogin")
        launchAtLoginCheckbox.font = NSFont.systemFont(ofSize: 12)
        launchAtLoginCheckbox.state = .on

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        cancelRepairButton.title = L("setup.cancel")
        cancelRepairButton.bezelStyle = .rounded
        cancelRepairButton.target = self
        cancelRepairButton.action = #selector(cancelRepair)
        cancelRepairButton.isHidden = true

        connectButton.title = L("setup.connect")
        connectButton.bezelStyle = .rounded
        connectButton.controlSize = .large
        connectButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(connect)
        connectButton.isEnabled = false

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        buttons.addView(launchAtLoginCheckbox, in: .leading)
        buttons.addView(spinner, in: .trailing)
        buttons.addView(cancelRepairButton, in: .trailing)
        buttons.addView(connectButton, in: .trailing)

        for view in [inputScroll, recognisedLabel, detailsHeader, detailsGrid,
                     remoteLoginBanner, pairingStatus, noPasswordNote, buttons] {
            pairingFace.addArrangedSubview(view)
        }
        pairingFace.setCustomSpacing(6, after: inputScroll)
        pairingFace.setCustomSpacing(4, after: detailsHeader)

        NSLayoutConstraint.activate([
            inputScroll.widthAnchor.constraint(equalToConstant: width),
            inputScroll.heightAnchor.constraint(equalToConstant: 88),
            inputPlaceholder.leadingAnchor.constraint(equalTo: inputScroll.leadingAnchor, constant: 13),
            inputPlaceholder.topAnchor.constraint(equalTo: inputScroll.topAnchor, constant: 8),
            recognisedLabel.widthAnchor.constraint(equalToConstant: width),
            remoteLoginBanner.widthAnchor.constraint(equalToConstant: width),
            remoteLoginText.widthAnchor.constraint(equalToConstant: 280),
            pairingStatus.widthAnchor.constraint(equalToConstant: width),
            noPasswordNote.widthAnchor.constraint(equalToConstant: width),
            buttons.widthAnchor.constraint(equalToConstant: width),
            sshPortField.widthAnchor.constraint(equalToConstant: 80)
        ])
    }

    private func buildStatusFace() {
        let width = SetupWindowController.bodyWidth
        statusFace.orientation = .vertical
        statusFace.alignment = .leading
        statusFace.spacing = 14

        for value in [statusNameValue, statusServerValue, statusPortValue, statusProxyValue] {
            value.font = NSFont.systemFont(ofSize: 13)
            value.isSelectable = true
        }
        statusProxyValue.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statusProxyValue.lineBreakMode = .byTruncatingMiddle

        statusGrid.addRow(with: [gridLabel(L("status.name")), statusNameValue])
        statusGrid.addRow(with: [gridLabel(L("status.server")), statusServerValue])
        statusGrid.addRow(with: [gridLabel(L("status.port")), statusPortValue])
        statusProxyRow = statusGrid.addRow(with: [gridLabel(L("setup.proxyCommand")), statusProxyValue])
        statusGrid.rowSpacing = 6
        statusGrid.columnSpacing = 12
        statusGrid.column(at: 0).xPlacement = .trailing

        statusAdvice.font = NSFont.systemFont(ofSize: 12)
        statusAdvice.maximumNumberOfLines = 4
        statusAdvice.isHidden = true

        statusSharingButton.title = L("setup.openSharing")
        statusSharingButton.bezelStyle = .rounded
        statusSharingButton.controlSize = .small
        statusSharingButton.target = self
        statusSharingButton.action = #selector(openSharing)
        statusSharingButton.isHidden = true

        repairButton.title = L("setup.repair")
        repairButton.bezelStyle = .rounded
        repairButton.target = self
        repairButton.action = #selector(beginRepair)

        pauseButton.bezelStyle = .rounded
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)

        logButton.title = L("menu.openLog")
        logButton.bezelStyle = .rounded
        logButton.target = self
        logButton.action = #selector(openLog)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        buttons.addView(repairButton, in: .leading)
        buttons.addView(logButton, in: .trailing)
        buttons.addView(pauseButton, in: .trailing)

        for view in [statusGrid, statusAdvice, statusSharingButton, buttons] {
            statusFace.addArrangedSubview(view)
        }
        statusFace.setCustomSpacing(6, after: statusAdvice)

        NSLayoutConstraint.activate([
            statusAdvice.widthAnchor.constraint(equalToConstant: width),
            statusProxyValue.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            buttons.widthAnchor.constraint(equalToConstant: width)
        ])
    }

    private func gridLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }

    // MARK: - faces

    private func show(_ face: Face) {
        self.face = face
        pairingFace.isHidden = face != .pairing
        statusFace.isHidden = face != .status
        renderHeader()
        fitWindow()
        if face == .pairing {
            window?.makeFirstResponder(input)
        }
    }

    /// The window is exactly as tall as what it shows: no empty band under a
    /// folded section, no clipped banner when one appears.
    private func fitWindow() {
        guard let window = window else { return }
        root.layoutSubtreeIfNeeded()
        let size = root.fittingSize
        window.setContentSize(NSSize(width: SetupWindowController.contentWidth, height: size.height))
    }

    private func renderHeader() {
        let config = ConfigStore.shared.current
        switch face {
        case .pairing:
            iconView.image = NSImage(systemSymbolName: "link.circle.fill", accessibilityDescription: nil)
            iconView.contentTintColor = .controlAccentColor
            headline.stringValue = config.enrolled ? L("setup.repairHeadline") : L("setup.headline")
            lead.stringValue = L("setup.lead")
        case .status:
            let symbol: String
            let tint: NSColor
            switch lastState.appearance {
            case .connected: symbol = "checkmark.circle.fill";                 tint = .systemGreen
            case .working:   symbol = "arrow.triangle.2.circlepath.circle.fill"; tint = .controlAccentColor
            case .stopped:   symbol = "pause.circle.fill";                     tint = .systemGray
            case .problem:   symbol = "exclamationmark.triangle.fill";         tint = .systemOrange
            }
            iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            iconView.contentTintColor = tint
            headline.stringValue = StatusItemController.statusLine(for: lastState)
            switch lastState {
            case .connected: lead.stringValue = L("status.lead.connected")
            case .paused:    lead.stringValue = L("status.lead.paused")
            case .failed:    lead.stringValue = L("status.lead.failed")
            default:         lead.stringValue = L("status.lead.working")
            }
        }
    }

    /// Called by the AppDelegate on every supervisor state change and on the
    /// 5-second heartbeat, so "connected · 3m" stays honest while visible.
    func render(state: TunnelSupervisor.State) {
        lastState = state
        guard let window = window, window.isVisible, face == .status else { return }
        renderStatusFace()
    }

    private func renderStatusFace() {
        let config = ConfigStore.shared.current
        renderHeader()
        statusNameValue.stringValue = config.macName
        statusServerValue.stringValue = config.serverSSHPort == Config.defaultServerSSHPort
            ? config.serverHost
            : "\(config.serverHost):\(config.serverSSHPort)"
        statusPortValue.stringValue = String(config.tunnelPort)
        let proxy = config.proxyCommand.trimmingCharacters(in: .whitespaces)
        statusProxyValue.stringValue = proxy
        statusProxyRow.isHidden = proxy.isEmpty

        if case .failed(let failure) = lastState {
            statusAdvice.stringValue = failure.nextStep(config: config)
            statusAdvice.textColor = .labelColor
            statusAdvice.isHidden = false
            statusSharingButton.isHidden = failure != .remoteLoginOff
        } else {
            statusAdvice.isHidden = true
            statusSharingButton.isHidden = true
        }

        let paused: Bool
        if case .paused = lastState { paused = true } else { paused = config.paused }
        pauseButton.title = paused ? L("menu.resume") : L("menu.pause")

        fitWindow()
    }

    // MARK: - lifecycle

    func present() {
        loadFromConfig()
        if ConfigStore.shared.current.enrolled {
            cancelRepairButton.isHidden = true
            lastState = TunnelSupervisor.shared.currentState
            show(.status)
            renderStatusFace()
        } else {
            show(.pairing)
            refreshRemoteLogin()
            readClipboardIfUseful()
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if face == .pairing {
            refreshRemoteLogin()
            readClipboardIfUseful()
        }
    }

    private func loadFromConfig() {
        let config = ConfigStore.shared.current
        serverField.stringValue = config.serverHost
        nameField.stringValue = config.macName
        sshPortField.stringValue = config.serverSSHPort == Config.defaultServerSSHPort
            ? "" : String(config.serverSSHPort)
        proxyField.stringValue = config.proxyCommand
        if !config.proxyCommand.isEmpty || config.serverSSHPort != Config.defaultServerSSHPort {
            setDetails(expanded: true)
        }
        switch LoginItem.status() {
        case .enabled, .requiresApproval:
            launchAtLoginCheckbox.state = .on
        case .disabled:
            launchAtLoginCheckbox.state = config.launchAtLogin ? .on : .off
        case .unavailable:
            launchAtLoginCheckbox.state = .off
            launchAtLoginCheckbox.isEnabled = false
        }
    }

    // MARK: - the one box

    /// If the clipboard holds something `mac setup` printed, use it — but only
    /// while the box is empty. Never overwrite what the user typed.
    private func readClipboardIfUseful() {
        guard input.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let text = NSPasteboard.general.string(forType: .string),
              text != clipboardSeen else { return }
        clipboardSeen = text
        switch Pairing.recognise(text, fallbackHost: currentHost()) {
        case .block, .code:
            input.string = text.trimmingCharacters(in: .whitespacesAndNewlines)
            inputDidChange()
            setStatus(L("setup.tookClipboard"), isError: false)
        default:
            break
        }
    }

    func textDidChange(_ notification: Notification) {
        inputDidChange()
    }

    private func currentHost() -> String {
        let typed = serverField.stringValue.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? ConfigStore.shared.current.serverHost : typed
    }

    private func inputDidChange() {
        let text = input.string
        inputPlaceholder.isHidden = !text.isEmpty
        recognised = Pairing.recognise(text, fallbackHost: currentHost())

        switch recognised {
        case .nothing:
            recognisedLabel.stringValue = ""
            recognisedLabel.textColor = .secondaryLabelColor
        case .code:
            recognisedLabel.stringValue = Lf("setup.recognisedCode",
                                             Config.sanitize(name: nameField.stringValue),
                                             currentHost())
            recognisedLabel.textColor = .secondaryLabelColor
        case .block(let request):
            // The block knows better than the remembered defaults.
            serverField.stringValue = request.serverHost
            nameField.stringValue = request.macName
            if request.serverSSHPort != Config.defaultServerSSHPort {
                sshPortField.stringValue = String(request.serverSSHPort)
                setDetails(expanded: true)
            }
            if !request.proxyCommand.isEmpty {
                proxyField.stringValue = request.proxyCommand
                setDetails(expanded: true)
            }
            recognisedLabel.stringValue = Lf("setup.recognisedBlock",
                                             request.macName, request.serverHost, request.tunnelPort)
            recognisedLabel.textColor = .secondaryLabelColor
        case .invalid(let error):
            // The problem is *in the box*, so it is said right under the box.
            recognisedLabel.stringValue = message(for: error)
            recognisedLabel.textColor = .systemRed
        }
        refreshConnectButton()
        fitWindow()
    }

    private func refreshConnectButton() {
        let usable: Bool
        switch recognised {
        case .block, .code: usable = true
        default:            usable = false
        }
        connectButton.isEnabled = usable && !busy
    }

    // MARK: - actions

    @objc private func toggleDetails() {
        setDetails(expanded: detailsToggle.state == .on)
    }

    private func setDetails(expanded: Bool) {
        detailsToggle.state = expanded ? .on : .off
        detailsGrid.isHidden = !expanded
        fitWindow()
    }

    @objc private func nameEdited() {
        let cleaned = Config.sanitize(name: nameField.stringValue)
        if cleaned != nameField.stringValue {
            nameField.stringValue = cleaned
        }
        inputDidChange()
    }

    @objc private func openSharing() {
        if !RemoteLoginCheck.openSharingSettings() {
            setStatus(L("next.remoteLoginOff"), isError: true)
        }
    }

    @objc private func refreshRemoteLogin() {
        RemoteLoginCheck.check { [weak self] isOn in
            guard let self = self else { return }
            self.remoteLoginOn = isOn
            if self.remoteLoginBanner.isHidden != isOn {
                self.remoteLoginBanner.isHidden = isOn
                self.fitWindow()
            }
        }
    }

    @objc private func beginRepair() {
        input.string = ""
        clipboardSeen = ""
        inputDidChange()
        setStatus("", isError: false)
        cancelRepairButton.isHidden = false
        show(.pairing)
        refreshRemoteLogin()
        readClipboardIfUseful()
    }

    @objc private func cancelRepair() {
        cancelRepairButton.isHidden = true
        lastState = TunnelSupervisor.shared.currentState
        show(.status)
        renderStatusFace()
    }

    @objc private func togglePause() {
        if ConfigStore.shared.current.paused {
            TunnelSupervisor.shared.resume()
        } else {
            TunnelSupervisor.shared.pause()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            self.lastState = TunnelSupervisor.shared.currentState
            self.renderStatusFace()
        }
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

    @objc private func connect() {
        guard !busy else { return }

        // Everything the form knows, folded into one request.
        let code: String
        var host = currentHost()
        var name = Config.sanitize(name: nameField.stringValue)
        var enrollHint = ""
        var claimedPort = ConfigStore.shared.current.tunnelPort
        switch recognised {
        case .code(let bare):
            code = bare
        case .block(let request):
            code = request.code
            host = request.serverHost
            name = request.macName
            enrollHint = request.enrollURL.absoluteString
            claimedPort = request.tunnelPort
        default:
            return
        }
        let proxy = proxyField.stringValue.trimmingCharacters(in: .whitespaces)
        let sshPortText = sshPortField.stringValue.trimmingCharacters(in: .whitespaces)
        let wantsLoginItem = launchAtLoginCheckbox.state == .on

        if host.isEmpty {
            failInDetails(L("err.emptyHost"), focus: serverField); return
        }
        guard Enroller.isValidHost(host) else {
            failInDetails(Lf("err.badHost", host), focus: serverField); return
        }
        if !Config.isValid(name: name) {
            failInDetails(Lf("err.badName", nameField.stringValue), focus: nameField); return
        }
        var sshPort = Config.defaultServerSSHPort
        if !sshPortText.isEmpty {
            guard let value = Int(sshPortText), value > 0, value <= 65535 else {
                failInDetails(Lf("err.badSSHPort", sshPortText), focus: sshPortField); return
            }
            sshPort = value
        }
        guard Enroller.isValidProxyCommand(proxy) else {
            failInDetails(L("err.badProxy"), focus: proxyField); return
        }
        // Hard gate. A tunnel to a Mac with Remote Login off is a tunnel to a
        // closed door.
        if !remoteLoginOn {
            setStatus(L("setup.blockedByRemoteLogin"), isError: true)
            remoteLoginBanner.isHidden = false
            fitWindow()
            refreshRemoteLogin()
            return
        }

        nameField.stringValue = name
        serverField.stringValue = host
        setBusy(true)
        setStatus(L("setup.working"), isError: false)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                if Enroller.standDownLegacyAgent(macName: name) {
                    DispatchQueue.main.async {
                        self.setStatus(L("setup.legacyAgentFound"), isError: false)
                    }
                }
                let url = try Pairing.enrollURL(from: enrollHint.isEmpty ? nil : enrollHint,
                                                host: host)
                let request = PairingRequest(macName: name,
                                             tunnelPort: claimedPort,
                                             serverHost: host,
                                             tunnelUser: Config.defaultTunnelUser,
                                             code: code,
                                             serverSSHPort: sshPort,
                                             proxyCommand: proxy,
                                             enrollURL: url)
                let installed = try Enroller.enroll(with: request)

                DispatchQueue.main.async {
                    // The code is spent; leaving it on screen only invites a
                    // second, now-useless attempt.
                    self.input.string = ""
                    self.inputDidChange()
                    self.nameField.stringValue = installed.macName
                    self.setStatus(Lf("setup.installedAs", installed.macName, installed.tunnelPort),
                                   isError: false)
                    if wantsLoginItem {
                        if let problem = LoginItem.set(true) {
                            Log.shared.write("launch at login not enabled: \(problem)")
                        } else {
                            ConfigStore.shared.update { $0.launchAtLogin = true }
                        }
                    }
                    TunnelSupervisor.shared.configChanged()
                }

                let outcome = self.waitForConnection(seconds: 30)
                DispatchQueue.main.async {
                    self.setBusy(false)
                    switch outcome {
                    case .connected:
                        // Done. The window now shows what it did, not the form
                        // it came from.
                        self.cancelRepairButton.isHidden = true
                        self.setStatus("", isError: false)
                        self.lastState = TunnelSupervisor.shared.currentState
                        self.show(.status)
                        self.renderStatusFace()
                    case .failed(let failure):
                        let config = ConfigStore.shared.current
                        self.setStatus(failure.summary + "\n" + failure.nextStep(config: config),
                                       isError: true)
                        // R10: when the network is the problem, the fields that
                        // fix it open by themselves and take the cursor.
                        switch failure {
                        case .serverUnreachable:
                            self.setDetails(expanded: true)
                            self.window?.makeFirstResponder(self.sshPortField)
                        case .proxyFailed:
                            self.setDetails(expanded: true)
                            self.window?.makeFirstResponder(self.proxyField)
                        case .remoteLoginOff:
                            self.remoteLoginBanner.isHidden = false
                            self.fitWindow()
                        default:
                            break
                        }
                    case .stillTrying:
                        self.setStatus(Lf("err.verifyTimeout", 30), isError: true)
                    }
                }
            } catch {
                let text = self.message(for: error)
                Log.shared.write("setup failed: \(text)")
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.setStatus(text, isError: true)
                    if case EnrollmentError.enrollUnreachable = error {
                        self.setDetails(expanded: true)
                    }
                }
            }
        }
    }

    /// A validation problem in a folded field is invisible until the fold
    /// opens, so open it and put the cursor on the offender.
    private func failInDetails(_ text: String, focus field: NSTextField) {
        setDetails(expanded: true)
        setStatus(text, isError: true)
        window?.makeFirstResponder(field)
    }

    private func message(for error: Error) -> String {
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private enum Outcome {
        case connected
        case failed(TunnelSupervisor.Failure)
        case stillTrying
    }

    /// Polls the supervisor rather than subscribing, so the window cannot leave
    /// a stale callback behind if it is closed mid-connect.
    private func waitForConnection(seconds: Int) -> Outcome {
        var waited = 0
        while waited < seconds * 2 {
            switch TunnelSupervisor.shared.currentState {
            case .connected:
                return .connected
            case .failed(let failure) where !failure.isRetryable:
                return .failed(failure)
            default:
                break
            }
            usleep(500_000)
            waited += 1
        }
        switch TunnelSupervisor.shared.currentState {
        case .connected:
            return .connected
        case .failed(let failure):
            return .failed(failure)
        default:
            return .stillTrying
        }
    }

    private func setBusy(_ value: Bool) {
        busy = value
        input.isEditable = !value
        serverField.isEnabled = !value
        nameField.isEnabled = !value
        sshPortField.isEnabled = !value
        proxyField.isEnabled = !value
        cancelRepairButton.isEnabled = !value
        refreshConnectButton()
        if value { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func setStatus(_ text: String, isError: Bool) {
        pairingStatus.stringValue = text
        pairingStatus.textColor = isError ? .systemRed : .secondaryLabelColor
        pairingStatus.isHidden = text.isEmpty
        fitWindow()
    }
}
