import AppKit
import Foundation
import MacHandsCore

/// 与中继的那一条 WebSocket(SPEC §4),外加它上面跑的端到端层(§5)。
///
/// 全部状态都活在一条串行队列上,UI 回调统一 hop 到主线程。执行器可能从任何
/// 线程回调 `emit`,所以 `send` 自己再 hop 回来 —— 计数器只有一个人碰。
final class RelayClient {

    enum State: Equatable {
        case idle
        case connecting
        /// 已经通过中继的验签,可以收发了。
        case online
        case retrying(attempt: Int, seconds: Int)
        /// 说得出原因的失败(BAD_SIG / BANNED …)。
        case failed(String)
    }

    // MARK: - 外部接线

    var onStateChange: ((State) -> Void)?
    var onAgentsChanged: (() -> Void)?

    // MARK: - 内部

    private let queue = DispatchQueue(label: "app.machands.relay")
    private let identity: Identity
    private let executor: Executor
    private let policy: PolicyEngine
    private let session: URLSession

    private var task: URLSessionWebSocketTask?
    private var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            let snapshot = state
            DispatchQueue.main.async { [weak self] in self?.onStateChange?(snapshot) }
        }
    }

    private var wantsConnection = false
    private var attempt = 0
    private var sendSequence = 0
    private var authed = false
    private var lastInbound = Date()
    private var watchdog: DispatchSourceTimer?
    private var generation = 0

    /// agentId → 已建好的端到端会话。
    private var e2e: [String: E2ESession] = [:]
    /// 在线的 agent(relay 的 presence)。
    private var online: Set<String> = []
    /// 还没被认领的配对 token。
    private var pendingToken: String?
    private var pendingTokenExpiry: Date?
    /// 中继在 hello 里报的公钥(配对块里要带上它)。
    private var relayKey: String?

    init(identity: Identity, executor: Executor, policy: PolicyEngine) {
        self.identity = identity
        self.executor = executor
        self.policy = policy
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        // 委托为 nil:握手成功与否由第一条 hello 决定,不需要 didOpen。
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - 生命周期

    func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.wantsConnection = true
            self.attempt = 0
            self.connectOnQueue()
            self.startWatchdogOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.wantsConnection = false
            self.teardownOnQueue()
            self.state = .idle
        }
    }

    /// 中继地址改了,或者用户点了"立即重连"。
    func reconnectNow() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.attempt = 0
            self.teardownOnQueue()
            if self.wantsConnection { self.connectOnQueue() }
        }
    }

    var onlineAgents: Set<String> {
        return queue.sync { online }
    }

    var currentState: State {
        return queue.sync { state }
    }

    /// 中继的公钥。没连上过就是 nil —— 那时配对块**建不出来**,
    /// 不能编一个(铁律 4)。
    var relayPublicKey: String? {
        return queue.sync { relayKey }
    }

    // MARK: - 配对

    /// 用户点了"复制给 agent":生成 token 并登记到中继(SPEC §4.2)。
    /// 返回的 token 会被主窗口拼进配对块。
    func openPairing() -> String {
        let token = PairingCode.newToken()
        queue.async { [weak self] in
            guard let self = self else { return }
            self.pendingToken = token
            self.pendingTokenExpiry = Date().addingTimeInterval(TimeInterval(PairingCode.ttlSeconds))
            if self.authed {
                self.sendJSONOnQueue(PairOpenMessage(token: token))
            }
        }
        return token
    }

    func revoke(agentId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.authed { self.sendJSONOnQueue(PairRevokeMessage(agentId: agentId)) }
            self.e2e.removeValue(forKey: agentId)
            self.online.remove(agentId)
        }
        policy.revokeGrant(agentId: agentId)
        SettingsStore.shared.update { settings in
            settings.agents.removeAll { $0.id == agentId }
        }
        ApprovalPanelController.shared.cancelAll(agentId: agentId)
        DispatchQueue.main.async { [weak self] in self?.onAgentsChanged?() }
    }

    // MARK: - 连接

    private func connectOnQueue() {
        teardownOnQueue()
        let settings = SettingsStore.shared.current
        guard let url = settings.macEndpoint else {
            state = .failed(L("settings.badRelay"))
            return
        }
        generation += 1
        let mine = generation
        state = .connecting
        authed = false
        lastInbound = Date()

        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 4 * 1024 * 1024
        task = socket
        socket.resume()
        Log.shared.write("relay: connecting to \(url.absoluteString)")
        receiveOnQueue(socket, generation: mine)
    }

    private func teardownOnQueue() {
        if let socket = task {
            socket.cancel(with: .goingAway, reason: nil)
        }
        task = nil
        authed = false
        e2e.removeAll()
        online.removeAll()
    }

    private func receiveOnQueue(_ socket: URLSessionWebSocketTask, generation mine: Int) {
        socket.receive { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                guard mine == self.generation else { return }
                switch result {
                case .failure(let error):
                    self.handleDisconnect(reason: RelayClient.friendly(error))
                case .success(let message):
                    self.lastInbound = Date()
                    switch message {
                    case .string(let text):
                        self.handle(text: text)
                    case .data(let data):
                        // 协议是文本帧;二进制帧当文本试一次,不行就忽略。
                        if let text = String(data: data, encoding: .utf8) { self.handle(text: text) }
                    @unknown default:
                        break
                    }
                    self.receiveOnQueue(socket, generation: mine)
                }
            }
        }
    }

    /// URLSession 的原文("The operation couldn't be completed…")对用户毫无意义。
    /// 认得出的几种网络故障换成人话,认不出的原样透出去 —— 不编。
    private static func friendly(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return ns.localizedDescription }
        switch ns.code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return L("fail.dns")
        case NSURLErrorCannotConnectToHost, NSURLErrorTimedOut:
            return L("fail.refused")
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return L("fail.network")
        default:
            return ns.localizedDescription
        }
    }

    private func handleDisconnect(reason: String) {
        guard wantsConnection else { return }
        Log.shared.write("relay: disconnected — \(reason)")
        teardownOnQueue()
        ApprovalPanelController.shared.cancelAll(agentId: nil)
        DispatchQueue.main.async { [weak self] in self?.onAgentsChanged?() }
        scheduleReconnectOnQueue()
    }

    private func scheduleReconnectOnQueue() {
        attempt += 1
        // 1、2、4、8、16、30、30… 秒,加 ±20% 抖动,免得一堆 Mac 同时回来。
        let base = min(30.0, pow(2.0, Double(min(attempt, 6)) - 1.0))
        let jitter = Double.random(in: 0.8...1.2)
        let delay = max(1.0, base * jitter)
        state = .retrying(attempt: attempt, seconds: Int(delay.rounded()))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.wantsConnection, self.task == nil else { return }
            self.connectOnQueue()
        }
    }

    /// 60 秒没有 pong 就断(SPEC §4.1)。我们从收方看:90 秒一个字都没有就重连。
    private func startWatchdogOnQueue() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.wantsConnection, self.task != nil else { return }
            if Date().timeIntervalSince(self.lastInbound) > 90 {
                self.handleDisconnect(reason: "no traffic for 90s")
            }
        }
        timer.resume()
        watchdog = timer
    }

    // MARK: - 收

    private func handle(text: String) {
        guard let message = RelayCodec.decode(text) else {
            Log.shared.write("relay: unparsable frame (\(text.count) chars)")
            return
        }
        switch message {
        case .hello(let hello):
            guard let key = hello.relayKey else {
                state = .failed(L("fail.badSig"))
                wantsConnection = false
                teardownOnQueue()
                Log.shared.write("relay: hello carried no relay key")
                return
            }
            // SPEC §2:首次连接就 pin,以后对不上直接拒。
            let pinned = SettingsStore.shared.current.pinnedRelayKey
            if pinned.isEmpty {
                SettingsStore.shared.update { $0.pinnedRelayKey = key }
            } else if pinned != key {
                state = .failed(L("fail.banned"))
                wantsConnection = false
                teardownOnQueue()
                Log.shared.write("relay: key changed (pinned \(pinned), got \(key)) — refusing")
                return
            }
            // pin 住公钥还不够:让中继证明它握着对应的私钥。
            if let signature = hello.sig {
                let payload = RelayCodec.helloPayload(relayId: key, nonce: hello.nonce, ts: hello.ts)
                guard Identity.verify(payload: payload,
                                      signatureB64URL: signature,
                                      edPublicKeyB64URL: key) else {
                    state = .failed(L("fail.badSig"))
                    wantsConnection = false
                    teardownOnQueue()
                    Log.shared.write("relay: hello signature does not verify — refusing")
                    return
                }
            }
            relayKey = key
            sendAuthOnQueue(hello)

        case .ok:
            authed = true
            attempt = 0
            state = .online
            Log.shared.write("relay: authenticated as \(identity.macId)")
            if let token = pendingToken,
               let expiry = pendingTokenExpiry, expiry > Date() {
                sendJSONOnQueue(PairOpenMessage(token: token))
            }

        case .err(let error):
            Log.shared.write("relay: err \(error.code) \(error.msg ?? "")")
            switch error.code {
            case "BAD_SIG":
                state = .failed(L("fail.badSig"))
                wantsConnection = false
                teardownOnQueue()
            case "BANNED":
                state = .failed(L("fail.banned"))
                wantsConnection = false
                teardownOnQueue()
            default:
                break                       // OFFLINE / NOT_PAIRED / RATE:不致命
            }

        case .ping:
            sendJSONOnQueue(PongMessage())

        case .pong:
            break

        case .pairRequest(let request):
            handlePairRequest(request)

        case .recv(let frame):
            handleIncomingFrame(frame)

        case .presence(let presence):
            // 会话(以及两个方向的计数器)是**连接**级的:对端上线/下线就意味着
            // 它那边的计数器从 1 重新开始,所以我们也把这条会话丢掉重建。
            // presence 是两端共同的同步信号 —— 中继给双方都发。
            e2e.removeValue(forKey: presence.id)
            if presence.online { online.insert(presence.id) } else { online.remove(presence.id) }
            DispatchQueue.main.async { [weak self] in self?.onAgentsChanged?() }

        case .unknown(let type):
            Log.shared.write("relay: ignoring \(type)")
        }
    }

    private func sendAuthOnQueue(_ hello: HelloMessage) {
        // 签的 ts 是**我们自己的**当前毫秒时间,不是 hello 里那个:中继按
        // `msg.ts` 验签,并要求它与自己的时钟差在 5 分钟内。
        let timestamp = RelayCodec.nowMilliseconds()
        let payload = RelayCodec.authPayload(id: identity.macId,
                                             nonce: hello.nonce,
                                             ts: Double(timestamp))
        guard let signature = identity.sign(payload) else {
            state = .failed(L("fail.badSig"))
            return
        }
        let name = SettingsStore.shared.current.macName
        sendJSONOnQueue(AuthMessage(id: identity.macId,
                                    edPub: identity.edPublicKeyB64,
                                    xPub: identity.xPublicKeyB64,
                                    name: name,
                                    sig: signature,
                                    ts: timestamp))
    }

    /// SPEC §4.2:token 没过期就**自动允许**并弹通知;同时记进"已授权 agent"。
    private func handlePairRequest(_ request: PairRequestMessage) {
        let known = SettingsStore.shared.current.agents.contains { $0.id == request.agentId }
        let tokenAlive = (pendingTokenExpiry.map { $0 > Date() } ?? false)
        let allow = tokenAlive || known

        sendJSONOnQueue(PairDecideMessage(agentId: request.agentId, allow: allow))
        guard allow else {
            Log.shared.write("relay: refused pairing from \(request.agentId) — no live token")
            return
        }

        pendingToken = nil
        pendingTokenExpiry = nil
        e2e.removeValue(forKey: request.agentId)

        let name = request.agentName ?? String(request.agentId.prefix(8))
        let record = AuthorizedAgent(id: request.agentId,
                                     name: name,
                                     edPub: request.agentEdPub,
                                     xPub: request.agentXPub,
                                     fromIP: request.from ?? "",
                                     pairedAt: Date().timeIntervalSince1970,
                                     lastCommand: nil,
                                     lastCommandAt: nil)
        SettingsStore.shared.update { settings in
            settings.agents.removeAll { $0.id == record.id }
            settings.agents.append(record)
        }
        online.insert(record.id)
        Log.shared.write("relay: paired with \(record.id) (\(name))")
        DispatchQueue.main.async { [weak self] in
            self?.onAgentsChanged?()
            Notifier.post(title: Lf("notify.paired.title", name), body: L("notify.paired.body"))
        }
    }

    private func handleIncomingFrame(_ frame: RecvMessage) {
        guard let agent = SettingsStore.shared.current.agents.first(where: { $0.id == frame.from }) else {
            Log.shared.write("relay: frame from an agent we do not know (\(frame.from))")
            return
        }
        guard let e2eSession = sessionOnQueue(for: agent) else {
            Log.shared.write("relay: no session key for \(agent.id) — bad xPub?")
            return
        }
        let plaintext: Data
        do {
            plaintext = try e2eSession.open(frame.body)
        } catch {
            // 重放或解不开:不回错(回错等于给攻击者一个预言机),只记一笔。
            Log.shared.write("relay: cannot open a frame from \(agent.id): \(error)")
            return
        }
        guard let request = RPCRequest.decode(plaintext) else {
            Log.shared.write("relay: frame from \(agent.id) is not an RPC request")
            return
        }

        let context = Executor.AgentContext(id: agent.id,
                                            name: agent.displayName,
                                            fromIP: agent.fromIP.isEmpty ? nil : agent.fromIP)
        executor.handle(request, agent: context) { [weak self] outbound in
            self?.send(outbound, to: agent.id)
        }
    }

    private func sessionOnQueue(for agent: AuthorizedAgent) -> E2ESession? {
        if let existing = e2e[agent.id] { return existing }
        guard let xPub = Base64URL.decode(agent.xPub) else { return nil }
        guard let created = try? E2ESession(identity: identity,
                                            agentId: agent.id,
                                            agentXPublicKeyRaw: xPub) else { return nil }
        e2e[agent.id] = created
        return created
    }

    // MARK: - 发

    /// 执行器从任意线程调这个。加密与计数都在队列上完成。
    func send(_ outbound: RPCOutbound, to agentId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let agent = SettingsStore.shared.current.agents.first(where: { $0.id == agentId }),
                  let e2eSession = self.sessionOnQueue(for: agent) else { return }
            guard let body = try? e2eSession.seal(outbound.encoded()) else {
                Log.shared.write("relay: cannot seal a reply for \(agentId)")
                return
            }
            self.sendSequence += 1
            self.sendJSONOnQueue(SendMessage(to: agentId, body: body, n: self.sendSequence))
        }
    }

    private func sendJSONOnQueue<T: Encodable>(_ message: T) {
        guard let socket = task, let text = RelayCodec.encode(message) else { return }
        socket.send(.string(text)) { [weak self] error in
            guard let error = error, let self = self else { return }
            self.queue.async {
                self.handleDisconnect(reason: "send failed: \(error.localizedDescription)")
            }
        }
    }
}
