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
    /// True when any file's tags could not be written last time.
    public var hasWriteProblem: Bool

    public init(
        id: Int64, book: Book, hasAudio: Bool, hasEbook: Bool, formats: [FileFormat], coverURL: URL?,
        hasWriteProblem: Bool
    ) {
        self.id = id
        self.book = book
        self.hasAudio = hasAudio
        self.hasEbook = hasEbook
        self.formats = formats
        self.coverURL = coverURL
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
