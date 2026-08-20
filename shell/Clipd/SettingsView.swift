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

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            HistorySettingsView(onCommit: onCommitHistoryLimits)
                .tabItem { Label("History", systemImage: "clock") }
            CaptureSettingsView()
                .tabItem { Label("Capture", systemImage: "clipboard") }
        }
        .frame(width: 460, height: 440)
        .padding(.top, 8)
    }
}

/// History: how much is kept. Separate from Capture on purpose — Capture decides
/// what gets recorded, History decides how much of it survives.
///
/// Both controls are bounded and offer no "unlimited" option (see
/// ClipdHistoryLimits), and both commit on a real gesture — Enter, focus loss, a
/// stepper click, a picker selection. There is no Apply button and no debounce
/// timer: a change applies live, after a confirmation if it would evict.
///
/// The two values live in local state rather than binding straight to
/// ClipdSettings, because a cancelled confirmation has to revert without ever
/// having persisted. `settings` is the source of truth after every attempt, so
/// both commit paths re-seed from it whether the user accepted or cancelled.
struct HistorySettingsView: View {
    @ObservedObject private var settings = ClipdSettings.shared
    let onCommit: (Int, UInt64) -> Bool

    @State private var entriesText = ""
    @State private var byteBudget: UInt64 = ClipdSettings.defaultMaxBytes
    @FocusState private var entriesFocused: Bool

    init(onCommit: @escaping (Int, UInt64) -> Bool) {
        self.onCommit = onCommit
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
                Stepper("", value: entriesStepper,
                        in: ClipdHistoryLimits.minEntries...ClipdHistoryLimits.maxEntries,
                        step: 100)
                    .labelsHidden()
                Text("entries")
            }
            Text("\(ClipdHistoryLimits.minEntries.formatted())–"
                + "\(ClipdHistoryLimits.maxEntries.formatted()) entries.")
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
        }
        .padding(20)
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
            if !isFocused { commitEntries() }
        }
    }

    private func reseed() {
        entriesText = String(settings.maxEntries)
        byteBudget = ClipdHistoryLimits.nearestByteBudget(to: settings.maxBytes)
    }

    /// The stepper drives the same text field the user can type into, and a click
    /// is itself a commit gesture.
    private var entriesStepper: Binding<Int> {
        Binding(get: { parsedEntries },
                set: { entriesText = String($0); commitEntries() })
    }

    private var budgetSelection: Binding<UInt64> {
        Binding(get: { byteBudget }, set: { commitBudget($0) })
    }

    /// Digits only, then clamped — so a half-typed "1" can never reach the store
    /// as a one-entry history, and a paste of junk falls back to what is in force.
    private var parsedEntries: Int {
        let digits = entriesText.filter(\.isWholeNumber)
        return ClipdHistoryLimits.clampEntries(Int(digits) ?? settings.maxEntries)
    }

    private func commitEntries() {
        let proposed = parsedEntries
        // Pass the *committed* budget, not the local one, so each control commits
        // only its own change and a confirmation names only what actually moved.
        if proposed != settings.maxEntries {
            _ = onCommit(proposed, settings.maxBytes)
        }
        reseed()  // settings is the truth, whether the change applied or was cancelled
    }

    private func commitBudget(_ proposed: UInt64) {
        guard proposed != settings.maxBytes else { return }
        byteBudget = proposed  // show the click immediately; reseed corrects a cancel
        _ = onCommit(settings.maxEntries, proposed)
        reseed()
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
