import Foundation
import Testing
@testable import VoxCarrelCore

/// KL1–KL7: reading an account's Kindle library from Amazon and bringing it in.
@Suite struct KindleLibraryTests {
    typealias F = LibraryFixture
    typealias FakeTransport = AudibleLibraryTests.FakeTransport

    static let search = "/kindle-library/search?query=&libraryType=BOOKS&sortType=recency&querySize=50"

    static func item(_ asin: String, _ title: String, authors: String = "Author, Ann:", kind: String = "EBOOK") -> [String: Any] {
        [
            "asin": asin, "title": title, "authors": [authors], "resourceType": kind, "originType": "PURCHASE",
            "percentageRead": 0, "productUrl": "https://m.media-amazon.com/images/I/\(asin).jpg",
            "webReaderUrl": "https://read.amazon.com/?asin=\(asin)", "mangaOrComicAsin": false,
        ]
    }

    static func session(_ transport: FakeTransport, cookies: [[String: Any]]? = nil) throws {
        let given = cookies ?? [["Name": "x-main", "Value": "\"abc?123\""], ["Name": "at-main", "Value": "Atza|tok+en="]]
        let answer: [String: Any] = ["response": ["tokens": ["cookies": [".amazon.com": given]]]]
        transport.answers["/ap/exchangetoken/cookies"] = (try JSONSerialization.data(withJSONObject: answer), 200)
    }

    static func page(_ items: [[String: Any]], next: String? = nil) throws -> (Data, Int) {
        var answer: [String: Any] = ["itemsList": items, "libraryType": "BOOKS", "sortType": "recency"]
        if let next { answer["paginationToken"] = next }
        return (try JSONSerialization.data(withJSONObject: answer), 200)
    }

    private func owned(_ asin: String, _ title: String, author: String = "Ann Author") -> KindleOwnedBook {
        var book = KindleOwnedBook(asin: asin, title: title)
        book.authors = [author]
        return book
    }

