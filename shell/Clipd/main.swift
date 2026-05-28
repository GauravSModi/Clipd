import AppKit

// Menu-bar agent entry point. .accessory = no Dock icon / no menu bar app menu;
// the UI is the status item + the floating search panel, both run by AppDelegate.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
