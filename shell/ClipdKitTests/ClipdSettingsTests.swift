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

    // MARK: - Capture policy (pause + per-kind filters)

    func testEmptyStoreCapturesEverythingAndIsNotPaused() {
        let settings = ClipdSettings(defaults: defaults)

        XCTAssertFalse(settings.captureIsPaused)
        XCTAssertTrue(settings.capturesText)
        XCTAssertTrue(settings.capturesImages)
        XCTAssertTrue(settings.capturesFiles)
    }

    func testCaptureSettingsWriteThroughToRawKeys() {
        let settings = ClipdSettings(defaults: defaults)

        settings.captureIsPaused = true
        settings.capturesImages = false

        XCTAssertEqual(defaults.object(forKey: "clipd.captureIsPaused") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "clipd.capturesImages") as? Bool, false)
    }

    func testCaptureSettingsSurviveANewInstanceOverTheSameStore() {
        // Decision 1: pause is a persisted setting, not session-only state.
        let first = ClipdSettings(defaults: defaults)
        first.captureIsPaused = true
        first.capturesFiles = false

        let second = ClipdSettings(defaults: defaults)

        XCTAssertTrue(second.captureIsPaused)
        XCTAssertFalse(second.capturesFiles)
    }

    // MARK: - Excluded source apps

    func testEmptyStoreSeedsTheDocumentedExcludedApps() {
        // An install that predates the editable list must keep behaving the same:
        // an absent key reads back as the two ids that used to be compiled into
        // PasteboardMonitor.
        let settings = ClipdSettings(defaults: defaults)

        XCTAssertEqual(settings.excludedSourceApps,
                       ClipdSettings.defaultExcludedSourceApps)
    }

    func testSeededExcludedAppsAreTheTwoAppleIDs() {
        // PasteboardMonitor's injected default is permissive (no exclusions), so
        // this table is the ONLY thing keeping the Passwords/Keychain fallback
        // alive. A drift here silently drops it.
        XCTAssertEqual(ClipdSettings.defaultExcludedSourceApps,
                       ["com.apple.Passwords", "com.apple.keychainaccess"])
    }

    func testExcludedAppsWriteThroughToTheRawKey() {
        let settings = ClipdSettings(defaults: defaults)

        settings.excludedSourceApps = ["com.example.vault"]

        XCTAssertEqual(defaults.object(forKey: "clipd.excludedSourceApps") as? [String],
                       ["com.example.vault"])
    }

    func testExcludedAppsSurviveANewInstanceOverTheSameStore() {
        let first = ClipdSettings(defaults: defaults)
        first.addExcludedApp("com.example.vault")

        let second = ClipdSettings(defaults: defaults)

        XCTAssertTrue(second.excludedSourceApps.contains("com.example.vault"))
    }

    func testEmptiedListStaysEmptyAndIsNotReSeeded() {
        // Decision: removal is a real, persisted choice. A STORED empty array is
        // honored; only a missing key falls back to the seed.
        let first = ClipdSettings(defaults: defaults)
        for id in first.excludedSourceApps { first.removeExcludedApp(id) }
        XCTAssertEqual(first.excludedSourceApps, [])

        let second = ClipdSettings(defaults: defaults)

        XCTAssertEqual(second.excludedSourceApps, [],
                       "an emptied list must not silently re-seed on next launch")
    }

    func testCorruptExcludedAppsValueFallsBackToTheSeed() {
        defaults.set("not-an-array", forKey: "clipd.excludedSourceApps")

        XCTAssertEqual(ClipdSettings(defaults: defaults).excludedSourceApps,
                       ClipdSettings.defaultExcludedSourceApps)
    }

    func testAddingADuplicateIsANoOpAndKeepsOrder() {
        let settings = ClipdSettings(defaults: defaults)
        settings.excludedSourceApps = ["com.a", "com.b"]

        settings.addExcludedApp("com.a")

        XCTAssertEqual(settings.excludedSourceApps, ["com.a", "com.b"],
                       "a duplicate must neither append nor reorder")
    }

    func testAddingTrimsWhitespaceAndIgnoresEmpty() {
        let settings = ClipdSettings(defaults: defaults)
        settings.excludedSourceApps = []

        settings.addExcludedApp("  com.example.vault  ")
        settings.addExcludedApp("   ")
        settings.addExcludedApp("")

        XCTAssertEqual(settings.excludedSourceApps, ["com.example.vault"])
    }

    func testRemovingAnAppDropsItFromTheList() {
        let settings = ClipdSettings(defaults: defaults)
        settings.excludedSourceApps = ["com.a", "com.b"]

        settings.removeExcludedApp("com.a")
        settings.removeExcludedApp("com.not-present")

        XCTAssertEqual(settings.excludedSourceApps, ["com.b"])
    }

    func testExcludedSourceAppIDsMirrorsTheList() {
        // The Set is what PasteboardMonitor's provider hands back; the Array is
        // what the UI lists in a stable order.
        let settings = ClipdSettings(defaults: defaults)
        settings.excludedSourceApps = ["com.a", "com.b"]

        XCTAssertEqual(settings.excludedSourceAppIDs, ["com.a", "com.b"])
    }

    func testCapturePolicyMirrorsTheFourProperties() {
        let settings = ClipdSettings(defaults: defaults)
        settings.captureIsPaused = false
        settings.capturesText = true
        settings.capturesImages = false
        settings.capturesFiles = true

        let policy = settings.capturePolicy

        XCTAssertFalse(policy.isPaused)
        XCTAssertTrue(policy.allows(.text))
        XCTAssertFalse(policy.allows(.image))
        XCTAssertTrue(policy.allows(.file))
    }

    // MARK: - Retention

    /// Age expiry is opt-in: an upgraded install must not silently start
    /// deleting history, and clear-on-quit must not silently start firing.
    func testRetentionDefaultsToNeverAndClearOnQuitToOff() {
        let settings = ClipdSettings(defaults: defaults)

        XCTAssertEqual(settings.retentionDays, ClipdRetention.defaultDays)
        XCTAssertEqual(settings.retentionDays, 0)
        XCTAssertFalse(settings.clearsHistoryOnQuit)
    }

    func testRetentionAndClearOnQuitPersistAcrossInstances() {
        let settings = ClipdSettings(defaults: defaults)
        settings.retentionDays = 30
        settings.clearsHistoryOnQuit = true

        let reopened = ClipdSettings(defaults: defaults)

        XCTAssertEqual(reopened.retentionDays, 30)
        XCTAssertTrue(reopened.clearsHistoryOnQuit)
    }

    /// retentionDays deliberately does NOT go through `positiveInt` — 0 is a
    /// real, meaningful value here (Never), not a corrupt one.
    func testStoredNeverSurvivesRatherThanFallingBackToAPeriod() {
        defaults.set(0, forKey: "clipd.retentionDays")

        XCTAssertEqual(ClipdSettings(defaults: defaults).retentionDays, 0)
    }

    /// A junk or stale value falls back to Never — the direction that deletes
    /// nothing. Reading it as some arbitrary period would destroy history off a
    /// corrupt plist.
    func testCorruptRetentionValueFallsBackToNever() {
        defaults.set(13, forKey: "clipd.retentionDays")
        XCTAssertEqual(ClipdSettings(defaults: defaults).retentionDays, 0)

        defaults.set(-30, forKey: "clipd.retentionDays")
        XCTAssertEqual(ClipdSettings(defaults: defaults).retentionDays, 0)

        defaults.set("thirty", forKey: "clipd.retentionDays")
        XCTAssertEqual(ClipdSettings(defaults: defaults).retentionDays, 0)
    }
}
