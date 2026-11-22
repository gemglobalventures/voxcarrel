import Foundation

/// What one search found, across every source.
public struct LookupResults: Equatable, Sendable {
    /// Best first.
    public var candidates: [LookupCandidate]
    /// Sources that could not answer.
    public var failures: [LookupSource: LookupError]
    /// Sources that were asked.
    public var searched: [LookupSource]
    /// How many of `candidates` each source that answered found; 0 for one that found none.
    public var found: [LookupSource: Int]

    public init(
        candidates: [LookupCandidate] = [], failures: [LookupSource: LookupError] = [:], searched: [LookupSource] = [],
        found: [LookupSource: Int] = [:]
    ) {
        self.candidates = candidates
        self.failures = failures
        self.searched = searched
        self.found = found
    }
}

/// Asks every lookup source at once, ranks what they found, and fetches covers.
/// Nothing here touches the library: results are only ever handed back.
public struct LookupService: Sendable {
    let providers: [any LookupProvider]
    private let http: any HTTPFetching

    /// The only hosts a cover is downloaded from: the ones the providers produce.
    static let coverHosts: Set<String> = ["covers.openlibrary.org", "m.media-amazon.com", "images-na.ssl-images-amazon.com"]
    static let coverByteLimit = 10 * 1024 * 1024
    /// Scores this close count as equal when ordering results.
    static let nearEqual = 0.05

    public init(providers: [any LookupProvider], http: any HTTPFetching) {
        self.providers = providers
        self.http = http
    }

    /// The standard set: Open Library and Audible for `store`, over the real network.
    public static func standard(store: AudibleStore) -> LookupService {
        let http = URLSessionFetcher()
        return LookupService(providers: [OpenLibraryProvider(http: http), AudibleProvider(http: http, store: store)], http: http)
    }

    // MARK: Search

    /// Asks every provider at the same time and waits for all of them. Never throws: a
    /// source that fails is named in `failures` and the others' results are kept.
    /// `language`: the two-letter code results are preferred in; nil for no preference.
    /// When the calling task is cancelled the requests are cancelled too, and the sources
    /// cut short are not reported as failures.
    /// `sources`: the only sources to ask; nil for all of them. A source that is not
    /// named is sent nothing and is not in `searched`.
    public func search(
        _ query: LookupQuery, preferAudio: Bool, language: String?, sources: Set<LookupSource>? = nil
    ) async -> LookupResults {
        guard !query.isEmpty else { return LookupResults() }
        let providers = providers.filter { sources?.contains($0.source) ?? true }
        var results = LookupResults(searched: providers.map(\.source))
        guard !Task.isCancelled else { return results }

        let answers = await Self.askAll(providers, query)

        var found: [LookupCandidate] = []
        var seen: Set<String> = []
        for (provider, answer) in zip(providers, answers) {
            switch answer {
            case .success(let candidates):
                // Provider order; a second candidate with the same id is dropped.
                var kept = 0
                for candidate in candidates where seen.insert(candidate.id).inserted {
                    found.append(candidate)
                    kept += 1
                }
                results.found[provider.source, default: 0] += kept
            case .failure(let error):
                if error is CancellationError { continue }
                results.failures[provider.source] = error as? LookupError ?? .unreadable
            case nil:
                break
            }
        }
        results.candidates = Self.ranked(found, query: query, preferAudio: preferAudio, language: language)
        return results
    }

    /// One answer per provider, in provider order; nil for one that gave none.
    private struct Answer: Sendable {
        var index: Int
        var result: Result<[LookupCandidate], any Error>
    }

    /// Asks every provider at once and waits for all of them.
    private static func askAll(
        _ providers: [any LookupProvider], _ query: LookupQuery
    ) async -> [Result<[LookupCandidate], any Error>?] {
        var byIndex: [Int: Result<[LookupCandidate], any Error>] = [:]
        await withTaskGroup(of: Answer.self) { group in
            for index in providers.indices {
                let provider = providers[index]
                let position = index
                group.addTask {
                    do {
                        return Answer(index: position, result: .success(try await provider.search(query)))
                    } catch {
                        return Answer(index: position, result: .failure(error))
                    }
                }
            }
            for await answer in group { byIndex[answer.index] = answer.result }
        }
        return providers.indices.map { byIndex[$0] }
    }

