import Foundation

/// SPEC §5:密文里装的东西。
///
///   请求  {id:"<uuid>", m:"<method>", p:{...}}
///   响应  {id, r:{...}}  |  {id, e:{code, msg}}
///   流式  {id, s:{...}}   // 同 id 多条,最后以响应结束
public struct RPCRequest: Equatable {
    public let id: String
    public let method: String
    public let params: JSONValue

    public init(id: String, method: String, params: JSONValue) {
        self.id = id
        self.method = method
        self.params = params
    }

    public func param(_ key: String) -> JSONValue? {
        return params[key]
    }

    public func string(_ key: String) -> String? { return params[key]?.stringValue }
    public func int(_ key: String) -> Int? { return params[key]?.intValue }
    public func double(_ key: String) -> Double? { return params[key]?.doubleValue }
    public func bool(_ key: String) -> Bool? { return params[key]?.boolValue }

    /// agent 可以在任何一条请求上附一句"为什么"(人话目的)。审批卡拿它当大标题——
    /// 用户要看的是"它想干什么",不是一行 shell。空白与超长在这里就收拾干净,
    /// 后面的界面代码可以直接用。
    public var why: String? {
        return RPCRequest.cleanWhy(params["why"]?.stringValue)
    }

    /// 120 字上限:再长的一句话会把卡片上的按钮挤下去。
    public static func cleanWhy(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let flattened = raw.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flattened.isEmpty { return nil }
        if flattened.count <= 120 { return flattened }
        return String(flattened.prefix(119)) + "…"
    }

    public static func decode(_ data: Data) -> RPCRequest? {
        guard let value = JSONValue.parse(data),
              let id = value["id"]?.stringValue,
              let method = value["m"]?.stringValue else {
            return nil
        }
        return RPCRequest(id: id, method: method, params: value["p"] ?? .object([:]))
    }

    public func encoded() -> Data {
        return CanonicalJSON.data(.object([
            "id": .string(id),
            "m": .string(method),
            "p": params
        ]))
    }
}

/// SPEC §5.1 的错误码。
public enum RPCErrorCode: String {
    case denied = "DENIED"
    case timeout = "TIMEOUT"
    case policy = "POLICY"
    case eio = "EIO"
    case enoent = "ENOENT"
    case ebusy = "EBUSY"
    case badParams = "BAD_PARAMS"
    /// SPEC §7.5:试用结束后 run / fs.put 返回这个。
    case license = "LICENSE"
}

public enum RPCOutbound: Equatable {
    case stream(id: String, body: JSONValue)
    case response(id: String, body: JSONValue)
    case failure(id: String, code: String, message: String)

    public var requestId: String {
        switch self {
        case .stream(let id, _): return id
        case .response(let id, _): return id
        case .failure(let id, _, _): return id
        }
    }

    /// 一次 RPC 的最后一条。流式帧之后必然还有一条 response 或 failure。
    public var isTerminal: Bool {
        if case .stream = self { return false }
        return true
    }

    public var json: JSONValue {
        switch self {
        case .stream(let id, let body):
            return .object(["id": .string(id), "s": body])
        case .response(let id, let body):
            return .object(["id": .string(id), "r": body])
        case .failure(let id, let code, let message):
            return .object(["id": .string(id),
                            "e": .object(["code": .string(code), "msg": .string(message)])])
        }
    }

    public func encoded() -> Data {
        return CanonicalJSON.data(json)
    }

    /// 故意不叫 `failure`:与同名的 case 构造器重名会让类型检查器为难。
    public static func fail(_ id: String, _ code: RPCErrorCode, _ message: String) -> RPCOutbound {
        return .failure(id: id, code: code.rawValue, message: message)
    }

    public static func ok(id: String) -> RPCOutbound {
        return .response(id: id, body: .object([:]))
    }
}
