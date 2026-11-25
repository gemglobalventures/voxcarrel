import Foundation
import GRDB
import Testing
import UniformTypeIdentifiers
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// CB1–CB7: reading a calibre library and bringing its books in.
@Suite struct CalibreLibraryTests {
    typealias F = LibraryFixture

    /// A calibre library in a folder: the tables of its catalogue that are read, as
    /// calibre makes them, and whatever books are put in.
    final class Calibre {
        let folder: URL
        let queue: DatabaseQueue
        private var nextId: Int64 = 0

        init(in base: URL) throws {
            folder = base.appendingPathComponent("Calibre Library", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            queue = try DatabaseQueue(path: folder.appendingPathComponent("metadata.db").path)
            try queue.write { db in
                try db.execute(sql: """
                    CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT, path TEXT, has_cover BOOL DEFAULT 0,
                                        series_index REAL DEFAULT 1.0, pubdate TEXT, timestamp TEXT);
                    CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT);
                    CREATE TABLE books_authors_link (id INTEGER PRIMARY KEY, book INTEGER, author INTEGER);
                    CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT);
                    CREATE TABLE books_tags_link (id INTEGER PRIMARY KEY, book INTEGER, tag INTEGER);
                    CREATE TABLE series (id INTEGER PRIMARY KEY, name TEXT);
                    CREATE TABLE books_series_link (id INTEGER PRIMARY KEY, book INTEGER, series INTEGER);
                    CREATE TABLE publishers (id INTEGER PRIMARY KEY, name TEXT);
                    CREATE TABLE books_publishers_link (id INTEGER PRIMARY KEY, book INTEGER, publisher INTEGER);
                    CREATE TABLE languages (id INTEGER PRIMARY KEY, lang_code TEXT);
                    CREATE TABLE books_languages_link (id INTEGER PRIMARY KEY, book INTEGER, lang_code INTEGER);
                    CREATE TABLE ratings (id INTEGER PRIMARY KEY, rating INTEGER);
                    CREATE TABLE books_ratings_link (id INTEGER PRIMARY KEY, book INTEGER, rating INTEGER);
                    CREATE TABLE identifiers (id INTEGER PRIMARY KEY, book INTEGER, type TEXT, val TEXT);
                    CREATE TABLE comments (id INTEGER PRIMARY KEY, book INTEGER, text TEXT);
                    CREATE TABLE data (id INTEGER PRIMARY KEY, book INTEGER, format TEXT, name TEXT);
                    """)
            }
        }

        /// Adds a book with these files (made here, real ones for EPUB and PDF) and details.
        @discardableResult
        func add(
            _ title: String, authors: [String], formats: [String] = ["EPUB"], cover: Bool = true, series: (String, Double)? = nil,
            tags: [String] = [], rating: Int? = nil, isbn: String? = nil, comment: String? = nil, publisher: String? = nil,
            pubdate: String = "2019-03-04 00:00:00+00:00", timestamp: String = "2020-05-01 12:34:56+00:00",
            missing: Set<String> = []
        ) throws -> URL {
            nextId += 1
            let id = nextId
            let path = "\(authors.first ?? "Unknown")/\(title) (\(id))"
            let bookFolder = folder.appendingPathComponent(path, isDirectory: true)
            try FileManager.default.createDirectory(at: bookFolder, withIntermediateDirectories: true)
            let name = "\(title) - \(authors.first ?? "Unknown")"
            for format in formats where !missing.contains(format) {
                let url = bookFolder.appendingPathComponent("\(name).\(format.lowercased())")
                switch format {
                case "EPUB": _ = try MediaFixtures.makeEPUB3(in: bookFolder, name: url.lastPathComponent)
                case "PDF": MediaFixtures.makePDF(at: url, pages: 2 + Int(id))
                default: try Data("\(format) of \(title) \(id)".utf8).write(to: url)
                }
            }
            if cover { try MediaFixtures.makeImage(.jpeg).write(to: bookFolder.appendingPathComponent("cover.jpg")) }
            try queue.write { db in
                try db.execute(
                    sql: "INSERT INTO books (id, title, path, has_cover, series_index, pubdate, timestamp) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    arguments: [id, title, path, cover, series?.1 ?? 1.0, pubdate, timestamp])
                func link(_ table: String, _ column: String, _ field: String, _ value: String) throws {
                    try db.execute(sql: "INSERT INTO \(table) (\(field)) VALUES (?)", arguments: [value])
                    let made = db.lastInsertedRowID
                    try db.execute(sql: "INSERT INTO books_\(table)_link (book, \(column)) VALUES (?, ?)", arguments: [id, made])
                }
                for author in authors { try link("authors", "author", "name", author.replacingOccurrences(of: ",", with: "|")) }
                for tag in tags { try link("tags", "tag", "name", tag) }
                if let series { try link("series", "series", "name", series.0) }
                if let publisher { try link("publishers", "publisher", "name", publisher) }
                try link("languages", "lang_code", "lang_code", "eng")
                if let rating {
                    try db.execute(sql: "INSERT INTO ratings (rating) VALUES (?)", arguments: [rating])
                    try db.execute(sql: "INSERT INTO books_ratings_link (book, rating) VALUES (?, ?)", arguments: [id, db.lastInsertedRowID])
                }
                if let isbn {
                    try db.execute(sql: "INSERT INTO identifiers (book, type, val) VALUES (?, 'mobi-asin', 'B00KINDLE1'), (?, 'isbn', ?)", arguments: [id, id, isbn])
                }
                if let comment { try db.execute(sql: "INSERT INTO comments (book, text) VALUES (?, ?)", arguments: [id, comment]) }
                for format in formats {
                    try db.execute(sql: "INSERT INTO data (book, format, name) VALUES (?, ?, ?)", arguments: [id, format, name])
                }
            }
            return bookFolder
        }

        /// Every file of the library with its bytes, for showing nothing was touched.
        func snapshot() throws -> [String: Data] {
            var found: [String: Data] = [:]
            let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
            while let url = walker?.nextObject() as? URL {
                guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
                found[String(url.path.dropFirst(folder.path.count))] = try Data(contentsOf: url)
            }
            return found
        }
    }

    @Test func CB1_aBookIsReadWithEverythingCalibreSaysOfIt() throws {
        let calibre = try Calibre(in: try makeTempDir())
        let folder = try calibre.add(
            "The Long Road", authors: ["Ann Author", "Smith, Jr."], formats: ["EPUB", "PDF", "KFX"], series: ("The Saga", 2.5),
            tags: ["Science Fiction", "to-read", "Signed Copy"], rating: 9, isbn: "9780000000001",
            comment: "<div><p>A <b>fine</b> book.</p><p>Really.</p></div>", publisher: "Small Press")
        let read = try CalibreLibraryReader.read(calibre.folder)
        #expect(read.books.count == 1 && read.withoutFiles.isEmpty && read.formatsLeftOut == ["KFX": 1])
        let book = try #require(read.books.first)
        let details = book.candidate.metadata
        #expect(details.title == "The Long Road" && details.authors == ["Ann Author", "Smith, Jr."])
        #expect(details.series == "The Saga" && details.seriesNumber == "2.5" && details.publisher == "Small Press")
        #expect(details.year == 2019 && details.language == "eng" && details.isbn == "9780000000001")
        // An ebook's Kindle ID is not an Audible ID.
        #expect(details.asin == nil)
        #expect(details.summary?.contains("A fine book.") == true && details.summary?.contains("<") == false)
        #expect(details.genres == ["Science Fiction"])
        #expect(book.extras.tags == ["to-read", "Signed Copy"] && book.extras.rating == 5)
        #expect(book.extras.added == Date(timeIntervalSince1970: 1_588_336_496))
        #expect(book.candidate.files.map(\.url.pathExtension) == ["epub", "pdf"] && book.candidate.files.allSatisfy { $0.role == .ebook })
        #expect(book.candidate.sourceFolder == folder && book.candidate.coverBeside == folder.appendingPathComponent("cover.jpg"))
    }

    @Test func CB2_oddValuesAreReadForWhatTheyAre() throws {
        #expect(CalibreLibraryReader.number(1) == "1" && CalibreLibraryReader.number(2.5) == "2.5" && CalibreLibraryReader.number(.nan) == nil)
        // The year 101 is how calibre writes "not known".
        #expect(CalibreLibraryReader.year("0101-01-01 00:00:00+00:00") == nil && CalibreLibraryReader.year("1999-12-31") == 1999)
        #expect(CalibreLibraryReader.year(nil) == nil && CalibreLibraryReader.year("soon") == nil)
        #expect(CalibreLibraryReader.date("2020-05-01 12:34:56+00:00") == Date(timeIntervalSince1970: 1_588_336_496))
        let fine = try #require(CalibreLibraryReader.date("2020-05-01 12:34:56.789000+00:00"))
        #expect(abs(fine.timeIntervalSince1970 - 1_588_336_496.789) < 0.01 && CalibreLibraryReader.date("never") == nil)
        #expect(CalibreLibraryReader.name("Smith| Jr.") == "Smith, Jr.")
        let calibre = try Calibre(in: try makeTempDir())
        try calibre.add("Half", authors: ["A"], rating: 5)
        try calibre.add("None", authors: ["B"], cover: false, pubdate: "0101-01-01 00:00:00+00:00")
        let read = try CalibreLibraryReader.read(calibre.folder)
        #expect(read.books.map(\.extras.rating) == [3, 0])
        #expect(read.books[1].candidate.coverBeside == nil && read.books[1].candidate.metadata.year == nil)
    }

    @Test func CB3_aBookWithNoFileThisLibraryKeepsIsNamedAndLeftOut() throws {
        let calibre = try Calibre(in: try makeTempDir())
        try calibre.add("Only Kindle Format", authors: ["A"], formats: ["KFX"])
        try calibre.add("Gone From Disk", authors: ["B"], formats: ["EPUB"], missing: ["EPUB"])
        try calibre.add("Here", authors: ["C"], formats: ["EPUB", "MOBI"], missing: ["MOBI"])
        let read = try CalibreLibraryReader.read(calibre.folder)
        #expect(read.books.map(\.candidate.metadata.title) == ["Here"] && read.books[0].candidate.files.count == 1)
        #expect(read.withoutFiles == ["Only Kindle Format", "Gone From Disk"] && read.formatsLeftOut == ["KFX": 1])
    }

    @Test func CB4_aFolderThatIsNoCalibreLibraryOrACatalogueThatIsNoneSaysSo() throws {
        let base = try makeTempDir()
        #expect(throws: CalibreLibraryError.notACalibreLibrary) { try CalibreLibraryReader.read(base) }
        #expect(!CalibreLibraryReader.isCalibreLibrary(base))
        try Data("not a database".utf8).write(to: base.appendingPathComponent("metadata.db"))
        #expect(CalibreLibraryReader.isCalibreLibrary(base))
        #expect(throws: CalibreLibraryError.unreadable) { try CalibreLibraryReader.read(base) }
        // A path in the catalogue that points out of the library is not followed.
        let calibre = try Calibre(in: base.appendingPathComponent("c"))
        try calibre.add("Fine", authors: ["A"])
        try calibre.queue.write { db in
            try db.execute(sql: "INSERT INTO books (id, title, path) VALUES (50, 'Sly', '../../outside'), (51, 'Rooted', '/etc')")
            try db.execute(sql: "INSERT INTO data (book, format, name) VALUES (50, 'EPUB', 'x'), (51, 'EPUB', 'passwd')")
        }
        #expect(try CalibreLibraryReader.read(calibre.folder).books.map(\.candidate.metadata.title) == ["Fine"])
    }

    @Test func CB5_broughtInTheBooksAreCopiesWithTheirDetailsAndCalibreIsAsItWas() throws {
        let f = try F().knowsFilesAgain()
        let calibre = try Calibre(in: f.base)
        try calibre.add(
            "The Long Road", authors: ["Ann Author"], formats: ["EPUB", "PDF"], series: ("The Saga", 2), tags: ["Fantasy", "to-read"],
            rating: 8, comment: "<p>Good.</p>")
        try calibre.add("Other Book", authors: ["Bea Writer"], formats: ["PDF"], timestamp: "2001-02-03 04:05:06+00:00")
        let before = try calibre.snapshot()

        let read = try f.service.scanCalibreLibrary(calibre.folder)
        #expect(read.scan.candidates.count == 2 && read.scan.alreadyInLibrary.isEmpty && read.extras.count == 2)
        let result = try f.service.importItems(read.scan.candidates.map { ImportItem(candidate: $0) }, options: ImportOptions(mode: .copy))
        for (candidate, outcome) in zip(read.scan.candidates, result.outcomes) {
            let id = try f.importedId(outcome)
            let folder = try #require(candidate.sourceFolder)
            try f.service.apply(try #require(read.extras[folder]), toBook: id)
        }
        #expect(try calibre.snapshot() == before)

        let road = try #require(try f.store.books().first { $0.title == "The Long Road" })
        #expect(road.authors == ["Ann Author"] && road.series == "The Saga" && road.seriesNumber == "2")
        #expect(road.genres == ["Fantasy"] && road.tags == ["to-read"] && road.rating == 4 && road.summary == "Good.")
        #expect(road.dateAdded == Date(timeIntervalSince1970: 1_588_336_496))
        #expect(try f.store.files(bookId: try #require(road.id)).map(\.format) == [.epub, .pdf])
        #expect(f.service.covers.url(for: try #require(road.id)) != nil)
        let other = try #require(try f.store.books().first { $0.title == "Other Book" })
        #expect(other.dateAdded == Date(timeIntervalSince1970: 981_173_106) && other.rating == 0 && other.tags.isEmpty)

        // Looked at again, there is nothing left to bring in.
        let again = try f.service.scanCalibreLibrary(calibre.folder)
        #expect(again.scan.candidates.isEmpty && again.scan.alreadyInLibrary.count == 3)
    }

    @Test func CB6_twoEntriesOfOneBookComeInAsOneWithBothSetsOfExtras() throws {
        let f = try F()
        let calibre = try Calibre(in: f.base)
        let first = try calibre.add("Twice", authors: ["Ann Author"], formats: ["EPUB"], tags: ["one"], rating: 4, timestamp: "2020-05-01 12:34:56+00:00")
        try calibre.add("twice", authors: ["Ann Author"], formats: ["PDF"], cover: false, tags: ["two"], rating: 10, timestamp: "2010-05-01 12:34:56+00:00")
        try calibre.add("Twice", authors: ["Somebody Else"], formats: ["PDF"])
        let read = try f.service.scanCalibreLibrary(calibre.folder)
        #expect(read.scan.candidates.count == 2)
        let joined = try #require(read.scan.candidates.first { $0.sourceFolder == first })
        #expect(joined.files.map(\.url.pathExtension) == ["epub", "pdf"] && joined.coverBeside != nil)
        let extras = try #require(read.extras[first])
        #expect(extras.tags == ["one", "two"] && extras.rating == 5 && extras.added == Date(timeIntervalSince1970: 1_272_717_296))
        let result = try f.service.importItems(read.scan.candidates.map { ImportItem(candidate: $0) }, options: ImportOptions(mode: .copy))
        #expect(result.outcomes.allSatisfy { if case .imported = $0 { true } else { false } })
    }

    @Test func CB7_whatABookAlreadyHasIsNotLostToCalibresExtras() throws {
        let f = try F()
        var mine = Book(metadata: BookMetadata(title: "Mine", authors: ["A"]), folderPath: nil, needsAttention: false, dateAdded: Date(timeIntervalSince1970: 1000))
        mine.tags = ["kept"]
        mine.rating = 2
        let id = try #require(try f.store.insert(mine, files: []).id)
        var extras = CalibreExtras()
        extras.tags = ["Kept", "new"]
        extras.rating = 5
        extras.added = Date(timeIntervalSince1970: 5000)
        try f.service.apply(extras, toBook: id)
        let after = try #require(try f.store.book(id: id))
        #expect(after.tags == ["kept", "new"] && after.rating == 2 && after.dateAdded == Date(timeIntervalSince1970: 1000))
        try f.service.apply(extras, toBook: 999)
    }
}
