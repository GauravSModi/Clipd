/// The Settings window's explanations. They live here rather than in the
/// Settings views because the views are in the app target, which no test can
/// reach; SettingsCopyTests pins every caveat each one has to keep.
///
/// Keep them short, and keep them honest (see "Known limitations" in CLAUDE.md):
/// the history is plaintext, and the excluded-apps check is a best-effort
/// heuristic, never security. The panes carry no other explanation on purpose:
/// the caps', retention's and clear-on-quit's caveats are in the confirmation
/// alerts they raise (ClipdLimitReduction, ClipdRetentionChange,
/// ClipdClearOnQuit).
public enum ClipdSettingsCopy {
    /// Shown under the excluded-apps list. The one explanation that stays
    /// visible, because removing an app there can put passwords in the history.
    public static let excludedAppsFooter =
        "A best-effort check with a brief timing window, not a security "
        + "guarantee. Passwords and Keychain Access don’t mark copies as secret, "
        + "so removing them can leave passwords in plaintext history."
}
