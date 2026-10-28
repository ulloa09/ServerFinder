import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// A menu bar app: no Dock icon, no app switcher entry.
app.setActivationPolicy(.accessory)
app.run()
