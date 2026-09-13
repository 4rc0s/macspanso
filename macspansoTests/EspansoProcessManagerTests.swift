// macspansoTests/EspansoProcessManagerTests.swift
import XCTest
@testable import macspanso

@MainActor
final class EspansoProcessManagerTests: XCTestCase {

    /// Writes an executable stand-in for the espanso binary.
    private func makeFakeEspanso(script: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-espanso-\(UUID().uuidString).sh")
        try "#!/bin/bash\n\(script)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    /// A `Preferences` over a throwaway suite, so tests that snooze never
    /// leave state in the developer's real defaults.
    private func makeIsolatedPreferences() -> Preferences {
        let suite = "macspanso.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Preferences(defaults: defaults)
    }

    /// Races `body` against a deadline. Async XCTest bodies that never return
    /// hang the whole suite (XCTest waits without timeout), so every test that
    /// exercises a potentially-hanging path must go through this.
    private func withDeadline<T: Sendable>(
        seconds: UInt64,
        _ body: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                return nil
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }

    func testRunReadsOutputLargerThanPipeBuffer() async throws {
        // ~1 MB of output — far beyond the ~64 KB pipe buffer. If run() waits
        // for exit before draining the pipe, the child blocks on a full pipe
        // and run() never returns. The output comes from bash itself (no
        // grandchildren) and a watchdog bounds the child's life so a deadlocked
        // child can't hold the test host's inherited pipes open forever.
        // The watchdog must NOT inherit our stdout pipe (>/dev/null), or its
        // orphaned sleep would hold the write end open and delay EOF to 15s.
        let script = """
        ( sleep 15; kill -9 $$ ) >/dev/null 2>&1 &
        watchdog=$!
        line=$(printf 'x%.0s' {1..999})
        for i in {1..1000}; do echo "$line"; done
        kill -9 $watchdog 2>/dev/null
        exit 0
        """
        let path = try makeFakeEspanso(script: script)
        let manager = EspansoProcessManager(espansoPath: path)

        let output = await withDeadline(seconds: 10) { await manager.run("log") }
        let result = try XCTUnwrap(output, "run() deadlocked on output > pipe buffer")
        XCTAssertGreaterThan(result.utf8.count, 900_000)
    }

    func testRunReturnsEmptyWhenBinaryCannotLaunch() async throws {
        // A failed launch must not leave run() blocked reading a pipe whose
        // write end our own process still holds (EOF never arrives).
        let manager = EspansoProcessManager(
            espansoPath: "/nonexistent/path/to/espanso")
        let output = await withDeadline(seconds: 5) { await manager.run("status") }
        let result = try XCTUnwrap(output, "run() hung forever on launch failure")
        XCTAssertEqual(result, "")
    }
}

// MARK: - Snooze expiry & path resolution

extension EspansoProcessManagerTests {

    func testRefreshClearsExpiredSnooze() async throws {
        let path = try makeFakeEspanso(script: "echo 'espanso is running'")
        let manager = EspansoProcessManager(espansoPath: path,
                                            preferences: makeIsolatedPreferences())
        defer { manager.cancelSnooze(reenable: false) }

        // Snooze that has already elapsed — as after a Mac sleeps through the
        // end date (Timer doesn't fire during system sleep).
        manager.snooze(until: Date(timeIntervalSinceNow: -60))
        XCTAssertNotNil(manager.snoozeUntil)

        await manager.refresh()
        XCTAssertNil(manager.snoozeUntil,
            "refresh() must clear a snooze whose end date has passed")
    }

    func testResolveMatchDirectoryTimesOutOnHungBinary() async throws {
        // exec → single process, so the deadline SIGKILL closes the pipe's
        // only write end and the reader sees EOF immediately.
        let path = try makeFakeEspanso(script: "exec sleep 8")
        let started = Date()
        let dir = await EspansoProcessManager.resolveMatchDirectory(
            espansoPath: path, timeout: 2)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 6,
            "a hung espanso binary must not block match-directory resolution")
        XCTAssertTrue(dir.path.hasSuffix("Library/Application Support/espanso/match"),
            "timeout must fall back to the default directory, got \(dir.path)")
    }
}

// MARK: - Expansion enable/disable
//
// espanso reports daemon liveness only: `espanso status` prints "espanso is running"
// whether or not expansion is enabled, and no `espanso cmd` subcommand queries it.
// Code that branched on a `.disabled` state therefore never took that branch, which
// made the menu toggle one-way and left an expiring snooze disabled forever. The
// paused state is tracked separately from the daemon log — see the extension below.

