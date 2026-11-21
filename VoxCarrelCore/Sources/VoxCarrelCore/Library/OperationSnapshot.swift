import Foundation

/// What undo needs to reverse one operation. Stored as JSON with the journal batch.
///
/// Every type here decodes tolerantly: a field that is absent takes its default, and a
/// field this code does not know is ignored, so adding a field later does not make data
/// already saved unreadable. A change that older code could not act on safely must raise
/// `currentVersion` instead.
struct OperationSnapshot: Codable, Equatable {
    /// The newest snapshot layout this code understands.
    static let currentVersion = 1

    /// The layout the snapshot was written in. A snapshot with a higher version than
    /// `currentVersion` cannot be undone by this code.
    var version = OperationSnapshot.currentVersion
    /// Folder name under `layout.undoFolder` holding saved cover images for this operation.
    var token: String
    var books: [BookSnapshot]

    init(token: String, books: [BookSnapshot]) {
        self.token = token
        self.books = books
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        token = try c.decode(String.self, forKey: .token)
        books = try c.decodeIfPresent([BookSnapshot].self, forKey: .books) ?? []
    }

    /// The snapshot in `data`, or nil when it cannot be read or was written by newer code.
    static func usable(from data: Data) -> OperationSnapshot? {
        guard let snapshot = try? JSONDecoder().decode(OperationSnapshot.self, from: data),
              snapshot.version <= currentVersion
        else { return nil }
        return snapshot
    }
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

    init(
        bookId: Int64, bookBefore: Book?, filesBefore: [BookFile], fileStates: [FileState],
        storedCoverBefore: String?
    ) {
        self.bookId = bookId
        self.bookBefore = bookBefore
        self.filesBefore = filesBefore
        self.fileStates = fileStates
        self.storedCoverBefore = storedCoverBefore
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookId = try c.decode(Int64.self, forKey: .bookId)
        bookBefore = try c.decodeIfPresent(Book.self, forKey: .bookBefore)
        filesBefore = try c.decodeIfPresent([BookFile].self, forKey: .filesBefore) ?? []
        fileStates = try c.decodeIfPresent([FileState].self, forKey: .fileStates) ?? []
        storedCoverBefore = try c.decodeIfPresent(String.self, forKey: .storedCoverBefore)
    }
}

struct FileState: Codable, Equatable {
    /// Absolute path of the file after the operation.
    var pathAfter: String
    var metadataBefore: BookMetadata
    /// The file's place among the book's audio parts before the operation, or, for a file
    /// the operation brought into the library as one of several parts, the place it was
    /// given. Only decides the track tags when `trackBefore` is nil.
    var part: PartPosition?
    /// An audio file's own track title and number before the operation. Restoring puts
    /// these back exactly. Nil for other formats.
    var trackBefore: TrackTags?
    /// Set only when the operation changed the cover inside the file.
    var coverBefore: CoverBefore?

    init(
        pathAfter: String, metadataBefore: BookMetadata, part: PartPosition?, trackBefore: TrackTags?,
        coverBefore: CoverBefore?
    ) {
        self.pathAfter = pathAfter
        self.metadataBefore = metadataBefore
        self.part = part
        self.trackBefore = trackBefore
        self.coverBefore = coverBefore
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pathAfter = try c.decode(String.self, forKey: .pathAfter)
        // Required: writing an empty stand-in back would wipe the file's tags.
        metadataBefore = try c.decode(BookMetadata.self, forKey: .metadataBefore)
        part = try c.decodeIfPresent(PartPosition.self, forKey: .part)
        trackBefore = try c.decodeIfPresent(TrackTags.self, forKey: .trackBefore)
        coverBefore = try c.decodeIfPresent(CoverBefore.self, forKey: .coverBefore)
    }
}

enum CoverBefore: Codable, Equatable {
    /// The file had no cover.
    case none
    /// The file's cover, saved under this name in the operation's undo folder.
    case saved(fileName: String)
}
