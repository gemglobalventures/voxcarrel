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

/// Any JSON value, kept exactly as it was read so that it can be written back.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let value = try? c.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? c.decode(Double.self) {
            self = .number(value)
        } else if let value = try? c.decode(String.self) {
            self = .string(value)
        } else if let value = try? c.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
}

/// A book's external copies as they are stored: one list, of which this code reads the
/// copies it knows. An entry it cannot read (a kind added by a newer version, say) is
/// kept exactly as it was and written back after the others, so that an older version
/// changing a book never loses what a newer one recorded.
struct StoredCopies: Codable, Equatable, Sendable {
    /// The copies this code can read, without repeats.
    var known: [ExternalCopy] = []
    /// Everything else that was in the list, untouched.
    var unread: [JSONValue] = []

    init() {}

    private enum Entry: Decodable {
        case known(ExternalCopy)
        case unread(JSONValue)

        init(from decoder: Decoder) throws {
            if let copy = try? ExternalCopy(from: decoder), copy.form != .extra {
                self = .known(copy)
            } else {
                self = .unread(try JSONValue(from: decoder))
            }
        }
    }

    init(from decoder: Decoder) throws {
        var list = try decoder.unkeyedContainer()
        var known: [ExternalCopy] = []
        while !list.isAtEnd {
            switch try list.decode(Entry.self) {
            case .known(let copy): known.append(copy)
            case .unread(let value): unread.append(value)
            }
        }
        self.known = ExternalCopy.withoutDuplicates(known)
    }

    func encode(to encoder: Encoder) throws {
        var list = encoder.unkeyedContainer()
        for copy in known { try list.encode(copy) }
        for value in unread { try list.encode(value) }
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
    ///
    /// Copies recorded by a newer version, which this one cannot read, are not listed
    /// here, and are kept with the book whatever is done to this list.
    public var externalCopies: [ExternalCopy] {
        get { storedCopies.known }
        set { storedCopies.known = ExternalCopy.withoutDuplicates(newValue) }
    }

    /// The copies as stored, with those this code cannot read.
    var storedCopies = StoredCopies()

    /// Whether the audiobook is unabridged, abridged or a dramatisation, with how that
    /// is known; nil when it is not known. Kept in the catalogue only: never written
    /// into a file's tags.
    public var editionKind: EditionKindNote? = nil
    /// True when the audio files the book was imported from were numbered with gaps
    /// (1, 2, 4): it may be incomplete, and its length is no sign of an abridgement.
    /// Recorded at import, because filing gives the parts new names.
    public var partsAppearMissing = false

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, authors, narrators, series, seriesNumber, genre, year, publisher, summary
        case language, isbn, asin, durationSeconds, pageCount, tags, rating, folderPath, needsAttention
        case dateAdded, readStatus, dateStarted, dateFinished, appOnlyFields
        case storedCopies = "externalCopies"
        case editionKind, partsAppearMissing
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
        // A copy this code cannot read (a kind added by a newer version, say) is not
        // listed, and is kept to be written back. Text that is not a list of anything
        // counts as no copies: what a book is owned on must never make the book itself
        // unreadable.
        storedCopies = (try? c.decodeIfPresent(StoredCopies.self, forKey: .storedCopies)) ?? StoredCopies()
        // A value this code cannot read (a kind or a basis added by a newer version)
        // counts as not known: it must never make the book, or an undo snapshot holding
        // it, unreadable.
        editionKind = (try? c.decodeIfPresent(EditionKindNote.self, forKey: .editionKind)) ?? nil
        partsAppearMissing = (try? c.decodeIfPresent(Bool.self, forKey: .partsAppearMissing)) ?? false
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
    /// Set for an MP3 whose length header states a length the audio does not have, as
    /// found when the file was last read. Nil for a file with nothing wrong, and for one
    /// that has not been measured.
    public var lengthProblem: LengthProblem? = nil
    /// Set for an MP3 whose length had to be measured and could not be, as found when the
    /// file was last read: the length counted for it is the one it states. It holds for
    /// the file as it was then (`UnmeasuredLength.describes`).
    public var lengthUnmeasured: UnmeasuredLength? = nil

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
        // A value this code cannot read counts as none: it must never make the file's
        // row, or an undo snapshot holding it, unreadable.
        lengthProblem = (try? c.decodeIfPresent(LengthProblem.self, forKey: .lengthProblem)) ?? nil
        lengthUnmeasured = (try? c.decodeIfPresent(UnmeasuredLength.self, forKey: .lengthUnmeasured)) ?? nil
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

/// A watch folder as it is stored. Dates in this table and in the ledger are kept as
/// numbers, so that they come back exactly as they went in.
struct WatchFolderRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "watchFolder"
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSinceReferenceDate
    }
    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSinceReferenceDate
    }

    var id: Int64?
    var path: String
    var mode: WatchFolderMode
    var isEnabled: Bool
    var includesPDFs: Bool
    var addedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// The folder this row describes; nil for a row not yet stored.
    var folder: WatchFolder? {
        guard let id else { return nil }
        return WatchFolder(
            id: id, path: path, mode: mode, isEnabled: isEnabled, includesPDFs: includesPDFs, addedAt: addedAt)
    }
}

