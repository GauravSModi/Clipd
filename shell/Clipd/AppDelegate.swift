import AppKit
import SwiftUI
import KeyboardShortcuts
import ClipdKit

/// Owns the app's lifetime: builds the core pipeline, drives pasteboard polling,
/// and shows the status item + search panel. Deliberately thin — all history
/// logic lives in ClipdKit/the C++ core.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var pollTimer: Timer?

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
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                           accessibilityDescription: "Clipd")
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.target = self
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
        panel.contentView = NSHostingView(rootView: SearchView(model: model))
        self.panel = panel
    }

    @objc private func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    private func showPanel() {
        model.reset()
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func hidePanel() {
        panel.orderOut(nil)
        // Relinquish focus so the user's previous app gets the paste.
        NSApp.hide(nil)
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
