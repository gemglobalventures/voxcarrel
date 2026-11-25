import Foundation

/// A series of the library tied to the series Audible lists it as.
public struct SeriesLink: Equatable, Sendable {
    /// The library's own name for the series.
    public var seriesName: String
    public var audibleSeriesId: String
    public var audibleSeriesTitle: String
    public var store: AudibleStore
    public var checkedAt: Date

    public init(
        seriesName: String, audibleSeriesId: String, audibleSeriesTitle: String, store: AudibleStore, checkedAt: Date
    ) {
        self.seriesName = seriesName
        self.audibleSeriesId = audibleSeriesId
        self.audibleSeriesTitle = audibleSeriesTitle
        self.store = store
        self.checkedAt = checkedAt
    }
}

/// A book of Audible's list that the library does not have.
public struct MissingEntry: Identifiable, Equatable, Sendable {
    /// The stored entry's row id.
    public var id: Int64
    public var entry: SeriesEntry
    public var isHidden: Bool

    public init(id: Int64, entry: SeriesEntry, isHidden: Bool) {
        self.id = id
        self.entry = entry
        self.isHidden = isHidden
    }
}

/// How much of a series the library has, by Audible's list of it.
public struct SeriesCompleteness: Equatable, Sendable {
    public var link: SeriesLink
    /// The entries the library has.
    public var ownedCount: Int
    /// The entries, hidden ones left out.
    public var totalCount: Int
    /// In series order; hidden ones included, flagged.
    public var missing: [MissingEntry]
    /// For each book numbered differently on Audible, Audible's number.
    public var numberDifferences: [Int64: String]
    /// The library's books of the series that the list does not include, by id.
    public var notInList: [Int64]

    public init(
        link: SeriesLink, ownedCount: Int, totalCount: Int, missing: [MissingEntry],
        numberDifferences: [Int64: String], notInList: [Int64]
    ) {
        self.link = link
        self.ownedCount = ownedCount
        self.totalCount = totalCount
        self.missing = missing
        self.numberDifferences = numberDifferences
        self.notInList = notInList
    }
}

/// Why a series' list could not be stored or changed. Nothing was changed.
public enum SeriesListError: Error, Equatable, Sendable {
    /// The list has no books: it would put nothing in place of what is stored.
    case emptyList
    /// No book of the library is in the series.
    case noBooks
    /// No stored entry has this id.
    case entryNotFound(Int64)
}

extension LibraryService {
    /// Every book of a series, with files or without, by id: each with its own ASIN and
    /// the item IDs of its Audible copies.
    ///
    /// A series is what the sidebar lists as one: the books whose series is exactly
    /// `name`. A blank name is no series.
    public func librarySeriesBooks(named name: String) throws -> [LibrarySeriesBook] {
        guard !name.isBlank else { return [] }
        let books = try store.books(where: .series, equals: name).compactMap { book -> LibrarySeriesBook? in
            guard let id = book.id else { return nil }
            var seen: Set<String> = []
            let own = [book.asin] + book.externalCopies.filter { $0.kind == .audible }.map(\.itemId)
            let asins = own.compactMap { $0?.nonBlank }.filter { seen.insert(SeriesMatch.tidyASIN($0)).inserted }
            return LibrarySeriesBook(id: id, title: book.title, number: book.seriesNumber?.nonBlank, asins: asins)
        }
        return books.sorted { $0.id < $1.id }
    }

