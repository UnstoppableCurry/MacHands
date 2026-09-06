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
        "time.days": ["zh": "%d 天", "en": "%dd", "ja": "%d 日", "ko": "%d일"],

        // --- 审批卡打磨(设计定稿,ApprovalPanel.swift 专用;键名前缀 approval.)----------
        // 两颗主按钮:"允许这一条"(实心)与"拒绝"(浅灰底)。"允许 1 小时 / 总是允许"
        // 沿用上面 approve.hour / approve.always,只降成次要样式,文案不变。
        "approval.allowThis": ["zh": "允许这一条", "en": "Allow this one",
                               "ja": "この 1 件を許可", "ko": "이 명령만 허용"],
        // 卡片不抢焦点(铁律 5),数字键要先点一下卡才生效;没焦点时把这句话说明白,
        // 拿到焦点后才列按键。
        "approval.focusHint": ["zh": "点一下这张卡,就能用键盘", "en": "Click this card to use the keyboard",
                               "ja": "このカードをクリックするとキーボードで操作できます",
                               "ko": "이 카드를 클릭하면 키보드로 조작할 수 있습니다"],
        "approval.keysHint": ["zh": "1 允许这一条 · 4 / Esc 拒绝 · 2 允许 1 小时 · 3 总是允许",
                              "en": "1 allow · 4 / Esc refuse · 2 for an hour · 3 always",
                              "ja": "1 許可 · 4 / Esc 拒否 · 2 1 時間許可 · 3 常に許可",
                              "ko": "1 허용 · 4 / Esc 거부 · 2 1시간 허용 · 3 항상 허용"],
        // 收尾态:点了允许/拒绝之后卡片停 1.6 秒,对勾/叉号 + 这一行,再收起。
        "approval.doneAllowed": ["zh": "已允许,命令正在执行", "en": "Allowed — the command is running",
                                 "ja": "許可しました。コマンドを実行中です", "ko": "허용했습니다. 명령을 실행 중입니다"],
        "approval.doneAllowedHour": ["zh": "已允许,接下来 1 小时不再问", "en": "Allowed — no more asking for an hour",
                                     "ja": "許可しました。これから 1 時間は確認しません",
                                     "ko": "허용했습니다. 앞으로 1시간 동안 묻지 않습니다"],
        "approval.doneAllowedAlways": ["zh": "已允许,这条以后不再问", "en": "Allowed — this one is never asked again",
                                       "ja": "許可しました。このコマンドは今後確認しません",
                                       "ko": "허용했습니다. 이 명령은 다시 묻지 않습니다"],
        "approval.doneDenied": ["zh": "已拒绝,命令没有执行", "en": "Refused — nothing was run",
                                "ja": "拒否しました。コマンドは実行されません", "ko": "거부했습니다. 명령은 실행되지 않았습니다"],
        "approval.doneTimeout": ["zh": "没人回应,已自动拒绝,命令没有执行",
                                 "en": "No answer — refused automatically, nothing was run",
                                 "ja": "応答がなかったため自動的に拒否しました。コマンドは実行されません",
                                 "ko": "응답이 없어 자동으로 거부했습니다. 명령은 실행되지 않았습니다"],
        // 风险胶囊(只读 = 绿 accentA,会写盘 = 橙 warning,删除 = 红 danger)+ 一句说明。
        // 说明按"档位 × 方法"挑,挑不到用档位的通用那句(ApprovalRisk.swift 判档)。
        "approval.risk.read": ["zh": "只读", "en": "Read-only", "ja": "読み取りのみ", "ko": "읽기 전용"],
        "approval.risk.write": ["zh": "会写盘", "en": "Writes files", "ja": "書き込みあり", "ko": "파일 쓰기"],
        "approval.risk.delete": ["zh": "删除", "en": "Deletes", "ja": "削除", "ko": "삭제"],
        "approval.risk.explain.read": ["zh": "只看不改,不会动你的文件。", "en": "Looks only — nothing on your Mac changes.",
                                       "ja": "見るだけで、ファイルは変更しません。", "ko": "보기만 하며, 파일을 바꾸지 않습니다."],
        "approval.risk.explain.read.fs": ["zh": "只读取这个路径,不会改它。", "en": "Reads this path only — it is not changed.",
                                          "ja": "このパスを読み取るだけで、変更はしません。", "ko": "이 경로를 읽기만 하고 바꾸지 않습니다."],
        "approval.risk.explain.read.screen": ["zh": "只截一张屏幕图,不改任何东西。", "en": "Takes a screenshot — nothing changes.",
                                              "ja": "画面を撮るだけで、何も変更しません。", "ko": "화면을 찍기만 하고 아무것도 바꾸지 않습니다."],
        "approval.risk.explain.read.clip": ["zh": "只读取剪贴板里的文字。", "en": "Reads what is on the clipboard.",
                                            "ja": "クリップボードの内容を読み取るだけです。", "ko": "클립보드의 내용을 읽기만 합니다."],
        "approval.risk.explain.read.sys": ["zh": "只读取这台 Mac 的基本信息。", "en": "Reads basic facts about this Mac.",
                                           "ja": "この Mac の基本情報を読み取るだけです。", "ko": "이 Mac의 기본 정보만 읽습니다."],
        "approval.risk.explain.write": ["zh": "可能新建或修改文件,请看清命令。", "en": "May create or change files — read it first.",
                                        "ja": "ファイルを作成・変更する可能性があります。内容を確認してください。",
                                        "ko": "파일을 만들거나 바꿀 수 있습니다. 명령을 확인하세요."],
        "approval.risk.explain.write.fs": ["zh": "会写入这个路径,已有内容会被覆盖。", "en": "Writes this path — existing content is replaced.",
                                           "ja": "このパスに書き込みます。既存の内容は上書きされます。",
                                           "ko": "이 경로에 씁니다. 기존 내용은 덮어씁니다."],
        "approval.risk.explain.write.open": ["zh": "会打开一个程序、文件或网址。", "en": "Opens an app, a file or a link.",
                                             "ja": "アプリ、ファイル、または URL を開きます。", "ko": "앱, 파일 또는 링크를 엽니다."],
        "approval.risk.explain.write.clip": ["zh": "会替换你剪贴板里的内容。", "en": "Replaces what is on your clipboard.",
                                             "ja": "クリップボードの内容を置き換えます。", "ko": "클립보드의 내용을 바꿉니다."],
        "approval.risk.explain.delete": ["zh": "会删除文件,删掉就找不回来了。", "en": "Deletes files — gone is gone.",
                                         "ja": "ファイルを削除します。元に戻せません。", "ko": "파일을 삭제합니다. 되돌릴 수 없습니다."]
        // --- v0.3 更新与意图 -----------------------------------------------------
        // 这一块整体是 v0.3 新增的,放在文件最后、自成一段,别往上面的区块里插。

        // 菜单与更新提示
        "menu.checkUpdates": ["zh": "检查更新…", "en": "Check for updates…"],
        "menu.updateAvailable": ["zh": "有新版本 %@", "en": "Version %@ is available"],
        "update.ok": ["zh": "好", "en": "OK"],
        "update.alert.current": ["zh": "已经是最新版 %@。", "en": "You're on the latest version, %@."],
        "update.alert.found": ["zh": "有新版本 %@。", "en": "Version %@ is available."],
        "update.alert.installing": ["zh": "正在装 %@,装好会自动重开。",
                                    "en": "Installing %@ — MacHands will reopen itself when it's done."],
        "update.fix": ["zh": "确认这台 Mac 能上网,并且设置里的更新地址是 https 开头。",
                       "en": "Check this Mac's internet connection, and that the update host in Settings starts with https."],

        // 更新失败的原因(每种一句话,别混成一句)
        "update.err.busy": ["zh": "已经在更新了。", "en": "An update is already running."],
        "update.err.host": ["zh": "更新地址必须以 https:// 开头。", "en": "The update host must start with https://."],
        "update.err.network": ["zh": "连不上更新服务器:%@", "en": "Cannot reach the update server: %@"],
        "update.err.timeout": ["zh": "超时", "en": "timed out"],
        "update.err.badAppcast": ["zh": "更新信息读不懂(appcast 格式不对)。",
                                  "en": "The update manifest is not readable (bad appcast)."],
        "update.err.notHTTPS": ["zh": "更新包的下载地址不是 https,已拒绝。",
                                "en": "The download URL is not https — refused."],
        "update.err.minOS": ["zh": "新版本要求 macOS %@ 或更新的系统。",
                             "en": "The new version needs macOS %@ or later."],
        "update.err.notBundle": ["zh": "不是从 .app 里运行的,没法自我更新。",
                                 "en": "Not running from a .app bundle — self-update is not possible."],
        "update.err.translocated": ["zh": "MacHands 现在是从只读的临时位置运行的(直接从 DMG 或下载目录打开会这样)。请先把它拖进「应用程序」,再打开。",
                                    "en": "MacHands is running from a read-only temporary location (that happens when you open it straight from a DMG or the Downloads folder). Move it to Applications first, then open it."],
        "update.err.location": ["zh": "只有装在「应用程序」里才能自我更新。当前位置:%@",
                                "en": "Self-update only works from the Applications folder. Currently at: %@"],
        "update.err.disk": ["zh": "磁盘剩余空间不足 %d MB,先腾点地方。",
                            "en": "Less than %d MB free — clear some space first."],
        "update.err.readonly": ["zh": "没有写这个位置的权限:%@", "en": "No permission to write here: %@"],
        "update.err.tempDir": ["zh": "建不了临时目录,更新中止。", "en": "Cannot create a temporary folder — update stopped."],
        "update.err.readBack": ["zh": "下载的文件读不回来。", "en": "The downloaded file cannot be read back."],
        "update.err.sha": ["zh": "下载的文件校验不过(算出来 %@…,应该是 %@…),已丢弃。",
                           "en": "The download failed its checksum (got %@…, expected %@…) — discarded."],
        "update.err.signature": ["zh": "更新包的签名验不过,已拒绝安装。",
                                 "en": "The update's signature did not verify — refused."],
        "update.err.unzip": ["zh": "解压失败:%@", "en": "Unpacking failed: %@"],
        "update.err.noApp": ["zh": "更新包里没找到 MacHands.app。", "en": "No MacHands.app inside the update."],
        "update.err.codesign": ["zh": "新版本的代码签名不完整:%@", "en": "The new version's code signature is broken: %@"],
        "update.err.drUnreadable": ["zh": "读不出签名要求,不敢换,已保留当前版本。",
                                    "en": "Cannot read the code signing requirement — keeping the current version."],
        "update.err.drMismatch": ["zh": "新版本的签名和当前版本不一致,已拒绝(换签名会让系统清掉屏幕录制等授权)。",
                                  "en": "The new version is signed differently — refused (a signing change makes macOS drop Screen Recording and other permissions)."],
        "update.err.replace": ["zh": "替换失败,已保留当前版本:%@",
                               "en": "Replacing the app failed — the current version is untouched: %@"],

        // 多份安装
        "install.dup.title": ["zh": "这台 Mac 上有不止一个 MacHands", "en": "More than one copy of MacHands on this Mac"],
        "install.dup.body": ["zh": "正在运行的是:\n%@\n\n下面这些拷贝也在磁盘上。它们共用同一份身份,谁先打开谁就接管 agent 连接,还会互相顶掉系统授权。建议只留一个,其余拖进废纸篓(我不会替你删):",
                             "en": "Running from:\n%@\n\nThese other copies are also on disk. They share one identity, so whichever opens first takes over the agent connection — and they knock out each other's system permissions. Keep one and move the rest to the Trash (I won't delete anything for you):"],
        "install.dup.reveal": ["zh": "在访达中显示", "en": "Show in Finder"],

        // 自画窗口截图
        "selfshot.noMain": ["zh": "主窗口没开。先调 app.showWindow,或者在 Mac 上点菜单栏那只手。",
                            "en": "The main window isn't open. Call app.showWindow first, or click the hand in the Mac's menu bar."],
        "selfshot.noApproval": ["zh": "现在没有待审批的卡片。", "en": "There's no approval card on screen right now."],
        "selfshot.noWindows": ["zh": "MacHands 现在一个窗口都没开。", "en": "MacHands has no open windows right now."],
        "verify.screen.fallback": ["zh": "可用 screen.selfshot 看 App 自己的界面",
                                   "en": "use screen.selfshot to see the app's own windows"],
        "verify.update": ["zh": "更新通道", "en": "Updates"],

        // 意图:它动的是哪一块
        "intent.area.terminal": ["zh": "终端", "en": "Terminal"],
        "intent.area.files": ["zh": "文件", "en": "Files"],
        "intent.area.screen": ["zh": "屏幕", "en": "Screen"],
        "intent.area.input": ["zh": "键鼠", "en": "Keyboard & mouse"],
        "intent.area.clipboard": ["zh": "剪贴板", "en": "Clipboard"],
        "intent.area.web": ["zh": "网页", "en": "Web"],
        "intent.area.tools": ["zh": "工具", "en": "Tools"],
        "intent.area.mac": ["zh": "系统", "en": "System"],

        // 意图:它想干什么(agent 没说 why 时用这些)
        "intent.run.git": ["zh": "用 git 操作代码仓库", "en": "Work on the repository with git"],
        "intent.run.npm": ["zh": "跑一条 npm 命令", "en": "Run an npm command"],
        "intent.run.swift": ["zh": "编译或测试 Swift 代码", "en": "Build or test Swift code"],
        "intent.run.xcodebuild": ["zh": "用 Xcode 编译工程", "en": "Build the project with Xcode"],
        "intent.run.godot": ["zh": "跑 Godot(游戏引擎)", "en": "Run Godot, the game engine"],
        "intent.run.blender": ["zh": "跑 Blender(三维建模)", "en": "Run Blender for 3-D work"],
        "intent.run.python": ["zh": "跑一段 Python", "en": "Run some Python"],
        "intent.run.node": ["zh": "跑一段 Node.js", "en": "Run some Node.js"],
        "intent.run.brew": ["zh": "用 Homebrew 装或查软件", "en": "Install or check software with Homebrew"],
        "intent.run.ffmpeg": ["zh": "用 ffmpeg 处理音视频", "en": "Process audio or video with ffmpeg"],
        "intent.run.make": ["zh": "跑 make 构建", "en": "Run a make build"],
        "intent.run.cargo": ["zh": "编译或测试 Rust 代码", "en": "Build or test Rust code"],
        "intent.run.docker": ["zh": "操作 Docker 容器", "en": "Work with Docker containers"],
        "intent.run.test": ["zh": "跑一遍测试", "en": "Run the tests"],
        "intent.run.ls": ["zh": "看看目录里有什么", "en": "Look at what's in a folder"],
        "intent.run.search": ["zh": "在文件里搜东西", "en": "Search through files"],
        "intent.run.net": ["zh": "从网上取东西", "en": "Fetch something from the network"],
        "intent.run.other": ["zh": "在终端里执行 %@", "en": "Run %@ in the terminal"],

        "intent.job.submit.git": ["zh": "在后台用 git 操作仓库", "en": "Work on the repository with git, in the background"],
        "intent.job.submit.npm": ["zh": "在后台跑一条 npm 命令", "en": "Run an npm command in the background"],
        "intent.job.submit.swift": ["zh": "在后台编译或测试 Swift 代码", "en": "Build or test Swift code in the background"],
        "intent.job.submit.xcodebuild": ["zh": "在后台用 Xcode 编译工程", "en": "Build the project with Xcode in the background"],
        "intent.job.submit.godot": ["zh": "在后台跑 Godot", "en": "Run Godot in the background"],
        "intent.job.submit.blender": ["zh": "在后台跑 Blender", "en": "Run Blender in the background"],
        "intent.job.submit.python": ["zh": "在后台跑一段 Python", "en": "Run some Python in the background"],
        "intent.job.submit.node": ["zh": "在后台跑一段 Node.js", "en": "Run some Node.js in the background"],
        "intent.job.submit.brew": ["zh": "在后台用 Homebrew 装软件", "en": "Install software with Homebrew in the background"],
        "intent.job.submit.ffmpeg": ["zh": "在后台用 ffmpeg 处理音视频", "en": "Process media with ffmpeg in the background"],
        "intent.job.submit.make": ["zh": "在后台跑 make 构建", "en": "Run a make build in the background"],
        "intent.job.submit.cargo": ["zh": "在后台编译或测试 Rust 代码", "en": "Build or test Rust code in the background"],
        "intent.job.submit.docker": ["zh": "在后台操作 Docker", "en": "Work with Docker in the background"],
        "intent.job.submit.test": ["zh": "在后台跑一遍测试", "en": "Run the tests in the background"],
        "intent.job.submit.ls": ["zh": "在后台列目录", "en": "List a folder in the background"],
        "intent.job.submit.search": ["zh": "在后台搜文件", "en": "Search files in the background"],
        "intent.job.submit.net": ["zh": "在后台从网上取东西", "en": "Fetch something from the network in the background"],
        "intent.job.submit.other": ["zh": "在后台执行 %@", "en": "Run %@ in the background"],

        "intent.fs.put": ["zh": "写入文件 %@", "en": "Write to the file %@"],
        "intent.fs.get": ["zh": "读取文件 %@", "en": "Read the file %@"],
        "intent.fs.ls": ["zh": "看看 %@ 里有什么", "en": "See what's inside %@"],
        "intent.screen.shot": ["zh": "看一眼这台 Mac 的屏幕", "en": "Take a look at this Mac's screen"],
        "intent.screen.selfshot": ["zh": "看一眼 MacHands 自己的界面", "en": "Look at MacHands' own window"],
        "intent.screen.window": ["zh": "看一眼 %@ 的窗口", "en": "Look at the %@ window"],
        "intent.screen.frontWindow": ["zh": "看一眼最前面那个窗口", "en": "Look at the frontmost window"],
        "intent.screen.record": ["zh": "把屏幕录一小段", "en": "Record a short clip of the screen"],
        "intent.clip.get": ["zh": "读剪贴板", "en": "Read the clipboard"],
        "intent.clip.set": ["zh": "往剪贴板里放东西", "en": "Put something on the clipboard"],
        "intent.open.url": ["zh": "打开网址 %@", "en": "Open %@ in the browser"],
        "intent.open.file": ["zh": "打开 %@", "en": "Open %@"],
        "intent.input.where": ["zh": "看鼠标现在在哪儿", "en": "Check where the pointer is"],
        "intent.input.move": ["zh": "移动鼠标", "en": "Move the pointer"],
        "intent.input.click": ["zh": "点一下鼠标", "en": "Click the mouse"],
        "intent.input.drag": ["zh": "拖动鼠标", "en": "Drag with the mouse"],
        "intent.input.scroll": ["zh": "滚动页面", "en": "Scroll"],
        "intent.input.key": ["zh": "按下 %@", "en": "Press %@"],
        "intent.input.type": ["zh": "用键盘打字", "en": "Type on the keyboard"],
        "intent.job.status": ["zh": "看后台作业的状态", "en": "Check on a background job"],
        "intent.job.tail": ["zh": "看后台作业的输出", "en": "Read a background job's output"],
        "intent.job.kill": ["zh": "停掉一个后台作业", "en": "Stop a background job"],
        "intent.job.list": ["zh": "列出所有后台作业", "en": "List the background jobs"],
        "intent.session.open": ["zh": "开一个终端会话", "en": "Open a terminal session"],
        "intent.session.write": ["zh": "往终端会话里输入", "en": "Type into the terminal session"],
        "intent.session.read": ["zh": "读终端会话的输出", "en": "Read the terminal session's output"],
        "intent.session.close": ["zh": "关掉终端会话", "en": "Close the terminal session"],
        "intent.mcp.servers": ["zh": "看这台 Mac 上配了哪些 MCP 服务", "en": "See which MCP servers this Mac has"],
        "intent.mcp.open": ["zh": "连上 MCP 服务 %@", "en": "Connect to the MCP server %@"],
        "intent.mcp.list": ["zh": "看 MCP 服务提供哪些工具", "en": "List the MCP server's tools"],
        "intent.mcp.call": ["zh": "调用 MCP 工具 %@", "en": "Call the MCP tool %@"],
        "intent.mcp.close": ["zh": "断开 MCP 服务", "en": "Disconnect from the MCP server"],
        "intent.sys.info": ["zh": "看这台 Mac 的基本情况", "en": "Check this Mac's basics"],
        "intent.sys.perms": ["zh": "看 MacHands 拿到了哪些系统权限", "en": "Check which permissions MacHands has"],
        "intent.sys.which": ["zh": "看这台 Mac 装了哪些开发工具", "en": "Check which developer tools are installed"],
        "intent.notify": ["zh": "给你发一条通知", "en": "Send you a notification"],
        "intent.power.assert": ["zh": "让这台 Mac 先别睡", "en": "Keep this Mac awake"],
        "intent.power.release": ["zh": "让这台 Mac 可以睡了", "en": "Let this Mac sleep again"],
        "intent.policy": ["zh": "问一下当前的审批规则", "en": "Ask about the current approval rules"],
        "intent.verify": ["zh": "自检一遍能不能干活", "en": "Run the self-check"],
        "intent.app.relaunch": ["zh": "重开 MacHands", "en": "Restart MacHands"],
        "intent.app.update": ["zh": "把 MacHands 更新到新版本", "en": "Update MacHands to a newer version"],
        "intent.app.doctor": ["zh": "体检 MacHands 自己的安装状态", "en": "Check MacHands' own installation"],
        "intent.app.showWindow": ["zh": "打开 MacHands 的窗口", "en": "Open the MacHands window"],
        "intent.generic": ["zh": "执行 %@", "en": "Run %@"]
    ]
}

func L(_ key: String) -> String {
    return Strings.shared.s(key)
}

/// 故意与 `L` 不同名:一个变参重载会让每个调用点都歧义。
func Lf(_ key: String, _ args: CVarArg...) -> String {
    return Strings.shared.f(key, args)
}
