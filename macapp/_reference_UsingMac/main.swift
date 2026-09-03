import AppKit

// No @main / no storyboard: this file *is* the entry point, which keeps the
// launch path readable — and an accessory app has to set its activation policy
// before the first run loop turn, or it briefly steals focus and shows a Dock
// icon it will never use again.

let application = NSApplication.shared
_ = application.setActivationPolicy(.accessory)

let delegate = AppDelegate()
application.delegate = delegate

application.run()
