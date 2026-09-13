// macspansoTests/UpdateCheckerTests.swift
import XCTest
@testable import macspanso

/// Covers the gate in front of the network: automatic checks respect the
/// preference and the 24h interval, the manual check ignores both. The
/// checker's fetch is stubbed, so nothing here touches GitHub.
@MainActor
final class UpdateCheckerTests: XCTestCase {
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

    // MARK: - Helpers

    private static let interval: TimeInterval = 86_400

    /// A checker whose fetch fulfils `expectation` and answers with `tag` at
    /// `status`. `expectation` should be inverted for the "must not fetch"
    /// cases so the test fails if a request is attempted.
    private func makeChecker(currentVersion: String = "1.0.0",
                             remoteTag: String = "v9.9.9",
                             status: Int = 200,
                             fulfilling expectation: XCTestExpectation) -> UpdateChecker {
        UpdateChecker(preferences: prefs, currentVersion: currentVersion) { request in
            expectation.fulfill()
            let body = try JSONSerialization.data(withJSONObject: ["tag_name": remoteTag])
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }

    private func noFetch() -> XCTestExpectation {
        let e = expectation(description: "fetch must not be attempted")
        e.isInverted = true
        return e
    }

    private func oneFetch() -> XCTestExpectation {
        let e = expectation(description: "fetch attempted once")
        e.assertForOverFulfill = true
        return e
    }

    // MARK: - checkIfStale

    func testStaleCheckSkipsWhenAutomaticChecksAreOff() async {
        prefs.automaticUpdateChecks = false
        let fetched = noFetch()
        let checker = makeChecker(fulfilling: fetched)

        checker.checkIfStale()

        await fulfillment(of: [fetched], timeout: 0.2)
        XCTAssertNil(prefs.lastUpdateCheck)
    }

    func testStaleCheckFetchesWhenNeverChecked() async {
        let fetched = oneFetch()
        let checker = makeChecker(fulfilling: fetched)

        checker.checkIfStale()

        await fulfillment(of: [fetched], timeout: 1)
        await Task.yield()
        XCTAssertNotNil(prefs.lastUpdateCheck, "a successful fetch stamps the last-check date")
        XCTAssertEqual(checker.latestVersion, "9.9.9")
        XCTAssertTrue(checker.updateAvailable)
    }

    func testStaleCheckSkipsARecentCheck() async {
        prefs.lastUpdateCheck = Date(timeIntervalSinceNow: -60)
        let fetched = noFetch()
        let checker = makeChecker(fulfilling: fetched)

        checker.checkIfStale()

        await fulfillment(of: [fetched], timeout: 0.2)
    }

    func testStaleCheckFetchesPastTheInterval() async {
        prefs.lastUpdateCheck = Date(timeIntervalSinceNow: -(Self.interval + 60))
        let fetched = oneFetch()
        let checker = makeChecker(fulfilling: fetched)

        checker.checkIfStale()

        await fulfillment(of: [fetched], timeout: 1)
    }

    // MARK: - checkNow

    func testManualCheckIgnoresTheToggleAndTheInterval() async {
        prefs.automaticUpdateChecks = false
        prefs.lastUpdateCheck = Date()
        let fetched = oneFetch()
        let checker = makeChecker(remoteTag: "v1.0.0", fulfilling: fetched)
        let completed = expectation(description: "completion called")
        var outcome: UpdateChecker.CheckOutcome?

        checker.checkNow { result in
            outcome = result
            completed.fulfill()
        }

        await fulfillment(of: [fetched, completed], timeout: 1)
        XCTAssertEqual(outcome, .upToDate("1.0.0"))
        XCTAssertFalse(checker.updateAvailable)
    }

    // MARK: - Failure

    func testFailedResponseDoesNotStampLastCheck() async {
        let fetched = oneFetch()
        let checker = makeChecker(status: 500, fulfilling: fetched)
        let completed = expectation(description: "completion called")
        var outcome: UpdateChecker.CheckOutcome?

        checker.checkNow { result in
            outcome = result
            completed.fulfill()
        }

        await fulfillment(of: [fetched, completed], timeout: 1)
        XCTAssertEqual(outcome, .failed)
        XCTAssertNil(prefs.lastUpdateCheck,
                     "only a successful response counts as a check, so a flaky network retries next time")
        XCTAssertNil(checker.latestVersion)
    }
}
