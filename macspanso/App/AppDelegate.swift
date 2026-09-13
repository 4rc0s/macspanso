// macspanso/App/AppDelegate.swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarController: MenuBarController?
    var configStore: EspansoConfigStore?
    var processManager: EspansoProcessManager?
    var updateChecker: UpdateChecker?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Resolve espanso's directories off the main thread (spawns `espanso path`),
        // then finish setup back on main. The runtime dir carries the daemon log
        // the paused-state tracker reads.
        Task { @MainActor in
            let paths = await EspansoProcessManager.resolveEspansoPaths()
            let store = EspansoConfigStore(matchDirectory: paths.match)
            let procMgr = EspansoProcessManager(logURL: paths.runtime)
            let checker = UpdateChecker()

            store.load()
            procMgr.startPolling()
            checker.startChecking()

            self.configStore = store
            self.processManager = procMgr
            self.updateChecker = checker
            self.menuBarController = MenuBarController(store: store, processManager: procMgr, updateChecker: checker)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        processManager?.stopPolling()
    }
}