    /// Best first. The query's own ASIN or ISBN leads; then by match score; among scores
    /// within `nearEqual` of each other the preferred kind of source comes first, and a
    /// result known to be in another language goes after the rest; ties keep their order.
    static func ranked(_ candidates: [LookupCandidate], query: LookupQuery, preferAudio: Bool, language: String?) -> [LookupCandidate] {
        struct Entry {
            var candidate: LookupCandidate
            var index: Int
            var score: Double
            var sourceRank: Int
            var otherLanguage: Bool
        }
        let preferred: LookupSource = preferAudio ? .audible : .openLibrary
        let wanted = language.flatMap(LookupText.languageCode)
        let askedASIN = query.asin?.nonBlank?.uppercased()
        let askedISBN = query.isbn.flatMap(LookupText.isbn)

        var exact: [Entry] = []
        var rest: [Entry] = []
        for (index, candidate) in candidates.enumerated() {
            let known = candidate.metadata.language.flatMap(LookupText.languageCode)
            let entry = Entry(candidate: candidate, index: index, score: score(candidate, query: query),
                              sourceRank: candidate.source == preferred ? 0 : 1,
                              otherLanguage: wanted != nil && known != nil && known != wanted)
            let sameASIN = askedASIN != nil && candidate.metadata.asin?.nonBlank?.uppercased() == askedASIN
            let sameISBN = askedISBN != nil && candidate.metadata.isbn.flatMap(LookupText.isbn) == askedISBN
            if sameASIN || sameISBN { exact.append(entry) } else { rest.append(entry) }
        }

        func byPreference(_ a: Entry, _ b: Entry) -> Bool {
            if a.sourceRank != b.sourceRank { return a.sourceRank < b.sourceRank }
            if a.otherLanguage != b.otherLanguage { return !a.otherLanguage }
            if a.score != b.score { return a.score > b.score }
            return a.index < b.index
        }

        rest.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        var ordered = exact.sorted(by: byPreference)
        // Bands of near-equal scores, each measured from its best member.
        var start = 0
        while start < rest.count {
            var end = start + 1
            while end < rest.count, rest[start].score - rest[end].score <= nearEqual { end += 1 }
            ordered += rest[start..<end].sorted(by: byPreference)
            start = end
        }
        return ordered.map(\.candidate)
    }

    /// The candidate's best match score: against any one of its authors or all of them,
    /// with or without its subtitle.
    static func score(_ candidate: LookupCandidate, query: LookupQuery) -> Double {
        let metadata = candidate.metadata
        var titles = [metadata.title]
        if let subtitle = metadata.subtitle?.nonBlank { titles.append("\(metadata.title) \(subtitle)") }
        var authors = metadata.authors
        if authors.count != 1 { authors.append(metadata.authors.joined(separator: " ")) }
        var best = 0.0
        for title in titles {
            for author in authors {
                best = max(best, LookupText.matchScore(title: title, author: author, query: query))
            }
        }
        return best
    }

    // MARK: Details

    /// Anything more the candidate's source can add. A candidate from a source with no
    /// provider is returned unchanged.
    public func details(for candidate: LookupCandidate) async throws -> LookupCandidate {
        guard let provider = providers.first(where: { $0.source == candidate.source }) else { return candidate }
        return try await provider.details(for: candidate)
    }

    // MARK: Cover

    /// Where a cover's address may redirect: the cover hosts, and the Internet Archive,
    /// which holds Open Library's covers.
    static let coverRedirectHosts: Set<String> = coverHosts.union(["archive.org"])

    /// Downloads the candidate's cover. Throws `.unreadable` when there is no cover, when
    /// its address is not `https` on one of the known cover hosts (no request is made), or
    /// when what arrives is not a JPEG or PNG of at most 10 MB.
    public func cover(for candidate: LookupCandidate) async throws -> CoverImage {
        try await image(at: candidate.coverURL)
    }

    /// The same for the smaller picture a result's row shows: `thumbnailURL`, or the
    /// cover itself when the candidate has no smaller one.
    public func thumbnail(for candidate: LookupCandidate) async throws -> CoverImage {
        try await image(at: candidate.thumbnailURL ?? candidate.coverURL)
    }

    private func image(at url: URL?) async throws -> CoverImage {
        guard let url, Self.isCoverAddress(url) else { throw LookupError.unreadable }
        let answer = try await http.get(
            url, headers: ["User-Agent": LookupRequest.userAgent], maxBytes: Self.coverByteLimit,
            redirectHosts: Self.coverRedirectHosts)
        guard answer.status == 200 else { throw LookupError.refused(status: answer.status) }
        guard answer.data.count <= Self.coverByteLimit,
              let mime = CoverImage.sniffedMIME(answer.data), mime == "image/jpeg" || mime == "image/png"
        else { throw LookupError.unreadable }
        return CoverImage(data: answer.data, mime: mime)
    }

    static func isCoverAddress(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), coverHosts.contains(host),
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443
        else { return false }
        return true
    }
}
