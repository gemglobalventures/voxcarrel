import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// Sequences that once lost a file, stranded one, or left files, tags and database disagreeing.
@Suite struct LibraryServiceConsistencyTests {
    typealias F = LibraryFixture

    func importM4B(_ f: F, _ metadata: BookMetadata, name: String = "in.m4b", mode: TransferMode = .move) throws -> Int64 {
        try f.importNew([try f.makeM4B(name, tags: F.meta("Old", "Old Author"))], metadata, mode: mode)
    }

    func edit(_ f: F, _ id: Int64, _ change: (inout BookEdit) -> Void) throws -> [SaveOutcome] {
        var e = BookEdit(book: try #require(try f.store.book(id: id)))
        change(&e)
        return try f.service.save([e])
    }

    func lock(_ url: URL) { #expect(chflags(url.path, UInt32(UF_IMMUTABLE)) == 0) }
    func unlock(_ url: URL) { _ = chflags(url.path, 0) }

    // MARK: Undo of a copy

    @Test func undoOfACopyImportNeverDestroysTheOnlyCopy() throws {
        let f = try F()
        let source = try f.makeM4B("keep.m4b", tags: F.meta("Original", "Writer"))
        _ = try f.importNew([source], F.meta("Dune", "Frank Herbert"), mode: .copy)
        // The user tidies the original away, then changes their mind about the import.
        try FileManager.default.removeItem(at: source)

        try f.service.undoLast()

        // The library copy took the original's place, with the original's tags.
        #expect(f.inboxTree() == ["keep.m4b"])
        #expect(try f.tags(source) == F.meta("Original", "Writer"))
        #expect(f.libraryTree().isEmpty)
        #expect(try f.store.books().isEmpty)
        #expect(try f.service.undoLabel() == nil)
    }

    @Test func undoOfACopyAddedToABookNeverDestroysTheOnlyCopy() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Dune", "Frank Herbert"))
        let epub = try f.makeEPUB("extra/dune.epub")
        let result = try f.service.importItems(
            [ImportItem(candidate: f.candidate([epub], F.meta("x", "y")), target: .existing(bookId: id))],
            options: ImportOptions(mode: .copy))
        _ = try f.importedId(result.outcomes[0])
        try FileManager.default.removeItem(at: f.inbox.appendingPathComponent("extra"))

        try f.service.undoLast()

        #expect(f.inboxTree() == ["extra", "extra/dune.epub"])
        #expect(try f.tags(epub).title == "Original Title")
        #expect(f.libraryTree() == ["Frank Herbert", "Frank Herbert/Dune", "Frank Herbert/Dune/Dune.m4b"])
        #expect(try f.store.files(bookId: id).map(\.path) == ["Frank Herbert/Dune/Dune.m4b"])
    }

    // MARK: Files that already belong to a book

    @Test func aFileOfAnotherBookCannotBeImported() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Dune", "Frank Herbert"))
        let other = try importM4B(f, F.meta("Other", "Ann Author"), name: "o.m4b")
        let tracked = f.lib("Frank Herbert/Dune/Dune.m4b")
        let bytes = try f.bytes(tracked)
        let journal = try f.store.lastBatch()
        let tree = f.libraryTree()
        // The same file, spelled as the user might drop it.
        let dropped = URL(fileURLWithPath: tracked.path.uppercased())
        let caseInsensitive = exists(dropped)

        var items = [
            ImportItem(candidate: f.candidate([tracked], F.meta("Dune", "Frank Herbert"))),
            ImportItem(candidate: f.candidate([tracked], F.meta("Stolen", "Someone Else"))),
            ImportItem(candidate: f.candidate([tracked], F.meta("x", "y")), target: .existing(bookId: other)),
        ]
        if caseInsensitive {
            items.append(ImportItem(candidate: CandidateBook(
                files: [CandidateFile(url: dropped, role: .audio)], metadata: F.meta("Stolen", "Someone Else"))))
        }
        for mode in [TransferMode.move, .copy] {
            let result = try f.service.importItems(items, options: ImportOptions(mode: mode))
            for outcome in result.outcomes {
                #expect(isFailed(outcome)?.contains("already belongs to") == true, "\(outcome)")
            }
        }

        #expect(f.libraryTree() == tree)
        #expect(try f.bytes(tracked) == bytes)
        #expect(try f.store.books().count == 2)
        #expect(try f.store.files(bookId: id).map(\.path) == ["Frank Herbert/Dune/Dune.m4b"])
        #expect(try f.store.lastBatch() == journal)
    }

