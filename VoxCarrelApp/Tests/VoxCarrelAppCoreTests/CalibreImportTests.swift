import Foundation
import GRDB
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// CL1 onwards: Import Calibre Library, as the app's model does it. Every calibre
/// library here is one the test makes in a temporary folder.
@MainActor
@Suite struct CalibreImportTests {
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

    /// A started model on a new, empty library that sets aside files it already has.
    private func library() async throws -> Harness {
        let root = try makeTempDir()
        _ = try LibraryStore(libraryRoot: root)
        let h = try Harness(root: root)
        await h.model.start()
        return h
    }

    /// A calibre library of two books: one with everything calibre can say of a book,
    /// one with next to nothing.
    private func twoBooks() throws -> Calibre {
        let calibre = try Calibre(in: try makeTempDir())
        try calibre.add(
            "The Long Road", authors: ["Ann Author"], formats: ["EPUB", "PDF"], series: ("The Saga", 2),
            tags: ["Fantasy", "to-read"], rating: 8, comment: "<p>Good.</p>")
        try calibre.add("Other Book", authors: ["Bea Writer"], formats: ["PDF"], timestamp: "2001-02-03 04:05:06+00:00")
        return calibre
    }

    private func index(_ h: Harness, _ title: String) throws -> Int {
        try #require(h.model.review?.entries.firstIndex { $0.candidate.metadata.title == title }, "no entry titled \(title)")
    }

    @Test func CL1_theReviewShowsTheCalibreLibrarysBooksAndSaysTheyAreCopied() async throws {
        let h = try await library()
        let calibre = try twoBooks()
        h.recordBusyLabels()

        await h.model.beginCalibreImport(calibre.folder)
        await h.model.settle()

        #expect(h.busyLabels == ["Reading the calibre library…"] && h.model.busyLabel == nil && h.model.alert == nil)
        let review = try #require(h.model.review)
        #expect(review.entries.map(\.candidate.metadata.title) == ["The Long Road", "Other Book"])
        #expect(review.entries.allSatisfy { $0.included && $0.cover != nil } && review.canImport)
        let road = review.entries[0].candidate
        #expect(road.metadata.series == "The Saga" && road.metadata.genres == ["Fantasy"] && road.files.count == 2)
        // The choice between moving and copying is not offered: it is said instead.
        #expect(!review.offersCopy && review.copyInsteadOfMove)
        #expect(review.calibreNote == "Copied from your calibre library, which is left as it is.")
        #expect(review.tidyingLines.isEmpty)
        // Any other review says nothing of calibre.
        let plain = ImportReview(seeds: [], skipped: [], copyInsteadOfMove: false)
        #expect(plain.calibreNote == nil && plain.calibre == nil && plain.offersCopy)
    }

    // A calibre library tried in place: its books are catalogued where they are, with
    // everything calibre says of them, and not one byte of calibre's is moved, copied
    // or changed. They can be brought in later.
    @Test func CL1b_aCalibreLibraryCanBeTriedInPlace() async throws {
        let h = try await library()
        let calibre = try twoBooks()
        let before = try calibre.snapshot()
        await h.model.beginCalibreImport(calibre.folder)
        await h.model.settle()
        h.model.updateReview { $0.leavesInPlace = true }
        let review = try #require(h.model.review)
        #expect(review.offersInPlace && review.options.leavesInPlace)
        #expect(review.calibreNote == "Catalogued where they are: nothing in your calibre library is moved, copied or changed.")
        await h.model.confirmImport()
        await h.model.settle()
        #expect(h.model.alert == nil)
        #expect(try calibre.snapshot() == before)
        let road = try #require(h.model.rows.first { $0.book.title == "The Long Road" })
        #expect(road.book.keptOutside && road.book.series == "The Saga" && road.outsideFiles.count == 2)
        #expect(road.outsideFiles.allSatisfy { $0.contains(calibre.folder.lastPathComponent) })
        #expect(h.model.rows.filter(\.book.keptOutside).count == 2 && road.coverURL != nil)

        // Brought in as copies: calibre's library is still as it was.
        await h.model.bringIntoLibrary(Set(h.model.rows.map(\.id)), copying: true)
        await h.model.settle()
        #expect(h.model.alert == nil && h.model.rows.allSatisfy { !$0.book.keptOutside && $0.outsideFiles.isEmpty })
        #expect(try calibre.snapshot() == before)
    }

