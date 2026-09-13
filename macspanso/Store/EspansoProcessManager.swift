// macspanso/Store/EspansoProcessManager.swift
import Foundation
import Combine

@MainActor
final class EspansoProcessManager: ObservableObject {
    /// What `espanso status` can actually report. There is deliberately no
    /// `disabled` case: `espanso status` is documented as "Check if the espanso
    /// daemon is running or not" and prints "espanso is running" whether or not
    /// expansion is enabled. No `espanso cmd` subcommand queries that state either,
    /// so a `disabled` case could never be reached — see `setExpansions(enabled:)`.
    /// The paused state is tracked separately, display-only, in `expansionsPaused`.
    enum DaemonState: Equatable {
        case running        // daemon is running; expansion may be enabled or not
        case stopped        // espanso daemon is not running
        case notInstalled   // espanso binary not found in PATH
        case unknown
    }

    @Published var state: DaemonState = .unknown

    /// Whether espanso's expansion engine is paused (`cmd disable`/`toggle`),
    /// reconstructed from the daemon log by `ExpansionStateParser`; nil when
    /// unknown. Display-only — commands must never branch on this (that is
    /// exactly what made the old `DaemonState.disabled` unreachable), because
    /// the reconstruction depends on log shapes that are not a contract.
    @Published private(set) var expansionsPaused: Bool?

    /// Non-nil while a snooze is active; the user has temporarily disabled expansion
    /// and we'll re-enable at this date. Persists across app launches via `Preferences`.
    @Published private(set) var snoozeUntil: Date?

    private var pollTimer: Timer?
    private var snoozeTimer: Timer?
    let espansoPath: String
    private let preferences: Preferences

    /// espanso's daemon log (`<runtime>/espanso.log`) — the only readable
    /// channel for the paused state. Resolved by the caller from
    /// `resolveEspansoPaths()`; nil disables tracking.
    private let logURL: URL?

    private var logParser = ExpansionStateParser()
    private var logOffset: UInt64 = 0
    private var pendingLogBytes: [UInt8] = []

    /// Pass a custom `espansoPath` for testing; leave nil to auto-locate via
    /// Homebrew / PATH. Pass `preferences` backed by a throwaway suite so tests
    /// don't share persisted snooze state. Pass `logURL` to point the paused-
    /// state tracker at a specific daemon log (tests use a temp file).
    init(espansoPath: String? = nil, preferences: Preferences? = nil, logURL: URL? = nil) {
        let path = espansoPath ?? EspansoProcessManager.locateEspanso() ?? ""
        self.espansoPath = path
        self.logURL = logURL
        // Resolved here rather than as a default argument: default arguments
        // are evaluated outside the actor, and `shared` is main-actor bound.
        self.preferences = preferences ?? .shared
        if path.isEmpty { state = .notInstalled }
        restorePersistedSnooze()
    }

    // MARK: - Lifecycle

