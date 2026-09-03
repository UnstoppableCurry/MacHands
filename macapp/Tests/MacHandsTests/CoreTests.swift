import XCTest
import CryptoKit
@testable import MacHandsCore

final class Base64URLTests: XCTestCase {

    func testRoundTrip() {
        for length in 0...40 {
            let data = Identity.randomBytes(length)
            let text = Base64URL.encode(data)
            XCTAssertFalse(text.contains("="), "padding must be stripped")
            XCTAssertFalse(text.contains("+"))
            XCTAssertFalse(text.contains("/"))
            XCTAssertEqual(Base64URL.decode(text), data, "round trip at length \(length)")
        }
    }

    func testKnownVector() {
        // "你好,MacHands"(半角逗号)的 UTF-8;标准 base64 与 base64url 在这一段上相同。
        XCTAssertEqual(Base64URL.encodeUTF8("你好,MacHands"), "5L2g5aW9LE1hY0hhbmRz")
        XCTAssertEqual(Base64URL.decodeUTF8("5L2g5aW9LE1hY0hhbmRz"), "你好,MacHands")
    }

    func testDecodeIsTolerant() {
        XCTAssertEqual(Base64URL.decode("5L2g5aW9LE1hY0hhbmRz"),
                       Base64URL.decode("5L2g5aW9LE1h\nY0hhbmRz"))
        // 带填充的输入也收。
        XCTAssertEqual(Base64URL.decode("YQ=="), Data("a".utf8))
        // mod 4 == 1 是不可能的长度。
        XCTAssertNil(Base64URL.decode("YQAAA"))
    }

    func testMinusUnderscoreMapping() {
        let data = Data([0xFB, 0xFF, 0xBE])
        let text = Base64URL.encode(data)
        XCTAssertEqual(text, "-_--")
        XCTAssertEqual(Base64URL.decode(text), data)
    }
}

final class CanonicalJSONTests: XCTestCase {

    func testKeysAreSortedAndThereIsNoWhitespace() {
        let value = JSONValue.object(["b": .int(1), "a": .int(2)])
        XCTAssertEqual(CanonicalJSON.string(value), "{\"a\":2,\"b\":1}")
    }

    func testNestedAndNonASCII() {
        let value = JSONValue.object([
            "z": .array([.int(3), .object(["y": .int(1), "x": .int(2)])]),
            "nested": .object(["k": .string("值"), "n": .null, "t": .bool(true)])
        ])
        XCTAssertEqual(CanonicalJSON.string(value),
                       "{\"nested\":{\"k\":\"值\",\"n\":null,\"t\":true},\"z\":[3,{\"x\":2,\"y\":1}]}")
    }

    func testIntegersDoNotGrowADecimalPoint() {
        XCTAssertEqual(CanonicalJSON.string(.number(1756800000000)), "1756800000000")
        XCTAssertEqual(CanonicalJSON.string(.number(0)), "0")
        XCTAssertEqual(CanonicalJSON.string(.number(-7)), "-7")
    }

    func testEscaping() {
        XCTAssertEqual(CanonicalJSON.string(.string("a\"b\\c\nd\te")),
                       "\"a\\\"b\\\\c\\nd\\te\"")
        XCTAssertEqual(CanonicalJSON.string(.string("\u{01}")), "\"\\u0001\"")
    }

    func testParseKeepsBoolAndNumberApart() {
        guard let parsed = JSONValue.parse("{\"a\":1,\"b\":true}") else {
            return XCTFail("did not parse")
        }
        XCTAssertEqual(parsed["a"], .number(1))
        XCTAssertEqual(parsed["b"], .bool(true))
    }
}

final class E2ETests: XCTestCase {

