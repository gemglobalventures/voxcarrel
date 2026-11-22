import Foundation
import Testing
@testable import VoxCarrelCore

@Suite struct OpenLibraryProviderTests {
    static let fields = "key,title,subtitle,author_name,first_publish_year,publisher,isbn,cover_i,language,subject,number_of_pages_median,edition_count"

    private func json(_ text: String) -> Data { Data(text.utf8) }

    private func candidate(key: String = "/works/OL21745884W") -> LookupCandidate {
        var metadata = BookMetadata(title: "Project Hail Mary", authors: ["Andy Weir"])
        metadata.year = 2021
        return LookupCandidate(id: "openLibrary:\(key)", source: .openLibrary, metadata: metadata,
                               coverURL: URL(string: "https://covers.openlibrary.org/b/id/11200092-L.jpg"),
                               note: "Open Library · 2021 · 32 editions", hasMoreDetails: true)
    }

    // MARK: O1 requests

    @Test func O1_titleAndAuthorRequest() async throws {
        let http = FakeHTTP(data: fixture("ol-search"))
        let provider = OpenLibraryProvider(http: http)
        #expect(provider.source == .openLibrary)
        _ = try await provider.search(LookupQuery(title: " Project Hail Mary ", author: "Andy Weir"))
        let url = try #require(http.urls.first)
        #expect(http.urls.count == 1)
        #expect(url.scheme == "https")
        #expect(url.host == "openlibrary.org")
        #expect(url.path == "/search.json")
        #expect(queryItems(url) == ["title": "Project Hail Mary", "author": "Andy Weir", "limit": "8", "fields": Self.fields])
        #expect(url.absoluteString ==
            "https://openlibrary.org/search.json?title=Project%20Hail%20Mary&author=Andy%20Weir&limit=8&fields=\(Self.fields)")
    }

    @Test func O1_anEmptyTitleOrAuthorIsOmitted() async throws {
        let http = FakeHTTP(data: fixture("ol-none"))
        let provider = OpenLibraryProvider(http: http, limit: 3)
        _ = try await provider.search(LookupQuery(title: "Dune", author: "  "))
        _ = try await provider.search(LookupQuery(title: "", author: "Frank Herbert"))
        #expect(queryItems(http.urls[0]) == ["title": "Dune", "limit": "3", "fields": Self.fields])
        #expect(queryItems(http.urls[1]) == ["author": "Frank Herbert", "limit": "3", "fields": Self.fields])
    }

    @Test func O1_anISBNThatIsFoundIsSearchedAlone() async throws {
        let http = FakeHTTP(data: fixture("ol-isbn"))
        let found = try await OpenLibraryProvider(http: http).search(
            LookupQuery(title: "Project Hail Mary", author: "Andy Weir", isbn: "978-0-593-13520-4", asin: "B08G9PRS1K"))
        #expect(!found.isEmpty)
        #expect(http.urls.count == 1)
        let url = try #require(http.urls.first)
        #expect(url.host == "openlibrary.org")
        #expect(url.path == "/search.json")
        #expect(queryItems(url) == ["isbn": "9780593135204", "limit": "8", "fields": Self.fields])
    }

    /// An ISBN Open Library does not know: the title and author are searched for instead.
    @Test func O1_anISBNThatFindsNothingFallsBackToTitleAndAuthor() async throws {
        let none = fixture("ol-none"), some = fixture("ol-search")
        let http = FakeHTTP { url in (queryItems(url)["isbn"] == nil ? some : none, 200) }
        let found = try await OpenLibraryProvider(http: http).search(
            LookupQuery(title: "Project Hail Mary", author: "Andy Weir", isbn: "9780000000002"))
        #expect(http.urls.count == 2)
        #expect(queryItems(http.urls[0]) == ["isbn": "9780000000002", "limit": "8", "fields": Self.fields])
        #expect(queryItems(http.urls[1]) == ["title": "Project Hail Mary", "author": "Andy Weir", "limit": "8", "fields": Self.fields])
        #expect(!found.isEmpty)
        // What was found by its title is not said to have the ISBN that found nothing.
        #expect(found.allSatisfy { $0.metadata.isbn != "9780000000002" })
    }

    @Test func O1_anISBNAloneThatFindsNothingAsksNoMore() async throws {
        let http = FakeHTTP(data: fixture("ol-none"))
        #expect(try await OpenLibraryProvider(http: http).search(LookupQuery(isbn: "9780000000002")).isEmpty)
        #expect(http.urls.count == 1)
    }

    @Test func O1_aFailedISBNRequestDoesNotFallBack() async throws {
        let http = FakeHTTP(data: Data(), status: 503)
        await #expect(throws: LookupError.refused(status: 503)) {
            _ = try await OpenLibraryProvider(http: http).search(LookupQuery(title: "Dune", isbn: "9780000000002"))
        }
        #expect(http.urls.count == 1)
    }

    /// An answer may be 5 MB at most, and may redirect only within openlibrary.org.
    @Test func O2_requestsAreLimited() async throws {
        let http = FakeHTTP { url in
            (url.path == "/search.json" ? fixture("ol-search") : fixture("ol-work"), 200)
        }
        let provider = OpenLibraryProvider(http: http)
        let found = try await provider.search(LookupQuery(title: "Project Hail Mary"))
        _ = try await provider.details(for: try #require(found.first))
        #expect(http.limits.count == 2)
        for limit in http.limits {
            #expect(limit == FakeHTTP.Limits(maxBytes: 5 * 1024 * 1024, redirectHosts: ["openlibrary.org"]))
        }
    }

    @Test func O1_anUnusableISBNFallsBackToTitleAndAuthor() async throws {
        let http = FakeHTTP(data: fixture("ol-none"))
        _ = try await OpenLibraryProvider(http: http).search(LookupQuery(title: "Dune", isbn: "not an isbn"))
        #expect(queryItems(try #require(http.urls.first)) == ["title": "Dune", "limit": "8", "fields": Self.fields])
    }

    @Test func O1_queryTextIsPercentEncoded() async throws {
        let http = FakeHTTP(data: fixture("ol-none"))
        _ = try await OpenLibraryProvider(http: http).search(LookupQuery(title: "Q&A + C# = 100%", author: "村上 春樹"))
        let url = try #require(http.urls.first)
        #expect(queryItems(url) == ["title": "Q&A + C# = 100%", "author": "村上 春樹", "limit": "8", "fields": Self.fields])
        #expect(url.absoluteString.contains("title=Q%26A%20%2B%20C%23%20%3D%20100%25&author=%E6%9D%91%E4%B8%8A%20%E6%98%A5%E6%A8%B9&limit=8"))
        #expect(url.fragment == nil)
    }

    // MARK: O2

    @Test func O2_everyRequestCarriesOnlyTheAppsUserAgent() async throws {
        let http = FakeHTTP { url in
            (url.path == "/search.json" ? fixture("ol-search") : fixture("ol-work"), 200)
        }
        let provider = OpenLibraryProvider(http: http)
        let found = try await provider.search(LookupQuery(title: "Project Hail Mary"))
        _ = try await provider.details(for: try #require(found.first))
        #expect(http.requests.count == 2)
        for request in http.requests {
            #expect(request.headers == ["User-Agent": "VoxCarrel/0.1 (https://voxcarrel.app)", "Accept": "application/json"])
        }
    }

    // MARK: O3–O6 mapping

    @Test func O3_aWorkWithManyEditions() async throws {
        let found = try await OpenLibraryProvider(http: FakeHTTP(data: fixture("ol-search")))
            .search(LookupQuery(title: "Project Hail Mary", author: "Andy Weir"))
        #expect(found.count == 2)
        let work = try #require(found.first)
        var expected = BookMetadata(title: "Project Hail Mary", authors: ["Andy Weir"])
        expected.year = 2021
        expected.pageCount = 496
        // Publisher, ISBN and language across 32 editions are a jumble: left empty.
        // O4: no genre. Nothing else is invented.
        #expect(work.metadata == expected)
        #expect(work.source == .openLibrary)
        // O5
        #expect(work.coverURL == URL(string: "https://covers.openlibrary.org/b/id/11200092-L.jpg"))
        // O6
        #expect(work.id == "openLibrary:/works/OL21745884W")
        #expect(work.note == "Open Library · 2021 · 32 editions")
        #expect(work.hasMoreDetails)
    }

    @Test func O3_aWorkWithExactlyOneEdition() async throws {
        let found = try await OpenLibraryProvider(http: FakeHTTP(data: fixture("ol-search")))
            .search(LookupQuery(title: "Project Hail Mary", author: "Andy Weir"))
        let boxSet = try #require(found.last)
        var expected = BookMetadata(title: "The Martian / Artemis / Project Hail Mary", authors: ["Andy Weir"])
        expected.year = 2022
        expected.pageCount = 1344
        expected.publisher = "Ballantine Books"
        expected.isbn = "9781637990520"
        expected.language = "en"
        #expect(boxSet.metadata == expected)
        #expect(boxSet.metadata.genre == nil)     // O4
        #expect(boxSet.coverURL == nil)           // O5: no cover_i
        #expect(boxSet.id == "openLibrary:/works/OL36735881W")
        #expect(boxSet.note == "Open Library · 2022 · 1 edition")
        #expect(boxSet.hasMoreDetails)
    }

    @Test func O3_subtitleAllAuthorsAndOneEditionOddities() async throws {
        let body = json("""
        {"numFound": 3, "docs": [
          {"key": "/works/OL1W", "title": " Good Omens ", "subtitle": "The Nice and Accurate Prophecies",
           "author_name": ["Terry Pratchett", " Neil Gaiman ", ""], "edition_count": 1,
           "publisher": ["Gollancz", "Workman"], "isbn": ["0575048003"], "language": ["eng", "fre"]},
          {"key": "/works/OL2W", "title": "Solo", "edition_count": 1, "language": ["xxx"], "isbn": ["junk", "057504800X"]},
          {"key": "/works/OL3W", "title": "Bare"}
        ]}
        """)
        let found = try await OpenLibraryProvider(http: FakeHTTP(data: body)).search(LookupQuery(title: "x"))
        #expect(found.count == 3)
        var first = BookMetadata(title: "Good Omens", authors: ["Terry Pratchett", "Neil Gaiman"])
        first.subtitle = "The Nice and Accurate Prophecies"
        first.isbn = "0575048003"
        // Two publishers and two languages for one edition are not a clear answer: left empty.
        #expect(found[0].metadata == first)
        var second = BookMetadata(title: "Solo")
        second.isbn = "057504800X"
        #expect(found[1].metadata == second)
        #expect(found[2].metadata == BookMetadata(title: "Bare"))
        #expect(found[2].note == "Open Library")
        #expect(found[1].note == "Open Library · 1 edition")
    }

    @Test func O3_anISBNSearchGivesTheAskedISBN() async throws {
        // The real answer by ISBN has no edition_count: publisher and language stay empty.
        let found = try await OpenLibraryProvider(http: FakeHTTP(data: fixture("ol-isbn")))
            .search(LookupQuery(isbn: "0-593-13520-2"))
        #expect(found.count == 1)
        let work = try #require(found.first)
        var expected = BookMetadata(title: "Project Hail Mary", authors: ["Andy Weir"])
        expected.year = 2021
        expected.pageCount = 496
        expected.isbn = "0593135202"
        #expect(work.metadata == expected)
        #expect(work.note == "Open Library · 2021")
        #expect(work.coverURL == URL(string: "https://covers.openlibrary.org/b/id/11200092-L.jpg"))
    }

    // MARK: O7 details

    @Test func O7_detailsAddTheDescription() async throws {
        let http = FakeHTTP(data: fixture("ol-work"))
        let before = candidate()
        let after = try await OpenLibraryProvider(http: http).details(for: before)
        #expect(http.urls == [try #require(URL(string: "https://openlibrary.org/works/OL21745884W.json"))])
        let summary = try #require(after.metadata.summary)
        // Placeholder text in the recorded answer: four paragraphs, Markdown emphasis and a source note.
        #expect(summary == """
        This text stands in for a description from Open Library–it is invented, and says nothing about any real book.

        A second paragraph follows, as the descriptions there often run to several.

        The third is one short line.

        The last names Project Hail Mary and The Martian with Markdown emphasis, which is taken out.
        """)
        #expect(summary.components(separatedBy: "\n\n").count == 4)
        #expect(!summary.contains("\r"))
        #expect(!after.hasMoreDetails)
        // Nothing else changes.
        var expected = before
        expected.metadata.summary = summary
        expected.hasMoreDetails = false
        #expect(after == expected)
    }

    @Test func O7_descriptionAsAPlainStringWithSourceNotes() async throws {
        let cases = [
            (#"{"description": "  A fine book.\r\n\r\nSecond paragraph.\r\n\r\n([source][1])\r\n\r\n[1]: https://example.org"}"#,
             "A fine book.\n\nSecond paragraph."),
            (#"{"description": "A fine book.\n\n----------\nAlso contained in:\n - [Omnibus](https://openlibrary.org/works/OL1W)"}"#,
             "A fine book."),
            (#"{"description": {"type": "/type/text", "value": "Line one.\n  ([Source][1])\n[1]: x"}}"#, "Line one."),
            (#"{"description": "No notes here (source unknown) --- really."}"#, "No notes here (source unknown) --- really."),
        ]
        for (body, expected) in cases {
            let after = try await OpenLibraryProvider(http: FakeHTTP(data: json(body))).details(for: candidate())
            #expect(after.metadata.summary == expected)
            #expect(!after.hasMoreDetails)
        }
    }

    @Test func O7_noDescriptionLeavesTheCandidateAsItWas() async throws {
        for body in [#"{"title": "Project Hail Mary", "key": "/works/OL21745884W"}"#, #"{"description": "  "}"#,
                     #"{"description": {"type": "/type/text"}}"#, #"{"description": 7}"#,
                     #"{"description": "([source][1])\n[1]: https://example.org"}"#] {
            let before = candidate()
            let after = try await OpenLibraryProvider(http: FakeHTTP(data: json(body))).details(for: before)
            #expect(after.metadata == before.metadata)
            #expect(after.coverURL == before.coverURL)
            #expect(after.note == before.note)
            #expect(after.id == before.id)
            // There is nothing more to fetch a second time.
            #expect(!after.hasMoreDetails)
        }
    }

    @Test func O7_detailsFailures() async throws {
        await #expect(throws: LookupError.refused(status: 404)) {
            _ = try await OpenLibraryProvider(http: FakeHTTP(data: Data("{}".utf8), status: 404)).details(for: candidate())
        }
        await #expect(throws: LookupError.unreadable) {
            _ = try await OpenLibraryProvider(http: FakeHTTP(data: Data("<html>".utf8))).details(for: candidate())
        }
        await #expect(throws: LookupError.notReachable) {
            _ = try await OpenLibraryProvider(http: FakeHTTP(throwing: LookupError.notReachable)).details(for: candidate())
        }
    }

    @Test func O7_detailsAskOnlyForOpenLibraryWorks() async throws {
        let http = FakeHTTP(data: fixture("ol-work"))
        let provider = OpenLibraryProvider(http: http)
        let audible = LookupCandidate(id: "audible:us:B08G9PRS1K", source: .audible, metadata: BookMetadata(title: "T"),
                                      coverURL: nil, note: "", hasMoreDetails: false)
        #expect(try await provider.details(for: audible) == audible)
        // A key that is not a plain Open Library path is never put into a URL.
        for key in ["/works/../../x", "//evil.example/works/OL1W", "/works/OL1W?x=1", "works/OL1W", "/works/OL1W#f", ""] {
            let odd = candidate(key: key)
            #expect(try await provider.details(for: odd) == odd)
        }
        #expect(http.requests.isEmpty)
    }

    // MARK: O8, O9

    @Test func O8_noResultsIsAnEmptyList() async throws {
        let found = try await OpenLibraryProvider(http: FakeHTTP(data: fixture("ol-none"))).search(LookupQuery(title: "zzzz"))
        #expect(found.isEmpty)
    }

    @Test(arguments: [403, 429, 500, 503, 204, 301])
    func O8_anErrorStatusIsRefused(status: Int) async throws {
        let http = FakeHTTP(data: fixture("ol-search"), status: status)
        await #expect(throws: LookupError.refused(status: status)) {
            _ = try await OpenLibraryProvider(http: http).search(LookupQuery(title: "Dune"))
        }
    }

    @Test(arguments: ["", "<html><body>Busy</body></html>", "[]", "{}", #"{"numFound": 2}"#, #"{"docs": {"a": 1}}"#, #"{"docs": "none"}"#])
    func O8_anUnexpectedShapeIsUnreadable(body: String) async throws {
        let http = FakeHTTP(data: Data(body.utf8))
        await #expect(throws: LookupError.unreadable) {
            _ = try await OpenLibraryProvider(http: http).search(LookupQuery(title: "Dune"))
        }
    }

    @Test func O8_aMalformedResultIsSkipped() async throws {
        let body = json("""
        {"numFound": 7, "docs": [
          "not an object",
          {"title": "No key"},
          {"key": "/works/OL5W"},
          {"key": "/works/OL6W", "title": "   "},
          {"key": 12, "title": "Numeric key"},
          {"key": "https://evil.example/works/OL7W", "title": "Odd key"},
          {"key": "/works/OL8W", "title": "Good", "author_name": "not a list", "first_publish_year": "1999",
           "cover_i": "x", "number_of_pages_median": 3.5, "edition_count": "1", "publisher": ["P"]}
        ]}
        """)
        let found = try await OpenLibraryProvider(http: FakeHTTP(data: body)).search(LookupQuery(title: "Good"))
        #expect(found.map(\.id) == ["openLibrary:/works/OL8W"])
        // Fields of the wrong type are left out rather than guessed at.
        #expect(found.first?.metadata == BookMetadata(title: "Good"))
        #expect(found.first?.coverURL == nil)
        #expect(found.first?.note == "Open Library")
    }

    @Test func O8_notReachablePassesThrough() async throws {
        await #expect(throws: LookupError.notReachable) {
            _ = try await OpenLibraryProvider(http: FakeHTTP(throwing: LookupError.notReachable)).search(LookupQuery(title: "Dune"))
        }
    }

    @Test func O9_nothingToSearchWithMakesNoRequest() async throws {
        let http = FakeHTTP(data: fixture("ol-search"))
        let provider = OpenLibraryProvider(http: http)
        #expect(try await provider.search(LookupQuery()).isEmpty)
        #expect(try await provider.search(LookupQuery(title: "  ", author: "\n", isbn: " ")).isEmpty)
        // Open Library cannot search by ASIN, and a broken ISBN is not sent.
        #expect(try await provider.search(LookupQuery(asin: "B08G9PRS1K")).isEmpty)
        #expect(try await provider.search(LookupQuery(isbn: "12345")).isEmpty)
        #expect(http.requests.isEmpty)
    }

    // MARK: What is taken is made safe

    @Test func O3_everythingTakenIsCleaned() async throws {
        let long = String(repeating: "x", count: 3000)
        let http = FakeHTTP(data: json("""
        {"docs": [
          {"key": "/works/OL1W", "title": "The\\tSalt\\nRoad\\u202e", "subtitle": "\\u0001 ",
           "author_name": ["Ines\\u2066 Calloway", "\\u0001", 7, null], "first_publish_year": 123456789,
           "number_of_pages_median": -3, "edition_count": 1, "publisher": ["Harbour\\u0001\\nPress"],
           "cover_i": -3, "isbn": ["9780593135204\\n"]},
          {"key": "/works/OL2W", "title": "\(long)", "author_name": ["\(long)"], "first_publish_year": 0,
           "edition_count": 1, "publisher": ["\(long)"], "cover_i": 12},
          {"key": "/works/OL3W", "title": "A", "first_publish_year": -44, "edition_count": 99999999999},
          {"key": "/works/OL4W", "title": "\\u0001\\u202e"},
          {"key": "/works/OL5W", "title": "B", "first_publish_year": 1e40, "cover_i": "12"}
        ]}
        """))
        let found = try await OpenLibraryProvider(http: http).search(LookupQuery(title: "Salt Road"))
        #expect(found.map(\.id) == ["openLibrary:/works/OL1W", "openLibrary:/works/OL2W", "openLibrary:/works/OL3W", "openLibrary:/works/OL5W"])
        let book = try #require(found.first)
        #expect(book.metadata.title == "The Salt Road")
        #expect(book.metadata.subtitle == nil)
        #expect(book.metadata.authors == ["Ines Calloway"])
        #expect(book.metadata.year == nil)
        #expect(book.metadata.pageCount == nil)
        #expect(book.metadata.publisher == "Harbour Press")
        #expect(book.metadata.isbn == "9780593135204")
        #expect(book.coverURL == nil)
        #expect(book.thumbnailURL == nil)
        #expect(book.note == "Open Library · 1 edition")
        #expect(found[1].metadata.title.count == 500)
        #expect(found[1].metadata.authors.first?.count == 500)
        #expect(found[1].metadata.publisher?.count == 200)
        #expect(found[1].metadata.year == nil)
        #expect(found[2].metadata.year == nil)
        #expect(found[2].note == "Open Library")
        #expect(found[3].metadata.year == nil)
        #expect(found[3].coverURL == nil)
    }

    /// O5: the row's picture is the medium size of the same cover.
    @Test func O5_theThumbnailIsTheMediumCover() async throws {
        let found = try await OpenLibraryProvider(http: FakeHTTP(data: fixture("ol-search")))
            .search(LookupQuery(title: "Project Hail Mary"))
        let work = try #require(found.first)
        #expect(work.coverURL == URL(string: "https://covers.openlibrary.org/b/id/11200092-L.jpg"))
        #expect(work.thumbnailURL == URL(string: "https://covers.openlibrary.org/b/id/11200092-M.jpg"))
    }

    /// The whole key, or it is no key: nothing may follow it, a line break included.
    @Test func O7_aKeyIsMatchedWhole() async throws {
        for good in ["/works/OL21745884W", "/books/OL1M", "/a/9"] {
            #expect(OpenLibraryProvider.isKey(good), "\(good)")
        }
        for bad in ["/works/OL1W\n", "/works/OL1W\r\n", "/works/OL1W\u{2028}", "\n/works/OL1W", "/works/OL1W/", "works/OL1W",
                    "/works/", "//OL1W", "/Works/OL1W", "/works/OL1W.json", "/works/OL1W?x=1", "/works/../OL1W", "/wörks/OL1W",
                    "/works/OL１W", ""] {
            #expect(!OpenLibraryProvider.isKey(bad), "\(bad.debugDescription)")
        }
        // As it comes out of a JSON answer, too.
        let http = FakeHTTP(data: json(#"{"docs": [{"key": "/works/OL1W\n", "title": "T"}, {"key": "/works/OL2W", "title": "U"}]}"#))
        let found = try await OpenLibraryProvider(http: http).search(LookupQuery(title: "T"))
        #expect(found.map(\.id) == ["openLibrary:/works/OL2W"])
    }

    @Test func O7_markdownEmphasisAndLinkReferencesAreRemoved() {
        let raw = """
        **Ada Example** is the *only reader* in a _quiet_ library.\r
        \r
        He has 2 * 3 * 4 problems, a snake_case_name, a footnote* and a rating of *****.\r
        See [the publisher][1].\r
        \r
        [1]: https://example.org/a\r
        \r
          [2]: https://example.org/b\r
        """
        #expect(OpenLibraryProvider.description(raw) == """
        Ada Example is the only reader in a quiet library.

        He has 2 * 3 * 4 problems, a snake_case_name, a footnote* and a rating of *****.
        See [the publisher][1].
        """)
        // A reference that is not at the end is part of the text.
        #expect(OpenLibraryProvider.description("[1]: https://example.org/a\nText") == "[1]: https://example.org/a\nText")
        #expect(OpenLibraryProvider.withoutEmphasis("*a* and **b c** and _d_ and * e * and f*g*h") == "a and b c and d and * e * and f*g*h")
    }

    @Test func O7_aDescriptionIsCleanedAndKeptToFiftyThousandCharacters() async throws {
        let http = FakeHTTP(data: json(#"{"description": {"value": "One\u0001\u202e\r\n\r\nTwo"}}"#))
        let detailed = try await OpenLibraryProvider(http: http).details(for: candidate())
        #expect(detailed.metadata.summary == "One\n\nTwo")
        let long = FakeHTTP(data: json("{\"description\": \"\(String(repeating: "word ", count: 30_000))\"}"))
        let summary = try #require(try await OpenLibraryProvider(http: long).details(for: candidate()).metadata.summary)
        #expect(summary.count <= 50_000)
    }
}
