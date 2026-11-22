import Foundation

/// A place book details can be looked up.
public enum LookupSource: String, Codable, Sendable, CaseIterable {
    case openLibrary, audible, libraryOfCongress

    public var title: String {
        switch self {
        case .openLibrary: "Open Library"
        case .audible: "Audible"
        case .libraryOfCongress: "Library of Congress"
        }
    }
}

/// What to search for. Only the title, author, ISBN, ASIN and narrator are ever sent to a source.
public struct LookupQuery: Equatable, Sendable {
    public var title: String
    /// First author only.
    public var author: String
    public var isbn: String?
    public var asin: String?
    /// First narrator only. Sent only by the sources that can search by it, and never alone.
    public var narrator: String?
    /// True when the book has audio: sources that list a work's editions then offer the
    /// audio ones too. Nothing of it is sent.
    public var wantsAudioEditions: Bool

    public init(
        title: String = "", author: String = "", isbn: String? = nil, asin: String? = nil, narrator: String? = nil,
        wantsAudioEditions: Bool = false
    ) {
        self.title = title
        self.author = author
        self.isbn = isbn
        self.asin = asin
        self.narrator = narrator
        self.wantsAudioEditions = wantsAudioEditions
    }

    /// True when there is nothing to search with.
    public var isEmpty: Bool {
        [title, author, isbn ?? "", asin ?? ""].allSatisfy(\.isBlank)
    }
}

/// What an edition is recorded on.
public enum EditionFormat: String, Codable, Sendable {
    case digital, cassette, cd, mp3CD, other

    /// "Cassette", "MP3 CD"; "Audio" for a kind that has no name here.
    public var label: String {
        switch self {
        case .digital: "Digital"
        case .cassette: "Cassette"
        case .cd: "CD"
        case .mp3CD: "MP3 CD"
        case .other: "Audio"
        }
    }
}

/// What a source says about which edition a result is. Everything starts unknown.
public struct EditionFacts: Equatable, Sendable {
    public var format: EditionFormat?
    /// Nil when the source does not say.
    public var abridged: Bool?
    public var publisher: String?
    public var year: Int?
    /// The Audible store codes ("us", "uk") that list it, in the order asked; empty for other sources.
    public var stores: [String]

    public init(
        format: EditionFormat? = nil, abridged: Bool? = nil, publisher: String? = nil, year: Int? = nil,
        stores: [String] = []
    ) {
        self.format = format
        self.abridged = abridged
        self.publisher = publisher
        self.year = year
        self.stores = stores
    }
}

/// One match a source found.
public struct LookupCandidate: Identifiable, Equatable, Sendable {
    /// "<source>:<source's own id>".
    public var id: String
    public var source: LookupSource
    /// Only what the source actually gave; everything else left empty or nil.
    public var metadata: BookMetadata
    public var coverURL: URL?
    /// A smaller picture of the same cover, for a row in a list; nil when the source has none.
    public var thumbnailURL: URL?
    /// One line to tell editions apart: "Audible · Unabridged · 16h 10m · English".
    public var note: String
    /// True when `LookupService.details(for:)` can add more (a description).
    public var hasMoreDetails: Bool
    /// Which edition this is, as far as the source says.
    public var edition: EditionFacts

    public init(id: String, source: LookupSource, metadata: BookMetadata, coverURL: URL? = nil,
                thumbnailURL: URL? = nil, note: String = "", hasMoreDetails: Bool = false,
                edition: EditionFacts = EditionFacts()) {
        self.id = id
        self.source = source
        self.metadata = metadata
        self.coverURL = coverURL
        self.thumbnailURL = thumbnailURL
        self.note = note
        self.hasMoreDetails = hasMoreDetails
        self.edition = edition
    }
}

public enum LookupError: Error, Equatable, Sendable {
    /// No connection, timed out, DNS.
    case notReachable
    /// The service answered with an error status.
    case refused(status: Int)
    /// The answer was not what was expected.
    case unreadable
}

/// One source of book details.
public protocol LookupProvider: Sendable {
    var source: LookupSource { get }
    func search(_ query: LookupQuery) async throws -> [LookupCandidate]
    /// The candidate with anything more the source can add. Default: unchanged.
    func details(for candidate: LookupCandidate) async throws -> LookupCandidate
}

public extension LookupProvider {
    func details(for candidate: LookupCandidate) async throws -> LookupCandidate { candidate }
}

extension String {
    var lookupTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var isBlank: Bool { lookupTrimmed.isEmpty }
    /// Trimmed, or nil when nothing is left.
    var nonBlank: String? {
        let trimmed = lookupTrimmed
        return trimmed.isEmpty ? nil : trimmed
    }
}
