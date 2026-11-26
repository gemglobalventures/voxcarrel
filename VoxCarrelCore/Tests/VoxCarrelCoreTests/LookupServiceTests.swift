import Foundation
import Testing
@testable import VoxCarrelCore

/// Counts arrivals, so a test can prove several providers were running at the same moment.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var cancelled = 0

    func arrive() { lock.withLock { count += 1 } }
    func noteCancelled() { lock.withLock { cancelled += 1 } }
    var arrivals: Int { lock.withLock { count } }
    var cancellations: Int { lock.withLock { cancelled } }

    /// Returns once `wanted` have arrived; throws if they never do.
    func wait(for wanted: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(60)
        while arrivals < wanted {
            guard clock.now < deadline else { throw LookupError.notReachable }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct FakeProvider: LookupProvider {
    var source: LookupSource
    var search: @Sendable (LookupQuery) async throws -> [LookupCandidate]
    var details: @Sendable (LookupCandidate) async throws -> LookupCandidate = { $0 }

    init(_ source: LookupSource, _ search: @escaping @Sendable (LookupQuery) async throws -> [LookupCandidate]) {
        self.source = source
        self.search = search
    }

    init(_ source: LookupSource, results: [LookupCandidate]) {
        self.init(source) { _ in results }
    }

    func search(_ query: LookupQuery) async throws -> [LookupCandidate] { try await search(query) }
    func details(for candidate: LookupCandidate) async throws -> LookupCandidate { try await details(candidate) }
}

private func found(_ source: LookupSource, _ key: String, _ title: String, authors: [String] = ["Andy Weir"],
                   language: String? = nil, asin: String? = nil, isbn: String? = nil, subtitle: String? = nil) -> LookupCandidate {
    var metadata = BookMetadata(title: title, authors: authors)
    metadata.language = language
    metadata.asin = asin
    metadata.isbn = isbn
    metadata.subtitle = subtitle
    return LookupCandidate(id: "\(source.rawValue):\(key)", source: source, metadata: metadata, coverURL: nil,
                           note: source.title, hasMoreDetails: source == .openLibrary)
}

private let unusedHTTP = FakeHTTP(throwing: LookupError.notReachable)

@Suite struct LookupServiceTests {
    private let query = LookupQuery(title: "Project Hail Mary", author: "Andy Weir")

    // MARK: S1

    @Test func S1_everyProviderIsAskedAtTheSameTime() async throws {
        let gate = Gate()
        // Each waits for the other to have started: asked one after another, neither would finish.
        let open = FakeProvider(.openLibrary) { asked in
            gate.arrive()
            try await gate.wait(for: 2)
            return [found(.openLibrary, "/works/OL1W", asked.title)]
        }
        let audible = FakeProvider(.audible) { asked in
            gate.arrive()
            try await gate.wait(for: 2)
            return [found(.audible, "us:B000000001", asked.title)]
        }
        let results = await LookupService(providers: [open, audible], http: unusedHTTP)
            .search(query, preferAudio: false, language: nil)
        #expect(results.failures.isEmpty)
        #expect(results.candidates.map(\.id) == ["openLibrary:/works/OL1W", "audible:us:B000000001"])
        #expect(results.searched == [.openLibrary, .audible])
        #expect(results.found == [.openLibrary: 1, .audible: 1])
    }

    /// How many each source found is told apart from a source that did not answer.
    @Test func S1_howManyEachSourceFound() async throws {
        let open = FakeProvider(.openLibrary) { _ in [] }
        let audible = FakeProvider(.audible) { asked in
            [found(.audible, "us:B000000001", asked.title), found(.audible, "us:B000000002", asked.title),
             found(.audible, "us:B000000001", asked.title)]
        }
        let results = await LookupService(providers: [open, audible], http: unusedHTTP)
            .search(query, preferAudio: false, language: nil)
        // Counted as kept: a second result with the same id is not one more.
        #expect(results.found == [.openLibrary: 0, .audible: 2])

        let failing = FakeProvider(.openLibrary) { _ in throw LookupError.notReachable }
        let partly = await LookupService(providers: [failing, audible], http: unusedHTTP)
            .search(query, preferAudio: false, language: nil)
        #expect(partly.found == [.audible: 2])
        #expect(partly.failures == [.openLibrary: .notReachable])
    }

    /// N1 (plan 6): only the sources named are asked; nil asks them all.
    @Test func S1_onlyTheNamedSourcesAreAsked() async throws {
        let gate = Gate()
        let open = FakeProvider(.openLibrary) { asked in
            gate.arrive()
            return [found(.openLibrary, "/works/OL1W", asked.title)]
        }
        let audible = FakeProvider(.audible, results: [found(.audible, "us:B000000001", "Project Hail Mary")])
        let service = LookupService(providers: [open, audible], http: unusedHTTP)

        let onlyAudible = await service.search(query, preferAudio: false, language: nil, sources: [.audible])
        #expect(onlyAudible.candidates.map(\.id) == ["audible:us:B000000001"])
        #expect(onlyAudible.searched == [.audible])
        #expect(onlyAudible.found == [.audible: 1])
        #expect(onlyAudible.failures.isEmpty)
        // Open Library was never asked.
        #expect(gate.arrivals == 0)

        let all = await service.search(query, preferAudio: false, language: nil, sources: nil)
        #expect(all.searched == [.openLibrary, .audible])
        #expect(all.candidates.count == 2)
        #expect(gate.arrivals == 1)
        let both = await service.search(query, preferAudio: false, language: nil, sources: [.audible, .openLibrary])
        #expect(both == all)

        // No source named: nobody is asked.
        let none = await service.search(query, preferAudio: false, language: nil, sources: [])
        #expect(none.candidates.isEmpty)
        #expect(none.searched.isEmpty)
        #expect(gate.arrivals == 2)
    }

    @Test func S1_oneFailingProviderDoesNotLoseTheOthers() async throws {
        let failing = FakeProvider(.audible) { _ in throw LookupError.notReachable }
        let working = FakeProvider(.openLibrary, results: [found(.openLibrary, "/works/OL1W", "Project Hail Mary")])
        let results = await LookupService(providers: [failing, working], http: unusedHTTP)
            .search(query, preferAudio: true, language: "en")
        #expect(results.candidates.map(\.id) == ["openLibrary:/works/OL1W"])
        #expect(results.failures == [.audible: .notReachable])
        #expect(results.searched == [.audible, .openLibrary])
    }

    @Test func S1_everyKindOfFailureIsReportedPerSource() async throws {
        struct Odd: Error {}
        let refused = FakeProvider(.openLibrary) { _ in throw LookupError.refused(status: 503) }
        let odd = FakeProvider(.audible) { _ in throw Odd() }
        let results = await LookupService(providers: [refused, odd], http: unusedHTTP)
            .search(query, preferAudio: true, language: nil)
        #expect(results.candidates.isEmpty)
        #expect(results.failures == [.openLibrary: .refused(status: 503), .audible: .unreadable])
        #expect(results.searched == [.openLibrary, .audible])
    }

    @Test func S1_aSlowProviderIsWaitedFor() async throws {
        let slow = FakeProvider(.audible) { _ in
            try await Task.sleep(for: .milliseconds(150))
            return [found(.audible, "us:B000000001", "Project Hail Mary")]
        }
        let quick = FakeProvider(.openLibrary, results: [found(.openLibrary, "/works/OL1W", "Project Hail Mary")])
        let results = await LookupService(providers: [slow, quick], http: unusedHTTP)
            .search(query, preferAudio: false, language: nil)
        #expect(Set(results.candidates.map(\.id)) == ["openLibrary:/works/OL1W", "audible:us:B000000001"])
        #expect(results.failures.isEmpty)
    }

    @Test func S1_withRealProvidersOverFakeHTTP() async throws {
        // Open Library answers; Audible's host cannot be reached.
        let http = FakeHTTP { url in
            guard url.host == "openlibrary.org" else { throw LookupError.notReachable }
            return (fixture("ol-search"), 200)
        }
        let service = LookupService(providers: [OpenLibraryProvider(http: http), AudibleProvider(http: http, store: .uk)], http: http)
        let results = await service.search(query, preferAudio: true, language: "en")
        #expect(results.candidates.map(\.id) == ["openLibrary:/works/OL21745884W", "openLibrary:/works/OL36735881W"])
        #expect(results.failures == [.audible: .notReachable])
        #expect(Set(http.urls.compactMap { $0.host }) == ["openlibrary.org", "api.audible.co.uk"])
    }

    // MARK: S2

    @Test func S2_bestMatchFirst() async throws {
        let open = FakeProvider(.openLibrary, results: [
            found(.openLibrary, "/works/OL3W", "Exoplanet", authors: ["Someone Else"]),
            found(.openLibrary, "/works/OL2W", "The Martian / Artemis / Project Hail Mary"),
            found(.openLibrary, "/works/OL4W", "Project Hail Mary", authors: ["Someone Else"]),
            found(.openLibrary, "/works/OL1W", "Project Hail Mary"),
        ])
        let results = await LookupService(providers: [open], http: unusedHTTP).search(query, preferAudio: false, language: nil)
        #expect(results.candidates.map(\.id) == ["openLibrary:/works/OL1W", "openLibrary:/works/OL4W", "openLibrary:/works/OL2W", "openLibrary:/works/OL3W"])
    }

    @Test func S2_nearEqualScoresFollowThePreferredKind() async throws {
        let open = FakeProvider(.openLibrary, results: [
            found(.openLibrary, "/works/OL1W", "Project Hail Mary"),
            found(.openLibrary, "/works/OL2W", "Unrelated Thing", authors: ["Nobody"]),
        ])
        let audible = FakeProvider(.audible, results: [
            found(.audible, "us:B000000001", "Project Hail Mary"),
            found(.audible, "us:B000000002", "Project Hail Mary", authors: ["Wrong Person"]),
        ])
        let service = LookupService(providers: [open, audible], http: unusedHTTP)
        let audio = await service.search(query, preferAudio: true, language: nil)
        #expect(audio.candidates.map(\.id) == ["audible:us:B000000001", "openLibrary:/works/OL1W", "audible:us:B000000002", "openLibrary:/works/OL2W"])
        let text = await service.search(query, preferAudio: false, language: nil)
        #expect(text.candidates.map(\.id) == ["openLibrary:/works/OL1W", "audible:us:B000000001", "audible:us:B000000002", "openLibrary:/works/OL2W"])
        // The preference never lifts a clearly worse match over a better one.
        #expect(audio.candidates.firstIndex { $0.id == "audible:us:B000000002" }! > audio.candidates.firstIndex { $0.id == "openLibrary:/works/OL1W" }!)
    }

    @Test func S2_anotherLanguageGoesAfterNearEqualMatches() async throws {
        let audible = FakeProvider(.audible, results: [
            found(.audible, "us:IT", "Project Hail Mary", language: "it"),
            found(.audible, "us:UNKNOWN", "Project Hail Mary"),
            found(.audible, "us:EN", "Project Hail Mary", language: "en"),
            found(.audible, "us:EN2", "Project Hail Mary", language: "en"),
        ])
        let open = FakeProvider(.openLibrary, results: [found(.openLibrary, "/works/OL1W", "Project Hail Mary")])
        let service = LookupService(providers: [audible, open], http: unusedHTTP)

        let english = await service.search(query, preferAudio: true, language: "en")
        // Unknown is not "another language"; ties keep the provider's order.
        #expect(english.candidates.map(\.id) == ["audible:us:UNKNOWN", "audible:us:EN", "audible:us:EN2", "audible:us:IT", "openLibrary:/works/OL1W"])
        let italian = await service.search(query, preferAudio: true, language: "IT")
        #expect(italian.candidates.map(\.id) == ["audible:us:IT", "audible:us:UNKNOWN", "audible:us:EN", "audible:us:EN2", "openLibrary:/works/OL1W"])
        // No preference: exactly the provider's order.
        let none = await service.search(query, preferAudio: true, language: nil)
        #expect(none.candidates.map(\.id) == ["audible:us:IT", "audible:us:UNKNOWN", "audible:us:EN", "audible:us:EN2", "openLibrary:/works/OL1W"])
        // Reading: the other kind first, the language rule still holding within Audible's.
        let reading = await service.search(query, preferAudio: false, language: "en")
        #expect(reading.candidates.map(\.id) == ["openLibrary:/works/OL1W", "audible:us:UNKNOWN", "audible:us:EN", "audible:us:EN2", "audible:us:IT"])
    }

    @Test func S2_languageNeverLiftsAWorseMatch() async throws {
        let audible = FakeProvider(.audible, results: [
            found(.audible, "us:EN", "Project Hail Mary: The Graphic Novel", language: "en"),
            found(.audible, "us:IT", "Project Hail Mary", language: "it"),
        ])
        let results = await LookupService(providers: [audible], http: unusedHTTP).search(query, preferAudio: true, language: "en")
        #expect(results.candidates.map(\.id) == ["audible:us:IT", "audible:us:EN"])
    }

    @Test func S2_theQuerysOwnASINOrISBNIsAlwaysFirst() async throws {
        let open = FakeProvider(.openLibrary, results: [
            found(.openLibrary, "/works/OL1W", "Project Hail Mary"),
            found(.openLibrary, "/works/OL9W", "Different Title Entirely", authors: ["Nobody"], isbn: "9780593135204"),
        ])
        let audible = FakeProvider(.audible, results: [
            found(.audible, "us:B000000001", "Project Hail Mary", language: "en"),
            found(.audible, "us:B08G9PRS1K", "Proyecto Hail Mary", authors: ["Otro"], language: "es", asin: "B08G9PRS1K"),
        ])
        let service = LookupService(providers: [open, audible], http: unusedHTTP)
        var asked = query
        asked.asin = " b08g9prs1k "
        let byASIN = await service.search(asked, preferAudio: false, language: "en")
        #expect(byASIN.candidates.map(\.id) == ["audible:us:B08G9PRS1K", "openLibrary:/works/OL1W", "audible:us:B000000001", "openLibrary:/works/OL9W"])
        asked.asin = nil
        asked.isbn = "978-0-593-13520-4"
        let byISBN = await service.search(asked, preferAudio: true, language: "en")
        #expect(byISBN.candidates.first?.id == "openLibrary:/works/OL9W")
        #expect(byISBN.candidates.map(\.id).dropFirst() == ["audible:us:B000000001", "openLibrary:/works/OL1W", "audible:us:B08G9PRS1K"])
    }

    @Test func S2_withTheRealAnswers() async throws {
        let http = FakeHTTP { url in
            (url.host == "openlibrary.org" ? fixture("ol-search") : fixture("au-search"), 200)
        }
        let service = LookupService(providers: [OpenLibraryProvider(http: http), AudibleProvider(http: http, store: .us)], http: http)
        let results = await service.search(query, preferAudio: true, language: "en")
        // English audiobook, its Italian edition, the book, then the box set.
        #expect(results.candidates.map(\.id) == [
            "audible:us:B08G9PRS1K", "audible:us:B0CTZVXP8H", "openLibrary:/works/OL21745884W", "openLibrary:/works/OL36735881W",
        ])
        #expect(results.failures.isEmpty)
        #expect(results.searched == [.openLibrary, .audible])
    }

    // MARK: S3, S4

    @Test func S3_nearDuplicatesKeptExactDuplicatesDropped() async throws {
        let first = found(.openLibrary, "/works/OL1W", "Project Hail Mary")
        var again = first
        again.note = "the same id a second time"
        let open = FakeProvider(.openLibrary, results: [first, again])
        let audible = FakeProvider(.audible, results: [found(.audible, "us:B000000001", "Project Hail Mary"), found(.audible, "us:B000000001", "Project Hail Mary")])
        let results = await LookupService(providers: [open, audible], http: unusedHTTP).search(query, preferAudio: false, language: nil)
        #expect(results.candidates.map(\.id) == ["openLibrary:/works/OL1W", "audible:us:B000000001"])
        #expect(results.candidates.first == first)
    }

    @Test func S4_anEmptyQueryAsksNoProvider() async throws {
        let gate = Gate()
        let provider = FakeProvider(.openLibrary) { _ in
            gate.arrive()
            return [found(.openLibrary, "/works/OL1W", "Anything")]
        }
        let http = FakeHTTP(data: Data())
        let service = LookupService(providers: [provider, OpenLibraryProvider(http: http), AudibleProvider(http: http, store: .us)], http: http)
        let results = await service.search(LookupQuery(title: "  ", author: "", isbn: " ", asin: nil), preferAudio: true, language: "en")
        #expect(results == LookupResults(candidates: [], failures: [:], searched: []))
        #expect(gate.arrivals == 0)
        #expect(http.requests.isEmpty)
    }

    // MARK: S5

    @Test func S5_detailsGoToTheCandidatesProvider() async throws {
        var open = FakeProvider(.openLibrary, results: [])
        open.details = { candidate in
            var detailed = candidate
            detailed.metadata.summary = "From Open Library."
            detailed.hasMoreDetails = false
            return detailed
        }
        var audible = FakeProvider(.audible, results: [])
        audible.details = { _ in throw LookupError.refused(status: 500) }
        let service = LookupService(providers: [audible, open], http: unusedHTTP)

        let detailed = try await service.details(for: found(.openLibrary, "/works/OL1W", "Project Hail Mary"))
        #expect(detailed.metadata.summary == "From Open Library.")
        #expect(!detailed.hasMoreDetails)
        // A provider's error is the caller's to handle.
        await #expect(throws: LookupError.refused(status: 500)) {
            _ = try await service.details(for: found(.audible, "us:B000000001", "Project Hail Mary"))
        }
    }

    @Test func S5_noProviderForTheSourceLeavesTheCandidateUnchanged() async throws {
        let service = LookupService(providers: [FakeProvider(.audible, results: [])], http: unusedHTTP)
        let candidate = found(.openLibrary, "/works/OL1W", "Project Hail Mary")
        #expect(try await service.details(for: candidate) == candidate)
        #expect(try await LookupService(providers: [], http: unusedHTTP).details(for: candidate) == candidate)
    }

    // MARK: S6

    private static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00])

    /// The source of the candidates whose covers are asked for: a service fetches
    /// nothing for a source it does not ask.
    private static let audible: [any LookupProvider] = [FakeProvider(.audible, results: [])]

    /// A source that is off has no provider: its results' covers, pictures and details
    /// are not fetched, and nothing is asked.
    @Test func S6_nothingIsFetchedForASourceThatIsNotAsked() async throws {
        let http = FakeHTTP(data: Self.jpeg)
        var candidate = withCover("https://m.media-amazon.com/images/I/x.jpg")
        candidate.thumbnailURL = URL(string: "https://m.media-amazon.com/images/I/x._SL500_.jpg")
        candidate.hasMoreDetails = true
        for configuration in [
            LookupConfiguration(sources: [.openLibrary, .libraryOfCongress], audibleStores: [.uk]),
            LookupConfiguration(sources: [], audibleStores: [.uk]),
            // Audible with no store to ask is off.
            LookupConfiguration(sources: [.audible], audibleStores: []),
        ] {
            let service = LookupService.standard(configuration, http: http)
            await #expect(throws: LookupError.unreadable) { _ = try await service.cover(for: candidate) }
            await #expect(throws: LookupError.unreadable) { _ = try await service.thumbnail(for: candidate) }
            #expect(try await service.details(for: candidate) == candidate)
        }
        #expect(http.requests.isEmpty)
        // On, it is fetched.
        let on = LookupService.standard(LookupConfiguration(sources: [.audible], audibleStores: [.uk]), http: http)
        #expect(try await on.cover(for: candidate) == CoverImage(data: Self.jpeg, mime: "image/jpeg"))
        #expect(http.urls.map(\.absoluteString) == ["https://m.media-amazon.com/images/I/x.jpg"])
        #expect(http.limits.allSatisfy { $0.insecure.isEmpty })
    }

    private func withCover(_ url: String?) -> LookupCandidate {
        var candidate = found(.audible, "us:B000000001", "Project Hail Mary")
        candidate.coverURL = url.flatMap(URL.init(string:))
        return candidate
    }

    @Test(arguments: [
        "https://covers.openlibrary.org/b/id/11200092-L.jpg",
        "https://m.media-amazon.com/images/I/81Nzlrfud+L._SL1024_.jpg",
        "https://images-na.ssl-images-amazon.com/images/I/51POf8gOyLL.jpg",
        "HTTPS://M.MEDIA-AMAZON.COM/images/I/x.jpg",
    ])
    func S6_downloadsACoverFromAKnownHost(address: String) async throws {
        let http = FakeHTTP(data: Self.jpeg)
        let cover = try await LookupService(providers: Self.audible, http: http).cover(for: withCover(address))
        #expect(cover == CoverImage(data: Self.jpeg, mime: "image/jpeg"))
        #expect(http.requests.count == 1)
        #expect(http.urls.first == URL(string: address))
        #expect(http.requests.first?.headers == ["User-Agent": "VoxCarrel/0.1 (https://voxcarrel.com)"])
    }

    /// A cover may be 10 MB at most, and may redirect only among the cover hosts and the Internet Archive.
    @Test func S6_coverRequestsAreLimited() async throws {
        let http = FakeHTTP(data: Self.jpeg)
        _ = try await LookupService(providers: Self.audible, http: http).cover(for: withCover("https://covers.openlibrary.org/b/id/1-L.jpg"))
        #expect(http.limits == [FakeHTTP.Limits(
            maxBytes: 10 * 1024 * 1024,
            redirectHosts: ["covers.openlibrary.org", "m.media-amazon.com", "images-na.ssl-images-amazon.com", "archive.org"])])
    }

    /// The row's picture: the smaller address when there is one, under the same rules as the cover.
    @Test func S6_theThumbnailIsFetchedFromItsOwnAddress() async throws {
        let http = FakeHTTP(data: Self.jpeg)
        let service = LookupService(providers: Self.audible, http: http)
        var candidate = withCover("https://covers.openlibrary.org/b/id/1-L.jpg")
        candidate.thumbnailURL = URL(string: "https://covers.openlibrary.org/b/id/1-M.jpg")
        #expect(try await service.thumbnail(for: candidate) == CoverImage(data: Self.jpeg, mime: "image/jpeg"))
        #expect(http.urls == [URL(string: "https://covers.openlibrary.org/b/id/1-M.jpg")])
        #expect(http.limits.first?.maxBytes == 10 * 1024 * 1024)
        #expect(http.limits.first?.redirectHosts.contains("archive.org") == true)

        // Without a smaller one, the cover itself.
        candidate.thumbnailURL = nil
        _ = try await service.thumbnail(for: candidate)
        #expect(http.urls.last == URL(string: "https://covers.openlibrary.org/b/id/1-L.jpg"))

        // Not from anywhere else, and not when it is no picture.
        candidate.thumbnailURL = URL(string: "https://evil.test/1-M.jpg")
        await #expect(throws: LookupError.unreadable) { _ = try await service.thumbnail(for: candidate) }
        #expect(http.urls.count == 2)
        candidate.thumbnailURL = URL(string: "https://covers.openlibrary.org/b/id/1-M.jpg")
        await #expect(throws: LookupError.unreadable) {
            _ = try await LookupService(providers: Self.audible, http: FakeHTTP(data: Data("<html>".utf8))).thumbnail(for: candidate)
        }
    }

    @Test func S6_pngIsAcceptedAndTypedByItsBytes() async throws {
        let cover = try await LookupService(providers: Self.audible, http: FakeHTTP(data: Self.png))
            .cover(for: withCover("https://covers.openlibrary.org/b/id/1-L.jpg"))
        #expect(cover.mime == "image/png")
        #expect(cover.data == Self.png)
    }

    @Test(arguments: [
        "http://m.media-amazon.com/images/I/x.jpg",                     // not https
        "https://example.com/cover.jpg",                                // another host
        "https://m.media-amazon.com.evil.example/x.jpg",                // looks like one
        "https://evil.example/m.media-amazon.com/x.jpg",
        "https://m.media-amazon.com@evil.example/x.jpg",                // the real host is evil.example
        "https://user:secret@m.media-amazon.com/x.jpg",                 // carries a login
        "https://m.media-amazon.com:8443/x.jpg",                        // another port
        "https://openlibrary.org/b/id/1-L.jpg",                         // not the covers host
        "https://api.audible.com/x.jpg",
        "file:///etc/hosts",
        "ftp://covers.openlibrary.org/b/id/1-L.jpg",
        "//covers.openlibrary.org/b/id/1-L.jpg",
    ])
    func S6_anyOtherAddressIsRefusedWithoutARequest(address: String) async throws {
        let http = FakeHTTP(data: Self.jpeg)
        let service = LookupService(providers: Self.audible, http: http)
        let candidate = withCover(address)
        try #require(candidate.coverURL != nil)
        await #expect(throws: LookupError.unreadable) {
            _ = try await service.cover(for: candidate)
        }
        #expect(http.requests.isEmpty)
    }

    @Test func S6_noCoverURLIsUnreadable() async throws {
        let http = FakeHTTP(data: Self.jpeg)
        await #expect(throws: LookupError.unreadable) {
            _ = try await LookupService(providers: Self.audible, http: http).cover(for: withCover(nil))
        }
        #expect(http.requests.isEmpty)
    }

    @Test func S6_whatIsNotAJPEGOrPNGIsRefused() async throws {
        let gif = try #require(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
        #expect(CoverImage.sniffedMIME(gif) == "image/gif")
        for body in [gif, Data("<html>Not found</html>".utf8), Data(), Data([0xFF, 0xD8]), Data("%PDF-1.7".utf8)] {
            await #expect(throws: LookupError.unreadable) {
                _ = try await LookupService(providers: Self.audible, http: FakeHTTP(data: body))
                    .cover(for: withCover("https://covers.openlibrary.org/b/id/1-L.jpg"))
            }
        }
    }

    @Test func S6_tenMegabytesIsTheLimit() async throws {
        let limit = 10 * 1024 * 1024
        let atLimit = Self.jpeg + Data(count: limit - Self.jpeg.count)
        let candidate = withCover("https://m.media-amazon.com/images/I/x.jpg")
        let cover = try await LookupService(providers: Self.audible, http: FakeHTTP(data: atLimit)).cover(for: candidate)
        #expect(cover.data.count == limit)
        await #expect(throws: LookupError.unreadable) {
            _ = try await LookupService(providers: Self.audible, http: FakeHTTP(data: atLimit + Data([0]))).cover(for: candidate)
        }
    }

    @Test func S6_downloadFailures() async throws {
        let candidate = withCover("https://m.media-amazon.com/images/I/x.jpg")
        await #expect(throws: LookupError.refused(status: 404)) {
            _ = try await LookupService(providers: Self.audible, http: FakeHTTP(data: Self.jpeg, status: 404)).cover(for: candidate)
        }
        await #expect(throws: LookupError.notReachable) {
            _ = try await LookupService(providers: Self.audible, http: FakeHTTP(throwing: LookupError.notReachable)).cover(for: candidate)
        }
    }

    // MARK: S7

    @Test func S7_cancellingTheCallerCancelsTheRequests() async throws {
        let gate = Gate()
        let slow: @Sendable (LookupQuery) async throws -> [LookupCandidate] = { _ in
            gate.arrive()
            do {
                try await Task.sleep(for: .seconds(600))
            } catch {
                gate.noteCancelled()
                throw error
            }
            return [found(.audible, "us:B000000001", "Too late")]
        }
        let service = LookupService(providers: [FakeProvider(.openLibrary, slow), FakeProvider(.audible, slow)], http: unusedHTTP)
        let query = query
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task { await service.search(query, preferAudio: true, language: nil) }
        try await gate.wait(for: 2)
        task.cancel()
        let results = await task.value
        #expect(clock.now - started < .seconds(120))
        #expect(gate.cancellations == 2)
        #expect(results.candidates.isEmpty)
        // A cancelled search is not a source that failed.
        #expect(results.failures.isEmpty)
        #expect(results.searched == [.openLibrary, .audible])
    }

    @Test func S7_aSearchStartedAlreadyCancelledAsksNothing() async throws {
        let gate = Gate()
        let provider = FakeProvider(.openLibrary) { _ in
            gate.arrive()
            return [found(.openLibrary, "/works/OL1W", "Project Hail Mary")]
        }
        let service = LookupService(providers: [provider], http: unusedHTTP)
        let query = query
        let task = Task { () -> LookupResults in
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.search(query, preferAudio: true, language: nil)
        }
        let results = await task.value
        #expect(gate.arrivals == 0)
        #expect(results.candidates.isEmpty)
        #expect(results.failures.isEmpty)
    }

    @Test func S7_cancellationReachesDetailsAndCover() async throws {
        let cancelled = FakeHTTP { _ in throw CancellationError() }
        let service = LookupService(providers: [OpenLibraryProvider(http: cancelled)] + Self.audible, http: cancelled)
        await #expect(throws: CancellationError.self) {
            _ = try await service.details(for: found(.openLibrary, "/works/OL1W", "Project Hail Mary"))
        }
        await #expect(throws: CancellationError.self) {
            _ = try await service.cover(for: withCover("https://m.media-amazon.com/images/I/x.jpg"))
        }
    }
}
