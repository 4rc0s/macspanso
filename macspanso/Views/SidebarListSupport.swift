// macspanso/Views/SidebarListSupport.swift
import AppKit
import SwiftUI

/// Selection arithmetic for the custom match list, shared by the grouped view
/// and the flat list. Pure so it can be unit-tested: views hand in the flat
/// display order and get back the new selection and anchor.
///
/// The list is laid out in plain SwiftUI (`ScrollView` + `VStack`) rather than
/// the stock `List`: on macOS 26 `List` is outline-backed and its internal row
/// map drifts from what is on screen — after a few selections the same visible
/// row selects different matches, group headers commit clicks meant for the
/// row below them, and the topmost row goes dead, while arrow keys (which read
/// the model rather than the hit geometry) keep working. Clicks ride SwiftUI's
/// own gesture machinery — the same path as the context menu, which never
/// misses — with modifiers read live off `NSEvent.modifierFlags`, which SwiftUI
/// tap gestures don't expose.
enum MatchListSelection {
    /// Plain click selects just the row; ⌘-click toggles it; ⇧-click extends
    /// from the selection anchor.
    enum Route { case replace, toggle, extend }

    /// The route for a click, from the modifier state at click time.
    static func route(fromModifiers flags: NSEvent.ModifierFlags) -> Route {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) { return .extend }
        if flags.contains(.command) { return .toggle }
        return .replace
    }

    /// Applies a row click. `order` is the selectable rows' display order;
    /// rows that can't be selected never reach this. Returns the id to scroll
    /// to, if any.
    static func handleClick(_ route: Route,
                            id: UUID,
                            order: [UUID],
                            anchor: inout UUID?,
                            selection: inout Set<UUID>) -> UUID? {
        switch route {
        case .replace:
            selection = [id]
            anchor = id
        case .toggle:
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
                anchor = id
            }
        case .extend:
            let from = anchor ?? selection.first
            guard let from, let a = order.firstIndex(of: from), let b = order.firstIndex(of: id) else {
                // Anchor not in the visible order (stale, or filtered out):
                // fall back to a plain select rather than doing nothing.
                selection = [id]
                anchor = id
                return id
            }
            let lo = min(a, b), hi = max(a, b)
            selection = Set(order[lo...hi])
        }
        return id
    }

    /// Applies an arrow-key move. Returns the id of the newly selected row, or
    /// nil when there is nothing to select. With no selection, down starts at
    /// the first row and up at the last — the standard outline behavior.
    static func handleMove(_ direction: MoveCommandDirection,
                           order: [UUID],
                           anchor: inout UUID?,
                           selection: inout Set<UUID>) -> UUID? {
        guard !order.isEmpty else { return nil }
        let currentIndex = selection.count == 1 ? order.firstIndex(of: selection.first!) : nil
        let nextIndex: Int
        switch direction {
        case .down:
            nextIndex = currentIndex.map { min($0 + 1, order.count - 1) } ?? 0
        case .up:
            nextIndex = currentIndex.map { max($0 - 1, 0) } ?? order.count - 1
        default:
            return nil
        }
        let id = order[nextIndex]
        selection = [id]
        anchor = id
        return id
    }
}
