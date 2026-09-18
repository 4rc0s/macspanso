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
