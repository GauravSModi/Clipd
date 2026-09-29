import AppKit

/// The app's main menu, which exists only so ⌘-shortcuts work in text fields.
///
/// Clipd is an `.accessory` app, so it never shows a menu bar. But ⌘A/⌘C/⌘V/⌘X/⌘Z
/// are not built into text fields: they are Edit-menu key equivalents, and AppKit
/// looks them up in `NSApp.mainMenu` whether or not a menu bar is visible. With no
/// main menu those keys reached nothing, so the Settings entries field and the
/// panel's search box both ignored them.
///
/// Every item has a nil target, so AppKit sends its action to whatever has keyboard
/// focus (the first responder) — the text field being edited.
enum ClipdMainMenu {
    static func make() -> NSMenu {
        let mainMenu = NSMenu()

        // AppKit always treats the first item as the application menu. It is never
        // shown here, so it stays an empty placeholder.
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = NSMenu()
        mainMenu.addItem(appMenuItem)

        let editMenu = NSMenu(title: "Edit")
        // undo:/redo: have no Swift-visible declaration to #selector (the field
        // editor's undo manager answers them), hence the string selectors.
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")),
                                    keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")

        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        return mainMenu
    }
}
