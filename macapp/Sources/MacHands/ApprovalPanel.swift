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
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let subjectLabel = NSTextField(wrappingLabelWithString: "")
    private let expandButton = NSButton()
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let queueLabel = NSTextField(labelWithString: "")
    private let onceButton = NSButton()
    private let hourButton = NSButton()
    private let alwaysButton = NSButton()
    private let denyButton = NSButton()

    // MARK: - 状态

    private var queue: [Pending] = []
    private var showing: Pending?
    private var expanded = false
    private var deadline: Date?
    private var tick: Timer?

    private static let width: CGFloat = 380

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
                            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
                            backing: .buffered,
                            defer: false)
        created.title = L("app.name")
        created.isFloatingPanel = true
        created.becomesKeyOnlyIfNeeded = true
        created.hidesOnDeactivate = false
        created.worksWhenModal = true
        created.isReleasedWhenClosed = false
        created.level = .floating
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        created.standardWindowButton(.closeButton)?.isHidden = true

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.maximumNumberOfLines = 2

        subjectLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        subjectLabel.maximumNumberOfLines = 6
        subjectLabel.lineBreakMode = .byTruncatingTail
        subjectLabel.isSelectable = true

        expandButton.bezelStyle = .inline
        expandButton.controlSize = .small
        expandButton.font = NSFont.systemFont(ofSize: 11)
        expandButton.target = self
        expandButton.action = #selector(toggleExpand)
        expandButton.isHidden = true

        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 3

        queueLabel.font = NSFont.systemFont(ofSize: 11)
        queueLabel.textColor = .tertiaryLabelColor

        configure(onceButton, title: L("approve.once"), key: "1", action: #selector(allowOnce))
        configure(hourButton, title: L("approve.hour"), key: "2", action: #selector(allowHour))
        configure(alwaysButton, title: L("approve.always"), key: "3", action: #selector(allowAlways))
        configure(denyButton, title: L("approve.deny"), key: "4", action: #selector(refuse))

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
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(titleLabel)
        root.addArrangedSubview(subjectLabel)
        root.addArrangedSubview(expandButton)
        root.addArrangedSubview(detailLabel)
        root.addArrangedSubview(queueLabel)
        root.addArrangedSubview(topRow)
        root.addArrangedSubview(bottomRow)

        let content = NSView()
        content.addSubview(root)
        created.contentView = content

        let inner = ApprovalPanelController.width - 28
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: inner),
            subjectLabel.widthAnchor.constraint(equalToConstant: inner),
            detailLabel.widthAnchor.constraint(equalToConstant: inner),
            topRow.widthAnchor.constraint(equalToConstant: inner),
            bottomRow.widthAnchor.constraint(equalToConstant: inner)
        ])

        panel = created
        return created
    }

    private func configure(_ button: NSButton, title: String, key: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = NSFont.systemFont(ofSize: 12)
        button.target = self
        button.action = action
        // 数字键 1-4(SPEC §5.2)。面板被点一下成为 key window 之后就能用。
        button.keyEquivalent = key
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
            titleLabel.stringValue = Lf("approve.title", request.agentName)
        } else {
            titleLabel.stringValue = Lf("approve.titleGeneric", request.agentName, request.method)
        }
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

        renderQueueCount()
    }

    private func renderQueueCount() {
        var parts: [String] = []
        if !queue.isEmpty { parts.append(Lf("approve.more", queue.count)) }
        if let deadline = deadline {
            let left = max(0, Int(deadline.timeIntervalSinceNow.rounded()))
            parts.append(Lf("approve.timeout", left))
        }
        queueLabel.stringValue = parts.joined(separator: "   ·   ")
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
        if Date() >= deadline {
            finish(.timeout)
        } else {
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
