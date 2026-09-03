import AppKit

// 没有 @main、没有 storyboard:这个文件**就是**入口,启动路径一眼看得完。
// 而且辅助型 App 必须在第一次跑 run loop 之前把 activationPolicy 设成
// .accessory,否则它会闪一下 Dock 图标、抢一次焦点 —— 之后再也不用那个图标。
let application = NSApplication.shared
_ = application.setActivationPolicy(.accessory)

let delegate = AppDelegate()
application.delegate = delegate

application.run()
