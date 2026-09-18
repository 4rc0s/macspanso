// macspansoTests/MatchExpanderTests.swift
import XCTest
@testable import macspanso

final class MatchExpanderTests: XCTestCase {

    func testPlainReplacementPassesThrough() {
        let m = EspansoMatch(trigger: "::hi", replace: "Hello, world")
        XCTAssertEqual(MatchExpander.preview(of: m), "Hello, world")
    }

    func testEchoVariableSubstitutes() {
        let m = EspansoMatch(
            trigger: "::greet",
            replace: "Hello {{name}}",
            vars: [EspansoVar(name: "name", type: .echo, params: ["echo": .string("Jeff")])]
        )
        XCTAssertEqual(MatchExpander.preview(of: m), "Hello Jeff")
    }

    func testDateVariableUsesFormat() {
        let m = EspansoMatch(
            trigger: "::y",
            replace: "{{y}}",
            vars: [EspansoVar(name: "y", type: .date, params: ["format": .string("%Y")])]
        )
        let preview = MatchExpander.preview(of: m)
        let year = Calendar.current.component(.year, from: Date())
        XCTAssertEqual(preview, "\(year)")
    }

    func testShellVariableShowsPlaceholderNotExecution() {
        let m = EspansoMatch(
            trigger: "::ls",
            replace: "{{out}}",
            vars: [EspansoVar(name: "out", type: .shell, params: ["cmd": .string("rm -rf /")])]
        )
        let preview = MatchExpander.preview(of: m)
        XCTAssertTrue(preview.contains("[shell:"), "shell command must not execute in preview")
        XCTAssertTrue(preview.contains("rm -rf /"))
    }

    func testRandomVariableShowsFirstChoice() {
        let m = EspansoMatch(
            trigger: "::r",
            replace: "{{r}}",
            vars: [EspansoVar(name: "r", type: .random, params: ["choices": .array([.string("a"), .string("b"), .string("c")])])]
        )
        XCTAssertEqual(MatchExpander.preview(of: m), "a")
    }

    func testFormPlaceholdersRenderAsBracketedNames() {
        let m = EspansoMatch(
            trigger: "::email",
            form: "Hello [[name]], your email is [[email]]"
        )
        XCTAssertEqual(MatchExpander.preview(of: m), "Hello [name], your email is [email]")
    }

    func testEmptyReplacementRendersEmpty() {
        let m = EspansoMatch(trigger: "::empty")
        XCTAssertEqual(MatchExpander.preview(of: m), "")
    }
}

// MARK: - Literal text in date formats

extension MatchExpanderTests {

    private func dateMatch(format: String) -> EspansoMatch {
        EspansoMatch(
            trigger: "::d",
            replace: "{{d}}",
            vars: [EspansoVar(name: "d", type: .date, params: ["format": .string(format)])]
        )
    }

    func testDateFormatLiteralTextPassesThrough() {
        // 'd', 'a', 'y', 's' are all ICU pattern letters — they must not be
        // interpreted when they appear as literal text around a token.
        let preview = MatchExpander.preview(of: dateMatch(format: "%Y days"))
        let year = Calendar.current.component(.year, from: Date())
        XCTAssertEqual(preview, "\(year) days")
    }

    func testDateFormatLiteralPrefixWithColon() {
        let preview = MatchExpander.preview(of: dateMatch(format: "Updated: %Y"))
        let year = Calendar.current.component(.year, from: Date())
        XCTAssertEqual(preview, "Updated: \(year)")
    }

    func testDateFormatEscapedPercentIsLiteral() {
        let preview = MatchExpander.preview(of: dateMatch(format: "100%% %Y"))
        let year = Calendar.current.component(.year, from: Date())
        XCTAssertEqual(preview, "100% \(year)")
    }

