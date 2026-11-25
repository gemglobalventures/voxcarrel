import Foundation
import GRDB

/// One genre of the library's list as it is stored.
struct GenreRow: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "genre"

    var id: Int64
    var name: String
    /// A `GenreGroup` raw value.
    var genreGroup: String
    /// The name the app ships the genre under; nil for one of the owner's own.
    var builtInName: String?
    /// True for a built-in genre that has been merged away.
    var isHidden: Bool
    /// For a built-in genre merged away: the id of the genre it was merged into.
    var mergedInto: Int64?

    var group: GenreGroup { GenreGroup(rawValue: genreGroup) ?? .other }
    var isBuiltIn: Bool { builtInName != nil }

    init(id: Int64, name: String, genreGroup: String, builtInName: String?, isHidden: Bool, mergedInto: Int64?) {
        self.id = id
        self.name = name
        self.genreGroup = genreGroup
        self.builtInName = builtInName
        self.isHidden = isHidden
        self.mergedInto = mergedInto
    }

    /// Tolerant of fields that are absent, as everything kept for undo is.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        genreGroup = try c.decodeIfPresent(String.self, forKey: .genreGroup) ?? GenreGroup.other.rawValue
        builtInName = try c.decodeIfPresent(String.self, forKey: .builtInName)
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        mergedInto = try c.decodeIfPresent(Int64.self, forKey: .mergedInto)
    }
}

/// The library's list at one moment, for saying what a name comes to in it.
public struct GenreListing: Sendable {
    let rows: [GenreRow]

    init(rows: [GenreRow]) {
        self.rows = rows
    }

    /// The genre a name is: the one that has it now, or failing that the built-in one
    /// that shipped under it. Capitalisation does not count.
    func row(named name: String) -> GenreRow? {
        let tidy = GenreName.tidied(name)
        return rows.first { GenreName.same($0.name, tidy) }
            ?? rows.first { row in row.builtInName.map { GenreName.same($0, tidy) } ?? false }
    }

    /// Where a genre's books are: the genre itself, or for one merged away the genre it
    /// went into, however many merges on. What the list records is followed until it
    /// ends; if it goes round in a circle the genre itself is given.
    func standing(for row: GenreRow) -> GenreRow {
        var current = row
        var seen: Set<Int64> = [row.id]
        while current.isHidden, let next = current.mergedInto,
              let target = rows.first(where: { $0.id == next }) {
            guard seen.insert(target.id).inserted else { return row }
            current = target
        }
        return current
    }

    /// The name the library keeps for this one: a renamed built-in genre by its new
    /// name, one merged away by the genre it went into. Nil for a name the list lacks.
    public func listed(_ name: String) -> String? {
        row(named: name).map { standing(for: $0).name }
    }

    /// Genres as the library keeps them on a book: each as `listed` gives it, a name
    /// the list lacks as it is, and none twice.
    public func names(_ names: [String]) -> [String] {
        GenreName.distinct(GenreName.distinct(names).map { listed($0) ?? $0 })
    }
}

/// What a change to the list did, kept so that it can be undone.
struct GenreListSnapshot: Codable, Equatable {
    /// The rows the change altered or removed, as they were.
    var rowsBefore: [GenreRow]
    /// The ids of the rows the change made.
    var addedIds: [Int64]
    /// The genres of each book the change touched, as they were.
    var books: [BookBefore]

    struct BookBefore: Codable, Equatable {
        var bookId: Int64
        var genres: [String]
    }

    init(rowsBefore: [GenreRow], addedIds: [Int64], books: [BookBefore]) {
        self.rowsBefore = rowsBefore
        self.addedIds = addedIds
        self.books = books
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rowsBefore = try c.decodeIfPresent([GenreRow].self, forKey: .rowsBefore) ?? []
        addedIds = try c.decodeIfPresent([Int64].self, forKey: .addedIds) ?? []
        books = try c.decodeIfPresent([BookBefore].self, forKey: .books) ?? []
    }
}

