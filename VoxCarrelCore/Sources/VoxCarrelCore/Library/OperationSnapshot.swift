import Foundation

/// What undo needs to reverse one operation. Stored as JSON with the journal batch.
///
/// Every type here decodes tolerantly: a field that is absent takes its default, and a
/// field this code does not know is ignored, so adding a field later does not make data
/// already saved unreadable. A change that older code could not act on safely must raise
/// `currentVersion` instead.
struct OperationSnapshot: Codable, Equatable {
    /// The newest snapshot layout this code understands. 2 added `layoutChange`: code
    /// that does not know it would put the folders back and leave the new pattern.
    static let currentVersion = 2

    /// The oldest layout whose code can act on this snapshot safely: 1, unless it
    /// carries something only newer code knows what to do with. A snapshot with a
    /// higher version than `currentVersion` cannot be undone by this code.
    var version = 1
    /// Folder name under `layout.undoFolder` holding saved cover images for this operation.
    var token: String
    var books: [BookSnapshot]
    /// Set when the operation changed the library's folder layout: what undoing that
    /// needs. The batch's moves are then moves of whole book folders, and `books` is empty.
    var layoutChange: LayoutChangeSnapshot? {
        didSet { if layoutChange != nil { version = max(version, 2) } }
    }

    init(token: String, books: [BookSnapshot]) {
        self.token = token
        self.books = books
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        token = try c.decode(String.self, forKey: .token)
        books = try c.decodeIfPresent([BookSnapshot].self, forKey: .books) ?? []
        layoutChange = try c.decodeIfPresent(LayoutChangeSnapshot.self, forKey: .layoutChange)
    }

    /// The snapshot in `data`, or nil when it cannot be read or was written by newer code.
    static func usable(from data: Data) -> OperationSnapshot? {
        guard let snapshot = try? JSONDecoder().decode(OperationSnapshot.self, from: data),
              snapshot.version <= currentVersion
        else { return nil }
        return snapshot
    }
}

/// What undoing a change of folder layout needs, besides the folder moves themselves.
struct LayoutChangeSnapshot: Codable, Equatable {
    /// The pattern as the catalogue stored it before the change; nil when none was
    /// stored (the standard pattern).
    var patternTextBefore: String?
    /// Every book the change wrote: those whose folder moved, and those it flagged.
    var books: [BookBefore]

    struct BookBefore: Codable, Equatable {
        var bookId: Int64
        /// The book's folder before and after, as stored. Equal for a book that was
        /// only flagged.
        var folderBefore: String?
        var folderAfter: String?
        var needsAttentionBefore: Bool
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
    /// The first frame of each MP3 whose length header the operation rewrote, as it was.
    /// Empty for every other operation, and absent from snapshots saved before it existed.
    var headerRepairs: [HeaderRepairState]

    init(
        bookId: Int64, bookBefore: Book?, filesBefore: [BookFile], fileStates: [FileState],
        storedCoverBefore: String?, headerRepairs: [HeaderRepairState] = []
    ) {
        self.headerRepairs = headerRepairs
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
        headerRepairs = try c.decodeIfPresent([HeaderRepairState].self, forKey: .headerRepairs) ?? []
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
