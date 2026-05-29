import AppKit
import SwiftUI
import ServiceManagement
import KeyboardShortcuts
import ClipdKit

/// Owns the app's lifetime: builds the core pipeline, drives pasteboard polling,
/// and shows the status item + search panel. Deliberately thin — all history
/// logic lives in ClipdKit/the C++ core.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var launchAtLoginItem: NSMenuItem!
    private var panel: NSPanel!
    private var pollTimer: Timer?
    private var suppressAutoDismiss = false
    /// Local monitor for ↑/↓ list navigation while the query field stays focused.
    private var keyMonitor: Any?

    // Held for the process lifetime.
    private var clipboard: Clipboard!
    private var monitor: PasteboardMonitor!
    private var controller: HistoryController!
    private var model: SearchModel!

    private let maxEntries = 10_000
    private let compactThresholdBytes: UInt64 = 4 * 1024 * 1024  // 4 MB

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let clipboard = makeClipboard() else {
            presentFatal("Couldn’t open the clipboard-history log in Application Support.")
            return
        }
        self.clipboard = clipboard
        monitor = PasteboardMonitor(pasteboard: SystemPasteboard())
        controller = HistoryController(clipboard: clipboard,
                                       monitor: monitor,
                                       compactThresholdBytes: compactThresholdBytes)
        model = SearchModel(controller: controller)
        model.onChoose = { [weak self] in self?.hidePanel() }

        startPolling()
        setupStatusItem()
        setupPanel()

        KeyboardShortcuts.onKeyUp(for: .toggleClipd) { [weak self] in
            self?.togglePanel()
        }

        promptLaunchAtLoginIfFirstRun()
    }

    // MARK: - Pipeline

    private func makeClipboard() -> Clipboard? {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(for: .applicationSupportDirectory,
                                           in: .userDomainMask,
                                           appropriateFor: nil,
                                           create: true) else { return nil }
        let dir = appSupport.appendingPathComponent("Clipd", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let logPath = dir.appendingPathComponent("clipd.log").path
        return try? Clipboard(logPath: logPath,
                              maxEntries: maxEntries,
                              compactThresholdBytes: compactThresholdBytes)
    }

    private func startPolling() {
        // Checking changeCount is ~free; the timer fires on the main run loop and
        // only reads contents when the counter actually moved (see PasteboardMonitor).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.monitor.poll()
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                   accessibilityDescription: "Clipd")
            button.action = #selector(statusItemClicked)
            button.target = self
            // Need right-clicks too, so we can show the menu instead of the panel.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        statusMenu = NSMenu()
        statusMenu.delegate = self
        statusMenu.addItem(withTitle: "Search Clipd  (⌘⇧V)",
                           action: #selector(togglePanel), keyEquivalent: "")
        statusMenu.addItem(.separator())
        launchAtLoginItem = statusMenu.addItem(withTitle: "Launch at Login",
                                               action: #selector(toggleLaunchAtLogin),
                                               keyEquivalent: "")
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Quit Clipd",
                           action: #selector(quit), keyEquivalent: "q")
        statusMenu.items.forEach { $0.target = self }
    }

    // MARK: - Launch at login

    /// Refresh the checkbox from the real service state each time the menu opens,
    /// so it never drifts from what the system actually has registered.
    func menuNeedsUpdate(_ menu: NSMenu) {
        launchAtLoginItem.state = isLaunchAtLoginEnabled ? .on : .off
    }

    private var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Clipd: launch-at-login toggle failed: \(error)")
        }
        // Re-sync from the real status, so a failed register doesn't desync the UI.
        launchAtLoginItem.state = isLaunchAtLoginEnabled ? .on : .off
    }

    /// One-time onboarding: offer to register as a login item on first launch.
    private func promptLaunchAtLoginIfFirstRun() {
        let key = "didPromptLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Launch Clipd at login?"
            alert.informativeText = "Clipd can start automatically when you log in, so your clipboard history is always being captured."
            alert.addButton(withTitle: "Launch at Login")
            alert.addButton(withTitle: "Not Now")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do { try SMAppService.mainApp.register() }
            catch { NSLog("Clipd: launch-at-login registration failed: \(error)") }
        }
    }

    /// Left-click toggles the search panel; right-click (or control-click) opens
    /// the menu. We attach the menu only for the duration of the click so the
    /// button keeps firing its action on a plain left-click.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRightClick {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePanel()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Search panel

    private func setupPanel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
                            styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered,
                            defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: SearchView(model: model))
        self.panel = panel
    }

    @objc private func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    private func showPanel() {
        model.reset()
        panel.center()
        // Becoming key during activation must not be misread as a focus-loss
        // dismissal; suppress auto-dismiss until the panel has settled as key.
        suppressAutoDismiss = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        DispatchQueue.main.async { [weak self] in self?.suppressAutoDismiss = false }
    }

    private func hidePanel() {
        removeKeyMonitor()
        panel.orderOut(nil)
        // Relinquish focus so the user's previous app gets the paste.
        NSApp.hide(nil)
    }

    /// Arrow ↑/↓ drive list selection while the SwiftUI TextField keeps focus for
    /// typing (a focused single-line field otherwise swallows the arrows). ⌘1–9,
    /// Enter, and the digit keys are left for SwiftUI to handle, so we only consume
    /// the plain arrows. Run-the-app verified.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible,
                  !event.modifierFlags.contains(.command) else { return event }
            switch event.keyCode {
            case 126: self.model.moveSelection(by: -1); return nil   // up
            case 125: self.model.moveSelection(by: 1);  return nil   // down
            default:  return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Auto-dismiss when the user interacts with something behind the panel
    /// (clicks another app, another window, or the desktop). Unlike hidePanel(),
    /// this does NOT call NSApp.hide: focus has already moved to whatever was
    /// clicked, and forcing a hide would yank it away.
    func windowDidResignKey(_ notification: Notification) {
        guard !suppressAutoDismiss, panel.isVisible else { return }
        removeKeyMonitor()
        panel.orderOut(nil)
    }

    // MARK: - Errors

    private func presentFatal(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Clipd can’t start"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }
}
