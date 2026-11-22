import Foundation

/// One book of a series as Audible lists it: every edition with the same number, as one.
public struct SeriesEntry: Equatable, Sendable {
    /// Nil for a member with no number.
    public var number: String?
    /// The lowest of its editions' ordering values.
    public var sort: Double
    public var preferred: AudibleSeriesEdition
    /// Every edition folded in, the preferred first.
    public var asins: [String]
    /// Every title its editions go by, the preferred's first: editions of one book are
    /// not always called the same.
    public var titles: [String]

    public init(number: String?, sort: Double, preferred: AudibleSeriesEdition, asins: [String], titles: [String]) {
        self.number = number
        self.sort = sort
        self.preferred = preferred
        self.asins = asins
        self.titles = titles
    }
}

/// What matching needs to know of a library book in the series.
public struct LibrarySeriesBook: Equatable, Sendable {
    public var id: Int64
    public var title: String
    public var number: String?
    /// The book's own ASIN and its Audible copies' IDs.
    public var asins: [String]

    public init(id: Int64, title: String, number: String?, asins: [String]) {
        self.id = id
        self.title = title
        self.number = number
        self.asins = asins
    }
}

public struct SeriesMatchResult: Equatable, Sendable {
    public struct Owned: Equatable, Sendable {
        public var bookId: Int64
        public var entry: SeriesEntry
        /// True when the book and the entry both have a number and they are not the same.
        public var numberDiffers: Bool

        public init(bookId: Int64, entry: SeriesEntry, numberDiffers: Bool) {
            self.bookId = bookId
            self.entry = entry
            self.numberDiffers = numberDiffers
        }
    }

    /// In series order.
    public var owned: [Owned]
    /// The entries no library book matched, in series order.
    public var missing: [SeriesEntry]
    /// The library books the list does not include, by id.
    public var notInList: [Int64]

    public init(owned: [Owned], missing: [SeriesEntry], notInList: [Int64]) {
        self.owned = owned
        self.missing = missing
        self.notInList = notInList
    }
}

/// Works out which books of a series the library has. Reads nothing and asks nothing:
/// the same editions and books give the same answer in whatever order they are given.
public enum SeriesMatch {
    // MARK: Folding

    /// One entry for each number, in series order: by the lowest ordering value among
    /// an entry's editions, then number (plain numbers by value), then title.
    ///
    /// Editions fold when their numbers are the same ("01" and "1.0" are "1"); a range
    /// such as "1-3" is a number of its own. Editions with no number fold only with
    /// others of the same title, as the lookup compares titles.
    ///
    /// `owned`: the ASINs the library has. An entry's preferred edition is one of those;
    /// failing that an unabridged one (or one that does not say) over an abridged; the
    /// longest; the earliest released; the lowest ASIN. An edition with no length, or
    /// released after the year 2100, only holds a place: it is preferred only when the
    /// entry has no other.
    public static func entries(from editions: [AudibleSeriesEdition], preferring owned: Set<String>) -> [SeriesEntry] {
        let owned = Set(owned.map(tidyASIN))
        // Each edition once, whatever order they came in.
        var seen: Set<String> = []
        let editions = editions.sorted(by: stably).filter { seen.insert(tidyASIN($0.asin)).inserted }

        var groups: [String: [AudibleSeriesEdition]] = [:]
        for edition in editions { groups[foldKey(edition), default: []].append(edition) }

        let entries: [SeriesEntry] = groups.values.compactMap { group in
            let ordered = group.sorted { isPreferred($0, to: $1, owned: owned) }
            guard let preferred = ordered.first else { return nil }
            var titles: [String] = []
            for edition in ordered where !titles.contains(edition.title) { titles.append(edition.title) }
            return SeriesEntry(
                number: preferred.number?.nonBlank, sort: ordered.map(\.sort).min() ?? preferred.sort,
                preferred: preferred, asins: ordered.map(\.asin), titles: titles)
        }
        return entries.sorted(by: inSeriesOrder)
    }

