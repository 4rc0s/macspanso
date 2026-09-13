// macspanso/App/LoginItem.swift
import AppKit
import ServiceManagement

/// Launch-at-login state, shared by the status menu and Settings → General.
///
/// `SMAppService.mainApp.status` is the only source of truth: the user can
/// flip this in System Settings › Login Items at any time, so nothing here is
/// ever cached in `Preferences`. Call `refresh()` whenever the value is about
/// to be shown.
///
/// One instance on purpose. Two would each read the system truthfully but
/// never see each other's changes: toggling from the status menu while the
/// Settings window is frontmost doesn't deactivate the app, so the view's
/// refresh hooks never fire and its toggle stays stale. Sharing the instance
/// lets the menu's `refresh()` publish to the view as well.
@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    @Published private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    @Published private(set) var lastError: String?

    var isEnabled: Bool { status == .enabled }

    /// macOS accepted the registration but is waiting for the user to approve
    /// it in System Settings — the toggle should read as off with a hint.
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            NSLog("Launch at login toggle failed: %@", error.localizedDescription)
        }
        refresh()
    }

    func toggle() {
        refresh()
        setEnabled(!isEnabled)
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
