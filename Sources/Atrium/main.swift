import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()      // global → strongly retained (NSApp.delegate is weak)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