/// Why a file under a watch folder is not offered in the inbox.
enum InboxEntryState: String, Codable, Sendable {
    /// It was there when the folder was added.
    case baseline
    /// The owner dismissed it.
    case dismissed
    /// It was imported and left where it was.
    case imported
}

/// One line of the inbox ledger: a file not to offer, as it was when that was decided.
/// A file whose size or modification date has changed since is a different file.
struct InboxEntryRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "inboxEntry"
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSinceReferenceDate
    }
    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSinceReferenceDate
    }

    var id: Int64?
    var folderId: Int64
    /// Absolute, as the folder's listing spelled it.
    var path: String
    var size: Int64
    var modifiedAt: Date
    var state: InboxEntryState

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A library series tied to an Audible series, as it is stored. The date is kept as a
/// number, so that it comes back exactly as it went in.
struct SeriesLinkRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "seriesLink"
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSinceReferenceDate
    }
    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSinceReferenceDate
    }

    var id: Int64?
    /// What says which series this is: the value of the books' `series` column.
    var seriesKey: String
    var seriesName: String
    var audibleSeriesId: String
    var audibleSeriesTitle: String
    /// An `AudibleStore` raw value.
    var store: String
    var checkedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One book of a series as Audible lists it, as it is stored: a `SeriesEntry` with what
/// is known of its preferred edition.
struct SeriesEntryRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "seriesEntry"
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSinceReferenceDate
    }
    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSinceReferenceDate
    }

    var id: Int64?
    var linkId: Int64
    /// Its place in the series, from 0.
    var position: Int
    var number: String?
    var sort: Double
    /// The preferred edition's title.
    var title: String
    /// Every edition's ASIN, the preferred first.
    var asins: [String]
    /// Every title its editions go by, the preferred's first.
    var titles: [String]
    var authors: [String]
    var narrators: [String]
    var minutes: Int?
    var isAbridged: Bool?
    var releaseDate: Date?
    var isHidden: Bool

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// The row for an entry, not yet stored and not hidden.
    init(_ entry: SeriesEntry) {
        id = nil
        linkId = 0
        position = 0
        number = entry.number
        sort = entry.sort.isFinite ? entry.sort : .greatestFiniteMagnitude
        title = entry.preferred.title
        asins = entry.asins
        titles = entry.titles
        authors = entry.preferred.authors
        narrators = entry.preferred.narrators
        minutes = entry.preferred.minutes
        isAbridged = entry.preferred.isAbridged
        releaseDate = entry.preferred.releaseDate
        isHidden = false
    }

    /// The entry this row holds. Its preferred edition carries the entry's own number
    /// and ordering value.
    var entry: SeriesEntry {
        SeriesEntry(
            number: number, sort: sort,
            preferred: AudibleSeriesEdition(
                asin: asins.first ?? "", title: title, number: number, sort: sort, authors: authors,
                narrators: narrators, minutes: minutes, isAbridged: isAbridged, releaseDate: releaseDate),
            asins: asins, titles: titles.isEmpty ? [title] : titles)
    }
}
