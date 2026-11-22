import Foundation

/// Looks books up in Open Library. A result is a *work*, which may have many editions.
public struct OpenLibraryProvider: LookupProvider {
    public let source = LookupSource.openLibrary
    private let http: any HTTPFetching
    private let limit: Int

    static let host = "openlibrary.org"
    static let coverHost = "covers.openlibrary.org"
    static let fields = "key,title,subtitle,author_name,first_publish_year,publisher,isbn,cover_i,language,subject,number_of_pages_median,edition_count"

    public init(http: any HTTPFetching, limit: Int = 8) {
        self.http = http
        self.limit = limit
    }

    public func search(_ query: LookupQuery) async throws -> [LookupCandidate] {
        let askedISBN = query.isbn.flatMap(LookupText.isbn)
        var items: [(name: String, value: String)] = []
        if let askedISBN {
            items.append(("isbn", askedISBN))
        } else {
            if let title = query.title.nonBlank { items.append(("title", title)) }
            if let author = query.author.nonBlank { items.append(("author", author)) }
        }
        guard !items.isEmpty else { return [] }
        items.append(("limit", String(limit)))
        items.append(("fields", Self.fields))
        guard let url = LookupRequest.url(host: Self.host, path: "/search.json", query: items) else { return [] }

        let answer = try await LookupRequest.object(at: url, http: http)
        guard let docs = answer["docs"] as? [Any] else { throw LookupError.unreadable }
        return docs.compactMap { candidate(from: $0, askedISBN: askedISBN) }
    }

    /// Nil for a result without a usable key and title.
    private func candidate(from doc: Any, askedISBN: String?) -> LookupCandidate? {
        guard let doc = doc as? [String: Any],
              let key = doc["key"] as? String, Self.isKey(key),
              let title = (doc["title"] as? String)?.nonBlank
        else { return nil }

        var metadata = BookMetadata(title: title)
        metadata.subtitle = (doc["subtitle"] as? String)?.nonBlank
        metadata.authors = (doc["author_name"] as? [String] ?? []).compactMap(\.nonBlank)
        metadata.year = doc["first_publish_year"] as? Int
        metadata.pageCount = doc["number_of_pages_median"] as? Int

        // Across many editions these are a jumble; with one edition they describe it.
        let editions = doc["edition_count"] as? Int
        if editions == 1 {
            if let publishers = doc["publisher"] as? [String], publishers.count == 1 {
                metadata.publisher = publishers[0].nonBlank
            }
            if let languages = doc["language"] as? [String], languages.count == 1 {
                metadata.language = LookupText.languageCode(languages[0])
            }
            let isbns = (doc["isbn"] as? [String] ?? []).compactMap(LookupText.isbn)
            metadata.isbn = isbns.first { $0.count == 13 } ?? isbns.first
        }
        if let askedISBN { metadata.isbn = askedISBN }

        var note = [source.title]
        if let year = metadata.year { note.append(String(year)) }
        if let editions, editions > 0 { note.append(editions == 1 ? "1 edition" : "\(editions) editions") }

        return LookupCandidate(
            id: "\(source.rawValue):\(key)",
            source: source,
            metadata: metadata,
            coverURL: (doc["cover_i"] as? Int).flatMap { URL(string: "https://\(Self.coverHost)/b/id/\($0)-L.jpg") },
            note: note.joined(separator: " · "),
            hasMoreDetails: true
        )
    }

    /// Adds the work's description. Afterwards there is nothing more to ask for.
    public func details(for candidate: LookupCandidate) async throws -> LookupCandidate {
        let prefix = "\(source.rawValue):"
        guard candidate.source == source, candidate.id.hasPrefix(prefix) else { return candidate }
        let key = String(candidate.id.dropFirst(prefix.count))
        guard Self.isKey(key), let url = LookupRequest.url(host: Self.host, path: "\(key).json", query: []) else {
            return candidate
        }
        let work = try await LookupRequest.object(at: url, http: http)
        var detailed = candidate
        detailed.hasMoreDetails = false
        let raw = work["description"] as? String ?? (work["description"] as? [String: Any])?["value"] as? String
        if let summary = raw.map(Self.description).flatMap(\.nonBlank) {
            detailed.metadata.summary = summary
        }
        return detailed
    }

    /// "/works/OL21745884W": one lower-case word and one identifier, nothing that could
    /// lead a request anywhere else.
    static func isKey(_ key: String) -> Bool {
        key.range(of: "^/[a-z]+/[A-Za-z0-9]+$", options: .regularExpression) != nil
    }

    /// A description without the source notes Open Library editors append.
    static func description(_ raw: String) -> String {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        let kept = lines.prefix { line in
            let start = line.lookupTrimmed.lowercased()
            return !start.hasPrefix("([source]") && !start.hasPrefix("----------")
        }
        return LookupText.plainText(fromHTML: kept.joined(separator: "\n"))
    }
}
