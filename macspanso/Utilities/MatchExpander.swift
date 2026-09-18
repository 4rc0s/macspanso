// macspanso/Utilities/MatchExpander.swift
import AppKit
import Foundation

/// Renders a preview of how a match would expand. Shell/script vars are not executed;
/// they show a `[shell: cmd]` placeholder so the user understands what would run without
/// the editor side-effecting the system on every keystroke. Form placeholders `[[name]]`
/// render as `[name]` to indicate they would prompt the user.
public enum MatchExpander {
    public static func preview(of match: EspansoMatch) -> String {
        let template = match.replace ?? match.form ?? ""
        var output = template

        // Substitute declared variables before form placeholders so a var named the same
        // as a form field does not get rewritten — but in practice form mode has no vars.
        // Interpolation mirrors espanso's own regex (`\w+` names, optional surrounding
        // whitespace): a token like `{{short-date}}` never matches it, so espanso passes
        // it through as literal text and the preview must show it raw.
        let declaredVars = (match.vars ?? [])
        let varRef = /\{\{\s*(\w+)\s*\}\}/
        output = output.replacing(varRef) { m in
            guard let v = declaredVars.first(where: { $0.name == m.1 }) else {
                return String(m.0)
            }
            return resolve(v)
        }

        if match.form != nil {
            output = expandFormPlaceholders(output)
        }

        return output
    }

    private static func resolve(_ v: EspansoVar) -> String {
        switch v.type {
        case .date:
            let fmt = stringParam(v, "format") ?? "%Y-%m-%d"
            return formatDate(strftimePattern: fmt)
        case .clipboard:
            return NSPasteboard.general.string(forType: .string) ?? "[clipboard]"
        case .echo:
            return stringParam(v, "echo") ?? ""
        case .random:
            // `choices` is now [YAMLAny]; take the first entry that is a string.
            if case let .array(choices)? = v.params?["choices"],
               let first = choices.compactMap(\.stringValue).first {
                return first
            }
            return "[random]"
        case .shell:
            return "[shell: \(stringParam(v, "cmd") ?? "")]"
        case .script:
            return "[script]"
        case .form:
            return "[form]"
        case .match:
            return "[match]"
        case .choice:
            // The first offered label, mirroring how `.random` previews a choice.
            if case let .array(values)? = v.params?["values"],
               case let .dictionary(first)? = values.first,
               case let .string(label)? = first["label"] {
                return label
            }
            return "[choice]"
        case .unknown(let raw):
            return "[\(raw)]"
        }
    }

    private static func stringParam(_ v: EspansoVar, _ key: String) -> String? {
        v.params?[key]?.stringValue
    }

    /// ICU equivalents for the strftime tokens espanso accepts. espanso renders
    /// dates with chrono, whose dialect matches C's strftime in the common codes
    /// and extends it (`%F`, `%-d`, `%:z`); this map and the date table in
    /// `VariableHelpContent` must agree — every code the help sheet documents
    /// has to render in the preview, or the preview shows raw text where the
    /// snippet would produce a date, which is the one direction the user cannot
    /// check against a running espanso.
    ///
    /// Tokens chrono defines but ICU cannot express faithfully — the
    /// week-numbering family (`%U %W %V %G %g`, whose week-start rules differ),
    /// century (`%C`), and sub-second fractions (`%f` and friends) — are
    /// deliberately left to the literal pass-through below: a visible raw code
    /// invites a correction, a plausible wrong number smuggles one in. Tokens
    /// chrono itself rejects (a typo like `%J`) also pass through, surfacing
    /// the mistake the same way the expansion's failure does.
    private static let strftimeToICU: [Character: String] = [
        "Y": "yyyy", "y": "yy",
        "m": "MM", "B": "MMMM", "b": "MMM", "h": "MMM",
        "d": "dd", "e": "d", "j": "DDD", "q": "Q",
        "H": "HH", "k": "HH", "I": "hh", "l": "h",
        "M": "mm", "S": "ss",
        "A": "EEEE", "a": "EEE",
        "p": "a", "P": "a",
        // Composite date/time codes, expanded to their ICU spellings.
        "F": "yyyy-MM-dd", "T": "HH:mm:ss",
        "D": "MM/dd/yy", "R": "HH:mm",
        // chrono's %Z prints only the offset (it knows no zone names), so all
        // three zone tokens reduce to the numeric offset.
        "z": "Z", "Z": "Z",
    ]

