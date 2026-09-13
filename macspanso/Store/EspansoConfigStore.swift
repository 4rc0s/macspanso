// macspanso/Store/EspansoConfigStore.swift
import Foundation
import Combine

@MainActor
final class EspansoConfigStore: ObservableObject {
    @Published var matchFiles: [MatchFile] = []

    /// Non-nil when a watched file changes externally while the window is open.
    /// Set to nil after the user responds to the reload banner.
    @Published var externallyChangedURL: URL? = nil

    /// Snapshot of the most recent `deleteMatches` call, kept only long enough
    /// for the user to undo it. Single-level by design: a new delete replaces
    /// this rather than stacking, and any other mutating call clears it — see
    /// the `pendingUndo = nil` at the top of every method but `deleteMatches`/
    /// `delete(matchID:)` (which replace it) and `undoDelete` (which clears it
    /// only on success). A deeper undo stack would need every entry's indices
    /// re-validated against however many intervening edits happened, which is
    /// not worth the complexity for an accidental-delete safety net.
    struct PendingDelete: Identifiable {
        struct Entry {
            let url: URL
            let match: EspansoMatch
            /// Position within that file's `matches` at the moment of deletion —
            /// where `undoDelete` reinserts it, clamped if the file has since
            /// shrunk.
            let originalIndex: Int
        }
        let id = UUID()
        let entries: [Entry]
        /// Precomputed for the banner: "Deleted "trigger"" for one match,
        /// "Deleted N matches" for a batch.
        let label: String
    }

    // Not private(set): matches externallyChangedURL below — mutated only by
    // the store's own methods by convention, and tests construct one directly
    // to exercise undoDelete's clamping/skip behavior against a state no
    // real code path can currently produce.
    @Published var pendingUndo: PendingDelete? = nil

    let matchDirectory: URL
    private let watcher = FileWatcher()

    /// Reference-counted write-in-progress markers; FSEvents for these paths are suppressed.
    private var writingPaths: [String: Int] = [:]

    /// All non-package matches, flattened across all files.
    var allMatches: [EspansoMatch] {
        matchFiles.filter { !$0.isPackage }.flatMap { $0.matches }
    }

    /// Names declared under `global_vars:` in any loaded file, sorted.
    /// Matches may reference these without declaring them locally.
    var globalVarNames: [String] {
        var names = Set<String>()
        for file in matchFiles {
            guard case let .array(items)? = file.extras["global_vars"] else { continue }
            for case let .dictionary(entry) in items {
                if case let .string(name)? = entry["name"] { names.insert(name) }
            }
        }
        return names.sorted()
    }

    init(matchDirectory: URL) {
        // Resolve symlinks once at the boundary: directory enumeration returns
        // symlink-resolved URLs (/private/var vs /var), and the store compares
        // constructed URLs against enumerated ones by equality throughout.
        self.matchDirectory = matchDirectory.resolvingSymlinksInPath()
        watcher.onChange = { [weak self] url in
            Task { @MainActor in self?.handleExternalChange(at: url) }
        }
    }

    // MARK: - Load

    func load() {
        pendingUndo = nil   // matchFiles is being wholly rebuilt from disk; any captured indices are meaningless
        watcher.stopAll()   // clear stale watches if load() is called more than once
        let urls = scanMatchDirectory()
        matchFiles = urls.map { loadFile(at: $0) }
        // Watch every directory in the tree: a dispatch source on the root
        // doesn't fire for files created inside subdirectories.
        watcher.watch(url: matchDirectory)
        scanSubdirectories().forEach { watcher.watch(url: $0) }
        matchFiles.forEach { watcher.watch(url: $0.url) }
    }

    /// espanso v2 loads both extensions. Internal, not private: every path that
    /// enumerates match files must agree on this set, or files get loaded but
    /// never cleaned up (or vice versa). See BackupManager.deleteUserMatchFiles.
    static let matchExtensions: Set<String> = ["yml", "yaml"]

