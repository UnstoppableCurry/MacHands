import AppKit
import CoreGraphics
import MacHandsCore

/// 把 **MacHands 自己的窗口**画成 PNG,不需要「屏幕录制」授权。
///
/// 为什么需要它:授权掉了、或者用户还没勾的时候,谁也截不了图,界面就没法验收。
///
/// **两条路,优先走第一条:**
///
/// 1. `CGWindowListCreateImage(.optionIncludingWindow)` —— 问窗口服务器要**已经合成好**
///    的那一张图。TCC 拦的是"别的 App 的窗口";自己的窗口一直拿得到,所以不需要授权。
///    拿到的是屏幕上真正显示的东西:文字、毛玻璃、圆角、阴影全对。
///
/// 2. `cacheDisplay` 兜底 —— 让视图自己往一张离屏位图里重画一遍。
///    真机实测(0.3.0,mini)证明这条路**基本不能看**:460×677 的主窗口只画出了按钮、
///    单选圆点、开关和几个彩色标签,**整窗的 NSTextField 文字一个都没有**,本该是深色的
///    背景也画成了白的。这些内容依赖窗口级的合成与图层后备存储,离屏上下文里没有。
///    所以它只在第一条路返回 nil 时才用,而且每张图都带 `method` 字段 ——
///    看到 `cache` 就知道图为什么不对,不用再猜一遍。
///
/// 两条路都只拍自己的窗口:拍不到别的 App、菜单栏和桌面。
enum SelfShot {

    /// 主窗口靠这个 identifier 认。审批卡是 NSPanel,靠类型认,不必打标。
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("machands.main")

    /// 这张图是怎么来的。图不对时先看它。
    enum Method: String {
        /// 窗口服务器合成好的真图。正常情况都该是它。
        case window
        /// 视图自绘的兜底图。文字多半是缺的。
        case cache
    }

    struct Shot {
        let title: String
        let data: Data
        let width: Int
        let height: Int
        let method: Method

        /// 响应里 `windows[]` 的一项。
        var json: JSONValue {
            return .object(["title": .string(title),
                            "w": .int(width),
                            "h": .int(height),
                            "bytes": .int(data.count),
                            "method": .string(method.rawValue)])
        }
    }

    enum Which: String {
        case main
        case approval
        case all

        static func parse(_ raw: String?) -> Which {
            guard let raw = raw?.lowercased(), let value = Which(rawValue: raw) else { return .main }
            return value
        }
    }

    /// 主线程上取图。调用方在别的队列上,所以这里自己 hop 过去并等。
    static func capture(which: Which, scale: Double, format: String, quality: Double) -> [Shot] {
        var shots: [Shot] = []
        let work = { shots = SelfShot.captureOnMain(which: which, scale: scale,
                                                    format: format, quality: quality) }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        return shots
    }

    /// 目标窗口一个都没有时,给一句能照做的话。
    static func complaint(for which: Which) -> String {
        switch which {
        case .main:     return L("selfshot.noMain")
        case .approval: return L("selfshot.noApproval")
        case .all:      return L("selfshot.noWindows")
        }
    }

    // MARK: - private

    private static func captureOnMain(which: Which, scale: Double,
                                      format: String, quality: Double) -> [Shot] {
        var out: [Shot] = []
        for window in matchingWindows(which) {
            let name = title(of: window)

            // 第一条路:窗口服务器合成好的真图。
            if let rep = windowServerRep(window),
               let encoded = encode(rep, scale: scale, format: format, quality: quality) {
                out.append(Shot(title: name, data: encoded.0,
                                width: encoded.1, height: encoded.2, method: .window))
                continue
            }

            // 第二条路:自绘兜底。写一行日志 —— 这张图多半缺字,别让人对着它 debug。
            Log.shared.write("selfshot: window server gave nothing for \(name); "
                             + "falling back to cacheDisplay (text will likely be missing)")
            guard let view = window.contentView else { continue }
            let bounds = view.bounds
            guard bounds.width >= 1, bounds.height >= 1 else { continue }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
            view.cacheDisplay(in: bounds, to: rep)
            guard let encoded = encode(rep, scale: scale, format: format, quality: quality) else { continue }
            out.append(Shot(title: name, data: encoded.0,
                            width: encoded.1, height: encoded.2, method: .cache))
        }
        return out
    }

    /// 向窗口服务器要这一个窗口的合成图。
    ///
    /// 窗口必须真的在屏幕上:最小化、还没上屏、窗口号无效时都拿不到内容,返回 nil,
    /// 由调用方退回兜底。
    ///
    /// `.boundsIgnoreFraming` 去掉窗口外的阴影留白,拍出来就是窗口本身;
    /// `.bestResolution` 在 Retina 上给全分辨率像素,而不是逻辑点。
    private static func windowServerRep(_ window: NSWindow) -> NSBitmapImageRep? {
        guard window.isVisible, !window.isMiniaturized else { return nil }
        let number = window.windowNumber
        guard number > 0 else { return nil }
        guard let image = CGWindowListCreateImage(.null,
                                                  .optionIncludingWindow,
                                                  CGWindowID(number),
                                                  [.boundsIgnoreFraming, .bestResolution]) else {
            return nil
        }
        // 0×0 或 1 像素的结果等于没拍到。当失败处理,别把空图当成功交出去。
        guard image.width > 1, image.height > 1 else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    private static func matchingWindows(_ which: Which) -> [NSWindow] {
        let visible = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        switch which {
        case .main:
            // 先按 identifier 认;万一没打上标,退回到"第一个不是面板的可见窗口"。
            if let tagged = visible.first(where: { $0.identifier == mainWindowIdentifier }) {
                return [tagged]
            }
            return visible.filter { !($0 is NSPanel) }.prefix(1).map { $0 }
        case .approval:
            return visible.filter { $0 is NSPanel }
        case .all:
            return visible
        }
    }

    private static func title(of window: NSWindow) -> String {
        if window.identifier == mainWindowIdentifier { return "main" }
        if window is NSPanel { return "approval" }
        let raw = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "window" : raw
    }

    /// 缩放 + 编码。scale ≥ 1 时不重采样,直接编码原图。
    private static func encode(_ rep: NSBitmapImageRep, scale: Double,
                               format: String, quality: Double) -> (Data, Int, Int)? {
        let wantsResize = scale < 0.999
        let source: NSBitmapImageRep
        if wantsResize {
            let width = max(1, Int(Double(rep.pixelsWide) * scale))
            let height = max(1, Int(Double(rep.pixelsHigh) * scale))
            guard let target = NSBitmapImageRep(bitmapDataPlanes: nil,
                                                pixelsWide: width,
                                                pixelsHigh: height,
                                                bitsPerSample: 8,
                                                samplesPerPixel: 4,
                                                hasAlpha: true,
                                                isPlanar: false,
                                                colorSpaceName: NSColorSpaceName.deviceRGB,
                                                bytesPerRow: 0,
                                                bitsPerPixel: 0) else { return nil }
            target.size = NSSize(width: width, height: height)
            guard let context = NSGraphicsContext(bitmapImageRep: target) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            _ = rep.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                         from: .zero, operation: .copy, fraction: 1.0,
                         respectFlipped: false, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            source = target
        } else {
            source = rep
        }

        let data: Data?
        if format == "jpg" {
            data = source.representation(using: .jpeg, properties: [.compressionFactor: quality])
        } else {
            data = source.representation(using: .png, properties: [:])
        }
        guard let out = data else { return nil }
        return (out, source.pixelsWide, source.pixelsHigh)
    }
}
