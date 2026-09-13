// macspansoTests/RoundTripPreservationTests.swift
import XCTest
@testable import macspanso

/// Editing a match through macspanso must not destroy YAML content the app
/// doesn't model: top-level keys like `global_vars:` and per-match keys like
/// `markdown:` or `image_path:` must survive a decode→encode round trip.
final class RoundTripPreservationTests: XCTestCase {

    func testGlobalVarsSurviveRoundTrip() throws {
        let yaml = """
        global_vars:
          - name: myname
            type: echo
            params:
              echo: Jeff
        matches:
          - trigger: "::hi"
            replace: "Hello {{myname}}"
        """
        let content = try YAMLSerializer.decodeContent(yaml: yaml)
        let out = try YAMLSerializer.encode(content)
        XCTAssertTrue(out.contains("global_vars"), "global_vars key must survive: \(out)")
        XCTAssertTrue(out.contains("myname"), "global var name must survive: \(out)")

        // Re-decoding the output must produce structurally identical extras.
        let again = try YAMLSerializer.decodeContent(yaml: out)
        XCTAssertEqual(content.extras, again.extras)
        XCTAssertEqual(again.matches?.first?.trigger, "::hi")
    }

    func testUnknownMatchKeysSurviveRoundTrip() throws {
        let yaml = """
        matches:
          - trigger: ":md"
            markdown: "**bold**"
            priority: 10
            paste_shortcut: CTRL+V
        """
        let matches = try YAMLSerializer.decode(yaml: yaml)
        let out = try YAMLSerializer.encode(matches)
        XCTAssertTrue(out.contains("markdown"), "unknown match key must survive: \(out)")
        XCTAssertTrue(out.contains("**bold**"))
        XCTAssertTrue(out.contains("priority"))
        XCTAssertTrue(out.contains("paste_shortcut"))
        XCTAssertTrue(out.contains("CTRL+V"))
    }

    func testNestedUnknownStructuresSurvive() throws {
        let yaml = """
        matches:
          - trigger: ":form2"
            form: "Hi [[choices]]"
            apps:
              - title: Slack
              - exe: notes
        """
        let matches = try YAMLSerializer.decode(yaml: yaml)
        let out = try YAMLSerializer.encode(matches)
        XCTAssertTrue(out.contains("apps"), "nested unknown structure must survive: \(out)")
        XCTAssertTrue(out.contains("Slack"))
        XCTAssertTrue(out.contains("notes"))
    }

    func testKnownKeysNotDuplicatedIntoExtras() throws {
        let yaml = """
        matches:
          - trigger: "::a"
            replace: Alpha
            word: true
        """
        let matches = try YAMLSerializer.decode(yaml: yaml)
        let match = try XCTUnwrap(matches.first)
        XCTAssertTrue(match.extras.isEmpty,
            "modelled keys must not leak into extras: \(match.extras)")
    }

    func testCommentOnlyFileStillDecodesEmpty() throws {
        // Regression guard: the empty-codingPath typeMismatch catch must keep working.
        let yaml = "# just a comment\n"
        let matches = try YAMLSerializer.decode(yaml: yaml)
        XCTAssertTrue(matches.isEmpty)
    }

    @MainActor
    func testStoreUpdatePreservesGlobalVarsOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macspanso-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("base.yml")
        try """
        global_vars:
          - name: city
            type: echo
            params:
              echo: Sudbury
        matches:
          - trigger: "::where"
            replace: "I live in {{city}}"
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = EspansoConfigStore(matchDirectory: dir)
        store.load()

        var match = try XCTUnwrap(store.allMatches.first)
        match.label = "Edited"
        try store.update(match)

        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("global_vars"),
            "editing a match must not delete global_vars from the file: \(onDisk)")
        XCTAssertTrue(onDisk.contains("Sudbury"))
        XCTAssertTrue(onDisk.contains("Edited"))
    }
}

// MARK: - Global var name extraction

extension RoundTripPreservationTests {

    @MainActor
    func testStoreExposesGlobalVarNames() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macspanso-gv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        try """
        global_vars:
          - name: city
            type: echo
            params:
              echo: Sudbury
          - name: signoff
            type: echo
            params:
              echo: Best
        matches:
          - trigger: "::where"
            replace: "{{city}}"
        """.write(to: dir.appendingPathComponent("base.yml"), atomically: true, encoding: .utf8)

        let store = EspansoConfigStore(matchDirectory: dir)
        store.load()
        XCTAssertEqual(store.globalVarNames, ["city", "signoff"])
    }
}

// MARK: - YAML anchors and aliases (known limitation)

extension RoundTripPreservationTests {

    /// espanso documents `anchors:` + YAML aliases as the compact way to share one
    /// script across several matches:
    /// https://espanso.org/docs/matches/extensions/#anchors-and-aliases
    ///
    /// Yams resolves aliases while composing the node graph and keeps no record of
    /// the anchor name, so a decode→encode round trip inlines every `*ref`. The file
    /// stays *semantically* identical — espanso resolves the same aliases — but the
    /// shared definition is copied into every use site, which is exactly the kind of
    /// hand-authored structure `extras` exists to protect.
    ///
    /// Pinned with `XCTExpectFailure` rather than deleted: it is executable
    /// documentation, and it turns red the moment someone makes aliases survive, so
    /// the limitation note in CLAUDE.md gets removed at the same time.
    func testYAMLAliasesAreInlinedOnRoundTrip() throws {
        let yaml = """
        anchors:
          script1: &script1 |
            fruits = ["apple", "banana"]
            for x in fruits:
              print(x)