    /// No-padding variants for chrono's `%-x` modifier — ICU spells these with
    /// single letters. `%0x` is chrono's default padding (the base map above);
    /// `%_x` asks for space padding, which ICU cannot express, so it is
    /// approximated with the base map's zero padding.
    private static let strftimeNoPadToICU: [Character: String] = [
        "Y": "y", "y": "y", "m": "M", "d": "d", "e": "d", "j": "D",
        "H": "H", "k": "H", "I": "h", "l": "h", "M": "m", "S": "s",
    ]

    /// Locale-composition tokens ask for the locale's own rendering ("locale's
    /// date representation"), which ICU expresses through formatter styles
    /// rather than patterns — and which cannot ride inside a larger ICU
    /// pattern, so each one splits the format into a separate run.
    private static let strftimeLocaleStyles: [Character: (DateFormatter.Style, DateFormatter.Style)] = [
        "x": (.short, .none),    // locale's date
        "X": (.none, .medium),   // locale's time
        "r": (.none, .medium),   // locale's 12-hour clock time
        "c": (.medium, .medium), // locale's date and time
    ]

    /// Convert the most common strftime tokens espanso accepts into an ICU
    /// pattern for `DateFormatter`. Literal text is single-quoted so letters
    /// like "days" aren't interpreted as ICU pattern characters; `%%` is a
    /// literal percent; tokens with no faithful ICU equivalent pass through as
    /// literals rather than render something espanso wouldn't.
    private static func formatDate(strftimePattern: String) -> String {
        var assembled = ""
        var icu = ""
        var literal = ""

        func flushRun() {
            guard !icu.isEmpty || !literal.isEmpty else { return }
            var pattern = icu
            if !literal.isEmpty {
                pattern += "'" + literal.replacingOccurrences(of: "'", with: "''") + "'"
            }
            let f = DateFormatter()
            f.dateFormat = pattern
            assembled += f.string(from: Date())
            icu = ""
            literal = ""
        }

        var i = strftimePattern.startIndex
        while i < strftimePattern.endIndex {
            let ch = strftimePattern[i]
            let next = strftimePattern.index(after: i)
            if ch == "%", next < strftimePattern.endIndex {
                let token = strftimePattern[next]
                let after = strftimePattern.index(after: next)

                func flushLiteral() {
                    guard !literal.isEmpty else { return }
                    icu += "'" + literal.replacingOccurrences(of: "'", with: "''") + "'"
                    literal = ""
                }

                if token == "%" {
                    literal.append("%")
                    i = after
                } else if token == "s" {
                    flushRun()
                    assembled += String(Int(Date().timeIntervalSince1970))
                    i = after
                } else if token == "+" {
                    // chrono's %+ is RFC 3339 / ISO 8601, exactly.
                    flushLiteral()
                    icu += "yyyy-MM-dd'T'HH:mm:ssXXX"
                    i = after
                } else if token == ":", after < strftimePattern.endIndex,
                          strftimePattern[after] == "z" {
                    flushLiteral()
                    icu += "XXX" // ±HH:MM
                    i = strftimePattern.index(after: after)
                } else if token == "-" || token == "_" || token == "0",
                          after < strftimePattern.endIndex,
                          strftimePattern[after] != "%" {
                    let base = strftimePattern[after]
                    if token == "-", let noPad = strftimeNoPadToICU[base] {
                        flushLiteral()
                        icu += noPad
                    } else if let padded = strftimeToICU[base] {
                        flushLiteral()
                        icu += padded
                    } else {
                        literal.append("%")
                        literal.append(token)
                        literal.append(base)
                    }
                    i = strftimePattern.index(after: after)
                } else if let icuToken = strftimeToICU[token] {
                    flushLiteral()
                    icu += icuToken
                    i = after
                } else if let styles = strftimeLocaleStyles[token] {
                    flushRun()
                    let f = DateFormatter()
                    f.dateStyle = styles.0
                    f.timeStyle = styles.1
                    assembled += f.string(from: Date())
                    i = after
                } else {
                    literal.append("%")
                    literal.append(token)
                    i = after
                }
            } else {
                literal.append(ch)
                i = next
            }
        }
        flushRun()
        return assembled
    }

    private static func expandFormPlaceholders(_ template: String) -> String {
        template.replacing(/\[\[(\w+)\]\]/) { match in "[\(match.1)]" }
    }
}
