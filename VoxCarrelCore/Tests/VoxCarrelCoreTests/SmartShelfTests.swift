import Foundation
import GRDB
import Testing
@testable import VoxCarrelCore

/// SH1–SH9: smart shelves and the Up Next list.
@Suite struct SmartShelfTests {
    typealias F = LibraryFixture
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(
        _ title: String = "T", audio: Bool = false, ebook: Bool = false, groups: Set<GenreGroup> = [],
        _ change: (inout Book) -> Void = { _ in }
    ) -> ShelfBook {
        var book = Book(metadata: BookMetadata(title: title, authors: ["Ann Author"]), dateAdded: now.addingTimeInterval(-100 * 86_400))
        change(&book)
        return ShelfBook(book: book, hasAudio: audio, hasEbook: ebook, genreGroups: groups)
    }

    @Test func SH1_eachConditionAsksOneThing() {
        func met(_ condition: ShelfCondition, _ item: ShelfBook) -> Bool { condition.isMet(by: item, now: now) }
        #expect(met(.format(.audiobook), item(audio: true)) && !met(.format(.audiobook), item(ebook: true)))
        #expect(met(.format(.ebook), item(ebook: true)) && !met(.format(.both), item(ebook: true)))
        #expect(met(.format(.both), item(audio: true, ebook: true)))
        #expect(met(.status(.unread), item()) && !met(.status(.finished), item()))
        #expect(met(.genre("fantasy "), item { $0.genres = ["Horror", "Fantasy"] }) && !met(.genre("Fantasy"), item()))
        #expect(met(.genreGroup(.fiction), item(groups: [.fiction])) && !met(.genreGroup(.nonFiction), item(groups: [.fiction])))
        #expect(met(.author("ANN AUTHOR"), item()) && !met(.author("Bob"), item()))
        #expect(met(.narrator("Tom Hale"), item { $0.narrators = ["Tom Hale"] }))
        #expect(met(.series("Jack Ryan"), item { $0.series = "Jack Ryan" }) && !met(.series("Jack Ryan"), item()))
        #expect(met(.tag("book club"), item { $0.tags = ["Book Club"] }))
        #expect(met(.ratingAtLeast(4), item { $0.rating = 4 }) && !met(.ratingAtLeast(4), item { $0.rating = 3 }))
        #expect(met(.unrated, item()) && !met(.unrated, item { $0.rating = 1 }))
        #expect(met(.shorterThan(hours: 6), item { $0.durationSeconds = 5 * 3600 }))
        #expect(!met(.shorterThan(hours: 6), item { $0.durationSeconds = 7 * 3600 }))
        #expect(met(.longerThan(hours: 6), item { $0.durationSeconds = 7 * 3600 }))
        // No stated length is neither shorter nor longer than anything.
        #expect(!met(.shorterThan(hours: 6), item()) && !met(.longerThan(hours: 6), item()))
        // Pages, by the book's page count; a book with none has neither fewer nor more.
        #expect(met(.fewerPagesThan(300), item { $0.pageCount = 250 }))
        #expect(!met(.fewerPagesThan(300), item { $0.pageCount = 300 }))
        #expect(met(.morePagesThan(300), item { $0.pageCount = 301 }))
        #expect(!met(.morePagesThan(300), item { $0.pageCount = 300 }))
        #expect(!met(.fewerPagesThan(300), item()) && !met(.morePagesThan(1), item()))
        #expect(!met(.fewerPagesThan(300), item { $0.pageCount = 0 }))
        #expect(met(.yearFrom(2000), item { $0.year = 2000 }) && !met(.yearFrom(2000), item { $0.year = 1999 }))
        #expect(met(.yearTo(2000), item { $0.year = 2000 }) && !met(.yearTo(2000), item()))
        #expect(met(.addedWithin(days: 30), item { $0.dateAdded = self.now.addingTimeInterval(-29 * 86_400) }))
        #expect(!met(.addedWithin(days: 30), item()))
        #expect(met(.onAudible(false), item()) && !met(.onAudible(true), item()))
        #expect(met(.inASeries(true), item { $0.series = "S" }) && met(.inASeries(false), item { $0.series = "  " }))
        // A blank name asks for nothing that any book has.
        #expect(!met(.author("  "), item()))
    }

