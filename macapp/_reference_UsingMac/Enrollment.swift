import Foundation

enum EnrollmentError: LocalizedError {
    case badName(String)
    case emptyHost
    case badHost(String)
    case badProxyCommand
    case pairing(PairingError)
    case keygenFailed(String)
    case missingKey(String)
    case writeKeyFailed(path: String, reason: String)
    case writeAuthorizedKeysFailed(reason: String)
    case writeConfFailed(reason: String)
    case enrollUnreachable(url: String, detail: String)
    case enrollRefused(detail: String)
    case enrollBadAnswer(detail: String)
    case badServerPubkey
    case portMismatch(expected: Int, got: Int)

    var errorDescription: String? {
        switch self {
        case .badName(let name):
            return Lf("err.badName", name)
        case .emptyHost:
            return L("err.emptyHost")
        case .badHost(let host):
            return Lf("err.badHost", host)
        case .badProxyCommand:
            return L("err.badProxy")
        case .pairing(let inner):
            return inner.errorDescription
        case .keygenFailed(let reason):
            return Lf("err.keygen", reason)
        case .missingKey(let path):
            return Lf("next.missingIdentity", path)
        case .writeKeyFailed(let path, let reason):
            return Lf("err.writeKey", path, reason)
        case .writeAuthorizedKeysFailed(let reason):
            return Lf("err.writeAuthorizedKeys", reason)
        case .writeConfFailed(let reason):
            return Lf("err.writeConf", reason)
        case .enrollUnreachable(let url, let detail):
            return Lf("err.enrollUnreachable", url, detail)
        case .enrollRefused(let detail):
            return Lf("err.enrollRefused", detail)
        case .enrollBadAnswer(let detail):
            return Lf("err.enrollBadAnswer", detail)
        case .badServerPubkey:
            return L("err.badServerPubkey")
        case .portMismatch(let expected, let got):
            // "allocated <got> … the block said <expected>"
            return Lf("err.portMismatch", got, expected)
        }
    }
}

/// Everything that happens once, at enrolment.
///
/// RULINGS.md R8 — **the private key never travels**:
///
///   1. this Mac runs `ssh-keygen` and writes `~/.ssh/id_ed25519_usingmac` (0600);
///   2. it sends only the **public** key and the single-use pairing code to the
///      server's enrolment endpoint;
///   3. the server checks the code (exists / not expired / not used), writes the
///      public key into `~tunnel/.ssh/authorized_keys` in R9's exact shape —
///      including `permitopen="127.0.0.1:1"`, without which `restrict` plus
///      `port-forwarding` would hand a stolen key `-L` and `-D` as well — burns
///      the code, and answers with its own public key;
///   4. that server key is authorised here so the server can ssh **in**.
///
/// No password is asked for at any point: not a server password, not the Mac's,
/// not sudo. The private key is never logged, never shown in the UI, never put
/// in UserDefaults, and never passed as a command-line argument.
///
/// R12 — the direction is one-way. The tunnel this Mac dials out is a pipe, not
/// a permission: the `tunnel` account is nologin with `command="/bin/false"` and
/// its only capability is binding one loopback port on the server. The Mac dials
/// out purely because it sits behind NAT.
enum Enroller {

    // MARK: - the two markers (R4/R9; byte-identical to the shell side)

    /// The trailing key comment on the **server**'s `~tunnel/.ssh/authorized_keys`
    /// line. `lib/setup.sh:authorize_tunnel_key` and `mac uninstall` both match
    /// `using-mac:<name>` as a whole field. The app never writes that file — the
    /// enrolment endpoint does — but it is the contract both sides answer to.
    static func serverMarker(for name: String) -> String {
        return "using-mac:\(name)"
    }

    /// What ends this **Mac**'s `~/.ssh/authorized_keys` line, byte for byte the
    /// same as `install.sh`'s `AK_LINE="$SRV_KEYPART # $MARKER"`, so re-running
    /// either one replaces the line instead of adding a second copy.
    static func macMarker(for name: String) -> String {
        return "# using-mac:\(name)"
    }

    /// The comment baked into this Mac's own tunnel key, matching
    /// `install.sh`'s `-C "using-mac-tunnel-<name>"`. `uninstall.sh` removes an
    /// authorized_keys line whose comment field is exactly this.
    static func keyComment(for name: String) -> String {
        return "using-mac-tunnel-\(name)"
    }

    // MARK: - validation