        matches:
          - trigger: ":one"
            replace: "{{output}}"
            vars:
              - name: output
                type: script
                params:
                  args: [python, -c, *script1]
          - trigger: ":two"
            replace: "{{output}}"
            vars:
              - name: output
                type: script
                params:
                  args: [python, -c, *script1]
        """
        let content = try YAMLSerializer.decodeContent(yaml: yaml)
        let out = try YAMLSerializer.encode(content)

        // What does hold: the anchors block and the script body both survive, so the
        // file still behaves identically under espanso.
        XCTAssertTrue(out.contains("anchors"), "anchors key must survive: \(out)")
        XCTAssertTrue(out.contains("fruits"), "the shared script body must survive: \(out)")

        // What does not: the anchor/alias syntax is gone and the body is duplicated
        // once per use site plus the definition.
        XCTAssertEqual(out.components(separatedBy: "banana").count - 1, 3,
            "the shared body is currently inlined at every use site: \(out)")

        XCTExpectFailure("Yams resolves aliases at parse time — see CLAUDE.md, 'YAML anchors are not preserved'") {
            XCTAssertTrue(out.contains("&script1"), "anchor definition should survive: \(out)")
            XCTAssertTrue(out.contains("*script1"), "alias should not be expanded: \(out)")
        }
    }
}

// MARK: - Newly modelled espanso keys
//
// The authoritative key list is espanso's schemas/match.schema.json on the `dev`
// branch (main and master 404), which sets
// additionalProperties: false. A property added to EspansoMatch without a matching
// CodingKeys case is decoded *and* copied into extras, so it gets written twice —
// `testKnownKeysNotDuplicatedIntoExtras` and the extras check below guard that.

extension RoundTripPreservationTests {

    func testAdvancedKeysAreModelledNotExtras() throws {
        let yaml = """
        matches:
          - trigger: "::sig"
            replace: Best regards
            label: Sign-off
            left_word: true
            right_word: true
            uppercase_style: capitalize_words
            force_mode: clipboard
            search_terms:
              - signoff
              - regards
            comment: Used at the end of emails
        """
        let match = try XCTUnwrap(try YAMLSerializer.decode(yaml: yaml).first)

        XCTAssertEqual(match.label, "Sign-off")
        XCTAssertEqual(match.leftWord, true)
        XCTAssertEqual(match.rightWord, true)
        XCTAssertEqual(match.uppercaseStyle, "capitalize_words")
        XCTAssertEqual(match.forceMode, "clipboard")
        XCTAssertEqual(match.searchTerms, ["signoff", "regards"])
        XCTAssertEqual(match.comment, "Used at the end of emails")
        XCTAssertTrue(match.extras.isEmpty,
            "modelled keys must not leak into extras: \(match.extras)")

        // And they must come back out unchanged.
        var again = try XCTUnwrap(
            try YAMLSerializer.decode(yaml: try YAMLSerializer.encode([match])).first)
        // `id` is minted at decode time and deliberately never serialized, so align
        // it before comparing every other field at once.
        again.id = match.id
        XCTAssertEqual(again, match)
    }

    func testUntouchedOptionalKeysAreNotEmitted() throws {
        // espanso omits what it doesn't need. Writing `false` or `""` would add keys
        // the user never asked for and churn the file on every save.
        let match = EspansoMatch(trigger: "::x", replace: "Alpha")
        let out = try YAMLSerializer.encode([match])

        for key in ["label", "left_word", "right_word", "uppercase_style",
                    "force_mode", "search_terms", "comment"] {
            XCTAssertFalse(out.contains(key), "\(key) must not be emitted when unset: \(out)")
        }
        XCTAssertFalse(out.contains("null"), "unset keys must be omitted, not nulled: \(out)")
    }

    func testUnrecognisedEnumValueRoundTripsInsteadOfFailing() throws {
        // uppercase_style and force_mode are String, not Swift enums, on purpose: a
        // strict enum would throw here, and a file that fails to decode is stored
        // with a parseError and becomes unwritable.
        let yaml = """
        matches:
          - trigger: "::x"
            replace: Alpha
            force_mode: some_future_mode
            uppercase_style: some_future_style
        """
        let match = try XCTUnwrap(try YAMLSerializer.decode(yaml: yaml).first)
        XCTAssertEqual(match.forceMode, "some_future_mode")
        XCTAssertEqual(match.uppercaseStyle, "some_future_style")

        let out = try YAMLSerializer.encode([match])
        XCTAssertTrue(out.contains("some_future_mode"), "unknown values must survive: \(out)")
        XCTAssertTrue(out.contains("some_future_style"), "unknown values must survive: \(out)")
    }
}
