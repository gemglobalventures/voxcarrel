import Foundation
import GRDB
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

@Suite struct LibraryChangeTests {
    func makeStore() throws -> LibraryStore {
        try LibraryStore(libraryRoot: makeTempDir())
    }

    func book(_ title: String, author: String = "Andy Weir") -> Book {
        // A whole-second date, so a book read back equals the one written.
        Book(metadata: BookMetadata(title: title, authors: [author]),
             dateAdded: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func file(_ path: String, _ format: FileFormat = .m4b, _ role: FileRole = .audio, _ position: Int = 0)
        -> BookFile
    {
        BookFile(path: path, format: format, role: role, position: position)
    }

    func count(_ table: String, in store: LibraryStore) throws -> Int {
        try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    let moves = [
        MoveRecord(from: "/in/a.mp3", to: "/lib/01.mp3", wasCopy: false),
        MoveRecord(from: "/in/b.mp3", to: "/lib/02.mp3", wasCopy: true),
    ]

    // S1: a database made by Plan 1's schema opens, keeps its data and gains the new columns.
    @Test func v1DatabaseUpgrades() throws {
        let root = try makeTempDir()
        let path = root.appendingPathComponent(LibraryStore.databaseFileName).path
        do {
            let queue = try DatabaseQueue(path: path)
            try LibraryStore.migrator.migrate(queue, upTo: "v1")
            try queue.write { db in
                // The v1 tables have none of the v2 columns.
                #expect(try db.columns(in: "book").contains { $0.name == "appOnlyFields" } == false)
                #expect(try db.columns(in: "bookFile").contains { $0.name == "writeProblem" } == false)
                #expect(try db.columns(in: "operationBatch").contains { $0.name == "snapshot" } == false)
                try db.execute(sql: """
                    INSERT INTO book (title, authors, narrators, tags, rating, needsAttention,
                                      dateAdded, readStatus)
                    VALUES ('Old Book', '["Old Author"]', '["Old Narrator"]', '["kept"]', 4, 0,
                            '2025-01-02 03:04:05.000', 'finished')
                    """)
                let bookId = db.lastInsertedRowID
                try db.execute(sql: """
                    INSERT INTO bookFile (bookId, path, format, role, position)
                    VALUES (?, 'Old Author/Old Book/Old Book.m4b', 'm4b', 'audio', 0)
                    """, arguments: [bookId])
                try db.execute(sql: """
                    INSERT INTO operationBatch (label, createdAt) VALUES ('old', '2025-01-02 03:04:05.000')
                    """)
                try db.execute(sql: """
                    INSERT INTO operationMove (batchId, fromPath, toPath, wasCopy)
                    VALUES (?, '/in/a.mp3', '/lib/01.mp3', 0)
                    """, arguments: [db.lastInsertedRowID])
            }
            try queue.close()
        }

        let store = try LibraryStore(libraryRoot: root)

        let books = try store.books()
        #expect(books.count == 1)
        let old = try #require(books.first)
        #expect(old.title == "Old Book")
        #expect(old.authors == ["Old Author"])
        #expect(old.narrators == ["Old Narrator"])
        #expect(old.tags == ["kept"])
        #expect(old.rating == 4)
        #expect(old.readStatus == .finished)
        #expect(old.appOnlyFields == [])
        let files = try store.files(bookId: try #require(old.id))
        #expect(files.map(\.path) == ["Old Author/Old Book/Old Book.m4b"])
        #expect(files.first?.writeProblem == nil)
        let batch = try #require(try store.lastBatch())
        #expect(batch.label == "old")
        #expect(batch.moves == [moves[0]])
        #expect(batch.snapshot == nil)
        // Search still finds the old row, and the upgraded book can be updated.
        #expect(try store.search("old").map(\.title) == ["Old Book"])
        var edited = old
        edited.appOnlyFields = [.narrators]
        try store.update(edited)
        #expect(try store.book(id: try #require(old.id))?.appOnlyFields == [.narrators])
    }

    // S1: opening an already-upgraded database again changes nothing.
    @Test func reopeningAnUpgradedDatabaseKeepsItsData() throws {
        let root = try makeTempDir()
        var b = book("Artemis")
        b.appOnlyFields = [.cover]
        let saved = try LibraryStore(libraryRoot: root).insert(b, files: [])
        let reopened = try LibraryStore(libraryRoot: root)
        #expect(try reopened.book(id: try #require(saved.id)) == saved)
    }

    // S3
    @Test func insertUpdateAndFilesInOneApply() throws {
        let store = try makeStore()
        var existing = try store.insert(book("Dune", author: "Frank Herbert"), files: [
            file("Frank Herbert/Dune/Dune 1.mp3", .mp3, .audio, 0),
            file("Frank Herbert/Dune/Dune 2.mp3", .mp3, .audio, 1),
        ])
        let existingId = try #require(existing.id)
        let oldFileIds = try store.files(bookId: existingId).compactMap(\.id)
        existing.title = "Dune (Revised)"

        // Files arrive carrying stale ids and book ids; both are replaced.
        var stale = file("Frank Herbert/Dune/Dune.epub", .epub, .ebook, 1)
        stale.id = 999
        stale.bookId = 999
        var change = LibraryChange()
        change.writes = [
            .init(book: book("Project Hail Mary"), files: [
                file("Andy Weir/Project Hail Mary/Project Hail Mary.m4b", .m4b, .audio, 0),
                file("Andy Weir/Project Hail Mary/Project Hail Mary.epub", .epub, .ebook, 1),
            ]),
            .init(book: existing, files: [
                file("Frank Herbert/Dune/Dune.m4b", .m4b, .audio, 0),
                stale,
                file("Frank Herbert/Dune/Extras/Map.pdf", .pdf, .extra, 2),
            ]),
        ]

        let result = try store.apply(change)

        #expect(result.batchId == nil)
        #expect(result.books.count == 2)
        #expect(result.books.map(\.title) == ["Project Hail Mary", "Dune (Revised)"])
        let newId = try #require(result.books[0].id)
        #expect(newId != existingId)
        #expect(result.books[1].id == existingId)
        #expect(try store.book(id: newId) == result.books[0])
        #expect(try store.book(id: existingId)?.title == "Dune (Revised)")
        #expect(try store.books().count == 2)

        let newFiles = try store.files(bookId: newId)
        #expect(newFiles.map(\.path) == [
            "Andy Weir/Project Hail Mary/Project Hail Mary.m4b",
            "Andy Weir/Project Hail Mary/Project Hail Mary.epub",
        ])
        #expect(newFiles.map(\.format) == [.m4b, .epub])
        #expect(newFiles.map(\.role) == [.audio, .ebook])
        #expect(newFiles.allSatisfy { $0.bookId == newId })

        let replaced = try store.files(bookId: existingId)
        #expect(replaced.map(\.path) == [
            "Frank Herbert/Dune/Dune.m4b",
            "Frank Herbert/Dune/Dune.epub",
            "Frank Herbert/Dune/Extras/Map.pdf",
        ])
        #expect(replaced.map(\.position) == [0, 1, 2])
        #expect(replaced.allSatisfy { $0.bookId == existingId })
        // Fresh ids: none of the old rows, nor the stale id, survive.
        let replacedIds = replaced.compactMap(\.id)
        #expect(replacedIds.count == 3)
        #expect(Set(replacedIds).isDisjoint(with: oldFileIds))
        #expect(!replacedIds.contains(999))
        #expect(try count("bookFile", in: store) == 5)
    }

