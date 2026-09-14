// macspanso/Store/ExpansionStateParser.swift
import Foundation

/// Reconstructs espanso's expansion-enabled state from the daemon log.
///
/// espanso offers no query for the paused state: `espanso status` reports
/// daemon liveness only, and the IPC protocol (`espanso/src/ipc.rs`) exposes
/// just `EnableRequest`/`DisableRequest`/`ToggleRequest`. The worker does,
/// however, log every transition to the shared daemon log
/// (`<runtime>/espanso.log`). Verified against espanso v2.4.1
/// (`espanso-engine/src/process/middleware/disable.rs`):
///
///     info!("toggled enabled state, is_enabled = {}", *enabled);
///
/// The line fires on `EnableRequest`, `DisableRequest`, `ToggleRequest`, and
/// the built-in keyboard toggle — including no-ops, so every request produces
/// a line. The engine's `enabled` flag is in-memory and initialized `true` on
/// every worker start, and a fresh worker's first log line is always its
/// `reading configs from:` banner — that banner both marks the reset and
/// separates a real restart from a dead worker's late-flushed output.
///
/// The result feeds `EspansoProcessManager.expansionsPaused`, which is
/// display-only: commands must never branch on it (see the `setExpansions`
/// commentary for what branching on this state cost us the first time).
struct ExpansionStateParser {
    /// nil until some worker line has been seen; `true` = expansions paused.
    private(set) var paused: Bool?

    private var currentWorkerPID: Int?

    /// Feed lines in file order. Line-oriented: pass one `\n`-terminated
    /// line per call, without the newline.
    ///
    /// - Returns: whether the line changed the tracked state — a fresh
    ///   worker's banner or a toggle line from the current worker. Callers
    ///   use it to self-verify commands: any state change proves the log
    ///   channel is alive and speaking the expected format.
    @discardableResult
    mutating func consume(line rawLine: String) -> Bool {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        guard let pid = Self.workerPID(in: line) else { return false }

        if line.contains(Self.workerStartMarker) && pid != currentWorkerPID {
            // A fresh worker process: the engine (and its enabled flag) was
            // just created, so the state is *enabled* regardless of history.
            currentWorkerPID = pid
            paused = false
            return true
        } else if currentWorkerPID == nil {
            // First worker line in a log that may be truncated mid-session:
            // adopt the PID but stay unknown until a toggle line speaks.
            currentWorkerPID = pid
        }

        if let enabled = Self.toggleValue(in: line), pid == currentWorkerPID {
            paused = !enabled
            return true
        }
        return false
    }

    /// One-shot convenience: the paused state implied by a whole log.
    static func isPaused(lines: [String]) -> Bool? {
        var parser = ExpansionStateParser()
        for line in lines { parser.consume(line: line) }
        return parser.paused
    }

    // MARK: - Log shapes (pinned by ExpansionStateParserTests)

    private static let workerStartMarker = "reading configs from:"
    private static let toggleMarker = "toggled enabled state, is_enabled = "

    /// `… [worker(60383)] [INFO] toggled …` → 60383. Only `[worker(…)]`
    /// matches; the same banner text also appears in `[service(…)]` lines
    /// from `espanso status` runs and must not be mistaken for a worker.
    private static func workerPID(in line: Substring) -> Int? {
        guard let open = line.range(of: "[worker(") else { return nil }
        let afterOpen = line[open.upperBound...]
        guard let close = afterOpen.firstIndex(of: ")") else { return nil }
        return Int(afterOpen[..<close])
    }

    /// `toggled enabled state, is_enabled = true` → true.
    private static func toggleValue(in line: Substring) -> Bool? {
        guard let marker = line.range(of: toggleMarker) else { return nil }
        let value = line[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
}
