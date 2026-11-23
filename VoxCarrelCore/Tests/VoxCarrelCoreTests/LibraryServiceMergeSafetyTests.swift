import Foundation
import GRDB
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// Merging entries: what is not the merge's own is never replaced, removed or lost.
@Suite struct LibraryServiceMergeSafetyTests {
    typealias F = LibraryFixture

    /// Every file under a folder, by its path there, with its bytes.
    private func contents(of folder: URL) throws -> [String: Data] {
        var found: [String: Data] = [:]
        let base = folder.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        else { return found }
        for case let url as URL in walker {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard !path.contains("/.voxcarrel/"), !path.hasPrefix(base + "/" + LibraryStore.databaseFileName)
            else { continue }
            found[String(path.dropFirst(base.count + 1))] = try Data(contentsOf: url)
        }
        return found
    }

    private func ebookAndNotes(_ f: F) throws -> (ebook: Int64, notes: Int64) {
        let ebook = try f.importNew([try f.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))
        let notes = try f.importNew([try f.makePDF("notes.pdf")], F.meta("Dune Notes", "Frank Herbert"))
        return (ebook, notes)
    }

    private func undoData(_ f: F) -> [String] {
        f.hiddenTree().filter { $0.hasPrefix("undo/") }
    }

    // MARK: What is not the merge's own

    @Test func aFileThatIsNoBooksInARemovedEntrysFolderStaysWithItsFolder() throws {
        let f = try F()
        let (ebook, notes) = try ebookAndNotes(f)
        let stray = try touch(f.lib("Frank Herbert/Dune Notes/my scribbles.txt"), "mine")
        let before = try contents(of: f.root)

        try f.service.mergeBooks([ebook, notes], keep: ebook, roles: [:])
        #expect(try read(stray) == "mine")
        #expect(try f.store.files(bookId: ebook).map(\.path) == ["Frank Herbert/Dune/Dune.epub", "Frank Herbert/Dune/Dune.pdf"])

        try f.service.undoLast()
        #expect(try contents(of: f.root) == before)
        #expect(try f.service.reconcile().booksWithMissingFiles.isEmpty)
    }

    @Test func theKeptBookMovesIntoAFolderWhereAnExtraOfTheSameNameIsAndNeitherIsReplaced() throws {
        let f = try F()
        func entry(_ dir: String, _ main: URL, title: String, pages: Int) throws -> Int64 {
            let extra = try f.makePDF("\(dir)/notes.pdf", pages: pages)
            let result = try f.service.importItems([
                ImportItem(candidate: f.candidate([main, extra], F.meta(title, "Frank Herbert"), roles: [extra: .extra]))
            ])
            return try f.importedId(try #require(result.outcomes.first))
        }
        // An audiobook given the title of the PDF's entry: flagged, in its old folder.
        let audio = try entry("a", try f.makeM4B("a/dune.m4b", tags: BookMetadata()), title: "Dune (Unabridged)", pages: 3)
        let text = try entry("t", try f.makePDF("t/dune.pdf", pages: 4), title: "Dune", pages: 5)
        var edit = BookEdit(book: try #require(try f.store.book(id: audio)))
        edit.metadata.title = "Dune"
        _ = try f.service.save([edit])
        let before = try contents(of: f.root)
        let ownExtra = try #require(before["Frank Herbert/Dune (Unabridged)/Extras/notes.pdf"])
        let othersExtra = try #require(before["Frank Herbert/Dune/Extras/notes.pdf"])
        #expect(ownExtra != othersExtra)

        // The kept book's extra goes where the other's is, which takes the next name.
        try f.service.mergeBooks([audio, text], keep: audio, roles: [:])

        #expect(try f.store.files(bookId: audio).map(\.path) == [
            "Frank Herbert/Dune/Dune.m4b", "Frank Herbert/Dune/Dune.pdf", "Frank Herbert/Dune/Extras/notes.pdf",
            "Frank Herbert/Dune/Extras/notes 2.pdf",
        ])
        let merged = try contents(of: f.root)
        #expect(merged.count == 4)
        #expect(merged["Frank Herbert/Dune/Extras/notes.pdf"] == ownExtra)
        #expect(merged["Frank Herbert/Dune/Extras/notes 2.pdf"] == othersExtra)
        #expect(try f.service.reconcile() == ReconcileReport())

        try f.service.undoLast()
        #expect(try contents(of: f.root) == before)
    }

