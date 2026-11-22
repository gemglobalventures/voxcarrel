import Foundation
import Testing
@testable import VoxCarrelCore

@Suite struct AudibleStoreTests {
    @Test func hostsAndTitles() {
        let expected: [(AudibleStore, String, String)] = [
            (.us, "United States", "api.audible.com"), (.uk, "United Kingdom", "api.audible.co.uk"),
            (.au, "Australia", "api.audible.com.au"), (.ca, "Canada", "api.audible.ca"),
            (.de, "Germany", "api.audible.de"), (.fr, "France", "api.audible.fr"),
            (.it, "Italy", "api.audible.it"), (.es, "Spain", "api.audible.es"),
            (.jp, "Japan", "api.audible.co.jp"), (.in, "India", "api.audible.in"),
            (.br, "Brazil", "api.audible.com.br"),
        ]
        #expect(expected.map(\.0) == AudibleStore.allCases)
        for (store, title, host) in expected {
            #expect(store.title == title)
            #expect(store.host == host)
        }
        #expect(AudibleStore.in.rawValue == "in")
        #expect(AudibleStore(rawValue: "uk") == .uk)
    }

    @Test func storeForARegion() {
        #expect(AudibleStore.forRegion("US") == .us)
        #expect(AudibleStore.forRegion("GB") == .uk)
        #expect(AudibleStore.forRegion("gb") == .uk)
        #expect(AudibleStore.forRegion("UK") == .uk)
        #expect(AudibleStore.forRegion("AU") == .au)
        #expect(AudibleStore.forRegion("CA") == .ca)
        #expect(AudibleStore.forRegion("DE") == .de)
        #expect(AudibleStore.forRegion("FR") == .fr)
        #expect(AudibleStore.forRegion("IT") == .it)
        #expect(AudibleStore.forRegion("ES") == .es)
        #expect(AudibleStore.forRegion("JP") == .jp)
        #expect(AudibleStore.forRegion("IN") == .in)
        #expect(AudibleStore.forRegion("BR") == .br)
        // Countries served by a neighbour's store.
        #expect(AudibleStore.forRegion("NZ") == .au)
        #expect(AudibleStore.forRegion("IE") == .uk)
        #expect(AudibleStore.forRegion("AT") == .de)
        #expect(AudibleStore.forRegion("CH") == .de)
        // None, or one with no store.
        #expect(AudibleStore.forRegion(nil) == .us)
        #expect(AudibleStore.forRegion("") == .us)
        #expect(AudibleStore.forRegion("ZA") == .us)
    }
}

@Suite struct AudibleProviderTests {
    static let groups = "contributors,product_desc,product_extended_attrs,product_attrs,media,series,category_ladders"

    private func json(_ text: String) -> Data { Data(text.utf8) }

    private func search(_ body: String, store: AudibleStore = .us,
                        query: LookupQuery = LookupQuery(title: "x")) async throws -> [LookupCandidate] {
        try await AudibleProvider(http: FakeHTTP(data: json(body)), store: store).search(query)
    }

    // MARK: U1, U2 requests