    // S3: an empty file list removes every file row of an updated book.
    @Test func updateWithNoFilesClearsTheFileList() throws {
        let store = try makeStore()
        let saved = try store.insert(book("Dune"), files: [file("Dune.m4b")])
        var change = LibraryChange()
        change.writes = [.init(book: saved, files: [])]
        try store.apply(change)
        #expect(try store.files(bookId: try #require(saved.id)).isEmpty)
    }

    // S1
    @Test func newFieldsRoundTrip() throws {
        let store = try makeStore()
        var b = book("Project Hail Mary")
        b.appOnlyFields = [.narrators, .cover]
        var locked = file("Andy Weir/Project Hail Mary/Project Hail Mary.m4b")
        locked.writeProblem = "locked"
        var change = LibraryChange()
        change.writes = [.init(book: b, files: [locked, file("a.epub", .epub, .ebook, 1)])]

        let saved = try #require(try store.apply(change).books.first)

        #expect(saved.appOnlyFields == [.narrators, .cover])
        let id = try #require(saved.id)
        #expect(try store.book(id: id)?.appOnlyFields == [.narrators, .cover])
        #expect(try store.files(bookId: id).map(\.writeProblem) == ["locked", nil])
        // The older entry points carry the new fields too.
        let viaInsert = try store.insert(b, files: [locked])
        let insertId = try #require(viaInsert.id)
        #expect(try store.book(id: insertId)?.appOnlyFields == [.narrators, .cover])
        #expect(try store.files(bookId: insertId).map(\.writeProblem) == ["locked"])
    }

