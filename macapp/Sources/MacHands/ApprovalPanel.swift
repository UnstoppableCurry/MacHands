import AppKit
import MacHandsCore

enum ApprovalOutcome {
    case once
    case hour
    case always
    case deny
    case timeout
}

struct ApprovalRequest {
    let requestId: String
    let agentId: String
    let agentName: String
    let method: String
    /// 命令原文 / 路径 / 要写进剪贴板的文字 —— 卡片上等宽显示的那一段。
    let subject: String
    let cwd: String?
    let fromIP: String?
}

/// 非激活浮动面板(SPEC §7.3)。这是 MacHands 最核心的一屏。
///
/// 铁律 5:**不抢焦点**。用 `orderFrontRegardless()` 出现,从不调
/// `NSApp.activate`,也不切换 Space —— 所以 `collectionBehavior` 里有
/// `.canJoinAllSpaces`:它跟着用户走,而不是把用户拽走。
///
/// 不抢焦点的代价是数字快捷键要先点一下卡才生效。所以:点卡片任意位置就拿到
/// 焦点(`becomesKeyOnlyIfNeeded = false` + `sendEvent` 兜底),拿到焦点前底下
/// 那行字写"点一下这张卡,就能用键盘",拿到之后才列出按键;有焦点时卡片描一圈
/// 强调色边,一眼分得清。
///
/// 一次只显示一条,后面的排队并在卡上写"还有 N 条"。120 秒没人动就 TIMEOUT。
/// 点了允许/拒绝之后卡片不是立刻消失,而是停 1.6 秒显示"已允许,命令正在执行"
/// 或"已拒绝,命令没有执行"——点了跟没点一样是最糟的反馈。
/// 视觉上是一张无边框圆角毛玻璃卡片,不是普通标题栏窗口。
final class ApprovalPanelController: NSObject {

    static let shared = ApprovalPanelController()

    static let timeoutSeconds: Int = 120
    /// 决定之后卡片停留多久再收起(或换下一张)。
    static let settleSeconds: TimeInterval = 1.6

    private final class Panel: NSPanel {
        var onEscape: (() -> Void)?

        /// 非激活面板要能成为 key window(点一下就能用数字键)。
        override var canBecomeKey: Bool { return true }
        override var canBecomeMain: Bool { return false }

        /// 点卡片任意位置即取得焦点。铁律 5 禁止的是我们**主动**抢,用户点了是他要的。
        override func sendEvent(_ event: NSEvent) {
            if event.type == .leftMouseDown, !isKeyWindow { makeKey() }
            super.sendEvent(event)
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {            // Esc
                onEscape?()
                return
            }
            super.keyDown(with: event)
        }
    }

    /// 毛玻璃底 + 一圈边:没焦点时是很淡的一圈,拿到焦点后换成强调色。
    private final class CardBackground: NSVisualEffectView {
        var focused = false { didSet { applyBorder() } }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyBorder()
        }

