import XCTest
import CryptoKit
@testable import MacHandsCore

/// SPEC §9.3:`swift test` 用 `shared/PROTOCOL-VECTORS.json` 验证加解密与 Node 互通。
///
/// 向量文件由 agent 侧生成。文件不在(还没生成、或者只拿了 macapp 这一个目录)
/// 时,这一组测试**跳过**而不是失败 —— 但会打印一行说明,免得"全绿"骗人。
final class InteropTests: XCTestCase {

    /// `#filePath` 是 …/macapp/Tests/MacHandsTests/InteropTests.swift,
    /// 往上四层是 machands/,再进 shared/。
    private static var vectorsURL: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url = url.deletingLastPathComponent() }
        return url.appendingPathComponent("shared/PROTOCOL-VECTORS.json")
    }

    private var vectors: JSONValue?

    override func setUp() {
        super.setUp()
        guard let data = try? Data(contentsOf: InteropTests.vectorsURL) else { return }
        vectors = JSONValue.parse(data)
    }

    private func requireVectors() throws -> JSONValue {
        guard let vectors = vectors else {
            throw XCTSkip("no shared/PROTOCOL-VECTORS.json at \(InteropTests.vectorsURL.path)")
        }
        return vectors
    }

    // MARK: - 身份

    func testIdsAreBase32OfSixteenBytes() throws {
        let vectors = try requireVectors()
        for role in ["mac", "agent"] {
            let identifier = try XCTUnwrap(vectors[role]?["id"]?.stringValue)
            XCTAssertEqual(identifier.count, 26, "\(role) id is 26 base32 characters")
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz234567")
            XCTAssertNil(identifier.rangeOfCharacter(from: allowed.inverted))
        }
    }

    func testPublicKeysAre32Bytes() throws {
        let vectors = try requireVectors()
        for role in ["mac", "agent"] {
            for field in ["x25519_pub", "ed25519_pub", "x25519_priv", "ed25519_priv"] {
                let text = try XCTUnwrap(vectors[role]?[field]?.stringValue, "\(role).\(field)")
                XCTAssertEqual(Base64URL.decode(text)?.count, 32, "\(role).\(field)")
            }
        }
    }

    // MARK: - 会话密钥

    func testSharedSecretAndSessionKeyMatchNode() throws {
        let vectors = try requireVectors()
        let macPrivRaw = try XCTUnwrap(Base64URL.decode(
            try XCTUnwrap(vectors["mac"]?["x25519_priv"]?.stringValue)))
        let agentPubRaw = try XCTUnwrap(Base64URL.decode(
            try XCTUnwrap(vectors["agent"]?["x25519_pub"]?.stringValue)))
        let agentPrivRaw = try XCTUnwrap(Base64URL.decode(
            try XCTUnwrap(vectors["agent"]?["x25519_priv"]?.stringValue)))
        let macPubRaw = try XCTUnwrap(Base64URL.decode(
            try XCTUnwrap(vectors["mac"]?["x25519_pub"]?.stringValue)))

        let macId = try XCTUnwrap(vectors["mac"]?["id"]?.stringValue)
        let agentId = try XCTUnwrap(vectors["agent"]?["id"]?.stringValue)

        let macPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: macPrivRaw)
        let agentPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agentPrivRaw)

        // 私钥推出来的公钥必须与向量里的公钥一致。
        XCTAssertEqual(macPriv.publicKey.rawRepresentation, macPubRaw)
        XCTAssertEqual(agentPriv.publicKey.rawRepresentation, agentPubRaw)

        let secret = try E2ECrypto.sharedSecret(privateKey: macPriv, peerPublicKeyRaw: agentPubRaw)
        if let expected = vectors["session"]?["shared_secret_hex"]?.stringValue {
            XCTAssertEqual(CoreTestHelpers.hex(secret), expected)
        }

        XCTAssertEqual(E2ECrypto.info(macId: macId, agentId: agentId),
                       vectors["session"]?["hkdf_info_utf8"]?.stringValue)
        XCTAssertEqual(E2ECrypto.saltString,
                       vectors["session"]?["hkdf_salt_utf8"]?.stringValue)

        let key = E2ECrypto.deriveKeyBytes(sharedSecret: secret, macId: macId, agentId: agentId)
        if let expected = vectors["session"]?["key_hex"]?.stringValue {
            XCTAssertEqual(CoreTestHelpers.hex(key), expected, "HKDF output must match Node's")
        }
        if let expected = vectors["session"]?["key_base64url"]?.stringValue {
            XCTAssertEqual(Base64URL.encode(key), expected)
        }
    }

    // MARK: - 帧

    /// Node 造的 a2m 帧,Swift 必须能解开;Swift 造的 m2a 帧,必须与 Node 的逐字节相同。
    func testFramesInteroperate() throws {
        let vectors = try requireVectors()
        let macId = try XCTUnwrap(vectors["mac"]?["id"]?.stringValue)
        let agentId = try XCTUnwrap(vectors["agent"]?["id"]?.stringValue)
        let macPriv = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: try XCTUnwrap(Base64URL.decode(
                try XCTUnwrap(vectors["mac"]?["x25519_priv"]?.stringValue))))
        let agentPubRaw = try XCTUnwrap(Base64URL.decode(
            try XCTUnwrap(vectors["agent"]?["x25519_pub"]?.stringValue)))
        let key = try E2ECrypto.deriveKey(privateKey: macPriv,
                                          peerPublicKeyRaw: agentPubRaw,
                                          macId: macId, agentId: agentId)

        // --- Node → Mac:解开 -------------------------------------------------
        let inbound = vectors["frames"]?["agent_to_mac"]?.arrayValue ?? []
        XCTAssertFalse(inbound.isEmpty, "the vectors file should carry at least one a2m frame")
        let receiving = E2ESession(key: key, localId: macId, remoteId: agentId,
                                   sendDirection: E2ESession.macToAgent,
                                   receiveDirection: E2ESession.agentToMac)
        for frame in inbound {
            let body = try XCTUnwrap(frame["body_base64url"]?.stringValue)
            let expected = try XCTUnwrap(frame["plaintext_utf8"]?.stringValue)
            let plaintext = try receiving.open(body)
            XCTAssertEqual(String(decoding: plaintext, as: UTF8.self), expected)

            // nonce 与 aad 也逐字节核一遍:解得开不代表布局一样。
            if let nonceHex = frame["nonce_hex"]?.stringValue,
               let counter = frame["counter"]?.intValue {
                XCTAssertEqual(CoreTestHelpers.hex(E2ECrypto.nonce(direction: "a2m",
                                                                   counter: UInt64(counter))),
                               nonceHex)
            }
            if let aad = frame["aad_utf8"]?.stringValue {
                XCTAssertEqual(aad, agentId + ">" + macId)
            }

            // 解出来的必须是一条 RPC 请求。
            XCTAssertNotNil(RPCRequest.decode(plaintext), "a2m frames carry RPC requests")
        }

        // --- Mac → Node:重新加密,逐字节比 -----------------------------------
        // ChaCha20-Poly1305 是确定性的:同一把 key + nonce + aad + 明文,密文唯一。
        let outbound = vectors["frames"]?["mac_to_agent"]?.arrayValue ?? []
        XCTAssertFalse(outbound.isEmpty, "the vectors file should carry at least one m2a frame")
        let sending = E2ESession(key: key, localId: macId, remoteId: agentId,
                                 sendDirection: E2ESession.macToAgent,
                                 receiveDirection: E2ESession.agentToMac)
        for frame in outbound {
            let expectedBody = try XCTUnwrap(frame["body_base64url"]?.stringValue)
            let plaintext = try XCTUnwrap(frame["plaintext_utf8"]?.stringValue)
            let counter = try XCTUnwrap(frame["counter"]?.intValue)
            // 计数器从 1 开始,向量也从 1 开始,顺序一致,所以直接 seal 就对得上。
            XCTAssertEqual(Int(sending.nextSendCounter), counter,
                           "our counter must line up with the vectors")
            let body = try sending.seal(Data(plaintext.utf8))
            XCTAssertEqual(body, expectedBody)
        }
    }

    // MARK: - 握手签名

    func testAuthSignaturesVerify() throws {
        let vectors = try requireVectors()
        let entries = try XCTUnwrap(vectors["auth"]?.arrayValue)
        XCTAssertFalse(entries.isEmpty)
        for entry in entries {
            let who = try XCTUnwrap(entry["who"]?.stringValue)
            let signed = try XCTUnwrap(entry["signed_payload"])
            let canonical = CanonicalJSON.string(signed)
            if let expected = entry["canonical_json_utf8"]?.stringValue {
                XCTAssertEqual(canonical, expected, "canonical JSON for \(who)")
            }
            let signature = try XCTUnwrap(entry["signature_base64url"]?.stringValue)
            let publicKey = try XCTUnwrap(vectors[who]?["ed25519_pub"]?.stringValue)
            XCTAssertTrue(Identity.verify(payload: signed,
                                          signatureB64URL: signature,
                                          edPublicKeyB64URL: publicKey),
                          "\(who)'s auth signature must verify")

            // 我们自己签一遍也要得到同一串(Ed25519 是确定性签名)。
            let privateRaw = try XCTUnwrap(Base64URL.decode(
                try XCTUnwrap(vectors[who]?["ed25519_priv"]?.stringValue)))
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateRaw)
            let ours = try key.signature(for: Data(canonical.utf8))
            XCTAssertEqual(Base64URL.encode(ours), signature)
        }
    }

    // MARK: - canonical JSON

    func testCanonicalJSONVectors() throws {
        let vectors = try requireVectors()
        let cases = try XCTUnwrap(vectors["canonical_json"]?.arrayValue)
        for item in cases {
            let value = try XCTUnwrap(item["value"])
            let expected = try XCTUnwrap(item["canonical"]?.stringValue)
            XCTAssertEqual(CanonicalJSON.string(value), expected)
        }
    }

    // MARK: - 配对块

    func testPairingCodeVector() throws {
        let vectors = try requireVectors()
        let text = try XCTUnwrap(vectors["pairing"]?["code"]?.stringValue)
        let parsed = try XCTUnwrap(PairingCode.parse(text))
        let decoded = try XCTUnwrap(vectors["pairing"]?["decoded"])

        if let host = decoded["host"]?.stringValue, let port = decoded["port"]?.intValue {
            XCTAssertEqual(parsed.relayEndpoint, "\(host):\(port)")
        }
        XCTAssertEqual(parsed.relayPublicKey, decoded["relayPub"]?.stringValue)
        XCTAssertEqual(parsed.macId, decoded["macId"]?.stringValue)
        XCTAssertEqual(parsed.macXPublicKey, decoded["macXPub"]?.stringValue)
        XCTAssertEqual(parsed.macEdPublicKey, decoded["macEdPub"]?.stringValue)
        XCTAssertEqual(parsed.token, decoded["token"]?.stringValue)
        XCTAssertEqual(parsed.macName, decoded["macName"]?.stringValue)
        XCTAssertEqual(parsed.encoded, text, "re-encoding must be byte-identical")

        if let ttl = vectors["pairing"]?["token_ttl_seconds"]?.intValue {
            XCTAssertEqual(PairingCode.ttlSeconds, ttl)
        }
        if let block = vectors["pairing"]?["clipboard_block"]?.stringValue {
            XCTAssertEqual(PairingCode.clipboardText(code: text), block,
                           "the clipboard block must match the agent's expectation byte for byte")
        }
    }
}
