import Foundation
import Testing
@testable import VoxCarrelCore

/// HB1–HB7: books the owner keeps out of sight.
@Suite struct HiddenBookTests {
    typealias F = LibraryFixture

    /// Two books alike in every way that a list could find them by; the second is hidden.
    private func pair(_ f: F) throws -> (shown: Int64, hidden: Int64) {
        func add(_ title: String, asin: String) throws -> Int64 {
            var metadata = BookMetadata(title: title, authors: ["Ann Author"])
            metadata.narrators = ["Ned Narrator"]
            metadata.series = "The Saga"
            metadata.genres = ["Fantasy"]
            metadata.durationSeconds = 3600
            var book = Book(metadata: metadata, folderPath: nil, needsAttention: false, dateAdded: Date())
            book.externalCopies = [ExternalCopy(kind: .audible, form: .audio, itemId: asin), ExternalCopy(kind: .kindle, form: .ebook, itemId: "K" + asin)]
            let id = try #require(try f.store.insert(book, files: []).id)
            _ = try f.service.addHighlight(text: "A passage about lighthouses.", note: nil, toBook: id)
            try f.store.addToUpNext([id])
            return id
        }
        let shown = try add("Open Water", asin: "B0SHOWN001")
        let hidden = try add("Closed Door", asin: "B0HIDDEN01")
        let collection = try f.store.createCollection(name: "Both")
        try f.store.add(bookId: shown, toCollection: try #require(collection.id))
        try f.store.add(bookId: hidden, toCollection: try #require(collection.id))
        try f.store.setHidden(true, bookIds: [hidden, 987_654])
        return (shown, hidden)
    }

    @Test func HB1_aHiddenBookIsLeftOutOfEveryListCountAndSearchThatIsShown() throws {
        let f = try F()
        let (shown, hidden) = try pair(f)
        let collection = try #require(try f.store.collections().first?.id)
        try BookScope.visible { () throws -> Void in
            #expect(try f.store.books().compactMap(\.id) == [shown])
            #expect(try f.store.books(having: .audio).compactMap(\.id) == [shown])
            #expect(try f.store.books(readStatus: .unread).compactMap(\.id) == [shown])
            #expect(try f.store.books(ownedOn: .kindle).compactMap(\.id) == [shown])
            #expect(try f.store.search("door").isEmpty && f.store.search("ann").compactMap(\.id) == [shown])
            #expect(try f.store.books(where: .series, equals: "The Saga").compactMap(\.id) == [shown])
            #expect(try f.store.books(where: .authors, equals: "Ann Author").compactMap(\.id) == [shown])
            #expect(try f.store.books(inCollection: collection).compactMap(\.id) == [shown])
            #expect(try f.store.bookIds(inGenre: "Fantasy") == [shown])
            #expect(try f.store.bookIds(inGroup: .fiction) == [shown])
            #expect(try f.store.genreList().first { $0.name == "Fantasy" }?.bookCount == 1)
            #expect(try f.store.highlightCounts() == [shown: 1])
            #expect(try f.store.bookIds(withHighlightsMatching: "lighthouses") == [shown])
            #expect(try f.service.booksWithHighlights().compactMap(\.id) == [shown])
            #expect(try f.store.upNextIds() == [shown])
            #expect(try f.store.totalAudioSeconds() == 3600)
            #expect(try f.service.upNext().items.count == 1)
            for shelf in try f.service.smartShelves() {
                #expect(try !f.service.books(on: shelf).contains { $0.id == hidden })
            }
        }
        // The hidden ones are asked for by name, in any scope.
        #expect(try f.store.hiddenBooks().compactMap(\.id) == [hidden] && f.store.hiddenBookCount() == 1)
        try BookScope.visible { () throws -> Void in
            #expect(try f.store.hiddenBooks().compactMap(\.id) == [hidden])
            #expect(try f.store.book(id: hidden)?.isHidden == true)
            #expect(try f.store.highlights(forBook: hidden).count == 1)
        }
    }

    @Test func HB2_aHiddenValueOnlyHiddenBooksHaveIsNotListed() throws {
        let f = try F()
        var metadata = BookMetadata(title: "Secret", authors: ["Only Hidden"])
        metadata.series = "Hidden Series"
        metadata.genres = ["Erotica"]
        let id = try #require(try f.store.insert(Book(metadata: metadata, folderPath: nil, needsAttention: false, dateAdded: Date()), files: []).id)
        #expect(try f.store.distinctValues(.authors) == ["Only Hidden"])
        try f.store.setHidden(true, bookIds: [id])
        try BookScope.visible { () throws -> Void in
            #expect(try f.store.distinctValues(.authors).isEmpty && f.store.distinctValues(.series).isEmpty)
            #expect(try f.store.bookIdsWithNoGenre().isEmpty)
            #expect(try f.store.genreList().allSatisfy { $0.bookCount == 0 })
        }
        #expect(try f.store.distinctValues(.series) == ["Hidden Series"])
    }

    @Test func HB3_theLibrarysOwnWorkSeesEveryBookSoAHiddenOneIsNotBroughtInTwice() throws {
        let f = try F()
        let (_, hidden) = try pair(f)
        #expect(try f.store.books().count == 2 && f.store.search("door").count == 1)
        #expect(try f.store.totalAudioSeconds() == 7200 && f.store.upNextIds().count == 2)
        // Its Kindle ID and its Audible ID are still known.
        var kindle = KindleOwnedBook(asin: "KB0HIDDEN01", title: "Closed Door (Another Edition)")
        kindle.authors = ["Somebody Else"]
        #expect(try f.service.bringInKindleLibrary([kindle], apply: true).changesNothing)
        var audible = AudibleOwnedBook(asin: "B0HIDDEN01", title: "Closed Door")
        audible.authors = ["Ann Author"]
        let report = try f.service.bringInAudibleLibrary([audible], store: .us, apply: true)
        #expect(report.added.isEmpty && report.alreadyThere == 1)
        // By title and author too.
        var again = KindleOwnedBook(asin: "KNEW", title: "Closed Door")
        again.authors = ["Ann Author"]
        #expect(try f.service.bringInKindleLibrary([again], apply: true).added.isEmpty)
        #expect(try f.store.books().count == 2)
        // And it stays hidden through all of it.
        #expect(try f.store.book(id: hidden)?.isHidden == true)
    }

    @Test func HB4_aBookBroughtBackIsListedAgainWithAllItHad() throws {
        let f = try F()
        let (shown, hidden) = try pair(f)
        let before = try #require(try f.store.book(id: hidden))
        try f.store.setHidden(false, bookIds: [hidden])
        var after = try #require(try f.store.book(id: hidden))
        #expect(!after.isHidden)
        after.isHidden = true
        #expect(after == before)
        try BookScope.visible { () throws -> Void in
            #expect(try Set(f.store.books().compactMap(\.id)) == [shown, hidden])
            #expect(try f.store.highlightCounts().count == 2)
        }
        #expect(try f.store.hiddenBooks().isEmpty)
    }

    @Test func HB5_anEditOfAHiddenBookLeavesItHiddenAndAnOldRecordReadsAsNotHidden() throws {
        let f = try F()
        let (_, hidden) = try pair(f)
        _ = try f.store.modifyBook(id: hidden) { book, _ in book.rating = 5 }
        #expect(try f.store.book(id: hidden)?.isHidden == true && f.store.book(id: hidden)?.rating == 5)
        // A book written down before there was hiding (an undo record, say).
        let old = try JSONSerialization.data(withJSONObject: ["title": "Old", "authors": ["A"]])
        #expect(try JSONDecoder().decode(Book.self, from: old).isHidden == false)
    }

    @Test func HB6_undoingAnEditMadeBeforeABookWasHiddenLeavesItHiddenAndDoesNotNameIt() throws {
        let f = try F()
        let (shown, hidden) = try pair(f)
        try f.store.setHidden(false, bookIds: [hidden])
        var edit = BookEdit(book: try #require(try f.store.book(id: hidden)))
        edit.metadata.title = "Closed Door Again"
        #expect(try f.service.save([edit]).count == 1)
        #expect(try f.service.undoLabel() == "Edit Closed Door Again")
        try f.store.setHidden(true, bookIds: [hidden])

        // Shown, the label does not name the book, by the title it has or the one it had.
        #expect(try BookScope.visible { try f.service.undoLabel() } == "Edit 1 book")
        #expect(try f.service.undoLabel() == "Edit Closed Door Again")

        _ = try f.service.undoLast()
        let back = try #require(try f.store.book(id: hidden))
        #expect(back.title == "Closed Door" && back.isHidden)

        // The other way round: a book brought back since stays in view.
        try f.store.setHidden(true, bookIds: [shown])
        var other = BookEdit(book: try #require(try f.store.book(id: shown)))
        other.metadata.title = "Open Water Again"
        _ = try f.service.save([other])
        #expect(try f.store.book(id: shown)?.isHidden == true)
        try f.store.setHidden(false, bookIds: [shown])
        #expect(try BookScope.visible { try f.service.undoLabel() } == "Edit Open Water Again")
        _ = try f.service.undoLast()
        #expect(try f.store.book(id: shown)?.isHidden == false)
    }

    @Test func HB7_aHiddenBookOfACheckedSeriesIsNotListedAsMissingFromIt() throws {
        let f = try F()
        func add(_ title: String, number: String, series: String? = "Jack Ryan", asin: String? = nil) throws -> Int64 {
            var metadata = BookMetadata(title: title, authors: ["Tom Clancy"])
            metadata.series = series
            metadata.seriesNumber = number
            metadata.asin = asin
            return try #require(try f.store.insert(Book(metadata: metadata), files: []).id)
        }
        let first = try add("The Hunt for Red October", number: "1")
        // One hidden book is found by its title, the other by its Audible ID though it
        // is filed under another series.
        let second = try add("Patriot Games", number: "2")
        let third = try add("Another Name Altogether", number: "9", series: "Elsewhere", asin: "B000000003")
        try f.service.saveSeriesList(SeriesStoreTests.list(SeriesStoreTests.four), forSeries: "Jack Ryan", now: Date())
        try f.store.setHidden(true, bookIds: [second, third])

        let seen = try #require(try BookScope.visible { try f.service.seriesCompleteness(forSeries: "Jack Ryan") })
        #expect(seen.missing.map(\.entry.preferred.title) == ["Clear and Present Danger"])
        #expect(seen.ownedCount == 1 && seen.totalCount == 2)
        // Nor is one of them what comes next.
        try f.service.setReadStatus(.finished, for: [first])
        let next = try BookScope.visible { try f.service.upNext().items }
        #expect(next.count == 1)
        if case .missing(let entry, _)? = next.first {
            #expect(entry.entry.preferred.title == "Clear and Present Danger")
        } else {
            Issue.record("the next book of the series should be the one the library lacks")
        }

        // The library's own work still counts them.
        let all = try #require(try f.service.seriesCompleteness(forSeries: "Jack Ryan"))
        #expect(all.ownedCount == 3 && all.missing.count == 1)
    }
}
