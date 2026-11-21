import Foundation
import Testing
import VoxCarrelAppCore
import VoxCarrelCore

/// S1
@Suite struct BookSortTests {
    private func row(
        _ id: Int64, _ title: String, authors: [String] = ["Someone"], series: String? = nil,
        number: String? = nil, duration: Double? = nil, added: TimeInterval = 0,
        audio: Bool = true, ebook: Bool = false, status: ReadStatus = .unread
    ) -> BookRow {
        var metadata = BookMetadata(title: title, authors: authors)
        metadata.series = series
        metadata.seriesNumber = number
        metadata.durationSeconds = duration
        var book = Book(metadata: metadata, dateAdded: Date(timeIntervalSinceReferenceDate: added))
        book.id = id
        book.setReadStatus(status)
        return BookRow(
            id: id, book: book, hasAudio: audio, hasEbook: ebook,
            formats: (audio ? [.m4b] : []) + (ebook ? [.epub] : []), coverURL: nil, hasWriteProblem: false)
    }

    private func ids(_ sort: BookSort, _ rows: [BookRow]) -> [Int64] { sort.sorted(rows).map(\.id) }

    @Test func defaultsToTitleAscending() {
        #expect(BookSort() == BookSort(key: .title, ascending: true))
    }

    /// S1: text ignores case, and numbers inside it are in natural order.
    @Test func titleIgnoresCaseAndUsesNaturalNumbers() {
        let rows = [row(1, "Book 10"), row(2, "book 2"), row(3, "apple"), row(4, "Banana")]
        #expect(ids(BookSort(key: .title), rows) == [3, 4, 2, 1])
        #expect(ids(BookSort(key: .title, ascending: false), rows) == [1, 2, 4, 3])
    }

    /// S1: every key breaks ties by title then id.
    @Test func equalTitlesAreOrderedById() {
        let rows = [row(3, "Same"), row(1, "same"), row(2, "SAME")]
        #expect(ids(BookSort(key: .title), rows) == [1, 2, 3])
        #expect(ids(BookSort(key: .title, ascending: false), rows) == [3, 2, 1])
    }

    /// S1: `author` uses the first author; books with none sort last, whichever way.
    @Test func authorUsesTheFirstAuthorAndPutsNoneLast() {
        let rows = [
            row(1, "A", authors: ["zadie", "Aaron"]),
            row(2, "B", authors: []),
            row(3, "C", authors: ["Aaron", "Zadie"]),
            row(4, "D", authors: ["  "]),
            row(5, "A2", authors: ["Zadie"]),
        ]
        #expect(ids(BookSort(key: .author), rows) == [3, 1, 5, 2, 4])
        #expect(ids(BookSort(key: .author, ascending: false), rows) == [5, 1, 3, 4, 2])
    }

    /// S1: series name, then number (numerically where it is one), no series last, ties by title.
    @Test func seriesSortsByNameThenNumber() {
        let rows = [
            row(1, "Ten", series: "Saga", number: "10"),
            row(2, "Two", series: "saga", number: "2"),
            row(3, "Half", series: "Saga", number: "2.5"),
            row(4, "Alone B"),
            row(5, "Other", series: "Alpha", number: "7"),
            row(6, "Alone A", series: ""),
            row(7, "Twin B", series: "Saga", number: "3"),
            row(8, "Twin A", series: "Saga", number: "3"),
        ]
        #expect(ids(BookSort(key: .series), rows) == [5, 2, 3, 8, 7, 1, 6, 4])
        // Descending: the books in a series are reversed; those with none stay last.
        #expect(ids(BookSort(key: .series, ascending: false), rows) == [1, 7, 8, 3, 2, 5, 4, 6])
    }

    /// S1: a number that is not one ("1-3") or is absent comes after the numbered books.
    @Test func seriesNumbersThatAreNotNumbersFollowTheNumbered() {
        let rows = [
            row(1, "Omnibus", series: "Saga", number: "1-3"),
            row(2, "Unnumbered", series: "Saga"),
            row(3, "Twelve", series: "Saga", number: "12"),
        ]
        #expect(ids(BookSort(key: .series), rows) == [3, 1, 2])
    }

    /// S1: audio-only, then audio and ebook, then ebook-only.
    @Test func formatsSortsAudioThenBothThenEbook() {
        let rows = [
            row(1, "E", audio: false, ebook: true),
            row(2, "B", audio: true, ebook: true),
            row(3, "A2", audio: true, ebook: false),
            row(4, "A1", audio: true, ebook: false),
            row(5, "Neither", audio: false, ebook: false),
        ]
        #expect(ids(BookSort(key: .formats), rows) == [4, 3, 2, 1, 5])
        // A book with neither (extras only) is a "last" group.
        #expect(ids(BookSort(key: .formats, ascending: false), rows) == [1, 2, 3, 4, 5])
    }

