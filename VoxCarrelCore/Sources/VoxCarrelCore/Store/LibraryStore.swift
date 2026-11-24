import Foundation
import GRDB

/// The library catalogue: a SQLite database inside the library folder.
public final class LibraryStore: Sendable {
    public static let databaseFileName = "VoxCarrel.sqlite"

    /// The library folder in canonical form (`LibraryLayout.canonicalFolder`): however the
    /// folder was named when the store was opened, every path the library builds or
    /// stores starts from this one spelling.
    public let libraryRoot: URL
    let dbQueue: DatabaseQueue

    /// Opens (creating if needed) the catalogue inside `libraryRoot`.
    ///
    /// A catalogue an earlier version left, with books in it, is copied beside itself
    /// before its genres are converted (`copyBeforeGenresName`): an earlier version
    /// cannot read a converted one. When the copy cannot be made,
    /// `LibraryStoreError.copyBeforeGenresFailed` is thrown and the catalogue is as it was.
    public init(libraryRoot: URL) throws {
        let opened = try Self.open(libraryRoot, today: Date(), copyBeforeGenres: LibraryStore.copyWhole)
        self.libraryRoot = opened.root
        dbQueue = opened.queue
    }

    /// As `init(libraryRoot:)`. `today` dates the copy; `copyBeforeGenres` makes it, given
    /// the open catalogue and the path to copy it to. Both are test seams.
    init(
        libraryRoot: URL, today: Date = Date(),
        copyBeforeGenres: (Database, String) throws -> Void = LibraryStore.copyWhole
    ) throws {
        let opened = try Self.open(libraryRoot, today: today, copyBeforeGenres: copyBeforeGenres)
        self.libraryRoot = opened.root
        dbQueue = opened.queue
    }

    /// A catalogue opened and brought up to date, with the folder it is in.
    private struct Opened {
        var root: URL
        var queue: DatabaseQueue
    }

    private static func open(
        _ libraryRoot: URL, today: Date, copyBeforeGenres: (Database, String) throws -> Void
    ) throws -> Opened {
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        let root = LibraryLayout.canonicalFolder(libraryRoot)
        let queue = try DatabaseQueue(path: root.appendingPathComponent(Self.databaseFileName).path)
        try keepCopyBeforeGenres(of: queue, in: root, today: today, copy: copyBeforeGenres)
        try migrator.migrate(queue)
        return Opened(root: root, queue: queue)
    }

    // MARK: The copy kept before genres are converted

    /// The migration that gives books several genres.
    static let genresMigration = "v12"

    /// Copies a catalogue that has books and has not had its genres converted, beside
    /// itself. A new catalogue, one with no books and one already converted get none.
    private static func keepCopyBeforeGenres(
        of queue: DatabaseQueue, in root: URL, today: Date, copy: (Database, String) throws -> Void
    ) throws {
        let isDue = try queue.read { db -> Bool in
            guard try db.tableExists("grdb_migrations"), try db.tableExists("book") else { return false }
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            guard !applied.contains(genresMigration) else { return false }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book") ?? 0 > 0
        }
        guard isDue else { return }

        let taken = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let target = root.appendingPathComponent(copyBeforeGenresName(on: today, taken: taken))
        do {
            // Not in a transaction: the database will not copy itself inside one.
            try queue.writeWithoutTransaction { db in try copy(db, target.path) }
        } catch {
            // Whatever was begun is not a copy.
            try? FileManager.default.removeItem(at: target)
            throw LibraryStoreError.copyBeforeGenresFailed(target.lastPathComponent)
        }
    }

    /// The copy as the database itself makes it: one whole, consistent file, whatever
    /// the catalogue has waiting in files beside it. Nothing is ever replaced.
    static func copyWhole(_ db: Database, to path: String) throws {
        try db.execute(sql: "VACUUM INTO ?", arguments: [path])
    }

