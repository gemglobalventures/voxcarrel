import Foundation
import VoxCarrelCore

/// One thing the sidebar can show the books of.
public enum SidebarItem: Hashable, Sendable {
    case allBooks, audiobooks, ebooks, unread, inProgress, finished, needsAttention
    /// Every book marked as owned on Audible, with or without files here.
    case onAudible
    /// The books that have one value of a browse field. A genre is one of these:
    /// `.browse(.genre, name)` is the one way a genre is selected.
    case browse(BrowseField, String)
    /// G35: every book with a genre of this group, each once.
    case genreGroup(GenreGroup)
    /// G36: the books that have no genre.
    case noGenre
    case collection(Int64)
    /// The books that have arrived in the watch folders and wait to be reviewed. Shown
    /// only while there is a watch folder (`AppModel.showsInbox`), and not one of `fixed`:
    /// it lists arrivals, not books of the library.
    case inbox

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
    /// How many of the book's files have a length that could not be measured
    /// (`BookFile.lengthUnmeasured`): the book's length is then not to be relied on.
    public var unmeasuredLengthFiles: Int
    /// Not nil for a row that stands for a book the library does not have: one that
    /// Audible's list of the series shown has and the library lacks. Such a row has a
    /// negative id, which is no book's, and no files, cover or copies.
    public var missing: MissingEntry?
    /// For a book of a series that has been checked against Audible, how the book
    /// stands with Audible's list when that is worth saying: "Audible: #7" when Audible
    /// numbers it differently, "Not on Audible's list" when the list does not have it.
    /// Nil otherwise, and wherever the rows are not those of such a series.
    public var seriesNote: String?

    /// Whether the row stands for a book the library does not have.
    public var isMissing: Bool { missing != nil }

    public init(
        id: Int64, book: Book, hasAudio: Bool, hasEbook: Bool, formats: [FileFormat], coverURL: URL?,
        coverModified: Date? = nil, hasWriteProblem: Bool, outsideFiles: [String] = [], hasFiles: Bool = true,
        lengthProblemFiles: Int = 0, repairableLengthFiles: Int = 0, unmeasuredLengthFiles: Int = 0,
        missing: MissingEntry? = nil
    ) {
        self.missing = missing
        self.unmeasuredLengthFiles = unmeasuredLengthFiles
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

    /// Said when the file's length could not be measured, so nothing is known to be
    /// wrong with its header and there is nothing to repair; nil otherwise.
    public var lengthUnmeasuredText: String? {
        file.lengthProblem == nil && file.lengthUnmeasured != nil ? LengthText.unmeasured : nil
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
    /// What the library's folder pattern needs and the book lacks, so that it cannot be
    /// filed; empty when it lacks nothing. Nil when that has not been worked out.
    public var missingForFiling: [FolderToken]?
    /// Why the book is not, and cannot now be, filed where the library's folder layout
    /// files it, as the library says it; nil when nothing stands in its way, or that
    /// has not been worked out.
    public var unfiledReason: String?
    /// PH29: when the book was last sent to the phone; nil when it never was, or that
    /// has not been read.
    public var lastSent: Date?
    /// MG5: the other book to offer a merge with, when this one is flagged because the
    /// folder it belongs in is that book's; nil otherwise, or when that has not been read.
    public var mergeOffer: MergeOffer?

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
    /// Every browse field's values, sorted ignoring case; blank values left out. For
    /// genres: the genres that have books, in the order the sidebar's tree shows them.
    public var browse: [BrowseField: [String]]
    public var collections: [BookCollection]
    /// The library's list of genres, those merged away included, each with its number
    /// of books: by group, the built-in ones in their own order, then the owner's own.
    public var genres: [GenreEntry]
    /// G35: how many books have a genre of each group, each book counted once.
    public var genreGroupCounts: [GenreGroup: Int]
    /// G36: how many books have no genre.
    public var noGenreCount: Int
    /// G13: how many books have files whose genre tag differs from what would be written.
    public var genreFilesToUpdate: Int
    /// The length of all the library's audio, in seconds, for the status bar.
    public var audioSeconds: Double = 0

    public init(
        counts: [SidebarItem: Int], browse: [BrowseField: [String]], collections: [BookCollection],
        genres: [GenreEntry] = [], genreGroupCounts: [GenreGroup: Int] = [:], noGenreCount: Int = 0,
        genreFilesToUpdate: Int = 0
    ) {
        self.counts = counts
        self.browse = browse
        self.collections = collections
        self.genres = genres
        self.genreGroupCounts = genreGroupCounts
        self.noGenreCount = noGenreCount
        self.genreFilesToUpdate = genreFilesToUpdate
    }
}

/// A scanned candidate with what the review sheet needs to show beside it.
public struct ImportSeed: Equatable, Sendable {
    public var candidate: CandidateBook
    /// Found in the candidate's files, or failing that beside them.
    public var cover: CoverImage?
    /// True when `cover` is a picture found beside the book, which its files do not
    /// hold: it is sent with the import so that the book gets it.
    public var coverIsFromBeside = false
    public var existingMatch: Book?
    /// IH1: how sure `existingMatch` is. Means nothing without one.
    public var matchStrength: MatchStrength = .sure
    /// IH3: whether that book has an audio file in the library, and a PDF as its ebook.
    public var matchHasAudio = false
    public var matchHasPDFEbook = false
    /// The measured length of the candidate's one audio file; nil when it has none or
    /// several, or the file's length could not be measured.
    public var measuredAudio: MeasuredAudio?

    /// A seed whose match, when it has one, is a sure one.
    public init(
        candidate: CandidateBook, cover: CoverImage?, existingMatch: Book?, measuredAudio: MeasuredAudio? = nil
    ) {
        self.measuredAudio = measuredAudio
        self.candidate = candidate
        self.cover = cover
        self.existingMatch = existingMatch
    }

    public init(
        candidate: CandidateBook, cover: CoverImage?, match: ImportMatch?, measuredAudio: MeasuredAudio? = nil
    ) {
        self.init(candidate: candidate, cover: cover, existingMatch: match?.book, measuredAudio: measuredAudio)
        if let match {
            matchStrength = match.strength
            matchHasAudio = match.hasAudio
            matchHasPDFEbook = match.hasPDFEbook
        }
    }

    /// The match with its strength and what the book has; nil when there is none.
    public var match: ImportMatch? {
        existingMatch.map {
            ImportMatch(book: $0, strength: matchStrength, hasAudio: matchHasAudio, hasPDFEbook: matchHasPDFEbook)
        }
    }
}

/// A library book that files being imported may be added to, how sure it is that they
/// are that book, and what the book already has.
public struct ImportMatch: Equatable, Sendable {
    public var book: Book
    public var strength: MatchStrength
    /// Whether the book has an audio file in the library.
    public var hasAudio: Bool
    /// Whether the book has a PDF as its ebook.
    public var hasPDFEbook: Bool

    public init(book: Book, strength: MatchStrength, hasAudio: Bool = false, hasPDFEbook: Bool = false) {
        self.book = book
        self.strength = strength
        self.hasAudio = hasAudio
        self.hasPDFEbook = hasPDFEbook
    }
}

/// The measured length of one audio file that is waiting to be imported.
public struct MeasuredAudio: Equatable, Sendable {
    public var file: URL
    public var seconds: Double

    public init(file: URL, seconds: Double) {
        self.file = file
        self.seconds = seconds
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
