import Foundation
import GRDB

/// Where the user is with a book. Set by hand; one status covers every form of the book.
public enum ReadStatus: String, Codable, Sendable, CaseIterable {
    case unread
    case inProgress
    case finished
}

/// A place other than the library's own files where a book can be owned.
public enum ExternalKind: String, Codable, Sendable, CaseIterable {
    case audible

    public var title: String {
        switch self {
        case .audible: "Audible"
        }
    }
}

/// One place a book is owned other than as files in the library.
public struct ExternalCopy: Codable, Equatable, Hashable, Sendable {
    public var kind: ExternalKind
    /// What it is there: `.audio` or `.ebook`. Never `.extra`.
    public var form: FileRole
    /// Which store, for a kind that has several: an `AudibleStore` raw value.
    public var store: String?
    /// The item's ID there: an ASIN for Audible.
    public var itemId: String?

    public init(kind: ExternalKind, form: FileRole, store: String? = nil, itemId: String? = nil) {
        self.kind = kind
        self.form = form
        self.store = store
        self.itemId = itemId
    }

    /// The list without repeats: the first of each copy stays where it is.
    static func withoutDuplicates(_ copies: [ExternalCopy]) -> [ExternalCopy] {
        var seen = Set<ExternalCopy>()
        return copies.filter { seen.insert($0).inserted }
    }
}

