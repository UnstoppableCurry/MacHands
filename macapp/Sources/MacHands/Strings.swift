import Foundation

/// 铁律 3:任何面向用户的字符串走 i18n。逻辑里不写裸中文,只写 key。
/// 语言:zh(简体中文)/ en(English)/ ja(日本語)/ ko(한국어)。
/// 跟系统语言走,认不出的语言落到 **en**(不是 zh——这是面向全球卖的商业软件,
/// 中文只是我们自己团队的源语言,不该是陌生语言用户看到的兜底)。
/// 用户也可以在设置里手动选;选完要重启才生效,见 Settings.language 上的注释。
enum Lang: String {
    case zh
    case en
    case ja
    case ko
}

struct Strings {

    static var shared = Strings()

    var lang: Lang

    private init() {
        self.lang = Strings.resolveLanguage()
    }

    /// 重新解析一次(设置里手动选了语言之后,下次启动生效)。
    static func reload() {
        shared = Strings()
    }

    private static func resolveLanguage() -> Lang {
        let override = SettingsStore.shared.current.language
        if let forced = Lang(rawValue: override) { return forced }
        for tag in Locale.preferredLanguages {
            let lower = tag.lowercased()
            if lower.hasPrefix("zh") { return .zh }
            if lower.hasPrefix("ja") { return .ja }
            if lower.hasPrefix("ko") { return .ko }
            if lower.hasPrefix("en") { return .en }
        }
        return .en
    }

    func s(_ key: String) -> String {
        guard let row = Strings.table[key] else { return key }
        return row[lang.rawValue] ?? row["en"] ?? row["zh"] ?? key
    }

    func f(_ key: String, _ args: [CVarArg]) -> String {
        return String(format: s(key), arguments: args)
    }

