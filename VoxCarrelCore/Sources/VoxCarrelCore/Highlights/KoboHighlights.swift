import Foundation
import GRDB

/// Reads the highlights and notes a Kobo keeps in its own database
/// (`.kobo/KoboReader.sqlite` on the device). The database is opened for reading only
/// and nothing is asked of Kobo.
public enum KoboHighlights {
    public static let fileName = "KoboReader.sqlite"

    public enum Problem: Error, Equatable {
        /// The file is not a Kobo's database, or not one this code can read.
        case notAKoboDatabase
    }

    /// The books of a Kobo's database that have highlights or notes, each with them in
    /// the order they were made.
    public static func books(fromDatabaseAt url: URL) throws -> [HighlightedBook] {
        var configuration = Configuration()
        configuration.readonly = true
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: configuration)
        } catch {
            throw Problem.notAKoboDatabase
        }
        return try queue.read { db in
            guard try db.tableExists("Bookmark"), try db.tableExists("content") else { throw Problem.notAKoboDatabase }
            let marks = Set(try db.columns(in: "Bookmark").map { $0.name.lowercased() })
            guard marks.isSuperset(of: ["bookmarkid", "volumeid", "text"]) else { throw Problem.notAKoboDatabase }
            func column(_ name: String) -> String { marks.contains(name.lowercased()) ? "b.\(name)" : "NULL" }
            let rows = try Row.fetchAll(db, sql: """
                SELECT b.BookmarkID AS id, b.VolumeID AS volume, b.Text AS text,
                       \(column("Annotation")) AS note, \(column("DateCreated")) AS made,
                       \(column("Hidden")) AS hidden, \(column("Type")) AS type
                FROM Bookmark b
                ORDER BY b.VolumeID, \(column("DateCreated")), b.BookmarkID
                """)
            var order: [String] = []
            var found: [String: [IncomingHighlight]] = [:]
            for row in rows {
                let hidden = (row["hidden"] as String?)?.lowercased()
                guard hidden != "true", hidden != "1" else { continue }
                // A turned-down corner marks a page and says nothing.
                if (row["type"] as String?)?.lowercased() == "dogear" { continue }
                let text = (row["text"] as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let note = (row["note"] as String?)?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let id = row["id"] as String?, let volume = row["volume"] as String?,
                      !text.isEmpty || !(note ?? "").isEmpty
                else { continue }
                var highlight = IncomingHighlight(sourceId: id, text: text)
                highlight.note = (note ?? "").isEmpty ? nil : note
                highlight.madeAt = (row["made"] as String?).flatMap(date)
                if found[volume] == nil { order.append(volume) }
                highlight.location = Double((found[volume]?.count ?? 0) + 1)
                highlight.locationKind = .order
                found[volume, default: []].append(highlight)
            }
            return try order.compactMap { volume in
                let named = try Row.fetchOne(
                    db, sql: "SELECT Title AS title, Attribution AS author FROM content WHERE ContentID = ? AND Title IS NOT NULL LIMIT 1",
                    arguments: [volume])
                let title = (named?["title"] as String?)?.trimmingCharacters(in: .whitespaces) ?? ""
                guard !title.isEmpty, let highlights = found[volume] else { return nil }
                let authors = ((named?["author"] as String?) ?? "").components(separatedBy: CharacterSet(charactersIn: ",;&"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                return HighlightedBook(title: title, authors: authors, source: .kobo, highlights: highlights)
            }
        }
    }

    /// "2025-03-03T09:14:05.000" or "2025-03-03T09:14:05Z", as the device writes it: in
    /// universal time.
    static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
