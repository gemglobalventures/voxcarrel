import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

@Suite struct LibraryStoreTests {
    func makeStore() throws -> LibraryStore {
        try LibraryStore(libraryRoot: makeTempDir())
    }

    func hailMary() -> BookMetadata {
        var m = BookMetadata(title: "Project Hail Mary", authors: ["Andy Weir"])
        m.narrators = ["Ray Porter"]
        m.genre = "Science Fiction"
        m.year = 2021
        m.durationSeconds = 58_200
        m.pageCount = 496
        return m
    }

    func dune() -> BookMetadata {
        var m = BookMetadata(title: "Dune", authors: ["Frank Herbert"])
        m.series = "Dune"
        m.seriesNumber = "1"
        m.genre = "Science Fiction"
        return m
    }

    @Test func databaseFileIsCreatedInsideTheLibrary() throws {
        let root = try makeTempDir()
        _ = try LibraryStore(libraryRoot: root)
        #expect(exists(root.appendingPathComponent("VoxCarrel.sqlite")))
    }

    @Test func insertAssignsAnIdAndRoundTripsEveryField() throws {
        let store = try makeStore()
        var book = Book(metadata: hailMary(), folderPath: "Andy Weir/Project Hail Mary")
        book.tags = ["favourite"]
        book.rating = 5

        let saved = try store.insert(book, files: [
            BookFile(path: "Andy Weir/Project Hail Mary/Project Hail Mary.m4b",
                     format: .m4b, role: .audio, position: 0),
            BookFile(path: "Andy Weir/Project Hail Mary/Project Hail Mary.epub",
                     format: .epub, role: .ebook, position: 1),
            BookFile(path: "Andy Weir/Project Hail Mary/Extras/Star Map.pdf",
                     format: .pdf, role: .extra, position: 2),
        ])

        let id = try #require(saved.id)
        let fetched = try #require(try store.book(id: id))
        #expect(fetched.metadata == hailMary())
        #expect(fetched.tags == ["favourite"])
        #expect(fetched.rating == 5)
        #expect(fetched.folderPath == "Andy Weir/Project Hail Mary")
        #expect(fetched.needsAttention == false)

        let files = try store.files(bookId: id)
        #expect(files.map(\.role) == [.audio, .ebook, .extra])
        #expect(files.map(\.format) == [.m4b, .epub, .pdf])
        #expect(files.allSatisfy { $0.bookId == id })
    }

    @Test func updateChangesStoredValues() throws {
        let store = try makeStore()
        var book = try store.insert(Book(metadata: dune()), files: [])
        book.metadata.title = "Dune (Revised)"
        book.needsAttention = true

        try store.update(book)

        let bookId = try #require(book.id)
        let fetched = try #require(try store.book(id: bookId))
        #expect(fetched.title == "Dune (Revised)")
        #expect(fetched.needsAttention == true)
    }

    @Test func replaceFilesSwapsTheFileListInOrder() throws {
        let store = try makeStore()
        let book = try store.insert(Book(metadata: dune()), files: [
            BookFile(path: "/in/a.mp3", format: .mp3, role: .audio, position: 0),
        ])
        let id = try #require(book.id)

        try store.replaceFiles(bookId: id, files: [
            BookFile(path: "x/02.mp3", format: .mp3, role: .audio, position: 1),
            BookFile(path: "x/01.mp3", format: .mp3, role: .audio, position: 0),
        ])

        #expect(try store.files(bookId: id).map(\.path) == ["x/01.mp3", "x/02.mp3"])
    }

    @Test func deletingABookDeletesItsFiles() throws {
        let store = try makeStore()
        let book = try store.insert(Book(metadata: dune()), files: [
            BookFile(path: "a.epub", format: .epub, role: .ebook, position: 0),
        ])
        let id = try #require(book.id)

        try store.deleteBook(id: id)

        #expect(try store.book(id: id) == nil)
        #expect(try store.files(bookId: id).isEmpty)
    }