    private func makePair() -> (E2ESession, E2ESession) {
        let macKey = Curve25519.KeyAgreement.PrivateKey()
        let agentKey = Curve25519.KeyAgreement.PrivateKey()
        let macId = "aaaaaaaaaaaaaaaaaaaaaaaaaa"
        let agentId = "zzzzzzzzzzzzzzzzzzzzzzzzzz"

        let macSide = try! E2ECrypto.deriveKey(privateKey: macKey,
                                               peerPublicKeyRaw: agentKey.publicKey.rawRepresentation,
                                               macId: macId, agentId: agentId)
        let agentSide = try! E2ECrypto.deriveKey(privateKey: agentKey,
                                                 peerPublicKeyRaw: macKey.publicKey.rawRepresentation,
                                                 macId: macId, agentId: agentId)
        XCTAssertEqual(CoreTestHelpers.bytes(macSide), CoreTestHelpers.bytes(agentSide),
                       "both sides must derive the same key")

        let mac = E2ESession(key: macSide, localId: macId, remoteId: agentId,
                             sendDirection: E2ESession.macToAgent,
                             receiveDirection: E2ESession.agentToMac)
        let agent = E2ESession(key: agentSide, localId: agentId, remoteId: macId,
                               sendDirection: E2ESession.agentToMac,
                               receiveDirection: E2ESession.macToAgent)
        return (mac, agent)
    }

    func testDirectionTagIsFourBytes() {
        XCTAssertEqual([UInt8](E2ECrypto.directionTag("a2m")), [0x61, 0x32, 0x6d, 0x00])
        XCTAssertEqual([UInt8](E2ECrypto.directionTag("m2a")), [0x6d, 0x32, 0x61, 0x00])
    }

    func testNonceLayout() {
        let nonce = [UInt8](E2ECrypto.nonce(direction: "a2m", counter: 1))
        XCTAssertEqual(nonce.count, 12)
        XCTAssertEqual(nonce, [0x61, 0x32, 0x6d, 0x00, 0, 0, 0, 0, 0, 0, 0, 1])
    }

    func testInfoIsSorted() {
        XCTAssertEqual(E2ECrypto.info(macId: "b", agentId: "a"), "a|b")
        XCTAssertEqual(E2ECrypto.info(macId: "a", agentId: "b"), "a|b")
    }

    func testRoundTrip() throws {
        let (mac, agent) = makePair()
        let message = Data("{\"id\":\"1\",\"m\":\"sys.info\",\"p\":{}}".utf8)
        let body = try mac.seal(message)
        XCTAssertEqual(try agent.open(body), message)

        let reply = Data("{\"id\":\"1\",\"r\":{}}".utf8)
        XCTAssertEqual(try mac.open(try agent.seal(reply)), reply)
    }

    func testCounterStartsAtOneAndIncrements() throws {
        let (mac, agent) = makePair()
        for expected in UInt64(1)...UInt64(4) {
            let body = try mac.seal(Data("hi".utf8))
            let raw = try XCTUnwrap(Base64URL.decode(body))
            let bytes = [UInt8](raw)
            var counter: UInt64 = 0
            for index in 4..<12 { counter = (counter << 8) | UInt64(bytes[index]) }
            XCTAssertEqual(counter, expected)
            _ = try agent.open(body)
        }
    }

    func testReplayIsRejected() throws {
        let (mac, agent) = makePair()
        let first = try mac.seal(Data("one".utf8))
        _ = try agent.open(first)
        XCTAssertThrowsError(try agent.open(first)) { error in
            guard let typed = error as? E2EError, case .replay = typed else {
                return XCTFail("expected a replay error, got \(error)")
            }
        }
    }

    func testWrongDirectionIsRejected() throws {
        let (mac, _) = makePair()
        let body = try mac.seal(Data("one".utf8))
        // Mac 收自己发的帧:方向标记是 m2a,而它只接受 a2m。
        XCTAssertThrowsError(try mac.open(body)) { error in
            XCTAssertEqual(error as? E2EError, E2EError.wrongDirection)
        }
    }

    func testTamperedFrameFails() throws {
        let (mac, agent) = makePair()
        var raw = [UInt8](try XCTUnwrap(Base64URL.decode(try mac.seal(Data("hello".utf8)))))
        raw[raw.count - 1] ^= 0xFF
        XCTAssertThrowsError(try agent.open(frame: Data(raw))) { error in
            XCTAssertEqual(error as? E2EError, E2EError.decryptFailed)
        }
    }

