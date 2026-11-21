import Foundation
import GRDB

/// The library catalogue: a SQLite database inside the library folder.
public final class LibraryStore: Sendable {
    public static let databaseFileName = "VoxCarrel.sqlite"

    public let libraryRoot: URL
    let dbQueue: DatabaseQueue

    /// Opens (creating if needed) the catalogue inside `libraryRoot`.
    public init(libraryRoot: URL) throws {
        self.libraryRoot = libraryRoot
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(
            path: libraryRoot.appendingPathComponent(Self.databaseFileName).path)
        try Self.migrator.migrate(dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "book") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("subtitle", .text)
                t.column("authors", .text).notNull()
                t.column("narrators", .text).notNull()
                t.column("series", .text)
                t.column("seriesNumber", .text)
                t.column("genre", .text)
                t.column("year", .integer)
                t.column("publisher", .text)
                t.column("summary", .text)
                t.column("language", .text)
                t.column("isbn", .text)
                t.column("asin", .text)
                t.column("durationSeconds", .double)
                t.column("pageCount", .integer)
                t.column("tags", .text).notNull()
                t.column("rating", .integer).notNull()
                t.column("folderPath", .text)
                t.column("needsAttention", .boolean).notNull()
                t.column("dateAdded", .datetime).notNull()
                t.column("readStatus", .text).notNull()
                t.column("dateStarted", .datetime)
                t.column("dateFinished", .datetime)
            }
            try db.create(table: "bookFile") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("bookId", .integer).notNull().indexed()
                    .references("book", onDelete: .cascade)
                t.column("path", .text).notNull()
                t.column("format", .text).notNull()
                t.column("role", .text).notNull()
                t.column("position", .integer).notNull()
            }
            try db.create(table: "collection") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
            }
            try db.create(table: "collectionBook") { t in
                t.column("collectionId", .integer).notNull()
                    .references("collection", onDelete: .cascade)
                t.column("bookId", .integer).notNull()
                    .references("book", onDelete: .cascade)
                t.primaryKey(["collectionId", "bookId"])
            }
            try db.create(table: "operationBatch") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("label", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "operationMove") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("batchId", .integer).notNull().indexed()
                    .references("operationBatch", onDelete: .cascade)
                t.column("fromPath", .text).notNull()
                t.column("toPath", .text).notNull()
                t.column("wasCopy", .boolean).notNull()
            }
            try db.create(virtualTable: "bookSearch", using: FTS5()) { t in
                t.synchronize(withTable: "book")
                t.column("title")
                t.column("authors")
                t.column("narrators")
                t.column("series")
                t.column("tags")
            }
        }
        return migrator
    }

    // MARK: Paths

    /// Absolute location of a stored file.
    public func url(for file: BookFile) -> URL {
        file.path.hasPrefix("/")
            ? URL(fileURLWithPath: file.path)
            : libraryRoot.appendingPathComponent(file.path)
    }

    /// The form a file URL is stored in: relative when inside the library, else absolute.
    public func storedPath(for url: URL) -> String {
        let rootPrefix = libraryRoot.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPrefix) ? String(path.dropFirst(rootPrefix.count)) : path
    }

    // MARK: Books

    /// Inserts a book and its files; returns the book with its new id.
    @discardableResult
    public func insert(_ book: Book, files: [BookFile]) throws -> Book {
        try dbQueue.write { db in
            var book = book
            try book.insert(db)
            for var file in files {
                file.id = nil
                file.bookId = book.id
                try file.insert(db)
            }
            return book
        }
    }

    public func update(_ book: Book) throws {
        try dbQueue.write { db in try book.update(db) }
    }

    public func deleteBook(id: Int64) throws {
        _ = try dbQueue.write { db in try Book.deleteOne(db, key: id) }
    }

    public func book(id: Int64) throws -> Book? {
        try dbQueue.read { db in try Book.fetchOne(db, key: id) }
    }

    /// All books sorted by title, optionally filtered.
    /// - Parameter role: Only books with at least one file of this role, so
    ///   `.audio` is the Audiobooks list and `.ebook` the Ebooks list.
    public func books(
        having role: FileRole? = nil, needsAttention: Bool? = nil, readStatus: ReadStatus? = nil
    ) throws -> [Book] {
        try dbQueue.read { db in
            var request = Book.order(Column("title").collating(.nocase))
            if let role {
                request = request.filter(
                    sql: """
                        EXISTS (SELECT 1 FROM bookFile
                                WHERE bookFile.bookId = book.id AND bookFile.role = ?)
                        """,
                    arguments: [role.rawValue])
            }
            if let needsAttention {
                request = request.filter(Column("needsAttention") == needsAttention)
            }
            if let readStatus {
                request = request.filter(Column("readStatus") == readStatus.rawValue)
            }
            return try request.fetchAll(db)
        }
    }

    /// Books whose title, authors, narrators, series or tags contain words
    /// starting with every word of `text`. Blank text returns all books; text
    /// with nothing searchable in it (only punctuation, say) returns none.
    public func search(_ text: String) throws -> [Book] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return try books()
        }
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: text) else {
            return []
        }
        return try dbQueue.read { db in
            try Book.fetchAll(db, sql: """
                SELECT book.* FROM book
                JOIN bookSearch ON bookSearch.rowid = book.id
                WHERE bookSearch MATCH ?
                ORDER BY book.title COLLATE NOCASE
                """, arguments: [pattern])
        }
    }

    // MARK: Files

    /// A book's files in position order.
    public func files(bookId: Int64) throws -> [BookFile] {
        try dbQueue.read { db in
            try BookFile.filter(Column("bookId") == bookId).order(Column("position")).fetchAll(db)
        }
    }

    public func replaceFiles(bookId: Int64, files: [BookFile]) throws {
        try dbQueue.write { db in
            try BookFile.filter(Column("bookId") == bookId).deleteAll(db)
            for var file in files {
                file.id = nil
                file.bookId = bookId
                try file.insert(db)
            }
        }
    }

    // MARK: Browsing

    /// Every distinct value of a browse field, sorted.
    public func distinctValues(_ field: BrowseField) throws -> [String] {
        let column = field.rawValue
        let sql = field.isList
            ? """
              SELECT DISTINCT j.value FROM book, json_each(book.\(column)) AS j
              WHERE j.value <> ''
              ORDER BY j.value COLLATE NOCASE
              """
            : """
              SELECT DISTINCT \(column) FROM book
              WHERE \(column) IS NOT NULL AND \(column) <> ''
              ORDER BY \(column) COLLATE NOCASE
              """
        return try dbQueue.read { db in try String.fetchAll(db, sql: sql) }
    }

    /// Books having exactly `value` for a browse field, sorted by title.
    public func books(where field: BrowseField, equals value: String) throws -> [Book] {
        let column = field.rawValue
        let condition = field.isList
            ? "EXISTS (SELECT 1 FROM json_each(book.\(column)) WHERE value = ?)"
            : "book.\(column) = ?"
        return try dbQueue.read { db in
            try Book.fetchAll(
                db,
                sql: "SELECT * FROM book WHERE \(condition) ORDER BY title COLLATE NOCASE",
                arguments: [value])
        }
    }

    // MARK: Collections

    @discardableResult
    public func createCollection(name: String) throws -> BookCollection {
        try dbQueue.write { db in
            var collection = BookCollection(name: name)
            try collection.insert(db)
            return collection
        }
    }

    public func collections() throws -> [BookCollection] {
        try dbQueue.read { db in
            try BookCollection.order(Column("name").collating(.nocase)).fetchAll(db)
        }
    }

    public func add(bookId: Int64, toCollection collectionId: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO collectionBook (collectionId, bookId) VALUES (?, ?)",
                arguments: [collectionId, bookId])
        }
    }

    public func remove(bookId: Int64, fromCollection collectionId: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM collectionBook WHERE collectionId = ? AND bookId = ?",
                arguments: [collectionId, bookId])
        }
    }

    public func books(inCollection collectionId: Int64) throws -> [Book] {
        try dbQueue.read { db in
            try Book.fetchAll(db, sql: """
                SELECT book.* FROM book
                JOIN collectionBook ON collectionBook.bookId = book.id
                WHERE collectionBook.collectionId = ?
                ORDER BY book.title COLLATE NOCASE
                """, arguments: [collectionId])
        }
    }
}

