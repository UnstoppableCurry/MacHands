import AppKit
import CoreGraphics
import MacHandsCore

/// SPEC §11 `input.*`:用 CGEvent 发键鼠事件。需要"辅助功能"权限;没授权时
/// 明确报错并指到设置面板,不假装点了。
/// 坐标全部是**顶左原点**(与 `screen.shot` 的像素坐标一致);`NSEvent.mouseLocation`
/// 是底左原点,进出都在这里换算一次。
enum InputController {

    struct Failure: Error {
        let code: RPCErrorCode
        let message: String
    }

    private static func requireAccessibility() throws {
        guard Permissions.accessibility(prompt: false) else {
            throw Failure(code: .eio, message: L("perm.ax.rpc"))
        }
    }

    private static var mainHeight: CGFloat {
        return CGDisplayBounds(CGMainDisplayID()).height
    }

    static func currentLocation() -> CGPoint {
        var point = CGPoint.zero
        let read = { point = NSEvent.mouseLocation }
        if Thread.isMainThread { read() } else { DispatchQueue.main.sync(execute: read) }
        return CGPoint(x: point.x, y: mainHeight - point.y)
    }

    static func move(to point: CGPoint) throws {
        try requireAccessibility()
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                  mouseCursorPosition: point, mouseButton: .left) else {
            throw Failure(code: .eio, message: "cannot create mouse event")
        }
        event.post(tap: .cghidEventTap)
    }

    static func click(at point: CGPoint, button: String, count: Int) throws {
        try requireAccessibility()
        let right = button.lowercased() == "right"
        let downType: CGEventType = right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = right ? .rightMouseUp : .leftMouseUp
        let cgButton: CGMouseButton = right ? .right : .left
        try move(to: point)
        usleep(30_000)
        for index in 1...max(1, min(count, 3)) {
            guard let down = CGEvent(mouseEventSource: nil, mouseType: downType,
                                     mouseCursorPosition: point, mouseButton: cgButton),
                  let up = CGEvent(mouseEventSource: nil, mouseType: upType,
                                   mouseCursorPosition: point, mouseButton: cgButton) else {
                throw Failure(code: .eio, message: "cannot create mouse event")
            }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            down.post(tap: .cghidEventTap)
            usleep(40_000)
            up.post(tap: .cghidEventTap)
            usleep(70_000)
        }
    }

    static func drag(from start: CGPoint, to end: CGPoint, milliseconds: Int) throws {
        try requireAccessibility()
        try move(to: start)
        usleep(40_000)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                 mouseCursorPosition: start, mouseButton: .left) else {
            throw Failure(code: .eio, message: "cannot create mouse event")
        }
        down.post(tap: .cghidEventTap)
        let steps = 20
        let pause = useconds_t(max(1, milliseconds) * 1000 / steps)
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            if let dragged = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                                     mouseCursorPosition: point, mouseButton: .left) {
                dragged.post(tap: .cghidEventTap)
            }
            usleep(pause)
        }
        if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                            mouseCursorPosition: end, mouseButton: .left) {
            up.post(tap: .cghidEventTap)
        }
    }

    static func scroll(at point: CGPoint, dx: Int, dy: Int) throws {
        try move(to: point)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else {
            throw Failure(code: .eio, message: "cannot create scroll event")
        }
        event.post(tap: .cghidEventTap)
    }

    /// Unicode 直接注入,不依赖键盘布局;一个字符一对事件,兼容性最好。
    static func type(_ text: String) throws {
        try requireAccessibility()
        for scalar in text.unicodeScalars {
            var units = Array(String(scalar).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw Failure(code: .eio, message: "cannot create key event")
            }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.post(tap: .cghidEventTap)
            usleep(8_000)
            up.post(tap: .cghidEventTap)
            usleep(8_000)
        }
    }

    static func key(_ name: String, modifiers: [String]) throws {
        try requireAccessibility()
        guard let code = keyCode(for: name) else {
            throw Failure(code: .badParams, message: "unknown key: \(name)")
        }
        var flags = CGEventFlags()
        for modifier in modifiers {
            switch modifier.lowercased() {
            case "cmd", "command", "meta": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn", "function": flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw Failure(code: .eio, message: "cannot create key event")
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(30_000)
        up.post(tap: .cghidEventTap)
    }

    /// ANSI 美式布局的虚拟键码。字母数字按物理位置;不在表里的字符用 `input.type`。
    static func keyCode(for rawName: String) -> CGKeyCode? {
        let name = rawName.lowercased()
        let table: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
            "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
            "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
            ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, " ": 49,
            "`": 50, "delete": 51, "backspace": 51, "esc": 53, "escape": 53,
            "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103, "f13": 105,
            "f14": 107, "f10": 109, "f12": 111, "f15": 113, "home": 115, "pageup": 116,
            "forwarddelete": 117, "f4": 118, "end": 119, "f2": 120, "pagedown": 121, "f1": 122,
            "left": 123, "right": 124, "down": 125, "up": 126
        ]
        return table[name]
    }
}
