// macspanso/Views/FileTreeView.swift
import SwiftUI

/// The grouped match list: matches are grouped by the file that defines them,
/// with subdirectories as one collapsible level above the files. Search narrows
/// both files and matches; parse-errored files stay visible in every state so
/// the user can't lose track of a file the app can't edit.
struct FileTreeView: View {
    @ObservedObject var store: EspansoConfigStore
    @Binding var selectedMatchIDs: Set<UUID>
    var searchText: String = ""
    @State private var actionError: String?
    @State private var collapsedFolders: Set<String> = []
    /// The file label currently under a drag — highlights the drop target.
    @State private var dropTargetURL: URL?
    /// Group being renamed/deleted; non-nil drives the sheet and the dialog.
    @State private var renameTarget: MatchFile?
    @State private var renameText: String = ""
    @State private var deleteTarget: MatchFile?

    private var isSearching: Bool { !searchText.isEmpty }

    private var conflictingFileURLs: Set<URL> {
        Set(store.triggerConflicts().flatMap { $0.occurrences.map(\.fileURL) })
    }

    var body: some View {
        // Hoisted once per render: conflictingFileURLs rebuilds the whole
        // cross-file conflict map, so reading it inside fileLabel made that
        // O(files × all matches) on every body evaluation — including every
        // keystroke in the search field. MatchListView.flatList does the same.
        let conflicted = conflictingFileURLs
        // Use List(selection:) so rows highlight correctly on macOS.
        // Package matches get no .tag, preventing them from being selected
        // (allMatches excludes package files, so the editor panel can't display them).
        return List(selection: $selectedMatchIDs) {
            ForEach(visibleGroups) { group in
                if let folderPath = group.folderPath {
                    folderSection(group, folderPath: folderPath, conflicted: conflicted)
                } else {
                    ForEach(group.files, id: \.id) { file in
                        Section {
                            fileBodyRows(file)
                        } header: {
                            fileLabel(file, conflicted: conflicted)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .sheet(item: $renameTarget) { file in
            RenameGroupSheet(name: $renameText) { commitRename(file) } onCancel: {
                renameTarget = nil
            }
        }
        .confirmationDialog(
            "Delete Group",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { file in
            deleteDialogButtons(for: file)
        } message: { file in
            deleteDialogMessage(for: file)
        }
        .alert("Action Failed", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - Filtering

    private var visibleGroups: [EspansoConfigStore.FileGroup] {
        store.groupedFiles.compactMap { group in
            let files = isSearching
                ? group.files.filter { file in
                    // Parse-errored files hold no matches to search, but the
                    // warning must not vanish the moment the user types.
                    file.parseError != nil ||
                    file.matches.contains { MatchListView.matchesSearch($0, searchText) }
                }
                : group.files
            guard !files.isEmpty else { return nil }
            return EspansoConfigStore.FileGroup(folderPath: group.folderPath, files: files)
        }
    }

    private func visibleMatches(in file: MatchFile) -> [EspansoMatch] {
        isSearching ? file.matches.filter { MatchListView.matchesSearch($0, searchText) } : file.matches
    }

    // MARK: - Sections

    /// A subdirectory: one collapsible row, its files beneath it.
    private func folderSection(
        _ group: EspansoConfigStore.FileGroup,
        folderPath: String,
        conflicted: Set<URL>
    ) -> some View {
        Section {
            DisclosureGroup(isExpanded: expansion(for: folderPath)) {
                ForEach(group.files, id: \.id) { file in
                    fileLabel(file, conflicted: conflicted)
                    fileBodyRows(file)
                }
            } label: {
                HStack {
                    Image(systemName: "folder")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                    Text(folderPath)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer()
                    Text("\(group.files.reduce(0) { $0 + visibleMatches(in: $1).count })")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Rows for everything beneath a file label: its matches, plus the
    /// placeholder and parse-error states.
    @ViewBuilder
    private func fileBodyRows(_ file: MatchFile) -> some View {
        ForEach(visibleMatches(in: file), id: \.id) { match in
            matchRow(match, in: file)
        }
        if file.matches.isEmpty && file.parseError == nil && !isSearching {
            Text("No matches")
                .foregroundStyle(.tertiary)
                .font(.caption)
        }
        if let error = file.parseError {
            Label("Parse error: \(error)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.caption)
        }
    }

    private func matchRow(_ match: EspansoMatch, in file: MatchFile) -> some View {
        MatchRowView(match: match)
            .foregroundStyle(file.isPackage ? .secondary : .primary)
            // Only non-package matches get a selection tag
            .ifLet(!file.isPackage) { $0.tag(match.id) }
            // Package matches can't be moved — no drag either.
            .ifLet(!file.isPackage) { view in
                view.onDrag {
                    NSItemProvider(object: match.id.uuidString as NSString)
                }
            }
            .contextMenu {
                if !file.isPackage {
                    Button("Duplicate") { duplicate(matchID: match.id) }
                    moveToMenu(for: match.id, currentURL: file.url)
                    Button("Delete", role: .destructive) { delete(matchID: match.id) }
                }
            }
    }

    /// The file's label with its status icons and match count — used both as
    /// a section header (root files) and as a row (files inside folders).
    /// Also the drop target for dragging matches between groups: dropping a
    /// match row here moves it into this file. Folders are deliberately not
    /// drop targets — with several files inside, the destination would be
    /// ambiguous.
    private func fileLabel(_ file: MatchFile, conflicted: Set<URL>) -> some View {
        HStack {
            if file.isPackage {
                Image(systemName: "lock")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            Text(store.displayLabel(for: file))
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
            Spacer()
            // Counts the rows actually shown: while searching, the badge must
            // agree with the matches beneath it rather than the file's total.
            Text("\(visibleMatches(in: file).count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if conflicted.contains(file.url) {
                Image(systemName: "exclamationmark.2")
                    .imageScale(.small)
                    .foregroundStyle(.orange)
                    .help("Has triggers also defined in another group")
            }
            if file.parseError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            // Package and parse-errored files refuse moves — don't invite drops.
            dropTargetURL == file.url && file.isDroppable
                ? Color.accentColor.opacity(0.15)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .dropDestination(for: String.self, action: { items, _ in
            guard file.isDroppable,
                  let idString = items.first,
                  let matchID = UUID(uuidString: idString) else { return false }
            move(matchID: matchID, to: file.url)
            return true
        }, isTargeted: { targeted in
            // Only clear the highlight if it is still ours: dragging from one
            // label onto another fires false on the label being left and true
            // on the one being entered in unspecified order, so an unguarded
            // nil here can wipe the highlight the new target just set.
            if targeted {
                if file.isDroppable { dropTargetURL = file.url }
            } else if dropTargetURL == file.url {
                dropTargetURL = nil
            }
        })
        .contextMenu {
            Button("Open in Editor") {
                NSWorkspace.shared.open(file.url)
            }
            if !file.isPackage {
                Button("Rename…") {
                    renameText = file.baseName
                    renameTarget = file
                }
                Button("Delete Group…", role: .destructive) {
                    deleteTarget = file
                }
            }
        }
    }

    // MARK: - Folder expansion

    private func expansion(for folderPath: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedFolders.contains(folderPath) },
            set: {
                if $0 {
                    collapsedFolders.remove(folderPath)
                } else {
                    collapsedFolders.insert(folderPath)
                }
            }
        )
    }

    // MARK: - Actions

    // MARK: - Rename / delete group

    private func commitRename(_ file: MatchFile) {
        do {
            try store.renameFile(at: file.url, to: renameText)
            renameTarget = nil
        } catch {
            renameTarget = nil
            actionError = error.localizedDescription
        }
    }

    private func deleteGroup(_ file: MatchFile, movingTo target: URL?) {
        do {
            try store.deleteFile(at: file.url, movingMatchesTo: target)
            // Only an outright delete destroys the matches. Moving them keeps
            // their UUIDs, so dropping the selection there would close an open
            // editor on a match that merely changed file.
            if target == nil {
                selectedMatchIDs.subtract(file.matches.map(\.id))
            }
            deleteTarget = nil
        } catch {
            deleteTarget = nil
            actionError = error.localizedDescription
        }
    }

    /// The dialog's buttons are the choices: one per destination group when the
    /// group has matches (nothing is deleted by choosing one), then the outright
    /// delete. A parse-errored group offers only outright delete — its contents
    /// are unreadable, so there's nothing to move.
    @ViewBuilder
    private func deleteDialogButtons(for file: MatchFile) -> some View {
        if file.isDroppable {
            let count = file.matches.count
            if count > 0 {
                ForEach(store.writableFiles.filter { $0.url != file.url }, id: \.url) { dest in
                    Button("Move \(count) match\(count == 1 ? "" : "es") to “\(store.displayLabel(for: dest))” and delete group") {
                        deleteGroup(file, movingTo: dest.url)
                    }
                }
                Button("Delete group and its \(count) match\(count == 1 ? "" : "es")", role: .destructive) {
                    deleteGroup(file, movingTo: nil)
                }
            } else {
                Button("Delete Group", role: .destructive) {
                    deleteGroup(file, movingTo: nil)
                }
            }
        } else {
            Button("Delete Group", role: .destructive) {
                deleteGroup(file, movingTo: nil)
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    private func deleteDialogMessage(for file: MatchFile) -> Text {
        if !file.isDroppable {
            return Text("This group's file couldn't be parsed, so its contents can't be moved — they will be permanently deleted.")
        }
        let count = file.matches.count
        if count > 0 {
            return Text("Choose where its \(count) match\(count == 1 ? "" : "es") should go, or delete them permanently.")
        }
        return Text("This group is empty. The file will be permanently deleted.")
    }

    @ViewBuilder
    private func moveToMenu(for matchID: UUID, currentURL: URL) -> some View {
        let candidates = store.writableFiles.filter { $0.url != currentURL }
        if !candidates.isEmpty {
            Menu("Move to") {
                ForEach(candidates, id: \.url) { file in
                    Button(store.displayLabel(for: file)) { move(matchID: matchID, to: file.url) }
                }
            }
        }
    }

    private func move(matchID: UUID, to url: URL) {
        do {
            try store.move(matchID: matchID, to: url)
            selectedMatchIDs = [matchID]
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func duplicate(matchID: UUID) {
        do {
            let copy = try store.duplicate(matchID: matchID)
            selectedMatchIDs = [copy.id]
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func delete(matchID: UUID) {
        do {
            try store.delete(matchID: matchID)
            selectedMatchIDs.remove(matchID)
        } catch {
            actionError = error.localizedDescription
        }
    }
}

// MARK: - Rename sheet

private struct RenameGroupSheet: View {
    @Binding var name: String
    let onRename: () -> Void
    let onCancel: () -> Void

    /// Mirrors `EspansoConfigStore.renameFile`'s own rule, so a name it would
    /// refuse simply leaves Rename disabled instead of arriving as an alert.
    private var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains("/")
            && trimmed != "." && trimmed != ".."
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Group")
                .font(.headline)
            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if isValid { onRename() } }
            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { onRename() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

// MARK: - View helper

private extension View {
    /// Conditionally applies a modifier. Used to apply .tag only when the condition is true.
    @ViewBuilder
    func ifLet(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition { transform(self) } else { self }
    }
}