    private func scanMatchDirectory() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: matchDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { Self.matchExtensions.contains($0.pathExtension) }
            // Normalize: enumeration yields /private/var/… for symlinked roots, while
            // URLs built via appendingPathComponent(_:) keep /var/…. Resolving strips
            // the /private prefix so URL equality works across the store.
            .map { $0.resolvingSymlinksInPath() }
            .sorted { $0.path < $1.path }
    }

    private func scanSubdirectories() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: matchDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.resolvingSymlinksInPath() }
    }

    private func loadFile(at url: URL, reusingIDsFrom previous: [EspansoMatch] = []) -> MatchFile {
        // Anchor package detection to the known config root rather than global path search.
        let relative = url.path.replacingOccurrences(of: matchDirectory.path, with: "")
        let isPackage = relative.hasPrefix("/packages/")
        do {
            let content = try YAMLSerializer.decodeContent(contentsOf: url)
            var matches = content.matches ?? []
            if !previous.isEmpty {
                Self.reassociateIDs(into: &matches, from: previous)
            }
            return MatchFile(url: url, matches: matches, isPackage: isPackage,
                             extras: content.extras)
        } catch {
            return MatchFile(url: url, matches: [], isPackage: isPackage,
                             parseError: error.localizedDescription)
        }
    }

    /// After a reload, decoded matches receive freshly-generated UUIDs. Walk through them
    /// and reuse the prior UUID whenever a previous match has the same identity (primary
    /// trigger or regex pattern). This keeps the editor's selection alive across external
    /// edits to unrelated matches in the same file.
    nonisolated static func reassociateIDs(into fresh: inout [EspansoMatch], from previous: [EspansoMatch]) {
        var available = previous
        for i in fresh.indices {
            guard let j = available.firstIndex(where: { matchKey(for: $0) == matchKey(for: fresh[i]) })
            else { continue }
            fresh[i].id = available[j].id
            available.remove(at: j)
        }
    }

    /// Identity used to re-associate a match across reloads. Primary trigger (or regex
    /// pattern) is the canonical, user-meaningful key; collisions are guarded by the
    /// validator at edit time, so duplicates here are vanishingly rare.
    nonisolated private static func matchKey(for m: EspansoMatch) -> String {
        if let r = m.regex { return "regex:\(r)" }
        if let t = m.trigger { return "t:\(t)" }
        if let first = m.triggers?.first { return "t:\(first)" }
        return "label:\(m.label ?? "")"
    }

    // MARK: - Write

    /// Full file content for a write: the new matches plus whatever top-level
    /// extras (global_vars, imports, …) the file carried when loaded.
    private func fileContent(_ matches: [EspansoMatch], for url: URL) -> MatchFileContent {
        let extras = matchFiles.first(where: { $0.url == url })?.extras ?? [:]
        return MatchFileContent(matches: matches, extras: extras)
    }

    /// Registers a write-in-progress for `url` so that the resulting FSEvent is
    /// not mistaken for an external edit. Clears after a short delay to account
    /// for async FSEvent delivery.
    private func suppressingWatcherEvents(for url: URL, _ body: () throws -> Void) rethrows {
        // Suppress the file itself, its parent directory (atomic writes rename
        // into it), and the root — all three can emit events for our own write.
        let paths = [url.path, url.deletingLastPathComponent().path, matchDirectory.path]
        paths.forEach { writingPaths[$0, default: 0] += 1 }
        // Schedule the decrement even when the write throws — otherwise the
        // counter leaks and external-edit detection is suppressed forever.
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                for p in paths {
                    if let count = self.writingPaths[p] {
                        if count <= 1 { self.writingPaths.removeValue(forKey: p) }
                        else { self.writingPaths[p] = count - 1 }
                    }
                }
            }
        }
        try body()
    }

    /// How a group's file is removed when the user deletes it outright.
    /// Production moves it to the real macOS Trash — recoverable via Finder's
    /// Put Back, and needs no retention/cleanup policy of our own, unlike a
    /// custom soft-delete scheme would. Overridable so tests never touch the
    /// user's actual Trash; they substitute a plain `removeItem`. Internal
    /// rollback of a destination file `deleteFile` created and must undo on
    /// its own failure does NOT go through this seam — that's never
    /// user-facing deletion, and trashing it would litter the user's Trash
    /// with the app's own artifacts.
    var trashHandler: (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Update a single match in place.
    func update(_ match: EspansoMatch) throws {
        pendingUndo = nil
        for i in matchFiles.indices {
            if let j = matchFiles[i].matches.firstIndex(where: { $0.id == match.id }) {
                let url = matchFiles[i].url
                var updated = matchFiles[i].matches
                updated[j] = match
                // Write first; only update in-memory if the write succeeds.
                try suppressingWatcherEvents(for: url) {
                    try YAMLSerializer.write(fileContent(updated, for: url), to: url)
                }
                matchFiles[i].matches = updated
                return
            }
        }
    }

    /// Add a new match. Saves to `targetURL` if provided; otherwise to base.yml.
    /// Creates the file if it doesn't exist. Refuses to write into package files
    /// or files that failed to parse (a write would clobber their unmodeled content),
    /// and refuses targets espanso would never load — see `validateWriteTarget`.
    func add(_ match: EspansoMatch, to targetURL: URL? = nil) throws {
        pendingUndo = nil
        let url = targetURL ?? matchDirectory.appendingPathComponent("base.yml")
        try validateWriteTarget(url, domain: "macspanso.add")
        if let existing = matchFiles.first(where: { $0.url == url }),
           existing.isPackage || existing.parseError != nil {
            throw NSError(
                domain: "macspanso.add",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: existing.isPackage
                    ? "Cannot add matches to a package file."
                    : "Cannot add matches to a file that failed to parse — fix its YAML first."]
            )
        }
        if let index = matchFiles.firstIndex(where: { $0.url == url }) {
            // Write first; only update in-memory if the write succeeds.
            let updatedMatches = matchFiles[index].matches + [match]
            try suppressingWatcherEvents(for: url) {
                try YAMLSerializer.write(fileContent(updatedMatches, for: url), to: url)
            }
            matchFiles[index].matches = updatedMatches
        } else {
            // File doesn't exist yet — create it
            try suppressingWatcherEvents(for: url) {
                try YAMLSerializer.write(fileContent([match], for: url), to: url)
            }
            let newFile = MatchFile(url: url, matches: [match], isPackage: false)
            matchFiles.append(newFile)
            matchFiles.sort { $0.url.path < $1.url.path }
            watcher.watch(url: url)
        }
    }

    /// Files that the user can write matches into (excludes packages and parse-errored files).
    var writableFiles: [MatchFile] {
        matchFiles.filter { !$0.isPackage && $0.parseError == nil }
    }

    // MARK: - File grouping

    /// Matches grouped by the file that defines them. The file is espanso's own
    /// organizational unit — the user can edit the same grouping by hand and
    /// espanso watches it — so groups map 1:1 to files rather than inventing a
    /// parallel categorization nothing else knows about. Folders render as one
    /// flat level: every distinct parent directory (at any depth) becomes a
    /// group whose header shows its path relative to the match directory root.
    struct FileGroup: Identifiable {
        /// Parent directory path relative to the match directory root,
        /// or nil for files sitting directly in the root.
        let folderPath: String?
        let files: [MatchFile]
        var id: String { folderPath ?? "" }
    }

    /// Root-level files first, then folders sorted by path. Groups are never empty.
    var groupedFiles: [FileGroup] {
        var folders: [String: [MatchFile]] = [:]
        var root: [MatchFile] = []
        for file in matchFiles {
            if let folder = pathRelativeToRoot(for: file.url.deletingLastPathComponent()) {
                folders[folder, default: []].append(file)
            } else {
                root.append(file)
            }
        }
        var groups = root.isEmpty ? [] : [FileGroup(folderPath: nil, files: root)]
        for folder in folders.keys.sorted() {
            groups.append(FileGroup(folderPath: folder, files: folders[folder]!))
        }
        return groups
    }

    /// Label used wherever several files are listed together (group headers,
    /// "Move to" menus, the destination picker). The .yml/.yaml extension is
    /// espanso's loading rule, not something the user chose, so it is hidden
    /// and the base name stands alone. When two files share a base name the
    /// bare name is ambiguous — those fall back to the path relative to the
    /// match directory root, extension included, since yml-vs-yaml may be the
    /// only thing distinguishing them.
    func displayLabel(for file: MatchFile) -> String {
        let name = file.baseName
        let isAmbiguous = matchFiles.contains {
            $0.id != file.id && $0.baseName == name
        }
        return isAmbiguous
            ? pathRelativeToRoot(for: file.url) ?? file.displayName
            : name
    }

    /// `url`'s path relative to the match directory root, or nil when `url` is
    /// the root itself. Both operands are normalized the same way — scanMatchDirectory
    /// resolves symlinks on every entry and init resolves the root, so the prefix
    /// comparison is safe (see the URL-identity notes there).
    private func pathRelativeToRoot(for url: URL) -> String? {
        let root = matchDirectory.path
        let path = url.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    /// Guard for any file the user names as a write target. espanso loads only
    /// `.yml`/`.yaml`, and only from under the match directory — a file written
    /// under any other name, or anywhere else on disk, is invisible in this app
    /// and in espanso alike. The write itself succeeds, so without this guard
    /// the match appears in the list until the next `load()` and is then gone,
    /// having never once expanded.
    ///
    /// Containment resolves symlinks on the candidate because `init` resolved
    /// the root: normalizing one operand only would guarantee the mismatch it
    /// was meant to prevent (see the URL-identity notes on `scanMatchDirectory`).
    private func validateWriteTarget(_ url: URL, domain: String) throws {
        guard Self.matchExtensions.contains(url.pathExtension) else {
            throw NSError(
                domain: domain,
                code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "“\(url.lastPathComponent)” is missing the .yml extension — "
                    + "espanso only loads .yml and .yaml files, so it would never be visible."]
            )
        }
        guard pathRelativeToRoot(for: url.resolvingSymlinksInPath()) != nil else {
            throw NSError(
                domain: domain,
                code: 6,
                userInfo: [NSLocalizedDescriptionKey:
                    "“\(url.lastPathComponent)” is outside the espanso match folder — "
                    + "espanso only loads files under \(matchDirectory.path), "
                    + "so it would never be visible."]
            )
        }
    }

    /// One occurrence of a trigger string in a specific match within a specific file.
    /// Used to surface cross-file trigger collisions (`::hello` defined in two files).
    struct TriggerOccurrence: Hashable {
        let trigger: String
        let fileURL: URL
        let matchID: UUID
    }

    struct TriggerConflict: Identifiable {
        let trigger: String
        let occurrences: [TriggerOccurrence]
        var id: String { trigger }
    }

    /// Find triggers that appear in more than one non-package file. Within-file duplicates
    /// are caught by `MatchValidator` at edit time; this surfaces the cross-file case the
    /// validator can't see (espanso silently picks one and ignores the rest).
    func triggerConflicts() -> [TriggerConflict] {
        var byTrigger: [String: [TriggerOccurrence]] = [:]
        for file in matchFiles where !file.isPackage {
            for match in file.matches {
                var triggers: [String] = []
                if let t = match.trigger { triggers.append(t) }
                if let arr = match.triggers { triggers.append(contentsOf: arr) }
                // Regex patterns aren't compared as literal triggers — different match type.
                for t in triggers where !t.isEmpty {
                    byTrigger[t, default: []].append(
                        TriggerOccurrence(trigger: t, fileURL: file.url, matchID: match.id)
                    )
                }
            }
        }
        return byTrigger
            .filter { _, occs in Set(occs.map(\.fileURL)).count > 1 }
            .map { TriggerConflict(trigger: $0.key, occurrences: $0.value) }
            .sorted { $0.trigger < $1.trigger }
    }

    /// Duplicate a match: insert a copy directly after the original in the same file.
    /// The copy gets a fresh UUID and an unused trigger derived from the original
    /// (e.g. `::hello` → `::hello-copy`, then `::hello-copy-2`, etc.). Multi-trigger
    /// and regex matches duplicate the primary trigger only — secondary triggers and
    /// the regex pattern are preserved as-is, then deduplicated against existing matches.
    /// Returns the new match so callers can select it.
    @discardableResult
    func duplicate(matchID: UUID) throws -> EspansoMatch {
        pendingUndo = nil
        for i in matchFiles.indices {
            guard let j = matchFiles[i].matches.firstIndex(where: { $0.id == matchID })
            else { continue }

            let original = matchFiles[i].matches[j]
            var copy = original
            copy.id = UUID()
            copy.label = original.label.map { "\($0) (copy)" }

            // Derive a unique primary trigger so the copy does not collide.
            let usedLiteral = Set(allMatches.flatMap { m -> [String] in
                var ts: [String] = []
                if let t = m.trigger { ts.append(t) }
                if let arr = m.triggers { ts.append(contentsOf: arr) }
                return ts
            })
            let usedRegex = Set(allMatches.compactMap { $0.regex })

            if let regex = original.regex {
                copy.regex = uniqueTrigger(base: regex, suffix: "-copy", taken: usedRegex)
            } else if let trig = original.trigger {
                copy.trigger = uniqueTrigger(base: trig, suffix: "-copy", taken: usedLiteral)
            } else if let triggers = original.triggers, let first = triggers.first {
                var newTriggers = triggers
                newTriggers[0] = uniqueTrigger(base: first, suffix: "-copy", taken: usedLiteral)
                copy.triggers = newTriggers
            }

            var updated = matchFiles[i].matches
            updated.insert(copy, at: j + 1)
            let url = matchFiles[i].url
            try suppressingWatcherEvents(for: url) {
                try YAMLSerializer.write(fileContent(updated, for: url), to: url)
            }
            matchFiles[i].matches = updated
            return copy
        }
        throw NSError(
            domain: "macspanso.duplicate",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Match not found"]
        )
    }

    private func uniqueTrigger(base: String, suffix: String, taken: Set<String>) -> String {
        let first = base + suffix
        if !taken.contains(first) { return first }
        var n = 2
        while taken.contains("\(first)-\(n)") { n += 1 }
        return "\(first)-\(n)"
    }

    /// Move a match to a different file. Removes from the source file and appends to
    /// the destination file, writing both. No-op if the match is already in `targetURL`.
    /// Refuses to move into package files or files with parse errors, and refuses
    /// targets espanso would never load (see `add(_:to:)`).
    func move(matchID: UUID, to targetURL: URL) throws {
        pendingUndo = nil
        try validateWriteTarget(targetURL, domain: "macspanso.move")
        // Locate the source file and match
        guard let sourceIndex = matchFiles.firstIndex(where: { f in
                  f.matches.contains(where: { $0.id == matchID })
              }),
              let matchIndex = matchFiles[sourceIndex].matches.firstIndex(where: { $0.id == matchID })
        else {
            throw NSError(
                domain: "macspanso.move",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Match not found"]
            )
        }

        let sourceURL = matchFiles[sourceIndex].url
        guard sourceURL != targetURL else { return }

        if let existing = matchFiles.first(where: { $0.url == targetURL }),
           existing.isPackage || existing.parseError != nil {
            throw NSError(
                domain: "macspanso.move",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Cannot move matches into a package or unreadable file."]
            )
        }

        let match = matchFiles[sourceIndex].matches[matchIndex]

        // Compose the new state for both files before writing.
        var newSource = matchFiles[sourceIndex].matches
        newSource.remove(at: matchIndex)

        // Write source first; if that fails, in-memory state is unchanged.
        try suppressingWatcherEvents(for: sourceURL) {
            try YAMLSerializer.write(fileContent(newSource, for: sourceURL), to: sourceURL)
        }

        // Write destination — on failure we restore the source on disk so we don't
        // silently delete the user's match.
        do {
            if let destIndex = matchFiles.firstIndex(where: { $0.url == targetURL }) {
                var newDest = matchFiles[destIndex].matches
                newDest.append(match)
                try suppressingWatcherEvents(for: targetURL) {
                    try YAMLSerializer.write(fileContent(newDest, for: targetURL), to: targetURL)
                }
                matchFiles[destIndex].matches = newDest
            } else {
                // Destination file doesn't exist yet — create it.
                try suppressingWatcherEvents(for: targetURL) {
                    try YAMLSerializer.write(fileContent([match], for: targetURL), to: targetURL)
                }
                let newFile = MatchFile(url: targetURL, matches: [match], isPackage: false)
                matchFiles.append(newFile)
                matchFiles.sort { $0.url.path < $1.url.path }
                watcher.watch(url: targetURL)
            }
            matchFiles[sourceIndex].matches = newSource
        } catch {
            // Roll back the source file write so the match isn't lost.
            try? suppressingWatcherEvents(for: sourceURL) {
                try YAMLSerializer.write(fileContent(matchFiles[sourceIndex].matches, for: sourceURL), to: sourceURL)
            }
            throw error
        }
    }

    /// Delete a batch of matches in at most one write per affected file, and
    /// capture what was removed into `pendingUndo` so the caller can offer an
    /// Undo affordance. Replaces the old one-write-per-match loop every bulk
    /// delete call site used to run.
    ///
    /// All-or-nothing across files: if any file's write fails, every file
    /// already written this call is rewritten back to its pre-delete content
    /// before the error is rethrown, so a partial batch is never left half
    /// applied on disk or in memory — the same "either every write agrees, or
    /// none of them changed" contract `move()`/`deleteFile()` already keep,
    /// generalized from two files to N.
    func deleteMatches(_ ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }

        // Group hits by index into matchFiles (not by URL) since that's what
        // gets mutated directly below.
        var perFileRemovals: [Int: [(index: Int, match: EspansoMatch)]] = [:]
        for i in matchFiles.indices {
            let hits = matchFiles[i].matches.enumerated()
                .filter { ids.contains($0.element.id) }
                .map { (index: $0.offset, match: $0.element) }
            if !hits.isEmpty { perFileRemovals[i] = hits }
        }
        guard !perFileRemovals.isEmpty else { return }

        var written: [(index: Int, url: URL, previousMatches: [EspansoMatch])] = []
        do {
            // Ascending index order: Dictionary iteration order is unspecified,
            // and a deterministic write order makes a partial-failure rollback
            // reproducible rather than dependent on hash-seed luck.
            for (i, hits) in perFileRemovals.sorted(by: { $0.key < $1.key }) {
                let url = matchFiles[i].url
                let removeIndices = Set(hits.map(\.index))
                let updated = matchFiles[i].matches.enumerated()
                    .filter { !removeIndices.contains($0.offset) }
                    .map(\.element)
                try suppressingWatcherEvents(for: url) {
                    try YAMLSerializer.write(fileContent(updated, for: url), to: url)
                }
                written.append((i, url, matchFiles[i].matches))
                matchFiles[i].matches = updated
            }
        } catch {
            // Put every file already written this call back the way it was,
            // so the batch never lands half-deleted.
            for (i, url, previous) in written {
                try? suppressingWatcherEvents(for: url) {
                    try YAMLSerializer.write(fileContent(previous, for: url), to: url)
                }
                matchFiles[i].matches = previous
            }
            throw error
        }

        var entries: [PendingDelete.Entry] = []
        for (i, hits) in perFileRemovals {
            let url = matchFiles[i].url
            for hit in hits {
                entries.append(.init(url: url, match: hit.match, originalIndex: hit.index))
            }
        }
        let label = entries.count == 1
            ? "Deleted “\(entries[0].match.primaryTrigger)”"
            : "Deleted \(entries.count) matches"
        pendingUndo = PendingDelete(entries: entries, label: label)
    }

    /// Delete a single match by ID. Thin wrapper over `deleteMatches` so this
    /// call site (and its test) keep working unchanged, and gain undo capture
    /// for free.
    func delete(matchID: UUID) throws {
        try deleteMatches([matchID])
    }

    /// Reverses the most recent `deleteMatches` call. No-op if there is
    /// nothing pending. Reinserts each match at its recorded index, clamped to
    /// the file's current length in case something else has shrunk it since
    /// the delete — this must never crash on an out-of-range index. A file
    /// that has vanished entirely since the delete (renamed or removed) is
    /// skipped rather than failing the whole undo, so what's still
    /// restorable still gets restored.
    func undoDelete() throws {
        guard let pending = pendingUndo else { return }

        // Grouped by URL, each file's entries kept in ascending original-index
        // order so inserting an earlier one doesn't shift a later target.
        var byURL: [URL: [PendingDelete.Entry]] = [:]
        for entry in pending.entries {
            byURL[entry.url, default: []].append(entry)
        }

        var written: [(index: Int, url: URL, previousMatches: [EspansoMatch])] = []
        do {
            // Ascending path order, for the same determinism reason as deleteMatches.
            for (url, entries) in byURL.sorted(by: { $0.key.path < $1.key.path }) {
                guard let i = matchFiles.firstIndex(where: { $0.url == url }) else { continue }
                var updated = matchFiles[i].matches
                for entry in entries.sorted(by: { $0.originalIndex < $1.originalIndex }) {
                    let insertAt = min(entry.originalIndex, updated.count)
                    updated.insert(entry.match, at: insertAt)
                }
                try suppressingWatcherEvents(for: url) {
                    try YAMLSerializer.write(fileContent(updated, for: url), to: url)
                }
                written.append((i, url, matchFiles[i].matches))
                matchFiles[i].matches = updated
            }
        } catch {
            for (i, url, previous) in written {
                try? suppressingWatcherEvents(for: url) {
                    try YAMLSerializer.write(fileContent(previous, for: url), to: url)
                }
                matchFiles[i].matches = previous
            }
            throw error
        }

        pendingUndo = nil
    }

    /// Dismisses the pending-undo banner without applying it.
    func dismissPendingUndo() {
        pendingUndo = nil
    }

    /// Rename the file backing a group — a group is a file, so renaming a
    /// group is a file rename. Content is untouched (no YAML rewrite, no
    /// round-trip surface) and match IDs are stable, so selection and open
    /// editors survive. The typed name is coerced to the file's current
    /// extension, so renaming `email.yml` to "Work" yields `Work.yml`; a
    /// `.yaml` file stays `.yaml`. Refuses package files and targets another
    /// file already occupies — compared case-insensitively (APFS is
    /// case-insensitive), except a case-only change of the same file, which
    /// is a true rename and is allowed.
    func renameFile(at url: URL, to name: String) throws {
        pendingUndo = nil
        guard let index = matchFiles.firstIndex(where: { $0.url == url }) else {
            throw NSError(domain: "macspanso.rename", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Group not found."])
        }
        guard !matchFiles[index].isPackage else {
            throw NSError(domain: "macspanso.rename", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot rename a package file."])
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/") else {
            throw NSError(domain: "macspanso.rename", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "“\(name)” is not a valid group name."])
        }

        let newURL = url.deletingLastPathComponent()
            .appendingPathComponent(trimmed)
            // Replace any typed extension rather than appending to it.
            .deletingPathExtension()
            .appendingPathExtension(url.pathExtension)

        let targetPath = newURL.path
        let sourcePath = url.path
        if sourcePath != targetPath {
            let isCaseOnlyRename = sourcePath.lowercased() == targetPath.lowercased()
            if !isCaseOnlyRename {
                let occupied = matchFiles.contains {
                    $0.url != url && $0.url.path.lowercased() == targetPath.lowercased()
                } || FileManager.default.fileExists(atPath: targetPath)
                if occupied {
                    throw NSError(domain: "macspanso.rename", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey:
                        "A group called “\(newURL.lastPathComponent)” already exists."])
                }
            }

            // A rename looks like a create+delete to the watcher; suppress both
            // spellings (parent and root are suppressed inside) so the app's
            // own rename isn't read as an external edit.
            try suppressingWatcherEvents(for: url) {
                try suppressingWatcherEvents(for: newURL) {
                    try FileManager.default.moveItem(atPath: sourcePath, toPath: targetPath)
                }
            }
            // Disk succeeded — now re-point memory and the watch.
            matchFiles[index].url = newURL
            matchFiles.sort { $0.url.path < $1.url.path }
            watcher.stopWatching(url: url)
            watcher.watch(url: newURL)
            // An unanswered external-edit banner names a path that no longer
            // exists: Reload would find nothing and silently do nothing. The
            // edit is still unreloaded, so re-point the notice rather than
            // dropping it.
            if externallyChangedURL == url { externallyChangedURL = newURL }
        }
    }

    /// Delete a group's file outright, or — when `movingMatchesTo` is set —
    /// append all its matches to that file in one composed write first, so
    /// matches are never lost. If the source can't be removed after the
    /// destination write succeeded, the destination is rewritten without them
    /// (same compensation as `move`) and the error surfaces. Refuses package
    /// files; a file that failed to parse may only be deleted outright — its
    /// contents are unreadable, so they cannot be moved anywhere.
    func deleteFile(at url: URL, movingMatchesTo targetURL: URL? = nil) throws {
        pendingUndo = nil
        guard Self.matchExtensions.contains(url.pathExtension) else {
            throw NSError(domain: "macspanso.deleteGroup", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                        "“\(url.lastPathComponent)” is not a match file."])
        }
        guard let index = matchFiles.firstIndex(where: { $0.url == url }) else {
            throw NSError(domain: "macspanso.deleteGroup", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Group not found."])
        }
        guard !matchFiles[index].isPackage else {
            throw NSError(domain: "macspanso.deleteGroup", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot delete a package file."])
        }

        let source = matchFiles[index]
        // Moving to itself, or from a file with no matches in memory, is an
        // outright delete.
        let target: URL? = (targetURL == url || source.matches.isEmpty) ? nil : targetURL
        if let target {
            try validateWriteTarget(target, domain: "macspanso.deleteGroup")
            if let dest = matchFiles.first(where: { $0.url == target }),
               dest.isPackage || dest.parseError != nil {
                throw NSError(domain: "macspanso.deleteGroup", code: 5,
                              userInfo: [NSLocalizedDescriptionKey:
                            "Cannot move matches into a package or unreadable file."])
            }
        }

        // With a destination: write it first (source still on disk), remove the
        // source second, and compensate the destination write if the removal
        // fails — the same two-file dance as move(). Either both sides agree on
        // disk, or the source is untouched.
        if let target {
            let destIndex = matchFiles.firstIndex { $0.url == target }
            let destMatches = (destIndex.map { matchFiles[$0].matches } ?? []) + source.matches
            do {
                try suppressingWatcherEvents(for: target) {
                    try YAMLSerializer.write(fileContent(destMatches, for: target), to: target)
                }
                try suppressingWatcherEvents(for: url) {
                    try trashHandler(url)
                }
            } catch {
                // Removal failed after the destination write: put the destination
                // back the way it was so the matches exist in one file, not two.
                // A destination that wasn't a loaded file was created by the write
                // just above, so undoing it means removing it — rewriting it with
                // no matches would leave an empty file the user never asked for.
                try? suppressingWatcherEvents(for: target) {
                    if let destIndex {
                        try YAMLSerializer.write(
                            fileContent(matchFiles[destIndex].matches, for: target), to: target)
                    } else {
                        try FileManager.default.removeItem(atPath: target.path)
                    }
                }
                throw error
            }

            // Both disk writes succeeded — now update memory.
            if let destIndex {
                matchFiles[destIndex].matches = destMatches
            } else {
                matchFiles.append(MatchFile(url: target, matches: destMatches, isPackage: false))
                matchFiles.sort { $0.url.path < $1.url.path }
                watcher.watch(url: target)
            }
        } else {
            try suppressingWatcherEvents(for: url) {
                try trashHandler(url)
            }
        }

        // Commit: drop the source from memory and stop watching it.
        matchFiles.remove(at: index)
        watcher.stopWatching(url: url)
        // The file this banner refers to is gone, so Reload has nothing to
        // read — dismiss the notice rather than leaving a dead button.
        if externallyChangedURL == url { externallyChangedURL = nil }
    }

    /// Returns the MatchFile that owns a given match ID.
    func file(containing matchID: UUID) -> MatchFile? {
        matchFiles.first { $0.matches.contains(where: { $0.id == matchID }) }
    }

    // MARK: - External Change Handling

    private func handleExternalChange(at url: URL) {
        guard writingPaths[url.path] == nil else { return }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if url == matchDirectory || isDirectory.boolValue {
            handleDirectoryChange()
        } else {
            externallyChangedURL = url
        }
    }

    /// Called when the match directory (or a subdirectory) changes — a file or
    /// folder added or removed externally. Silently syncs matchFiles with disk.
    private func handleDirectoryChange() {
        pendingUndo = nil   // an external add/remove of files invalidates any recorded index
        // Newly created subdirectories need their own watch.
        scanSubdirectories().forEach { watcher.watch(url: $0) }

        let urls = Set(scanMatchDirectory())
        let existingURLs = Set(matchFiles.map { $0.url })

        // Add newly discovered files
        let added = urls.subtracting(existingURLs)
        for url in added.sorted(by: { $0.path < $1.path }) {
            let file = loadFile(at: url)
            matchFiles.append(file)
            watcher.watch(url: url)
        }

        // Remove files that no longer exist on disk (and stop watching them,
        // so their dispatch sources and file descriptors don't leak)
        for file in matchFiles where !urls.contains(file.url) {
            watcher.stopWatching(url: file.url)
        }
        matchFiles.removeAll { !urls.contains($0.url) }

        // Re-sort to keep consistent ordering
        matchFiles.sort { $0.url.path < $1.url.path }
    }

    /// Called when the user chooses "Reload" in the external edit banner.
    func reloadFile(at url: URL) {
        pendingUndo = nil
        guard let index = matchFiles.firstIndex(where: { $0.url == url }) else {
            // The file went away between the banner appearing and Reload being
            // pressed (deleted externally, or by deleteFile). There is nothing
            // to reload, but the notice must still clear — otherwise Reload is
            // a dead button and only "Keep Mine" dismisses the banner.
            externallyChangedURL = nil
            return
        }
        let previous = matchFiles[index].matches
        matchFiles[index] = loadFile(at: url, reusingIDsFrom: previous)
        externallyChangedURL = nil
    }

    func dismissExternalChangeNotice() {
        externallyChangedURL = nil
    }
}