    func testDateFormatMultipleTokens() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let expected = f.string(from: Date())
        XCTAssertEqual(MatchExpander.preview(of: dateMatch(format: "%Y-%m-%d")), expected)
    }

    /// Every composite token the help table documents must render — a preview
    /// showing the raw code where espanso would produce a date is the lie in
    /// the direction the user cannot check. `%x` is the locale's date.
    func testDateFormatLocaleCompositeRenders() {
        let preview = MatchExpander.preview(of: dateMatch(format: "%x"))
        XCTAssertFalse(preview.contains("%"),
            "documented token %x must render, not pass through raw (got '\(preview)')")
    }

    func testDateFormatISOCompositeRenders() {
        let preview = MatchExpander.preview(of: dateMatch(format: "%F"))
        let year = Calendar.current.component(.year, from: Date())
        XCTAssertTrue(preview.hasPrefix("\(year)-"),
            "%F must render as %Y-%m-%d (got '\(preview)')")
    }

    func testDateFormatTimeCompositeRenders() {
        let preview = MatchExpander.preview(of: dateMatch(format: "%T"))
        XCTAssertEqual(preview.count, 8)
        XCTAssertEqual(preview.split(separator: ":").count, 3)
    }

    func testDateFormatNoPadModifierRenders() {
        let preview = MatchExpander.preview(of: dateMatch(format: "%-d"))
        let day = Calendar.current.component(.day, from: Date())
        XCTAssertEqual(preview, "\(day)")
    }

    func testDateFormatUnknownTokenPassesThroughRaw() {
        // chrono has no %J; espanso leaves it as literal text, so the preview
        // must too — surfacing the typo the same way the expansion does.
        let preview = MatchExpander.preview(of: dateMatch(format: "%J"))
        XCTAssertEqual(preview, "%J")
    }

    func testDateFormatWeekNumberFamilyPassesThroughRaw() {
        // Deliberately not approximated: ICU's week rules differ from chrono's,
        // and a plausible wrong number is worse than a visible raw code.
        let preview = MatchExpander.preview(of: dateMatch(format: "%V"))
        XCTAssertEqual(preview, "%V")
    }

    func testDateFormatUnixTimestampRenders() {
        let preview = MatchExpander.preview(of: dateMatch(format: "%s"))
        XCTAssertNotNil(Int(preview), "%s must render as a unix timestamp")
    }

    func testDateFormatMixedTokensAndLiterals() {
        let preview = MatchExpander.preview(of: dateMatch(format: "due %F at %H:%M"))
        XCTAssertTrue(preview.hasPrefix("due "),
            "literal text around composite tokens must survive (got '\(preview)')")
        XCTAssertTrue(preview.contains(" at "),
            "literal text between tokens must survive (got '\(preview)')")
        XCTAssertFalse(preview.contains("%"), "no token may pass through raw (got '\(preview)')")
    }
}

// MARK: - Interpolation fidelity (mirror espanso's \w+ reference regex)

extension MatchExpanderTests {

    func testHyphenatedVarNameStaysRawLikeEspanso() {
        // espanso's interpolation regex is \w+ only, so {{short-date}} is passed
        // through as literal text — the preview must not substitute it.
        let m = EspansoMatch(
            trigger: ";sdat",
            replace: "{{short-date}}",
            vars: [EspansoVar(name: "short-date", type: .date, params: ["format": .string("%Y")])]
        )
        XCTAssertEqual(MatchExpander.preview(of: m), "{{short-date}}")
    }

    func testWhitespaceInsideBracesStillInterpolates() {
        // espanso's regex allows {{\s*name\s*}} — the preview must agree.
        let m = EspansoMatch(
            trigger: "::y",
            replace: "{{ y }}",
            vars: [EspansoVar(name: "y", type: .date, params: ["format": .string("%Y")])]
        )
        let year = Calendar.current.component(.year, from: Date())
        XCTAssertEqual(MatchExpander.preview(of: m), "\(year)")
    }

    func testUndeclaredValidNameStaysRaw() {
        let m = EspansoMatch(trigger: "::x", replace: "{{unknown}}")
        XCTAssertEqual(MatchExpander.preview(of: m), "{{unknown}}")
    }
}

// MARK: - Day-period case (%p uppercase, %P lowercase)

extension MatchExpanderTests {

    /// chrono's %p is uppercase AM/PM; ICU's `a` renders the locale's canonical
    /// case, which is the uppercase form in English.
    func testLowercasePercentPPercentUppercase() {
        let preview = MatchExpander.preview(of: dateMatch(format: "%p"))
        XCTAssertTrue(["AM", "PM"].contains(preview), "got '\(preview)'")
    }

    /// %P is chrono's lowercase am/pm. ICU has no case-distinct day-period
    /// pair, so the preview lowercases its output — the value itself is
    /// time-of-day dependent, so accept either.
    func testPercentPLowercaseRendersLowercase() {
        let preview = MatchExpander.preview(of: dateMatch(format: "%P"))
        XCTAssertTrue(["am", "pm"].contains(preview), "got '\(preview)'")
    }

    func testPercentPMixedWithOtherTokens() {
        let preview = MatchExpander.preview(of: dateMatch(format: "%I:%M %P"))
        XCTAssertTrue(preview.contains(" am") || preview.contains(" pm"),
                      "got '\(preview)'")
        XCTAssertFalse(preview.contains("\u{E000}"),
                       "the sentinel must never reach the user (got '\(preview)')")
    }
}

// MARK: - Nested matches (`.match` variables)

extension MatchExpanderTests {

    private func matchVar(named name: String = "out", trigger: String) -> EspansoVar {
        EspansoVar(name: name, type: .match, params: ["trigger": .string(trigger)])
    }

    private func simpleMatch(trigger: String, replace: String) -> EspansoMatch {
        EspansoMatch(trigger: trigger, replace: replace)
    }

