// macspanso/Views/MatchEditorForm.swift
import SwiftUI
import UniformTypeIdentifiers

struct MatchEditorForm: View {
    let initialMatch: EspansoMatch
    let sourceFile: MatchFile?
    let store: EspansoConfigStore
    let onSave: (EspansoMatch) -> Void
    let onCancel: () -> Void

    @State private var draft: EspansoMatch
    @State private var useRegex: Bool
    @State private var isFormMatch: Bool
    @State private var validationErrors: [ValidationError] = []
    @State private var saveError: String? = nil
    @State private var showUnsavedAlert: Bool = false
    @State private var triggerEntryIDs: [UUID] = []
    @State private var savedTriggers: [String]? = nil
    @State private var destinationURL: URL? = nil
    @State private var regexTestInput: String = ""
    /// Held as raw text rather than derived from `draft.searchTerms`: a binding that
    /// re-rendered the parsed array would swallow the comma as the user typed it,
    /// making a second term impossible to enter.
    @State private var searchTermsText: String

    init(
        match: EspansoMatch,
        sourceFile: MatchFile?,
        store: EspansoConfigStore,
        onSave: @escaping (EspansoMatch) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialMatch = match
        self.sourceFile = sourceFile
        self.store = store
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: match)
        _useRegex = State(initialValue: match.regex != nil)
        _isFormMatch = State(initialValue: match.form != nil)
        _triggerEntryIDs = State(initialValue: (match.triggers ?? []).map { _ in UUID() })
        _searchTermsText = State(
            initialValue: (match.searchTerms ?? []).joined(separator: ", "))
    }

    private var isNew: Bool { sourceFile == nil }
    private var isDirty: Bool { draft != initialMatch }
    private var canSave: Bool { validationErrors.isEmpty && (isDirty || groupChanged) }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNew ? "New Match" : "Edit Match")
                        .font(.headline)
                    if let file = store.file(containing: draft.id) {
                        Text(store.displayLabel(for: file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(16)
            .background(.background)

            Divider()

            // Form body
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    destinationSection
                    triggerSection
                    replacementSection
                    if !isFormMatch {
                        VariableBuilderView(vars: $draft.vars)
                    }
                    optionsSection
                }
                .padding(20)
            }

            // Error summary
            if let err = saveError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            Divider()

            // Save bar
            HStack {
                Spacer()
                Button("Cancel") {
                    if isDirty {
                        showUnsavedAlert = true
                    } else {
                        onCancel()
                    }
                }
                .buttonStyle(.bordered)

                Button("Save Match") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(16)
        }
        .onChange(of: draft) { _ in revalidate() }
        .alert("Unsaved Changes", isPresented: $showUnsavedAlert) {
            Button("Save") { save() }
            Button("Discard", role: .destructive) { onCancel() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save changes to \(draft.primaryTrigger)?")
        }
    }

    // MARK: - Sections

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(isNew ? "Save to" : "Group", systemImage: "folder")
                .sectionHeader()

            HStack(spacing: 8) {
                Picker("", selection: destinationBinding) {
                    ForEach(store.writableFiles, id: \.url) { file in
                        Text(store.displayLabel(for: file)).tag(Optional(file.url))
                    }
                    // A destination chosen via New File… isn't in writableFiles
                    // until it exists — without this item the picker renders
                    // blank and the choice the user just made looks lost.
                    if let dest = destinationURL,
                       !store.writableFiles.contains(where: { $0.url == dest }) {
                        Text(store.displayLabel(for: MatchFile(url: dest, matches: [], isPackage: false))
                                + " (new group)").tag(Optional(dest))
                    }
                    if store.writableFiles.isEmpty {
                        Text("base.yml").tag(Optional(defaultDestination))
                    }
                }
                .labelsHidden()

                Button {
                    promptForNewFile()
                } label: {
                    Label("New Group…", systemImage: "folder.badge.plus")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
        // Only new matches hydrate a destination: for an existing match the
        // picker already defaults to the file holding it, and pulling
        // lastDestinationFilePath here would silently arm a move.
        .onAppear { if isNew { hydrateDestination() } }
    }

    private var defaultDestination: URL {
        store.matchDirectory.appendingPathComponent("base.yml")
    }

    /// The file that currently holds this match — looked up live rather than
    /// from the captured `sourceFile`, so a group renamed or deleted while the
    /// form is open can't leave a stale URL here (a stale URL would make the
    /// next Save move the match back to the old path).
    private var currentFileURL: URL? {
        isNew ? nil : store.file(containing: draft.id)?.url
    }

    /// The group the match will live in after save. For a new match that's the
    /// picked destination (or base.yml); for an existing match it defaults to
    /// the file that already holds it.
    private var effectiveDestination: URL {
        if isNew { return destinationURL ?? defaultDestination }
        return destinationURL ?? currentFileURL ?? defaultDestination
    }

    /// True when an existing match's group was changed in the picker — the
    /// move is applied on Save, so it alone must enable the Save button.
    private var groupChanged: Bool {
        !isNew && effectiveDestination != currentFileURL
    }

    private var destinationBinding: Binding<URL?> {
        Binding(
            get: { effectiveDestination },
            set: { destinationURL = $0 }
        )
    }

    private func hydrateDestination() {
        guard destinationURL == nil else { return }
        if let path = Preferences.shared.lastDestinationFilePath {
            let candidate = URL(fileURLWithPath: path)
            if store.writableFiles.contains(where: { $0.url == candidate }) {
                destinationURL = candidate
                return
            }
        }
        if let base = store.writableFiles.first(where: { $0.displayName == "base.yml" }) {
            destinationURL = base.url
        } else {
            destinationURL = store.writableFiles.first?.url ?? defaultDestination
        }
    }

    private func promptForNewFile() {
        let panel = NSSavePanel()
        panel.directoryURL = store.matchDirectory
        // A dynamic type whose preferred extension is "yml" — the panel then
        // appends .yml to a bare typed name, so what the panel shows is what
        // gets created. (.yaml would also load in espanso, but the displayed
        // name must not differ from the created one.)
        panel.allowedContentTypes = [UTType(filenameExtension: "yml") ?? .yaml]
        panel.nameFieldStringValue = "untitled.yml"
        panel.message = "Create a new match group"
        if panel.runModal() == .OK, let url = panel.url {
            // Coerce regardless — belt and braces against the panel returning
            // anything espanso wouldn't load.
            destinationURL = Self.withYMLExtension(url)
        }
    }

    /// The URL re-pointed at .yml: strips whatever extension it has (including
    /// none) and appends yml. Typing `email` in the save panel must yield
    /// `email.yml`, never a bare `email` espanso would ignore.
    private static func withYMLExtension(_ url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("yml")
    }

    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Trigger", systemImage: "keyboard")
                .sectionHeader()

            HStack(spacing: 8) {
                TextField(useRegex ? "Regex pattern…" : "e.g. ::hello", text: triggerBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                Picker("", selection: $useRegex) {
                    Text("Text").tag(false)
                    Text("Regex").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .onChange(of: useRegex) { regex in
                    if regex {
                        savedTriggers = TriggerModeTransition.toRegex(&draft)
                        triggerEntryIDs = []
                    } else {
                        TriggerModeTransition.toText(&draft, restoring: savedTriggers)
                        triggerEntryIDs = (draft.triggers ?? []).map { _ in UUID() }
                        savedTriggers = nil
                    }
                }
            }

            // Alternate triggers (multi-trigger). Up/down arrows reorder; the first
            // trigger is the "primary" and renders in the main field above.
            if !useRegex {
                let triggerCount = draft.triggers?.count ?? 0
                ForEach(Array(zip(triggerEntryIDs, (draft.triggers ?? []).indices)), id: \.0) { _, i in
                    HStack(spacing: 4) {
                        Button {
                            moveTrigger(from: i, to: i - 1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(i == 0)
                        .help("Move up")

                        Button {
                            moveTrigger(from: i, to: i + 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(i == triggerCount - 1)
                        .help("Move down")

                        TextField("Alternate trigger…", text: Binding(
                            get: { draft.triggers?[i] ?? "" },
                            set: { if i < (draft.triggers?.count ?? 0) { draft.triggers?[i] = $0 } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                        Button {
                            if i < (draft.triggers?.count ?? 0) {
                                draft.triggers?.remove(at: i)
                                triggerEntryIDs.remove(at: i)
                                if draft.triggers?.isEmpty == true { draft.triggers = nil }
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }

                Button {
                    if draft.triggers == nil {
                        // Promote single trigger to multi-trigger
                        var ts = draft.trigger.map { [$0] } ?? []
                        ts.append("")
                        draft.triggers = ts
                        draft.trigger = nil
                        triggerEntryIDs = ts.map { _ in UUID() }
                    } else {
                        draft.triggers?.append("")
                        triggerEntryIDs.append(UUID())
                    }
                } label: {
                    Label("Add alternate trigger", systemImage: "plus.circle")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            validationLabel(for: .emptyTrigger, message: "Trigger is required")
            validationLabel(for: .duplicateTrigger, message: "This trigger already exists")

            if useRegex { regexTesterSection }
        }
    }

    private var regexTesterSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Test input")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            TextField("Type something the pattern should match…", text: $regexTestInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            regexTestResult
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var regexTestResult: some View {
        let pattern = draft.regex ?? ""
        if pattern.isEmpty || regexTestInput.isEmpty {
            EmptyView()
        } else if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(regexTestInput.startIndex..., in: regexTestInput)
            let matches = regex.matches(in: regexTestInput, range: range)
            if matches.isEmpty {
                Label("No match", systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("\(matches.count) match\(matches.count == 1 ? "" : "es")",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                ForEach(Array(matches.enumerated()), id: \.offset) { idx, m in
                    if let r = Range(m.range, in: regexTestInput) {
                        Text("[\(idx)] \(String(regexTestInput[r]))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Label("Invalid regex pattern", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var replacementSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Replacement", systemImage: "text.alignleft")
                    .sectionHeader()
                Spacer()
                Picker("", selection: $isFormMatch) {
                    Text("Text").tag(false)
                    Text("Form").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .onChange(of: isFormMatch) { wantsForm in
                    if wantsForm {
                        draft.form = draft.replace ?? ""
                        draft.replace = nil
                    } else {
                        draft.replace = draft.form ?? ""
                        draft.form = nil
                        draft.formFields = nil
                    }
                }
            }

            if isFormMatch {
                FormFieldsSection(
                    formTemplate: Binding(
                        get: { draft.form ?? "" },
                        set: { draft.form = $0.isEmpty ? nil : $0 }
                    ),
                    formFields: Binding(
                        get: { draft.formFields ?? [:] },
                        set: { draft.formFields = $0.isEmpty ? nil : $0 }
                    )
                )
                validationLabel(for: .emptyFormTemplate, message: "Form template is required")
            } else {
                TextEditor(text: Binding(
                    get: { draft.replace ?? "" },
                    set: { draft.replace = $0.isEmpty ? nil : $0 }
                ))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))

                ForEach(unresolvedVarErrors, id: \.self) { varName in
                    Label("{{\(varName)}} is not declared as a variable", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                ForEach(invalidVarNames, id: \.self) { name in
                    Label("Variable name '\(name)' is invalid — espanso can only reference letters, digits, and underscores", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                ForEach(duplicateVarNames, id: \.self) { name in
                    Label("Variable name '\(name)' is used more than once", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                validationLabel(for: .emptyShellCmd, message: "Shell variable needs a command")
            }

            previewSection
        }
    }

    private var previewSection: some View {
        let preview = MatchExpander.preview(of: draft)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "eye")
                Text("Preview")
            }
            .sectionHeader()

            Text(preview.isEmpty ? "—" : preview)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(preview.isEmpty ? .tertiary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .textSelection(.enabled)

            if previewHasUnexecutedVars {
                Label("Shell, script, and random values are placeholders in preview.",
                      systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    private var previewHasUnexecutedVars: Bool {
        (draft.vars ?? []).contains { v in
            v.type == .shell || v.type == .script || v.type == .random
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Options")
                .sectionHeader()

            // The match list and Quick Switcher both search `label`, so until now
            // they filtered on a field that couldn't be set anywhere in the app.
            TextField("Label (optional)", text: optionalStringBinding(\.label))
                .textFieldStyle(.roundedBorder)

            Toggle("Word boundary", isOn: Binding(
                get: { draft.word ?? false },
                set: { draft.word = $0 ? true : nil }
            ))
            Toggle("Propagate case", isOn: Binding(
                get: { draft.propagateCase ?? false },
                set: { draft.propagateCase = $0 ? true : nil }
            ))

            advancedSection
        }
    }

    /// espanso keys that matter but shouldn't lengthen the default form. Every
    /// control writes `nil` rather than a falsy value, so an option the user never
    /// touches leaves no key in the YAML at all.
    private var advancedSection: some View {
        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Match only at start of word", isOn: Binding(
                    get: { draft.leftWord ?? false },
                    set: { draft.leftWord = $0 ? true : nil }
                ))
                Toggle("Match only at end of word", isOn: Binding(
                    get: { draft.rightWord ?? false },
                    set: { draft.rightWord = $0 ? true : nil }
                ))

                choicePicker("Capitalisation", key: \.uppercaseStyle, options: [
                    ChoiceOption(id: "capitalize",       title: "Capitalize"),
                    ChoiceOption(id: "capitalize_words", title: "Capitalize Words"),
                    ChoiceOption(id: "uppercase",        title: "UPPERCASE"),
                ])
                .help("Used with Propagate case to decide how a capitalised trigger is echoed.")

                // espanso itself warns about this combination and pops its
                // troubleshooting window: "specifying the 'uppercase_style' option
                // without 'propagate_case' has no effect". Say so before the file is
                // written rather than letting espanso complain afterwards.
                if draft.uppercaseStyle != nil && draft.propagateCase != true {
                    Label("Capitalisation has no effect unless Propagate case is on",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                choicePicker("Injection", key: \.forceMode, options: [
                    ChoiceOption(id: "clipboard", title: "Clipboard"),
                    ChoiceOption(id: "keys",      title: "Keystrokes"),
                ])
                .help("Clipboard pastes the replacement in one go — the fix for long or multi-line text in slow apps.")

                VStack(alignment: .leading, spacing: 2) {
                    TextField("Search terms (comma separated)", text: $searchTermsText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: searchTermsText) { text in
                            let terms = text.split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                            draft.searchTerms = terms.isEmpty ? nil : terms
                        }
                    Text("Extra words that find this match in espanso's own search bar.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                TextField("Comment (optional)", text: optionalStringBinding(\.comment))
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.top, 6)
        }
    }

    // MARK: - Optional-field bindings
    //
    // espanso omits what it doesn't need, and so must we: writing `false` or `""`
    // would add a key the user never asked for and churn the file on every save.

    private func optionalStringBinding(
        _ key: WritableKeyPath<EspansoMatch, String?>
    ) -> Binding<String> {
        Binding(
            get: { draft[keyPath: key] ?? "" },
            set: {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                draft[keyPath: key] = trimmed.isEmpty ? nil : $0
            }
        )
    }

    struct ChoiceOption: Identifiable {
        let id: String      // the espanso value, e.g. "capitalize_words"
        let title: String
    }

    /// A picker over espanso's documented values that also tolerates one it doesn't
    /// know. `uppercase_style` and `force_mode` are stored as String precisely so a
    /// value espanso adds later survives a round trip; without a matching tag the
    /// Picker would render blank and log a tag-mismatch warning, so the file would
    /// look empty while still holding a value. Show the raw value instead.
    private func choicePicker(
        _ title: String,
        key: WritableKeyPath<EspansoMatch, String?>,
        options: [ChoiceOption]
    ) -> some View {
        let current = draft[keyPath: key] ?? ""
        let isUnrecognised = !current.isEmpty && !options.contains { $0.id == current }
        return Picker(title, selection: optionalChoiceBinding(key)) {
            Text("Default").tag("")
            ForEach(options) { Text($0.title).tag($0.id) }
            if isUnrecognised { Text(current).tag(current) }
        }
    }

    /// Pickers can't select nil, so "Default" is the empty tag and maps back to nil.
    private func optionalChoiceBinding(
        _ key: WritableKeyPath<EspansoMatch, String?>
    ) -> Binding<String> {
        Binding(
            get: { draft[keyPath: key] ?? "" },
            set: { draft[keyPath: key] = $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: - Helpers

    private func moveTrigger(from source: Int, to destination: Int) {
        guard var triggers = draft.triggers else { return }
        guard triggers.indices.contains(source), triggers.indices.contains(destination)
        else { return }
        triggers.swapAt(source, destination)
        draft.triggers = triggers
        triggerEntryIDs.swapAt(source, destination)
    }

    private var triggerBinding: Binding<String> {
        Binding(
            get: { draft.trigger ?? draft.regex ?? draft.triggers?.first ?? "" },
            set: { v in
                if useRegex { draft.regex = v }
                else if draft.triggers?.isEmpty == false { draft.triggers?[0] = v }
                else { draft.trigger = v }
            }
        )
    }

    private var unresolvedVarErrors: [String] {
        validationErrors.compactMap {
            if case .unresolvedVarReference(let name) = $0 { return name }
            return nil
        }
    }

    private var invalidVarNames: [String] {
        validationErrors.compactMap {
            if case .invalidVarName(let name) = $0 { return name }
            return nil
        }
    }

    private var duplicateVarNames: [String] {
        validationErrors.compactMap {
            if case .duplicateVarName(let name) = $0 { return name }
            return nil
        }
    }

    private func revalidate() {
        var errors = MatchValidator.validate(
            draft,
            existingMatches: store.allMatches.filter { $0.id != draft.id },
            globalVarNames: Set(store.globalVarNames)
        )
        // In form mode, {{name}} placeholders refer to form fields, not vars — suppress false positives.
        if isFormMatch {
            errors = errors.filter { if case .unresolvedVarReference = $0 { return false }; return true }
        }
        validationErrors = errors
    }

    @ViewBuilder
    private func validationLabel(for error: ValidationError, message: String) -> some View {
        if validationErrors.contains(error) {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func save() {
        revalidate()
        guard validationErrors.isEmpty else { return }
        var matchToSave = draft
        // Silently strip empty strings from dropdown option lists before writing to disk.
        if let fields = matchToSave.formFields, !fields.isEmpty {
            var cleaned: [String: FormField] = [:]
            for (name, field) in fields {
                guard field.isDropdown else { cleaned[name] = field; continue }
                var f = field
                f.values = (f.values ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if !(f.values?.isEmpty ?? true) { cleaned[name] = f }
            }
            matchToSave.formFields = cleaned.isEmpty ? nil : cleaned
        }
        do {
            if isNew {
                let target = destinationURL ?? defaultDestination
                try store.add(matchToSave, to: target)
                Preferences.shared.lastDestinationFilePath = target.path
            } else {
                // Move first, then update: update() locates the match by id, so
                // after the move it writes the draft into the destination file.
                if groupChanged {
                    try store.move(matchID: matchToSave.id, to: effectiveDestination)
                }
                // A group-only change needs no rewrite — move() already
                // persisted the stored content to the destination.
                if isDirty {
                    try store.update(matchToSave)
                }
            }
            saveError = nil
            onSave(matchToSave)
        } catch {
            saveError = error.localizedDescription
        }
    }
}

// MARK: - Section header styling

private struct SectionHeaderStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

private extension View {
    func sectionHeader() -> some View { modifier(SectionHeaderStyle()) }
}
