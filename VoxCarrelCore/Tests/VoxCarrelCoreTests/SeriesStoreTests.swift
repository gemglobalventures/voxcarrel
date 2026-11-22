import Foundation
import GRDB
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// A series' Audible list in the catalogue (rules SC20–SC27).
@Suite struct SeriesStoreTests {
    typealias F = LibraryFixture

    static let series = "Jack Ryan"
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000.123456)

    static func edition(
        _ asin: String, _ title: String, _ number: String?, minutes: Int? = 600, abridged: Bool? = false
    ) -> AudibleSeriesEdition {
        SeriesMatchTests.edition(asin, title, number, minutes: minutes, abridged: abridged)
    }

    static func list(_ editions: [AudibleSeriesEdition], id: String = "B0SERIES01", title: String = "A Jack Ryan Novel")
        -> AudibleSeriesList
    {
        AudibleSeriesList(ref: AudibleSeriesRef(id: id, title: title, number: nil, store: .uk), editions: editions)
    }

    /// Four books, numbered 1 to 4.
    static let four = [
        edition("B000000001", "The Hunt for Red October", "1"),
        edition("B000000002", "Patriot Games", "2"),
        edition("B000000003", "The Cardinal of the Kremlin", "3"),
        edition("B000000004", "Clear and Present Danger", "4"),
    ]

    /// Adds a book with no files to the catalogue; returns its id.
    @discardableResult
    private func add(
        _ f: F, _ title: String, number: String? = nil, series: String? = SeriesStoreTests.series, asin: String? = nil,
        copies: [ExternalCopy] = []
    ) throws -> Int64 {
        var metadata = BookMetadata(title: title, authors: ["Tom Clancy"])
        metadata.series = series
        metadata.seriesNumber = number
        metadata.asin = asin
        var book = Book(metadata: metadata)
        book.externalCopies = copies
        return try #require(try f.store.insert(book, files: []).id)
    }

    private func completeness(_ f: F, _ name: String = SeriesStoreTests.series) throws -> SeriesCompleteness {
        try #require(try f.service.seriesCompleteness(forSeries: name))
    }

    private func count(_ f: F, _ table: String) throws -> Int {
        try f.store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1 }
    }

    // MARK: SC20

    @Test func SC20_aSeriesIsTheOneTheSidebarLists() throws {
        let f = try F()
        try add(f, "The Hunt for Red October", number: "1")
        try add(f, "Patriot Games", number: "2", series: "jack ryan")
        try add(f, "Rainbow Six", number: "1", series: "John Clark")

        // Each name the sidebar lists is a series of its own, with the books it shows there.
        for name in try f.store.distinctValues(.series) {
            let shown = try f.store.books(where: .series, equals: name).compactMap(\.id).sorted()
            #expect(try f.service.librarySeriesBooks(named: name).map(\.id) == shown)
            #expect(shown.count == 1)
        }

        try f.service.saveSeriesList(Self.list(Self.four), forSeries: Self.series, now: now)
        #expect(try completeness(f).ownedCount == 1)
        #expect(try f.service.seriesCompleteness(forSeries: "jack ryan") == nil)
        #expect(try f.service.seriesCompleteness(forSeries: "John Clark") == nil)
        #expect(try f.service.seriesCompleteness(forSeries: "Jack Ryan ") == nil)
    }

    // MARK: SC21

    @Test func SC21_everyBookOfTheSeriesWithItsASINs() throws {
        let f = try F()
        let withFile = try #require(try f.store.insert(
            {
                var m = BookMetadata(title: "Patriot Games", authors: ["Tom Clancy"])
                m.series = Self.series
                m.seriesNumber = "2"
                m.asin = " B000000002 "
                return Book(metadata: m, folderPath: "Tom Clancy/Patriot Games")
            }(),
            files: [BookFile(path: "Tom Clancy/Patriot Games/Patriot Games.m4b", format: .m4b, role: .audio, position: 0)]).id)
        let elsewhere = try add(
            f, "The Hunt for Red October", number: "1", asin: "B000000001",
            copies: [
                ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: "B000000001"),
                ExternalCopy(kind: .audible, form: .ebook, store: "uk", itemId: "B00000000X"),
                ExternalCopy(kind: .audible, form: .audio, store: "us", itemId: nil),
            ])
        let bare = try add(f, "Red Rabbit")
        try add(f, "Rainbow Six", number: "1", series: "John Clark", asin: "B000000009")
        try add(f, "No Series", series: nil)

        let books = try f.service.librarySeriesBooks(named: Self.series)

        #expect(books == [
            LibrarySeriesBook(id: withFile, title: "Patriot Games", number: "2", asins: ["B000000002"]),
            LibrarySeriesBook(id: elsewhere, title: "The Hunt for Red October", number: "1", asins: ["B000000001", "B00000000X"]),
            LibrarySeriesBook(id: bare, title: "Red Rabbit", number: nil, asins: []),
        ])
        #expect(try f.service.librarySeriesBooks(named: "Nothing").isEmpty)
        #expect(try f.service.librarySeriesBooks(named: "").isEmpty)
    }

    // MARK: SC22

    @Test func SC22_theListIsStoredFoldedPreferringWhatTheLibraryHas() throws {
        let f = try F()
        try add(f, "Patriot Games", number: "2", copies: [ExternalCopy(kind: .audible, form: .audio, itemId: "b00000002a")])
        var editions = Self.four
        editions.append(Self.edition("B00000002A", "Patriot Games (Abridged)", "2", minutes: 200, abridged: true))
        editions[0] = AudibleSeriesEdition(
            asin: "B000000001", title: "The Hunt for Red October", number: "1", sort: 1, authors: ["Tom Clancy"],
            narrators: ["Scott Brick", "Another"], minutes: 1101, isAbridged: nil,
            releaseDate: Date(timeIntervalSince1970: 1_300_000_000))

        try f.service.saveSeriesList(Self.list(editions), forSeries: Self.series, now: now)

        let status = try completeness(f)
        #expect(status.link == SeriesLink(
            seriesName: Self.series, audibleSeriesId: "B0SERIES01", audibleSeriesTitle: "A Jack Ryan Novel",
            store: .uk, checkedAt: now))
        #expect(try count(f, "seriesEntry") == 4)
        // The edition the library has is the entry's preferred, and every edition is kept.
        let stored = try f.store.dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT title, asins, titles FROM seriesEntry WHERE number = '2'")
        }
        #expect(stored?["title"] == "Patriot Games (Abridged)")
        #expect(stored?["asins"] == #"["B00000002A","B000000002"]"#)
        #expect(stored?["titles"] == #"["Patriot Games (Abridged)","Patriot Games"]"#)
        // What is stored comes back as it was folded.
        let fresh = SeriesMatch.entries(from: editions, preferring: ["B00000002A"])
        #expect(status.missing.map(\.entry) == [fresh[0], fresh[2], fresh[3]])
        #expect(status.missing[0].entry.preferred == editions[0])
    }

    @Test func SC22_savingAgainReplacesTheLinkAndItsEntries() throws {
        let f = try F()
        try add(f, "Patriot Games", number: "2")
        try f.service.saveSeriesList(Self.list(Self.four), forSeries: Self.series, now: now)
        let later = now.addingTimeInterval(86_400.5)

        try f.service.saveSeriesList(
            Self.list(Array(Self.four.prefix(2)), id: "B0SERIES02", title: "Jack Ryan (chronological)"),
            forSeries: Self.series, now: later)

        let status = try completeness(f)
        #expect(status.link.audibleSeriesId == "B0SERIES02")
        #expect(status.link.audibleSeriesTitle == "Jack Ryan (chronological)")
        #expect(status.link.checkedAt == later)
        #expect(status.totalCount == 2)
        #expect(try count(f, "seriesLink") == 1)
        #expect(try count(f, "seriesEntry") == 2)
    }

    @Test func SC22_aHiddenEntryStaysHiddenWhileItIsStillInTheList() throws {
        let f = try F()
        try add(f, "Patriot Games", number: "2")
        try f.service.saveSeriesList(Self.list(Self.four), forSeries: Self.series, now: now)
        for entry in try completeness(f).missing { try f.service.setMissingEntry(id: entry.id, hidden: true) }

        // Number 1 comes back as "01" under another ASIN; number 3 with another number
        // and the same ASIN; number 4 with another number and another ASIN.
        try f.service.saveSeriesList(
            Self.list([
                Self.edition("B00000001N", "The Hunt for Red October", "01"),
                Self.four[1],
                Self.edition("B000000003", "The Cardinal of the Kremlin", "5"),
                Self.edition("B00000004N", "Clear and Present Danger", "6"),
            ]),
            forSeries: Self.series, now: now)

        let missing = try completeness(f).missing
        #expect(missing.map(\.entry.preferred.asin) == ["B00000001N", "B000000003", "B00000004N"])
        #expect(missing.map(\.isHidden) == [true, true, false])
    }

    /// A number says which book only within one Audible series: linked to another
    /// series, an entry stays hidden only when it is the edition that was hidden.
    @Test func SC22_aHiddenEntryIsNotKnownByItsNumberInAnotherAudibleSeries() throws {
        let f = try F()
        try add(f, "Patriot Games", number: "2")
        try f.service.saveSeriesList(Self.list(Self.four), forSeries: Self.series, now: now)
        for entry in try completeness(f).missing { try f.service.setMissingEntry(id: entry.id, hidden: true) }

        // Another series: its number 3 is another book, and the edition that was hidden
        // as number 4 is its number 7.
        let other = [
            Self.four[1],
            Self.edition("B00000009X", "Debt of Honor", "3"),
            Self.edition("B000000004", "Clear and Present Danger", "7"),
        ]
        try f.service.saveSeriesList(
            Self.list(other, id: "B0SERIES02", title: "A Jack Ryan Novel (chronological order)"),
            forSeries: Self.series, now: now)

        var missing = try completeness(f).missing
        #expect(missing.map(\.entry.preferred.asin) == ["B00000009X", "B000000004"])
        #expect(missing.map(\.isHidden) == [false, true])

        // The same ID in another store is another series too.
        try f.service.setMissingEntry(id: missing[0].id, hidden: true)
        var elsewhere = Self.list(
            [Self.four[1], Self.edition("B00000008X", "Executive Orders", "3")], id: "B0SERIES02")
        elsewhere.ref.store = .us
        try f.service.saveSeriesList(elsewhere, forSeries: Self.series, now: now)
        missing = try completeness(f).missing
        #expect(missing.map(\.entry.preferred.asin) == ["B00000008X"])
        #expect(missing.map(\.isHidden) == [false])
    }

    @Test func SC22_anEmptyListIsRefusedAndWhatWasStoredStays() throws {
        let f = try F()
        try add(f, "Patriot Games", number: "2")
        try f.service.saveSeriesList(Self.list(Self.four), forSeries: Self.series, now: now)
        let before = try completeness(f)

        #expect(throws: SeriesListError.emptyList) {
            try f.service.saveSeriesList(Self.list([]), forSeries: Self.series, now: now.addingTimeInterval(60))
        }

        #expect(try completeness(f) == before)
        // A series never saved is not linked by an empty list either.
        try add(f, "Rainbow Six", series: "John Clark")
        #expect(throws: SeriesListError.emptyList) {
            try f.service.saveSeriesList(Self.list([]), forSeries: "John Clark", now: now)
        }
        #expect(try f.service.seriesCompleteness(forSeries: "John Clark") == nil)
    }

    @Test func SC22_aListForASeriesNoBookIsInIsRefused() throws {
        let f = try F()
        try add(f, "Patriot Games", number: "2")

        #expect(throws: SeriesListError.noBooks) {
            try f.service.saveSeriesList(Self.list(Self.four), forSeries: "Nothing", now: now)
        }

        #expect(try count(f, "seriesLink") == 0)
        #expect(try count(f, "seriesEntry") == 0)
    }

    // MARK: SC23

    @Test func SC23_aBookAddedLaterMovesItsEntryFromMissingToOwned() throws {
        let f = try F()
        try add(f, "Patriot Games", number: "2")
        try f.service.saveSeriesList(Self.list(Self.four), forSeries: Self.series, now: now)
        var status = try completeness(f)
        #expect(status.ownedCount == 1)
        #expect(status.totalCount == 4)
        #expect(status.missing.map(\.entry.preferred.title) == [
            "The Hunt for Red October", "The Cardinal of the Kremlin", "Clear and Present Danger",
        ])
        #expect(status.missing.allSatisfy { !$0.isHidden })
        #expect(Set(status.missing.map(\.id)).count == 3)

        // By title, and by the ID of an Audible copy.
        try add(f, "the cardinal of the kremlin")
        try add(f, "Something Else", copies: [ExternalCopy(kind: .audible, form: .audio, itemId: "B000000004")])

        status = try completeness(f)
        #expect(status.ownedCount == 3)
        #expect(status.totalCount == 4)
        #expect(status.missing.map(\.entry.preferred.title) == ["The Hunt for Red October"])
        #expect(status.notInList.isEmpty)
    }

    @Test func SC23_hiddenEntriesAreListedButNotCounted() throws {
        let f = try F()
        try add(f, "Patriot Games", number: "2")
        try f.service.saveSeriesList(Self.list(Self.four), forSeries: Self.series, now: now)
        let third = try #require(try completeness(f).missing.first { $0.entry.number == "3" })

        try f.service.setMissingEntry(id: third.id, hidden: true)

        let status = try completeness(f)
        #expect(status.ownedCount == 1)
        #expect(status.totalCount == 3)
        #expect(status.missing.map(\.isHidden) == [false, true, false])
        #expect(status.ownedCount + status.missing.filter { !$0.isHidden }.count == status.totalCount)
    }

    @Test func SC23_numberDifferencesAndBooksNotInTheList() throws {
        let f = try F()
        let same = try add(f, "The Hunt for Red October", number: "01")
        let differs = try add(f, "Patriot Games", number: "3")
        let unnumbered = try add(f, "The Cardinal of the Kremlin")
        let stranger = try add(f, "Without Remorse", number: "6")

        try f.service.saveSeriesList(Self.list(Self.four), forSeries: Self.series, now: now)

        let status = try completeness(f)
        #expect(status.ownedCount == 3)
        #expect(status.numberDifferences == [differs: "2"])
        #expect(status.notInList == [stranger])
        #expect(status.numberDifferences[same] == nil && status.numberDifferences[unnumbered] == nil)
    }

    @Test func SC23_aSecondCopyOfAnOwnedBookIsNotCalledNotInTheList() throws {
        let f = try F()
        // The entry goes to the book that holds one of its ASINs. The others are the
        // same book again: two by its title, one by the ASIN of its other edition.
        try add(f, "Patriot Games", number: "2")
        try add(f, "Patriot Games!", number: "9")
        let owner = try add(f, "Patriot Games (Abridged)", number: "2", asin: " b00000002a ")
        try add(f, "Another Name Altogether", copies: [ExternalCopy(kind: .audible, form: .audio, itemId: "b000000002")])
        let stranger = try add(f, "Without Remorse")
        var editions = Self.four
        editions.append(Self.edition("B00000002A", "Patriot Games: A Jack Ryan Novel", "2", minutes: 200, abridged: true))
        try f.service.saveSeriesList(Self.list(editions), forSeries: Self.series, now: now)

        let status = try completeness(f)

        #expect(status.ownedCount == 1)
        #expect(status.totalCount == 4)
        #expect(status.missing.map(\.entry.number) == ["1", "3", "4"])
        #expect(status.notInList == [stranger])
        // Only the book that has the entry is compared with its number.
        #expect(status.numberDifferences.isEmpty)
        #expect(try f.service.editsUsingAudibleNumbers(forSeries: Self.series).isEmpty)
        #expect(try f.service.librarySeriesBooks(named: Self.series).contains { $0.id == owner })
    }

    @Test func SC23_aSeriesThatIsNotLinkedHasNoCompleteness() throws {
        let f = try F()
        try add(f, "Patriot Games", number: "2")

        #expect(try f.service.seriesCompleteness(forSeries: Self.series) == nil)
    }

    // MARK: SC24

    @Test func SC24_hidingChangesOnlyThatEntrysFlag() throws {
        let f = try F()
        try add(f, "Patriot Games", number: "2")
        try f.service.saveSeriesList(Self.list(Self.four), forSeries: Self.series, now: now)
        func rows() throws -> [[String: DatabaseValue]] {
            try f.store.dbQueue.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM seriesEntry ORDER BY id").map { row in
                    Dictionary(uniqueKeysWithValues: row.map { ($0.0, $0.1) })
                }
            }
        }
        let before = try rows()
        let linkBefore = try completeness(f).link
        let target = try #require(try completeness(f).missing.last)

        try f.service.setMissingEntry(id: target.id, hidden: true)

        var expected = before
        let index = try #require(expected.firstIndex { $0["id"] == target.id.databaseValue })
        expected[index]["isHidden"] = true.databaseValue
        #expect(try rows() == expected)
        #expect(try completeness(f).link == linkBefore)

        try f.service.setMissingEntry(id: target.id, hidden: false)
        #expect(try rows() == before)
    }

    @Test func SC24_anUnknownEntryThrows() throws {
        let f = try F()
        try add(f, "Patriot Games", number: "2")
        try f.service.saveSeriesList(Self.list(Self.four), forSeries: Self.series, now: now)
        let before = try completeness(f)

        #expect(throws: SeriesListError.entryNotFound(9_999)) {
            try f.service.setMissingEntry(id: 9_999, hidden: true)
        }

        #expect(try completeness(f) == before)
    }

    // MARK: SC25

    @Test func SC25_unlinkingDeletesTheLinkAndItsEntries() throws {
        let f = try F()
        try add(f, "Patriot Games", number: "2")
        try add(f, "Rainbow Six", number: "1", series: "John Clark")
        try f.service.saveSeriesList(Self.list(Self.four), forSeries: Self.series, now: now)
        try f.service.saveSeriesList(
            Self.list([Self.edition("B000000009", "Rainbow Six", "1")], id: "B0SERIES09"), forSeries: "John Clark", now: now)

        try f.service.unlinkSeries(named: Self.series)

        #expect(try f.service.seriesCompleteness(forSeries: Self.series) == nil)
        #expect(try completeness(f, "John Clark").totalCount == 1)
        #expect(try count(f, "seriesLink") == 1)
        #expect(try count(f, "seriesEntry") == 1)
        // Unlinking what is not linked does nothing.
        try f.service.unlinkSeries(named: Self.series)
        try f.service.unlinkSeries(named: "Nothing")
        #expect(try count(f, "seriesLink") == 1)
    }

    @Test func SC25_aLinkNoBookUsesGoesAtTheNextSaveOrUnlink() throws {
        for unlinking in [false, true] {
            let f = try F()
            let id = try add(f, "Patriot Games", number: "2")
            try add(f, "Rainbow Six", number: "1", series: "John Clark")
            try f.service.saveSeriesList(Self.list(Self.four), forSeries: Self.series, now: now)
            try f.service.saveSeriesList(
                Self.list([Self.edition("B000000009", "Rainbow Six", "1")], id: "B0SERIES09"), forSeries: "John Clark", now: now)

            // The owner renames the series.
            var book = try #require(try f.store.book(id: id))
            book.series = "Ryanverse"
            try f.store.update(book)

            // The old link is left as it is, unused.
            #expect(try count(f, "seriesLink") == 2)
            #expect(try f.service.seriesCompleteness(forSeries: "Ryanverse") == nil)

            if unlinking {
                try f.service.unlinkSeries(named: "John Clark")
                #expect(try count(f, "seriesLink") == 0)
                #expect(try count(f, "seriesEntry") == 0)
            } else {
                try f.service.saveSeriesList(Self.list(Self.four), forSeries: "Ryanverse", now: now)
                #expect(try count(f, "seriesLink") == 2)
                #expect(try count(f, "seriesEntry") == 5)
                #expect(try f.service.seriesCompleteness(forSeries: Self.series) == nil)
                #expect(try completeness(f, "Ryanverse").ownedCount == 1)
                #expect(try completeness(f, "John Clark").ownedCount == 1)
            }
        }
    }

    // MARK: SC26

    @Test func SC26_oneEditForEachBookNumberedDifferentlyAndNothingWritten() throws {
        let f = try F()
        try add(f, "The Hunt for Red October", number: "01")
        let differs = try add(f, "Patriot Games", number: "3")
        let alsoDiffers = try add(f, "Clear and Present Danger", number: "7")
        try add(f, "The Cardinal of the Kremlin")
        try add(f, "Without Remorse", number: "6")
        try f.service.saveSeriesList(Self.list(Self.four), forSeries: Self.series, now: now)
        let booksBefore = try f.store.books()

        let edits = try f.service.editsUsingAudibleNumbers(forSeries: Self.series)

        #expect(edits.map(\.bookId) == [differs, alsoDiffers])
        #expect(edits.map(\.metadata.seriesNumber) == ["2", "4"])
        // Nothing but the number differs from the book as it is.
        for edit in edits {
            let book = try #require(try f.store.book(id: edit.bookId))
            var expected = BookEdit(book: book)
            expected.metadata.seriesNumber = edit.metadata.seriesNumber
            #expect(edit.metadata == expected.metadata)
            #expect(edit.tags == book.tags && edit.rating == book.rating && edit.editionKind == book.editionKind)
            guard case .keep = edit.cover else {
                Issue.record("the cover is to be kept")
                continue
            }
        }
        #expect(try f.store.books() == booksBefore)
        #expect(try f.service.editsUsingAudibleNumbers(forSeries: "John Clark").isEmpty)
    }

    @Test func SC26_theEditsSaveAsAnOrdinaryUndoableEdit() throws {
        let f = try F()
        let differs = try add(
            f, "Patriot Games", number: "3", copies: [ExternalCopy(kind: .audible, form: .audio, itemId: "B000000002")])
        try f.service.saveSeriesList(Self.list(Self.four), forSeries: Self.series, now: now)

        _ = try f.service.save(try f.service.editsUsingAudibleNumbers(forSeries: Self.series))

        #expect(try f.store.book(id: differs)?.seriesNumber == "2")
        #expect(try completeness(f).numberDifferences.isEmpty)
        #expect(try f.service.editsUsingAudibleNumbers(forSeries: Self.series).isEmpty)
        #expect(try f.service.undoLabel() != nil)
    }

    // MARK: SC27

    @Test func SC27_nothingIsJournaledAndTheUndoableOperationStays() throws {
        let f = try F()
        let id = try add(
            f, "Patriot Games", number: "3", copies: [ExternalCopy(kind: .audible, form: .audio, itemId: "B000000002")])
        var edit = BookEdit(book: try #require(try f.store.book(id: id)))
        edit.rating = 4
        _ = try f.service.save([edit])
        let label = try #require(try f.service.undoLabel())
        let batch = try f.store.lastBatch()
        let books = try f.store.books()
        let hidden = f.hiddenTree()

        try f.service.saveSeriesList(Self.list(Self.four), forSeries: Self.series, now: now)
        let status = try completeness(f)
        try f.service.setMissingEntry(id: try #require(status.missing.first).id, hidden: true)
        _ = try f.service.editsUsingAudibleNumbers(forSeries: Self.series)
        _ = try f.service.librarySeriesBooks(named: Self.series)
        try f.service.unlinkSeries(named: Self.series)

        #expect(try f.service.undoLabel() == label)
        #expect(try f.store.lastBatch() == batch)
        #expect(try f.store.books() == books)
        #expect(f.hiddenTree() == hidden)
        #expect(f.libraryTree().isEmpty)
    }

    @Test func SC27_aV8DatabaseOpensUnchangedAndTakesASeriesList() throws {
        let root = try makeTempDir()
        let path = root.appendingPathComponent(LibraryStore.databaseFileName).path
        let tables = [
            "book", "bookFile", "collection", "collectionBook", "operationBatch", "operationMove", "libraryNote",
            "watchFolder", "inboxEntry",
        ]
        func contents(_ db: Database) throws -> [String: [Row]] {
            var all: [String: [Row]] = [:]
            for table in tables {
                all[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map { $0.copy() }
            }
            return all
        }
        func schema(_ db: Database) throws -> [String] {
            try String.fetchAll(
                db, sql: "SELECT sql FROM sqlite_master WHERE tbl_name IN (\(tables.map { "'\($0)'" }.joined(separator: ","))) AND sql IS NOT NULL ORDER BY name")
        }
        var before: [String: [Row]] = [:]
        var schemaBefore: [String] = []
        do {
            let queue = try DatabaseQueue(path: path)
            try LibraryStore.migrator.migrate(queue, upTo: "v8")
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO book (title, authors, narrators, series, seriesNumber, tags, rating, needsAttention,
                                      folderPath, durationSeconds, dateAdded, readStatus, appOnlyFields, externalCopies,
                                      editionKind, partsAppearMissing)
                    VALUES ('Patriot Games', '["Tom Clancy"]', '[]', 'Jack Ryan', '2', '["kept"]', 4, 0,
                            'Tom Clancy/Patriot Games', 4368.5, '2025-01-02 03:04:05.000', 'finished', '[]', '[]', NULL, 1);
                    INSERT INTO bookFile (bookId, path, format, role, position)
                    VALUES (1, 'Tom Clancy/Patriot Games/Patriot Games.m4b', 'm4b', 'audio', 0);
                    INSERT INTO collection (name) VALUES ('To Read');
                    INSERT INTO collectionBook (collectionId, bookId) VALUES (1, 1);
                    INSERT INTO operationBatch (label, createdAt) VALUES ('Import 1 Book', '2025-01-02 03:04:05.000');
                    INSERT INTO operationMove (batchId, fromPath, toPath, wasCopy) VALUES (1, '/from', '/to', 0);
                    INSERT INTO libraryNote (key, value) VALUES ('k', 'v');
                    INSERT INTO watchFolder (path, mode, isEnabled, includesPDFs, addedAt)
                    VALUES ('/somewhere/watched', 'move', 1, 0, 700000000.25);
                    INSERT INTO inboxEntry (folderId, path, size, modifiedAt, state)
                    VALUES (1, '/somewhere/watched/a.m4b', 10, 700000000.5, 'dismissed');
                    """)
                let hasLinks = try db.tableExists("seriesLink")
                let hasEntries = try db.tableExists("seriesEntry")
                #expect(!hasLinks && !hasEntries)
                before = try contents(db)
                schemaBefore = try schema(db)
            }
            try queue.close()
        }

        let store = try LibraryStore(libraryRoot: root)
        let service = LibraryService(store: store)

        #expect(try service.seriesCompleteness(forSeries: Self.series) == nil)
        #expect(try store.dbQueue.read { db in try contents(db) } == before)
        #expect(try store.dbQueue.read { db in try schema(db) } == schemaBefore)
        #expect(before.values.allSatisfy { $0.count == 1 })

        // The upgraded catalogue takes a list, and still nothing earlier has changed.
        try service.saveSeriesList(Self.list(Self.four), forSeries: Self.series, now: now)
        let status = try #require(try service.seriesCompleteness(forSeries: Self.series))
        #expect(status.ownedCount == 1 && status.totalCount == 4)
        #expect(status.link.checkedAt == now)
        #expect(try store.dbQueue.read { db in try contents(db) } == before)
    }

    @Test func SC27_entriesGoWithTheirLinkAndASeriesHasOneLink() throws {
        let f = try F()
        try add(f, "Patriot Games", number: "2")
        try f.service.saveSeriesList(Self.list(Self.four), forSeries: Self.series, now: now)

        #expect(throws: DatabaseError.self) {
            try f.store.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO seriesLink (seriesKey, seriesName, audibleSeriesId, audibleSeriesTitle, store, checkedAt)
                    VALUES ('Jack Ryan', 'Jack Ryan', 'B0SERIES02', 'Again', 'us', 1)
                    """)
            }
        }
        try f.store.dbQueue.write { db in try db.execute(sql: "DELETE FROM seriesLink") }
        #expect(try count(f, "seriesEntry") == 0)
    }
}
