import Foundation

/// How sure it is that a library book is the one some details describe.
public enum MatchStrength: Equatable, Sendable {
    /// The same Audible ID.
    case audibleID
    /// The same first author and the same title, edition words aside.
    case sure
    /// Worth asking about, and never to be joined without asking.
    case possible
}

/// A library book that some details most likely describe.
public struct ExistingMatch: Equatable, Sendable {
    public var book: Book
    public var strength: MatchStrength

    public init(book: Book, strength: MatchStrength) {
        self.book = book
        self.strength = strength
    }
}

extension LibraryService {
    /// Adds a book that is owned elsewhere and has no files here.
    ///
    /// When the library already has the book (`existingMatch(for:)`: the same Audible ID,
    /// else the same title and first author; a possible match is not enough) that book is given the copy instead and
    /// nothing else about it changes: its details, cover and files are left alone, and no
    /// file is opened. Its `asin` is filled in from an Audible copy only when it had none
    /// (and, when it has files, is then listed among its `appOnlyFields`). A book that
    /// already has such a copy gets no second one: `.alreadyMarked`.
    ///
    /// Otherwise a book is added with the details as given (`durationSeconds` and
    /// `pageCount` included), no files and no folder, and `cover` is stored for it. For
    /// an Audible copy with an item ID, that ID is the book's `asin`.
    ///
    /// Not an undoable operation, and the one recorded is left as it is: removing the
    /// entry is the way back.
    ///
    /// - Throws: `LibraryError.invalidDetails` when the title is blank or the copy's form
    ///   is not audio or ebook. Nothing has changed then.
    public func addExternalBook(
        metadata: BookMetadata, cover: CoverImage?, copy: ExternalCopy
    ) throws -> ExternalBookOutcome {
        // X1
        guard !metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryError.invalidDetails("A book needs a title")
        }
        let copy = try Self.checked(copy)

        // The copy's own ID is the book's Audible ID, whatever the details say.
        var metadata = metadata
        if let asin = Self.audibleId(of: [copy]) { metadata.asin = asin }

        // X3
        if let match = try existingMatch(for: metadata), let id = match.id {
            var wasMarked = false
            try store.modifyBook(id: id) { book, fileCount in
                wasMarked = Self.give(copy, to: &book)
                Self.fillASIN(of: &book, hasFiles: fileCount > 0)
            }
            return wasMarked ? .alreadyMarked(bookId: id) : .markedExisting(bookId: id)
        }

