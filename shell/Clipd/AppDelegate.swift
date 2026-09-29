import AppKit
import Combine
import SwiftUI
import ApplicationServices
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
    private var pauseCaptureItem: NSMenuItem!
    /// Held so menuNeedsUpdate can restate the current hotkey in its title.
    private var searchItem: NSMenuItem!
    private var panel: NSPanel!
    /// Built lazily on first "Settings…" and reused (isReleasedWhenClosed = false),
    /// so closing it keeps the recorded shortcut's view state rather than tearing
    /// the hosting view down.
    private var settingsWindow: NSWindow?
    private var pollTimer: Timer?
    private var expiryTimer: Timer?
    private var suppressAutoDismiss = false
    /// Local monitor for ↑/↓ list navigation while the query field stays focused.
    private var keyMonitor: Any?
    /// The app that was frontmost when the panel was summoned — paste-back targets
    /// it. Captured in showPanel() before we steal focus.
    private var previousApp: NSRunningApplication?

    // Held for the process lifetime.
    private var clipboard: Clipboard!
    private var monitor: PasteboardMonitor!
    private var controller: HistoryController!
    private var model: SearchModel!

    /// Persisted settings (caps, first-run flags, capture policy). ClipdSettings
    /// owns the default table the caps used to be hardcoded from. The caps seed
    /// the core at launch and are then applied live by observeHistoryLimits();
    /// the capture policy is read fresh on every poll via a provider closure.
    private let settings = ClipdSettings.shared
    /// Keeps the status-item icon in sync with pause state changed from the
    /// Settings window, not just from the status menu. Held for the process
    /// lifetime.
    private var settingsSubscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let clipboard = makeClipboard() else {
            presentFatal("Couldn’t open the clipboard-history log in Application Support.")
            return
        }
        self.clipboard = clipboard
        monitor = PasteboardMonitor(
            pasteboard: SystemPasteboard(),
            policy: { [settings] in settings.capturePolicy },
            excludedApps: { [settings] in settings.excludedSourceAppIDs },
            frontmostBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier })
        controller = HistoryController(clipboard: clipboard,
                                       monitor: monitor,
                                       compactThresholdBytes: settings.compactThresholdBytes)
        model = SearchModel(controller: controller)
        model.onActivate = { [weak self] match, requested in
            self?.activate(match, requested: requested)
        }
        model.onConfirmDelete = { [weak self] match in
            self?.confirmDeletePinned(match)
        }

        observeHistoryLimits()
        observeRetention()
        runExpirySweep(retentionDays: settings.retentionDays)  // catch up at launch
        startExpirySweeps()
        startPolling()
        setupStatusItem()
        setupPanel()

        KeyboardShortcuts.onKeyUp(for: .toggleClipd) { [weak self] in
            self?.togglePanel()
        }

        promptLaunchAtLoginIfFirstRun()
        requestAccessibilityOnFirstRun()
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
                              maxEntries: settings.maxEntries,
                              compactThresholdBytes: settings.compactThresholdBytes,
                              maxBytes: settings.maxBytes,
                              maxBlobBytes: settings.maxBlobBytes)
    }

    /// Apply a cap change to the running core, so retuning a limit never needs a
    /// restart. This is the ONLY path that calls setLimits: the confirmation
    /// writes to ClipdSettings, and these sinks apply what was written.
    ///
    /// Two Combine hazards, both handled here:
    ///   * @Published publishes from willSet, so the property being changed still
    ///     reads as its PRE-change value inside the sink. Each sink therefore uses
    ///     its own emitted value for the property that moved and reads the OTHER
    ///     one off `settings` (which is not mid-assignment). Re-reading the
    ///     changing property is the bug that bit the Stage 2 status icon.
    ///   * A @Published sink emits the current value on subscribe; dropFirst()
    ///     avoids a redundant setLimits at launch with the very values
    ///     clipd_create was just handed.
    private func observeHistoryLimits() {
        settings.$maxEntries
            .dropFirst()
            .sink { [weak self] newMaxEntries in
                guard let self else { return }
                try? self.controller.setLimits(maxEntries: newMaxEntries,
                                               maxBytes: self.settings.maxBytes)
            }
            .store(in: &settingsSubscriptions)

        settings.$maxBytes
            .dropFirst()
            .sink { [weak self] newMaxBytes in
                guard let self else { return }
                try? self.controller.setLimits(maxEntries: self.settings.maxEntries,
                                               maxBytes: newMaxBytes)
            }
            .store(in: &settingsSubscriptions)
    }

    /// Confirm a cap change that would evict, then persist it (the observers
    /// above do the applying). Returns whether it was applied, so the History tab
    /// can snap its controls back on a cancel.
    ///
    /// Only a reduction that would ACTUALLY evict is confirmed — raising a cap, or
    /// lowering one that is still above the live set, applies silently.
    private func applyHistoryLimits(maxEntries: Int, maxBytes: UInt64) -> Bool {
        // Effectively unreachable: clipd_stats only fails on a NULL handle, and a
        // failed core aborts launch. If it ever does fail we can't tell whether
        // this evicts, and evicting without asking is the worse outcome.
        guard let stats = try? controller.stats() else {
            NSLog("Clipd: couldn't read stats; leaving the history limits unchanged")
            return false
        }

        let reduction = clipdLimitReduction(liveCount: stats.entryCount,
                                            liveBytes: stats.storeBytes,
                                            maxEntries: maxEntries,
                                            maxBytes: maxBytes)
        if reduction != .none {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = reduction.messageText
            alert.informativeText = reduction.informativeText
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Reduce Limit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }

        // Guarded: @Published fires on any assignment, including a same-value one,
        // which would re-run the observer and rewrite UserDefaults for nothing.
        if settings.maxEntries != maxEntries { settings.maxEntries = maxEntries }
        if settings.maxBytes != maxBytes { settings.maxBytes = maxBytes }
        return true
    }

    // MARK: - Retention

    /// Age expiry is day-granularity, so exactness is pointless: a sleeping Mac
    /// will not fire this on time and sweeping late is fine. An hour bounds how
    /// late without any wake-scheduling machinery — there is deliberately none.
    private static let expirySweepInterval: TimeInterval = 3600

    private func startExpirySweeps() {
        expiryTimer = Timer.scheduledTimer(withTimeInterval: Self.expirySweepInterval,
                                           repeats: true) { [weak self] _ in
            guard let self else { return }
            self.runExpirySweep(retentionDays: self.settings.retentionDays)
        }
    }

    /// Sweep as soon as the period changes, so a shortened retention takes effect
    /// without waiting for the next tick or a restart.
    ///
    /// Uses the value the sink hands us rather than re-reading
    /// `settings.retentionDays`: @Published publishes from willSet, so the
    /// property still reads as its PRE-change value inside the sink (the bug that
    /// bit Stages 2 and 4). dropFirst() skips the emit-on-subscribe, because the
    /// launch sweep above has already run.
    private func observeRetention() {
        settings.$retentionDays
            .dropFirst()
            .sink { [weak self] days in self?.runExpirySweep(retentionDays: days) }
            .store(in: &settingsSubscriptions)
    }

    /// One sweep. Best-effort: a failed sweep drops entries later rather than
    /// taking the app down, exactly like a dropped capture.
    private func runExpirySweep(retentionDays: Int) {
        guard retentionDays > 0 else { return }  // Never: don't even cross the boundary
        do {
            let removed = try controller.sweepExpired(retentionDays: retentionDays)
            if removed > 0 {
                NSLog("Clipd: retention sweep removed \(removed) entries")
            }
        } catch {
            NSLog("Clipd: retention sweep failed: \(error)")
        }
    }

    /// Confirm a retention change that would START deleting entries, then persist
    /// it and sweep at once. Returns whether it was applied, so the History tab
    /// can snap its picker back on a cancel.
    ///
    /// Only a shortening (including Never → a period) is confirmed; lengthening
    /// the period or choosing Never deletes nothing and applies silently — the
    /// same rule the cap confirmation uses.
    private func applyRetention(days: Int) -> Bool {
        let proposed = ClipdRetention.sanitize(days)
        let change = clipdRetentionChange(currentDays: settings.retentionDays,
                                          proposedDays: proposed)
        if change != .none {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = change.messageText
            alert.informativeText = change.informativeText
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete Older Entries")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }

        // Guarded: @Published fires on any assignment, and a same-value write
        // would re-run the observer and sweep for nothing.
        if settings.retentionDays != proposed { settings.retentionDays = proposed }
        return true
    }

    /// Confirm when clear-on-quit is switched ON. There is deliberately no
    /// confirmation at quit time — the user opted in here, and a dialog on every
    /// quit is the kind people learn to click through without reading.
    private func applyClearOnQuit(_ enabled: Bool) -> Bool {
        if enabled {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = ClipdClearOnQuit.messageText
            alert.informativeText = ClipdClearOnQuit.informativeText
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Clear on Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        if settings.clearsHistoryOnQuit != enabled {
            settings.clearsHistoryOnQuit = enabled
        }
        return true
    }

    /// Clear history (keeping pinned entries) on a normal quit, when the user has
    /// opted in. Best-effort by nature: a force quit, a crash, or an abrupt logout
    /// never delivers this notification, so the history simply survives. Clearing
    /// also compacts, which is why a large history can make quitting take a
    /// moment — and it is removal, not secure erase.
    func applicationWillTerminate(_ notification: Notification) {
        guard settings.clearsHistoryOnQuit else { return }
        try? controller?.clear()
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
        updateStatusIcon()
        if let button = statusItem.button {
            button.action = #selector(statusItemClicked)
            button.target = self
            // Need right-clicks too, so we can show the menu instead of the panel.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // Keep the icon in sync with a pause toggle made in the Settings window,
        // not just the status menu — both surfaces must agree. Use the value the
        // sink hands us, not a re-read of settings.captureIsPaused: @Published
        // publishes from willSet, so re-reading the property from inside the sink
        // can still observe the PRE-toggle value on the very next run-loop turn —
        // that was the "icon doesn't flip until the second toggle" bug.
        settings.$captureIsPaused
            .sink { [weak self] isPaused in self?.updateStatusIcon(paused: isPaused) }
            .store(in: &settingsSubscriptions)

        statusMenu = NSMenu()
        statusMenu.delegate = self
        searchItem = statusMenu.addItem(withTitle: Self.searchItemTitle,
                                        action: #selector(togglePanel), keyEquivalent: "")
        statusMenu.addItem(.separator())
        pauseCaptureItem = statusMenu.addItem(withTitle: "Pause Capture",
                                              action: #selector(togglePauseCapture),
                                              keyEquivalent: "")
        launchAtLoginItem = statusMenu.addItem(withTitle: "Launch at Login",
                                               action: #selector(toggleLaunchAtLogin),
                                               keyEquivalent: "")
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Settings…",
                           action: #selector(showSettings), keyEquivalent: ",")
        statusMenu.addItem(withTitle: "Clear History…",
                           action: #selector(clearHistory), keyEquivalent: "")
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Quit Clipd",
                           action: #selector(quit), keyEquivalent: "q")
        statusMenu.items.forEach { $0.target = self }
    }

    /// `doc.on.clipboard` (the normal icon) while capturing, `pause.circle` while
    /// paused. There is no slashed-clipboard SF Symbol, so a distinct pause glyph
    /// reads more clearly as "paused" than the plain `clipboard` symbol did; the
    /// status MENU item's checkmark remains the unambiguous indicator either way.
    private func updateStatusIcon(paused: Bool = ClipdSettings.shared.captureIsPaused) {
        let symbolName = paused ? "pause.circle" : "doc.on.clipboard"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Clipd")
        // pause.circle reads as smaller than doc.on.clipboard at the default menu-
        // bar (.small) scale — bump it to .large so the paused state is easy to
        // spot at a glance, matching the doc.on.clipboard glyph's visual weight.
        statusItem.button?.image = paused
            ? image?.withSymbolConfiguration(.init(scale: .large))
            : image
    }

    // MARK: - Launch at login

    /// Refresh from the real state each time the menu opens: the checkbox from the
    /// login-service status (so it never drifts from what the system has
    /// registered), and the search item's label from the currently bound shortcut
    /// (so rebinding it in Settings doesn't leave a stale hint behind).
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Reconcile with the system before showing the checkbox (a change made in
        // System Settings ▸ Login Items happens behind the app's back).
        ClipdLoginItem.shared.refresh()
        launchAtLoginItem.state = ClipdLoginItem.shared.isEnabled ? .on : .off
        searchItem.title = Self.searchItemTitle
        pauseCaptureItem.state = settings.captureIsPaused ? .on : .off
    }

    /// A frequent, transient action, so it lives in the status menu (in addition
    /// to the Settings checkbox — both read/write the same ClipdSettings property).
    @objc private func togglePauseCapture() {
        settings.captureIsPaused.toggle()
    }

    /// "Search Clipd  (⌘⇧V)", or just "Search Clipd" when no shortcut is bound.
    private static var searchItemTitle: String {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .toggleClipd) else {
            return "Search Clipd"
        }
        return "Search Clipd  (\(shortcut))"
    }

    @objc private func toggleLaunchAtLogin() {
        let item = ClipdLoginItem.shared
        item.setEnabled(!item.isEnabled)
        // setEnabled already fell back to the system state if the call failed, so
        // a failed register can't leave the checkmark lying.
        launchAtLoginItem.state = item.isEnabled ? .on : .off
    }

    /// One-time onboarding: offer to register as a login item on first launch.
    private func promptLaunchAtLoginIfFirstRun() {
        guard !settings.didPromptLaunchAtLogin else { return }
        settings.didPromptLaunchAtLogin = true

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Launch Clipd at login?"
            alert.informativeText = "Clipd can start automatically when you log in, so your clipboard history is always being captured."
            alert.addButton(withTitle: "Launch at Login")
            alert.addButton(withTitle: "Not Now")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            ClipdLoginItem.shared.setEnabled(true)
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

    // MARK: - Settings

    /// Show the Settings window, building it on first use: toolbar tabs from
    /// SettingsTabViewController, one SwiftUI pane per tab (SettingsWindow.swift
    /// explains why this isn't a SwiftUI TabView).
    ///
    /// Deliberately NOT given `self` as its delegate: windowDidResignKey is the
    /// search panel's auto-dismiss hook and must stay panel-only.
    @objc private func showSettings() {
        if settingsWindow == nil {
            let tabs = SettingsTabViewController()
            tabs.addPane("General", systemImage: "gearshape", GeneralSettingsView())
            tabs.addPane("History", systemImage: "clock", HistorySettingsView(
                onCommit: { [weak self] maxEntries, maxBytes in
                    self?.applyHistoryLimits(maxEntries: maxEntries,
                                             maxBytes: maxBytes) ?? false
                },
                onCommitRetention: { [weak self] days in
                    self?.applyRetention(days: days) ?? false
                },
                onCommitClearOnQuit: { [weak self] enabled in
                    self?.applyClearOnQuit(enabled) ?? false
                }))
            tabs.addPane("Capture", systemImage: "clipboard", CaptureSettingsView())

            // No size here: the tab controller sizes the window to each pane. This
            // initializer also makes the window resizable and miniaturizable,
            // which a settings window isn't — hence the explicit style mask.
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference  // centered icon-over-label tabs
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        // An .accessory app has to activate explicitly for its window to take focus
        // (the hotkey recorder is useless without key events).
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Destructive actions (confirmed)

    /// Clear history (keeping pinned entries) after a confirmation. Lives in the
    /// status menu — a rare, global, irreversible action.
    @objc private func clearHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "This removes all unpinned entries. Pinned entries are kept."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.clearHistory()
    }

    /// Confirm before deleting a *pinned* row (unpinned deletes are instant and
    /// never reach here). Suppress the panel's focus-loss auto-dismiss while the
    /// modal alert is up so the panel survives the confirmation.
    private func confirmDeletePinned(_ match: Match) {
        suppressAutoDismiss = true
        defer { suppressAutoDismiss = false }
        let alert = NSAlert()
        alert.messageText = "Delete this pinned entry?"
        alert.informativeText = "This favorite will be permanently removed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.performDelete(match)
        panel.makeKeyAndOrderFront(nil)
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
        // Capture the app we're stealing focus from *before* activating, so
        // paste-back can hand the keystroke back to it.
        previousApp = NSWorkspace.shared.frontmostApplication
        panel.center()
        // Becoming key during activation must not be misread as a focus-loss
        // dismissal; suppress auto-dismiss until the panel has settled as key.
        suppressAutoDismiss = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        DispatchQueue.main.async { [weak self] in
            self?.suppressAutoDismiss = false
            // Now that the panel is actually key, ask the search field to take
            // focus. Doing it here (not just in the view's `.onAppear`) re-focuses
            // on every open and after the window is key, so typing filters and the
            // field behaves normally each time the panel is summoned.
            self?.model.focusNonce += 1
        }
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
            // Return / keypad-Enter: activate the highlighted row here rather
            // than via SwiftUI's `.onSubmit`, which only fires when the search
            // field is first responder. Routing it through this monitor (like
            // ↑/↓) makes Enter paste even when focus didn't take. Consuming the
            // event (return nil) also stops a duplicate `.onSubmit` firing when
            // the field *does* have focus. ⌘↵ is excluded by the guard above, so
            // it still reaches the invisible "copy" button.
            case 36, 76: self.model.chooseSelected(); return nil     // return / enter
            default:  return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: - Paste-back

    /// Resolve the requested action against the Accessibility permission (paste
    /// degrades to copy when not granted), put the entry on the pasteboard under
    /// the type its kind dictates, then either hand focus back for a manual paste
    /// (copy) or paste it in (paste).
    private func activate(_ match: Match, requested: ClipdPasteAction) {
        let action = clipdResolvePasteAction(requested: requested,
                                             accessibilityTrusted: AXIsProcessTrusted())
        switch match.kind {
        case .text:
            SystemClipboardWriter.write(match.text)
        case .image:
            guard let data = controller.readBlob(id: match.id) else {
                // Blob missing (manually deleted, etc.): dismiss without
                // overwriting the user's current pasteboard contents.
                hidePanel()
                return
            }
            SystemClipboardWriter.writeImage(data, format: clipdImageFormat(of: data))
        case .file:
            SystemClipboardWriter.writeFile(match.text)  // for File, text == path
        }
        switch action {
        case .copy:
            hidePanel()
            // The user asked to PASTE but we could only copy — that can only be
            // the missing Accessibility permission, and staying silent about it
            // is indistinguishable from "the app is broken" (the panel just
            // dismisses and nothing appears). Say so once per launch.
            if requested == .paste { warnAccessibilityMissing() }
        case .paste:
            pasteBack()
        }
    }

    /// Told the user this launch already? Paste-back is a frequent action, so a
    /// dialog on every press would be worse than the silence it replaces.
    private var didWarnAccessibility = false

    /// Explain why a requested paste only copied, and offer the fix. Deliberately
    /// NOT gated on `settings.didRequestAccessibility`: that flag gates the
    /// one-time onboarding prompt at first run, whereas this is feedback for an
    /// action the user just took and watched fail. The two must stay independent,
    /// or a user who dismissed the first-run prompt gets no explanation ever.
    ///
    /// Note the entry IS on the pasteboard, so ⌘V always works — the alert says
    /// that rather than presenting this as a total failure.
    private func warnAccessibilityMissing() {
        guard !didWarnAccessibility else { return }
        didWarnAccessibility = true

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Copied — but Clipd can’t paste for you"
        alert.informativeText = """
            Pasting directly into the app you were using needs the Accessibility \
            permission. The entry is on your clipboard, so you can press ⌘V yourself.

            If Clipd already appears checked in Accessibility, remove it with “−” \
            and add it again — a rebuilt app is treated as a different app.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Re-ask the system first: this is what re-adds Clipd to the list when the
        // grant was invalidated, so the user has a row to toggle when they arrive.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Reactivate the prior app and synthesize ⌘V once it's actually frontmost.
    /// We orderOut (not hidePanel/NSApp.hide, which would fight our activate for
    /// focus) and let the explicit activate be the single source of focus truth.
    private func pasteBack() {
        removeKeyMonitor()
        panel.orderOut(nil)
        guard let target = previousApp else { return }

        // Fire ⌘V when `target` becomes frontmost; fall back to a short delay only
        // if the activation notification never arrives. Guarded so it fires once.
        var observer: NSObjectProtocol?
        var fired = false
        let fire: () -> Void = { [weak self] in
            guard !fired else { return }
            fired = true
            if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            self?.synthesizePaste()
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier == target.processIdentifier { fire() }
        }
        target.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: fire)
    }

    private func synthesizePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09   // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// One-time prompt for the Accessibility permission paste-back needs. Gated by
    /// its own flag (independent of the launch-at-login prompt) so it also fires
    /// for installs that predate this feature; skipped if already trusted.
    private func requestAccessibilityOnFirstRun() {
        guard !settings.didRequestAccessibility else { return }
        settings.didRequestAccessibility = true
        guard !AXIsProcessTrusted() else { return }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
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
