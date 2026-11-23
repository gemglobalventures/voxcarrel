import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// FP43: a change of folder layout that is cut short is put right when the library is
/// next opened.
@Suite struct LibraryServiceLayoutRecoveryTests {
    typealias F = LibraryFixture

    static let byNarrator = "{Narrator}/{Title}"

    /// Twelve books under the standard pattern, eleven of which the narrator pattern moves.
    private func twelveBooks() throws -> F {
        let f = try F()
        for number in 1...11 {
            try f.shelve(
                "Book \(number)", "Author \(number % 4)", series: number % 2 == 0 ? "Series" : nil,
                number: number % 2 == 0 ? "\(number)" : nil, narrator: "Narrator \(number % 3)",
                files: ["Book \(number).m4b", "Extras/notes \(number).pdf"])
        }
        try f.shelve("Unread Aloud", "Author 0")
        try Data("the owner's".utf8).write(to: f.lib("Author 1/keep.txt"))
        return f
    }

    /// A swap and a book going deeper along its own path: six renames, three folders set aside.
    private func dependentBooks() throws -> F {
        let f = try F()
        try f.shelve("One", "Ann", at: "Ann/Two", files: ["One.m4b", "Extras/a.pdf"])
        try f.shelve("Two", "Ann", at: "Ann/One")
        try f.shelve("Dune", "Frank Herbert", series: "Dune", number: "1", at: "Frank Herbert/Dune")
        return f
    }

    /// Lets `count` renames through and then stops dead, as a crash would: nothing is put back.
    private func crash(_ service: LibraryService, afterRenames count: Int) {
        var done = 0
        service.renameFolder = { from, to in
            if done == count { throw FolderMover.Halted() }
            done += 1
            try FolderMover.renameWithoutReplacing(from, to)
        }
    }

    /// The library opened afresh, as at the next launch.
    private func reopened(_ f: F) throws -> LibraryService {
        LibraryService(store: try LibraryStore(libraryRoot: f.root))
    }

    private func expectSame(_ f: F, _ before: LayoutState, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let after = try LayoutState(f)
        #expect(after.tree == before.tree, sourceLocation: sourceLocation)
        #expect(after.bytes == before.bytes, sourceLocation: sourceLocation)
        #expect(after.books == before.books, sourceLocation: sourceLocation)
        #expect(after.files == before.files, sourceLocation: sourceLocation)
        #expect(after.pattern == before.pattern, sourceLocation: sourceLocation)
        #expect(after.batch == before.batch, sourceLocation: sourceLocation)
    }

    /// Opens the library again and runs the launch check: the folders are put back, the
    /// library is exactly as `before`, and a second check has nothing to say.
    private func expectPutRightAtLaunch(
        _ f: F, _ before: LayoutState, moved: Bool = true, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let service = try reopened(f)
        #expect(service.hasInterruptedLayoutChange, sourceLocation: sourceLocation)
        let report = try service.reconcile()
        #expect(report.recoveredLayoutChange == moved, sourceLocation: sourceLocation)
        #expect(report.layoutChangeProblem == nil, sourceLocation: sourceLocation)
        var expected = ReconcileReport()
        expected.recoveredLayoutChange = moved
        #expect(report == expected, sourceLocation: sourceLocation)
        #expect(!service.hasInterruptedLayoutChange, sourceLocation: sourceLocation)
        try expectSame(f, before, sourceLocation: sourceLocation)
        #expect(try service.reconcile() == ReconcileReport(), sourceLocation: sourceLocation)
        #expect(try reopened(f).reconcile() == ReconcileReport(), sourceLocation: sourceLocation)
    }

    // MARK: The record

