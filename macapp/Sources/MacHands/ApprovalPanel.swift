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

/// 非激活浮动面板(SPEC §7.3)。
///
/// 铁律 5:**不抢焦点**。用 `orderFrontRegardless()` 出现,从不调
/// `NSApp.activate`,也不切换 Space —— 所以 `collectionBehavior` 里有
/// `.canJoinAllSpaces`:它跟着用户走,而不是把用户拽走。
///
/// 一次只显示一条,后面的排队并在卡上写"还有 N 条"。120 秒没人动就 TIMEOUT。
/// 视觉上是一张无边框圆角毛玻璃卡片,不是普通标题栏窗口。
final class ApprovalPanelController: NSObject {

    static let shared = ApprovalPanelController()

    static let timeoutSeconds: Int = 120

    private final class Panel: NSPanel {
        /// 非激活面板默认也能成为 key window(点一下就能用数字键),
        /// 但显式写出来免得依赖 styleMask 的隐含行为。
        override var canBecomeKey: Bool { return true }
        override var canBecomeMain: Bool { return false }
    }

    private struct Pending {
        let request: ApprovalRequest
        let completion: (ApprovalOutcome) -> Void
    }

    // MARK: - 视图

    private var panel: Panel?
    private let root = NSStackView()
    private let badge = GradientBadge(symbolName: "hand.raised.fill", size: 26)
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")

    private let commandCard = CardView()
    private let subjectLabel = NSTextField(wrappingLabelWithString: "")
    private let expandButton = StyledButton(title: "", kind: .outline, size: 10.5, weight: .medium)
    private let detailLabel = NSTextField(wrappingLabelWithString: "")

    private let timeoutBar = NSProgressIndicator()
    private let queueLabel = NSTextField(labelWithString: "")

    private let onceButton = StyledButton(title: "", kind: .filled(Theme.accentA), size: 12, weight: .semibold)
    private let hourButton = StyledButton(title: "", kind: .outline, size: 12, weight: .medium)
    private let alwaysButton = StyledButton(title: "", kind: .tinted(Theme.accentB), size: 12, weight: .medium)
    private let denyButton = StyledButton(title: "", kind: .tinted(Theme.danger), size: 12, weight: .semibold)

    // MARK: - 状态

    private var queue: [Pending] = []
    private var showing: Pending?
    private var expanded = false
    private var deadline: Date?
    private var tick: Timer?

    private static let width: CGFloat = 360

    // MARK: - 入口(必须在主线程)

