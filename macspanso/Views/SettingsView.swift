// macspanso/Views/SettingsView.swift
import SwiftUI
import KeyboardShortcuts

/// Content of the app's `Settings` scene (see macspansoApp), which gives ⌘,,
/// toolbar-style tabs, and frame autosave for free. The status menu opens the
/// same window via `showSettingsWindow:` — see `MenuBarController.openSettings`.
///
/// Everything here reaches its state through singletons or system APIs on
/// purpose: a `Settings` scene can't be handed dependencies. The one control
/// that needs an app object (the update-check toggle) goes through
/// `AppDelegate`, which already exposes the checker.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutsSettingsTab()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 460)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject private var preferences = Preferences.shared
    @StateObject private var loginItem = LoginItem()

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: launchAtLogin)
                if loginItem.requiresApproval {
                    HStack(alignment: .firstTextBaseline) {
                        Text("macOS is waiting for you to approve this in Login Items.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items…") { LoginItem.openSystemSettings() }
                    }
                }
                if let error = loginItem.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Toggle("Check for updates automatically", isOn: automaticUpdateChecks)
            } footer: {
                Text("Checks GitHub once a day. “Check for Updates…” in the menu bar always works.")
            }
        }
        .formStyle(.grouped)
        // A change made in System Settings shows up the next time the user
        // comes back to this window.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
        .onAppear { loginItem.refresh() }
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.setEnabled($0) }
        )
    }

    private var automaticUpdateChecks: Binding<Bool> {
        Binding(
            get: { preferences.automaticUpdateChecks },
            set: { enabled in
                preferences.automaticUpdateChecks = enabled
                // Don't leave the user waiting up to a day after turning it on.
                if enabled {
                    (NSApp.delegate as? AppDelegate)?.updateChecker?.checkIfStale()
                }
            }
        )
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettingsTab: View {
    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Open Match Manager:", name: .openManager)
                KeyboardShortcuts.Recorder("New Match:", name: .newMatch)
            } footer: {
                Text("These work from any app while macspanso is running and need no Accessibility permission. Clear one to disable it.")
            }

            Section {
                Button("Reset to Defaults") {
                    KeyboardShortcuts.reset(.openManager, .newMatch)
                }
            }
        }
        .formStyle(.grouped)
    }
}
