import SwiftUI
import ServiceManagement
import KeyboardShortcuts
import ClipdKit

// The Settings window's panes, one per toolbar tab. SettingsWindow.swift builds
// the window and the tabs around them.

/// History: how much is kept. Separate from Capture on purpose — Capture decides
/// what gets recorded, History decides how much of it survives.
///
/// Both controls are bounded and offer no "unlimited" option (see
/// ClipdHistoryLimits), and both commit on a real gesture — Enter, focus loss
/// (including a click on blank space in the tab), a picker selection. There is
/// no Apply button and no debounce timer: a change applies live, after a
/// confirmation if it would evict. The entries field accepts only digits, and
/// refuses an out-of-range count rather than clamping it.
///
/// The two values live in local state rather than binding straight to
/// ClipdSettings, because a cancelled confirmation has to revert without ever
/// having persisted. `settings` is the source of truth after every attempt, so
/// both commit paths re-seed from it whether the user accepted or cancelled.
struct HistorySettingsView: View {
    @ObservedObject private var settings = ClipdSettings.shared
    /// Applies a proposed pair of history caps, confirming first if the change
    /// would evict. Returns false when the user cancels, so this tab can snap its
    /// controls back. Owned by AppDelegate: the alert is AppKit, and the live-set
    /// stats it needs come from the controller.
    let onCommit: (Int, UInt64) -> Bool
    /// Applies a proposed retention period, confirming first if it would start
    /// deleting entries, then sweeping at once. Returns false on a cancel.
    let onCommitRetention: (Int) -> Bool
    /// Applies the clear-on-quit setting, confirming when it is switched ON.
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
            // "Limits" is how much is kept, by count and by size. Retention below
            // is how LONG — a separate section on purpose (see its comment).
            Section("Limits") {
                LabeledContent {
                    HStack(spacing: 6) {
                        TextField("", text: $entriesText)
                            .labelsHidden()
                            // A grouped Form draws a field as plain text, with no
                            // box, so it doesn't read as editable. The bordered
                            // style gives it one; textPointer() gives it the I-beam.
                            .textFieldStyle(.roundedBorder)
                            .textPointer()
                            .frame(width: 72)
                            .multilineTextAlignment(.trailing)
                            .focused($entriesFocused)
                            .onSubmit { commitEntries() }
                            // Drop anything but digits the moment it's typed or
                            // pasted. Writing the filtered text back re-fires this
                            // once, as a no-op.
                            .onChange(of: entriesText) { text in
                                let digits = ClipdHistoryLimits.digitsOnly(text)
                                if digits != text { entriesText = digits }
                            }
                        Text("entries")
                    }
                } label: {
                    Text("Keep at most")
                    // A second Text in a grouped row's label draws as its gray
                    // subtitle. Shown only while the box holds a count that isn't
                    // in force — how to apply it, or what the box accepts — so the
                    // field never silently shows a number that isn't the real cap.
                    if entriesEdit != .unchanged {
                        Text(entriesEdit.caption)
                    }
                }

                Picker("Storage budget", selection: budgetSelection) {
                    ForEach(ClipdHistoryLimits.byteBudgetOptions, id: \.self) { option in
                        Text(ClipdHistoryLimits.label(forBytes: option)).tag(option)
                    }
                }
            }

            // Retention lives in its own section, not folded into Limits: how LONG
            // an entry is kept is a different question from how MANY are kept.
            // Unlike the two caps above, this picker does offer a "never" row —
            // that is the default and a normal choice, not the absurd value an
            // unbounded cap would be. Its caveats (pins never expire) are in the
            // confirmation it raises.
            Section("Retention") {
                Picker("Delete entries older than", selection: retentionSelection) {
                    ForEach(ClipdRetention.dayOptions, id: \.self) { days in
                        Text(ClipdRetention.label(forDays: days)).tag(days)
                    }
                }

                // Its caveats (pins kept, best-effort) are in the confirmation
                // that switching it on raises.
                Toggle("Clear history when Clipd quits", isOn: clearOnQuitSelection)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(WholeRowToggleStyle())
        // Same sizing as the other panes: the window is sized to the pane, so the
        // Form never needs to scroll, and fixedSize reports its full content
        // height for that measurement.
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 500)
        // A click on blank space or a label doesn't move keyboard focus on macOS,
        // so without this the field keeps focus and never commits. Filling the tab
        // with a tappable shape and dropping focus on a tap routes that click into
        // the focus-loss commit below. The pickers and switch are AppKit controls
        // that take their own clicks, so this never sees those.
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

