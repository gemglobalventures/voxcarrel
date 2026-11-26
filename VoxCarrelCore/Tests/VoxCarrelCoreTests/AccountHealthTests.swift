import Foundation
import Testing
@testable import VoxCarrelCore

/// AH1–AH6: what a reading of an Audible or Kindle library does when Amazon does not
/// answer as it should, and the check that says whether a link still works.
@Suite struct AccountHealthTests {
    typealias F = LibraryFixture
    typealias FakeTransport = AudibleLibraryTests.FakeTransport

    private static func audiblePage(_ n: Int) -> String {
        "/1.0/library?num_results=50&page=\(n)&response_groups=\(AudibleLibraryReader.groups)"
    }

    private static func fullAudiblePage() throws -> (Data, Int) {
        let items = (0..<50).map { ["asin": "B\(1000 + $0)", "title": "Book \($0)"] }
        return (try JSONSerialization.data(withJSONObject: ["items": items]), 200)
    }

    // AH1: Audible saying "not now" is told from a refusal and from an answer that
    // cannot be understood.
    @Test func AH1_audibleSayingNotNowIsNotARefusal() async throws {
        let account = AudibleLibraryTests.account()
        for (status, expected) in [
            (429, AudibleAccountError.busy(429)), (500, .busy(500)), (503, .busy(503)), (401, .refused(401)),
            (403, .refused(403)), (404, .unreadable), (302, .unreadable),
        ] {
            let transport = FakeTransport()
            transport.answers[Self.audiblePage(1)] = (Data("<html>later</html>".utf8), status)
            await #expect(throws: expected) { _ = try await AudibleLibraryReader.books(of: account, transport: transport) }
        }
        // Answered, but not with a library: a page of HTML, half a page of JSON, another shape.
        for body in ["<html>Sign in</html>", "{\"items\": [", "{\"books\": []}", "[]", ""] {
            let transport = FakeTransport()
            transport.answers[Self.audiblePage(1)] = (Data(body.utf8), 200)
            await #expect(throws: AudibleAccountError.unreadable) {
                _ = try await AudibleLibraryReader.books(of: account, transport: transport)
            }
        }
    }

    // AH2: a reading cut short part way gives no books at all: half a library is never
    // taken for the whole of it.
    @Test func AH2_aReadingCutShortGivesNothing() async throws {
        let account = AudibleLibraryTests.account()
        for (answer, expected) in [
            ((Data("{}".utf8), 503), AudibleAccountError.busy(503)), ((Data("{}".utf8), 401), .refused(401)),
            ((Data("{\"items\": [{\"asin\"".utf8), 200), .unreadable),
        ] {
            let transport = FakeTransport()
            transport.answers[Self.audiblePage(1)] = try Self.fullAudiblePage()
            transport.answers[Self.audiblePage(2)] = answer
            await #expect(throws: expected) { _ = try await AudibleLibraryReader.books(of: account, transport: transport) }
            #expect(transport.asked.count == 2)
        }
        // The same for Kindle: the second page fails.
        let kindle = FakeTransport()
        try KindleLibraryTests.session(kindle)
        kindle.answers[KindleLibraryTests.search] = try KindleLibraryTests.page(
            [KindleLibraryTests.item("B1", "One")], next: "next page")
        kindle.answers[KindleLibraryTests.search + "&paginationToken=next%20page"] = (Data(), 500)
        await #expect(throws: AudibleAccountError.busy(500)) { _ = try await KindleLibraryReader.books(of: account, transport: kindle) }
    }

    // AH3: Kindle saying "not now", at the session or at the reader.
    @Test func AH3_amazonSayingNotNowForKindleIsNotARefusal() async throws {
        let account = AudibleLibraryTests.account()
        let session = FakeTransport()
        session.answers["/ap/exchangetoken/cookies"] = (Data(), 503)
        await #expect(throws: AudibleAccountError.busy(503)) { _ = try await KindleLibraryReader.books(of: account, transport: session) }
        let limited = FakeTransport()
        limited.answers["/ap/exchangetoken/cookies"] = (Data(), 429)
        await #expect(throws: AudibleAccountError.busy(429)) { _ = try await KindleLibraryReader.books(of: account, transport: limited) }
        let reader = FakeTransport()
        try KindleLibraryTests.session(reader)
        reader.answers[KindleLibraryTests.search] = (Data(), 502)
        await #expect(throws: AudibleAccountError.busy(502)) { _ = try await KindleLibraryReader.books(of: account, transport: reader) }
        // A session answered in a shape this code does not know.
        let odd = FakeTransport()
        odd.answers["/ap/exchangetoken/cookies"] = (Data("{\"response\": {}}".utf8), 200)
        await #expect(throws: AudibleAccountError.unreadable) { _ = try await KindleLibraryReader.books(of: account, transport: odd) }
    }

    // AH4: the Audible check asks for one book, signed, and says what a reading would.
    @Test func AH4_theAudibleCheckAsksForOneBook() async throws {
        let account = AudibleLibraryTests.account(.uk)
        let good = FakeTransport()
        good.answers["/1.0/library?num_results=1&page=1"] = (Data("{\"items\": []}".utf8), 200)
        try await AudibleLibraryReader.check(account, transport: good)
        #expect(good.asked.count == 1 && good.asked[0].url?.host == "api.audible.co.uk" && good.asked[0].httpMethod == "GET")
        #expect(good.asked[0].value(forHTTPHeaderField: "x-adp-signature") != nil)

        for (answer, expected) in [
            ((Data("{}".utf8), 403), AudibleAccountError.refused(403)), ((Data(), 503), .busy(503)),
            ((Data("<html>".utf8), 200), .unreadable),
        ] {
            let transport = FakeTransport()
            transport.answers["/1.0/library?num_results=1&page=1"] = answer
            await #expect(throws: expected) { try await AudibleLibraryReader.check(account, transport: transport) }
        }
        let down = FakeTransport()
        down.fails = true
        await #expect(throws: AudibleAccountError.notReachable) { try await AudibleLibraryReader.check(account, transport: down) }
    }

    // AH5: the Kindle check asks for a session and one book, of the account's own store only.
    @Test func AH5_theKindleCheckAsksForASessionAndOneBook() async throws {
        let account = AudibleLibraryTests.account()
        let one = "/kindle-library/search?query=&libraryType=BOOKS&sortType=recency&querySize=1"
        let good = FakeTransport()
        try KindleLibraryTests.session(good)
        good.answers[one] = try KindleLibraryTests.page([])
        try await KindleLibraryReader.check(account, transport: good)
        #expect(good.asked.map { $0.url?.host } == ["www.amazon.com", "read.amazon.com"])

        let refused = FakeTransport()
        refused.answers["/ap/exchangetoken/cookies"] = (Data("{}".utf8), 400)
        await #expect(throws: AudibleAccountError.refused(400)) { try await KindleLibraryReader.check(account, transport: refused) }
        let turnedAway = FakeTransport()
        try KindleLibraryTests.session(turnedAway)
        turnedAway.answers[one] = (Data(), 302)
        await #expect(throws: AudibleAccountError.refused(302)) { try await KindleLibraryReader.check(account, transport: turnedAway) }
        let odd = FakeTransport()
        try KindleLibraryTests.session(odd)
        odd.answers[one] = (Data("{\"items\": []}".utf8), 200)
        await #expect(throws: AudibleAccountError.unreadable) { try await KindleLibraryReader.check(account, transport: odd) }
    }

    // AH6: bringing a library in again after it stopped part way finishes the job and
    // changes nothing twice.
    @Test func AH6_bringingInAgainFinishesWhatWasBegun() throws {
        let f = try F()
        let books = (1...6).map { n -> AudibleOwnedBook in
            var book = AudibleOwnedBook(asin: "B00\(n)", title: "Book \(n)")
            book.authors = ["Ann Author"]
            return book
        }
        // The first three got in before something stopped it.
        _ = try f.service.bringInAudibleLibrary(Array(books.prefix(3)), store: .us, apply: true)
        let before = try f.store.books()
        #expect(before.count == 3)
        let report = try f.service.bringInAudibleLibrary(books, store: .us, apply: true)
        #expect(report.added.count == 3 && report.alreadyThere == 3 && report.marked.isEmpty)
        let after = try f.store.books()
        #expect(after.count == 6)
        // What was there is exactly as it was.
        for book in before { #expect(after.first { $0.id == book.id } == book) }
        #expect(try f.service.bringInAudibleLibrary(books, store: .us, apply: true).changesNothing)
    }
}
