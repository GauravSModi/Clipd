// What activating a history entry should do, and the pure rule for resolving it.
// Holds no AppKit/AX state — the caller passes in whether the Accessibility
// permission is granted, so the fallback decision is testable in the UI-free
// layer. The actual keystroke synthesis is run-the-app only (in AppDelegate).

import Foundation

public enum ClipdPasteAction: Equatable {
    case paste   // reactivate the prior app and synthesize ⌘V
    case copy    // only place the entry on the pasteboard
}

/// Paste-back happens only when requested *and* Accessibility is granted;
/// otherwise it degrades to copy-only so the action is never silently dropped.
public func clipdResolvePasteAction(requested: ClipdPasteAction,
                                    accessibilityTrusted: Bool) -> ClipdPasteAction {
    (requested == .paste && accessibilityTrusted) ? .paste : .copy
}