    // S1: new values default to nothing, and the helper types are Codable.
    @Test func newFieldsDefaultAndCode() throws {
        #expect(book("x").appOnlyFields == [])
        #expect(file("x.m4b").writeProblem == nil)
        let fields = try JSONDecoder().decode(
            [MetadataField].self, from: JSONEncoder().encode([MetadataField.narrators, .cover]))
        #expect(fields == [.narrators, .cover])
        let part = try JSONDecoder().decode(
            PartPosition.self, from: JSONEncoder().encode(PartPosition(index: 2, count: 5)))
        #expect(part == PartPosition(index: 2, count: 5))
    }

    // S4
    @Test func deleteCascades() throws {
        let store = try makeStore()
        let doomed = try store.insert(book("Doomed"), files: [file("Doomed/1.mp3", .mp3), file("Doomed/2.mp3", .mp3)])
        let kept = try store.insert(book("Kept"), files: [file("Kept/Kept.m4b")])
        let doomedId = try #require(doomed.id)
        let keptId = try #require(kept.id)
        let shelf = try #require(try store.createCollection(name: "Shelf").id)
        try store.add(bookId: doomedId, toCollection: shelf)
        try store.add(bookId: keptId, toCollection: shelf)

        var change = LibraryChange()
        change.deletedBookIds = [doomedId, 987_654]  // an unknown id is not an error
        let result = try store.apply(change)

        #expect(result.books.isEmpty)
        #expect(try store.book(id: doomedId) == nil)
        #expect(try store.files(bookId: doomedId).isEmpty)
        #expect(try count("bookFile", in: store) == 1)
        #expect(try store.books(inCollection: shelf).map(\.id) == [keptId])
        #expect(try count("collectionBook", in: store) == 1)
        #expect(try store.collections().count == 1)
        #expect(try store.search("doomed").isEmpty)
    }

    // S2
    @Test func failureChangesNothing() throws {
        let store = try makeStore()
        let victim = try store.insert(book("Victim"), files: [file("Victim/Victim.m4b")])
        let victimId = try #require(victim.id)
        let shelf = try #require(try store.createCollection(name: "Shelf").id)
        try store.add(bookId: victimId, toCollection: shelf)
        let earlier = try store.recordBatch(label: "earlier", moves: [moves[0]])

        var ghost = book("Ghost")
        ghost.id = 424_242
        var change = LibraryChange()
        change.writes = [
            .init(book: book("First"), files: [file("First/First.m4b")]),
            .init(book: ghost, files: [file("Ghost/Ghost.m4b")]),
        ]
        change.deletedBookIds = [victimId]
        change.batch = .init(label: "doomed", moves: [moves[1]], snapshot: Data([1, 2, 3]))
        change.clearsJournal = true

        #expect(throws: (any Error).self) { try store.apply(change) }

        #expect(try store.books().map(\.title) == ["Victim"])
        #expect(try store.files(bookId: victimId).map(\.path) == ["Victim/Victim.m4b"])
        #expect(try count("bookFile", in: store) == 1)
        #expect(try store.books(inCollection: shelf).map(\.id) == [victimId])
        let batch = try #require(try store.lastBatch())
        #expect(batch.id == earlier)
        #expect(batch.label == "earlier")
        #expect(batch.moves == [moves[0]])
        #expect(try count("operationBatch", in: store) == 1)
        #expect(try count("operationMove", in: store) == 1)
    }

    // S5, S6
    @Test func journalHoldsTheNewestBatches() throws {
        let store = try makeStore()
        // Bytes that are neither text nor JSON, to show the store does not interpret them.
        let snapshot = Data([0x00, 0xFF, 0x7B, 0x00, 0x80, 0x0A])

        var first = LibraryChange()
        first.batch = .init(label: "one", moves: moves, snapshot: Data("{}".utf8))
        let firstId = try #require(try store.apply(first).batchId)

        var second = LibraryChange()
        second.batch = .init(label: "two", moves: [moves[1]], snapshot: snapshot)
        let secondId = try #require(try store.apply(second).batchId)

        #expect(secondId != firstId)
        var last = try #require(try store.lastBatch())
        #expect(last.id == secondId)
        #expect(last.label == "two")
        #expect(last.moves == [moves[1]])
        #expect(last.snapshot == snapshot)
        // The one before it is kept behind it.
        #expect(try count("operationBatch", in: store) == 2)
        #expect(try count("operationMove", in: store) == 3)

        // S6: the older entry point also adds one, with no snapshot.
        let thirdId = try store.recordBatch(label: "three", moves: moves)
        last = try #require(try store.lastBatch())
        #expect(last.id == thirdId)
        #expect(last.label == "three")
        #expect(last.moves == moves)
        #expect(last.snapshot == nil)
        #expect(try count("operationBatch", in: store) == 3)
        #expect(try count("operationMove", in: store) == 5)
        #expect(try store.batches().map(\.label) == ["three", "two", "one"])

        // S5: clearing empties both tables.
        var clear = LibraryChange()
        clear.clearsJournal = true
        #expect(try store.apply(clear).batchId == nil)
        #expect(try store.lastBatch() == nil)
        #expect(try count("operationBatch", in: store) == 0)
        #expect(try count("operationMove", in: store) == 0)
    }

