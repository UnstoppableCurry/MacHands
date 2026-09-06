import AppKit
import ApplicationServices
import CoreGraphics
import UserNotifications
import MacHandsCore

/// SPEC §10.2:三项系统权限的查询、请求与直达设置面板。
/// 全部只读函数可从任何线程调;`request*` 会弹系统对话框,在主线程调。
enum Permissions {

    enum Pane {
        case screen
        case accessibility
        case notifications

        var settingsURL: URL? {
            switch self {
            case .screen:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            case .notifications:
                return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
            }
        }
    }

    struct Snapshot: Equatable {
        var screen: Bool
        var accessibility: Bool
        /// authorized / denied / notDetermined / unknown
        var notifications: String

        var allGranted: Bool {
            return screen && accessibility && notifications == "authorized"
        }

        var json: JSONValue {
            return .object([
                "screen": .bool(screen),
                "accessibility": .bool(accessibility),
                "notifications": .string(notifications),
                "automation": .string("onDemand")
            ])
        }
    }

    static func screenRecording() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    /// 弹一次系统的"屏幕录制"请求(用户还没决定过时才会真的弹)。
    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func accessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: NSDictionary = [key: prompt]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// 通知授权状态。`UNUserNotificationCenter` 需要 bundle id,裸二进制回 unknown。
    static func notifications(timeout: TimeInterval = 2.0) -> String {
        guard Notifier.isAvailable else { return "unknown" }
        let box = LockedBox("unknown")
        let done = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            // `.ephemeral` 是 iOS(App Clip)专用,macOS SDK 里标了 unavailable,写上去编不过。
            case .authorized, .provisional:
                box.value = "authorized"
            case .denied:
                box.value = "denied"
            case .notDetermined:
                box.value = "notDetermined"
            @unknown default:
                box.value = "unknown"
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        return box.value
    }

    static func snapshot() -> Snapshot {
        return Snapshot(screen: screenRecording(),
                        accessibility: accessibility(prompt: false),
                        notifications: notifications())
    }

    /// 授权页的「授权并验证」:把三项能弹的系统请求一次弹完(SPEC §10.2)。
    static func requestAll() {
        requestScreenRecording()
        _ = accessibility(prompt: true)
        Notifier.requestAuthorization()
    }

    static func open(_ pane: Pane) {
        guard let url = pane.settingsURL else { return }
        if !NSWorkspace.shared.open(url) {
            // 老系统认不出扩展式的 URL,退回到通用的隐私面板。
            if let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
                _ = NSWorkspace.shared.open(fallback)
            }
        }
    }
}