    /// RFC 5869 附录 A.1。手写的 HKDF 必须过标准向量,否则和 Node 对不上。
    func testHKDFAgainstRFC5869() {
        let ikm = Data(repeating: 0x0b, count: 22)
        let salt = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
                         0x0a, 0x0b, 0x0c])
        let info = Data([0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9])
        let out = E2ECrypto.hkdfSHA256(ikm: ikm, salt: salt, info: info, length: 42)
        let expected = "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
        XCTAssertEqual(CoreTestHelpers.hex(out), expected)
    }
}

final class PairingCodeTests: XCTestCase {

    private let sample = "MH1.134.199.230.126:8443.G5A1eDQKxxk1mehRdGnTdLhBmYgheh59KBvHdUARcj8"
        + ".4bpiqf23o63l7kxs5wymtlez4m.zwvRgLscGS8vzoWT8pkknM4gipvItdRJvqzv6SszG0Q"
        + ".ZyITyl0aUSokgAbzMF3LPVGnwzY5BlcxBqhZDg1Ylhk.bWFjaGFuZHMtdG9rZW4wMQ"
        + ".S2FpIOeahCBNYWNCb29rIFBybw"

    func testParsesAnIPv4EndpointWithDots() throws {
        let code = try XCTUnwrap(PairingCode.parse(sample))
        XCTAssertEqual(code.relayEndpoint, "134.199.230.126:8443")
        XCTAssertEqual(code.relayPublicKey, "G5A1eDQKxxk1mehRdGnTdLhBmYgheh59KBvHdUARcj8")
        XCTAssertEqual(code.macId, "4bpiqf23o63l7kxs5wymtlez4m")
        XCTAssertEqual(code.macXPublicKey, "zwvRgLscGS8vzoWT8pkknM4gipvItdRJvqzv6SszG0Q")
        XCTAssertEqual(code.macEdPublicKey, "ZyITyl0aUSokgAbzMF3LPVGnwzY5BlcxBqhZDg1Ylhk")
        XCTAssertEqual(code.token, "bWFjaGFuZHMtdG9rZW4wMQ")
        XCTAssertEqual(code.macName, "Kai 的 MacBook Pro")
    }

    func testEncodeIsTheInverseOfParse() throws {
        let code = try XCTUnwrap(PairingCode.parse(sample))
        XCTAssertEqual(code.encoded, sample)
    }

    func testHostnameEndpointAlsoWorks() throws {
        let built = PairingCode(relayEndpoint: "relay.machands.app:443",
                                relayPublicKey: "AAAA",
                                macId: "4bpiqf23o63l7kxs5wymtlez4m",
                                macXPublicKey: "BBBB",
                                macEdPublicKey: "CCCC",
                                token: "DDDD",
                                macName: "我的 Mac")
        let parsed = try XCTUnwrap(PairingCode.parse(built.encoded))
        XCTAssertEqual(parsed, built)
        XCTAssertEqual(parsed.macName, "我的 Mac")
    }

    func testRejectsRubbish() {
        XCTAssertNil(PairingCode.parse("hello"))
        XCTAssertNil(PairingCode.parse("MH1.only.three.parts"))
        XCTAssertNil(PairingCode.parse("MH2." + sample.dropFirst(4)))
    }

    func testFindsTheCodeInsideAPastedBlock() throws {
        let block = PairingCode.clipboardText(code: sample)
        let found = try XCTUnwrap(PairingCode.find(in: block))
        XCTAssertEqual(found.macId, "4bpiqf23o63l7kxs5wymtlez4m")
    }

    func testClipboardBlockShape() {
        let text = PairingCode.clipboardText(code: sample)
        XCTAssertTrue(text.contains("npx -y machands@latest pair \"\(sample)\""))
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    func testTokenIs16Bytes() {
        let token = PairingCode.newToken()
        XCTAssertEqual(Base64URL.decode(token)?.count, 16)
    }
}

final class PolicyTests: XCTestCase {