    /// Stores Audible's list of a series, folded to one entry for each number and
    /// preferring the editions the library's books of that series have, in place of
    /// any link and list the series had. An entry that was hidden stays hidden while
    /// the list still has it: under the same number, or with the same preferred edition.
    /// A number says which book only within one Audible series: when the list is of
    /// another series than the one stored (another ID, or another store), only the
    /// same preferred edition keeps an entry hidden.
    ///
    /// A link whose series no book is in any more is deleted on the way. Not an
    /// undoable operation, and the one recorded is left as it is. No file is touched.
    ///
    /// - Throws: `SeriesListError.emptyList` for a list with no books, which is also
    ///   what a store that does not know the series answers: it never replaces what is
    ///   stored. `SeriesListError.noBooks` when no book is in the series. Nothing has
    ///   changed then.
    public func saveSeriesList(_ list: AudibleSeriesList, forSeries name: String, now: Date) throws {
        let books = try librarySeriesBooks(named: name)
        let entries = SeriesMatch.entries(from: list.editions, preferring: Set(books.flatMap(\.asins)))
        guard !entries.isEmpty else { throw SeriesListError.emptyList }
        guard !books.isEmpty else { throw SeriesListError.noBooks }

        let link = SeriesLinkRecord(
            id: nil, seriesKey: name, seriesName: name, audibleSeriesId: list.ref.id,
            audibleSeriesTitle: list.ref.title, store: list.ref.store.rawValue, checkedAt: now)
        try store.replaceSeriesList(link: link, entries: entries.map(SeriesEntryRecord.init)) { was, before, now in
            let sameSeries = was.store == link.store
                && SeriesMatch.tidyASIN(was.audibleSeriesId) == SeriesMatch.tidyASIN(link.audibleSeriesId)
            if sameSeries, SeriesMatch.sameNumber(before.number, now.number) { return true }
            guard let was = before.asins.first, let isNow = now.asins.first else { return false }
            return SeriesMatch.tidyASIN(was) == SeriesMatch.tidyASIN(isNow)
        }
    }

    /// How much of a series the library has, by the list stored for it and the
    /// library's books as they are now. Nil when the series is not linked. Asks nothing
    /// of the network.
    ///
    /// A book that is a second copy of one the list already counts as owned (it holds
    /// an ASIN of that entry, or goes by one of its titles) is not reported as missing
    /// from the list.
    ///
    /// An entry no book of the series matched is still owned when any book of the
    /// library holds one of its ASINs (its own, or an Audible copy's), whatever series
    /// that book is filed under: the book stays where it is, and is no book of this
    /// series. A title alone counts only for books of the series.
    ///
    /// An entry whose title is the title of an entry the library has (an edition with
    /// no number, listed beside the numbered one) is the same book again: it is not
    /// missing, and is not counted.
    public func seriesCompleteness(forSeries name: String) throws -> SeriesCompleteness? {
        guard let stored = try store.seriesList(key: name),
              let audibleStore = AudibleStore(rawValue: stored.link.store)
        else { return nil }
        let link = SeriesLink(
            seriesName: stored.link.seriesName, audibleSeriesId: stored.link.audibleSeriesId,
            audibleSeriesTitle: stored.link.audibleSeriesTitle, store: audibleStore, checkedAt: stored.link.checkedAt)

        let books = try librarySeriesBooks(named: name)
        let result = SeriesMatch.match(stored.entries.map(\.entry), with: books)

        /// Which row an entry came from: no two rows hold the same editions.
        func key(_ entry: SeriesEntry) -> [String] { entry.asins.map(SeriesMatch.tidyASIN) }
        let rows = Dictionary(stored.entries.map { (key($0.entry), $0) }, uniquingKeysWith: { first, _ in first })
        // Owned by a book filed elsewhere. The library's ASINs are read once, and only
        // when there is an entry to look for.
        var ownedEntries = result.owned.map(\.entry)
        var unmatched = result.missing
        // Inside `BookScope.visible` the books above are those that are not hidden. An
        // entry that a hidden book is must not then be listed as missing, which would
        // name the book: it is left out altogether, neither owned nor missing.
        if BookScope.visibleOnly, !unmatched.isEmpty {
            let everyBook = try BookScope.$visibleOnly.withValue(false) {
                (ofSeries: try librarySeriesBooks(named: name), hiddenASINs: try libraryASINs(hiddenOnly: true))
            }
            let shown = Set(books.map(\.id))
            let hiddenOfSeries = everyBook.ofSeries.filter { !shown.contains($0.id) }
            let theirs = Set(SeriesMatch.match(unmatched, with: hiddenOfSeries).owned.map { key($0.entry) })
            unmatched.removeAll { entry in
                theirs.contains(key(entry))
                    || entry.asins.contains { everyBook.hiddenASINs.contains(SeriesMatch.tidyASIN($0)) }
            }
        }
        if !unmatched.isEmpty {
            let held = try libraryASINs()
            let (elsewhere, rest) = unmatched.reduce(into: ([SeriesEntry](), [SeriesEntry]())) { parts, entry in
                if entry.asins.contains(where: { held.contains(SeriesMatch.tidyASIN($0)) }) {
                    parts.0.append(entry)
                } else {
                    parts.1.append(entry)
                }
            }
            ownedEntries += elsewhere
            unmatched = rest
        }
        // The same book again, under the title of one the library has.
        let ownedTitles = Set(ownedEntries.flatMap { $0.titles.map { LookupText.comparable($0) } })
        let missing = unmatched.compactMap { entry -> MissingEntry? in
            let title = LookupText.comparable(entry.preferred.title)
            if !title.isEmpty, ownedTitles.contains(title) { return nil }
            guard let row = rows[key(entry)], let id = row.id else { return nil }
            return MissingEntry(id: id, entry: entry, isHidden: row.isHidden)
        }

        var differences: [Int64: String] = [:]
        for owned in result.owned where owned.numberDiffers {
            differences[owned.bookId] = owned.entry.number
        }

        let takenASINs = Set(result.owned.flatMap { $0.entry.asins.map(SeriesMatch.tidyASIN) })
        let takenTitles = Set(result.owned.flatMap { $0.entry.titles.map { LookupText.comparable($0) } })
        let byId = Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let notInList = result.notInList.filter { id in
            guard let book = byId[id] else { return true }
            if book.asins.contains(where: { takenASINs.contains(SeriesMatch.tidyASIN($0)) }) { return false }
            let title = LookupText.comparable(book.title)
            return title.isEmpty || !takenTitles.contains(title)
        }

        return SeriesCompleteness(
            link: link, ownedCount: ownedEntries.count,
            totalCount: ownedEntries.count + missing.filter { !$0.isHidden }.count,
            missing: missing, numberDifferences: differences, notInList: notInList)
    }

