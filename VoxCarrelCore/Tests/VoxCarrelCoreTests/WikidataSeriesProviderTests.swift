import Foundation
import Testing
@testable import VoxCarrelCore

/// WD1–WD5: what Wikidata says a series holds.
@Suite struct WikidataSeriesProviderTests {
    static let search = """
        {"search":[
          {"id":"Q100","label":"Tidewater","description":"television series"},
          {"id":"Q200","label":"Tidewater","description":"series of novels by Ines Calloway"},
          {"id":"notanid","label":"Junk"}
        ]}
        """

    private static func row(_ series: String, _ book: String, _ label: String, _ ordinal: String?, _ author: String?) -> String {
        var fields = [
            "\"s\":{\"value\":\"http://www.wikidata.org/entity/\(series)\"}",
            "\"book\":{\"value\":\"http://www.wikidata.org/entity/\(book)\"}",
            "\"bookLabel\":{\"value\":\"\(label)\"}",
        ]
        if let ordinal { fields.append("\"ordinal\":{\"value\":\"\(ordinal)\"}") }
        if let author { fields.append("\"authorLabel\":{\"value\":\"\(author)\"}") }
        return "{" + fields.joined(separator: ",") + "}"
    }

    static let books = "{\"results\":{\"bindings\":[" + [
        // The television series: its seasons have no author.
        row("Q100", "Q101", "Season 1", "1", nil), row("Q100", "Q102", "Season 2", "2", nil),
        // The novels, out of order, one row for each author of a book, one with no number,
        // one with no name in English.
        row("Q200", "Q203", "Harbour of Glass", "3", "Ines Calloway"),
        row("Q200", "Q201", "Salt Road", "1", "Ines Calloway"),
        row("Q200", "Q201", "Salt Road", "1", "Second Writer"),
        row("Q200", "Q202", "The Drowned Bell", "2", "Ines Calloway"),
        row("Q200", "Q204", "Low Water", "2.5", "Ines Calloway"),
        row("Q200", "Q205", "A Tidewater Companion", nil, "Ines Calloway"),
        row("Q200", "Q206", "Q206", "9", "Ines Calloway"),
    ].joined(separator: ",") + "]}}"

    private func provider(_ http: FakeHTTP) -> WikidataSeriesProvider { WikidataSeriesProvider(http: http) }

    private func http() -> FakeHTTP {
        FakeHTTP { url in
            (Data((url.host == "www.wikidata.org" ? Self.search : Self.books).utf8), 200)
        }
    }

    // WD1: a series is found by its name, with its books in order; what shares the
    // name and is not written is left out.
    @Test func WD1_aSeriesIsFoundByNameWithItsBooksInOrder() async throws {
        let http = http()
        let found = try await provider(http).series(named: " Tidewater ", author: "Ines Calloway")
        #expect(found.map(\.id) == ["Q200"])
        let series = try #require(found.first)
        #expect(series.title == "Tidewater" && series.about == "series of novels by Ines Calloway")
        #expect(series.page?.absoluteString == "https://www.wikidata.org/wiki/Q200")
        #expect(series.books.map(\.title) == ["Salt Road", "The Drowned Bell", "Low Water", "Harbour of Glass", "A Tidewater Companion"])
        #expect(series.books.map(\.number) == ["1", "2", "2.5", "3", nil])
        #expect(series.books[0].authors == ["Ines Calloway", "Second Writer"] && series.books[0].id == "Q201")
    }

    // WD2: two requests are made, both over https, saying who asks; the second names
    // only the things the first found, and asks both ways a book can be in a series.
    @Test func WD2_whatIsAskedOfWikidata() async throws {
        let http = http()
        _ = try await provider(http).series(named: "Tidewater")
        #expect(http.requests.count == 2)
        let first = try #require(URLComponents(url: http.requests[0].url, resolvingAgainstBaseURL: false))
        #expect(first.scheme == "https" && first.host == "www.wikidata.org" && first.path == "/w/api.php")
        #expect(first.queryItems?.first { $0.name == "search" }?.value == "Tidewater")
        #expect(first.queryItems?.first { $0.name == "action" }?.value == "wbsearchentities")
        let second = try #require(URLComponents(url: http.requests[1].url, resolvingAgainstBaseURL: false))
        #expect(second.scheme == "https" && second.host == "query.wikidata.org" && second.path == "/sparql")
        let query = try #require(second.queryItems?.first { $0.name == "query" }?.value)
        #expect(query.contains("VALUES ?s { wd:Q100 wd:Q200 }") && query.contains("P179") && query.contains("P527") && query.contains("P1545"))
        #expect(!query.contains("notanid"))
        #expect(http.requests.allSatisfy { $0.headers["User-Agent"]?.hasPrefix("VoxCarrel/") == true })
    }

    // WD3: a name nothing goes by asks once and finds nothing; a blank name asks nothing.
    @Test func WD3_nothingByThatName() async throws {
        let none = FakeHTTP(data: Data("{\"search\":[]}".utf8))
        #expect(try await provider(none).series(named: "No Such Series").isEmpty)
        #expect(none.requests.count == 1)
        let blank = FakeHTTP(data: Data("{}".utf8))
        #expect(try await provider(blank).series(named: "   ").isEmpty && blank.requests.isEmpty)
    }

    // WD4: an answer that cannot be read, and one that is refused, are said as such.
    @Test func WD4_whatGoesWrongIsSaid() async throws {
        await #expect(throws: LookupError.unreadable) { _ = try await provider(FakeHTTP(data: Data("<html>".utf8))).series(named: "X") }
        await #expect(throws: LookupError.refused(status: 429)) {
            _ = try await provider(FakeHTTP(data: Data(), status: 429)).series(named: "X")
        }
        let half = FakeHTTP { url in url.host == "www.wikidata.org" ? (Data(Self.search.utf8), 200) : (Data("busy".utf8), 503) }
        await #expect(throws: LookupError.refused(status: 503)) { _ = try await provider(half).series(named: "Tidewater") }
    }

    // WD5: of several series by one name, the one with a book by the author asked
    // about comes first, then the one with the most books; ids are told from addresses.
    @Test func WD5_whichSeriesComesFirst() throws {
        func series(_ id: String, _ author: String, _ count: Int) -> WikidataSeries {
            WikidataSeries(id: id, title: "Same Name", about: nil, books: (1...count).map {
                WikidataSeriesBook(id: "\(id)\($0)", title: "Book \($0)", number: "\($0)", authors: [author])
            })
        }
        let all = [series("Q1", "Someone Else", 9), series("Q2", "Inès Calloway", 3), series("Q3", "Another", 12)]
        #expect(WikidataSeriesProvider.ranked(all, author: "ines calloway").map(\.id) == ["Q2", "Q3", "Q1"])
        #expect(WikidataSeriesProvider.ranked(all, author: nil).map(\.id) == ["Q3", "Q1", "Q2"])
        #expect(WikidataSeriesProvider.id("http://www.wikidata.org/entity/Q42") == "Q42")
        #expect(WikidataSeriesProvider.id("http://example.com/Q42x") == nil && !WikidataSeriesProvider.isId("Q") && !WikidataSeriesProvider.isId("P179"))
    }
}
