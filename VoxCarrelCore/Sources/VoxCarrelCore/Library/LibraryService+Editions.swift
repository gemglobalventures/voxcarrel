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
        nameEditionFolders(ofWork: key)
        refreshDetailsFiles(ofBooks: all.sorted())
    }

    // MARK: Folders

    /// What an edition's folder could say after its title to tell it from another, the
    /// surest first: its language, that it is abridged or a dramatisation, who reads it.
    static func editionLabels(of book: Book) -> [String] {
        func said(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        var labels: [String] = []
        if let language = said(book.language) {
            labels.append(Locale(identifier: "en").localizedString(forIdentifier: language) ?? language)
        }
        switch book.editionKind?.kind {
        case .abridged: labels.append("abridged")
        case .dramatised: labels.append("dramatisation")
        default: break
        }
        if let narrator = said(book.narrators.first) { labels.append("read by \(narrator)") }
        return labels
    }

    /// What each edition's folder is to say after its title: for an edition that
    /// shares its title and first author with another edition of the work, the first
    /// thing about it that none of those others shares; nil for one whose title is its
    /// own, and for one that nothing tells apart.
    static func editionSuffixes(of editions: [Book]) -> [Int64: String?] {
        func key(_ book: Book) -> String {
            LookupText.comparable(book.title).joined(separator: " ") + "|" + KnownNames.authorKey(book.authors.first ?? "")
        }
        var suffixes: [Int64: String?] = [:]
        for book in editions {
            guard let id = book.id else { continue }
            let alike = editions.filter { $0.id != id && key($0) == key(book) }
            guard !alike.isEmpty else {
                suffixes[id] = .some(nil)
                continue
            }
            let taken = Set(alike.flatMap { editionLabels(of: $0).map { $0.lowercased() } })
            suffixes[id] = .some(editionLabels(of: book).first { !taken.contains($0.lowercased()) })
        }
        return suffixes
    }

    /// These edits, with what each edition's folder is to say worked out for the books
    /// as the edits leave them; and, after them, an edit for every other edition of
    /// the same works whose folder must then say something else. Edits of books that
    /// are no edition of anything are as they were.
    func namingEditions(in edits: [BookEdit]) -> [BookEdit] {
        guard let all = try? BookScope.$visibleOnly.withValue(false, operation: { try store.books() }) else { return edits }
        var byId: [Int64: Book] = [:]
        for book in all { if let id = book.id { byId[id] = book } }
        let keys = Set(edits.compactMap { byId[$0.bookId]?.workKey })
        guard !keys.isEmpty else { return edits }
        var result = edits
        for key in keys.sorted() {
            var editions = all.filter { $0.workKey == key }
            for index in editions.indices {
                guard let edit = edits.first(where: { $0.bookId == editions[index].id }) else { continue }
                editions[index].metadata = edit.metadata
                editions[index].editionKind = edit.editionKind
            }
            let wanted = Self.editionSuffixes(of: editions)
            for edition in editions {
                guard let id = edition.id, let suffix = wanted[id] else { continue }
                if let index = result.firstIndex(where: { $0.bookId == id }) {
                    result[index].editionSuffix = suffix
                } else if let book = byId[id], suffix != book.editionSuffix {
                    var edit = BookEdit(book: book)
                    edit.editionSuffix = suffix
                    result.append(edit)
                }
            }
        }
        return result
    }

    /// Gives each edition of a work the folder its suffix calls for, as a save would:
    /// the folders are moved, the catalogue follows, and Undo puts them back. An
    /// edition that cannot be filed stays where it is, flagged, as any book would.
    /// Nothing here can fail the linking or unlinking that asked for it.
    func nameEditionFolders(ofWork key: String, alsoClearing loose: [Int64] = []) {
        guard let everyBook = try? BookScope.$visibleOnly.withValue(false, operation: { try store.books() }) else { return }
        let editions = everyBook.filter { $0.workKey == key }
        var wanted = Self.editionSuffixes(of: editions)
        for id in loose { wanted[id] = .some(nil) }
        let edits = everyBook.compactMap { book -> BookEdit? in
            guard let id = book.id, let suffix = wanted[id], suffix != book.editionSuffix else { return nil }
            var edit = BookEdit(book: book)
            edit.editionSuffix = suffix
            return edit
        }
        guard !edits.isEmpty else { return }
        _ = try? save(edits)
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
        // Those that leave the work lose their suffix; those that stay are named afresh.
        nameEditionFolders(ofWork: key, alsoClearing: changed)
        refreshDetailsFiles(ofBooks: changed + rest.compactMap(\.id))
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