    @Test func CL2_importingCopiesTheBooksWithEverythingCalibreSaysAndLeavesCalibreAsItWas() async throws {
        let h = try await library()
        let calibre = try twoBooks()
        let before = try calibre.snapshot()
        // The setting says move, and so does the review if it is asked to: calibre's
        // books are copied all the same.
        h.model.copyOnImport = false
        await h.model.beginCalibreImport(calibre.folder)
        h.model.updateReview { $0.copyInsteadOfMove = false }
        await h.model.settle()
        #expect(h.model.review?.options.mode == .copy)

        await h.model.confirmImport()
        await h.model.settle()

        #expect(h.model.review == nil && h.model.alert == nil && h.model.busyLabel == nil)
        #expect(try calibre.snapshot() == before)
        #expect(h.model.copyOnImport == false)
        #expect(Set(h.titles) == ["The Long Road", "Other Book"])
        let road = try h.book(try h.id("The Long Road"))
        #expect(road.authors == ["Ann Author"] && road.series == "The Saga" && road.seriesNumber == "2")
        #expect(road.genres == ["Fantasy"] && road.summary == "Good.")
        #expect(road.tags == ["to-read"] && road.rating == 4)
        #expect(road.dateAdded == Date(timeIntervalSince1970: 1_588_336_496))
        let files = try h.fileURLs(try h.id("The Long Road"))
        #expect(Set(files.map(\.pathExtension)) == ["epub", "pdf"])
        #expect(files.allSatisfy { $0.path.hasPrefix(h.root.path) && FileManager.default.fileExists(atPath: $0.path) })
        let covers = LibraryService(store: try h.store()).covers
        let roadId = try h.id("The Long Road")
        let otherId = try h.id("Other Book")
        #expect(covers.url(for: roadId) != nil && covers.url(for: otherId) != nil)
        let other = try h.book(try h.id("Other Book"))
        #expect(other.dateAdded == Date(timeIntervalSince1970: 981_173_106) && other.rating == 0 && other.tags.isEmpty)
    }

    @Test func CL3_aBookThatIsUntickedIsNotImportedAndGetsNothing() async throws {
        let h = try await library()
        let calibre = try twoBooks()
        await h.model.beginCalibreImport(calibre.folder)
        let road = try index(h, "The Long Road")
        h.model.updateReview { $0.entries[road].included = false }
        await h.model.settle()

        await h.model.confirmImport()
        await h.model.settle()

        // The one that is imported is the second of the review and the first of the
        // import: it has its own date, and none of the other's tags or stars.
        #expect(h.titles == ["Other Book"])
        let other = try h.book(try h.id("Other Book"))
        #expect(other.tags.isEmpty && other.rating == 0 && other.dateAdded == Date(timeIntervalSince1970: 981_173_106))
        #expect(try h.store().books().count == 1)
    }

