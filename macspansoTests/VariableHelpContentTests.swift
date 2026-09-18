// macspansoTests/VariableHelpContentTests.swift
import XCTest
@testable import macspanso

final class VariableHelpContentTests: XCTestCase {

    /// Every documented type must have an `id="var-…"` section in the HTML, so a
    /// type added to `documentedTypes` without a section (or renamed) can't ship
    /// a help button that opens the reference showing nothing.
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

    /// `match` is documented from espanso's Nested Matches docs and the
    /// renderer's special-case in espanso-render/src/renderer/mod.rs — it has
    /// no extension source file, but it is real and deserves its section.
    func testMatchTypeHasHelpAnchor() {
        XCTAssertEqual(VariableHelpContent.anchor(for: .match), "var-match")
        XCTAssertTrue(VariableHelpContent.html.contains("id=\"var-match\""))
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
        // Everything known must be documented — a new VarType case fails here
        // until someone decides whether it gets a help section.
        for type in VarType.known {
            XCTAssertTrue(VariableHelpContent.documentedTypes.contains(type),
                          "\(type.rawValue) is a known type with no help section")
        }
    }
}
