import AppKit
import MacHandsCore

/// 启动、关停,以及把几个长命对象接在一起:
/// 身份 → 策略 → 执行器 → 中继客户端 → 菜单栏 / 窗口。
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let secretStore: SecretStore = FallbackSecretStore()

    private var identity: Identity?
    private var policy: PolicyEngine?
    private var executor: Executor?
    private var relay: RelayClient?

    private var statusItem: StatusItemController?
    private var mainWindow: MainWindowController?
    private var settingsWindow: SettingsWindowController?

    private var heartbeat: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    // MARK: - 启动

    /// `--no-relay` 或环境变量 MACHANDS_NO_RELAY=1:只显示界面,不连中继。
    static var relayDisabled: Bool {
        return CommandLine.arguments.contains("--no-relay")
            || ProcessInfo.processInfo.environment["MACHANDS_NO_RELAY"] == "1"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.shared.write("MacHands starting (bundle=\(LoginItem.isBundled ? "yes" : "no"))")
        AuditLog.shared.onProblem = { message in Log.shared.write(message) }

        let settings = SettingsStore.shared.current

        let identity = Identity.loadOrCreate(store: secretStore, name: settings.macName)
        self.identity = identity
        Log.shared.write("this Mac is \(identity.macId)")

        let policy = PolicyEngine(state: settings.policy)
        policy.onChange = { state in
            SettingsStore.shared.update { $0.policy = state }
        }
        self.policy = policy

        let executor = Executor(policy: policy)
        executor.onActivity = { [weak self] agentId, summary in
            self?.recordActivity(agentId: agentId, summary: summary)
        }
        self.executor = executor

        let relay = RelayClient(identity: identity, executor: executor, policy: policy)
        relay.onStateChange = { [weak self] _ in self?.refreshUI() }
        relay.onAgentsChanged = { [weak self] in self?.refreshUI() }
        // SPEC §10.2:配对成功就把授权页摆到用户面前 —— 这是唯一一次需要他点的地方。
        relay.onPaired = { [weak self] _ in self?.showMainWindow(activating: true) }
        self.relay = relay

        let statusItem = StatusItemController()
        statusItem.onCopyForAgent = { [weak self] in self?.copyPairingBlock() }
        statusItem.onSetMode = { [weak self] mode in self?.setMode(mode) }
        statusItem.onTogglePause = { [weak self] in self?.togglePause() }
        statusItem.onOpenAudit = { AppDelegate.reveal(AuditLog.fileURL) }
        statusItem.onOpenWindow = { [weak self] in self?.showMainWindow(activating: true) }
        statusItem.onOpenSettings = { [weak self] in self?.showSettingsWindow() }
        statusItem.onAuthorize = { [weak self] in self?.showMainWindow(activating: true) }
        statusItem.onQuit = { NSApp.terminate(nil) }
        self.statusItem = statusItem

        SettingsStore.shared.onChange = { [weak self] _ in
            DispatchQueue.main.async { self?.refreshUI() }
        }

        applyLicense()
        var askNotifications = true
        #if DEBUG
        // 预览副本别去要通知权限:换了 bundle id 的副本会在屏幕上弹一个系统授权框。
        if DebugPreview.options.isActive { askNotifications = false }
        #endif
        if askNotifications { Notifier.requestAuthorization() }
        installSignalHandlers()

        // 开机自启的默认值是"开",但只在第一次尝试注册,失败也不吵。
        if settings.launchAtLogin, case .disabled = LoginItem.status() {
            if let problem = LoginItem.set(true) {
                Log.shared.write("launch at login: \(problem)")
            }
        }

        // 开发者便利(SPEC §13):`--no-relay` 或 MACHANDS_NO_RELAY=1 只起界面、不连中继,
        // 给界面调试用的副本——否则它会用同一份身份把正式版顶下线。
        var uiOnly = AppDelegate.relayDisabled
        #if DEBUG
        // 预览假审批卡的副本一律不连中继,免得忘了带 --no-relay 把正式版顶下线。
        if DebugPreview.options.isActive { uiOnly = true }
        #endif
        if uiOnly {
            Log.shared.write("relay disabled by --no-relay / MACHANDS_NO_RELAY; UI-only run")
        } else {
            relay.start()
        }

        // 菜单里的"3 分钟前"要自己走动;顺便刷新重连倒计时。
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshUI()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer

        // SPEC §7.2:首启自动打开一次。
        if !settings.seenWelcome {
            SettingsStore.shared.update { $0.seenWelcome = true }
            showMainWindow(activating: true)
        }
        refreshUI()

        #if DEBUG
        DebugPreview.launch()       // 只有带 --preview-approval 启动时才做事(见 DebugPreview.swift)
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        heartbeat?.invalidate()
        heartbeat = nil
        relay?.stop()
        AuditLog.shared.flush()
        Log.shared.write("MacHands stopped")
        Log.shared.close()
    }

    /// 菜单栏 App 没有要恢复的窗口,但再点一次图标应该把那一个窗口叫出来 ——
    /// 启动后什么都不发生,读起来就是"它没起来"。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(activating: true)
        return true
    }

    // MARK: - UI

    private func showMainWindow(activating: Bool) {
        if mainWindow == nil {
            let window = MainWindowController()
            window.onCopy = { [weak self] in self?.copyPairingBlock() }
            window.onSetMode = { [weak self] mode in self?.setMode(mode) }
            window.onSetLaunchAtLogin = { [weak self] on in self?.setLaunchAtLogin(on) }
            window.onOpenSettings = { [weak self] in self?.showSettingsWindow() }
            window.onAuthorize = { [weak self] mode in self?.authorize(mode) }
            mainWindow = window
        }
        mainWindow?.render(mainModel())
        mainWindow?.present(activating: activating)
    }

    private func showSettingsWindow() {
        if settingsWindow == nil {
            let window = SettingsWindowController()
            window.onSave = { [weak self] next in self?.saveSettings(next) }
            window.onRevoke = { [weak self] agentId in self?.revoke(agentId) }
            settingsWindow = window
        }
        settingsWindow?.present(settings: SettingsStore.shared.current,
                                licenseLine: licenseLine() ?? "")
    }

    private func refreshUI() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.refreshUI() }
            return
        }
        let settings = SettingsStore.shared.current
        let state = relay?.currentState ?? .idle
        let online = relay?.onlineAgents ?? []
        let paused = policy?.paused ?? false
        let mode = policy?.mode ?? .ask

        statusItem?.model = StatusItemController.Model(relayState: state,
                                                       agents: settings.agents,
                                                       online: online,
                                                       mode: mode,
                                                       paused: paused,
                                                       licenseLine: licenseLine(),
                                                       authorizedAt: settings.authorizedAt)
        statusItem?.render()

        if let window = mainWindow, window.window?.isVisible == true {
            window.render(mainModel())
        }
    }

    private func mainModel() -> MainWindowController.Model {
        let settings = SettingsStore.shared.current
        return MainWindowController.Model(relayState: relay?.currentState ?? .idle,
                                          agents: settings.agents,
                                          online: relay?.onlineAgents ?? [],
                                          mode: policy?.mode ?? .ask,
                                          paused: policy?.paused ?? false,
                                          relayURL: settings.relayURL,
                                          macName: settings.macName,
                                          macId: identity?.macId ?? "",
                                          licenseLine: licenseLine(),
                                          authorizedAt: settings.authorizedAt)
    }

    // MARK: - 动作

    /// SPEC §3:唯一一个用户要复制的东西。
    ///
    /// 中继没连上时**不生成**配对码 —— 里面要带中继公钥,而且 token 得先登记到
    /// 中继才有效。编一个出来只会让 agent 那边报一句看不懂的错。
    private func copyPairingBlock() {
        guard let relay = relay, let identity = identity else { return }
        guard case .online = relay.currentState, let relayKey = relay.relayPublicKey else {
            showMainWindow(activating: true)
            mainWindow?.showCopied(success: false)
            return
        }
        let settings = SettingsStore.shared.current
        let token = relay.openPairing()
        let code = PairingCode(relayEndpoint: settings.relayEndpointForCode,
                               relayPublicKey: relayKey,
                               macId: identity.macId,
                               macXPublicKey: identity.xPublicKeyB64,
                               macEdPublicKey: identity.edPublicKeyB64,
                               token: token,
                               macName: settings.macName)
        let text = PairingCode.clipboardText(code: code.encoded,
                                             lead: L("pair.lead"),
                                             note: L("pair.note"))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let ok = pasteboard.setString(text, forType: .string)
        Log.shared.write("pairing block copied (token registered, 600s)")
        showMainWindow(activating: true)
        mainWindow?.showCopied(success: ok)
    }

    private func setMode(_ mode: ApprovalMode) {
        policy?.mode = mode
        refreshUI()
    }

    /// SPEC §10.2「授权并验证」:写范围、记时刻、一次性把系统权限请求弹完。
    /// 自检本身由主窗口在后台跑并渲染(两端同一份 Verifier)。
    private func authorize(_ mode: ApprovalMode) {
        policy?.mode = mode
        SettingsStore.shared.update { $0.authorizedAt = Date().timeIntervalSince1970 * 1000 }
        Permissions.requestAll()
        Log.shared.write("authorized once: mode=\(mode.rawValue)")
        refreshUI()
    }

    private func togglePause() {
        guard let policy = policy else { return }
        let next = !policy.paused
        policy.paused = next
        if next { ApprovalPanelController.shared.cancelAll(agentId: nil) }
        refreshUI()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if let problem = LoginItem.set(enabled) {
            Log.shared.write("launch at login change failed: \(problem)")
            let alert = NSAlert()
            alert.messageText = L("app.name")
            alert.informativeText = problem
            _ = alert.runModal()
        }
        SettingsStore.shared.update { $0.launchAtLogin = enabled }
        refreshUI()
    }

    private func saveSettings(_ next: Settings) {
        let previousRelay = SettingsStore.shared.current.relayURL
        SettingsStore.shared.update { current in
            current.relayURL = next.relayURL
            current.license = next.license
            current.policy.allow = next.policy.allow
            current.policy.deny = next.policy.deny
            current.policy.askForReads = next.policy.askForReads
        }
        policy?.update { state in
            state.allow = next.policy.allow
            state.deny = next.policy.deny
            state.askForReads = next.policy.askForReads
        }
        applyLicense()
        if previousRelay != next.relayURL {
            // 换了中继就换了信任对象,旧的 pin 不再适用。
            SettingsStore.shared.update { $0.pinnedRelayKey = "" }
            relay?.reconnectNow()
        }
        settingsWindow?.load(SettingsStore.shared.current)
        refreshUI()
    }

    private func revoke(_ agentId: String) {
        relay?.revoke(agentId: agentId)
        settingsWindow?.load(SettingsStore.shared.current)
        refreshUI()
    }

    private func recordActivity(agentId: String, summary: String) {
        SettingsStore.shared.update { settings in
            for index in settings.agents.indices where settings.agents[index].id == agentId {
                settings.agents[index].lastCommand = StatusItemController.shorten(summary, to: 80)
                settings.agents[index].lastCommandAt = Date().timeIntervalSince1970
            }
        }
    }

    // MARK: - 许可证

    private func currentLicenseState() -> LicenseState {
        let settings = SettingsStore.shared.current
        let start = Identity.trialStart(store: secretStore)
        return License.state(licenseText: settings.license, trialStart: start)
    }

    private func applyLicense() {
        let state = currentLicenseState()
        policy?.setLicenseBlocksWrites(state.blocksWrites)
    }

    private func licenseLine() -> String? {
        switch currentLicenseState() {
        case .trial(let days):
            return Lf("license.trial", days)
        case .trialExpired:
            return L("license.blocked")
        case .licensed(let email, _):
            return Lf("license.ok", email)
        case .licenseExpired(let email, _):
            return Lf("license.expired", email)
        case .invalid:
            return L("license.invalid")
        }
    }

    // MARK: - 杂项

    private static func reveal(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            Paths.ensureDirectory(url.deletingLastPathComponent(), permissions: 0o700)
            _ = FileManager.default.createFile(atPath: url.path, contents: nil,
                                               attributes: [.posixPermissions: 0o600])
        }
        if !NSWorkspace.shared.open(url) {
            _ = NSWorkspace.shared.selectFile(url.path,
                                              inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        }
    }

    /// `kill` 与 `launchctl bootout` 发的是 SIGTERM;没有这一段,App 会直接死掉,
    /// `applicationWillTerminate` 不跑,日志的最后几行就丢了。
    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT] {
            _ = signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }
}