    /// S1: `length` uses duration; books with none sort last.
    @Test func lengthPutsBooksWithNoDurationLast() {
        let rows = [
            row(1, "Long", duration: 9000), row(2, "None B"), row(3, "Short", duration: 60),
            row(4, "None A"), row(5, "Also short", duration: 60),
        ]
        #expect(ids(BookSort(key: .length), rows) == [5, 3, 1, 4, 2])
        #expect(ids(BookSort(key: .length, ascending: false), rows) == [1, 3, 5, 2, 4])
    }

    @Test func dateAddedSortsOldestFirstThenByTitle() {
        let rows = [row(1, "New", added: 300), row(2, "Old", added: 100), row(3, "Mid B", added: 200),
                    row(4, "Mid A", added: 200)]
        #expect(ids(BookSort(key: .dateAdded), rows) == [2, 4, 3, 1])
        #expect(ids(BookSort(key: .dateAdded, ascending: false), rows) == [1, 3, 4, 2])
    }

    /// S1: the order does not depend on the order the rows arrive in.
    @Test func orderIsStableWhateverTheInputOrder() {
        let rows = [
            row(1, "Same", authors: ["Ann"]), row(2, "Same", authors: ["ann"]),
            row(3, "Other", authors: []), row(4, "Other", authors: []),
        ]
        for key in BookSortKey.allCases {
            for ascending in [true, false] {
                let sort = BookSort(key: key, ascending: ascending)
                #expect(ids(sort, rows) == ids(sort, rows.reversed()), "\(key) \(ascending)")
            }
        }
    }

    /// S1, for the list's Status column: unread, in progress, finished; then by title.
    @Test func statusSortsUnreadThenInProgressThenFinished() {
        let rows = [
            row(1, "F", status: .finished), row(2, "U2", status: .unread), row(3, "P", status: .inProgress),
            row(4, "U1", status: .unread),
        ]
        #expect(ids(BookSort(key: .status), rows) == [4, 2, 3, 1])
        #expect(ids(BookSort(key: .status, ascending: false), rows) == [1, 3, 2, 4])
    }

    // MARK: G3 The list's column headers

    /// G3: every key has a column, and a click on its header comes back as that key.
    @Test func everySortIsAColumnSortOrderAndBack() {
        for key in BookSortKey.allCases {
            for ascending in [true, false] {
                let sort = BookSort(key: key, ascending: ascending)
                let order = sort.tableSortOrder
                #expect(order.count == 1)
                #expect(order.first?.order == (ascending ? .forward : .reverse))
                #expect(BookSort(tableSortOrder: order) == sort)
            }
        }
        // Each key's column is keyed by something of its own.
        #expect(Set(BookSortKey.allCases.map { BookSort(key: $0).tableSortOrder[0].keyPath }).count
            == BookSortKey.allCases.count)
    }

    /// G3: a column of text is named with the comparator a table's text column has. With
    /// any other the table does not know its own column: no arrow, and no change of direction.
    @Test func textColumnsUseTheTablesOwnComparator() {
        for key in [BookSortKey.title, .author, .series, .status] {
            for order in [SortOrder.forward, .reverse] {
                let ours = BookSort(key: key, ascending: order == .forward).tableSortOrder[0]
                let standard = String.StandardComparator.localizedStandard
                let expected: [KeyPathComparator<BookRow>] = [
                    KeyPathComparator(\.titleSortKey, comparator: standard, order: order),
                    KeyPathComparator(\.authorSortKey, comparator: standard, order: order),
                    KeyPathComparator(\.seriesSortKey, comparator: standard, order: order),
                    KeyPathComparator(\.statusSortKey, comparator: standard, order: order),
                ]
                #expect(expected.contains(ours), "\(key) \(order)")
                #expect(String(describing: ours).contains("StandardComparator"))
            }
        }
    }

    /// G3: a table hands back the clicked column first and the earlier ones after it; only the first counts.
    @Test func theFirstColumnOfASortOrderIsTheSort() {
        let order = BookSort(key: .length, ascending: false).tableSortOrder + BookSort(key: .title).tableSortOrder
        #expect(BookSort(tableSortOrder: order) == BookSort(key: .length, ascending: false))
        #expect(BookSort(tableSortOrder: []) == nil)
        // A column that is not one of the sort keys.
        #expect(BookSort(tableSortOrder: [KeyPathComparator(\BookRow.id)]) == nil)
    }
}
