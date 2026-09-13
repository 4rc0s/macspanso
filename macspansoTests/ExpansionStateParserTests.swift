// macspansoTests/ExpansionStateParserTests.swift
import XCTest
@testable import macspanso

/// Pins the reconstruction of espanso's expansion-enabled state from the
/// daemon log. Line shapes are copied from a live espanso 2.4.1 log; the
/// emitting site is `espanso-engine/src/process/middleware/disable.rs`.
final class ExpansionStateParserTests: XCTestCase {

    private func banner(_ pid: Int) -> String {
        "23:08:25 [worker(\(pid))] [INFO] reading configs from: \"/Users/gtc/Library/Application Support/espanso\""
    }

    private func toggle(_ pid: Int, enabled: Bool) -> String {
        "14:41:48 [worker(\(pid))] [INFO] toggled enabled state, is_enabled = \(enabled)"
    }

    func testFreshWorkerStartsEnabled() {
        XCTAssertEqual(ExpansionStateParser.isPaused(lines: [
            banner(43185),
            "23:08:25 [worker(43185)] [INFO] using CocoaAppInfoProvider",
            "23:08:25 [worker(43185)] [INFO] binded to IPC unix socket: /Users/gtc/Library/Caches/espanso/espansoworkerv2.sock",
        ]), false, "a worker that never toggled must read as enabled — the engine's flag is initialized true")
    }

    func testDisableToggleReadsAsPaused() {
        XCTAssertEqual(ExpansionStateParser.isPaused(lines: [
            banner(43185),
            toggle(43185, enabled: false),
        ]), true)
    }

    func testEnableAfterDisableReadsAsEnabled() {
        XCTAssertEqual(ExpansionStateParser.isPaused(lines: [
            banner(43185),
            toggle(43185, enabled: false),
            toggle(43185, enabled: true),
        ]), false)
    }

    func testNoOpEnableStillReportsEnabled() {
        // DisableMiddleware logs on every request, even when nothing changes —
        // so `espanso cmd enable` while already enabled still produces a line.
        XCTAssertEqual(ExpansionStateParser.isPaused(lines: [
            banner(43185),
            toggle(43185, enabled: true),
            toggle(43185, enabled: true),
        ]), false)
    }

    func testWorkerRestartResetsToEnabled() {
        XCTAssertEqual(ExpansionStateParser.isPaused(lines: [
            banner(43185),
            toggle(43185, enabled: false),
            banner(99277),
            "18:20:48 [worker(99277)] [INFO] using CocoaSource",
        ]), false, "the enabled flag is in-memory; a new worker process starts over at enabled")
    }

    func testToggleAfterRestartIsApplied() {
        XCTAssertEqual(ExpansionStateParser.isPaused(lines: [
            banner(43185),
            banner(99277),
            toggle(99277, enabled: false),
        ]), true)
    }

    func testLateToggleFromDeadWorkerIgnored() {
        // A dead worker's output can flush into the log after its successor
        // has started; it must not clobber the live worker's state.
        XCTAssertEqual(ExpansionStateParser.isPaused(lines: [
            banner(43185),
            toggle(43185, enabled: false),
            banner(99277),
            toggle(43185, enabled: false),
        ]), false, "a toggle attributed to a superseded worker PID is stale output")
    }

    func testToggleWithoutWorkerBannerAdoptsPID() {
        // A rotated/truncated log can begin mid-session; the first line seen
        // then speaks for its worker.
        XCTAssertEqual(ExpansionStateParser.isPaused(lines: [
            toggle(60383, enabled: false),
            "16:33:00 [worker(60383)] [INFO] secure input has been disabled",
        ]), true)
    }

    func testServiceLinesDoNotResetWorkerState() {
        // Every `espanso status` run logs the same "reading configs from:"
        // banner under [service(…)]; it must not impersonate a worker restart.
        let lines = [
            banner(43185),
            toggle(43185, enabled: false),
            "18:58:54 [service(10255)] [INFO] reading configs from: \"/Users/gtc/Library/Application Support/espanso\"",
            "18:58:54 [service(10255)] [INFO] system info: Darwin v26.6.2 - kernel: 25.6.0",
            "18:58:54 [service(10255)] [INFO] espanso is running",
        ]
        XCTAssertEqual(ExpansionStateParser.isPaused(lines: lines), true,
            "service chatter must not reset the tracked state to enabled")
        XCTAssertNil(ExpansionStateParser.isPaused(lines: [
            "18:58:54 [service(10255)] [INFO] reading configs from: \"/Users/gtc/Library/Application Support/espanso\"",
        ]), "a log with no worker lines says nothing about expansion state")
    }

    func testUnrelatedDisabledLinesIgnored() {
        // Both lines really appear in the log and both contain "disabled".
        XCTAssertNil(ExpansionStateParser.isPaused(lines: [
            "15:11:54 [worker(41500)] [INFO] stats recorder disabled by config",
            "16:33:00 [worker(56391)] [INFO] secure input has been disabled",
        ]), "lookalike lines must not fabricate expansion state")
    }

    func testEmptyAndGarbageYieldNil() {
        XCTAssertNil(ExpansionStateParser.isPaused(lines: []))
        XCTAssertNil(ExpansionStateParser.isPaused(lines: [
            "not a log line",
            "18:58:54 [worker] missing pid",
            "18:58:54 [worker(abc)] non-numeric pid",
        ]))
    }

    func testToggleWithUnparsedValueIgnored() {
        // If espanso ever changes the value's spelling, degrade to unknown
        // rather than to a guess when nothing else is known…
        XCTAssertNil(ExpansionStateParser.isPaused(lines: [
            "14:41:48 [worker(43185)] [INFO] toggled enabled state, is_enabled = yes",
        ]))
        // …and otherwise keep the previously known state in place.
        XCTAssertEqual(ExpansionStateParser.isPaused(lines: [
            banner(43185),
            "14:41:48 [worker(43185)] [INFO] toggled enabled state, is_enabled = yes",
        ]), false)
    }

    func testIncrementalConsumptionMatchesWholeFile() {
        // The manager feeds a retained parser as bytes arrive; the same state
        // must come out as a one-shot scan of the whole log.
        let lines = [
            banner(43185),
            toggle(43185, enabled: false),
            banner(99277),
            toggle(99277, enabled: true),
        ]
        var parser = ExpansionStateParser()
        for line in lines { parser.consume(line: line) }
        XCTAssertEqual(parser.paused, ExpansionStateParser.isPaused(lines: lines))
        XCTAssertEqual(parser.paused, false)
    }
}