extension EspansoProcessManagerTests {

    /// A fake espanso that appends each invocation's arguments to `log`.
    private func makeRecordingEspanso(
        log: URL, statusOutput: String = "espanso is running"
    ) throws -> String {
        addTeardownBlock { try? FileManager.default.removeItem(at: log) }
        return try makeFakeEspanso(script: """
        echo "$@" >> \(log.path)
        echo '\(statusOutput)'
        """)
    }

    private func makeLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("espanso-calls-\(UUID().uuidString).log")
    }

    /// These commands run in detached Tasks, so poll rather than assuming ordering.
    private func waitForCall(_ needle: String, in log: URL, seconds: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let text = try? String(contentsOf: log, encoding: .utf8),
               text.contains(needle) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    func testCancelSnoozeReenablesExpansion() async throws {
        let log = makeLogURL()
        let manager = EspansoProcessManager(espansoPath: try makeRecordingEspanso(log: log),
                                            preferences: makeIsolatedPreferences())
        defer { manager.cancelSnooze(reenable: false) }

        manager.snooze(until: Date(timeIntervalSinceNow: 3600))
        let disabled = await waitForCall("cmd disable", in: log)
        XCTAssertTrue(disabled, "snoozing must disable expansion")

        manager.cancelSnooze(reenable: true)
        let reenabled = await waitForCall("cmd enable", in: log)
        XCTAssertTrue(reenabled,
            "an ending snooze must re-enable expansion; this cannot be guarded on a "
            + "disabled state, because espanso never reports one")
    }

    func testSetExpansionsSendsCommandRegardlessOfKnownState() async throws {
        let log = makeLogURL()
        let manager = EspansoProcessManager(espansoPath: try makeRecordingEspanso(log: log),
                                            preferences: makeIsolatedPreferences())
        // No refresh() yet, so state is .unknown — the old state-driven toggle sent
        // nothing at all here.
        XCTAssertEqual(manager.state, .unknown)

        manager.setExpansions(enabled: false)
        let disabled = await waitForCall("cmd disable", in: log)
        XCTAssertTrue(disabled)

        manager.setExpansions(enabled: true)
        let enabled = await waitForCall("cmd enable", in: log)
        XCTAssertTrue(enabled,
            "expansion must be re-enableable; the old toggle could only ever disable")
    }

    func testToggleExpansionsDelegatesToEspanso() async throws {
        let log = makeLogURL()
        let manager = EspansoProcessManager(espansoPath: try makeRecordingEspanso(log: log),
                                            preferences: makeIsolatedPreferences())
        manager.toggleExpansions()
        let toggled = await waitForCall("cmd toggle", in: log)
        XCTAssertTrue(toggled,
            "toggling without a readable state must let espanso do the flipping")
    }

    func testRunningDaemonWithExpansionDisabledStillReadsAsRunning() async throws {
        // Exactly what espanso 2.4.1 prints after `espanso cmd disable`.
        let path = try makeFakeEspanso(script: "echo 'espanso is running'")
        let manager = EspansoProcessManager(espansoPath: path,
                                            preferences: makeIsolatedPreferences())
        await manager.refresh()
        XCTAssertEqual(manager.state, .running,
            "status reports liveness only — there is no disabled state to detect")
    }

    func testStoppedDaemonIsParsed() async throws {
        let path = try makeFakeEspanso(script: "echo 'espanso is not running'")
        let manager = EspansoProcessManager(espansoPath: path,
                                            preferences: makeIsolatedPreferences())
        await manager.refresh()
        XCTAssertEqual(manager.state, .stopped)
    }
}

// MARK: - Paused-state tracking (daemon log)
//
// espanso has no query for the paused state, but its worker logs every
// expansion transition to the daemon log. These tests feed a real temp file
// through the same readLogTail path production uses.

extension EspansoProcessManagerTests {

    /// An empty daemon log, as espanso would have it before its first worker
    /// writes anything.
    private func makeDaemonLog() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("espanso-daemon-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func appendToLog(_ text: String, of url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func workerBanner(_ pid: Int) -> String {
        "23:08:25 [worker(\(pid))] [INFO] reading configs from: \"/tmp/espanso\"\n"
    }

    private func toggleLine(_ pid: Int, enabled: Bool) -> String {
        "14:41:48 [worker(\(pid))] [INFO] toggled enabled state, is_enabled = \(enabled)\n"
    }

