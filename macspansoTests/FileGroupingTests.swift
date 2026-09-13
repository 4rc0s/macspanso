// macspansoTests/FileGroupingTests.swift
import XCTest
@testable import macspanso

/// The grouped match list: groups are the files espanso owns, folders render
/// as one flat level, and same-named files disambiguate wherever several files
/// are listed together. All computed over a real temp match directory.
@MainActor
final class FileGroupingTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macspanso-grouping-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func load() -> EspansoConfigStore {
        let store = EspansoConfigStore(matchDirectory: dir)
        store.load()
        return store
    }

    private func makeSubfolder(_ path: String) throws -> URL {
        let sub = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        return sub
    }

    private func writeMatchYAML(_ trigger: String, to path: URL) throws {
        try """
        matches:
          - trigger: "\(trigger)"
            replace: "\(trigger) replacement"
        """.write(to: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Grouping

    func testRootFilesGroupWithoutFolderHeader() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        try writeMatchYAML("::b", to: dir.appendingPathComponent("b.yml"))
        let store = load()

        XCTAssertEqual(store.groupedFiles.count, 1)
        let group = try XCTUnwrap(store.groupedFiles.first)
        XCTAssertNil(group.folderPath)
        XCTAssertEqual(group.files.map(\.displayName), ["a.yml", "b.yml"])
    }

    func testSubdirectoryBecomesOneFolderGroupAfterRoot() throws {
        try writeMatchYAML("::r", to: dir.appendingPathComponent("root.yml"))
        let sub = try makeSubfolder("work")
        try writeMatchYAML("::a", to: sub.appendingPathComponent("a.yml"))
        try writeMatchYAML("::b", to: sub.appendingPathComponent("b.yml"))
        let store = load()

        XCTAssertEqual(store.groupedFiles.count, 2)
        XCTAssertNil(store.groupedFiles.first?.folderPath, "root files must come first")
        let folder = try XCTUnwrap(store.groupedFiles.last)
        XCTAssertEqual(folder.folderPath, "work")
        XCTAssertEqual(folder.files.map(\.displayName), ["a.yml", "b.yml"])
    }

    func testDeeperNestingStaysOneFlatLevel() throws {
        let deep = try makeSubfolder("work/2026")
        try writeMatchYAML("::d", to: deep.appendingPathComponent("d.yml"))
        let store = load()

        XCTAssertEqual(store.groupedFiles.count, 1)
        XCTAssertEqual(store.groupedFiles.first?.folderPath, "work/2026",
                       "nested folders collapse into one group labeled by relative path")
    }

    func testFoldersSortAlphabetically() throws {
        for folder in ["zeta", "alpha"] {
            let sub = try makeSubfolder(folder)
            try writeMatchYAML("::\(folder)", to: sub.appendingPathComponent("\(folder).yml"))
        }
        let store = load()

        XCTAssertEqual(store.groupedFiles.compactMap(\.folderPath), ["alpha", "zeta"])
    }

    func testPackageFilesStayInTheirFolderGroup() throws {
        let pkg = try makeSubfolder("packages/github/someone")
        try writeMatchYAML("::p", to: pkg.appendingPathComponent("p.yml"))
        let store = load()

        let folder = try XCTUnwrap(store.groupedFiles.first)
        XCTAssertEqual(folder.folderPath, "packages/github/someone")
        let file = try XCTUnwrap(folder.files.first)
        XCTAssertTrue(file.isPackage)
        XCTAssertFalse(store.allMatches.contains { $0.primaryTrigger == "::p" },
                       "package matches stay excluded from allMatches")
    }

    func testParseErroredFileStaysVisibleInItsGroup() throws {
        let sub = try makeSubfolder("work")
        try "matches:\n  - trigger: [unclosed\n"
            .write(to: sub.appendingPathComponent("broken.yml"), atomically: true, encoding: .utf8)
        let store = load()

        let folder = try XCTUnwrap(store.groupedFiles.first)
        XCTAssertEqual(folder.folderPath, "work")
        let broken = try XCTUnwrap(folder.files.first)
        XCTAssertNotNil(broken.parseError)
        XCTAssertTrue(broken.matches.isEmpty)
    }

    // MARK: - Display labels

    func testDisplayLabelStripsExtensionWhenUnique() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("base.yml"))
        let store = load()

        let file = try XCTUnwrap(store.matchFiles.first)
        XCTAssertEqual(store.displayLabel(for: file), "base",
                       "the .yml extension is an espanso loading rule, not user intent")
    }

    func testDisplayLabelDisambiguatesSameBaseNameInDifferentFolders() throws {
        for folder in ["work", "personal"] {
            let sub = try makeSubfolder(folder)
            try writeMatchYAML("::\(folder)", to: sub.appendingPathComponent("team.yml"))
        }
        let store = load()

        let labels = store.matchFiles.map { store.displayLabel(for: $0) }.sorted()
        // Ambiguous base names fall back to the path — extension included,
        // since yml-vs-yaml may be the only distinction.
        XCTAssertEqual(labels, ["personal/team.yml", "work/team.yml"])
    }

    func testDisplayLabelDisambiguatesSameBaseNameAcrossExtensions() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("email.yml"))
        try writeMatchYAML("::b", to: dir.appendingPathComponent("email.yaml"))
        let store = load()

        let labels = Set(store.matchFiles.map { store.displayLabel(for: $0) })
        XCTAssertEqual(labels, ["email.yml", "email.yaml"])
    }

    func testDisplayNameItselfIsUnchanged() throws {
        // displayName keeps its bare-name meaning; only displayLabel strips.
        let sub = try makeSubfolder("work")
        try writeMatchYAML("::a", to: sub.appendingPathComponent("team.yml"))
        let store = load()

        XCTAssertEqual(try XCTUnwrap(store.matchFiles.first).displayName, "team.yml")
        XCTAssertEqual(try XCTUnwrap(store.matchFiles.first).baseName, "team")
    }

    // MARK: - Extension guard

    func testAddRefusesTargetWithoutYMLExtension() throws {
        // A file written under any other name is invisible — espanso never
        // loads it and scanMatchDirectory never reports it.
        let store = load()
        let match = EspansoMatch(trigger: "::e", replace: "Email")

        XCTAssertThrowsError(try store.add(match, to: dir.appendingPathComponent("email"))) { error in
            XCTAssertEqual((error as NSError).domain, "macspanso.add")
            XCTAssertTrue(error.localizedDescription.contains(".yml"))
        }
        XCTAssertThrowsError(try store.add(match, to: dir.appendingPathComponent("notes.txt")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("email").path))
        XCTAssertTrue(store.allMatches.isEmpty)
    }

    func testMoveRefusesTargetWithoutYMLExtension() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        let store = load()
        let match = try XCTUnwrap(store.allMatches.first)

        XCTAssertThrowsError(try store.move(matchID: match.id, to: dir.appendingPathComponent("email"))) { error in
            XCTAssertEqual((error as NSError).domain, "macspanso.move")
        }

        // The guard fires before any write: the match is still in its source file.
        XCTAssertEqual(store.allMatches.count, 1)
        XCTAssertTrue(store.matchFiles.first { $0.url.lastPathComponent == "a.yml" }?
            .matches.contains { $0.id == match.id } ?? false)
    }

    // MARK: - Shared search predicate

    func testSearchPredicateMatchesTriggerReplacementAndLabel() {
        let match = EspansoMatch(trigger: "::sig", replace: "Best, Jeff", label: "Email sign-off")
        XCTAssertTrue(MatchListView.matchesSearch(match, "sig"))
        XCTAssertTrue(MatchListView.matchesSearch(match, "JEFF"))
        XCTAssertTrue(MatchListView.matchesSearch(match, "sign-off"))
        XCTAssertFalse(MatchListView.matchesSearch(match, "nomatch"))
        XCTAssertTrue(MatchListView.matchesSearch(match, ""), "empty search must match everything")
    }

    // MARK: - Renaming groups

    func testRenameRepointsFileOnDiskAndInMemory() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        let store = load()
        let oldURL = dir.appendingPathComponent("a.yml")
        let contentOnDisk = try String(contentsOf: oldURL, encoding: .utf8)
        let matchID = try XCTUnwrap(store.allMatches.first).id

        try store.renameFile(at: oldURL, to: "work")

        let newURL = dir.appendingPathComponent("work.yml")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        // Content is untouched — a rename is a file rename, not a YAML rewrite.
        XCTAssertEqual(try String(contentsOf: newURL, encoding: .utf8), contentOnDisk)

        let file = try XCTUnwrap(store.matchFiles.first)
        XCTAssertEqual(file.url, newURL)
        XCTAssertEqual(file.displayName, "work.yml")
        XCTAssertEqual(store.groupedFiles.first?.files.first?.displayName, "work.yml")
        XCTAssertEqual(try XCTUnwrap(file.matches.first).id, matchID,
                       "match IDs survive a rename so selection and open editors do too")
    }

    func testRenameCoercesExtensionAndPreservesYAML() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("email.yml"))
        try writeMatchYAML("::b", to: dir.appendingPathComponent("notes.yaml"))
        let store = load()

        try store.renameFile(at: dir.appendingPathComponent("email.yml"), to: "Work")
        try store.renameFile(at: dir.appendingPathComponent("notes.yaml"), to: "Archive.yaml")
        try store.renameFile(at: dir.appendingPathComponent("Work.yml"), to: "Team.yml")

        XCTAssertEqual(store.matchFiles.map(\.displayName).sorted(), ["Archive.yaml", "Team.yml"],
                       "typed extensions are replaced by the file's own, never doubled")
    }

    func testRenameRefusesCollisionWithLoadedFile() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        try writeMatchYAML("::b", to: dir.appendingPathComponent("b.yml"))
        let store = load()
        let onDiskA = try String(contentsOf: dir.appendingPathComponent("a.yml"), encoding: .utf8)

        XCTAssertThrowsError(try store.renameFile(at: dir.appendingPathComponent("a.yml"), to: "b"))

        // Nothing moved.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.yml").path))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a.yml"), encoding: .utf8), onDiskA)
        XCTAssertEqual(store.matchFiles.map(\.displayName).sorted(), ["a.yml", "b.yml"])
    }

    func testRenameRefusesInvalidNames() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        let store = load()

        for bad in ["", "   ", "sub/name", "..", "."] {
            XCTAssertThrowsError(try store.renameFile(at: dir.appendingPathComponent("a.yml"), to: bad))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.yml").path))
    }

    func testRenameCaseOnlyIsAllowed() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("email.yml"))
        let store = load()

        // On a case-insensitive filesystem the target "exists" — as the same
        // file — so the collision guard must not fire.
        try store.renameFile(at: dir.appendingPathComponent("email.yml"), to: "EMAIL")

        XCTAssertEqual(store.matchFiles.first?.displayName, "EMAIL.yml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("EMAIL.yml").path))
    }

    func testRenameRefusesPackageFile() throws {
        let pkg = try makeSubfolder("packages/github/someone")
        try writeMatchYAML("::p", to: pkg.appendingPathComponent("p.yml"))
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        let store = load()

        let packageFile = try XCTUnwrap(store.matchFiles.first { $0.isPackage })
        XCTAssertThrowsError(try store.renameFile(at: packageFile.url, to: "renamed"))
        XCTAssertTrue(store.matchFiles.contains { $0.isPackage && $0.displayName == "p.yml" })
    }

    func testExternalChangeDetectedOnRenamedPath() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        let store = load()
        try store.renameFile(at: dir.appendingPathComponent("a.yml"), to: "b")
        let newURL = dir.appendingPathComponent("b.yml")

        // Wait out the 2-second post-rename suppression window.
        let window = XCTestExpectation(description: "suppression window elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { window.fulfill() }
        wait(for: [window], timeout: 5)

        try """
        matches:
          - trigger: "::a"
            replace: Alpha (externally edited)
        """.write(to: newURL, atomically: true, encoding: .utf8)

        let detected = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in store.externallyChangedURL != nil },
            object: nil
        )
        wait(for: [detected], timeout: 5)
        XCTAssertEqual(store.externallyChangedURL, newURL,
                       "the re-pointed watch must keep detecting external edits")
    }

    // MARK: - Deleting groups

    func testDeleteGroupOutright() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        try writeMatchYAML("::b", to: dir.appendingPathComponent("b.yml"))
        let store = load()
        let deletedMatchID = try XCTUnwrap(store.matchFiles.first { $0.displayName == "a.yml" }).matches[0].id

        try store.deleteFile(at: dir.appendingPathComponent("a.yml"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.yml").path))
        XCTAssertEqual(store.matchFiles.map(\.displayName), ["b.yml"])
        XCTAssertEqual(store.allMatches.count, 1)
        XCTAssertNil(store.file(containing: deletedMatchID))
    }

    func testDeleteGroupMovesMatchesToDestination() throws {
        try """
        global_vars:
          - name: shared
            type: date
            params:
              format: "%Y"
        matches:
          - trigger: "::dest"
            replace: "Year {{shared}}"
        """.write(to: dir.appendingPathComponent("dest.yml"), atomically: true, encoding: .utf8)
        try writeMatchYAML("::a", to: dir.appendingPathComponent("src.yml"))
        let store = load()
        let sourceMatchID = try XCTUnwrap(store.matchFiles.first { $0.displayName == "src.yml" }).matches[0].id

        try store.deleteFile(at: dir.appendingPathComponent("src.yml"),
                             movingMatchesTo: dir.appendingPathComponent("dest.yml"))

        // Source gone; destination carries its own match plus the moved one,
        // with the moved match's ID stable.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("src.yml").path))
        let dest = try XCTUnwrap(store.matchFiles.first { $0.displayName == "dest.yml" })
        XCTAssertEqual(dest.matches.count, 2)
        XCTAssertTrue(dest.matches.contains { $0.id == sourceMatchID })
        XCTAssertTrue(dest.matches.contains { $0.trigger == "::dest" })

        // The destination's unmodeled top-level content survives the rewrite.
        let onDisk = try String(contentsOf: dir.appendingPathComponent("dest.yml"), encoding: .utf8)
        XCTAssertTrue(onDisk.contains("global_vars"))
        XCTAssertTrue(onDisk.contains("::a"))
        XCTAssertTrue(onDisk.contains("::dest"))
    }

    func testDeleteGroupWithNoMatchesIsOutrightEvenWithDestination() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        let empty = """
        matches: []
        """
        try empty.write(to: dir.appendingPathComponent("empty.yml"), atomically: true, encoding: .utf8)
        let store = load()
        let destBefore = try String(contentsOf: dir.appendingPathComponent("a.yml"), encoding: .utf8)

        try store.deleteFile(at: dir.appendingPathComponent("empty.yml"),
                             movingMatchesTo: dir.appendingPathComponent("a.yml"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("empty.yml").path))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a.yml"), encoding: .utf8),
                       destBefore, "moving zero matches must not rewrite the destination")
    }

    func testDeleteGroupRefusesPackageAndNonYML() throws {
        let pkg = try makeSubfolder("packages/github/someone")
        try writeMatchYAML("::p", to: pkg.appendingPathComponent("p.yml"))
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        let store = load()

        let packageFile = try XCTUnwrap(store.matchFiles.first { $0.isPackage })
        XCTAssertThrowsError(try store.deleteFile(at: packageFile.url))
        XCTAssertThrowsError(try store.deleteFile(at: dir.appendingPathComponent("a.yml"),
                                                  movingMatchesTo: dir.appendingPathComponent("noext")))
        XCTAssertTrue(store.matchFiles.contains { $0.isPackage && $0.displayName == "p.yml" })
        XCTAssertEqual(store.allMatches.count, 1)
    }

    func testDeleteGroupRefusesParseErroredDestination() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        try "matches:\n  - trigger: [unclosed\n"
            .write(to: dir.appendingPathComponent("broken.yml"), atomically: true, encoding: .utf8)
        let store = load()

        XCTAssertThrowsError(try store.deleteFile(at: dir.appendingPathComponent("a.yml"),
                                                  movingMatchesTo: dir.appendingPathComponent("broken.yml")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.yml").path))
        XCTAssertEqual(store.allMatches.count, 1)
    }

    func testDeleteParseErroredGroupOutright() throws {
        try "matches:\n  - trigger: [unclosed\n"
            .write(to: dir.appendingPathComponent("broken.yml"), atomically: true, encoding: .utf8)
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        let store = load()

        let broken = try XCTUnwrap(store.matchFiles.first { $0.parseError != nil })
        try store.deleteFile(at: broken.url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: broken.url.path))
        XCTAssertEqual(store.matchFiles.count, 1)
        XCTAssertEqual(store.allMatches.count, 1)
    }
}