    @Test func U1_titleAndAuthorRequest() async throws {
        let http = FakeHTTP(data: fixture("au-search"))
        let provider = AudibleProvider(http: http, store: .us)
        #expect(provider.source == .audible)
        _ = try await provider.search(LookupQuery(title: " Project Hail Mary ", author: "Andy Weir", isbn: "9780593135204"))
        #expect(http.urls.count == 1)
        let url = try #require(http.urls.first)
        #expect(url.scheme == "https")
        #expect(url.host == "api.audible.com")
        #expect(url.path == "/1.0/catalog/products")
        #expect(queryItems(url) == [
            "title": "Project Hail Mary", "author": "Andy Weir", "num_results": "8", "products_sort_by": "Relevance",
            "response_groups": Self.groups, "image_sizes": "500,1024",
        ])
        #expect(queryItems(url)["keywords"] == nil)
        #expect(url.absoluteString == "https://api.audible.com/1.0/catalog/products?title=Project%20Hail%20Mary&author=Andy%20Weir"
            + "&num_results=8&products_sort_by=Relevance&response_groups=\(Self.groups)&image_sizes=500,1024")
    }

    @Test func U1_anEmptyTitleOrAuthorIsOmitted() async throws {
        let http = FakeHTTP(data: fixture("au-none"))
        let provider = AudibleProvider(http: http, store: .us, limit: 5)
        _ = try await provider.search(LookupQuery(title: "Q&A + C# = 100%", author: " "))
        _ = try await provider.search(LookupQuery(author: "村上 春樹"))
        #expect(queryItems(http.urls[0]) == [
            "title": "Q&A + C# = 100%", "num_results": "5", "products_sort_by": "Relevance",
            "response_groups": Self.groups, "image_sizes": "500,1024",
        ])
        #expect(http.urls[0].absoluteString.contains("?title=Q%26A%20%2B%20C%23%20%3D%20100%25&num_results=5&"))
        #expect(queryItems(http.urls[1]) == [
            "author": "村上 春樹", "num_results": "5", "products_sort_by": "Relevance",
            "response_groups": Self.groups, "image_sizes": "500,1024",
        ])
    }

    @Test func U1_anASINIsLookedUpDirectly() async throws {
        let http = FakeHTTP(data: fixture("au-asin"))
        let found = try await AudibleProvider(http: http, store: .us)
            .search(LookupQuery(title: "Project Hail Mary", author: "Andy Weir", asin: " b08g9prs1k "))
        #expect(http.urls.count == 1)
        let url = try #require(http.urls.first)
        #expect(url.host == "api.audible.com")
        #expect(url.path == "/1.0/catalog/products/B08G9PRS1K")
        #expect(queryItems(url) == ["response_groups": Self.groups, "image_sizes": "500,1024"])
        #expect(url.absoluteString ==
            "https://api.audible.com/1.0/catalog/products/B08G9PRS1K?response_groups=\(Self.groups)&image_sizes=500,1024")
        #expect(found.map(\.id) == ["audible:us:B08G9PRS1K"])
        #expect(found.first?.metadata.title == "Project Hail Mary")
        #expect(found.first?.metadata.asin == "B08G9PRS1K")
    }

    @Test func U1_anUnknownASINGivesNothing() async throws {
        let http = FakeHTTP(data: fixture("au-badasin"))
        let found = try await AudibleProvider(http: http, store: .us).search(LookupQuery(asin: "B000000000"))
        #expect(found.isEmpty)
        #expect(http.urls.map(\.path) == ["/1.0/catalog/products/B000000000"])
    }

    @Test func U1_anASINThatIsNotOneNeverReachesThePath() async throws {
        let http = FakeHTTP(data: fixture("au-none"))
        let provider = AudibleProvider(http: http, store: .us)
        // Falls back to the title; with no title, nothing is asked.
        _ = try await provider.search(LookupQuery(title: "Dune", asin: "../../x?y=1"))
        #expect(http.urls.count == 1)
        #expect(http.urls.first?.path == "/1.0/catalog/products")
        #expect(queryItems(try #require(http.urls.first))["title"] == "Dune")
        #expect(try await provider.search(LookupQuery(asin: "B08G9PRS1K/extra")).isEmpty)
        #expect(try await provider.search(LookupQuery(asin: "short")).isEmpty)
        #expect(http.urls.count == 1)
    }

    @Test func U1_nothingSearchableMakesNoRequest() async throws {
        let http = FakeHTTP(data: fixture("au-search"))
        let provider = AudibleProvider(http: http, store: .us)
        #expect(try await provider.search(LookupQuery()).isEmpty)
        #expect(try await provider.search(LookupQuery(title: " ", author: "\t")).isEmpty)
        // An ISBN alone cannot be searched here.
        #expect(try await provider.search(LookupQuery(isbn: "9780593135204")).isEmpty)
        #expect(http.requests.isEmpty)
    }

    @Test(arguments: [
        (AudibleStore.us, "api.audible.com"), (.uk, "api.audible.co.uk"), (.au, "api.audible.com.au"),
        (.de, "api.audible.de"), (.jp, "api.audible.co.jp"), (.in, "api.audible.in"), (.br, "api.audible.com.br"),
    ])
    func U2_theHostIsTheStores(store: AudibleStore, host: String) async throws {
        let http = FakeHTTP { url in
            (url.path.hasSuffix("/products") ? fixture("au-uk") : fixture("au-asin"), 200)
        }
        let provider = AudibleProvider(http: http, store: store)
        let found = try await provider.search(LookupQuery(title: "Project Hail Mary", author: "Andy Weir"))
        _ = try await provider.search(LookupQuery(asin: "B08GB2RLKM"))
        #expect(http.urls.map(\.host) == [host, host])
        #expect(http.urls.map(\.scheme) == ["https", "https"])
        #expect(http.urls[0].absoluteString == "https://\(host)/1.0/catalog/products?title=Project%20Hail%20Mary&author=Andy%20Weir"
            + "&num_results=8&products_sort_by=Relevance&response_groups=\(Self.groups)&image_sizes=500,1024")
        #expect(http.urls[1].absoluteString ==
            "https://\(host)/1.0/catalog/products/B08GB2RLKM?response_groups=\(Self.groups)&image_sizes=500,1024")
        // U7: the store is part of the id, since each store has its own ASINs.
        #expect(found.map(\.id) == ["audible:\(store.rawValue):B08GB2RLKM"])
    }

    @Test func U2_noCookiesOrAccountHeaders() async throws {
        let http = FakeHTTP { url in
            (url.path.hasSuffix("/products") ? fixture("au-search") : fixture("au-asin"), 200)
        }
        let provider = AudibleProvider(http: http, store: .uk)
        _ = try await provider.search(LookupQuery(title: "Project Hail Mary"))
        _ = try await provider.search(LookupQuery(asin: "B08G9PRS1K"))
        #expect(http.requests.count == 2)
        for request in http.requests {
            #expect(request.headers == ["User-Agent": "VoxCarrel/0.1 (https://voxcarrel.app)", "Accept": "application/json"])
        }
    }

    // MARK: U3 mapping

    @Test func U3_aProductFromTheRealSearch() async throws {
        let found = try await AudibleProvider(http: FakeHTTP(data: fixture("au-search")), store: .us)
            .search(LookupQuery(title: "Project Hail Mary", author: "Andy Weir"))
        let first = try #require(found.first)
        let summary = try #require(first.metadata.summary)
        #expect(summary.hasPrefix("A demonstration summary."))
        #expect(summary.contains("\n\nA placeholder description"))
        #expect(!summary.contains("<"))

        var expected = BookMetadata(title: "Project Hail Mary", authors: ["Andy Weir"])
        expected.narrators = ["Ray Porter"]
        expected.publisher = "Audible Studios"
        expected.year = 2021
        expected.language = "en"
        expected.durationSeconds = 970 * 60
        expected.genre = "Mystery, Thriller & Suspense"
        expected.asin = "B08G9PRS1K"
        expected.summary = summary
        // No subtitle, no series, no ISBN, no page count: nothing invented.
        #expect(first.metadata == expected)
        #expect(first.source == .audible)
        // U6, U7
        #expect(first.coverURL == URL(string: "https://m.media-amazon.com/images/I/81Nzlrfud+L._SL1024_.jpg"))
        #expect(first.note == "Audible · Unabridged · 16h 10m · English")
        #expect(first.id == "audible:us:B08G9PRS1K")
        #expect(!first.hasMoreDetails)
    }

    @Test func U3_subtitleNarratorsAndIssueDate() async throws {
        let found = try await AudibleProvider(http: FakeHTTP(data: fixture("au-series")), store: .us)
            .search(LookupQuery(title: "The Way of Kings"))
        let book = try #require(found.first)
        #expect(book.metadata.title == "The Way of Kings")
        #expect(book.metadata.subtitle == "Book One of the Stormlight Archive")
        #expect(book.metadata.narrators == ["Michael Kramer", "Kate Reading"])
        #expect(book.metadata.publisher == "Macmillan Audio")
        #expect(book.metadata.year == 2010)
        #expect(book.metadata.durationSeconds == 163_800.0)
        #expect(book.metadata.genre == "Science Fiction & Fantasy")
        #expect(book.note == "Audible · Unabridged · 45h 30m · English")

        let fallback = try await search("""
        {"products": [
          {"asin": "B000000001", "title": "Issue Only", "issue_date": "1999-12-31"},
          {"asin": "B000000002", "title": "Both", "release_date": "2005-01-01", "issue_date": "1999-12-31"},
          {"asin": "B000000003", "title": "Bad Dates", "release_date": "soon", "issue_date": ""},
          {"asin": "B000000004", "title": "Bad Release", "release_date": "tbc", "issue_date": "2001-02-03"}
        ]}
        """)
        #expect(fallback.map(\.metadata.year) == [1999, 2005, nil, 2001])
    }

    @Test func U3_genreIsTheFirstGenresLadder() async throws {
        let found = try await search("""
        {"products": [
          {"asin": "B000000001", "title": "A", "category_ladders": [
            {"root": "EditorsPicks", "ladder": [{"id": "1", "name": "Staff Picks"}]},
            {"root": "Genres", "ladder": [{"id": "2", "name": "History"}, {"id": "3", "name": "Europe"}]},
            {"root": "Genres", "ladder": [{"id": "4", "name": "Biographies"}]}]},
          {"asin": "B000000002", "title": "B", "category_ladders": [{"root": "Genres", "ladder": []}]},
          {"asin": "B000000003", "title": "C", "category_ladders": "none"}
        ]}
        """)
        #expect(found.map(\.metadata.genre) == ["History", nil, nil])
    }

    @Test func U3_languageGoesThroughLanguageCode() async throws {
        let found = try await search("""
        {"products": [
          {"asin": "B000000001", "title": "A", "language": "german"},
          {"asin": "B000000002", "title": "B", "language": "klingon"},
          {"asin": "B000000003", "title": "C"}
        ]}
        """)
        #expect(found.map(\.metadata.language) == ["de", nil, nil])
        // The note shows what Audible said, even when no code is known for it.
        #expect(found.map(\.note) == ["Audible · German", "Audible · Klingon", "Audible"])
    }

    // MARK: U4 series

    @Test func U4_theNumberedMainSeriesFromTheRealAnswer() async throws {
        let found = try await AudibleProvider(http: FakeHTTP(data: fixture("au-series")), store: .us)
            .search(LookupQuery(title: "The Way of Kings", author: "Brandon Sanderson"))
        let book = try #require(found.first)
        // "The Cosmere" comes first but has no number.
        #expect(book.metadata.series == "The Stormlight Archive")
        #expect(book.metadata.seriesNumber == "1")
    }

    @Test func U4_seriesChoices() async throws {
        let found = try await search("""
        {"products": [
          {"asin": "B000000001", "title": "Named main series wins", "publication_name": "Second",
           "series": [{"title": "First", "sequence": "3"}, {"title": "Second", "sequence": "2.5"}]},
          {"asin": "B000000002", "title": "Else the first numbered", "publication_name": "Unnumbered",
           "series": [{"title": "Unnumbered", "sequence": ""}, {"title": "First", "sequence": "3"}, {"title": "Second", "sequence": "1-3"}]},
          {"asin": "B000000003", "title": "No numbers at all", "publication_name": "Main",
           "series": [{"title": "Universe", "sequence": ""}, {"title": "Main"}]},
          {"asin": "B000000004", "title": "No numbers, no main",
           "series": [{"title": "Universe", "sequence": " "}, {"title": "Other", "sequence": ""}]},
          {"asin": "B000000005", "title": "No series"},
          {"asin": "B000000006", "title": "Empty series", "series": [], "publication_name": "Ghost"},
          {"asin": "B000000007", "title": "Odd entries", "series": ["x", {"sequence": "1"}, {"title": " ", "sequence": "2"}, {"title": "Real", "sequence": 4}]}
        ]}
        """)
        #expect(found.map(\.metadata.series) == ["Second", "First", "Main", "Universe", nil, nil, "Real"])
        #expect(found.map(\.metadata.seriesNumber) == ["2.5", "3", nil, nil, nil, nil, nil])
    }

    // MARK: U5, U6, U7

    @Test func U5_authorsAndNarratorsAreKeptAsGiven() async throws {
        let found = try await search("""
        {"products": [{"asin": "B000000001", "title": "A",
          "authors": [{"asin": "B1", "name": "Homer"}, {"name": "Emily Wilson - translator"}, {"name": "Jane Doe - foreword"}, {"name": "  "}, {"asin": "B2"}, "x"],
          "narrators": [{"name": "Claire Danes"}, {"name": "Full cast"}]}]}
        """)
        #expect(found.first?.metadata.authors == ["Homer", "Emily Wilson - translator", "Jane Doe - foreword"])
        #expect(found.first?.metadata.narrators == ["Claire Danes", "Full cast"])

        // The real answer that lists a translator as a second author.
        let real = try await AudibleProvider(http: FakeHTTP(data: fixture("au-keywords")), store: .us).search(LookupQuery(title: "x"))
        #expect(real.last?.metadata.authors == ["Andy Weir", "Javier Guerrero Gimeno"])
        #expect(real[1].metadata.narrators.count == 9)
        #expect(real[1].metadata.narrators.last == "Full cast")
    }

    @Test func U6_theLargestCoverOnOffer() async throws {
        let uk = try await AudibleProvider(http: FakeHTTP(data: fixture("au-uk")), store: .uk).search(LookupQuery(title: "x"))
        #expect(uk.first?.coverURL == URL(string: "https://m.media-amazon.com/images/I/51POf8gOyLL._SL500_.jpg"))
        let found = try await search("""
        {"products": [
          {"asin": "B000000001", "title": "A", "product_images": {"500": "https://m.media-amazon.com/a500.jpg", "1024": "https://m.media-amazon.com/a1024.jpg"}},
          {"asin": "B000000002", "title": "B", "product_images": {"252": "https://m.media-amazon.com/b252.jpg"}},
          {"asin": "B000000003", "title": "C", "product_images": {}},
          {"asin": "B000000004", "title": "D"},
          {"asin": "B000000005", "title": "E", "product_images": {"1024": "", "500": 5}}
        ]}
        """)
        #expect(found.map(\.coverURL) == [URL(string: "https://m.media-amazon.com/a1024.jpg"), nil, nil, nil, nil])
    }

    @Test func U7_notesLeaveOutWhatIsUnknown() async throws {
        let found = try await search("""
        {"products": [
          {"asin": "B000000001", "title": "A", "format_type": "abridged", "runtime_length_min": 45, "language": "french"},
          {"asin": "B000000002", "title": "B", "runtime_length_min": 120},
          {"asin": "B000000003", "title": "C", "format_type": "original_recording", "runtime_length_min": 0},
          {"asin": "B000000004", "title": "D"},
          {"asin": "B000000005", "title": "E", "language": "mandarin_chinese", "runtime_length_min": 61}
        ]}
        """, store: .in)
        #expect(found.map(\.note) == [
            "Audible · Abridged · 45m · French", "Audible · 2h 0m", "Audible · Original recording", "Audible",
            "Audible · 1h 1m · Mandarin chinese",
        ])
        #expect(found.map(\.id) == (1...5).map { "audible:in:B00000000\($0)" })
        #expect(found.allSatisfy { !$0.hasMoreDetails })
        #expect(found.map(\.metadata.durationSeconds) == [2700, 7200, nil, nil, 3660])
        #expect(found.last?.metadata.language == "zh")

        // Details add nothing for Audible.
        let first = try #require(found.first)
        let http = FakeHTTP(data: fixture("au-asin"))
        #expect(try await AudibleProvider(http: http, store: .in).details(for: first) == first)
        #expect(http.requests.isEmpty)
    }

    // MARK: U8, U9

    @Test func U8_noProductsIsAnEmptyList() async throws {
        let found = try await AudibleProvider(http: FakeHTTP(data: fixture("au-none")), store: .us).search(LookupQuery(title: "zzzz"))
        #expect(found.isEmpty)
    }

    @Test(arguments: [403, 429, 500, 503])
    func U8_anErrorStatusIsRefused(status: Int) async throws {
        let http = FakeHTTP(data: fixture("au-search"), status: status)
        await #expect(throws: LookupError.refused(status: status)) {
            _ = try await AudibleProvider(http: http, store: .us).search(LookupQuery(title: "Dune"))
        }
        await #expect(throws: LookupError.refused(status: status)) {
            _ = try await AudibleProvider(http: http, store: .us).search(LookupQuery(asin: "B08G9PRS1K"))
        }
    }

    @Test(arguments: ["", "<html>Sign in</html>", "[]", "{}", #"{"products": {"a": 1}}"#, #"{"product": {"asin": "B08G9PRS1K", "title": "By ASIN shape"}}"#])
    func U8_anUnexpectedSearchShapeIsUnreadable(body: String) async throws {
        let http = FakeHTTP(data: Data(body.utf8))
        await #expect(throws: LookupError.unreadable) {
            _ = try await AudibleProvider(http: http, store: .us).search(LookupQuery(title: "Dune"))
        }
    }

    @Test(arguments: ["", "[]", "{}", #"{"product": []}"#, #"{"products": []}"#])
    func U8_anUnexpectedASINShapeIsUnreadable(body: String) async throws {
        let http = FakeHTTP(data: Data(body.utf8))
        await #expect(throws: LookupError.unreadable) {
            _ = try await AudibleProvider(http: http, store: .us).search(LookupQuery(asin: "B08G9PRS1K"))
        }
    }

    @Test func U8_aMalformedProductIsSkipped() async throws {
        let found = try await search("""
        {"products": [
          "not an object",
          {"title": "No ASIN"},
          {"asin": "B000000001"},
          {"asin": "B000000002", "title": "  "},
          {"asin": 5, "title": "Numeric ASIN"},
          {"asin": "B000000003", "title": "Good", "authors": "nobody", "narrators": 3, "runtime_length_min": "long",
           "publisher_name": 9, "release_date": 2020, "language": [], "series": "none", "publisher_summary": {}}
        ]}
        """)
        #expect(found.map(\.id) == ["audible:us:B000000003"])
        var expected = BookMetadata(title: "Good")
        expected.asin = "B000000003"
        #expect(found.first?.metadata == expected)
        #expect(found.first?.note == "Audible")
    }

    @Test func U8_notReachablePassesThrough() async throws {
        await #expect(throws: LookupError.notReachable) {
            _ = try await AudibleProvider(http: FakeHTTP(throwing: LookupError.notReachable), store: .us).search(LookupQuery(title: "Dune"))
        }
    }

    @Test func U9_otherLanguagesAreKeptInAudiblesOrder() async throws {
        let found = try await AudibleProvider(http: FakeHTTP(data: fixture("au-search")), store: .us)
            .search(LookupQuery(title: "Project Hail Mary", author: "Andy Weir"))
        #expect(found.map(\.id) == ["audible:us:B08G9PRS1K", "audible:us:B0CTZVXP8H"])
        #expect(found.map(\.metadata.language) == ["en", "it"])
        #expect(found.last?.note == "Audible · Unabridged · 17h 5m · Italian")
        #expect(found.last?.metadata.narrators == ["William Angiuli"])

        // Even unrelated titles and a looser match are passed on untouched.
        let loose = try await AudibleProvider(http: FakeHTTP(data: fixture("au-keywords")), store: .us)
            .search(LookupQuery(title: "Project Hail Mary"))
        #expect(loose.map(\.metadata.title) == ["Project Hail Mary", "Exoplanet", "Proyecto Hail Mary"])
        #expect(loose.map(\.metadata.asin) == ["B08G9PRS1K", "B0HDFGKSTL", "8418037121"])
        #expect(loose.map(\.metadata.language) == ["en", "en", "es"])
    }
}
