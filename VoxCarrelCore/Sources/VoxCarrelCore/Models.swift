import Foundation

/// What a file is to its book.
public enum FileRole: String, Codable, Sendable, CaseIterable {
    /// The audiobook: one file, or one of its ordered parts.
    case audio
    /// The readable text of the book.
    case ebook
    /// Accompanying material (companion PDF, map, appendix). Never modified.
    case extra
}

public enum FileFormat: String, Codable, Sendable, CaseIterable {
    case m4b, m4a, mp3, epub, pdf, mobi, azw3
    /// Ebooks that are filed and listed but never opened or changed, like MOBI and
    /// AZW3: their details come from their names and from lookups.
    case djvu, prc, azw, fb2, lit, chm

    /// True for a format the app files without reading or writing what is inside.
    public var isKeptAsItIs: Bool {
        switch self {
        case .mobi, .azw3, .djvu, .prc, .azw, .fb2, .lit, .chm: true
        case .m4b, .m4a, .mp3, .epub, .pdf: false
        }
    }

    /// Nil when the extension is not a supported book format.
    public init?(url: URL) {
        self.init(rawValue: url.pathExtension.lowercased())
    }

    /// The role a file of this format has unless something says otherwise.
    public var defaultRole: FileRole {
        switch self {
        case .m4b, .m4a, .mp3: .audio
        case .epub, .pdf, .mobi, .azw3, .djvu, .prc, .azw, .fb2, .lit, .chm: .ebook
        }
    }
}

/// Descriptive fields of a book. The cover image is handled separately.
public struct BookMetadata: Codable, Equatable, Sendable {
    public var title: String = ""
    public var subtitle: String?
    public var authors: [String] = []
    public var narrators: [String] = []
    public var series: String?
    /// Free text so "2.5" and "1-3" are possible.
    public var seriesNumber: String?
    /// The book's genres in order, the main one first. No genre is there twice.
    public var genres: [String] = []
    /// The genre wording the book had from its source (a file's tag, or a lookup),
    /// unchanged. For details read from a file it is the file's genre tag as it stands.
    public var genreSource: String?
    public var year: Int?
    public var publisher: String?
    /// The book's description / blurb.
    public var summary: String?
    public var language: String?
    public var isbn: String?
    public var asin: String?
    public var durationSeconds: Double?
    public var pageCount: Int?

    public init() {}

    public init(title: String, authors: [String] = []) {
        self.title = title
        self.authors = authors
    }

    /// Tolerant of fields that are absent, so saved data written before a field existed
    /// still decodes. Add every new field here with `decodeIfPresent`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        authors = try c.decodeIfPresent([String].self, forKey: .authors) ?? []
        narrators = try c.decodeIfPresent([String].self, forKey: .narrators) ?? []
        series = try c.decodeIfPresent(String.self, forKey: .series)
        seriesNumber = try c.decodeIfPresent(String.self, forKey: .seriesNumber)
        if let list = try c.decodeIfPresent([String].self, forKey: .genres) {
            genres = list
            genreSource = try c.decodeIfPresent(String.self, forKey: .genreSource)
        } else {
            // Written before a book had several genres: one text, which is the wording
            // and gives the genres.
            let old = try decoder.container(keyedBy: EarlierKeys.self)
            (genres, genreSource) = Self.genres(fromEarlier: try old.decodeIfPresent(String.self, forKey: .genre))
        }
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        isbn = try c.decodeIfPresent(String.self, forKey: .isbn)
        asin = try c.decodeIfPresent(String.self, forKey: .asin)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount)
    }

    /// The key the one genre text was saved under before a book had several genres.
    enum EarlierKeys: String, CodingKey {
        case genre
    }

    /// What one genre text saved by an earlier version comes to: the text is the source
    /// wording, and the mapping gives the genres.
    static func genres(fromEarlier text: String?) -> (genres: [String], source: String?) {
        guard let text else { return ([], nil) }
        return (GenreMapping.map(.text(text)).names, text)
    }

    /// These details as they go back into the file they were read from: the genre tag
    /// exactly as the file had it, whatever genres it was read as.
    var asReadFromFile: BookMetadata {
        var details = self
        details.genres = genreSource.map { [$0] } ?? []
        return details
    }
}

/// A file on disk together with its role in a book that is not yet in the library.
public struct CandidateFile: Equatable, Sendable {
    public var url: URL
    public var role: FileRole

    public init(url: URL, role: FileRole) {
        self.url = url
        self.role = role
    }
}

/// One completed file transfer, with absolute paths, kept so it can be undone.
public struct MoveRecord: Codable, Equatable, Sendable {
    public var from: String
    public var to: String
    public var wasCopy: Bool

    public init(from: String, to: String, wasCopy: Bool) {
        self.from = from
        self.to = to
        self.wasCopy = wasCopy
    }
}
