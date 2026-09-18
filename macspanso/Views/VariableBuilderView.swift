// macspanso/Views/VariableBuilderView.swift
import SwiftUI

struct VariableBuilderView: View {
    @Binding var vars: [EspansoVar]?
    @State private var showTypePicker = false
    @State private var showHelp = false
    /// Stable row identities parallel to `vars` — index-based ForEach identity
    /// makes SwiftUI reuse row state (focus, text fields) across deletions.
    @State private var entryIDs: [UUID] = []

    private var varList: [EspansoVar] { vars ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Variables")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                // Reachable with zero variables — help must exist before the
                // first card does, or a new match has no way to learn the syntax.
                Button {
                    showHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Variable quick reference")

                Spacer()
            }

            ForEach(Array(zip(entryIDs, varList.indices)), id: \.0) { _, i in
                VarCardView(
                    variable: Binding(
                        get: { i < (vars?.count ?? 0) ? vars![i] : EspansoVar(name: "", type: .echo) },
                        set: { newValue in
                            if vars == nil { vars = [] }
                            if i < vars!.count { vars![i] = newValue }
                        }
                    ),
                    onDelete: {
                        if i < (vars?.count ?? 0) {
                            vars?.remove(at: i)
                            entryIDs.remove(at: i)
                            if vars?.isEmpty == true { vars = nil }
                        }
                    }
                )
            }

            Button {
                showTypePicker = true
            } label: {
                Label("Add variable", systemImage: "plus.circle")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .onAppear { syncEntryIDs() }
        .onChange(of: varList.count) { _ in syncEntryIDs() }
        .sheet(isPresented: $showHelp) {
            VariableHelpSheet(type: nil)
        }
        .sheet(isPresented: $showTypePicker) {
            VarTypePickerSheet { type in
                let existing = Set(varList.map(\.name))
                var n = varList.count + 1
                while existing.contains("var\(n)") { n += 1 }
                let newVar = EspansoVar(name: "var\(n)", type: type)
                if vars == nil { vars = [] }
                vars?.append(newVar)
                entryIDs.append(UUID())
                showTypePicker = false
            }
        }
    }

    /// Re-sync after external mutations (e.g. the editor re-initializing the draft).
    private func syncEntryIDs() {
        if entryIDs.count != varList.count {
            entryIDs = varList.map { _ in UUID() }
        }
    }
}

struct VarCardView: View {
    @Binding var variable: EspansoVar
    let onDelete: () -> Void

    /// Types with no help section: `match` has no espanso extension behind it,
    /// and an unknown type added after this build has nothing to document.
    private var hasHelp: Bool {
        VariableHelpContent.anchor(for: variable.type) != nil
    }

    @State private var showHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("name", text: $variable.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: 160)

