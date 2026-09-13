// macspanso/App/Shortcuts.swift
import KeyboardShortcuts

/// The app's system-wide hotkeys. KeyboardShortcuts owns registration (via
/// Carbon, so no Accessibility permission is needed) and persistence (in
/// UserDefaults under its own keys); the user changes them in Settings →
/// Shortcuts. The `initial` values sit beside espanso's own ⌃⇧Space without
/// colliding with system or common app shortcuts.
///
/// A registered combo is consumed system-wide for as long as macspanso runs;
/// if another app claims the same combo, whichever registered last wins.
extension KeyboardShortcuts.Name {
    /// Open the Match Manager.
    static let openManager = Self("openManager", initial: .init(.m, modifiers: [.control, .shift]))
    /// Open the Match Manager on a new-match draft.
    static let newMatch    = Self("newMatch",    initial: .init(.n, modifiers: [.control, .shift]))
}
