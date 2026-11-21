import Foundation
import VoxCarrelCore

/// One thing the sidebar can show the books of.
public enum SidebarItem: Hashable, Sendable {
    case allBooks, audiobooks, ebooks, unread, inProgress, finished, needsAttention
    case browse(BrowseField, String)
    case collection(Int64)

    /// The seven items every library has, in sidebar order.
    public static let fixed: [SidebarItem] = [
        .allBooks, .audiobooks, .ebooks, .unread, .inProgress, .finished, .needsAttention,
    ]
}

/// A book as the grid and the list show it.
public struct BookRow: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var book: Book
    public var hasAudio: Bool
    public var hasEbook: Bool
    /// Distinct formats of the audio and ebook files, in file order. Extras not included.
    public var formats: [FileFormat]
    public var coverURL: URL?
    /// When the cover's file was last written; nil when there is no cover. A cover that
    /// is replaced keeps its place, so this is what tells the new one from the old.
    public var coverModified: Date?
    /// True when any file's tags could not be written last time.
    public var hasWriteProblem: Bool

    public init(
        id: Int64, book: Book, hasAudio: Bool, hasEbook: Bool, formats: [FileFormat], coverURL: URL?,
        coverModified: Date? = nil, hasWriteProblem: Bool
    ) {
        self.id = id
        self.book = book
        self.hasAudio = hasAudio
        self.hasEbook = hasEbook
        self.formats = formats
        self.coverURL = coverURL
        self.coverModified = coverModified
        self.hasWriteProblem = hasWriteProblem
    }
}

/// One file of a book as the inspector shows it.
public struct FileRow: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var file: BookFile
    public var url: URL
    /// Last path component.
    public var name: String
    public var isMissing: Bool
    /// Roles this file's format may take.
    public var allowedRoles: [FileRole]

    public init(id: Int64, file: BookFile, url: URL, name: String, isMissing: Bool, allowedRoles: [FileRole]) {
        self.id = id
        self.file = file
        self.url = url
        self.name = name
        self.isMissing = isMissing
        self.allowedRoles = allowedRoles
    }

    /// The roles `LibraryService.setRole` accepts for a format: an audio format is always
    /// audio; every ebook format is an ebook or an extra.
    public static func allowedRoles(for format: FileFormat) -> [FileRole] {
        format.defaultRole == .audio ? [.audio] : [.ebook, .extra]
    }
}

/// Everything the inspector shows about one book.
public struct BookDetail: Equatable, Sendable {
    public var row: BookRow
    public var files: [FileRow]
    /// Of the first audio file; 0 when there is none or it cannot be read.
    public var chapterCount: Int
    public var collectionIds: Set<Int64>

    public init(row: BookRow, files: [FileRow], chapterCount: Int, collectionIds: Set<Int64>) {
        self.row = row
        self.files = files
        self.chapterCount = chapterCount
        self.collectionIds = collectionIds
    }
}

/// What the sidebar shows.
public struct SidebarData: Equatable, Sendable {
    /// The seven fixed items, each with its number of books (zero included).
    public var counts: [SidebarItem: Int]
    /// Every browse field's values, sorted ignoring case; blank values left out.
    public var browse: [BrowseField: [String]]
    public var collections: [BookCollection]

    public init(counts: [SidebarItem: Int], browse: [BrowseField: [String]], collections: [BookCollection]) {
        self.counts = counts
        self.browse = browse
        self.collections = collections
    }
}

/// A scanned candidate with what the review sheet needs to show beside it.
public struct ImportSeed: Equatable, Sendable {
    public var candidate: CandidateBook
    /// Found in the candidate's files.
    public var cover: CoverImage?
    public var existingMatch: Book?

    public init(candidate: CandidateBook, cover: CoverImage?, existingMatch: Book?) {
        self.candidate = candidate
        self.cover = cover
        self.existingMatch = existingMatch
    }
}

/// How much a list of books has changed.
public enum RowsChange {
    /// The most books that may come and go in a small change.
    public static let limit = 20

    /// True when the books that are in both lists are in the same order in both, and no
    /// more than `limit` were removed or inserted between them.
    ///
    /// A table can take a small change as it is. Shown a list that is very different
    /// (2,000 books in the opposite order, or 1,800 more than a moment ago) it measures
    /// every row that moved before it draws again, which takes most of a minute; it is
    /// quicker by far to make the table again.
    public static func isSmall(from old: [Int64], to new: [Int64]) -> Bool {
        if old == new { return true }
        let (before, after) = (Set(old), Set(new))
        guard before.subtracting(after).count + after.subtracting(before).count <= limit else { return false }
        return old.filter(after.contains) == new.filter(before.contains)
    }
}
