// macspanso/App/macspansoApp.swift
import SwiftUI

@main
struct macspansoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No main window — menu bar only; LSUIElement suppresses the Dock icon.
        // The Settings scene is real: it backs ⌘, and the status menu's
        // "Settings…" item (opened via showSettingsWindow:).
        Settings { SettingsView() }
    }
}
