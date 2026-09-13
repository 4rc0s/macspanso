// macspansoTests/SettingsMenuItemTests.swift
import XCTest
import AppKit
@testable import macspanso

/// `MenuBarController.openSettings` finds the app menu's Settings item by its
/// ⌘, key equivalent, because SwiftUI localizes the title and renamed it in
/// macOS 13. These cover the matching rule against a synthetic app menu; the
/// real menu is SwiftUI's and can't be built in a test.
@MainActor
final class SettingsMenuItemTests: XCTestCase {

    private func item(title: String,
                      keyEquivalent: String,
                      modifiers: NSEvent.ModifierFlags = .command,
                      targeted: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        if targeted { item.target = self }
        return item
    }

    /// Shaped like the menu SwiftUI builds: About, separator, Settings, …
    private func appMenu(settings: NSMenuItem?) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(title: "About macspanso", keyEquivalent: "", modifiers: []))
        menu.addItem(.separator())
        if let settings { menu.addItem(settings) }
        menu.addItem(.separator())
        menu.addItem(item(title: "Quit macspanso", keyEquivalent: "q"))
        return menu
    }

    func testFindsTheSettingsItem() {
        let menu = appMenu(settings: item(title: "Settings…", keyEquivalent: ","))
        XCTAssertEqual(MenuBarController.settingsItemIndex(in: menu), 2)
    }

    func testFindsAnUnlocalizedOrRenamedTitle() {
        // macOS 12 called it "Preferences…"; other locales call it anything.
        let menu = appMenu(settings: item(title: "Réglages…", keyEquivalent: ","))
        XCTAssertEqual(MenuBarController.settingsItemIndex(in: menu), 2,
                       "the title must not be part of the match")
    }

    func testReturnsNilWhenAbsent() {
        XCTAssertNil(MenuBarController.settingsItemIndex(in: appMenu(settings: nil)),
                     "a missing item must be reported, not guessed at")
    }

    func testIgnoresAnUntargetedPlaceholder() {
        let menu = appMenu(settings: item(title: "Settings…", keyEquivalent: ",", targeted: false))
        XCTAssertNil(MenuBarController.settingsItemIndex(in: menu),
                     "an item with no target would perform nothing")
    }

    func testIgnoresOtherModifierCombinations() {
        let menu = appMenu(settings: item(title: "Something Else",
                                          keyEquivalent: ",",
                                          modifiers: [.command, .shift]))
        XCTAssertNil(MenuBarController.settingsItemIndex(in: menu))
    }

    func testMatchesTheFirstCandidateOnly() {
        let menu = appMenu(settings: item(title: "Settings…", keyEquivalent: ","))
        menu.addItem(item(title: "Decoy", keyEquivalent: ","))
        XCTAssertEqual(MenuBarController.settingsItemIndex(in: menu), 2)
    }
}
