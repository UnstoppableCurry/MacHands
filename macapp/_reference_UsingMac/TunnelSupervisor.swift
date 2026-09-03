import Foundation
import Network

/// Owns the one `ssh -N -R …` child process and everything about its lifetime.
///
/// The whole component is an explicit state machine: one `State` enum, one
/// `Event` enum, and one transition function (`apply`) that is the only place
/// `state` is ever written. Everything runs on one serial queue. There are no
/// "am I connecting or reconnecting" booleans — the state says so — and the two
/// pieces of bookkeeping that remain are counters, not flags:
///
///   * `generation` — bumped whenever we deliberately abandon an attempt. Every
///     event that a child or a timer can deliver carries the generation it was
///     born in, so a late answer from an attempt we already gave up on is
///     dropped instead of corrupting a newer one.
///   * `attempt`    — how many times in a row we have retried, for the backoff.
///
///     transition table (event → state), everything else is ignored:
///
///     from \ on   start        stop    pause    resume   preflight ok/fail
///     idle        checking     idle    paused   checking      –
///     paused      checking     idle    paused   checking      –
///     checking    –            idle    paused   checking  connecting / failed
///     connecting  –            idle    paused   checking      –
///     connected   –            idle    paused   checking      –
///     retrying    checking     idle    paused   checking      –
///     failed      checking     idle    paused   checking      –
///
///     from \ on   forwardEstablished  graceElapsed  childExited        fatalDiagnosis
///     connecting  connected           connected     retrying / failed  failed
///     connected   connected           –             retrying / failed  failed
///     (any other) –                   –             –                  –
///
///     retryDue: retrying → checking.  networkBecameAvailable: retrying, or any
///     failed(f) with f.isRetryable → checking (a new network is exactly what
///     fixes a blocked port).  configChanged: anything but paused → checking.
///
/// `paused` is a separate resting state from `idle` so that a user's explicit
/// pause survives network changes, reconnects and relaunches.
final class TunnelSupervisor {

    // MARK: - state

    enum Failure: Equatable {
        case notEnrolled
        case missingIdentity(String)
        case sshMissing
        case remoteLoginOff
        case authRejected
        case portInUse(Int)
        case hostKeyChanged
        /// R10: nothing answered on the server's ssh port. Almost always a
        /// network that blocks it, which is fixable — but only if we say so.
        case serverUnreachable(port: Int)
        /// R10: a ProxyCommand was configured and the connection died in the
        /// handshake — the proxy, not the key, is what needs looking at.
        case proxyFailed
        case network
        case unknown(String)

        /// Whether waiting and trying again could plausibly fix it.
        var isRetryable: Bool {
            switch self {
            case .remoteLoginOff, .network, .portInUse, .serverUnreachable, .proxyFailed, .unknown:
                return true
            case .notEnrolled, .missingIdentity, .sshMissing, .authRejected, .hostKeyChanged:
                return false
            }
        }

        var summary: String {
            switch self {
            case .notEnrolled:                  return L("fail.notEnrolled")
            case .missingIdentity:              return L("fail.missingIdentity")
            case .sshMissing:                   return L("fail.sshMissing")
            case .remoteLoginOff:               return L("fail.remoteLoginOff")
            case .authRejected:                 return L("fail.authRejected")
            case .portInUse(let port):          return Lf("fail.portInUse", port)
            case .hostKeyChanged:               return L("fail.hostKeyChanged")
            case .serverUnreachable(let port):  return Lf("fail.serverUnreachable", port)
            case .proxyFailed:                  return L("fail.proxyFailed")
            case .network:                      return L("fail.network")
            case .unknown:                      return L("fail.unknown")
            }
        }