    /// The name of the copy made on `today`: "VoxCarrel before genres 2026-11-24.sqlite",
    /// or with " 2", " 3"… before the extension when `taken` (the names in the library
    /// folder) holds that name already, in any capitalisation.
    static func copyBeforeGenresName(on today: Date, taken: [String]) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian)
        format.dateFormat = "yyyy-MM-dd"
        let stem = "VoxCarrel before genres \(format.string(from: today))"
        let used = Set(taken.map { $0.lowercased() })
        var name = "\(stem).sqlite"
        var number = 2
        while used.contains(name.lowercased()) {
            name = "\(stem) \(number).sqlite"
            number += 1
        }
        return name
    }

    /// Whether an error came from the database itself (it could not be opened, read or
    /// written), as against one of the library's own errors. Such an error's text is
    /// written for programmers and should not be shown as it is.
    public static func isDatabaseError(_ error: Error) -> Bool {
        error is DatabaseError
    }

    static var migrator: DatabaseMigrator {
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
        migrator.registerMigration("v2") { db in
            try db.alter(table: "book") { t in
                t.add(column: "appOnlyFields", .text).notNull().defaults(to: "[]")
            }
            try db.alter(table: "bookFile") { t in
                t.add(column: "writeProblem", .text)
            }
            try db.alter(table: "operationBatch") { t in
                t.add(column: "snapshot", .blob)
            }
        }
        migrator.registerMigration("v3") { db in
            try db.alter(table: "bookFile") { t in
                t.add(column: "originalName", .text)
            }
        }
        migrator.registerMigration("v4") { db in
            try db.alter(table: "book") { t in
                t.add(column: "externalCopies", .text).notNull().defaults(to: "[]")
            }
        }
        migrator.registerMigration("v5") { db in
            try db.alter(table: "bookFile") { t in
                t.add(column: "lengthProblem", .text)
            }
        }
        migrator.registerMigration("v6") { db in
            try db.alter(table: "bookFile") { t in
                t.add(column: "lengthUnmeasured", .text)
            }
            // Facts about the library as a whole: what has been done to it once.
            try db.create(table: "libraryNote") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        migrator.registerMigration("v7") { db in
            try db.alter(table: "book") { t in
                t.add(column: "editionKind", .text)
                t.add(column: "partsAppearMissing", .boolean).notNull().defaults(to: false)
            }
        }
        migrator.registerMigration("v8") { db in
            // Folders watched for books that arrive. Paths are this Mac's.
            try db.create(table: "watchFolder") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
                t.column("mode", .text).notNull()
                t.column("isEnabled", .boolean).notNull()
                t.column("includesPDFs", .boolean).notNull()
                t.column("addedAt", .double).notNull()
            }
            // The ledger: files under a watch folder that are not to be offered.
            try db.create(table: "inboxEntry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("folderId", .integer).notNull()
                    .references("watchFolder", onDelete: .cascade)
                t.column("path", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("modifiedAt", .double).notNull()
                t.column("state", .text).notNull()
                    .check { ["baseline", "dismissed", "imported"].contains($0) }
                t.uniqueKey(["folderId", "path"])
            }
        }
        migrator.registerMigration("v9") { db in
            // A series of the library, tied to the series Audible lists it as.
            try db.create(table: "seriesLink") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("seriesKey", .text).notNull().unique()
                t.column("seriesName", .text).notNull()
                t.column("audibleSeriesId", .text).notNull()
                t.column("audibleSeriesTitle", .text).notNull()
                t.column("store", .text).notNull()
                t.column("checkedAt", .double).notNull()
            }
            // Audible's list of that series: one row for each book of it, in series order.
            try db.create(table: "seriesEntry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("linkId", .integer).notNull().indexed()
                    .references("seriesLink", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("number", .text)
                t.column("sort", .double).notNull()
                t.column("title", .text).notNull()
                t.column("asins", .text).notNull()
                t.column("titles", .text).notNull()
                t.column("authors", .text).notNull()
                t.column("narrators", .text).notNull()
                t.column("minutes", .integer)
                t.column("isAbridged", .boolean)
                t.column("releaseDate", .double)
                t.column("isHidden", .boolean).notNull().defaults(to: false)
            }
        }
        migrator.registerMigration("v10") { db in
            // What the owner has chosen for the library as a whole. A key that is absent
            // has its default.
            try db.create(table: "librarySetting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        migrator.registerMigration("v11") { db in
            // Each sending of a book to the phone, with what was sent as JSON. A book
            // that is removed takes its rows with it.
            try db.create(table: "sentRecord") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("bookId", .integer).notNull().indexed()
                    .references("book", onDelete: .cascade)
                t.column("sentAt", .double).notNull()
                t.column("method", .text).notNull()
                t.column("fingerprint", .text).notNull()
            }
        }
        migrator.registerMigration("v12") { db in
            try Self.giveBooksSeveralGenres(db)
        }
        return migrator
    }

    /// The change to a book having several genres. Each book's one genre text becomes
    /// its source wording, and the mapping gives its genres; the text is also recorded
    /// as the tag its files hold, which it was. The library's list of genres is made:
    /// the built-in ones, and one of the owner's own in Other for each name the mapping
    /// did not know. No file is read or written.
    private static func giveBooksSeveralGenres(_ db: Database) throws {
        try db.create(table: "genre") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull().unique().collate(.nocase)
            // A `GenreGroup` raw value.
            t.column("genreGroup", .text).notNull()
            // The name the app ships the genre under; null for one of the owner's own.
            t.column("builtInName", .text)
            t.column("isHidden", .boolean).notNull().defaults(to: false)
            // For a built-in genre merged away: the id of the genre it was merged into.
            t.column("mergedInto", .integer)
        }
        for genre in BuiltInGenre.all {
            try db.execute(
                sql: "INSERT INTO genre (name, genreGroup, builtInName) VALUES (?, ?, ?)",
                arguments: [genre.name, genre.group.rawValue, genre.name])
        }

        // The search index follows the book table, and is made again below with the genres in it.
        try db.dropFTS5SynchronizationTriggers(forTable: "bookSearch")
        try db.drop(table: "bookSearch")
        try db.alter(table: "book") { t in
            t.rename(column: "genre", to: "genreSource")
            t.add(column: "genres", .text).notNull().defaults(to: "[]")
            t.add(column: "genreTag", .text)
        }
        // A text with nothing in it was no genre.
        try db.execute(sql: "UPDATE book SET genreSource = NULL WHERE trim(genreSource) = ''")
        try db.execute(sql: "UPDATE book SET genreTag = genreSource")
        let rows = try Row.fetchAll(
            db, sql: "SELECT id, genreSource FROM book WHERE genreSource IS NOT NULL ORDER BY id")
        for row in rows {
            let id: Int64 = row["id"]
            let text: String = row["genreSource"]
            let mapped = GenreMapping.map(.text(text)).names
            guard !mapped.isEmpty else { continue }
            try addOwnGenres(db, named: mapped)
            // A name two books spell differently is spelled as the list has it: as the
            // book with the lower id has it.
            let genres = GenreName.spelled(mapped, as: try String.fetchAll(db, sql: "SELECT name FROM genre"))
            let list = String(decoding: try JSONEncoder().encode(genres), as: UTF8.self)
            try db.execute(sql: "UPDATE book SET genres = ? WHERE id = ?", arguments: [list, id])
        }
        try db.create(virtualTable: "bookSearch", using: FTS5()) { t in
            t.synchronize(withTable: "book")
            t.column("title")
            t.column("authors")
            t.column("narrators")
            t.column("series")
            t.column("tags")
            t.column("genres")
        }
    }

    /// Adds to the library's list, as genres of the owner's own in Other, each of these
    /// names that it does not hold yet. A name the list has, shown or hidden, in any
    /// capitalisation, is left as it is.
    static func addOwnGenres(_ db: Database, named names: [String]) throws {
        guard !names.isEmpty else { return }
        var listed = try String.fetchAll(db, sql: "SELECT name FROM genre")
        for name in GenreName.distinct(names) where !listed.contains(where: { GenreName.same($0, name) }) {
            try db.execute(
                sql: "INSERT OR IGNORE INTO genre (name, genreGroup) VALUES (?, ?)",
                arguments: [name, GenreGroup.other.rawValue])
            listed.append(name)
        }
    }

    // MARK: Paths

    /// Absolute location of a stored file.
    public func url(for file: BookFile) -> URL {
        file.path.hasPrefix("/")
            ? URL(fileURLWithPath: file.path)
            : libraryRoot.appendingPathComponent(file.path)
    }

    /// Absolute location of a book's stored folder path.
    public func url(forFolder folderPath: String) -> URL {
        folderPath.hasPrefix("/")
            ? URL(fileURLWithPath: folderPath, isDirectory: true)
            : libraryRoot.appendingPathComponent(folderPath, isDirectory: true)
    }

    /// The form a file URL is stored in: relative when inside the library, else absolute.
    /// Decided by path components in canonical form, so it does not matter how the URL is
    /// spelled (`/private/tmp` or `/tmp`, with or without `..`) or whether it exists yet.
    public func storedPath(for url: URL) -> String {
        if let relative = LibraryLayout(root: libraryRoot).relativeComponents(of: url) {
            return relative.joined(separator: "/")
        }
        return url.standardizedFileURL.path
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

    /// Changes one book in a single transaction: `change` is given the book as it is and
    /// how many files it has, and what it leaves is saved. If it throws, nothing is changed.
    /// - Throws: `LibraryError.bookNotFound` when no book has the id.
    @discardableResult
    func modifyBook(id: Int64, _ change: (inout Book, _ fileCount: Int) throws -> Void) throws -> Book {
        try dbQueue.write { db in
            guard var book = try Book.fetchOne(db, key: id) else { throw LibraryError.bookNotFound(id) }
            let fileCount = try BookFile.filter(Column("bookId") == id).fetchCount(db)
            try change(&book, fileCount)
            try book.update(db)
            return book
        }
    }

    /// Sets the read status of several books in one transaction, keeping each book's
    /// dates consistent (`Book.setReadStatus`). Ids that are not in the database are ignored.
    public func setReadStatus(_ status: ReadStatus, for bookIds: [Int64], on date: Date = Date()) throws {
        try dbQueue.write { db in
            for id in bookIds {
                guard var book = try Book.fetchOne(db, key: id) else { continue }
                book.setReadStatus(status, on: date)
                try book.update(db)
            }
        }
    }

    /// Sets and clears the needs-attention flag of the given books in one transaction.
    public func setNeedsAttention(flagging: [Int64], clearing: [Int64]) throws {
        try dbQueue.write { db in
            try Book.filter(keys: flagging).updateAll(db, Column("needsAttention").set(to: true))
            try Book.filter(keys: clearing).updateAll(db, Column("needsAttention").set(to: false))
        }
    }

    /// Records what measuring a book's audio files found: the book's length (nil leaves
    /// the recorded one), and for each file row named what is wrong with its length
    /// header (nil for nothing) and whether it could not be measured (nil for "it could",
    /// or "it did not need to be"). One transaction; no other column is touched, and the
    /// rows keep their ids.
    public func setMeasuredLength(
        bookId: Int64, durationSeconds: Double?, lengthProblems: [Int64: LengthProblem?],
        unmeasured: [Int64: UnmeasuredLength?] = [:]
    ) throws {
        try dbQueue.write { db in
            if let durationSeconds {
                try Book.filter(key: bookId).updateAll(db, Column("durationSeconds").set(to: durationSeconds))
            }
            for fileId in Set(lengthProblems.keys).union(unmeasured.keys) {
                guard var file = try BookFile.fetchOne(db, key: fileId), file.bookId == bookId else { continue }
                if let problem = lengthProblems[fileId] { file.lengthProblem = problem }
                if let state = unmeasured[fileId] { file.lengthUnmeasured = state }
                try file.update(db)
            }
        }
    }

    /// A fact recorded about the library as a whole, or nil when it has not been.
    public func note(_ key: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM libraryNote WHERE key = ?", arguments: [key])
        }
    }

    /// Records a fact about the library as a whole; nil forgets it.
    public func setNote(_ key: String, to value: String?) throws {
        try dbQueue.write { db in
            if let value {
                try db.execute(
                    sql: "INSERT INTO libraryNote (key, value) VALUES (?, ?) "
                        + "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM libraryNote WHERE key = ?", arguments: [key])
            }
        }
    }

    /// The setting that holds the library's folder pattern.
    static let folderPatternSetting = "folderPattern"

    /// The folder pattern as it is stored: its text, which may be one this code cannot
    /// read. Nil when none is stored, which means the standard pattern.
    public func folderPatternText() throws -> String? {
        try dbQueue.read { db in try Self.folderPatternText(db) }
    }

    static func folderPatternText(_ db: Database) throws -> String? {
        try String.fetchOne(
            db, sql: "SELECT value FROM librarySetting WHERE key = ?", arguments: [folderPatternSetting])
    }

    /// Stores the folder pattern's text; nil stores none. Nothing is moved: this is
    /// only the record of how the library files.
    func setFolderPatternText(_ text: String?) throws {
        try dbQueue.write { db in try Self.setFolderPatternText(db, text) }
    }

    static func setFolderPatternText(_ db: Database, _ text: String?) throws {
        if let text {
            try db.execute(
                sql: "INSERT INTO librarySetting (key, value) VALUES (?, ?) "
                    + "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [folderPatternSetting, text])
        } else {
            try db.execute(sql: "DELETE FROM librarySetting WHERE key = ?", arguments: [folderPatternSetting])
        }
    }

    /// The stored folder of every book that has one, by book id.
    func bookFolders() throws -> [Int64: String] {
        try dbQueue.read { db in
            var folders: [Int64: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, folderPath FROM book WHERE folderPath IS NOT NULL") {
                folders[row["id"]] = row["folderPath"]
            }
            return folders
        }
    }

    /// The copies stored with each `book` row, one row per copy, for use in a query.
    /// Text that is not JSON counts as no copies, as it does when a book is read.
    private static let storedCopies = """
        json_each(CASE WHEN json_valid(book.externalCopies) THEN book.externalCopies ELSE '[]' END)
        """

    /// One field of a stored copy; null for an entry that is not an object.
    private static func copyField(_ name: String) -> String {
        "CASE WHEN type = 'object' THEN json_extract(value, '$.\(name)') END"
    }

    /// The kinds this code can read, as an SQL list. Copies of any other kind are
    /// skipped when a book is read, so the lists must not count them either.
    private static let knownKinds = ExternalKind.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")

    /// All books sorted by title, optionally filtered.
    /// - Parameter role: Only books with at least one file of this role, or, for `.audio`
    ///   and `.ebook`, an external copy in that form: so `.audio` is the Audiobooks list
    ///   and `.ebook` the Ebooks list, each including books owned elsewhere.
    public func books(
        having role: FileRole? = nil, needsAttention: Bool? = nil, readStatus: ReadStatus? = nil
    ) throws -> [Book] {
        try dbQueue.read { db in
            var request = Book.order(Column("title").collating(.nocase))
            if let role {
                let hasFile = """
                    EXISTS (SELECT 1 FROM bookFile
                            WHERE bookFile.bookId = book.id AND bookFile.role = ?)
                    """
                if role == .extra {
                    request = request.filter(sql: hasFile, arguments: [role.rawValue])
                } else {
                    request = request.filter(
                        sql: """
                            (\(hasFile) OR EXISTS (
                                SELECT 1 FROM \(Self.storedCopies)
                                WHERE \(Self.copyField("form")) = ?
                                  AND \(Self.copyField("kind")) IN (\(Self.knownKinds))))
                            """,
                        arguments: [role.rawValue, role.rawValue])
                }
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

    /// Every book with an external copy of this kind, with or without files, sorted by title.
    public func books(ownedOn kind: ExternalKind) throws -> [Book] {
        try dbQueue.read { db in
            try Book.fetchAll(db, sql: """
                SELECT book.* FROM book
                WHERE EXISTS (SELECT 1 FROM \(Self.storedCopies) WHERE \(Self.copyField("kind")) = ?)
                ORDER BY book.title COLLATE NOCASE
                """, arguments: [kind.rawValue])
            // The query finds candidates; what counts is what the book reads as.
            .filter { $0.isOwned(on: kind) }
        }
    }

    /// Books whose title, authors, narrators, series, tags or genres contain words
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

    /// One file row by its id. Ids are replaced whenever a book's file list is rewritten,
    /// so fetch them afresh after each operation.
    public func file(id: Int64) throws -> BookFile? {
        try dbQueue.read { db in try BookFile.fetchOne(db, key: id) }
    }

    /// Every file row of every book, ordered by book and then position.
    public func allFiles() throws -> [BookFile] {
        try dbQueue.read { db in
            try BookFile.order(Column("bookId"), Column("position")).fetchAll(db)
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
        let column = field.column
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

    /// Every distinct title that is not empty, in no particular order.
    public func distinctTitles() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT title FROM book WHERE title <> ''")
        }
    }

    /// Books having exactly `value` for a browse field, sorted by title.
    public func books(where field: BrowseField, equals value: String) throws -> [Book] {
        let column = field.column
        // A genre is the same genre however it is capitalised.
        let match = field == .genre ? "value = ? COLLATE NOCASE" : "value = ?"
        let condition = field.isList
            ? "EXISTS (SELECT 1 FROM json_each(book.\(column)) WHERE \(match))"
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

    /// Gives a collection a new name, without the spaces around it.
    ///
    /// - Throws: `CollectionError.blankName` when nothing is left of the name, and
    ///   `CollectionError.notFound` when no collection has that id; a database error when
    ///   another collection already has the name. Nothing is changed then.
    public func renameCollection(id: Int64, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CollectionError.blankName }
        try dbQueue.write { db in
            guard var collection = try BookCollection.fetchOne(db, key: id) else {
                throw CollectionError.notFound(id)
            }
            collection.name = trimmed
            try collection.update(db)
        }
    }

    /// Removes the collection and its memberships. The books themselves are untouched.
    /// An id no collection has does nothing.
    public func deleteCollection(id: Int64) throws {
        // Memberships go with their collection by cascade.
        _ = try dbQueue.write { db in try BookCollection.deleteOne(db, key: id) }
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

    /// The collections a book is in, by id, in id order.
    func collectionIds(bookId: Int64) throws -> [Int64] {
        try dbQueue.read { db in
            try Int64.fetchAll(
                db, sql: "SELECT collectionId FROM collectionBook WHERE bookId = ? ORDER BY collectionId",
                arguments: [bookId])
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

/// Why a catalogue could not be opened, where the reason is the library's own and can
/// be said as it is.
public enum LibraryStoreError: Error, Equatable, LocalizedError {
    /// The copy kept before the genres are converted could not be made, under this
    /// name in the library folder. Nothing was changed.
    case copyBeforeGenresFailed(String)

    public var errorDescription: String? {
        switch self {
        case .copyBeforeGenresFailed(let name):
            return "Before this version changes how the library keeps genres it makes a copy of the catalogue, "
                + "\"\(name)\", in the library folder. The copy could not be made, so nothing was changed. "
                + "Check that the library folder can be written to and has room, then open it again."
        }
    }
}

/// Why a collection could not be changed.
public enum CollectionError: Error, Equatable {
    /// A collection's name must have something in it besides spaces.
    case blankName
    /// No collection has this id.
    case notFound(Int64)
}

/// One undoable batch of file transfers.
public struct OperationBatch: Equatable, Sendable {
    public var id: Int64
    public var label: String
    public var moves: [MoveRecord]
    /// The undo data recorded with the batch, exactly as it was given; nil when there is none.
    public var snapshot: Data?
}

extension LibraryStore {
    /// Saves a batch of completed transfers, replacing any earlier batch: the journal
    /// holds at most one. Returns the new batch's id.
    @discardableResult
    public func recordBatch(label: String, moves: [MoveRecord]) throws -> Int64 {
        try dbQueue.write { db in
            try Self.replaceJournal(db, label: label, moves: moves, snapshot: nil)
        }
    }

    /// Empties the journal. Moves go with their batch by cascade.
    static func clearJournal(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM operationBatch")
    }

    /// Replaces the whole journal with one batch; returns its id.
    static func replaceJournal(
        _ db: Database, label: String, moves: [MoveRecord], snapshot: Data?
    ) throws -> Int64 {
        try clearJournal(db)
        try db.execute(
            sql: "INSERT INTO operationBatch (label, createdAt, snapshot) VALUES (?, ?, ?)",
            arguments: [label, Date(), snapshot])
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

    /// The recorded batch, or nil when the journal is empty.
    public func lastBatch() throws -> OperationBatch? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT id, label, snapshot FROM operationBatch ORDER BY id DESC LIMIT 1")
            else { return nil }
            let id: Int64 = row["id"]
            let moves = try Row.fetchAll(
                db,
                sql: "SELECT fromPath, toPath, wasCopy FROM operationMove WHERE batchId = ? ORDER BY id",
                arguments: [id]
            ).map { MoveRecord(from: $0["fromPath"], to: $0["toPath"], wasCopy: $0["wasCopy"]) }
            return OperationBatch(id: id, label: row["label"], moves: moves, snapshot: row["snapshot"])
        }
    }

    public func deleteBatch(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM operationBatch WHERE id = ?", arguments: [id])
        }
    }
}

// MARK: Watch folders and the inbox ledger

extension LibraryStore {
    /// Every watch folder, oldest first.
    func watchFolders() throws -> [WatchFolder] {
        try dbQueue.read { db in try Self.watchFolders(db) }
    }

    static func watchFolders(_ db: Database) throws -> [WatchFolder] {
        try WatchFolderRecord.order(Column("addedAt"), Column("id")).fetchAll(db).compactMap(\.folder)
    }

    /// Stores a new watch folder and its baseline in one transaction. `check` is given
    /// the folders already stored, inside that transaction; if it throws, nothing is stored.
    func insertWatchFolder(
        path: String, addedAt: Date, baseline: [ListedFile], check: ([WatchFolder]) throws -> Void
    ) throws -> WatchFolder {
        try dbQueue.write { db in
            try check(try Self.watchFolders(db))
            var record = WatchFolderRecord(
                id: nil, path: path, mode: .move, isEnabled: true, includesPDFs: false, addedAt: addedAt)
            try record.insert(db)
            guard let folder = record.folder else { throw WatchFolderError.notFound(0) }
            try Self.insertInboxEntries(db, baseline, state: .baseline, folderId: folder.id)
            return folder
        }
    }

    /// Changes a watch folder's mode, whether it is enabled and whether PDFs count, and
    /// in the same transaction adds `baseline` to its ledger. A file of `baseline` that
    /// has an entry already keeps it.
    /// - Throws: `WatchFolderError.notFound` when no folder has the id.
    func updateWatchFolderSettings(_ folder: WatchFolder, baseline: [ListedFile] = []) throws {
        try dbQueue.write { db in
            guard var record = try WatchFolderRecord.fetchOne(db, key: folder.id) else {
                throw WatchFolderError.notFound(folder.id)
            }
            record.mode = folder.mode
            record.isEnabled = folder.isEnabled
            record.includesPDFs = folder.includesPDFs
            try record.update(db)
            for file in baseline {
                var entry = InboxEntryRecord(
                    id: nil, folderId: folder.id, path: file.url.path, size: file.size,
                    modifiedAt: file.modifiedAt, state: .baseline)
                try entry.insert(db, onConflict: .ignore)
            }
        }
    }

    /// Deletes a watch folder; its ledger entries go with it by cascade.
    func deleteWatchFolder(id: Int64) throws {
        _ = try dbQueue.write { db in try WatchFolderRecord.deleteOne(db, key: id) }
    }

    /// A watch folder's ledger entries, in the order they were recorded.
    func inboxEntries(folderId: Int64) throws -> [InboxEntryRecord] {
        try dbQueue.read { db in
            try InboxEntryRecord.filter(Column("folderId") == folderId).order(Column("id")).fetchAll(db)
        }
    }

    /// Records files of a watch folder in the ledger, as they are now.
    func recordInboxEntries(_ files: [ListedFile], state: InboxEntryState, folderId: Int64) throws {
        try dbQueue.write { db in try Self.insertInboxEntries(db, files, state: state, folderId: folderId) }
    }

    static func insertInboxEntries(
        _ db: Database, _ files: [ListedFile], state: InboxEntryState, folderId: Int64
    ) throws {
        for file in files {
            var entry = InboxEntryRecord(
                id: nil, folderId: folderId, path: file.url.path, size: file.size,
                modifiedAt: file.modifiedAt, state: state)
            try entry.insert(db)
        }
    }

    /// Records files in the ledger as they are now, each under its own watch folder
    /// and in place of any entry the file had. One transaction.
    func replaceInboxEntries(_ files: [(file: ListedFile, folderId: Int64)], state: InboxEntryState) throws {
        guard !files.isEmpty else { return }
        try dbQueue.write { db in
            for (file, folderId) in files {
                try InboxEntryRecord
                    .filter(Column("folderId") == folderId && Column("path") == file.url.path)
                    .deleteAll(db)
                try Self.insertInboxEntries(db, [file], state: state, folderId: folderId)
            }
        }
    }

    /// Deletes the ledger entries with these ids.
    func deleteInboxEntries(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in _ = try InboxEntryRecord.deleteAll(db, keys: ids) }
    }

    /// Deletes a watch folder's ledger entries of one state.
    func deleteInboxEntries(folderId: Int64, state: InboxEntryState) throws {
        try dbQueue.write { db in
            _ = try InboxEntryRecord
                .filter(Column("folderId") == folderId && Column("state") == state.rawValue)
                .deleteAll(db)
        }
    }
}

// MARK: Series lists

extension LibraryStore {
    /// The link stored for a series and its entries in series order; nil when the
    /// series has none.
    func seriesList(key: String) throws -> (link: SeriesLinkRecord, entries: [SeriesEntryRecord])? {
        try dbQueue.read { db in
            guard let link = try SeriesLinkRecord.filter(Column("seriesKey") == key).fetchOne(db), let id = link.id
            else { return nil }
            let entries = try SeriesEntryRecord
                .filter(Column("linkId") == id).order(Column("position"), Column("id")).fetchAll(db)
            return (link, entries)
        }
    }

    /// Stores a series' link and entries in place of any it had, in one transaction.
    /// An entry is stored hidden when `staysHidden` says so of it and an entry that was
    /// hidden before, given the link that entry was stored under. Links no book uses
    /// any more are deleted on the way.
    func replaceSeriesList(
        link: SeriesLinkRecord, entries: [SeriesEntryRecord],
        staysHidden: (_ was: SeriesLinkRecord, _ before: SeriesEntryRecord, _ now: SeriesEntryRecord) -> Bool
    ) throws {
        try dbQueue.write { db in
            var hidden: [SeriesEntryRecord] = []
            let old = try SeriesLinkRecord.filter(Column("seriesKey") == link.seriesKey).fetchOne(db)
            if let id = old?.id {
                hidden = try SeriesEntryRecord
                    .filter(Column("linkId") == id && Column("isHidden") == true).fetchAll(db)
                try SeriesLinkRecord.deleteOne(db, key: id)
            }
            var link = link
            link.id = nil
            try link.insert(db)
            guard let linkId = link.id else { return }
            for (position, entry) in entries.enumerated() {
                var entry = entry
                entry.id = nil
                entry.linkId = linkId
                entry.position = position
                entry.isHidden = old.map { was in hidden.contains { staysHidden(was, $0, entry) } } ?? false
                try entry.insert(db)
            }
            try Self.deleteUnusedSeriesLinks(db)
        }
    }

    /// Deletes a series' link; its entries go with it by cascade. Links no book uses
    /// any more are deleted on the way.
    func deleteSeriesList(key: String) throws {
        try dbQueue.write { db in
            _ = try SeriesLinkRecord.filter(Column("seriesKey") == key).deleteAll(db)
            try Self.deleteUnusedSeriesLinks(db)
        }
    }

    /// Deletes every link whose series no book is in, as `books(where:equals:)` decides
    /// which books are in a series.
    private static func deleteUnusedSeriesLinks(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM seriesLink
            WHERE NOT EXISTS (SELECT 1 FROM book WHERE book.\(BrowseField.series.column) = seriesLink.seriesKey)
            """)
    }

    /// Sets whether an entry is hidden, and nothing else.
    /// - Returns: False when no entry has the id.
    func setSeriesEntry(id: Int64, hidden: Bool) throws -> Bool {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE seriesEntry SET isHidden = ? WHERE id = ?", arguments: [hidden, id])
            return db.changesCount > 0
        }
    }
}

// MARK: - Sends to the phone

extension LibraryStore {
    func insertSentRecord(_ record: SentRecord) throws {
        let fingerprint = String(decoding: try JSONEncoder().encode(record.fingerprint), as: UTF8.self)
        try dbQueue.write { db in
            var row = SentRecordRow(
                id: nil, bookId: record.bookId, sentAt: record.sentAt, method: record.method.rawValue,
                fingerprint: fingerprint)
            try row.insert(db)
        }
    }

    /// The row ids of a book's sent records, readable by this code or not, oldest first.
    func sentRecordIds(bookId: Int64) throws -> [Int64] {
        try dbQueue.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM sentRecord WHERE bookId = ? ORDER BY id", arguments: [bookId])
        }
    }

    /// A book's sends, newest first; of two at one moment, the one recorded last first.
    /// A row this code cannot read (a way of sending added by a newer version, say) is
    /// left out.
    func sentRecords(bookId: Int64) throws -> [SentRecord] {
        try dbQueue.read { db in
            try SentRecordRow.filter(Column("bookId") == bookId)
                .order(Column("sentAt").desc, Column("id").desc).fetchAll(db)
        }.compactMap(\.record)
    }
}
