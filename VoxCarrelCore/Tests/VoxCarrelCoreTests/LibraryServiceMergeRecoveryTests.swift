import Foundation
import GRDB
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// A file manager that makes a number of moves and then no more: every later move
/// fails, those that would put a file back included, as if the app had stopped dead.
final class StoppingFileManager: FileManager, @unchecked Sendable {
    /// How many moves are made before the stop; nil for no stop.
    var movesBeforeStop: Int?
    private(set) var made = 0

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if let movesBeforeStop, made >= movesBeforeStop { throw CocoaError(.fileWriteUnknown) }
        try super.moveItem(at: srcURL, to: dstURL)
        made += 1
    }
}

/// A merge that is cut short is put right when the library is next opened.
@Suite struct LibraryServiceMergeRecoveryTests {
    typealias F = LibraryFixture

    struct Stopped: Error {}

    /// Everything a merge may touch, in one comparable value.
    struct Whole: Equatable {
        var books: [Book]
        var files: [BookFile]
        /// Every file in the library folder but the catalogue and the hidden folder, with its bytes.
        var bytes: [String: Data]
        /// Every folder there.
        var folders: [String]
        var covers: [Int64: Data]
        /// The stored covers, as files.
        var coverFiles: Int
        var memberships: [String]
    }

    private func whole(_ f: F) throws -> Whole {
        let books = try f.store.books().sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        var bytes: [String: Data] = [:]
        var folders: [String] = []
        for path in f.libraryTree() {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: f.lib(path).path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue { folders.append(path) } else { bytes[path] = try f.bytes(f.lib(path)) }
        }
        var covers: [Int64: Data] = [:]
        for book in books {
            let id = try #require(book.id)
            if let image = f.service.covers.image(for: id) { covers[id] = image.data }
        }
        let memberships = try f.store.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT collectionId, bookId FROM collectionBook ORDER BY 1, 2")
                .map { "\($0[0] as Int64):\($0[1] as Int64)" }
        }
        return Whole(
            books: books, files: try f.store.allFiles(), bytes: bytes, folders: folders, covers: covers,
            coverFiles: f.hiddenTree().filter { $0.hasPrefix("covers/") }.count, memberships: memberships)
    }

    private struct Case {
        var kept: Int64
        var ids: [Int64]
    }

    /// An ebook that is kept and has no cover, an audiobook with a cover and more
    /// details, a PDF and a companion PDF: the merge moves every file (the kept book is
    /// filed in another folder), writes three of them, and takes the audiobook's cover.
    private func entries(_ f: F) throws -> Case {
        let kept = try f.importNew([try f.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))
        try f.service.covers.remove(for: kept)
        let audio = try f.importNew(
            [try f.makeM4B("dune.m4b", tags: F.meta("Old", "Old Author"), cover: F.png)],
            F.fullMeta("Dune Audio", "Frank Herbert"))
        let text = try f.importNew([try f.makePDF("text.pdf")], F.meta("Dune Text", "Frank Herbert"))
        let companion = try f.importNew(
            [try f.makePDF("companion.pdf", pages: 2)], F.meta("Dune [B09WXN61GL]", "Frank Herbert"))
        let shelf = try #require(try f.store.createCollection(name: "Shelf").id)
        try f.store.add(bookId: text, toCollection: shelf)
        let plan = try f.service.planMerge(bookIds: [kept, audio, text, companion], keep: kept)
        #expect(plan.blockers.isEmpty)
        #expect(plan.files.map(\.role) == [.ebook, .audio, .ebook, .extra])
        #expect(plan.resultFolder == "Frank Herbert/The Series/2 - Dune")
        return Case(kept: kept, ids: [kept, audio, text, companion])
    }

    /// A service of another run of the app on the same library.
    private func reopened(_ f: F, organiser: Organiser = Organiser()) throws -> LibraryService {
        LibraryService(store: try LibraryStore(libraryRoot: f.root), metadataIO: FileMetadataIO(), organiser: organiser)
    }

    private func hasRecord(_ f: F) -> Bool {
        f.hiddenTree().contains(MergeIntent.fileName)
    }

    /// The library opened again after a merge that stopped: it is as it was before, and
    /// a second check finds nothing to tell.
    private func expectPutBack(
        _ f: F, to before: Whole, undoDataGone: Bool = true, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let service = try reopened(f)
        let report = try service.reconcile()
        #expect(report.mergeProblem == nil, sourceLocation: sourceLocation)
        #expect(report.mergeFilesOutOfPlace.isEmpty, sourceLocation: sourceLocation)
        #expect(report.booksWithMissingFiles.isEmpty, sourceLocation: sourceLocation)
        #expect(report.untrackedFiles.isEmpty, sourceLocation: sourceLocation)
        #expect(try whole(f) == before, sourceLocation: sourceLocation)
        #expect(!hasRecord(f), sourceLocation: sourceLocation)
        #expect(!service.hasInterruptedMerge, sourceLocation: sourceLocation)
        // No undo data of the merge is kept: there is nothing of it to undo.
        if undoDataGone {
            #expect(!f.hiddenTree().contains { $0.hasSuffix(".orig") }, sourceLocation: sourceLocation)
        }
        #expect(try service.reconcile() == ReconcileReport(), sourceLocation: sourceLocation)
        #expect(try whole(f) == before, sourceLocation: sourceLocation)
    }

    // MARK: Stopped at a stage of the merge

    static let stages: [MergeCheckpoint] = [
        .originalsSaved, .recorded, .moved, .tagsWritten(1), .tagsWritten(2), .tagsWritten(3),
    ]

    @Test(arguments: stages)
    func aMergeStoppedBeforeTheCatalogueIsWrittenIsPutBackWhenTheLibraryIsNextOpened(_ stage: MergeCheckpoint) throws {
        let f = try F()
        let s = try entries(f)
        let before = try whole(f)
        var reached = false
        f.service.mergeCheckpoint = { now in
            if now == stage {
                reached = true
                throw Stopped()
            }
        }

        #expect(throws: Stopped.self) { try f.service.mergeBooks(s.ids, keep: s.kept, roles: [:]) }
        #expect(reached)

        if stage != .originalsSaved {
            // The record is there, something is out of place, and nothing else may be changed.
            #expect(hasRecord(f))
            #expect(f.service.hasInterruptedMerge)
            if stage != .recorded { #expect(try whole(f) != before) }
            var edit = BookEdit(book: try #require(try f.store.book(id: s.kept)))
            edit.rating = 5
            #expect(throws: LibraryError.mergeInterrupted) { _ = try f.service.save([edit]) }
            #expect(throws: LibraryError.mergeInterrupted) {
                try f.service.mergeBooks(s.ids, keep: s.kept, roles: [:])
            }
            #expect(try f.service.planMerge(bookIds: s.ids, keep: s.kept).blockers.first == .mergeInterrupted)
        }
        // (Stopped before the record was written, nothing had moved; what was saved for
        // undo is cleared away with the next operation.)
        try expectPutBack(f, to: before, undoDataGone: stage != .originalsSaved)

        // And the merge can then be made.
        let again = try reopened(f)
        try again.mergeBooks(s.ids, keep: s.kept, roles: [:])
        #expect(try f.store.books().map(\.id) == [s.kept])
        #expect(!hasRecord(f))
        #expect(f.hiddenTree().filter { $0.hasPrefix("undo/") && $0.split(separator: "/").count == 2 }.count == 1)
    }

    @Test(arguments: [1, 2, 3])
    func aMergeStoppedAfterSomeOfItsMovesIsPutBack(_ moves: Int) throws {
        let files = StoppingFileManager()
        let f = try F(organiser: Organiser(fileManager: files))
        let s = try entries(f)
        let before = try whole(f)
        let made = files.made
        files.movesBeforeStop = made + moves

        #expect(throws: (any Error).self) { try f.service.mergeBooks(s.ids, keep: s.kept, roles: [:]) }
        #expect(files.made == made + moves)
        #expect(hasRecord(f))
        #expect(try whole(f).bytes.keys.sorted() != before.bytes.keys.sorted())

        try expectPutBack(f, to: before)
    }

    @Test func foldersTheMergeHadMadeForFilesThatNeverArrivedAreRemoved() throws {
        let f = try F()
        let s = try entries(f)
        let before = try whole(f)
        f.service.mergeCheckpoint = { if $0 == .recorded { throw Stopped() } }
        #expect(throws: Stopped.self) { try f.service.mergeBooks(s.ids, keep: s.kept, roles: [:]) }
        // As the app stopping between making a file's folder and moving the file leaves it.
        try FileManager.default.createDirectory(
            at: f.lib("Frank Herbert/The Series/2 - Dune/Extras"), withIntermediateDirectories: true)
        #expect(try whole(f).folders != before.folders)

        try expectPutBack(f, to: before)
    }

    @Test func aMergeStoppedWhileAFileWasSetAsideOnTheWayIsPutBack() throws {
        let files = StoppingFileManager()
        let f = try F(organiser: Organiser(fileManager: files))
        func entry(_ dir: String, _ main: URL, title: String, pages: Int) throws -> Int64 {
            let extra = try f.makePDF("\(dir)/notes.pdf", pages: pages)
            let result = try f.service.importItems([
                ImportItem(candidate: f.candidate([main, extra], F.meta(title, "Frank Herbert"), roles: [extra: .extra]))
            ])
            return try f.importedId(try #require(result.outcomes.first))
        }
        // The kept book's extra goes where the other's is, which is set aside first.
        let audio = try entry("a", try f.makeM4B("a/dune.m4b", tags: BookMetadata()), title: "Dune (Unabridged)", pages: 3)
        let text = try entry("t", try f.makePDF("t/dune.pdf", pages: 4), title: "Dune", pages: 5)
        var edit = BookEdit(book: try #require(try f.store.book(id: audio)))
        edit.metadata.title = "Dune"
        _ = try f.service.save([edit])
        let before = try whole(f)

        for moves in [1, 2] {
            files.movesBeforeStop = files.made + moves
            #expect(throws: (any Error).self) { try f.service.mergeBooks([audio, text], keep: audio, roles: [:]) }
            #expect(hasRecord(f))
            #expect(try whole(f) != before)
            try expectPutBack(f, to: before)
        }
    }

    // MARK: Stopped once the catalogue was written

    @Test func aMergeStoppedOnceTheCatalogueWasWrittenIsOnlyTidiedUp() throws {
        // What the merge leaves when nothing stops it.
        let whole0 = try F()
        let s0 = try entries(whole0)
        try whole0.service.mergeBooks(s0.ids, keep: s0.kept, roles: [:])
        let finished = try whole(whole0)
        #expect(finished.coverFiles == 1)

        let f = try F()
        let s = try entries(f)
        var atCommit: Whole?
        f.service.mergeCheckpoint = { stage in
            if stage == .committed {
                atCommit = try self.whole(f)
                throw Stopped()
            }
        }
        #expect(throws: Stopped.self) { try f.service.mergeBooks(s.ids, keep: s.kept, roles: [:]) }
        #expect(hasRecord(f))
        // The covers of the entries that are gone were still to be removed.
        var expected = try #require(atCommit)
        #expect(expected.coverFiles > 1)
        expected.coverFiles = 1

        let service = try reopened(f)
        let report = try service.reconcile()
        #expect(report == ReconcileReport())
        #expect(try whole(f) == expected)
        #expect(!hasRecord(f))
        #expect(try f.store.books().map(\.id) == [s.kept])
        // As a merge that was not stopped leaves it (the files' own bytes aside, which hold dates).
        let after = try whole(f)
        #expect(after.bytes.keys.sorted() == finished.bytes.keys.sorted())
        #expect(after.folders == finished.folders)
        #expect(after.covers.count == finished.covers.count)
        #expect(after.covers[s.kept] == F.png.data)
        #expect(try service.reconcile() == ReconcileReport())

        // The merge is still the operation that undo reverses, exactly.
        #expect(try service.undoLast() == "Merge Books")
        #expect(try f.store.books().count == 4)
        #expect(try service.reconcile() == ReconcileReport())
    }

    @Test func theCoverTheKeptBookTakesIsSetWhenTheMergeStoppedBeforeItWas() throws {
        let f = try F()
        let s = try entries(f)
        f.service.mergeCheckpoint = { stage in
            if stage == .committed {
                // As if the app had stopped before the stored covers were brought up to date.
                try f.service.covers.remove(for: s.kept)
                throw Stopped()
            }
        }
        #expect(throws: Stopped.self) { try f.service.mergeBooks(s.ids, keep: s.kept, roles: [:]) }
        #expect(f.service.covers.image(for: s.kept) == nil)

        _ = try reopened(f).reconcile()

        #expect(f.service.covers.image(for: s.kept)?.data == F.png.data)
        #expect(f.hiddenTree().filter { $0.hasPrefix("covers/") }.count == 1)
        #expect(!hasRecord(f))
    }

    // MARK: Putting right, interrupted and blocked

    @Test func puttingAMergeRightCanItselfBeStoppedAndRunAgain() throws {
        let f = try F()
        let s = try entries(f)
        let before = try whole(f)
        f.service.mergeCheckpoint = { if $0 == .tagsWritten(2) { throw Stopped() } }
        #expect(throws: Stopped.self) { try f.service.mergeBooks(s.ids, keep: s.kept, roles: [:]) }

        // The first attempt stops after one, then two, moves back.
        for moves in [1, 2] {
            let files = StoppingFileManager()
            files.movesBeforeStop = moves
            let stopped = try reopened(f, organiser: Organiser(fileManager: files))
            let report = try stopped.reconcile()
            #expect(report.mergeProblem != nil)
            #expect(!report.mergeFilesOutOfPlace.isEmpty)
            #expect(!report.recoveredMerge)
            #expect(hasRecord(f))
            #expect(stopped.hasInterruptedMerge)
        }
        let service = try reopened(f)
        let report = try service.reconcile()
        #expect(report.recoveredMerge)
        #expect(report.mergeProblem == nil)
        try expectPutBack(f, to: before)
    }

    @Test func aFileThatCannotGoBackKeepsTheRecordAndIsToldOfUntilItCan() throws {
        let f = try F()
        let s = try entries(f)
        let before = try whole(f)
        f.service.mergeCheckpoint = { if $0 == .moved { throw Stopped() } }
        #expect(throws: Stopped.self) { try f.service.mergeBooks(s.ids, keep: s.kept, roles: [:]) }
        let stopped = try whole(f)

        // Something has been put where a file has to go back to.
        let inTheWay = try touch(f.lib("Frank Herbert/Dune Text/Dune Text.pdf"), "in the way")
        let service = try reopened(f)
        let report = try service.reconcile()
        #expect(report.mergeProblem?.hasPrefix("A merge of books was interrupted") == true)
        #expect(!report.mergeFilesOutOfPlace.isEmpty)
        #expect(!report.recoveredMerge)
        // The check waits: nothing is flagged, and nothing was moved, replaced or deleted.
        #expect(report.booksWithMissingFiles.isEmpty)
        #expect(try read(inTheWay) == "in the way")
        var blocked = try whole(f)
        #expect(blocked.bytes.removeValue(forKey: "Frank Herbert/Dune Text/Dune Text.pdf") == Data("in the way".utf8))
        blocked.folders.removeAll { $0 == "Frank Herbert/Dune Text" }
        #expect(blocked == stopped)
        #expect(hasRecord(f))
        #expect(throws: LibraryError.mergeInterrupted) { try service.undoLast() }

        // Out of the way, the next check puts everything back.
        try FileManager.default.removeItem(at: inTheWay)
        #expect(try service.reconcile().recoveredMerge)
        try expectPutBack(f, to: before)
    }

    @Test func givingUpRemovesTheRecordAndTouchesNothingElse() throws {
        let f = try F()
        let s = try entries(f)
        f.service.mergeCheckpoint = { if $0 == .moved { throw Stopped() } }
        #expect(throws: Stopped.self) { try f.service.mergeBooks(s.ids, keep: s.kept, roles: [:]) }
        let stopped = try whole(f)

        let service = try reopened(f)
        try service.discardInterruptedMerge()

        #expect(!hasRecord(f))
        #expect(!service.hasInterruptedMerge)
        #expect(try whole(f) == stopped)
        // The ordinary check then says what is where.
        let report = try service.reconcile()
        #expect(report.mergeProblem == nil)
        #expect(report.booksWithMissingFiles.count == 4)
        #expect(report.untrackedFiles.count == 4)
        // Nothing to give up on: nothing happens.
        try service.discardInterruptedMerge()
    }

    @Test func aRecordThatCannotBeReadIsToldOfAndKept() throws {
        let f = try F()
        _ = try entries(f)
        let before = try whole(f)
        try Data("not a record".utf8).write(to: f.service.mergeIntentURL)

        let report = try reopened(f).reconcile()

        #expect(report.mergeProblem?.contains("cannot be read") == true)
        #expect(hasRecord(f))
        #expect(try whole(f) == before)
    }

    // MARK: A merge that is not stopped

    @Test func aMergeThatIsMadeOrRefusedOrFailsLeavesNoRecord() throws {
        let files = StoppingFileManager()
        let f = try F(organiser: Organiser(fileManager: files))
        let s = try entries(f)
        // Fails at the commit: everything is put back there and then.
        f.service.beforeCommit = { throw Stopped() }
        #expect(throws: Stopped.self) { try f.service.mergeBooks(s.ids, keep: s.kept, roles: [:]) }
        #expect(!hasRecord(f))
        f.service.beforeCommit = nil
        // Refused.
        #expect(throws: LibraryError.self) { try f.service.mergeBooks([s.kept], keep: s.kept, roles: [:]) }
        #expect(!hasRecord(f))
        // Made.
        try f.service.mergeBooks(s.ids, keep: s.kept, roles: [:])
        #expect(!hasRecord(f))
        #expect(try f.service.reconcile() == ReconcileReport())
    }
}