    @Test func aFileCataloguedInPlaceCannotBeImportedAgain() throws {
        let f = try F()
        let source = try f.makeM4B("mystery.m4b", tags: F.meta("Old", "Old Author"))
        let first = try f.service.importItems([ImportItem(candidate: f.candidate([source], BookMetadata(title: "Mystery")))])
        guard case .needsAttention = first.outcomes[0] else {
            Issue.record("expected .needsAttention, got \(first.outcomes)")
            return
        }
        let again = try f.service.importItems([ImportItem(candidate: f.candidate([source], F.meta("Mystery", "Ann Author")))])
        #expect(isFailed(again.outcomes[0])?.contains("already belongs to") == true)
        #expect(f.inboxTree() == ["mystery.m4b"])
        #expect(try f.store.books().count == 1)
    }

    @Test(arguments: [TransferMode.move, .copy])
    func theSameFileInTwoItemsFailsTheSecond(mode: TransferMode) throws {
        let f = try F()
        let source = try f.makeM4B("a.m4b", tags: F.meta("x", "y"))
        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([source], F.meta("First", "Ann Author"))),
            ImportItem(candidate: f.candidate([source], F.meta("Second", "Ben Author"))),
        ], options: ImportOptions(mode: mode))

        _ = try f.importedId(result.outcomes[0])
        #expect(isFailed(result.outcomes[1])?.contains("earlier") == true, "\(result.outcomes[1])")
        #expect(f.libraryTree() == ["Ann Author", "Ann Author/First", "Ann Author/First/First.m4b"])
        #expect(try f.store.books().count == 1)
    }

    @Test func rolesMustSuitTheFormatAtImport() throws {
        let f = try F()
        let m4b = try f.makeM4B("a.m4b", tags: F.meta("x", "y"))
        let mp3 = try f.makeMP3("a.mp3", tags: F.meta("x", "y"))
        let epub = try f.makeEPUB("a.epub")
        let pdf = try f.makePDF("a.pdf")
        let id = try importM4B(f, F.meta("Dune", "Frank Herbert"))
        let journal = try f.store.lastBatch()

        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([m4b], F.meta("A", "Ann"), roles: [m4b: .extra])),
            ImportItem(candidate: f.candidate([mp3], F.meta("B", "Ann"), roles: [mp3: .ebook])),
            ImportItem(candidate: f.candidate([epub], F.meta("C", "Ann"), roles: [epub: .audio])),
            ImportItem(candidate: f.candidate([pdf], F.meta("D", "Ann"), roles: [pdf: .audio]), target: .existing(bookId: id)),
        ])

        for outcome in result.outcomes {
            #expect(isFailed(outcome)?.contains("cannot be") == true, "\(outcome)")
        }
        #expect(f.inboxTree() == ["a.epub", "a.m4b", "a.mp3", "a.pdf"])
        #expect(try f.store.books().count == 1)
        #expect(try f.store.lastBatch() == journal)
        // Ebook formats may be an ebook or an extra.
        let fine = try f.service.importItems([
            ImportItem(candidate: f.candidate([epub, pdf], F.meta("E", "Ann"), roles: [epub: .extra, pdf: .ebook]))
        ])
        _ = try f.importedId(fine.outcomes[0])
    }

    // MARK: Capitalisation wherever destinations are planned

    @Test func filesCanBeAddedAfterACapitalisationOnlyRetitle() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("dune", "Frank Herbert"))
        _ = try edit(f, id) { $0.metadata.title = "Dune" }
        #expect(f.libraryTree() == ["Frank Herbert", "Frank Herbert/dune", "Frank Herbert/dune/dune.m4b"])
        let audioBytes = try f.bytes(f.lib("Frank Herbert/dune/dune.m4b"))
        let epub = try f.makeEPUB("e.epub")
        let pdf = try f.makePDF("notes.pdf")

        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([epub, pdf], F.meta("x", "y"), roles: [pdf: .extra]), target: .existing(bookId: id))
        ])

        _ = try f.importedId(result.outcomes[0])
        // The existing file keeps its spelling; the new ones are named for the title as it now is.
        #expect(f.libraryTree() == [
            "Frank Herbert", "Frank Herbert/dune", "Frank Herbert/dune/Dune.epub", "Frank Herbert/dune/Extras",
            "Frank Herbert/dune/Extras/notes.pdf", "Frank Herbert/dune/dune.m4b",
        ])
        #expect(try f.store.files(bookId: id).map(\.path) == [
            "Frank Herbert/dune/dune.m4b", "Frank Herbert/dune/Dune.epub", "Frank Herbert/dune/Extras/notes.pdf",
        ])
        #expect(try f.bytes(f.lib("Frank Herbert/dune/dune.m4b")) == audioBytes)
        #expect(try #require(try f.store.lastBatch()).moves.map(\.to) == [
            f.lib("Frank Herbert/dune/Dune.epub").path, f.lib("Frank Herbert/dune/Extras/notes.pdf").path,
        ])

        try f.service.undoLast()
        #expect(f.libraryTree() == ["Frank Herbert", "Frank Herbert/dune", "Frank Herbert/dune/dune.m4b"])
    }

    @Test(arguments: [TransferMode.move, .copy])
    func aFileAlreadyInPlaceUnderOtherCapitalisationIsImportedWhereItIs(mode: TransferMode) throws {
        let f = try F()
        let source = try f.makeM4B("a.m4b", tags: F.meta("x", "y"))
        let inPlace = f.lib("frank herbert/Dune/dune.m4b")
        try FileManager.default.createDirectory(at: inPlace.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: inPlace)

        let id = try f.importNew([inPlace], F.meta("Dune", "Frank Herbert"), mode: mode)

        #expect(f.libraryTree() == ["frank herbert", "frank herbert/Dune", "frank herbert/Dune/dune.m4b"])
        #expect(try f.store.files(bookId: id).map(\.path) == ["frank herbert/Dune/dune.m4b"])
        #expect(try f.store.book(id: id)?.folderPath == "frank herbert/Dune")
        #expect(try #require(try f.store.lastBatch()).moves.isEmpty)
        #expect(try f.tags(inPlace).title == "Dune")
        #expect(try f.service.reconcile() == ReconcileReport())

        try f.service.undoLast()
        #expect(f.libraryTree() == ["frank herbert", "frank herbert/Dune", "frank herbert/Dune/dune.m4b"])
        #expect(try f.tags(inPlace).title == "x")
    }

    // MARK: Undo restores only what the operation changed

    @Test func undoKeepsReadStatusSetSince() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Dune", "Frank Herbert"))
        _ = try edit(f, id) { $0.rating = 4; $0.metadata.genres = ["SF"] }
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        try f.service.setReadStatus(.finished, for: [id], on: day)

        try f.service.undoLast()

        let book = try #require(try f.store.book(id: id))
        #expect(book.rating == 0)
        #expect(book.genres == [])
        #expect(book.readStatus == .finished)
        #expect(book.dateStarted == day)
        #expect(book.dateFinished == day)
    }

    @Test func undoLeavesABookWithAMissingFileFlagged() throws {
        let f = try F()
        let m4b = try f.makeM4B("a.m4b", tags: F.meta("x", "y"))
        let epub = try f.makeEPUB("a.epub")
        let id = try f.importNew([m4b, epub], F.meta("Dune", "Frank Herbert"))
        _ = try edit(f, id) { $0.rating = 4 }
        try FileManager.default.removeItem(at: f.lib("Frank Herbert/Dune/Dune.epub"))
        #expect(try f.service.reconcile().booksWithMissingFiles == [id])

        try f.service.undoLast()

        let book = try #require(try f.store.book(id: id))
        #expect(book.rating == 0)
        #expect(book.needsAttention)
        #expect(try f.service.reconcile().booksWithMissingFiles == [id])
    }

    // MARK: A blocked undo changes nothing

    @Test func blockedUndoLeavesFilesTagsAndRowsAlone() throws {
        let f = try F()
        let one = try f.makeMP3("one.mp3", tags: F.meta("x", "y"))
        let two = try f.makeMP3("two.mp3", tags: F.meta("x", "y"))
        let id = try f.importNew([one], F.meta("Dune", "Frank Herbert"))
        let before = (tree: f.libraryTree(), rows: try f.store.files(bookId: id))
        _ = try f.service.importItems(
            [ImportItem(candidate: f.candidate([two], F.meta("q", "q")), target: .existing(bookId: id))],
            options: ImportOptions(mode: .copy))
        let first = f.lib("Frank Herbert/Dune/01 - Dune.mp3")
        let copy = f.lib("Frank Herbert/Dune/02 - Dune.mp3")
        let tree = f.libraryTree()
        let rows = try f.store.files(bookId: id)
        let journal = try f.store.lastBatch()
        #expect(try f.track(first) == "1/2")
        // The copy can no longer be deleted.
        lock(copy)
        defer { unlock(copy) }

        #expect { try f.service.undoLast() } throws: { error in
            if case LibraryError.undoBlocked? = error as? LibraryError { return true }
            return false
        }

        #expect(f.libraryTree() == tree)
        #expect(try f.track(first) == "1/2")
        #expect(try f.store.files(bookId: id) == rows)
        #expect(try f.store.lastBatch() == journal)
        #expect(try f.service.reconcile() == ReconcileReport())

        unlock(copy)
        try f.service.undoLast()
        #expect(f.libraryTree() == before.tree)
        #expect(try f.store.files(bookId: id) == before.rows)
        #expect(try f.track(f.lib("Frank Herbert/Dune/Dune.mp3")) == nil)
        #expect(f.inboxTree() == ["two.mp3"])
    }

    @Test func blockedUndoOfAnImportLeavesTheTagsAsTheDatabaseHasThem() throws {
        let f = try F()
        let source = try f.makeM4B("a.m4b", tags: F.meta("x", "y"))
        let id = try f.importNew([source], F.meta("Dune", "Frank Herbert"))
        try touch(source, "in the way")

        #expect { try f.service.undoLast() } throws: { error in
            if case LibraryError.undoBlocked? = error as? LibraryError { return true }
            return false
        }

        #expect(try f.tags(f.lib("Frank Herbert/Dune/Dune.m4b")) == F.meta("Dune", "Frank Herbert"))
        #expect(try f.store.book(id: id)?.title == "Dune")
    }

    @Test func aLockedOriginalCanBeCopiedInWrittenAndUndone() throws {
        let f = try F()
        let source = try f.makeM4B("a.m4b", tags: F.meta("x", "y"))
        lock(source)
        defer { unlock(source) }

        let id = try f.importNew([source], F.meta("Dune", "Frank Herbert"), mode: .copy)  // no file problems

        #expect(try f.tags(f.lib("Frank Herbert/Dune/Dune.m4b")).title == "Dune")
        #expect(try f.store.files(bookId: id).map(\.writeProblem) == [nil])
        #expect(try source.resourceValues(forKeys: [.isUserImmutableKey]).isUserImmutable == true)
        try f.service.undoLast()
        #expect(f.libraryTree().isEmpty)
        #expect(try f.tags(source).title == "x")
    }

    // MARK: Smaller rules

    @Test func aSaveDoesNotClearTheFlagWhileAFileIsMissing() throws {
        let f = try F()
        let m4b = try f.makeM4B("a.m4b", tags: F.meta("x", "y"))
        let epub = try f.makeEPUB("a.epub")
        let id = try f.importNew([m4b, epub], F.meta("Dune", "Frank Herbert"))
        let away = f.base.appendingPathComponent("away.epub")
        try FileManager.default.moveItem(at: f.lib("Frank Herbert/Dune/Dune.epub"), to: away)
        _ = try f.service.reconcile()
        #expect(try f.store.book(id: id)?.needsAttention == true)

        _ = try edit(f, id) { $0.metadata.genres = ["SF"] }
        #expect(try f.store.book(id: id)?.genres == ["SF"])
        #expect(try f.store.book(id: id)?.needsAttention == true)

        // Once the file is back, the next check clears it as before.
        try FileManager.default.moveItem(at: away, to: f.lib("Frank Herbert/Dune/Dune.epub"))
        #expect(try f.service.reconcile().booksRecovered == [id])
    }

    @Test func durationIsKeptWhenAnAudioPartCannotBeRead() throws {
        let f = try F()
        let parts = try f.makeMP3Parts(folder: "b", tags: F.meta("x", "y"), count: 2, seconds: 2)
        let id = try f.importNew(parts, F.meta("Dune", "Frank Herbert"))
        let duration = try #require(try f.store.book(id: id)?.durationSeconds)
        try FileManager.default.removeItem(at: f.lib("Frank Herbert/Dune/02 - Dune.mp3"))

        let epub = try f.makeEPUB("e.epub")
        let result = try f.service.importItems(
            [ImportItem(candidate: f.candidate([epub], F.meta("q", "q")), target: .existing(bookId: id))])

        _ = try f.importedId(result.outcomes[0])
        #expect(try f.store.book(id: id)?.durationSeconds == duration)
    }

    // A library whose folder is given through /private (as /private/var/… is for /var/…),
    // or with ".." in it, is like any other.
    @Test(arguments: [false, true])
    func libraryUnderPrivateTmpBehavesLikeAnyOther(dotDot: Bool) throws {
        // In this run's own temporary folder, spelled by the longer of its two names.
        let made = try makeTempDir().path
        let longer = made.hasPrefix("/private/") ? made : "/private" + made
        let path = FileManager.default.fileExists(atPath: longer) ? longer : made
        let real = URL(fileURLWithPath: path, isDirectory: true)
        let base = dotDot
            ? URL(fileURLWithPath: "\(path)/sub/../", isDirectory: true)
            : real
        try FileManager.default.createDirectory(at: real.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let f = try F(base: base)
        func libraryTree() -> [String] { f.libraryTree() }

        let first = try importM4B(f, F.meta("First", "andy weir"), name: "1.m4b")
        let second = try importM4B(f, F.meta("Second", "Andy Weir"), name: "2.m4b")
        // The existing author folder is adopted, and everything is stored relative to the library.
        #expect(libraryTree() == [
            "andy weir", "andy weir/First", "andy weir/First/First.m4b", "andy weir/Second", "andy weir/Second/Second.m4b",
        ])
        #expect(try f.store.book(id: second)?.folderPath == "andy weir/Second")
        #expect(try f.store.files(bookId: second).map(\.path) == ["andy weir/Second/Second.m4b"])

        let outcomes = try edit(f, first) { $0.metadata.title = "Renamed" }
        #expect(outcomes == [.saved(bookId: first, refiled: true, appOnlyFields: [], fileProblems: [])])
        #expect(try f.store.book(id: first)?.folderPath == "andy weir/Renamed")
        #expect(try f.store.files(bookId: first).map(\.path) == ["andy weir/Renamed/Renamed.m4b"])

        let epub = try f.makeEPUB("e.epub")
        let added = try f.service.importItems(
            [ImportItem(candidate: f.candidate([epub], F.meta("q", "q")), target: .existing(bookId: first))])
        _ = try f.importedId(added.outcomes[0])
        #expect(try f.store.files(bookId: first).map(\.path) == ["andy weir/Renamed/Renamed.m4b", "andy weir/Renamed/Renamed.epub"])
        #expect(libraryTree() == [
            "andy weir", "andy weir/Renamed", "andy weir/Renamed/Renamed.epub", "andy weir/Renamed/Renamed.m4b",
            "andy weir/Second", "andy weir/Second/Second.m4b",
        ])
        // A file inside the library, however its path is spelled, is known to be inside it.
        let spelled = URL(fileURLWithPath: "\(path)/Library/andy weir/Second/Second.m4b")
        #expect(f.store.storedPath(for: spelled) == "andy weir/Second/Second.m4b")
        #expect(try f.service.reconcile() == ReconcileReport())

        try f.service.undoLast()
        #expect(f.inboxTree() == ["e.epub"])
        #expect(try f.store.files(bookId: first).map(\.path) == ["andy weir/Renamed/Renamed.m4b"])
    }

    // MARK: Rollback after a failed commit

    @Test func rollbackThatIsPartlyBlockedPutsTheRestBackAndSaysWhatIsLeft() throws {
        let f = try F()
        let a = try f.makeM4B("a.m4b", tags: F.meta("Original A", "Writer"))
        let b = try f.makeM4B("b.m4b", tags: F.meta("Original B", "Writer"))
        let c = try f.makeM4B("c.m4b", tags: F.meta("Original C", "Writer"))
        let earlier = try f.store.recordBatch(label: "earlier", moves: [])
        // By the time the commit fails, something else sits where the first file came from.
        f.service.beforeCommit = {
            try touch(a, "reappeared")
            throw Boom()
        }
        let strandedAt = f.lib("Ann Author/First/First.m4b")

        #expect {
            try f.service.importItems([
                ImportItem(candidate: f.candidate([a], F.meta("First", "Ann Author"))),
                ImportItem(candidate: f.candidate([b], F.meta("Second", "Ben Author"))),
                ImportItem(candidate: f.candidate([c], F.meta("Third", "Cat Author"))),
            ])
        } throws: { error in
            guard case LibraryError.rollbackIncomplete(let cause, let stranded)? = error as? LibraryError else {
                return false
            }
            return !cause.isEmpty && stranded == ["\(strandedAt.path) (from \(a.path))"]
        }

        // The other books are back where they came from, with their own tags.
        #expect(f.inboxTree() == ["a.m4b", "b.m4b", "c.m4b"])
        #expect(try read(a) == "reappeared")
        #expect(try f.tags(b) == F.meta("Original B", "Writer"))
        #expect(try f.tags(c) == F.meta("Original C", "Writer"))
        // Only the blocked file is left in the library; nothing in the database or the
        // journal refers to it, and the launch check finds it.
        #expect(f.libraryTree() == ["Ann Author", "Ann Author/First", "Ann Author/First/First.m4b"])
        #expect(try f.store.books().isEmpty)
        #expect(try f.store.lastBatch()?.id == earlier)
        #expect(!f.hiddenTree().contains { $0.hasPrefix("undo") })
        #expect(try f.service.reconcile().untrackedFiles.map(\.lastPathComponent) == ["First.m4b"])
        // The message names the file and where it came from.
        let message = LibraryService.describe(
            LibraryError.rollbackIncomplete(cause: "x", stranded: ["\(strandedAt.path) (from \(a.path))"]))
        #expect(message.contains(strandedAt.path) && message.contains(a.path))
    }

    @Test func rollbackOfASavePutsEachBookBackOnItsOwn() throws {
        let f = try F()
        let first = try importM4B(f, F.meta("First", "Ann Author"), name: "1.m4b")
        let second = try importM4B(f, F.meta("Second", "Ann Author"), name: "2.m4b")
        let before = (try f.store.books(), try f.store.files(bookId: first), try f.store.files(bookId: second))
        f.service.beforeCommit = {
            try touch(f.lib("Ann Author/Second/Second.m4b"), "in the way")
            throw Boom()
        }
        var e1 = BookEdit(book: try #require(try f.store.book(id: first)))
        e1.metadata.title = "First Renamed"
        var e2 = BookEdit(book: try #require(try f.store.book(id: second)))
        e2.metadata.title = "Second Renamed"

        #expect {
            try f.service.save([e1, e2])
        } throws: { error in
            guard case LibraryError.rollbackIncomplete(_, let stranded)? = error as? LibraryError else { return false }
            return stranded == [
                "\(f.lib("Ann Author/Second Renamed/Second Renamed.m4b").path) (from \(f.lib("Ann Author/Second/Second.m4b").path))"
            ]
        }

        #expect(f.libraryTree() == [
            "Ann Author", "Ann Author/First", "Ann Author/First/First.m4b", "Ann Author/Second",
            "Ann Author/Second Renamed", "Ann Author/Second Renamed/Second Renamed.m4b",
            "Ann Author/Second/Second.m4b",
        ])
        #expect(try f.tags(f.lib("Ann Author/First/First.m4b")).title == "First")
        // The stranded file has its earlier tags back too.
        #expect(try f.tags(f.lib("Ann Author/Second Renamed/Second Renamed.m4b")).title == "Second")
        #expect(try f.store.books() == before.0)
        #expect(try f.store.files(bookId: first) == before.1)
        #expect(try f.store.files(bookId: second) == before.2)
    }

    // MARK: Undo data from other versions and other libraries

    /// Replaces the recorded snapshot with an edited copy of itself.
    func rewriteSnapshot(_ f: F, _ change: (inout [String: Any]) -> Void) throws {
        let batch = try #require(try f.store.lastBatch())
        let data = try #require(batch.snapshot)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&json)
        // In place of the one recorded, not on top of it.
        var taken = LibraryChange()
        taken.popsJournal = true
        try f.store.apply(taken)
        var replacement = LibraryChange()
        replacement.batch = .init(
            label: batch.label, moves: batch.moves, snapshot: try JSONSerialization.data(withJSONObject: json))
        try f.store.apply(replacement)
    }

    /// An edit that moved the book, changed a tag and the cover.
    func editedBook(_ f: F) throws -> Int64 {
        let id = try f.importNew(
            [try f.makeM4B("in.m4b", tags: F.meta("Old", "Old Author"), cover: F.jpeg)], F.meta("Dune", "Frank Herbert"))
        var e = BookEdit(book: try #require(try f.store.book(id: id)), cover: .set(F.png))
        e.metadata.authors = ["F. Herbert"]
        e.metadata.genres = ["SF"]
        _ = try f.service.save([e])
        return id
    }

    func expectEditUndone(_ f: F, _ id: Int64) throws {
        #expect(try f.service.undoLabel() == "Edit Dune")
        try f.service.undoLast()
        #expect(f.libraryTree() == ["Frank Herbert", "Frank Herbert/Dune", "Frank Herbert/Dune/Dune.m4b"])
        let book = try #require(try f.store.book(id: id))
        #expect(book.authors == ["Frank Herbert"])
        #expect(book.genres == [])
        #expect(try f.store.files(bookId: id).map(\.path) == ["Frank Herbert/Dune/Dune.m4b"])
        #expect(try f.tags(f.lib("Frank Herbert/Dune/Dune.m4b")).genreSource == nil)
        #expect(try f.io.read(f.lib("Frank Herbert/Dune/Dune.m4b")).cover == F.jpeg)
        #expect(f.service.covers.image(for: id) == F.jpeg)
        // The edit is undone; what is next to undo is the import before it.
        #expect(try f.service.undoLabels().allSatisfy { $0.hasPrefix("Import ") })
    }

    @Test func snapshotCarriesItsVersion() throws {
        let f = try F()
        _ = try editedBook(f)
        // An edit holds a book and its files' tags as they were, with their several
        // genres, and says so: code that knows one genre text must leave it alone.
        #expect(try f.snapshot().version == 4)
        #expect(OperationSnapshot.currentVersion == 5)
        let batch = try #require(try f.store.lastBatch())
        let data = try #require(batch.snapshot)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["version"] as? Int == 4)
    }

    // A snapshot written before some fields existed can still be undone.
    @Test func snapshotWithFieldsMissingIsStillUndoable() throws {
        let f = try F()
        let id = try editedBook(f)
        try rewriteSnapshot(f) { json in
            json["version"] = nil
            var books = json["books"] as! [[String: Any]]
            var before = books[0]["bookBefore"] as! [String: Any]
            #expect(before["appOnlyFields"] != nil)
            before["appOnlyFields"] = nil
            before["readStatus"] = nil
            before["rating"] = nil
            books[0]["bookBefore"] = before
            books[0]["filesBefore"] = (books[0]["filesBefore"] as! [[String: Any]]).map { row in
                var row = row
                row["position"] = nil
                row["originalName"] = nil
                return row
            }
            books[0]["fileStates"] = (books[0]["fileStates"] as! [[String: Any]]).map { state in
                var state = state
                var metadata = state["metadataBefore"] as! [String: Any]
                metadata["narrators"] = nil
                state["metadataBefore"] = metadata
                state["part"] = nil
                return state
            }
            json["books"] = books
        }
        try expectEditUndone(f, id)
    }

    // A snapshot with fields this code does not know (same version) can still be undone.
    @Test func snapshotWithUnknownFieldsIsStillUndoable() throws {
        let f = try F()
        let id = try editedBook(f)
        try rewriteSnapshot(f) { json in
            json["writtenBy"] = "a later build"
            var books = json["books"] as! [[String: Any]]
            books[0]["somethingNew"] = ["a": 1]
            var before = books[0]["bookBefore"] as! [String: Any]
            before["shelf"] = "upstairs"
            books[0]["bookBefore"] = before
            books[0]["filesBefore"] = (books[0]["filesBefore"] as! [[String: Any]]).map { row in
                var row = row
                row["checksum"] = "abc"
                return row
            }
            json["books"] = books
        }
        try expectEditUndone(f, id)
    }

    // A snapshot from a newer layout is not undoable: it is not offered, and asking forgets it.
    @Test func snapshotFromANewerVersionIsNotUndoable() throws {
        let f = try F()
        let id = try editedBook(f)
        try rewriteSnapshot(f) { $0["version"] = OperationSnapshot.currentVersion + 1 }
        let tree = f.libraryTree()
        let book = try f.store.book(id: id)
        #expect(f.hiddenTree().contains { $0.hasPrefix("undo/") })

        #expect(try f.service.undoLabel() == nil)
        #expect(throws: LibraryError.nothingToUndo) { try f.service.undoLast() }

        #expect(f.libraryTree() == tree)
        #expect(try f.store.book(id: id) == book)
        #expect(try f.tags(f.lib("F. Herbert/Dune/Dune.m4b")).genreSource == "SF")
        #expect(try f.store.lastBatch() == nil)
        #expect(!f.hiddenTree().contains { $0.hasPrefix("undo") })
    }

    // Undo data that cannot be read says nothing about which books it involves.
    @Test func removingABookDoesNotForgetAnUnreadableBatchAboutOthers() throws {
        let f = try F()
        let id = try editedBook(f)
        let other = try importM4B(f, F.meta("Other", "Ann Author"), name: "o.m4b")
        var broken = LibraryChange()
        broken.batch = .init(
            label: "Broken", moves: [
                MoveRecord(from: f.inbox.appendingPathComponent("in.m4b").path,
                           to: f.lib("F. Herbert/Dune/Dune.m4b").path, wasCopy: false)
            ], snapshot: Data("not json".utf8))
        try f.store.apply(broken)

        try f.service.removeBook(id: other, moveFilesToTrash: false)
        #expect(try f.store.lastBatch()?.label == "Broken")

        // A book one of whose files the batch moved is still taken to be involved.
        try f.service.removeBook(id: id, moveFilesToTrash: false)
        #expect(try f.store.lastBatch() == nil)
    }

    // A journal that describes files of another folder (the library was copied or moved)
    // is never acted on.
    @Test func aBatchAboutAnotherLibraryIsNotUndoable() throws {
        let f = try F()
        let elsewhere = try F()
        let id = try importM4B(elsewhere, F.meta("Dune", "Frank Herbert"))
        let batch = try #require(try elsewhere.store.lastBatch())
        // The copied library has the same rows and the same journal, word for word.
        _ = try importM4B(f, F.meta("Dune", "Frank Herbert"))
        var copied = LibraryChange()
        copied.batch = .init(label: batch.label, moves: batch.moves, snapshot: batch.snapshot)
        try f.store.apply(copied)

        #expect(try f.service.undoLabel() == nil)
        #expect(throws: LibraryError.nothingToUndo) { try f.service.undoLast() }

        // Neither library was touched.
        #expect(elsewhere.libraryTree() == ["Frank Herbert", "Frank Herbert/Dune", "Frank Herbert/Dune/Dune.m4b"])
        #expect(try elsewhere.tags(elsewhere.lib("Frank Herbert/Dune/Dune.m4b")).title == "Dune")
        #expect(elsewhere.inboxTree().isEmpty)
        #expect(try elsewhere.store.book(id: id) != nil)
        #expect(f.libraryTree() == ["Frank Herbert", "Frank Herbert/Dune", "Frank Herbert/Dune/Dune.m4b"])
        #expect(try f.store.books().count == 1)
        #expect(try f.store.lastBatch() == nil)
    }

    // MARK: An extra's own name

    @Test func anExtraGetsItsNameBackAfterBeingAnEbook() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Dune", "Frank Herbert"))
        let pdf = try f.makePDF("Reading Guide.pdf")
        _ = try f.service.importItems([
            ImportItem(candidate: f.candidate([pdf], F.meta("x", "y"), roles: [pdf: .extra]), target: .existing(bookId: id))
        ])
        func pdfRow() throws -> BookFile { try #require(try f.store.files(bookId: id).first { $0.format == .pdf }) }
        #expect(try pdfRow().originalName == "Reading Guide.pdf")
        #expect(try f.store.files(bookId: id).first?.originalName == nil)

        try f.service.setRole(.ebook, forFile: try #require(try pdfRow().id))
        #expect(try pdfRow().path == "Frank Herbert/Dune/Dune.pdf")
        #expect(try pdfRow().originalName == "Reading Guide.pdf")

        // A save in between keeps it.
        _ = try edit(f, id) { $0.metadata.title = "Dune Messiah" }
        #expect(try pdfRow().path == "Frank Herbert/Dune Messiah/Dune Messiah.pdf")
        #expect(try pdfRow().originalName == "Reading Guide.pdf")

        try f.service.setRole(.extra, forFile: try #require(try pdfRow().id))
        #expect(try pdfRow().path == "Frank Herbert/Dune Messiah/Extras/Reading Guide.pdf")

        // Undo puts it back as the ebook, name recorded as before.
        try f.service.undoLast()
        #expect(try pdfRow().path == "Frank Herbert/Dune Messiah/Dune Messiah.pdf")
        #expect(try pdfRow().originalName == "Reading Guide.pdf")
    }

    // A row filed as an extra before names were recorded: the name it has is the one kept.
    @Test func anExtraFiledBeforeNamesWereRecordedKeepsTheNameItHas() throws {
        let f = try F()
        let m4b = try f.makeM4B("a.m4b", tags: F.meta("x", "y"))
        let pdf = try f.makePDF("Map.pdf")
        let id = try f.importNew([m4b, pdf], F.meta("Dune", "Frank Herbert"))
        try f.service.setRole(.extra, forFile: try #require(try f.store.files(bookId: id).last?.id))
        try f.store.replaceFiles(bookId: id, files: try f.store.files(bookId: id).map {
            var row = $0
            row.originalName = nil
            return row
        })
        try FileManager.default.moveItem(
            at: f.lib("Frank Herbert/Dune/Extras/Dune.pdf"), to: f.lib("Frank Herbert/Dune/Extras/Old Map.pdf"))
        try f.store.replaceFiles(bookId: id, files: try f.store.files(bookId: id).map {
            var row = $0
            if row.format == .pdf { row.path = "Frank Herbert/Dune/Extras/Old Map.pdf" }
            return row
        })
        func pdfRow() throws -> BookFile { try #require(try f.store.files(bookId: id).first { $0.format == .pdf }) }

        try f.service.setRole(.ebook, forFile: try #require(try pdfRow().id))
        #expect(try pdfRow().path == "Frank Herbert/Dune/Dune.pdf")
        #expect(try pdfRow().originalName == "Old Map.pdf")
        try f.service.setRole(.extra, forFile: try #require(try pdfRow().id))
        #expect(try pdfRow().path == "Frank Herbert/Dune/Extras/Old Map.pdf")
    }
}
