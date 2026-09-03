import Foundation

/// 一棵 JSON 树。RPC 的 `p` / `r` / `s` 是任意 JSON,Swift 的 Codable 处理不了
/// "任意",所以协议层统一用这个显式表示。
public enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        guard case .number(let value) = self, value.isFinite else { return nil }
        if value > 9.0e18 || value < -9.0e18 { return nil }
        return Int(value)
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    // MARK: - convenience constructors

    public static func int(_ value: Int) -> JSONValue { return .number(Double(value)) }

    public static func strings(_ values: [String]) -> JSONValue {
        return .array(values.map { JSONValue.string($0) })
    }
}

// MARK: - parsing

extension JSONValue {

    public static func parse(_ data: Data) -> JSONValue? {
        guard let object = try? JSONSerialization.jsonObject(with: data,
                                                             options: [.fragmentsAllowed]) else {
            return nil
        }
        return from(object)
    }

    public static func parse(_ text: String) -> JSONValue? {
        return parse(Data(text.utf8))
    }

    /// Foundation 把 JSON 的 true / 1 都装进 NSNumber,`as? Bool` 对两者都成功,
    /// 所以必须用 CFGetTypeID 分辨,否则 `{"a":1}` 会变成 `{"a":true}`。
    public static func from(_ object: Any) -> JSONValue {
        if object is NSNull { return .null }
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        }
        if let text = object as? String { return .string(text) }
        if let list = object as? [Any] { return .array(list.map { from($0) }) }
        if let dict = object as? [String: Any] {
            var out: [String: JSONValue] = [:]
            for (key, value) in dict { out[key] = from(value) }
            return .object(out)
        }
        return .null
    }
}

// MARK: - Codable

extension JSONValue: Codable {

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container,
                                               debugDescription: "not a JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            if value.isFinite, value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

/// SPEC §2:`canonicalJSON = 键按字典序、无空白`。签名两端必须逐字节一致,
/// 所以这里自己拼字符串,不依赖 JSONEncoder 的排序选项(它不保证转义方式)。
///
/// 数字:整数按整数打印(与 JS 的 `JSON.stringify(1725350400000)` 一致)。
/// 被签名的载荷里只应该出现整数;非整数走 Swift 的最短往返表示,与 JS 在极端
/// 情况(指数表示)下可能不同 —— 别把浮点数放进要签名的对象里。
public enum CanonicalJSON {

    public static func string(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .number(let number):
            return canonicalNumber(number)
        case .string(let text):
            return quoted(text)
        case .array(let items):
            return "[" + items.map { string($0) }.joined(separator: ",") + "]"
        case .object(let dict):
            let parts = dict.keys.sorted().map { key -> String in
                return quoted(key) + ":" + string(dict[key] ?? .null)
            }
            return "{" + parts.joined(separator: ",") + "}"
        }
    }

    public static func data(_ value: JSONValue) -> Data {
        return Data(string(value).utf8)
    }

    private static func canonicalNumber(_ number: Double) -> String {
        if number.isNaN || number.isInfinite { return "null" }
        if number == number.rounded(), abs(number) < 9_007_199_254_740_992 {
            return String(Int64(number))
        }
        return "\(number)"
    }

    private static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"":
                out += "\\\""
            case "\\":
                out += "\\\\"
            case "\n":
                out += "\\n"
            case "\r":
                out += "\\r"
            case "\t":
                out += "\\t"
            case "\u{08}":
                out += "\\b"
            case "\u{0C}":
                out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
