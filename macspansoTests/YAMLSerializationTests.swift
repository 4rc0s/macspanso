// macspansoTests/YAMLSerializationTests.swift
import XCTest
import Foundation
@testable import macspanso

final class YAMLSerializationTests: XCTestCase {

    func testRoundTripWithDateVar() throws {
        let match = EspansoMatch(
            trigger: "::date",
            replace: "{{d}}",
            vars: [EspansoVar(name: "d", type: .date, params: ["format": .string("%Y-%m-%d")])]
        )
        let yaml = try YAMLSerializer.encode([match])
        let decoded = try YAMLSerializer.decode(yaml: yaml)
        let v = try XCTUnwrap(decoded.first?.vars?.first)
        XCTAssertEqual(v.name, "d")
        XCTAssertEqual(v.type, .date)
        XCTAssertEqual(v.params?["format"], .string("%Y-%m-%d"))
    }

    /// espanso's script extension requires `args` to be a sequence — a plain
    /// string fails with "missing 'args' parameter" at expansion time. The editor
    /// writes the space-separated field back as a YAML list; pin the shape.
    func testRoundTripWithScriptVarArgsAsList() throws {
        let args = YAMLAny.array([
            .string("python3"), .string("/path/to/script.py"),
        ])
        let match = EspansoMatch(
            trigger: "::run",
            replace: "{{out}}",
            vars: [EspansoVar(name: "out", type: .script, params: ["args": args])]
        )
        let yaml = try YAMLSerializer.encode([match])
        XCTAssertTrue(yaml.contains("- python3"), "args should serialize as a YAML sequence:\n\(yaml)")
        let decoded = try YAMLSerializer.decode(yaml: yaml)
        let v = try XCTUnwrap(decoded.first?.vars?.first)
        XCTAssertEqual(v.params?["args"], args)
    }

    /// Files written before the editor stored a list keep their legacy string
    /// `args` intact through a round trip — an existing var must not be rewritten
    /// just by being opened and saved elsewhere.
    func testLegacyStringScriptArgsRoundTrip() throws {
        let match = EspansoMatch(
            trigger: "::run",
            replace: "{{out}}",
            vars: [EspansoVar(name: "out", type: .script, params: ["args": .string("python3 script.py")])]
        )
        let yaml = try YAMLSerializer.encode([match])
        let decoded = try YAMLSerializer.decode(yaml: yaml)
        let v = try XCTUnwrap(decoded.first?.vars?.first)
        XCTAssertEqual(v.params?["args"], .string("python3 script.py"))
    }

    func testRoundTripFormMatch() throws {
        let match = EspansoMatch(
            trigger: "::greet",
            form: "Hi [[name]]",
            formFields: ["name": FormField(default: "World")]
        )
        let yaml = try YAMLSerializer.encode([match])
        let decoded = try YAMLSerializer.decode(yaml: yaml)
        let result = try XCTUnwrap(decoded.first)
        XCTAssertEqual(result.trigger, "::greet")
        XCTAssertEqual(result.form, "Hi [[name]]")
        XCTAssertEqual(result.formFields?["name"]?.default, "World")
    }

    func testUUIDNotSerializedToYAML() throws {
        let match = EspansoMatch(trigger: "::test", replace: "Test")
        let yaml = try YAMLSerializer.encode([match])
        XCTAssertFalse(yaml.contains(match.id.uuidString),
            "UUID should not appear in YAML output")
    }

    func testAtomicWriteAndRead() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).yml")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let matches = [
            EspansoMatch(trigger: "::a", replace: "Alpha"),
            EspansoMatch(trigger: "::b", replace: "Beta"),
        ]
        try YAMLSerializer.write(matches, to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let readBack = try YAMLSerializer.decode(contentsOf: url)
        XCTAssertEqual(readBack.count, 2)
        let first = try XCTUnwrap(readBack.first)
        let second = try XCTUnwrap(readBack.dropFirst().first)
        XCTAssertEqual(first.trigger, "::a")
        XCTAssertEqual(first.replace, "Alpha")
        XCTAssertEqual(second.trigger, "::b")
        XCTAssertEqual(second.replace, "Beta")
    }

    func testWriteCreatesFileWhenAbsent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("new-\(UUID().uuidString).yml")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try YAMLSerializer.write([EspansoMatch(trigger: "::x", replace: "X")], to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