    func startPolling() {
        guard !espansoPath.isEmpty else { return }
        Task { await refresh() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Commands

    /// Refreshes daemon state by running `espanso status` off the main thread,
    /// and tails the daemon log for expansion enable/disable transitions.
    // Verified against espanso v2.4.1 output ("espanso is running" / "espanso is
    // not running"). Check if these strings change on upgrade.
    func refresh() async {
        // Timers don't fire during system sleep, so a snooze can outlive its end
        // date — the poll is the reliable place to notice and re-enable.
        if let end = snoozeUntil, end <= Date() {
            cancelSnooze(reenable: true)
        }
        readLogTail()
        let output = await run("status")
        let lower = output.lowercased()
        if lower.contains("not running") || lower.contains("stopped") {
            state = .stopped
            // The worker died, and its in-memory enabled state died with it.
            expansionsPaused = nil
        } else if lower.contains("running") {
            // "not running" checked above, so this is safe
            state = .running
            // Catch transitions logged while the status subprocess ran —
            // including a restarted worker's banner, which resets the state.
            readLogTail()
        } else {
            state = .unknown
        }
    }

    // MARK: - Paused-state tracking (daemon log)

    /// Feeds new daemon-log bytes to `logParser`. The first call scans the
    /// whole file (small — a few MB at most); later calls read from the last
    /// offset. Runs synchronously on the main actor every poll tick; the
    /// incremental reads keep that negligible after the first scan.
    private func readLogTail() {
        guard let logURL else { return }
        guard let handle = try? FileHandle(forReadingFrom: logURL) else {
            // No log file (fresh install, or the runtime dir was purged).
            // Nothing to know until espanso writes one.
            resetLogTracking()
            return
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < logOffset {
            // Truncated or rotated: earlier bytes are gone. A rescan of what
            // remains can only see a newer slice of history — a fresh parser
            // keeps that from being merged into stale state.
            resetLogTracking()
        }
        guard size > logOffset else { return }
        try? handle.seek(toOffset: logOffset)
        let data = (try? handle.readDataToEndOfFile()) ?? Data()
        if !data.isEmpty {
            logOffset = size
            applyLogData(data)
        }
    }

    private func resetLogTracking() {
        logOffset = 0
        pendingLogBytes = []
        logParser = ExpansionStateParser()
        expansionsPaused = nil
    }

    private func applyLogData(_ data: Data) {
        guard !data.isEmpty else { return }
        pendingLogBytes.append(contentsOf: data)
        // Consume only complete lines; a partial trailing line waits for its
        // newline (the log line is meaningless half-written).
        while let newline = pendingLogBytes.firstIndex(of: UInt8(0x0A)) {
            let lineData = Data(pendingLogBytes[..<newline])
            pendingLogBytes.removeSubrange(...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                logParser.consume(line: line)
            }
        }
        expansionsPaused = logParser.paused
    }

    /// Turn text expansion on or off (the daemon keeps running).
    ///
    /// This takes an explicit value rather than reading `state` and flipping it:
    /// espanso never reports whether expansion is enabled, so a state-driven
    /// toggle always took the same branch and could only ever disable.
    func setExpansions(enabled: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await run("cmd", enabled ? "enable" : "disable")
            await refresh()
        }
    }

    /// Flip expansion without knowing its current state — espanso's own
    /// `cmd toggle` does the flipping, which is the only correct way to express
    /// "toggle" when the state can't be queried.
    func toggleExpansions() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await run("cmd", "toggle")
            await refresh()
        }
    }

    // MARK: - Snooze

    enum SnoozeDuration {
        case minutes(Int)
        case hours(Int)
        case untilTomorrow

        var endDate: Date {
            switch self {
            case .minutes(let n):
                return Date().addingTimeInterval(TimeInterval(n) * 60)
            case .hours(let n):
                return Date().addingTimeInterval(TimeInterval(n) * 3600)
            case .untilTomorrow:
                let cal = Calendar.current
                let tomorrowStart = cal.startOfDay(for: Date().addingTimeInterval(86400))
                // Default to 8 AM tomorrow rather than midnight so the user wakes up
                // with espanso ready, not active overnight.
                return cal.date(byAdding: .hour, value: 8, to: tomorrowStart) ?? tomorrowStart
            }
        }

        var label: String {
            switch self {
            case .minutes(let n):  return "\(n) minutes"
            case .hours(let n):    return n == 1 ? "1 hour" : "\(n) hours"
            case .untilTomorrow:   return "Until tomorrow"
            }
        }
    }

    func snooze(for duration: SnoozeDuration) {
        snooze(until: duration.endDate)
    }

