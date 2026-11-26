import Foundation
import VoxCarrelCore

public enum BookSortKey: String, CaseIterable, Sendable {
    case title, author, series, formats, length, pages, dateAdded, status
    /// Unabridged, abridged, dramatised; books whose edition is not known last.
    case edition
    /// G37: by a book's first genre; books with no genre last.
    case genre
}

/// How the grid and the list order their books.
public struct BookSort: Equatable, Sendable {
    public var key: BookSortKey = .title
    public var ascending = true
    /// Set only while one series is being put in its own order (`sorted(_:showing:)`).
    private var bySeriesNumber = false

    public init(key: BookSortKey = .title, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }

    /// The rows in this order. Text is compared ignoring case, with numbers inside it in
    /// natural order. Every key breaks ties by title and then id, so the result does not
    /// depend on the order the rows arrive in.
    ///
    /// Rows that have no value for the key (no author, no series, no audio or ebook
    /// file, no duration) come last. Descending reverses the whole order, ties included,
    /// except that those rows still come last.
    ///
    /// The books of one series (`item` is that series in the sidebar) are shown in the
    /// order of the series while the sort is by title, which is the sort nobody has
    /// chosen: by number, numerically where the numbers are numbers, books with no
    /// number last, ties by title. Any other key is the user's choice and is kept.
    ///
    /// Plan 9, SV5: rows that stand for books the library does not have (`isMissing`)
    /// fall in place by number in the order of the series. Under any other sort they
    /// come after the library's books, in the order of the series, whichever way the
    /// sort runs: they have no place among books sorted by what a library book has.
    public func sorted(_ rows: [BookRow], showing item: SidebarItem? = nil) -> [BookRow] {
        // Up Next has an order of its own, whatever the sort.
        if case .upNext? = item { return rows }
        if key == .title, case .browse(.series, _)? = item {
            var inSeriesOrder = self
            inSeriesOrder.bySeriesNumber = true
            return inSeriesOrder.arranged(rows)
        }
        let missing = rows.filter(\.isMissing)
        guard !missing.isEmpty else { return arranged(rows) }
        return arranged(rows.filter { !$0.isMissing }) + Self.inSeriesOrder(missing)
    }

    /// The books of one series in the order of the series: by number, numerically where
    /// the numbers are numbers, books with no number last, ties by title. The order a
    /// single series' view shows, and the order of the books inside a series group.
    static func inSeriesOrder(_ rows: [BookRow]) -> [BookRow] {
        var inSeriesOrder = BookSort()
        inSeriesOrder.bySeriesNumber = true
        return inSeriesOrder.arranged(rows)
    }

    private func arranged(_ rows: [BookRow]) -> [BookRow] {
        arranged(rows, by: SortValues.init(row:))
    }

    /// Anything in this order that can say what it is ordered by: books, and series
    /// groups among them. Those with no value for the key come last, as rows do.
    func arranged<Element>(_ elements: [Element], by values: (Element) -> SortValues) -> [Element] {
        var valued: [(SortValues, Element)] = []
        var valueless: [(SortValues, Element)] = []
        for element in elements {
            let entry = (values(element), element)
            if hasValue(entry.0) { valued.append(entry) } else { valueless.append(entry) }
        }
        return (ordered(valued) + ordered(valueless)).map(\.1)
    }