    /// What editions of one book share: their number, or with none their title, or with
    /// no title either nothing but themselves.
    private static func foldKey(_ edition: AudibleSeriesEdition) -> String {
        if let number = numberKey(edition.number) { return "number " + number }
        let title = LookupText.comparable(edition.title)
        return title.isEmpty ? "edition " + tidyASIN(edition.asin) : "title " + title.joined(separator: " ")
    }

    /// A number for comparing: "01" and "1.0" are "1"; anything that is not a plain
    /// number is itself, trimmed, whatever its case. Nil for none.
    private static func numberKey(_ number: String?) -> String? {
        guard let text = number?.nonBlank else { return nil }
        if let value = SeriesNumber.value(text) { return String(value) }
        return "text " + text.lowercased()
    }

    /// Whether two numbers are the same number; false when either is missing.
    static func sameNumber(_ first: String?, _ second: String?) -> Bool {
        guard let first = numberKey(first), let second = numberKey(second) else { return false }
        return first == second
    }

    /// The start of 2101, in seconds since 1970: later than this is after the year 2100.
    static let endOf2100 = Date(timeIntervalSince1970: 4_133_980_800)

    /// An edition that only holds a place in the catalogue.
    static func isPlaceholder(_ edition: AudibleSeriesEdition) -> Bool {
        if edition.minutes == nil { return true }
        if let released = edition.releaseDate, released >= endOf2100 { return true }
        return false
    }

    private static func isPreferred(_ a: AudibleSeriesEdition, to b: AudibleSeriesEdition, owned: Set<String>) -> Bool {
        let placeholders = (isPlaceholder(a), isPlaceholder(b))
        if placeholders.0 != placeholders.1 { return !placeholders.0 }
        let has = (owned.contains(tidyASIN(a.asin)), owned.contains(tidyASIN(b.asin)))
        if has.0 != has.1 { return has.0 }
        let abridged = (a.isAbridged == true, b.isAbridged == true)
        if abridged.0 != abridged.1 { return !abridged.0 }
        let minutes = (a.minutes ?? 0, b.minutes ?? 0)
        if minutes.0 != minutes.1 { return minutes.0 > minutes.1 }
        let released = (a.releaseDate ?? .distantFuture, b.releaseDate ?? .distantFuture)
        if released.0 != released.1 { return released.0 < released.1 }
        return stably(a, b)
    }

    /// An order that leaves nothing to the order things were given in.
    private static func stably(_ a: AudibleSeriesEdition, _ b: AudibleSeriesEdition) -> Bool {
        let asins = (tidyASIN(a.asin), tidyASIN(b.asin))
        if asins.0 != asins.1 { return asins.0 < asins.1 }
        if a.title != b.title { return a.title < b.title }
        if a.number != b.number { return (a.number ?? "") < (b.number ?? "") }
        if a.sort != b.sort { return a.sort < b.sort }
        if a.minutes != b.minutes { return (a.minutes ?? -1) < (b.minutes ?? -1) }
        if a.releaseDate != b.releaseDate { return (a.releaseDate ?? .distantPast) < (b.releaseDate ?? .distantPast) }
        if a.isAbridged != b.isAbridged { return a.isAbridged == nil || (a.isAbridged == false && b.isAbridged == true) }
        if a.authors != b.authors { return a.authors.lexicographicallyPrecedes(b.authors) }
        return a.narrators.lexicographicallyPrecedes(b.narrators)
    }

    private static func inSeriesOrder(_ a: SeriesEntry, _ b: SeriesEntry) -> Bool {
        if a.sort != b.sort { return a.sort < b.sort }
        if let precedes = SeriesNumber.precedes(a.number, b.number) { return precedes }
        let titles = (LookupText.comparable(a.preferred.title).joined(separator: " "),
                      LookupText.comparable(b.preferred.title).joined(separator: " "))
        if titles.0 != titles.1 { return titles.0 < titles.1 }
        if a.preferred.title != b.preferred.title { return a.preferred.title < b.preferred.title }
        return a.asins.lexicographicallyPrecedes(b.asins)
    }

    private static func tidyASIN(_ asin: String) -> String {
        asin.lookupTrimmed.uppercased()
    }

