import Foundation
import CryptoKit

public enum E2EError: Error, Equatable {
    case badPublicKey
    case keyAgreementFailed
    case shortFrame
    case badBase64
    case wrongDirection
    case replay(UInt64)
    case decryptFailed
    case sealFailed
}

/// SPEC §5 的密码学部分,与 Node 侧必须逐字节一致。
///
///   ss   = X25519(myPriv, theirPub)
///   key  = HKDF-SHA256(ss, salt="machands-v1", info=sort(macId,agentId).join("|"), 32)
///   nonce(12) = 4 字节方向标记 + 8 字节大端计数器
///   ct   = ChaCha20-Poly1305(key, nonce, plaintext, aad=utf8(from+">"+to))
///   body = base64url(nonce ‖ ct)   ,ct 含 16 字节 Poly1305 tag
///
/// HKDF 是手写的(RFC 5869),不是 CryptoKit 的 `HKDF<SHA256>`:两者结果相同,
/// 但手写的版本可以直接被测试逐步比对,出问题时能指出是 extract 还是 expand 错。
public enum E2ECrypto {

    public static let saltString = "machands-v1"

    /// SPEC 写的是「"m2a"/"a2m" 的前 4 字节 ASCII」,而这两个串只有 3 字节 ——
    /// 规范自相矛盾。这里的解释是:取 UTF-8,右侧补 0x00 到 4 字节,多了截断。
    /// 这是 Swift 侧与 Node 侧最可能对不上的一处,`PROTOCOL-VECTORS.json` 里的
    /// 帧一旦到手,先验它。
    public static func directionTag(_ direction: String) -> Data {
        var bytes = [UInt8](Data(direction.utf8).prefix(4))
        while bytes.count < 4 { bytes.append(0) }
        return Data(bytes)
    }

    public static func nonce(direction: String, counter: UInt64) -> Data {
        var out = directionTag(direction)
        var shift = 56
        while shift >= 0 {
            out.append(UInt8((counter >> UInt64(shift)) & 0xFF))
            shift -= 8
        }
        return out
    }

    /// RFC 5869,HMAC-SHA256。
    public static func hkdfSHA256(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        let saltBytes = salt.isEmpty ? Data(repeating: 0, count: 32) : salt
        let prk = Data(HMAC<SHA256>.authenticationCode(for: ikm,
                                                       using: SymmetricKey(data: saltBytes)))
        let prkKey = SymmetricKey(data: prk)
        var out = Data()
        var block = Data()
        var counter: UInt8 = 1
        while out.count < length {
            var input = Data()
            input.append(block)
            input.append(info)
            input.append(counter)
            block = Data(HMAC<SHA256>.authenticationCode(for: input, using: prkKey))
            out.append(block)
            if counter == 255 { break }
            counter += 1
        }
        return Data(out.prefix(length))
    }

    public static func sharedSecret(privateKey: Curve25519.KeyAgreement.PrivateKey,
                                    peerPublicKeyRaw: Data) throws -> Data {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKeyRaw) else {
            throw E2EError.badPublicKey
        }
        guard let secret = try? privateKey.sharedSecretFromKeyAgreement(with: peer) else {
            throw E2EError.keyAgreementFailed
        }
        return secret.withUnsafeBytes { raw in Data(Array(raw)) }
    }

    /// info = sort(macId, agentId).join("|")
    public static func info(macId: String, agentId: String) -> String {
        return [macId, agentId].sorted().joined(separator: "|")
    }

    public static func deriveKey(privateKey: Curve25519.KeyAgreement.PrivateKey,
                                 peerPublicKeyRaw: Data,
                                 macId: String,
                                 agentId: String) throws -> SymmetricKey {
        let ss = try sharedSecret(privateKey: privateKey, peerPublicKeyRaw: peerPublicKeyRaw)
        let bytes = hkdfSHA256(ikm: ss,
                               salt: Data(saltString.utf8),
                               info: Data(info(macId: macId, agentId: agentId).utf8),
                               length: 32)
        return SymmetricKey(data: bytes)
    }

    public static func deriveKeyBytes(sharedSecret: Data, macId: String, agentId: String) -> Data {
        return hkdfSHA256(ikm: sharedSecret,
                          salt: Data(saltString.utf8),
                          info: Data(info(macId: macId, agentId: agentId).utf8),
                          length: 32)
    }
}

