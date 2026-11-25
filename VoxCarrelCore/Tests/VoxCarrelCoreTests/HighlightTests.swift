import Foundation
import Testing
@testable import VoxCarrelCore

/// HL1–HL16: highlights, where they come from, and how they reach a book.
@Suite struct HighlightTests {
    typealias F = LibraryFixture
    typealias FakeTransport = AudibleLibraryTests.FakeTransport

    static func readwiseHighlight(_ id: Int, _ text: String, location: Int? = nil, note: String = "", deleted: Bool = false) -> [String: Any] {
        var item: [String: Any] = [
            "id": id, "text": text, "note": note, "location_type": "location", "is_deleted": deleted,
            "highlighted_at": "2016-05-04T03:02:01Z", "color": "yellow", "is_favorite": false,
            "readwise_url": "https://readwise.io/open/\(id)", "tags": [["id": 1, "name": "idea"]],
        ]
        if let location { item["location"] = location }
        return item
    }

    static func readwiseBook(
        _ title: String, author: String, asin: String? = "B00KINDLE01", source: String = "kindle", category: String = "books",
        highlights: [[String: Any]]
    ) -> [String: Any] {
        var item: [String: Any] = [
            "user_book_id": 1, "title": title, "author": author, "category": category, "source": source,
            "cover_image_url": "https://m.media-amazon.com/images/I/x.jpg", "highlights": highlights, "is_deleted": false,
        ]
        if let asin { item["asin"] = asin }
        return item
    }

