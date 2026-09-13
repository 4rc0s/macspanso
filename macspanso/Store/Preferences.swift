// macspanso/Store/Preferences.swift
import Foundation
import Combine

/// The single home for app preferences kept in `UserDefaults`.
///
/// Key strings are frozen: they predate this type, and existing users' values
/// must survive. Add new keys here rather than reaching for
/// `UserDefaults.standard` at a call site.
///
/// Deliberately *not* stored here:
/// - Launch at Login — `SMAppService.mainApp.status` is the source of truth and
///   is read live wherever it's shown (see `LoginItem`). A cached copy drifts
///   the moment the user flips it in System Settings.
/// - Global hotkeys — owned and persisted by the KeyboardShortcuts package
///   under its own keys.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    enum Key {
        static let snoozeUntil             = "macspanso.snoozeUntil"
        static let lastUpdateCheck         = "updateChecker.lastCheckDate"
        static let lastDestinationFilePath = "macspanso.lastDestinationFilePath"
        static let listSort                = "macspanso.listSort"
        static let listGrouped             = "macspanso.listGrouped"
        static let automaticUpdateChecks   = "macspanso.automaticUpdateChecks"
    }

    let defaults: UserDefaults

    /// Pass a throwaway suite in tests so they don't share `.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.automaticUpdateChecks: true,
            Key.listGrouped: true,
        ])
    }

    // MARK: - Settings the user controls

    /// Poll GitHub for a newer release on launch and every 24h. The manual
    /// "Check for Updates…" command ignores this.
    var automaticUpdateChecks: Bool {
        get { defaults.bool(forKey: Key.automaticUpdateChecks) }
        set { set(newValue, for: Key.automaticUpdateChecks) }
    }

    // MARK: - State the app remembers for itself

    /// End of an active snooze, restored on launch by `EspansoProcessManager`.
    var snoozeUntil: Date? {
        get { defaults.object(forKey: Key.snoozeUntil) as? Date }
        set { set(newValue, for: Key.snoozeUntil) }
    }

    var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheck) as? Date }
        set { set(newValue, for: Key.lastUpdateCheck) }
    }

    /// Path of the match file the editor last saved a new match into.
    var lastDestinationFilePath: String? {
        get { defaults.string(forKey: Key.lastDestinationFilePath) }
        set { set(newValue, for: Key.lastDestinationFilePath) }
    }

    /// Raw `MatchListSort` value. `MatchListView` binds this via `@AppStorage`
    /// using `Key.listSort`; the accessor exists so nothing else has to know
    /// the key.
    var listSortRaw: String? {
        get { defaults.string(forKey: Key.listSort) }
        set { set(newValue, for: Key.listSort) }
    }

    /// Whether the match list groups matches by file (default) or shows a
    /// flat list. `MatchListView` binds this via `@AppStorage` using `Key.listGrouped`.
    var listGrouped: Bool {
        get { defaults.bool(forKey: Key.listGrouped) }
        set { set(newValue, for: Key.listGrouped) }
    }

    // MARK: - Helpers

    private func set(_ value: Any?, for key: String) {
        objectWillChange.send()
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