/// A genre's name on books becoming another, or (with no new name) being taken off them.
struct GenreRename {
    var from: String
    var to: String?
}

// MARK: Reading the list

extension LibraryStore {
    /// The library's list of genres, hidden ones included, each with the number of
    /// books that have it: by group, the built-in ones in their own order and then the
    /// owner's own by name.
    public func genreList() throws -> [GenreEntry] {
        let scope = BookScope.sql
        return try dbQueue.read { db in
            // Counted here and not by the database, which only folds the case of ASCII letters.
            var counts: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT j.value AS name, COUNT(*) AS books FROM book, json_each(book.genres) AS j WHERE 1\(scope) GROUP BY j.value
                """) {
                let name: String = row["name"]
                counts[name.lowercased(), default: 0] += row["books"]
            }
            let rows = try GenreRow.fetchAll(db, sql: """
                SELECT * FROM genre
                ORDER BY builtInName IS NULL, CASE WHEN builtInName IS NULL THEN 0 ELSE id END, name COLLATE NOCASE
                """)
            let entries = rows.map { row in
                GenreEntry(
                    name: row.name, group: row.group, builtInName: row.builtInName, isHidden: row.isHidden,
                    bookCount: counts[row.name.lowercased()] ?? 0,
                    mergedInto: row.mergedInto.flatMap { id in rows.first { $0.id == id }?.name })
            }
            return GenreGroup.allCases.flatMap { group in entries.filter { $0.group == group } }
        }
    }

    /// The names of the library's list, hidden ones included.
    public func genreNames() throws -> [String] {
        try genreRows().map(\.name)
    }

    /// The list as it is stored, in the order it was made.
    func genreRows() throws -> [GenreRow] {
        try dbQueue.read { db in try Self.genreRows(db) }
    }

    static func genreRows(_ db: Database) throws -> [GenreRow] {
        try GenreRow.fetchAll(db, sql: "SELECT * FROM genre ORDER BY id")
    }

    /// The list, for saying what names come to in it.
    func genreListing() throws -> GenreListing {
        GenreListing(rows: try genreRows())
    }

    /// The ids of the books that have this genre, whatever its place in their lists,
    /// sorted by title.
    public func bookIds(inGenre name: String) throws -> [Int64] {
        let scope = BookScope.sql
        return try dbQueue.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT id FROM book
                WHERE EXISTS (SELECT 1 FROM json_each(book.genres) WHERE value = ? COLLATE NOCASE)\(scope)
                ORDER BY title COLLATE NOCASE
                """, arguments: [name])
        }
    }

    /// The ids of the books with a genre of this group, each once, sorted by title.
    public func bookIds(inGroup group: GenreGroup) throws -> [Int64] {
        let scope = BookScope.sql
        return try dbQueue.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT id FROM book
                WHERE EXISTS (
                    SELECT 1 FROM json_each(book.genres) AS j
                    JOIN genre ON genre.name = j.value COLLATE NOCASE
                    WHERE genre.genreGroup = ?)\(scope)
                ORDER BY title COLLATE NOCASE
                """, arguments: [group.rawValue])
        }
    }

    /// The ids of the books with no genre, sorted by title.
    public func bookIdsWithNoGenre() throws -> [Int64] {
        let scope = BookScope.sql
        return try dbQueue.read { db in
            try Int64.fetchAll(
                db, sql: "SELECT id FROM book WHERE json_array_length(genres) = 0\(scope) ORDER BY title COLLATE NOCASE")
        }
    }
}

// MARK: Changing the list

extension LibraryStore {
    /// Changes the list without recording anything for undo. `change` is given the list
    /// as it stands, inside the transaction.
    func writeGenreList<T>(_ change: (Database, GenreListing) throws -> T) throws -> T {
        try dbQueue.write { db in try change(db, GenreListing(rows: try Self.genreRows(db))) }
    }

    /// One change to the list and to the books it touches, in a single transaction,
    /// recorded as the one operation that can be undone.
    ///
    /// `change` is given the list as it stands and alters its rows; what it returns
    /// says which names on books become which. Every book holding one of them has its
    /// genres rewritten, in place and without a name twice. `snapshot` turns what was
    /// changed into the undo data to store with the journal's batch.
    ///
    /// When nothing at all was changed, nothing is recorded and false is returned.
    @discardableResult
    func changeGenreList(
        label: String, snapshot: (GenreListSnapshot) throws -> Data,
        _ change: (Database, GenreListing) throws -> [GenreRename]
    ) throws -> Bool {
        try dbQueue.write { db in
            let before = try Self.genreRows(db)
            let renames = try change(db, GenreListing(rows: before))

            var books: [GenreListSnapshot.BookBefore] = []
            if !renames.isEmpty {
                for row in try Row.fetchAll(
                    db, sql: "SELECT id, genres FROM book WHERE json_array_length(genres) > 0 ORDER BY id") {
                    let id: Int64 = row["id"]
                    let held = Self.genres(fromStored: row["genres"])
                    let renamed = GenreName.distinct(held.compactMap { name -> String? in
                        guard let rename = renames.first(where: { GenreName.same($0.from, name) }) else { return name }
                        return rename.to
                    })
                    guard renamed != held else { continue }
                    try Self.setGenres(db, renamed, ofBook: id)
                    books.append(.init(bookId: id, genres: held))
                }
            }

            let after = try Self.genreRows(db)
            let rowsBefore = before.filter { row in after.first { $0.id == row.id } != row }
            let addedIds = after.map(\.id).filter { id in !before.contains { $0.id == id } }
            guard !rowsBefore.isEmpty || !addedIds.isEmpty || !books.isEmpty else { return false }
            let data = try snapshot(GenreListSnapshot(rowsBefore: rowsBefore, addedIds: addedIds, books: books))
            try Self.replaceJournal(db, label: label, moves: [], snapshot: data)
            return true
        }
    }

    /// Undoes a change to the list: its rows are as they were, the rows it made are
    /// gone, and each book it touched that is still in the library has the genres it
    /// had. The journal is emptied in the same transaction.
    ///
    /// A genre added since under a name that a restored one had takes that one's place.
    func restoreGenreList(_ saved: GenreListSnapshot) throws {
        try dbQueue.write { db in
            let restoredIds = saved.rowsBefore.map(\.id)
            for id in restoredIds + saved.addedIds {
                try db.execute(sql: "DELETE FROM genre WHERE id = ?", arguments: [id])
            }
            for row in try Self.genreRows(db)
            where saved.rowsBefore.contains(where: { GenreName.same($0.name, row.name) }) {
                try db.execute(sql: "DELETE FROM genre WHERE id = ?", arguments: [row.id])
            }
            for row in saved.rowsBefore { try row.insert(db) }
            // Nothing is left merged into a genre that is no longer there.
            try db.execute(sql: """
                UPDATE genre SET isHidden = 0, mergedInto = NULL
                WHERE mergedInto IS NOT NULL AND mergedInto NOT IN (SELECT id FROM genre)
                """)
            for book in saved.books {
                try Self.setGenres(db, book.genres, ofBook: book.bookId)
            }
            try Self.clearJournal(db)
        }
    }

    /// A book's genres as its row holds them.
    static func genres(fromStored text: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? []
    }

    /// Stores a book's genres and nothing else of it. The names are taken as they are:
    /// nothing is added to the list for them.
    static func setGenres(_ db: Database, _ genres: [String], ofBook id: Int64) throws {
        let text = String(decoding: try JSONEncoder().encode(genres), as: UTF8.self)
        try db.execute(sql: "UPDATE book SET genres = ? WHERE id = ?", arguments: [text, id])
    }
}
