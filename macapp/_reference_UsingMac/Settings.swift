import Foundation
import ServiceManagement

/// Every path and name the app touches, in one place.
///
/// The layout is fixed by RULINGS.md R4 — the app and the shell installer
/// (`bootstrap/install.sh`) must be indistinguishable from the server's point of
/// view, and `bootstrap/uninstall.sh` / `mac uninstall` must be able to clean up
/// after either one:
///
///   launchd Label   com.using-mac.tunnel.<name>
///   plist           ~/Library/LaunchAgents/com.using-mac.tunnel.<name>.plist
///   helper          ~/.local/bin/mac-tunnel
///   tunnel key      ~/.ssh/id_ed25519_usingmac          (0600, ed25519, no passphrase)
///   config          ~/.using-mac-tunnel.conf            (0600, never secrets)
///   log             ~/Library/Logs/using-mac-tunnel-<name>.log
///   authorized_keys line ends with ` # using-mac:<name>`
///
/// This app does not install a LaunchAgent of its own — it *is* the supervisor —
/// but it has to know those names to stand the shell installation down.
enum Paths {

    static var home: URL {
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// ~/Library/Application Support/UsingMac — the app's own state, which is
    /// not part of the shell contract, so it keeps the app's own name.
    static var supportDir: URL {
        return home.appendingPathComponent("Library/Application Support/UsingMac", isDirectory: true)
    }

    static var configFile: URL {
        return supportDir.appendingPathComponent("config.json")
    }

    /// R4: ~/Library/Logs/using-mac-tunnel-<name>.log — one file per Mac name,
    /// which is exactly what `bootstrap/logrotate.sh`'s `using-mac-tunnel*.log`
    /// glob is meant to find.
    static var logDir: URL {
        return home.appendingPathComponent("Library/Logs", isDirectory: true)
    }

    static func logFile(name: String) -> URL {
        let safe = Config.isValid(name: name) ? name : "unnamed"
        return logDir.appendingPathComponent("using-mac-tunnel-\(safe).log")
    }

    static var sshDir: URL {
        return home.appendingPathComponent(".ssh", isDirectory: true)
    }

    /// R4: ~/.ssh/id_ed25519_usingmac
    static var identityFile: URL {
        return sshDir.appendingPathComponent("id_ed25519_usingmac")
    }

    static var identityPublicFile: URL {
        return sshDir.appendingPathComponent("id_ed25519_usingmac.pub")
    }

    /// The key name used by the earliest shell drafts. Only ever read, never
    /// written: a Mac carrying one is adopted rather than re-keyed, because
    /// re-keying would invalidate the authorisation already on the server.
    static var legacyIdentityFile: URL {
        return sshDir.appendingPathComponent("using-mac-tunnel")
    }

    static var authorizedKeys: URL {
        return sshDir.appendingPathComponent("authorized_keys")
    }

    /// The tunnel's own known_hosts. Deliberately not ~/.ssh/known_hosts: what
    /// this tunnel trusts is the app's business, and mixing it into the user's
    /// file makes both harder to reason about.
    static var knownHosts: URL {
        return supportDir.appendingPathComponent("known_hosts")
    }

    /// R4: ~/.using-mac-tunnel.conf (0600). Shared with the shell install — the
    /// app reads it to adopt an existing setup and rewrites it after enrolling,
    /// so `uninstall.sh` finds the same facts either way. Never holds secrets.
    static var tunnelConf: URL {
        return home.appendingPathComponent(".using-mac-tunnel.conf")
    }

    /// R3/R4: ~/.local/bin/mac-tunnel — the shell install's start/stop switch.
    /// The app never writes it; its presence is how we notice that install.
    static var helperScript: URL {
        return home.appendingPathComponent(".local/bin/mac-tunnel")
    }

    static var launchAgentsDir: URL {
        return home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    /// R4: com.using-mac.tunnel.<name>
    static func agentLabel(name: String) -> String {
        return "com.using-mac.tunnel.\(name)"
    }

    static func agentPlist(label: String) -> URL {
        return launchAgentsDir.appendingPathComponent("\(label).plist")
    }

    /// Every label a shell installation may be running under, newest first.
    ///
    /// `com.using-mac.tunnel.<name>` is the R4 name; `com.usingmac.tunnel.<name>`
    /// is what `bootstrap/install.sh` still writes at the time of writing; the
    /// bare `com.using-mac.tunnel` is the single-Mac layout that came first.
    /// Reading tolerantly costs nothing; missing one means two ssh clients fight
    /// over the same remote port forever.
    static func standDownLabels(name: String) -> [String] {
        var labels: [String] = []
        if Config.isValid(name: name) {
            labels.append(agentLabel(name: name))
            labels.append("com.usingmac.tunnel.\(name)")
        }
        labels.append("com.using-mac.tunnel")
        return labels
    }

    @discardableResult
    static func ensureDirectory(_ url: URL, permissions: Int) -> Bool {
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: url.path) {
                try fm.createDirectory(at: url,
                                       withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: permissions])
            } else {
                try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            }
            return true
        } catch {
            return false
        }
    }
}