    /// completion 一定会被调用一次,且一定在主线程上。
    func ask(_ request: ApprovalRequest, completion: @escaping (ApprovalOutcome) -> Void) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.ask(request, completion: completion) }
            return
        }
        queue.append(Pending(request: request, completion: completion))
        if showing == nil { showNext() }
        else { renderQueueCount() }
    }

    /// 断线或撤销时把某个 agent 还挂着的卡全部拒掉。
    func cancelAll(agentId: String?, outcome: ApprovalOutcome = .deny) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.cancelAll(agentId: agentId, outcome: outcome) }
            return
        }
        let matching = queue.filter { agentId == nil || $0.request.agentId == agentId }
        queue = queue.filter { !(agentId == nil || $0.request.agentId == agentId) }
        for item in matching { item.completion(outcome) }
        if let current = showing, agentId == nil || current.request.agentId == agentId {
            finish(outcome)
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
        created.becomesKeyOnlyIfNeeded = true
        created.hidesOnDeactivate = false
        created.worksWhenModal = true
        created.isReleasedWhenClosed = false
        created.level = .floating
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Theme.cardRadius + 2
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        titleLabel.font = NSFont.systemFont(ofSize: 13.5, weight: .bold)
        titleLabel.maximumNumberOfLines = 2

        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 1

        let headerText = NSStackView(views: [titleLabel, subtitleLabel])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 2

        let headerRow = NSStackView(views: [badge, headerText])
        headerRow.orientation = .horizontal
        headerRow.alignment = .top
        headerRow.spacing = 10

        subjectLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        subjectLabel.maximumNumberOfLines = 6
        subjectLabel.lineBreakMode = .byTruncatingTail
        subjectLabel.isSelectable = true
        subjectLabel.textColor = .labelColor
        commandCard.addSubview(subjectLabel)
        subjectLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            subjectLabel.leadingAnchor.constraint(equalTo: commandCard.leadingAnchor, constant: 11),
            subjectLabel.trailingAnchor.constraint(equalTo: commandCard.trailingAnchor, constant: -11),
            subjectLabel.topAnchor.constraint(equalTo: commandCard.topAnchor, constant: 9),
            subjectLabel.bottomAnchor.constraint(equalTo: commandCard.bottomAnchor, constant: -9)
        ])

        expandButton.target = self
        expandButton.action = #selector(toggleExpand)
        expandButton.isHidden = true

        detailLabel.font = NSFont.systemFont(ofSize: 10.5)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.maximumNumberOfLines = 3

        timeoutBar.style = .bar
        timeoutBar.isIndeterminate = false
        timeoutBar.minValue = 0
        timeoutBar.maxValue = Double(ApprovalPanelController.timeoutSeconds)
        timeoutBar.controlSize = .small

        queueLabel.font = NSFont.systemFont(ofSize: 10.5)
        queueLabel.textColor = .tertiaryLabelColor

        configure(onceButton, title: L("approve.once"))
        configure(hourButton, title: L("approve.hour"))
        configure(alwaysButton, title: L("approve.always"))
        configure(denyButton, title: L("approve.deny"))
        onceButton.keyEquivalent = "1"
        hourButton.keyEquivalent = "2"
        alwaysButton.keyEquivalent = "3"
        denyButton.keyEquivalent = "4"
        onceButton.target = self; onceButton.action = #selector(allowOnce)
        hourButton.target = self; hourButton.action = #selector(allowHour)
        alwaysButton.target = self; alwaysButton.action = #selector(allowAlways)
        denyButton.target = self; denyButton.action = #selector(refuse)

        let topRow = NSStackView(views: [onceButton, hourButton])
        topRow.orientation = .horizontal
        topRow.distribution = .fillEqually
        topRow.spacing = 8

        let bottomRow = NSStackView(views: [alwaysButton, denyButton])
        bottomRow.orientation = .horizontal
        bottomRow.distribution = .fillEqually
        bottomRow.spacing = 8

        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(headerRow)
        root.addArrangedSubview(commandCard)
        root.addArrangedSubview(expandButton)
        root.addArrangedSubview(detailLabel)
        root.addArrangedSubview(timeoutBar)
        root.addArrangedSubview(queueLabel)
        root.addArrangedSubview(topRow)
        root.addArrangedSubview(bottomRow)
        root.setCustomSpacing(4, after: timeoutBar)

        effect.addSubview(root)
        created.contentView = effect

        let inner = ApprovalPanelController.width - 32
        let bodyInsetInner = inner - 36  // 头部让出徽标宽度
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            root.topAnchor.constraint(equalTo: effect.topAnchor),
            root.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            headerText.widthAnchor.constraint(equalToConstant: bodyInsetInner),
            titleLabel.widthAnchor.constraint(equalToConstant: bodyInsetInner),
            subtitleLabel.widthAnchor.constraint(equalToConstant: bodyInsetInner),
            commandCard.widthAnchor.constraint(equalToConstant: inner),
            detailLabel.widthAnchor.constraint(equalToConstant: inner),
            timeoutBar.widthAnchor.constraint(equalToConstant: inner),
            queueLabel.widthAnchor.constraint(equalToConstant: inner),
            topRow.widthAnchor.constraint(equalToConstant: inner),
            bottomRow.widthAnchor.constraint(equalToConstant: inner)
        ])

        panel = created
        return created
    }

    private func configure(_ button: StyledButton, title: String) {
        button.title = title
    }

    // MARK: - 显示

    private func showNext() {
        tick?.invalidate()
        tick = nil
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

        root.layoutSubtreeIfNeeded()
        let height = root.fittingSize.height
        created.setContentSize(NSSize(width: ApprovalPanelController.width, height: height))
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
        if request.method == "run" {
            titleLabel.stringValue = L("approve.titleShort")
        } else {
            titleLabel.stringValue = Lf("approve.titleGenericShort", request.method)
        }
        subtitleLabel.stringValue = request.agentName
        subjectLabel.stringValue = request.subject.isEmpty ? request.method : request.subject
        subjectLabel.maximumNumberOfLines = expanded ? 0 : 6

        let lineCount = subjectLabel.stringValue.split(separator: "\n",
                                                       omittingEmptySubsequences: false).count
        expandButton.isHidden = lineCount <= 6 && subjectLabel.stringValue.count < 300
        expandButton.title = expanded ? L("approve.collapse") : L("approve.expand")

        var details: [String] = []
        if let cwd = request.cwd, !cwd.isEmpty {
            details.append("\(L("approve.cwd")): \(cwd)")
        }
        if let ip = request.fromIP, !ip.isEmpty {
            details.append("\(L("approve.from")): \(ip)")
        }
        detailLabel.stringValue = details.joined(separator: "   ")
        detailLabel.isHidden = details.isEmpty

        timeoutBar.doubleValue = Double(ApprovalPanelController.timeoutSeconds)
        renderQueueCount()
    }

    private func renderQueueCount() {
        queueLabel.stringValue = queue.isEmpty ? "" : Lf("approve.more", queue.count)
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
            renderQueueCount()
        }
    }

    private func finish(_ outcome: ApprovalOutcome) {
        tick?.invalidate()
        tick = nil
        deadline = nil
        guard let current = showing else { return }
        showing = nil
        current.completion(outcome)
        showNext()
    }

    // MARK: - 按钮

    @objc private func allowOnce() { finish(.once) }
    @objc private func allowHour() { finish(.hour) }
    @objc private func allowAlways() { finish(.always) }
    @objc private func refuse() { finish(.deny) }

    @objc private func toggleExpand() {
        expanded.toggle()
        guard let current = showing, let created = panel else { return }
        render(current.request)
        root.layoutSubtreeIfNeeded()
        let height = root.fittingSize.height
        created.setContentSize(NSSize(width: ApprovalPanelController.width, height: height))
        placeTopRight(created)
    }
}
