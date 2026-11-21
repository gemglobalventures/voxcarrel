import Foundation

/// What undo needs to reverse one operation. Stored as JSON with the journal batch.
struct OperationSnapshot: Codable, Equatable {
    /// Folder name under `layout.undoFolder` holding saved cover images for this operation.
    var token: String
    var books: [BookSnapshot]
}

struct BookSnapshot: Codable, Equatable {
    var bookId: Int64
    /// The book before the operation; nil when the operation created it.
    var bookBefore: Book?
    var filesBefore: [BookFile]
    /// Tags inside each audio or ebook file before the operation. Only files whose tags
    /// the operation really changed, and which could be read beforehand, are listed.
    var fileStates: [FileState]
    /// The cover-store image before: a file name in the undo folder, or nil for "had none".
    var storedCoverBefore: String?
}

struct FileState: Codable, Equatable {
    /// Absolute path of the file after the operation.
    var pathAfter: String
    var metadataBefore: BookMetadata
    /// The part position to give when writing `metadataBefore` back: the file's place among
    /// the book's audio parts before the operation, or, for a file the operation brought
    /// into the library as one of several parts, the place it was given (so that its own
    /// track title, which was not touched, is not touched by the restore either).
    var part: PartPosition?
    /// Set only when the operation changed the cover inside the file.
    var coverBefore: CoverBefore?
}

enum CoverBefore: Codable, Equatable {
    /// The file had no cover.
    case none
    /// The file's cover, saved under this name in the operation's undo folder.
    case saved(fileName: String)
}
