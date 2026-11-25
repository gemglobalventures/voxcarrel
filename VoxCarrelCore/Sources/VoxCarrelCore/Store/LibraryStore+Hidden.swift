import Foundation
import GRDB

/// Which books a reading of the library sees.
///
/// The library's own work (importing, knowing a book again, moving folders, writing
/// tags) sees every book, hidden or not: a hidden book must still be known for the
/// book it is, or it would be brought in twice. What is read to be shown runs inside
/// `BookScope.visible`, and there the lists, counts and searches leave hidden books out.
public enum BookScope {
    @TaskLocal public static var visibleOnly = false

    /// Runs `body` seeing only the books that are not hidden.
    public static func visible<T>(_ body: () throws -> T) rethrows -> T {
        try $visibleOnly.withValue(true, operation: body)
    }

    /// What has been read once is kept and given again, for as long as one reading of
    /// the library for showing lasts: a sidebar counts the same books a dozen ways.
    /// Only for a stretch in which nothing is written: what is kept is not looked at again.
    @TaskLocal static var memo: ReadMemo?

    /// Runs `body`, in which each whole list of books or files is read at most once.
    /// Nothing may be changed in the library inside it.
    public static func readingOnce<T>(_ body: () throws -> T) rethrows -> T {
        try $memo.withValue(ReadMemo(), operation: body)
    }

    final class ReadMemo: @unchecked Sendable {
        var books: [String: [Book]] = [:]
        var files: [Bool: [BookFile]] = [:]
    }

    /// What a query of the book table adds to its conditions. Read before the query
    /// runs: the database works on a thread of its own, where the scope is not known.
    static var sql: String { visibleOnly ? " AND isHidden = 0" : "" }

    /// The same for a table that names its book in a `bookId` column.
    static var ofBookIds: String { visibleOnly ? " AND bookId IN (SELECT id FROM book WHERE isHidden = 0)" : "" }
}

extension LibraryStore {
    /// Every tag any book has, each once, in no order.
    public func allTags() throws -> [String] {
        let scope = BookScope.sql
        return try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT j.value FROM book, json_each(book.tags) AS j WHERE j.value <> ''\(scope)")
        }
    }

    /// The hidden books, sorted by title, whatever the scope.
    public func hiddenBooks() throws -> [Book] {
        try dbQueue.read { db in
            try Book.fetchAll(db, sql: "SELECT * FROM book WHERE isHidden = 1 ORDER BY title COLLATE NOCASE")
        }
    }

    public func hiddenBookCount() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book WHERE isHidden = 1") ?? 0 }
    }

    /// Hides books, or brings them back. Nothing else about them changes, and no file
    /// is touched. An id no book has does nothing.
    public func setHidden(_ hidden: Bool, bookIds: [Int64]) throws {
        try dbQueue.write { db in
            for id in bookIds {
                try db.execute(sql: "UPDATE book SET isHidden = ? WHERE id = ?", arguments: [hidden, id])
            }
        }
    }
}