        /// What the user should do next. Always present, always concrete.
        func nextStep(config: Config) -> String {
            switch self {
            case .notEnrolled:               return L("next.notEnrolled")
            case .missingIdentity(let path): return Lf("next.missingIdentity", path)
            case .sshMissing:                return L("next.sshMissing")
            case .remoteLoginOff:            return L("next.remoteLoginOff")
            case .authRejected:              return Lf("next.authRejected", config.macName)
            case .portInUse:                 return Lf("next.portInUse", config.macName)
            case .hostKeyChanged:            return L("next.hostKeyChanged")
            case .serverUnreachable(let port):
                // R10: name the port, and name both ways out of it.
                return Lf("next.serverUnreachable", port, config.macName)
            case .proxyFailed:               return L("next.proxyFailed")
            case .network:                   return L("next.network")
            case .unknown:                   return L("next.unknown")
            }
        }
    }

    enum State: Equatable {
        case idle
        case paused
        /// Pre-flight: is Remote Login actually on? Nothing has been spawned yet.
        case checking
        case connecting
        case connected(since: Date)
        case retrying(attempt: Int, resumeAt: Date)
        case failed(Failure)

        /// The four things the menu-bar icon has to be able to say.
        enum Appearance {
            case connected
            case working
            case stopped
            case problem
        }

        var appearance: Appearance {
            switch self {
            case .idle, .paused:                    return .stopped
            case .checking, .connecting, .retrying: return .working
            case .connected:                        return .connected
            case .failed:                           return .problem
            }
        }
    }

    /// Everything that can move the machine. The `generation` on the events a
    /// child or timer delivers is what makes a late answer harmless.
    enum Event {
        case start
        case stop
        case pause
        case resume
        case configChanged
        case networkBecameAvailable
        case retryDue
        case preflightFinished(generation: Int, remoteLoginOn: Bool)
        case forwardEstablished(generation: Int)
        case graceElapsed(generation: Int)
        case fatalDiagnosis(generation: Int, failure: Failure)
        case childExited(generation: Int, status: Int32, diagnosis: Failure?)
    }

    // MARK: - wiring

    static let shared = TunnelSupervisor()

    /// Called on the main queue whenever the state changes.
    var onStateChange: ((State) -> Void)?

    private let queue = DispatchQueue(label: "com.using-mac.supervisor")

    private var state: State = .idle
    private var child: Process?
    private var childErrorPipe: Pipe?
    private var stderrRemainder = ""
    private var lastDiagnosis: Failure?
    private var attempt = 0
    private var generation = 0
    private var spawnedAt: Date?
    private var retryWork: DispatchWorkItem?
    private var graceWork: DispatchWorkItem?
    private var monitor: NWPathMonitor?

    /// 1s, 2s, 5s, 15s, then 30s forever.
    private let backoff: [TimeInterval] = [1, 2, 5, 15, 30]
    /// A connection that lasted this long counts as "it worked", so the next
    /// drop starts from a 1s retry rather than from a 30s one.
    private let stableAfter: TimeInterval = 60
    /// ssh -N says nothing on success, so a child that has stayed alive this
    /// long without complaining is treated as connected even if the
    /// "remote forward success" line never showed up.
    private let graceSeconds: TimeInterval = 12
    /// How long to wait before looking again at something only the user can fix.
    private let recheckSeconds: TimeInterval = 15

    private init() {}

    // MARK: - public API (safe from any thread)

    var currentState: State {
        return queue.sync { state }
    }

    func start() { queue.async { self.apply(.start) } }
    func pause() { queue.async { self.apply(.pause) } }
    func resume() { queue.async { self.apply(.resume) } }
    func reconnectNow() {
        queue.async {
            self.apply(.stop)
            self.apply(.start)
        }
    }
    func configChanged() { queue.async { self.apply(.configChanged) } }

