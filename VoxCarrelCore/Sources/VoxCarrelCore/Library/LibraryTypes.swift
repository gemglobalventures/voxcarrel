import Foundation

public struct ImportOptions: Sendable {
    public var mode: TransferMode = .move

    public init(mode: TransferMode = .move) {
        self.mode = mode
    }
}

public enum ImportTarget: Equatable, Sendable {
    case newBook
    /// Add the candidate's files to a book already in the library.
    case existing(bookId: Int64)
}

/// One reviewed candidate, ready to import.
public struct ImportItem: Sendable {
    public var candidate: CandidateBook
    public var target: ImportTarget
    /// `.keep` uses the cover found in the files; `.set` overrides it.
    public var cover: CoverChange

    public init(candidate: CandidateBook, target: ImportTarget = .newBook, cover: CoverChange = .keep) {
        self.candidate = candidate
        self.target = target
        self.cover = cover
    }
}

public struct FileProblem: Equatable, Sendable {
    /// File name only.
    public var file: String
    public var reason: String

    public init(file: String, reason: String) {
        self.file = file
        self.reason = reason
    }
}

public enum ImportOutcome: Equatable, Sendable {
    /// Filed in the library.
    case imported(bookId: Int64, fileProblems: [FileProblem])
    /// Catalogued but left where it was, because it has no usable title or author.
    case needsAttention(bookId: Int64)
    /// Nothing changed for this item.
    case failed(reason: String)
}

public struct ImportResult: Equatable, Sendable {
    /// One per item, in order.
    public var outcomes: [ImportOutcome]

    public init(outcomes: [ImportOutcome]) {
        self.outcomes = outcomes
    }
}

/// A full replacement of a book's editable values.
public struct BookEdit: Sendable {
    public var bookId: Int64
    /// `durationSeconds` and `pageCount` are ignored: they describe the files.
    public var metadata: BookMetadata
    public var cover: CoverChange
    public var tags: [String]
    public var rating: Int

    /// Starts from the book's current values, so a caller changes only what it means to.
    public init(book: Book, cover: CoverChange = .keep) {
        // A book that was never saved has no id; 0 is never one, so such an edit fails.
        self.bookId = book.id ?? 0
        self.metadata = book.metadata
        self.cover = cover
        self.tags = book.tags
        self.rating = book.rating
    }
}

public enum SaveOutcome: Equatable, Sendable {
    case saved(bookId: Int64, refiled: Bool, appOnlyFields: Set<MetadataField>, fileProblems: [FileProblem])
    /// Nothing changed for this book.
    case failed(bookId: Int64, reason: String)
}

public enum LibraryError: Error, Equatable {
    case bookNotFound(Int64)
    case fileNotFound(Int64)
    /// The file's format cannot have that role.
    case invalidRole
    case nothingToUndo
    /// Undo could not put files back; nothing in the database was changed. Safe to retry.
    case undoBlocked(String)
}
