// macspansoTests/MatchManagerSummonToggleTests.swift
import XCTest
@testable import macspanso

/// The summon shortcut toggles the Match Manager: a second press while the
/// window is frontmost dismisses it. The decision core is
/// `MenuBarController.shouldDismiss(appIsActive:windowIsVisible:isKeyOrMain:)`,
/// kept pure so the whole summon/dismiss matrix can be pinned without real
/// window or application activation state. The convention being pinned is the
/// standard macOS summoner behavior (Spotlight, Raycast, terminal visors): an
/// open but backgrounded window is summoned forward first, never dismissed by
/// a press aimed at it.
final class MatchManagerSummonToggleTests: XCTestCase {

    /// Another app is active; the manager sits open in the background. The
    /// press must summon it forward, not dismiss it.
    func testInBackgroundWindowDoesNotDismiss() {
        XCTAssertFalse(MenuBarController.shouldDismiss(
            appIsActive: false, windowIsVisible: true, isKeyOrMain: true))
    }

    /// No window exists yet (never opened, or closed earlier) — open it.
    func testNoWindowDoesNotDismiss() {
        XCTAssertFalse(MenuBarController.shouldDismiss(
            appIsActive: true, windowIsVisible: false, isKeyOrMain: false))
        XCTAssertFalse(MenuBarController.shouldDismiss(
            appIsActive: false, windowIsVisible: false, isKeyOrMain: false))
    }

    /// The app is active but the manager window is not frontmost (the Settings
    /// window or a sheet elsewhere holds key) — summon the manager forward.
    func testAppActiveButWindowNotKeyDoesNotDismiss() {
        XCTAssertFalse(MenuBarController.shouldDismiss(
            appIsActive: true, windowIsVisible: true, isKeyOrMain: false))
    }

    /// App active, window visible and key: the dismissal case.
    func testFrontmostWindowDismisses() {
        XCTAssertTrue(MenuBarController.shouldDismiss(
            appIsActive: true, windowIsVisible: true, isKeyOrMain: true))
    }
}

/// A real window close must run the same teardown the close button and Cmd+W
/// do: `willCloseNotification` fires (MenuBarController tears the controller
/// down and reverts the activation policy on it) and the window stops being
/// visible. The controller is created with real dependencies against a temp
/// match directory, mirroring how the other MainActor suites build state.
@MainActor
final class MatchManagerWindowCloseTests: XCTestCase {

    func testClosePostsWillCloseNotificationAndHidesWindow() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = EspansoConfigStore(matchDirectory: tmp)
        let processManager = EspansoProcessManager(espansoPath: "/usr/bin/false")
        let wc = MatchManagerWindowController(store: store, processManager: processManager)
        let window = try XCTUnwrap(wc.window)

        window.orderFront(nil)
        XCTAssertTrue(window.isVisible)

        var notified = false
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { _ in notified = true }

        window.close()

        XCTAssertEqual(notified, true)
        XCTAssertEqual(window.isVisible, false)
        NotificationCenter.default.removeObserver(token)
    }
}
