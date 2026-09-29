import AppKit

// Menu-bar agent entry point. .accessory = no Dock icon and no visible menu bar;
// the UI is the status item + the floating search panel, both run by AppDelegate.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
// Never shown, but it's where AppKit looks up ⌘A/⌘C/⌘V/⌘X/⌘Z — without it, text
// fields ignore those keys. See ClipdMainMenu.
app.mainMenu = ClipdMainMenu.make()
app.run()
