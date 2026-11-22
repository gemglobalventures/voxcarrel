import Foundation
import VoxCarrelCore

public enum BookSortKey: String, CaseIterable, Sendable {
    case title, author, series, formats, length, dateAdded, status
    /// Unabridged, abridged, dramatised; books whose edition is not known last.
    case edition
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
    public func sorted(_ rows: [BookRow], showing item: SidebarItem? = nil) -> [BookRow] {
        if key == .title, case .browse(.series, _)? = item {
            var inSeriesOrder = self
            inSeriesOrder.bySeriesNumber = true
            return inSeriesOrder.sorted(rows)
        }
        var valued: [BookRow] = []
        var valueless: [BookRow] = []
        for row in rows {
            if hasValue(row) { valued.append(row) } else { valueless.append(row) }
        }
        return ordered(valued) + ordered(valueless)
    }

    private func ordered(_ rows: [BookRow]) -> [BookRow] {
        rows.sorted { a, b in
            let result = compare(a, b)
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    // MARK: Values

    private static func text(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func firstAuthor(_ row: BookRow) -> String? { text(row.book.authors.first) }

    /// 0 audio only, 1 an audiobook that is only owned elsewhere (on Audible), 2 audio
    /// and ebook, 3 ebook only; nil when the book has neither.
    private static func formatRank(_ row: BookRow) -> Int? {
        switch (row.hasAudio, row.hasEbook) {
        case (true, false): row.hasFiles ? 0 : 1
        case (true, true): 2
        case (false, true): 3
        case (false, false): nil
        }
    }

    /// Unread, in progress, finished.
    private static func statusRank(_ row: BookRow) -> Int {
        switch row.book.readStatus {
        case .unread: 0
        case .inProgress: 1
        case .finished: 2
        }
    }

    /// Unabridged, abridged, dramatised.
    private static func editionRank(_ row: BookRow) -> Int? {
        switch row.book.editionKind?.kind {
        case .unabridged: 0
        case .abridged: 1
        case .dramatised: 2
        case nil: nil
        }
    }

    private func hasValue(_ row: BookRow) -> Bool {
        if bySeriesNumber { return Self.text(row.book.seriesNumber) != nil }
        return switch key {
        case .title, .dateAdded, .status: true
        case .author: Self.firstAuthor(row) != nil
        case .series: Self.text(row.book.series) != nil
        case .formats: Self.formatRank(row) != nil
        case .length: row.book.durationSeconds != nil
        case .edition: Self.editionRank(row) != nil
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
    private static func compareSeriesNumbers(_ a: String?, _ b: String?) -> ComparisonResult {
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
    private func compare(_ a: BookRow, _ b: BookRow) -> ComparisonResult {
        var result: ComparisonResult = .orderedSame
        switch key {
        case .title:
            if bySeriesNumber { result = Self.compareSeriesNumbers(a.book.seriesNumber, b.book.seriesNumber) }
        case .author:
            result = Self.compareText(Self.firstAuthor(a) ?? "", Self.firstAuthor(b) ?? "")
        case .series:
            result = Self.compareText(Self.text(a.book.series) ?? "", Self.text(b.book.series) ?? "")
            if result == .orderedSame {
                result = Self.compareSeriesNumbers(a.book.seriesNumber, b.book.seriesNumber)
            }
        case .formats:
            result = Self.compareValues(Self.formatRank(a) ?? .max, Self.formatRank(b) ?? .max)
        case .length:
            result = Self.compareValues(a.book.durationSeconds ?? 0, b.book.durationSeconds ?? 0)
        case .dateAdded:
            result = Self.compareValues(a.book.dateAdded, b.book.dateAdded)
        case .status:
            result = Self.compareValues(Self.statusRank(a), Self.statusRank(b))
        case .edition:
            result = Self.compareValues(Self.editionRank(a) ?? .max, Self.editionRank(b) ?? .max)
        }
        if result == .orderedSame { result = Self.compareText(a.book.title, b.book.title) }
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
    public var dateAddedSortKey: Date { book.dateAdded }
    public var statusSortKey: String { book.readStatus.rawValue }
    public var editionSortKey: String { book.editionKind?.kind.rawValue ?? "" }
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
        case .dateAdded: KeyPathComparator(\.dateAddedSortKey, order: order)
        case .status: KeyPathComparator(\.statusSortKey, comparator: text, order: order)
        case .edition: KeyPathComparator(\.editionSortKey, comparator: text, order: order)
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
