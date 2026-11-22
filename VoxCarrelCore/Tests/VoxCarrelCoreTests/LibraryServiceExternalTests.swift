import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// Plan 6, Task 2: adding and marking books owned elsewhere (rules X1–X5, X8).
@Suite struct LibraryServiceExternalTests {
    typealias F = LibraryFixture

    static let asin = "B0AUDIBLE1"
    static let audible = ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: asin)

    /// Details as the Audible catalogue gives them.
    static func catalogue(_ title: String, _ author: String, asin: String? = LibraryServiceExternalTests.asin)
        -> BookMetadata
    {
        var m = F.fullMeta(title, author)
        m.asin = asin
        m.durationSeconds = 36_000
        return m
    }

    /// Everything about the library that adding or marking must leave alone when it fails.
    struct State: Equatable {
        var books: [Book]
        var files: [BookFile]
        var tree: [String]
        var hidden: [String]
        var batch: OperationBatch?
    }

    func state(_ f: F) throws -> State {
        State(
            books: try f.store.books(), files: try f.store.allFiles(), tree: f.libraryTree(),
            hidden: f.hiddenTree(), batch: try f.store.lastBatch())
    }

    // MARK: X1

    // X1: a book needs a title.
    @Test func X1_aBlankTitleIsRefused() throws {
        let f = try F()
        let before = try state(f)
        for title in ["", "   ", "\n\t "] {
            var thrown: LibraryError?
            do {
                _ = try f.service.addExternalBook(
                    metadata: Self.catalogue(title, "Ann Author"), cover: F.jpeg, copy: Self.audible)
            } catch let error as LibraryError {
                thrown = error
            }
            guard case .invalidDetails(let reason) = thrown else {
                Issue.record("expected .invalidDetails, got \(String(describing: thrown))")
                continue
            }
            #expect(reason.lowercased().contains("title"))
        }
        #expect(try state(f) == before)
        #expect(f.hiddenTree().isEmpty)
    }

    // X1: a copy is an audiobook or an ebook, never an extra.
    @Test func X1_anExtraIsNotAFormOfCopy() throws {
        let f = try F()
        let extra = ExternalCopy(kind: .audible, form: .extra, store: "uk", itemId: Self.asin)
        var thrown: LibraryError?
        do {
            _ = try f.service.addExternalBook(
                metadata: Self.catalogue("Some Book", "Ann Author"), cover: nil, copy: extra)
        } catch let error as LibraryError {
            thrown = error
        }
        guard case .invalidDetails = thrown else {
            Issue.record("expected .invalidDetails, got \(String(describing: thrown))")
            return
        }
        #expect(try f.store.books().isEmpty)

        // The same for a list of copies.
        let outcome = try f.service.addExternalBook(
            metadata: Self.catalogue("Some Book", "Ann Author"), cover: nil, copy: Self.audible)
        guard case .added(let id) = outcome else {
            Issue.record("expected .added, got \(outcome)")
            return
        }
        let before = try state(f)
        #expect(throws: LibraryError.self) { try f.service.setExternalCopies([Self.audible, extra], for: id) }
        #expect(try state(f) == before)
    }

    // MARK: X2

    // X2: a new entry with the details as given, no files, no folder, and its cover.
    @Test func X2_addsABookWithNoFiles() throws {
        let f = try F()
        var metadata = Self.catalogue("The Glass Tide", "Ines Calloway")
        metadata.pageCount = 321

        let outcome = try f.service.addExternalBook(metadata: metadata, cover: F.jpeg, copy: Self.audible)

        guard case .added(let id) = outcome else {
            Issue.record("expected .added, got \(outcome)")
            return
        }
        let book = try #require(try f.store.book(id: id))
        #expect(book.metadata == metadata)
        #expect(book.durationSeconds == 36_000)
        #expect(book.pageCount == 321)
        #expect(book.asin == Self.asin)
        #expect(book.externalCopies == [Self.audible])
        #expect(book.folderPath == nil)
        #expect(book.needsAttention == false)
        #expect(book.readStatus == .unread)
        #expect(book.dateStarted == nil)
        #expect(book.dateFinished == nil)
        #expect(book.appOnlyFields.isEmpty)
        #expect(book.tags.isEmpty)
        #expect(book.rating == 0)
        #expect(try f.store.files(bookId: id).isEmpty)
        // Nothing is filed; the only file written is the stored cover.
        #expect(f.libraryTree().isEmpty)
        #expect(f.hiddenTree() == ["covers", "covers/\(id).jpg"])
        #expect(f.service.covers.image(for: id)?.data == F.jpeg.data)
        // It is a full entry: in the lists, and found by search.
        #expect(try f.store.books(having: .audio).map(\.id) == [id])
        #expect(try f.store.books(ownedOn: .audible).map(\.id) == [id])
        #expect(try f.store.search("glass").map(\.id) == [id])
        #expect(try f.store.books(where: .authors, equals: "Ines Calloway").map(\.id) == [id])
        #expect(try f.store.books(where: .series, equals: "The Series").map(\.id) == [id])
    }

    // X2: without a cover none is stored; typed details with no ASIN and no author are fine.
    @Test func X2_addsABookTypedByHand() throws {
        let f = try F()
        let copy = ExternalCopy(kind: .audible, form: .audio, store: "us")

        let outcome = try f.service.addExternalBook(
            metadata: BookMetadata(title: "  Typed Title "), cover: nil, copy: copy)

        guard case .added(let id) = outcome else {
            Issue.record("expected .added, got \(outcome)")
            return
        }
        let book = try #require(try f.store.book(id: id))
        #expect(book.title == "  Typed Title ")
        #expect(book.authors.isEmpty)
        #expect(book.asin == nil)
        #expect(book.durationSeconds == nil)
        #expect(book.externalCopies == [copy])
        // No author, so it could not be filed: but it is never filed, and never flagged for it.
        #expect(book.needsAttention == false)
        #expect(f.hiddenTree().isEmpty)
        #expect(f.service.covers.url(for: id) == nil)
    }

    // X2: the Audible copy's item ID is the book's ASIN, whatever the details said.
    @Test func X2_theCopysItemIdBecomesTheASIN() throws {
        let f = try F()
        let outcome = try f.service.addExternalBook(
            metadata: Self.catalogue("Some Book", "Ann Author", asin: nil), cover: nil, copy: Self.audible)
        guard case .added(let id) = outcome else {
            Issue.record("expected .added, got \(outcome)")
            return
        }
        #expect(try f.store.book(id: id)?.asin == Self.asin)

        let second = try f.service.addExternalBook(
            metadata: Self.catalogue("Other Book", "Ann Author", asin: "B0DETAILS1"), cover: nil,
            copy: ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: " B0COPYID01 "))
        guard case .added(let otherId) = second else {
            Issue.record("expected .added, got \(second)")
            return
        }
        let other = try #require(try f.store.book(id: otherId))
        #expect(other.asin == "B0COPYID01")
        #expect(other.externalCopies.map(\.itemId) == ["B0COPYID01"])

        // A copy without an item ID leaves the ASIN from the details.
        let third = try f.service.addExternalBook(
            metadata: Self.catalogue("Third Book", "Ann Author", asin: "B0DETAILS3"), cover: nil,
            copy: ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: "  "))
        guard case .added(let thirdId) = third else {
            Issue.record("expected .added, got \(third)")
            return
        }
        let thirdBook = try #require(try f.store.book(id: thirdId))
        #expect(thirdBook.asin == "B0DETAILS3")
        #expect(thirdBook.externalCopies == [ExternalCopy(kind: .audible, form: .audio, store: "uk")])
    }

    // MARK: X3

    // X3: a book already in the library (same title and first author) is marked, not doubled,
    // and nothing else about it changes: not its details, cover, files or tags.
    @Test func X3_marksTheExistingBookInstead() throws {
        let f = try F()
        let tags = F.meta("The Glass Tide", "Ines Calloway")
        let source = try f.makeM4B("glass.m4b", tags: tags, cover: F.png)
        let id = try f.importNew([source], tags)
        try f.service.setReadStatus(.finished, for: [id])
        let filed = f.lib("Ines Calloway/The Glass Tide/The Glass Tide.m4b")
        let before = try #require(try f.store.book(id: id))
        let rowsBefore = try f.store.files(bookId: id)
        let bytesBefore = try f.bytes(filed)
        let dateBefore = try filed.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let coverBefore = f.service.covers.image(for: id)?.data
        #expect(coverBefore != nil)
        let treeBefore = f.libraryTree()
        let hiddenBefore = f.hiddenTree()

        var catalogue = Self.catalogue("the glass tide ", " INES CALLOWAY")
        catalogue.summary = "Audible's own words."
        let outcome = try f.service.addExternalBook(metadata: catalogue, cover: F.jpeg, copy: Self.audible)

        #expect(outcome == .markedExisting(bookId: id))
        #expect(try f.store.books().count == 1)
        let after = try #require(try f.store.book(id: id))
        #expect(after.externalCopies == [Self.audible])
        // The ASIN was empty, so it is filled in; nothing else differs.
        #expect(after.asin == Self.asin)
        var expected = before
        expected.externalCopies = [Self.audible]
        expected.asin = Self.asin
        #expect(after == expected)
        #expect(try f.store.files(bookId: id) == rowsBefore)
        #expect(try f.bytes(filed) == bytesBefore)
        #expect(try filed.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == dateBefore)
        #expect(f.service.covers.image(for: id)?.data == coverBefore)
        #expect(f.libraryTree() == treeBefore)
        #expect(f.hiddenTree() == hiddenBefore)

        // Adding it again changes nothing (M5).
        let again = try f.service.addExternalBook(metadata: catalogue, cover: F.jpeg, copy: Self.audible)
        #expect(again == .markedExisting(bookId: id))
        #expect(try f.store.book(id: id) == expected)
        // A second copy in another form joins the first.
        let ebook = ExternalCopy(kind: .audible, form: .ebook, store: "uk", itemId: Self.asin)
        #expect(try f.service.addExternalBook(metadata: catalogue, cover: nil, copy: ebook)
            == .markedExisting(bookId: id))
        #expect(try f.store.book(id: id)?.externalCopies == [Self.audible, ebook])
        #expect(try f.bytes(filed) == bytesBefore)
    }

    // X3: an ASIN the book already has is kept.
    @Test func X3_anExistingASINIsKept() throws {
        let f = try F()
        var tags = F.meta("The Glass Tide", "Ines Calloway")
        tags.asin = "B0FILEASIN"
        let id = try f.importNew([try f.makeM4B("glass.m4b", tags: tags)], tags)

        let outcome = try f.service.addExternalBook(
            metadata: Self.catalogue("The Glass Tide", "Ines Calloway"), cover: nil, copy: Self.audible)

        #expect(outcome == .markedExisting(bookId: id))
        let after = try #require(try f.store.book(id: id))
        #expect(after.asin == "B0FILEASIN")
        #expect(after.externalCopies == [Self.audible])
    }

    // X3: the same ASIN marks the book whatever its title; and an Audible-only entry is
    // found again by its ASIN, so the same catalogue result is never added twice.
    @Test func X3_theSameASINMarksTheSameBook() throws {
        let f = try F()
        var tags = F.meta("Glass Tide (Unabridged)", "I. Calloway")
        tags.asin = Self.asin.lowercased()
        let filedId = try f.importNew([try f.makeM4B("glass.m4b", tags: tags)], tags)

        #expect(try f.service.addExternalBook(
            metadata: Self.catalogue("The Glass Tide", "Ines Calloway"), cover: nil, copy: Self.audible)
            == .markedExisting(bookId: filedId))
        #expect(try f.store.book(id: filedId)?.title == "Glass Tide (Unabridged)")

        let first = try f.service.addExternalBook(
            metadata: Self.catalogue("Another Book", "Ann Author", asin: "B0ANOTHER1"), cover: F.jpeg,
            copy: ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: "B0ANOTHER1"))
        guard case .added(let onlyId) = first else {
            Issue.record("expected .added, got \(first)")
            return
        }
        let again = try f.service.addExternalBook(
            metadata: Self.catalogue("Another Book: Retitled", "Someone Else", asin: "B0ANOTHER1"), cover: F.png,
            copy: ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: "B0ANOTHER1"))
        #expect(again == .markedExisting(bookId: onlyId))
        #expect(try f.store.books().count == 2)
        // The entry keeps its own details and cover.
        #expect(try f.store.book(id: onlyId)?.title == "Another Book")
        #expect(f.service.covers.image(for: onlyId)?.data == F.jpeg.data)
    }

    // X3, X8: a book that needs attention is not matched, so a separate entry is added.
    @Test func X3_aFlaggedBookIsNotMarked() throws {
        let f = try F()
        let flagged = try #require(try f.store.insert(
            Book(metadata: F.meta("The Glass Tide", "Ines Calloway"), needsAttention: true),
            files: [BookFile(path: "/gone/glass.m4b", format: .m4b, role: .audio, position: 0)]).id)

        let outcome = try f.service.addExternalBook(
            metadata: Self.catalogue("The Glass Tide", "Ines Calloway"), cover: nil, copy: Self.audible)

        guard case .added(let id) = outcome else {
            Issue.record("expected .added, got \(outcome)")
            return
        }
        #expect(id != flagged)
        #expect(try f.store.book(id: flagged)?.externalCopies.isEmpty == true)
    }

    // MARK: X4

    // X4: the list is replaced as given.
    @Test func X4_setExternalCopiesReplacesTheList() throws {
        let f = try F()
        let tags = F.meta("Local Book", "Ann Author")
        let source = try f.makeM4B("local.m4b", tags: tags)
        let id = try f.importNew([source], tags)
        let filed = f.lib("Ann Author/Local Book/Local Book.m4b")
        let bytesBefore = try f.bytes(filed)
        let before = try #require(try f.store.book(id: id))
        let ebook = ExternalCopy(kind: .audible, form: .ebook, store: "us", itemId: "B0EBOOK001")

        try f.service.setExternalCopies([Self.audible, ebook, Self.audible], for: id)
        var expected = before
        expected.externalCopies = [Self.audible, ebook]
        // The decision "the ASIN is kept in step": an empty ASIN takes the Audible copy's ID.
        expected.asin = Self.asin
        #expect(try f.store.book(id: id) == expected)

        try f.service.setExternalCopies([ebook], for: id)
        expected.externalCopies = [ebook]
        #expect(try f.store.book(id: id) == expected)

        // A book with files can lose every copy.
        try f.service.setExternalCopies([], for: id)
        expected.externalCopies = []
        #expect(try f.store.book(id: id) == expected)
        #expect(try f.store.books(ownedOn: .audible).isEmpty)

        // No file was touched by any of it.
        #expect(try f.bytes(filed) == bytesBefore)
        #expect(try f.store.files(bookId: id).map(\.path) == ["Ann Author/Local Book/Local Book.m4b"])
    }

    // X4: a book with no files must stay owned somewhere.
    @Test func X4_aBookWithNoFilesCannotLoseItsLastCopy() throws {
        let f = try F()
        let outcome = try f.service.addExternalBook(
            metadata: Self.catalogue("Only On Audible", "Ann Author"), cover: F.jpeg, copy: Self.audible)
        guard case .added(let id) = outcome else {
            Issue.record("expected .added, got \(outcome)")
            return
        }
        let before = try state(f)

        #expect(throws: LibraryError.wouldLeaveNothing) { try f.service.setExternalCopies([], for: id) }
        #expect(try state(f) == before)

        // It can change which copy it has.
        let other = ExternalCopy(kind: .audible, form: .audio, store: "us", itemId: Self.asin)
        try f.service.setExternalCopies([other], for: id)
        #expect(try f.store.book(id: id)?.externalCopies == [other])
    }

    @Test func X4_anUnknownBookIsNotFound() throws {
        let f = try F()
        #expect(throws: LibraryError.bookNotFound(99)) { try f.service.setExternalCopies([Self.audible], for: 99) }
        #expect(throws: LibraryError.bookNotFound(99)) { try f.service.setExternalCopies([], for: 99) }
        #expect(try f.store.books().isEmpty)
    }

    // MARK: X5

    // X5: neither call is an undoable operation, and the recorded one is still undone as it was.
    @Test func X5_nothingIsRecordedAndTheRecordedOperationStays() throws {
        let f = try F()
        let tags = F.meta("Local Book", "Ann Author")
        let source = try f.makeM4B("local.m4b", tags: tags, cover: F.png)
        let id = try f.importNew([source], tags)
        var edit = BookEdit(book: try #require(try f.store.book(id: id)), cover: .set(F.jpeg))
        edit.metadata.title = "Renamed Book"
        _ = try f.service.save([edit])
        let batch = try #require(try f.store.lastBatch())
        let undoData = f.hiddenTree().filter { $0.hasPrefix("undo") }
        #expect(!undoData.isEmpty)

        let added = try f.service.addExternalBook(
            metadata: Self.catalogue("Only On Audible", "Ann Author"), cover: F.jpeg, copy: Self.audible)
        guard case .added(let onlyId) = added else {
            Issue.record("expected .added, got \(added)")
            return
        }
        let ebook = ExternalCopy(kind: .audible, form: .ebook, store: "uk", itemId: "B0LOCAL001")
        #expect(try f.service.addExternalBook(
            metadata: Self.catalogue("Renamed Book", "Ann Author", asin: "B0LOCAL001"), cover: nil, copy: ebook)
            == .markedExisting(bookId: id))
        try f.service.setExternalCopies([Self.audible, ebook], for: onlyId)

        #expect(try f.store.lastBatch() == batch)
        #expect(try f.service.undoLabel() == "Edit Renamed Book")
        #expect(f.hiddenTree().filter { $0.hasPrefix("undo") } == undoData)

        // The edit is still undone, files and all; the Audible entry is not part of it.
        try f.service.undoLast()
        #expect(f.libraryTree() == ["Ann Author", "Ann Author/Local Book", "Ann Author/Local Book/Local Book.m4b"])
        #expect(try f.store.book(id: id)?.title == "Local Book")
        #expect(try f.io.read(f.lib("Ann Author/Local Book/Local Book.m4b")).cover?.data == F.png.data)
        #expect(try f.store.book(id: onlyId)?.externalCopies == [Self.audible, ebook])
        #expect(try f.service.undoLabel() == nil)
    }

    // X5: with nothing recorded, nothing is recorded.
    @Test func X5_addingToAnEmptyLibraryRecordsNothing() throws {
        let f = try F()
        let added = try f.service.addExternalBook(
            metadata: Self.catalogue("Only On Audible", "Ann Author"), cover: F.jpeg, copy: Self.audible)
        guard case .added(let id) = added else {
            Issue.record("expected .added, got \(added)")
            return
        }
        try f.service.setExternalCopies([ExternalCopy(kind: .audible, form: .ebook)], for: id)
        #expect(try f.store.lastBatch() == nil)
        #expect(try f.service.undoLabel() == nil)
        #expect(throws: LibraryError.nothingToUndo) { try f.service.undoLast() }
        #expect(try f.store.book(id: id) != nil)
    }

    // MARK: X8

    // X8: the same Audible ID first (the book's own ASIN, or a copy's item ID), else the
    // title and first author; never a book that needs attention.
    @Test func X8_matchingByDetails() throws {
        let f = try F()
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        func add(
            _ title: String, _ author: String, asin: String? = nil, copies: [ExternalCopy] = [],
            daysLater: Double, needsAttention: Bool = false
        ) throws -> Int64 {
            var metadata = BookMetadata(title: title, authors: [author])
            metadata.asin = asin
            var book = Book(
                metadata: metadata, needsAttention: needsAttention,
                dateAdded: day.addingTimeInterval(daysLater * 86_400))
            book.externalCopies = copies
            return try #require(try f.store.insert(book, files: []).id)
        }
        func match(_ title: String, _ author: String?, asin: String? = nil) throws -> Int64? {
            var metadata = BookMetadata(title: title, authors: author.map { [$0] } ?? [])
            metadata.asin = asin
            // Both forms give the same answer.
            let byDetails = try f.service.existingMatch(for: metadata)?.id
            let byCandidate = try f.service.existingMatch(for: CandidateBook(files: [], metadata: metadata))?.id
            #expect(byDetails == byCandidate)
            return byDetails
        }
        let byTitle = try add("Dune", "Frank Herbert", daysLater: 1)
        let byASIN = try add("Dune (Unabridged)", "F. Herbert", asin: "B0DUNE0001", daysLater: 5)
        let byCopy = try add(
            "Children of Dune", "Frank Herbert",
            copies: [ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: "b0children")], daysLater: 3)
        _ = try add("Flagged", "Ann Author", asin: "B0FLAGGED1", daysLater: 0, needsAttention: true)

        // Without an ASIN: title and first author, exactly as before.
        #expect(try match(" dune ", "FRANK HERBERT") == byTitle)
        #expect(try match("Dune Messiah", "Frank Herbert") == nil)
        #expect(try match("Dune", nil) == nil)
        #expect(try match("", "Frank Herbert") == nil)
        // The ASIN wins over the title, ignoring case and surrounding spaces.
        #expect(try match("Dune", "Frank Herbert", asin: " b0dune0001 ") == byASIN)
        #expect(try match("Something Else Entirely", nil, asin: "B0DUNE0001") == byASIN)
        // A copy's item ID counts as the book's Audible ID.
        #expect(try match("Kinder des Wüstenplaneten", "Frank Herbert", asin: "B0CHILDREN") == byCopy)
        // An ASIN no book has falls back to the title and first author.
        #expect(try match("Dune", "Frank Herbert", asin: "B0UNKNOWN1") == byTitle)
        #expect(try match("Nothing", "Nobody", asin: "B0UNKNOWN1") == nil)
        // A blank ASIN is no ASIN: it never matches books that have none.
        #expect(try match("Nothing", "Nobody", asin: "  ") == nil)
        #expect(try match("Dune", "Frank Herbert", asin: "") == byTitle)
        // Flagged books are never matched, by either route.
        #expect(try match("Other", "Other", asin: "B0FLAGGED1") == nil)
        #expect(try match("Flagged", "Ann Author") == nil)

        // Of several books with the ASIN, the earliest added.
        let earlier = try add("Dune Again", "Frank Herbert", asin: "B0DUNE0001", daysLater: 2)
        #expect(try match("Whatever", "Whoever", asin: "B0DUNE0001") == earlier)
    }
}
