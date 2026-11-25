import Foundation

/// One line of the Up Next list.
public enum UpNextItem: Equatable, Sendable {
    /// A book of the library.
    case book(Book)
    /// The next book of a series, which the library does not have.
    case missing(MissingEntry, SeriesLink)
}

/// What to pick up now: the books being read, then the next book of each series that
/// has been begun, then the books put on the list by hand.
public struct UpNextList: Equatable, Sendable {
    public var inProgress: [Book] = []
    public var nextInSeries: [UpNextItem] = []
    public var queued: [Book] = []

    public init() {}

    /// Every line in order, a book of the library no more than once.
    public var items: [UpNextItem] {
        var seen = Set<Int64>()
        var out: [UpNextItem] = []
        for book in inProgress where book.id.map({ seen.insert($0).inserted }) ?? false { out.append(.book(book)) }
        for item in nextInSeries {
            if case .book(let book) = item, !(book.id.map { seen.insert($0).inserted } ?? false) { continue }
            out.append(item)
        }
        for book in queued where book.id.map({ seen.insert($0).inserted }) ?? false { out.append(.book(book)) }
        return out
    }
}

enum UpNextRules {
    /// A place in a series as a number, for putting books in order: "3" is 3, "2.5"
    /// is 2.5, "1-3" is 1. Nil for a book with no number, which has no place.
    static func place(_ number: String?) -> Double? {
        guard let text = number?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let value = Double(text) { return value }
        let lead = text.prefix { $0.isNumber || $0 == "." }
        return Double(lead)
    }

    /// The next book of one series: the one that comes after the furthest book that is
    /// finished, by number, whether the library has it or not. Nil when the series has
    /// not been begun, when the furthest book begun is still being read (that book is
    /// what is up next), and when nothing comes after.
    ///
    /// - Parameters:
    ///   - books: The library's books of the series.
    ///   - missing: The books of the series the library lacks, those the owner has
    ///     hidden left out, each with its place.
    static func next(
        among books: [Book], missing: [(entry: MissingEntry, place: Double)], link: SeriesLink?
    ) -> UpNextItem? {
        let placed = books.compactMap { book in place(book.seriesNumber).map { (book: book, place: $0) } }
        guard let furthest = placed.filter({ $0.book.readStatus != .unread }).max(by: { $0.place < $1.place }),
              furthest.book.readStatus == .finished
        else { return nil }
        let own = placed.filter { $0.place > furthest.place && $0.book.readStatus == .unread }
            .min { ($0.place, $0.book.title) < ($1.place, $1.book.title) }
        let lacking = missing.filter { $0.place > furthest.place }.min { $0.place < $1.place }
        switch (own, lacking, link) {
        case (let own?, let lacking?, let link?) where lacking.place < own.place: return .missing(lacking.entry, link)
        case (let own?, _, _): return .book(own.book)
        case (nil, let lacking?, let link?): return .missing(lacking.entry, link)
        default: return nil
        }
    }
}
