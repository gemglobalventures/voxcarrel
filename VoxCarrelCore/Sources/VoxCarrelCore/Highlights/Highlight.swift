import Foundation
import GRDB

/// Where a highlight came from.
public enum HighlightSource: String, Codable, Sendable, CaseIterable {
    case readwise, audible, own

    public var title: String {
        switch self {
        case .readwise: "Readwise"
        case .audible: "Audible"
        case .own: "Added here"
        }
    }
}

/// What the number that places a highlight in its book counts.
public enum HighlightLocationKind: String, Codable, Sendable {
    /// A Kindle location.
    case location
    case page
    /// Its place in the order the source gives, where it gives nothing better.
    case order
    /// Seconds from the start of an audiobook.
    case time
}

/// A passage marked in a book, with what was noted about it. For a mark made while
/// listening, the text may be empty: the place is all there is until it is written out.
public struct Highlight: Codable, Equatable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "highlight"

    public var id: Int64?
    public var bookId: Int64
    public var source: HighlightSource
    /// What the source calls it; for one added here, an id made up when it was added.
    public var sourceId: String
    public var text: String
    public var note: String?
    public var location: Double?
    public var endLocation: Double?
    public var locationKind: HighlightLocationKind?
    public var madeAt: Date?
    public var colour: String?
    /// The highlight's own page at its source.
    public var link: String?
    public var isFavourite: Bool
    public var tags: [String]

    public init(
        bookId: Int64, source: HighlightSource, sourceId: String, text: String, note: String? = nil,
        location: Double? = nil, endLocation: Double? = nil, locationKind: HighlightLocationKind? = nil,
        madeAt: Date? = nil, colour: String? = nil, link: String? = nil, isFavourite: Bool = false, tags: [String] = []
    ) {
        self.id = nil
        self.bookId = bookId
        self.source = source
        self.sourceId = sourceId
        self.text = text
        self.note = note
        self.location = location
        self.endLocation = endLocation
        self.locationKind = locationKind
        self.madeAt = madeAt
        self.colour = colour
        self.link = link
        self.isFavourite = isFavourite
        self.tags = tags
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A highlight as a source gives it, before it belongs to a book of the library.
public struct IncomingHighlight: Equatable, Sendable {
    public var sourceId: String
    public var text: String
    public var note: String?
    public var location: Double?
    public var endLocation: Double?
    public var locationKind: HighlightLocationKind?
    public var madeAt: Date?
    public var colour: String?
    public var link: String?
    public var isFavourite = false
    public var tags: [String] = []
    /// True when the source says it was deleted there: it is taken out here too.
    public var isDeleted = false

    public init(sourceId: String, text: String) {
        self.sourceId = sourceId
        self.text = text
    }
}

/// A book as a source of highlights names it, with its highlights.
public struct HighlightedBook: Equatable, Sendable {
    public var title: String
    public var authors: [String]
    /// The book's ID where it is owned: a Kindle ID, or an Audible ID.
    public var itemId: String?
    /// Where the book is owned, when the source says: such a book can be added to the
    /// library as an entry with no files. Nil for a book that is only named.
    public var ownedOn: ExternalKind?
    public var coverURL: URL?
    public var source: HighlightSource
    public var highlights: [IncomingHighlight]

    public init(title: String, authors: [String], source: HighlightSource, highlights: [IncomingHighlight]) {
        self.title = title
        self.authors = authors
        self.source = source
        self.highlights = highlights
    }
}

/// What bringing highlights in would do, or did.
public struct HighlightsReport: Equatable, Sendable {
    /// Books the library did not have, added as owned elsewhere with no files.
    public var booksAdded: [String] = []
    /// Books of the library that have highlights from this.
    public var booksMatched = 0
    /// Of those, the books that get a highlight they did not have.
    public var booksGaining = 0
    /// Books that are in no library and are owned nowhere the app knows: left out.
    public var booksLeftOut: [String] = []
    public var added = 0
    public var changed = 0
    public var removed = 0
    public var unchanged = 0

    public init() {}

    public var changesNothing: Bool { booksAdded.isEmpty && added == 0 && changed == 0 && removed == 0 }
}
