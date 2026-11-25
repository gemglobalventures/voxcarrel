import Foundation

extension LibraryService {
    /// Every book of the library as a shelf's conditions see it, by title.
    func shelfBooks() throws -> [ShelfBook] {
        let audio = Set(try store.books(having: .audio).compactMap(\.id))
        let ebook = Set(try store.books(having: .ebook).compactMap(\.id))
        var groups: [String: GenreGroup] = [:]
        for entry in try genreList() where !entry.isHidden { groups[entry.name.lowercased()] = entry.group }
        return try store.books().compactMap { book in
            guard let id = book.id else { return nil }
            return ShelfBook(
                book: book, hasAudio: audio.contains(id), hasEbook: ebook.contains(id),
                genreGroups: Set(book.genres.compactMap { groups[$0.lowercased()] }))
        }
    }

    /// The books a shelf holds now, by title. The shelf need not be a stored one: this
    /// is also how a shelf that is being made is tried out.
    public func books(on shelf: SmartShelf, now: Date = Date()) throws -> [Book] {
        try shelfBooks().filter { shelf.holds($0, now: now) }.map(\.book)
    }

    public func smartShelves() throws -> [SmartShelf] {
        try store.smartShelves()
    }

    /// Stores a shelf under a name that is not blank; nil for a blank one.
    @discardableResult
    public func saveSmartShelf(_ shelf: SmartShelf) throws -> SmartShelf? {
        var tidy = shelf
        tidy.name = shelf.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tidy.name.isEmpty else { return nil }
        return try store.save(tidy)
    }

    public func deleteSmartShelf(id: Int64) throws {
        try store.deleteSmartShelf(id: id)
    }

    /// Puts books on the Up Next list by hand, after those already there.
    public func addToUpNext(_ ids: [Int64]) throws {
        try store.addToUpNext(ids)
    }

    public func removeFromUpNext(_ ids: [Int64]) throws {
        try store.removeFromUpNext(ids)
    }

    /// Which of these books are on the Up Next list by hand.
    public func queuedForUpNext(_ ids: [Int64]) throws -> Set<Int64> {
        Set(try store.upNextIds()).intersection(ids)
    }

    /// What to pick up now.
    ///
    /// 1. The books being read, by title.
    /// 2. For each series that has been begun, the book that comes after the furthest
    ///    one finished, whether the library has it or not (`UpNextRules.next`); the
    ///    series by name. A book the library lacks is known only for a series that has
    ///    been checked against Audible's list, and is never one the owner has hidden.
    /// 3. The books put on the list by hand that are not finished, in the order they
    ///    were put there.
    ///
    /// A finished book put there by hand is not shown, and stays on record.
    public func upNext() throws -> UpNextList {
        var list = UpNextList()
        let all = try store.books()
        list.inProgress = all.filter { $0.readStatus == .inProgress }

        var bySeries: [String: (name: String, books: [Book])] = [:]
        for book in all {
            guard let name = book.series?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            bySeries[name.lowercased(), default: (name, [])].books.append(book)
        }
        for key in bySeries.keys.sorted() {
            guard let series = bySeries[key], series.books.contains(where: { $0.readStatus == .finished }) else { continue }
            let completeness = try seriesCompleteness(forSeries: series.name)
            let missing = (completeness?.missing ?? []).filter { !$0.isHidden }.map { (entry: $0, place: $0.entry.sort) }
            if let next = UpNextRules.next(among: series.books, missing: missing, link: completeness?.link) {
                list.nextInSeries.append(next)
            }
        }

        let byId = Dictionary(uniqueKeysWithValues: all.compactMap { book in book.id.map { ($0, book) } })
        list.queued = try store.upNextIds().compactMap { byId[$0] }.filter { $0.readStatus != .finished }
        return list
    }
}