    // S5: a change that neither records nor clears leaves the journal alone; one that
    // does both ends with just the new batch.
    @Test func journalIsUntouchedUnlessAsked() throws {
        let store = try makeStore()
        let kept = try store.recordBatch(label: "kept", moves: [moves[0]])

        var change = LibraryChange()
        change.writes = [.init(book: book("Artemis"), files: [])]
        #expect(try store.apply(change).batchId == nil)
        #expect(try store.lastBatch()?.id == kept)

        var both = LibraryChange()
        both.clearsJournal = true
        both.batch = .init(label: "new", moves: [], snapshot: nil)
        let id = try #require(try store.apply(both).batchId)
        let last = try #require(try store.lastBatch())
        #expect(last.id == id)
        #expect(last.moves.isEmpty)
        #expect(last.snapshot == nil)
        #expect(try count("operationBatch", in: store) == 1)
        #expect(try count("operationMove", in: store) == 0)
    }

    // Migration v3: a v2 database opens, keeps its data, and gains `bookFile.originalName`.
    @Test func v2DatabaseUpgrades() throws {
        let root = try makeTempDir()
        let path = root.appendingPathComponent(LibraryStore.databaseFileName).path
        do {
            let queue = try DatabaseQueue(path: path)
            try LibraryStore.migrator.migrate(queue, upTo: "v2")
            try queue.write { db in
                #expect(try db.columns(in: "bookFile").contains { $0.name == "originalName" } == false)
                try db.execute(sql: """
                    INSERT INTO book (title, authors, narrators, tags, rating, needsAttention,
                                      dateAdded, readStatus, appOnlyFields)
                    VALUES ('Old Book', '["Old Author"]', '[]', '[]', 0, 0,
                            '2025-01-02 03:04:05.000', 'unread', '["cover"]')
                    """)
                try db.execute(sql: """
                    INSERT INTO bookFile (bookId, path, format, role, position, writeProblem)
                    VALUES (?, 'Old Author/Old Book/Extras/Map.pdf', 'pdf', 'extra', 0, 'locked')
                    """, arguments: [db.lastInsertedRowID])
            }
            try queue.close()
        }

        let store = try LibraryStore(libraryRoot: root)

        let old = try #require(try store.books().first)
        #expect(old.appOnlyFields == [.cover])
        var files = try store.files(bookId: try #require(old.id))
        #expect(files.map(\.path) == ["Old Author/Old Book/Extras/Map.pdf"])
        #expect(files.map(\.writeProblem) == ["locked"])
        #expect(files.map(\.originalName) == [nil])
        // The new column round-trips.
        files[0].originalName = "Map.pdf"
        let oldId = try #require(old.id)
        try store.replaceFiles(bookId: oldId, files: files)
        #expect(try store.files(bookId: oldId).map(\.originalName) == ["Map.pdf"])
    }

    // Saved data written before a field existed still decodes, the field taking its default.
    @Test func recordsDecodeWithFieldsAbsent() throws {
        let book = try JSONDecoder().decode(Book.self, from: Data(#"{"id":4,"title":"Dune","unknown":1}"#.utf8))
        #expect(book.id == 4)
        #expect(book.title == "Dune")
        #expect(book.authors == [])
        #expect(book.rating == 0)
        #expect(book.readStatus == .unread)
        #expect(book.appOnlyFields == [])
        let file = try JSONDecoder().decode(
            BookFile.self, from: Data(#"{"path":"A/B/B.m4b","format":"m4b","role":"audio","later":true}"#.utf8))
        #expect(file.path == "A/B/B.m4b")
        #expect(file.position == 0)
        #expect(file.writeProblem == nil)
        #expect(file.originalName == nil)
        let metadata = try JSONDecoder().decode(BookMetadata.self, from: Data(#"{"title":"Dune"}"#.utf8))
        #expect(metadata == BookMetadata(title: "Dune"))
        // What says which file it is cannot be defaulted.
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(BookFile.self, from: Data(#"{"format":"m4b","role":"audio"}"#.utf8))
        }
    }
}
