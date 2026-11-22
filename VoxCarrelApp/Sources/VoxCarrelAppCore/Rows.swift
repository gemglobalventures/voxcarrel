import Foundation
import VoxCarrelCore

/// One thing the sidebar can show the books of.
public enum SidebarItem: Hashable, Sendable {
    case allBooks, audiobooks, ebooks, unread, inProgress, finished, needsAttention
    /// Every book marked as owned on Audible, with or without files here.
    case onAudible
    case browse(BrowseField, String)
    case collection(Int64)

    /// The eight items every library has, in sidebar order.
    public static let fixed: [SidebarItem] = [
        .allBooks, .audiobooks, .ebooks, .onAudible, .unread, .inProgress, .finished, .needsAttention,
    ]
}

/// A book as the grid and the list show it.
public struct BookRow: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var book: Book
    /// The book has an audio file, or is owned somewhere else as an audiobook (on Audible).
    public var hasAudio: Bool
    /// The book has an ebook file, or is owned somewhere else as an ebook.
    public var hasEbook: Bool
    /// Distinct formats of the audio and ebook files, in file order. Extras not included,
    /// nor anything the book is only owned as elsewhere: these are real files.
    public var formats: [FileFormat]
    /// Whether the book has any file at all. A book that has none is owned elsewhere.
    public var hasFiles: Bool
    public var coverURL: URL?
    /// When the cover's file was last written; nil when there is no cover. A cover that
    /// is replaced keeps its place, so this is what tells the new one from the old.
    public var coverModified: Date?
    /// True when any file's tags could not be written last time.
    public var hasWriteProblem: Bool
    /// Where the book's files that are not in the library folder are: those of a book
    /// that was catalogued where it was found. Empty for a filed book.
    public var outsideFiles: [String]
    /// How many of the book's files state a length they do not have (`BookFile.lengthProblem`).
    public var lengthProblemFiles: Int
    /// How many of those have a header that can be repaired.
    public var repairableLengthFiles: Int

    public init(
        id: Int64, book: Book, hasAudio: Bool, hasEbook: Bool, formats: [FileFormat], coverURL: URL?,
        coverModified: Date? = nil, hasWriteProblem: Bool, outsideFiles: [String] = [], hasFiles: Bool = true,
        lengthProblemFiles: Int = 0, repairableLengthFiles: Int = 0
    ) {
        self.lengthProblemFiles = lengthProblemFiles
        self.repairableLengthFiles = repairableLengthFiles
        self.outsideFiles = outsideFiles
        self.hasFiles = hasFiles
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

    /// What is wrong with the file's length header, in words; nil when nothing is.
    public var lengthProblemText: String? {
        file.lengthProblem.map(LengthText.problem)
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
    /// The eight fixed items, each with its number of books (zero included).
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

    /// True when no more than `limit` books were removed, inserted or moved to another
    /// place among the rest.
    ///
    /// A table can take a small change as it is: a book that moves when it is renamed,
    /// a few that come and go. Shown a list that is very different (2,000 books in the
    /// opposite order, or 1,800 more than a moment ago) it measures every row that moved
    /// before it draws again, which takes most of a minute; it is quicker by far to make
    /// the table again.
    public static func isSmall(from old: [Int64], to new: [Int64]) -> Bool {
        if old == new { return true }
        let (before, after) = (Set(old), Set(new))
        let comeAndGone = before.subtracting(after).count + after.subtracting(before).count
        guard comeAndGone <= limit else { return false }
        let stayedBefore = old.filter(after.contains)
        let stayedAfter = new.filter(before.contains)
        if stayedBefore == stayedAfter { return true }
        // The books that stayed and did not move are the longest run of them that is in
        // the same order in both lists; the rest moved.
        var place: [Int64: Int] = [:]
        for (index, id) in stayedBefore.enumerated() { place[id] = index }
        let moved = stayedAfter.count - longestRisingRun(stayedAfter.compactMap { place[$0] })
        return comeAndGone + moved <= limit
    }

    /// The length of the longest strictly rising subsequence.
    private static func longestRisingRun(_ numbers: [Int]) -> Int {
        // tails[k]: the smallest number a rising run of length k + 1 can end with.
        var tails: [Int] = []
        for number in numbers {
            var (low, high) = (0, tails.count)
            while low < high {
                let middle = (low + high) / 2
                if tails[middle] < number { low = middle + 1 } else { high = middle }
            }
            if low == tails.count { tails.append(number) } else { tails[low] = number }
        }
        return tails.count
    }
}
