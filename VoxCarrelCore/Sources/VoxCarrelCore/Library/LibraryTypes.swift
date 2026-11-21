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

public enum LibraryError: Error, Equatable {
    case bookNotFound(Int64)
    case fileNotFound(Int64)
    /// The file's format cannot have that role.
    case invalidRole
    case nothingToUndo
    /// Undo could not put files back; nothing in the database was changed. Safe to retry.
    case undoBlocked(String)
}
