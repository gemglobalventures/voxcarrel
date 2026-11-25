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
    /// **Which book.** A highlighted book is the library's book with the same ID (as the
    /// book's own, or as that of a copy owned elsewhere), failing that the one that is
    /// surely the same by title and first author; that book is then marked as owned
    /// where the source says it is. A book the library lacks is added with no files
    /// when the source says where it is owned, and is left out, and named, when not.
    ///
    /// **Which highlight.** A highlight is known again by its source's own id for it.
    /// One that is new from this source but is the same highlight as one the book
    /// already has from elsewhere (`HighlightMatch.same`) is not added twice: this
    /// source is noted as another place it came from, what it lacks (a note, a place,
    /// a date, a link) is filled in, and the longer of two passages is kept. The same
    /// holds between two highlights of one answer.
    ///
    /// **What goes.** A highlight a source has deleted loses that source; it is removed
    /// only when no other source has it. A note the owner wrote here is never lost to
    /// a source that has none.
    ///
    /// No file is opened or written. Done again with the same answer, it changes nothing.
    public func bringInHighlights(_ books: [HighlightedBook], apply: Bool, now: Date = Date()) throws -> HighlightsReport {
        var report = HighlightsReport()
        var byItem: [String: Int64] = [:]
        var libraryBooks: [Int64: Book] = [:]
        for book in try store.books() {
            guard let id = book.id else { continue }
            libraryBooks[id] = book
            for item in ([book.asin] + book.externalCopies.map(\.itemId)).compactMap({ $0?.trimmingCharacters(in: .whitespaces).uppercased() })
            where !item.isEmpty && byItem[item] == nil { byItem[item] = id }
        }

        // Every highlight as this call will leave it, by the book it is on. A book this
        // call adds stands under a made-up key below zero until it is stored.
        var slots: [Int64: [HighlightSlot]] = [:]
        for highlight in try store.allHighlights() { slots[highlight.bookId, default: []].append(HighlightSlot(highlight)) }
        let storedOrigins = try store.highlightOrigins()
        for key in slots.keys {
            for index in slots[key]!.indices {
                if let id = slots[key]![index].highlight.id { slots[key]![index].origins = storedOrigins[id] ?? [] }
            }
        }
        var pendingBooks: [Int64: Book] = [:]
        var copiesToGive: [Int64: ExternalCopy] = [:]

        for incoming in books {
            let live = incoming.highlights.filter { !$0.isDeleted }
            var metadata = BookMetadata(title: incoming.title, authors: incoming.authors)
            let item = incoming.itemId?.trimmingCharacters(in: .whitespaces)
            let copy = incoming.ownedOn.map { ExternalCopy(kind: $0, form: $0 == .audible ? .audio : .ebook, itemId: item) }
            var bookKey = item.flatMap { byItem[$0.uppercased()] }
            if bookKey == nil { bookKey = try existingMatch(for: metadata)?.id }

            let isNewBook = bookKey == nil
            if isNewBook {
                // Nothing to show for a book with no highlights left.
                guard !live.isEmpty else { continue }
                guard let copy else {
                    report.booksLeftOut.append(incoming.title)
                    continue
                }
                report.booksAdded.append(incoming.title)
                if copy.kind == .audible { metadata.asin = item }
                var book = Book(metadata: metadata, folderPath: nil, needsAttention: false, dateAdded: now)
                book.externalCopies = [copy]
                let key = Int64(-(pendingBooks.count + 1))
                pendingBooks[key] = book
                if let item, !item.isEmpty { byItem[item.uppercased()] = key }
                bookKey = key
            } else if let id = bookKey, id > 0 {
                report.booksMatched += 1
                // The book is owned there too.
                if let copy, let book = libraryBooks[id], !book.externalCopies.contains(where: { $0.kind == copy.kind && $0.form == copy.form }) {
                    copiesToGive[id] = copy
                }
            }
            guard let bookKey else { continue }

            let addedBefore = report.added
            var bookSlots = slots[bookKey] ?? []
            for arriving in incoming.highlights {
                let origin = HighlightOrigin(source: incoming.source, sourceId: arriving.sourceId)
                let known = Self.slot(holding: origin, in: slots, current: (bookKey, bookSlots))

                if arriving.isDeleted {
                    guard let known, known.book == bookKey else { continue }
                    var slot = bookSlots[known.index]
                    if slot.highlight.source == origin.source, slot.highlight.sourceId == origin.sourceId {
                        if let next = slot.origins.first {
                            // Another source still has it: it is kept under that one.
                            slot.origins.removeFirst()
                            slot.highlight.source = next.source
                            slot.highlight.sourceId = next.sourceId
                            slot.isChanged = true
                        } else {
                            slot.isRemoved = true
                            report.removed += 1
                        }
                    } else {
                        slot.origins.removeAll { $0 == origin }
                        slot.originsChanged = true
                    }
                    bookSlots[known.index] = slot
                    continue
                }

                let given = Self.highlight(arriving, source: incoming.source, bookId: bookKey)
                if let known, known.book == bookKey {
                    var slot = bookSlots[known.index]
                    let before = slot.highlight
                    if before.source == origin.source, before.sourceId == origin.sourceId {
                        // Its own source says what it is; a note written here stays where that has none.
                        var after = given
                        after.id = before.id
                        if after.note == nil { after.note = before.note }
                        // What another source gave it is not lost each time this one is looked at.
                        if !slot.origins.isEmpty { Self.fill(&after, from: before) }
                        slot.highlight = after
                    } else {
                        Self.fill(&slot.highlight, from: given)
                    }
                    if slot.highlight == before { report.unchanged += 1 } else { report.changed += 1; slot.isChanged = true }
                    bookSlots[known.index] = slot
                } else if let index = bookSlots.firstIndex(where: { !$0.isRemoved && HighlightMatch.same($0.highlight, given) }) {
                    // The same highlight, come another way: one record, and this source noted.
                    var slot = bookSlots[index]
                    let before = slot.highlight
                    Self.fill(&slot.highlight, from: given)
                    slot.origins.append(origin)
                    slot.originsChanged = true
                    if slot.highlight != before { slot.isChanged = true }
                    bookSlots[index] = slot
                    report.joined += 1
                } else {
                    var slot = HighlightSlot(given)
                    slot.isNew = true
                    bookSlots.append(slot)
                    report.added += 1
                }
            }
            slots[bookKey] = bookSlots
            if !isNewBook, report.added > addedBefore { report.booksGaining += 1 }
        }
        guard apply else { return report }

        // Books first, so that their highlights have somewhere to go.
        var realKey: [Int64: Int64] = [:]
        for (key, book) in pendingBooks.sorted(by: { $0.key > $1.key }) {
            if let id = try store.insert(book, files: []).id { realKey[key] = id }
        }
        for (id, copy) in copiesToGive {
            _ = try store.modifyBook(id: id) { book, fileCount in
                Self.give(copy, to: &book)
                Self.fillASIN(of: &book, hasFiles: fileCount > 0)
            }
        }
        try store.dbQueue.write { db in
            for (key, bookSlots) in slots {
                guard let bookId = key > 0 ? key : realKey[key] else { continue }
                for slot in bookSlots {
                    var highlight = slot.highlight
                    highlight.bookId = bookId
                    if slot.isRemoved {
                        if let id = highlight.id { try db.execute(sql: "DELETE FROM highlight WHERE id = ?", arguments: [id]) }
                        continue
                    }
                    guard slot.isNew || slot.isChanged || slot.originsChanged else { continue }
                    // Its other sources are written again whole: one may have become the one it is kept under.
                    if let id = highlight.id { try db.execute(sql: "DELETE FROM highlightOrigin WHERE highlightId = ?", arguments: [id]) }
                    if slot.isNew { try highlight.insert(db) } else { try highlight.update(db) }
                    guard let id = highlight.id else { continue }
                    for origin in slot.origins {
                        try db.execute(
                            sql: "INSERT OR REPLACE INTO highlightOrigin (highlightId, source, sourceId) VALUES (?, ?, ?)",
                            arguments: [id, origin.source.rawValue, origin.sourceId])
                    }
                }
            }
        }
        return report
    }

    /// Where the highlight that came from `origin` is: the book it is on and its place
    /// among that book's highlights. `current` is the book being worked on, whose
    /// highlights are not yet put back among the rest.
    private static func slot(
        holding origin: HighlightOrigin, in slots: [Int64: [HighlightSlot]], current: (key: Int64, slots: [HighlightSlot])
    ) -> (book: Int64, index: Int)? {
        func index(in list: [HighlightSlot]) -> Int? {
            list.firstIndex { slot in
                !slot.isRemoved && ((slot.highlight.source == origin.source && slot.highlight.sourceId == origin.sourceId)
                    || slot.origins.contains(origin))
            }
        }
        if let found = index(in: current.slots) { return (current.key, found) }
        for (key, list) in slots where key != current.key {
            if let found = index(in: list) { return (key, found) }
        }
        return nil
    }

    /// Gives a highlight what it lacks from another copy of itself, and the longer
    /// passage of the two. What it has is never replaced.
    private static func fill(_ kept: inout Highlight, from other: Highlight) {
        if HighlightMatch.key(other.text).count > HighlightMatch.key(kept.text).count { kept.text = other.text }
        if kept.note == nil { kept.note = other.note }
        if kept.location == nil {
            kept.location = other.location
            kept.endLocation = other.endLocation
            kept.locationKind = other.locationKind
        }
        if kept.madeAt == nil { kept.madeAt = other.madeAt }
        if kept.link == nil { kept.link = other.link }
        if kept.colour == nil { kept.colour = other.colour }
        if !other.tags.isEmpty { kept.tags = GenreName.distinct(kept.tags + other.tags) }
        kept.isFavourite = kept.isFavourite || other.isFavourite
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

/// Another place a highlight came from: the source and its own id for it.
struct HighlightOrigin: Equatable, Hashable {
    var source: HighlightSource
    var sourceId: String
}

/// A highlight while highlights are being brought in: as it will be left, with the
/// other places it came from and what is to be done about it.
private struct HighlightSlot {
    var highlight: Highlight
    var origins: [HighlightOrigin] = []
    var isNew = false
    var isChanged = false
    var originsChanged = false
    var isRemoved = false

    init(_ highlight: Highlight) {
        self.highlight = highlight
    }
}
