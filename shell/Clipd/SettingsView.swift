import SwiftUI
import ServiceManagement
import KeyboardShortcuts
import ClipdKit

/// The Settings window's content. Tabbed from the start so later settings land as
/// new tabs rather than a restructure; only General exists today.
///
/// The app is AppKit-bootstrapped (main.swift builds NSApplication directly), so
/// there is no SwiftUI `Settings` scene — AppDelegate hosts this in an NSWindow via
/// NSHostingView, the same way setupPanel() hosts SearchView.
struct SettingsView: View {
    /// Applies a proposed pair of history caps, confirming first if the change
    /// would evict. Returns false when the user cancels, so the History tab can
    /// snap its controls back. Owned by AppDelegate: the alert is AppKit, and the
    /// live-set stats it needs come from the controller.
    let onCommitHistoryLimits: (Int, UInt64) -> Bool
    /// Applies a proposed retention period, confirming first if it would start
    /// deleting entries, then sweeping at once. Returns false on a cancel.
    let onCommitRetention: (Int) -> Bool
    /// Applies the clear-on-quit setting, confirming when it is switched ON.
    let onCommitClearOnQuit: (Bool) -> Bool

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            HistorySettingsView(onCommit: onCommitHistoryLimits,
                                onCommitRetention: onCommitRetention,
                                onCommitClearOnQuit: onCommitClearOnQuit)
                .tabItem { Label("History", systemImage: "clock") }
            CaptureSettingsView()
                .tabItem { Label("Capture", systemImage: "clipboard") }
        }
        .frame(width: 460, height: 560)
        .padding(.top, 8)
    }
}

/// History: how much is kept. Separate from Capture on purpose — Capture decides
/// what gets recorded, History decides how much of it survives.
///
/// Both controls are bounded and offer no "unlimited" option (see
/// ClipdHistoryLimits), and both commit on a real gesture — Enter, focus loss
/// (including a click on blank space in the tab), a stepper click, a picker
/// selection. There is no Apply button and no debounce timer: a change applies
/// live, after a confirmation if it would evict. The entries field accepts only
/// digits, and refuses an out-of-range count rather than clamping it.
///
/// The two values live in local state rather than binding straight to
/// ClipdSettings, because a cancelled confirmation has to revert without ever
/// having persisted. `settings` is the source of truth after every attempt, so
/// both commit paths re-seed from it whether the user accepted or cancelled.
struct HistorySettingsView: View {
    @ObservedObject private var settings = ClipdSettings.shared
    let onCommit: (Int, UInt64) -> Bool
    let onCommitRetention: (Int) -> Bool
    let onCommitClearOnQuit: (Bool) -> Bool

    @State private var entriesText = ""
    @State private var byteBudget: UInt64 = ClipdSettings.defaultMaxBytes
    @State private var retentionDays = ClipdRetention.defaultDays
    @FocusState private var entriesFocused: Bool

    init(onCommit: @escaping (Int, UInt64) -> Bool,
         onCommitRetention: @escaping (Int) -> Bool,
         onCommitClearOnQuit: @escaping (Bool) -> Bool) {
        self.onCommit = onCommit
        self.onCommitRetention = onCommitRetention
        self.onCommitClearOnQuit = onCommitClearOnQuit
    }