    func beginWatchingNetwork() {
        queue.async {
            guard self.monitor == nil else { return }
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self = self else { return }
                if path.status == .satisfied {
                    self.queue.async { self.apply(.networkBecameAvailable) }
                }
            }
            monitor.start(queue: self.queue)
            self.monitor = monitor
        }
    }

    /// Called on quit. Blocks until the ssh child is really gone, so the app
    /// never leaves a tunnel running behind it.
    func shutdown() {
        queue.sync {
            cancelTimers()
            generation += 1                  // strand every event still in flight
            terminateChild(waitFor: 3)
            monitor?.cancel()
            monitor = nil
            state = .idle
        }
    }

    // MARK: - the transition function (always on `queue`)

    private func apply(_ event: Event) {
        switch event {

        case .start:
            switch state {
            case .checking, .connecting, .connected:
                return                       // already up or on the way
            case .idle, .paused, .retrying, .failed:
                attempt = 0
                beginAttempt()
            }

        case .stop:
            abandonAttempt(waitFor: 2)
            setState(.idle)

        case .pause:
            abandonAttempt(waitFor: 2)
            ConfigStore.shared.update { $0.paused = true }
            setState(.paused)

        case .resume:
            ConfigStore.shared.update { $0.paused = false }
            attempt = 0
            abandonAttempt(waitFor: 2)
            beginAttempt()

        case .configChanged:
            if case .paused = state { return }
            attempt = 0
            abandonAttempt(waitFor: 2)
            beginAttempt()

        case .networkBecameAvailable:
            // A new Wi-Fi or a wake from sleep: do not sit out the rest of a
            // 30-second backoff when the reason for it just went away.
            switch state {
            case .retrying:
                attempt = 0
                abandonAttempt(waitFor: 0)
                beginAttempt()
            case .failed(let failure) where failure.isRetryable:
                // A blocked port or an unreachable server is exactly what a new
                // network can fix, so do not sit out the rest of the backoff.
                attempt = 0
                abandonAttempt(waitFor: 0)
                beginAttempt()
            default:
                break
            }

        case .retryDue:
            retryWork = nil
            beginAttempt()

        case .preflightFinished(let eventGeneration, let remoteLoginOn):
            guard eventGeneration == generation else { return }
            guard isAwaitingPreflight else { return }
            if remoteLoginOn {
                setState(.connecting)
                spawn(config: ConfigStore.shared.current, generation: eventGeneration)
            } else {
                // Keep looking — the user may be flipping the switch right now —
                // but keep *saying* what is wrong. A "reconnecting…" icon over a
                // Remote Login problem is exactly the lie this app exists to
                // stop telling.
                Log.shared.write("pre-flight refused to start ssh: remote login is off")
                setState(.failed(.remoteLoginOff))
                scheduleRecheck(after: recheckSeconds)
            }

        case .forwardEstablished(let eventGeneration):
            guard eventGeneration == generation else { return }
            cancelGraceTimer()
            if case .connected = state { return }
            attempt = 0
            setState(.connected(since: Date()))

        case .graceElapsed(let eventGeneration):
            guard eventGeneration == generation else { return }
            guard case .connecting = state else { return }
            Log.shared.write("no forward confirmation in \(Int(graceSeconds))s but ssh is alive; treating as connected")
            attempt = 0
            setState(.connected(since: Date()))

        case .fatalDiagnosis(let eventGeneration, let failure):
            guard eventGeneration == generation else { return }
            // A rejected key or a changed host key will not fix itself; stop
            // waiting for ssh to give up on its own, and say so now.
            abandonAttempt(waitFor: 2)
            setState(.failed(failure))

        case .childExited(let eventGeneration, let status, let diagnosis):
            // A stale generation means we killed it on purpose; the state that
            // replaced this attempt has already been set.
            guard eventGeneration == generation else { return }
            cancelGraceTimer()
            child = nil
            childErrorPipe = nil

            let lasted = spawnedAt.map { Date().timeIntervalSince($0) } ?? 0
            if lasted >= stableAfter { attempt = 0 }
            spawnedAt = nil

            let failure = diagnosis ?? .unknown("exit \(status)")
            Log.shared.write("ssh exited status=\(status) after \(Int(lasted))s diagnosis=\(failure)")
            if failure.isRetryable {
                scheduleRetry(after: failure)
            } else {
                setState(.failed(failure))
            }
        }
    }

    private func setState(_ next: State) {
        guard next != state else { return }
        state = next
        Log.shared.write("state -> \(describe(next))")
        let published = next
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(published)
        }
    }

    private func describe(_ state: State) -> String {
        switch state {
        case .idle:                          return "idle"
        case .paused:                        return "paused"
        case .checking:                      return "checking"
        case .connecting:                    return "connecting"
        case .connected:                     return "connected"
        case .retrying(let attempt, let at): return "retrying(attempt \(attempt), in \(Int(at.timeIntervalSinceNow))s)"
        case .failed(let failure):           return "failed(\(failure))"
        }
    }

    /// States in which a pre-flight answer is still wanted: either we said so
    /// (`.checking`), or we are quietly re-checking a problem we are already
    /// showing the user.
    private var isAwaitingPreflight: Bool {
        switch state {
        case .checking:                 return true
        case .failed(let failure):      return failure.isRetryable
        default:                        return false
        }
    }

    /// Give up on whatever attempt is in flight: cancel the timers, bump the
    /// generation so nothing it started can still reach us, and make sure the
    /// child is gone. The caller decides what state comes next.
    private func abandonAttempt(waitFor seconds: TimeInterval) {
        cancelTimers()
        generation += 1
        terminateChild(waitFor: seconds)
    }

    // MARK: - attempting a connection

    /// Pre-flight, then spawn. The checks that need I/O run off the state queue
    /// and come back as events, so the machine itself never blocks.
    private func beginAttempt() {
        let config = ConfigStore.shared.current

        if config.paused {
            setState(.paused)
            return
        }
        guard config.isRunnable else {
            setState(.failed(.notEnrolled))
            return
        }
        let identityPath = config.identityURL.path
        guard FileManager.default.fileExists(atPath: identityPath) else {
            setState(.failed(.missingIdentity(identityPath)))
            return
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh") else {
            setState(.failed(.sshMissing))
            return
        }

        generation += 1
        let thisGeneration = generation
        // Silent recheck: when the blocker is something only the user can fix,
        // the honest display is the unchanged problem. Flickering
        // problem → working → problem every 15 seconds is noise, not news.
        if case .failed(let failure) = state, failure.isRetryable {
            Log.shared.write("re-checking: \(describe(state))")
        } else {
            setState(.checking)
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            // Without Remote Login there is nothing on port 22 for the tunnel to
            // lead to. Refusing here, loudly, beats a tunnel that is "up" and
            // useless.
            let remoteLoginOn = RemoteLoginCheck.checkSynchronously(timeout: 2.0)
            self.queue.async {
                self.apply(.preflightFinished(generation: thisGeneration,
                                              remoteLoginOn: remoteLoginOn))
            }
        }
    }

    private func spawn(config: Config, generation thisGeneration: Int) {
        // Nothing should reach here with a child still running — every path into
        // a new attempt abandons the old one first — but a silent return would
        // leave the machine stuck in `connecting`, so clean up and say so.
        if child != nil {
            Log.shared.write("spawn found an ssh child still running; terminating it first")
            terminateChild(waitFor: 2)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = TunnelSupervisor.sshArguments(for: config)

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        // ssh must never inherit a terminal or try to read from one: with
        // BatchMode it should fail fast instead of waiting for a human. (R6:
        // an ssh that can read stdin will happily eat whatever is on it.)
        process.standardInput = FileHandle.nullDevice

        stderrRemainder = ""
        lastDiagnosis = nil

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self = self, !data.isEmpty else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            self.queue.async { self.ingest(stderr: text, generation: thisGeneration) }
        }

        process.terminationHandler = { [weak self] finished in
            errorPipe.fileHandleForReading.readabilityHandler = nil
            guard let self = self else { return }
            self.queue.async {
                self.apply(.childExited(generation: thisGeneration,
                                        status: finished.terminationStatus,
                                        diagnosis: self.lastDiagnosis))
            }
        }

        do {
            try process.run()
        } catch {
            Log.shared.write("cannot start ssh: \(error.localizedDescription)")
            setState(.failed(.sshMissing))
            return
        }

        child = process
        childErrorPipe = errorPipe
        spawnedAt = Date()
        let viaProxy = config.proxyCommand.trimmingCharacters(in: .whitespaces).isEmpty ? "direct" : "via ProxyCommand"
        Log.shared.write("ssh started pid=\(process.processIdentifier) forward=127.0.0.1:\(config.tunnelPort) server=\(config.tunnelUser)@\(config.serverHost):\(config.serverSSHPort) \(viaProxy)")
        scheduleGraceTimer(generation: thisGeneration)
    }

    /// The exact flags the server contract expects (`bootstrap/install.sh`'s
    /// helper runs the same ones): one reverse forward pinned to the server's
    /// loopback — R2 says write it out in full, `127.0.0.1:<port>:localhost:22`,
    /// because a bare port number does not line up with the server's
    /// `permitlisten="127.0.0.1:<port>"` — and keepalives that let a dead
    /// session be reaped promptly.
    static func sshArguments(for config: Config) -> [String] {
        var arguments = [
            "-N",
            "-v",                                     // gives us "remote forward success"
            "-i", config.identityURL.path,
            "-o", "IdentitiesOnly=yes",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "TCPKeepAlive=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(Paths.knownHosts.path)"
        ]
        // R10: an alternate sshd port and an optional ProxyCommand, for networks
        // that block the direct route. Both are passed with -o rather than
        // written into the user's own ~/.ssh/config, which is theirs.
        if config.serverSSHPort != 22 {
            arguments += ["-p", String(config.serverSSHPort)]
        }
        let proxy = config.proxyCommand.trimmingCharacters(in: .whitespaces)
        if !proxy.isEmpty {
            arguments += ["-o", "ProxyCommand=\(proxy)"]
        }
        arguments += [
            "-R", "127.0.0.1:\(config.tunnelPort):localhost:22",
            "\(config.tunnelUser)@\(config.serverHost)"
        ]
        return arguments
    }

    // MARK: - reading ssh's mind from its stderr

    private func ingest(stderr text: String, generation eventGeneration: Int) {
        guard eventGeneration == generation else { return }

        var buffer = stderrRemainder + text
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: "\n") {
            lines.append(String(buffer[buffer.startIndex..<newline]))
            buffer = String(buffer[buffer.index(after: newline)...])
        }
        stderrRemainder = buffer.count > 4096 ? "" : buffer

        let config = ConfigStore.shared.current
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            Log.shared.write("ssh: \(trimmed)")

            if TunnelSupervisor.indicatesForwardEstablished(trimmed) {
                apply(.forwardEstablished(generation: eventGeneration))
                continue
            }
            if let failure = TunnelSupervisor.diagnose(trimmed, config: config) {
                lastDiagnosis = failure
                if !failure.isRetryable {
                    apply(.fatalDiagnosis(generation: eventGeneration, failure: failure))
                    return                    // this attempt is over
                }
            }
        }
    }

    static func indicatesForwardEstablished(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("remote forward success")
            || lower.contains("all remote forwarding requests processed")
    }

    /// Turn one line of ssh's stderr into something the user can act on.
    ///
    /// R10 insists the two failures a user confuses stay apart: "nothing
    /// answers on that port" (the network is blocking it — change the port or
    /// add a proxy) and "the server said no to this key" (re-pair). They look
    /// alike in a log and need opposite fixes, so they are separate cases here
    /// and separate sentences in the menu.
    static func diagnose(_ line: String, config: Config) -> Failure? {
        let lower = line.lowercased()
        let usingProxy = !config.proxyCommand.trimmingCharacters(in: .whitespaces).isEmpty

        // 1. authentication — the key, not the network.
        if lower.contains("permission denied")
            || lower.contains("no supported authentication")
            || lower.contains("too many authentication failures") {
            return .authRejected
        }
        // 2. the reverse port is taken on the server.
        if lower.contains("remote port forwarding failed") {
            return .portInUse(config.tunnelPort)
        }
        // 3. the server is not who it was.
        if lower.contains("host key verification failed")
            || lower.contains("remote host identification has changed") {
            return .hostKeyChanged
        }
        // 4. the proxy itself, when there is one.
        if usingProxy && (lower.contains("proxy") || lower.contains("kex_exchange_identification")) {
            return .proxyFailed
        }
        // 5. nothing answered on the ssh port: blocked, filtered or down.
        if lower.contains("connection refused")
            || lower.contains("connection timed out")
            || lower.contains("operation timed out")
            || lower.contains("network is unreachable")
            || lower.contains("no route to host")
            || lower.contains("kex_exchange_identification") {
            return .serverUnreachable(port: config.serverSSHPort)
        }
        // 6. the address does not resolve, or an established link dropped.
        if lower.contains("could not resolve hostname")
            || lower.contains("name or service not known")
            || lower.contains("connection closed by remote host")
            || lower.contains("broken pipe")
            || lower.contains("timeout, server") {
            return .network
        }
        return nil
    }

    // MARK: - timers and the child

    private func scheduleRetry(after failure: Failure) {
        let index = min(attempt, backoff.count - 1)
        var delay = backoff[index]
        if case .portInUse = failure {
            // The server frees a squatted port on its own keepalive schedule;
            // hammering it just fills the log.
            delay = max(delay, 30)
        }
        attempt += 1
        let resumeAt = Date().addingTimeInterval(delay)
        setState(.retrying(attempt: attempt, resumeAt: resumeAt))
        scheduleRecheck(after: delay)
    }

    /// Try again in `delay` seconds without claiming anything new about the
    /// state. Also used when the blocker is on the user's side (Remote Login),
    /// where the honest display is the unchanged problem, not a spinner.
    private func scheduleRecheck(after delay: TimeInterval) {
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.apply(.retryDue)
        }
        retryWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleGraceTimer(generation thisGeneration: Int) {
        cancelGraceTimer()
        let work = DispatchWorkItem { [weak self] in
            self?.apply(.graceElapsed(generation: thisGeneration))
        }
        graceWork = work
        queue.asyncAfter(deadline: .now() + graceSeconds, execute: work)
    }

    private func cancelGraceTimer() {
        graceWork?.cancel()
        graceWork = nil
    }

    private func cancelTimers() {
        retryWork?.cancel()
        retryWork = nil
        cancelGraceTimer()
    }

    /// SIGTERM, then SIGKILL if it is still there. `Process` reaps the child
    /// itself (it installs its own SIGCHLD handling), so nothing is ever left
    /// as a zombie; waiting here means "gone" really means gone by the time the
    /// app terminates.
    private func terminateChild(waitFor seconds: TimeInterval) {
        guard let process = child else {
            spawnedAt = nil
            return
        }
        childErrorPipe?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            if seconds > 0 {
                let deadline = Date().addingTimeInterval(seconds)
                while process.isRunning && Date() < deadline {
                    usleep(50_000)
                }
                if process.isRunning {
                    Log.shared.write("ssh did not stop for SIGTERM; sending SIGKILL")
                    kill(process.processIdentifier, SIGKILL)
                    let hardDeadline = Date().addingTimeInterval(1)
                    while process.isRunning && Date() < hardDeadline {
                        usleep(50_000)
                    }
                }
            }
        }
        child = nil
        childErrorPipe = nil
        spawnedAt = nil
    }
}