        func applyBorder() {
            layer?.borderWidth = focused ? 1.5 : 1
            layer?.borderColor = focused
                ? Theme.accentA.withAlphaComponent(0.85).cgColor
                : NSColor.labelColor.withAlphaComponent(0.14).cgColor
        }
    }

    private struct Pending {
        let request: ApprovalRequest
        let completion: (ApprovalOutcome) -> Void
    }

    // MARK: - 视图

    private var panel: Panel?
    private var background: CardBackground?
    private let root = NSStackView()
    private let badge = GradientBadge(symbolName: "hand.raised.fill", size: 28)
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")

    private let commandCard = CardView()
    private let subjectLabel = NSTextField(wrappingLabelWithString: "")
    private let expandButton = StyledButton(title: "", kind: .text(NSColor.secondaryLabelColor), size: 10.5, weight: .medium)

    private let riskRow = NSStackView()
    private let riskPill = PillLabel()
    private let riskLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")

    private let timeoutBar = NSProgressIndicator()
    private let metaRow = NSStackView()
    private let queueLabel = NSTextField(labelWithString: "")
    private let countdownLabel = NSTextField(labelWithString: "")

    private let onceButton = StyledButton(title: "", kind: .filled(Theme.accentA), size: 13, weight: .semibold)
    private let denyButton = StyledButton(title: "", kind: .soft, size: 13, weight: .semibold)
    private let hourButton = StyledButton(title: "", kind: .text(NSColor.secondaryLabelColor), size: 11.5, weight: .medium)
    private let alwaysButton = StyledButton(title: "", kind: .text(NSColor.secondaryLabelColor), size: 11.5, weight: .medium)
    private let mainRow = NSStackView()
    private let secondaryRow = NSStackView()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")

    private let resultRow = NSStackView()
    private let resultIcon = NSImageView()
    private let resultLabel = NSTextField(wrappingLabelWithString: "")

    // MARK: - 状态

    private var queue: [Pending] = []
    private var showing: Pending?
    private var expanded = false
    private var deadline: Date?
    private var tick: Timer?
    private var settleTimer: Timer?

    private static let width: CGFloat = 360
    private static let inset: CGFloat = 16
    private static var inner: CGFloat { return width - inset * 2 }

    // MARK: - 入口(必须在主线程)

    /// completion 一定会被调用一次,且一定在主线程上。
    func ask(_ request: ApprovalRequest, completion: @escaping (ApprovalOutcome) -> Void) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.ask(request, completion: completion) }
            return
        }
        queue.append(Pending(request: request, completion: completion))
        if showing == nil && settleTimer == nil { showNext() }
        else { renderQueueCount() }
    }

    /// 断线或撤销时把某个 agent 还挂着的卡全部拒掉。不走"停留 1.6 秒"那一步:
    /// 那是给用户自己点了之后看的,不是给断线看的。
    func cancelAll(agentId: String?, outcome: ApprovalOutcome = .deny) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.cancelAll(agentId: agentId, outcome: outcome) }
            return
        }
        let matching = queue.filter { agentId == nil || $0.request.agentId == agentId }
        queue = queue.filter { !(agentId == nil || $0.request.agentId == agentId) }
        for item in matching { item.completion(outcome) }
        if let current = showing, agentId == nil || current.request.agentId == agentId {
            finish(outcome, settle: false)
        } else {
            renderQueueCount()
        }
    }

    // MARK: - 构造

    private func buildPanelIfNeeded() -> Panel {
        if let existing = panel { return existing }

        let created = Panel(contentRect: NSRect(x: 0, y: 0,
                                                width: ApprovalPanelController.width, height: 200),
                            styleMask: [.nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        created.isFloatingPanel = true
        // false:点卡片上任何地方(包括空白处)都成为 key window,数字键立刻可用。
        created.becomesKeyOnlyIfNeeded = false
        created.hidesOnDeactivate = false
        created.worksWhenModal = true
        created.isReleasedWhenClosed = false
        created.level = .floating
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.onEscape = { [weak self] in self?.refuse() }

        let effect = CardBackground()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Theme.cardRadius + 2
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.applyBorder()
        background = effect

        let inner = ApprovalPanelController.inner
        let headerTextWidth = inner - 28 - 10

        // --- 头:谁、想干什么 ------------------------------------------------------
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.font = NSFont.systemFont(ofSize: 11.5)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.preferredMaxLayoutWidth = headerTextWidth

        let headerText = NSStackView(views: [titleLabel, subtitleLabel])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 1

        let headerRow = NSStackView(views: [badge, headerText])
        headerRow.orientation = .horizontal
        headerRow.alignment = .top
        headerRow.spacing = 10

        // --- 命令原文:等宽、最大对比 -------------------------------------------------
        subjectLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        subjectLabel.maximumNumberOfLines = 6
        subjectLabel.lineBreakMode = .byTruncatingTail
        subjectLabel.isSelectable = true
        subjectLabel.textColor = .labelColor
        subjectLabel.preferredMaxLayoutWidth = inner - 24
        // 命令那块底比卡片本身更实一点,字才"跳"得出来。
        commandCard.setTint(background: NSColor.labelColor.withAlphaComponent(0.07),
                            border: NSColor.labelColor.withAlphaComponent(0.12))
        commandCard.addSubview(subjectLabel)
        subjectLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            subjectLabel.leadingAnchor.constraint(equalTo: commandCard.leadingAnchor, constant: 12),
            subjectLabel.trailingAnchor.constraint(equalTo: commandCard.trailingAnchor, constant: -12),
            subjectLabel.topAnchor.constraint(equalTo: commandCard.topAnchor, constant: 10),
            subjectLabel.bottomAnchor.constraint(equalTo: commandCard.bottomAnchor, constant: -10)
        ])

        expandButton.target = self
        expandButton.action = #selector(toggleExpand)
        expandButton.isHidden = true

        // --- 风险档位:胶囊 + 一句话 ------------------------------------------------
        riskLabel.font = NSFont.systemFont(ofSize: 11.5)
        riskLabel.textColor = .secondaryLabelColor
        riskLabel.maximumNumberOfLines = 2
        riskLabel.preferredMaxLayoutWidth = inner - 80
        riskRow.orientation = .horizontal
        riskRow.alignment = .centerY
        riskRow.spacing = 8
        riskRow.addArrangedSubview(riskPill)
        riskRow.addArrangedSubview(riskLabel)

        detailLabel.font = NSFont.systemFont(ofSize: 10.5)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.preferredMaxLayoutWidth = inner

        // --- 倒计时 + 排队 ---------------------------------------------------------
        timeoutBar.style = .bar
        timeoutBar.isIndeterminate = false
        timeoutBar.minValue = 0
        timeoutBar.maxValue = Double(ApprovalPanelController.timeoutSeconds)
        timeoutBar.controlSize = .small

        queueLabel.font = NSFont.systemFont(ofSize: 10.5)
        queueLabel.textColor = .tertiaryLabelColor
        countdownLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        countdownLabel.textColor = .tertiaryLabelColor
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.addView(queueLabel, in: .leading)
        metaRow.addView(countdownLabel, in: .trailing)

        // --- 两颗主按钮 + 两个次要选项 -------------------------------------------
        onceButton.title = L("approval.allowThis")
        denyButton.title = L("approve.deny")
        hourButton.title = L("approve.hour")
        alwaysButton.title = L("approve.always")
        onceButton.keyEquivalent = "1"
        hourButton.keyEquivalent = "2"
        alwaysButton.keyEquivalent = "3"
        denyButton.keyEquivalent = "4"
        onceButton.target = self; onceButton.action = #selector(allowOnce)
        hourButton.target = self; hourButton.action = #selector(allowHour)
        alwaysButton.target = self; alwaysButton.action = #selector(allowAlways)
        denyButton.target = self; denyButton.action = #selector(refuse)

        mainRow.orientation = .horizontal
        mainRow.alignment = .centerY
        mainRow.spacing = 10
        mainRow.addArrangedSubview(onceButton)
        mainRow.addArrangedSubview(denyButton)

        secondaryRow.orientation = .horizontal
        secondaryRow.alignment = .centerY
        secondaryRow.spacing = 18
        secondaryRow.addArrangedSubview(hourButton)
        secondaryRow.addArrangedSubview(alwaysButton)

        hintLabel.font = NSFont.systemFont(ofSize: 10.5)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.maximumNumberOfLines = 2
        hintLabel.preferredMaxLayoutWidth = inner

        // --- 收尾态:对勾 / 叉号 + 一句结果 ------------------------------------------
        resultIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        resultLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        resultLabel.maximumNumberOfLines = 2
        resultLabel.preferredMaxLayoutWidth = inner - 32
        resultRow.orientation = .horizontal
        resultRow.alignment = .centerY
        resultRow.spacing = 8
        resultRow.addArrangedSubview(resultIcon)
        resultRow.addArrangedSubview(resultLabel)
        resultRow.isHidden = true

        // --- 叠起来 -------------------------------------------------------------------
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: ApprovalPanelController.inset, left: ApprovalPanelController.inset,
                                       bottom: ApprovalPanelController.inset, right: ApprovalPanelController.inset)
        root.translatesAutoresizingMaskIntoConstraints = false
        let stacked: [NSView] = [headerRow, commandCard, expandButton, riskRow, detailLabel,
                                 timeoutBar, metaRow, mainRow, secondaryRow, hintLabel, resultRow]
        for view in stacked { root.addArrangedSubview(view) }
        root.setCustomSpacing(6, after: commandCard)
        root.setCustomSpacing(6, after: expandButton)
        root.setCustomSpacing(4, after: riskRow)
        root.setCustomSpacing(3, after: timeoutBar)
        root.setCustomSpacing(12, after: metaRow)
        root.setCustomSpacing(6, after: mainRow)

        effect.addSubview(root)
        created.contentView = effect

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            root.topAnchor.constraint(equalTo: effect.topAnchor),
            root.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            headerRow.widthAnchor.constraint(equalToConstant: inner),
            headerText.widthAnchor.constraint(equalToConstant: headerTextWidth),
            commandCard.widthAnchor.constraint(equalToConstant: inner),
            riskRow.widthAnchor.constraint(equalToConstant: inner),
            detailLabel.widthAnchor.constraint(equalToConstant: inner),
            timeoutBar.widthAnchor.constraint(equalToConstant: inner),
            metaRow.widthAnchor.constraint(equalToConstant: inner),
            mainRow.widthAnchor.constraint(equalToConstant: inner),
            onceButton.heightAnchor.constraint(equalToConstant: 44),
            denyButton.heightAnchor.constraint(equalToConstant: 44),
            onceButton.widthAnchor.constraint(equalToConstant: 196),
            denyButton.widthAnchor.constraint(equalToConstant: inner - 196 - 10),
            hourButton.heightAnchor.constraint(equalToConstant: 22),
            alwaysButton.heightAnchor.constraint(equalToConstant: 22),
            hintLabel.widthAnchor.constraint(equalToConstant: inner),
            resultRow.widthAnchor.constraint(equalToConstant: inner)
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(focusChanged(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: created)
        NotificationCenter.default.addObserver(self, selector: #selector(focusChanged(_:)),
                                               name: NSWindow.didResignKeyNotification, object: created)

        panel = created
        return created
    }

    // MARK: - 显示

    private func showNext() {
        tick?.invalidate()
        tick = nil
        settleTimer?.invalidate()
        settleTimer = nil
        guard !queue.isEmpty else {
            showing = nil
            panel?.orderOut(nil)
            return
        }
        let next = queue.removeFirst()
        showing = next
        expanded = false
        deadline = Date().addingTimeInterval(TimeInterval(ApprovalPanelController.timeoutSeconds))

        let created = buildPanelIfNeeded()
        render(next.request)
        setDecisionUI(visible: true)
        renderFocus()
        fit(created)
        placeTopRight(created)
        created.orderFrontRegardless()      // 绝不 activate

        Notifier.post(title: Lf("notify.approval.title", next.request.agentName),
                      body: AuditLog.clip(next.request.subject))

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.onTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func render(_ request: ApprovalRequest) {
        titleLabel.stringValue = request.agentName
        var subtitle = request.method == "run"
            ? L("approve.titleShort")
            : Lf("approve.titleGenericShort", request.method)
        if let ip = request.fromIP, !ip.isEmpty {
            subtitle += "  ·  \(L("approve.from")) \(ip)"
        }
        subtitleLabel.stringValue = subtitle

        subjectLabel.stringValue = request.subject.isEmpty ? request.method : request.subject
        subjectLabel.maximumNumberOfLines = expanded ? 0 : 6

        let lineCount = subjectLabel.stringValue.split(separator: "\n",
                                                       omittingEmptySubsequences: false).count
        expandButton.isHidden = lineCount <= 6 && subjectLabel.stringValue.count < 300
        expandButton.title = expanded ? L("approve.collapse") : L("approve.expand")

        let level = ApprovalRisk.classify(method: request.method, subject: request.subject)
        riskPill.set(text: L(ApprovalPanelController.pillKey(level)),
                     tint: ApprovalPanelController.tint(level))
        riskLabel.stringValue = L(ApprovalPanelController.explanationKey(method: request.method, level: level))

        if let cwd = request.cwd, !cwd.isEmpty {
            detailLabel.stringValue = "\(L("approve.cwd")) \(cwd)"
            detailLabel.isHidden = false
        } else {
            detailLabel.stringValue = ""
            detailLabel.isHidden = true
        }

        timeoutBar.doubleValue = Double(ApprovalPanelController.timeoutSeconds)
        countdownLabel.stringValue = Lf("approve.timeout", ApprovalPanelController.timeoutSeconds)
        renderQueueCount()
    }

    static func pillKey(_ level: ApprovalRiskLevel) -> String {
        switch level {
        case .readOnly: return "approval.risk.read"
        case .writes:   return "approval.risk.write"
        case .deletes:  return "approval.risk.delete"
        }
    }

    static func tint(_ level: ApprovalRiskLevel) -> NSColor {
        switch level {
        case .readOnly: return Theme.accentA
        case .writes:   return Theme.warning
        case .deletes:  return Theme.danger
        }
    }

    /// 一句说明按"方法 × 档位"挑,挑不到就用档位的通用那句。
    static func explanationKey(method: String, level: ApprovalRiskLevel) -> String {
        switch (level, method) {
        case (.readOnly, "fs.get"), (.readOnly, "fs.ls"):           return "approval.risk.explain.read.fs"
        case (.readOnly, "screen.shot"), (.readOnly, "screen.list"): return "approval.risk.explain.read.screen"
        case (.readOnly, "clip.get"):                                return "approval.risk.explain.read.clip"
        case (.readOnly, "sys.info"):                                return "approval.risk.explain.read.sys"
        case (.readOnly, _):                                         return "approval.risk.explain.read"
        case (.writes, "fs.put"):                                    return "approval.risk.explain.write.fs"
        case (.writes, "open"):                                      return "approval.risk.explain.write.open"
        case (.writes, "clip.set"):                                  return "approval.risk.explain.write.clip"
        case (.writes, _):                                           return "approval.risk.explain.write"
        case (.deletes, _):                                          return "approval.risk.explain.delete"
        }
    }

    private func renderQueueCount() {
        queueLabel.stringValue = queue.isEmpty ? "" : Lf("approve.more", queue.count)
    }

    /// 有焦点:列按键;没焦点:告诉人怎么拿到焦点。卡片边框跟着换色。
    private func renderFocus() {
        let focused = panel?.isKeyWindow ?? false
        background?.focused = focused
        hintLabel.stringValue = focused ? L("approval.keysHint") : L("approval.focusHint")
    }

    @objc private func focusChanged(_ note: Notification) {
        renderFocus()
    }

    /// 决定前:按钮、按键提示、倒计时;决定后:换成一行结果。
    private func setDecisionUI(visible: Bool) {
        mainRow.isHidden = !visible
        secondaryRow.isHidden = !visible
        hintLabel.isHidden = !visible
        timeoutBar.isHidden = !visible
        countdownLabel.isHidden = !visible
        for button in [onceButton, denyButton, hourButton, alwaysButton] {
            button.isEnabled = visible
        }
        resultRow.isHidden = visible
    }

    private func showSettled(_ outcome: ApprovalOutcome) {
        let allowed: Bool
        let text: String
        switch outcome {
        case .once:    allowed = true;  text = L("approval.doneAllowed")
        case .hour:    allowed = true;  text = L("approval.doneAllowedHour")
        case .always:  allowed = true;  text = L("approval.doneAllowedAlways")
        case .deny:    allowed = false; text = L("approval.doneDenied")
        case .timeout: allowed = false; text = L("approval.doneTimeout")
        }
        resultIcon.image = NSImage(systemSymbolName: allowed ? "checkmark.circle.fill" : "xmark.circle.fill",
                                   accessibilityDescription: text)
        resultIcon.contentTintColor = allowed ? Theme.accentA : Theme.danger
        resultLabel.stringValue = text
        setDecisionUI(visible: false)
    }

    private func fit(_ window: NSWindow) {
        root.layoutSubtreeIfNeeded()
        let height = root.fittingSize.height
        window.setContentSize(NSSize(width: ApprovalPanelController.width, height: height))
        root.layoutSubtreeIfNeeded()
    }

    private func placeTopRight(_ window: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let origin = NSPoint(x: visible.maxX - size.width - 16,
                             y: visible.maxY - size.height - 16)
        window.setFrameOrigin(origin)
    }

    private func onTick() {
        guard let deadline = deadline else { return }
        let left = deadline.timeIntervalSinceNow
        if left <= 0 {
            finish(.timeout)
        } else {
            timeoutBar.doubleValue = left
            countdownLabel.stringValue = Lf("approve.timeout", Int(left.rounded(.up)))
            renderQueueCount()
        }
    }

    /// `settle` 为真时先把结果亮 1.6 秒再收;断线/撤销那种不是用户点的,直接收。
    private func finish(_ outcome: ApprovalOutcome, settle: Bool = true) {
        tick?.invalidate()
        tick = nil
        deadline = nil
        guard let current = showing else { return }
        showing = nil
        current.completion(outcome)

        guard settle, let created = panel, created.isVisible else {
            showNext()
            return
        }
        showSettled(outcome)
        fit(created)
        placeTopRight(created)
        let timer = Timer(timeInterval: ApprovalPanelController.settleSeconds, repeats: false) { [weak self] _ in
            self?.settleTimer = nil
            self?.showNext()
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    // MARK: - 按钮

    @objc private func allowOnce() { if showing != nil { finish(.once) } }
    @objc private func allowHour() { if showing != nil { finish(.hour) } }
    @objc private func allowAlways() { if showing != nil { finish(.always) } }
    @objc private func refuse() { if showing != nil { finish(.deny) } }

    @objc private func toggleExpand() {
        expanded.toggle()
        guard let current = showing, let created = panel else { return }
        render(current.request)
        fit(created)
        placeTopRight(created)
    }
}
