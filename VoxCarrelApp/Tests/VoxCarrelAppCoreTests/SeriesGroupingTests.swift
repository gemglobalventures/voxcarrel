import Foundation
import Testing
import VoxCarrelCore

@testable import VoxCarrelAppCore

/// Plan 10, Task 1: a list's books grouped by series. GS1–GS8.
@Suite struct SeriesGroupingTests {
    private func row(
        _ id: Int64, _ title: String, authors: [String] = ["Someone"], series: String? = nil,
        number: String? = nil, duration: Double? = nil, added: TimeInterval = 0,
        audio: Bool = true, ebook: Bool = false, status: ReadStatus = .unread,
        edition: EditionKind? = nil, attention: Bool = false, writeProblem: Bool = false, audible: Bool = false
    ) -> BookRow {
        var metadata = BookMetadata(title: title, authors: authors)
        metadata.series = series
        metadata.seriesNumber = number
        metadata.durationSeconds = duration
        var book = Book(metadata: metadata, dateAdded: Date(timeIntervalSinceReferenceDate: added))
        book.id = id
        book.setReadStatus(status)
        book.needsAttention = attention
        if let edition { book.editionKind = EditionKindNote(kind: edition, basis: .setByHand) }
        if audible { book.externalCopies = [ExternalCopy(kind: .audible, form: .audio)] }
        return BookRow(
            id: id, book: book, hasAudio: audio, hasEbook: ebook,
            formats: (audio ? [.m4b] : []) + (ebook ? [.epub] : []), coverURL: nil, hasWriteProblem: writeProblem)
    }

    /// "b3" for a book, the series' name for a group.
    private func labels(_ items: [LibraryItem]) -> [String] {
        items.map {
            switch $0 {
            case .book(let row): "b\(row.id)"
            case .series(let group): group.name
            }
        }
    }

    private func grouped(_ rows: [BookRow], _ sort: BookSort = BookSort()) -> [String] {
        labels(SeriesGrouping.items(from: rows, sort: sort, grouped: true))
    }

    private func group(_ name: String, in rows: [BookRow], sort: BookSort = BookSort()) throws -> SeriesGroup {
        let items = SeriesGrouping.items(from: rows, sort: sort, grouped: true)
        let found = items.compactMap { item -> SeriesGroup? in
            if case .series(let group) = item, group.name == name { return group }
            return nil
        }
        return try #require(found.first, "no group named \(name)")
    }

    /// Two books alone, a series of two and a lone book of another series, with every
    /// value different enough to tell each sort from the others.
    private var mixed: [BookRow] {
        [
            row(1, "Mango", authors: ["Zed"], duration: 100, added: 10),
            row(2, "Apple", authors: ["Bea"], duration: 5000, added: 50, audio: false, ebook: true, status: .finished,
                edition: .dramatised),
            row(3, "Zulu", authors: ["Kay"], series: "Saga", number: "2", duration: 600, added: 20,
                status: .inProgress, edition: .abridged),
            row(4, "Yak", authors: ["Cat"], series: "Saga", number: "1", duration: 400, added: 40, ebook: true,
                status: .finished),
            row(5, "Banana", authors: ["Dee"], series: "Solo", number: "1", duration: 300, added: 30,
                edition: .unabridged),
        ]
    }

    // MARK: GS1

    /// GS1
    @Test func ungroupedItemsAreTheRowsInTheirOrder() {
        let rows = [
            row(3, "C", series: "Saga", number: "1"), row(1, "A", series: "Saga", number: "2"), row(2, "B"),
        ]
        let items = SeriesGrouping.items(from: rows, sort: BookSort(key: .length), grouped: false)
        #expect(items == rows.map(LibraryItem.book))
        #expect(items.map(\.id) == [.book(3), .book(1), .book(2)])
    }

    /// GS1, GS5: a single series' view is never grouped, and its missing rows stay.
    @Test func ungroupedItemsKeepRowsForMissingBooks() {
        let missing = row(-4, "Not here", series: "Saga", number: "3")
        let rows = [row(1, "A", series: "Saga", number: "1"), missing]
        #expect(SeriesGrouping.items(from: rows, sort: BookSort(), grouped: false).map(\.id) == [.book(1), .book(-4)])
    }

    // MARK: GS2

