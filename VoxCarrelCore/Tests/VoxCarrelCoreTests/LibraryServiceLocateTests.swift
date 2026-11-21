import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

@Suite struct LibraryServiceLocateTests {
    typealias F = LibraryFixture

    /// Everything the database holds that locating a file could change.
    struct Rows: Equatable {
        var books: [Book]
        var files: [BookFile]
        var batch: OperationBatch?
    }

    func rows(_ f: F) throws -> Rows {
        Rows(books: try f.store.books(), files: try f.store.allFiles(), batch: try f.store.lastBatch())
    }

    /// Every file and folder of the fixture (library, inbox and anything beside them),
    /// apart from the database's own files.
    func disk(_ f: F) -> [String] {
        tree(f.base).filter { !$0.contains(LibraryStore.databaseFileName) }
    }

    func importM4B(_ f: F, _ metadata: BookMetadata, name: String = "in.m4b") throws -> Int64 {
        try f.importNew([try f.makeM4B(name, tags: F.meta("Old", "Old Author"))], metadata)
    }

    func onlyFile(_ f: F, _ bookId: Int64) throws -> BookFile {
        try #require(try f.store.files(bookId: bookId).first)
    }

    /// Moves a file out of the way, to a folder beside the library; returns where it went.
    func moveAway(_ f: F, _ url: URL, as name: String) throws -> URL {
        let folder = f.base.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let away = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: url, to: away)
        return away
    }

    /// Expects `locateFile` to throw `cannotLocate`; returns the reason given.
    @discardableResult
    func expectCannotLocate(
        _ f: F, _ fileId: Int64, _ chosen: URL, sourceLocation: SourceLocation = #_sourceLocation
    ) -> String? {
        do {
            try f.service.locateFile(fileId: fileId, at: chosen)
            Issue.record("expected cannotLocate, but the file was located", sourceLocation: sourceLocation)
        } catch LibraryError.cannotLocate(let reason) {
            return reason
        } catch {
            Issue.record("expected cannotLocate, got \(error)", sourceLocation: sourceLocation)
        }
        return nil
    }

    // MARK: The planned folder

    /// Asks for the planned folder first, then imports a book with the same details.
    func plannedAndImported(_ f: F, _ metadata: BookMetadata) throws -> (planned: String?, imported: String?) {
        let planned = f.service.plannedFolder(for: metadata)
        let id = try importM4B(f, metadata)
        return (planned, try #require(try f.store.book(id: id)).folderPath)
    }

    // C3
    @Test func plannedFolderOfAStandaloneBookIsWhereImportFilesIt() throws {
        let f = try F()
        let (planned, imported) = try plannedAndImported(f, F.meta("Artemis", "Andy Weir"))
        #expect(planned == "Andy Weir/Artemis")
        #expect(planned == imported)
    }

    // C3
    @Test func plannedFolderOfABookInASeriesIsWhereImportFilesIt() throws {
        let f = try F()
        var metadata = F.meta("Dune Messiah", "Frank Herbert")
        metadata.series = "Dune"
        metadata.seriesNumber = "2"
        let (planned, imported) = try plannedAndImported(f, metadata)
        #expect(planned == "Frank Herbert/Dune/2 - Dune Messiah")
        #expect(planned == imported)
    }

    // C3
    @Test func plannedFolderAdoptsAnExistingFoldersCapitalisation() throws {
        let f = try F()
        try FileManager.default.createDirectory(at: f.lib("andy weir/ARTEMIS"), withIntermediateDirectories: true)
        let (planned, imported) = try plannedAndImported(f, F.meta("Artemis", "Andy Weir"))
        #expect(planned == "andy weir/ARTEMIS")
        #expect(planned == imported)
    }

    // C3: only the author's folder exists, spelled differently.
    @Test func plannedFolderAdoptsAnExistingAuthorFolder() throws {
        let f = try F()
        try FileManager.default.createDirectory(at: f.lib("andy weir"), withIntermediateDirectories: true)
        let (planned, imported) = try plannedAndImported(f, F.meta("Artemis", "Andy Weir"))
        #expect(planned == "andy weir/Artemis")
        #expect(planned == imported)
    }

    // C3
    @Test func plannedFolderIsNilWhenTheBookCannotBeFiled() throws {
        let f = try F()
        #expect(f.service.plannedFolder(for: BookMetadata(title: "Mystery")) == nil)  // no author
        #expect(f.service.plannedFolder(for: BookMetadata(title: "  ", authors: ["Andy Weir"])) == nil)
        #expect(f.libraryTree().isEmpty)  // asking creates nothing
    }

    // MARK: Refusals

    // L1
    @Test func unknownFileIdIsNotFound() throws {
        let f = try F()
        _ = try importM4B(f, F.meta("Artemis", "Andy Weir"))
        let chosen = try f.makeM4B("chosen.m4b", tags: F.meta("x", "y"))
        let (rowsBefore, diskBefore) = (try rows(f), disk(f))

        #expect(throws: LibraryError.fileNotFound(999)) { try f.service.locateFile(fileId: 999, at: chosen) }

        #expect(try rows(f) == rowsBefore)
        #expect(disk(f) == diskBefore)
    }

    // L2
    @Test func aFileThatIsNotMissingIsRefused() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"))
        let fileId = try #require(try onlyFile(f, id).id)
        let chosen = try f.makeM4B("chosen.m4b", tags: F.meta("x", "y"))
        let (rowsBefore, diskBefore) = (try rows(f), disk(f))
        let recordedBytes = try f.bytes(f.lib("Andy Weir/Artemis/Artemis.m4b"))

        let reason = expectCannotLocate(f, fileId, chosen)

        #expect(reason?.contains("the file is not missing") == true)
        #expect(try rows(f) == rowsBefore)
        #expect(disk(f) == diskBefore)
        #expect(try f.bytes(f.lib("Andy Weir/Artemis/Artemis.m4b")) == recordedBytes)
    }

    // L3
    @Test func theChosenItemMustBeARegularFileOfTheSameFormat() throws {
        let f = try F()
        let fm = FileManager.default
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"))
        let fileId = try #require(try onlyFile(f, id).id)
        _ = try moveAway(f, f.lib("Andy Weir/Artemis/Artemis.m4b"), as: "gone.m4b")
        _ = try f.service.reconcile()

        let real = try f.makeM4B("real.m4b", tags: F.meta("x", "y"))
        let folder = f.inbox.appendingPathComponent("Folder.m4b", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = f.inbox.appendingPathComponent("link.m4b")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let otherFormat = try f.makeMP3("other.mp3", tags: F.meta("x", "y"))
        let sibling = try f.makeM4B("sibling.m4a", tags: F.meta("x", "y"))  // audio, but not an M4B
        let absent = f.inbox.appendingPathComponent("absent.m4b")
        let (rowsBefore, diskBefore) = (try rows(f), disk(f))

        for chosen in [folder, link, otherFormat, sibling, absent] {
            expectCannotLocate(f, fileId, chosen)
            #expect(try rows(f) == rowsBefore, "\(chosen.lastPathComponent)")
            #expect(disk(f) == diskBefore, "\(chosen.lastPathComponent)")
        }
        #expect(try f.store.book(id: id)?.needsAttention == true)
        let target = try fm.destinationOfSymbolicLink(atPath: link.path)
        #expect(URL(fileURLWithPath: target).lastPathComponent == "real.m4b")  // still a link
    }

    // L4
    @Test func aFileThatBelongsToABookIsRefused() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"))
        _ = try importM4B(f, F.meta("Other", "Other Author"), name: "o.m4b")
        let fileId = try #require(try onlyFile(f, id).id)
        _ = try moveAway(f, f.lib("Andy Weir/Artemis/Artemis.m4b"), as: "gone.m4b")
        let (rowsBefore, diskBefore) = (try rows(f), disk(f))

        // Named as the database has it, and with other capitalisation.
        expectCannotLocate(f, fileId, f.lib("Other Author/Other/Other.m4b"))
        expectCannotLocate(f, fileId, f.lib("other author/OTHER/other.m4b"))

        #expect(try rows(f) == rowsBefore)
        #expect(disk(f) == diskBefore)
    }

    // L4: also a file of a book that was catalogued where it was (an absolute path).
    @Test func aFileOfABookLeftInPlaceIsRefused() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"))
        let loose = try f.makeM4B("loose.m4b", tags: F.meta("x", "y"))
        _ = try f.service.importItems([ImportItem(candidate: f.candidate([loose], BookMetadata(title: "Mystery")))])
        let fileId = try #require(try onlyFile(f, id).id)
        _ = try moveAway(f, f.lib("Andy Weir/Artemis/Artemis.m4b"), as: "gone.m4b")
        let (rowsBefore, diskBefore) = (try rows(f), disk(f))

        expectCannotLocate(f, fileId, loose)

        #expect(try rows(f) == rowsBefore)
        #expect(disk(f) == diskBefore)
    }

    // MARK: A file inside the library

    // L5, L7
    @Test func aLibraryFileIsMovedToExactlyTheRecordedPlace() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"))
        let other = try importM4B(f, F.meta("Other", "Other Author"), name: "o.m4b")
        let chosen = try moveAway(f, f.lib("Andy Weir/Artemis/Artemis.m4b"), as: "Some Download (1).m4b")
        try FileManager.default.removeItem(at: f.lib("Andy Weir"))  // the folders have gone too
        let report = try f.service.reconcile()
        #expect(report.booksWithMissingFiles == [id])
        let filesBefore = try f.store.allFiles()
        let bytes = try f.bytes(chosen)
        var expected = try #require(try f.store.book(id: id))
        #expect(expected.needsAttention)
        expected.needsAttention = false

        try f.service.locateFile(fileId: try #require(try onlyFile(f, id).id), at: chosen)

        #expect(f.libraryTree() == [
            "Andy Weir", "Andy Weir/Artemis", "Andy Weir/Artemis/Artemis.m4b",
            "Other Author", "Other Author/Other", "Other Author/Other/Other.m4b",
        ])
        #expect(!exists(chosen))
        #expect(try f.bytes(f.lib("Andy Weir/Artemis/Artemis.m4b")) == bytes)  // L7: not rewritten
        #expect(try f.store.allFiles() == filesBefore)  // the same rows, ids included
        #expect(try f.store.book(id: id) == expected)  // L8
        #expect(try f.store.book(id: other)?.needsAttention == false)
        #expect(try f.service.reconcile() == ReconcileReport())
    }

    // L5: a chosen file that is itself in the library (found by the launch check as untracked).
    @Test func anUntrackedFileInTheLibraryCanBeChosen() throws {
        let f = try F()
        let fm = FileManager.default
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"))
        try fm.createDirectory(at: f.lib("Stray"), withIntermediateDirectories: true)
        try fm.moveItem(at: f.lib("Andy Weir/Artemis/Artemis.m4b"), to: f.lib("Stray/renamed.m4b"))
        #expect(try f.service.reconcile().untrackedFiles.map(\.lastPathComponent) == ["renamed.m4b"])

        try f.service.locateFile(fileId: try #require(try onlyFile(f, id).id), at: f.lib("Stray/renamed.m4b"))

        #expect(exists(f.lib("Andy Weir/Artemis/Artemis.m4b")))
        #expect(!exists(f.lib("Stray/renamed.m4b")))
        #expect(try f.store.book(id: id)?.needsAttention == false)
        #expect(try f.service.reconcile().untrackedFiles.isEmpty)
    }

    // L5: the recorded place is taken by something that is not the file (here a link to
    // nowhere, which the launch check also reads as a missing file).
    @Test func nothingAtTheRecordedPlaceIsOverwritten() throws {
        let f = try F()
        let fm = FileManager.default
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"))
        let fileId = try #require(try onlyFile(f, id).id)
        let recorded = f.lib("Andy Weir/Artemis/Artemis.m4b")
        let chosen = try moveAway(f, recorded, as: "found.m4b")
        try fm.createSymbolicLink(atPath: recorded.path, withDestinationPath: "/nowhere/at/all.m4b")
        #expect(try f.service.reconcile().booksWithMissingFiles == [id])
        let bytes = try f.bytes(chosen)
        let (rowsBefore, diskBefore) = (try rows(f), disk(f))

        expectCannotLocate(f, fileId, chosen)

        #expect(try rows(f) == rowsBefore)
        #expect(disk(f) == diskBefore)
        #expect(try fm.destinationOfSymbolicLink(atPath: recorded.path) == "/nowhere/at/all.m4b")
        #expect(try f.bytes(chosen) == bytes)
    }

    // L5: when the database cannot be written the file goes back where it was chosen.
    @Test func aFailedCommitPutsTheChosenFileBack() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"))
        let fileId = try #require(try onlyFile(f, id).id)
        let chosen = try moveAway(f, f.lib("Andy Weir/Artemis/Artemis.m4b"), as: "found.m4b")
        _ = try f.service.reconcile()
        let bytes = try f.bytes(chosen)
        let (rowsBefore, diskBefore) = (try rows(f), disk(f))
        f.service.beforeCommit = { throw Boom() }

        #expect(throws: Boom.self) { try f.service.locateFile(fileId: fileId, at: chosen) }

        #expect(try rows(f) == rowsBefore)
        // Every file is where it was. The book's folders, left empty once more, are
        // tidied away as after any move out of the library.
        #expect(diskBefore == [
            "Elsewhere", "Elsewhere/found.m4b", "Inbox", "Library", "Library/Andy Weir", "Library/Andy Weir/Artemis",
        ])
        #expect(disk(f) == ["Elsewhere", "Elsewhere/found.m4b", "Inbox", "Library"])
        #expect(try f.bytes(chosen) == bytes)
    }

    // MARK: A file kept outside the library

    // L6
    @Test func aBookLeftInPlaceHasItsFileRecordedWhereItWasChosen() throws {
        let f = try F()
        let source = try f.makeM4B("mystery.m4b", tags: F.meta("Old", "Old Author"))
        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([source], BookMetadata(title: "Mystery")))
        ])
        guard case .needsAttention(let id) = result.outcomes[0] else {
            Issue.record("expected .needsAttention, got \(result.outcomes)")
            return
        }
        let before = try onlyFile(f, id)
        #expect(before.path.hasPrefix("/"))
        let chosen = try moveAway(f, source, as: "Mystery (moved).m4b")
        let bytes = try f.bytes(chosen)
        let bookBefore = try f.store.book(id: id)
        let diskBefore = disk(f)

        try f.service.locateFile(fileId: try #require(before.id), at: chosen)

        var expected = before
        expected.path = chosen.standardizedFileURL.path
        #expect(try f.store.files(bookId: id) == [expected])  // only the path changed
        #expect(exists(f.store.url(for: try onlyFile(f, id))))
        #expect(disk(f) == diskBefore)  // nothing is moved
        #expect(try f.bytes(chosen) == bytes)  // L7
        // L8: it was not flagged for a missing file, so it stays flagged.
        #expect(try f.store.book(id: id) == bookBefore)
        #expect(bookBefore?.needsAttention == true)
        #expect(try f.service.reconcile() == ReconcileReport())
    }

    // L7: the file is taken on its name alone. This one is deliberately not a real M4B:
    // had it been opened to be read or written, that would have failed or changed it.
    @Test func theChosenFileIsNeitherOpenedNorWritten() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"))
        try FileManager.default.removeItem(at: f.lib("Andy Weir/Artemis/Artemis.m4b"))
        let chosen = f.inbox.appendingPathComponent("unreadable.M4B")
        let content = Data("not audio at all".utf8)
        try content.write(to: chosen)
        let modified = try #require(
            try FileManager.default.attributesOfItem(atPath: chosen.path)[.modificationDate] as? Date)

        try f.service.locateFile(fileId: try #require(try onlyFile(f, id).id), at: chosen)

        let recorded = f.lib("Andy Weir/Artemis/Artemis.m4b")
        #expect(try f.bytes(recorded) == content)
        #expect(try FileManager.default.attributesOfItem(atPath: recorded.path)[.modificationDate] as? Date == modified)
        #expect(try onlyFile(f, id).writeProblem == nil)
    }

    // MARK: The needs-attention flag

    // L8
    @Test func aBookStaysFlaggedUntilItsLastMissingFileIsLocated() throws {
        let f = try F()
        let parts = try f.makeMP3Parts(folder: "parts", tags: F.meta("x", "y"))
        let id = try f.importNew(parts, F.meta("Artemis", "Andy Weir"))
        let first = try moveAway(f, f.lib("Andy Weir/Artemis/01 - Artemis.mp3"), as: "one.mp3")
        let second = try moveAway(f, f.lib("Andy Weir/Artemis/02 - Artemis.mp3"), as: "two.mp3")
        #expect(try f.service.reconcile().booksWithMissingFiles == [id])
        #expect(try f.store.book(id: id)?.needsAttention == true)

        var files = try f.store.files(bookId: id)
        try f.service.locateFile(fileId: try #require(files[0].id), at: first)

        #expect(try f.store.book(id: id)?.needsAttention == true)
        #expect(f.libraryTree() == ["Andy Weir", "Andy Weir/Artemis", "Andy Weir/Artemis/01 - Artemis.mp3"])

        files = try f.store.files(bookId: id)
        try f.service.locateFile(fileId: try #require(files[1].id), at: second)

        #expect(try f.store.book(id: id)?.needsAttention == false)
        #expect(f.libraryTree() == [
            "Andy Weir", "Andy Weir/Artemis", "Andy Weir/Artemis/01 - Artemis.mp3",
            "Andy Weir/Artemis/02 - Artemis.mp3",
        ])
        #expect(try f.service.reconcile() == ReconcileReport())
    }

    // L8: the same check as the launch check, so a book it has not yet seen with a file
    // still missing is flagged, as it would be at the next launch.
    @Test func aBookNotYetCheckedIsFlaggedWhileAnotherFileIsMissing() throws {
        let f = try F()
        let parts = try f.makeMP3Parts(folder: "parts", tags: F.meta("x", "y"))
        let id = try f.importNew(parts, F.meta("Artemis", "Andy Weir"))
        let first = try moveAway(f, f.lib("Andy Weir/Artemis/01 - Artemis.mp3"), as: "one.mp3")
        _ = try moveAway(f, f.lib("Andy Weir/Artemis/02 - Artemis.mp3"), as: "two.mp3")
        #expect(try f.store.book(id: id)?.needsAttention == false)

        try f.service.locateFile(fileId: try #require(try f.store.files(bookId: id)[0].id), at: first)

        #expect(try f.store.book(id: id)?.needsAttention == true)
    }

    // L8: a filed book that is flagged because it can no longer be filed stays flagged.
    @Test func aBookFlaggedForAnotherReasonStaysFlagged() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"))
        var edit = BookEdit(book: try #require(try f.store.book(id: id)))
        edit.metadata.authors = []
        _ = try f.service.save([edit])
        #expect(try f.store.book(id: id)?.needsAttention == true)
        let row = try onlyFile(f, id)
        let recorded = f.store.url(for: row)
        let chosen = try moveAway(f, recorded, as: "found.m4b")

        try f.service.locateFile(fileId: try #require(row.id), at: chosen)

        #expect(exists(recorded))
        #expect(try f.store.book(id: id)?.needsAttention == true)
    }

    // MARK: Undo

    // L9
    @Test func locatingAFileOfTheLastOperationsBookForgetsThatOperation() throws {
        let f = try F()
        let source = try f.makeM4B("in.m4b", tags: F.meta("Old", "Old Author"), cover: F.jpeg)
        let id = try f.importNew([source], F.meta("Artemis", "Andy Weir"))
        _ = try f.service.save([BookEdit(book: try #require(try f.store.book(id: id)), cover: .set(F.png))])
        #expect(try f.service.undoLabel() == "Edit Artemis")
        #expect(f.hiddenTree().contains { $0.hasPrefix("undo/") })
        let recorded = f.lib("Andy Weir/Artemis/Artemis.m4b")
        let chosen = f.base.appendingPathComponent("backup.m4b")
        try FileManager.default.copyItem(at: recorded, to: chosen)
        try FileManager.default.removeItem(at: recorded)  // deleted on disk

        try f.service.locateFile(fileId: try #require(try onlyFile(f, id).id), at: chosen)

        #expect(exists(recorded))
        #expect(try f.service.undoLabel() == nil)
        #expect(try f.store.lastBatch() == nil)
        #expect(throws: LibraryError.nothingToUndo) { try f.service.undoLast() }
        #expect(!f.hiddenTree().contains { $0.hasPrefix("undo") })
        #expect(exists(recorded))
    }

    // L9: locating is not itself recorded, and an operation on other books can still be undone.
    @Test func locatingAFileOfAnotherBookKeepsTheLastOperation() throws {
        let f = try F()
        let old = try importM4B(f, F.meta("Old Book", "Ann Author"), name: "old.m4b")
        let recent = try importM4B(f, F.meta("Recent", "Ben Author"), name: "recent.m4b")
        let batch = try f.store.lastBatch()
        let chosen = try moveAway(f, f.lib("Ann Author/Old Book/Old Book.m4b"), as: "found.m4b")

        try f.service.locateFile(fileId: try #require(try onlyFile(f, old).id), at: chosen)

        #expect(try f.store.lastBatch() == batch)
        #expect(try f.service.undoLabel() == "Import 1 book")
        try f.service.undoLast()
        #expect(try f.store.book(id: recent) == nil)
        #expect(exists(f.lib("Ann Author/Old Book/Old Book.m4b")))
    }
}
