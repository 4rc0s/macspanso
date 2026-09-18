// macspanso/Support/VariableHelpContent.swift
import Foundation

/// Offline quick reference for espanso's variable types, shown in a
/// `VariableHelpSheet`. One HTML document with an anchored section per
/// documented type; a var card's help button opens it scrolled to that type.
///
/// Content is pinned to espanso v2 (verified against espanso.org's Extensions
/// page and the espanso-render extension sources). Two things are deliberately
/// absent: there is no `match` section — espanso has no such extension, so there
/// is nothing authoritative to document — and the `date` table is chrono's
/// strftime dialect (what espanso actually uses), not C's.
enum VariableHelpContent {

    /// Types with a section in the help document, in document order.
    /// Deliberately excludes `.match` (no espanso extension behind it).
    static let documentedTypes: [VarType] =
        [.date, .clipboard, .shell, .script, .random, .form, .echo, .choice]

    /// The HTML fragment id each documented type scrolls to.
    static func anchor(for type: VarType) -> String? {
        documentedTypes.contains(type) ? "var-\(type.rawValue)" : nil
    }

    /// The complete help document. `loadHTMLString`-ready: self-contained,
    /// no external resources, dark-mode aware via `prefers-color-scheme`.
    static let html: String = {
        let sections = documentedTypes.map(sectionHTML(for:)).joined(separator: "\n")
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        :root { color-scheme: light dark; }
        body {
          font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
          font-size: 13px; line-height: 1.5; margin: 0; padding: 16px 20px 32px;
          color: CanvasText; background: Canvas;
        }
        h1 { font-size: 18px; margin: 0 0 4px; }
        h2 {
          font-size: 15px; margin: 28px 0 6px; padding-bottom: 4px;
          border-bottom: 1px solid color-mix(in srgb, CanvasText 15%, transparent);
          scroll-margin-top: 8px;
        }
        code, pre {
          font-family: ui-monospace, Menlo, monospace; font-size: 12px;
          background: color-mix(in srgb, CanvasText 8%, transparent);
          border-radius: 4px;
        }
        code { padding: 1px 4px; }
        pre { padding: 8px 10px; overflow-x: auto; }
        table { border-collapse: collapse; margin: 8px 0; }
        th, td { text-align: left; padding: 3px 12px 3px 0; vertical-align: top; }
        th { font-weight: 600; }
        td:first-child, th:first-child { white-space: nowrap; }
        .note { color: color-mix(in srgb, CanvasText 65%, transparent); }
        a { color: AccentColor; }
        </style>
        </head>
        <body>
        <h1>Variable reference</h1>
        <p>Variables produce values a match can inject. Declare one under
        <strong>Variables</strong>, then use its output in the replacement text with
        double curly braces: <code>{{varname}}</code>. Names may use only letters,
        numbers, and underscores.</p>
        <p class="note">Two further options espanso accepts on any variable —
        <code>inject_vars:</code> and <code>depends_on:</code> — are kept exactly as
        they are in the file but can only be changed by editing the YAML by hand.</p>
        \(sections)
        <p class="note">Full documentation: <a href="https://espanso.org/docs/matches/variables/">espanso.org/docs/matches/variables</a></p>
        </body>
        </html>
        """
    }()

    private static func sectionHTML(for type: VarType) -> String {
        switch type {
        case .date: return dateSection
        case .clipboard: return clipboardSection
        case .shell: return shellSection
        case .script: return scriptSection
        case .random: return randomSection
        case .form: return formSection
        case .echo: return echoSection
        case .choice: return choiceSection
        default: return ""
        }
    }

    // MARK: - Sections

    // Every line inside these literals is indented at least as far as the
    // closing delimiter; YAML samples carry their relative indentation on top
    // of that, which Swift strips — the <pre> blocks render properly.
    private static let dateSection = """
        <h2 id="var-date">date</h2>
        <p>The current date or time, rendered with a <code>format</code> string.
        espanso formats dates with the Rust <em>chrono</em> library — most codes match
        C's strftime, but not all.</p>
        <pre>vars:
              - name: today
                type: date
                params:
                  format: "%Y-%m-%d"</pre>
        <table>
        <tr><th>Code</th><th>Meaning</th><th>Example</th></tr>
        <tr><td><code>%Y</code></td><td>4-digit year</td><td>2026</td></tr>
        <tr><td><code>%y</code></td><td>2-digit year</td><td>26</td></tr>
        <tr><td><code>%m</code></td><td>Month, zero-padded</td><td>09</td></tr>
        <tr><td><code>%B</code></td><td>Month name</td><td>September</td></tr>
        <tr><td><code>%b</code></td><td>Abbreviated month</td><td>Sep</td></tr>
        <tr><td><code>%d</code></td><td>Day, zero-padded</td><td>05</td></tr>
        <tr><td><code>%-d</code></td><td>Day, no padding</td><td>5</td></tr>
        <tr><td><code>%A</code></td><td>Weekday name</td><td>Friday</td></tr>
        <tr><td><code>%a</code></td><td>Abbreviated weekday</td><td>Fri</td></tr>
        <tr><td><code>%H</code></td><td>Hour 00–23</td><td>14</td></tr>
        <tr><td><code>%I</code></td><td>Hour 01–12</td><td>02</td></tr>
        <tr><td><code>%M</code></td><td>Minute</td><td>07</td></tr>
        <tr><td><code>%S</code></td><td>Second</td><td>09</td></tr>
        <tr><td><code>%p</code></td><td>AM / PM</td><td>PM</td></tr>
        <tr><td><code>%F</code></td><td>Short date (<code>%Y-%m-%d</code>)</td><td>2026-09-18</td></tr>
        <tr><td><code>%T</code></td><td>Time (<code>%H:%M:%S</code>)</td><td>14:07:09</td></tr>
        <tr><td><code>%x</code></td><td>Locale's date</td><td>09/18/2026</td></tr>
        <tr><td><code>%X</code></td><td>Locale's time</td><td>02:07:09 PM</td></tr>
        <tr><td><code>%%</code></td><td>A literal <code>%</code></td><td>%</td></tr>
        </table>
        <p>Other params: <code>offset</code> (seconds added to now; negative for the
        past — <code>offset: 86400</code> is tomorrow), <code>locale:</code> (BCP 47,
        e.g. <code>"en-US"</code>), and <code>tz:</code> (IANA name, e.g.
        <code>"Europe/Paris"</code>).</p>
        <p class="note">The full code table: <a href="https://docs.rs/chrono/latest/chrono/format/strftime/index.html">chrono's strftime reference</a></p>
        """

    private static let clipboardSection = """
        <h2 id="var-clipboard">clipboard</h2>
        <p>The current clipboard contents. Takes no params.</p>
        <pre>vars:
              - name: link
                type: clipboard</pre>
        <p>Then <code>{{link}}</code> in the replacement text expands to whatever was
        copied when the snippet fired.</p>
        """

    private static let shellSection = """
        <h2 id="var-shell">shell</h2>
        <p>The output of a shell command. Pipes and shell syntax work as in your
        terminal. On macOS espanso uses the shell you have configured.</p>
        <pre>vars:
              - name: ip
                type: shell
                params:
                  cmd: "curl 'https://api.ipify.org'"</pre>
        <p>Optional params: <code>shell:</code> (e.g. <code>zsh</code>,
        <code>bash</code>), <code>trim: false</code> to keep trailing newlines,
        <code>debug: true</code> to log what ran (see <code>espanso log</code>), and
        <code>ignore_error: true</code> to expand empty instead of failing.</p>
        <p>Earlier variables in the same match are available both by injection
        (<code>{{othervar}}</code> inside <code>cmd</code>) and as environment
        variables named <code>ESPANSO_</code> + the uppercase name (e.g.
        <code>$ESPANSO_MYNAME</code>).</p>
        """

    private static let scriptSection = """
        <h2 id="var-script">script</h2>
        <p>The output of a script in any language. <code>args</code> is a list: the
        interpreter first, then the script and its arguments.</p>
        <pre>vars:
              - name: output
                type: script
                params:
                  args:
                    - python3
                    - /path/to/script.py</pre>
        <p>Path wildcards: <code>%CONFIG%</code> (the espanso config directory),
        <code>%HOME%</code>, and <code>%PACKAGES%</code>. <code>trim</code>,
        <code>debug</code>, and <code>ignore_error</code> work as in the shell type,
        and earlier variables arrive as <code>ESPANSO_</code> environment variables
        too.</p>
        <p class="note">An argument that itself contains spaces cannot be typed in
        the editor's space-separated field — add it by editing the YAML by hand, or
        keep the arg in a script file.</p>
        """

    private static let randomSection = """
        <h2 id="var-random">random</h2>
        <p>One of several values, chosen at random each time the snippet fires. The
        editor's <strong>Choices</strong> box holds one choice per line.</p>
        <pre>vars:
              - name: greeting
                type: random
                params:
                  choices:
                    - "Hey"
                    - "Hi there"
                    - "Hello"</pre>
        """

    private static let formSection = """
        <h2 id="var-form">form</h2>
        <p>A form variable belongs to a form match: the layout and its fields are
        edited in this app's own <strong>Form</strong> section, and field values are
        referenced as <code>{{formname.fieldname}}</code>.</p>
        <p>See the <a href="https://espanso.org/docs/matches/forms/">forms
        documentation</a> for the YAML behind it.</p>
        """

    private static let echoSection = """
        <h2 id="var-echo">echo</h2>
        <p>A fixed value. Mostly used to name a piece of text once and reuse it —
        especially as a <code>global_vars</code> entry shared by several matches,
        which this app preserves from the YAML.</p>
        <pre>vars:
              - name: myname
                type: echo
                params:
                  echo: "John"</pre>
        """

    private static let choiceSection = """
        <h2 id="var-choice">choice</h2>
        <p>Opens a selection dialog each time the snippet fires. This app shows its
        settings read-only; the shapes it round-trips:</p>
        <pre>params:
              values:
                - "First option"
                - "Second option"</pre>
        <p>Or separate the label shown from the value inserted with
        <code>label</code>/<code>id</code> pairs:</p>
        <pre>params:
              values:
                - label: "Show this"
                  id: "insert this"</pre>
        """
}