    /// GS2
    @Test func booksOfOneSeriesFormAGroupWhenThereAreTwoOrMore() throws {
        let rows = [
            row(1, "Alpha", series: "Saga", number: "1"), row(2, "Beta", series: "Saga", number: "2"),
            row(3, "Gamma", series: "Lone", number: "1"), row(4, "Delta"), row(5, "Epsilon", series: "  "),
            row(6, "Zeta", series: ""),
        ]
        let items = SeriesGrouping.items(from: rows, sort: BookSort(), grouped: true)
        #expect(labels(items) == ["b4", "b5", "b3", "Saga", "b6"])
        let saga = try group("Saga", in: rows)
        #expect(saga.id == .series("Saga"))
        #expect(saga.books.map(\.id) == [1, 2])
        #expect(items.first { $0.id == .series("Saga") } == .series(saga))
    }

    /// GS2: the series text is taken exactly: another spelling is another series, as it
    /// is under Browse ▸ Series.
    @Test func seriesAreToldApartByTheirExactText() throws {
        let rows = [
            row(1, "A", series: "Saga"), row(2, "B", series: "Saga"), row(3, "C", series: "saga"),
            row(4, "D", series: "saga"), row(5, "E", series: "Saga "),
        ]
        let names = SeriesGrouping.items(from: rows, sort: BookSort(), grouped: true).compactMap { item -> String? in
            if case .series(let group) = item { return group.name }
            return nil
        }
        #expect(Set(names) == ["Saga", "saga"])
        #expect(try group("saga", in: rows).books.map(\.id) == [3, 4])
        #expect(grouped(rows).contains("b5"))
    }

    // MARK: GS3

    /// GS3: the order a single series' view shows, whatever the sort.
    @Test func aGroupsBooksAreInSeriesOrder() throws {
        let rows = [
            row(1, "Zebra", series: "Saga", number: "1"), row(2, "Apple", series: "Saga", number: "10"),
            row(3, "Mango", series: "Saga", number: "2"), row(4, "Aardvark", series: "Saga"),
            row(5, "Kiwi", series: "Saga", number: "2.5"), row(6, "Lime", series: "Saga", number: "1-3"),
            row(7, "Fig", series: "Saga", number: "2"),
        ]
        let own = BookSort().sorted(rows, showing: .browse(.series, "Saga")).map(\.id)
        #expect(own == [1, 7, 3, 5, 2, 6, 4])
        for sort in [BookSort(), BookSort(key: .title, ascending: false), BookSort(key: .length), BookSort(key: .dateAdded, ascending: false)] {
            #expect(try group("Saga", in: rows, sort: sort).books.map(\.id) == own)
        }
    }

    // MARK: GS4

    /// GS4: Title, by the series' name.
    @Test func byTitleAGroupStandsWhereItsNameFalls() {
        #expect(grouped(mixed, BookSort(key: .title)) == ["b2", "b5", "b1", "Saga"])
        #expect(grouped(mixed, BookSort(key: .title, ascending: false)) == ["Saga", "b1", "b5", "b2"])
    }

    /// GS4: Series, by the series' name; books with no series last, whichever way.
    @Test func bySeriesAGroupStandsWhereItsNameFalls() {
        #expect(grouped(mixed, BookSort(key: .series)) == ["Saga", "b5", "b2", "b1"])
        #expect(grouped(mixed, BookSort(key: .series, ascending: false)) == ["b5", "Saga", "b1", "b2"])
    }

    /// GS4: Author, by the author of the group's first book in series order.
    @Test func byAuthorAGroupStandsWhereItsFirstBooksAuthorFalls() {
        #expect(grouped(mixed, BookSort(key: .author)) == ["b2", "Saga", "b5", "b1"])
        #expect(grouped(mixed, BookSort(key: .author, ascending: false)) == ["b1", "b5", "Saga", "b2"])
    }

    /// GS4: Length, by the total.
    @Test func byLengthAGroupStandsWhereItsTotalFalls() {
        #expect(grouped(mixed, BookSort(key: .length)) == ["b1", "b5", "Saga", "b2"])
        #expect(grouped(mixed, BookSort(key: .length, ascending: false)) == ["b2", "Saga", "b5", "b1"])

        // A group none of whose books has a length is last, as such a book is.
        let rows = [
            row(1, "A", series: "Saga"), row(2, "B", series: "Saga"), row(3, "C", duration: 60), row(4, "D"),
        ]
        #expect(grouped(rows, BookSort(key: .length)) == ["b3", "b4", "Saga"])
        #expect(grouped(rows, BookSort(key: .length, ascending: false)) == ["b3", "Saga", "b4"])
    }

