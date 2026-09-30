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

    // 没有默认中继。用户必须自己填自建地址,不要在这里写任何公共 ws:// URL。
    static let defaultRelayURL = ""

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
    /// UI language: `en` (default), `zh`, or `auto` (follow the system; unknown → English).
    /// A change takes effect on the next launch.
    var language: String
    /// SPEC §10.2:用户点过「授权并验证」的时刻(毫秒)。nil = 还没做过一次授权。
    var authorizedAt: Double?
    /// 内置自动更新。关掉之后只是不主动查,菜单里手动「检查更新…」照旧能用。
    var autoUpdate: Bool
    /// 上一次查更新的时刻(毫秒)。
    var lastUpdateCheck: Double?
    /// appcast 的来源,**必须是 https**。更新包本身有 Ed25519 验签挡掉包,
    /// 但明文 HTTP 会把"这台 Mac 装的是哪个版本"泄露给路上的任何人。
    var updateHost: String

    static let defaultUpdateHost = "https://machands.app"

    static func makeDefault() -> Settings {
        return Settings(relayURL: Settings.defaultRelayURL,
                        macName: Settings.suggestedMacName(),
                        agents: [],
                        policy: PolicyState(),
                        launchAtLogin: true,
                        license: "",
                        seenWelcome: false,
                        pinnedRelayKey: "",
                        language: "en",
                        authorizedAt: nil,
                        autoUpdate: true,
                        lastUpdateCheck: nil,
                        updateHost: Settings.defaultUpdateHost)
    }

    init(relayURL: String, macName: String, agents: [AuthorizedAgent],
         policy: PolicyState, launchAtLogin: Bool, license: String, seenWelcome: Bool,
         pinnedRelayKey: String, language: String, authorizedAt: Double? = nil,
         autoUpdate: Bool = true, lastUpdateCheck: Double? = nil,
         updateHost: String = Settings.defaultUpdateHost) {
        self.relayURL = relayURL
        self.macName = macName
        self.agents = agents
        self.policy = policy
        self.launchAtLogin = launchAtLogin
        self.license = license
        self.seenWelcome = seenWelcome
        self.pinnedRelayKey = pinnedRelayKey
        self.language = language
        self.authorizedAt = authorizedAt
        self.autoUpdate = autoUpdate
        self.lastUpdateCheck = lastUpdateCheck
        self.updateHost = updateHost
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
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
        authorizedAt = try c.decodeIfPresent(Double.self, forKey: .authorizedAt)
        autoUpdate = try c.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? true
        lastUpdateCheck = try c.decodeIfPresent(Double.self, forKey: .lastUpdateCheck)
        let host = try c.decodeIfPresent(String.self, forKey: .updateHost) ?? Settings.defaultUpdateHost
        // 从旧配置里读到的 host 也得过一遍 https 检查,别让手改过的文件把更新降级成明文。
        updateHost = host.hasPrefix("https://") ? host : Settings.defaultUpdateHost
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
        case .notRegistered, .notFound:
            // 真机踩过的坑:`.notFound` 不代表开关该锁死。重装/改签名之后 Background
            // Task Management 有时没同步上,SMAppService 会报 notFound,但
            // `register()` 照样能成功——不该在这里替用户判死刑,让他能点,
            // 点了真失败再由 `set(_:)` 的错误提示说明原因。
            return .disabled
        @unknown default:
            return .disabled
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