    func snooze(until end: Date) {
        snoozeUntil = end
        preferences.snoozeUntil = end
        scheduleSnoozeTimer()
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Unconditional for the same reason as cancelSnooze: gating on `.running`
            // meant a snooze started before the first poll (state `.unknown`) showed
            // "Snoozed until…" while espanso kept expanding.
            await run("cmd", "disable")
            await refresh()
        }
    }

    func cancelSnooze(reenable: Bool = true) {
        snoozeUntil = nil
        preferences.snoozeUntil = nil
        snoozeTimer?.invalidate()
        snoozeTimer = nil
        if reenable {
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Unconditional: espanso can't tell us whether expansion is off, and
                // enabling an already-enabled espanso is a no-op. Guarding this on a
                // state that is never reported is what made snooze one-way.
                await run("cmd", "enable")
                await refresh()
            }
        }
    }

    private func scheduleSnoozeTimer() {
        snoozeTimer?.invalidate()
        guard let end = snoozeUntil else { return }
        let delay = max(1, end.timeIntervalSinceNow)
        snoozeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.cancelSnooze(reenable: true) }
        }
    }

    private func restorePersistedSnooze() {
        guard let stored = preferences.snoozeUntil else { return }
        if stored > Date() {
            snoozeUntil = stored
            scheduleSnoozeTimer()
        } else {
            // Snooze elapsed while the app was closed — clear silently.
            preferences.snoozeUntil = nil
        }
    }

    func restart() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await run("restart")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await refresh()
        }
    }

    // MARK: - Helpers

    /// Runs an espanso command off the main thread and returns its combined stdout+stderr.
    @discardableResult
    nonisolated func run(_ args: String...) async -> String {
        let path = espansoPath
        return await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = args
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do {
                try proc.run()
            } catch {
                // Launch failed: return before touching the pipe. Our process
                // still holds its write end, so a read would never see EOF.
                return ""
            }
            // Drain to EOF *before* waiting: output beyond the ~64 KB pipe
            // buffer would otherwise block the child and deadlock both sides.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }

    nonisolated private static func locateEspanso() -> String? {
        let candidates = [
            "/opt/homebrew/bin/espanso",
            "/usr/local/bin/espanso",
            "/usr/bin/espanso",
        ]
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return found
        }
        // Uncommon install paths: fall back to `which` (synchronous, but only
        // runs once at launch, only if no Homebrew path is found).
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["espanso"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        do {
            try proc.run()
        } catch {
            return nil
        }
        // Read before waiting — see run(_:) for why this order matters.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    /// Discover espanso's directories by running `espanso path`. The runtime
    /// directory carries the daemon log that the paused-state tracker reads.
    /// Falls back to the known macOS default if espanso is absent, the output
    /// is unparseable, or the binary doesn't answer within `timeout`.
    static func resolveEspansoPaths(
        espansoPath: String? = nil,
        timeout: TimeInterval = 3
    ) async -> (match: URL, runtime: URL?) {
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/espanso/match")

        guard let espanso = espansoPath ?? locateEspanso() else { return (defaultPath, nil) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: espanso)
        proc.arguments = ["path"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        do {
            try proc.run()
        } catch {
            return (defaultPath, nil)
        }
        let pid = proc.processIdentifier

        // Race the read against the deadline. On timeout, kill the child so the
        // reader sees EOF and the group can finish — a task group cannot return
        // while a child is still blocked in read().
        let output: String = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                return String(data: data, encoding: .utf8) ?? ""
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return nil }
                kill(pid, SIGKILL)
                return nil
            }
            var result = ""
            for await value in group {
                if let value { result = value }
                group.cancelAll()   // reader won → stop the sleeper promptly
            }
            return result
        }

        // espanso path output (v2.x):
        //   Config:   /Users/jeff/Library/Application Support/espanso
        //   Packages: ...
        //   Runtime:  /Users/jeff/Library/Caches/espanso
        //   Data:     ...
        // Prefer a "Match:" line if espanso ever emits one; fall back to Config: + /match.
        func value(ofKey key: String, in trimmed: String) -> String? {
            guard trimmed.hasPrefix(key) else { return nil }
            let v = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }
        var matchPath: String?
        var configPath: String?
        var runtimePath: String?
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let v = value(ofKey: "Match:", in: trimmed) { matchPath = v }
            else if let v = value(ofKey: "Config:", in: trimmed) { configPath = v }
            else if let v = value(ofKey: "Runtime:", in: trimmed) { runtimePath = v }
        }

        let match: URL
        if let matchPath {
            match = URL(fileURLWithPath: matchPath)
        } else if let configPath {
            match = URL(fileURLWithPath: configPath).appendingPathComponent("match")
        } else {
            match = defaultPath
        }
        let runtimeLog = runtimePath.map {
            URL(fileURLWithPath: $0).appendingPathComponent("espanso.log")
        }
        return (match, runtimeLog)
    }

    static func resolveMatchDirectory(
        espansoPath: String? = nil,
        timeout: TimeInterval = 3
    ) async -> URL {
        await resolveEspansoPaths(espansoPath: espansoPath, timeout: timeout).match
    }
}
