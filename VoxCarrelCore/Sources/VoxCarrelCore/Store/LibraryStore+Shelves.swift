import Foundation
import GRDB

/// What of a smart shelf is kept as one piece of text.
private struct ShelfRule: Codable {
    var matchesAll: Bool
    var conditions: [ShelfCondition]
}

extension LibraryStore {
    static func ruleText(of shelf: SmartShelf) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ShelfRule(matchesAll: shelf.matchesAll, conditions: shelf.conditions))
        return String(decoding: data, as: UTF8.self)
    }

    /// The library's smart shelves in their order. A shelf whose conditions this code
    /// cannot read (one made by a later version) is given with none, so that it is
    /// still listed and holds nothing.
    public func smartShelves() throws -> [SmartShelf] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name, rule FROM smartShelf ORDER BY position, id").map { row in
                let text: String = row["rule"]
                let rule = try? JSONDecoder().decode(ShelfRule.self, from: Data(text.utf8))
                return SmartShelf(
                    id: row["id"], name: row["name"], matchesAll: rule?.matchesAll ?? true,
                    conditions: rule?.conditions ?? [])
            }
        }
    }

    /// Stores a shelf: a new one (no id) goes last; one with an id replaces what was
    /// stored under it. Returns the shelf as stored.
    @discardableResult
    public func save(_ shelf: SmartShelf) throws -> SmartShelf {
        try dbQueue.write { db in
            let rule = try Self.ruleText(of: shelf)
            var stored = shelf
            if let id = shelf.id, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM smartShelf WHERE id = ?", arguments: [id]) == 1 {
                try db.execute(sql: "UPDATE smartShelf SET name = ?, rule = ? WHERE id = ?", arguments: [shelf.name, rule, id])
            } else {
                let last = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) FROM smartShelf") ?? -1
                try db.execute(
                    sql: "INSERT INTO smartShelf (name, rule, position) VALUES (?, ?, ?)",
                    arguments: [shelf.name, rule, last + 1])
                stored.id = db.lastInsertedRowID
            }
            return stored
        }
    }

    public func deleteSmartShelf(id: Int64) throws {
        try dbQueue.write { db in try db.execute(sql: "DELETE FROM smartShelf WHERE id = ?", arguments: [id]) }
    }

    /// The books put on the Up Next list by hand, in the order they were put there.
    /// One that is no longer in the library is not given.
    public func upNextIds() throws -> [Int64] {
        try dbQueue.read { db in
            try Int64.fetchAll(
                db, sql: "SELECT bookId FROM upNext WHERE bookId IN (SELECT id FROM book) ORDER BY position, bookId")
        }
    }

    /// Puts books at the end of the Up Next list, in the order given. One that is on
    /// it already keeps its place.
    public func addToUpNext(_ ids: [Int64]) throws {
        try dbQueue.write { db in
            var last = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) FROM upNext") ?? -1
            for id in ids {
                guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book WHERE id = ?", arguments: [id]) == 1,
                      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM upNext WHERE bookId = ?", arguments: [id]) == 0
                else { continue }
                last += 1
                try db.execute(sql: "INSERT INTO upNext (bookId, position) VALUES (?, ?)", arguments: [id, last])
            }
        }
    }

    public func removeFromUpNext(_ ids: [Int64]) throws {
        try dbQueue.write { db in
            for id in ids { try db.execute(sql: "DELETE FROM upNext WHERE bookId = ?", arguments: [id]) }
        }
    }
}