    @Test func HL1_aReadwiseBookIsReadWithItsHighlightsAndWhatIsNotABookIsLeftOut() throws {
        let book = try #require(ReadwiseReader.book(from: Self.readwiseBook(
            "Steve Jobs", author: "Walter Isaacson, Someone Else, and A Third", highlights: [
                Self.readwiseHighlight(11, "  Stay hungry.  ", location: 120, note: " mine "),
                Self.readwiseHighlight(12, "Gone", deleted: true),
                Self.readwiseHighlight(13, ""),
            ])))
        #expect(book.title == "Steve Jobs" && book.authors == ["Walter Isaacson", "Someone Else", "A Third"])
        #expect(book.itemId == "B00KINDLE01" && book.ownedOn == .kindle && book.source == .readwise)
        #expect(book.coverURL?.host == "m.media-amazon.com")
        #expect(book.highlights.map(\.sourceId) == ["11", "12"])
        let first = book.highlights[0]
        #expect(first.text == "Stay hungry." && first.note == "mine" && first.location == 120 && first.locationKind == .location)
        #expect(first.madeAt == Date(timeIntervalSince1970: 1_462_330_921) && first.colour == "yellow" && first.tags == ["idea"])
        #expect(first.link == "https://readwise.io/open/11" && !first.isDeleted && book.highlights[1].isDeleted)
        // Not from a Kindle: named, but owned nowhere the app knows.
        #expect(ReadwiseReader.book(from: Self.readwiseBook("Typed In", author: "A", source: "manual", highlights: []))?.ownedOn == nil)
        // Articles and the like are not books.
        #expect(ReadwiseReader.book(from: Self.readwiseBook("A Post", author: "A", category: "articles", highlights: [])) == nil)
        #expect(ReadwiseReader.authors("A and B") == ["A", "B"] && ReadwiseReader.authors(nil).isEmpty)
    }

    @Test func HL2_readwiseIsReadPageByPageWithTheTokenAndARefusalIsSaidAsOne() async throws {
        let transport = FakeTransport()
        let one: [String: Any] = ["results": [Self.readwiseBook("One", author: "A", highlights: [Self.readwiseHighlight(1, "x")])], "nextPageCursor": 77]
        let two: [String: Any] = ["results": [Self.readwiseBook("Two", author: "B", asin: "B2", highlights: [Self.readwiseHighlight(2, "y")])], "nextPageCursor": NSNull()]
        transport.answers["/api/v2/export"] = (try JSONSerialization.data(withJSONObject: one), 200)
        transport.answers["/api/v2/export?pageCursor=77"] = (try JSONSerialization.data(withJSONObject: two), 200)
        let books = try await ReadwiseReader.books(token: " tok123 \n", transport: transport)
        #expect(books.map(\.title) == ["One", "Two"])
        #expect(transport.asked.count == 2 && transport.asked.allSatisfy { $0.url?.host == "readwise.io" })
        #expect(transport.asked.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Token tok123" })

        transport.answers["/api/v2/export"] = (Data("{}".utf8), 401)
        await #expect(throws: ReadwiseError.refused) { _ = try await ReadwiseReader.books(token: "tok", transport: transport) }
        // A token that is no token is not sent anywhere.
        let before = transport.asked.count
        await #expect(throws: ReadwiseError.refused) { _ = try await ReadwiseReader.books(token: "  ", transport: transport) }
        #expect(transport.asked.count == before)
        // Asked to slow down, the app waits and asks again; for ever, it gives up.
        transport.answers["/api/v2/export"] = (Data("{}".utf8), 429)
        var waits = 0
        await #expect(throws: ReadwiseError.busy) {
            _ = try await ReadwiseReader.books(token: "tok", transport: transport) { _ in waits += 1 }
        }
        #expect(waits >= 3)
        transport.fails = true
        await #expect(throws: ReadwiseError.notReachable) { _ = try await ReadwiseReader.books(token: "tok", transport: transport) }
    }

    @Test func HL3_marksMadeWhileListeningAreHighlightsPlacedByTime() throws {
        let records: [[String: Any]] = [
            ["type": "audible.last_heard", "startPosition": "5000", "creationTime": "2026-11-25 07:50:22.0"],
            ["type": "audible.clip", "annotationId": "c1", "startPosition": "60895138", "endPosition": "60925138",
             "creationTime": "2026-09-18 10:21:35.0", "metadata": ["title": "", "note": "the turning point"]],
            ["type": "audible.bookmark", "annotationId": "b1", "startPosition": "31495097", "creationTime": "2026-08-02 09:48:29.0"],
            ["type": "audible.note", "startPosition": "31495097", "text": "come back to this"],
        ]
        let marks = AudibleMarksReader.marks(from: records)
        #expect(marks.map(\.sourceId) == ["b1", "c1"])
        #expect(marks[0].location == 31495.097 && marks[0].endLocation == nil && marks[0].note == "come back to this")
        #expect(marks[1].location == 60895.138 && marks[1].endLocation == 60925.138 && marks[1].note == "the turning point")
        #expect(marks.allSatisfy { $0.locationKind == .time && $0.text.isEmpty })
        #expect(marks[1].madeAt == Date(timeIntervalSince1970: 1_789_726_895))
        #expect(AudibleMarksReader.marks(from: ["nonsense", ["type": "audible.clip"]]).isEmpty)
    }

    private func kindleBook(_ title: String, _ asin: String, _ highlights: [IncomingHighlight], author: String = "Ann Author") -> HighlightedBook {
        var book = HighlightedBook(title: title, authors: [author], source: .readwise, highlights: highlights)
        book.itemId = asin
        book.ownedOn = .kindle
        return book
    }

    private func incoming(_ id: String, _ text: String, at location: Double? = nil, note: String? = nil, deleted: Bool = false) -> IncomingHighlight {
        var highlight = IncomingHighlight(sourceId: id, text: text)
        highlight.location = location
        highlight.locationKind = location == nil ? nil : .location
        highlight.note = note
        highlight.isDeleted = deleted
        return highlight
    }

    @Test func HL4_aBookTheLibraryLacksIsAddedAsOwnedOnKindleWithItsHighlights() throws {
        let f = try F()
        let books = [kindleBook("Steve Jobs", "B00KINDLE01", [incoming("2", "Later", at: 900), incoming("1", "Earlier", at: 100)])]
        let preview = try f.service.bringInHighlights(books, apply: false)
        #expect(preview.booksAdded == ["Steve Jobs"] && preview.added == 2)
        #expect(try f.store.books().isEmpty)

        let report = try f.service.bringInHighlights(books, apply: true)
        #expect(report == preview)
        let book = try #require(try f.store.books().first)
        #expect(book.title == "Steve Jobs" && book.authors == ["Ann Author"] && book.folderPath == nil)
        #expect(book.externalCopies == [ExternalCopy(kind: .kindle, form: .ebook, itemId: "B00KINDLE01")])
        // A Kindle ID is not an Audible ID.
        #expect(book.asin == nil)
        let id = try #require(book.id)
        #expect(try f.service.highlights(forBook: id).map(\.text) == ["Earlier", "Later"])
        #expect(try f.service.highlightCounts() == [id: 2])
        #expect(try f.service.booksWithHighlights().map(\.title) == ["Steve Jobs"])
        #expect(try f.store.books(ownedOn: .kindle).count == 1 && f.store.books(having: .ebook).count == 1)
        // Done again, it changes nothing.
        let again = try f.service.bringInHighlights(books, apply: true)
        #expect(again.changesNothing && again.unchanged == 2 && again.booksMatched == 1)
        // Nothing new for the book: it gains nothing.
        #expect(again.booksGaining == 0)
        #expect(try f.store.books().count == 1)
    }

    @Test func HL5_highlightsFindTheLibrarysOwnBookByIDOrByTitleAndAuthor() throws {
        let f = try F()
        var mine = Book(metadata: BookMetadata(title: "Steve Jobs", authors: ["Walter Isaacson"]))
        mine.rating = 4
        let byName = try #require(try f.store.insert(mine, files: []).id)
        var other = Book(metadata: BookMetadata(title: "My Own Name For It", authors: ["Somebody"]))
        other.externalCopies = [ExternalCopy(kind: .kindle, form: .ebook, itemId: "B00KINDLE02")]
        let byId = try #require(try f.store.insert(other, files: []).id)

        let report = try f.service.bringInHighlights([
            kindleBook("Steve Jobs", "B00KINDLE01", [incoming("1", "One")], author: "Walter Isaacson"),
            kindleBook("Quite Another Title", "b00kindle02", [incoming("2", "Two")]),
        ], apply: true)
        #expect(report.booksAdded.isEmpty && report.booksMatched == 2 && report.added == 2)
        #expect(report.booksGaining == 2)
        #expect(try f.store.books().count == 2)
        #expect(try f.service.highlights(forBook: byName).map(\.text) == ["One"])
        #expect(try f.service.highlights(forBook: byId).map(\.text) == ["Two"])
        // The book keeps what it was.
        #expect(try f.store.book(id: byName)?.rating == 4)
    }

    @Test func HL6_aBookOwnedNowhereTheAppKnowsIsLeftOutAndNamed() throws {
        let f = try F()
        var typed = HighlightedBook(title: "Typed In By Hand", authors: ["A"], source: .readwise, highlights: [incoming("9", "x")])
        typed.ownedOn = nil
        let report = try f.service.bringInHighlights([typed], apply: true)
        #expect(report.booksLeftOut == ["Typed In By Hand"] && report.added == 0)
        #expect(try f.store.books().isEmpty)
        // A book whose every highlight is deleted is not added for nothing.
        let empty = try f.service.bringInHighlights([kindleBook("Empty", "B0EMPTY", [incoming("8", "x", deleted: true)])], apply: true)
        #expect(empty.changesNothing && empty.booksAdded.isEmpty)
    }

    @Test func HL7_lookedAtAgainAChangedHighlightIsChangedAndADeletedOneRemoved() throws {
        let f = try F()
        _ = try f.service.bringInHighlights([kindleBook("Book", "B1", [incoming("1", "First"), incoming("2", "Second")])], apply: true)
        let id = try #require(try f.store.books().first?.id)
        // The owner writes a note here on the first.
        let first = try #require(try f.service.highlights(forBook: id).first { $0.sourceId == "1" })
        try f.service.setNote("my own note", onHighlight: try #require(first.id))

        let report = try f.service.bringInHighlights(
            [kindleBook("Book", "B1", [incoming("1", "First, corrected"), incoming("2", "Second", deleted: true), incoming("3", "Third")])],
            apply: true)
        #expect(report.changed == 1 && report.removed == 1 && report.added == 1 && report.unchanged == 0)
        let now = try f.service.highlights(forBook: id)
        #expect(Set(now.map(\.text)) == ["First, corrected", "Third"])
        // The note written here stays, since the source has none.
        #expect(now.first { $0.sourceId == "1" }?.note == "my own note")
        // A note at the source replaces it.
        _ = try f.service.bringInHighlights([kindleBook("Book", "B1", [incoming("1", "First, corrected", note: "theirs")])], apply: true)
        #expect(try f.service.highlights(forBook: id).first { $0.sourceId == "1" }?.note == "theirs")
    }

    @Test func HL8_aHighlightOfTheOwnersOwnCanBeAddedToAnyBookAndRemoved() throws {
        let f = try F()
        let id = try #require(try f.store.insert(Book(metadata: BookMetadata(title: "A Local Book", authors: ["A"])), files: []).id)
        let made = try f.service.addHighlight(text: "  A line worth keeping. ", note: " why ", toBook: id, location: 754, locationKind: .time)
        #expect(made.source == .own && made.text == "A line worth keeping." && made.note == "why" && made.id != nil)
        #expect(made.location == 754 && made.locationKind == .time)
        _ = try f.service.addHighlight(text: "", note: "a thought with no passage", toBook: id)
        #expect(try f.service.highlights(forBook: id).count == 2)
        #expect(throws: LibraryError.self) { _ = try f.service.addHighlight(text: " ", note: nil, toBook: id) }
        #expect(throws: LibraryError.self) { _ = try f.service.addHighlight(text: "x", note: nil, toBook: 999) }
        try f.service.deleteHighlight(id: try #require(made.id))
        #expect(try f.service.highlights(forBook: id).map(\.note) == ["a thought with no passage"])
        // Bringing others in leaves the owner's own alone.
        _ = try f.service.bringInHighlights([], apply: true)
        #expect(try f.service.highlights(forBook: id).count == 1)
    }

    @Test func HL9_booksAreFoundByTheWordsOfTheirHighlights() throws {
        let f = try F()
        _ = try f.service.bringInHighlights([
            kindleBook("One", "B1", [incoming("1", "Stay hungry, stay foolish."), incoming("2", "100% of the time")]),
            kindleBook("Two", "B2", [incoming("3", "Nothing here", note: "but hungry in the note")]),
            kindleBook("Three", "B3", [incoming("4", "Something else")]),
        ], apply: true)
        let ids = Dictionary(uniqueKeysWithValues: try f.store.books().map { ($0.title, $0.id!) })
        #expect(try f.store.bookIds(withHighlightsMatching: "HUNGRY") == [ids["One"]!, ids["Two"]!])
        #expect(try f.store.bookIds(withHighlightsMatching: "foolish stay") == [ids["One"]!])
        // The signs a search pattern uses are only themselves.
        #expect(try f.store.bookIds(withHighlightsMatching: "100%") == [ids["One"]!])
        #expect(try f.store.bookIds(withHighlightsMatching: "_") == [])
        #expect(try f.store.bookIds(withHighlightsMatching: "   ").isEmpty)
    }

    @Test func HL10_aBooksHighlightsGoWhenTheBookGoesAndMarksSitOnTheAudibleBook() throws {
        let f = try F()
        var listened = HighlightedBook(title: "World Undone", authors: ["Some Author"], source: .audible, highlights: [])
        listened.itemId = "B0AUDIBLE1"
        listened.ownedOn = .audible
        var mark = IncomingHighlight(sourceId: "c1", text: "")
        mark.location = 60895.138
        mark.endLocation = 60925.138
        mark.locationKind = .time
        listened.highlights = [mark]
        let report = try f.service.bringInHighlights([listened], apply: true)
        #expect(report.booksAdded == ["World Undone"] && report.added == 1)
        let book = try #require(try f.store.books().first)
        #expect(book.asin == "B0AUDIBLE1")
        #expect(book.externalCopies == [ExternalCopy(kind: .audible, form: .audio, itemId: "B0AUDIBLE1")])
        let id = try #require(book.id)
        #expect(try f.service.highlights(forBook: id).first?.locationKind == .time)
        try f.store.dbQueue.write { db in try db.execute(sql: "DELETE FROM book WHERE id = ?", arguments: [id]) }
        #expect(try f.service.highlightCounts().isEmpty || (try f.store.highlights(forBook: id)).isEmpty)
    }

    // MARK: The same highlight from two places

    private func audibleBook(_ title: String, _ asin: String, _ highlights: [IncomingHighlight], author: String = "Ann Author") -> HighlightedBook {
        var book = HighlightedBook(title: title, authors: [author], source: .audible, highlights: highlights)
        book.itemId = asin
        book.ownedOn = .audible
        return book
    }

    private func mark(_ id: String, at seconds: Double, note: String? = nil, text: String = "", deleted: Bool = false) -> IncomingHighlight {
        var highlight = IncomingHighlight(sourceId: id, text: text)
        highlight.location = seconds
        highlight.locationKind = .time
        highlight.note = note
        highlight.isDeleted = deleted
        return highlight
    }

    @Test func HL11_theSameWordsFromAnotherSourceAreOneHighlightAndTheBookIsOwnedThereToo() throws {
        let f = try F()
        _ = try f.service.bringInHighlights([kindleBook("Book", "B1", [incoming("1", "Stay hungry, stay foolish.", at: 120)])], apply: true)
        let id = try #require(try f.store.books().first?.id)
        var same = mark("c9", at: 300, note: "heard this", text: "  stay hungry — stay FOOLISH ")
        same.madeAt = Date(timeIntervalSince1970: 1000)
        let heard = [audibleBook("Book", "B0AUD", [same, mark("c10", at: 900, text: "Something else entirely")])]

        let preview = try f.service.bringInHighlights(heard, apply: false)
        #expect(preview.joined == 1 && preview.added == 1 && preview.booksMatched == 1 && preview.booksAdded.isEmpty)
        #expect(!preview.changesNothing)
        #expect(try f.service.highlights(forBook: id).count == 1 && f.store.highlightOrigins().isEmpty)

        #expect(try f.service.bringInHighlights(heard, apply: true) == preview)
        let now = try f.service.highlights(forBook: id)
        #expect(now.count == 2)
        let kept = try #require(now.first { $0.sourceId == "1" })
        // It stays as it was, and gains what it lacked.
        #expect(kept.source == .readwise && kept.text == "Stay hungry, stay foolish." && kept.location == 120 && kept.locationKind == .location)
        #expect(kept.note == "heard this" && kept.madeAt == Date(timeIntervalSince1970: 1000))
        #expect(try f.store.otherSources(ofHighlightsOfBook: id) == [try #require(kept.id): [.audible]])
        // One book, owned in both places.
        let book = try #require(try f.store.books().first)
        #expect(try f.store.books().count == 1)
        #expect(Set(book.externalCopies.map(\.kind)) == [.kindle, .audible] && book.asin == "B0AUD")
        // Done again, it changes nothing.
        let again = try f.service.bringInHighlights(heard, apply: true)
        #expect(again.changesNothing && again.unchanged == 2 && again.joined == 0)
        #expect(try f.service.highlights(forBook: id).count == 2)
        // And from the first source again, likewise.
        let first = try f.service.bringInHighlights([kindleBook("Book", "B1", [incoming("1", "Stay hungry, stay foolish.", at: 120)])], apply: true)
        #expect(first.changesNothing)
        #expect(try f.service.highlights(forBook: id).first { $0.sourceId == "1" }?.note == "heard this")
    }

    @Test func HL12_aPassageHoldingAnotherIsTheSameAndTheLongerIsKeptButNotAtAnotherPlace() throws {
        let f = try F()
        let short = "the quick brown fox jumps over the lazy dog"
        let long = "And so it was that \(short), twice, before breakfast."
        _ = try f.service.bringInHighlights([kindleBook("Book", "B1", [incoming("1", short, at: 50), incoming("2", "It was.")])], apply: true)
        let id = try #require(try f.store.books().first?.id)
        var typed = HighlightedBook(title: "Book", authors: ["Ann Author"], source: .audible, highlights: [
            incoming("a", long), incoming("b", "It was. Or was it not, in the end?"),
        ])
        typed.itemId = "B0AUD"
        typed.ownedOn = .audible
        let report = try f.service.bringInHighlights([typed], apply: true)
        // The long passage holds the first; too few words are shared with the second for it to be the same.
        #expect(report.joined == 1 && report.added == 1)
        let now = try f.service.highlights(forBook: id)
        #expect(now.count == 3 && now.first { $0.sourceId == "1" }?.text == long)

        // The same words at a place far off are another highlight.
        #expect(!HighlightMatch.same(
            Highlight(bookId: 1, source: .readwise, sourceId: "x", text: short, location: 50, locationKind: .location),
            Highlight(bookId: 1, source: .readwise, sourceId: "y", text: long, location: 4000, locationKind: .location)))
        #expect(HighlightMatch.key("  Crème — brûlée, 2nd! ") == "cremebrulee2nd")
    }

    @Test func HL13_twoOfOneAnswerThatAreTheSameAreKeptOnce() throws {
        let f = try F()
        let report = try f.service.bringInHighlights(
            [kindleBook("Book", "B1", [incoming("1", "Stay hungry."), incoming("2", "stay hungry", note: "twice"), incoming("3", "Other")])], apply: true)
        #expect(report.added == 2 && report.joined == 1 && report.booksAdded == ["Book"])
        let id = try #require(try f.store.books().first?.id)
        let now = try f.service.highlights(forBook: id)
        #expect(now.count == 2 && now.first { $0.sourceId == "1" }?.note == "twice")
        let again = try f.service.bringInHighlights(
            [kindleBook("Book", "B1", [incoming("1", "Stay hungry."), incoming("2", "stay hungry", note: "twice"), incoming("3", "Other")])], apply: true)
        #expect(again.changesNothing && again.unchanged == 3)
    }

    @Test func HL14_marksWithNoWordsAreOneWhenTheyBeginWithinTwoSeconds() throws {
        let f = try F()
        _ = try f.service.bringInHighlights([audibleBook("Heard", "B0AUD", [mark("c1", at: 100)])], apply: true)
        let id = try #require(try f.store.books().first?.id)
        var other = HighlightedBook(title: "Heard", authors: ["Ann Author"], source: .readwise, highlights: [
            mark("r1", at: 101.5, note: "from the other side"), mark("r2", at: 103), mark("r3", at: 100, text: "Words"),
        ])
        other.itemId = "B0AUD"
        let report = try f.service.bringInHighlights([other], apply: true)
        #expect(report.joined == 1 && report.added == 2)
        let now = try f.service.highlights(forBook: id)
        #expect(now.count == 3 && now.first { $0.sourceId == "c1" }?.note == "from the other side")
    }

    @Test func HL15_aHighlightDeletedAtOneSourceStaysWhileAnotherHasIt() throws {
        let f = try F()
        _ = try f.service.bringInHighlights([kindleBook("Book", "B1", [incoming("1", "Stay hungry, stay foolish.")])], apply: true)
        let id = try #require(try f.store.books().first?.id)
        _ = try f.service.bringInHighlights([audibleBook("Book", "B0AUD", [mark("c9", at: 300, text: "Stay hungry, stay foolish.")])], apply: true)

        // The source it is kept under deletes it: it is kept under the other.
        let gone = try f.service.bringInHighlights([kindleBook("Book", "B1", [incoming("1", "Stay hungry, stay foolish.", deleted: true)])], apply: true)
        #expect(gone.removed == 0)
        var now = try f.service.highlights(forBook: id)
        #expect(now.count == 1 && now[0].source == .audible && now[0].sourceId == "c9")
        #expect(try f.store.highlightOrigins().isEmpty)
        // That one changes its words: its own source says what it is.
        let changed = try f.service.bringInHighlights([audibleBook("Book", "B0AUD", [mark("c9", at: 300, text: "Stay hungry.")])], apply: true)
        #expect(changed.changed == 1)
        // The last source deletes it: it goes.
        let last = try f.service.bringInHighlights([audibleBook("Book", "B0AUD", [mark("c9", at: 300, deleted: true)])], apply: true)
        #expect(last.removed == 1)
        now = try f.service.highlights(forBook: id)
        #expect(now.isEmpty)
    }

    @Test func HL16_aSourceThatIsNotTheOneKeptUnderDeletesAndOnlyItsMarkGoes() throws {
        let f = try F()
        _ = try f.service.bringInHighlights([kindleBook("Book", "B1", [incoming("1", "Stay hungry, stay foolish.")])], apply: true)
        let id = try #require(try f.store.books().first?.id)
        _ = try f.service.bringInHighlights([audibleBook("Book", "B0AUD", [mark("c9", at: 300, text: "Stay hungry, stay foolish.")])], apply: true)
        #expect(try f.store.highlightOrigins().count == 1)
        let report = try f.service.bringInHighlights([audibleBook("Book", "B0AUD", [mark("c9", at: 300, deleted: true)])], apply: true)
        #expect(report.removed == 0)
        let now = try f.service.highlights(forBook: id)
        #expect(now.count == 1 && now[0].source == .readwise)
        #expect(try f.store.highlightOrigins().isEmpty)
        // An owner's own highlight with the same words as an arriving one is not doubled either.
        _ = try f.service.addHighlight(text: "My own words, typed in here by hand.", note: nil, toBook: id)
        let more = try f.service.bringInHighlights(
            [kindleBook("Book", "B1", [incoming("1", "Stay hungry, stay foolish."), incoming("7", "my own words typed in here by hand")])], apply: true)
        #expect(more.joined == 1 && more.added == 0)
        #expect(try f.service.highlights(forBook: id).count == 2)
    }
}