    /// GS4: Added, by the newest of its books.
    @Test func byDateAddedAGroupStandsWhereItsNewestBookFalls() {
        #expect(grouped(mixed, BookSort(key: .dateAdded)) == ["b1", "b5", "Saga", "b2"])
        #expect(grouped(mixed, BookSort(key: .dateAdded, ascending: false)) == ["b2", "Saga", "b5", "b1"])
    }

    /// GS4: Formats, as a book with all the group's formats would be.
    @Test func byFormatsAGroupStandsWhereItsCombinedFormatsFall() {
        // Saga has an audiobook and a book that is both: audio and ebook.
        #expect(grouped(mixed, BookSort(key: .formats)) == ["b5", "b1", "Saga", "b2"])
        #expect(grouped(mixed, BookSort(key: .formats, ascending: false)) == ["b2", "Saga", "b1", "b5"])

        // Audio only, all through: with the audiobooks, by name.
        let rows = [
            row(1, "Tango", series: "Saga"), row(2, "Uniform", series: "Saga"),
            row(3, "Romeo"), row(4, "Victor"), row(5, "Echo", audio: false, ebook: true),
        ]
        #expect(grouped(rows, BookSort(key: .formats)) == ["b3", "Saga", "b4", "b5"])
    }

    /// GS4: Status, by the least advanced of its books.
    @Test func byStatusAGroupStandsWhereItsLeastAdvancedBookFalls() {
        // Saga: one in progress, one finished.
        #expect(grouped(mixed, BookSort(key: .status)) == ["b5", "b1", "Saga", "b2"])
        #expect(grouped(mixed, BookSort(key: .status, ascending: false)) == ["b2", "Saga", "b1", "b5"])

        let rows = [
            row(1, "A", series: "Saga", status: .finished), row(2, "B", series: "Saga"),
            row(3, "C", status: .inProgress),
        ]
        #expect(grouped(rows, BookSort(key: .status)) == ["Saga", "b3"])
    }

    /// GS4, for the one key the plan does not name: Edition, by the first kind in the
    /// sort's order that any of its books has; a group with none is last, as a book is.
    @Test func byEditionAGroupStandsWhereItsFirstKindFalls() {
        // Saga: one abridged, one with no kind.
        #expect(grouped(mixed, BookSort(key: .edition)) == ["b5", "Saga", "b2", "b1"])
        #expect(grouped(mixed, BookSort(key: .edition, ascending: false)) == ["b2", "Saga", "b5", "b1"])
    }

    /// GS4: where a book and a group tie, the title breaks the tie, the group's name
    /// standing for its title; then the id, the group's lowest standing for its own.
    @Test func tiesBetweenABookAndAGroupAreBrokenByNameThenId() {
        let rows = [
            row(3, "X", authors: ["Ann"], series: "Mid", number: "1"),
            row(4, "Y", authors: ["Ann"], series: "Mid", number: "2"),
            row(1, "Zed", authors: ["Ann"]), row(2, "Alpha", authors: ["Ann"]),
        ]
        #expect(grouped(rows, BookSort(key: .author)) == ["b2", "Mid", "b1"])
        #expect(grouped(rows, BookSort(key: .author, ascending: false)) == ["b1", "Mid", "b2"])

        // A book called what the series is called.
        let same = [
            row(5, "Saga", series: "Saga", number: "1"), row(6, "Saga Again", series: "Saga", number: "2"),
            row(9, "saga"), row(2, "SAGA"),
        ]
        #expect(grouped(same, BookSort(key: .title)) == ["b2", "Saga", "b9"])
        #expect(grouped(same, BookSort(key: .title, ascending: false)) == ["b9", "Saga", "b2"])
    }

    // MARK: GS5

    /// GS5
    @Test func rowsForMissingBooksAreDroppedBeforeGrouping() throws {
        let missing = row(-2, "Not here", series: "Saga", number: "2")
        let rows = [
            row(1, "One", series: "Saga", number: "1"), missing, row(0, "Nobody's"),
            row(3, "Three", series: "Pair", number: "1"), row(4, "Four", series: "Pair", number: "2"),
            row(-7, "Gone", series: "Pair", number: "3"),
        ]
        let items = SeriesGrouping.items(from: rows, sort: BookSort(), grouped: true)
        // Saga is left with one book, which is no group.
        #expect(labels(items) == ["b1", "Pair"])
        #expect(try group("Pair", in: rows).books.map(\.id) == [3, 4])
    }

