// macspansoTests/MatchValidationTests.swift
import XCTest
@testable import macspanso

final class MatchValidationTests: XCTestCase {

    func testEmptyTriggerIsInvalid() {
        let match = EspansoMatch(trigger: "", replace: "Hello")
        let errors = MatchValidator.validate(match, existingMatches: [])
        XCTAssertTrue(errors.contains(.emptyTrigger))
    }

    func testDuplicateTriggerIsInvalid() {
        let existing = [EspansoMatch(trigger: "::hello", replace: "Hi")]
        let duplicate = EspansoMatch(trigger: "::hello", replace: "Howdy")
        let errors = MatchValidator.validate(duplicate, existingMatches: existing)
        XCTAssertTrue(errors.contains(.duplicateTrigger))
    }

    func testSameTriggerOnSameMatchIsNotDuplicate() {
        // Editing an existing match — its own trigger should not count as a duplicate
        let match = EspansoMatch(id: UUID(), trigger: "::hello", replace: "Hi")
        let errors = MatchValidator.validate(match, existingMatches: [match])
        XCTAssertFalse(errors.contains(.duplicateTrigger))
    }

    func testUnresolvedVarReference() {
        let match = EspansoMatch(trigger: "::date", replace: "{{mydate}}")
        // No vars declared — {{mydate}} is unresolved
        let errors = MatchValidator.validate(match, existingMatches: [])
        XCTAssertTrue(errors.contains(.unresolvedVarReference("mydate")))
    }

    func testResolvedVarReferenceIsValid() {
        let match = EspansoMatch(
            trigger: "::date",
            replace: "{{d}}",
            vars: [EspansoVar(name: "d", type: .date)]
        )
        let errors = MatchValidator.validate(match, existingMatches: [])
        XCTAssertFalse(errors.contains(.unresolvedVarReference("d")))
    }

    func testDuplicateVarNameIsInvalid() {
        let match = EspansoMatch(
            trigger: "::test",
            replace: "{{a}}",
            vars: [
                EspansoVar(name: "a", type: .date),
                EspansoVar(name: "a", type: .clipboard),
            ]
        )
        let errors = MatchValidator.validate(match, existingMatches: [])
        XCTAssertTrue(errors.contains(.duplicateVarName("a")))
    }

    func testShellVarWithEmptyCmdIsInvalid() {
        let match = EspansoMatch(
            trigger: "::shell",
            replace: "{{out}}",
            vars: [EspansoVar(name: "out", type: .shell, params: ["cmd": .string("")])]
        )
        let errors = MatchValidator.validate(match, existingMatches: [])
        XCTAssertTrue(errors.contains(.emptyShellCmd))
    }

    func testShellVarWithNilCmdIsInvalid() {
        let match = EspansoMatch(
            trigger: "::shell",
            replace: "{{out}}",
            vars: [EspansoVar(name: "out", type: .shell, params: nil)]
        )
        let errors = MatchValidator.validate(match, existingMatches: [])
        XCTAssertTrue(errors.contains(.emptyShellCmd))
    }

    func testValidMatchHasNoErrors() {
        let match = EspansoMatch(trigger: "::sig", replace: "Best regards,\nJeff")
        let errors = MatchValidator.validate(match, existingMatches: [])
        XCTAssertTrue(errors.isEmpty)
    }

    func testNoTriggerIsInvalid() {
        let match = EspansoMatch(replace: "Hello")  // trigger, triggers, regex all nil
        let errors = MatchValidator.validate(match, existingMatches: [])
        XCTAssertTrue(errors.contains(.emptyTrigger))
    }
}

// MARK: - Global variable references

extension MatchValidationTests {

    func testReferenceToGlobalVarIsValid() {
        // A {{name}} declared in global_vars (another file) must not block saving.
        let m = EspansoMatch(trigger: "::where", replace: "I live in {{city}}")
        let errors = MatchValidator.validate(
            m, existingMatches: [], globalVarNames: ["city"])
        XCTAssertTrue(errors.isEmpty, "global var reference flagged: \(errors)")
    }

    func testUnknownVarStillReportedWithGlobalsPresent() {
        let m = EspansoMatch(trigger: "::x", replace: "{{nope}}")
        let errors = MatchValidator.validate(
            m, existingMatches: [], globalVarNames: ["city"])
        XCTAssertEqual(errors, [.unresolvedVarReference("nope")])
    }

    // The validator's reference pattern must be espanso's own — the same one
    // MatchExpander.preview substitutes with. A narrower one here means a
    // spaced reference is interpolated by espanso and filled in by the preview
    // but never checked, so the typo in it is reported nowhere.
    // Paired with MatchExpanderTests.testWhitespaceInsideBracesStillInterpolates.

    func testSpacedVarReferenceIsUnresolvedWhenUndeclared() {
        let m = EspansoMatch(trigger: "::x", replace: "Hello {{ nope }}")
        let errors = MatchValidator.validate(m, existingMatches: [])
        XCTAssertEqual(errors, [.unresolvedVarReference("nope")],
                       "espanso interpolates {{ nope }}, so validation must see it too")
    }

    func testSpacedVarReferenceResolvesAgainstADeclaredVar() {
        let m = EspansoMatch(
            trigger: "::date",
            replace: "Today is {{ d }}",
            vars: [EspansoVar(name: "d", type: .date)]
        )
        XCTAssertFalse(
            MatchValidator.validate(m, existingMatches: [])
                .contains(.unresolvedVarReference("d")))
    }

    func testSpacedGlobalVarReferenceResolves() {
        let m = EspansoMatch(trigger: "::where", replace: "I live in {{ city }}")
        let errors = MatchValidator.validate(
            m, existingMatches: [], globalVarNames: ["city"])
        XCTAssertTrue(errors.isEmpty, "global var reference flagged: \(errors)")
    }
}

// MARK: - Var name validity (espanso can only reference \w+ names)

extension MatchValidationTests {

    func testHyphenatedVarNameIsInvalid() {
        // espanso's interpolation regex is \w+ — {{short-date}} can never resolve.
        let match = EspansoMatch(
            trigger: ";sdat",
            replace: "{{short-date}}",
            vars: [EspansoVar(name: "short-date", type: .date)]
        )
        let errors = MatchValidator.validate(match, existingMatches: [])
        XCTAssertTrue(errors.contains(.invalidVarName("short-date")))
    }

    func testUnderscoredVarNameIsValid() {
        let match = EspansoMatch(
            trigger: ";sdat",
            replace: "{{short_date}}",
            vars: [EspansoVar(name: "short_date", type: .date)]
        )
        let errors = MatchValidator.validate(match, existingMatches: [])
        XCTAssertTrue(errors.isEmpty, "valid name flagged: \(errors)")
    }

    func testHyphenatedTokenInReplaceTextAloneIsNotAnError() {
        // No var declared: {{short-date}} is not extracted as a reference (espanso's
        // regex never matches it) and is passed through as literal text, which the
        // user may want — so it must not block saving.
        let match = EspansoMatch(trigger: ";lit", replace: "{{short-date}}")
        let errors = MatchValidator.validate(match, existingMatches: [])
        XCTAssertTrue(errors.isEmpty, "literal text flagged: \(errors)")
    }
}
