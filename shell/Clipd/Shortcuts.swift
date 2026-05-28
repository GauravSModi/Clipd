import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global hotkey that summons the search panel. Default ⌘⇧V; user-rebindable
    /// through KeyboardShortcuts' recorder. Uses Carbon RegisterEventHotKey under
    /// the hood (no Accessibility permission required).
    static let toggleClipd = Self("toggleClipd",
                                  default: .init(.v, modifiers: [.command, .shift]))
}
