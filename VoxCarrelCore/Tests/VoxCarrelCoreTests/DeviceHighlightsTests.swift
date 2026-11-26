import Foundation
import GRDB
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// DH1–DH7: highlights read from a Kindle's clippings file and a Kobo's database.
@Suite struct DeviceHighlightsTests {
    typealias F = LibraryFixture

    static let clippings = """
        \u{FEFF}Salt Road (Calloway, Ines)
        - Your Highlight on page 12 | Location 180-182 | Added on Monday, March 3, 2025 9:14:05 AM

        The map is not the coast, only a promise of it.
        ==========
        Salt Road (Calloway, Ines)
        - Your Note on page 12 | Location 182 | Added on Monday, March 3, 2025 9:15:00 AM

        For the talk
        ==========
        Salt Road (Calloway, Ines)
        - Your Bookmark on page 30 | Location 450 | Added on Monday, March 3, 2025 9:20:00 AM


        ==========
        Salt Road (Calloway, Ines)
        - Your Highlight on Location 90-91 | Added on Sunday, 2 March 2025 21:05:10

        An earlier line.
        ==========
        Quiet Rivers (Amara Okafor; Second Writer)
        - Highlight Loc. 1180-82 | Added on Tuesday, March 4, 2025, 7:00:00 PM

        Rivers do not hurry.
        ==========
        Quiet Rivers (Amara Okafor; Second Writer)
        - Your Highlight on page 4 | Location 50-51 | Added on Tuesday, March 4, 2025 7:01:00 PM

        <You have reached the clipping limit for this item>
        ==========
        Salt Road (Calloway, Ines)
        - Your Highlight on page 12 | Location 180-182 | Added on Monday, March 3, 2025 9:14:05 AM

        The map is not the coast, only a promise of it.
        ==========

        """

