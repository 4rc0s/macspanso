// macspanso/Utilities/YAMLSerializer.swift
import Foundation
import Yams

public enum YAMLSerializer {

    // MARK: - Decode

    /// Decode matches from a YAML string (used in tests and from files).
    public static func decode(yaml: String) throws -> [EspansoMatch] {
        let trimmed = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Files with no "matches:" key (global_vars.yml, etc.) decode fine because
        // MatchFileContent.matches is optional — they return [].
        // Comment-only files produce a non-mapping YAML node, causing a top-level
        // typeMismatch. We catch only that case (codingPath is empty) so errors inside
        // individual matches still propagate.
        do {
            let content = try YAMLDecoder().decode(MatchFileContent.self, from: yaml)
            return content.matches ?? []
        } catch DecodingError.typeMismatch(_, let ctx) where ctx.codingPath.isEmpty {
            return []
        }
    }

    /// Decode matches from a file URL.
    public static func decode(contentsOf url: URL) throws -> [EspansoMatch] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try decode(yaml: text)
    }

    /// Decode the full file content, including top-level keys macspanso doesn't
    /// model (global_vars, imports, …). Prefer this over `decode(yaml:)` whenever
    /// the result will be written back to disk.
    public static func decodeContent(yaml: String) throws -> MatchFileContent {
        let trimmed = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return MatchFileContent(matches: []) }
        do {
            return try YAMLDecoder().decode(MatchFileContent.self, from: yaml)
        } catch DecodingError.typeMismatch(_, let ctx) where ctx.codingPath.isEmpty {
            return MatchFileContent(matches: [])
        }
    }

    /// Decode the full file content from a file URL.
    public static func decodeContent(contentsOf url: URL) throws -> MatchFileContent {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try decodeContent(yaml: text)
    }

    // MARK: - Encode

    /// Encode matches to a YAML string. Top-level extras are empty; use
    /// `encode(_ content:)` when writing back a file that may carry them.
    public static func encode(_ matches: [EspansoMatch]) throws -> String {
        try encode(MatchFileContent(matches: matches))
    }

    /// Encode full file content (matches + preserved top-level keys).
    public static func encode(_ content: MatchFileContent) throws -> String {
        try YAMLEncoder().encode(content)
    }

    // MARK: - Atomic Write

    /// Write matches atomically to a file URL.
    /// Uses String.write(atomically:) which does temp-file + rename.
    /// Creates the file if it doesn't exist.
    public static func write(_ matches: [EspansoMatch], to url: URL) throws {
        try write(MatchFileContent(matches: matches), to: url)
    }

    /// Write full file content atomically, preserving top-level extras.
    ///
    /// The emitted YAML is decoded back and compared to what we meant to write
    /// *before* anything touches disk. Yams emits from a node tree so malformed
    /// syntax is near-impossible, but that is not the risk here: this app rewrites
    /// whole files it doesn't own, so the failure that matters is emitting
    /// something well-formed that no longer says what the model said. On a
    /// mismatch nothing is written and the file keeps its previous contents,
    /// which is the same guarantee the store's write-then-commit ordering relies on.
    public static func write(_ content: MatchFileContent, to url: URL) throws {
        let yaml = try encode(content)
        try verifyRoundTrip(of: yaml, matches: content, for: url)
        try yaml.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Write verification

    public enum SerializationError: LocalizedError {
        /// The encoder produced YAML that doesn't read back as the same content.
        case verificationFailed(file: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .verificationFailed(let file, let reason):
                return "macspanso could not safely rewrite \(file): \(reason). "
                     + "The file was left unchanged."
            }
        }
    }

    private static func verifyRoundTrip(
        of yaml: String, matches content: MatchFileContent, for url: URL
    ) throws {
        let name = url.lastPathComponent
        func fail(_ reason: String) -> SerializationError {
            .verificationFailed(file: name, reason: reason)
        }

        let reread: MatchFileContent
        do {
            reread = try decodeContent(yaml: yaml)
        } catch {
            // Only reachable if our own encoder emitted something unparseable —
            // i.e. a Yams regression. Carry the decode error so that diagnosis
            // doesn't require reproducing it.
            throw fail("the YAML it produced could not be parsed back (\(error))")
        }

        guard reread.extras == content.extras else {
            throw fail("top-level keys outside `matches:` did not survive the rewrite")
        }

        let intended = content.matches ?? []
        let actual = reread.matches ?? []
        guard intended.count == actual.count else {
            throw fail("it would have written \(actual.count) matches instead of \(intended.count)")
        }

        for (expected, var got) in zip(intended, actual) {
            // `id` is minted fresh at decode and deliberately never serialized,
            // so align it and let Equatable compare everything else.
            got.id = expected.id
            guard got == expected else {
                throw fail("the match `\(expected.primaryTrigger)` did not survive the rewrite")
            }
        }
    }
}
