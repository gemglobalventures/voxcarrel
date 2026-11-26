import Foundation
import VoxCarrelCore

// Group by Series (plan 10). GS1–GS8.
//
// A list's books as the list and the grid draw them when books are grouped by series:
// each item a book, or a series holding its books. Grouping is worked out from the rows
// the model already has; the selection stays a set of book ids, and nothing here asks
// the library anything.

/// What names one item of the list or the grid: a book, by its id, or a series group, by
/// the series' name. Only for the table and the grid; every command still takes book ids.
public enum ItemID: Hashable, Sendable {
    case book(Int64)
    case series(String)
}

/// The books of one series, shown as one row of the list or one stack of covers.
public struct SeriesGroup: Identifiable, Equatable, Sendable {
    public var id: ItemID { .series(name) }
    /// The series text exactly as the books have it: what Browse ▸ Series calls it.
    public var name: String
    /// In the order of the series; at least two.
    public var books: [BookRow]

    public init(name: String, books: [BookRow]) {
        self.name = name
        self.books = books
    }

    public var titleText: String { name }

    /// "5 books"
    public var countText: String {
        "\(books.count) books"
    }

    /// The one author all the books share, going by each book's first author and
    /// ignoring case; "Various" when they differ; empty when no book has an author.
    public var authorsText: String {
        let first = books.first?.firstAuthorText ?? ""
        let shared = books.allSatisfy { $0.firstAuthorText.compare(first, options: .caseInsensitive) == .orderedSame }
        return shared ? first : "Various"
    }

    /// The length of the books that have one, together; nil when none has.
    var totalSeconds: Double? {
        let lengths = books.compactMap(\.book.durationSeconds).filter { $0.isFinite && $0 > 0 }
        return lengths.isEmpty ? nil : lengths.reduce(0, +)
    }

    /// The pages of the books that have a page count, together; nil when none has.
    public var totalPages: Int? {
        let pages = books.compactMap(\.book.pageCount).filter { $0 > 0 }
        return pages.isEmpty ? nil : pages.reduce(0, +)
    }

    /// The total as a book's length is written; empty when no book has a length.
    public var lengthText: String {
        LengthText.text(seconds: totalSeconds) ?? ""
    }

    /// When the book added last was added.
    public var newestAdded: Date {
        books.map(\.book.dateAdded).max() ?? .distantPast
    }

    /// "2 of 5 finished", "All finished", "None started"
    public var statusText: String {
        let finished = books.filter { $0.book.readStatus == .finished }.count
        if finished == books.count { return "All finished" }
        if books.allSatisfy({ $0.book.readStatus == .unread }) { return "None started" }
        return "\(finished) of \(books.count) finished"
    }

    /// The same for the Status column of the list, which has no room for the last
    /// word: "2 of 5", "All finished", "None started". `statusText` is its tooltip.
    public var statusColumnText: String {
        let finished = books.filter { $0.book.readStatus == .finished }.count
        if finished == books.count || books.allSatisfy({ $0.book.readStatus == .unread }) { return statusText }
        return "\(finished) of \(books.count)"
    }

    public var hasAudio: Bool { books.contains(where: \.hasAudio) }
    public var hasEbook: Bool { books.contains(where: \.hasEbook) }
    public var isOnAudible: Bool { books.contains(where: \.isOnAudible) }
    public var isOnKindle: Bool { books.contains(where: \.isOnKindle) }

    /// Whether any of the books has audio files here, and whether any has an ebook
    /// here: when the group shows the headphones and the book, as a book's own row
    /// shows them only for files that are on this Mac.
    public var hasAudioFiles: Bool { books.contains { $0.hasFiles && $0.hasAudio } }
    public var hasEbookFiles: Bool { books.contains { $0.hasFiles && $0.hasEbook } }

    /// What the warning triangle is for: how many of the books have one of their own.
    /// Nil when none has.
    public var warningText: String? {
        let count = books.filter { $0.warningText != nil }.count
        switch count {
        case 0: return nil
        case 1: return "1 book needs attention"
        default: return "\(count) books need attention"
        }
    }

    /// The books whose covers stand for the group: the first three in series order.
    public var coverRows: [BookRow] {
        Array(books.prefix(3))
    }

    /// For the tooltip and VoiceOver: the name, the author, and the rest in one line.
    public var summaryText: String {
        let facts = [countText, lengthText, statusText, warningText ?? ""].filter { !$0.isEmpty }
        return [titleText, authorsText, facts.joined(separator: " · ")]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// GS4: what the group is ordered by among the books: its name for a title and for
    /// a series, its first book's author, its total length, its newest book's day, the
    /// formats of all its books together, and the least advanced status of any. For
    /// Edition, the first kind in the sort's order that any of its books has. Its lowest
    /// book id breaks a tie with a book of the same title.
    var sortValues: BookSort.SortValues {
        BookSort.SortValues(
            title: name, id: books.map(\.id).min() ?? 0, firstAuthor: books.first?.book.authors.first, series: name,
            seriesNumber: nil,
            formatRank: BookSort.formatRank(
                hasAudio: hasAudio, hasEbook: hasEbook, hasFiles: books.contains { $0.hasAudio && $0.hasFiles }),
            length: totalSeconds, added: newestAdded,
            statusRank: books.map { BookSort.statusRank($0.book.readStatus) }.min() ?? 0,
            editionRank: books.compactMap(BookSort.editionRank).min(),
            firstGenre: books.first?.book.genres.first, pages: totalPages)
    }
}

/// One thing the list or the grid shows: a book, or a series with its books.
public enum LibraryItem: Identifiable, Equatable, Sendable {
    case book(BookRow)
    case series(SeriesGroup)

    public var id: ItemID {
        switch self {
        case .book(let row): .book(row.id)
        case .series(let group): group.id
        }
    }

    /// The books the item stands for: the one, or the group's in series order.
    public var books: [BookRow] {
        switch self {
        case .book(let row): [row]
        case .series(let group): group.books
        }
    }
}

public enum SeriesGrouping {
    /// The rows as items. Not `grouped`: each row a book, in the order given (GS1).
    ///
    /// `grouped`: the rows that share a series text, exactly, are one group when there
    /// are two or more of them (GS2), its books in the order of the series (GS3); the
    /// groups stand among the other books where `sort` puts them (GS4). Rows that stand
    /// for books the library does not have (ids of zero or less) are left out (GS5):
    /// they belong to a single series' own view, which is never grouped.
    public static func items(from rows: [BookRow], sort: BookSort, grouped: Bool) -> [LibraryItem] {
        guard grouped else { return rows.map(LibraryItem.book) }
        var singles: [BookRow] = []
        var members: [String: [BookRow]] = [:]
        for row in rows where row.id > 0 && !row.isMissing {
            if let series = row.book.series, series.trimmedOrNil != nil {
                members[series, default: []].append(row)
            } else {
                singles.append(row)
            }
        }
        var items = singles.map(LibraryItem.book)
        for (name, books) in members {
            if books.count < 2 {
                items += books.map(LibraryItem.book)
            } else {
                items.append(.series(SeriesGroup(name: name, books: BookSort.inSeriesOrder(books))))
            }
        }
        return sort.arranged(items) { item in
            switch item {
            case .book(let row): BookSort.SortValues(row: row)
            case .series(let group): group.sortValues
            }
        }
    }
}
