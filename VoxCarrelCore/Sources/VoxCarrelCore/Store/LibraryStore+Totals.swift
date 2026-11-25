import Foundation
import GRDB

extension LibraryStore {
    /// The length of all the audio the library has, in seconds: the sum of what each
    /// book states. Books with no stated length count for nothing.
    public func totalAudioSeconds() throws -> Double {
        let scope = BookScope.sql
        return try dbQueue.read { db in
            try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(durationSeconds), 0) FROM book WHERE 1\(scope)") ?? 0
        }
    }

    /// The fingerprints files had when they came into the library, each with the book
    /// that has the file.
    public func arrivedPrints() throws -> [String: Int64] {
        try dbQueue.read { db in
            var found: [String: Int64] = [:]
            let rows = try Row.fetchAll(
                db, sql: "SELECT arrivedPrint, bookId FROM bookFile WHERE arrivedPrint IS NOT NULL AND bookId IS NOT NULL")
            for row in rows {
                if let print: String = row["arrivedPrint"], let book: Int64 = row["bookId"] { found[print] = book }
            }
            return found
        }
    }

    /// The content prints of the library's files (`BookFile.contentPrint`), those
    /// that could not be worked out left aside.
    public func contentPrints() throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(
                db, sql: "SELECT contentPrint FROM bookFile WHERE contentPrint IS NOT NULL AND contentPrint <> '' AND bookId IS NOT NULL"))
        }
    }

    /// Files of library books whose content print has yet to be worked out, oldest first.
    public func filesLackingContentPrint(limit: Int) throws -> [BookFile] {
        try dbQueue.read { db in
            try BookFile.fetchAll(
                db, sql: "SELECT * FROM bookFile WHERE contentPrint IS NULL AND bookId IS NOT NULL ORDER BY id LIMIT ?",
                arguments: [limit])
        }
    }

    /// Records a file's content print; the empty text for one that has none.
    public func setContentPrint(_ print: String, forFile id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE bookFile SET contentPrint = ? WHERE id = ?", arguments: [print, id])
        }
    }

    static let knowsFilesAgainSetting = "knowsFilesAgain"

    /// Whether a scan sets aside files this library already has. True unless it was
    /// switched off, as it is for a library of samples, whose books are met again on
    /// purpose.
    public func knowsFilesAgain() throws -> Bool {
        try dbQueue.read { db in
            try String.fetchOne(
                db, sql: "SELECT value FROM librarySetting WHERE key = ?", arguments: [Self.knowsFilesAgainSetting]) != "no"
        }
    }

    public func setKnowsFilesAgain(_ knows: Bool) throws {
        try dbQueue.write { db in
            if knows {
                try db.execute(sql: "DELETE FROM librarySetting WHERE key = ?", arguments: [Self.knowsFilesAgainSetting])
            } else {
                try db.execute(
                    sql: "INSERT INTO librarySetting (key, value) VALUES (?, 'no') "
                        + "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [Self.knowsFilesAgainSetting])
            }
        }
    }
}