    @Test func CL4_aSecondRunSaysEverythingIsHereAlsoWhenABookIsHidden() async throws {
        let h = try await library()
        let calibre = try twoBooks()
        await h.model.beginCalibreImport(calibre.folder)
        await h.model.confirmImport()
        await h.model.settle()

        await h.model.beginCalibreImport(calibre.folder)
        #expect(h.model.review == nil && h.model.busyLabel == nil)
        #expect(h.model.alert == "Everything in that calibre library is already in your library.")

        // A hidden book is still a book of the library: it is not brought in again.
        h.model.alert = nil
        let other = try await h.select("Other Book")
        await h.model.toggleHidden(for: [other])
        await h.model.settle()
        #expect(try h.book(other).isHidden)
        #expect(h.titles == ["The Long Road"])
        h.model.alert = nil
        await h.model.beginCalibreImport(calibre.folder)
        #expect(h.model.review == nil)
        #expect(h.model.alert == "Everything in that calibre library is already in your library.")
        #expect(try h.store().books().count == 2)

        // One new book in calibre is the only one offered, and the rest are counted.
        h.model.alert = nil
        try calibre.add("Third", authors: ["Cy Third"], formats: ["PDF"])
        await h.model.beginCalibreImport(calibre.folder)
        await h.model.settle()
        let review = try #require(h.model.review)
        #expect(review.entries.map(\.candidate.metadata.title) == ["Third"] && review.alreadyInLibrary == 3)
        #expect(review.tidyingLines == ["3 files are already in your library and are left where they are."])
    }

    @Test func CL5_aFolderThatIsNoCalibreLibraryOrHasNothingToKeepIsSaidInASentence() async throws {
        let h = try await library()
        let folder = try makeTempDir()
        h.recordBusyLabels()
        await h.model.beginCalibreImport(folder)
        #expect(h.model.alert == "That folder is not a calibre library: it has no metadata.db.")
        #expect(h.model.review == nil && h.model.busyLabel == nil)

        try Data("not a database".utf8).write(to: folder.appendingPathComponent("metadata.db"))
        await h.model.beginCalibreImport(folder)
        #expect(h.model.alert == "The calibre library's catalogue could not be read.")
        #expect(h.model.review == nil && h.model.busyLabel == nil)

        let calibre = try Calibre(in: try makeTempDir())
        try calibre.add("Only Kindle Format", authors: ["A"], formats: ["KFX"])
        await h.model.beginCalibreImport(calibre.folder)
        #expect(h.model.alert == "That calibre library has no books VoxCarrel can keep.")
        #expect(h.model.review == nil && h.model.busyLabel == nil)
        #expect(h.busyLabels == Array(repeating: "Reading the calibre library…", count: 3))
        #expect(try h.store().books().isEmpty)
    }