    // MARK: Failure before anything moves

    @Test func whenWhatUndoNeedsCannotBeSavedNothingIsChanged() throws {
        let f = try F()
        let (ebook, notes) = try ebookAndNotes(f)
        // The undo folder cannot be made: something that is no folder has its name.
        let blocked = f.service.layout.undoFolder
        try? FileManager.default.removeItem(at: blocked)
        try touch(blocked, "in the way")
        let before = try contents(of: f.root)
        let books = try f.store.books()
        let batch = try f.store.lastBatch()

        #expect(throws: (any Error).self) { try f.service.mergeBooks([ebook, notes], keep: ebook, roles: [:]) }

        #expect(try contents(of: f.root) == before)
        #expect(try f.store.books() == books)
        #expect(try f.store.lastBatch() == batch)
        #expect(try read(blocked) == "in the way")
    }

    // MARK: The saved originals

    @Test func theOriginalsAMergeSavedGoWhenAnotherOperationIsRecorded() throws {
        let f = try F()
        let (ebook, notes) = try ebookAndNotes(f)
        let third = try f.importNew([try f.makePDF("third.pdf")], F.meta("Third", "Someone"))
        try f.service.mergeBooks([ebook, notes], keep: ebook, roles: [:])
        #expect(undoData(f).contains { $0.hasSuffix(".orig") })

        var edit = BookEdit(book: try #require(try f.store.book(id: third)))
        edit.rating = 3
        _ = try f.service.save([edit])

        #expect(try f.service.undoLabel() == "Edit Third")
        #expect(!undoData(f).contains { $0.hasSuffix(".orig") })
        // And that edit is what undo reverses: the merge stays.
        try f.service.undoLast()
        #expect(try f.store.books().compactMap(\.id).sorted() == [ebook, third].sorted())
    }

    @Test func ofTwoMergesInARowOnlyTheSecondKeepsItsOriginals() throws {
        let f = try F()
        let (ebook, notes) = try ebookAndNotes(f)
        let maps = try f.importNew([try f.makePDF("maps.pdf")], F.meta("Dune Maps", "Frank Herbert"))
        try f.service.mergeBooks([ebook, notes], keep: ebook, roles: [:])
        let first = Set(undoData(f))
        let afterFirst = try contents(of: f.root)
        let books = try f.store.books()

        try f.service.mergeBooks([ebook, maps], keep: ebook, roles: [:])
        #expect(first.isDisjoint(with: undoData(f).filter { $0.split(separator: "/").count > 2 }))

        // Undo reverses the second only, exactly.
        try f.service.undoLast()
        #expect(try contents(of: f.root) == afterFirst)
        #expect(try f.store.books().sorted { ($0.id ?? 0) < ($1.id ?? 0) } == books.sorted { ($0.id ?? 0) < ($1.id ?? 0) })
        #expect(try f.service.undoLabel() == nil)
        #expect(undoData(f).isEmpty)
    }

    @Test func removingTheKeptBookForgetsTheMergeAndItsOriginals() throws {
        let f = try F()
        let (ebook, notes) = try ebookAndNotes(f)
        try f.service.mergeBooks([ebook, notes], keep: ebook, roles: [:])
        f.service.trashItem = { try FileManager.default.removeItem(at: $0) }

        try f.service.removeBook(id: ebook, moveFilesToTrash: true)

        #expect(try f.service.undoLabel() == nil)
        #expect(undoData(f).isEmpty)
        #expect(try f.store.books().isEmpty)
    }

    @Test func aMergeIsUndoneExactlyByAnotherRunOfTheApp() throws {
        let f = try F()
        let ebook = try f.importNew([try f.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))
        let audio = try f.importNew(
            [try f.makeM4B("dune.m4b", tags: F.meta("Old", "Old Author"), cover: F.jpeg)],
            F.fullMeta("Dune Audio", "Frank Herbert"))
        let before = try contents(of: f.root)
        let books = try f.store.books()
        try f.service.mergeBooks([ebook, audio], keep: ebook, roles: [:])

        // The app quits and is opened again.
        let again = LibraryService(store: try LibraryStore(libraryRoot: f.root))
        #expect(try again.undoLast() == "Merge Books")

        #expect(try contents(of: f.root) == before)
        #expect(try f.store.books() == books)
    }

    // MARK: Entries catalogued where they are

    @Test func aFileCataloguedOutsideTheLibraryComesInAndUndoPutsItBackAsItWas() throws {
        let f = try F()
        let kept = try f.importNew([try f.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))
        // No author: catalogued where it is, outside the library.
        let loose = try f.makePDF("loose/notes.pdf")
        try touch(f.inbox.appendingPathComponent("loose/beside.txt"), "beside")
        let result = try f.service.importItems([ImportItem(candidate: f.candidate([loose], BookMetadata(title: "Loose Notes")))])
        guard case .needsAttention(let other) = result.outcomes[0] else {
            Issue.record("expected the entry to be catalogued in place, got \(result.outcomes)")
            return
        }
        let inside = try contents(of: f.root)
        let outside = try contents(of: f.inbox)
        let books = try f.store.books()

        let plan = try f.service.planMerge(bookIds: [kept, other], keep: kept)
        #expect(plan.blockers.isEmpty)
        try f.service.mergeBooks([kept, other], keep: kept, roles: [:])
        #expect(try f.store.files(bookId: kept).map(\.path) == ["Frank Herbert/Dune/Dune.epub", "Frank Herbert/Dune/Dune.pdf"])
        // What was beside it outside is no one's to touch.
        #expect(try contents(of: f.inbox) == ["loose/beside.txt": Data("beside".utf8)])

        try f.service.undoLast()
        #expect(try contents(of: f.root) == inside)
        #expect(try contents(of: f.inbox) == outside)
        #expect(try f.store.books() == books)
    }

    @Test func thePlanCountsTheFilesThatWouldComeIntoTheLibraryFromOutside() throws {
        let f = try F()
        let inside = try f.importNew([try f.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))
        let alsoInside = try f.importNew([try f.makePDF("maps.pdf")], F.meta("Dune Maps", "Frank Herbert"))
        // No author: each is catalogued where it is, outside the library.
        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([try f.makePDF("loose/notes.pdf")], BookMetadata(title: "Loose Notes"))),
            ImportItem(candidate: f.candidate([try f.makePDF("loose/more.pdf")], BookMetadata(title: "More Notes"))),
        ])
        guard case .needsAttention(let outside) = result.outcomes[0],
              case .needsAttention(let alsoOutside) = result.outcomes[1]
        else {
            Issue.record("expected both to be catalogued in place, got \(result.outcomes)")
            return
        }

        // A file that comes in from outside.
        #expect(try f.service.planMerge(bookIds: [inside, outside], keep: inside).filesFromOutside == 1)
        // The kept entry's own file: with the other's author the book can be filed, in the library.
        let keptOutside = try f.service.planMerge(bookIds: [inside, outside], keep: outside)
        #expect(keptOutside.resultFolder == "Frank Herbert/Loose Notes")
        #expect(keptOutside.filesFromOutside == 1)
        #expect(try f.service.planMerge(bookIds: [inside, outside, alsoOutside], keep: inside).filesFromOutside == 2)
        // None: every file is in the library already, or nothing moves at all.
        #expect(try f.service.planMerge(bookIds: [inside, alsoInside], keep: inside).filesFromOutside == 0)
        let nowhere = try f.service.planMerge(bookIds: [outside, alsoOutside], keep: outside)
        #expect(nowhere.resultFolder == nil)
        #expect(nowhere.filesFromOutside == 0)
    }

    // MARK: A third book in the way

    @Test func aKeptEntryWithNoFolderOfItsOwnAndAThirdBookInTheWay() throws {
        let f = try F()
        let copy = ExternalCopy(kind: .audible, form: .audio, store: "us", itemId: "B000000001")
        guard case .added(let owned) = try f.service.addExternalBook(
            metadata: F.meta("Dune", "Frank Herbert"), cover: nil, copy: copy)
        else {
            Issue.record("not added")
            return
        }
        let third = try f.importNew([try f.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))
        let notes = try f.importNew([try f.makePDF("notes.pdf")], F.meta("Dune Notes", "Frank Herbert"))
        let before = try contents(of: f.root)
        let thirdBefore = try f.store.book(id: third)

        let plan = try f.service.planMerge(bookIds: [owned, notes], keep: owned)
        try f.service.mergeBooks([owned, notes], keep: owned, roles: [:])

        // The third book and its file are untouched, and the kept book is not in its folder.
        #expect(try f.store.book(id: third) == thirdBefore)
        #expect(try f.store.files(bookId: third).map(\.path) == ["Frank Herbert/Dune/Dune.epub"])
        let merged = try #require(try f.store.book(id: owned))
        let rows = try f.store.files(bookId: owned)
        #expect(rows.allSatisfy { !$0.path.hasPrefix("Frank Herbert/Dune/") })
        #expect(merged.needsAttention)
        #expect(plan.attention == .folderTaken)
        #expect(try f.service.reconcile().booksWithMissingFiles.isEmpty)
        #expect(try f.service.reconcile().untrackedFiles.isEmpty)

        try f.service.undoLast()
        #expect(try contents(of: f.root) == before)
    }

    // MARK: Roles given by the owner

    @Test func rolesGivenToFilesThatComeInAreUndoneExactly() throws {
        let f = try F()
        let kept = try f.importNew([try f.makeM4B("dune.m4b", tags: BookMetadata())], F.meta("Dune", "Frank Herbert"))
        let mapURL = try f.makePDF("o/map.pdf")
        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate(
                [try f.makeEPUB("o/dune.epub"), mapURL], F.meta("Dune Text", "Frank Herbert"), roles: [mapURL: .extra]))
        ])
        let other = try f.importedId(try #require(result.outcomes.first))
        let rows = try f.store.files(bookId: other)
        let before = try contents(of: f.root)
        let books = try f.store.books()
        let files = try f.store.allFiles()

        // The EPUB becomes an extra and the map the ebook.
        let roles: [Int64: FileRole] = [try #require(rows[0].id): .extra, try #require(rows[1].id): .ebook]
        try f.service.mergeBooks([kept, other], keep: kept, roles: roles)
        #expect(try f.store.files(bookId: kept).map(\.path) == [
            "Frank Herbert/Dune/Dune.m4b", "Frank Herbert/Dune/Dune.pdf", "Frank Herbert/Dune/Extras/Dune Text.epub",
        ])
        #expect(try f.service.reconcile() == ReconcileReport())

        try f.service.undoLast()
        #expect(try contents(of: f.root) == before)
        #expect(try f.store.books() == books)
        #expect(try f.store.allFiles() == files)
    }

    // MARK: A kept book that is not whole

    @Test func aKeptBookWithAFileMissingStaysInItsFolderThoughTheLayoutWouldMoveIt() throws {
        let f = try F()
        try f.store.setFolderPatternText("{Kind}/{Author}/{Title}")
        let ebook = try f.importNew([try f.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))
        let audio = try f.importNew([try f.makeM4B("dune.m4b", tags: BookMetadata())], F.meta("Dune", "Frank Herbert"))
        try FileManager.default.removeItem(at: f.lib("Ebooks/Frank Herbert/Dune/Dune.epub"))

        // With audio the layout files the book among the audiobooks; but a book that
        // is not whole is never moved, or it would be in two folders.
        let plan = try f.service.planMerge(bookIds: [ebook, audio], keep: ebook)
        #expect(plan.blockers.isEmpty)
        #expect(plan.resultFolder == "Ebooks/Frank Herbert/Dune")
        #expect(plan.attention == .fileMissing)
        try f.service.mergeBooks([ebook, audio], keep: ebook, roles: [:])

        let merged = try #require(try f.store.book(id: ebook))
        #expect(merged.folderPath == "Ebooks/Frank Herbert/Dune")
        #expect(merged.needsAttention)
        #expect(try f.store.files(bookId: ebook).map(\.path) == [
            "Ebooks/Frank Herbert/Dune/Dune.m4b", "Ebooks/Frank Herbert/Dune/Dune.epub",
        ])
        #expect(try contents(of: f.root).keys.sorted() == ["Ebooks/Frank Herbert/Dune/Dune.m4b"])
    }

    // MARK: The page count

    @Test func thePageCountIsNotTakenFromAnEntryWhoseFileBecomesAnExtra() throws {
        let f = try F()
        let audio = try f.importNew(
            [try f.makeM4B("mom.m4b", tags: BookMetadata())], F.meta("Mind Over Markets", "James Dalton"))
        let companion = try f.importNew(
            [try f.makePDF("companion.pdf", pages: 2)], F.meta("Mind Over Markets [B09WXN61GL]", "James Dalton"))
        let text = try f.importNew([try f.makePDF("text.pdf", pages: 7)], F.meta("Mind Over Markets Text", "James Dalton"))
        #expect(try f.store.book(id: companion)?.pageCount == 2)

        // The companion is chosen before the book's own text.
        let plan = try f.service.planMerge(bookIds: [audio, companion, text], keep: audio)
        #expect(plan.files.map(\.role) == [.audio, .extra, .ebook])
        try f.service.mergeBooks([audio, companion, text], keep: audio, roles: [:])
        #expect(try f.store.book(id: audio)?.pageCount == 7)

        // With no ebook at all, an audiobook has no pages to count.
        let f2 = try F()
        let audio2 = try f2.importNew(
            [try f2.makeM4B("mom.m4b", tags: BookMetadata())], F.meta("Mind Over Markets", "James Dalton"))
        let companion2 = try f2.importNew(
            [try f2.makePDF("companion.pdf", pages: 2)], F.meta("Mind Over Markets [B09WXN61GL]", "James Dalton"))
        try f2.service.mergeBooks([audio2, companion2], keep: audio2, roles: [:])
        #expect(try f2.store.book(id: audio2)?.pageCount == nil)
    }

    // MARK: Files as they were

    @Test func aFileThatCannotBeWrittenStillComesInAndGoesBackAsItWas() throws {
        let f = try F()
        let (ebook, notes) = try ebookAndNotes(f)
        let pdf = f.lib("Frank Herbert/Dune Notes/Dune Notes.pdf")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: pdf.path)
        let before = try contents(of: f.root)
        let books = try f.store.books()

        try f.service.mergeBooks([ebook, notes], keep: ebook, roles: [:])
        let rows = try f.store.files(bookId: ebook)
        #expect(rows.map(\.path) == ["Frank Herbert/Dune/Dune.epub", "Frank Herbert/Dune/Dune.pdf"])
        #expect(rows.map { $0.writeProblem == nil } == [true, false])
        // Nothing was written into it, so no original of it is kept.
        #expect(!undoData(f).contains { $0.hasSuffix(".orig") })

        try f.service.undoLast()
        #expect(try contents(of: f.root) == before)
        #expect(try f.store.books() == books)
        let mode = try FileManager.default.attributesOfItem(atPath: pdf.path)[.posixPermissions] as? Int
        #expect(mode == 0o444)
    }

    @Test func aFilePutBackWholeIsNotWrittenIntoAgainWhereDatesCannotTellItFromTheWrittenOne() throws {
        let f = try F()
        let file = try f.makePDF("x/book.pdf")
        let details = F.meta("Dune", "Frank Herbert")
        try f.io.write(details, to: file)
        let asItWas = try f.bytes(file)
        let token = UUID().uuidString
        var original = try f.service.saveOriginal(of: file, token: token)
        // As a write leaves the file on a disk that keeps dates to the second: of the
        // same size, and with the date it had.
        try Data(repeating: 0x20, count: asItWas.count).write(to: file)
        original.before.setTime(ofFileAt: file)
        original.written = FileStamp(fileAt: file)
        #expect(original.written == original.before)
        var state = FileState(
            pathAfter: file.path, metadataBefore: details, part: nil, trackBefore: nil, coverBefore: nil)
        state.original = original

        try f.service.restoreFile(state, at: file.path, token: token)
        #expect(try f.bytes(file) == asItWas)

        // The undo is made again, as after a catalogue that could not be written: the
        // file is already the one that was kept.
        try f.service.restoreFile(state, at: file.path, token: token)
        #expect(try f.bytes(file) == asItWas)
    }

    @Test func everyFilesDateIsWhatItWasOnceAMergeIsUndone() throws {
        let f = try F()
        let (ebook, notes) = try ebookAndNotes(f)
        func stamps() throws -> [String: FileStamp] {
            var found: [String: FileStamp] = [:]
            for path in try contents(of: f.root).keys { found[path] = FileStamp(fileAt: f.lib(path)) }
            return found
        }
        let before = try stamps()
        #expect(before.count == 2)
        try f.service.mergeBooks([ebook, notes], keep: ebook, roles: [:])
        #expect(try stamps() != before)
        try f.service.undoLast()
        #expect(try stamps() == before)
    }
}
