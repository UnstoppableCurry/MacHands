import Foundation
import CryptoKit
import Security

/// 私钥存哪里。Keychain 是正主;测试与"直接跑 .build/release 里的裸二进制"
/// 两种情况下 Keychain 会失败(没有 bundle id / 没有 entitlement),那时退到
/// UserDefaults —— 明确降级,好过静默不工作。
public protocol SecretStore: AnyObject {
    func data(forKey key: String) -> Data?
    @discardableResult func set(_ value: Data, forKey key: String) -> Bool
    func remove(forKey key: String)
}

public final class KeychainStore: SecretStore {

    private let service: String

    public init(service: String = "app.machands.MacHands") {
        self.service = service
    }

    public func data(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    public func set(_ value: Data, forKey key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        _ = SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = value
        // 开机自启后、用户还没解锁前 App 也要能连中继,所以是 AfterFirstUnlock。
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public func remove(forKey key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        _ = SecItemDelete(base as CFDictionary)
    }
}

public final class UserDefaultsSecretStore: SecretStore {

    private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults = UserDefaults.standard,
                prefix: String = "app.machands.secret.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    public func data(forKey key: String) -> Data? {
        return defaults.data(forKey: prefix + key)
    }

    @discardableResult
    public func set(_ value: Data, forKey key: String) -> Bool {
        defaults.set(value, forKey: prefix + key)
        return true
    }

    public func remove(forKey key: String) {
        defaults.removeObject(forKey: prefix + key)
    }
}

/// 先 Keychain,不行就 UserDefaults。写入时两边都写(Keychain 成功时也写一份
/// 到 defaults 是**不行**的 —— 私钥不能落到 plist),所以只有 Keychain 失败
/// 时才退。
public final class FallbackSecretStore: SecretStore {

    private let primary: SecretStore
    private let secondary: SecretStore

    public init(primary: SecretStore = KeychainStore(),
                secondary: SecretStore = UserDefaultsSecretStore()) {
        self.primary = primary
        self.secondary = secondary
    }

    public func data(forKey key: String) -> Data? {
        if let value = primary.data(forKey: key) { return value }
        return secondary.data(forKey: key)
    }

    @discardableResult
    public func set(_ value: Data, forKey key: String) -> Bool {
        if primary.set(value, forKey: key) {
            secondary.remove(forKey: key)
            return true
        }
        return secondary.set(value, forKey: key)
    }

    public func remove(forKey key: String) {
        primary.remove(forKey: key)
        secondary.remove(forKey: key)
    }
}

/// 一台 Mac 的身份:macId + Ed25519 签名密钥 + X25519 加密密钥(SPEC §2)。
public final class Identity {

    public static let storeKey = "identity.v1"
    public static let trialKey = "trial.start.v1"

    public let macId: String
    public let signing: Curve25519.Signing.PrivateKey
    public let agreement: Curve25519.KeyAgreement.PrivateKey
    public var name: String

    public init(macId: String,
                signing: Curve25519.Signing.PrivateKey,
                agreement: Curve25519.KeyAgreement.PrivateKey,
                name: String) {
        self.macId = macId
        self.signing = signing
        self.agreement = agreement
        self.name = name
    }

    public var edPublicKey: Data { return signing.publicKey.rawRepresentation }
    public var xPublicKey: Data { return agreement.publicKey.rawRepresentation }
    public var edPublicKeyB64: String { return Base64URL.encode(edPublicKey) }
    public var xPublicKeyB64: String { return Base64URL.encode(xPublicKey) }

    // MARK: - persistence

    private struct Stored: Codable {
        var macId: String
        var ed: String
        var x: String
        var created: Double
    }

    /// 读不到就新建并写回。任何一步失败都还是返回一个可用的身份(内存里的),
    /// 只是重启后会换一个 —— 不编造"已保存"。
    public static func loadOrCreate(store: SecretStore, name: String) -> Identity {
        if let data = store.data(forKey: storeKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           let edRaw = Base64URL.decode(stored.ed),
           let xRaw = Base64URL.decode(stored.x),
           let signing = try? Curve25519.Signing.PrivateKey(rawRepresentation: edRaw),
           let agreement = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: xRaw) {
            return Identity(macId: stored.macId, signing: signing, agreement: agreement, name: name)
        }

        let signing = Curve25519.Signing.PrivateKey()
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        let macId = Identity.newMacId()
        let stored = Stored(macId: macId,
                            ed: Base64URL.encode(signing.rawRepresentation),
                            x: Base64URL.encode(agreement.rawRepresentation),
                            created: Date().timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(stored) {
            _ = store.set(data, forKey: storeKey)
        }
        return Identity(macId: macId, signing: signing, agreement: agreement, name: name)
    }

    /// 试用期锚点。第一次问的时候写进 Keychain,删 App 不会重置(SPEC §7.5)。
    public static func trialStart(store: SecretStore) -> Date {
        if let data = store.data(forKey: trialKey),
           let text = String(data: data, encoding: .utf8),
           let seconds = Double(text), seconds > 0 {
            return Date(timeIntervalSince1970: seconds)
        }
        let now = Date()
        _ = store.set(Data(String(now.timeIntervalSince1970).utf8), forKey: trialKey)
        return now
    }

    // MARK: - signing

    /// SPEC §2:`sig = Ed25519.sign(key, utf8(canonicalJSON(payload)))`。
    public func sign(_ payload: JSONValue) -> String? {
        guard let signature = try? signing.signature(for: CanonicalJSON.data(payload)) else {
            return nil
        }
        return Base64URL.encode(signature)
    }

    public static func verify(payload: JSONValue,
                              signatureB64URL: String,
                              edPublicKeyB64URL: String) -> Bool {
        guard let signature = Base64URL.decode(signatureB64URL),
              let raw = Base64URL.decode(edPublicKeyB64URL),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            return false
        }
        return key.isValidSignature(signature, for: CanonicalJSON.data(payload))
    }

    // MARK: - ids and randomness

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var generator = SystemRandomNumberGenerator()
        for index in 0..<count {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        return Data(bytes)
    }

    /// 16 字节随机 → base32 小写 26 字符(SPEC §2)。
    public static func newMacId() -> String {
        return base32(randomBytes(16))
    }

    /// RFC 4648 base32,小写,不填充。
    public static func base32(_ data: Data) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var out = ""
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                let index = (buffer >> (bits - 5)) & 31
                out.append(alphabet[index])
                bits -= 5
            }
        }
        if bits > 0 {
            let index = (buffer << (5 - bits)) & 31
            out.append(alphabet[index])
        }
        return out
    }
}