/// 一条 agent ↔ Mac 的加密通道。计数器与重放检测都在这里,所以每个对端一个实例,
/// 并且只能从一个队列上用(RelayClient 有自己的串行队列)。
public final class E2ESession {

    public static let macToAgent = "m2a"
    public static let agentToMac = "a2m"

    public let key: SymmetricKey
    public let localId: String
    public let remoteId: String
    public let sendDirection: String
    public let receiveDirection: String

    /// 发出去的第一帧计数器是 0。接收侧只要求"严格递增",所以对端从 0 还是 1
    /// 开始都能收。
    private var sendCounter: UInt64 = 0
    private var lastReceived: UInt64?

    /// 单帧 ≤ 1 MiB(SPEC §4.5)。base64 会放大 4/3,所以明文上限留 700 KiB。
    public static let maxPlaintext = 700 * 1024

    public init(key: SymmetricKey,
                localId: String,
                remoteId: String,
                sendDirection: String,
                receiveDirection: String) {
        self.key = key
        self.localId = localId
        self.remoteId = remoteId
        self.sendDirection = sendDirection
        self.receiveDirection = receiveDirection
    }

    /// Mac 侧的构造:我发 m2a,我收 a2m。
    public convenience init(identity: Identity,
                            agentId: String,
                            agentXPublicKeyRaw: Data) throws {
        let key = try E2ECrypto.deriveKey(privateKey: identity.agreement,
                                          peerPublicKeyRaw: agentXPublicKeyRaw,
                                          macId: identity.macId,
                                          agentId: agentId)
        self.init(key: key,
                  localId: identity.macId,
                  remoteId: agentId,
                  sendDirection: E2ESession.macToAgent,
                  receiveDirection: E2ESession.agentToMac)
    }

    public var nextSendCounter: UInt64 { return sendCounter }

    public func seal(_ plaintext: Data) throws -> String {
        guard plaintext.count <= E2ESession.maxPlaintext else { throw E2EError.sealFailed }
        let counter = sendCounter
        sendCounter &+= 1
        let nonceBytes = E2ECrypto.nonce(direction: sendDirection, counter: counter)
        let aad = Data((localId + ">" + remoteId).utf8)
        guard let nonce = try? ChaChaPoly.Nonce(data: nonceBytes),
              let box = try? ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad) else {
            throw E2EError.sealFailed
        }
        var frame = nonceBytes
        frame.append(box.ciphertext)
        frame.append(box.tag)
        return Base64URL.encode(frame)
    }

    public func open(_ body: String) throws -> Data {
        guard let raw = Base64URL.decode(body) else { throw E2EError.badBase64 }
        return try open(frame: raw)
    }

    public func open(frame raw: Data) throws -> Data {
        let bytes = [UInt8](raw)
        guard bytes.count >= 12 + 16 else { throw E2EError.shortFrame }

        let nonceBytes = Data(bytes[0..<12])
        let expectedTag = E2ECrypto.directionTag(receiveDirection)
        guard Data(bytes[0..<4]) == expectedTag else { throw E2EError.wrongDirection }

        var counter: UInt64 = 0
        for index in 4..<12 { counter = (counter << 8) | UInt64(bytes[index]) }
        if let last = lastReceived, counter <= last { throw E2EError.replay(counter) }

        let ciphertext = Data(bytes[12..<(bytes.count - 16)])
        let tag = Data(bytes[(bytes.count - 16)..<bytes.count])
        let aad = Data((remoteId + ">" + localId).utf8)

        guard let nonce = try? ChaChaPoly.Nonce(data: nonceBytes),
              let box = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
              let plaintext = try? ChaChaPoly.open(box, using: key, authenticating: aad) else {
            throw E2EError.decryptFailed
        }
        lastReceived = counter
        return plaintext
    }
}
