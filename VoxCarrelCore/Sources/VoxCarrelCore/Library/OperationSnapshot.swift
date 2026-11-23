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
    /// 3 added `merge`: code that does not know it would put the files back and leave
    /// the entries that were merged away out of the catalogue.
    static let currentVersion = 3

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

    /// Set when the operation merged entries into one: what undoing that needs besides
    /// the kept book's own snapshot, which is the one in `books`.
    var merge: MergeSnapshot? {
        didSet { if merge != nil { version = max(version, 3) } }
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
        merge = try c.decodeIfPresent(MergeSnapshot.self, forKey: .merge)
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

/// What undoing a merge of entries needs, besides the kept book's own snapshot.
struct MergeSnapshot: Codable, Equatable {
    /// The entries the merge removed, in the order they were chosen.
    var removed: [RemovedBook]
    /// The collections the kept book was put in by the merge: it was in none of them before.
    var collectionsJoined: [Int64]

    /// One entry that was merged away, with everything that was attached to it.
    struct RemovedBook: Codable, Equatable {
        /// The entry as it was, with its id.
        var book: Book
        /// Its file rows as they were, with their ids.
        var files: [BookFile]
        /// Its stored cover: a file name in the undo folder, or nil for "had none".
        var storedCover: String?
        /// The collections it was in.
        var collectionIds: [Int64]
        /// The rows of its sent records, which the merge gave to the kept book.
        var sentRecordIds: [Int64]

        init(book: Book, files: [BookFile], storedCover: String?, collectionIds: [Int64], sentRecordIds: [Int64]) {
            self.book = book
            self.files = files
            self.storedCover = storedCover
            self.collectionIds = collectionIds
            self.sentRecordIds = sentRecordIds
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Required: without the entry there is nothing to put back.
            book = try c.decode(Book.self, forKey: .book)
            files = try c.decodeIfPresent([BookFile].self, forKey: .files) ?? []
            storedCover = try c.decodeIfPresent(String.self, forKey: .storedCover)
            collectionIds = try c.decodeIfPresent([Int64].self, forKey: .collectionIds) ?? []
            sentRecordIds = try c.decodeIfPresent([Int64].self, forKey: .sentRecordIds) ?? []
        }
    }

    init(removed: [RemovedBook], collectionsJoined: [Int64]) {
        self.removed = removed
        self.collectionsJoined = collectionsJoined
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        removed = try c.decodeIfPresent([RemovedBook].self, forKey: .removed) ?? []
        collectionsJoined = try c.decodeIfPresent([Int64].self, forKey: .collectionsJoined) ?? []
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
    /// Set when the operation kept the file as it was before its tags were written, so
    /// that it can be put back byte for byte.
    var original: SavedOriginal?

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
        original = try? c.decodeIfPresent(SavedOriginal.self, forKey: .original)
    }
}

/// A file as it was before an operation wrote into it, kept whole among the
/// operation's undo data.
struct SavedOriginal: Codable, Equatable {
    /// The kept file's name in the operation's undo folder.
    var fileName: String
    /// What the file was then.
    var before: FileStamp
    /// What the file was once the operation had written it; nil when it never was.
    var written: FileStamp?
}

/// A file's size and modification time, to the nanosecond as the disk keeps it: enough
/// to tell whether it is still the file it was at some moment.
struct FileStamp: Codable, Equatable {
    var size: Int64
    var seconds: Int64
    var nanoseconds: Int64

    /// The stamp of the file at `url` itself (a link is not followed); nil when there
    /// is nothing there.
    init?(fileAt url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        size = Int64(info.st_size)
        seconds = Int64(info.st_mtimespec.tv_sec)
        nanoseconds = Int64(info.st_mtimespec.tv_nsec)
    }

    /// Gives the file at `url` this stamp's modification time.
    func setTime(ofFileAt url: URL) {
        var times = [
            timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
            timespec(tv_sec: Int(seconds), tv_nsec: Int(nanoseconds)),
        ]
        _ = utimensat(AT_FDCWD, url.path, &times, 0)
    }
}

enum CoverBefore: Codable, Equatable {
    /// The file had no cover.
    case none
    /// The file's cover, saved under this name in the operation's undo folder.
    case saved(fileName: String)
}
