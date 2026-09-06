import AppKit
import MacHandsCore

/// `Intent` 的界面侧翻译。
///
/// Core 只产出 key + 参数(它 import 不到文案表,也不该 import)。这里把它们变成
/// 用户看得懂的一句话。分两层的好处:`swift test` 能在 Core 里断言"意图判对了",
/// 不必启动 AppKit;而中文/英文/日文/韩文四种说法只在这一处展开。
enum IntentText {

    /// 大标题:agent 传了 `why` 就照抄它的话,否则查表。
    static func headline(_ intent: Intent) -> String {
        if let literal = intent.literalHeadline { return literal }
        if intent.headlineArgs.isEmpty { return L(intent.headlineKey) }
        // 显式转成 [CVarArg]:`f` 收的是 [CVarArg],别指望隐式集合上转。
        return Strings.shared.f(intent.headlineKey, intent.headlineArgs as [CVarArg])
    }

    /// 徽标下面那个短名:"终端""文件""屏幕"…
    static func areaName(_ area: Intent.Area) -> String {
        return L(area.localizationKey)
    }

    /// 审计日志与菜单栏"最近一次命令"用的一行。
    /// 不再直接甩 shell —— 那行字在菜单里被截到 28 个字符,截出来的半截命令
    /// 既不能读也不能用。
    static func summary(_ intent: Intent) -> String {
        let head = headline(intent)
        if intent.scope.isEmpty { return head }
        return head + " · " + intent.scope
    }
}

/// 卡片要显示的意图,先寄存在这里。
///
/// 为什么不直接给 `ApprovalRequest` 加字段:审批卡那个文件正在被另一条线整文件重写,
/// 两边同时改同一个 struct 必冲突。寄存柜让执行器与卡片解耦 —— 执行器放,卡片取,
/// 合并的时候把它换成一个真字段是一行的事。
///
/// 生命周期是配对的:`put` 之后一定有一次 `take`(执行器在卡片回调里取),
/// 所以不会长。仍然设了上限,断线时的残留不至于堆着。
final class IntentBox {

    static let shared = IntentBox()

    private let lock = NSLock()
    private var storage: [String: Intent] = [:]
    private var order: [String] = []
    private let limit = 64

    private init() {}

    func put(_ intent: Intent, for requestId: String) {
        lock.lock(); defer { lock.unlock() }
        if storage[requestId] == nil { order.append(requestId) }
        storage[requestId] = intent
        while order.count > limit {
            let oldest = order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    /// 取走。取不到返回 nil —— 调用方自己兜底,别在这里编一个假的出来。
    @discardableResult
    func take(_ requestId: String) -> Intent? {
        lock.lock(); defer { lock.unlock() }
        order.removeAll { $0 == requestId }
        return storage.removeValue(forKey: requestId)
    }

    /// 只看不取,卡片渲染时用。
    func peek(_ requestId: String) -> Intent? {
        lock.lock(); defer { lock.unlock() }
        return storage[requestId]
    }
}
