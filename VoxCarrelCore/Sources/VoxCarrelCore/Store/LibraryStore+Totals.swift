import Foundation
import GRDB

extension LibraryStore {
    /// The length of all the audio the library has, in seconds: the sum of what each
    /// book states. Books with no stated length count for nothing.
    public func totalAudioSeconds() throws -> Double {
        try dbQueue.read { db in
            try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(durationSeconds), 0) FROM book") ?? 0
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
}
