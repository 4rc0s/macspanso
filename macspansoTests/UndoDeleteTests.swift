// macspansoTests/UndoDeleteTests.swift
import XCTest
@testable import macspanso

/// Batched match delete (`deleteMatches`) and its one-level undo
/// (`undoDelete`), plus the invalidation rule that keeps that undo from being
/// applied against stale state, and the Trash seam `deleteFile` now uses for
/// outright group deletion.
@MainActor
final class UndoDeleteTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macspanso-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    private func load() -> EspansoConfigStore {
        let store = EspansoConfigStore(matchDirectory: dir)
        store.load()
        return store
    }

    private func writeMatchYAML(_ trigger: String, to path: URL) throws {
        try """
        matches:
          - trigger: "\(trigger)"
            replace: "\(trigger) replacement"
        """.write(to: path, atomically: true, encoding: .utf8)
    }

    private func writeMatches(_ triggers: [String], to path: URL) throws {
        let entries = triggers.map { "  - trigger: \"\($0)\"\n    replace: \"\($0) replacement\"" }
            .joined(separator: "\n")
        try "matches:\n\(entries)\n".write(to: path, atomically: true, encoding: .utf8)
    }

    // MARK: - deleteMatches

    func testDeleteMatchesRemovesAcrossMultipleFilesInOneCallEach() throws {
        try writeMatches(["::a", "::b"], to: dir.appendingPathComponent("a.yml"))
        try writeMatchYAML("::c", to: dir.appendingPathComponent("b.yml"))
        let store = load()
        let ids = Set(store.allMatches.map(\.id))

        try store.deleteMatches(ids)

        XCTAssertEqual(store.allMatches.count, 0)
        XCTAssertTrue(store.matchFiles.allSatisfy { $0.matches.isEmpty })
    }

    func testDeleteMatchesPopulatesPendingUndoLabelForSingleMatch() throws {
        try writeMatchYAML("::hello", to: dir.appendingPathComponent("a.yml"))
        let store = load()
        let id = try XCTUnwrap(store.allMatches.first).id

        try store.deleteMatches([id])

        XCTAssertEqual(store.pendingUndo?.label, "Deleted “::hello”")
    }

    func testDeleteMatchesPopulatesPendingUndoLabelForBatch() throws {
        try writeMatches(["::a", "::b", "::c"], to: dir.appendingPathComponent("a.yml"))
        let store = load()
        let ids = Set(store.allMatches.map(\.id))

        try store.deleteMatches(ids)

        XCTAssertEqual(store.pendingUndo?.label, "Deleted 3 matches")
    }

    func testDeleteMatchesWithUnmatchedIDIsANoOp() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        let store = load()
        let onDisk = try String(contentsOf: dir.appendingPathComponent("a.yml"), encoding: .utf8)

        try store.deleteMatches([UUID()])

        XCTAssertEqual(store.allMatches.count, 1)
        XCTAssertNil(store.pendingUndo)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a.yml"), encoding: .utf8), onDisk)
    }

    func testDeleteMatchesEmptySetIsANoOp() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        let store = load()

        try store.deleteMatches([])

        XCTAssertEqual(store.allMatches.count, 1)
        XCTAssertNil(store.pendingUndo)
    }

    /// A failure partway through a multi-file batch must not leave the batch
    /// half-applied: the file already written this call is put back, and
    /// nothing is offered for undo since the whole operation failed.
    func testDeleteMatchesPartialFailureRollsBackFilesAlreadyWritten() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        try writeMatchYAML("::b", to: dir.appendingPathComponent("b.yml"))
        let store = load()
        let ids = Set(store.allMatches.map(\.id))
        let aPath = dir.appendingPathComponent("a.yml")
        let bPath = dir.appendingPathComponent("b.yml")
        let bOnDisk = try String(contentsOf: bPath, encoding: .utf8)

        // a.yml sorts before b.yml, and deleteMatches now processes files in
        // ascending index (== path) order specifically so this is
        // deterministic rather than dependent on Dictionary iteration order:
        // a.yml's write must succeed before b.yml's immutable-triggered
        // failure is even attempted, which is what actually exercises the
        // rollback branch rather than trivially passing because b.yml just
        // happened to fail first.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: bPath.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: bPath.path) }

        XCTAssertThrowsError(try store.deleteMatches(ids))

        XCTAssertEqual(store.allMatches.count, 2, "a partially-failed batch must not delete anything")
        XCTAssertNil(store.pendingUndo, "a failed delete has nothing to offer undo for")
        // b.yml's write was never attempted (rename onto an immutable file is
        // refused before any bytes change), so it's untouched byte-for-byte.
        XCTAssertEqual(try String(contentsOf: bPath, encoding: .utf8), bOnDisk)
        // a.yml WAS written and then rolled back — round-tripping through
        // YAMLSerializer changes incidental formatting, so compare decoded
        // content rather than raw bytes.
        let aContent = try YAMLSerializer.decodeContent(contentsOf: aPath)
        XCTAssertEqual(aContent.matches?.map(\.primaryTrigger), ["::a"],
                       "a.yml must be rolled back to its pre-delete content even though its own write succeeded")
    }

    func testDeleteSingleMatchIDStillWorksAndPopulatesPendingUndo() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        let store = load()
        let id = try XCTUnwrap(store.allMatches.first).id

        try store.delete(matchID: id)

        XCTAssertEqual(store.allMatches.count, 0)
        XCTAssertNotNil(store.pendingUndo, "delete(matchID:) is a thin wrapper over deleteMatches and must gain undo capture")
    }

    func testDeleteMatchesReplacesRatherThanMergesPendingUndo() throws {
        try writeMatches(["::a", "::b"], to: dir.appendingPathComponent("a.yml"))
        let store = load()
        let ids = store.allMatches
        let aID = try XCTUnwrap(ids.first { $0.primaryTrigger == "::a" }).id
        let bID = try XCTUnwrap(ids.first { $0.primaryTrigger == "::b" }).id

        try store.deleteMatches([aID])
        try store.deleteMatches([bID])

        XCTAssertEqual(store.pendingUndo?.entries.count, 1)
        XCTAssertEqual(store.pendingUndo?.entries.first?.match.id, bID)

        try store.undoDelete()
        XCTAssertTrue(store.allMatches.contains { $0.id == bID }, "the most recent delete is undoable")
        XCTAssertFalse(store.allMatches.contains { $0.id == aID }, "an earlier, replaced delete is not")
    }

    // MARK: - undoDelete

    func testUndoDeleteReinsertsAtOriginalIndex() throws {
        try writeMatches(["::a", "::b", "::c"], to: dir.appendingPathComponent("a.yml"))
        let store = load()
        let middle = try XCTUnwrap(store.allMatches.first { $0.primaryTrigger == "::b" })

        try store.deleteMatches([middle.id])
        try store.undoDelete()

        let triggers = store.matchFiles.first?.matches.map(\.primaryTrigger)
        XCTAssertEqual(triggers, ["::a", "::b", "::c"], "must land back in its original position, not appended")
    }

    func testUndoDeleteReinsertsMultipleInAscendingOrder() throws {
        try writeMatches(["::a", "::b", "::c", "::d", "::e"], to: dir.appendingPathComponent("a.yml"))
        let store = load()
        let toDelete = store.allMatches
            .filter { ["::b", "::d"].contains($0.primaryTrigger) }
            .map(\.id)

        try store.deleteMatches(Set(toDelete))
        try store.undoDelete()

        let triggers = store.matchFiles.first?.matches.map(\.primaryTrigger)
        XCTAssertEqual(triggers, ["::a", "::b", "::c", "::d", "::e"])
    }

    func testUndoDeleteAcrossMultipleFiles() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        try writeMatchYAML("::b", to: dir.appendingPathComponent("b.yml"))
        let store = load()
        let ids = Set(store.allMatches.map(\.id))

        try store.deleteMatches(ids)
        try store.undoDelete()

        XCTAssertEqual(store.allMatches.count, 2)
        XCTAssertNil(store.pendingUndo)
    }

    func testUndoDeleteClearsPendingUndoOnSuccess() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        let store = load()
        try store.deleteMatches([try XCTUnwrap(store.allMatches.first).id])

        try store.undoDelete()

        XCTAssertNil(store.pendingUndo)
    }

    func testUndoDeleteIsNoOpWhenNothingPending() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        let store = load()

        XCTAssertNoThrow(try store.undoDelete())
        XCTAssertEqual(store.allMatches.count, 1)
    }

    /// No in-repo path can produce a stale index today (every other mutator
    /// clears `pendingUndo`), so this constructs the edge case directly via
    /// @testable access rather than trying to race the store into it —
    /// clamping must hold regardless of how a stale index could arise.
    func testUndoDeleteClampsOutOfRangeIndexInsteadOfCrashing() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        let store = load()
        let url = dir.appendingPathComponent("a.yml")
        let ghost = EspansoMatch(trigger: "::ghost", replace: "Ghost")

        store.pendingUndo = EspansoConfigStore.PendingDelete(
            entries: [.init(url: url, match: ghost, originalIndex: 999)],
            label: "Deleted “::ghost”"
        )

        XCTAssertNoThrow(try store.undoDelete())
        XCTAssertTrue(store.allMatches.contains { $0.primaryTrigger == "::ghost" })
    }

    func testUndoDeleteSkipsAFileThatNoLongerExists() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        let store = load()
        let ghostURL = dir.appendingPathComponent("gone.yml")
        let ghost = EspansoMatch(trigger: "::ghost", replace: "Ghost")

        store.pendingUndo = EspansoConfigStore.PendingDelete(
            entries: [.init(url: ghostURL, match: ghost, originalIndex: 0)],
            label: "Deleted “::ghost”"
        )

        XCTAssertNoThrow(try store.undoDelete(), "a vanished file must be skipped, not thrown over")
        XCTAssertNil(store.pendingUndo)
    }

    // MARK: - pendingUndo invalidation

    private func makeStoreWithPendingUndo() throws -> (EspansoConfigStore, UUID) {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        let store = load()
        let deletedID = try XCTUnwrap(store.allMatches.first).id
        try store.deleteMatches([deletedID])
        XCTAssertNotNil(store.pendingUndo, "setup must actually populate pendingUndo")
        return (store, deletedID)
    }

    func testPendingUndoClearedByAdd() throws {
        let (store, _) = try makeStoreWithPendingUndo()
        try store.add(EspansoMatch(trigger: "::new", replace: "New"))
        XCTAssertNil(store.pendingUndo)
    }

    func testPendingUndoClearedByUpdate() throws {
        try writeMatches(["::a", "::b"], to: dir.appendingPathComponent("a.yml"))
        let store = load()
        var toKeep = try XCTUnwrap(store.allMatches.first { $0.primaryTrigger == "::b" })
        let toDelete = try XCTUnwrap(store.allMatches.first { $0.primaryTrigger == "::a" })
        try store.deleteMatches([toDelete.id])

        toKeep.label = "edited"
        try store.update(toKeep)

        XCTAssertNil(store.pendingUndo)
    }

    func testPendingUndoClearedByMove() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        try writeMatchYAML("::b", to: dir.appendingPathComponent("b.yml"))
        let store = load()
        let toDelete = try XCTUnwrap(store.allMatches.first { $0.primaryTrigger == "::a" })
        let toMove = try XCTUnwrap(store.allMatches.first { $0.primaryTrigger == "::b" })
        try store.deleteMatches([toDelete.id])

        try store.move(matchID: toMove.id, to: dir.appendingPathComponent("a.yml"))

        XCTAssertNil(store.pendingUndo)
    }

    func testPendingUndoClearedByDuplicate() throws {
        try writeMatches(["::a", "::b"], to: dir.appendingPathComponent("a.yml"))
        let store = load()
        let toDelete = try XCTUnwrap(store.allMatches.first { $0.primaryTrigger == "::a" })
        let toDuplicate = try XCTUnwrap(store.allMatches.first { $0.primaryTrigger == "::b" })
        try store.deleteMatches([toDelete.id])

        _ = try store.duplicate(matchID: toDuplicate.id)

        XCTAssertNil(store.pendingUndo)
    }

    func testPendingUndoClearedByRenameFile() throws {
        let (store, _) = try makeStoreWithPendingUndo()
        try store.renameFile(at: dir.appendingPathComponent("a.yml"), to: "renamed")
        XCTAssertNil(store.pendingUndo)
    }

    func testPendingUndoClearedByDeleteFile() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        try writeMatchYAML("::b", to: dir.appendingPathComponent("b.yml"))
        let store = load()
        let toDelete = try XCTUnwrap(store.allMatches.first { $0.primaryTrigger == "::a" })
        try store.deleteMatches([toDelete.id])

        try store.deleteFile(at: dir.appendingPathComponent("b.yml"))

        XCTAssertNil(store.pendingUndo)
    }

    func testPendingUndoClearedByReloadFile() throws {
        let (store, _) = try makeStoreWithPendingUndo()
        store.reloadFile(at: dir.appendingPathComponent("a.yml"))
        XCTAssertNil(store.pendingUndo)
    }

    func testPendingUndoClearedByLoad() throws {
        let (store, _) = try makeStoreWithPendingUndo()
        store.load()
        XCTAssertNil(store.pendingUndo)
    }

    func testPendingUndoClearedByExternalDirectoryChange() throws {
        let (store, _) = try makeStoreWithPendingUndo()

        // Wait out the post-write suppression window (see EspansoConfigStoreTests
        // for the same pattern) before making an external change.
        let window = XCTestExpectation(description: "suppression window elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { window.fulfill() }
        wait(for: [window], timeout: 5)

        try writeMatchYAML("::external", to: dir.appendingPathComponent("external.yml"))

        let detected = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in store.pendingUndo == nil },
            object: nil
        )
        wait(for: [detected], timeout: 5)
    }

    // MARK: - deleteFile routes user-facing removal through the Trash seam

    func testDeleteGroupOutrightCallsTrashHandler() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        let store = load()
        let url = dir.appendingPathComponent("a.yml")
        var trashed: [URL] = []
        store.trashHandler = { target in
            trashed.append(target)
            try FileManager.default.removeItem(at: target)
        }

        try store.deleteFile(at: url)

        XCTAssertEqual(trashed, [url])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDeleteGroupWithTargetCallsTrashHandlerForSourceOnly() throws {
        try writeMatchYAML("::dest", to: dir.appendingPathComponent("dest.yml"))
        try writeMatchYAML("::src", to: dir.appendingPathComponent("src.yml"))
        let store = load()
        var trashed: [URL] = []
        store.trashHandler = { target in
            trashed.append(target)
            try FileManager.default.removeItem(at: target)
        }

        try store.deleteFile(at: dir.appendingPathComponent("src.yml"),
                             movingMatchesTo: dir.appendingPathComponent("dest.yml"))

        XCTAssertEqual(trashed, [dir.appendingPathComponent("src.yml")])
        XCTAssertEqual(store.allMatches.count, 2)
    }

    /// Mirrors FileGroupingTests.testDeleteGroupCompensationRemovesADestinationItCreated,
    /// with a spy installed to pin the other half of that behavior: the
    /// internal rollback of the app's own just-created destination must never
    /// go through trashHandler — only the user-facing source removal may.
    func testDeleteGroupCompensationDoesNotUseTrashHandler() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("src.yml"))
        let store = load()
        let src = dir.appendingPathComponent("src.yml")
        let dest = dir.appendingPathComponent("dest.yml")   // never loaded

        var trashed: [URL] = []
        store.trashHandler = { target in
            trashed.append(target)
            try FileManager.default.removeItem(at: target)   // also fails on the immutable source below
        }

        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: src.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: src.path) }

        XCTAssertThrowsError(try store.deleteFile(at: src, movingMatchesTo: dest))

        XCTAssertEqual(trashed, [src], "only the user-facing source removal should go through trashHandler")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path),
                       "the destination this call created must still be rolled back on failure")
    }

    /// The one test in this file that exercises the real FileManager.trashItem
    /// API (default trashHandler, no spy) — to catch a signature/behavior
    /// regression rather than to assert store logic, which every other test
    /// above already covers via the seam. Cleans up its own Trash residue.
    func testDeleteGroupOutrightUsesRealTrashAPI() throws {
        try writeMatchYAML("::a", to: dir.appendingPathComponent("a.yml"))
        let store = load()
        let url = dir.appendingPathComponent("a.yml")

        var trashedTo: URL?
        store.trashHandler = { target in
            var result: NSURL?
            try FileManager.default.trashItem(at: target, resultingItemURL: &result)
            trashedTo = result as URL?
        }
        defer { if let trashedTo { try? FileManager.default.removeItem(at: trashedTo) } }

        try store.deleteFile(at: url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(trashedTo, "the real Trash API should report where the item landed")
    }
}
