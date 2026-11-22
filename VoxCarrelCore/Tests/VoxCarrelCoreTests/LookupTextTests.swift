import Foundation
import Testing
@testable import VoxCarrelCore

@Suite struct LookupTypesTests {
    @Test func sourceTitles() {
        #expect(LookupSource.openLibrary.title == "Open Library")
        #expect(LookupSource.audible.title == "Audible")
    }

    // T6
    @Test func T6_queryIsEmptyWhenEverythingIsBlank() {
        #expect(LookupQuery().isEmpty)
        #expect(LookupQuery(title: "  ", author: "\n", isbn: " ", asin: "").isEmpty)
        #expect(!LookupQuery(title: "Dune").isEmpty)
        #expect(!LookupQuery(author: "Herbert").isEmpty)
        #expect(!LookupQuery(isbn: "9780593135204").isEmpty)
        #expect(!LookupQuery(asin: "B08G9PRS1K").isEmpty)
    }

    @Test func providerDetailsDefaultIsUnchanged() async throws {
        struct Plain: LookupProvider {
            let source = LookupSource.audible
            func search(_ query: LookupQuery) async throws -> [LookupCandidate] { [] }
        }
        let candidate = LookupCandidate(id: "audible:us:X", source: .audible, metadata: BookMetadata(title: "T"),
                                        coverURL: nil, note: "Audible", hasMoreDetails: false)
        let detailed = try await Plain().details(for: candidate)
        #expect(detailed == candidate)
    }

    // O2: the User-Agent names the app and nothing else.
    @Test func O2_userAgentNamesOnlyTheApp() {
        #expect(LookupRequest.userAgent == "VoxCarrel/\(LookupRequest.version) (https://voxcarrel.app)")
        #expect(LookupRequest.headers["User-Agent"] == LookupRequest.userAgent)
        #expect(!LookupRequest.userAgent.contains(NSUserName()))
        #expect(!LookupRequest.userAgent.contains(ProcessInfo.processInfo.hostName))
    }

    // O1/U1: text is percent-encoded so nothing in it can change the request's shape.
    @Test func queryTextIsPercentEncoded() throws {
        let url = try #require(LookupRequest.url(host: "example.org", path: "/s", query: [
            ("title", "Fish & Chips + #1 = 100%?"), ("author", "村上 春樹"), ("fields", "a,b"),
        ]))
        let raw = url.absoluteString
        #expect(raw.hasPrefix("https://example.org/s?title=Fish%20%26%20Chips%20%2B%20%231%20%3D%20100%25%3F&author="))
        #expect(raw.hasSuffix("&fields=a,b"))
        #expect(queryItems(url) == ["title": "Fish & Chips + #1 = 100%?", "author": "村上 春樹", "fields": "a,b"])
    }
}