    // MARK: GS6

    /// GS6
    @Test func aGroupSaysHowManyBooksItHas() throws {
        let two = [row(1, "A", series: "Saga"), row(2, "B", series: "Saga")]
        #expect(try group("Saga", in: two).countText == "2 books")
        #expect(try group("Saga", in: two).titleText == "Saga")
        let five = (1...5).map { row($0, "Book \($0)", series: "Saga", number: "\($0)") }
        #expect(try group("Saga", in: five).countText == "5 books")
    }

    /// GS6: first authors, ignoring case.
    @Test func aGroupNamesTheOneAuthorAllItsBooksShare() throws {
        let shared = [
            row(1, "A", authors: ["Ines Calloway", "Other"], series: "Saga", number: "1"),
            row(2, "B", authors: ["ines calloway"], series: "Saga", number: "2"),
        ]
        #expect(try group("Saga", in: shared).authorsText == "Ines Calloway")
        let various = [
            row(1, "A", authors: ["Ines Calloway"], series: "Saga"), row(2, "B", authors: ["Tom Reed"], series: "Saga"),
        ]
        #expect(try group("Saga", in: various).authorsText == "Various")
        let partly = [row(1, "A", authors: ["Ines Calloway"], series: "Saga"), row(2, "B", authors: [], series: "Saga")]
        #expect(try group("Saga", in: partly).authorsText == "Various")
        let none = [row(1, "A", authors: [], series: "Saga"), row(2, "B", authors: [" "], series: "Saga")]
        #expect(try group("Saga", in: none).authorsText == "")
    }

    /// GS6: the total of the books that have a length, worded as a book's is.
    @Test func aGroupsLengthIsTheTotalOfItsBooks() throws {
        let rows = [
            row(1, "A", series: "Saga", duration: 3600), row(2, "B", series: "Saga", duration: 5400),
            row(3, "C", series: "Saga"),
        ]
        #expect(try group("Saga", in: rows).lengthText == "2h 30m")
        #expect(try group("Saga", in: rows).lengthText == LengthText.text(seconds: 9000))
        let none = [row(1, "A", series: "Saga"), row(2, "B", series: "Saga")]
        #expect(try group("Saga", in: none).lengthText == "")
    }

    /// GS6
    @Test func aGroupSaysHowManyOfItsBooksAreFinished() throws {
        func status(_ statuses: [ReadStatus]) throws -> String {
            let rows = statuses.enumerated().map { index, status in
                row(Int64(index + 1), "Book \(index)", series: "Saga", number: "\(index)", status: status)
            }
            return try group("Saga", in: rows).statusText
        }
        #expect(try status([.finished, .finished, .unread, .inProgress, .unread]) == "2 of 5 finished")
        #expect(try status([.finished, .finished]) == "All finished")
        #expect(try status([.unread, .unread, .unread]) == "None started")
        #expect(try status([.unread, .inProgress]) == "0 of 2 finished")
    }

    /// What the Status column of the list says of a group: short enough to fit the
    /// column beside a book's "In Progress"; the whole phrase is `statusText`.
    @Test func aGroupsStatusIsShortInTheColumn() throws {
        func status(_ statuses: [ReadStatus]) throws -> String {
            let rows = statuses.enumerated().map { index, status in
                row(Int64(index + 1), "Book \(index)", series: "Saga", number: "\(index)", status: status)
            }
            return try group("Saga", in: rows).statusColumnText
        }
        #expect(try status([.finished, .finished, .unread, .inProgress, .unread]) == "2 of 5")
        #expect(try status([.unread, .inProgress]) == "0 of 2")
        #expect(try status([.finished, .finished]) == "All finished")
        #expect(try status([.unread, .unread, .unread]) == "None started")
    }

    /// GS6
    @Test func aGroupHasTheFormatsOfAllItsBooks() throws {
        let rows = [
            row(1, "A", series: "Saga", audio: true, ebook: false),
            row(2, "B", series: "Saga", audio: false, ebook: true, audible: true),
            row(3, "C", series: "Pair"), row(4, "D", series: "Pair"),
        ]
        let saga = try group("Saga", in: rows)
        #expect(saga.hasAudio && saga.hasEbook && saga.isOnAudible)
        let pair = try group("Pair", in: rows)
        #expect(pair.hasAudio && !pair.hasEbook && !pair.isOnAudible)
    }