                Text(variable.type.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                if hasHelp {
                    Button {
                        showHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Quick reference for this variable type")
                }

                Spacer()

                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            // Type-specific param fields
            paramFields
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        .sheet(isPresented: $showHelp) {
            VariableHelpSheet(type: variable.type)
        }
    }

    @ViewBuilder
    private var paramFields: some View {
        switch variable.type {
        case .date:
            paramTextField(key: "format", placeholder: "%Y-%m-%d", label: "Format")
        case .shell:
            paramTextField(key: "cmd", placeholder: "date +%s", label: "Command")
        case .script:
            scriptArgsField
        case .random:
            randomChoicesField
        case .echo:
            paramTextField(key: "echo", placeholder: "static value", label: "Value")
        case .clipboard, .form, .match:
            EmptyView()
        case .choice, .unknown:
            readOnlyParamsNote
        }
    }

    /// espanso shapes macspanso has no editor for — a `choice` var's list of
    /// label/id mappings, or a type espanso added after this build. Saying so is
    /// better than an empty pane that implies there is nothing to keep: the params
    /// round-trip untouched either way.
    private var readOnlyParamsNote: some View {
        Label("Settings for this variable are kept as they are in the file.",
              systemImage: "lock")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func paramTextField(
        key: String,
        placeholder: String,
        label: String,
        displayValue: ((YAMLAny) -> String?)? = nil,
        storeValue: ((String) -> YAMLAny)? = nil
    ) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            TextField(placeholder, text: Binding(
                get: {
                    guard let param = variable.params?[key] else { return "" }
                    if let displayValue, let shown = displayValue(param) { return shown }
                    return param.stringValue ?? ""
                },
                set: { v in
                    if variable.params == nil { variable.params = [:] }
                    variable.params?[key] = storeValue?(v) ?? .string(v)
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
        }
    }

    private var randomChoicesField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Choices (one per line)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: {
                    guard case .array(let arr) = variable.params?["choices"] else { return "" }
                    // Non-string entries can't be shown as lines; skip them rather
                    // than render them wrong. Editing here rewrites the whole list.
                    return arr.compactMap(\.stringValue).joined(separator: "\n")
                },
                set: { text in
                    let choices = text.components(separatedBy: "\n").map(YAMLAny.string)
                    if variable.params == nil { variable.params = [:] }
                    variable.params?["choices"] = .array(choices)
                }
            ))
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 60)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
        }
    }

    /// espanso's script extension requires `args` to be a YAML sequence
    /// (`Value::Array` in espanso-render's script.rs) — a plain string fails with
    /// "missing 'args' parameter" at expansion time, so this field reads the list
    /// (or a legacy string, for files written before the fix) joined with spaces,
    /// and saves a space-split list. An argument containing spaces can't be
    /// expressed here; the help sheet says to add those by hand.
    private var scriptArgsField: some View {
        paramTextField(
            key: "args",
            placeholder: "python3 /path/to/script.py",
            label: "Args (space-separated)",
            displayValue: { param in
                switch param {
                case .array(let items):
                    return items.compactMap(\.stringValue).joined(separator: " ")
                case .string(let s):
                    return s
                default:
                    return nil
                }
            },
            storeValue: { text in
                .array(text.split(separator: " ", omittingEmptySubsequences: true)
                    .map { .string(String($0)) })
            }
        )
    }
}

struct VarTypePickerSheet: View {
    let onSelect: (VarType) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var helpType: VarType?

    private let descriptions: [VarType: String] = [
        .date:      "Current date/time with a strftime format",
        .clipboard: "Current clipboard contents",
        .shell:     "Output of a shell command",
        .script:    "Output of a script file",
        .random:    "Random choice from a list",
        .form:      "Form field (for use inside a form match)",
        .echo:      "A static string value",
        .match:     "Re-uses the output of another match",
        .choice:    "Pick from a list of labelled options",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add Variable")
                .font(.headline)
                .padding(16)

            Divider()

            ForEach(VarType.known, id: \.self) { type in
                HStack(spacing: 0) {
                    Button {
                        onSelect(type)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(type.rawValue)
                                    .font(.body)
                                    .fontWeight(.medium)
                                Text(descriptions[type] ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                                .imageScale(.small)
                        }
                        .padding(.leading, 16)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Read the type's reference before committing to it — a
                    // sibling of the selection button, not nested inside it,
                    // so the clicks can't be confused. Hidden for types with
                    // no help section (`match` has no espanso extension).
                    if VariableHelpContent.anchor(for: type) != nil {
                        Button {
                            helpType = type
                        } label: {
                            Image(systemName: "questionmark.circle")
                                .foregroundStyle(.secondary)
                                .imageScale(.small)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color.primary.opacity(0.05))
                Divider()
            }

            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)
                .padding(16)
        }
        .frame(width: 320, height: 520)
        .popover(
            isPresented: Binding(
                get: { helpType != nil },
                set: { if !$0 { helpType = nil } }
            ),
            arrowEdge: .trailing
        ) {
            VariableHelpWebView(type: helpType)
                .frame(width: 560, height: 480)
        }
    }
}