    // DH1: the clippings file is read into books, with each highlight's place, day
    // and note; bookmarks and what the publisher's limit cut off are passed over.
    @Test func DH1_aClippingsFileIsRead() throws {
        #expect(KindleClippings.looksLikeClippings(Self.clippings) && !KindleClippings.looksLikeClippings("Just some text"))
        let books = KindleClippings.books(from: Self.clippings.replacingOccurrences(of: "\n", with: "\r\n"))
        #expect(books.map(\.title) == ["Salt Road", "Quiet Rivers"])
        #expect(books[0].authors == ["Ines Calloway"] && books[1].authors == ["Amara Okafor", "Second Writer"])
        #expect(books.allSatisfy { $0.source == .kindle && $0.ownedOn == nil })
        let salt = books[0].highlights
        // In the order of the book, and the one written twice is there once.
        #expect(salt.map(\.text) == ["An earlier line.", "The map is not the coast, only a promise of it."])
        #expect(salt[1].location == 180 && salt[1].endLocation == 182 && salt[1].locationKind == .location)
        #expect(salt[1].note == "For the talk" && salt[0].note == nil)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let made = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: try #require(salt[1].madeAt))
        #expect(made.year == 2025 && made.month == 3 && made.day == 3 && made.hour == 9 && made.minute == 14)
        let earlier = calendar.dateComponents([.day, .hour], from: try #require(salt[0].madeAt))
        #expect(earlier.day == 2 && earlier.hour == 21)
        let rivers = books[1].highlights
        #expect(rivers.map(\.text) == ["Rivers do not hurry."] && rivers[0].location == 1180 && rivers[0].endLocation == 1182)
        #expect(rivers[0].madeAt != nil)
        // The same file read again names every highlight as before.
        #expect(KindleClippings.books(from: Self.clippings).flatMap(\.highlights).map(\.sourceId) == books.flatMap(\.highlights).map(\.sourceId))
    }

    // DH2: the line about an entry is read whatever a Kindle wrote.
    @Test func DH2_theLineAboutAnEntryIsRead() throws {
        #expect(KindleClippings.titleAndAuthors("A Book (With Brackets) (Le Guin, Ursula K.)") == ("A Book (With Brackets)", ["Ursula K. Le Guin"]))
        #expect(KindleClippings.titleAndAuthors("No Author Here") == ("No Author Here", []))
        #expect(KindleClippings.numbers(in: "Location 180-182") == [180, 182] && KindleClippings.numbers(in: "nothing") == [])
        #expect(KindleClippings.fullEnd(82, after: 1180) == 1182 && KindleClippings.fullEnd(182, after: 180) == 182)
        // Another language: the kind is not told, the numbers are, the day is not taken for a place.
        let german = try #require(KindleClippings.entry(from: [
            "Das Buch (Autor, Anna)", "- Ihre Markierung auf Seite 7 | Position 99-101 | Hinzugefügt am Montag, 3. März 2025 09:14:05", "", "Ein Satz.",
        ]))
        #expect(german.kind == .highlight && german.start == 99 && german.end == 101 && german.page == 7)
        #expect(german.added == nil && german.text == "Ein Satz.")
        #expect(KindleClippings.entry(from: ["Only a title"]) == nil)
    }

    private func importedBook(_ f: F, _ title: String, _ author: String) throws -> Int64 {
        var tags = BookMetadata(title: title, authors: [author])
        tags.genres = []
        let file = try f.makeM4B("\(title).m4b", tags: tags)
        let result = try f.service.importItems([ImportItem(candidate: f.candidate([file], tags))])
        return try f.importedId(result.outcomes[0])
    }

    // DH3: clippings land on the library's books by title and author; a book the
    // library lacks is left out and named, and nothing is added twice.
    @Test func DH3_clippingsLandOnTheLibrarysBooks() throws {
        let f = try F()
        let salt = try importedBook(f, "Salt Road", "Ines Calloway")
        let books = KindleClippings.books(from: Self.clippings)
        let preview = try f.service.bringInHighlights(books, apply: false)
        #expect(preview.added == 2 && preview.booksMatched == 1 && preview.booksLeftOut == ["Quiet Rivers"] && preview.booksAdded.isEmpty)
        #expect(try f.service.highlights(forBook: salt).isEmpty)
        let done = try f.service.bringInHighlights(books, apply: true)
        #expect(done.added == 2)
        let kept = try f.service.highlights(forBook: salt)
        #expect(kept.map(\.source) == [.kindle, .kindle] && kept.contains { $0.note == "For the talk" })
        // Again: nothing changes.
        let again = try f.service.bringInHighlights(books, apply: true)
        #expect(again.changesNothing && again.unchanged == 2)
        #expect(HighlightSource.kindle.title == "Kindle" && HighlightSource.kobo.title == "Kobo")
    }

    // DH4: a highlight the book already has from elsewhere is not added twice.
    @Test func DH4_theSameHighlightFromElsewhereIsJoined() throws {
        let f = try F()
        let salt = try importedBook(f, "Salt Road", "Ines Calloway")
        try f.service.addHighlight(text: "The map is not the coast, only a promise of it.", note: nil, toBook: salt)
        let report = try f.service.bringInHighlights(KindleClippings.books(from: Self.clippings), apply: true)
        #expect(report.joined == 1 && report.added == 1)
        #expect(try f.service.highlights(forBook: salt).count == 2)
    }

    /// A database with the tables and columns of a Kobo's that this code reads.
    private func kobo(_ fill: (Database) throws -> Void) throws -> URL {
        let url = try makeTempDir().appendingPathComponent("KoboReader.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE content (ContentID TEXT PRIMARY KEY, ContentType TEXT, Title TEXT, Attribution TEXT);
                CREATE TABLE Bookmark (BookmarkID TEXT PRIMARY KEY, VolumeID TEXT, ContentID TEXT, Text TEXT,
                    Annotation TEXT, DateCreated TEXT, Hidden TEXT, Type TEXT);
                """)
            try fill(db)
        }
        return url
    }

    private func mark(_ db: Database, _ id: String, _ volume: String, _ text: String?, note: String? = nil,
                      made: String = "2025-03-03T09:14:05.000", hidden: String = "false", type: String = "highlight") throws {
        try db.execute(
            sql: "INSERT INTO Bookmark VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            arguments: [id, volume, volume + "#ch1", text, note, made, hidden, type])
    }

    // DH5: a Kobo's database is read into books with their highlights and notes, in
    // the order they were made; hidden marks and turned-down corners are passed over.
    @Test func DH5_aKobosDatabaseIsRead() throws {
        let url = try kobo { db in
            try db.execute(sql: "INSERT INTO content VALUES ('file:///mnt/onboard/Salt.epub', '6', 'Salt Road', 'Ines Calloway')")
            try db.execute(sql: "INSERT INTO content VALUES ('vol-2', '6', 'Two Hands', 'Priya Nair, Daniel Brandt')")
            try db.execute(sql: "INSERT INTO content VALUES ('vol-3', '6', 'Unmarked', 'No One')")
            try mark(db, "b2", "file:///mnt/onboard/Salt.epub", "A later line.", note: "Mine", made: "2025-03-04T10:00:00Z")
            try mark(db, "b1", "file:///mnt/onboard/Salt.epub", "The map is not the coast, only a promise of it.")
            try mark(db, "b3", "file:///mnt/onboard/Salt.epub", "Taken back.", hidden: "true")
            try mark(db, "b4", "file:///mnt/onboard/Salt.epub", nil, type: "dogear")
            try mark(db, "b5", "vol-2", "", note: "A note alone", type: "note")
            try mark(db, "b6", "vol-gone", "Of a book the device no longer names.")
        }
        let books = try KoboHighlights.books(fromDatabaseAt: url)
        #expect(books.map(\.title) == ["Salt Road", "Two Hands"])
        #expect(books[1].authors == ["Priya Nair", "Daniel Brandt"] && books.allSatisfy { $0.source == .kobo })
        let salt = books[0].highlights
        #expect(salt.map(\.sourceId) == ["b1", "b2"] && salt.map(\.location) == [1, 2] && salt[0].locationKind == .order)
        #expect(salt[1].note == "Mine" && salt[0].note == nil)
        #expect(salt[0].madeAt == Date(timeIntervalSince1970: 1_740_993_245) && salt[1].madeAt != nil)
        #expect(books[1].highlights.map(\.note) == ["A note alone"] && books[1].highlights[0].text.isEmpty)
        // The database is as it was: it was only read.
        #expect(try DatabaseQueue(path: url.path).read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM Bookmark") } == 6)
    }

    // DH6: a file that is not a Kobo's database is refused, and said to be none.
    @Test func DH6_whatIsNotAKobosDatabaseIsRefused() throws {
        let text = try makeTempDir().appendingPathComponent("KoboReader.sqlite")
        try Data("not a database at all".utf8).write(to: text)
        #expect(throws: KoboHighlights.Problem.notAKoboDatabase) { try KoboHighlights.books(fromDatabaseAt: text) }
        let other = try makeTempDir().appendingPathComponent("other.sqlite")
        try DatabaseQueue(path: other.path).write { try $0.execute(sql: "CREATE TABLE thing (id INTEGER)") }
        #expect(throws: KoboHighlights.Problem.notAKoboDatabase) { try KoboHighlights.books(fromDatabaseAt: other) }
    }

    // DH7: a Kobo's highlights land on the library's books and are known again by
    // the device's own name for each.
    @Test func DH7_aKobosHighlightsLandOnTheLibrarysBooks() throws {
        let f = try F()
        let salt = try importedBook(f, "Salt Road", "Ines Calloway")
        let url = try kobo { db in
            try db.execute(sql: "INSERT INTO content VALUES ('v1', '6', 'Salt Road', 'Ines Calloway')")
            try mark(db, "b1", "v1", "The map is not the coast, only a promise of it.")
        }
        let books = try KoboHighlights.books(fromDatabaseAt: url)
        #expect(try f.service.bringInHighlights(books, apply: true).added == 1)
        #expect(try f.service.highlights(forBook: salt).map(\.source) == [.kobo])
        #expect(try f.service.bringInHighlights(books, apply: true).changesNothing)
    }
}