    /// GS6: the books that have a warning are counted.
    @Test func aGroupCountsItsBooksThatHaveAWarning() throws {
        let clean = [row(1, "A", series: "Saga"), row(2, "B", series: "Saga")]
        #expect(try group("Saga", in: clean).warningText == nil)
        let one = [row(1, "A", series: "Saga", attention: true), row(2, "B", series: "Saga")]
        #expect(try group("Saga", in: one).warningText == "1 book needs attention")
        let two = [
            row(1, "A", series: "Saga", attention: true), row(2, "B", series: "Saga", writeProblem: true),
            row(3, "C", series: "Saga"),
        ]
        #expect(try group("Saga", in: two).warningText == "2 books need attention")
    }

    /// GS6
    @Test func aGroupsNewestBookAndCovers() throws {
        let rows = (1...5).map {
            row(Int64($0), "Book \($0)", series: "Saga", number: "\(6 - $0)", added: TimeInterval($0 * 10))
        }
        let saga = try group("Saga", in: rows)
        #expect(saga.newestAdded == Date(timeIntervalSinceReferenceDate: 50))
        // The first three in series order.
        #expect(saga.coverRows.map(\.id) == [5, 4, 3])
        let two = Array(rows.prefix(2))
        #expect(try group("Saga", in: two).coverRows.map(\.id) == [2, 1])
    }