    private func ordered<Element>(_ entries: [(SortValues, Element)]) -> [(SortValues, Element)] {
        entries.sorted { a, b in
            let result = compare(a.0, b.0)
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    // MARK: Values

    /// What one thing in the list is ordered by, under every key: a book's own values,
    /// or a series group's (`SeriesGroup.sortValues`).
    struct SortValues {
        /// Compared last but for `id`, under every key.
        var title: String
        /// Breaks the last tie.
        var id: Int64
        var firstAuthor: String?
        var series: String?
        var seriesNumber: String?
        var formatRank: Int?
        var length: Double?
        var pages: Int?
        var added: Date
        var statusRank: Int
        var editionRank: Int?
        var firstGenre: String?

        init(
            title: String, id: Int64, firstAuthor: String?, series: String?, seriesNumber: String?,
            formatRank: Int?, length: Double?, added: Date, statusRank: Int, editionRank: Int?,
            firstGenre: String? = nil, pages: Int? = nil
        ) {
            self.pages = pages.flatMap { $0 > 0 ? $0 : nil }
            self.title = title
            self.id = id
            self.firstAuthor = BookSort.text(firstAuthor)
            self.series = BookSort.text(series)
            self.seriesNumber = BookSort.text(seriesNumber)
            self.formatRank = formatRank
            self.length = length
            self.added = added
            self.statusRank = statusRank
            self.editionRank = editionRank
            self.firstGenre = BookSort.text(firstGenre)
        }

        init(row: BookRow) {
            self.init(
                title: row.book.title, id: row.id, firstAuthor: row.book.authors.first, series: row.book.series,
                seriesNumber: row.book.seriesNumber,
                formatRank: BookSort.formatRank(hasAudio: row.hasAudio, hasEbook: row.hasEbook, hasFiles: row.hasFiles),
                length: row.book.durationSeconds, added: row.book.dateAdded,
                statusRank: BookSort.statusRank(row.book.readStatus), editionRank: BookSort.editionRank(row),
                firstGenre: row.book.genres.first, pages: row.book.pageCount)
        }
    }

    private static func text(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// 0 audio only, 1 an audiobook that is only owned elsewhere (on Audible), 2 audio
    /// and ebook, 3 ebook only; nil when the book has neither.
    static func formatRank(hasAudio: Bool, hasEbook: Bool, hasFiles: Bool) -> Int? {
        switch (hasAudio, hasEbook) {
        case (true, false): hasFiles ? 0 : 1
        case (true, true): 2
        case (false, true): 3
        case (false, false): nil
        }
    }

    /// Unread, in progress, finished.
    static func statusRank(_ status: ReadStatus) -> Int {
        switch status {
        case .unread: 0
        case .inProgress: 1
        case .finished: 2
        }
    }

    /// Unabridged, abridged, dramatised.
    static func editionRank(_ row: BookRow) -> Int? {
        switch row.book.editionKind?.kind {
        case .unabridged: 0
        case .abridged: 1
        case .dramatised: 2
        case .notKnown, nil: nil
        }
    }

    private func hasValue(_ values: SortValues) -> Bool {
        if bySeriesNumber { return values.seriesNumber != nil }
        return switch key {
        case .title, .dateAdded, .status: true
        case .author: values.firstAuthor != nil
        case .series: values.series != nil
        case .formats: values.formatRank != nil
        case .length: values.length != nil
        case .pages: values.pages != nil
        case .edition: values.editionRank != nil
        case .genre: values.firstGenre != nil
        }
    }

    // MARK: Comparing

    private static func compareText(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: [.caseInsensitive, .numeric])
    }

    private static func compareValues<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    /// Numbers first, in numeric order; then numbers that are not numbers ("1-3") as
    /// text; then books with no number.
    static func compareSeriesNumbers(_ a: String?, _ b: String?) -> ComparisonResult {
        func parts(_ value: String?) -> (group: Int, number: Double, text: String) {
            guard let value = text(value) else { return (2, 0, "") }
            if let number = Double(value), number.isFinite { return (0, number, value) }
            return (1, 0, value)
        }
        let (x, y) = (parts(a), parts(b))
        if x.group != y.group { return compareValues(x.group, y.group) }
        if x.number != y.number { return compareValues(x.number, y.number) }
        return compareText(x.text, y.text)
    }

    /// The ascending order for the key, ending with title and then id.
    private func compare(_ a: SortValues, _ b: SortValues) -> ComparisonResult {
        var result: ComparisonResult = .orderedSame
        switch key {
        case .title:
            if bySeriesNumber { result = Self.compareSeriesNumbers(a.seriesNumber, b.seriesNumber) }
        case .author:
            result = Self.compareText(a.firstAuthor ?? "", b.firstAuthor ?? "")
        case .series:
            result = Self.compareText(a.series ?? "", b.series ?? "")
            if result == .orderedSame {
                result = Self.compareSeriesNumbers(a.seriesNumber, b.seriesNumber)
            }
        case .formats:
            result = Self.compareValues(a.formatRank ?? .max, b.formatRank ?? .max)
        case .length:
            result = Self.compareValues(a.length ?? 0, b.length ?? 0)
        case .pages:
            result = Self.compareValues(a.pages ?? 0, b.pages ?? 0)
        case .dateAdded:
            result = Self.compareValues(a.added, b.added)
        case .status:
            result = Self.compareValues(a.statusRank, b.statusRank)
        case .edition:
            result = Self.compareValues(a.editionRank ?? .max, b.editionRank ?? .max)
        case .genre:
            result = Self.compareText(a.firstGenre ?? "", b.firstGenre ?? "")
        }
        if result == .orderedSame { result = Self.compareText(a.title, b.title) }
        if result == .orderedSame { result = Self.compareValues(a.id, b.id) }
        return result
    }
}

// MARK: The list's column headers

extension BookRow {
    // What the list's columns are keyed by, one for each sort key. A table names the
    // column whose header was clicked by its key path; `BookSort.sorted` does the
    // sorting, and nothing is ever compared by these values.
    public var titleSortKey: String { book.title }
    public var authorSortKey: String { book.authors.first ?? "" }
    public var seriesSortKey: String { book.series ?? "" }
    public var formatsSortKey: Int { (hasAudio ? 1 : 0) + (hasEbook ? 2 : 0) }
    public var lengthSortKey: Double { book.durationSeconds ?? 0 }
    public var pagesSortKey: Int { book.pageCount ?? 0 }
    public var dateAddedSortKey: Date { book.dateAdded }
    public var statusSortKey: String { book.readStatus.rawValue }
    public var editionSortKey: String {
        guard let kind = book.editionKind?.kind, kind != .notKnown else { return "" }
        return kind.rawValue
    }
    /// G37: the first genre.
    public var genreSortKey: String { book.genres.first ?? "" }
}

extension BookSortKey {
    /// This key's column as a table names it: the column's key path, with the comparator
    /// a `TableColumn` gives a column of that type. Both must be the table's own, or the
    /// table does not know its column again: it then shows no arrow in the header, and a
    /// click on the sorted column sorts the same way once more in place of the other way.
    func comparator(_ order: SortOrder) -> KeyPathComparator<BookRow> {
        // A column of text is compared with `String.StandardComparator`, which is not
        // the `String.Comparator` that a bare `.localizedStandard` would be taken for.
        let text = String.StandardComparator.localizedStandard
        return switch self {
        case .title: KeyPathComparator(\.titleSortKey, comparator: text, order: order)
        case .author: KeyPathComparator(\.authorSortKey, comparator: text, order: order)
        case .series: KeyPathComparator(\.seriesSortKey, comparator: text, order: order)
        case .formats: KeyPathComparator(\.formatsSortKey, order: order)
        case .length: KeyPathComparator(\.lengthSortKey, order: order)
        case .pages: KeyPathComparator(\.pagesSortKey, order: order)
        case .dateAdded: KeyPathComparator(\.dateAddedSortKey, order: order)
        case .status: KeyPathComparator(\.statusSortKey, comparator: text, order: order)
        case .edition: KeyPathComparator(\.editionSortKey, comparator: text, order: order)
        case .genre: KeyPathComparator(\.genreSortKey, comparator: text, order: order)
        }
    }
}

extension BookSort {
    /// This sort as a table's sort order: its key's column, forwards or in reverse.
    public var tableSortOrder: [KeyPathComparator<BookRow>] {
        [key.comparator(ascending ? .forward : .reverse)]
    }

    /// The sort a table's sort order asks for: the first column in it, which is the one
    /// whose header was clicked last. Nil when that is not the column of a sort key.
    public init?(tableSortOrder: [KeyPathComparator<BookRow>]) {
        guard let first = tableSortOrder.first,
              let key = BookSortKey.allCases.first(where: { $0.comparator(.forward).keyPath == first.keyPath })
        else { return nil }
        self.init(key: key, ascending: first.order == .forward)
    }
}

// MARK: The column headers of a list of items

extension LibraryItem {
    // What the columns of a table of items are keyed by: a book's are its row's, and a
    // series group's are what it is ordered by among the books (GS4). As with a row's,
    // nothing is ever compared by these values: they name the column that was clicked.
    public var titleSortKey: String {
        switch self {
        case .book(let row): row.titleSortKey
        case .series(let group): group.name
        }
    }

    public var authorSortKey: String {
        switch self {
        case .book(let row): row.authorSortKey
        case .series(let group): group.books.first?.authorSortKey ?? ""
        }
    }

    public var seriesSortKey: String {
        switch self {
        case .book(let row): row.seriesSortKey
        case .series(let group): group.name
        }
    }

    public var formatsSortKey: Int {
        switch self {
        case .book(let row): row.formatsSortKey
        case .series(let group): (group.hasAudio ? 1 : 0) + (group.hasEbook ? 2 : 0)
        }
    }

    public var lengthSortKey: Double {
        switch self {
        case .book(let row): row.lengthSortKey
        case .series(let group): group.totalSeconds ?? 0
        }
    }

    public var pagesSortKey: Int {
        switch self {
        case .book(let row): row.pagesSortKey
        case .series(let group): group.totalPages ?? 0
        }
    }

    public var dateAddedSortKey: Date {
        switch self {
        case .book(let row): row.dateAddedSortKey
        case .series(let group): group.newestAdded
        }
    }

    /// A group's is that of the least advanced of its books.
    public var statusSortKey: String {
        switch self {
        case .book(let row): row.statusSortKey
        case .series(let group):
            group.books.min { BookSort.statusRank($0.book.readStatus) < BookSort.statusRank($1.book.readStatus) }?
                .statusSortKey ?? ""
        }
    }

    /// A group's is the first kind, in the sort's order, that any of its books has.
    public var editionSortKey: String {
        switch self {
        case .book(let row): row.editionSortKey
        case .series(let group):
            group.books.filter { BookSort.editionRank($0) != nil }
                .min { (BookSort.editionRank($0) ?? .max) < (BookSort.editionRank($1) ?? .max) }?
                .editionSortKey ?? ""
        }
    }

    /// G37: a series stands where its first book's first genre puts it.
    public var genreSortKey: String {
        switch self {
        case .book(let row): row.genreSortKey
        case .series(let group): group.books.first?.genreSortKey ?? ""
        }
    }
}

extension BookSortKey {
    /// This key's column as a table of items names it: as `comparator(_:)`, which is
    /// for a table of books.
    func itemComparator(_ order: SortOrder) -> KeyPathComparator<LibraryItem> {
        let text = String.StandardComparator.localizedStandard
        return switch self {
        case .title: KeyPathComparator(\.titleSortKey, comparator: text, order: order)
        case .author: KeyPathComparator(\.authorSortKey, comparator: text, order: order)
        case .series: KeyPathComparator(\.seriesSortKey, comparator: text, order: order)
        case .formats: KeyPathComparator(\.formatsSortKey, order: order)
        case .length: KeyPathComparator(\.lengthSortKey, order: order)
        case .pages: KeyPathComparator(\.pagesSortKey, order: order)
        case .dateAdded: KeyPathComparator(\.dateAddedSortKey, order: order)
        case .status: KeyPathComparator(\.statusSortKey, comparator: text, order: order)
        case .edition: KeyPathComparator(\.editionSortKey, comparator: text, order: order)
        case .genre: KeyPathComparator(\.genreSortKey, comparator: text, order: order)
        }
    }
}

extension BookSort {
    /// This sort as the sort order of a table of items: its key's column, forwards or
    /// in reverse.
    public var itemSortOrder: [KeyPathComparator<LibraryItem>] {
        [key.itemComparator(ascending ? .forward : .reverse)]
    }

    /// The sort the sort order of a table of items asks for: the first column in it,
    /// which is the one whose header was clicked last. Nil when that is not the column
    /// of a sort key.
    public init?(itemSortOrder: [KeyPathComparator<LibraryItem>]) {
        guard let first = itemSortOrder.first,
              let key = BookSortKey.allCases.first(where: { $0.itemComparator(.forward).keyPath == first.keyPath })
        else { return nil }
        self.init(key: key, ascending: first.order == .forward)
    }
}