    func testMatchVarResolvesNestedTrigger() {
        let a = EspansoMatch(trigger: "::nested", replace: "{{out}}",
                             vars: [matchVar(trigger: ":one")])
        let b = simpleMatch(trigger: ":one", replace: "nested")
        XCTAssertEqual(MatchExpander.preview(of: a, in: [a, b]), "nested")
    }

    func testMatchVarResolvesAgainstTriggersList() {
        let a = EspansoMatch(trigger: "::n", replace: "{{out}}",
                             vars: [matchVar(trigger: ":two")])
        let b = EspansoMatch(triggers: [":one", ":two"], replace: "from list")
        XCTAssertEqual(MatchExpander.preview(of: a, in: [a, b]), "from list")
    }

    /// espanso renders the sub-template fully, so the target's own variables
    /// expand too — chained nesting is the point of the feature.
    func testMatchVarResolvesNestedMatchOwnVars() {
        let a = EspansoMatch(trigger: "::n", replace: "{{out}}",
                             vars: [matchVar(trigger: ":one")])
        let b = EspansoMatch(
            trigger: ":one", replace: "Hi {{name}}",
            vars: [EspansoVar(name: "name", type: .echo, params: ["echo": .string("Jeff")])]
        )
        XCTAssertEqual(MatchExpander.preview(of: a, in: [a, b]), "Hi Jeff")
    }

    func testMatchVarWithoutTriggerParamKeepsPlaceholder() {
        let a = EspansoMatch(trigger: "::n", replace: "{{out}}",
                             vars: [EspansoVar(name: "out", type: .match)])
        XCTAssertEqual(MatchExpander.preview(of: a, in: [a]), "[match]")
    }

    func testMatchVarWithoutLookupContextKeepsPlaceholder() {
        // `in: []` (the default) means the caller supplied no match set, not
        // that the config has no matches — keep the plain placeholder.
        let a = EspansoMatch(trigger: "::n", replace: "{{out}}",
                             vars: [matchVar(trigger: ":one")])
        XCTAssertEqual(MatchExpander.preview(of: a), "[match]")
    }

    func testMatchVarWithUnknownTriggerShowsNotFound() {
        let a = EspansoMatch(trigger: "::n", replace: "{{out}}",
                             vars: [matchVar(trigger: ":missing")])
        XCTAssertEqual(
            MatchExpander.preview(of: a, in: [a, simpleMatch(trigger: ":other", replace: "x")]),
            "[match: :missing not found]")
    }

    /// espanso recurses with no guard; the preview must degrade visibly
    /// instead of hanging the editor.
    func testMatchVarCircularReferenceStops() {
        let a = EspansoMatch(trigger: "::a", replace: "A {{out}}",
                             vars: [matchVar(trigger: ":b")])
        let b = EspansoMatch(trigger: ":b", replace: "B {{out}}",
                             vars: [matchVar(trigger: "::a")])
        let preview = MatchExpander.preview(of: a, in: [a, b])
        XCTAssertTrue(preview.contains("[match: circular reference]"), "got '\(preview)'")
    }

    func testMatchVarSelfReferenceStops() {
        let a = EspansoMatch(trigger: "::a", replace: "{{out}}",
                             vars: [matchVar(trigger: "::a")])
        let preview = MatchExpander.preview(of: a, in: [a])
        XCTAssertEqual(preview, "[match: circular reference]")
    }

    /// A diamond is not a cycle: both branches must resolve even though they
    /// share the leaf.
    func testMatchVarSharedTargetResolvesOnBothBranches() {
        let d = simpleMatch(trigger: ":d", replace: "leaf")
        let b = EspansoMatch(trigger: ":b", replace: "({{out}})",
                             vars: [matchVar(trigger: ":d")])
        let c = EspansoMatch(trigger: ":c", replace: "[{{out}}]",
                             vars: [matchVar(trigger: ":d")])
        let a = EspansoMatch(trigger: "::a", replace: "{{x}} {{y}}",
                             vars: [matchVar(named: "x", trigger: ":b"),
                                    matchVar(named: "y", trigger: ":c")])
        XCTAssertEqual(MatchExpander.preview(of: a, in: [a, b, c, d]), "(leaf) [leaf]")
    }

    /// With duplicate triggers espanso's winner depends on its config load
    /// order; the preview documents "first in store order" as the approximation.
    func testMatchVarDuplicateTriggersTakeFirst() {
        let a = EspansoMatch(trigger: "::n", replace: "{{out}}",
                             vars: [matchVar(trigger: ":one")])
        let first = simpleMatch(trigger: ":one", replace: "first")
        let second = simpleMatch(trigger: ":one", replace: "second")
        XCTAssertEqual(MatchExpander.preview(of: a, in: [a, first, second]), "first")
    }
}
