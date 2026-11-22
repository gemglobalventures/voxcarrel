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

/// What the launch-time check found.
public struct ReconcileReport: Equatable, Sendable {
    /// Books with at least one file missing, now flagged needs-attention.
    public var booksWithMissingFiles: [Int64]
    /// Books that were flagged only because files were missing, and are whole again.
    public var booksRecovered: [Int64]
    /// Supported book files inside the library that no book refers to.
    public var untrackedFiles: [URL]
    /// Hidden working copies left by an interrupted tag write, now deleted.
    public var removedWorkingCopies: Int
    /// Files left under a temporary name by an interrupted move. Never deleted.
    public var strandedFiles: [URL]
    /// Books whose recorded length was wrong because an MP3 of theirs states the wrong
    /// length, now corrected to the measured one.
    public var correctedLengths: Int
    /// MP3 files found, by this check, to state a length they do not have: they were not
    /// recorded as such before.
    public var filesWithWrongLength: Int

    public init(
        booksWithMissingFiles: [Int64] = [], booksRecovered: [Int64] = [], untrackedFiles: [URL] = [],
        removedWorkingCopies: Int = 0, strandedFiles: [URL] = [], correctedLengths: Int = 0,
        filesWithWrongLength: Int = 0
    ) {
        self.correctedLengths = correctedLengths
        self.filesWithWrongLength = filesWithWrongLength
        self.booksWithMissingFiles = booksWithMissingFiles
        self.booksRecovered = booksRecovered
        self.untrackedFiles = untrackedFiles
        self.removedWorkingCopies = removedWorkingCopies
        self.strandedFiles = strandedFiles
    }
}

/// What became of a book added as owned elsewhere (`LibraryService.addExternalBook`).
public enum ExternalBookOutcome: Equatable, Sendable {
    case added(bookId: Int64)
    /// The library already had this book; it now carries the copy too.
    case markedExisting(bookId: Int64)
    /// The library already had this book, and it was already marked as owned there in
    /// that form. Only what its copy lacked (an item ID, a store) was filled in.
    case alreadyMarked(bookId: Int64)
}

public enum LibraryError: Error, Equatable {
    case bookNotFound(Int64)
    case fileNotFound(Int64)
    /// The file's format cannot have that role.
    case invalidRole
    case nothingToUndo
    /// Undo could not put files back. Nothing was changed: not the files, not the tags
    /// inside them, not the database. Safe to retry once the obstacle is gone.
    case undoBlocked(String)
    /// An operation could not be committed (`cause`), and when its file moves were
    /// reversed some files could not be put back. `stranded` names each file still in the
    /// library and where it came from, as "<where it is> (from <where it was>)". Nothing
    /// in the database refers to them.
    case rollbackIncomplete(cause: String, stranded: [String])
    /// A missing file could not be replaced by the chosen one. The text says why.
    /// Nothing was changed.
    case cannotLocate(String)
    /// A book with no files must be owned somewhere: the change would leave an empty entry.
    /// Nothing was changed.
    case wouldLeaveNothing
    /// The details given for a book cannot be used. The text says why, in plain words.
    /// Nothing was changed.
    case invalidDetails(String)
}
