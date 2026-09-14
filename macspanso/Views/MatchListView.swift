// macspanso/Views/MatchListView.swift
import SwiftUI

enum MatchListSort: String, CaseIterable, Identifiable {
    case fileOrder, triggerAsc, triggerDesc
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fileOrder:    return "File order"
        case .triggerAsc:   return "Trigger A → Z"
        case .triggerDesc:  return "Trigger Z → A"
        }
    }
}

enum MatchListFilter: String, CaseIterable, Identifiable {
    case all, text, form, regex, hasVars
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all:      return "All"
        case .text:     return "Text"
        case .form:     return "Form"
        case .regex:    return "Regex"
        case .hasVars:  return "Vars"
        }
    }
    func matches(_ m: EspansoMatch) -> Bool {
        switch self {
        case .all:     return true
        case .text:    return m.regex == nil && m.form == nil
        case .form:    return m.form != nil
        case .regex:   return m.regex != nil
        case .hasVars: return !(m.vars ?? []).isEmpty
        }
    }
}

struct MatchListView: View {
    @ObservedObject var store: EspansoConfigStore
    @Binding var selectedMatchIDs: Set<UUID>
    @Binding var isCreatingNew: Bool
    @Binding var searchText: String
    @State private var deleteError: String?
    @State private var duplicateError: String?
    @State private var confirmMultiDelete = false
    // Grouped-by-file is the default; the toolbar folder button flips to the flat list.
    @AppStorage(Preferences.Key.listGrouped) private var listGrouped: Bool = true
    @AppStorage(Preferences.Key.listSort) private var sortRaw: String = MatchListSort.fileOrder.rawValue
    @State private var filter: MatchListFilter = .all

    /// Single home for the match-list search predicate: the flat list and the
    /// grouped view must agree on it, or search behaves differently per view mode.
    static func matchesSearch(_ match: EspansoMatch, _ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        return match.primaryTrigger.localizedCaseInsensitiveContains(text) ||
               match.replacementPreview.localizedCaseInsensitiveContains(text) ||
               (match.label ?? "").localizedCaseInsensitiveContains(text)
    }

    private var singleSelectedMatchID: UUID? {
        selectedMatchIDs.count == 1 ? selectedMatchIDs.first : nil
    }

    private var sort: MatchListSort {
        MatchListSort(rawValue: sortRaw) ?? .fileOrder
    }

