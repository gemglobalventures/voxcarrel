import Foundation
import GRDB

extension LibraryStore {
    /// A book's highlights in the order of the book: by place, those with none after,
    /// then by when they were made.
    public func highlights(forBook bookId: Int64) throws -> [Highlight] {
        try dbQueue.read { db in
            try Highlight.fetchAll(db, sql: """
                SELECT * FROM highlight WHERE bookId = ?
                ORDER BY location IS NULL, location, madeAt IS NULL, madeAt, id
                """, arguments: [bookId])
        }
    }

    /// How many highlights each book has; books with none are not in it.
    public func highlightCounts() throws -> [Int64: Int] {
        try dbQueue.read { db in
            var counts: [Int64: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT bookId, COUNT(*) AS n FROM highlight GROUP BY bookId") {
                counts[row["bookId"]] = row["n"]
            }
            return counts
        }
    }

    /// The books that have a highlight whose text or note contains every word of
    /// `text`, in any order and without regard to case. None for blank text.
    public func bookIds(withHighlightsMatching text: String) throws -> Set<Int64> {
        let words = text.split(whereSeparator: \.isWhitespace).map { String($0) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        return try dbQueue.read { db in
            let each = "(text LIKE ? ESCAPE '\\' OR COALESCE(note, '') LIKE ? ESCAPE '\\')"
            let pattern = { (word: String) -> String in
                "%" + word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_") + "%"
            }
            let arguments = StatementArguments(words.flatMap { [pattern($0), pattern($0)] })
            let sql = "SELECT DISTINCT bookId FROM highlight WHERE " + words.map { _ in each }.joined(separator: " AND ")
            return Set(try Int64.fetchAll(db, sql: sql, arguments: arguments))
        }
    }

    /// Stores highlights for books, replacing any stored under the same source and
    /// source id, and removes those named for removal. One transaction.
    func apply(highlights: [Highlight], removing: [(source: HighlightSource, sourceId: String)]) throws {
        try dbQueue.write { db in
            for mark in removing {
                try db.execute(
                    sql: "DELETE FROM highlight WHERE source = ? AND sourceId = ?",
                    arguments: [mark.source.rawValue, mark.sourceId])
            }
            for var highlight in highlights {
                if let id = try Int64.fetchOne(
                    db, sql: "SELECT id FROM highlight WHERE source = ? AND sourceId = ?",
                    arguments: [highlight.source.rawValue, highlight.sourceId]) {
                    highlight.id = id
                    try highlight.update(db)
                } else {
                    try highlight.insert(db)
                }
            }
        }
    }

    /// Every stored highlight of one source, by its id there.
    func highlights(from source: HighlightSource) throws -> [String: Highlight] {
        try dbQueue.read { db in
            var found: [String: Highlight] = [:]
            for highlight in try Highlight.fetchAll(db, sql: "SELECT * FROM highlight WHERE source = ?", arguments: [source.rawValue]) {
                found[highlight.sourceId] = highlight
            }
            return found
        }
    }

    public func deleteHighlight(id: Int64) throws {
        try dbQueue.write { db in try db.execute(sql: "DELETE FROM highlight WHERE id = ?", arguments: [id]) }
    }
}
