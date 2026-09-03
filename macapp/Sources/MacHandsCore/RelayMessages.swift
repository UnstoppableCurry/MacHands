import Foundation

/// SPEC §4:中继协议。WebSocket 文本帧,一行一条 JSON,每条都有 `t`。
///
/// 出站消息是具体的 Encodable struct(字段固定,编码顺序无所谓);
/// 入站消息先只解 `t`,再按类型解成对应 struct —— 这样 relay 加了新字段
/// 或新类型都不会让 App 崩,只会落到 `.unknown`。
public enum RelayMessages {

    public static let macPath = "/v1/mac"
    public static let agentPath = "/v1/agent"
    public static let protocolVersion = 1
}

// MARK: - 出站(Mac → relay)

public struct AuthMessage: Codable {
    public let t: String
    public let role: String
    public let id: String
    public let edPub: String
    public let xPub: String
    public let name: String
    public let sig: String
    /// **客户端自己的**毫秒时间戳,不是 hello 里那个。
    /// 中继验签用的正是这个字段,并且要求它与中继的时钟相差不超过 5 分钟;
    /// 签名覆盖 `{id, nonce, ts}`,ts 必须与这里发出去的一模一样。
    public let ts: Int

    public init(id: String, edPub: String, xPub: String, name: String, sig: String, ts: Int) {
        self.t = "auth"
        self.role = "mac"
        self.id = id
        self.edPub = edPub
        self.xPub = xPub
        self.name = name
        self.sig = sig
        self.ts = ts
    }
}

public struct PongMessage: Codable {
    public let t: String
    public init() { self.t = "pong" }
}

public struct PairOpenMessage: Codable {
    public let t: String
    public let token: String
    public let ttl: Int

    public init(token: String, ttl: Int = PairingCode.ttlSeconds) {
        self.t = "pair.open"
        self.token = token
        self.ttl = ttl
    }
}

public struct PairDecideMessage: Codable {
    public let t: String
    public let agentId: String
    public let allow: Bool

    public init(agentId: String, allow: Bool) {
        self.t = "pair.decide"
        self.agentId = agentId
        self.allow = allow
    }
}

public struct PairRevokeMessage: Codable {
    public let t: String
    public let agentId: String

    public init(agentId: String) {
        self.t = "pair.revoke"
        self.agentId = agentId
    }
}

public struct SendMessage: Codable {
    public let t: String
    public let to: String
    public let body: String
    public let n: Int

    public init(to: String, body: String, n: Int) {
        self.t = "send"
        self.to = to
        self.body = body
        self.n = n
    }
}

// MARK: - 入站(relay → Mac)

public struct HelloMessage: Codable {
    public let relayId: String?
    /// SPEC §2 说中继公钥要出现在配对块里,而 §4.1 的 hello 只列了 `relayId`。
    /// 两个名字都收:有 `relayPub` 就用它,否则把 `relayId` 当公钥。
    public let relayPub: String?
    public let nonce: String
    public let ts: Double
    public let ver: Int?
    /// 中继用自己的 Ed25519 私钥签的 `{nonce, relayId, ts}`。
    /// 有它就能证明对面确实握着我们 pin 的那把私钥,而不只是知道公钥。
    public let sig: String?

    /// 配对块里那一段、也是要 pin 的那一段。
    public var relayKey: String? {
        if let key = relayPub, !key.isEmpty { return key }
        if let key = relayId, !key.isEmpty { return key }
        return nil
    }
}

public struct OkMessage: Codable {
    public let id: String?
    public let ts: Double?
}

public struct ErrMessage: Codable {
    public let code: String
    public let msg: String?
    public let to: String?
}

public struct PairRequestMessage: Codable {
    public let agentId: String
    public let agentEdPub: String
    public let agentXPub: String
    public let agentName: String?
    public let from: String?
}

public struct RecvMessage: Codable {
    public let from: String
    public let body: String
    public let n: Int?
}

public struct PresenceMessage: Codable {
    public let id: String
    public let online: Bool
}

public enum RelayInbound {
    case hello(HelloMessage)
    case ok(OkMessage)
    case err(ErrMessage)
    case ping
    case pong
    case pairRequest(PairRequestMessage)
    case recv(RecvMessage)
    case presence(PresenceMessage)
    /// relay 说了我们不认识的话。不是错误,只是不处理。
    case unknown(String)
}

public enum RelayCodec {

    private struct TypeOnly: Decodable { let t: String }

    public static func encode<T: Encodable>(_ message: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(message) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 解不出来就返回 nil(不是异常:中继随时可能被别的东西喂垃圾)。
    public static func decode(_ text: String) -> RelayInbound? {
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        guard let head = try? decoder.decode(TypeOnly.self, from: data) else { return nil }
        switch head.t {
        case "hello":
            guard let value = try? decoder.decode(HelloMessage.self, from: data) else { return nil }
            return .hello(value)
        case "ok":
            let value = (try? decoder.decode(OkMessage.self, from: data)) ?? OkMessage(id: nil, ts: nil)
            return .ok(value)
        case "err":
            guard let value = try? decoder.decode(ErrMessage.self, from: data) else { return nil }
            return .err(value)
        case "ping":
            return .ping
        case "pong":
            return .pong
        case "pair.request":
            guard let value = try? decoder.decode(PairRequestMessage.self, from: data) else { return nil }
            return .pairRequest(value)
        case "recv":
            guard let value = try? decoder.decode(RecvMessage.self, from: data) else { return nil }
            return .recv(value)
        case "presence":
            guard let value = try? decoder.decode(PresenceMessage.self, from: data) else { return nil }
            return .presence(value)
        default:
            return .unknown(head.t)
        }
    }

    /// 现在的毫秒时间戳,整数 —— auth 的 `ts` 与被签名的 `ts` 都用它。
    public static func nowMilliseconds(_ date: Date = Date()) -> Int {
        return Int((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// SPEC §4.1:签的是 `{id, nonce, ts}` 的 canonical JSON。
    public static func authPayload(id: String, nonce: String, ts: Double) -> JSONValue {
        return .object([
            "id": .string(id),
            "nonce": .string(nonce),
            "ts": .number(ts)
        ])
    }

    /// 中继在 hello 里签的是 `{nonce, relayId, ts}`。
    public static func helloPayload(relayId: String, nonce: String, ts: Double) -> JSONValue {
        return .object([
            "nonce": .string(nonce),
            "relayId": .string(relayId),
            "ts": .number(ts)
        ])
    }
}
