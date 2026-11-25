import Foundation

/// What bringing in an Audible library would do, or did.
public struct AudibleLibraryReport: Equatable, Sendable {
    /// Books the library did not have, added as owned on Audible, with no files.
    public var added: [String] = []
    /// Books the library had, now marked as owned on Audible too.
    public var marked: [String] = []
    /// Books already marked as owned on Audible: nothing to do.
    public var alreadyThere = 0
    /// Books whose reading status moved on (to being read, or to finished).
    public var statusChanged = 0

    public init() {}

    public var changesNothing: Bool { added.isEmpty && marked.isEmpty && statusChanged == 0 }
}

extension LibraryService {
    /// The details an Audible library book has as a book of this library.
    func metadata(for owned: AudibleOwnedBook) -> BookMetadata {
        var metadata = BookMetadata(title: owned.title, authors: owned.authors)
        metadata.subtitle = owned.subtitle
        metadata.narrators = owned.narrators
        metadata.series = owned.series
        metadata.seriesNumber = owned.series == nil ? nil : owned.seriesNumber
        metadata.durationSeconds = owned.minutes.map { Double($0) * 60 }
        metadata.year = owned.year
        metadata.publisher = owned.publisher
        metadata.language = owned.language
        metadata.asin = owned.asin
        let source = GenreSource.paths(owned.genrePaths)
        metadata.genreSource = GenreMapping.wording(of: source)
        metadata.genres = listedGenres(GenreMapping.map(source).names)
        return metadata
    }

    /// The book of this library that an Audible library book is: one with that Audible
    /// ID, as its own or as an Audible copy's; failing that one that is surely the same
    /// by title and first author.
    private func bookId(for owned: AudibleOwnedBook, byASIN: [String: Int64]) throws -> Int64? {
        if let id = byASIN[owned.asin.uppercased()] { return id }
        return try existingMatch(for: metadata(for: owned))?.id
    }

    /// Brings an Audible account's library into this one, or says what doing so would
    /// do (`apply` false: nothing is changed).
    ///
    /// A book the library has (by Audible ID, or surely the same by title and first
    /// author) is marked as owned on Audible in that store, keeping every detail it
    /// has; one it lacks is added with Audible's details, no files and no folder, dated
    /// when it was bought. Reading status only ever moves on: an unread book that
    /// Audible says is begun or finished takes that, and a book being read that is
    /// finished there is finished; nothing is moved back. No file is opened or
    /// written. Done again with the same list, it changes nothing.
    ///
    /// Not an undoable operation: a book that was added is removed like any other.
    public func bringInAudibleLibrary(
        _ books: [AudibleOwnedBook], store audibleStore: AudibleStore, apply: Bool, now: Date = Date()
    ) throws -> AudibleLibraryReport {
        var report = AudibleLibraryReport()
        var byASIN: [String: Int64] = [:]
        for book in try store.books() {
            guard let id = book.id else { continue }
            let own = [book.asin] + book.externalCopies.filter { $0.kind == .audible }.map(\.itemId)
            for asin in own.compactMap({ $0?.trimmingCharacters(in: .whitespaces).uppercased() }) where !asin.isEmpty {
                if byASIN[asin] == nil { byASIN[asin] = id }
            }
        }

        for owned in books {
            let copy = ExternalCopy(kind: .audible, form: .audio, store: audibleStore.rawValue, itemId: owned.asin)
            if let id = try bookId(for: owned, byASIN: byASIN), var book = try store.book(id: id) {
                let wasMarked = Self.give(copy, to: &book)
                let moved = Self.movedOn(book.readStatus, to: owned.status)
                if wasMarked { report.alreadyThere += 1 } else { report.marked.append(book.title) }
                if moved != nil { report.statusChanged += 1 }
                guard apply, !wasMarked || moved != nil else { continue }
                try self.store.modifyBook(id: id) { stored, fileCount in
                    Self.give(copy, to: &stored)
                    Self.fillASIN(of: &stored, hasFiles: fileCount > 0)
                    if let moved { Self.set(moved, on: &stored, at: now) }
                }
            } else {
                report.added.append(owned.title)
                if owned.status != .unread { report.statusChanged += 1 }
                guard apply else { continue }
                var book = Book(
                    metadata: metadata(for: owned), folderPath: nil, needsAttention: false,
                    dateAdded: owned.purchased ?? now)
                book.externalCopies = [copy]
                if owned.status != .unread { Self.set(owned.status, on: &book, at: now) }
                if let id = try self.store.insert(book, files: []).id { byASIN[owned.asin.uppercased()] = id }
            }
        }
        return report
    }

    /// The status a book moves on to; nil when what Audible says is no further along.
    static func movedOn(_ current: ReadStatus, to audible: ReadStatus) -> ReadStatus? {
        func rank(_ status: ReadStatus) -> Int {
            switch status {
            case .unread: 0
            case .inProgress: 1
            case .finished: 2
            }
        }
        return rank(audible) > rank(current) ? audible : nil
    }

    private static func set(_ status: ReadStatus, on book: inout Book, at now: Date) {
        book.readStatus = status
        if book.dateStarted == nil { book.dateStarted = now }
        if status == .finished, book.dateFinished == nil { book.dateFinished = now }
    }

    /// The books that are owned on Audible and have no cover stored, each with its
    /// Audible ID: for fetching their covers after they were brought in.
    public func audibleBooksWithoutCover() throws -> [(bookId: Int64, asin: String)] {
        try store.books(ownedOn: .audible).compactMap { book in
            guard let id = book.id, covers.url(for: id) == nil, let asin = book.asin?.trimmingCharacters(in: .whitespaces),
                  !asin.isEmpty
            else { return nil }
            return (id, asin)
        }
    }

    /// Stores a cover for a book that has none. Nothing is written into any file.
    /// - Returns: False when the book has a cover already, or is not in the library.
    @discardableResult
    public func setCoverIfNone(_ cover: CoverImage, for bookId: Int64) throws -> Bool {
        guard try store.book(id: bookId) != nil, covers.url(for: bookId) == nil else { return false }
        try covers.set(cover, for: bookId)
        return true
    }
}