    @Test func fp43_theRecordIsOnDiskBeforeTheFirstRenameAndGoneAfterTheCommit() throws {
        let f = try dependentBooks()
        try f.shelve("Artemis", "Andy Weir", at: "Shelf/Artemis")
        try f.store.setFolderPatternText("{Author}/{Title}")
        var seen: LayoutIntent?
        var treeThen: [String] = []
        let before = try LayoutState(f)
        f.service.renameFolder = { from, to in
            if seen == nil {
                seen = try JSONDecoder().decode(LayoutIntent.self, from: Data(contentsOf: f.service.layoutIntentURL))
                treeThen = f.shown()
            }
            try FolderMover.renameWithoutReplacing(from, to)
        }
        let done = try f.service.applyLayoutChange(to: .standard)

        // Written before anything had moved, and listing everything that was to be done.
        let record = try #require(seen)
        #expect(treeThen == before.tree.filter { !$0.hasPrefix(".voxcarrel") })
        #expect(record.patternTextBefore == "{Author}/{Title}")
        #expect(record.patternTextAfter == FolderPattern.standard.text)
        #expect(record.committedWhenJournalHolds)
        #expect(record.token == (try f.snapshot().token))
        #expect(record.moves.map(\.from) == done.moves.map(\.from))
        #expect(record.moves.map(\.to) == done.moves.map(\.to))
        // The three folders in each other's way are set aside in the hidden folder; the fourth is not.
        let parked = record.moves.compactMap(\.parkedAt)
        #expect(parked.count == 3)
        #expect(parked.allSatisfy { $0.hasPrefix(".voxcarrel/moving/") })
        #expect(record.moves.first { $0.from == "Shelf/Artemis" }?.parkedAt == nil)
        #expect(Set(record.moves.map(\.identity)).count == 4)
        #expect(Set(record.madeFolders) == ["Andy Weir", "Frank Herbert/Dune"])

        // Gone once the catalogue is written, with nothing else left behind.
        #expect(!f.service.hasInterruptedLayoutChange)
        #expect(f.hiddenTree().isEmpty)
    }

    @Test func fp43_noRecordIsLeftByAChangeThatFailsAndIsPutBack() throws {
        let f = try twelveBooks()
        let before = try LayoutState(f)
        f.countRenames(failing: 5)
        #expect(throws: LibraryError.self) { try f.service.applyLayoutChange(to: try FolderPattern(Self.byNarrator)) }
        #expect(!f.service.hasInterruptedLayoutChange)
        try expectSame(f, before)
        // Nor by one whose catalogue write fails.
        f.countRenames()
        f.service.beforeCommit = { throw Boom() }
        #expect(throws: Boom.self) { try f.service.applyLayoutChange(to: try FolderPattern(Self.byNarrator)) }
        #expect(!f.service.hasInterruptedLayoutChange)
        try expectSame(f, before)
    }

    // MARK: A crash before the catalogue is written