    /// Settles a typed count before another control on this tab applies its own
    /// change, so that change's confirmation is never asked with a count still
    /// waiting behind it. The pickers and switch are AppKit controls that don't
    /// take focus, so clicking them never runs the focus-loss commit on its own.
    /// A cancel here doesn't block the other control: they're separate changes.
    private func commitPendingEntries() {
        guard entriesEdit != .unchanged else { return }
        commitEntries()
    }

    private func commitBudget(_ proposed: UInt64) {
        guard proposed != settings.maxBytes else { return }
        commitPendingEntries()
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
                    commitPendingEntries()
                    retentionDays = proposed
                    _ = onCommitRetention(proposed)
                    reseed()
                })
    }

    /// Not a direct binding to `settings`: switching this ON raises a
    /// confirmation, and a cancel must leave nothing persisted.
    private var clearOnQuitSelection: Binding<Bool> {
        Binding(get: { settings.clearsHistoryOnQuit },
                set: { enabled in
                    commitPendingEntries()
                    _ = onCommitClearOnQuit(enabled)
                })
    }
}

/// General: the global hotkey and the login item. The shortcut owns its own
/// persistence inside KeyboardShortcuts; the login item is owned by
/// ClipdLoginItem, observed here so a toggle made in the status menu redraws this
/// switch (and vice versa).
struct GeneralSettingsView: View {
    @ObservedObject private var loginItem = ClipdLoginItem.shared

    var body: some View {
        Form {
            Section {
                // The label-less recorder, so LabeledContent can put the label
                // on the left and the recorder with Reset on the right.
                LabeledContent("Search Clipd shortcut") {
                    HStack {
                        KeyboardShortcuts.Recorder(for: .toggleClipd)
                        Button("Reset") { KeyboardShortcuts.reset(.toggleClipd) }
                    }
                }
            }

            Section {
                Toggle("Launch Clipd at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }))
            }
        }
        .formStyle(.grouped)
        .toggleStyle(WholeRowToggleStyle())
        // Same sizing as CaptureSettingsView, which explains it.
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 500)
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
            Section {
                Toggle("Pause capture", isOn: $settings.captureIsPaused)
            }

            Section("Capture types") {
                Toggle("Text", isOn: $settings.capturesText)
                Toggle("Images", isOn: $settings.capturesImages)
                Toggle("Files", isOn: $settings.capturesFiles)
            }

            // The framing here has to stay honest: this is a frontmost-app check
            // with a poll-interval race that only covers the listed apps. It is a
            // best-effort heuristic, not security (see CLAUDE.md). This footer is
            // the only explanation in the Settings window, on purpose.
            Section {
                ExcludedAppsView(settings: settings)
            } header: {
                Text("Don’t capture from these apps")
            } footer: {
                Text(ClipdSettingsCopy.excludedAppsFooter)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(WholeRowToggleStyle())
        // The window is sized to the pane, so the Form never needs to scroll;
        // fixedSize reports the Form's full content height for that measurement.
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 500)
    }
}

/// Lets a click anywhere on a switch's row flip it — the label, the empty space
/// between, or the card's margin around them — not only a click on the switch
/// itself. It adds just that tap: `Toggle(configuration)` draws the toggle in the
/// style it would have had anyway, a grouped Form's switch. A click on the switch
/// itself is taken by the switch, an AppKit control, so it doesn't also reach the
/// tap and flip it twice.
private struct WholeRowToggleStyle: ToggleStyle {
    /// How far a grouped Form insets a row's content from its card's edges and
    /// from the divider below it — measured, not documented. Growing the tap area
    /// by exactly this much fills the card without overlapping the next row's.
    private static let rowInset: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            // Grow the tappable area out to the card's edges, then take the same
            // amount back so the row's layout doesn't move.
            .padding(Self.rowInset)
            .contentShape(Rectangle())
            .onTapGesture { configuration.isOn.toggle() }
            .padding(-Self.rowInset)
    }
}

private extension View {
    /// The I-beam over a text field before it's clicked. The hosting view shows
    /// the arrow over a field until it has focus, so without this the pointer
    /// never says "editable" until the first click. `pointerStyle` is macOS 15+;
    /// earlier systems keep the arrow until that click.
    @ViewBuilder func textPointer() -> some View {
        if #available(macOS 15, *) {
            pointerStyle(.horizontalText)
        } else {
            self
        }
    }
}

/// The single owner of login-item state, shared by the Settings switch and the
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
