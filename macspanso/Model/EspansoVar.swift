// macspanso/Model/EspansoVar.swift
import Foundation

/// Var param values reuse `YAMLAny` rather than a second, narrower YAML enum.
/// The previous `YAMLValue` modelled only string/int/bool/[String], so espanso
/// shapes it couldn't represent — a `choice` var's `values:` list of mappings, a
/// `form` var's `fields:` mapping, or any float or null param — failed to decode
/// and took the *whole file* down with them (stored as `parseError`, uneditable).
/// One recursive YAML type means that gap can't reopen.
public typealias VarParams = [String: YAMLAny]

/// espanso's nine documented variable types, plus anything it adds later.
///
/// `unknown` exists for the same reason `uppercase_style` is a String and not a
/// Swift enum: a strict enum turns a value espanso introduces into a decode
/// failure, and a file that fails to decode is quarantined and can't be edited.
/// An unknown type round-trips untouched and is read-only in the UI.
public enum VarType: Codable, Equatable, Hashable {
    case date, clipboard, shell, script, random, form, match, echo, choice
    case unknown(String)

    /// The types macspanso can build and edit, in the order the picker shows them.
    public static let known: [VarType] =
        [.date, .clipboard, .shell, .script, .random, .form, .match, .echo, .choice]

    public var rawValue: String {
        switch self {
        case .date:      return "date"
        case .clipboard: return "clipboard"
        case .shell:     return "shell"
        case .script:    return "script"
        case .random:    return "random"
        case .form:      return "form"
        case .match:     return "match"
        case .echo:      return "echo"
        case .choice:    return "choice"
        case .unknown(let raw): return raw
        }
    }

    public init(rawValue: String) {
        self = Self.known.first { $0.rawValue == rawValue } ?? .unknown(rawValue)
    }

    /// True for a type this app has no editor for; its params are shown read-only.
    public var isEditable: Bool {
        if case .unknown = self { return false }
        return true
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public struct EspansoVar: Codable, Equatable {
    public var name: String
    public var type: VarType
    public var params: VarParams?

    /// Keys on this var that macspanso doesn't model — `inject_vars:` and
    /// `depends_on:` are documented on every variable type in espanso's schema,
    /// and before this existed they were read, ignored, and dropped on save. This
    /// is the third tier of the same preservation `MatchFileContent.extras` and
    /// `EspansoMatch.extras` provide; the write-time round-trip check cannot catch
    /// a loss here, because both sides of that comparison share this decoder.
    public var extras: [String: YAMLAny] = [:]

    public init(name: String, type: VarType, params: VarParams? = nil,
                extras: [String: YAMLAny] = [:]) {
        self.name = name
        self.type = type
        self.params = params
        self.extras = extras
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name, type, params
    }

    /// Derived from `CodingKeys.allCases`: add a property here and to CodingKeys
    /// together, or it will be both decoded and duplicated into `extras`.
    private static let knownKeys: Set<String> =
        Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name   = try c.decode(String.self, forKey: .name)
        self.type   = try c.decode(VarType.self, forKey: .type)
        self.params = try c.decodeIfPresent(VarParams.self, forKey: .params)

        let dynamic = try decoder.container(keyedBy: AnyCodingKey.self)
        var extras: [String: YAMLAny] = [:]
        for key in dynamic.allKeys where !Self.knownKeys.contains(key.stringValue) {
            extras[key.stringValue] = try dynamic.decode(YAMLAny.self, forKey: key)
        }
        self.extras = extras
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(params, forKey: .params)

        var dynamic = encoder.container(keyedBy: AnyCodingKey.self)
        for key in extras.keys.sorted() {
            try dynamic.encode(extras[key]!, forKey: AnyCodingKey(stringValue: key))
        }
    }
}