    /// GS6: one line for the tooltip and VoiceOver.
    @Test func aGroupSummarisesItself() throws {
        let rows = [
            row(1, "A", authors: ["Ines Calloway"], series: "Saga", duration: 3600, status: .finished),
            row(2, "B", authors: ["Ines Calloway"], series: "Saga", duration: 3600, attention: true),
        ]
        #expect(
            try group("Saga", in: rows).summaryText
                == "Saga\nInes Calloway\n2 books · 2h 0m · 1 of 2 finished · 1 book needs attention")
        let bare = [row(1, "A", authors: [], series: "Saga"), row(2, "B", authors: [], series: "Saga")]
        #expect(try group("Saga", in: bare).summaryText == "Saga\n2 books · None started")
    }

    // MARK: GS7

    /// GS7
    @Test func theOrderRowsArriveInMakesNoDifference() {
        var rows = mixed + [
            row(6, "Same", series: "Twin", number: "1"), row(7, "Same", series: "Twin", number: "1"),
            row(8, "Same"), row(9, "Same"),
        ]
        for key in BookSortKey.allCases {
            for ascending in [true, false] {
                let sort = BookSort(key: key, ascending: ascending)
                let expected = SeriesGrouping.items(from: rows, sort: sort, grouped: true)
                #expect(SeriesGrouping.items(from: rows, sort: sort, grouped: true) == expected)
                for _ in 0..<5 {
                    rows.shuffle()
                    #expect(SeriesGrouping.items(from: rows, sort: sort, grouped: true) == expected)
                }
            }
        }
    }

    // MARK: GS8

    /// GS8
    @Test(.timeLimit(.minutes(1))) func twoThousandRowsAreGroupedQuickly() {
        var rows: [BookRow] = []
        for number in 1...2000 {
            let title = "Book \(number % 700)"
            let author = "Author \(number % 90)"
            let series: String? = number % 4 == 0 ? nil : "Series \(number % 150)"
            let place = "\(number % 13)"
            rows.append(
                row(
                    Int64(number), title, authors: [author], series: series, number: place,
                    duration: Double(number * 7), added: TimeInterval(number)))
        }
        let start = Date()
        for key in BookSortKey.allCases {
            let items = SeriesGrouping.items(from: rows, sort: BookSort(key: key), grouped: true)
            #expect(items.count < rows.count)
            let books = items.reduce(0) { count, item in
                switch item {
                case .book: count + 1
                case .series(let group): count + group.books.count
                }
            }
            #expect(books == 2000)
        }
        #expect(Date().timeIntervalSince(start) < 20)
    }

    /// GS6: the headphones and the book are for files that are here, as on a book's row.
    @Test func aGroupShowsTheFormatsOfTheFilesThatAreHere() throws {
        var elsewhere = row(1, "A", series: "Saga", number: "1", audible: true)
        elsewhere.hasFiles = false
        var alsoElsewhere = row(2, "B", series: "Saga", number: "2", audible: true)
        alsoElsewhere.hasFiles = false
        let onAudibleOnly = try group("Saga", in: [elsewhere, alsoElsewhere])
        #expect(onAudibleOnly.hasAudio)
        #expect(!onAudibleOnly.hasAudioFiles)
        #expect(!onAudibleOnly.hasEbookFiles)
        #expect(onAudibleOnly.isOnAudible)

        let mixed = try group(
            "Saga", in: [elsewhere, row(2, "B", series: "Saga", number: "2", audio: false, ebook: true)])
        #expect(!mixed.hasAudioFiles)
        #expect(mixed.hasEbookFiles)
        #expect(try group("Saga", in: self.mixed).hasAudioFiles)
        #expect(try group("Saga", in: self.mixed).hasEbookFiles)
    }

    // MARK: The list's column headers, over items

    /// A book's column keys are its row's; a group's are what it is ordered by (GS4).
    @Test func itemsHaveTheColumnKeysOfTheirRowsAndGroups() throws {
        let rows = mixed
        let book = LibraryItem.book(rows[1])
        #expect(book.titleSortKey == rows[1].titleSortKey)
        #expect(book.authorSortKey == rows[1].authorSortKey)
        #expect(book.seriesSortKey == rows[1].seriesSortKey)
        #expect(book.formatsSortKey == rows[1].formatsSortKey)
        #expect(book.lengthSortKey == rows[1].lengthSortKey)
        #expect(book.dateAddedSortKey == rows[1].dateAddedSortKey)
        #expect(book.statusSortKey == rows[1].statusSortKey)
        #expect(book.editionSortKey == rows[1].editionSortKey)

        let saga = LibraryItem.series(try group("Saga", in: rows))
        #expect(saga.titleSortKey == "Saga")
        #expect(saga.authorSortKey == "Cat")
        #expect(saga.seriesSortKey == "Saga")
        #expect(saga.formatsSortKey == 3)
        #expect(saga.lengthSortKey == 1000)
        #expect(saga.dateAddedSortKey == Date(timeIntervalSinceReferenceDate: 40))
        #expect(saga.statusSortKey == ReadStatus.inProgress.rawValue)
        #expect(saga.editionSortKey == EditionKind.abridged.rawValue)
    }

    /// G3: every key has a column in a table of items, and a click on its header
    /// comes back as that key.
    @Test func everySortIsAnItemColumnSortOrderAndBack() {
        for key in BookSortKey.allCases {
            for ascending in [true, false] {
                let sort = BookSort(key: key, ascending: ascending)
                let order = sort.itemSortOrder
                #expect(order.count == 1)
                #expect(order.first?.order == (ascending ? .forward : .reverse))
                #expect(BookSort(itemSortOrder: order) == sort)
            }
        }
        #expect(Set(BookSortKey.allCases.map { BookSort(key: $0).itemSortOrder[0].keyPath }).count
            == BookSortKey.allCases.count)

        // The clicked column is first; only it counts.
        let order = BookSort(key: .length, ascending: false).itemSortOrder + BookSort(key: .title).itemSortOrder
        #expect(BookSort(itemSortOrder: order) == BookSort(key: .length, ascending: false))
        #expect(BookSort(itemSortOrder: []) == nil)
        // A column that is not one of the sort keys.
        #expect(BookSort(itemSortOrder: [KeyPathComparator(\LibraryItem.books.count)]) == nil)
    }

    /// G3: a column of text is named with the comparator a table's text column has.
    @Test func itemTextColumnsUseTheTablesOwnComparator() {
        let standard = String.StandardComparator.localizedStandard
        for order in [SortOrder.forward, .reverse] {
            let expected: [BookSortKey: KeyPathComparator<LibraryItem>] = [
                .title: KeyPathComparator(\.titleSortKey, comparator: standard, order: order),
                .author: KeyPathComparator(\.authorSortKey, comparator: standard, order: order),
                .series: KeyPathComparator(\.seriesSortKey, comparator: standard, order: order),
                .status: KeyPathComparator(\.statusSortKey, comparator: standard, order: order),
            ]
            for (key, comparator) in expected {
                #expect(BookSort(key: key, ascending: order == .forward).itemSortOrder[0] == comparator, "\(key)")
            }
        }
    }
}
