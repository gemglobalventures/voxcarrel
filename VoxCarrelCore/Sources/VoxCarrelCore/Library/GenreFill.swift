import Foundation

/// A book that Fill in Genres may look up: one of `LibraryService.genreFillCandidates`.
/// Only the library makes these, so nothing is ever asked about a book it did not offer.
public struct GenreFillBook: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let title: String
    /// The first author.
    public let author: String?
    /// The book's Audible ID, when it has one.
    public let audibleID: String?

    init(id: Int64, title: String, author: String?, audibleID: String?) {
        self.id = id
        self.title = title
        self.author = author
        self.audibleID = audibleID
    }
}

/// What a lookup proposes as one book's genres, for the owner to review.
public struct GenreProposal: Equatable, Sendable, Identifiable {
    /// The book's id.
    public var id: Int64
    public var title: String
    public var author: String?
    /// The genres proposed, as the library names them; empty when nothing was found.
    public var genres: [String]
    /// The wording the genres came from, to be kept with them.
    public var genreSource: String?
    /// The title and first author of what was found; nil when nothing was.
    public var foundTitle: String?
    public var foundAuthor: String?
    /// Where it was found; nil when nothing was.
    public var source: LookupSource?
    /// True when what was found is surely this book: it was found by its Audible ID,
    /// or it has the same first author and the same title, edition words aside.
    public var isSure: Bool
    /// Set when nothing was found and a source that was asked could not answer.
    public var failure: LookupError?

    public init(
        id: Int64, title: String, author: String? = nil, genres: [String] = [], genreSource: String? = nil,
        foundTitle: String? = nil, foundAuthor: String? = nil, source: LookupSource? = nil, isSure: Bool = false,
        failure: LookupError? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.genres = genres
        self.genreSource = genreSource
        self.foundTitle = foundTitle
        self.foundAuthor = foundAuthor
        self.source = source
        self.isSure = isSure
        self.failure = failure
    }

    /// True when nothing was found for the book.
    public var foundNothing: Bool { genres.isEmpty }
}

/// The genres chosen for one book in Fill in Genres.
public struct GenreChoice: Equatable, Sendable {
    public var bookId: Int64
    public var genres: [String]
    /// The wording the genres came from (`GenreProposal.genreSource`).
    public var genreSource: String?

    public init(bookId: Int64, genres: [String], genreSource: String? = nil) {
        self.bookId = bookId
        self.genres = genres
        self.genreSource = genreSource
    }

    /// What a proposal proposes, as it stands.
    public init(_ proposal: GenreProposal) {
        self.init(bookId: proposal.id, genres: proposal.genres, genreSource: proposal.genreSource)
    }
}

/// Looks up genres for books that have none. Nothing here touches the library: what is
/// found is only ever handed back, for `LibraryService.applyGenres` once it is reviewed.
public struct GenreFill: Sendable {
    private let lookup: LookupService
    private let listing: GenreListing

    /// `listing`: the library's list (`LibraryService.genreListing()`), so that what is
    /// proposed is named as the library names it.
    public init(lookup: LookupService, listing: GenreListing) {
        self.lookup = lookup
        self.listing = listing
    }

    /// One proposal for each book, in the order given, each made when it is asked for:
    /// nothing is sent about a book until the one before it has been handed over, so
    /// one book is looked up at a time. It ends when the task reading it is cancelled,
    /// and what has been handed over by then stands.
    ///
    /// A book with an Audible ID is asked for by that ID, and what is found is sure.
    /// Failing that, and for every other book, the title and first author are searched
    /// for: on Audible, and on Open Library only when Audible has nothing. What is
    /// found that way is sure only when it has the same first author and the same
    /// title, edition words aside. Only the Audible ID, or the title and first author,
    /// are ever sent.
    ///
    /// - Throws: `LookupError.notReachable`, ending the stream, when a source could not
    ///   be reached at all: without the network there is nothing to propose.
    public func proposals(for books: [GenreFillBook]) -> AsyncThrowingStream<GenreProposal, any Error> {
        let remaining = Remaining(books)
        return AsyncThrowingStream(unfolding: {
            guard !Task.isCancelled, let book = remaining.next() else { return nil }
            do {
                let proposal = try await proposal(for: book)
                return Task.isCancelled ? nil : proposal
            } catch is CancellationError {
                // Stopped in the middle of a book: it ends there, and that is no error.
                return nil
            }
        })
    }

    /// The books still to look up, handed out one at a time.
    private final class Remaining: @unchecked Sendable {
        private let lock = NSLock()
        private var books: ArraySlice<GenreFillBook>

        init(_ books: [GenreFillBook]) {
            self.books = books[...]
        }

        func next() -> GenreFillBook? {
            lock.withLock { books.popFirst() }
        }
    }

    /// What the sources have for one book.
    func proposal(for book: GenreFillBook) async throws -> GenreProposal {
        var proposal = GenreProposal(id: book.id, title: book.title, author: book.author)

        // G30: by its Audible ID. What comes back under that ID is the book.
        if let id = book.audibleID.flatMap(AudibleProvider.asin) {
            let results = try await search(LookupQuery(asin: id), in: .audible, noting: &proposal)
            let found = results.first { candidate in
                candidate.metadata.asin.flatMap(AudibleProvider.asin) == id && !candidate.metadata.genres.isEmpty
            }
            if let found { return filled(proposal, from: found, isSure: true) }
        }

        guard let title = book.title.nonBlank else { return proposal }
        let query = LookupQuery(title: title, author: book.author?.nonBlank ?? "")
        for source in [LookupSource.audible, .openLibrary] {
            let results = try await search(query, in: source, noting: &proposal)
                .filter { !$0.metadata.genres.isEmpty }
            // The best match that is surely the book; failing that, the best match.
            if let sure = results.first(where: { LibraryService.isSurelyTheSameBook(book, $0.metadata) }) {
                return filled(proposal, from: sure, isSure: true)
            }
            if let first = results.first { return filled(proposal, from: first, isSure: false) }
        }
        return proposal
    }