@Suite struct LookupTextTests {
    // T2
    @Test func T2_anAudibleSummaryBecomesParagraphs() throws {
        let json = try #require(try JSONSerialization.jsonObject(with: fixture("au-search")) as? [String: Any])
        let products = try #require(json["products"] as? [[String: Any]])
        let html = try #require(products[0]["publisher_summary"] as? String)
        let text = LookupText.plainText(fromHTML: html)
        #expect(!text.contains("<"))
        #expect(!text.contains(">"))
        #expect(!text.contains("  "))
        #expect(!text.contains("\n\n\n"))
        let paragraphs = text.components(separatedBy: "\n\n")
        // The summary in the recorded answer is placeholder text in the shape Audible sends.
        #expect(paragraphs == [
            "A demonstration summary in bold italics for the tests.",
            "A second line, set apart",
            "This text stands in for a publisher's description. It is invented & says nothing about any real book.",
            "The next paragraph has a line break here,\nthen carries on — with a numeric entity and some italics.",
            "Note: none of this prose was written by a publisher.",
        ])
        #expect(text == text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test func T2_paragraphsAndBreaks() {
        #expect(LookupText.plainText(fromHTML: "<p>One</p><p>Two<br>Three<br/>Four<BR />Five</p>") == "One\n\nTwo\nThree\nFour\nFive")
        #expect(LookupText.plainText(fromHTML: "<P class=\"x\">One</P>\n\n\n<p></p><p> </p><p>Two</p>") == "One\n\nTwo")
        #expect(LookupText.plainText(fromHTML: "  <p>  spaced   <b>out</b>\t text </p>  ") == "spaced out text")
    }

    @Test func T2_otherTagsAreRemoved() {
        #expect(LookupText.plainText(fromHTML: "<div><b>Bold</b> <i>italic</i> <a href=\"https://x.test/?a=1&b=2\">link</a></div>") == "Bold italic link")
        #expect(LookupText.plainText(fromHTML: "<ul><li>a</li></ul><!-- note -->b") == "ab")
        #expect(LookupText.plainText(fromHTML: "<p>keep</p><script>alert(1)</script><style>p { }</style>") == "keep")
    }

    @Test func T2_entitiesAreDecoded() {
        #expect(LookupText.plainText(fromHTML: "<p>Tom &amp; Jerry &lt;3 &gt; &quot;hi&quot; it&#39;s&nbsp;fine</p>") == "Tom & Jerry <3 > \"hi\" it's fine")
        #expect(LookupText.plainText(fromHTML: "<p>caf&#233; &#x2014; &#X41;</p>") == "café — A")
        // Decoded once only, and an escaped tag stays as text.
        #expect(LookupText.plainText(fromHTML: "<p>&amp;lt; &lt;b&gt;</p>") == "&lt; <b>")
        // Not entities: left alone.
        #expect(LookupText.plainText(fromHTML: "<p>AT&T &bogus; &#xZZ; &#1114112;</p>") == "AT&T &bogus; &#xZZ; &#1114112;")
    }

    @Test func T2_plainTextPassesThroughTrimmed() {
        #expect(LookupText.plainText(fromHTML: "  Just text.\n\n\nTwo  spaces, 1 < 2 and 3 > 2; Simon & Schuster.  \n") ==
            "Just text.\n\n\nTwo  spaces, 1 < 2 and 3 > 2; Simon & Schuster.")
        #expect(LookupText.plainText(fromHTML: "") == "")
        #expect(LookupText.plainText(fromHTML: "<p></p>") == "")
    }

    /// The scanner reads once: text made to send a pattern-matcher back over itself costs no more than any other.
    @Test(arguments: ["<script>", "<style>", "<!--", "<a ", "</p", "&amp", "<script></script x", "<p>&#x41;"])
    func T2_hostileTextIsReadInLinearTime(piece: String) {
        let megabyte = String(repeating: piece, count: 1_048_576 / piece.utf8.count)
        var scanner = LookupText.HTMLScanner(Array(megabyte.utf8))
        let clock = ContinuousClock()
        let taken = clock.measure { scanner.scan() }
        // The limit is generous on purpose: reading once takes well under a second even on a
        // busy machine in a debug build, where the old pattern-matching took many minutes.
        #expect(taken < .seconds(20), "1 MB of \(piece) took \(taken)")
        // And through the front door, which reads only the first 50,000 characters.
        let whole = clock.measure { _ = LookupText.plainText(fromHTML: megabyte) }
        #expect(whole < .seconds(20), "1 MB of \(piece) took \(whole) in all")
    }

    @Test func T2_unfinishedMarkupIsLeftAsText() {
        #expect(LookupText.plainText(fromHTML: "<b>a</b> <!-- never closed") == "a <!-- never closed")
        #expect(LookupText.plainText(fromHTML: "<b>a</b> <i never closed") == "a <i never closed")
        // A script with no end: only its tag goes, as any other tag would.
        #expect(LookupText.plainText(fromHTML: "<p>a</p><script>b") == "a\n\nb")
        #expect(LookupText.plainText(fromHTML: "<p>a</p><SCRIPT type=x>b</script >c<style>d</STYLE>e") == "a\n\nce")
    }

    @Test func T2_onlyTheFirstFiftyThousandCharactersAreRead() {
        let long = "<p>" + String(repeating: "é", count: 60_000) + "</p>"
        let text = LookupText.plainText(fromHTML: long)
        #expect(text.count == 50_000 - 3 + 1)
        #expect(text.hasSuffix("é…"))
        let plain = LookupText.plainText(fromHTML: String(repeating: "a", count: 50_001))
        #expect(plain.count == 50_001)
        #expect(plain.hasSuffix("a…"))
        #expect(LookupText.plainText(fromHTML: String(repeating: "a", count: 50_000)).count == 50_000)
    }

    /// An entity that stands for a control character, or for one that turns the text around, stands for nothing.
    @Test func T2_entitiesForControlCharactersAreDropped() {
        #expect(LookupText.plainText(fromHTML: "a&#1;b&#x202E;c&#x7f;d&#x2066;e&#x9b;f") == "abcdef")
        #expect(LookupText.plainText(fromHTML: "<p>a&#10;b&#9;c</p>") == "a\nb c")
    }

    // MARK: Cleaning

    @Test func cleanedRemovesControlAndDirectionCharacters() {
        #expect(LookupText.cleaned("A\u{202E}B\u{01}C\u{2066}D\u{2069}\u{7F}\u{9B}E", limit: 200) == "ABCDE")
        // Marks that belong in right-to-left text are kept.
        #expect(LookupText.cleaned("שלום\u{200F} עולם", limit: 200) == "שלום\u{200F} עולם")
        #expect(LookupText.cleaned("\u{01}\u{202E}", limit: 200) == nil)
        #expect(LookupText.cleaned("   ", limit: 200) == nil)
        #expect(LookupText.cleaned(nil, limit: 200) == nil)
    }

    @Test func cleanedPutsAOneLineValueOnOneLine() {
        #expect(LookupText.cleaned("  The\tSalt\r\nRoad \n\n again\u{2028}now  ", limit: 200) == "The Salt Road again now")
        #expect(LookupText.cleaned("a  b", limit: 200) == "a b")
    }

    @Test func cleanedKeepsTheLinesOfADescription() {
        #expect(LookupText.cleaned(" One\r\n\r\nTwo\tthree\u{01}\u{2029}Four ", limit: 200, multiline: true) == "One\n\nTwo three\nFour")
    }

    @Test func cleanedKeepsNoMoreThanTheLimit() {
        #expect(LookupText.cleaned(String(repeating: "a", count: 1000), limit: 500)?.count == 500)
        #expect(LookupText.cleaned("abc def", limit: 4) == "abc")
        #expect(LookupText.cleaned(String(repeating: "éa", count: 100_000), limit: 50_000, multiline: true)?.count == 50_000)
        // Hostile length costs little: what is past the limit is hardly read.
        let clock = ContinuousClock()
        let huge = String(repeating: "\u{01}x ", count: 2_000_000)
        #expect(clock.measure { _ = LookupText.cleaned(huge, limit: 200) } < .seconds(20))
    }

    @Test func cleanedNamesDropsEmptyOnesAndKeepsFifty() {
        #expect(LookupText.cleanedNames([" A\nB ", "\u{01}", "", "C"]) == ["A B", "C"])
        #expect(LookupText.cleanedNames((1...80).map { "N\($0)" }).count == 50)
    }

    @Test func yearsOutsideOneToNineThousandNineHundredNinetyNineAreNoYear() {
        #expect(LookupText.year(1984) == 1984)
        #expect(LookupText.year(1) == 1)
        #expect(LookupText.year(9999) == 9999)
        #expect(LookupText.year(0) == nil)
        #expect(LookupText.year(-44) == nil)
        #expect(LookupText.year(10_000) == nil)
        #expect(LookupText.year(123_456_789) == nil)
        #expect(LookupText.year(nil) == nil)
    }

    // T3
    @Test(arguments: [
        ("en", "English", "eng", "eng"), ("fr", "French", "fre", "fra"), ("de", "German", "ger", "deu"),
        ("es", "Spanish", "spa", "spa"), ("it", "Italian", "ita", "ita"), ("pt", "Portuguese", "por", "por"),
        ("nl", "Dutch", "dut", "nld"), ("sv", "Swedish", "swe", "swe"), ("da", "Danish", "dan", "dan"),
        ("no", "Norwegian", "nor", "nor"), ("fi", "Finnish", "fin", "fin"), ("pl", "Polish", "pol", "pol"),
        ("ru", "Russian", "rus", "rus"), ("ja", "Japanese", "jpn", "jpn"), ("zh", "Chinese", "chi", "zho"),
        ("ko", "Korean", "kor", "kor"), ("tr", "Turkish", "tur", "tur"), ("ar", "Arabic", "ara", "ara"),
        ("hi", "Hindi", "hin", "hin"),
    ])
    func T3_languageFamilies(code: String, name: String, bibliographic: String, terminologic: String) {
        #expect(LookupText.languageCode(code) == code)
        #expect(LookupText.languageCode(code.uppercased()) == code)
        #expect(LookupText.languageCode(name) == code)
        #expect(LookupText.languageCode(name.lowercased()) == code)
        #expect(LookupText.languageCode(name.uppercased()) == code)
        #expect(LookupText.languageCode(bibliographic) == code)
        #expect(LookupText.languageCode(terminologic.uppercased()) == code)
        #expect(LookupText.languageCode("\(code)-XX") == code)
        #expect(LookupText.languageCode(" \(code)_xx ") == code)
    }

    @Test func T3_examplesAndUnknowns() {
        #expect(LookupText.languageCode("english") == "en")
        #expect(LookupText.languageCode("eng") == "en")
        #expect(LookupText.languageCode("en-GB") == "en")
        #expect(LookupText.languageCode("EN") == "en")
        #expect(LookupText.languageCode("pt-BR") == "pt")
        #expect(LookupText.languageCode("") == nil)
        #expect(LookupText.languageCode("klingonese") == nil)
        #expect(LookupText.languageCode("zz") == nil)
        #expect(LookupText.languageCode("qqq") == nil)
        #expect(LookupText.languageCode("e") == nil)
        #expect(LookupText.languageCode("12") == nil)
    }

    // T4
    @Test func T4_isbnTidying() {
        #expect(LookupText.isbn("978-0-593-13520-4") == "9780593135204")
        #expect(LookupText.isbn(" 0 593 13520 2 ") == "0593135202")
        #expect(LookupText.isbn("147358258x") == "147358258X")
        #expect(LookupText.isbn("1-4735-8258-X") == "147358258X")
        #expect(LookupText.isbn("9780593135204") == "9780593135204")
    }

    @Test func T4_isbnRefusals() {
        #expect(LookupText.isbn("") == nil)
        #expect(LookupText.isbn("12345") == nil)
        #expect(LookupText.isbn("97805931352041") == nil)       // 14
        #expect(LookupText.isbn("05931352021") == nil)          // 11
        #expect(LookupText.isbn("ISBN 9780593135204") == nil)   // other letters
        #expect(LookupText.isbn("9780593135204&x=1") == nil)
        #expect(LookupText.isbn("978059313520X") == nil)        // X only ends a 10-character ISBN
        #expect(LookupText.isbn("0X93135202") == nil)           // X not at the end
        #expect(LookupText.isbn("B08G9PRS1K") == nil)
        #expect(LookupText.isbn("٠٥٩٣١٣٥٢٠٢") == nil)            // not ASCII digits
    }

    // T5
    @Test func T5_exactBeatsPrefixBeatsUnrelated() {
        let query = LookupQuery(title: "Dune", author: "Frank Herbert")
        let exact = LookupText.matchScore(title: "Dune", author: "Frank Herbert", query: query)
        let prefix = LookupText.matchScore(title: "Dune Messiah", author: "Frank Herbert", query: query)
        let boxSet = LookupText.matchScore(title: "Dune: The Complete Saga", author: "Frank Herbert", query: query)
        let unrelated = LookupText.matchScore(title: "Project Hail Mary", author: "Andy Weir", query: query)
        #expect(exact == 1)
        #expect(exact - prefix >= 0.2)
        #expect(exact - boxSet >= 0.2)
        #expect(prefix > unrelated)
        #expect(unrelated >= 0)
        #expect(unrelated < 0.2)
    }

    @Test func T5_rightAuthorBeatsWrongAuthor() {
        let query = LookupQuery(title: "Dune", author: "Frank Herbert")
        let right = LookupText.matchScore(title: "Dune", author: "Frank Herbert", query: query)
        let reordered = LookupText.matchScore(title: "Dune", author: "Herbert, Frank", query: query)
        let wrong = LookupText.matchScore(title: "Dune", author: "Brian Aldiss", query: query)
        let none = LookupText.matchScore(title: "Dune", author: "", query: query)
        #expect(right == 1)
        #expect(reordered == 1)
        #expect(right > wrong)
        #expect(right > none)
        // An exact title by the wrong author is still nearer than a different book by the right one.
        #expect(wrong > LookupText.matchScore(title: "Dune Messiah", author: "Frank Herbert", query: query))
    }

    @Test func T5_emptyAskedAuthorIsNotHeldAgainstTheCandidate() {
        let query = LookupQuery(title: "Dune")
        #expect(LookupText.matchScore(title: "Dune", author: "Frank Herbert", query: query) == 1)
        #expect(LookupText.matchScore(title: "Dune", author: "", query: query) == 1)
        // And with only an author asked for, the title is not held against it either.
        let byAuthor = LookupQuery(author: "Frank Herbert")
        #expect(LookupText.matchScore(title: "Anything", author: "Frank Herbert", query: byAuthor) == 1)
        #expect(LookupText.matchScore(title: "Anything", author: "Someone Else", query: byAuthor) < 1)
    }

    @Test func T5_ignoresCaseAccentsPunctuationAndLeadingArticles() {
        let query = LookupQuery(title: "the way of kings", author: "brandon sanderson")
        #expect(LookupText.matchScore(title: "The Way of Kings", author: "Brandon Sanderson", query: query) == 1)
        #expect(LookupText.matchScore(title: "Way of Kings!", author: "Brandon  Sanderson.", query: query) == 1)
        let accents = LookupQuery(title: "Les Miserables", author: "Emile Zola")
        #expect(LookupText.matchScore(title: "Les Misérables", author: "Émile Zola", query: accents) == 1)
        #expect(LookupText.matchScore(title: "A Game of Thrones", author: "", query: LookupQuery(title: "Game of Thrones")) == 1)
        #expect(LookupText.matchScore(title: "An Instance of the Fingerpost", author: "", query: LookupQuery(title: "Instance of the Fingerpost")) == 1)
        #expect(LookupText.matchScore(title: "Ender’s Game", author: "", query: LookupQuery(title: "Enders Game")) == 1)
        // A title that is only an article is left alone.
        #expect(LookupText.matchScore(title: "A", author: "", query: LookupQuery(title: "A")) == 1)
    }

    @Test func T5_deterministicAndInRange() {
        let query = LookupQuery(title: "Project Hail Mary", author: "Andy Weir")
        let samples = [("Project Hail Mary", "Andy Weir"), ("The Martian / Artemis / Project Hail Mary", "Andy Weir"),
                       ("Proyecto Hail Mary", "Andy Weir"), ("", ""), ("Exoplanet", "Someone")]
        for (title, author) in samples {
            let first = LookupText.matchScore(title: title, author: author, query: query)
            #expect(first == LookupText.matchScore(title: title, author: author, query: query))
            #expect((0...1).contains(first))
        }
        // Monotonic: more of the asked title's words in common never scores lower.
        let two = LookupText.matchScore(title: "Hail Mary Pass", author: "Andy Weir", query: query)
        let one = LookupText.matchScore(title: "Mary Poppins Returns", author: "Andy Weir", query: query)
        let zero = LookupText.matchScore(title: "Exoplanet", author: "Andy Weir", query: query)
        #expect(two >= one)
        #expect(one >= zero)
    }
}