    private static let table: [String: [String: String]] = [

        // --- app ------------------------------------------------------------
        "app.name": ["zh": "MacHands", "en": "MacHands", "ja": "MacHands", "ko": "MacHands"],
        "app.tagline": [
            "zh": "给你的云端 AI 代理一双 Mac 上的手,每一下都经你同意。",
            "en": "Hands on your Mac for your cloud AI agent — every move needs your yes.",
            "ja": "クラウドの AI エージェントに、あなたの Mac を操る手を。ひとつひとつ、あなたの許可のもとで。",
            "ko": "클라우드 AI 에이전트에게 당신의 Mac을 다룰 손을 빌려주세요. 모든 동작은 당신의 승인이 필요합니다."],
        "value.unknown": ["zh": "—", "en": "—", "ja": "—", "ko": "—"],

        // --- 菜单栏 (SPEC §7.1) -----------------------------------------------
        "menu.state.unpaired": ["zh": "还没有 agent 连接", "en": "No agent connected yet",
                                "ja": "まだエージェントが接続していません", "ko": "아직 연결된 에이전트가 없습니다"],
        "menu.state.waiting": ["zh": "等待 agent…", "en": "Waiting for an agent…",
                               "ja": "エージェントを待っています…", "ko": "에이전트를 기다리는 중…"],
        "menu.state.connected": ["zh": "已连接 · %@", "en": "Connected · %@",
                                 "ja": "接続済み · %@", "ko": "연결됨 · %@"],
        "menu.state.connecting": ["zh": "正在连接中继…", "en": "Connecting to the relay…",
                                  "ja": "リレーに接続中…", "ko": "릴레이에 연결하는 중…"],
        "menu.state.offline": ["zh": "连不上中继 · %@", "en": "Cannot reach the relay · %@",
                               "ja": "リレーに接続できません · %@", "ko": "릴레이에 연결할 수 없습니다 · %@"],
        "menu.state.paused": ["zh": "已暂停 · 所有命令都会被拒绝", "en": "Paused · every command is refused",
                              "ja": "一時停止中 · すべてのコマンドが拒否されます", "ko": "일시 중지됨 · 모든 명령이 거부됩니다"],
        "menu.copyForAgent": ["zh": "复制给 agent", "en": "Copy for your agent",
                              "ja": "エージェント用にコピー", "ko": "에이전트용으로 복사"],
        "menu.mode": ["zh": "审批模式", "en": "Approval", "ja": "承認モード", "ko": "승인 모드"],
        "menu.mode.ask": ["zh": "逐条问", "en": "Ask every time", "ja": "毎回確認", "ko": "매번 확인"],
        "menu.mode.auto": ["zh": "自动", "en": "Automatic", "ja": "自動", "ko": "자동"],
        "menu.pause": ["zh": "暂停", "en": "Pause", "ja": "一時停止", "ko": "일시 중지"],
        "menu.resume": ["zh": "恢复", "en": "Resume", "ja": "再開", "ko": "재개"],
        "menu.openAudit": ["zh": "打开审计日志", "en": "Open the audit log",
                           "ja": "監査ログを開く", "ko": "감사 로그 열기"],
        "menu.window": ["zh": "打开主窗口…", "en": "Open the window…",
                        "ja": "ウインドウを開く…", "ko": "창 열기…"],
        "menu.settings": ["zh": "设置…", "en": "Settings…", "ja": "設定…", "ko": "설정…"],
        "menu.quit": ["zh": "退出 MacHands", "en": "Quit MacHands",
                      "ja": "MacHands を終了", "ko": "MacHands 종료"],
        "menu.agentLine": ["zh": "%@ · %@ · %@前", "en": "%@ · %@ · %@ ago",
                           "ja": "%@ · %@ · %@前", "ko": "%@ · %@ · %@ 전"],
        "menu.agentIdle": ["zh": "%@ · 还没执行过命令", "en": "%@ · nothing run yet",
                           "ja": "%@ · まだ何も実行していません", "ko": "%@ · 아직 실행한 명령이 없습니다"],

        // --- 主窗口 (SPEC §7.2) -----------------------------------------------
        "main.headline": ["zh": "把这台 Mac 交给你的 agent", "en": "Hand this Mac to your agent",
                          "ja": "この Mac をエージェントに渡す", "ko": "이 Mac을 에이전트에게 넘겨주세요"],
        "main.copy": ["zh": "复制给 agent", "en": "Copy for your agent",
                      "ja": "エージェント用にコピー", "ko": "에이전트용으로 복사"],
        "main.copied": [
            "zh": "已复制。贴给你的 agent,让它执行那一行。",
            "en": "Copied. Paste it to your agent and let it run that line.",
            "ja": "コピーしました。エージェントに貼り付けて、その 1 行を実行させてください。",
            "ko": "복사했습니다. 에이전트에 붙여넣어 그 한 줄을 실행하게 하세요."],
        "main.copyFailed": ["zh": "复制失败,下面的文字可以手动选。", "en": "Copy failed — select the text below by hand.",
                            "ja": "コピーに失敗しました。下のテキストを手動で選択してください。",
                            "ko": "복사에 실패했습니다. 아래 텍스트를 직접 선택하세요."],
        "main.waiting": ["zh": "等待 agent 连接…", "en": "Waiting for an agent…",
                         "ja": "エージェントの接続を待っています…", "ko": "에이전트 연결을 기다리는 중…"],
        "main.connectedHeadline": [
            "zh": "✓ %@ 已连接。可以关掉这个窗口了。",
            "en": "✓ %@ is connected. You can close this window.",
            "ja": "✓ %@ が接続しました。このウインドウは閉じて構いません。",
            "ko": "✓ %@ 연결되었습니다. 이 창은 닫아도 됩니다."],
        "main.relayDown": [
            "zh": "还连不上中继。%@",
            "en": "Still cannot reach the relay. %@",
            "ja": "まだリレーに接続できません。%@",
            "ko": "아직 릴레이에 연결할 수 없습니다. %@"],
        "main.details": ["zh": "详细信息", "en": "Details", "ja": "詳細", "ko": "세부 정보"],
        "main.relay": ["zh": "中继地址", "en": "Relay", "ja": "リレー", "ko": "릴레이"],
        "main.macName": ["zh": "这台 Mac 的名字", "en": "This Mac's name",
                         "ja": "この Mac の名前", "ko": "이 Mac의 이름"],
        "main.macId": ["zh": "Mac ID", "en": "Mac ID", "ja": "Mac ID", "ko": "Mac ID"],
        "main.mode": ["zh": "审批模式", "en": "Approval mode", "ja": "承認モード", "ko": "승인 모드"],
        "main.mode.ask": ["zh": "逐条问", "en": "Ask each time", "ja": "毎回確認", "ko": "매번 확인"],
        "main.mode.auto": ["zh": "自动放行", "en": "Automatic", "ja": "自動", "ko": "자동"],
        "main.mode.hint.ask": ["zh": "推荐 · 每条命令都要你点头", "en": "Recommended · every command needs your OK",
                               "ja": "おすすめ · すべてのコマンドに承認が必要です",
                               "ko": "권장 · 모든 명령에 승인이 필요합니다"],
        "main.mode.hint.auto": ["zh": "黑名单仍然拦危险命令", "en": "A denylist still blocks the dangerous stuff",
                                "ja": "危険なコマンドはブロックリストで防ぎます",
                                "ko": "위험한 명령은 차단 목록이 계속 막습니다"],
        "main.launchAtLogin": ["zh": "开机自动启动", "en": "Open at login",
                               "ja": "ログイン時に開く", "ko": "로그인 시 자동 실행"],
        "main.openSettings": ["zh": "设置…", "en": "Settings…", "ja": "設定…", "ko": "설정…"],
        "main.pausedBanner": ["zh": "已暂停 —— 所有命令都会被自动拒绝",
                              "en": "Paused — every command is being refused",
                              "ja": "一時停止中 — すべてのコマンドが自動的に拒否されます",
                              "ko": "일시 중지됨 — 모든 명령이 자동으로 거부됩니다"],

        // --- 语言 -----------------------------------------------------------
        "main.language": ["zh": "语言", "en": "Language", "ja": "言語", "ko": "언어"],
        "lang.auto": ["zh": "跟随系统", "en": "System", "ja": "システムに従う", "ko": "시스템 설정"],
        "lang.zh": ["zh": "简体中文", "en": "简体中文", "ja": "简体中文", "ko": "简体中文"],
        "lang.en": ["zh": "English", "en": "English", "ja": "English", "ko": "English"],
        "lang.ja": ["zh": "日本語", "en": "日本語", "ja": "日本語", "ko": "日本語"],
        "lang.ko": ["zh": "한국어", "en": "한국어", "ja": "한국어", "ko": "한국어"],
        "settings.languageHint": [
            "zh": "改了要重启 MacHands 才生效。",
            "en": "Restart MacHands for a language change to take effect.",
            "ja": "言語の変更は MacHands の再起動後に反映されます。",
            "ko": "언어를 변경하면 MacHands를 다시 시작해야 적용됩니다."],

        // --- 配对块 (SPEC §3) --------------------------------------------------
        // 这两行会原样进用户的剪贴板,既是给人看的说明,也是给 agent 的指令。
        "pair.lead": [
            "zh": "把下面这一行在你的机器上执行,然后告诉我结果:",
            "en": "Run this one line on your machine and tell me what it says:",
            "ja": "次の 1 行をあなたのマシンで実行し、結果を教えてください:",
            "ko": "다음 한 줄을 당신의 컴퓨터에서 실행하고 결과를 알려주세요:"],
        "pair.note": [
            "zh": "(这是 MacHands 配对码,10 分钟内有效,只能用一次。)",
            "en": "(A MacHands pairing code — good for 10 minutes, once.)",
            "ja": "(MacHands のペアリングコードです。10 分間だけ有効で、1 回限り使えます。)",
            "ko": "(MacHands 페어링 코드입니다. 10분간 유효하며 한 번만 사용할 수 있습니다.)"],

        // --- 审批卡 (SPEC §5.2 / §7.3) ----------------------------------------
        "approve.title": ["zh": "%@ 想执行", "en": "%@ wants to run",
                          "ja": "%@ が実行しようとしています", "ko": "%@ 이(가) 실행하려고 합니다"],
        "approve.titleGeneric": ["zh": "%@ 请求 %@", "en": "%@ is asking for %@",
                                 "ja": "%@ が %@ を要求しています", "ko": "%@ 이(가) %@ 을(를) 요청합니다"],
        "approve.titleShort": ["zh": "想执行一条命令", "en": "wants to run a command",
                               "ja": "コマンドを実行しようとしています", "ko": "명령을 실행하려고 합니다"],
        "approve.titleGenericShort": ["zh": "请求 %@", "en": "is asking for %@",
                                      "ja": "%@ を要求しています", "ko": "%@ 을(를) 요청합니다"],
        "approve.once": ["zh": "允许一次", "en": "Allow once", "ja": "1 回だけ許可", "ko": "한 번만 허용"],
        "approve.hour": ["zh": "允许 1 小时", "en": "Allow for an hour",
                         "ja": "1 時間許可", "ko": "1시간 허용"],
        "approve.always": ["zh": "总是允许这条", "en": "Always allow this",
                           "ja": "常にこのコマンドを許可", "ko": "이 명령은 항상 허용"],
        "approve.deny": ["zh": "拒绝", "en": "Refuse", "ja": "拒否", "ko": "거부"],
        "approve.more": ["zh": "还有 %d 条", "en": "%d more waiting",
                         "ja": "他に %d 件待機中", "ko": "%d개 더 대기 중"],
        "approve.cwd": ["zh": "目录", "en": "Folder", "ja": "フォルダ", "ko": "폴더"],
        "approve.from": ["zh": "来源", "en": "From", "ja": "送信元", "ko": "출처"],
        "approve.expand": ["zh": "展开全部", "en": "Show all", "ja": "すべて表示", "ko": "모두 보기"],
        "approve.collapse": ["zh": "收起", "en": "Collapse", "ja": "折りたたむ", "ko": "접기"],
        "approve.timeout": ["zh": "%d 秒后自动拒绝", "en": "refused automatically in %ds",
                            "ja": "%d 秒後に自動的に拒否されます", "ko": "%d초 후 자동으로 거부됩니다"],

        // --- 设置窗口 (SPEC §7.2 末) -------------------------------------------
        "settings.title": ["zh": "MacHands 设置", "en": "MacHands Settings",
                           "ja": "MacHands 設定", "ko": "MacHands 설정"],
        "settings.relay": ["zh": "中继地址", "en": "Relay address", "ja": "リレーアドレス", "ko": "릴레이 주소"],
        "settings.relayHint": [
            "zh": "改了要重连。留空恢复默认。",
            "en": "Changing this reconnects. Empty restores the default.",
            "ja": "変更すると再接続します。空欄にすると既定値に戻ります。",
            "ko": "변경하면 다시 연결됩니다. 비워두면 기본값으로 돌아갑니다."],
        "settings.agents": ["zh": "已授权的 agent", "en": "Authorised agents",
                            "ja": "承認済みのエージェント", "ko": "승인된 에이전트"],
        "settings.noAgents": ["zh": "还没有。", "en": "None yet.", "ja": "まだありません。", "ko": "아직 없습니다."],
        "settings.revoke": ["zh": "撤销", "en": "Revoke", "ja": "取り消す", "ko": "취소"],
        "settings.allow": ["zh": "白名单(命令前缀,一行一条)", "en": "Allowlist (command prefixes, one per line)",
                           "ja": "許可リスト(コマンドの接頭辞、1 行に 1 件)",
                           "ko": "허용 목록(명령 접두사, 한 줄에 하나씩)"],
        "settings.deny": ["zh": "黑名单(一行一条)", "en": "Denylist (one per line)",
                          "ja": "拒否リスト(1 行に 1 件)", "ko": "차단 목록(한 줄에 하나씩)"],
        "settings.denyBuiltin": [
            "zh": "内置黑名单永远生效:%@",
            "en": "These are always blocked: %@",
            "ja": "常にブロックされる項目:%@",
            "ko": "항상 차단되는 항목: %@"],
        "settings.askForReads": ["zh": "读取也要问", "en": "Ask before reads too",
                                 "ja": "読み取りも確認する", "ko": "읽기도 확인하기"],
        "settings.license": ["zh": "许可证", "en": "Licence", "ja": "ライセンス", "ko": "라이선스"],
        "settings.licensePlaceholder": ["zh": "MHL1.…", "en": "MHL1.…", "ja": "MHL1.…", "ko": "MHL1.…"],
        "settings.save": ["zh": "保存", "en": "Save", "ja": "保存", "ko": "저장"],
        "settings.saved": ["zh": "已保存。", "en": "Saved.", "ja": "保存しました。", "ko": "저장했습니다."],
        "settings.badRelay": [
            "zh": "中继地址要以 ws:// 或 wss:// 开头。",
            "en": "The relay address must start with ws:// or wss://.",
            "ja": "リレーアドレスは ws:// または wss:// で始まる必要があります。",
            "ko": "릴레이 주소는 ws:// 또는 wss://로 시작해야 합니다."],

        // --- 许可证 (SPEC §7.5) -----------------------------------------------
        "license.trial": ["zh": "试用中,还剩 %d 天", "en": "Trial · %d days left",
                          "ja": "試用期間 · 残り %d 日", "ko": "체험판 · %d일 남음"],
        "license.ok": ["zh": "已授权 · %@", "en": "Licensed · %@", "ja": "ライセンス済み · %@", "ko": "라이선스됨 · %@"],
        "license.expired": ["zh": "许可证已过期 · %@", "en": "Licence expired · %@",
                            "ja": "ライセンスの有効期限が切れました · %@", "ko": "라이선스가 만료되었습니다 · %@"],
        "license.invalid": ["zh": "许可证无效", "en": "Licence is not valid",
                            "ja": "ライセンスが無効です", "ko": "유효하지 않은 라이선스입니다"],
        "license.blocked": [
            "zh": "试用结束:执行命令与写文件已停用,配对和查看还能用。",
            "en": "Trial over: running and writing are off; pairing and viewing still work.",
            "ja": "試用期間が終了しました:コマンド実行とファイル書き込みは停止していますが、ペアリングと閲覧は引き続き使えます。",
            "ko": "체험 기간이 종료되었습니다: 명령 실행과 파일 쓰기는 중지되었지만 페어링과 보기는 계속 사용할 수 있습니다."],

        // --- 通知 --------------------------------------------------------------
        "notify.paired.title": ["zh": "%@ 已连接", "en": "%@ is connected",
                                "ja": "%@ が接続しました", "ko": "%@ 연결됨"],
        "notify.paired.body": [
            "zh": "它现在可以在这台 Mac 上执行命令了。每一条都会先问你。",
            "en": "It can act on this Mac now. Every command asks you first.",
            "ja": "この Mac 上で操作できるようになりました。どのコマンドも先にあなたに確認します。",
            "ko": "이제 이 Mac에서 작업할 수 있습니다. 모든 명령은 먼저 당신에게 확인합니다."],
        "notify.approval.title": ["zh": "%@ 在等你批准", "en": "%@ is waiting for you",
                                  "ja": "%@ があなたの承認を待っています", "ko": "%@ 이(가) 당신의 승인을 기다립니다"],

        // --- 权限引导 (SPEC §7.4) ----------------------------------------------
        "perm.screen.title": ["zh": "agent 想截屏,需要你授权一次", "en": "The agent wants a screenshot — one-time permission",
                              "ja": "エージェントがスクリーンショットを要求しています — 初回のみ許可が必要です",
                              "ko": "에이전트가 스크린샷을 요청합니다 — 최초 1회 권한이 필요합니다"],
        "perm.screen.body": [
            "zh": "在「隐私与安全性 → 屏幕录制」里勾上 MacHands,然后回来重试。",
            "en": "Tick MacHands under Privacy & Security → Screen Recording, then try again.",
            "ja": "「プライバシーとセキュリティ → 画面収録」で MacHands にチェックを入れ、もう一度お試しください。",
            "ko": "개인정보 보호 및 보안 → 화면 기록에서 MacHands를 체크한 뒤 다시 시도하세요."],
        "perm.screen.open": ["zh": "打开设置", "en": "Open Settings", "ja": "設定を開く", "ko": "설정 열기"],
        "perm.screen.rpc": ["zh": "需要在 Mac 上授权屏幕录制", "en": "screen recording must be allowed on the Mac",
                            "ja": "Mac で画面収録を許可する必要があります",
                            "ko": "Mac에서 화면 기록을 허용해야 합니다"],
        "perm.later": ["zh": "以后再说", "en": "Later", "ja": "あとで", "ko": "나중에"],

        // --- 降级说明 ------------------------------------------------------------
        "err.notBundled": [
            "zh": "开机自启需要打包好的 MacHands.app,不能是 .build 里的裸二进制。",
            "en": "Open at login needs the packaged MacHands.app, not the bare build product.",
            "ja": "ログイン時起動にはパッケージ化された MacHands.app が必要です。.build 内の裸のバイナリでは動作しません。",
            "ko": "로그인 시 자동 실행에는 패키징된 MacHands.app이 필요합니다. .build의 원본 바이너리로는 동작하지 않습니다."],

        // --- 连接失败 ------------------------------------------------------------
        "fail.dns": ["zh": "找不到中继的地址", "en": "cannot resolve the relay's address",
                     "ja": "リレーのアドレスを解決できません", "ko": "릴레이 주소를 확인할 수 없습니다"],
        "fail.refused": ["zh": "中继没有应答", "en": "the relay does not answer",
                         "ja": "リレーが応答しません", "ko": "릴레이가 응답하지 않습니다"],
        "fail.badSig": ["zh": "中继不认这台 Mac 的签名", "en": "the relay rejected this Mac's signature",
                        "ja": "リレーがこの Mac の署名を拒否しました", "ko": "릴레이가 이 Mac의 서명을 거부했습니다"],
        "fail.banned": ["zh": "这台 Mac 被中继拒绝了", "en": "the relay refuses this Mac",
                        "ja": "リレーがこの Mac を拒否しています", "ko": "릴레이가 이 Mac을 거부합니다"],
        "fail.network": ["zh": "网络不通", "en": "no network", "ja": "ネットワークに接続できません", "ko": "네트워크 연결 없음"],
        "fail.retry": ["zh": "%@ 后重试", "en": "retrying in %@", "ja": "%@ 後に再試行", "ko": "%@ 후 재시도"],

        // --- v0.2 一次授权 (SPEC §10) ---------------------------------------------
        "menu.mode.readonly": ["zh": "只读", "en": "Read-only"],
        "main.mode.readonly": ["zh": "只读", "en": "Read-only"],
        "main.mode.hint.readonly": ["zh": "只能看,不能改", "en": "Can look, cannot change"],
        "menu.authorize": ["zh": "授权与验证…", "en": "Authorize & verify…"],
        "menu.authorized": ["zh": "已授权 · %@", "en": "Authorized · %@"],
        "auth.headline": ["zh": "✓ %@ 已连接。选一次授权范围,之后不再打扰。",
                          "en": "✓ %@ is connected. Pick a scope once — it won't ask again."],
        "auth.title": ["zh": "授权范围(只需选一次)", "en": "Access scope (choose once)"],
        "auth.scope.auto": ["zh": "开发者 — 全部允许;危险命令仍被黑名单拦下",
                            "en": "Developer — everything allowed; the denylist still blocks the dangerous stuff"],
        "auth.scope.readonly": ["zh": "只读 — 只能看,不能改", "en": "Read-only — look, don't touch"],
        "auth.scope.ask": ["zh": "逐条审批 — 每条命令都问我", "en": "Ask — approve every command"],
        "auth.recommended": ["zh": "推荐", "en": "Recommended"],
        "auth.perms.title": ["zh": "需要的系统权限", "en": "System permissions needed"],
        "perm.notify.name": ["zh": "通知", "en": "Notifications"],
        "perm.notify.desc": ["zh": "agent 提醒你时用", "en": "So the agent can reach you"],
        "perm.screen.name": ["zh": "屏幕录制", "en": "Screen Recording"],
        "perm.screen.desc": ["zh": "截屏、录屏", "en": "Screenshots and recordings"],
        "perm.ax.name": ["zh": "辅助功能", "en": "Accessibility"],
        "perm.ax.desc": ["zh": "键盘鼠标(手感测试、点按钮)", "en": "Keyboard & mouse (play-testing, clicking buttons)"],
        "perm.state.ok": ["zh": "已授权", "en": "Granted"],
        "perm.state.no": ["zh": "未授权", "en": "Not granted"],
        "perm.state.unknown": ["zh": "未知", "en": "Unknown"],
        "perm.open": ["zh": "打开设置", "en": "Open Settings"],
        "perm.ax.rpc": ["zh": "需要在 Mac 上授权辅助功能(隐私与安全性 → 辅助功能 → 勾上 MacHands)",
                        "en": "accessibility must be allowed on the Mac (Privacy & Security → Accessibility → tick MacHands)"],
        "perm.notify.rpc": ["zh": "需要在 Mac 上允许 MacHands 发通知", "en": "notifications must be allowed for MacHands on the Mac"],
        "auth.button": ["zh": "授权并验证", "en": "Authorize & verify"],
        "auth.reverify": ["zh": "重新验证", "en": "Verify again"],
        "auth.verifying": ["zh": "正在验证…", "en": "Verifying…"],
        "auth.done": ["zh": "已授权 · %@", "en": "Authorized · %@"],
        "verify.title": ["zh": "验证结果", "en": "Results"],
        "verify.run": ["zh": "执行命令", "en": "Run commands"],
        "verify.fs": ["zh": "读写文件", "en": "Read & write files"],
        "verify.screen": ["zh": "截屏", "en": "Screenshot"],
        "verify.input": ["zh": "键鼠", "en": "Keyboard & mouse"],
        "verify.notify": ["zh": "通知", "en": "Notification"],
        "verify.job": ["zh": "后台作业", "en": "Background job"],
        "verify.mcp": ["zh": "MCP 桥", "en": "MCP bridge"],
        "verify.allPass": ["zh": "全部通过,可以关掉这个窗口了。", "en": "Everything passed. You can close this window."],
        "verify.someFail": ["zh": "有 %d 项没过,按提示处理后点「重新验证」。",
                            "en": "%d item(s) failed — follow the hints, then verify again."],
        "verify.notify.body": ["zh": "验证通过:agent 可以在这台 Mac 上干活了。",
                               "en": "Verified: the agent can work on this Mac now."],
        "notify.paired.body.v2": ["zh": "打开 MacHands 窗口选一次授权范围,之后不再打扰。",
                                  "en": "Open the MacHands window, pick a scope once, and it won't ask again."],

        // --- 时间 ---------------------------------------------------------------
        "time.now": ["zh": "刚刚", "en": "just now", "ja": "たった今", "ko": "방금"],
        "time.seconds": ["zh": "%d 秒", "en": "%ds", "ja": "%d 秒", "ko": "%d초"],
        "time.minutes": ["zh": "%d 分", "en": "%dm", "ja": "%d 分", "ko": "%d분"],
        "time.hours": ["zh": "%d 小时", "en": "%dh", "ja": "%d 時間", "ko": "%d시간"],
        "time.days": ["zh": "%d 天", "en": "%dd", "ja": "%d 日", "ko": "%d일"]
    ]
}

func L(_ key: String) -> String {
    return Strings.shared.s(key)
}

/// 故意与 `L` 不同名:一个变参重载会让每个调用点都歧义。
func Lf(_ key: String, _ args: CVarArg...) -> String {
    return Strings.shared.f(key, args)
}
