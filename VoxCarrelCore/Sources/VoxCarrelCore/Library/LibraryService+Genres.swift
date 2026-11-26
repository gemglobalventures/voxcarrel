import Foundation
import GRDB

extension LibraryService {
    /// Why the list of genres could not be changed. Nothing has changed then.
    public enum GenreChangeError: Error, Equatable, Sendable {
        /// The name is empty, or has a comma, a semicolon or a slash in it.
        case invalidName
        /// Another genre has the name, or shipped under it: that genre, as the list
        /// now names it. The two can be merged instead.
        case nameInUse(String)
        /// A built-in genre cannot be deleted.
        case builtIn
        /// No genre that is shown in the list has the name.
        case unknownGenre
    }

    // MARK: Adding

    /// Adds a genre of the owner's own to a group, and returns its name as listed.
    ///
    /// Text the mapping knows as a name for a built-in genre ("Sci-Fi") is that genre:
    /// nothing is added and its name, as the library now has it, is returned. A built-in
    /// genre that was merged away is brought back into sight, empty, when it is asked
    /// for by name. Adding is not recorded for undo, and leaves what can be undone alone.
    ///
    /// - Throws: `GenreChangeError.invalidName`; `.nameInUse` when a genre that is
    ///   shown already has the name.
    @discardableResult
    public func addGenre(_ name: String, group: GenreGroup) throws -> String {
        try refuseWhileLayoutChangeIsInterrupted()
        guard let name = GenreName.valid(name) else { throw GenreChangeError.invalidName }
        return try store.writeGenreList { db, listing in
            if let row = listing.rows.first(where: { GenreName.same($0.name, name) }) {
                guard row.isHidden else { throw GenreChangeError.nameInUse(row.name) }
                try db.execute(
                    sql: "UPDATE genre SET isHidden = 0, mergedInto = NULL WHERE id = ?", arguments: [row.id])
                return row.name
            }
            if let listed = Self.listedGenre(forTyped: name, in: listing) { return listed }
            try db.execute(
                sql: "INSERT INTO genre (name, genreGroup) VALUES (?, ?)", arguments: [name, group.rawValue])
            return name
        }
    }

    // MARK: Renaming

    /// Gives a genre another name, in the list and on every book that has it. A change
    /// of capitalisation only is a rename like any other. No file is written and no
    /// folder moved: the books whose tags then differ are those of
    /// `genreFileDifferences()`. One undoable operation.
    ///
    /// - Throws: `GenreChangeError.unknownGenre`; `.invalidName`; `.nameInUse` when
    ///   another genre has the new name, shown or merged away, or is a built-in genre
    ///   that shipped under it. The caller may then offer to merge the two; nothing is
    ///   merged here.
    public func renameGenre(_ name: String, to new: String) throws {
        // Whatever way this ends, the details files follow the catalogue.
        defer { refreshDetailsFiles() }
        try changeGenreList(label: "Rename genre") { db, listing in
            let row = try Self.shown(name, in: listing)
            guard let new = GenreName.valid(new) else { throw GenreChangeError.invalidName }
            if let other = listing.rows.first(where: { $0.id != row.id && GenreName.same($0.name, new) }) {
                throw GenreChangeError.nameInUse(other.name)
            }
            if let other = listing.rows.first(where: { other in
                other.id != row.id && other.builtInName.map { GenreName.same($0, new) } ?? false
            }) {
                throw GenreChangeError.nameInUse(listing.standing(for: other).name)
            }
            // A wording that files and catalogues use for another genre stays that
            // genre's: taking it would send their books here from then on.
            let meant = GenreMapping.map(.text(new))
            if meant.unknown.isEmpty, meant.builtIn.count == 1,
               let other = listing.rows.first(where: { other in
                   other.id != row.id && other.builtInName.map { GenreName.same($0, meant.builtIn[0]) } ?? false
               }) {
                let standing = listing.standing(for: other)
                if standing.id != row.id { throw GenreChangeError.nameInUse(standing.name) }
            }
            guard new != row.name else { return [] }
            try db.execute(sql: "UPDATE genre SET name = ? WHERE id = ?", arguments: [new, row.id])
            return [GenreRename(from: row.name, to: new)]
        }
    }

    // MARK: Merging

    /// Moves every book from one genre to another and removes the first. A book that
    /// has both keeps one, in the place of the first of the two. A built-in genre
    /// merged away is hidden, not removed, and the list records where it went, so that
    /// its name from a file or a lookup comes to the other genre from then on. No file
    /// is written. One undoable operation.
    ///
    /// Merging into a genre that was itself merged away goes where that one went; when
    /// that is this very genre, the other is brought back and this one goes into it.
    /// Merging a genre into itself changes nothing.
    ///
    /// - Throws: `GenreChangeError.unknownGenre` when the first is not a genre that is
    ///   shown, or the second is not in the list.
    public func mergeGenre(_ name: String, into other: String) throws {
        // Whatever way this ends, the details files follow the catalogue.
        defer { refreshDetailsFiles() }
        try changeGenreList(label: "Merge genres") { db, listing in
            let source = try Self.shown(name, in: listing)
            guard var target = listing.rows.first(where: { GenreName.same($0.name, GenreName.tidied(other)) }) else {
                throw GenreChangeError.unknownGenre
            }
            guard target.id != source.id else { return [] }
            if target.isHidden {
                let standing = listing.standing(for: target)
                if standing.id == source.id || standing.isHidden {
                    try db.execute(
                        sql: "UPDATE genre SET isHidden = 0, mergedInto = NULL WHERE id = ?", arguments: [target.id])
                } else {
                    target = standing
                }
            }
            if source.isBuiltIn {
                try db.execute(
                    sql: "UPDATE genre SET isHidden = 1, mergedInto = ? WHERE id = ?", arguments: [target.id, source.id])
            } else {
                // What was merged into the one that goes is handed on.
                try db.execute(
                    sql: "UPDATE genre SET mergedInto = ? WHERE mergedInto = ?", arguments: [target.id, source.id])
                try db.execute(sql: "DELETE FROM genre WHERE id = ?", arguments: [source.id])
            }
            return [GenreRename(from: source.name, to: target.name)]
        }
    }