    /// A host we are willing to put into an ssh argument list and into a
    /// `KEY="value"` line in a config file. Hostnames and IPv4/IPv6 literals
    /// need nothing outside this set, and anything else is far more likely to
    /// be a paste accident than a real address.
    static func isValidHost(_ host: String) -> Bool {
        if host.isEmpty || host.count > 255 { return false }
        if host.hasPrefix("-") { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:-_[]")
        return host.allSatisfy { allowed.contains($0) }
    }

    /// R10: a ProxyCommand is the user's own command line, handed to ssh with
    /// `-o ProxyCommand=…` (ssh runs it through /bin/sh itself). All we insist
    /// on is that it is one line and not absurdly long.
    static func isValidProxyCommand(_ command: String) -> Bool {
        if command.isEmpty { return true }
        if command.count > 512 { return false }
        return !command.contains("\n") && !command.contains("\r") && !command.contains("\0")
    }

    // MARK: - the Mac's own key pair (R8 step 1)

    /// Makes sure ~/.ssh/id_ed25519_usingmac exists (0600, ed25519, no
    /// passphrase) and returns its **public** key line.
    ///
    /// An existing key is kept: the server authorised *that* key, and quietly
    /// replacing it would lock this Mac out until someone re-enrolled it.
    /// Nothing here ever reads, logs or returns the private half.
    @discardableResult
    static func ensureKeyPair(macName: String) throws -> String {
        guard Paths.ensureDirectory(Paths.sshDir, permissions: 0o700) else {
            throw EnrollmentError.writeKeyFailed(path: Paths.sshDir.path,
                                                 reason: "cannot create ~/.ssh")
        }
        let fm = FileManager.default
        let key = Paths.identityFile
        let pub = Paths.identityPublicFile

        if !fm.fileExists(atPath: key.path) {
            // -N "" is an empty passphrase: launchd has no one to ask, and a
            // passphrase-protected key would simply hang at every boot.
            let result = Shell.run("/usr/bin/ssh-keygen",
                                   ["-t", "ed25519",
                                    "-N", "",
                                    "-C", keyComment(for: macName),
                                    "-f", key.path],
                                   timeout: 30)
            guard result.ok, fm.fileExists(atPath: key.path) else {
                // `complaint` is ssh-keygen's own words about paths and
                // permissions; it never contains key material.
                throw EnrollmentError.keygenFailed(result.complaint)
            }
            Log.shared.write("generated a new tunnel key pair at \(key.path) (the private half stays here and is never logged)")
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)

        if !fm.fileExists(atPath: pub.path) {
            // Derive the public half rather than giving up: a key restored from
            // a backup often arrives without its .pub.
            let derived = Shell.run("/usr/bin/ssh-keygen", ["-y", "-f", key.path], timeout: 20)
            guard derived.ok, !derived.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EnrollmentError.keygenFailed(derived.complaint)
            }
            let line = derived.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                + " " + keyComment(for: macName) + "\n"
            try? fm.removeItem(at: pub)
            fm.createFile(atPath: pub.path, contents: line.data(using: .utf8),
                          attributes: [.posixPermissions: 0o644])
        }
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pub.path)