/// Persisted configuration. Deliberately contains **no secrets**: the private
/// key stays in ~/.ssh at 0600, and the server password is never stored
/// anywhere at all — not here, not in UserDefaults, not in the log.
struct Config: Codable, Equatable {

    var serverHost: String
    var macName: String
    var tunnelUser: String
    var tunnelPort: Int
    var identityPath: String
    var enrolled: Bool
    var launchAtLogin: Bool
    var paused: Bool
    /// R10: the sshd port the tunnel dials. 22 unless the network blocks it and
    /// the server was told to listen somewhere else as well (443, 2222, …).
    var serverSSHPort: Int
    /// R10: an optional `ProxyCommand` line, passed to ssh with -o. Empty means
    /// "dial the server directly". We never touch the user's ~/.ssh/config.
    var proxyCommand: String

    static let portMin = 2201
    static let portMax = 2299
    static let defaultServerHost = "134.199.230.126"
    static let defaultTunnelUser = "tunnel"
    static let defaultServerSSHPort = 22
    /// Where the enrolment endpoint listens when the pairing block does not say.
    static let defaultEnrollPort = 8765

    static func makeDefault() -> Config {
        return Config(serverHost: Config.defaultServerHost,
                      macName: Config.suggestedMacName(),
                      tunnelUser: Config.defaultTunnelUser,
                      tunnelPort: 0,
                      identityPath: Paths.identityFile.path,
                      enrolled: false,
                      launchAtLogin: true,
                      paused: false,
                      serverSSHPort: Config.defaultServerSSHPort,
                      proxyCommand: "")
    }

    init(serverHost: String, macName: String, tunnelUser: String, tunnelPort: Int,
         identityPath: String, enrolled: Bool, launchAtLogin: Bool, paused: Bool,
         serverSSHPort: Int, proxyCommand: String) {
        self.serverHost = serverHost
        self.macName = macName
        self.tunnelUser = tunnelUser
        self.tunnelPort = tunnelPort
        self.identityPath = identityPath
        self.enrolled = enrolled
        self.launchAtLogin = launchAtLogin
        self.paused = paused
        self.serverSSHPort = serverSSHPort
        self.proxyCommand = proxyCommand
    }

