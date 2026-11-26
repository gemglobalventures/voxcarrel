import Foundation
import Testing
@testable import VoxCarrelCore

@Suite struct OpenLibraryEditionsTests {
    private static let query = LookupQuery(title: "A Perfect Spy", author: "John le Carré", wantsAudioEditions: true)

    /// The trial's answers: the search for the work, and the work's 23 editions.
    private static func trial() -> FakeHTTP {
        FakeHTTP { url in
            (fixture(url.path.hasSuffix("/editions.json") ? "ol-editions" : "ol-editions-search"), 200)
        }
    }

    /// A search that finds `works`, and `entries` as the editions of whichever is asked about.
    private static func http(works: String = #"{"key": "/works/OL1W", "title": "The Book", "author_name": ["Ann Author"]}"#,
                             entries: [String]) -> FakeHTTP {
        FakeHTTP { url in
            if url.path.hasSuffix("/editions.json") {
                return (Data(#"{"links": {}, "size": \#(entries.count), "entries": [\#(entries.joined(separator: ","))]}"#.utf8), 200)
            }
            return (Data(#"{"docs": [\#(works)]}"#.utf8), 200)
        }
    }

    private static func editions(_ entries: [String]) async throws -> [LookupCandidate] {
        let found = try await OpenLibraryProvider(http: http(entries: entries))
            .search(LookupQuery(title: "The Book", wantsAudioEditions: true))
        return found.filter { $0.id.hasPrefix("openLibrary:/books/") }
    }

    // MARK: D1

    @Test func D1_theEditionsOfTheBestWorkAreAskedFor() async throws {
        let http = Self.trial()
        let found = try await OpenLibraryProvider(http: http).search(Self.query)
        #expect(http.urls.count == 2)
        let search = try #require(http.urls.first), editions = try #require(http.urls.last)
        #expect(search.path == "/search.json")
        #expect(editions.absoluteString == "https://openlibrary.org/works/OL15723132W/editions.json?limit=100")
        #expect(queryItems(editions) == ["limit": "100"])
        // The same User-Agent and limits as the provider's other requests.
        let headers = ["User-Agent": "VoxCarrel/0.1 (https://voxcarrel.com)", "Accept": "application/json"]
        #expect(http.requests.map(\.headers) == [headers, headers])
        let limits = FakeHTTP.Limits(maxBytes: 5 * 1024 * 1024, redirectHosts: ["openlibrary.org"])
        #expect(http.limits == [limits, limits])
        // The works as before, then the audio editions.
        #expect(found.map(\.id) == [
            "openLibrary:/works/OL15723132W", "openLibrary:/works/OL17904551W", "openLibrary:/works/OL19893940W",
            "openLibrary:/books/OL10823902M", "openLibrary:/books/OL8624863M", "openLibrary:/books/OL11259119M",
            "openLibrary:/books/OL10635194M", "openLibrary:/books/OL12578085M",
        ])
    }

    @Test func D1_onlyWhenTheBookHasAudio() async throws {
        let http = Self.trial()
        var plain = Self.query
        plain.wantsAudioEditions = false
        let found = try await OpenLibraryProvider(http: http).search(plain)
        #expect(http.urls.count == 1)
        #expect(found.map(\.id) == ["openLibrary:/works/OL15723132W", "openLibrary:/works/OL17904551W", "openLibrary:/works/OL19893940W"])
        // The works themselves are the same either way.
        let withEditions = try await OpenLibraryProvider(http: Self.trial()).search(Self.query)
        #expect(Array(withEditions.prefix(3)) == found)
    }

    @Test func D1_theBestMatchingWorkNotTheFirst() async throws {
        let works = """
        {"key": "/works/OL1W", "title": "The Book of Others", "author_name": ["Ann Author"]},
        {"key": "/works/OL2W", "title": "Another Thing", "author_name": ["Ann Author"]},
        {"key": "/works/OL3W", "title": "The Book", "author_name": ["Someone Else"]},
        {"key": "/works/OL4W", "title": "the book", "author_name": ["Author, Ann"]},
        {"key": "/works/OL5W", "title": "The Book", "author_name": ["Ann Author"]}
        """
        let http = Self.http(works: works, entries: [])
        _ = try await OpenLibraryProvider(http: http)
            .search(LookupQuery(title: "The Book", author: "Ann Author", wantsAudioEditions: true))
        // One work only: the best by match score, and among equals the first.
        #expect(http.urls.count == 2)
        #expect(http.urls.last?.absoluteString == "https://openlibrary.org/works/OL4W/editions.json?limit=100")
    }

    @Test func D1_noWorksNoEditionsRequest() async throws {
        let http = FakeHTTP(data: fixture("ol-none"))
        #expect(try await OpenLibraryProvider(http: http).search(Self.query).isEmpty)
        #expect(http.urls.count == 1)
    }

    @Test func D1_afterAnISBNSearchToo() async throws {
        let http = Self.trial()
        var asked = Self.query
        asked.isbn = "9780754005568"
        let found = try await OpenLibraryProvider(http: http).search(asked)
        #expect(http.urls.count == 2)
        #expect(queryItems(http.urls[0])["isbn"] == "9780754005568")
        #expect(http.urls[1].path == "/works/OL15723132W/editions.json")
        #expect(found.count == 8)
    }

    // MARK: D2 to D4 on the trial's answer

    /// Twenty-three editions, five of them cassettes. The large-print paperback from the
    /// publisher of one of the cassettes is not among them.
    @Test func D2_D3_D4_theFiveCassetteEditions() async throws {
        let found = try await OpenLibraryProvider(http: Self.trial()).search(Self.query)
        let editions = Array(found.dropFirst(3))
        #expect(editions.count == 5)
        #expect(!found.contains { $0.id == "openLibrary:/books/OL11668673M" })
        #expect(editions.allSatisfy { $0.source == .openLibrary && !$0.hasMoreDetails })
        #expect(editions.allSatisfy { $0.edition.format == .cassette && $0.edition.stores.isEmpty })
        // D3: the authors are the work's; nobody is named as reading it and no length is given.
        #expect(editions.allSatisfy { $0.metadata.authors == ["John le Carré"] })
        #expect(editions.allSatisfy { $0.metadata.narrators.isEmpty && $0.metadata.durationSeconds == nil && $0.metadata.summary == nil })

        #expect(editions.map(\.metadata.title) == [
            "A Perfect Spy", "A Perfect Spy", "A Perfect Spy", "A Perfect Spy (BBC Radio Collection)", "Perfect Spy",
        ])
        #expect(editions.map(\.metadata.publisher) == [
            "Chivers Press Ltd", "Hodder & Stoughton Audio Books", "Dh Audio", "BBC Audiobooks", "Books On Tape",
        ])
        // D6: most recent first, the undated one last.
        let years: [Int?] = [2000, 1996, 1992, 1988, nil]
        #expect(editions.map(\.metadata.year) == years)
        // The 13-digit ISBN where there are both.
        #expect(editions.map(\.metadata.isbn) == ["9780754005568", "9781859986929", "9780886463403", "9780563225782", "9785553670870"])
        // D4
        #expect(editions.map(\.note) == [
            "Open Library · Cassette · Chivers Press Ltd · 2000",
            "Open Library · Cassette · Hodder & Stoughton Audio Books · 1996",
            "Open Library · Cassette · Dh Audio · 1992",
            "Open Library · Cassette · BBC Audiobooks · 1988",
            "Open Library · Cassette · Books On Tape",
        ])
        #expect(editions.map(\.edition.publisher) == editions.map(\.metadata.publisher))
        #expect(editions.map(\.edition.year) == years)
        let abridged: [Bool?] = [nil, nil, nil, true, nil]
        #expect(editions.map(\.edition.abridged) == abridged)
        // The one with a cover of its own.
        let covers: [URL?] = [nil, URL(string: "https://covers.openlibrary.org/b/id/2063020-L.jpg"), nil, nil, nil]
        #expect(editions.map(\.coverURL) == covers)
        #expect(editions[1].thumbnailURL == URL(string: "https://covers.openlibrary.org/b/id/2063020-M.jpg"))

        var expected = BookMetadata(title: "A Perfect Spy", authors: ["John le Carré"])
        expected.publisher = "Chivers Press Ltd"
        expected.year = 2000
        expected.isbn = "9780754005568"
        #expect(editions[0].metadata == expected)
    }

    // MARK: D2

    @Test(arguments: [
        ("Audio Cassette", EditionFormat.cassette), ("Audio cassette", .cassette), ("CASSETTE", .cassette),
        ("Audio CD", .cd), ("CD", .cd), ("cd-audio", .cd), ("Compact Disc Audio", .cd),
        ("MP3 CD", .mp3CD), ("mp3", .mp3CD),
        ("Audiobook", .other), ("Audio", .other), ("Sound recording", .other), ("Preloaded Digital Audio Player", .other),
        ("Audible Audio", .digital), ("Audio Download", .digital), ("eAudiobook", .other),
    ])
    func D2_anAudioFormatIsOffered(format: String, expected: EditionFormat) async throws {
        let found = try await Self.editions([#"{"key": "/books/OL1M", "title": "The Book", "physical_format": "\#(format)"}"#])
        #expect(found.count == 1)
        #expect(found.first?.edition.format == expected)
    }

    @Test(arguments: [
        "Paperback", "Hardcover", "Mass Market Paperback", "Library Binding", "Board book", "Ebook", "", "  ",
        // "cd" inside another word.
        "Abcd binding",
    ])
    func D2_aPrintFormatIsNotOffered(format: String) async throws {
        let entry = #"{"key": "/books/OL1M", "title": "The Book", "physical_format": "\#(format)", "publishers": ["Knopf"]}"#
        #expect(try await Self.editions([entry]).isEmpty)
    }

    /// With no format given, the publisher can show an edition is audio. A format that
    /// says print is believed before the publisher's name.
    @Test func D2_thePublisherShowsAnEditionIsAudio() async throws {
        for publisher in ["Random House Audio", "Books on Cassette Inc", "HarperAudio", "Sound Library", "Brilliance MP3", "Naxos CD"] {
            let found = try await Self.editions([#"{"key": "/books/OL1M", "title": "The Book", "publishers": ["Knopf", "\#(publisher)"]}"#])
            #expect(found.count == 1, "\(publisher)")
            // What it is recorded on is not known.
            #expect(found.first?.edition.format == nil)
            #expect(found.first?.note == "Open Library · Audio · Knopf")
        }
        for entry in [
            #"{"key": "/books/OL1M", "title": "The Book", "publishers": ["Knopf", "BOC", "Macdonald"]}"#,
            #"{"key": "/books/OL1M", "title": "The Book"}"#,
            #"{"key": "/books/OL1M", "title": "The Book", "physical_format": "Paperback", "publishers": ["HarperAudio"]}"#,
            #"{"key": "/books/OL1M", "title": "The Book", "physical_format": 7, "publishers": "Audio"}"#,
        ] {
            #expect(try await Self.editions([entry]).isEmpty)
        }
    }

    // MARK: D3

    @Test(arguments: [
        ("October 2000", 2000), ("September 12, 1988", 1988), ("1987", 1987), ("2000-10-01", 2000), ("c1994.", 1994),
        ("12/06/1996", 1996), ("June 96", nil), ("19877", nil), ("", nil), ("0000", nil), ("n.d.", nil),
    ] as [(String, Int?)])
    func D3_theYearIsFourDigitsAnywhereInTheDate(date: String, year: Int?) async throws {
        let entry = #"{"key": "/books/OL1M", "title": "The Book", "physical_format": "Audio CD", "publish_date": "\#(date)"}"#
        let found = try await Self.editions([entry])
        #expect(found.count == 1)
        #expect(found.first?.metadata.year == year)
        #expect(found.first?.edition.year == year)
    }

    @Test func D3_mappingOddities() async throws {
        let entries = [
            // Only a 10-digit ISBN; two publishers; covers, the first unusable; a subtitle; a language.
            #"""
            {"key": "/books/OL1M", "title": " The‮ Book ", "subtitle": "A Tale", "physical_format": "Audio CD",
             "publishers": ["First House", "Second House"], "isbn_10": ["bad", "034038784x"], "covers": [-1, 77, 78],
             "languages": [{"key": "/languages/ger"}], "edition_name": "Unabridged edition", "publish_date": "2001"}
            """#,
            // No title of its own: the work's.
            #"{"key": "/books/OL2M", "physical_format": "Audio CD", "isbn_13": ["9780754005568"], "isbn_10": ["0754005569"], "edition_name": "Abridged"}"#,
            // Nothing but what makes it an edition.
            #"{"key": "/books/OL3M", "title": "Third", "physical_format": "MP3 CD", "publishers": [], "covers": [], "isbn_13": "x", "languages": [{"key": "/languages/eng"}, {"key": "/languages/fre"}]}"#,
        ]
        let found = try await Self.editions(entries)
        // The dated one first.
        #expect(found.map(\.id) == ["openLibrary:/books/OL1M", "openLibrary:/books/OL2M", "openLibrary:/books/OL3M"])
        guard found.count == 3 else { return }

        var first = BookMetadata(title: "The Book", authors: ["Ann Author"])
        first.subtitle = "A Tale"
        first.publisher = "First House"
        first.year = 2001
        first.isbn = "034038784X"
        first.language = "de"
        #expect(found[0].metadata == first)
        #expect(found[0].edition == EditionFacts(format: .cd, abridged: false, publisher: "First House", year: 2001))
        #expect(found[0].coverURL == URL(string: "https://covers.openlibrary.org/b/id/77-L.jpg"))
        #expect(found[0].thumbnailURL == URL(string: "https://covers.openlibrary.org/b/id/77-M.jpg"))
        #expect(found[0].note == "Open Library · CD · First House · 2001")

        var second = BookMetadata(title: "The Book", authors: ["Ann Author"])
        second.isbn = "9780754005568"
        #expect(found[1].metadata == second)
        #expect(found[1].edition == EditionFacts(format: .cd, abridged: true))
        #expect(found[1].note == "Open Library · CD")

        // Two languages are a jumble: left empty.
        #expect(found[2].metadata == BookMetadata(title: "Third", authors: ["Ann Author"]))
        #expect(found[2].edition == EditionFacts(format: .mp3CD))
        #expect(found[2].coverURL == nil)
        #expect(found[2].note == "Open Library · MP3 CD")
    }

    @Test func D3_aMalformedEditionIsSkipped() async throws {
        let found = try await Self.editions([
            #"{"title": "No key", "physical_format": "Audio CD"}"#,
            #"{"key": "/books/../x", "title": "Bad key", "physical_format": "Audio CD"}"#,
            #"{"key": "/works/OL9W", "title": "Not an edition", "physical_format": "Audio CD"}"#,
            #"{"key": 7, "title": "Bad key", "physical_format": "Audio CD"}"#,
            #""a string""#, "7", "null", "[]",
            #"{"key": "/books/OL1M", "title": "Good", "physical_format": "Audio CD"}"#,
        ])
        #expect(found.map(\.id) == ["openLibrary:/books/OL1M"])
    }

    // MARK: D4

    @Test func D4_detailsOfAnEditionAskNothing() async throws {
        let http = Self.trial()
        let provider = OpenLibraryProvider(http: http)
        let found = try await provider.search(Self.query)
        let edition = try #require(found.first { $0.id == "openLibrary:/books/OL10823902M" })
        #expect(try await provider.details(for: edition) == edition)
        // Even were it said to have more.
        var marked = edition
        marked.hasMoreDetails = true
        #expect(try await provider.details(for: marked) == marked)
        #expect(http.urls.count == 2)
        // A work still has its description to fetch.
        #expect(found.first?.hasMoreDetails == true)
    }

    // MARK: D5

    @Test func D5_theEditionsRequestFailingKeepsTheWorks() async throws {
        let works = try await OpenLibraryProvider(http: FakeHTTP(data: fixture("ol-editions-search")))
            .search(LookupQuery(title: "A Perfect Spy", author: "John le Carré"))
        #expect(works.count == 3)

        let failures: [@Sendable (URL) throws -> (data: Data, status: Int)] = [
            { _ in throw LookupError.notReachable },
            { _ in throw LookupError.unreadable },
            { _ in (Data(), 500) },
            { _ in (Data(), 404) },
            { _ in (Data("<html>Busy</html>".utf8), 200) },
            { _ in (Data("[]".utf8), 200) },
            { _ in (Data("{}".utf8), 200) },
            { _ in (Data(#"{"entries": {"a": 1}}"#.utf8), 200) },
            { _ in (Data(#"{"entries": []}"#.utf8), 200) },
        ]
        for failure in failures {
            let http = FakeHTTP { url in
                if url.path.hasSuffix("/editions.json") { return try failure(url) }
                return (fixture("ol-editions-search"), 200)
            }
            let found = try await OpenLibraryProvider(http: http).search(Self.query)
            #expect(found == works)
            #expect(http.urls.count == 2)
        }
    }

    @Test func D5_theSearchItselfFailingStillThrows() async throws {
        let http = FakeHTTP(data: Data(), status: 503)
        await #expect(throws: LookupError.refused(status: 503)) {
            _ = try await OpenLibraryProvider(http: http).search(Self.query)
        }
        #expect(http.urls.count == 1)
    }

    // MARK: D6

    @Test func D6_atMostTwelveMostRecentFirstUndatedLast() async throws {
        let dates: [Int?] = [1990, nil, 2005, 1987, 2005, nil, 2021, 1999, 2010, 1995, 2001, 2003, 1993, 2015, 1989, 2007]
        var entries: [String] = []
        for (number, year) in dates.enumerated() {
            let date = year.map { #", "publish_date": "June \#($0)""# } ?? ""
            entries.append(#"{"key": "/books/OL\#(number)M", "title": "The Book", "physical_format": "Audio CD"\#(date)}"#)
        }
        // Print editions among them do not count.
        entries.insert(#"{"key": "/books/OL99M", "title": "The Book", "physical_format": "Paperback", "publish_date": "2024"}"#, at: 0)
        let found = try await Self.editions(entries)
        #expect(found.count == 12)
        let years: [Int?] = [2021, 2015, 2010, 2007, 2005, 2005, 2003, 2001, 1999, 1995, 1993, 1990]
        #expect(found.map(\.metadata.year) == years)
        // The same year: in the order given.
        #expect(found.filter { $0.metadata.year == 2005 }.map(\.id) == ["openLibrary:/books/OL2M", "openLibrary:/books/OL4M"])

        // Fewer than twelve: the undated ones come last, in the order given.
        let few = try await Self.editions(Array(entries.prefix(5)))
        #expect(few.map(\.id) == ["openLibrary:/books/OL2M", "openLibrary:/books/OL0M", "openLibrary:/books/OL3M", "openLibrary:/books/OL1M"])
    }

    @Test func D6_aLongListIsNotReadPastWhatWasAskedFor() async throws {
        let entries = (0..<1000).map {
            #"{"key": "/books/OL\#($0)M", "title": "The Book", "physical_format": "Audio CD", "publish_date": "\#(1000 + $0)"}"#
        }
        let found = try await Self.editions(entries)
        #expect(found.count == 12)
        // A hundred were asked for: no more than the first hundred are read.
        #expect(found.first?.metadata.year == 1099)
    }
}