    @Test func CL6_whatCalibreListsThatIsLeftOutIsCounted() async throws {
        let h = try await library()
        let calibre = try Calibre(in: try makeTempDir())
        try calibre.add("Here", authors: ["C"], formats: ["PDF", "KFX"])
        try calibre.add("Only Kindle Format", authors: ["A"], formats: ["KFX"])
        await h.model.beginCalibreImport(calibre.folder)
        await h.model.settle()
        #expect(h.model.review?.tidyingLines == [
            "1 book calibre lists has no file VoxCarrel keeps and is left out.", "Left out by kind: KFX 2.",
        ])
        h.model.cancelImport()

        try calibre.add("Comic", authors: ["B"], formats: ["CBZ"])
        try calibre.add("Gone From Disk", authors: ["D"], formats: ["EPUB"], missing: ["EPUB"])
        await h.model.beginCalibreImport(calibre.folder)
        await h.model.settle()
        #expect(h.model.review?.tidyingLines == [
            "3 books calibre lists have no file VoxCarrel keeps and are left out.", "Left out by kind: CBZ 1, KFX 2.",
        ])
        // Nothing left out, nothing said.
        let none = ImportReview(
            seeds: [], skipped: [], copyInsteadOfMove: true,
            calibre: ImportReview.CalibreSource(extras: [:], withoutFiles: 0, formatsLeftOut: [:]))
        #expect(none.tidyingLines.isEmpty)
    }

    @Test func CL7_aBookAddedToOneOfTheLibrarysGetsCalibresTagsAndKeepsItsOwnRating() async throws {
        let h = try await library()
        let first = try Calibre(in: try makeTempDir())
        try first.add("Mine", authors: ["Ann Author"], formats: ["PDF"], tags: ["kept"], rating: 4)
        await h.model.beginCalibreImport(first.folder)
        await h.model.confirmImport()
        await h.model.settle()
        let mine = try h.id("Mine")
        let imported = try h.book(mine)
        #expect(imported.tags == ["kept"] && imported.rating == 2)

        // Another calibre library has the same book as another file, and says more of it.
        let second = try Calibre(in: try makeTempDir())
        try second.add(
            "Mine", authors: ["Ann Author"], formats: ["EPUB"], tags: ["Kept", "new"], rating: 10,
            timestamp: "2010-05-01 12:34:56+00:00")
        let before = try second.snapshot()
        await h.model.beginCalibreImport(second.folder)
        await h.model.settle()
        let entry = try #require(h.model.review?.entries.first)
        #expect(entry.existingMatch?.id == mine && entry.isAddedToExisting)
        await h.model.confirmImport()
        await h.model.settle()

        #expect(try h.store().books().count == 1)
        #expect(try second.snapshot() == before)
        let after = try h.book(mine)
        #expect(after.tags == ["kept", "new"] && after.rating == 2)
        #expect(after.dateAdded == Date(timeIntervalSince1970: 1_272_717_296))
        let kinds = Set(try h.fileURLs(mine).map(\.pathExtension))
        #expect(kinds == ["pdf", "epub"])
    }

    @Test func CL8_theCommandIsNamedAndCanBeChosenWhenImportCan() async throws {
        #expect(AppModel.calibreImportMenuTitle == "Import Calibre Library…")
        let h = try await library()
        #expect(h.model.canImport)
        let calibre = try twoBooks()
        await h.model.beginCalibreImport(calibre.folder)
        await h.model.settle()
        // While a review is open no import can be begun, and asking again changes nothing.
        #expect(!h.model.canImport)
        let open = try #require(h.model.review)
        h.recordBusyLabels()
        await h.model.beginCalibreImport(calibre.folder)
        #expect(h.busyLabels.isEmpty && h.model.review == open && h.model.alert == nil)
        h.model.cancelImport()
        #expect(h.model.canImport)

        // With no library open there is nothing to import into.
        let none = try Harness(root: try makeTempDir(), choose: false)
        await none.model.start()
        #expect(!none.model.canImport)
        await none.model.beginCalibreImport(calibre.folder)
        #expect(none.model.review == nil && none.model.alert == nil)
    }

    @Test func CL9_booksMergedOrSplitInTheReviewKeepWhatCalibreSaidOfTheirFiles() async throws {
        let h = try await library()
        let calibre = try Calibre(in: try makeTempDir())
        try calibre.add("One", authors: ["Ann Author"], formats: ["EPUB", "PDF"], tags: ["first"], rating: 6)
        try calibre.add(
            "Two", authors: ["Bea Writer"], formats: ["PDF"], tags: ["second"], rating: 10,
            timestamp: "2001-02-03 04:05:06+00:00")
        await h.model.beginCalibreImport(calibre.folder)
        await h.model.settle()
        // The PDF of the first is made a book of its own; the second is merged into the first.
        let one = try #require(h.model.review?.entries.first)
        let pdf = try #require(one.candidate.files.first { $0.url.pathExtension == "pdf" }).url
        h.model.updateReview { $0.detach(file: pdf, from: one.id) }
        await h.model.settle()
        let split = try index(h, "One") + 1
        h.model.updateReview { $0.entries[split].candidate.metadata.title = "One Apart" }
        let two = try #require(h.model.review?.entries.last).id
        h.model.updateReview { $0.merge([one.id, two]) }
        await h.model.settle()
        #expect(h.model.review?.entries.map(\.candidate.metadata.title) == ["One", "One Apart"])

        await h.model.confirmImport()
        await h.model.settle()

        let merged = try h.book(try h.id("One"))
        #expect(merged.tags == ["first", "second"] && merged.rating == 3)
        #expect(merged.dateAdded == Date(timeIntervalSince1970: 981_173_106))
        let apart = try h.book(try h.id("One Apart"))
        #expect(apart.tags == ["first"] && apart.rating == 3)
    }
}
