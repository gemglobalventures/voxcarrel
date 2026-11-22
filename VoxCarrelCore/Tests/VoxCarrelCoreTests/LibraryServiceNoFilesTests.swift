import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// Plan 6, Task 2: every rule that assumed a book has files, for one that has none (X6–X13).
@Suite struct LibraryServiceNoFilesTests {
    typealias F = LibraryFixture

    static let asin = "B0AUDIBLE1"
    static let audible = ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: asin)
    static let audibleSeconds: Double = 36_000

    /// Details as the Audible catalogue gives them: every field, filed under a series.
    static func catalogue(_ title: String, _ author: String, asin: String? = LibraryServiceNoFilesTests.asin)
        -> BookMetadata
    {
        var m = F.fullMeta(title, author)
        m.asin = asin
        m.durationSeconds = audibleSeconds
        return m
    }

    /// Adds a book that is on Audible only; returns its id.
    func addAudible(
        _ f: F, _ metadata: BookMetadata, cover: CoverImage? = F.jpeg, copy: ExternalCopy = audible
    ) throws -> Int64 {
        let outcome = try f.service.addExternalBook(metadata: metadata, cover: cover, copy: copy)
        guard case .added(let id) = outcome else {
            Issue.record("expected .added, got \(outcome)")
            throw F.FixtureError.unexpectedOutcome
        }
        return id
    }

    /// A book's details as its files should hold them: without the facts about the files.
    func details(_ book: Book) -> BookMetadata {
        var m = book.metadata
        m.durationSeconds = nil
        m.pageCount = nil
        return m
    }

    func importInto(
        _ f: F, _ bookId: Int64, _ urls: [URL], tags: BookMetadata, cover: CoverChange = .keep,
        mode: TransferMode = .move
    ) throws -> ImportOutcome {
        let result = try f.service.importItems(
            [ImportItem(candidate: f.candidate(urls, tags), target: .existing(bookId: bookId), cover: cover)],
            options: ImportOptions(mode: mode))
        return try #require(result.outcomes.first)
    }

    func duration(_ f: F, _ url: URL) throws -> Double {
        try #require(try f.io.read(url).metadata.durationSeconds)
    }

    static let glassFolder = "Ines Calloway/The Series/2 - The Glass Tide"

    // MARK: X6

    // X6: the launch check, on a library holding both kinds of book.
    @Test func X6_theLaunchCheckIgnoresBooksWithNoFiles() throws {
        let f = try F()
        let present = try f.importNew(
            [try f.makeM4B("present.m4b", tags: F.meta("Present", "Ann Author"))], F.meta("Present", "Ann Author"))
        let missing = try f.importNew(
            [try f.makeM4B("missing.m4b", tags: F.meta("Missing", "Ann Author"))], F.meta("Missing", "Ann Author"))
        try FileManager.default.removeItem(at: f.lib("Ann Author/Missing/Missing.m4b"))
        let only = try addAudible(f, Self.catalogue("Only On Audible", "Ann Author"))
        // One that cannot be filed (no author), and one flagged by hand for another reason.
        let authorless = try addAudible(
            f, BookMetadata(title: "No Author"), cover: nil,
            copy: ExternalCopy(kind: .audible, form: .audio, store: "uk"))
        let flagged = try addAudible(f, Self.catalogue("Flagged", "Ann Author", asin: "B0FLAGGED1"), cover: nil,
                                     copy: ExternalCopy(kind: .audible, form: .ebook, store: "uk", itemId: "B0FLAGGED1"))
        try f.store.setNeedsAttention(flagging: [flagged], clearing: [])
        let noFileBooks = try [only, authorless, flagged].map { try #require(try f.store.book(id: $0)) }

        let report = try f.service.reconcile()

        #expect(report.booksWithMissingFiles == [missing])
        #expect(report.booksRecovered.isEmpty)
        #expect(report.untrackedFiles.isEmpty)
        #expect(report.strandedFiles.isEmpty)
        // Not flagged, not un-flagged, not changed in any way.
        #expect(try [only, authorless, flagged].map { try #require(try f.store.book(id: $0)) } == noFileBooks)
        #expect(try f.store.book(id: only)?.needsAttention == false)
        #expect(try f.store.book(id: authorless)?.needsAttention == false)
        #expect(try f.store.book(id: flagged)?.needsAttention == true)
        #expect(try f.store.book(id: present)?.needsAttention == false)
        #expect(try f.store.book(id: missing)?.needsAttention == true)
        #expect(try f.store.books(needsAttention: true).compactMap(\.id).sorted() == [missing, flagged].sorted())

        // The same again: nothing new to say.
        let again = try f.service.reconcile()
        #expect(again.booksWithMissingFiles == [missing])
        #expect(again.booksRecovered.isEmpty)
        #expect(try [only, authorless, flagged].map { try #require(try f.store.book(id: $0)) } == noFileBooks)
    }

    // X6: a library of Audible-only books alone has nothing to report and nothing to write.
    @Test func X6_aLibraryOfOnlyAudibleBooksIsClean() throws {
        let f = try F()
        _ = try addAudible(f, Self.catalogue("One", "Ann Author", asin: "B0ONE00001"),
                           copy: ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: "B0ONE00001"))
        _ = try addAudible(f, Self.catalogue("Two", "Ann Author", asin: "B0TWO00001"),
                           copy: ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: "B0TWO00001"))
        #expect(try f.service.reconcile() == ReconcileReport())
        #expect(try f.store.books(needsAttention: true).isEmpty)
    }

    // X6: a flagged book with no files is never "recovered", even when everything else
    // about it looks like a filed book whose files came back.
    @Test func X6_aFlaggedBookWithNoFilesIsNeverRecovered() throws {
        let f = try F()
        var book = Book(
            metadata: Self.catalogue("Flagged", "Ann Author"), folderPath: "Ann Author/Flagged", needsAttention: true)
        book.externalCopies = [Self.audible]
        let id = try #require(try f.store.insert(book, files: []).id)
        let stored = try #require(try f.store.book(id: id))

        #expect(f.service.fileCheck(of: stored, files: []) == .asItWas)
        var unflagged = stored
        unflagged.needsAttention = false
        #expect(f.service.fileCheck(of: unflagged, files: []) == .asItWas)

        let report = try f.service.reconcile()
        #expect(report == ReconcileReport())
        #expect(try f.store.book(id: id) == stored)
    }

    // MARK: X7

    // X7: saving edits changes the database and the stored cover, and nothing on disk.
    @Test func X7_savingABookWithNoFiles() throws {
        let f = try F()
        let id = try addAudible(f, Self.catalogue("The Glass Tide", "Ines Calloway"))
        let before = try #require(try f.store.book(id: id))

        var edit = BookEdit(book: before, cover: .set(F.png))
        edit.metadata.title = "The Glass Tide: Revised"
        edit.metadata.authors = ["I. Calloway", "Second Author"]
        edit.metadata.series = "Tidewater Chronicles"
        edit.metadata.seriesNumber = "4"
        edit.metadata.durationSeconds = 5  // E2: not editable
        edit.metadata.pageCount = 99
        edit.tags = ["wishlist"]
        edit.rating = 4
        let outcomes = try f.service.save([edit])

        #expect(outcomes == [.saved(bookId: id, refiled: false, appOnlyFields: [], fileProblems: [])])
        let after = try #require(try f.store.book(id: id))
        #expect(after.title == "The Glass Tide: Revised")
        #expect(after.authors == ["I. Calloway", "Second Author"])
        #expect(after.series == "Tidewater Chronicles")
        #expect(after.seriesNumber == "4")
        #expect(after.tags == ["wishlist"])
        #expect(after.rating == 4)
        #expect(after.durationSeconds == Self.audibleSeconds)
        #expect(after.pageCount == nil)
        #expect(after.folderPath == nil)
        #expect(after.needsAttention == false)
        #expect(after.appOnlyFields.isEmpty)
        #expect(after.externalCopies == [Self.audible])
        #expect(try f.store.files(bookId: id).isEmpty)
        #expect(f.service.covers.image(for: id)?.data == F.png.data)
        // Never filed: no folder is made for the new title or author.
        #expect(f.libraryTree().isEmpty)

        // It is an ordinary edit: undo puts the details and the cover back.
        #expect(try f.service.undoLabel() == "Edit The Glass Tide: Revised")
        try f.service.undoLast()
        #expect(try f.store.book(id: id) == before)
        #expect(f.service.covers.image(for: id)?.data == F.jpeg.data)
        #expect(f.libraryTree().isEmpty)
        #expect(f.hiddenTree() == ["covers", "covers/\(id).jpg"])
    }

    // X7: a book with no files is not flagged for having no author or title to file by.
    @Test func X7_losingTheAuthorDoesNotFlagIt() throws {
        let f = try F()
        let id = try addAudible(f, Self.catalogue("The Glass Tide", "Ines Calloway"))
        var edit = BookEdit(book: try #require(try f.store.book(id: id)))
        edit.metadata.authors = []

        let outcomes = try f.service.save([edit])

        #expect(outcomes == [.saved(bookId: id, refiled: false, appOnlyFields: [], fileProblems: [])])
        let after = try #require(try f.store.book(id: id))
        #expect(after.authors.isEmpty)
        #expect(after.needsAttention == false)
        #expect(after.folderPath == nil)
        #expect(f.libraryTree().isEmpty)

        // And a flag it has for another reason is left alone by a save.
        try f.store.setNeedsAttention(flagging: [id], clearing: [])
        var second = BookEdit(book: try #require(try f.store.book(id: id)))
        second.metadata.authors = ["Ines Calloway"]
        _ = try f.service.save([second])
        #expect(try f.store.book(id: id)?.needsAttention == true)
        #expect(try f.store.book(id: id)?.authors == ["Ines Calloway"])
    }

    // X7: removing the cover removes the stored one; an edit that changes nothing is not recorded.
    @Test func X7_coverRemovalAndUnchangedEdits() throws {
        let f = try F()
        let id = try addAudible(f, Self.catalogue("The Glass Tide", "Ines Calloway"))
        let book = try #require(try f.store.book(id: id))

        #expect(try f.service.save([BookEdit(book: book)])
            == [.saved(bookId: id, refiled: false, appOnlyFields: [], fileProblems: [])])
        #expect(try f.store.lastBatch() == nil)
        #expect(f.hiddenTree() == ["covers", "covers/\(id).jpg"])

        #expect(try f.service.save([BookEdit(book: book, cover: .remove)])
            == [.saved(bookId: id, refiled: false, appOnlyFields: [], fileProblems: [])])
        #expect(f.service.covers.url(for: id) == nil)
        #expect(try f.store.book(id: id)?.appOnlyFields.isEmpty == true)
        try f.service.undoLast()
        #expect(f.service.covers.image(for: id)?.data == F.jpeg.data)
    }

    // X7: one save over a filed book and a book with no files: each by its own rules.
    @Test func X7_savedTogetherWithAFiledBook() throws {
        let f = try F()
        let tags = F.meta("Local Book", "Ann Author")
        let local = try f.importNew([try f.makeM4B("local.m4b", tags: tags)], tags)
        let only = try addAudible(f, Self.catalogue("The Glass Tide", "Ines Calloway"), cover: nil)

        var first = BookEdit(book: try #require(try f.store.book(id: local)))
        first.metadata.title = "Local Book Renamed"
        var second = BookEdit(book: try #require(try f.store.book(id: only)))
        second.metadata.title = "The Glass Tide Renamed"
        let outcomes = try f.service.save([first, second])

        #expect(outcomes == [
            .saved(bookId: local, refiled: true, appOnlyFields: [], fileProblems: []),
            .saved(bookId: only, refiled: false, appOnlyFields: [], fileProblems: []),
        ])
        #expect(f.libraryTree() == [
            "Ann Author", "Ann Author/Local Book Renamed", "Ann Author/Local Book Renamed/Local Book Renamed.m4b",
        ])
        #expect(try f.store.book(id: only)?.title == "The Glass Tide Renamed")

        try f.service.undoLast()
        #expect(try f.store.book(id: only)?.title == "The Glass Tide")
        #expect(try f.store.book(id: local)?.title == "Local Book")
    }

    // MARK: X8

    // X8: a file whose tags carry the ASIN finds its Audible-only entry, whatever its title.
    @Test func X8_aFilesASINFindsItsAudibleEntry() throws {
        let f = try F()
        let id = try addAudible(f, Self.catalogue("The Glass Tide", "Ines Calloway"))
        var tags = F.meta("Glass Tide (Unabridged)", "I. Calloway")
        tags.asin = Self.asin
        let withASIN = try f.makeM4B("with.m4b", tags: tags)
        let sameTitle = try f.makeM4B("title.m4b", tags: F.meta("the glass tide", "ines calloway"))
        let unrelated = try f.makeM4B("other.m4b", tags: F.meta("Other", "Someone"))

        func match(_ url: URL) throws -> Int64? {
            let candidate = try #require(f.service.scan([url]).candidates.first)
            return try f.service.existingMatch(for: candidate)?.id
        }
        #expect(try match(withASIN) == id)
        #expect(try match(sameTitle) == id)
        #expect(try match(unrelated) == nil)
    }

    // MARK: X9

    // X9: files arriving for an Audible-only book are filed from the book's own details.
    @Test func X9_importingIntoABookWithNoFiles() throws {
        let f = try F()
        let id = try addAudible(f, Self.catalogue("The Glass Tide", "Ines Calloway"))
        let before = try #require(try f.store.book(id: id))
        // The files say something else about themselves, and the audio has its own cover.
        let fileTags = F.meta("glass tide rip", "Unknown Artist")
        let audio = try f.makeM4B("glass.m4b", tags: fileTags, cover: F.png, seconds: 2)
        let ebook = try f.makeEPUB("glass.epub")
        let extra = try f.makePDF("map.pdf")
        let seconds = try duration(f, audio)

        let result = try f.service.importItems([
            ImportItem(
                candidate: f.candidate([audio, ebook, extra], fileTags, roles: [extra: .extra]),
                target: .existing(bookId: id), cover: .set(F.png)),
        ])

        #expect(try f.importedId(try #require(result.outcomes.first)) == id)
        // Filed exactly as a new book with the book's details would be.
        #expect(f.service.plannedFolder(for: before.metadata) == Self.glassFolder)
        #expect(f.libraryTree() == [
            "Ines Calloway", "Ines Calloway/The Series", Self.glassFolder,
            "\(Self.glassFolder)/Extras", "\(Self.glassFolder)/Extras/map.pdf",
            "\(Self.glassFolder)/The Glass Tide.epub", "\(Self.glassFolder)/The Glass Tide.m4b",
        ])
        #expect(f.inboxTree().isEmpty)

        let after = try #require(try f.store.book(id: id))
        var expected = before
        expected.folderPath = Self.glassFolder
        expected.durationSeconds = seconds  // X10
        expected.appOnlyFields = after.appOnlyFields
        #expect(after == expected)
        #expect(after.externalCopies == [Self.audible])
        #expect(after.needsAttention == false)
        #expect(after.appOnlyFields.isEmpty)
        #expect(after.durationSeconds != Self.audibleSeconds)
        let rows = try f.store.files(bookId: id)
        #expect(rows.map(\.path) == [
            "\(Self.glassFolder)/The Glass Tide.m4b", "\(Self.glassFolder)/The Glass Tide.epub",
            "\(Self.glassFolder)/Extras/map.pdf",
        ])
        #expect(rows.map(\.role) == [.audio, .ebook, .extra])
        #expect(rows.allSatisfy { $0.writeProblem == nil })

        // The book's details went into the files, not the item's; and the book's stored
        // cover, not the item's and not the file's own.
        let filedAudio = f.lib("\(Self.glassFolder)/The Glass Tide.m4b")
        #expect(try f.tags(filedAudio) == details(before))
        #expect(try f.io.read(filedAudio).cover?.data == F.jpeg.data)
        let filedEbook = f.lib("\(Self.glassFolder)/The Glass Tide.epub")
        #expect(try f.tags(filedEbook).title == "The Glass Tide")
        #expect(try f.tags(filedEbook).authors == ["Ines Calloway"])
        #expect(try f.io.read(filedEbook).cover?.data == F.jpeg.data)
        #expect(f.service.covers.image(for: id)?.data == F.jpeg.data)

        // It is still in every list it was in.
        #expect(try f.store.books(ownedOn: .audible).map(\.id) == [id])
        #expect(try f.store.books(having: .audio).map(\.id) == [id])
        #expect(try f.service.reconcile() == ReconcileReport())
    }

    // X9: undo takes the files back out and leaves the no-file entry exactly as it was.
    @Test func X9_undoRestoresTheEntryWithNoFiles() throws {
        let f = try F()
        let id = try addAudible(f, Self.catalogue("The Glass Tide", "Ines Calloway"))
        let before = try #require(try f.store.book(id: id))
        let fileTags = F.meta("glass tide rip", "Unknown Artist")
        let audio = try f.makeM4B("glass.m4b", tags: fileTags, cover: F.png)
        let ebook = try f.makeEPUB("glass.epub")
        let ebookTags = try f.tags(ebook)
        let ebookCover = try f.io.read(ebook).cover?.data
        let hiddenBefore = f.hiddenTree()

        #expect(try f.importedId(try importInto(f, id, [audio, ebook], tags: fileTags)) == id)
        #expect(try f.service.undoLabel() == "Import 1 book")
        #expect(try f.snapshot().books.map(\.bookBefore) == [before])
        try f.service.undoLast()

        // No folder left behind, the files where they came from with what they held.
        #expect(f.libraryTree().isEmpty)
        #expect(f.inboxTree() == ["glass.epub", "glass.m4b"])
        #expect(try f.tags(audio) == fileTags)
        #expect(try f.io.read(audio).cover?.data == F.png.data)
        #expect(try f.tags(ebook) == ebookTags)
        #expect(try f.io.read(ebook).cover?.data == ebookCover)
        // The entry: no files, no folder, the Audible length, its copies and its cover.
        #expect(try f.store.book(id: id) == before)
        #expect(try f.store.book(id: id)?.folderPath == nil)
        #expect(try f.store.book(id: id)?.durationSeconds == Self.audibleSeconds)
        #expect(try f.store.files(bookId: id).isEmpty)
        #expect(try f.store.allFiles().isEmpty)
        #expect(f.service.covers.image(for: id)?.data == F.jpeg.data)
        #expect(f.hiddenTree() == hiddenBefore)
        #expect(try f.service.undoLabel() == nil)
        #expect(try f.service.reconcile() == ReconcileReport())

        // And it can be done again.
        #expect(try f.importedId(try importInto(f, id, [audio, ebook], tags: fileTags)) == id)
        #expect(exists(f.lib("\(Self.glassFolder)/The Glass Tide.m4b")))
    }

    // X9: with no stored cover the files keep their own, and the book takes the first of them;
    // undo takes that cover away again.
    @Test func X9_aBookWithoutACoverTakesTheFiles() throws {
        let f = try F()
        let id = try addAudible(f, Self.catalogue("The Glass Tide", "Ines Calloway"), cover: nil)
        let before = try #require(try f.store.book(id: id))
        let fileTags = F.meta("glass tide rip", "Unknown Artist")
        let audio = try f.makeM4B("glass.m4b", tags: fileTags, cover: F.png)

        // The item's own cover choice is ignored, as for any book already in the library.
        #expect(try f.importedId(try importInto(f, id, [audio], tags: fileTags, cover: .set(F.jpeg))) == id)

        let filed = f.lib("\(Self.glassFolder)/The Glass Tide.m4b")
        #expect(try f.io.read(filed).cover?.data == F.png.data)
        #expect(f.service.covers.image(for: id)?.data == F.png.data)
        #expect(try f.store.book(id: id)?.appOnlyFields.isEmpty == true)

        try f.service.undoLast()
        #expect(f.service.covers.url(for: id) == nil)
        #expect(try f.store.book(id: id) == before)
        #expect(f.libraryTree().isEmpty)
        #expect(f.hiddenTree().filter { $0 != "covers" }.isEmpty)
        #expect(try f.io.read(audio).cover?.data == F.png.data)
    }

    // X9: a cover the files cannot hold stays in the app only, and is listed as such.
    @Test func X9_aCoverTheFilesCannotHoldIsAppOnly() throws {
        let f = try F()
        let id = try addAudible(f, Self.catalogue("The Glass Tide", "Ines Calloway"))
        let pdf = try f.makePDF("glass.pdf")

        #expect(try f.importedId(try importInto(f, id, [pdf], tags: F.meta("x", "y"))) == id)

        let after = try #require(try f.store.book(id: id))
        #expect(after.folderPath == Self.glassFolder)
        #expect(after.appOnlyFields.contains(.cover))
        // Only an ebook arrived: the length is still the Audible edition's (X10).
        #expect(after.durationSeconds == Self.audibleSeconds)
        #expect(after.pageCount == 3)
        #expect(f.service.covers.image(for: id)?.data == F.jpeg.data)
        #expect(try f.tags(f.lib("\(Self.glassFolder)/The Glass Tide.pdf")).title == "The Glass Tide")
    }

    // X9: the folder is planned by the shared planner, so an author folder that is
    // already there is used as it is spelled.
    @Test func X9_anExistingFoldersCapitalisationIsAdopted() throws {
        let f = try F()
        let localTags = F.meta("Earlier Book", "ines calloway")
        _ = try f.importNew([try f.makeM4B("earlier.m4b", tags: localTags)], localTags)
        #expect(exists(f.lib("ines calloway/Earlier Book/Earlier Book.m4b")))
        let id = try addAudible(f, Self.catalogue("The Glass Tide", "Ines Calloway"))
        let book = try #require(try f.store.book(id: id))
        let planned = try #require(f.service.plannedFolder(for: book.metadata))
        #expect(planned == "ines calloway/The Series/2 - The Glass Tide")

        let audio = try f.makeM4B("glass.m4b", tags: F.meta("x", "y"))
        #expect(try f.importedId(try importInto(f, id, [audio], tags: F.meta("x", "y"))) == id)

        #expect(try f.store.book(id: id)?.folderPath == planned)
        #expect(try f.store.files(bookId: id).map(\.path) == ["\(planned)/The Glass Tide.m4b"])
        #expect(f.libraryTree().contains("\(planned)/The Glass Tide.m4b"))
        #expect(!f.libraryTree().contains("Ines Calloway"))
        #expect(try f.service.reconcile() == ReconcileReport())
    }

    // X9: a book that cannot be filed (no author) fails the item with a plain reason.
    @Test func X9_aBookWithNoAuthorCannotTakeFiles() throws {
        let f = try F()
        let id = try addAudible(
            f, BookMetadata(title: "Typed Title"), cover: F.jpeg,
            copy: ExternalCopy(kind: .audible, form: .audio, store: "uk"))
        let before = try #require(try f.store.book(id: id))
        let tags = F.meta("Typed Title", "File Author")
        let audio = try f.makeM4B("typed.m4b", tags: tags, cover: F.png)
        let bytes = try f.bytes(audio)

        let outcome = try importInto(f, id, [audio], tags: tags)

        let reason = try #require(isFailed(outcome))
        #expect(reason.contains("Typed Title"))
        #expect(reason.lowercased().contains("author"))
        #expect(try f.store.book(id: id) == before)
        #expect(try f.store.files(bookId: id).isEmpty)
        #expect(f.libraryTree().isEmpty)
        #expect(f.inboxTree() == ["typed.m4b"])
        #expect(try f.bytes(audio) == bytes)
        #expect(try f.store.lastBatch() == nil)
        #expect(f.hiddenTree() == ["covers", "covers/\(id).jpg"])

        // Once it has an author it can.
        var edit = BookEdit(book: before)
        edit.metadata.authors = ["Real Author"]
        _ = try f.service.save([edit])
        #expect(try f.importedId(try importInto(f, id, [audio], tags: tags)) == id)
        #expect(exists(f.lib("Real Author/Typed Title/Typed Title.m4b")))
        #expect(try f.tags(f.lib("Real Author/Typed Title/Typed Title.m4b")).authors == ["Real Author"])
    }

    // X9: all or nothing. A file that cannot be moved leaves the item exactly as it was.
    @Test func X9_aFailedMoveLeavesEverythingAsItWas() throws {
        let files = FailingFileManager()
        let f = try F(organiser: Organiser(fileManager: files))
        let id = try addAudible(f, Self.catalogue("The Glass Tide", "Ines Calloway"))
        let before = try #require(try f.store.book(id: id))
        let fileTags = F.meta("glass tide rip", "Unknown Artist")
        let audio = try f.makeM4B("glass.m4b", tags: fileTags, cover: F.png)
        let ebook = try f.makeEPUB("glass.epub")
        let audioBytes = try f.bytes(audio)
        let ebookBytes = try f.bytes(ebook)
        files.failMovesTo = [f.lib("\(Self.glassFolder)/The Glass Tide.epub").path]

        let outcome = try importInto(f, id, [audio, ebook], tags: fileTags)

        #expect(isFailed(outcome) != nil)
        #expect(try f.store.book(id: id) == before)
        #expect(try f.store.allFiles().isEmpty)
        #expect(f.libraryTree().isEmpty)
        #expect(f.inboxTree() == ["glass.epub", "glass.m4b"])
        #expect(try f.bytes(audio) == audioBytes)
        #expect(try f.bytes(ebook) == ebookBytes)
        #expect(try f.store.lastBatch() == nil)
        #expect(f.hiddenTree() == ["covers", "covers/\(id).jpg"])
    }

    // X9: a commit that fails is rolled back like any other import.
    @Test func X9_aFailedCommitIsRolledBack() throws {
        let f = try F()
        let id = try addAudible(f, Self.catalogue("The Glass Tide", "Ines Calloway"))
        let before = try #require(try f.store.book(id: id))
        let fileTags = F.meta("glass tide rip", "Unknown Artist")
        let audio = try f.makeM4B("glass.m4b", tags: fileTags, cover: F.png)
        f.service.beforeCommit = { throw Boom() }

        #expect(throws: Boom.self) { _ = try importInto(f, id, [audio], tags: fileTags) }

        f.service.beforeCommit = nil
        #expect(try f.store.book(id: id) == before)
        #expect(try f.store.allFiles().isEmpty)
        #expect(f.libraryTree().isEmpty)
        #expect(f.inboxTree() == ["glass.m4b"])
        #expect(try f.tags(audio) == fileTags)
        #expect(try f.io.read(audio).cover?.data == F.png.data)
        #expect(f.service.covers.image(for: id)?.data == F.jpeg.data)
        #expect(f.hiddenTree() == ["covers", "covers/\(id).jpg"])
        #expect(try f.store.lastBatch() == nil)
    }

    // X9: copying leaves the originals untouched; undo deletes the copies.
    @Test func X9_inCopyMode() throws {
        let f = try F()
        let id = try addAudible(f, Self.catalogue("The Glass Tide", "Ines Calloway"))
        let before = try #require(try f.store.book(id: id))
        let fileTags = F.meta("glass tide rip", "Unknown Artist")
        let audio = try f.makeM4B("glass.m4b", tags: fileTags, cover: F.png)
        let bytes = try f.bytes(audio)

        #expect(try f.importedId(try importInto(f, id, [audio], tags: fileTags, mode: .copy)) == id)

        #expect(try f.bytes(audio) == bytes)
        let filed = f.lib("\(Self.glassFolder)/The Glass Tide.m4b")
        #expect(try f.tags(filed) == details(before))
        #expect(try f.io.read(filed).cover?.data == F.jpeg.data)

        try f.service.undoLast()
        #expect(f.libraryTree().isEmpty)
        #expect(try f.bytes(audio) == bytes)
        #expect(try f.store.book(id: id) == before)
    }

    // X9: one book takes the files of one item per import, as any existing book.
    @Test func X9_twoItemsForTheSameBook() throws {
        let f = try F()
        let id = try addAudible(f, Self.catalogue("The Glass Tide", "Ines Calloway"))
        let tags = F.meta("x", "y")
        let one = try f.makeM4B("one.m4b", tags: tags)
        let two = try f.makeM4B("two.m4b", tags: tags)

        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([one], tags), target: .existing(bookId: id)),
            ImportItem(candidate: f.candidate([two], tags), target: .existing(bookId: id)),
        ])

        #expect(try f.importedId(result.outcomes[0]) == id)
        #expect(isFailed(result.outcomes[1]) == "Another item of this import already adds files to that book")
        #expect(f.inboxTree() == ["two.m4b"])
        #expect(try f.store.files(bookId: id).count == 1)
    }

    // X9 and after: once filed, it is an ordinary book. More files join it in its folder,
    // and an edit re-files it and writes its tags.
    @Test func X9_afterwardsItIsAnOrdinaryFiledBook() throws {
        let f = try F()
        let id = try addAudible(f, Self.catalogue("The Glass Tide", "Ines Calloway"))
        let tags = F.meta("x", "y")
        #expect(try f.importedId(try importInto(f, id, [try f.makeM4B("a.m4b", tags: tags)], tags: tags)) == id)
        #expect(try f.importedId(try importInto(f, id, [try f.makeEPUB("b.epub")], tags: tags)) == id)
        #expect(try f.store.files(bookId: id).map(\.path) == [
            "\(Self.glassFolder)/The Glass Tide.m4b", "\(Self.glassFolder)/The Glass Tide.epub",
        ])

        var edit = BookEdit(book: try #require(try f.store.book(id: id)))
        edit.metadata.series = nil
        edit.metadata.seriesNumber = nil
        let outcomes = try f.service.save([edit])
        guard case .saved(_, let refiled, _, let problems) = try #require(outcomes.first) else {
            Issue.record("expected .saved, got \(outcomes)")
            return
        }
        #expect(refiled)
        #expect(problems.isEmpty)
        #expect(exists(f.lib("Ines Calloway/The Glass Tide/The Glass Tide.m4b")))
        #expect(try f.tags(f.lib("Ines Calloway/The Glass Tide/The Glass Tide.m4b")).series == nil)
        #expect(try f.store.book(id: id)?.externalCopies == [Self.audible])
    }

    // MARK: X10

    // X10: the Audible length until there are audio files; then the files' total.
    @Test func X10_theLengthIsTheFilesOnceThereAreAudioFiles() throws {
        let f = try F()
        let id = try addAudible(f, Self.catalogue("The Glass Tide", "Ines Calloway"))
        #expect(try f.store.book(id: id)?.durationSeconds == Self.audibleSeconds)

        let tags = F.meta("x", "y")
        let parts = try f.makeMP3Parts(folder: "glass", tags: tags, count: 2, seconds: 2)
        let total = try parts.map { try duration(f, $0) }.reduce(0, +)
        #expect(total > 3)

        #expect(try f.importedId(try importInto(f, id, parts, tags: tags)) == id)

        let after = try #require(try f.store.book(id: id))
        #expect(after.durationSeconds == total)
        // Parts are named and numbered as any book's.
        let rows = try f.store.files(bookId: id)
        #expect(rows.count == 2)
        #expect(try rows.map { try f.track(f.store.url(for: $0)) } == ["1/2", "2/2"])

        // Undo: the Audible length again.
        try f.service.undoLast()
        #expect(try f.store.book(id: id)?.durationSeconds == Self.audibleSeconds)
    }

    // MARK: X11

    // X11: removing a book with no files trashes nothing, whatever is asked.
    @Test(arguments: [true, false])
    func X11_removingABookWithNoFilesTrashesNothing(moveFilesToTrash: Bool) throws {
        let f = try F()
        let tags = F.meta("Local Book", "Ann Author")
        let local = try f.importNew([try f.makeM4B("local.m4b", tags: tags)], tags)
        let id = try addAudible(f, Self.catalogue("The Glass Tide", "Ines Calloway"))
        let shelf = try #require(try f.store.createCollection(name: "Shelf").id)
        try f.store.add(bookId: id, toCollection: shelf)
        #expect(f.service.covers.url(for: id) != nil)
        let treeBefore = f.libraryTree()
        var trashCalls = 0
        f.service.trashItem = { _ in trashCalls += 1 }

        try f.service.removeBook(id: id, moveFilesToTrash: moveFilesToTrash)

        #expect(trashCalls == 0)
        #expect(try f.store.book(id: id) == nil)
        #expect(f.service.covers.url(for: id) == nil)
        #expect(f.hiddenTree().filter { $0.hasPrefix("covers/") }.isEmpty)
        #expect(try f.store.books(inCollection: shelf).isEmpty)
        #expect(try f.store.books().map(\.id) == [local])
        #expect(f.libraryTree() == treeBefore)
        #expect(try f.store.books(ownedOn: .audible).isEmpty)
        #expect(throws: LibraryError.bookNotFound(id)) {
            try f.service.removeBook(id: id, moveFilesToTrash: moveFilesToTrash)
        }
    }

    // X11: a book with files and copies is removed whole, as before.
    @Test func X11_aBookWithFilesAndCopiesIsRemovedWhole() throws {
        let f = try F()
        let tags = F.meta("Local Book", "Ann Author")
        let id = try f.importNew([try f.makeM4B("local.m4b", tags: tags)], tags)
        try f.service.setExternalCopies([Self.audible], for: id)
        var trashed: [String] = []
        f.service.trashItem = { url in
            trashed.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }

        try f.service.removeBook(id: id, moveFilesToTrash: true)

        #expect(trashed == ["Local Book.m4b"])
        #expect(try f.store.book(id: id) == nil)
        #expect(try f.store.books().isEmpty)
        #expect(f.libraryTree().isEmpty)
    }

    // X11: removing an Audible-only entry forgets an undo that involves it, as for any book.
    @Test func X11_removingForgetsAnUndoThatInvolvesIt() throws {
        let f = try F()
        let id = try addAudible(f, Self.catalogue("The Glass Tide", "Ines Calloway"))
        var edit = BookEdit(book: try #require(try f.store.book(id: id)))
        edit.metadata.title = "Renamed"
        _ = try f.service.save([edit])
        #expect(try f.service.undoLabel() != nil)
        f.service.trashItem = { _ in Issue.record("nothing to trash") }

        try f.service.removeBook(id: id, moveFilesToTrash: true)

        #expect(try f.service.undoLabel() == nil)
        #expect(try f.store.lastBatch() == nil)
        #expect(f.hiddenTree().filter { $0 != "covers" }.isEmpty)
    }

    // MARK: X12

    // X12: rewriting tags has nothing to write, says so, and records nothing.
    @Test func X12_rewriteTagsDoesNothing() throws {
        let f = try F()
        let id = try addAudible(f, Self.catalogue("The Glass Tide", "Ines Calloway"))
        let before = try #require(try f.store.book(id: id))
        let hiddenBefore = f.hiddenTree()

        let outcomes = try f.service.rewriteTags(for: [id])

        #expect(outcomes == [.saved(bookId: id, refiled: false, appOnlyFields: [], fileProblems: [])])
        #expect(try f.store.book(id: id) == before)
        #expect(try f.store.lastBatch() == nil)
        #expect(f.hiddenTree() == hiddenBefore)
        #expect(f.libraryTree().isEmpty)
    }

    // X12: together with a filed book, only the filed book is written and recorded.
    @Test func X12_rewriteTagsWithAFiledBook() throws {
        let f = try F()
        let tags = F.meta("Local Book", "Ann Author")
        let local = try f.importNew([try f.makeM4B("local.m4b", tags: tags)], tags)
        let id = try addAudible(f, Self.catalogue("The Glass Tide", "Ines Calloway"))
        let before = try #require(try f.store.book(id: id))
        // Another program changes the local file's tags.
        let filed = f.lib("Ann Author/Local Book/Local Book.m4b")
        try f.io.write(F.meta("Changed Elsewhere", "Ann Author"), to: filed)

        let outcomes = try f.service.rewriteTags(for: [id, local])

        #expect(outcomes == [
            .saved(bookId: id, refiled: false, appOnlyFields: [], fileProblems: []),
            .saved(bookId: local, refiled: false, appOnlyFields: [], fileProblems: []),
        ])
        #expect(try f.tags(filed).title == "Local Book")
        #expect(try f.store.book(id: id) == before)
        #expect(try f.snapshot().books.map(\.bookId) == [local])
    }

    // X12: the calls that take a file id cannot reach a book with no files.
    @Test func X12_thereIsNoFileToChange() throws {
        let f = try F()
        let id = try addAudible(f, Self.catalogue("The Glass Tide", "Ines Calloway"))
        let before = try #require(try f.store.book(id: id))
        let stray = try f.makeM4B("stray.m4b", tags: F.meta("x", "y"))

        #expect(throws: LibraryError.fileNotFound(id)) { try f.service.setRole(.extra, forFile: id) }
        #expect(throws: LibraryError.fileNotFound(id)) { try f.service.locateFile(fileId: id, at: stray) }

        #expect(try f.store.book(id: id) == before)
        #expect(exists(stray))
        #expect(f.libraryTree().isEmpty)
        #expect(try f.store.lastBatch() == nil)
    }

    // MARK: X13

    // X13: undo restores the book's details but keeps the copies it has now.
    @Test func X13_undoKeepsCopiesGainedSinceTheOperation() throws {
        let f = try F()
        let tags = F.meta("Local Book", "Ann Author")
        let id = try f.importNew([try f.makeM4B("local.m4b", tags: tags)], tags)
        var edit = BookEdit(book: try #require(try f.store.book(id: id)))
        edit.metadata.title = "Renamed Book"
        _ = try f.service.save([edit])
        #expect(try f.snapshot().books.first?.bookBefore?.externalCopies.isEmpty == true)

        // After the edit was recorded, the book is marked as also on Audible.
        try f.service.setExternalCopies([Self.audible], for: id)
        try f.service.setReadStatus(.finished, for: [id])

        try f.service.undoLast()

        let restored = try #require(try f.store.book(id: id))
        #expect(restored.title == "Local Book")
        #expect(restored.externalCopies == [Self.audible])
        #expect(restored.readStatus == .finished)
        #expect(exists(f.lib("Ann Author/Local Book/Local Book.m4b")))
        #expect(try f.tags(f.lib("Ann Author/Local Book/Local Book.m4b")).title == "Local Book")
        #expect(try f.store.books(ownedOn: .audible).map(\.id) == [id])
    }

    // X13: and it does not bring back copies the book has lost since.
    @Test func X13_undoDoesNotBringBackCopiesLostSince() throws {
        let f = try F()
        let tags = F.meta("Local Book", "Ann Author")
        let id = try f.importNew([try f.makeM4B("local.m4b", tags: tags)], tags)
        let ebook = ExternalCopy(kind: .audible, form: .ebook, store: "us", itemId: "B0EBOOK001")
        try f.service.setExternalCopies([Self.audible, ebook], for: id)
        var edit = BookEdit(book: try #require(try f.store.book(id: id)))
        edit.metadata.title = "Renamed Book"
        _ = try f.service.save([edit])
        #expect(try f.snapshot().books.first?.bookBefore?.externalCopies == [Self.audible, ebook])

        try f.service.setExternalCopies([ebook], for: id)
        try f.service.undoLast()
        #expect(try f.store.book(id: id)?.title == "Local Book")
        #expect(try f.store.book(id: id)?.externalCopies == [ebook])

        // Losing all of them, for a book that has files, stays lost too.
        var again = BookEdit(book: try #require(try f.store.book(id: id)))
        again.metadata.title = "Renamed Again"
        _ = try f.service.save([again])
        try f.service.setExternalCopies([], for: id)
        try f.service.undoLast()
        #expect(try f.store.book(id: id)?.title == "Local Book")
        #expect(try f.store.book(id: id)?.externalCopies.isEmpty == true)
    }

    // X13 with X9: undoing the import that gave an Audible-only book its files keeps the
    // copies it has now.
    @Test func X13_undoingTheJoiningImportKeepsTheCurrentCopies() throws {
        let f = try F()
        let id = try addAudible(f, Self.catalogue("The Glass Tide", "Ines Calloway"))
        let before = try #require(try f.store.book(id: id))
        let tags = F.meta("x", "y")
        #expect(try f.importedId(try importInto(f, id, [try f.makeM4B("a.m4b", tags: tags)], tags: tags)) == id)
        let other = ExternalCopy(kind: .audible, form: .audio, store: "us", itemId: Self.asin)
        try f.service.setExternalCopies([other], for: id)

        try f.service.undoLast()

        var expected = before
        expected.externalCopies = [other]
        #expect(try f.store.book(id: id) == expected)
        #expect(try f.store.files(bookId: id).isEmpty)
        #expect(f.libraryTree().isEmpty)
    }

    // X13 with X4: but undo never leaves an entry with no files and no copies. If the
    // copies were all removed while the book had files, the ones it had come back with
    // the no-file entry.
    @Test func X13_undoNeverLeavesAnEmptyEntry() throws {
        let f = try F()
        let id = try addAudible(f, Self.catalogue("The Glass Tide", "Ines Calloway"))
        let before = try #require(try f.store.book(id: id))
        let tags = F.meta("x", "y")
        #expect(try f.importedId(try importInto(f, id, [try f.makeM4B("a.m4b", tags: tags)], tags: tags)) == id)
        // Allowed: it has files now.
        try f.service.setExternalCopies([], for: id)
        #expect(try f.store.book(id: id)?.externalCopies.isEmpty == true)

        try f.service.undoLast()

        #expect(try f.store.book(id: id) == before)
        #expect(try f.store.book(id: id)?.externalCopies == [Self.audible])
        #expect(try f.store.files(bookId: id).isEmpty)
        #expect(f.libraryTree().isEmpty)
    }
}
