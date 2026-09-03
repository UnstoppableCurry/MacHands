import Foundation

/// SPEC §3 的配对块。
///
///   MH1.<relayHost>:<port>.<relayPubkey>.<macId>.<macPubkeyX25519>.<macPubkeyEd25519>.<token>.<macName>
///
/// 坑:字段用 `.` 分隔,而 `<relayHost>:<port>` 里的 IPv4 本身就带 3 个点,
/// 所以从左往右 split 会散架。解析改成从**右**边数 6 个字段(它们都是
/// base64url / base32,不含点),剩下的开头部分就是 host:port。
/// 这样 `134.199.230.126:8443` 与 `relay.example.com:443` 都能正确还原。
public struct PairingCode: Equatable {

    public static let prefix = "MH1"
    /// SPEC §3:token 10 分钟内有效,只能用一次。
    public static let ttlSeconds: Int = 600

    public var relayEndpoint: String       // "host:port",原样 ASCII
    public var relayPublicKey: String      // base64url Ed25519
    public var macId: String               // base32 小写
    public var macXPublicKey: String       // base64url X25519
    public var macEdPublicKey: String      // base64url Ed25519
    public var token: String               // base64url,16 字节
    public var macNameEncoded: String      // base64url(UTF-8 名字)

    public init(relayEndpoint: String,
                relayPublicKey: String,
                macId: String,
                macXPublicKey: String,
                macEdPublicKey: String,
                token: String,
                macNameEncoded: String) {
        self.relayEndpoint = relayEndpoint
        self.relayPublicKey = relayPublicKey
        self.macId = macId
        self.macXPublicKey = macXPublicKey
        self.macEdPublicKey = macEdPublicKey
        self.token = token
        self.macNameEncoded = macNameEncoded
    }

    public init(relayEndpoint: String,
                relayPublicKey: String,
                macId: String,
                macXPublicKey: String,
                macEdPublicKey: String,
                token: String,
                macName: String) {
        self.init(relayEndpoint: relayEndpoint,
                  relayPublicKey: relayPublicKey,
                  macId: macId,
                  macXPublicKey: macXPublicKey,
                  macEdPublicKey: macEdPublicKey,
                  token: token,
                  macNameEncoded: Base64URL.encodeUTF8(macName))
    }

    public var macName: String {
        return Base64URL.decodeUTF8(macNameEncoded) ?? macNameEncoded
    }

    public var encoded: String {
        return [PairingCode.prefix,
                relayEndpoint,
                relayPublicKey,
                macId,
                macXPublicKey,
                macEdPublicKey,
                token,
                macNameEncoded].joined(separator: ".")
    }

    public static func parse(_ text: String) -> PairingCode? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard trimmed.hasPrefix(prefix + ".") else { return nil }
        let body = String(trimmed.dropFirst(prefix.count + 1))
        let parts = body.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        // endpoint + 6 个不含点的字段
        guard parts.count >= 7 else { return nil }
        let tailStart = parts.count - 6
        let endpoint = parts[0..<tailStart].joined(separator: ".")
        let tail = Array(parts[tailStart...])
        guard !endpoint.isEmpty else { return nil }
        for field in tail where field.isEmpty { return nil }
        return PairingCode(relayEndpoint: endpoint,
                           relayPublicKey: tail[0],
                           macId: tail[1],
                           macXPublicKey: tail[2],
                           macEdPublicKey: tail[3],
                           token: tail[4],
                           macNameEncoded: tail[5])
    }

    /// 从一段文字里把配对码抠出来(用户可能整段粘贴)。
    public static func find(in text: String) -> PairingCode? {
        for rawToken in text.split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) {
            let candidate = String(rawToken)
            if candidate.hasPrefix(prefix + "."), let code = parse(candidate) {
                return code
            }
        }
        return parse(text)
    }

    public static func newToken() -> String {
        return Base64URL.encode(Identity.randomBytes(16))
    }

    /// 用户真正会复制走的那一整段(SPEC §3)。
    ///
    /// 三行提示语从外面传进来,因为 i18n 表在 App target 里(铁律 3:不写裸中文
    /// 进逻辑)。默认值是中文,方便测试与不带 UI 的场景。
    public static func clipboardText(code: String,
                                     lead: String = "把下面这一行在你的机器上执行,然后告诉我结果:",
                                     note: String = "(这是 MacHands 配对码,10 分钟内有效,只能用一次。)") -> String {
        return """
        \(lead)

        npx -y machands@latest pair "\(code)"

        \(note)
        """
    }
}