    /// Asks one source. A source that cannot be reached ends everything; one that
    /// answers with an error is noted on the proposal and counts as having found nothing.
    private func search(
        _ query: LookupQuery, in source: LookupSource, noting proposal: inout GenreProposal
    ) async throws -> [LookupCandidate] {
        try Task.checkCancellation()
        let results = await lookup.search(query, preferAudio: source == .audible, language: nil, sources: [source])
        try Task.checkCancellation()
        if let failure = results.failures[source] {
            if failure == .notReachable { throw failure }
            proposal.failure = proposal.failure ?? failure
        }
        return results.candidates
    }

    /// G31: only the genres are taken from what was found, and the wording they came
    /// from; its title and author are kept to be shown.
    private func filled(_ proposal: GenreProposal, from found: LookupCandidate, isSure: Bool) -> GenreProposal {
        var proposal = proposal
        proposal.genres = listing.names(found.metadata.genres)
        proposal.genreSource = found.metadata.genreSource
        proposal.foundTitle = found.metadata.title
        proposal.foundAuthor = found.metadata.authors.first
        proposal.source = found.source
        proposal.isSure = isSure
        proposal.failure = nil
        return proposal
    }
}

extension LibraryService {
    /// The library's list of genres as it stands, for saying what names come to in it
    /// away from the library (`GenreFill`).
    public func genreListing() throws -> GenreListing {
        try store.genreListing()
    }

    /// The books Fill in Genres covers, sorted by title: those with no genre; and, when
    /// `includingGeneral`, those all of whose genres are general ones (Literary &
    /// General, Reference & Learning, whatever they are now called) or in the group Other.
    public func genreFillCandidates(includingGeneral: Bool) throws -> [GenreFillBook] {
        let listing = try store.genreListing()
        func saysLittle(_ name: String) -> Bool {
            // A name the list lacks would join it in Other.
            guard let row = listing.rows.first(where: { GenreName.same($0.name, name) }) else { return true }
            if row.group == .other { return true }
            return row.builtInName.flatMap(BuiltInGenre.named)?.isGeneral ?? false
        }
        return try store.books().compactMap { book in
            guard let id = book.id else { return nil }
            guard book.genres.isEmpty || (includingGeneral && book.genres.allSatisfy(saysLittle)) else { return nil }
            return GenreFillBook(
                id: id, title: book.title, author: book.authors.first?.nonBlank, audibleID: Self.audibleID(of: book))
        }
    }

    /// A book's Audible ID: its ASIN, or failing that the item ID of an Audible copy.
    static func audibleID(of book: Book) -> String? {
        book.asin?.nonBlank ?? book.externalCopies.lazy.filter { $0.kind == .audible }.compactMap { $0.itemId?.nonBlank }.first
    }

    /// Whether details found by title and author are surely a book: the rule by which a
    /// book that arrives is surely one the library has (`existingMatches`, `.sure`).
    /// The same first author, and the same title, edition words aside. Never without
    /// an author to compare.
    static func isSurelyTheSameBook(_ book: GenreFillBook, _ found: BookMetadata) -> Bool {
        let author = KnownNames.authorKey(book.author ?? "")
        guard !author.isEmpty, KnownNames.authorKey(found.authors.first ?? "") == author else { return false }
        return TitleMatch.relation(book.title, found.title) == .same
    }

    /// Gives the chosen books their genres, with the wording they came from, as one
    /// undoable operation, and writes their files as a save of an edited book does
    /// (`save`): nothing else of a book is changed, and its cover is left alone. Names
    /// are stored as the library's list has them.
    ///
    /// The outcomes are a save's, one for each choice in order. A choice with no
    /// genres is refused: Fill in Genres never takes a book's genres away.
    public func applyGenres(_ chosen: [GenreChoice]) throws -> [SaveOutcome] {
        var edits: [BookEdit] = []
        var refused: [Int: SaveOutcome] = [:]
        for (index, choice) in chosen.enumerated() {
            guard !GenreName.distinct(choice.genres).isEmpty else {
                refused[index] = .failed(bookId: choice.bookId, reason: "No genres were chosen for that book")
                continue
            }
            guard let book = try store.book(id: choice.bookId) else {
                refused[index] = .failed(bookId: choice.bookId, reason: Self.reason(for: LibraryError.bookNotFound(choice.bookId)))
                continue
            }
            var edit = BookEdit(book: book)
            edit.metadata.genres = choice.genres
            edit.metadata.genreSource = choice.genreSource ?? book.genreSource
            edits.append(edit)
        }
        var saved = try save(edits, label: { count, _ in
            count == 1 ? "Fill in genres" : "Fill in genres for \(count) books"
        })[...]
        return chosen.indices.map { refused[$0] ?? saved.removeFirst() }
    }
}
