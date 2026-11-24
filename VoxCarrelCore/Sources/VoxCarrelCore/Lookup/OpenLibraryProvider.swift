import Foundation

/// Looks books up in Open Library. A result is a *work*, which may have many editions;
/// for a book with audio, the audio editions of the best-matching work follow the works.
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

    /// The most editions asked for of one work, and the most audio editions offered.
    static let editionsAsked = 100
    static let editionsOffered = 12

    public func search(_ query: LookupQuery) async throws -> [LookupCandidate] {
        let works = try await works(for: query)
        guard query.wantsAudioEditions, let work = Self.bestMatch(works, query: query) else { return works }
        do {
            return works + (try await audioEditions(of: work))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The works are an answer already: the editions are only more.
            return works
        }
    }

    /// The work that matches what was asked for best; among equals, the first.
    private static func bestMatch(_ works: [LookupCandidate], query: LookupQuery) -> LookupCandidate? {
        var best: (work: LookupCandidate, score: Double)?
        for work in works {
            let score = LookupService.score(work, query: query)
            if best == nil || score > (best?.score ?? 0) { best = (work, score) }
        }
        return best?.work
    }

    private func works(for query: LookupQuery) async throws -> [LookupCandidate] {
        var words: [(name: String, value: String)] = []
        if let title = query.title.nonBlank { words.append(("title", title)) }
        if let author = query.author.nonBlank { words.append(("author", author)) }

        if let askedISBN = query.isbn.flatMap(LookupText.isbn) {
            let found = try await docs(matching: [("isbn", askedISBN)]).compactMap { candidate(from: $0, askedISBN: askedISBN) }
            // An ISBN Open Library does not know: the title and author are searched for
            // instead. A request that failed has thrown by now, and is not searched around.
            if !found.isEmpty || words.isEmpty { return found }
        }
        guard !words.isEmpty else { return [] }
        return try await docs(matching: words).compactMap { candidate(from: $0, askedISBN: nil) }
    }

    private func docs(matching items: [(name: String, value: String)]) async throws -> [Any] {
        let items = items + [("limit", String(limit)), ("fields", Self.fields)]
        guard let url = LookupRequest.url(host: Self.host, path: "/search.json", query: items) else { return [] }
        let answer = try await LookupRequest.object(at: url, http: http)
        guard let docs = answer["docs"] as? [Any] else { throw LookupError.unreadable }
        return docs
    }

    /// The most subjects taken from one work: a work can list hundreds.
    static let subjectLimit = 50

    /// A work's subjects as listed, each made safe to keep, the first `subjectLimit` of them.
    static func subjects(_ list: Any?) -> [String] {
        Array((list as? [Any] ?? []).prefix(500)
            .compactMap { LookupText.cleaned($0 as? String, limit: LookupText.lineLimit) }
            .prefix(subjectLimit))
    }

    /// Nil for a result without a usable key and title.
    private func candidate(from doc: Any, askedISBN: String?) -> LookupCandidate? {
        guard let doc = doc as? [String: Any],
              let key = doc["key"] as? String, Self.isKey(key),
              let title = LookupText.cleaned(doc["title"] as? String, limit: LookupText.nameLimit)
        else { return nil }

        var metadata = BookMetadata(title: title)
        metadata.subtitle = LookupText.cleaned(doc["subtitle"] as? String, limit: LookupText.nameLimit)
        metadata.authors = LookupText.cleanedNames((doc["author_name"] as? [Any] ?? []).compactMap { $0 as? String })
        metadata.year = LookupText.year(doc["first_publish_year"] as? Int)
        metadata.pageCount = (doc["number_of_pages_median"] as? Int).flatMap { (1...100_000).contains($0) ? $0 : nil }

        // Across many editions these are a jumble; with one edition they describe it.
        let editions = (doc["edition_count"] as? Int).flatMap { (1...1_000_000).contains($0) ? $0 : nil }
        if editions == 1 {
            if let publishers = doc["publisher"] as? [String], publishers.count == 1 {
                metadata.publisher = LookupText.cleaned(publishers[0], limit: LookupText.lineLimit)
            }
            if let languages = doc["language"] as? [String], languages.count == 1 {
                metadata.language = LookupText.languageCode(languages[0])
            }
            let isbns = (doc["isbn"] as? [Any] ?? []).prefix(200).compactMap { ($0 as? String).flatMap(LookupText.isbn) }
            metadata.isbn = isbns.first { $0.count == 13 } ?? isbns.first
        }
        if let askedISBN { metadata.isbn = askedISBN }
        // The subjects go to the mapping together; one it does not know is dropped there.
        let subjects = GenreSource.subjects(Self.subjects(doc["subject"]))
        metadata.genres = GenreMapping.map(subjects).names
        metadata.genreSource = GenreMapping.wording(of: subjects)

        var note = [source.title]
        if let year = metadata.year { note.append(String(year)) }
        if let editions { note.append(editions == 1 ? "1 edition" : "\(editions) editions") }

        let cover = (doc["cover_i"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        return LookupCandidate(
            id: "\(source.rawValue):\(key)",
            source: source,
            metadata: metadata,
            coverURL: cover.flatMap { URL(string: "https://\(Self.coverHost)/b/id/\($0)-L.jpg") },
            thumbnailURL: cover.flatMap { URL(string: "https://\(Self.coverHost)/b/id/\($0)-M.jpg") },
            note: note.joined(separator: " · "),
            hasMoreDetails: true
        )
    }

    // MARK: Editions

    /// The audio editions among the first hundred of a work: most recent first, undated
    /// last, at most twelve. Authors are the work's; an edition names no narrator and no length.
    private func audioEditions(of work: LookupCandidate) async throws -> [LookupCandidate] {
        let key = String(work.id.dropFirst(source.rawValue.count + 1))
        guard Self.isKey(key), key.hasPrefix("/works/"),
              let url = LookupRequest.url(host: Self.host, path: "\(key)/editions.json", query: [("limit", String(Self.editionsAsked))])
        else { return [] }
        let answer = try await LookupRequest.object(at: url, http: http)
        guard let entries = answer["entries"] as? [Any] else { throw LookupError.unreadable }
        let found = entries.prefix(Self.editionsAsked).compactMap { edition(from: $0, of: work) }
        let dated = found.enumerated().sorted { first, second in
            switch (first.element.metadata.year, second.element.metadata.year) {
            case (let a?, let b?) where a != b: a > b
            case (_?, nil): true
            case (nil, _?): false
            default: first.offset < second.offset
            }
        }
        return Array(dated.map(\.element).prefix(Self.editionsOffered))
    }

    /// Nil for an edition that is not audio, or has no usable key.
    private func edition(from entry: Any, of work: LookupCandidate) -> LookupCandidate? {
        guard let entry = entry as? [String: Any],
              let key = entry["key"] as? String, Self.isKey(key), key.hasPrefix("/books/")
        else { return nil }
        let said = LookupText.cleaned(entry["physical_format"] as? String, limit: LookupText.lineLimit)
        let publishers = LookupText.cleanedNames((entry["publishers"] as? [Any] ?? []).compactMap { $0 as? String })
        // What the edition says it is decides; only when it does not say, its publishers' names.
        guard said.map(Self.isAudio) ?? publishers.contains(where: Self.isAudio) else { return nil }
        let format = said.map(Self.format)

        var metadata = BookMetadata(
            title: LookupText.cleaned(entry["title"] as? String, limit: LookupText.nameLimit) ?? work.metadata.title)
        metadata.subtitle = LookupText.cleaned(entry["subtitle"] as? String, limit: LookupText.nameLimit)
        metadata.authors = work.metadata.authors
        // An edition is of the work, and has the work's subjects.
        metadata.genres = work.metadata.genres
        metadata.genreSource = work.metadata.genreSource
        metadata.publisher = publishers.first.flatMap { LookupText.cleaned($0, limit: LookupText.lineLimit) }
        metadata.year = (entry["publish_date"] as? String).flatMap(Self.year)
        let isbns = ["isbn_13", "isbn_10"].flatMap { (entry[$0] as? [Any] ?? []).prefix(50) }
            .compactMap { ($0 as? String).flatMap(LookupText.isbn) }
        metadata.isbn = isbns.first { $0.count == 13 } ?? isbns.first
        // "/languages/eng". Several languages are a jumble; one describes the edition.
        if let languages = entry["languages"] as? [Any], languages.count == 1,
           let language = (languages[0] as? [String: Any])?["key"] as? String {
            metadata.language = language.split(separator: "/").last.flatMap { LookupText.languageCode(String($0)) }
        }

        let name = (entry["edition_name"] as? String)?.lowercased() ?? ""
        let abridged: Bool? = name.contains("unabridged") ? false : name.contains("abridged") ? true : nil

        var note = [source.title, format?.label ?? EditionFormat.other.label]
        if let publisher = metadata.publisher { note.append(publisher) }
        if let year = metadata.year { note.append(String(year)) }

        let cover = (entry["covers"] as? [Any] ?? []).prefix(50).lazy.compactMap { $0 as? Int }.first { $0 > 0 }
        return LookupCandidate(
            id: "\(source.rawValue):\(key)",
            source: source,
            metadata: metadata,
            coverURL: cover.flatMap { URL(string: "https://\(Self.coverHost)/b/id/\($0)-L.jpg") },
            thumbnailURL: cover.flatMap { URL(string: "https://\(Self.coverHost)/b/id/\($0)-M.jpg") },
            note: note.joined(separator: " · "),
            hasMoreDetails: false,
            edition: EditionFacts(format: format, abridged: abridged, publisher: metadata.publisher, year: metadata.year)
        )
    }

    /// Whether a format or a publisher's name is one of sound: "Audio Cassette", "MP3 CD",
    /// "HarperAudio". "cd" counts as a word of its own, not inside another.
    static func isAudio(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if ["audio", "cassette", "mp3", "sound", "compact disc"].contains(where: lowered.contains) { return true }
        return LookupText.comparable(lowered, droppingArticle: false).contains("cd")
    }

    /// What an audio format is recorded on.
    static func format(_ text: String) -> EditionFormat {
        let lowered = text.lowercased()
        if lowered.contains("cassette") { return .cassette }
        if lowered.contains("mp3") { return .mp3CD }
        if lowered.contains("compact disc") || LookupText.comparable(lowered, droppingArticle: false).contains("cd") { return .cd }
        if lowered.contains("download") || lowered.contains("audible") { return .digital }
        return .other
    }

    /// Four digits standing alone anywhere in a date: "October 2000", "September 12, 1988".
    private static func year(_ date: String) -> Int? {
        guard let digits = LookupText.firstMatch("(?<![0-9])[0-9]{4}(?![0-9])", in: String(date.prefix(100)))?.first else { return nil }
        return LookupText.year(Int(digits))
    }

    // MARK: Details

    /// Adds the work's description. Afterwards there is nothing more to ask for. An
    /// edition has nothing more.
    public func details(for candidate: LookupCandidate) async throws -> LookupCandidate {
        let prefix = "\(source.rawValue):"
        guard candidate.source == source, candidate.id.hasPrefix(prefix) else { return candidate }
        let key = String(candidate.id.dropFirst(prefix.count))
        guard Self.isKey(key), key.hasPrefix("/works/"), let url = LookupRequest.url(host: Self.host, path: "\(key).json", query: []) else {
            return candidate
        }
        let work = try await LookupRequest.object(at: url, http: http)
        var detailed = candidate
        detailed.hasMoreDetails = false
        let raw = work["description"] as? String ?? (work["description"] as? [String: Any])?["value"] as? String
        if let summary = raw.map(Self.description).flatMap({ LookupText.cleaned($0, limit: LookupText.summaryLimit, multiline: true) }) {
            detailed.metadata.summary = summary
        }
        return detailed
    }

    /// "/works/OL21745884W": one lower-case word and one identifier, nothing that could
    /// lead a request anywhere else.
    static func isKey(_ key: String) -> Bool {
        // The whole of it, read character by character: nothing before, between or after.
        let parts = key.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty else { return false }
        let isLower: (Unicode.Scalar) -> Bool = { $0.value >= 97 && $0.value <= 122 }
        let isUpper: (Unicode.Scalar) -> Bool = { $0.value >= 65 && $0.value <= 90 }
        let isDigit: (Unicode.Scalar) -> Bool = { $0.value >= 48 && $0.value <= 57 }
        return parts[1].allSatisfy(isLower) && parts[2].allSatisfy { isLower($0) || isUpper($0) || isDigit($0) }
    }

    /// A description without the source notes Open Library editors append, the link
    /// references at its end, and the Markdown marks of emphasis.
    static func description(_ raw: String) -> String {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var kept = Array(lines.prefix { line in
            let start = line.lookupTrimmed.lowercased()
            return !start.hasPrefix("([source]") && !start.hasPrefix("----------")
        })
        // "[1]: https://…" lines at the end, and the blank lines among them.
        while let last = kept.last, last.isBlank || Self.isLinkReference(last) { kept.removeLast() }
        return withoutEmphasis(LookupText.plainText(fromHTML: kept.joined(separator: "\n")))
    }

    /// "[1]: https://example.org/page"
    private static func isLinkReference(_ line: String) -> Bool {
        line.range(of: "^\\s*\\[[0-9]{1,4}\\]:\\s*\\S", options: .regularExpression) != nil
    }

    /// `**bold**`, `*italic*` and `_italic_` without their marks. A mark that is not one
    /// of a pair around words on one line (a footnote star, snake_case, "2 * 3") is left.
    static func withoutEmphasis(_ text: String) -> String {
        var text = text
        for pattern in [
            "\\*\\*([^*\\s\\n](?:[^*\\n]{0,400}[^*\\s\\n])?)\\*\\*",
            "(?<![\\w*])\\*([^*\\s\\n](?:[^*\\n]{0,400}[^*\\s\\n])?)\\*(?![\\w*])",
            "(?<![\\w_])_([^_\\s\\n](?:[^_\\n]{0,400}[^_\\s\\n])?)_(?![\\w_])",
        ] {
            text = text.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        }
        return text
    }
}
