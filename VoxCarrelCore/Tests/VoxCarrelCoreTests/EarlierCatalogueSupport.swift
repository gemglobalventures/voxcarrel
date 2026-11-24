import GRDB
@testable import VoxCarrelCore

/// One row of a catalogue made by an earlier version, for comparing with the same row
/// once this version has opened the catalogue.
typealias EarlierRow = [String: DatabaseValue]

/// The columns of the book table that the change to several genres (v12) renamed or
/// added. They are left out of the comparison, and have tests of their own.
private let genreColumns: Set<String> = ["genre", "genreSource", "genres", "genreTag"]

/// A table's rows in row order, the book table's genre columns left out.
func earlierRows(_ db: Database, of table: String) throws -> [EarlierRow] {
    try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map { row in
        var values: EarlierRow = [:]
        for (column, value) in row where !genreColumns.contains(column) { values[column] = value }
        return values
    }
}

/// The tables whose definitions must read the same before and after, as an SQL list:
/// every one but the book table, whose genre columns v12 changes.
func earlierSchemaTables(_ tables: [String]) -> String {
    tables.filter { $0 != "book" }.map { "'\($0)'" }.joined(separator: ",")
}
