import XCTest
@testable import ClipdKit

/// The Settings window's explanations. They are short on purpose, and
/// shortening is exactly how an honest caveat gets dropped, so every fact each
/// one must keep is pinned here — the same way RetentionTests pins the
/// clear-on-quit alert.
final class SettingsCopyTests: XCTestCase {

    /// A frontmost-app heuristic with a poll race, and Apple's two password apps
    /// don't tag their copies — so removing them is the one edit here that can
    /// put passwords in the history.
    func testExcludedAppsFooterStatesHeuristicAndThePasswordRisk() {
        let text = ClipdSettingsCopy.excludedAppsFooter.lowercased()
        for fact in ["best-effort", "timing window", "not a security guarantee",
                     "passwords and keychain access", "removing them",
                     "plaintext history"] {
            XCTAssertTrue(text.contains(fact), "excludedAppsFooter must say “\(fact)”")
        }
    }

    /// It may not overclaim erasure. "security" is fine ("not a security
    /// guarantee"); it doesn't contain "secure".
    func testExcludedAppsFooterDoesNotOverclaimErasure() {
        let text = ClipdSettingsCopy.excludedAppsFooter.lowercased()
        for forbidden in ["permanent", "erase", "wipe", "secure"] {
            XCTAssertFalse(text.contains(forbidden),
                           "excludedAppsFooter must not say “\(forbidden)”")
        }
    }
}