    private var filteredMatches: [EspansoMatch] {
        var results = store.allMatches.filter(filter.matches)
        results = results.filter { Self.matchesSearch($0, searchText) }
        switch sort {
        case .fileOrder:
            return results
        case .triggerAsc:
            return results.sorted { $0.primaryTrigger.localizedCompare($1.primaryTrigger) == .orderedAscending }
        case .triggerDesc:
            return results.sorted { $0.primaryTrigger.localizedCompare($1.primaryTrigger) == .orderedDescending }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            // The filter chips only drive the flat list's type filters;
            // the grouped view narrows by file instead.
            if !listGrouped {
                filterBar
            }
            Divider()

            if listGrouped {
                FileTreeView(
                    store: store,
                    selectedMatchIDs: $selectedMatchIDs,
                    searchText: searchText
                )
            } else {
                flatList
            }

            Divider()
            toolbar
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Pieces

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search matches…", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(MatchListFilter.allCases) { f in
                    FilterChip(
                        label: f.label,
                        selected: filter == f
                    ) {
                        filter = f
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button {
                selectedMatchIDs = []
                isCreatingNew = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("New match")

            Button {
                // Deleting many matches at once is unrecoverable — confirm first.
                if selectedMatchIDs.count > 1 {
                    confirmMultiDelete = true
                } else {
                    deleteSelected()
                }
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.plain)
            .help(selectedMatchIDs.count > 1 ? "Delete \(selectedMatchIDs.count) matches" : "Delete selected match")
            .disabled(selectedMatchIDs.isEmpty)
            .confirmationDialog(
                "Delete \(selectedMatchIDs.count) matches?",
                isPresented: $confirmMultiDelete
            ) {
                Button("Delete \(selectedMatchIDs.count) Matches", role: .destructive) {
                    deleteSelected()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes them from your espanso files.")
            }
            .alert("Delete Failed", isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )) {
                Button("OK") { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
            .alert("Duplicate Failed", isPresented: Binding(
                get: { duplicateError != nil },
                set: { if !$0 { duplicateError = nil } }
            )) {
                Button("OK") { duplicateError = nil }
            } message: {
                Text(duplicateError ?? "")
            }

            // The sort menu only affects the flat list; in the grouped view,
            // order is inherent (root files first, folders A → Z), so hide it
            // rather than show a control that does nothing.
            if !listGrouped {
                Menu {
                    ForEach(MatchListSort.allCases) { option in
                        Button {
                            sortRaw = option.rawValue
                        } label: {
                            if sort == option {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort matches")
            }

            Spacer()

            Text(countLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                withAnimation { listGrouped.toggle() }
            } label: {
                Label(listGrouped ? "Grouped View" : "All", systemImage: listGrouped ? "folder" : "list.bullet")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help(listGrouped ? "Show flat list" : "Show groups")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var countLabel: String {
        let total = store.allMatches.count
        let shown = filteredMatches.count
        if shown == total {
            return "\(total) match\(total == 1 ? "" : "es")"
        } else {
            return "\(shown) of \(total)"
        }
    }

    /// Triggers defined in more than one file — espanso silently picks one.
    private var conflictedTriggers: Set<String> {
        Set(store.triggerConflicts().map(\.trigger))
    }

    private func hasConflict(_ match: EspansoMatch, in conflicted: Set<String>) -> Bool {
        if let t = match.trigger, conflicted.contains(t) { return true }
        if let ts = match.triggers, ts.contains(where: conflicted.contains) { return true }
        return false
    }

    private var flatList: some View {
        let conflicted = conflictedTriggers
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredMatches) { match in
                        flatRow(match, conflicted: conflicted)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .background(
                // Keyboard focus lives on this invisible anchor rather than on
                // the scroll view: a focused ScrollView draws a focus ring
                // around the whole pane, which reads as a stuck highlight.
                // The anchor itself would draw a ring too (opacity doesn't
                // suppress it), so it sits pushed out past the window's edge.
                Color.clear
                    .frame(width: 1, height: 1)
                    .focusable(true)
                    .focused($flatListFocused)
                    .onMoveCommand { direction in
                        if let id = MatchListSelection.handleMove(
                            direction, order: filteredMatches.map(\.id),
                            anchor: &flatSelectionAnchor, selection: &selectedMatchIDs) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                    .offset(x: -200, y: 0)
            )
            .background(
                // Hidden button so ⌘D works even when the row context menu is closed.
                Button("Duplicate") { duplicateSelected() }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(singleSelectedMatchID == nil)
                    .opacity(0)
                    .frame(width: 0, height: 0)
            )
        }
    }

    @State private var flatSelectionAnchor: UUID?
    @FocusState private var flatListFocused: Bool

    private func flatRow(_ match: EspansoMatch, conflicted: Set<String>) -> some View {
        let selected = selectedMatchIDs.contains(match.id)
        return MatchRowView(match: match, isConflicted: hasConflict(match, in: conflicted))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
            // Clicks ride SwiftUI's gesture machinery — the same path as the
            // context menu, which never misses. AppKit-level mouseDown
            // delivery to a background NSView dies after the first click in
            // this window; modifiers come from NSEvent.modifierFlags, which
            // tap gestures don't expose.
            .onTapGesture {
                flatListFocused = true
                MatchListSelection.handleClick(
                    MatchListSelection.route(fromModifiers: NSEvent.modifierFlags),
                    id: match.id, order: filteredMatches.map(\.id),
                    anchor: &flatSelectionAnchor, selection: &selectedMatchIDs)
            }
            .onDrag {
                NSItemProvider(object: match.id.uuidString as NSString)
            }
            .contextMenu { rowContextMenu(for: match.id) }
    }

    @ViewBuilder
    private func rowContextMenu(for matchID: UUID) -> some View {
        Button("Duplicate") {
            selectedMatchIDs = [matchID]
            duplicateSelected()
        }
        .keyboardShortcut("d", modifiers: .command)

        moveToMenu(for: matchID)

        Button("Delete", role: .destructive) {
            do {
                try store.deleteMatches([matchID])
                selectedMatchIDs.remove(matchID)
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func moveToMenu(for matchID: UUID) -> some View {
        let currentFile = store.file(containing: matchID)
        let candidates = store.writableFiles.filter { $0.url != currentFile?.url }
        if !candidates.isEmpty {
            Menu("Move to") {
                ForEach(candidates, id: \.url) { file in
                    Button(store.displayLabel(for: file)) {
                        do {
                            try store.move(matchID: matchID, to: file.url)
                        } catch {
                            duplicateError = error.localizedDescription
                        }
                    }
                }
            }
        }
    }

    private func duplicateSelected() {
        guard let id = singleSelectedMatchID else { return }
        do {
            let copy = try store.duplicate(matchID: id)
            selectedMatchIDs = [copy.id]
        } catch {
            duplicateError = error.localizedDescription
        }
    }

    private func deleteSelected() {
        let ids = selectedMatchIDs
        selectedMatchIDs = []
        do {
            try store.deleteMatches(ids)
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

private struct FilterChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .fontWeight(selected ? .semibold : .regular)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(selected ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(
                        selected ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.3),
                        lineWidth: 0.5
                    )
                )
        }
        .buttonStyle(.plain)
    }
}

struct MatchRowView: View {
    let match: EspansoMatch
    var isConflicted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(match.primaryTrigger)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                // The search field above matches on `label`, so it has to be visible
                // here too — rendered the same way QuickSwitcherRow already does it.
                if let label = match.label, !label.isEmpty {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if isConflicted {
                    Image(systemName: "exclamationmark.2")
                        .imageScale(.small)
                        .foregroundStyle(.orange)
                        .help("This trigger is also defined in another group — espanso will only use one of them")
                }
                if match.form != nil {
                    Text("form")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                if match.regex != nil {
                    Text("regex")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.purple.opacity(0.15))
                        .foregroundStyle(Color.purple)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            Text(match.replacementPreview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}