    @Test func SH2_aShelfWantsAllOfItsConditionsOrAnyOfThem() {
        let short = item(audio: true) { $0.durationSeconds = 3600 }
        let long = item(audio: true) { $0.durationSeconds = 20 * 3600 }
        var shelf = SmartShelf(name: "S", conditions: [.format(.audiobook), .shorterThan(hours: 6)])
        #expect(shelf.holds(short, now: now) && !shelf.holds(long, now: now))
        shelf.matchesAll = false
        #expect(shelf.holds(short, now: now) && shelf.holds(long, now: now))
        // A shelf that asks for nothing holds nothing.
        #expect(!SmartShelf(name: "Empty", conditions: []).holds(short, now: now))
        #expect(!SmartShelf(name: "Empty", matchesAll: false, conditions: []).holds(short, now: now))
    }

    @Test func SH3_aLibraryBeginsWithTheStarterShelvesAndKeepsWhatIsDoneToThem() throws {
        let f = try F()
        var shelves = try f.service.smartShelves()
        #expect(shelves.map(\.name) == SmartShelf.starters.map(\.name))
        #expect(shelves.map(\.conditions) == SmartShelf.starters.map(\.conditions))
        // A new one goes last and is given an id.
        let made = try #require(try f.service.saveSmartShelf(
            SmartShelf(name: "  Spies  ", matchesAll: false, conditions: [.genre("Thrillers & Spies"), .author("Mick Herron")])))
        #expect(made.id != nil && made.name == "Spies")
        shelves = try f.service.smartShelves()
        #expect(shelves.last == made)
        // Changing one keeps its place and its id.
        var first = shelves[0]
        first.name = "Quick Listens"
        first.conditions.append(.unrated)
        #expect(try f.service.saveSmartShelf(first) == first)
        #expect(try f.service.smartShelves().first == first)
        #expect(try f.service.smartShelves().count == 4)
        // A blank name is no shelf.
        #expect(try f.service.saveSmartShelf(SmartShelf(name: "   ", conditions: [.unrated])) == nil)
        try f.service.deleteSmartShelf(id: try #require(made.id))
        #expect(try f.service.smartShelves().map(\.name) == ["Quick Listens", "Recently Added", "Finished, Not Rated"])
        // Opened again, they are as they were left.
        let again = LibraryService(store: try LibraryStore(libraryRoot: f.root))
        #expect(try again.smartShelves().map(\.name) == ["Quick Listens", "Recently Added", "Finished, Not Rated"])
    }

    @Test func SH4_aShelfWhoseConditionsCannotBeReadIsListedAndHoldsNothing() throws {
        let f = try F()
        try f.store.dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO smartShelf (name, rule, position) VALUES ('From Later', ?, 9)",
                arguments: [#"{"conditions":[{"mood":{}}]}"#])
        }
        let later = try #require(try f.service.smartShelves().last)
        #expect(later.name == "From Later" && later.conditions.isEmpty)
        #expect(try f.service.books(on: later).isEmpty)
    }

    private func add(
        _ f: F, _ title: String, series: String? = nil, number: String? = nil, status: ReadStatus = .unread,
        _ change: (inout Book) -> Void = { _ in }
    ) throws -> Int64 {
        var metadata = BookMetadata(title: title, authors: ["Tom Clancy"])
        metadata.series = series
        metadata.seriesNumber = number
        var book = Book(metadata: metadata)
        book.readStatus = status
        change(&book)
        return try #require(try f.store.insert(book, files: []).id)
    }

    @Test func SH5_theBooksOnAShelfAreWorkedOutFromTheLibraryAsItIs() throws {
        let f = try F()
        let thriller = try add(f, "Slow Horses") { $0.genres = ["Thrillers & Spies"]; $0.durationSeconds = 5 * 3600 }
        _ = try add(f, "A History") { $0.genres = ["History"] }
        let fiction = SmartShelf(name: "Fiction", conditions: [.genreGroup(.fiction)])
        #expect(try f.service.books(on: fiction).map(\.title) == ["Slow Horses"])
        let either = SmartShelf(name: "Either", matchesAll: false, conditions: [.genre("History"), .shorterThan(hours: 6)])
        #expect(try f.service.books(on: either).map(\.title) == ["A History", "Slow Horses"])
        // It follows the library: finished, the book leaves a shelf of unread ones.
        let unread = SmartShelf(name: "Unread", conditions: [.status(.unread), .genreGroup(.fiction)])
        #expect(try f.service.books(on: unread).count == 1)
        try f.service.setReadStatus(.finished, for: [thriller])
        #expect(try f.service.books(on: unread).isEmpty)
    }

    @Test func SH6_aPlaceInASeriesIsItsNumber() {
        #expect(UpNextRules.place("3") == 3 && UpNextRules.place(" 2.5 ") == 2.5 && UpNextRules.place("1-3") == 1)
        #expect(UpNextRules.place(nil) == nil && UpNextRules.place("") == nil && UpNextRules.place("Prequel") == nil)
    }

    @Test func SH7_upNextIsWhatIsBeingReadThenTheNextOfEachSeriesBegunThenWhatWasPutThere() throws {
        let f = try F()
        let reading = try add(f, "Being Read", status: .inProgress)
        _ = try add(f, "Book One", series: "Saga", number: "1", status: .finished)
        let two = try add(f, "Book Two", series: "Saga", number: "2")
        _ = try add(f, "Book Three", series: "Saga", number: "3")
        // A series not begun, and one whose furthest book is still being read.
        _ = try add(f, "Other One", series: "Untouched", number: "1")
        _ = try add(f, "Mid One", series: "Midway", number: "1", status: .finished)
        let midTwo = try add(f, "Mid Two", series: "Midway", number: "2", status: .inProgress)
        _ = try add(f, "Mid Three", series: "Midway", number: "3")
        let loose = try add(f, "Loose Book")
        let done = try add(f, "Done Already", status: .finished)

        try f.service.addToUpNext([loose, done, two, loose])
        let list = try f.service.upNext()
        #expect(Set(list.inProgress.compactMap(\.id)) == [reading, midTwo])
        #expect(list.nextInSeries == [.book(try #require(try f.store.book(id: two)))])
        // In the order put there; a finished one is not shown.
        #expect(list.queued.compactMap(\.id) == [loose, two])
        // No book twice in the whole list.
        let ids = list.items.compactMap { item -> Int64? in if case .book(let book) = item { return book.id } else { return nil } }
        #expect(ids.count == Set(ids).count)
        #expect(ids.last == loose)
        #expect(try f.service.queuedForUpNext([loose, two, reading]) == [loose, two])

        // Finished, the book gives way to the one after it.
        try f.service.setReadStatus(.finished, for: [two])
        let after = try f.service.upNext()
        #expect(after.nextInSeries.count == 1)
        if case .book(let next)? = after.nextInSeries.first { #expect(next.title == "Book Three") } else { Issue.record("no next book") }
        #expect(after.queued.compactMap(\.id) == [loose])
        try f.service.removeFromUpNext([loose])
        #expect(try f.service.upNext().queued.isEmpty)
        // A book that is removed from the library leaves the list with it.
        try f.service.addToUpNext([loose])
        try f.store.dbQueue.write { db in try db.execute(sql: "DELETE FROM book WHERE id = ?", arguments: [loose]) }
        #expect(!(try f.store.upNextIds().contains(loose)))
    }

    @Test func SH8_theNextBookOfASeriesIsShownWhetherTheLibraryHasItOrNot() throws {
        let f = try F()
        _ = try add(f, "The Hunt for Red October", series: "Jack Ryan", number: "1", status: .finished) { $0.asin = "B000000001" }
        let four = try add(f, "Clear and Present Danger", series: "Jack Ryan", number: "4") { $0.asin = "B000000004" }
        try f.service.saveSeriesList(SeriesStoreTests.list(SeriesStoreTests.four), forSeries: "Jack Ryan", now: now)

        // Book 2 comes next, and the library lacks it.
        var list = try f.service.upNext()
        guard case .missing(let entry, let link)? = list.nextInSeries.first else {
            Issue.record("expected the book the library lacks, got \(list.nextInSeries)")
            return
        }
        #expect(entry.entry.preferred.title == "Patriot Games" && link.seriesName == "Jack Ryan")
        #expect(list.items.count == 1)

        // Hidden by the owner, it is passed over for the next one that is not.
        try f.service.setMissingEntry(id: entry.id, hidden: true)
        list = try f.service.upNext()
        if case .missing(let next, _)? = list.nextInSeries.first { #expect(next.entry.preferred.title == "The Cardinal of the Kremlin") } else {
            Issue.record("expected book 3, got \(list.nextInSeries)")
        }
        // With 2 and 3 both hidden, the one the library has comes next.
        if case .missing(let next, _)? = list.nextInSeries.first { try f.service.setMissingEntry(id: next.id, hidden: true) }
        list = try f.service.upNext()
        #expect(list.nextInSeries == [.book(try #require(try f.store.book(id: four)))])
    }

    @Test func SH9_nothingComesAfterTheLastBookAndABookWithNoNumberHasNoPlace() throws {
        let f = try F()
        _ = try add(f, "Only", series: "Short", number: "1", status: .finished)
        _ = try add(f, "Unnumbered", series: "Short")
        _ = try add(f, "Earlier", series: "Late Start", number: "1")
        _ = try add(f, "Later", series: "Late Start", number: "2", status: .finished)
        #expect(try f.service.upNext().nextInSeries.isEmpty)
    }
}
