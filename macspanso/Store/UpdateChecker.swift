// macspanso/Store/UpdateChecker.swift
import Foundation

/// Checks the GitHub Releases API for a newer version of macspanso.
/// Checks once on launch (if the last check was more than 24 hours ago) and
/// then once every 24 hours in the background.
@MainActor
final class UpdateChecker {

    // MARK: - Public state

    /// The latest version string from GitHub (e.g. "1.3.0"), if fetched.
    private(set) var latestVersion: String? = nil

    /// True when the fetched release version is newer than the running bundle.
    private(set) var updateAvailable: Bool = false

    /// Called on the main actor whenever `updateAvailable` or `latestVersion` changes.
    var onStateChange: (() -> Void)?

    // MARK: - Private

    /// 24 hours. Internal rather than private so `UpdateCheckerTests` can
    /// build its fixtures from the real value instead of restating it.
    static let checkInterval: TimeInterval = 86_400

    private static let releasesURL = URL(
        string: "https://api.github.com/repos/jeffcaldwellca/macspanso/releases/latest"
    )!

    /// Performs the HTTP request. The default is `URLSession.shared`; tests
    /// inject a stub so the gate logic can be exercised without the network.
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

    private let currentVersion: String
    private let preferences: Preferences
    private let fetch: Fetch
    private var timer: Timer?

    // MARK: - Init

    init(preferences: Preferences? = nil,
         currentVersion: String? = nil,
         fetch: Fetch? = nil) {
        // See EspansoProcessManager.init for why this isn't a default argument.
        self.preferences = preferences ?? .shared
        self.currentVersion = currentVersion
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "0.0.0"
        self.fetch = fetch ?? { try await URLSession.shared.data(for: $0) }
    }

    deinit { timer?.invalidate() }

    // MARK: - Public API

    /// Outcome of a single check, for user-facing feedback.
    enum CheckOutcome: Equatable {
        case updateAvailable(String)   // newer remote version
        case upToDate(String)          // current version is latest
        case failed                    // network / parse failure
    }

    /// Start automatic checking: fires immediately if stale, then every 24 h.
    /// Timers don't fire across system sleep, so callers should also invoke
    /// `checkIfStale()` at natural moments (e.g. when the menu opens).
    ///
    /// The timer always runs; each tick re-reads `automaticUpdateChecks`, so
    /// the Settings toggle takes effect without restarting the checker.
    func startChecking() {
        checkIfStale()
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.checkInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.preferences.automaticUpdateChecks else { return }
                _ = await self.fetchLatestRelease()
            }
        }
    }

    /// Fetch only if automatic checks are on and the last successful check is
    /// older than the interval. The manual `checkNow` bypasses both.
    func checkIfStale() {
        guard preferences.automaticUpdateChecks else { return }
        let lastCheck = preferences.lastUpdateCheck
        if lastCheck == nil || Date().timeIntervalSince(lastCheck!) >= Self.checkInterval {
            Task { _ = await fetchLatestRelease() }
        }
    }

    /// Trigger an immediate check (e.g. from the "Check for Updates" menu item)
    /// and report the outcome so the UI can show feedback instead of failing silently.
    func checkNow(completion: ((CheckOutcome) -> Void)? = nil) {
        Task {
            let outcome = await fetchLatestRelease()
            completion?(outcome)
        }
    }

    // MARK: - Fetch

    @discardableResult
    private func fetchLatestRelease() async -> CheckOutcome {
        var request = URLRequest(url: Self.releasesURL)
        request.setValue("application/vnd.github+json",  forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28",                   forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("macspanso/\(currentVersion)",  forHTTPHeaderField: "User-Agent")

        guard
            let (data, response) = try? await fetch(request),
            let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return .failed }

        preferences.lastUpdateCheck = Date()

        guard
            let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tagName  = json["tag_name"] as? String
        else { return .failed }

        let remote = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        let wasAvailable = updateAvailable
        let wasVersion   = latestVersion

        latestVersion    = remote
        updateAvailable  = isNewer(remote, than: currentVersion)

        if updateAvailable != wasAvailable || latestVersion != wasVersion {
            onStateChange?()
        }
        return updateAvailable ? .updateAvailable(remote) : .upToDate(currentVersion)
    }

    // MARK: - Version comparison

    /// Returns true when `remote` is strictly newer than `local` (semver, major.minor.patch).
    private func isNewer(_ remote: String, than local: String) -> Bool {
        let parts: (String) -> [Int] = {
            $0.split(separator: ".").compactMap { Int($0) }
        }
        let r = parts(remote)
        let l = parts(local)
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }
}