    private func engine(_ state: PolicyState) -> PolicyEngine {
        return PolicyEngine(state: state)
    }

    func testAskModeAsksForWritesAndAllowsReads() {
        let policy = engine(PolicyState(mode: .ask))
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "ls"), .ask)
        XCTAssertEqual(policy.decide(agentId: "a", method: "fs.put", subject: "~/x"), .ask)
        XCTAssertEqual(policy.decide(agentId: "a", method: "open", subject: "https://x"), .ask)
        XCTAssertEqual(policy.decide(agentId: "a", method: "clip.set", subject: "hi"), .ask)
        XCTAssertEqual(policy.decide(agentId: "a", method: "fs.get", subject: "~/x"), .allow)
        XCTAssertEqual(policy.decide(agentId: "a", method: "screen.shot", subject: ""), .allow)
        XCTAssertEqual(policy.decide(agentId: "a", method: "sys.info", subject: ""), .allow)
    }

    func testAskForReadsMakesReadsAskToo() {
        let policy = engine(PolicyState(mode: .ask, askForReads: true))
        XCTAssertEqual(policy.decide(agentId: "a", method: "fs.get", subject: "~/x"), .ask)
        XCTAssertEqual(policy.decide(agentId: "a", method: "sys.info", subject: ""), .ask)
    }

    func testAutoAllowsButTheDenylistStillBites() {
        let policy = engine(PolicyState(mode: .auto))
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "ls -la"), .allow)
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "sudo reboot"),
                       .deny(code: "POLICY", reason: "sudo"))
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "rm -rf / --no-preserve-root"),
                       .deny(code: "POLICY", reason: "rm -rf /"))
    }

    func testDenylistDoesNotFireOnAWordThatMerelyContainsIt() {
        let policy = engine(PolicyState(mode: .auto))
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "open sudoku.app"), .allow)
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "echo pseudosudo"), .allow)
    }

    func testPausedRefusesEverything() {
        let policy = engine(PolicyState(mode: .auto, paused: true))
        XCTAssertEqual(policy.decide(agentId: "a", method: "sys.info", subject: ""),
                       .deny(code: "DENIED", reason: "paused"))
    }

    func testHourGrant() {
        let policy = engine(PolicyState(mode: .ask))
        let now = Date()
        policy.grantHour(agentId: "a", now: now)
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "ls", now: now), .allow)
        XCTAssertEqual(policy.decide(agentId: "b", method: "run", subject: "ls", now: now), .ask,
                       "a grant belongs to one agent only")
        let later = now.addingTimeInterval(3601)
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "ls", now: later), .ask)
    }

    func testAlwaysAllowIsAPrefixMatch() {
        let policy = engine(PolicyState(mode: .ask))
        policy.alwaysAllow(prefix: "xcodebuild")
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "xcodebuild -version"), .allow)
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "xcodebuild"), .allow)
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "swift build"), .ask)
    }

    func testLicenseBlocksOnlyRunAndPut() {
        let policy = engine(PolicyState(mode: .auto))
        policy.setLicenseBlocksWrites(true)
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "ls"),
                       .deny(code: "LICENSE", reason: "trial ended"))
        XCTAssertEqual(policy.decide(agentId: "a", method: "fs.put", subject: "~/x"),
                       .deny(code: "LICENSE", reason: "trial ended"))
        XCTAssertEqual(policy.decide(agentId: "a", method: "fs.get", subject: "~/x"), .allow,
                       "reading still works after the trial")
    }

    func testSubjectExtraction() {
        XCTAssertEqual(PolicyEngine.subject(method: "run",
                                            params: .object(["cmd": .string("sw_vers")])), "sw_vers")
        XCTAssertEqual(PolicyEngine.subject(method: "open",
                                            params: .object(["target": .string("https://x")])),
                       "https://x")
        XCTAssertEqual(PolicyEngine.subject(method: "sys.info", params: .object([:])), "")
    }

    func testPublicSnapshotShape() {
        let policy = engine(PolicyState(mode: .ask, allow: ["ls"]))
        let snapshot = policy.publicSnapshot()
        XCTAssertEqual(snapshot["mode"]?.stringValue, "ask")
        XCTAssertEqual(snapshot["allow"]?.arrayValue?.count, 1)
        XCTAssertEqual(snapshot["deny"]?.arrayValue?.count, PolicyEngine.defaultDeny.count)
    }
}