    @Test func booksAreListedByTitleAndFilteredByFormAndAttention() throws {
        let store = try makeStore()
        // Both audio and ebook, with an extra PDF.
        try store.insert(Book(metadata: hailMary()), files: [
            BookFile(path: "phm.m4b", format: .m4b, role: .audio, position: 0),
            BookFile(path: "phm.epub", format: .epub, role: .ebook, position: 1),
            BookFile(path: "Extras/map.pdf", format: .pdf, role: .extra, position: 2),
        ])
        // Ebook only.
        try store.insert(Book(metadata: dune()), files: [
            BookFile(path: "dune.epub", format: .epub, role: .ebook, position: 0),
        ])
        // Audio only, needs attention.
        try store.insert(Book(metadata: BookMetadata(title: "apple"), needsAttention: true), files: [
            BookFile(path: "/in/apple.mp3", format: .mp3, role: .audio, position: 0),
        ])

        #expect(try store.books().map(\.title) == ["apple", "Dune", "Project Hail Mary"])
        #expect(try store.books(having: .audio).map(\.title) == ["apple", "Project Hail Mary"])
        #expect(try store.books(having: .ebook).map(\.title) == ["Dune", "Project Hail Mary"])
        #expect(try store.books(having: .extra).map(\.title) == ["Project Hail Mary"])
        #expect(try store.books(needsAttention: true).map(\.title) == ["apple"])
        #expect(try store.books(having: .audio, needsAttention: false).map(\.title)
            == ["Project Hail Mary"])
    }

    @Test func readStatusSetsAndClearsItsDates() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let finish = Date(timeIntervalSince1970: 1_800_500_000)
        var book = Book(metadata: dune())
        #expect(book.readStatus == .unread)
        #expect(book.dateStarted == nil)

        book.setReadStatus(.inProgress, on: start)
        #expect(book.readStatus == .inProgress)
        #expect(book.dateStarted == start)
        #expect(book.dateFinished == nil)

        book.setReadStatus(.finished, on: finish)
        #expect(book.dateStarted == start)  // kept from when it was started
        #expect(book.dateFinished == finish)

        book.setReadStatus(.inProgress, on: finish)
        #expect(book.dateStarted == start)
        #expect(book.dateFinished == nil)  // no longer finished

        book.setReadStatus(.unread, on: finish)
        #expect(book.dateStarted == nil)
        #expect(book.dateFinished == nil)

        // Marking a never-started book finished sets both dates.
        book.setReadStatus(.finished, on: finish)
        #expect(book.dateStarted == finish)
        #expect(book.dateFinished == finish)
    }

    @Test func readStatusIsStoredAndFilterable() throws {
        let store = try makeStore()
        let finish = Date(timeIntervalSince1970: 1_800_500_000)
        var read = Book(metadata: dune())
        read.setReadStatus(.finished, on: finish)
        let saved = try store.insert(read, files: [])
        try store.insert(Book(metadata: hailMary()), files: [])

        let savedId = try #require(saved.id)
        let fetched = try #require(try store.book(id: savedId))
        #expect(fetched.readStatus == .finished)
        #expect(fetched.dateFinished == finish)
        #expect(try store.books(readStatus: .finished).map(\.title) == ["Dune"])
        #expect(try store.books(readStatus: .unread).map(\.title) == ["Project Hail Mary"])
        #expect(try store.books(readStatus: .inProgress).isEmpty)
    }

    @Test func searchMatchesTitleAuthorNarratorSeriesAndTagsByPrefix() throws {
        let store = try makeStore()
        var tagged = Book(metadata: hailMary())
        tagged.tags = ["roadtrip"]
        try store.insert(tagged, files: [])
        try store.insert(Book(metadata: dune()), files: [])

        #expect(try store.search("weir").map(\.title) == ["Project Hail Mary"])
        #expect(try store.search("ray por").map(\.title) == ["Project Hail Mary"])
        #expect(try store.search("roadt").map(\.title) == ["Project Hail Mary"])
        #expect(try store.search("herbert").map(\.title) == ["Dune"])
        #expect(try store.search("zzz").isEmpty)
        #expect(try store.search("  ").count == 2)
    }

    @Test func searchReflectsUpdates() throws {
        let store = try makeStore()
        var book = try store.insert(Book(metadata: dune()), files: [])
        book.metadata.authors = ["Brian Herbert"]
        try store.update(book)

        #expect(try store.search("frank").isEmpty)
        #expect(try store.search("brian").count == 1)
    }

    @Test func distinctValuesForBrowsing() throws {
        let store = try makeStore()
        try store.insert(Book(metadata: hailMary()), files: [])
        try store.insert(Book(metadata: dune()), files: [])
        var coAuthored = BookMetadata(title: "Good Omens", authors: ["Terry Pratchett", "Andy Weir"])
        coAuthored.genre = "Fantasy"
        try store.insert(Book(metadata: coAuthored), files: [])

        #expect(try store.distinctValues(.authors) == ["Andy Weir", "Frank Herbert", "Terry Pratchett"])
        #expect(try store.distinctValues(.narrators) == ["Ray Porter"])
        #expect(try store.distinctValues(.series) == ["Dune"])
        #expect(try store.distinctValues(.genre) == ["Fantasy", "Science Fiction"])
    }

    @Test func booksCanBeFetchedByBrowseValue() throws {
        let store = try makeStore()
        try store.insert(Book(metadata: hailMary()), files: [])
        try store.insert(Book(metadata: dune()), files: [])
        try store.insert(
            Book(metadata: BookMetadata(title: "Good Omens", authors: ["Terry Pratchett", "Andy Weir"])),
            files: [])

        #expect(try store.books(where: .authors, equals: "Andy Weir").map(\.title)
            == ["Good Omens", "Project Hail Mary"])
        #expect(try store.books(where: .series, equals: "Dune").map(\.title) == ["Dune"])
        #expect(try store.books(where: .genre, equals: "Science Fiction").count == 2)
    }

    @Test func collectionsHoldBooks() throws {
        let store = try makeStore()
        let a = try store.insert(Book(metadata: dune()), files: [])
        let b = try store.insert(Book(metadata: hailMary()), files: [])
        let toRead = try store.createCollection(name: "To Read")
        let collectionId = try #require(toRead.id)

        try store.add(bookId: try #require(a.id), toCollection: collectionId)
        try store.add(bookId: try #require(b.id), toCollection: collectionId)
        try store.add(bookId: try #require(b.id), toCollection: collectionId)  // no duplicate
        try store.remove(bookId: try #require(a.id), fromCollection: collectionId)

        #expect(try store.collections().map(\.name) == ["To Read"])
        #expect(try store.books(inCollection: collectionId).map(\.title) == ["Project Hail Mary"])
    }

    @Test func fileURLsResolveRelativeAndAbsolutePaths() throws {
        let root = try makeTempDir()
        let store = try LibraryStore(libraryRoot: root)

        let relative = BookFile(path: "A/T/T.epub", format: .epub, role: .ebook, position: 0)
        let absolute = BookFile(path: "/Users/me/Downloads/T.epub", format: .epub, role: .ebook, position: 0)

        #expect(store.url(for: relative).path == root.appendingPathComponent("A/T/T.epub").path)
        #expect(store.url(for: absolute).path == "/Users/me/Downloads/T.epub")
    }

    @Test func storedPathIsRelativeInsideTheLibraryAndAbsoluteOutside() throws {
        let root = try makeTempDir()
        let store = try LibraryStore(libraryRoot: root)

        #expect(store.storedPath(for: root.appendingPathComponent("A/T/T.epub")) == "A/T/T.epub")
        #expect(store.storedPath(for: URL(fileURLWithPath: "/Users/me/T.epub")) == "/Users/me/T.epub")
    }

    @Test func reopeningTheLibraryKeepsTheData() throws {
        let root = try makeTempDir()
        do {
            let store = try LibraryStore(libraryRoot: root)
            try store.insert(Book(metadata: dune()), files: [])
        }
        let reopened = try LibraryStore(libraryRoot: root)
        #expect(try reopened.books().map(\.title) == ["Dune"])
    }

    // MARK: Review fixes

    @Test func searchMatchesTitleAndASeriesNamedDifferently() throws {
        let store = try makeStore()
        var hobbit = BookMetadata(title: "The Hobbit", authors: ["J.R.R. Tolkien"])
        hobbit.series = "Middle-earth"
        try store.insert(Book(metadata: hobbit), files: [])
        try store.insert(Book(metadata: dune()), files: [])

        #expect(try store.search("hobb").map(\.title) == ["The Hobbit"])
        #expect(try store.search("middle").map(\.title) == ["The Hobbit"])
        #expect(try store.search("earth hobbit").map(\.title) == ["The Hobbit"])
    }

    @Test func searchCopesWithQuotesAndPunctuation() throws {
        let store = try makeStore()
        try store.insert(Book(metadata: dune()), files: [])
        try store.insert(
            Book(metadata: BookMetadata(title: "At Swim-Two-Birds", authors: ["Flann O'Brien"])),
            files: [])

        #expect(try store.search("\"herbert\"").map(\.title) == ["Dune"])
        #expect(try store.search("o'brien").map(\.title) == ["At Swim-Two-Birds"])
        #expect(try store.search("swim-two").map(\.title) == ["At Swim-Two-Birds"])
        for odd in ["\"dune", "dune*", "dune AND (", "NEAR(dune", "title:dune", "du\"ne ^", "-dune"] {
            _ = try store.search(odd)
        }
    }

    @Test func searchWithNoUsableTermsFindsNothingButBlankFindsEverything() throws {
        let store = try makeStore()
        try store.insert(Book(metadata: dune()), files: [])
        try store.insert(Book(metadata: hailMary()), files: [])

        #expect(try store.search("!!!").isEmpty)
        #expect(try store.search(" \"* ").isEmpty)
        #expect(try store.search("").count == 2)
        #expect(try store.search(" \n\t ").count == 2)
    }

    @Test func searchNoLongerFindsADeletedBook() throws {
        let store = try makeStore()
        let book = try store.insert(Book(metadata: dune()), files: [])
        try store.insert(Book(metadata: hailMary()), files: [])
        #expect(try store.search("herbert").count == 1)

        try store.deleteBook(id: try #require(book.id))

        #expect(try store.search("herbert").isEmpty)
        #expect(try store.search("dune").isEmpty)
        #expect(try store.search("weir").count == 1)
    }

    @Test func distinctValuesLeaveOutEmptyNames() throws {
        let store = try makeStore()
        var m = BookMetadata(title: "Anthology", authors: ["", "Ursula K. Le Guin"])
        m.narrators = [""]
        try store.insert(Book(metadata: m), files: [])

        #expect(try store.distinctValues(.authors) == ["Ursula K. Le Guin"])
        #expect(try store.distinctValues(.narrators).isEmpty)
    }

    @Test func insertGivesFilesFreshIdsEvenWhenTheyCarryOldOnes() throws {
        let store = try makeStore()
        let first = try store.insert(
            Book(metadata: dune()),
            files: [BookFile(path: "A/T/T.epub", format: .epub, role: .ebook, position: 0)])
        let stored = try store.files(bookId: try #require(first.id))

        let second = try store.insert(Book(metadata: hailMary()), files: stored)

        #expect(try store.files(bookId: try #require(first.id)).count == 1)
        let copies = try store.files(bookId: try #require(second.id))
        #expect(copies.map(\.path) == ["A/T/T.epub"])
        #expect(copies.first?.id != stored.first?.id)
    }
}

