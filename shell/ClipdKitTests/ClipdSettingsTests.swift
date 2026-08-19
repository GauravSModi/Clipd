import Combine
import XCTest
@testable import ClipdKit

/// The typed settings store: explicit defaults, write-through persistence, and a
/// change signal. Each test runs against a throwaway UserDefaults suite so the
/// real `.standard` domain (which holds the app's live settings) is never touched.
final class ClipdSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ClipdSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Defaults

    func testEmptyStoreReturnsDocumentedDefaults() {
        let settings = ClipdSettings(defaults: defaults)

        XCTAssertEqual(settings.maxEntries, ClipdSettings.defaultMaxEntries)
        XCTAssertEqual(settings.maxBytes, ClipdSettings.defaultMaxBytes)
        XCTAssertEqual(settings.maxBlobBytes, ClipdSettings.defaultMaxBlobBytes)
        XCTAssertEqual(settings.compactThresholdBytes,
                       ClipdSettings.defaultCompactThresholdBytes)
        XCTAssertFalse(settings.didPromptLaunchAtLogin)
        XCTAssertFalse(settings.didRequestAccessibility)
    }

    func testDefaultsMatchTheShippedConstants() {
        // These were AppDelegate's private constants before the settings store
        // existed; ClipdSettings is now the single default table, so a drift here
        // silently changes the store the app builds at launch.
        XCTAssertEqual(ClipdSettings.defaultMaxEntries, 10_000)
        XCTAssertEqual(ClipdSettings.defaultMaxBytes, 256 * 1024 * 1024)
        XCTAssertEqual(ClipdSettings.defaultMaxBlobBytes, 50 * 1024 * 1024)
        XCTAssertEqual(ClipdSettings.defaultCompactThresholdBytes, 4 * 1024 * 1024)
    }

    // MARK: - Write-through

    func testSettingAValueWritesThroughToUserDefaults() {
        let settings = ClipdSettings(defaults: defaults)

        settings.maxEntries = 250
        settings.maxBytes = 12_345
        settings.didRequestAccessibility = true

        // Assert the RAW keys: the app's persistence contract is the stored plist,
        // not just the in-memory property.
        XCTAssertEqual(defaults.object(forKey: "clipd.maxEntries") as? Int, 250)
        XCTAssertEqual(defaults.object(forKey: "clipd.maxBytes") as? Int, 12_345)
        XCTAssertEqual(defaults.object(forKey: "didRequestAccessibility") as? Bool, true)
    }

    func testValuesSurviveANewInstanceOverTheSameStore() {
        // The "survives an app restart" property, without restarting an app.
        let first = ClipdSettings(defaults: defaults)
        first.maxEntries = 42
        first.maxBlobBytes = 9_000
        first.didPromptLaunchAtLogin = true

        let second = ClipdSettings(defaults: defaults)

        XCTAssertEqual(second.maxEntries, 42)
        XCTAssertEqual(second.maxBlobBytes, 9_000)
        XCTAssertTrue(second.didPromptLaunchAtLogin)
    }

    // MARK: - Upgrade path

    func testPreExistingFirstRunFlagsAreHonored() {
        // Installs that predate the settings store already have these two bare
        // keys set by AppDelegate. Reusing the exact key strings is what keeps an
        // upgraded install from re-showing the first-run prompts.
        defaults.set(true, forKey: "didPromptLaunchAtLogin")
        defaults.set(true, forKey: "didRequestAccessibility")

        let settings = ClipdSettings(defaults: defaults)

        XCTAssertTrue(settings.didPromptLaunchAtLogin)
        XCTAssertTrue(settings.didRequestAccessibility)
    }

    // MARK: - Change signal

    func testChangingAValuePublishes() {
        let settings = ClipdSettings(defaults: defaults)
        var observed: [Int] = []
        let cancellable = settings.$maxEntries.dropFirst().sink { observed.append($0) }
        defer { cancellable.cancel() }

        settings.maxEntries = 7
        settings.maxEntries = 8

        XCTAssertEqual(observed, [7, 8])
    }

    func testObjectWillChangeFiresForAnyProperty() {
        let settings = ClipdSettings(defaults: defaults)
        var fired = 0
        let cancellable = settings.objectWillChange.sink { _ in fired += 1 }
        defer { cancellable.cancel() }

        settings.maxBytes = 1
        settings.didPromptLaunchAtLogin = true

        XCTAssertEqual(fired, 2)
    }

    // MARK: - Defensive reads

    func testZeroMaxEntriesFallsBackToDefault() {
        // A corrupt or hand-edited plist must not produce a zero-count store that
        // keeps nothing. This is shell-side input validation only — eviction policy
        // itself stays in the C++ ClipStore.
        defaults.set(0, forKey: "clipd.maxEntries")

        XCTAssertEqual(ClipdSettings(defaults: defaults).maxEntries,
                       ClipdSettings.defaultMaxEntries)
    }

    func testZeroByteCapsArePreserved() {
        // clipd.h documents 0 as MEANINGFUL for both byte caps: max_bytes 0 =
        // unbounded, max_blob_bytes 0 = no per-image limit. The store must pass
        // them through, not "correct" them into a default.
        defaults.set(0, forKey: "clipd.maxBytes")
        defaults.set(0, forKey: "clipd.maxBlobBytes")

        let settings = ClipdSettings(defaults: defaults)

        XCTAssertEqual(settings.maxBytes, 0)
        XCTAssertEqual(settings.maxBlobBytes, 0)
    }

    func testNegativeStoredValuesFallBackToDefaults() {
        // Negative is nonsense for every cap (and would trap converting to UInt64),
        // so it always falls back rather than crashing at launch.
        defaults.set(-1, forKey: "clipd.maxEntries")
        defaults.set(-1, forKey: "clipd.maxBytes")
        defaults.set(-1, forKey: "clipd.maxBlobBytes")
        defaults.set(-1, forKey: "clipd.compactThresholdBytes")

        let settings = ClipdSettings(defaults: defaults)

        XCTAssertEqual(settings.maxEntries, ClipdSettings.defaultMaxEntries)
        XCTAssertEqual(settings.maxBytes, ClipdSettings.defaultMaxBytes)
        XCTAssertEqual(settings.maxBlobBytes, ClipdSettings.defaultMaxBlobBytes)
        XCTAssertEqual(settings.compactThresholdBytes,
                       ClipdSettings.defaultCompactThresholdBytes)
    }
}