    @Test func KL1_anItemIsReadWithItsAuthorsTurnedRoundAndTheSeriesItsTitleNames() throws {
        let book = try #require(KindleLibraryReader.book(from: Self.item(
            "B00KINDLE1", "  Caliban's War (The Expanse Book 2) ", authors: "Corey, James S. A.:Abraham, Daniel:")))
        #expect(book.asin == "B00KINDLE1" && book.title == "Caliban's War" && book.series == "The Expanse" && book.seriesNumber == "2")
        #expect(book.authors == ["James S. A. Corey", "Daniel Abraham"])
        #expect(book.coverURL?.absoluteString == "https://m.media-amazon.com/images/I/B00KINDLE1.jpg")
        #expect(KindleLibraryReader.authors("Plato:") == ["Plato"] && KindleLibraryReader.authors("").isEmpty)
        // A title that ends any other way is left alone.
        for plain in ["Salt Roads: A History (English Edition)", "Book 2", "(Series Book 2)", "Title (Series Book)"] {
            let read = KindleLibraryReader.seriesNamed(in: plain)
            #expect(read.title == plain && read.series == nil && read.number == nil)
        }
        #expect(KindleLibraryReader.seriesNamed(in: "Low Tide (The Harbour Files, Book 14)").series == "The Harbour Files")
        // A sample is not a book that is owned; an item with no ID or title is nothing.
        #expect(KindleLibraryReader.book(from: Self.item("B2", "Taster", kind: "EBOOK_SAMPLE")) == nil)
        #expect(KindleLibraryReader.book(from: Self.item("", "No ID")) == nil)
        #expect(KindleLibraryReader.book(from: Self.item("B3", "  ")) == nil)
        // A cover address that is not encrypted is not kept.
        var open = Self.item("B4", "Open")
        open["productUrl"] = "http://m.media-amazon.com/images/I/x.jpg"
        #expect(KindleLibraryReader.book(from: open)?.coverURL == nil)
    }

    @Test func KL2_theLibraryIsReadPageByPageWithASessionAskedOfAmazonAndSentOnlyToItsReader() async throws {
        let transport = FakeTransport()
        try Self.session(transport)
        transport.answers[Self.search] = try Self.page([Self.item("B1", "One"), Self.item("B2", "Two")], next: "tok/2=")
        transport.answers[Self.search + "&paginationToken=tok%2F2%3D"] = try Self.page([Self.item("B2", "Two"), Self.item("B3", "Three")])
        let books = try await KindleLibraryReader.books(of: AudibleLibraryTests.account(.uk), transport: transport)
        #expect(books.map(\.asin) == ["B1", "B2", "B3"])

        #expect(transport.asked.count == 3)
        let exchange = transport.asked[0]
        #expect(exchange.url?.absoluteString == "https://www.amazon.co.uk/ap/exchangetoken/cookies" && exchange.httpMethod == "POST")
        let form = String(decoding: exchange.httpBody ?? Data(), as: UTF8.self)
        #expect(form.contains("source_token=refresh") && form.contains("requested_token_type=auth_cookies") && form.contains("domain=.amazon.co.uk"))
        // The device's other keys go nowhere, and no session is sent where it is asked for.
        #expect(!form.contains("access") && exchange.value(forHTTPHeaderField: "Cookie") == nil)
        for request in transport.asked.dropFirst() {
            #expect(request.url?.host == "read.amazon.co.uk" && request.url?.scheme == "https")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "at-main=Atza|tok+en=; x-main=\"abc?123\"")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        }
    }

    @Test func KL3_aRefreshKeyWithAPlusSignIsSentWhole() async throws {
        let transport = FakeTransport()
        try Self.session(transport)
        transport.answers[Self.search] = try Self.page([])
        var account = AudibleLibraryTests.account()
        account.refreshToken = "Atnr|a+b/c=&d"
        _ = try await KindleLibraryReader.books(of: account, transport: transport)
        let form = String(decoding: transport.asked[0].httpBody ?? Data(), as: UTF8.self)
        #expect(form.contains("source_token=Atnr%7Ca%2Bb/c%3D%26d") || form.contains("source_token=Atnr%7Ca%2Bb%2Fc%3D%26d"))
    }

    @Test func KL4_aRefusalIsSaidAsOneAndNothingStrangeGoesIntoTheSession() async throws {
        let account = AudibleLibraryTests.account()
        // Amazon will not give a session.
        let refused = FakeTransport()
        refused.answers["/ap/exchangetoken/cookies"] = (Data("{}".utf8), 401)
        await #expect(throws: AudibleAccountError.refused(401)) { try await KindleLibraryReader.books(of: account, transport: refused) }
        // The reader sends the session to its sign-in page.
        let turnedAway = FakeTransport()
        try Self.session(turnedAway)
        turnedAway.answers[Self.search] = (Data(), 302)
        await #expect(throws: AudibleAccountError.refused(302)) { try await KindleLibraryReader.books(of: account, transport: turnedAway) }
        // An answer that is not a library.
        let odd = FakeTransport()
        try Self.session(odd)
        odd.answers[Self.search] = (Data("<html>".utf8), 200)
        await #expect(throws: AudibleAccountError.unreadable) { try await KindleLibraryReader.books(of: account, transport: odd) }
        // No answer at all.
        let down = FakeTransport()
        down.fails = true
        await #expect(throws: AudibleAccountError.notReachable) { try await KindleLibraryReader.books(of: account, transport: down) }
        // A cookie that would end the header or begin another is left out.
        let sly = FakeTransport()
        try Self.session(sly, cookies: [
            ["Name": "good", "Value": "1"], ["Name": "bad", "Value": "1; other=2"], ["Name": "worse\r\nHost", "Value": "x"],
            ["Name": "", "Value": "x"], ["Name": "line", "Value": "a\nb"],
        ])
        sly.answers[Self.search] = try Self.page([])
        _ = try await KindleLibraryReader.books(of: account, transport: sly)
        #expect(sly.asked[1].value(forHTTPHeaderField: "Cookie") == "good=1")
        // None that can be used: refused, and the reader is never asked.
        let none = FakeTransport()
        try Self.session(none, cookies: [["Name": "bad", "Value": "1; other=2"]])
        await #expect(throws: AudibleAccountError.refused(200)) { try await KindleLibraryReader.books(of: account, transport: none) }
        #expect(none.asked.count == 1)
    }

    @Test func KL5_aPageThatNamesItselfAsTheNextEndsTheReading() async throws {
        let transport = FakeTransport()
        try Self.session(transport)
        transport.answers[Self.search] = try Self.page([Self.item("B1", "One")], next: "same")
        transport.answers[Self.search + "&paginationToken=same"] = try Self.page([Self.item("B2", "Two")], next: "same")
        let books = try await KindleLibraryReader.books(of: AudibleLibraryTests.account(), transport: transport)
        #expect(books.map(\.asin) == ["B1", "B2"] && transport.asked.count == 3)
    }

    @Test func KL6_booksTheLibraryLacksAreAddedAsOwnedOnKindleAndDoneAgainNothingChanges() throws {
        let f = try F()
        var second = owned("B00KINDLE2", "Caliban's War")
        second.series = "The Expanse"
        second.seriesNumber = "2"
        // Two editions of one title are two books.
        let books = [owned("B00KINDLE1", "Leviathan Wakes"), second, owned("B00KINDLE3", "Leviathan Wakes")]
        let preview = try f.service.bringInKindleLibrary(books, apply: false)
        #expect(preview.added == ["Leviathan Wakes", "Caliban's War", "Leviathan Wakes"] && preview.marked.isEmpty && !preview.changesNothing)
        #expect(try f.store.books().isEmpty)

        #expect(try f.service.bringInKindleLibrary(books, apply: true) == preview)
        let stored = try f.store.books(ownedOn: .kindle)
        #expect(stored.count == 3)
        let war = try #require(stored.first { $0.title == "Caliban's War" })
        #expect(war.series == "The Expanse" && war.seriesNumber == "2" && war.authors == ["Ann Author"] && war.folderPath == nil)
        #expect(war.externalCopies == [ExternalCopy(kind: .kindle, form: .ebook, itemId: "B00KINDLE2")])
        // A Kindle ID is not an Audible ID.
        #expect(war.asin == nil && war.readStatus == .unread)
        let again = try f.service.bringInKindleLibrary(books, apply: true)
        #expect(again.changesNothing && again.alreadyThere == 3)
        #expect(try f.store.books().count == 3)
    }

    @Test func KL7_aBookTheLibraryHasIsMarkedNotAddedByItsKindleIDOrItsTitleAndAuthor() throws {
        let f = try F()
        // One that came with highlights, known by its Kindle ID under another title.
        var highlighted = HighlightedBook(title: "Salt Roads", authors: ["Ines Calloway"], source: .readwise, highlights: [])
        highlighted.itemId = "B00KINDLE9"
        highlighted.ownedOn = .kindle
        var passage = IncomingHighlight(sourceId: "1", text: "Marked.")
        passage.location = 5
        highlighted.highlights = [passage]
        _ = try f.service.bringInHighlights([highlighted], apply: true)
        // One the library has under its own name, with an Audible ID and a rating.
        var mine = Book(metadata: BookMetadata(title: "Quiet Rivers", authors: ["Amara Okafor"]))
        mine.asin = "B0AUDIBLE1"
        mine.rating = 4
        let local = try f.store.insert(mine, files: [])
        let localId = try #require(local.id)

        let books = [owned("b00kindle9", "Salt Roads: A History", author: "Ines Calloway"), owned("B00KINDLE5", "Quiet Rivers", author: "Amara Okafor")]
        let preview = try f.service.bringInKindleLibrary(books, apply: false)
        #expect(preview.added.isEmpty && preview.marked == ["Quiet Rivers"] && preview.alreadyThere == 1)
        #expect(try f.service.bringInKindleLibrary(books, apply: true) == preview)
        #expect(try f.store.books().count == 2)
        let marked = try #require(try f.store.book(id: localId))
        #expect(marked.externalCopies == [ExternalCopy(kind: .kindle, form: .ebook, itemId: "B00KINDLE5")])
        #expect(marked.asin == "B0AUDIBLE1" && marked.title == "Quiet Rivers" && marked.rating == 4)
        #expect(try f.service.bringInKindleLibrary(books, apply: true).changesNothing)
    }
}
