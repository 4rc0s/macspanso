// macspanso/Model/EspansoMatch.swift
import Foundation

public struct EspansoMatch: Identifiable, Codable, Equatable {
    public var id: UUID

    // Trigger — exactly one of these should be set
    public var trigger: String?
    public var triggers: [String]?
    public var regex: String?

    // Replacement — exactly one of these should be set
    public var replace: String?
    public var form: String?

    public var formFields: [String: FormField]?
    public var vars: [EspansoVar]?
    public var label: String?
    public var propagateCase: Bool?
    public var word: Bool?
    public var leftWord: Bool?
    public var rightWord: Bool?
    /// espanso allows "capitalize", "capitalize_words", "uppercase". Kept as a
    /// String, not an enum: an unrecognised value must round-trip, and a strict
    /// enum would fail the decode and mark the whole file unparseable.
    public var uppercaseStyle: String?
    /// espanso allows "clipboard" or "keys". String for the same reason.
    public var forceMode: String?
    public var searchTerms: [String]?
    public var comment: String?

    /// YAML keys on this match that macspanso doesn't model (markdown, html,
    /// image_path, paragraph, …), preserved verbatim so editing never destroys them.
    /// The authoritative key list is espanso's own schemas/match.schema.json, which
    /// sets additionalProperties: false — check it before assuming a key exists.
    public var extras: [String: YAMLAny] = [:]

    public init(
        id: UUID = .init(),
        trigger: String? = nil,
        triggers: [String]? = nil,
        regex: String? = nil,
        replace: String? = nil,
        form: String? = nil,
        formFields: [String: FormField]? = nil,
        vars: [EspansoVar]? = nil,
        label: String? = nil,
        propagateCase: Bool? = nil,
        word: Bool? = nil,
        leftWord: Bool? = nil,
        rightWord: Bool? = nil,
        uppercaseStyle: String? = nil,
        forceMode: String? = nil,
        searchTerms: [String]? = nil,
        comment: String? = nil
    ) {
        self.id = id
        self.trigger = trigger
        self.triggers = triggers
        self.regex = regex
        self.replace = replace
        self.form = form
        self.formFields = formFields
        self.vars = vars
        self.label = label
        self.propagateCase = propagateCase
        self.word = word
        self.leftWord = leftWord
        self.rightWord = rightWord
        self.uppercaseStyle = uppercaseStyle
        self.forceMode = forceMode
        self.searchTerms = searchTerms
        self.comment = comment
    }

    // id is internal — exclude from YAML encode/decode
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case trigger, triggers, regex, replace, form, vars, label, word, comment
        case formFields     = "form_fields"
        case propagateCase  = "propagate_case"
        case leftWord       = "left_word"
        case rightWord      = "right_word"
        case uppercaseStyle = "uppercase_style"
        case forceMode      = "force_mode"
        case searchTerms    = "search_terms"
    }

    /// YAML key names this model handles explicitly; anything else is an extra.
    private static let knownKeys: Set<String> =
        Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id            = UUID()
        self.trigger       = try c.decodeIfPresent(String.self,              forKey: .trigger)
        self.triggers      = try c.decodeIfPresent([String].self,            forKey: .triggers)
        self.regex         = try c.decodeIfPresent(String.self,              forKey: .regex)
        self.replace       = try c.decodeIfPresent(String.self,              forKey: .replace)
        self.form          = try c.decodeIfPresent(String.self,              forKey: .form)
        self.formFields    = try c.decodeIfPresent([String: FormField].self, forKey: .formFields)
        self.vars          = try c.decodeIfPresent([EspansoVar].self,        forKey: .vars)
        self.label         = try c.decodeIfPresent(String.self,              forKey: .label)
        self.propagateCase = try c.decodeIfPresent(Bool.self,                forKey: .propagateCase)
        self.word          = try c.decodeIfPresent(Bool.self,                forKey: .word)
        self.leftWord      = try c.decodeIfPresent(Bool.self,                forKey: .leftWord)
        self.rightWord     = try c.decodeIfPresent(Bool.self,                forKey: .rightWord)
        self.uppercaseStyle = try c.decodeIfPresent(String.self,             forKey: .uppercaseStyle)
        self.forceMode     = try c.decodeIfPresent(String.self,              forKey: .forceMode)
        self.searchTerms   = try c.decodeIfPresent([String].self,            forKey: .searchTerms)
        self.comment       = try c.decodeIfPresent(String.self,              forKey: .comment)
        // `form:` takes precedence — clear `replace:` if both are present in malformed YAML.
        if self.form != nil { self.replace = nil }

        // Preserve every key this model doesn't handle so a rewrite never drops it.
        let dynamic = try decoder.container(keyedBy: AnyCodingKey.self)
        var extras: [String: YAMLAny] = [:]
        for key in dynamic.allKeys where !Self.knownKeys.contains(key.stringValue) {
            extras[key.stringValue] = try dynamic.decode(YAMLAny.self, forKey: key)
        }
        self.extras = extras
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(trigger,       forKey: .trigger)
        try c.encodeIfPresent(triggers,      forKey: .triggers)
        try c.encodeIfPresent(regex,         forKey: .regex)
        try c.encodeIfPresent(replace,       forKey: .replace)
        try c.encodeIfPresent(form,          forKey: .form)
        try c.encodeIfPresent(formFields,    forKey: .formFields)
        try c.encodeIfPresent(vars,          forKey: .vars)
        try c.encodeIfPresent(label,         forKey: .label)
        try c.encodeIfPresent(propagateCase, forKey: .propagateCase)
        try c.encodeIfPresent(word,          forKey: .word)
        try c.encodeIfPresent(leftWord,      forKey: .leftWord)
        try c.encodeIfPresent(rightWord,     forKey: .rightWord)
        try c.encodeIfPresent(uppercaseStyle, forKey: .uppercaseStyle)
        try c.encodeIfPresent(forceMode,     forKey: .forceMode)
        try c.encodeIfPresent(searchTerms,   forKey: .searchTerms)
        try c.encodeIfPresent(comment,       forKey: .comment)

        var dynamic = encoder.container(keyedBy: AnyCodingKey.self)
        for key in extras.keys.sorted() {
            try dynamic.encode(extras[key]!, forKey: AnyCodingKey(stringValue: key))
        }
    }

    // Convenience: the primary trigger string for display
    public var primaryTrigger: String {
        trigger ?? triggers?.first ?? regex ?? "(no trigger)"
    }

    // Convenience: a short preview of the replacement for display
    public var replacementPreview: String {
        (replace ?? form ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
