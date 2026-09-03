import Foundation

/// base64url,无填充(SPEC §2:"所有二进制字段 base64url 无填充")。
///
/// 解码故意宽容:接受带 `=` 填充的输入、接受混进来的空白(邮件与聊天框会折行),
/// 但绝不接受长度不可能的输入(mod 4 == 1)。
public enum Base64URL {

    public static func encode(_ data: Data) -> String {
        var text = data.base64EncodedString()
        text = text.replacingOccurrences(of: "+", with: "-")
        text = text.replacingOccurrences(of: "/", with: "_")
        while text.hasSuffix("=") { text.removeLast() }
        return text
    }

    public static func encode(_ bytes: [UInt8]) -> String {
        return encode(Data(bytes))
    }

    public static func decode(_ string: String) -> Data? {
        var text = ""
        for character in string {
            if character.isWhitespace || character.isNewline { continue }
            switch character {
            case "-": text.append("+")
            case "_": text.append("/")
            case "=": continue
            default: text.append(character)
            }
        }
        switch text.count % 4 {
        case 0: break
        case 2: text += "=="
        case 3: text += "="
        default: return nil          // mod 4 == 1 is not a possible base64 length
        }
        return Data(base64Encoded: text)
    }

    /// UTF-8 文本的 base64url(配对块里的 macName 用这个)。
    public static func encodeUTF8(_ string: String) -> String {
        return encode(Data(string.utf8))
    }

    public static func decodeUTF8(_ string: String) -> String? {
        guard let data = decode(string) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