/// Answers requests inside the process, so `URLSessionFetcher` is exercised with no network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Answer {
        case respond(status: Int, headers: [String: String], body: Data)
        case fail(URLError.Code)
        case redirect(to: URL)
        case notHTTP
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: Answer] = [:]
    nonisolated(unsafe) private static var seen: [String: [URLRequest]] = [:]

    /// Answers are keyed by host so tests running side by side do not meet.
    static func set(_ answer: Answer, forHost host: String) {
        lock.withLock { answers[host] = answer }
    }

    static func requests(forHost host: String) -> [URLRequest] {
        lock.withLock { seen[host] ?? [] }
    }

    /// For tests that must ask one real host name: answers keyed by the path asked for.
    static func set(_ answer: Answer, forPath path: String) {
        lock.withLock { answers["path:" + path] = answer }
    }

    static func requests(forPath path: String) -> [URLRequest] {
        lock.withLock { seen["path:" + path] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let host = request.url?.host ?? ""
        let path = "path:" + (request.url?.path ?? "")
        let answer = Self.lock.withLock { () -> Answer? in
            Self.seen[host, default: []].append(request)
            Self.seen[path, default: []].append(request)
            return Self.answers[host] ?? Self.answers[path]
        }
        guard let url = request.url, let answer else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch answer {
        case .respond(let status, let headers, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .redirect(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        case .notHTTP:
            let response = URLResponse(url: url, mimeType: "text/plain", expectedContentLength: 0, textEncodingName: nil)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

@Suite struct URLSessionFetcherTests {
    private func fetcher() -> URLSessionFetcher {
        URLSessionFetcher(timeout: 60, protocolClasses: [StubURLProtocol.self])
    }

    // T1
    @Test func T1_sendsTheGivenHeadersAndReturnsBodyAndStatus() async throws {
        let host = "headers.stub.test"
        StubURLProtocol.set(.respond(status: 200, headers: ["Set-Cookie": "id=1; Path=/"], body: Data("hello".utf8)), forHost: host)
        let url = try #require(URL(string: "https://\(host)/a?b=c"))
        let fetcher = fetcher()
        let answer = try await fetcher.get(url, headers: ["User-Agent": "VoxCarrel/test", "Accept": "application/json"], maxBytes: 1000, redirectHosts: [])
        #expect(answer.status == 200)
        #expect(answer.data == Data("hello".utf8))
        let request = try #require(StubURLProtocol.requests(forHost: host).first)
        #expect(request.url == url)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "VoxCarrel/test")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")

        // No cookies: one set by an answer is not sent back on the next request.
        _ = try await fetcher.get(url, headers: [:], maxBytes: 1000, redirectHosts: [])
        let second = try #require(StubURLProtocol.requests(forHost: host).last)
        #expect(second.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(StubURLProtocol.requests(forHost: host).count == 2)
    }

    @Test func T1_anErrorStatusIsReturnedNotThrown() async throws {
        let host = "status.stub.test"
        StubURLProtocol.set(.respond(status: 503, headers: [:], body: Data()), forHost: host)
        let answer = try await fetcher().get(try #require(URL(string: "https://\(host)/")), headers: [:], maxBytes: 1000, redirectHosts: [])
        #expect(answer.status == 503)
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost,
                      .networkConnectionLost, .dnsLookupFailed, .secureConnectionFailed, .badServerResponse])
    func T1_connectionFailuresBecomeNotReachable(code: URLError.Code) async throws {
        let host = "fail\(code.rawValue).stub.test"
        StubURLProtocol.set(.fail(code), forHost: host)
        let url = try #require(URL(string: "https://\(host)/"))
        await #expect(throws: LookupError.notReachable) {
            _ = try await fetcher().get(url, headers: [:], maxBytes: 1000, redirectHosts: [])
        }
    }

    @Test func T1_errorMappingNeverLetsAURLErrorThrough() {
        #expect(URLSessionFetcher.mapped(URLError(.timedOut)) as? LookupError == .notReachable)
        #expect(URLSessionFetcher.mapped(URLError(.notConnectedToInternet)) as? LookupError == .notReachable)
        #expect(URLSessionFetcher.mapped(CocoaError(.fileReadUnknown)) as? LookupError == .notReachable)
        #expect(URLSessionFetcher.mapped(LookupError.unreadable) as? LookupError == .unreadable)
        // S7: a cancelled request reads as cancellation, not as a failed source.
        #expect(URLSessionFetcher.mapped(URLError(.cancelled)) is CancellationError)
        #expect(URLSessionFetcher.mapped(CancellationError()) is CancellationError)
    }

    @Test func T1_aRefusedConnectionIsNotReachable() async throws {
        // What the system says when nothing listens at the address; no socket is opened here.
        let host = "refusedconnection.stub.test"
        StubURLProtocol.set(.fail(.cannotConnectToHost), forHost: host)
        let url = try #require(URL(string: "https://\(host)/"))
        await #expect(throws: LookupError.notReachable) {
            _ = try await fetcher().get(url, headers: [:], maxBytes: 1000, redirectHosts: [])
        }
        #expect(StubURLProtocol.requests(forHost: host).count == 1)
    }

    @Test func T1_anAnswerThatIsNotHTTPIsUnreadable() async throws {
        let host = "nothttp.stub.test"
        StubURLProtocol.set(.notHTTP, forHost: host)
        let url = try #require(URL(string: "https://\(host)/"))
        await #expect(throws: LookupError.unreadable) {
            _ = try await fetcher().get(url, headers: [:], maxBytes: 1000, redirectHosts: [])
        }
    }

    @Test func T1_followsARedirectToAnAllowedHost() async throws {
        let from = "from.stub.test", to = "to.stub.test"
        let target = try #require(URL(string: "https://\(to)/final"))
        StubURLProtocol.set(.redirect(to: target), forHost: from)
        StubURLProtocol.set(.respond(status: 200, headers: [:], body: Data("arrived".utf8)), forHost: to)
        let answer = try await fetcher().get(
            try #require(URL(string: "https://\(from)/start")), headers: ["User-Agent": "VoxCarrel/test"],
            maxBytes: 1000, redirectHosts: ["elsewhere.test", to])
        #expect(answer.status == 200)
        #expect(answer.data == Data("arrived".utf8))
        #expect(StubURLProtocol.requests(forHost: to).count == 1)
    }

    @Test func T1_followsARedirectToASubdomainOfAnAllowedHost() async throws {
        let from = "covers.stub.test", to = "ia800.us.archive.stub.test"
        let target = try #require(URL(string: "https://\(to)/final"))
        StubURLProtocol.set(.redirect(to: target), forHost: from)
        StubURLProtocol.set(.respond(status: 200, headers: [:], body: Data("arrived".utf8)), forHost: to)
        let answer = try await fetcher().get(
            try #require(URL(string: "https://\(from)/start")), headers: [:], maxBytes: 1000,
            redirectHosts: ["archive.stub.test"])
        #expect(answer.data == Data("arrived".utf8))
    }

    /// A redirect to a host that was not allowed is not followed: nothing is asked of that host.
    @Test func T1_aRedirectAnywhereElseIsRefusedWithoutFollowing() async throws {
        let from = "leaving.stub.test", to = "notallowed.stub.test"
        let target = try #require(URL(string: "https://\(to)/final"))
        StubURLProtocol.set(.redirect(to: target), forHost: from)
        StubURLProtocol.set(.respond(status: 200, headers: [:], body: Data("arrived".utf8)), forHost: to)
        await #expect(throws: LookupError.refused(status: 302)) {
            _ = try await fetcher().get(
                try #require(URL(string: "https://\(from)/start")), headers: [:], maxBytes: 1000,
                redirectHosts: [from, "allowed.stub.test", "d.stub.test"])
        }
        #expect(StubURLProtocol.requests(forHost: to).isEmpty)
    }

    /// Nor is one that leaves `https`, even to an allowed host.
    @Test func T1_aRedirectToPlainHTTPIsRefused() async throws {
        let from = "downgrade.stub.test", to = "plain.stub.test"
        let target = try #require(URL(string: "http://\(to)/final"))
        StubURLProtocol.set(.redirect(to: target), forHost: from)
        StubURLProtocol.set(.respond(status: 200, headers: [:], body: Data("arrived".utf8)), forHost: to)
        await #expect(throws: LookupError.refused(status: 302)) {
            _ = try await fetcher().get(
                try #require(URL(string: "https://\(from)/start")), headers: [:], maxBytes: 1000, redirectHosts: [to])
        }
        #expect(StubURLProtocol.requests(forHost: to).isEmpty)
    }

    @Test func T1_redirectRules() throws {
        let hosts: Set<String> = ["archive.org", "m.media-amazon.com"]
        func may(_ address: String) -> Bool { URLSessionFetcher.mayRedirect(to: URL(string: address), hosts: hosts) }
        #expect(may("https://archive.org/x.jpg"))
        #expect(may("https://ia800100.us.archive.org/1/items/x.jpg"))
        #expect(may("https://M.Media-Amazon.com/x.jpg"))
        #expect(!may("http://archive.org/x.jpg"))
        #expect(!may("https://notarchive.org/x.jpg"))
        #expect(!may("https://archive.org.evil.test/x.jpg"))
        #expect(!may("https://evil.test/archive.org"))
        #expect(!may("file:///etc/passwd"))
        #expect(!URLSessionFetcher.mayRedirect(to: nil, hosts: hosts))
        #expect(!URLSessionFetcher.mayRedirect(to: URL(string: "https://archive.org/"), hosts: []))
    }

    // MARK: The one address asked without encryption

    private static let catalogue: Set<InsecureOrigin> = [.libraryOfCongress]

    /// The Library of Congress catalogue's address is the only one there is.
    @Test func T2_theOnlyExceptionIsTheLibraryOfCongressCatalogue() {
        #expect(InsecureOrigin.allowed == [InsecureOrigin(scheme: "http", host: "lx2.loc.gov", port: 210)])
        #expect(InsecureOrigin.libraryOfCongress == InsecureOrigin(scheme: "HTTP", host: "LX2.loc.gov", port: 210))
    }

    @Test func T2_theCatalogueIsAskedOverPlainHTTPWhenTheRequestNamesIt() async throws {
        let path = "/t2-asked"
        StubURLProtocol.set(.respond(status: 200, headers: [:], body: Data("records".utf8)), forPath: path)
        let url = try #require(URL(string: "http://lx2.loc.gov:210\(path)?query=x"))
        let answer = try await fetcher().get(url, headers: [:], maxBytes: 1000, redirectHosts: [], insecure: Self.catalogue)
        #expect(answer.status == 200)
        #expect(answer.data == Data("records".utf8))
        #expect(StubURLProtocol.requests(forPath: path).map(\.url) == [url])
    }

    /// The exception is the request's to name: without it the same address is not asked.
    @Test func T2_withoutTheExceptionNamedNothingIsSent() async throws {
        let path = "/t2-unnamed"
        StubURLProtocol.set(.respond(status: 200, headers: [:], body: Data()), forPath: path)
        let url = try #require(URL(string: "http://lx2.loc.gov:210\(path)"))
        await #expect(throws: LookupError.unreadable) {
            _ = try await fetcher().get(url, headers: [:], maxBytes: 1000, redirectHosts: [], insecure: [])
        }
        await #expect(throws: LookupError.unreadable) {
            _ = try await fetcher().get(url, headers: [:], maxBytes: 1000, redirectHosts: [])
        }
        #expect(StubURLProtocol.requests(forPath: path).isEmpty)
    }

    /// Plain http to any other host, to the catalogue's host on another port, or to a
    /// host that only looks like it, is refused without a request, whatever the request names.
    @Test(arguments: [
        "http://plain.stub.test/t2-a", "http://plain.stub.test:210/t2-b", "http://openlibrary.org/t2-c",
        "http://api.audible.com:210/t2-d",
        "http://lx2.loc.gov/t2-e", "http://lx2.loc.gov:80/t2-f", "http://lx2.loc.gov:211/t2-g", "http://lx2.loc.gov:2100/t2-h",
        "http://lx2.loc.gov:443/t2-i",
        "http://lx2.loc.gov.example.com:210/t2-j", "http://evil-lx2.loc.gov:210/t2-k", "http://loc.gov:210/t2-l",
        "http://www.lx2.loc.gov:210/t2-m", "http://lx2.loc.gov.:210/t2-n", "http://user@lx2.loc.gov:210/t2-o",
        "http://user:word@lx2.loc.gov:210/t2-p", "http://lx2.loc.gov@plain.stub.test:210/t2-q",
        "ftp://lx2.loc.gov:210/t2-r", "file:///t2-s",
    ])
    func T2_plainHTTPAnywhereElseIsRefusedWithoutARequest(address: String) async throws {
        let url = try #require(URL(string: address))
        StubURLProtocol.set(.respond(status: 200, headers: [:], body: Data("arrived".utf8)), forPath: url.path)
        // Named by the request or not, and named with an exception of the request's own making.
        var own: Set<InsecureOrigin> = Self.catalogue
        if let scheme = url.scheme, let host = url.host {
            own.insert(InsecureOrigin(scheme: scheme, host: host, port: url.port ?? 80))
        }
        for insecure in [[], Self.catalogue, own] {
            await #expect(throws: LookupError.unreadable) {
                _ = try await fetcher().get(url, headers: [:], maxBytes: 1000, redirectHosts: [], insecure: insecure)
            }
        }
        #expect(StubURLProtocol.requests(forPath: url.path).isEmpty)
    }

    /// Every other host is still asked over https as before, exception named or not.
    @Test func T2_httpsIsUntouchedByTheException() async throws {
        let host = "secure-t2.stub.test"
        StubURLProtocol.set(.respond(status: 200, headers: [:], body: Data("ok".utf8)), forHost: host)
        let url = try #require(URL(string: "https://\(host)/"))
        let answer = try await fetcher().get(url, headers: [:], maxBytes: 1000, redirectHosts: [], insecure: Self.catalogue)
        #expect(answer.data == Data("ok".utf8))
    }

    @Test func T2_requestRules() throws {
        func may(_ address: String, _ insecure: Set<InsecureOrigin> = Self.catalogue) throws -> Bool {
            URLSessionFetcher.mayRequest(try #require(URL(string: address)), insecure: insecure)
        }
        #expect(try may("http://lx2.loc.gov:210/lcdb?version=1.1"))
        #expect(try may("HTTP://LX2.LOC.GOV:210/lcdb"))
        #expect(try may("https://lx2.loc.gov/lcdb", []))
        #expect(try may("https://anything.example/", []))
        #expect(try !may("http://lx2.loc.gov:210/lcdb", []))
        #expect(try !may("http://lx2.loc.gov/lcdb"))
        #expect(try !may("http://lx2.loc.gov:8210/lcdb"))
        #expect(try !may("http://lx2.loc.gov.example.com:210/lcdb"))
        #expect(try !may("http://evil-lx2.loc.gov:210/lcdb"))
        #expect(try !may("http://example.com:210/lcdb", [InsecureOrigin(scheme: "http", host: "example.com", port: 210)]))
        #expect(try !may("lcdb"))
    }

    /// A body that says it is longer than is wanted is not read.
    @Test func T1_aBodyDeclaredTooLongIsUnreadable() async throws {
        let host = "declared.stub.test"
        StubURLProtocol.set(.respond(status: 200, headers: ["Content-Length": "5000"], body: Data(count: 5000)), forHost: host)
        let url = try #require(URL(string: "https://\(host)/"))
        await #expect(throws: LookupError.unreadable) {
            _ = try await fetcher().get(url, headers: [:], maxBytes: 4999, redirectHosts: [])
        }
    }

    /// One that does not say, or says less than it sends, is given up on at the limit.
    @Test func T1_aBodyLongerThanTheLimitIsUnreadable() async throws {
        let host = "undeclared.stub.test"
        StubURLProtocol.set(.respond(status: 200, headers: [:], body: Data(count: 20_000)), forHost: host)
        let url = try #require(URL(string: "https://\(host)/"))
        await #expect(throws: LookupError.unreadable) {
            _ = try await fetcher().get(url, headers: [:], maxBytes: 19_999, redirectHosts: [])
        }
        // Exactly the limit is fine.
        let answer = try await fetcher().get(url, headers: [:], maxBytes: 20_000, redirectHosts: [])
        #expect(answer.data.count == 20_000)
    }

    @Test func T1_sessionIsEphemeralWithNoCookiesAndNoCache() {
        let configuration = URLSessionFetcher.configuration(timeout: 7)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.timeoutIntervalForRequest == 7)
    }
}
