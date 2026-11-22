import Foundation

/// A place book details can be looked up.
public enum LookupSource: String, Codable, Sendable, CaseIterable {
    case openLibrary, audible

    public var title: String {
        switch self {
        case .openLibrary: "Open Library"
        case .audible: "Audible"
        }
    }
}

/// What to search for. Only these four values are ever sent to a source.
public struct LookupQuery: Equatable, Sendable {
    public var title: String
    /// First author only.
    public var author: String
    public var isbn: String?
    public var asin: String?

    public init(title: String = "", author: String = "", isbn: String? = nil, asin: String? = nil) {
        self.title = title
        self.author = author
        self.isbn = isbn
        self.asin = asin
    }

    /// True when there is nothing to search with.
    public var isEmpty: Bool {
        [title, author, isbn ?? "", asin ?? ""].allSatisfy(\.isBlank)
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
    /// One line to tell editions apart: "Audible · Unabridged · 16h 10m · English".
    public var note: String
    /// True when `LookupService.details(for:)` can add more (a description).
    public var hasMoreDetails: Bool

    public init(id: String, source: LookupSource, metadata: BookMetadata, coverURL: URL? = nil,
                note: String = "", hasMoreDetails: Bool = false) {
        self.id = id
        self.source = source
        self.metadata = metadata
        self.coverURL = coverURL
        self.note = note
        self.hasMoreDetails = hasMoreDetails
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
