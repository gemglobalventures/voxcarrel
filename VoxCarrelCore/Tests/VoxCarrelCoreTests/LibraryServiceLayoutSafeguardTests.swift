import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// Further safeguards of the folder layout: folders on another disk, renames forced to
/// disk before the catalogue is written, a record that says more than the disk shows,
/// new books and folders that are taken, and names the library needs for itself.
@Suite struct LibraryServiceLayoutSafeguardTests {
    typealias F = LibraryFixture

    static let byKind = "{Kind}/{Author}/[{Series}/][{Number} - ]{Title}"
    static let otherDisk = "Its folder is on another disk."
    static let ownFiles = "Its folder would have the same name as the library's own files."
    static let takenByAnother =
        "Another book already uses the folder this book belongs in. Add these files to that book instead, "
        + "or change one book's details."

    private func stay(_ plan: LayoutChangePlan, _ id: Int64) -> String? {
        plan.staying.first { $0.bookId == id }?.reason
    }

    private func failure(_ outcome: ImportOutcome) -> String? {
        if case .failed(let reason) = outcome { return reason }
        return nil
    }

    private func reopened(_ f: F) throws -> LibraryService {
        LibraryService(store: try LibraryStore(libraryRoot: f.root))
    }

    // MARK: A folder on another disk

    @Test func aBookWhoseFolderIsOnAnotherDiskStaysAndTheOthersMove() throws {
        let f = try F()
        let away = try f.shelve("One", "Ann")
        let here = try f.shelve("Two", "Bob")
        // Ann's folder is a way through to another disk.
        f.service.volumeOfFolder = { $0.pathComponents.contains("Ann") ? 2 : 1 }
        let renames = f.countRenames()

        let plan = try f.service.planLayoutChange(to: try FolderPattern(Self.byKind))
        #expect(stay(plan, away) == Self.otherDisk)
        #expect(plan.moves.map(\.bookId) == [here])

        let done = try f.service.applyLayoutChange(to: try FolderPattern(Self.byKind))
        #expect(stay(done, away) == Self.otherDisk)
        #expect(renames() == 1)
        #expect(try f.folder(away) == "Ann/One")
        #expect(try !f.flagged(away))
        #expect(try f.folder(here) == "Audiobooks/Bob/Two")
        #expect(try read(f.lib("Ann/One/One.m4b")) == "One by Ann: One.m4b")
        #expect(try f.service.reconcile() == ReconcileReport())
    }

    @Test func aBookWhoseNewFolderWouldBeOnAnotherDiskStays() throws {
        let f = try F()
        let ebook = try f.shelve("One", "Ann", files: ["One.epub"])
        let audio = try f.shelve("Two", "Bob")
        // "Audiobooks" is already there, and leads to another disk.
        try FileManager.default.createDirectory(at: f.lib("Audiobooks"), withIntermediateDirectories: true)
        f.service.volumeOfFolder = { $0.pathComponents.contains("Audiobooks") ? 2 : 1 }

        let done = try f.service.applyLayoutChange(to: try FolderPattern(Self.byKind))
        #expect(stay(done, audio) == Self.otherDisk)
        #expect(try f.folder(audio) == "Bob/Two")
        #expect(try f.folder(ebook) == "Ebooks/Ann/One")
        #expect(f.names(in: "Audiobooks").isEmpty)
    }

    @Test func theMoverRefusesAFolderOnAnotherDiskBeforeAnythingMoves() throws {
        let g = try FolderMoverTests.Ground()
        try g.make("Ann/One")
        try g.make("Bob/Two")
        g.mover.volume = { $0.pathComponents.contains("Bob") ? 2 : 1 }
        let before = g.contents()
        let moves = g.moves([("Ann/One", "Z/One"), ("Bob/Two", "Z/Two")])
        #expect(g.mover.blockers(for: moves) == [1: .otherVolume])
        #expect(throws: FolderMoveError.self) { try g.mover.move(moves) }
        #expect(g.contents() == before)
    }

    // MARK: On the disk before the catalogue is written

    @Test func theRenamesAreForcedToDiskOnceAfterTheLastOfThemAndBeforeTheCatalogueIsWritten() throws {
        let f = try F()
        try f.shelve("One", "Ann")
        try f.shelve("Two", "Bob")
        try f.shelve("Three", "Cat")
        var events: [String] = []
        f.service.renameFolder = { from, to in
            events.append("rename")
            try FolderMover.renameWithoutReplacing(from, to)
        }
        f.service.forceFoldersToDisk = { events.append("force") }
        f.service.beforeCommit = { events.append("commit") }

        try f.service.applyLayoutChange(to: try FolderPattern(Self.byKind))
        #expect(events == ["rename", "rename", "rename", "force", "commit"])

        // Undoing the change, the same.
        events = []
        try f.service.undoLast()
        #expect(events == ["rename", "rename", "rename", "force", "commit"])

        // A change that moves no folder forces nothing.
        events = []
        try f.service.applyLayoutChange(to: try FolderPattern("{Author}/{Title}"))
        #expect(events == ["commit"])
    }