    var body: some View {
        Form {
            HStack(spacing: 6) {
                Text("Keep at most")
                TextField("", text: $entriesText)
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
                    .focused($entriesFocused)
                    .onSubmit { commitEntries() }
                    // Drop anything but digits the moment it's typed or pasted.
                    // Writing the filtered text back re-fires this once, as a no-op.
                    .onChange(of: entriesText) { text in
                        let digits = ClipdHistoryLimits.digitsOnly(text)
                        if digits != text { entriesText = digits }
                    }
                Stepper("", value: entriesStepper,
                        in: ClipdHistoryLimits.minEntries...ClipdHistoryLimits.maxEntries,
                        step: 100)
                    .labelsHidden()
                Text("entries")
            }
            // The range, or — while the box holds a count that isn't in force —
            // how to apply it or what the box accepts. Keeps the field from ever
            // silently showing a number that isn't the real cap.
            Text(entriesEdit.caption)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            Picker("Storage budget:", selection: budgetSelection) {
                ForEach(ClipdHistoryLimits.byteBudgetOptions, id: \.self) { option in
                    Text(ClipdHistoryLimits.label(forBytes: option)).tag(option)
                }
            }
            .frame(width: 240)

            Text("Clipd evicts its least-recent entries once either limit is "
                + "reached. Lowering a limit takes effect right away — Clipd asks "
                + "first if entries would be removed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Pinned entries are never evicted, so pinning a lot of large "
                + "images can keep Clipd above the storage budget.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            // Retention lives here, not in Capture: how LONG an entry is kept is
            // the same question as how MANY are kept. Unlike the two caps above,
            // this picker does offer a "never" row — that is the default and a
            // normal choice, not the absurd value an unbounded cap would be.
            Picker("Delete entries older than:", selection: retentionSelection) {
                ForEach(ClipdRetention.dayOptions, id: \.self) { days in
                    Text(ClipdRetention.label(forDays: days)).tag(days)
                }
            }
            .frame(width: 260)

            Text("Clipd checks when it starts and periodically while running, so "
                + "an entry can outlive its period by a while. Pinned entries "
                + "never expire, so some older entries can remain.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            Toggle("Clear history when Clipd quits", isOn: clearOnQuitSelection)
                .toggleStyle(.checkbox)

            Text("Unpinned entries only — pinned entries are kept. Best-effort: a "
                + "force quit or a sudden logout skips it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // The honest floor, on the tab where it matters most: this is
            // removal, not erasure, and the store is still local plaintext.
            Text("Removing an entry drops it from Clipd’s history and rewrites the "
                + "log — it does not overwrite the underlying disk space, and "
                + "Clipd’s history is stored as local plaintext either way.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        // A click on blank space or a label doesn't move keyboard focus on macOS,
        // so without this the field keeps focus and never commits. Filling the tab
        // with a tappable shape and dropping focus on a tap routes that click into
        // the focus-loss commit below. The pickers, stepper, and checkbox are
        // AppKit controls that take their own clicks, so this never sees those.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { entriesFocused = false }
        .onAppear(perform: reseed)
        // No publisher observation here on purpose: both commit paths reseed from
        // `settings` afterwards, and this view is the only thing that changes
        // these two values while the window is open. A `.onReceive` on a
        // `dropFirst()` publisher would also be rebuilt on every body pass, which
        // is exactly the kind of resubscribe that fires at the wrong moment and
        // clobbers a half-typed field.
        //
        // Committing on focus loss is what makes "type a number and click away"
        // behave the same as pressing Enter.
        .onChange(of: entriesFocused) { isFocused in
            // Deferred one turn: SwiftUI runs onChange inside a Core Animation
            // transaction commit, and AppKit suppresses NSAlert.runModal() there
            // ("cannot run inside a transaction… commit"), so a reduction's
            // confirmation never appeared and the suppressed alert read as a
            // Cancel. Enter's .onSubmit runs outside that commit and needs no hop.
            if !isFocused { DispatchQueue.main.async { commitEntries() } }
        }
    }

    private func reseed() {
        entriesText = String(settings.maxEntries)
        byteBudget = ClipdHistoryLimits.nearestByteBudget(to: settings.maxBytes)
        retentionDays = ClipdRetention.sanitize(settings.retentionDays)
    }

    /// What the box holds, judged against the count in force.
    private var entriesEdit: ClipdEntriesEdit {
        ClipdEntriesEdit(text: entriesText, current: settings.maxEntries)
    }

    /// The stepper drives the same text field the user can type into, and a click
    /// is itself a commit gesture. It steps from the typed count only when that's
    /// a valid edit; from anything else it steps from the count in force, because
    /// clamping junk first would apply a number nobody typed.
    private var entriesStepper: Binding<Int> {
        Binding(get: {
                    if case .valid(let typed) = entriesEdit { return typed }
                    return settings.maxEntries
                },
                set: { entriesText = String($0); commitEntries() })
    }

    private var budgetSelection: Binding<UInt64> {
        Binding(get: { byteBudget }, set: { commitBudget($0) })
    }

    private func commitEntries() {
        switch entriesEdit {
        case .valid(let proposed):
            // Pass the *committed* budget, not the local one, so each control
            // commits only its own change and a confirmation names only what
            // actually moved.
            _ = onCommit(proposed, settings.maxBytes)
        case .invalid:
            // Refused, never clamped: a clamp saves a number nobody typed. The
            // beep says "not applied"; reseed() snaps the box back below.
            NSSound.beep()
        case .unchanged:
            break
        }
        reseed()  // settings is the truth, whether the change applied, was cancelled, or was refused
    }

    private func commitBudget(_ proposed: UInt64) {
        guard proposed != settings.maxBytes else { return }
        byteBudget = proposed  // show the click immediately; reseed corrects a cancel
        _ = onCommit(settings.maxEntries, proposed)
        reseed()
    }

    /// Same shape as the budget picker: show the click at once, then let reseed
    /// snap it back if the confirmation was cancelled.
    private var retentionSelection: Binding<Int> {
        Binding(get: { retentionDays },
                set: { proposed in
                    guard proposed != settings.retentionDays else { return }
                    retentionDays = proposed
                    _ = onCommitRetention(proposed)
                    reseed()
                })
    }

    /// Not a direct binding to `settings`: switching this ON raises a
    /// confirmation, and a cancel must leave nothing persisted.
    private var clearOnQuitSelection: Binding<Bool> {
        Binding(get: { settings.clearsHistoryOnQuit },
                set: { _ = onCommitClearOnQuit($0) })
    }
}

/// General: the global hotkey and the login item. The shortcut owns its own
/// persistence inside KeyboardShortcuts; the login item is owned by
/// ClipdLoginItem, observed here so a toggle made in the status menu redraws this
/// checkbox (and vice versa).
struct GeneralSettingsView: View {
    @ObservedObject private var loginItem = ClipdLoginItem.shared

    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Search Clipd:", name: .toggleClipd)

            HStack {
                Spacer()
                Button("Reset to Default") { KeyboardShortcuts.reset(.toggleClipd) }
            }

            Divider().padding(.vertical, 4)

            Toggle("Launch Clipd at login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }))
                .toggleStyle(.checkbox)
        }
        .padding(20)
        // Catch changes made outside the app (System Settings ▸ Login Items).
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification)) { _ in loginItem.refresh() }
    }
}

/// Capture: pause/resume, per-kind capture filters (text/image/file), and the apps
/// to skip by source. All three are the same shape — a gate PasteboardMonitor
/// consults on every poll — so they share one tab. ClipdSettings is the single
/// store; toggling here and toggling "Pause Capture" in the status menu read/write
/// the same properties, so the two surfaces can't disagree.
struct CaptureSettingsView: View {
    @ObservedObject private var settings = ClipdSettings.shared

    var body: some View {
        Form {
            Toggle("Pause clipboard capture", isOn: $settings.captureIsPaused)
                .toggleStyle(.checkbox)

            Divider().padding(.vertical, 4)

            Text("Capture these types:")
            Toggle("Text", isOn: $settings.capturesText)
                .toggleStyle(.checkbox)
            Toggle("Images", isOn: $settings.capturesImages)
                .toggleStyle(.checkbox)
            Toggle("Files", isOn: $settings.capturesFiles)
                .toggleStyle(.checkbox)

            Text("These filters affect new copies only — nothing already saved is "
                + "removed, and this is not encryption. Clipd's history is still "
                + "stored as local plaintext.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            // The framing here has to stay honest: this is a frontmost-app check
            // with a poll-interval race that only covers the listed apps. It is a
            // best-effort heuristic, not security (see CLAUDE.md).
            Text("Don’t capture from these apps:")
            ExcludedAppsView(settings: settings)
            Text("Clipd skips a copy while one of these apps is frontmost. It’s a "
                + "best-effort check with a brief timing window — it can miss "
                + "copies, and it is not a security guarantee.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Apple’s Passwords and Keychain Access don’t mark copies as "
                + "secret, so removing them can leave passwords in Clipd’s "
                + "plaintext history.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

/// The single owner of login-item state, shared by the Settings checkbox and the
/// status-menu item so the two can't disagree: both read `isEnabled` and both
/// mutate through `setEnabled`, and the @Published value redraws SwiftUI.
///
/// It is a published value rather than a live `SMAppService.status` read on every
/// access because that status can still report the PREVIOUS registration for a
/// moment after register()/unregister() — reading it back immediately would snap
/// the control the user just clicked right back. So a call that doesn't throw is
/// shown as applied, and the system's own state is reconciled by refresh() the
/// next time a surface is about to be displayed.
final class ClipdLoginItem: ObservableObject {
    static let shared = ClipdLoginItem()

    @Published private(set) var isEnabled: Bool

    private init() { isEnabled = Self.systemEnabled }

    private static var systemEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Re-read what the system actually has registered. Called when the status
    /// menu opens and when the Settings window appears/becomes key — never
    /// straight after a mutation, for the reason above.
    func refresh() { isEnabled = Self.systemEnabled }

    /// Best-effort: on failure we log and fall back to the system's own state, so
    /// the UI never claims a change that didn't happen.
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isEnabled = enabled
        } catch {
            NSLog("Clipd: launch-at-login \(enabled ? "registration" : "removal") failed: \(error)")
            isEnabled = Self.systemEnabled
        }
    }
}