    // MARK: Matching

    /// Pairs library books with entries: each book with at most one entry and each entry
    /// with at most one book.
    ///
    /// A book is the entry that holds any of its ASINs. Failing that, the entry one of
    /// whose titles is the book's, as the lookup compares titles. Failing that, an entry
    /// with the book's number whose title is the book's with a subtitle after it, or
    /// the other way round. Nothing cleverer: a wrong match hides a missing book.
    ///
    /// Matches by ASIN are made first, then by title, then by subtitle and number; of
    /// two books that could be one entry, the one with the lower id is.
    public static func match(_ entries: [SeriesEntry], with books: [LibrarySeriesBook]) -> SeriesMatchResult {
        let entries = entries.sorted(by: inSeriesOrder)
        let books = books.sorted { $0.id < $1.id }
        /// The index of the book each entry went to.
        var bookOfEntry: [Int: Int] = [:]
        var matched: Set<Int> = []

        /// Gives each book still without an entry the first free entry that fits it.
        func pair(_ fits: (_ book: Int, _ entry: Int) -> Bool) {
            for book in books.indices where !matched.contains(book) {
                guard let entry = entries.indices.first(where: { bookOfEntry[$0] == nil && fits(book, $0) }) else { continue }
                bookOfEntry[entry] = book
                matched.insert(book)
            }
        }

        let entryASINs = entries.map { Set($0.asins.map(tidyASIN)) }
        let entryTitles = entries.map { $0.titles.map(Title.init) }
        let bookTitles = books.map { Title($0.title) }

        func sameTitle(_ book: Int, _ entry: Int) -> Bool {
            let words = bookTitles[book].words
            return !words.isEmpty && entryTitles[entry].contains { $0.words == words }
        }
        func numbersAgree(_ book: Int, _ entry: Int) -> Bool {
            Self.sameNumber(books[book].number, entries[entry].number)
        }

        pair { book, entry in books[book].asins.contains { entryASINs[entry].contains(tidyASIN($0)) } }
        // Of several entries with the book's title, the one with its number.
        pair { sameTitle($0, $1) && numbersAgree($0, $1) }
        pair(sameTitle)
        pair { book, entry in
            numbersAgree(book, entry)
                && entryTitles[entry].contains { $0.isSubtitled(bookTitles[book]) || bookTitles[book].isSubtitled($0) }
        }

        var result = SeriesMatchResult(owned: [], missing: [], notInList: [])
        for (index, entry) in entries.enumerated() {
            guard let bookIndex = bookOfEntry[index] else {
                result.missing.append(entry)
                continue
            }
            let book = books[bookIndex]
            let differs = book.number?.nonBlank != nil && entry.number?.nonBlank != nil
                && !sameNumber(book.number, entry.number)
            result.owned.append(SeriesMatchResult.Owned(bookId: book.id, entry: entry, numberDiffers: differs))
        }
        result.notInList = books.indices.filter { !matched.contains($0) }.map { books[$0].id }
        return result
    }

    /// A title for comparing: its words as the lookup compares titles, and the words of
    /// each of its beginnings that a subtitle could follow.
    private struct Title {
        var words: [String]
        var heads: [[String]] = []

        /// What divides a title from its subtitle: a colon; a dash with a space on each
        /// side; an opening bracket after a space.
        private static let dividers = [":", " - ", " – ", " — ", " (", " ["]

        init(_ text: String) {
            words = LookupText.comparable(text)
            for divider in Self.dividers {
                var from = text.startIndex
                while let found = text.range(of: divider, range: from..<text.endIndex) {
                    let head = LookupText.comparable(String(text[..<found.lowerBound]))
                    // Something before the divider, and something after it.
                    if !head.isEmpty, head.count < words.count, !heads.contains(head) { heads.append(head) }
                    from = found.upperBound
                }
            }
        }

        /// True when this title is `other` with a subtitle after it.
        func isSubtitled(_ other: Title) -> Bool {
            !other.words.isEmpty && heads.contains(other.words)
        }
    }
}