    @Test(arguments: [0, 1, 6, 10, 11])
    func fp43_aCrashAfterAnyRenameIsPutRightAtTheNextLaunch(renames: Int) throws {
        let f = try twelveBooks()
        let before = try LayoutState(f)
        crash(f.service, afterRenames: renames)
        // Eleven renames in all: after the last, the crash comes before the catalogue is written.
        f.service.beforeCommit = { throw FolderMover.Halted() }
        #expect(throws: FolderMover.Halted.self) { try f.service.applyLayoutChange(to: try FolderPattern(Self.byNarrator)) }
        #expect(f.service.hasInterruptedLayoutChange)
        if renames > 0 { #expect(try LayoutState(f).tree != before.tree) }

        try expectPutRightAtLaunch(f, before, moved: renames > 0)

        // And the change can then be made.
        let service = try reopened(f)
        #expect(try service.applyLayoutChange(to: try FolderPattern(Self.byNarrator)).moves.count == 11)
        #expect(try service.reconcile() == ReconcileReport())
    }

    @Test(arguments: 0...6)
    func fp43_aCrashWithFoldersSetAsideIsPutRightAtTheNextLaunch(renames: Int) throws {
        let f = try dependentBooks()
        let before = try LayoutState(f)
        crash(f.service, afterRenames: renames)
        f.service.beforeCommit = { throw FolderMover.Halted() }
        #expect(throws: FolderMover.Halted.self) { try f.service.applyLayoutChange(to: .standard) }
        // After one to three renames folders are in the hidden folder, where the launch
        // check does not otherwise look.
        if (1...3).contains(renames) { #expect(f.hiddenTree().contains { $0.hasSuffix(".m4b") }) }

        try expectPutRightAtLaunch(f, before, moved: renames > 0)
    }

    @Test func fp43_aCrashWhileRefilingUnderTheSamePatternIsPutRight() throws {
        // The pattern does not change, so it cannot be what says whether the catalogue was written.
        let f = try F()
        try f.shelve("Artemis", "Andy Weir", at: "Elsewhere/Artemis")
        try f.shelve("Emma", "Jane Austen", at: "Elsewhere/Emma")
        try f.store.setFolderPatternText(FolderPattern.standard.text)
        let before = try LayoutState(f)
        f.service.beforeCommit = { throw FolderMover.Halted() }
        #expect(throws: FolderMover.Halted.self) { try f.service.applyLayoutChange(to: .standard) }
        #expect(FileManager.default.fileExists(atPath: f.lib("Andy Weir/Artemis/Artemis.m4b").path))
        try expectPutRightAtLaunch(f, before)
    }

    // MARK: A crash after the catalogue is written

    @Test func fp43_aCrashAfterTheCommitOnlyNeedsTidyingUp() throws {
        for sameText in [false, true] {
            let f = try dependentBooks()
            try f.shelve("Artemis", "Andy Weir", at: "Shelf/Artemis")
            if sameText { try f.store.setFolderPatternText(FolderPattern.standard.text) }
            let before = try LayoutState(f)
            f.service.afterLayoutCommit = { throw FolderMover.Halted() }
            #expect(throws: FolderMover.Halted.self) { try f.service.applyLayoutChange(to: .standard) }
            #expect(f.service.hasInterruptedLayoutChange)
            let changed = try LayoutState(f)

            // Nothing is moved and nothing is reported: the record just goes.
            let service = try reopened(f)
            #expect(try service.reconcile() == ReconcileReport())
            #expect(!service.hasInterruptedLayoutChange)
            #expect(f.hiddenTree().isEmpty)
            let after = try LayoutState(f)
            #expect(after.tree == changed.tree.filter { !$0.hasPrefix(".voxcarrel") })
            #expect(after.books == changed.books)
            #expect(after.files == changed.files)
            #expect(after.pattern == FolderPattern.standard.text)
            #expect(try f.folder(1) == "Ann/One")
            #expect(try read(f.lib("Ann/One/One.m4b")) == "One by Ann: One.m4b")

            // The change is there to undo, as if nothing had happened.
            #expect(try service.undoLast() == "Change Folder Layout")
            let undone = try LayoutState(f)
            #expect(undone.tree == before.tree)
            #expect(undone.bytes == before.bytes)
            #expect(undone.books == before.books)
            #expect(undone.files == before.files)
            #expect(undone.pattern == before.pattern)
        }
    }

    // MARK: What cannot be put right is kept and said

    @Test func fp43_aFolderMovedByHandInBetweenKeepsTheRecordAndIsReported() throws {
        let f = try twelveBooks()
        let before = try LayoutState(f)
        let planned = try f.service.planLayoutChange(to: try FolderPattern(Self.byNarrator))
        crash(f.service, afterRenames: 6)
        #expect(throws: FolderMover.Halted.self) { try f.service.applyLayoutChange(to: try FolderPattern(Self.byNarrator)) }
        // One of the folders already moved is taken out of the library by hand.
        let gone = planned.moves[2]
        let away = f.base.appendingPathComponent("Away", isDirectory: true)
        try FileManager.default.moveItem(at: f.lib(gone.to), to: away)
        let interrupted = try LayoutState(f)

        let service = try reopened(f)
        let report = try service.reconcile()
        #expect(!report.recoveredLayoutChange)
        #expect(try #require(report.layoutChangeProblem).contains(gone.from))
        #expect(report.strandedFolders.map(\.belongsAt) == [gone.from])
        #expect(report.strandedFolders.first?.url.path == f.lib(gone.to).path)
        #expect(report.strandedFolders.first?.wasMovingTo == gone.to)
        // Nothing was moved or deleted, and the record is kept.
        #expect(service.hasInterruptedLayoutChange)
        try expectSame(f, interrupted)
        #expect(try read(away.appendingPathComponent("\(gone.title).m4b")).hasPrefix(gone.title))

        // Said again, and tried again, at each launch.
        #expect(try reopened(f).reconcile().layoutChangeProblem != nil)
        try expectSame(f, interrupted)

        // With the folder back in either of the places it could be, the library is put right.
        try FileManager.default.moveItem(at: away, to: f.lib(gone.to))
        try expectPutRightAtLaunch(f, before)
    }

    @Test func fp43_aFolderThatCannotGoBackKeepsTheRecordAndIsReported() throws {
        let f = try twelveBooks()
        let before = try LayoutState(f)
        let planned = try f.service.planLayoutChange(to: try FolderPattern(Self.byNarrator))
        crash(f.service, afterRenames: 6)
        #expect(throws: FolderMover.Halted.self) { try f.service.applyLayoutChange(to: try FolderPattern(Self.byNarrator)) }
        // Something else now stands where one of the moved folders was.
        let barred = planned.moves[1]
        try FileManager.default.createDirectory(at: f.lib(barred.from), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: f.lib(barred.from).appendingPathComponent("new.txt"))
        let interrupted = try LayoutState(f)

        let service = try reopened(f)
        let report = try service.reconcile()
        #expect(!report.recoveredLayoutChange)
        #expect(try #require(report.layoutChangeProblem).contains(barred.from))
        #expect(report.strandedFolders.map(\.belongsAt) == [barred.from])
        #expect(report.strandedFolders.first?.url.path == f.lib(barred.to).path)
        #expect(service.hasInterruptedLayoutChange)
        try expectSame(f, interrupted)

        try FileManager.default.removeItem(at: f.lib(barred.from))
        try expectPutRightAtLaunch(f, before)
    }

    @Test func fp43_foldersAreNotMovedWhenTheCatalogueNoLongerAgreesWithTheRecord() throws {
        let f = try twelveBooks()
        let before = try LayoutState(f)
        let planned = try f.service.planLayoutChange(to: try FolderPattern(Self.byNarrator))
        crash(f.service, afterRenames: 6)
        #expect(throws: FolderMover.Halted.self) { try f.service.applyLayoutChange(to: try FolderPattern(Self.byNarrator)) }
        // Something that knows nothing of the record has since filed a book elsewhere.
        let changed = planned.moves[4]
        var book = try #require(try f.store.book(id: changed.bookId))
        book.folderPath = "Somewhere Else/\(changed.title)"
        try f.store.update(book)
        let interrupted = try LayoutState(f)

        let service = try reopened(f)
        let report = try service.reconcile()
        #expect(!report.recoveredLayoutChange)
        #expect(report.layoutChangeProblem != nil)
        #expect(report.strandedFolders.map(\.belongsAt) == [changed.from])
        #expect(service.hasInterruptedLayoutChange)
        try expectSame(f, interrupted)

        // With the catalogue as it was, the library is put right.
        book.folderPath = changed.from
        try f.store.update(book)
        try expectPutRightAtLaunch(f, before)
    }

    @Test func fp43_everyOperationIsRefusedUntilTheLibraryIsPutRight() throws {
        let f = try twelveBooks()
        let epub = try f.makeEPUB("in.epub")
        let planned = try f.service.planLayoutChange(to: try FolderPattern(Self.byNarrator))
        crash(f.service, afterRenames: 6)
        #expect(throws: FolderMover.Halted.self) { try f.service.applyLayoutChange(to: try FolderPattern(Self.byNarrator)) }
        try FileManager.default.moveItem(at: f.lib(planned.moves[2].to), to: f.base.appendingPathComponent("Away"))
        let service = try reopened(f)
        #expect(try service.reconcile().layoutChangeProblem != nil)
        let interrupted = try LayoutState(f)

        let book = try #require(try f.store.book(id: 1))
        let file = try #require(try f.store.files(bookId: 1).first?.id)
        let refused = LibraryError.layoutChangeInterrupted
        #expect(throws: refused) { try service.applyLayoutChange(to: try FolderPattern("{Author}/{Title}")) }
        #expect(throws: refused) { try service.applyLayoutChange(to: .standard) }
        #expect(throws: refused) { try service.save([BookEdit(book: book)]) }
        #expect(throws: refused) {
            try service.importItems([ImportItem(candidate: f.candidate([epub], F.meta("New", "Ann")))])
        }
        #expect(throws: refused) { try service.setRole(.extra, forFile: file) }
        #expect(throws: refused) { try service.rewriteTags(for: [1]) }
        #expect(throws: refused) { try service.repairLengthHeaders(for: [1]) }
        #expect(throws: refused) { try service.removeBook(id: 1, moveFilesToTrash: false) }
        #expect(throws: refused) { try service.locateFile(fileId: file, at: epub) }
        #expect(throws: refused) { try service.undoLast() }
        try expectSame(f, interrupted)
        #expect(f.inboxTree() == ["in.epub"])
        // Looking is not refused.
        _ = try service.planLayoutChange(to: .standard)
        _ = try service.unfiledReason(for: 1)
    }

    @Test func fp43_aRecordThatCannotBeReadIsKeptAndReported() throws {
        let f = try twelveBooks()
        try FileManager.default.createDirectory(at: f.service.layout.hiddenFolder, withIntermediateDirectories: true)
        try Data("not a record".utf8).write(to: f.service.layoutIntentURL)
        let interrupted = try LayoutState(f)
        let service = try reopened(f)
        let report = try service.reconcile()
        #expect(!report.recoveredLayoutChange)
        #expect(report.layoutChangeProblem != nil)
        #expect(service.hasInterruptedLayoutChange)
        #expect(throws: LibraryError.layoutChangeInterrupted) { try service.applyLayoutChange(to: .standard) }
        try expectSame(f, interrupted)
    }

    @Test func fp43_aChangeWhoseFoldersCouldNotBePutBackIsPutRightAtTheNextLaunch() throws {
        let f = try twelveBooks()
        let before = try LayoutState(f)
        let planned = try f.service.planLayoutChange(to: try FolderPattern(Self.byNarrator))
        let first = f.lib(planned.moves[0].from).path
        var count = 0
        f.service.renameFolder = { from, to in
            count += 1
            // The third move fails, and then the first folder cannot go back.
            if count == 3 || to.path == first { throw Boom() }
            try FolderMover.renameWithoutReplacing(from, to)
        }
        #expect(throws: LibraryError.self) { try f.service.applyLayoutChange(to: try FolderPattern(Self.byNarrator)) }
        // The record stays, because a folder is still out of place.
        #expect(f.service.hasInterruptedLayoutChange)
        try expectPutRightAtLaunch(f, before)
    }

    // MARK: Putting right can itself be interrupted

    @Test(arguments: [0, 1, 4, 7])
    func fp43_puttingRightIsItselfPutRightWhenInterrupted(renames: Int) throws {
        let f = try twelveBooks()
        let before = try LayoutState(f)
        crash(f.service, afterRenames: 8)
        #expect(throws: FolderMover.Halted.self) { try f.service.applyLayoutChange(to: try FolderPattern(Self.byNarrator)) }

        // The next launch gets part of the way through putting the eight folders back.
        let second = try reopened(f)
        crash(second, afterRenames: renames)
        #expect(throws: FolderMover.Halted.self) { try second.reconcile() }
        #expect(second.hasInterruptedLayoutChange)

        // The one after that finishes the job.
        try expectPutRightAtLaunch(f, before)
    }

    @Test(arguments: 0...5, [2, 4, 6])
    func fp43_puttingRightFoldersInEachOthersWayIsItselfPutRightWhenInterrupted(renames: Int, crashedAfter: Int) throws {
        let f = try dependentBooks()
        let before = try LayoutState(f)
        crash(f.service, afterRenames: crashedAfter)
        f.service.beforeCommit = { throw FolderMover.Halted() }
        #expect(throws: FolderMover.Halted.self) { try f.service.applyLayoutChange(to: .standard) }

        let second = try reopened(f)
        crash(second, afterRenames: renames)
        do {
            _ = try second.reconcile()
        } catch is FolderMover.Halted {
            // Interrupted again, and once more after that.
            let third = try reopened(f)
            crash(third, afterRenames: 1)
            _ = try? third.reconcile()
        }
        let last = try reopened(f)
        _ = try last.reconcile()
        #expect(!last.hasInterruptedLayoutChange)
        try expectSame(f, before)
        #expect(try last.reconcile() == ReconcileReport())
    }

    // MARK: Undoing a change is protected the same way

    @Test(arguments: [0, 1, 5, 11])
    func fp43_aCrashWhileUndoingAChangeLeavesTheChangeAsItWas(renames: Int) throws {
        let f = try twelveBooks()
        let before = try LayoutState(f)
        try f.service.applyLayoutChange(to: try FolderPattern(Self.byNarrator))
        let changed = try LayoutState(f)
        crash(f.service, afterRenames: renames)
        f.service.beforeCommit = { throw FolderMover.Halted() }
        #expect(throws: FolderMover.Halted.self) { try f.service.undoLast() }
        #expect(f.service.hasInterruptedLayoutChange)

        // The catalogue still describes the change, so the folders go there again.
        try expectPutRightAtLaunch(f, changed, moved: renames > 0)

        // And the change can still be undone.
        let service = try reopened(f)
        #expect(try service.undoLast() == "Change Folder Layout")
        let undone = try LayoutState(f)
        #expect(undone.tree == before.tree)
        #expect(undone.bytes == before.bytes)
        #expect(undone.books == before.books)
        #expect(undone.files == before.files)
        #expect(undone.pattern == before.pattern)
    }

    @Test func fp43_aCrashAfterAnUndoIsWrittenOnlyNeedsTidyingUp() throws {
        let f = try dependentBooks()
        let before = try LayoutState(f)
        try f.service.applyLayoutChange(to: .standard)
        f.service.afterLayoutCommit = { throw FolderMover.Halted() }
        #expect(throws: FolderMover.Halted.self) { try f.service.undoLast() }
        #expect(f.service.hasInterruptedLayoutChange)

        let service = try reopened(f)
        #expect(try service.reconcile() == ReconcileReport())
        #expect(!service.hasInterruptedLayoutChange)
        let after = try LayoutState(f)
        #expect(after.tree == before.tree)
        #expect(after.bytes == before.bytes)
        #expect(after.books == before.books)
        #expect(after.files == before.files)
        #expect(after.pattern == before.pattern)
        #expect(try service.undoLabel() == nil)
    }

    // MARK: FL13 Giving up on putting the folders back

    /// An interruption that cannot be put right: six folders moved, one of them then
    /// taken out of the library by hand. Returns the library opened afresh, checked once.
    private func unrecoverable(_ f: F) throws -> LibraryService {
        let planned = try f.service.planLayoutChange(to: try FolderPattern(Self.byNarrator))
        crash(f.service, afterRenames: 6)
        #expect(throws: FolderMover.Halted.self) { try f.service.applyLayoutChange(to: try FolderPattern(Self.byNarrator)) }
        try FileManager.default.moveItem(at: f.lib(planned.moves[2].to), to: f.base.appendingPathComponent("Away"))
        let service = try reopened(f)
        #expect(try service.reconcile().layoutChangeProblem != nil)
        #expect(service.hasInterruptedLayoutChange)
        return service
    }

    @Test func fl13_discardingUnlocksTheLibraryAndDeletesNothing() throws {
        let f = try twelveBooks()
        let service = try unrecoverable(f)
        let interrupted = try LayoutState(f)
        let record = ".voxcarrel/" + LayoutIntent.fileName
        #expect(interrupted.tree.contains(record))

        try service.discardInterruptedLayoutChange()

        // Only the record is gone (and the hidden folder, which held nothing else).
        #expect(!service.hasInterruptedLayoutChange)
        let after = try LayoutState(f)
        #expect(after.tree == interrupted.tree.filter { $0 != record && $0 != ".voxcarrel" })
        #expect(after.bytes == interrupted.bytes.filter { $0.key != record })
        // The catalogue is as it was: it still files every book where it was before the change.
        #expect(after.books == interrupted.books)
        #expect(after.files == interrupted.files)
        #expect(after.pattern == interrupted.pattern)
        #expect(after.batch == interrupted.batch)

        // The next launch check does not throw: the books whose folders moved are
        // missing their files, and the files where the folders went belong to no book.
        let moved = Set(try f.store.bookFolders().filter { !FileManager.default.fileExists(atPath: f.lib($0.value).path) }.keys)
        #expect(moved.count == 6)
        let again = try reopened(f)
        let report = try again.reconcile()
        #expect(report.layoutChangeProblem == nil)
        #expect(!report.recoveredLayoutChange)
        #expect(Set(report.booksWithMissingFiles) == moved)
        // Five of the six folders are still in the library; each holds a book file and an extra.
        #expect(report.untrackedFiles.count == 10)
        #expect(try LayoutState(f).tree == after.tree)

        // And the library can be changed again.
        let movedId = try #require(moved.first)
        let book = try #require(try f.store.book(id: movedId))
        _ = try again.save([BookEdit(book: book)])
        _ = try again.planLayoutChange(to: .standard)
    }

    @Test func fl13_discardingRemovesOnlyEmptyParkingFolders() throws {
        // Crashed before the first rename: places to set folders aside were made, and hold none.
        let empty = try dependentBooks()
        crash(empty.service, afterRenames: 0)
        #expect(throws: FolderMover.Halted.self) { try empty.service.applyLayoutChange(to: .standard) }
        let untouched = empty.libraryTree()
        try reopened(empty).discardInterruptedLayoutChange()
        #expect(empty.hiddenTree().isEmpty)
        #expect(empty.libraryTree() == untouched)

        // Crashed with folders set aside: they stay exactly where they are, and are said.
        let f = try dependentBooks()
        crash(f.service, afterRenames: 2)
        #expect(throws: FolderMover.Halted.self) { try f.service.applyLayoutChange(to: .standard) }
        let interrupted = try LayoutState(f)
        let parked = f.hiddenTree().filter { $0.hasSuffix(".m4b") }
        #expect(!parked.isEmpty)
        let service = try reopened(f)
        try service.discardInterruptedLayoutChange()
        #expect(!service.hasInterruptedLayoutChange)
        let after = try LayoutState(f)
        let record = ".voxcarrel/" + LayoutIntent.fileName
        #expect(after.tree == interrupted.tree.filter { $0 != record })
        #expect(after.bytes == interrupted.bytes.filter { $0.key != record })
        #expect(after.books == interrupted.books)
        #expect(after.files == interrupted.files)
        let report = try service.reconcile()
        #expect(report.layoutChangeProblem == nil)
        #expect(!report.strandedFolders.isEmpty)
        #expect(!report.booksWithMissingFiles.isEmpty)
        #expect(f.hiddenTree().filter { $0.hasSuffix(".m4b") } == parked)
    }

    @Test func fl13_discardingWhenNothingWasInterruptedDoesNothing() throws {
        let f = try twelveBooks()
        let before = try LayoutState(f)
        try f.service.discardInterruptedLayoutChange()
        try expectSame(f, before)
    }

    // MARK: Asking directly

    @Test func fp43_puttingRightCanBeAskedForWithoutTheLaunchCheck() throws {
        let f = try twelveBooks()
        let before = try LayoutState(f)
        #expect(try f.service.recoverInterruptedLayoutChange() == LayoutRecovery())
        crash(f.service, afterRenames: 4)
        #expect(throws: FolderMover.Halted.self) { try f.service.applyLayoutChange(to: try FolderPattern(Self.byNarrator)) }
        let service = try reopened(f)
        #expect(try service.recoverInterruptedLayoutChange() == LayoutRecovery(foldersPutBack: true))
        #expect(try service.recoverInterruptedLayoutChange() == LayoutRecovery())
        try expectSame(f, before)
    }
}