final class RPCTests: XCTestCase {

    func testDecodeRequest() throws {
        let data = Data("{\"id\":\"7\",\"m\":\"run\",\"p\":{\"cmd\":\"sw_vers\",\"timeout\":600}}".utf8)
        let request = try XCTUnwrap(RPCRequest.decode(data))
        XCTAssertEqual(request.id, "7")
        XCTAssertEqual(request.method, "run")
        XCTAssertEqual(request.string("cmd"), "sw_vers")
        XCTAssertEqual(request.int("timeout"), 600)
        XCTAssertNil(request.string("cwd"))
    }

    func testEncodeOutbound() {
        XCTAssertEqual(String(decoding: RPCOutbound.response(id: "7", body: .object(["code": .int(0)])).encoded(),
                              as: UTF8.self),
                       "{\"id\":\"7\",\"r\":{\"code\":0}}")
        XCTAssertEqual(String(decoding: RPCOutbound.stream(id: "7", body: .object(["o": .string("hi")])).encoded(),
                              as: UTF8.self),
                       "{\"id\":\"7\",\"s\":{\"o\":\"hi\"}}")
        XCTAssertEqual(String(decoding: RPCOutbound.fail("7", .denied, "no").encoded(), as: UTF8.self),
                       "{\"e\":{\"code\":\"DENIED\",\"msg\":\"no\"},\"id\":\"7\"}")
    }

    func testTerminality() {
        XCTAssertFalse(RPCOutbound.stream(id: "1", body: .object([:])).isTerminal)
        XCTAssertTrue(RPCOutbound.ok(id: "1").isTerminal)
        XCTAssertTrue(RPCOutbound.fail("1", .eio, "x").isTerminal)
    }
}

final class RelayMessageTests: XCTestCase {

    func testDecodeHello() throws {
        let text = "{\"t\":\"hello\",\"relayId\":\"KEY\",\"nonce\":\"N\",\"ts\":1756800000000,\"ver\":1}"
        guard case .hello(let hello)? = RelayCodec.decode(text) else {
            return XCTFail("did not decode a hello")
        }
        XCTAssertEqual(hello.nonce, "N")
        XCTAssertEqual(hello.ts, 1756800000000)
        XCTAssertEqual(hello.relayKey, "KEY")
    }

    func testDecodeEveryInboundType() {
        XCTAssertNotNil(RelayCodec.decode("{\"t\":\"ok\",\"id\":\"m\",\"ts\":1}"))
        XCTAssertNotNil(RelayCodec.decode("{\"t\":\"err\",\"code\":\"BAD_SIG\",\"msg\":\"no\"}"))
        XCTAssertNotNil(RelayCodec.decode("{\"t\":\"ping\"}"))
        XCTAssertNotNil(RelayCodec.decode("{\"t\":\"recv\",\"from\":\"a\",\"body\":\"x\",\"n\":1}"))
        XCTAssertNotNil(RelayCodec.decode("{\"t\":\"presence\",\"id\":\"a\",\"online\":true}"))
        guard case .unknown(let type)? = RelayCodec.decode("{\"t\":\"whatever\"}") else {
            return XCTFail("unknown types must not be fatal")
        }
        XCTAssertEqual(type, "whatever")
        XCTAssertNil(RelayCodec.decode("not json"))
    }

