import XCTest
@testable import MacHandsCore

/// SPEC §10 一次授权:readonly 模式、黑名单的 rootish / wordish 规则、
/// 新方法的读写归类、`policy.check`,以及新方法的 subject 文本。
final class PolicyV2Tests: XCTestCase {

    private func engine(_ state: PolicyState) -> PolicyEngine {
        return PolicyEngine(state: state)
    }

    // MARK: - readonly

    func testReadonlyAllowsReadsAndRefusesWritesWithoutAsking() {
        let policy = engine(PolicyState(mode: .readonly))
        XCTAssertEqual(policy.decide(agentId: "a", method: "fs.get", subject: "~/x"), .allow)
        XCTAssertEqual(policy.decide(agentId: "a", method: "screen.shot", subject: ""), .allow)
        XCTAssertEqual(policy.decide(agentId: "a", method: "job.status", subject: "abc123"), .allow)
        XCTAssertEqual(policy.decide(agentId: "a", method: "sys.perms", subject: ""), .allow)

        let readonly = PolicyDecision.deny(code: "DENIED", reason: "readonly")
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "ls"), readonly)
        XCTAssertEqual(policy.decide(agentId: "a", method: "fs.put", subject: "~/x"), readonly)
        XCTAssertEqual(policy.decide(agentId: "a", method: "input.click", subject: "click 1,2"), readonly)
        XCTAssertEqual(policy.decide(agentId: "a", method: "job.submit", subject: "make"), readonly)
        // 表里没有的方法按写处理:只读模式下也拒,不弹卡。
        XCTAssertEqual(policy.decide(agentId: "a", method: "future.method", subject: ""), readonly)
    }

    func testReadonlyIgnoresGrantsAndAllowlist() {
        let policy = engine(PolicyState(mode: .readonly, allow: ["ls"]))
        policy.grantHour(agentId: "a")
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "ls"),
                       .deny(code: "DENIED", reason: "readonly"),
                       "readonly is a hard mode — neither a grant nor the allowlist opens it")
    }

    func testAlwaysAllowedMethodsInEveryMode() {
        for mode in [ApprovalMode.ask, .auto, .readonly] {
            let policy = engine(PolicyState(mode: mode, askForReads: true))
            XCTAssertEqual(policy.decide(agentId: "a", method: "notify", subject: ""), .allow, "\(mode)")
            XCTAssertEqual(policy.decide(agentId: "a", method: "policy.get", subject: ""), .allow, "\(mode)")
            XCTAssertEqual(policy.decide(agentId: "a", method: "policy.check", subject: "ls -la"), .allow, "\(mode)")
        }
        // 暂停压过一切,连 notify 也拒。
        let paused = engine(PolicyState(mode: .auto, paused: true))
        XCTAssertEqual(paused.decide(agentId: "a", method: "notify", subject: ""),
                       .deny(code: "DENIED", reason: "paused"))
    }

    func testDenyModeRefusesEverythingButTheAlwaysAllowed() {
        let policy = engine(PolicyState(mode: .deny))
        XCTAssertEqual(policy.decide(agentId: "a", method: "fs.get", subject: "~/x"),
                       .deny(code: "DENIED", reason: "mode=deny"))
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "ls"),
                       .deny(code: "DENIED", reason: "mode=deny"))
        XCTAssertEqual(policy.decide(agentId: "a", method: "notify", subject: ""), .allow)
    }

    // MARK: - 黑名单

    func testRootishPatternsOnlyMatchTheWholeRootOrHome() {
        let policy = engine(PolicyState(mode: .auto))
        let root = PolicyDecision.deny(code: "POLICY", reason: "rm -rf /")
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "rm -rf /"), root)
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "rm -rf / "), root)
        // `rm -rf /*` 先被 `rm -rf /` 这一条接住(后面允许紧跟 `*`),命中理由是前者。
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "rm -rf /*"), root)
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "cd /tmp && rm -rf /; echo done"), root)
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "rm -rf ~"),
                       .deny(code: "POLICY", reason: "rm -rf ~"))

        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "rm -rf /tmp/x"), .allow)
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "rm -rf ~/build"), .allow)
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "rm -rf ./dist"), .allow)
    }

    func testWordishPatternsNeedWordBoundaries() {
        let policy = engine(PolicyState(mode: .auto))
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "sudo ls"),
                       .deny(code: "POLICY", reason: "sudo"))
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "echo hi | sudo -S tee /etc/x"),
                       .deny(code: "POLICY", reason: "sudo"))
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "open sudoku.app"), .allow)
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "mkfs.ext4 /dev/disk2"),
                       .deny(code: "POLICY", reason: "mkfs"))
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "diskutil eraseDisk JHFS+ X disk2"),
                       .deny(code: "POLICY", reason: "diskutil erase"))
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "diskutil list"), .allow)
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "killall MacHands"),
                       .deny(code: "POLICY", reason: "killall MacHands"))
        XCTAssertEqual(policy.decide(agentId: "a", method: "run", subject: "killall Godot"), .allow)
    }

    func testDenylistBeatsAskModeAndUserEntriesCount() {
        let asking = engine(PolicyState(mode: .ask))
        XCTAssertEqual(asking.decide(agentId: "a", method: "run", subject: "sudo ls"),
                       .deny(code: "POLICY", reason: "sudo"),
                       "the denylist refuses outright — it never turns into a card")
        // 用户加的条目同样生效,大小写不敏感。
        let custom = engine(PolicyState(mode: .auto, deny: ["git push --force"]))
        XCTAssertEqual(custom.decide(agentId: "a", method: "run", subject: "GIT PUSH --FORCE origin main"),
                       .deny(code: "POLICY", reason: "git push --force"))
    }

    // MARK: - 新方法的归类

    func testAutoAllowsTheNewMethods() {
        let policy = engine(PolicyState(mode: .auto))
        for method in ["input.key", "input.type", "job.submit", "job.kill", "session.open", "mcp.call",
                       "power.assert", "app.relaunch", "verify.run", "screen.record", "sys.which"] {
            XCTAssertEqual(policy.decide(agentId: "a", method: method, subject: "x"), .allow, method)
        }
    }

    func testAskModeAsksForNewWritesAndAllowsNewReads() {
        let policy = engine(PolicyState(mode: .ask))
        for method in ["input.click", "input.key", "job.submit", "job.kill", "session.open", "mcp.open",
                       "mcp.call", "power.assert", "app.relaunch", "verify.run"] {
            XCTAssertEqual(policy.decide(agentId: "a", method: method, subject: "x"), .ask, method)
        }
        for method in ["job.status", "job.tail", "job.list", "session.read", "mcp.servers", "mcp.list",
                       "screen.window", "screen.record", "sys.perms", "sys.which"] {
            XCTAssertEqual(policy.decide(agentId: "a", method: method, subject: "x"), .allow, method)
        }
        // 表里没有的方法按写处理:宁可多问一次。
        XCTAssertEqual(policy.decide(agentId: "a", method: "future.method", subject: ""), .ask)
    }

    func testEveryDispatchedMethodIsClassified() {
        // Executor.perform 的分发表(手抄)。每个方法必须落在读表 / 写表 / 免审表之一,
        // 否则 ask 模式把它当写、readonly 直接拒 —— 也许对,但必须是有意的。
        let dispatched = [
            "sys.info", "sys.perms", "sys.which", "run", "fs.put", "fs.get", "fs.ls",
            "screen.shot", "screen.list", "screen.window", "screen.record",
            "open", "clip.get", "clip.set", "notify", "policy.get", "policy.check",
            "input.where", "input.move", "input.click", "input.drag", "input.scroll", "input.key", "input.type",
            "job.submit", "job.status", "job.tail", "job.result", "job.kill", "job.list",
            "session.open", "session.write", "session.read", "session.close",
            "mcp.servers", "mcp.open", "mcp.list", "mcp.call", "mcp.close",
            "power.assert", "power.release", "app.relaunch", "verify.run"
        ]
        let classified = PolicyEngine.readMethods
            .union(PolicyEngine.writeMethods)
            .union(PolicyEngine.alwaysAllowedMethods)
        for method in dispatched {
            XCTAssertTrue(classified.contains(method), "\(method) is dispatched but not classified")
        }
        XCTAssertTrue(PolicyEngine.readMethods.isDisjoint(with: PolicyEngine.writeMethods))
        XCTAssertTrue(PolicyEngine.alwaysAllowedMethods.isDisjoint(with: PolicyEngine.readMethods))
        XCTAssertTrue(PolicyEngine.alwaysAllowedMethods.isDisjoint(with: PolicyEngine.writeMethods))
    }

    func testLicenseBlocksJobSubmitToo() {
        let policy = engine(PolicyState(mode: .auto))
        policy.setLicenseBlocksWrites(true)
        XCTAssertEqual(policy.decide(agentId: "a", method: "job.submit", subject: "make"),
                       .deny(code: "LICENSE", reason: "trial ended"))
        XCTAssertEqual(policy.decide(agentId: "a", method: "input.click", subject: "click 1,1"), .allow,
                       "only run / fs.put / job.submit are licence-gated")
    }

    // MARK: - policy.check / label / snapshot

    func testCheckIsADryRunOfDecide() {
        let readonly = engine(PolicyState(mode: .readonly))
        XCTAssertEqual(readonly.check(agentId: "a", method: "run", subject: "ls").label, "deny")
        XCTAssertEqual(readonly.check(agentId: "a", method: "fs.get", subject: "~/x").label, "allow")
        XCTAssertEqual(engine(PolicyState(mode: .ask)).check(agentId: "a", method: "run", subject: "ls").label, "ask")
        XCTAssertEqual(PolicyDecision.allow.label, "allow")
        XCTAssertEqual(PolicyDecision.ask.label, "ask")
        XCTAssertEqual(PolicyDecision.deny(code: "POLICY", reason: "sudo").label, "deny")
    }

    func testModesRoundTripThroughRawValues() {
        XCTAssertEqual(ApprovalMode.allCases.map { $0.rawValue }, ["ask", "auto", "readonly", "deny"])
        XCTAssertEqual(ApprovalMode(rawValue: "readonly"), .readonly)
        XCTAssertEqual(engine(PolicyState(mode: .readonly)).publicSnapshot()["mode"]?.stringValue, "readonly")
        XCTAssertEqual(engine(PolicyState(mode: .readonly, paused: true)).publicSnapshot()["mode"]?.stringValue,
                       "deny", "paused shows as deny, whatever the underlying mode")
    }

    // MARK: - subject

    func testSubjectsForTheNewMethods() {
        func subject(_ method: String, _ params: [String: JSONValue]) -> String {
            return PolicyEngine.subject(method: method, params: .object(params))
        }
        XCTAssertEqual(subject("input.click", ["x": .int(640), "y": .int(360)]), "click 640,360")
        XCTAssertEqual(subject("input.move", ["x": .number(10.5), "y": .int(20)]), "move 10.5,20")
        XCTAssertEqual(subject("input.move", [:]), "move ?,?")
        XCTAssertEqual(subject("input.drag", ["x1": .int(1), "y1": .int(2), "x2": .int(3), "y2": .int(4)]),
                       "drag 1,2 → 3,4")
        XCTAssertEqual(subject("input.scroll", ["x": .int(10), "y": .int(20), "dx": .int(0), "dy": .int(-5)]),
                       "scroll 0,-5 @ 10,20")
        XCTAssertEqual(subject("input.key", ["key": .string("s"), "mods": .strings(["cmd", "shift"])]), "cmd+shift+s")
        XCTAssertEqual(subject("input.key", ["key": .string("return")]), "return")
        let long = String(repeating: "a", count: 70)
        XCTAssertEqual(subject("input.type", ["text": .string(long)]), String(repeating: "a", count: 60) + "…")
        XCTAssertEqual(subject("input.type", ["text": .string("hi")]), "hi")
        XCTAssertEqual(subject("job.submit", ["cmd": .string("swift build")]), "swift build")
        XCTAssertEqual(subject("session.open", ["cmd": .string("python3 -i")]), "python3 -i")
        XCTAssertEqual(subject("job.tail", ["jobId": .string("ab12")]), "ab12")
        XCTAssertEqual(subject("session.write", ["sessionId": .string("s1"), "data": .string("secret")]), "s1",
                       "what was typed into a session never reaches the audit log")
        XCTAssertEqual(subject("mcp.open", ["name": .string("chrome")]), "chrome")
        XCTAssertEqual(subject("mcp.open", ["command": .string("npx")]), "npx")
        XCTAssertEqual(subject("mcp.call", ["sessionId": .string("s1"), "tool": .string("screenshot")]), "screenshot")
        XCTAssertEqual(subject("power.assert", ["seconds": .int(600)]), "600s")
        XCTAssertEqual(subject("screen.record", ["seconds": .int(5)]), "5s")
        XCTAssertEqual(subject("screen.window", ["app": .string("Godot")]), "Godot")
        XCTAssertEqual(subject("sys.which", ["names": .strings(["godot", "blender"])]), "godot blender")
        XCTAssertEqual(subject("policy.check", ["method": .string("run"), "subject": .string("rm -rf /")]), "rm -rf /")
        XCTAssertEqual(subject("verify.run", [:]), "")
    }
}