    func testPausedStateTrackedFromDaemonLog() async throws {
        let log = makeDaemonLog()
        let path = try makeFakeEspanso(script: "echo 'espanso is running'")
        let manager = EspansoProcessManager(espansoPath: path,
                                            preferences: makeIsolatedPreferences(),
                                            logURL: log)

        await manager.refresh()
        XCTAssertNil(manager.expansionsPaused,
            "an empty log says nothing about expansion state")

        try appendToLog(workerBanner(43185), of: log)
        await manager.refresh()
        XCTAssertEqual(manager.expansionsPaused, false,
            "a worker that never toggled starts enabled")

        try appendToLog(toggleLine(43185, enabled: false), of: log)
        await manager.refresh()
        XCTAssertEqual(manager.expansionsPaused, true)

        try appendToLog(toggleLine(43185, enabled: true), of: log)
        await manager.refresh()
        XCTAssertEqual(manager.expansionsPaused, false)
    }

    func testPausedStateResetsWhenDaemonStops() async throws {
        let log = makeDaemonLog()
        let flag = FileManager.default.temporaryDirectory
            .appendingPathComponent("stopped-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: flag) }
        let path = try makeFakeEspanso(script: """
        if [ -f \(flag.path) ]; then
          echo 'espanso is not running'
        else
          echo 'espanso is running'
        fi
        """)
        let manager = EspansoProcessManager(espansoPath: path,
                                            preferences: makeIsolatedPreferences(),
                                            logURL: log)

        try appendToLog(workerBanner(43185) + toggleLine(43185, enabled: false), of: log)
        await manager.refresh()
        XCTAssertEqual(manager.state, .running)
        XCTAssertEqual(manager.expansionsPaused, true)

        FileManager.default.createFile(atPath: flag.path, contents: nil)
        await manager.refresh()
        XCTAssertEqual(manager.state, .stopped)
        XCTAssertNil(manager.expansionsPaused,
            "the paused state belongs to the worker; when the daemon dies it is unknown")
    }

    func testLogTruncationRescans() async throws {
        let log = makeDaemonLog()
        let path = try makeFakeEspanso(script: "echo 'espanso is running'")
        let manager = EspansoProcessManager(espansoPath: path,
                                            preferences: makeIsolatedPreferences(),
                                            logURL: log)

        try appendToLog(workerBanner(43185) + toggleLine(43185, enabled: false), of: log)
        await manager.refresh()
        XCTAssertEqual(manager.expansionsPaused, true)

        // Simulate espanso truncating or rotating the log down to a fresh
        // worker banner: the tracker must not merge the old state back in.
        try Data(workerBanner(99277).utf8).write(to: log)
        await manager.refresh()
        XCTAssertEqual(manager.expansionsPaused, false,
            "after truncation the log describes a fresh worker — enabled")
    }

    func testMissingLogKeepsStateUnknownAndRecovers() async throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).log")
        addTeardownBlock { try? FileManager.default.removeItem(at: log) }
        let path = try makeFakeEspanso(script: "echo 'espanso is running'")
        let manager = EspansoProcessManager(espansoPath: path,
                                            preferences: makeIsolatedPreferences(),
                                            logURL: log)

        await manager.refresh()
        XCTAssertEqual(manager.state, .running)
        XCTAssertNil(manager.expansionsPaused,
            "a log that does not exist must not fabricate state")

        // espanso creates the log when its daemon first starts; the tracker
        // must pick it up from then on.
        FileManager.default.createFile(atPath: log.path, contents: nil)
        try appendToLog(workerBanner(43185) + toggleLine(43185, enabled: false), of: log)
        await manager.refresh()
        XCTAssertEqual(manager.expansionsPaused, true)
    }

    func testPartialLogLineWaitsForItsNewline() async throws {
        let log = makeDaemonLog()
        let path = try makeFakeEspanso(script: "echo 'espanso is running'")
        let manager = EspansoProcessManager(espansoPath: path,
                                            preferences: makeIsolatedPreferences(),
                                            logURL: log)

        // A log that begins with a half-written line: nothing is known yet.
        try appendToLog("14:41:48 [worker(43185)] [INFO] toggled enabled state, is_enabled = fal", of: log)
        await manager.refresh()
        XCTAssertNil(manager.expansionsPaused,
            "a half-written line must not be consumed")

        try appendToLog("se\n", of: log)
        await manager.refresh()
        XCTAssertEqual(manager.expansionsPaused, true)
    }
}