    func testEncodeAuth() throws {
        let message = AuthMessage(id: "i", edPub: "e", xPub: "x", name: "n", sig: "s")
        let text = try XCTUnwrap(RelayCodec.encode(message))
        XCTAssertTrue(text.contains("\"t\":\"auth\""))
        XCTAssertTrue(text.contains("\"role\":\"mac\""))
    }

    func testAuthPayloadIsTheThreeSignedKeys() {
        let payload = RelayCodec.authPayload(id: "i", nonce: "n", ts: 1756800000000)
        XCTAssertEqual(CanonicalJSON.string(payload),
                       "{\"id\":\"i\",\"nonce\":\"n\",\"ts\":1756800000000}")
    }
}

final class IdentityTests: XCTestCase {

    func testMacIdShape() {
        let identifier = Identity.newMacId()
        XCTAssertEqual(identifier.count, 26)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz234567")
        XCTAssertNil(identifier.rangeOfCharacter(from: allowed.inverted))
    }

    func testBase32KnownVector() {
        // RFC 4648 §10 的 "foobar",小写、无填充。
        XCTAssertEqual(Identity.base32(Data("foobar".utf8)), "mzxw6ytboi")
    }

    func testSignAndVerify() {
        let store = UserDefaultsSecretStore(defaults: freshDefaults(), prefix: "test.")
        let identity = Identity.loadOrCreate(store: store, name: "Test Mac")
        let payload = RelayCodec.authPayload(id: identity.macId, nonce: "N", ts: 1)
        let signature = identity.sign(payload)
        XCTAssertNotNil(signature)
        XCTAssertTrue(Identity.verify(payload: payload,
                                      signatureB64URL: signature ?? "",
                                      edPublicKeyB64URL: identity.edPublicKeyB64))
        let tampered = RelayCodec.authPayload(id: identity.macId, nonce: "M", ts: 1)
        XCTAssertFalse(Identity.verify(payload: tampered,
                                       signatureB64URL: signature ?? "",
                                       edPublicKeyB64URL: identity.edPublicKeyB64))
    }

    func testIdentityIsStable() {
        let defaults = freshDefaults()
        let store = UserDefaultsSecretStore(defaults: defaults, prefix: "test.")
        let first = Identity.loadOrCreate(store: store, name: "A")
        let second = Identity.loadOrCreate(store: store, name: "A")
        XCTAssertEqual(first.macId, second.macId)
        XCTAssertEqual(first.edPublicKeyB64, second.edPublicKeyB64)
        XCTAssertEqual(first.xPublicKeyB64, second.xPublicKeyB64)
    }

    func testTrialAnchorIsWrittenOnce() {
        let store = UserDefaultsSecretStore(defaults: freshDefaults(), prefix: "test.")
        let first = Identity.trialStart(store: store)
        let second = Identity.trialStart(store: store)
        XCTAssertEqual(first.timeIntervalSince1970, second.timeIntervalSince1970, accuracy: 0.001)
    }