    /// A config.json written by an earlier build will not carry every key;
    /// decoding must not fail over a field that did not exist yet.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverHost    = try c.decodeIfPresent(String.self, forKey: .serverHost) ?? Config.defaultServerHost
        macName       = try c.decodeIfPresent(String.self, forKey: .macName) ?? Config.suggestedMacName()
        tunnelUser    = try c.decodeIfPresent(String.self, forKey: .tunnelUser) ?? Config.defaultTunnelUser
        tunnelPort    = try c.decodeIfPresent(Int.self, forKey: .tunnelPort) ?? 0
        identityPath  = try c.decodeIfPresent(String.self, forKey: .identityPath) ?? Paths.identityFile.path
        enrolled      = try c.decodeIfPresent(Bool.self, forKey: .enrolled) ?? false
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
        paused        = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        serverSSHPort = try c.decodeIfPresent(Int.self, forKey: .serverSSHPort) ?? Config.defaultServerSSHPort
        proxyCommand  = try c.decodeIfPresent(String.self, forKey: .proxyCommand) ?? ""
    }

    /// `bin/mac` rejects anything outside [A-Za-z0-9_-], so suggest a name it
    /// will actually accept rather than letting the user discover it later.
    static func sanitize(name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        var out = ""
        for ch in name {
            if allowed.contains(ch) {
                out.append(ch)
            } else if ch == " " || ch == "." || ch == "\u{2019}" || ch == "'" {
                out.append("-")
            }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        return out
    }

    static func isValid(name: String) -> Bool {
        if name.isEmpty { return false }
        if name.hasPrefix("-") { return false }
        return name == sanitize(name: name)
    }

    private static func suggestedMacName() -> String {
        let raw = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let cleaned = sanitize(name: raw)
        return cleaned.isEmpty ? "mac" : cleaned
    }

    var identityURL: URL {
        return URL(fileURLWithPath: (identityPath as NSString).expandingTildeInPath)
    }

    /// True when there is enough here to actually start ssh.
    var isRunnable: Bool {
        return enrolled
            && !serverHost.isEmpty
            && !tunnelUser.isEmpty
            && tunnelPort >= Config.portMin
            && tunnelPort <= Config.portMax
            && serverSSHPort > 0
            && serverSSHPort <= 65535
    }
}

/// Loads/stores `Config`. All access is serialised; callers may touch it from
/// any thread.
final class ConfigStore {

    static let shared = ConfigStore()

    private let queue = DispatchQueue(label: "com.using-mac.config")
    private var cached: Config

    private init() {
        self.cached = ConfigStore.loadFromDisk() ?? Config.makeDefault()
    }

    var current: Config {
        return queue.sync { cached }
    }

    /// Mutate + persist in one step. Returns the stored value.
    @discardableResult
    func update(_ body: (inout Config) -> Void) -> Config {
        return queue.sync {
            var next = cached
            body(&next)
            cached = next
            ConfigStore.saveToDisk(next)
            return next
        }
    }

    private static func loadFromDisk() -> Config? {
        guard let data = try? Data(contentsOf: Paths.configFile) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    private static func saveToDisk(_ config: Config) {
        Paths.ensureDirectory(Paths.supportDir, permissions: 0o700)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        let fm = FileManager.default
        // temp + rename: a reader never sees half a file.
        let tmp = Paths.supportDir.appendingPathComponent("config.json.tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            // replaceItemAt needs something to replace; on the very first save
            // there is nothing there yet.
            if fm.fileExists(atPath: Paths.configFile.path) {
                _ = try fm.replaceItemAt(Paths.configFile, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: Paths.configFile)
            }
            try? fm.setAttributes([.posixPermissions: 0o600],
                                  ofItemAtPath: Paths.configFile.path)
        } catch {
            try? fm.removeItem(at: tmp)
            Log.shared.write("config save failed: \(error.localizedDescription)")
        }
    }
}

/// "Open at login", via the modern (macOS 13+) API.
///
/// SMAppService only works for a real .app bundle. When the executable is run
/// straight out of .build/release there is nothing to register, and saying so
/// plainly beats a silent no-op.
enum LoginItem {

    enum Status {
        case enabled
        case disabled
        case requiresApproval
        case unavailable(String)
    }

    static var isBundled: Bool {
        return Bundle.main.bundleIdentifier != nil
            && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static func status() -> Status {
        guard isBundled else {
            return .unavailable("not running from a .app bundle")
        }
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .disabled
        case .notFound:
            return .unavailable("login item not found")
        @unknown default:
            return .unavailable("unknown status")
        }
    }

    /// Returns nil on success, or a human sentence describing what went wrong.
    static func set(_ enabled: Bool) -> String? {
        guard isBundled else {
            return "Open at login needs the packaged app (UsingMac.app), not the bare build product."
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
