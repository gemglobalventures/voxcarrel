import Foundation

extension LibraryService {
    public func highlights(forBook bookId: Int64) throws -> [Highlight] {
        try store.highlights(forBook: bookId)
    }

    public func highlightCounts() throws -> [Int64: Int] {
        try store.highlightCounts()
    }

    /// The books that have highlights, by title.
    public func booksWithHighlights() throws -> [Book] {
        let having = Set(try store.highlightCounts().keys)
        return try store.books().filter { $0.id.map(having.contains) ?? false }
    }

    /// Adds a highlight of the owner's own to a book: a passage, a note, or both.
    /// - Throws: `LibraryError.invalidDetails` when both are blank; `bookNotFound`.
    @discardableResult
    public func addHighlight(
        text: String, note: String?, toBook bookId: Int64, location: Double? = nil,
        locationKind: HighlightLocationKind? = nil, now: Date = Date()
    ) throws -> Highlight {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !note.isEmpty else { throw LibraryError.invalidDetails("A highlight needs some words") }
        guard try store.book(id: bookId) != nil else { throw LibraryError.bookNotFound(bookId) }
        let highlight = Highlight(
            bookId: bookId, source: .own, sourceId: UUID().uuidString, text: text, note: note.isEmpty ? nil : note,
            location: location, locationKind: location == nil ? nil : locationKind, madeAt: now)
        try store.apply(highlights: [highlight], removing: [])
        return try store.highlights(from: .own)[highlight.sourceId] ?? highlight
    }

    /// Changes the note on a highlight; a blank one removes it. The words of a
    /// highlight that came from elsewhere are its source's, and are left alone.
    public func setNote(_ note: String?, onHighlight id: Int64) throws {
        let tidy = (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE highlight SET note = ? WHERE id = ?", arguments: [tidy.isEmpty ? nil : tidy, id])
        }
    }

    /// Removes a highlight from the library. One that came from elsewhere is not
    /// removed there, and comes back when that source is brought in again.
    public func deleteHighlight(id: Int64) throws {
        try store.deleteHighlight(id: id)
    }

    /// Brings books' highlights into the library, or says what doing so would do
    /// (`apply` false: nothing is changed).
    ///
    /// A highlighted book is the library's book with the same ID (as the book's own,
    /// or as that of a copy owned elsewhere), failing that the one that is surely the
    /// same by title and first author. A book the library lacks is added with no files
    /// when the source says where it is owned (a Kindle book), and is left out, and
    /// named, when it does not. A highlight is known again by its source's own id for
    /// it: one already here is changed if the source changed it, one the source has
    /// deleted is removed, and a note the owner wrote here on a highlight whose source
    /// has none is kept. No file is opened or written. Done again with the same
    /// answer, it changes nothing.
    public func bringInHighlights(_ books: [HighlightedBook], apply: Bool, now: Date = Date()) throws -> HighlightsReport {
        var report = HighlightsReport()
        var byItem: [String: Int64] = [:]
        for book in try store.books() {
            guard let id = book.id else { continue }
            for item in ([book.asin] + book.externalCopies.map(\.itemId)).compactMap({ $0?.trimmingCharacters(in: .whitespaces).uppercased() })
            where !item.isEmpty && byItem[item] == nil { byItem[item] = id }
        }
        var stored: [HighlightSource: [String: Highlight]] = [:]
        var toStore: [Highlight] = []
        var toRemove: [(source: HighlightSource, sourceId: String)] = []
        // Books this call adds stand in under made-up ids until they are stored.
        var pendingBooks: [(book: Book, highlights: [IncomingHighlight], source: HighlightSource)] = []

        for incoming in books {
            let live = incoming.highlights.filter { !$0.isDeleted }
            let known = try stored[incoming.source] ?? store.highlights(from: incoming.source)
            stored[incoming.source] = known

            var metadata = BookMetadata(title: incoming.title, authors: incoming.authors)
            let item = incoming.itemId?.trimmingCharacters(in: .whitespaces)
            var bookId = item.flatMap { byItem[$0.uppercased()] }
            if bookId == nil { bookId = try existingMatch(for: metadata)?.id }

            guard let bookId else {
                // Nothing to show for a book with no highlights left.
                guard !live.isEmpty else { continue }
                guard let kind = incoming.ownedOn else {
                    report.booksLeftOut.append(incoming.title)
                    continue
                }
                report.booksAdded.append(incoming.title)
                report.added += live.count
                guard apply else { continue }
                if kind == .audible { metadata.asin = item }
                var book = Book(metadata: metadata, folderPath: nil, needsAttention: false, dateAdded: now)
                book.externalCopies = [ExternalCopy(kind: kind, form: kind == .audible ? .audio : .ebook, itemId: item)]
                pendingBooks.append((book, live, incoming.source))
                continue
            }

            report.booksMatched += 1
            let addedBefore = report.added
            defer { if report.added > addedBefore { report.booksGaining += 1 } }
            for highlight in incoming.highlights {
                let before = known[highlight.sourceId]
                if highlight.isDeleted {
                    if before != nil {
                        report.removed += 1
                        toRemove.append((incoming.source, highlight.sourceId))
                    }
                    continue
                }
                var after = Self.highlight(highlight, source: incoming.source, bookId: bookId)
                if let before {
                    // A note written here stays where the source has none.
                    if after.note == nil { after.note = before.note }
                    after.id = before.id
                    if after == before { report.unchanged += 1 } else { report.changed += 1; toStore.append(after) }
                } else {
                    report.added += 1
                    toStore.append(after)
                }
            }
        }
        guard apply else { return report }
        for pending in pendingBooks {
            guard let id = try store.insert(pending.book, files: []).id else { continue }
            toStore += pending.highlights.map { Self.highlight($0, source: pending.source, bookId: id) }
        }
        try store.apply(highlights: toStore, removing: toRemove)
        return report
    }

    private static func highlight(_ incoming: IncomingHighlight, source: HighlightSource, bookId: Int64) -> Highlight {
        Highlight(
            bookId: bookId, source: source, sourceId: incoming.sourceId, text: incoming.text, note: incoming.note,
            location: incoming.location, endLocation: incoming.endLocation, locationKind: incoming.locationKind,
            madeAt: incoming.madeAt, colour: incoming.colour, link: incoming.link, isFavourite: incoming.isFavourite,
            tags: incoming.tags)
    }

    /// The books owned on Kindle that have no cover stored, for fetching their covers.
    public func booksOwnedElsewhereWithoutCover() throws -> [Int64] {
        try ExternalKind.allCases.flatMap { try store.books(ownedOn: $0) }.compactMap(\.id)
            .filter { covers.url(for: $0) == nil }
    }
}
