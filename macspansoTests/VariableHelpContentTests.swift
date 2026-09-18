// macspansoTests/VariableHelpContentTests.swift
import XCTest
@testable import macspanso

final class VariableHelpContentTests: XCTestCase {

    /// Every documented type must have an `id="var-…"` section in the HTML, so a
    /// type added to `documentedTypes` without a section (or renamed) can't ship
    /// a help button that opens the reference showing nothing. `.match` is
    /// deliberately absent — espanso has no such extension — and its absence is
    /// pinned separately below.
    func testEveryDocumentedTypeHasAnAnchorSection() {
        for type in VariableHelpContent.documentedTypes {
            let anchor = VariableHelpContent.anchor(for: type)
            XCTAssertNotNil(anchor, "\(type.rawValue) has no anchor")
            XCTAssertTrue(
                VariableHelpContent.html.contains("id=\"\(anchor!)\""),
                "HTML has no section with id \(anchor!) for \(type.rawValue)"
            )
        }
    }

    /// `match` is offered in the type picker but has no espanso extension behind
    /// it, so it must not claim a help section.
    func testMatchTypeHasNoHelpAnchor() {
        XCTAssertNil(VariableHelpContent.anchor(for: .match))
        XCTAssertFalse(VariableHelpContent.html.contains("id=\"var-match\""))
    }

    /// Unknown types (espanso added after this build) get no help button either.
    func testUnknownTypeHasNoHelpAnchor() {
        XCTAssertNil(VariableHelpContent.anchor(for: .unknown("widget")))
    }

    /// A type documented but missing from `VarType.known` would give a help
    /// button nothing to open for; keep the two lists in step.
    func testDocumentedTypesAreAKnownSubset() {
        for type in VariableHelpContent.documentedTypes {
            XCTAssertTrue(VarType.known.contains(type),
                          "\(type.rawValue) documented but not in VarType.known")
        }
        // Everything known except `match` should be documented — a new VarType
        // case fails here until someone decides whether it gets a help section.
        for type in VarType.known where type != .match {
            XCTAssertTrue(VariableHelpContent.documentedTypes.contains(type),
                          "\(type.rawValue) is a known type with no help section")
        }
    }
}