        // X2. A book with no files has nothing "in the app only" (X7), is never filed
        // and so is never flagged for what filing would need.
        var book = Book(metadata: metadata, folderPath: nil, needsAttention: false)
        book.externalCopies = [copy]
        let added = try store.insert(book, files: [])
        guard let id = added.id else { throw LibraryError.invalidDetails("The book could not be added") }
        // The book is in the library; a cover that cannot be stored does not undo that.
        if let cover { try? covers.set(cover, for: id) }
        return .added(bookId: id)
    }

    /// Replaces a book's external copies. Repeats in the list are dropped.
    ///
    /// Only the database changes: no file is opened, moved or written. A book whose
    /// `asin` is empty takes the item ID of its first Audible copy that has one.
    ///
    /// Not an undoable operation, and the one recorded is left as it is.
    ///
    /// - Throws: `LibraryError.bookNotFound` for an unknown id;
    ///   `LibraryError.wouldLeaveNothing` when the book has no files and the list is
    ///   empty; `LibraryError.invalidDetails` when a copy's form is not audio or ebook.
    ///   Nothing has changed then.
    public func setExternalCopies(_ copies: [ExternalCopy], for bookId: Int64) throws {
        let copies = try copies.map(Self.checked)
        try store.modifyBook(id: bookId) { book, fileCount in
            // X4
            guard !copies.isEmpty || fileCount > 0 else { throw LibraryError.wouldLeaveNothing }
            book.externalCopies = copies
            Self.fillASIN(of: &book, hasFiles: fileCount > 0)
        }
    }

    /// The library book a set of details most likely is, and how sure that is.
    ///
    /// - `.audibleID`: a book with the same Audible ID. The ID is the details' ASIN,
    ///   compared ignoring case and surrounding spaces with each book's own ASIN and
    ///   with the item IDs of its Audible copies.
    /// - `.sure`: failing that, a book with the same first author
    ///   (`KnownNames.authorKey`) and the same title, edition words aside
    ///   (`TitleMatch.relation` is `.same`).
    /// - `.possible`: failing that, a book with the same first author whose title is the
    ///   same up to a subtitle; or, when the details name no author, a book with the
    ///   same title.
    ///
    /// Nil when there is none. Of several matches of one strength the earliest added is
    /// returned. Books flagged as needing attention are never matched. Different first
    /// authors never match without an Audible ID.
    public func existingMatches(for metadata: BookMetadata) throws -> ExistingMatch? {
        func key(_ text: String?) -> String {
            (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        func earliest(_ books: [Book]) -> Book? {
            books.min { ($0.dateAdded, $0.id ?? .max) < ($1.dateAdded, $1.id ?? .max) }
        }
        let books = try store.books(needsAttention: false)

        let asin = key(metadata.asin)
        if !asin.isEmpty {
            let sameId = books.filter { book in
                key(book.asin) == asin
                    || book.externalCopies.contains { $0.kind == .audible && key($0.itemId) == asin }
            }
            if let match = earliest(sameId) { return ExistingMatch(book: match, strength: .audibleID) }
        }

        let title = TitleMatch.parts(metadata.title)
        guard !title.core.isEmpty else { return nil }
        let author = KnownNames.authorKey(metadata.authors.first ?? "")
        var sure: [Book] = []
        var possible: [Book] = []
        for book in books {
            if author.isEmpty {
                // No author to compare: the same title is worth asking about, no more.
                if TitleMatch.relation(title, TitleMatch.parts(book.title)) == .same { possible.append(book) }
                continue
            }
            guard KnownNames.authorKey(book.authors.first ?? "") == author else { continue }
            switch TitleMatch.relation(title, TitleMatch.parts(book.title)) {
            case .same: sure.append(book)
            case .sameUpToSubtitle: possible.append(book)
            case .different: break
            }
        }
        if let match = earliest(sure) { return ExistingMatch(book: match, strength: .sure) }
        return earliest(possible).map { ExistingMatch(book: $0, strength: .possible) }
    }

    /// The library book a set of details is, when that is sure enough to join it without
    /// asking: `existingMatches(for:)` when its strength is `.audibleID` or `.sure`. A
    /// possible match is none.
    public func existingMatch(for metadata: BookMetadata) throws -> Book? {
        guard let match = try existingMatches(for: metadata), match.strength != .possible else { return nil }
        return match.book
    }

    // MARK: Helpers

    /// The copy as it is stored: its store and item ID without surrounding spaces, and
    /// nil when nothing is left. Throws when its form is not one a copy can have.
    private static func checked(_ copy: ExternalCopy) throws -> ExternalCopy {
        guard copy.form == .audio || copy.form == .ebook else {
            throw LibraryError.invalidDetails("A book owned elsewhere is an audiobook or an ebook")
        }
        func tidy(_ text: String?) -> String? {
            let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var copy = copy
        copy.store = tidy(copy.store)
        copy.itemId = tidy(copy.itemId)
        return copy
    }

    /// The item ID of the first Audible copy that has one.
    private static func audibleId(of copies: [ExternalCopy]) -> String? {
        copies.lazy.filter { $0.kind == .audible }.compactMap(\.itemId).first
    }

    /// Gives a book a copy. A book that already has one of that kind in that form keeps
    /// it, and only what that one lacks (its item ID, its store) is filled in from
    /// `copy`: an item ID it already has is never replaced, and no second copy of the
    /// same thing is added.
    /// - Returns: True when the book already had such a copy.
    @discardableResult
    static func give(_ copy: ExternalCopy, to book: inout Book) -> Bool {
        var copies = book.externalCopies
        guard let index = copies.firstIndex(where: { $0.kind == copy.kind && $0.form == copy.form }) else {
            book.externalCopies.append(copy)
            return false
        }
        if copies[index].itemId == nil {
            // An Audible ID the book already has is the one its copy means.
            let own = (book.asin ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            copies[index].itemId = copy.kind == .audible && !own.isEmpty ? own : copy.itemId
        }
        if copies[index].store == nil { copies[index].store = copy.store }
        book.externalCopies = copies
        return true
    }

    /// Keeps `asin` in step with the Audible copy: a book without an ASIN takes the
    /// copy's item ID. An ASIN the book already has is left alone (its files carry it).
    ///
    /// No file is opened for this, so for a book with files the ASIN it takes is in
    /// the app only until its tags are next written: it is listed as such.
    static func fillASIN(of book: inout Book, hasFiles: Bool) {
        let current = (book.asin ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.isEmpty, let asin = audibleId(of: book.externalCopies) else { return }
        book.asin = asin
        if hasFiles, !book.appOnlyFields.contains(.asin) {
            let fields = Set(book.appOnlyFields + [.asin])
            book.appOnlyFields = MetadataField.allCases.filter(fields.contains)
        }
    }
}
