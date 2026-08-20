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
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            CaptureSettingsView()
                .tabItem { Label("Capture", systemImage: "clipboard") }
        }
        .frame(width: 460, height: 440)
        .padding(.top, 8)
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