    /// Every ASIN the library holds: each book's own, and the item IDs of its Audible
    /// copies, tidied for comparing. One read of the catalogue.
    /// - Parameter hiddenOnly: Only those of the hidden books.
    private func libraryASINs(hiddenOnly: Bool = false) throws -> Set<String> {
        var held: Set<String> = []
        for book in try hiddenOnly ? store.hiddenBooks() : store.books() {
            let own = [book.asin] + book.externalCopies.filter { $0.kind == .audible }.map(\.itemId)
            for asin in own.compactMap({ $0?.nonBlank }) { held.insert(SeriesMatch.tidyASIN(asin)) }
        }
        return held
    }

    /// Hides an entry of a stored list, or shows it again. Nothing else changes.
    /// - Throws: `SeriesListError.entryNotFound` when no stored entry has the id.
    public func setMissingEntry(id: Int64, hidden: Bool) throws {
        guard try store.setSeriesEntry(id: id, hidden: hidden) else { throw SeriesListError.entryNotFound(id) }
    }

    /// Forgets the link and list stored for a series; a series that has none is left
    /// as it is. A link whose series no book is in any more is deleted on the way.
    public func unlinkSeries(named name: String) throws {
        try store.deleteSeriesList(key: name)
    }

    /// One edit for each book of the series that Audible numbers differently, by book
    /// id: the book as it is, with Audible's number for its series number. Books the
    /// list does not include, books with the same number and books with no number get
    /// none. Writes nothing: saving the edits is the caller's to do.
    public func editsUsingAudibleNumbers(forSeries name: String) throws -> [BookEdit] {
        guard let differences = try seriesCompleteness(forSeries: name)?.numberDifferences else { return [] }
        return try differences.keys.sorted().compactMap { id in
            guard let book = try store.book(id: id), let number = differences[id] else { return nil }
            var edit = BookEdit(book: book)
            edit.metadata.seriesNumber = number
            return edit
        }
    }
}