/// One undoable batch of file transfers.
public struct OperationBatch: Equatable, Sendable {
    public var id: Int64
    public var label: String
    public var moves: [MoveRecord]
}

extension LibraryStore {
    /// Saves a batch of completed transfers; returns its id.
    @discardableResult
    public func recordBatch(label: String, moves: [MoveRecord]) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO operationBatch (label, createdAt) VALUES (?, ?)",
                arguments: [label, Date()])
            let batchId = db.lastInsertedRowID
            for move in moves {
                try db.execute(
                    sql: """
                        INSERT INTO operationMove (batchId, fromPath, toPath, wasCopy)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [batchId, move.from, move.to, move.wasCopy])
            }
            return batchId
        }
    }

    /// The most recently recorded batch, or nil when the journal is empty.
    public func lastBatch() throws -> OperationBatch? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT id, label FROM operationBatch ORDER BY id DESC LIMIT 1")
            else { return nil }
            let id: Int64 = row["id"]
            let moves = try Row.fetchAll(
                db,
                sql: "SELECT fromPath, toPath, wasCopy FROM operationMove WHERE batchId = ? ORDER BY id",
                arguments: [id]
            ).map { MoveRecord(from: $0["fromPath"], to: $0["toPath"], wasCopy: $0["wasCopy"]) }
            return OperationBatch(id: id, label: row["label"], moves: moves)
        }
    }

    public func deleteBatch(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM operationBatch WHERE id = ?", arguments: [id])
        }
    }
}