        guard let text = try? String(contentsOf: pub, encoding: .utf8) else {
            throw EnrollmentError.missingKey(pub.path)
        }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, line.split(separator: " ").count >= 2,
              looksLikePublicKey(line) else {
            throw EnrollmentError.missingKey(pub.path)
        }
        return line
    }

    // MARK: - enrolling with a pairing code (R8 steps 2-4)

    /// Sends `{code, pubkey, name}` to the enrolment endpoint and installs
    /// whatever comes back. Blocking; call from a background queue.
    ///
    /// Endpoint contract (`bin/enroll-server`, final):
    ///
    ///     POST <enroll_url>            Content-Type: application/json
    ///     {"code": "<32 hex>", "pubkey": "ssh-ed25519 AAAA… using-mac-tunnel-<name>",
    ///      "name": "<mac name>"}
    ///
    ///     200 {"ok": true, "name": "mbp", "tunnel_port": 2201, "tunnel_user": "tunnel",
    ///          "server_host": "…", "server_pubkey": "ssh-ed25519 AAAA… using-mac-server"}
    ///     400 {"ok": false, "error": "enrollment_failed", "message": "<human sentence>"}
    ///
    /// Every failure is the same `enrollment_failed`: telling "no such code"
    /// from "already used" from "expired" apart would turn this into an oracle
    /// for guessing codes. The app therefore shows the server's `message` and
    /// does not try to classify it.
    ///
    /// `name` and `tunnel_port` from the answer **win** over what was typed or
    /// pasted — they are what the server actually authorised. Returns the
    /// request as installed, so the caller can show the final values.
    @discardableResult
    static func enroll(with request: PairingRequest) throws -> PairingRequest {
        guard Config.isValid(name: request.macName) else {
            throw EnrollmentError.badName(request.macName)
        }
        guard !request.serverHost.isEmpty else { throw EnrollmentError.emptyHost }
        guard isValidHost(request.serverHost) else {
            throw EnrollmentError.badHost(request.serverHost)
        }
        guard isValidProxyCommand(request.proxyCommand) else {
            throw EnrollmentError.badProxyCommand
        }
        guard Pairing.isValidCode(request.code) else {
            throw EnrollmentError.pairing(.badCode)
        }

        Log.shared.use(name: request.macName)
        let publicKey = try ensureKeyPair(macName: request.macName)

        if request.enrollURL.scheme?.lowercased() == "http" {
            // R8's residual risk, stated where it happens rather than only in a
            // document: over plain HTTP, whoever can read the code inside its
            // 30-day life can spend it on a key of their own.
            Log.shared.write("enrolling over plain HTTP (\(request.enrollURL.host ?? "?")) — the pairing code is not encrypted in transit")
        }

        let answer = try post(publicKey: publicKey, request: request)

        // The answer is authoritative for the name and the port: they are what
        // the server wrote into `permitlisten=` and into its own registry. A
        // difference is worth a log line — it usually means a stale paste — but
        // never worth arguing with.
        var installed = request
        if answer.tunnelPort != request.tunnelPort {
            Log.shared.write("server says port \(answer.tunnelPort), the pasted block said \(request.tunnelPort); the server wins")
        }
        installed.tunnelPort = answer.tunnelPort
        if !answer.macName.isEmpty && answer.macName != request.macName {
            Log.shared.write("server registered this Mac as \(answer.macName), not \(request.macName); the server wins")
            installed.macName = answer.macName
            Log.shared.use(name: answer.macName)
            // The line we may have written under the old name would otherwise
            // sit in authorized_keys forever: `mac uninstall <new name>` only
            // knows the new marker.
            deauthorize(macName: request.macName)
        }
        installed.tunnelUser = answer.tunnelUser.isEmpty ? request.tunnelUser : answer.tunnelUser
        // The address is the one thing a human can see is wrong: the server only
        // *guesses* its own public address, while the user typed one that
        // demonstrably reached it. So the typed one stays; a difference is only
        // noted.
        if !answer.serverHost.isEmpty && answer.serverHost != request.serverHost {
            Log.shared.write("server calls itself \(answer.serverHost); keeping the address that worked: \(request.serverHost)")
        }

        try authorizeServerKey(answer.serverPublicKey, macName: installed.macName)
        try writeTunnelConf(installed)

        ConfigStore.shared.update { config in
            config.serverHost = installed.serverHost
            config.macName = installed.macName
            config.tunnelUser = installed.tunnelUser
            config.tunnelPort = installed.tunnelPort
            config.serverSSHPort = installed.serverSSHPort
            config.proxyCommand = installed.proxyCommand
            config.identityPath = Paths.identityFile.path
            config.enrolled = true
            config.paused = false
        }
        Log.shared.write("enrolled name=\(installed.macName) port=\(installed.tunnelPort) server=\(installed.serverHost):\(installed.serverSSHPort) (pairing code spent; no key material logged)")
        return installed
    }

    /// The one network call. Blocking, with its own timeout.
    private static func post(publicKey: String, request: PairingRequest) throws -> PairingResult {
        var urlRequest = URLRequest(url: request.enrollURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("UsingMac.app", forHTTPHeaderField: "User-Agent")
        urlRequest.timeoutInterval = 20

        // `user` is this Mac's login name. The server writes it into its
        // registry so `mac check <name>` ssh's in as the account whose
        // authorized_keys we are about to add the server's key to. Without it
        // the server keeps whatever `mac setup --user` guessed (default root)
        // and every later check fails with "key rejected" while the tunnel is
        // perfectly healthy.
        let body: [String: Any] = [
            "code": request.code,
            "pubkey": publicKey,
            "name": request.macName,
            "user": NSUserName()
        ]
        guard let requestBody = try? JSONSerialization.data(withJSONObject: body) else {
            throw EnrollmentError.enrollBadAnswer(detail: "cannot encode the request")
        }
        urlRequest.httpBody = requestBody

        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        var status = 0
        var transportError: Error?

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: urlRequest) { data, response, error in
            payload = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            transportError = error
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 35) == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            throw EnrollmentError.enrollUnreachable(url: request.enrollURL.absoluteString,
                                                    detail: Lf("err.timeout", 35))
        }
        session.finishTasksAndInvalidate()

        if let error = transportError {
            throw EnrollmentError.enrollUnreachable(url: request.enrollURL.absoluteString,
                                                    detail: error.localizedDescription)
        }

        let text = payload.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        guard let answerBody = payload,
              let object = try? JSONSerialization.jsonObject(with: answerBody),
              let dict = object as? [String: Any] else {
            let snippet = text.split(separator: "\n").prefix(2).joined(separator: " ")
            throw EnrollmentError.enrollBadAnswer(detail: snippet.isEmpty
                                                  ? "HTTP \(status)"
                                                  : "HTTP \(status): \(snippet)")
        }

        // Failure is always {"ok": false, "error": "enrollment_failed", …}: one
        // code for every cause, on purpose. Show the server's sentence; do not
        // try to classify what it deliberately did not distinguish.
        let ok = (dict["ok"] as? Bool) ?? (status >= 200 && status < 300)
        if !ok || status >= 400 {
            let message = (dict["message"] as? String)
                ?? (dict["error"] as? String)
                ?? "HTTP \(status)"
            throw EnrollmentError.enrollRefused(detail: message)
        }

        let serverKey = firstString(dict, ["server_pubkey", "serverPubkey", "server_public_key"]) ?? ""
        guard looksLikePublicKey(serverKey) else {
            throw EnrollmentError.badServerPubkey
        }
        // `tunnel_port` is the contract's spelling; `port` is tolerated.
        var port = request.tunnelPort
        if let reported = firstInt(dict, ["tunnel_port", "port", "tunnelPort"]) {
            guard reported >= Config.portMin, reported <= Config.portMax else {
                throw EnrollmentError.portMismatch(expected: request.tunnelPort, got: reported)
            }
            port = reported
        }
        // Neither side named a usable port: the endpoint left it out and the
        // pasted block had none either. Enrolling anyway would leave a config
        // that can never start ssh.
        guard port >= Config.portMin, port <= Config.portMax else {
            throw EnrollmentError.pairing(.badPort(port))
        }
        // The server's name is authoritative, but only if it is a name the rest
        // of the toolchain accepts; a junk one would poison every path we build
        // from it (log file, conf, launchd label, authorized_keys marker).
        var name = request.macName
        if let reported = firstString(dict, ["name", "mac_name", "host"]) {
            guard Config.isValid(name: reported) else {
                throw EnrollmentError.badName(reported)
            }
            name = reported
        }
        let user = firstString(dict, ["tunnel_user", "tunnelUser"]) ?? request.tunnelUser
        let host = firstString(dict, ["server_host", "serverHost", "server"]) ?? ""

        return PairingResult(macName: name,
                             tunnelPort: port,
                             tunnelUser: user,
                             serverHost: Enroller.isValidHost(host) ? host : "",
                             serverPublicKey: serverKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func firstString(_ dict: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func firstInt(_ dict: [String: Any], _ keys: [String]) -> Int? {
        for key in keys {
            if let value = dict[key] as? Int { return value }
            if let text = dict[key] as? String, let value = Int(text) { return value }
        }
        return nil
    }

    // MARK: - letting the server ssh back in

    /// Appends the server's public key to ~/.ssh/authorized_keys, replacing any
    /// previous line for the same key or the same Mac registration.
    ///
    /// Line shape (identical to `install.sh`):
    ///     ssh-ed25519 AAAA… # using-mac:<name>
    private static func authorizeServerKey(_ publicKey: String, macName: String) throws {
        guard Paths.ensureDirectory(Paths.sshDir, permissions: 0o700) else {
            throw EnrollmentError.writeAuthorizedKeysFailed(reason: "cannot create ~/.ssh")
        }
        let blob = keyBlob(of: publicKey)
        guard !blob.isEmpty, looksLikePublicKey(publicKey) else {
            throw EnrollmentError.badServerPubkey
        }
        let path = Paths.authorizedKeys.path
        let fm = FileManager.default

        var lines: [String] = []
        if let existing = try? String(contentsOf: Paths.authorizedKeys, encoding: .utf8) {
            lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }

        let mark = macMarker(for: macName)
        lines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return false }
            if trimmed.hasSuffix(mark) { return false }
            if keyBlob(of: trimmed) == blob { return false }
            return true
        }
        lines.append("\(blob) \(mark)")

        let body = lines.joined(separator: "\n") + "\n"
        guard let data = body.data(using: .utf8) else {
            throw EnrollmentError.writeAuthorizedKeysFailed(reason: "cannot encode file")
        }
        do {
            if !fm.fileExists(atPath: path) {
                fm.createFile(atPath: path, contents: nil,
                              attributes: [.posixPermissions: 0o600])
            }
            try data.write(to: Paths.authorizedKeys, options: [])
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            throw EnrollmentError.writeAuthorizedKeysFailed(reason: error.localizedDescription)
        }
    }

    private static func looksLikePublicKey(_ line: String) -> Bool {
        let prefixes = ["ssh-ed25519 ", "ssh-rsa ", "ecdsa-sha2-", "sk-ssh-", "sk-ecdsa-"]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return prefixes.contains { trimmed.hasPrefix($0) }
    }

    /// "ssh-ed25519 AAAA… comment" -> "ssh-ed25519 AAAA…"; the comment is not
    /// part of the identity of a key.
    private static func keyBlob(of line: String) -> String {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return "" }
        return String(parts[0]) + " " + String(parts[1])
    }

    /// Removes this app's traces from authorized_keys. Used when the user
    /// re-enrols under a different name.
    static func deauthorize(macName: String) {
        guard let existing = try? String(contentsOf: Paths.authorizedKeys, encoding: .utf8) else { return }
        let mark = macMarker(for: macName)
        let kept = existing.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasSuffix(mark)
            }
        let body = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        try? body.write(to: Paths.authorizedKeys, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Paths.authorizedKeys.path)
    }

    // MARK: - ~/.using-mac-tunnel.conf (R4, R10)

    /// The same file `install.sh` writes, with the same keys, so that
    /// `uninstall.sh` (which reads MAC_NAME out of it) cleans up after the app
    /// exactly as it does after the script, and so the `mac-tunnel` helper —
    /// if one is ever installed alongside — reads the same server port and
    /// ProxyCommand the app is using. No secrets ever go in here.
    private static func writeTunnelConf(_ request: PairingRequest) throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let body = """
        # using-mac tunnel config — 由 UsingMac.app 生成,可读可改,别放口令。
        MAC_NAME=\(confValue(request.macName))
        TUNNEL_PORT=\(confValue(String(request.tunnelPort)))
        SERVER_HOST=\(confValue(request.serverHost))
        SERVER_PORT=\(confValue(String(request.serverSSHPort)))
        PROXY_COMMAND=\(confValue(request.proxyCommand))
        TUNNEL_USER=\(confValue(request.tunnelUser))
        MAC_USER=\(confValue(NSUserName()))
        LABEL=\(confValue(Paths.agentLabel(name: request.macName)))
        KEY=\(confValue(Paths.identityFile.path))
        LOG=\(confValue(Paths.logFile(name: request.macName).path))
        MANAGED_BY="UsingMac.app"
        INSTALLED=\(confValue(stamp))

        """
        do {
            let fm = FileManager.default
            if !fm.fileExists(atPath: Paths.tunnelConf.path) {
                fm.createFile(atPath: Paths.tunnelConf.path, contents: nil,
                              attributes: [.posixPermissions: 0o600])
            }
            try body.write(to: Paths.tunnelConf, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o600],
                                  ofItemAtPath: Paths.tunnelConf.path)
        } catch {
            throw EnrollmentError.writeConfFailed(reason: error.localizedDescription)
        }
    }

    /// `"…"` with the four characters a double-quoted shell word still expands.
    /// Names and ports are already validated; a home directory and a
    /// ProxyCommand are not.
    private static func confValue(_ value: String) -> String {
        var escaped = ""
        for ch in value {
            if ch == "\n" || ch == "\r" { continue }
            if ch == "\\" || ch == "\"" || ch == "$" || ch == "`" { escaped.append("\\") }
            escaped.append(ch)
        }
        return "\"\(escaped)\""
    }

    // MARK: - the shell-script install

    /// The one-liner installer leaves a LaunchAgent that runs its own ssh. Two
    /// clients asking for the same remote port means `ExitOnForwardFailure`
    /// kills one of them on every reconnect, forever. So: switch the old job
    /// off — by label, never by pattern-killing processes — and keep the plist
    /// on disk, renamed, so the change is visible and reversible.
    ///
    /// All three label spellings are checked (R4's, install.sh's current one,
    /// and the original single-Mac one).
    @discardableResult
    static func standDownLegacyAgent(macName: String) -> Bool {
        let fm = FileManager.default
        let domain = "gui/\(getuid())"
        var didSomething = false

        for label in Paths.standDownLabels(name: macName) {
            let printed = Shell.run("/bin/launchctl", ["print", "\(domain)/\(label)"], timeout: 8)
            if printed.status == 0 {
                _ = Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], timeout: 8)
                Log.shared.write("legacy LaunchAgent \(label) booted out")
                didSomething = true
            }
            let plist = Paths.agentPlist(label: label)
            guard fm.fileExists(atPath: plist.path) else { continue }
            let parked = plist.deletingLastPathComponent()
                .appendingPathComponent(plist.lastPathComponent + ".disabled-by-UsingMac")
            try? fm.removeItem(at: parked)
            do {
                try fm.moveItem(at: plist, to: parked)
                Log.shared.write("parked \(plist.lastPathComponent) (kept as \(parked.lastPathComponent))")
                didSomething = true
            } catch {
                Log.shared.write("could not park \(plist.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return didSomething
    }

    // MARK: - adopting an existing shell install

    /// The Mac may already be enrolled by the shell installer: the key is in
    /// place, the port is allocated, the server knows the name. In that case
    /// there is nothing to ask the user — read ~/.using-mac-tunnel.conf and take
    /// over from it.
    ///
    /// Returns true when this Mac was adopted. Blocking; call off the main
    /// thread.
    static func adoptExistingShellInstall() -> Bool {
        let fm = FileManager.default
        guard let text = try? String(contentsOf: Paths.tunnelConf, encoding: .utf8) else {
            return false
        }

        var fields: [String: String] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\$", with: "$")
                    .replacingOccurrences(of: "\\`", with: "`")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            fields[key] = value
        }

        guard let name = fields["MAC_NAME"], Config.isValid(name: name),
              let host = fields["SERVER_HOST"], isValidHost(host),
              let portText = fields["TUNNEL_PORT"], let port = Int(portText),
              port >= Config.portMin, port <= Config.portMax else {
            Log.shared.write("found \(Paths.tunnelConf.lastPathComponent) but it is incomplete; asking the user instead")
            return false
        }

        // Which key file that install actually uses. KEY= is authoritative;
        // the R4 path and the oldest draft's path are the fallbacks.
        var identity = Paths.identityFile
        if let keyPath = fields["KEY"], !keyPath.isEmpty {
            let expanded = URL(fileURLWithPath: (keyPath as NSString).expandingTildeInPath)
            if fm.fileExists(atPath: expanded.path) { identity = expanded }
        }
        if !fm.fileExists(atPath: identity.path),
           fm.fileExists(atPath: Paths.legacyIdentityFile.path) {
            identity = Paths.legacyIdentityFile
        }
        guard fm.fileExists(atPath: identity.path) else {
            Log.shared.write("\(Paths.tunnelConf.lastPathComponent) describes \(name) but its key is missing; asking the user instead")
            return false
        }

        let user = fields["TUNNEL_USER"] ?? Config.defaultTunnelUser
        var sshPort = Config.defaultServerSSHPort
        if let text = fields["SERVER_PORT"], let value = Int(text), value > 0, value <= 65535 {
            sshPort = value
        }
        let proxy = fields["PROXY_COMMAND"] ?? ""

        Log.shared.use(name: name)
        ConfigStore.shared.update { config in
            config.macName = name
            config.serverHost = host
            config.tunnelPort = port
            config.tunnelUser = user.isEmpty ? Config.defaultTunnelUser : user
            config.serverSSHPort = sshPort
            config.proxyCommand = isValidProxyCommand(proxy) ? proxy : ""
            config.identityPath = identity.path
            config.enrolled = true
        }
        Log.shared.write("adopted existing shell install name=\(name) port=\(port) server=\(host):\(sshPort) key=\(identity.lastPathComponent)")
        return true
    }
}
