import GRDB
@testable import VoxCarrelCore

/// One row of a catalogue made by an earlier version, for comparing with the same row
/// once this version has opened the catalogue.
typealias EarlierRow = [String: DatabaseValue]

/// The columns of the book table that the change to several genres (v12) renamed or
/// added. They are left out of the comparison, and have tests of their own.
/// So is the column v13 added to the file table, for what a file was when it arrived,
/// and the one v18 added to the book table, for a book kept out of sight (HB1 onwards).
private let genreColumns: Set<String> = ["genre", "genreSource", "genres", "genreTag", "arrivedPrint", "contentPrint", "isHidden", "lengthMeasured", "wordCount", "workKey", "editionSuffix", "keptOutside"]

/// The column v21 added to the table of series links, for whose list a link holds.
/// Left out of the comparison of that table alone; WL1 and WL2 test it.
private let seriesLinkColumns: Set<String> = ["source"]

/// A table's rows in row order, the book table's genre columns left out.
func earlierRows(_ db: Database, of table: String) throws -> [EarlierRow] {
    try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map { row in
        var values: EarlierRow = [:]
        for (column, value) in row where !genreColumns.contains(column) {
            if table == "seriesLink", seriesLinkColumns.contains(column) { continue }
            values[column] = value
        }
        return values
    }
}

/// The tables whose definitions must read the same before and after, as an SQL list:
/// every one but the book table, whose genre columns v12 changes, and the file table,
/// to which v13 adds a column, and the table of series links, to which v21 adds one.
func earlierSchemaTables(_ tables: [String]) -> String {
    tables.filter { $0 != "book" && $0 != "bookFile" && $0 != "seriesLink" }.map { "'\($0)'" }.joined(separator: ",")
}
