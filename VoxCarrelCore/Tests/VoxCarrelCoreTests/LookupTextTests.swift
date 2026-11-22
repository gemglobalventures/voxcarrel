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
    @Test func T2_realAudibleSummaryBecomesParagraphs() throws {
        let json = try #require(try JSONSerialization.jsonObject(with: fixture("au-search")) as? [String: Any])
        let products = try #require(json["products"] as? [[String: Any]])
        let html = try #require(products[0]["publisher_summary"] as? String)
        let text = LookupText.plainText(fromHTML: html)
        #expect(!text.contains("<"))
        #expect(!text.contains(">"))
        #expect(!text.contains("  "))
        #expect(!text.contains("\n\n\n"))
        let paragraphs = text.components(separatedBy: "\n\n")
        #expect(paragraphs.count == 12)
        #expect(paragraphs.first?.hasPrefix("A demonstration summary") == true)
        #expect(paragraphs.contains("A placeholder sentence."))
        #expect(paragraphs.last?.hasPrefix("PLEASE NOTE: To accommodate this audio edition") == true)
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

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let host = request.url?.host ?? ""
        let answer = Self.lock.withLock { () -> Answer? in
            Self.seen[host, default: []].append(request)
            return Self.answers[host]
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
        URLSessionFetcher(timeout: 5, protocolClasses: [StubURLProtocol.self])
    }

    // T1
    @Test func T1_sendsTheGivenHeadersAndReturnsBodyAndStatus() async throws {
        let host = "headers.stub.test"
        StubURLProtocol.set(.respond(status: 200, headers: ["Set-Cookie": "id=1; Path=/"], body: Data("hello".utf8)), forHost: host)
        let url = try #require(URL(string: "https://\(host)/a?b=c"))
        let fetcher = fetcher()
        let answer = try await fetcher.get(url, headers: ["User-Agent": "VoxCarrel/test", "Accept": "application/json"])
        #expect(answer.status == 200)
        #expect(answer.data == Data("hello".utf8))
        let request = try #require(StubURLProtocol.requests(forHost: host).first)
        #expect(request.url == url)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "VoxCarrel/test")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")

        // No cookies: one set by an answer is not sent back on the next request.
        _ = try await fetcher.get(url, headers: [:])
        let second = try #require(StubURLProtocol.requests(forHost: host).last)
        #expect(second.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(StubURLProtocol.requests(forHost: host).count == 2)
    }

    @Test func T1_anErrorStatusIsReturnedNotThrown() async throws {
        let host = "status.stub.test"
        StubURLProtocol.set(.respond(status: 503, headers: [:], body: Data()), forHost: host)
        let answer = try await fetcher().get(try #require(URL(string: "https://\(host)/")), headers: [:])
        #expect(answer.status == 503)
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost,
                      .networkConnectionLost, .dnsLookupFailed, .secureConnectionFailed, .badServerResponse])
    func T1_connectionFailuresBecomeNotReachable(code: URLError.Code) async throws {
        let host = "fail\(code.rawValue).stub.test"
        StubURLProtocol.set(.fail(code), forHost: host)
        let url = try #require(URL(string: "https://\(host)/"))
        await #expect(throws: LookupError.notReachable) {
            _ = try await fetcher().get(url, headers: [:])
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

    @Test func T1_aRealRefusedConnectionIsNotReachable() async throws {
        // Nothing listens on this machine's port 1; the request never leaves it.
        let url = try #require(URL(string: "http://127.0.0.1:1/"))
        await #expect(throws: LookupError.notReachable) {
            _ = try await URLSessionFetcher(timeout: 5).get(url, headers: [:])
        }
    }

    @Test func T1_anAnswerThatIsNotHTTPIsUnreadable() async throws {
        let host = "nothttp.stub.test"
        StubURLProtocol.set(.notHTTP, forHost: host)
        let url = try #require(URL(string: "https://\(host)/"))
        await #expect(throws: LookupError.unreadable) {
            _ = try await fetcher().get(url, headers: [:])
        }
    }

    @Test func T1_followsRedirects() async throws {
        let from = "from.stub.test", to = "to.stub.test"
        let target = try #require(URL(string: "https://\(to)/final"))
        StubURLProtocol.set(.redirect(to: target), forHost: from)
        StubURLProtocol.set(.respond(status: 200, headers: [:], body: Data("arrived".utf8)), forHost: to)
        let answer = try await fetcher().get(try #require(URL(string: "https://\(from)/start")), headers: ["User-Agent": "VoxCarrel/test"])
        #expect(answer.status == 200)
        #expect(answer.data == Data("arrived".utf8))
        #expect(StubURLProtocol.requests(forHost: to).count == 1)
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
