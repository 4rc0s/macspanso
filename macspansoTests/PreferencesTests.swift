// macspansoTests/PreferencesTests.swift
import XCTest
import Combine
@testable import macspanso

@MainActor
final class PreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var prefs: Preferences!

    override func setUp() {
        super.setUp()
        suiteName = "macspanso.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        prefs = Preferences(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Keys

    /// Renaming a key orphans every existing user's stored value, so the
    /// literals are pinned here. Every key belongs in this list once it has
    /// shipped, not just the ones that predate `Preferences`.
    func testKeysAreFrozen() {
        XCTAssertEqual(Preferences.Key.snoozeUntil,             "macspanso.snoozeUntil")
        XCTAssertEqual(Preferences.Key.lastUpdateCheck,         "updateChecker.lastCheckDate")
        XCTAssertEqual(Preferences.Key.lastDestinationFilePath, "macspanso.lastDestinationFilePath")
        XCTAssertEqual(Preferences.Key.listSort,                "macspanso.listSort")
        XCTAssertEqual(Preferences.Key.listGrouped,             "macspanso.listGrouped")
        XCTAssertEqual(Preferences.Key.automaticUpdateChecks,   "macspanso.automaticUpdateChecks")
    }

    // MARK: - Defaults and round-trips

    func testAutomaticUpdateChecksDefaultsToTrue() {
        XCTAssertTrue(prefs.automaticUpdateChecks)
        // object(forKey:) consults the registration domain too, so inspect
        // the persistent domain to prove nothing was written.
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?[Preferences.Key.automaticUpdateChecks],
                     "the default must come from the registration domain, not a stored value")
    }

    func testListGroupedDefaultsToTrue() {
        XCTAssertTrue(prefs.listGrouped)
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?[Preferences.Key.listGrouped],
                     "the default must come from the registration domain, not a stored value")
    }

    func testListGroupedPersists() {
        prefs.listGrouped = false
        XCTAssertFalse(prefs.listGrouped)
        XCTAssertFalse(Preferences(defaults: defaults).listGrouped,
                       "a fresh instance over the same suite must see the stored value")
    }

    func testAutomaticUpdateChecksPersists() {
        prefs.automaticUpdateChecks = false
        XCTAssertFalse(prefs.automaticUpdateChecks)
        XCTAssertFalse(Preferences(defaults: defaults).automaticUpdateChecks,
                       "a fresh instance over the same suite must see the stored value")
    }

    func testDatesRoundTrip() {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        prefs.snoozeUntil = when
        prefs.lastUpdateCheck = when
        XCTAssertEqual(prefs.snoozeUntil, when)
        XCTAssertEqual(prefs.lastUpdateCheck, when)
    }

    func testStringsRoundTrip() {
        prefs.lastDestinationFilePath = "/tmp/base.yml"
        prefs.listSortRaw = "alphabetical"
        XCTAssertEqual(prefs.lastDestinationFilePath, "/tmp/base.yml")
        XCTAssertEqual(prefs.listSortRaw, "alphabetical")
    }

    func testSettingNilRemovesTheKey() {
        prefs.snoozeUntil = Date()
        prefs.snoozeUntil = nil
        XCTAssertNil(prefs.snoozeUntil)
        XCTAssertNil(defaults.object(forKey: Preferences.Key.snoozeUntil),
                     "nil must remove the key rather than store a null")
    }

    func testWritesPublishChange() {
        var fired = 0
        let sub = prefs.objectWillChange.sink { fired += 1 }
        prefs.automaticUpdateChecks = false
        prefs.snoozeUntil = nil
        sub.cancel()
        XCTAssertEqual(fired, 2, "every write must notify observers, including a removal")
    }

    // MARK: - Consumers

    func testProcessManagerRestoresFutureSnooze() {
        let end = Date(timeIntervalSinceNow: 3600)
        prefs.snoozeUntil = end
        let manager = EspansoProcessManager(espansoPath: "/nonexistent/espanso", preferences: prefs)
        XCTAssertEqual(manager.snoozeUntil, end)
    }

    func testProcessManagerDiscardsExpiredSnooze() {
        prefs.snoozeUntil = Date(timeIntervalSinceNow: -60)
        let manager = EspansoProcessManager(espansoPath: "/nonexistent/espanso", preferences: prefs)
        XCTAssertNil(manager.snoozeUntil)
        XCTAssertNil(prefs.snoozeUntil, "an elapsed snooze must be cleared from storage too")
    }

    func testProcessManagerSnoozeWritesThrough() {
        let manager = EspansoProcessManager(espansoPath: "/nonexistent/espanso", preferences: prefs)
        let end = Date(timeIntervalSinceNow: 600)
        manager.snooze(until: end)
        XCTAssertEqual(prefs.snoozeUntil, end)
        manager.cancelSnooze(reenable: false)
        XCTAssertNil(prefs.snoozeUntil)
    }
}
