// macspansoTests/MatchListSelectionTests.swift
import XCTest
@testable import macspanso

/// The custom match list's selection arithmetic: plain click replaces, ⌘-click
/// toggles, ⇧-click extends from the anchor, and arrows walk the visible
/// order. The views hand in the flat display order; everything here is pure.
final class MatchListSelectionTests: XCTestCase {

    private var ids: [UUID]!
    private var a: UUID! { ids[0] }
    private var b: UUID! { ids[1] }
    private var c: UUID! { ids[2] }
    private var d: UUID! { ids[3] }

    override func setUp() {
        super.setUp()
        ids = (0..<4).map { _ in UUID() }
    }

    // MARK: - Clicks

    func testRouteFromModifiers() {
        XCTAssertEqual(MatchListSelection.route(fromModifiers: []),
                       .replace, "a bare click replaces the selection")
        XCTAssertEqual(MatchListSelection.route(fromModifiers: [.command]),
                       .toggle)
        XCTAssertEqual(MatchListSelection.route(fromModifiers: [.shift]),
                       .extend)
        XCTAssertEqual(MatchListSelection.route(fromModifiers: [.command, .shift]),
                       .extend, "⇧ wins when combined with ⌘, matching outline views")
        XCTAssertEqual(MatchListSelection.route(fromModifiers: [.control]),
                       .replace, "unrelated modifiers don't change the route")
    }

    func testPlainClickReplacesSelectionAndMovesAnchor() {
        var selection: Set<UUID> = [c]
        var anchor: UUID? = c
        MatchListSelection.handleClick(.replace, id: a, order: ids,
                                       anchor: &anchor, selection: &selection)
        XCTAssertEqual(selection, [a])
        XCTAssertEqual(anchor, a)
    }

    func testCommandClickTogglesOff() {
        var selection: Set<UUID> = [a, c]
        var anchor: UUID? = a
        MatchListSelection.handleClick(.toggle, id: a, order: ids,
                                       anchor: &anchor, selection: &selection)
        XCTAssertEqual(selection, [c])
    }

    func testCommandClickTogglesOnAndMovesAnchor() {
        var selection: Set<UUID> = [a]
        var anchor: UUID? = a
        MatchListSelection.handleClick(.toggle, id: c, order: ids,
                                       anchor: &anchor, selection: &selection)
        XCTAssertEqual(selection, [a, c])
        XCTAssertEqual(anchor, c, "the anchor follows the row just added")
    }

    func testShiftClickExtendsFromAnchorInclusive() {
        var selection: Set<UUID> = [a]
        var anchor: UUID? = a
        MatchListSelection.handleClick(.extend, id: c, order: ids,
                                       anchor: &anchor, selection: &selection)
        XCTAssertEqual(selection, [a, b, c])
        XCTAssertEqual(anchor, a, "⇧-click does not move the anchor")
    }

    func testShiftClickExtendsBackwardsFromAnchor() {
        var selection: Set<UUID> = [c]
        var anchor: UUID? = c
        MatchListSelection.handleClick(.extend, id: a, order: ids,
                                       anchor: &anchor, selection: &selection)
        XCTAssertEqual(selection, [a, b, c])
    }

    func testShiftClickWithAnchorMissingFromOrderFallsBackToPlainSelect() {
        // The anchor can go stale: the row it named may be filtered out by the
        // search box or removed by an external edit between clicks.
        var selection: Set<UUID> = [a]
        var anchor: UUID? = UUID() // not in order
        MatchListSelection.handleClick(.extend, id: c, order: ids,
                                       anchor: &anchor, selection: &selection)
        XCTAssertEqual(selection, [c])
        XCTAssertEqual(anchor, c)
    }

    // MARK: - Arrow moves

    func testDownFromNothingSelectsFirstRow() {
        var selection: Set<UUID> = []
        var anchor: UUID?
        let moved = MatchListSelection.handleMove(.down, order: ids,
                                                  anchor: &anchor, selection: &selection)
        XCTAssertEqual(moved, a)
        XCTAssertEqual(selection, [a])
    }

    func testUpFromNothingSelectsLastRow() {
        var selection: Set<UUID> = []
        var anchor: UUID?
        let moved = MatchListSelection.handleMove(.up, order: ids,
                                                  anchor: &anchor, selection: &selection)
        XCTAssertEqual(moved, d)
    }

    func testDownClampsAtTheLastRow() {
        var selection: Set<UUID> = [d]
        var anchor: UUID? = d
        let moved = MatchListSelection.handleMove(.down, order: ids,
                                                  anchor: &anchor, selection: &selection)
        XCTAssertEqual(moved, d)
        XCTAssertEqual(selection, [d])
    }

    func testUpWalksBackwardsOneRow() {
        var selection: Set<UUID> = [c]
        var anchor: UUID? = c
        let moved = MatchListSelection.handleMove(.up, order: ids,
                                                  anchor: &anchor, selection: &selection)
        XCTAssertEqual(moved, b)
        XCTAssertEqual(selection, [b])
    }

    func testMoveWithMultiSelectionWalksFromNothing() {
        // A multi-selection gives no single "current" row; down starts at the
        // top rather than guessing a direction from the set.
        var selection: Set<UUID> = [b, d]
        var anchor: UUID? = nil
        let moved = MatchListSelection.handleMove(.down, order: ids,
                                                  anchor: &anchor, selection: &selection)
        XCTAssertEqual(moved, a)
        XCTAssertEqual(selection, [a])
    }

    func testMoveWithEmptyOrderIsANoOp() {
        var selection: Set<UUID> = []
        var anchor: UUID?
        let moved = MatchListSelection.handleMove(.down, order: [],
                                                  anchor: &anchor, selection: &selection)
        XCTAssertNil(moved)
        XCTAssertTrue(selection.isEmpty)
    }
}