    private func freshDefaults() -> UserDefaults {
        let name = "app.machands.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name) ?? UserDefaults.standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

final class LicenseTests: XCTestCase {

    func testVerifyAKeyWeGenerateHere() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = Base64URL.encode(key.publicKey.rawRepresentation)
        let payload = LicensePayload(email: "kai@example.com", exp: nil, seats: 1)
        let text = try XCTUnwrap(License.issue(payload: payload, privateKey: key))

        XCTAssertTrue(text.hasPrefix("MHL1."))
        switch License.verify(text, publicKeyB64URL: publicKey) {
        case .success(let decoded):
            XCTAssertEqual(decoded, payload)
        case .failure(let error):
            XCTFail("should have verified, got \(error)")
        }
    }

    func testAnotherKeyDoesNotVerify() throws {
        let key = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey()
        let text = try XCTUnwrap(License.issue(payload: LicensePayload(email: "a@b", exp: nil, seats: 1),
                                               privateKey: key))
        XCTAssertEqual(License.verify(text, publicKeyB64URL: Base64URL.encode(other.publicKey.rawRepresentation)),
                       .failure(.badSignature))
    }

    func testExpiredLicence() throws {
        let key = Curve25519.Signing.PrivateKey()
        let expiry = Date().addingTimeInterval(-3600).timeIntervalSince1970.rounded()
        let text = try XCTUnwrap(License.issue(payload: LicensePayload(email: "a@b", exp: expiry, seats: 2),
                                               privateKey: key))
        let publicKey = Base64URL.encode(key.publicKey.rawRepresentation)
        XCTAssertEqual(License.verify(text, publicKeyB64URL: publicKey),
                       .failure(.expired(Date(timeIntervalSince1970: expiry))))

        let state = License.state(licenseText: text, trialStart: Date(), publicKeyB64URL: publicKey)
        XCTAssertTrue(state.blocksWrites)
    }

    func testMalformed() {
        XCTAssertEqual(License.verify("nope", publicKeyB64URL: "AAAA"), .failure(.malformed))
        XCTAssertEqual(License.verify("MHL1.a.b.c", publicKeyB64URL: "AAAA"), .failure(.malformed))
    }

    func testTrialWindow() {
        let now = Date()
        let fresh = License.state(licenseText: nil, trialStart: now, now: now)
        XCTAssertEqual(fresh, .trial(daysLeft: 7))
        XCTAssertFalse(fresh.blocksWrites)

        let nearlyOver = License.state(licenseText: "",
                                       trialStart: now.addingTimeInterval(-6.5 * 86400),
                                       now: now)
        XCTAssertEqual(nearlyOver, .trial(daysLeft: 1))

        let over = License.state(licenseText: nil,
                                 trialStart: now.addingTimeInterval(-8 * 86400),
                                 now: now)
        XCTAssertEqual(over, .trialExpired)
        XCTAssertTrue(over.blocksWrites)
    }

    func testEmptyPublicKeyMeansNoLicenceSystemYet() throws {
        // 载荷本身没问题,只是 App 里还没编进公钥。
        let payload = try JSONEncoder().encode(LicensePayload(email: "a@b", exp: nil, seats: 1))
        let text = "MHL1." + Base64URL.encode(payload) + ".AAAA"
        XCTAssertEqual(License.verify(text, publicKeyB64URL: ""), .failure(.noPublicKey))
        XCTAssertEqual(LicensePublicKeyB64URL, "", "发布前要把签发公钥填进 License.swift")
    }
}

final class AuditLogTests: XCTestCase {

    func testOneJSONLineWithEveryField() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("machands-audit-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }

        let log = AuditLog(url: url)
        log.write(AuditLog.Entry(agentId: "a1", agentName: "Claude@vps", method: "run",
                                 summary: "sw_vers", decision: "once",
                                 code: "0", milliseconds: 42))
        log.flush()

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 1)
        let parsed = try XCTUnwrap(JSONValue.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(parsed["agent"]?.stringValue, "a1")
        XCTAssertEqual(parsed["method"]?.stringValue, "run")
        XCTAssertEqual(parsed["summary"]?.stringValue, "sw_vers")
        XCTAssertEqual(parsed["decision"]?.stringValue, "once")
        XCTAssertEqual(parsed["code"]?.stringValue, "0")
        XCTAssertEqual(parsed["ms"]?.intValue, 42)
        XCTAssertNotNil(parsed["ts"]?.stringValue)
    }

    func testNewlinesInACommandStayOnOneLine() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("machands-audit-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = AuditLog(url: url)
        log.write(AuditLog.Entry(agentId: "a", agentName: "n", method: "run",
                                 summary: "one\ntwo\nthree", decision: "once"))
        log.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 1)
    }
}

enum CoreTestHelpers {

    static func bytes(_ key: SymmetricKey) -> Data {
        return key.withUnsafeBytes { raw in Data(Array(raw)) }
    }

    static func hex(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }

    static func unhex(_ text: String) -> Data? {
        let characters = Array(text)
        guard characters.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = 0
        while index < characters.count {
            guard let byte = UInt8(String(characters[index..<(index + 2)]), radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        return Data(bytes)
    }
}
