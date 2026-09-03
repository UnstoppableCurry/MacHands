import Foundation
import ServiceManagement
import MacHandsCore

/// App 碰到的每一条路径。
enum Paths {

    static var home: URL {
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// ~/Library/Application Support/MacHands —— 配置(**不含私钥**,私钥在 Keychain)。
    static var supportDir: URL {
        return home.appendingPathComponent("Library/Application Support/MacHands", isDirectory: true)
    }

    static var settingsFile: URL {
        return supportDir.appendingPathComponent("settings.json")
    }

    /// SPEC §7.6:~/Library/Logs/MacHands/app.log
    static var logDir: URL {
        return home.appendingPathComponent("Library/Logs/MacHands", isDirectory: true)
    }

    static var appLog: URL {
        return logDir.appendingPathComponent("app.log")
    }

    static var auditLog: URL {
        return logDir.appendingPathComponent("audit.log")
    }

    @discardableResult
    static func ensureDirectory(_ url: URL, permissions: Int) -> Bool {
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: url.path) {
                try fm.createDirectory(at: url,
                                       withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: permissions])
            }
            return true
        } catch {
            return false
        }
    }
}

/// 一个配对过的 agent(SPEC §4.2:配对成功即记入"已授权 agent"列表,可撤销)。
struct AuthorizedAgent: Codable, Equatable {
    var id: String
    var name: String
    var edPub: String
    var xPub: String
    var fromIP: String
    var pairedAt: Double
    var lastCommand: String?
    var lastCommandAt: Double?

    var displayName: String {
        return name.isEmpty ? String(id.prefix(8)) : name
    }
}

/// 持久化配置。**不含任何私钥**。
struct Settings: Codable, Equatable {

    static let defaultRelayURL = "ws://134.199.230.126:8443"

    var relayURL: String
    var macName: String
    var agents: [AuthorizedAgent]
    var policy: PolicyState
    var launchAtLogin: Bool
    var license: String
    /// 首启自动打开主窗口一次(SPEC §7.2),之后不再抢。
    var seenWelcome: Bool
    /// SPEC §2:中继的 Ed25519 公钥,首次连接就 pin;以后对不上直接拒。
    var pinnedRelayKey: String

    static func makeDefault() -> Settings {
        return Settings(relayURL: Settings.defaultRelayURL,
                        macName: Settings.suggestedMacName(),
                        agents: [],
                        policy: PolicyState(),
                        launchAtLogin: true,
                        license: "",
                        seenWelcome: false,
                        pinnedRelayKey: "")
    }

    init(relayURL: String, macName: String, agents: [AuthorizedAgent],
         policy: PolicyState, launchAtLogin: Bool, license: String, seenWelcome: Bool,
         pinnedRelayKey: String) {
        self.relayURL = relayURL
        self.macName = macName
        self.agents = agents
        self.policy = policy
        self.launchAtLogin = launchAtLogin
        self.license = license
        self.seenWelcome = seenWelcome
        self.pinnedRelayKey = pinnedRelayKey
    }

    /// 旧版本写的文件不会有新键;缺一个键不该让整份配置读不出来。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        relayURL = try c.decodeIfPresent(String.self, forKey: .relayURL) ?? Settings.defaultRelayURL
        macName = try c.decodeIfPresent(String.self, forKey: .macName) ?? Settings.suggestedMacName()
        agents = try c.decodeIfPresent([AuthorizedAgent].self, forKey: .agents) ?? []
        policy = try c.decodeIfPresent(PolicyState.self, forKey: .policy) ?? PolicyState()
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
        license = try c.decodeIfPresent(String.self, forKey: .license) ?? ""
        seenWelcome = try c.decodeIfPresent(Bool.self, forKey: .seenWelcome) ?? false
        pinnedRelayKey = try c.decodeIfPresent(String.self, forKey: .pinnedRelayKey) ?? ""
    }

    static func suggestedMacName() -> String {
        let raw = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Mac" : trimmed
    }

    /// `ws://host:port` → 加上 `/v1/mac`(SPEC §4)。
    var macEndpoint: URL? {
        var text = relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = Settings.defaultRelayURL }
        while text.hasSuffix("/") { text.removeLast() }
        guard text.hasPrefix("ws://") || text.hasPrefix("wss://") else { return nil }
        return URL(string: text + RelayMessages.macPath)
    }

    /// 配对块里的 `<host>:<port>`。
    var relayEndpointForCode: String {
        var text = relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = Settings.defaultRelayURL }
        for prefix in ["wss://", "ws://"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        while text.hasSuffix("/") { text.removeLast() }
        if let slash = text.firstIndex(of: "/") { text = String(text[text.startIndex..<slash]) }
        if !text.contains(":") { text += ":8443" }
        return text
    }
}

/// 读写 `Settings`。任何线程都能碰。
final class SettingsStore {

    static let shared = SettingsStore()

    private let queue = DispatchQueue(label: "app.machands.settings")
    private var cached: Settings

    /// 每次落盘后回调(主线程无关,调用方自己 hop)。
    var onChange: ((Settings) -> Void)?

    private init() {
        self.cached = SettingsStore.loadFromDisk() ?? Settings.makeDefault()
    }

    var current: Settings {
        return queue.sync { cached }
    }

    @discardableResult
    func update(_ body: (inout Settings) -> Void) -> Settings {
        let next: Settings = queue.sync {
            var draft = cached
            body(&draft)
            cached = draft
            SettingsStore.saveToDisk(draft)
            return draft
        }
        onChange?(next)
        return next
    }

    private static func loadFromDisk() -> Settings? {
        guard let data = try? Data(contentsOf: Paths.settingsFile) else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: data)
    }

    private static func saveToDisk(_ settings: Settings) {
        Paths.ensureDirectory(Paths.supportDir, permissions: 0o700)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        let fm = FileManager.default
        let tmp = Paths.supportDir.appendingPathComponent("settings.json.tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if fm.fileExists(atPath: Paths.settingsFile.path) {
                _ = try fm.replaceItemAt(Paths.settingsFile, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: Paths.settingsFile)
            }
            try? fm.setAttributes([.posixPermissions: 0o600],
                                  ofItemAtPath: Paths.settingsFile.path)
        } catch {
            try? fm.removeItem(at: tmp)
            Log.shared.write("settings save failed: \(error.localizedDescription)")
        }
    }
}

/// SPEC §7.6:开机自启用 `SMAppService.mainApp`(macOS 13+)。
/// 只有真正的 .app bundle 能注册;裸二进制里说清楚,不假装成功。
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
        guard isBundled else { return .unavailable("not running from a .app bundle") }
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

    /// 成功返回 nil,失败返回一句人话。
    static func set(_ enabled: Bool) -> String? {
        guard isBundled else {
            return L("err.notBundled")
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