    // MARK: Moving

    /// Puts a genre, built in or the owner's own, in another group. Books are not
    /// changed. One undoable operation.
    /// - Throws: `GenreChangeError.unknownGenre`.
    public func moveGenre(_ name: String, to group: GenreGroup) throws {
        try changeGenreList(label: "Move genre") { db, listing in
            let row = try Self.shown(name, in: listing)
            try db.execute(sql: "UPDATE genre SET genreGroup = ? WHERE id = ?", arguments: [group.rawValue, row.id])
            return []
        }
    }

    // MARK: Deleting

    /// Removes a genre of the owner's own from the list and from every book that has
    /// it (`genreList()` says how many). A built-in genre that was merged into it comes
    /// back into sight, empty. No file is written. One undoable operation.
    /// - Throws: `GenreChangeError.unknownGenre`; `.builtIn` for a built-in genre,
    ///   renamed or not.
    public func deleteGenre(_ name: String) throws {
        // Whatever way this ends, the details files follow the catalogue.
        defer { refreshDetailsFiles() }
        try changeGenreList(label: "Delete genre") { db, listing in
            let row = try Self.shown(name, in: listing)
            guard !row.isBuiltIn else { throw GenreChangeError.builtIn }
            try db.execute(
                sql: "UPDATE genre SET isHidden = 0, mergedInto = NULL WHERE mergedInto = ?", arguments: [row.id])
            try db.execute(sql: "DELETE FROM genre WHERE id = ?", arguments: [row.id])
            return [GenreRename(from: row.name, to: nil)]
        }
    }

    // MARK: Resetting

    /// Puts every built-in genre's name back, on the list and on the books, and brings
    /// those that were merged away back into sight, empty: books stay in the genres
    /// the merges put them in. Groups are left as they are, and so are the owner's own
    /// genres; except that one which has taken a built-in genre's name gives way to
    /// that genre, its books going with the name. No file is written. One undoable
    /// operation.
    public func resetBuiltInGenreNames() throws {
        // Whatever way this ends, the details files follow the catalogue.
        defer { refreshDetailsFiles() }
        try changeGenreList(label: "Reset genre names") { db, listing in
            let builtIn = listing.rows.filter(\.isBuiltIn)
            let renamed = builtIn.filter { $0.name != $0.builtInName }
            // Out of each other's way first: two may have exchanged names.
            for row in renamed {
                try db.execute(sql: "UPDATE genre SET name = ? WHERE id = ?", arguments: ["\u{1}reset \(row.id)", row.id])
            }
            // One of the owner's own that has a built-in genre's name gives way to it.
            var renames = renamed.map { GenreRename(from: $0.name, to: $0.builtInName) }
            for own in listing.rows where !own.isBuiltIn {
                guard let taken = builtIn.first(where: { GenreName.same($0.builtInName ?? "", own.name) }) else {
                    continue
                }
                try db.execute(sql: "DELETE FROM genre WHERE id = ?", arguments: [own.id])
                renames.append(GenreRename(from: own.name, to: taken.builtInName))
            }
            for row in renamed {
                try db.execute(sql: "UPDATE genre SET name = builtInName WHERE id = ?", arguments: [row.id])
            }
            try db.execute(sql: "UPDATE genre SET isHidden = 0, mergedInto = NULL WHERE builtInName IS NOT NULL")
            // The books are renamed all at once: a name one genre gives up may be the
            // name another takes.
            return renames
        }
    }

    // MARK: Shared

    /// The genre of this name that is shown in the list.
    private static func shown(_ name: String, in listing: GenreListing) throws -> GenreRow {
        let tidy = GenreName.tidied(name)
        guard let row = listing.rows.first(where: { GenreName.same($0.name, tidy) }), !row.isHidden else {
            throw GenreChangeError.unknownGenre
        }
        return row
    }

    /// Makes one change to the list as one undoable operation (`LibraryStore.changeGenreList`).
    /// Undo data of an earlier operation is discarded once this one is recorded.
    private func changeGenreList(
        label: String, _ change: (Database, GenreListing) throws -> [GenreRename]
    ) throws {
        try refuseWhileLayoutChangeIsInterrupted()
        try beforeCommit?()
        let token = UUID().uuidString
        let recorded = try store.changeGenreList(
            label: label,
            snapshot: { saved in
                var snapshot = OperationSnapshot(token: token, books: [])
                snapshot.genreList = saved
                return try JSONEncoder().encode(snapshot)
            },
            change)
        if recorded { discardUndoData(except: token) }
    }

    /// Undoes a change to the list of genres: the list and the books' genres are as
    /// they were. Nothing else about a book goes back, and a book removed since is
    /// passed over. No file was written, so none is written now.
    func undoGenreListChange(_ batch: OperationBatch, _ saved: GenreListSnapshot) throws -> String {
        try beforeCommit?()
        try store.restoreGenreList(saved)
        forgetUndoData()
        refreshDetailsFiles()
        return batch.label
    }
}