/// Decodes to nil, instead of failing, when the value is not a `Value` this code can
/// read: one unreadable element of a list then does not make the whole list unreadable.
struct Tolerant<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// One catalogued book: a single entry for every form of it (audio, ebook, extras).
/// Columns mirror `BookMetadata` plus library bookkeeping.
public struct Book: Codable, Equatable, Identifiable, Sendable,
    FetchableRecord, MutablePersistableRecord
{
    public static let databaseTableName = "book"

    public var id: Int64?

    public var title: String
    public var subtitle: String?
    public var authors: [String]
    public var narrators: [String]
    public var series: String?
    public var seriesNumber: String?
    public var genre: String?
    public var year: Int?
    public var publisher: String?
    public var summary: String?
    public var language: String?
    public var isbn: String?
    public var asin: String?
    public var durationSeconds: Double?
    public var pageCount: Int?

    public var tags: [String]
    /// 0 (unrated) to 5.
    public var rating: Int
    /// Folder relative to the library root; nil while the book is not filed.
    public var folderPath: String?
    public var needsAttention: Bool
    public var dateAdded: Date
    /// Change with `setReadStatus(_:on:)` so the dates stay consistent.
    public var readStatus: ReadStatus
    public var dateStarted: Date?
    public var dateFinished: Date?
    /// Fields that no file of this book holds; they live in the database only.
    public var appOnlyFields: [MetadataField] = []
    /// Where the book is owned other than as files in the library. Never holds the same
    /// copy twice (same kind, form, store and item ID); order is kept. A book with no
    /// files is valid only while this is not empty.
    public var externalCopies: [ExternalCopy] = [] {
        didSet {
            let unique = ExternalCopy.withoutDuplicates(externalCopies)
            if unique.count != externalCopies.count { externalCopies = unique }
        }
    }

    /// True when the book is owned somewhere other than as files in the library.
    public var isOwnedElsewhere: Bool { !externalCopies.isEmpty }

    public func isOwned(on kind: ExternalKind) -> Bool {
        externalCopies.contains { $0.kind == kind }
    }

    public init(
        metadata: BookMetadata, folderPath: String? = nil,
        needsAttention: Bool = false, dateAdded: Date = Date()
    ) {
        self.id = nil
        self.title = metadata.title
        self.subtitle = metadata.subtitle
        self.authors = metadata.authors
        self.narrators = metadata.narrators
        self.series = metadata.series
        self.seriesNumber = metadata.seriesNumber
        self.genre = metadata.genre
        self.year = metadata.year
        self.publisher = metadata.publisher
        self.summary = metadata.summary
        self.language = metadata.language
        self.isbn = metadata.isbn
        self.asin = metadata.asin
        self.durationSeconds = metadata.durationSeconds
        self.pageCount = metadata.pageCount
        self.tags = []
        self.rating = 0
        self.folderPath = folderPath
        self.needsAttention = needsAttention
        self.dateAdded = dateAdded
        self.readStatus = .unread
        self.dateStarted = nil
        self.dateFinished = nil
    }

    /// Sets the read status and keeps the dates consistent with it:
    /// unread clears both; in progress records when it started and clears the
    /// finish date; finished records the finish date (and a start date if none).
    public mutating func setReadStatus(_ status: ReadStatus, on date: Date = Date()) {
        readStatus = status
        switch status {
        case .unread:
            dateStarted = nil
            dateFinished = nil
        case .inProgress:
            dateStarted = dateStarted ?? date
            dateFinished = nil
        case .finished:
            dateStarted = dateStarted ?? date
            dateFinished = date
        }
    }

    /// Tolerant of fields that are absent: a row or a saved snapshot written before a
    /// field existed still decodes, the missing field taking its default. Add every new
    /// field here with `decodeIfPresent`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        authors = try c.decodeIfPresent([String].self, forKey: .authors) ?? []
        narrators = try c.decodeIfPresent([String].self, forKey: .narrators) ?? []
        series = try c.decodeIfPresent(String.self, forKey: .series)
        seriesNumber = try c.decodeIfPresent(String.self, forKey: .seriesNumber)
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        isbn = try c.decodeIfPresent(String.self, forKey: .isbn)
        asin = try c.decodeIfPresent(String.self, forKey: .asin)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        rating = try c.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath)
        needsAttention = try c.decodeIfPresent(Bool.self, forKey: .needsAttention) ?? false
        dateAdded = try c.decodeIfPresent(Date.self, forKey: .dateAdded) ?? Date(timeIntervalSinceReferenceDate: 0)
        readStatus = try c.decodeIfPresent(ReadStatus.self, forKey: .readStatus) ?? .unread
        dateStarted = try c.decodeIfPresent(Date.self, forKey: .dateStarted)
        dateFinished = try c.decodeIfPresent(Date.self, forKey: .dateFinished)
        appOnlyFields = try c.decodeIfPresent([MetadataField].self, forKey: .appOnlyFields) ?? []
        // A copy this code cannot read (a kind added by a newer version, say) is left
        // out, and so is anything else that is not a usable list of copies: what a book
        // is owned on must never make the book itself unreadable.
        let copies = (try? c.decodeIfPresent([Tolerant<ExternalCopy>].self, forKey: .externalCopies)) ?? []
        externalCopies = ExternalCopy.withoutDuplicates(
            copies.compactMap(\.value).filter { $0.form != .extra })
    }

    /// The descriptive fields as one value.
    public var metadata: BookMetadata {
        get {
            var m = BookMetadata(title: title, authors: authors)
            m.subtitle = subtitle
            m.narrators = narrators
            m.series = series
            m.seriesNumber = seriesNumber
            m.genre = genre
            m.year = year
            m.publisher = publisher
            m.summary = summary
            m.language = language
            m.isbn = isbn
            m.asin = asin
            m.durationSeconds = durationSeconds
            m.pageCount = pageCount
            return m
        }
        set {
            title = newValue.title
            subtitle = newValue.subtitle
            authors = newValue.authors
            narrators = newValue.narrators
            series = newValue.series
            seriesNumber = newValue.seriesNumber
            genre = newValue.genre
            year = newValue.year
            publisher = newValue.publisher
            summary = newValue.summary
            language = newValue.language
            isbn = newValue.isbn
            asin = newValue.asin
            durationSeconds = newValue.durationSeconds
            pageCount = newValue.pageCount
        }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One file belonging to a book.
public struct BookFile: Codable, Equatable, Identifiable, Sendable,
    FetchableRecord, MutablePersistableRecord
{
    public static let databaseTableName = "bookFile"

    public var id: Int64?
    public var bookId: Int64?
    /// Relative to the library root, or absolute (leading "/") for files left in place.
    public var path: String
    public var format: FileFormat
    public var role: FileRole
    /// Order within the book, starting at 0: audio parts first, then ebooks, then extras.
    public var position: Int
    /// Why the last attempt to write this file's tags failed, or nil.
    public var writeProblem: String? = nil
    /// The file's own name (with extension) when it was first filed as an extra. Kept
    /// through role changes, so a file that becomes an extra again gets its name back.
    /// Nil for a file that has never been an extra.
    public var originalName: String? = nil

    public init(path: String, format: FileFormat, role: FileRole, position: Int) {
        self.id = nil
        self.bookId = nil
        self.path = path
        self.format = format
        self.role = role
        self.position = position
    }

    /// Tolerant of optional fields that are absent, as `Book` is; what says which file
    /// this is and what it is (path, format, role) must be there.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id)
        bookId = try c.decodeIfPresent(Int64.self, forKey: .bookId)
        path = try c.decode(String.self, forKey: .path)
        format = try c.decode(FileFormat.self, forKey: .format)
        role = try c.decode(FileRole.self, forKey: .role)
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
        writeProblem = try c.decodeIfPresent(String.self, forKey: .writeProblem)
        originalName = try c.decodeIfPresent(String.self, forKey: .originalName)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A user-made list of books.
public struct BookCollection: Codable, Equatable, Identifiable, Sendable,
    FetchableRecord, MutablePersistableRecord
{
    public static let databaseTableName = "collection"

    public var id: Int64?
    public var name: String

    public init(name: String) {
        self.id = nil
        self.name = name
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Fields the sidebar can browse by. Raw values are column names.
public enum BrowseField: String, Sendable, CaseIterable {
    case authors, narrators, series, genre

    /// True for columns holding a JSON array of strings.
    var isList: Bool {
        self == .authors || self == .narrators
    }
}
