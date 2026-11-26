import Foundation

/// Why editions could not be tied together. Nothing was changed.
public enum EditionLinkError: Error, Equatable, Sendable {
    /// Fewer than two books of the library were named.
    case needsTwoBooks
}

extension LibraryService {
    /// Ties these books together as editions of one work: the same book in another
    /// language, read by another narrator, or as a dramatisation. Each stays an entry
    /// of its own, with its own folder, files and details. Books already tied to
    /// others bring those with them: the result is one work.
    ///
    /// Nothing but the tie changes, and no file is touched except the details file
    /// beside each book, which says which work the book is an edition of.
    /// - Throws: `EditionLinkError.needsTwoBooks` unless at least two of the ids are
    ///   books of the library.
    public func linkEditions(_ ids: [Int64]) throws {
        let books = try Set(ids).sorted().compactMap { try store.book(id: $0) }
        guard books.count >= 2 else { throw EditionLinkError.needsTwoBooks }
        let held = Set(books.compactMap(\.workKey))
        let key = held.sorted().first ?? UUID().uuidString
        var all = Set(books.compactMap(\.id))
        if !held.isEmpty {
            // Every book tied to any of them joins the one work.
            let everyBook = try BookScope.$visibleOnly.withValue(false) { try store.books() }
            for book in everyBook {
                if let other = book.workKey, held.contains(other), let id = book.id { all.insert(id) }
            }
        }
        try store.setWorkKey(key, bookIds: all.sorted())
        refreshDetailsFiles(ofBooks: all.sorted())
    }

    /// Unties a book from the other editions it was tied to. An edition left alone by
    /// that is untied too: a work of one is no work.
    public func unlinkEdition(_ id: Int64) throws {
        guard let key = try store.book(id: id)?.workKey else { return }
        var changed = [id]
        let rest = try BookScope.$visibleOnly.withValue(false) { try store.books() }
            .filter { $0.workKey == key && $0.id != id }
        try store.setWorkKey(nil, bookIds: [id])
        if rest.count == 1, let last = rest[0].id {
            try store.setWorkKey(nil, bookIds: [last])
            changed.append(last)
        }
        refreshDetailsFiles(ofBooks: changed)
    }

    /// The other editions of this book that the library has, by title then id. Empty
    /// for a book that stands alone. Inside `BookScope.visible`, hidden ones are left out.
    public func otherEditions(ofBook id: Int64) throws -> [Book] {
        guard let key = try store.book(id: id)?.workKey else { return [] }
        return try store.books().filter { $0.workKey == key && $0.id != id }.sorted {
            let order = $0.title.localizedCaseInsensitiveCompare($1.title)
            return order == .orderedSame ? ($0.id ?? 0) < ($1.id ?? 0) : order == .orderedAscending
        }
    }

    /// What sets one edition apart from another, in a few words: its language, who
    /// reads it, or what kind of edition it is. Nil when nothing tells them apart.
    public static func whatSetsApart(_ book: Book, from other: Book) -> String? {
        func said(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        if let language = said(book.language), language.lowercased() != said(other.language)?.lowercased() {
            return Locale.current.localizedString(forIdentifier: language) ?? language
        }
        if let narrator = said(book.narrators.first), narrator.lowercased() != said(other.narrators.first)?.lowercased() {
            return "read by \(narrator)"
        }
        if let kind = book.editionKind?.kind, kind != other.editionKind?.kind {
            switch kind {
            case .unabridged: return "unabridged"
            case .abridged: return "abridged"
            case .dramatised: return "dramatisation"
            case .notKnown: return nil
            }
        }
        return nil
    }
}