    @Test func forcingTheLibraryFolderToDiskLeavesItAsItIs() throws {
        let f = try F()
        try f.shelve("One", "Ann")
        let before = try LayoutState(f)
        LibraryService.forceToDisk(f.root)
        LibraryService.forceToDisk(f.base.appendingPathComponent("not there"))
        #expect(try LayoutState(f) == before)
    }

    // MARK: A record that says more than the disk shows

    @Test func aWrittenChangeWhoseFolderIsNotWhereTheCatalogueSaysKeepsItsRecordAndIsReported() throws {
        let f = try F()
        let one = try f.shelve("One", "Ann")
        try f.shelve("Two", "Bob")
        f.service.afterLayoutCommit = { throw FolderMover.Halted() }
        #expect(throws: FolderMover.Halted.self) { try f.service.applyLayoutChange(to: try FolderPattern(Self.byKind)) }
        #expect(try f.folder(one) == "Audiobooks/Ann/One")
        // The catalogue was written; one folder is then not where it says (as if its
        // rename had not reached the disk).
        try FileManager.default.createDirectory(at: f.lib("Ann"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: f.lib("Audiobooks/Ann/One"), to: f.lib("Ann/One"))
        let interrupted = try LayoutState(f)

        let service = try reopened(f)
        let report = try service.reconcile()
        let problem = try #require(report.layoutChangeProblem)
        #expect(problem.contains("Audiobooks/Ann/One"))
        #expect(report.strandedFolders.map(\.url.path) == [f.lib("Audiobooks/Ann/One").path])
        #expect(report.strandedFolders.map(\.belongsAt) == ["Audiobooks/Ann/One"])
        #expect(!report.recoveredLayoutChange)
        #expect(service.hasInterruptedLayoutChange)
        #expect(try LayoutState(f) == interrupted)
        #expect(throws: LibraryError.layoutChangeInterrupted) { try service.undoLast() }

        // With the folder where the catalogue says, only the tidying up was missed.
        try FileManager.default.moveItem(at: f.lib("Ann/One"), to: f.lib("Audiobooks/Ann/One"))
        try FileManager.default.removeItem(at: f.lib("Ann"))
        let again = try reopened(f)
        #expect(try again.reconcile() == ReconcileReport())
        #expect(!again.hasInterruptedLayoutChange)
        #expect(try again.undoLast() == "Change Folder Layout")
    }

    @Test func anotherFolderStandingWhereTheCatalogueSaysIsNotTakenForTheBooks() throws {
        let f = try F()
        try f.shelve("One", "Ann")
        f.service.afterLayoutCommit = { throw FolderMover.Halted() }
        #expect(throws: FolderMover.Halted.self) { try f.service.applyLayoutChange(to: try FolderPattern(Self.byKind)) }
        try FileManager.default.moveItem(at: f.lib("Audiobooks/Ann/One"), to: f.base.appendingPathComponent("Away"))
        try FileManager.default.createDirectory(at: f.lib("Audiobooks/Ann/One"), withIntermediateDirectories: true)
        let service = try reopened(f)
        #expect(try service.reconcile().layoutChangeProblem != nil)
        #expect(service.hasInterruptedLayoutChange)
    }

    // MARK: A new book and a folder that is taken

    @Test func aNewBookIsNotFiledIntoAnotherBooksFolder() throws {
        let f = try F()
        let first = try f.importNew([try f.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))
        let tree = f.libraryTree()
        let books = try f.store.books().count

        // A second book of the same name, with a file of another name: a book of its own.
        var separate = F.meta("dune", "FRANK HERBERT")
        separate.asin = "B000000001"
        let audio = try f.makeM4B("dune.m4b", tags: BookMetadata())
        let outcome = try #require(
            try f.service.importItems([ImportItem(candidate: f.candidate([audio], separate))]).outcomes.first)
        #expect(failure(outcome) == Self.takenByAnother)
        #expect(f.libraryTree() == tree)
        #expect(f.inboxTree() == ["dune.m4b"])
        #expect(try f.store.books().count == books)
        #expect(try f.store.files(bookId: first).map(\.path) == ["Frank Herbert/Dune/Dune.epub"])

        // Added to that book instead, the file is taken.
        let join = ImportItem(candidate: f.candidate([audio], separate), target: .existing(bookId: first))
        _ = try f.importedId(try #require(try f.service.importItems([join]).outcomes.first))
        #expect(try f.store.files(bookId: first).map(\.path).sorted() == [
            "Frank Herbert/Dune/Dune.epub", "Frank Herbert/Dune/Dune.m4b",
        ])
    }

    @Test func twoNewBooksOfOneImportAreNotFiledInOneFolder() throws {
        let f = try F()
        var other = F.meta("Dune", "Frank Herbert")
        other.asin = "B000000001"
        let items = [
            ImportItem(candidate: f.candidate([try f.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))),
            ImportItem(candidate: f.candidate([try f.makeM4B("dune.m4b", tags: BookMetadata())], other)),
        ]
        let outcomes = try f.service.importItems(items).outcomes
        _ = try f.importedId(outcomes[0])
        #expect(failure(outcomes[1]) == Self.takenByAnother)
        #expect(f.libraryTree().filter { $0.contains(".") } == ["Frank Herbert/Dune/Dune.epub"])
        #expect(f.inboxTree() == ["dune.m4b"])
        #expect(try f.store.books().count == 1)
    }

    // MARK: Names the library needs for itself

    @Test(arguments: ["VoxCarrel.sqlite", "voxcarrel.sqlite-JOURNAL", "VoxCarrel.sqlite-wal", "VoxCarrel.sqlite-shm"])
    func aBookWhoseFirstFolderWouldBeOneOfTheLibrarysOwnFilesCannotBeFiled(name: String) throws {
        let f = try F()
        f.service.volumeIsCaseSensitive = false
        let metadata = F.meta("Dune", name)
        #expect(f.service.plannedFolder(for: metadata, hasAudio: true) == nil)
        #expect(f.service.plannedFolder(for: F.meta(name, "Frank Herbert"), hasAudio: true) == "Frank Herbert/\(name)")

        // A new book is catalogued where it is, as any book that cannot be filed.
        let epub = try f.makeEPUB("dune.epub")
        let outcome = try #require(
            try f.service.importItems([ImportItem(candidate: f.candidate([epub], metadata))]).outcomes.first)
        guard case .needsAttention(let id) = outcome else {
            Issue.record("expected .needsAttention, got \(outcome)")
            return
        }
        #expect(f.libraryTree().isEmpty)
        #expect(f.inboxTree() == ["dune.epub"])
        #expect(try f.service.unfiledReason(for: id) == Self.ownFiles)

        // A book that is filed stays where it is when its details change to such a name.
        let filed = try f.importNew([try f.makeM4B("emma.m4b", tags: BookMetadata())], F.meta("Emma", "Jane Austen"))
        var edit = BookEdit(book: try #require(try f.store.book(id: filed)))
        edit.metadata.authors = [name]
        _ = try f.service.save([edit])
        #expect(try f.folder(filed) == "Jane Austen/Emma")
        #expect(try f.flagged(filed))
        #expect(try f.service.unfiledReason(for: filed) == Self.ownFiles)
        #expect(f.libraryTree().filter { $0.contains(".") } == ["Jane Austen/Emma/Emma.m4b"])
    }

    @Test func aChangeOfLayoutLeavesABookWhoseFirstFolderWouldBeOneOfTheLibrarysOwnFiles() throws {
        let f = try F()
        let odd = try f.shelve("VoxCarrel.sqlite-journal", "Ann")
        let other = try f.shelve("Dune", "Frank Herbert")
        let done = try f.service.applyLayoutChange(to: try FolderPattern("{Title}"))
        #expect(stay(done, odd) == Self.ownFiles)
        #expect(try f.folder(odd) == "Ann/VoxCarrel.sqlite-journal")
        #expect(try f.flagged(odd))
        #expect(try f.folder(other) == "Dune")
        // The catalogue can still be written.
        try f.service.undoLast()
        #expect(try f.folder(other) == "Frank Herbert/Dune")
    }

    @Test func whereCapitalisationTellsNamesApartOnlyTheExactNameIsTheLibrarys() throws {
        let f = try F()
        f.service.volumeIsCaseSensitive = true
        #expect(f.service.plannedFolder(for: F.meta("Dune", "voxcarrel.SQLITE"), hasAudio: true) == "voxcarrel.SQLITE/Dune")
        #expect(f.service.plannedFolder(for: F.meta("Dune", "VoxCarrel.sqlite"), hasAudio: true) == nil)
    }

    // MARK: A stored pattern that cannot be read

    @Test func aStoredPatternThatCannotBeReadIsSaidAndCanBeReplacedByTheStandardOne() throws {
        let f = try F()
        try f.shelve("Dune", "Frank Herbert")
        #expect(try !f.service.storedFolderPatternIsUnreadable())
        try f.store.setFolderPatternText("{Auther}/{Title")
        #expect(try f.service.storedFolderPatternIsUnreadable())
        #expect(try f.service.folderPattern() == .standard)

        // The standard pattern is what is in use, and no book moves: it is stored all the same.
        let done = try f.service.applyLayoutChange(to: .standard)
        #expect(done.moves.isEmpty)
        #expect(try f.store.folderPatternText() == FolderPattern.standard.text)
        #expect(try !f.service.storedFolderPatternIsUnreadable())

        // One operation, which Undo reverses exactly.
        #expect(try f.service.undoLast() == "Change Folder Layout")
        #expect(try f.store.folderPatternText() == "{Auther}/{Title")
    }
}
