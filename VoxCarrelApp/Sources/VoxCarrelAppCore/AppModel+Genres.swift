import Foundation
import VoxCarrelCore

// Genres in the app model (genres plan, Task 4): the sidebar's tree and what is
// selected in it, the chips of the inspector and the import review, and the changes to
// the library's list that Manage Genres asks for. G13, G19–G27, G34–G36, GH-a, GH-b.

/// One genre of the sidebar's tree.
public struct GenreTreeItem: Identifiable, Equatable, Sendable {
    public var name: String
    /// How many books have it.
    public var count: Int

    public var id: String { name }
    /// What selecting it selects.
    public var item: SidebarItem { .browse(.genre, name) }
}

/// One group of the sidebar's tree, with the genres under it.
public struct GenreTreeGroup: Identifiable, Equatable, Sendable {
    public var group: GenreGroup
    public var title: String
    /// How many books have a genre of the group, each counted once.
    public var count: Int
    /// The genres of the group that have books: the built-in ones in their own order,
    /// then the owner's own by name.
    public var genres: [GenreTreeItem]
    public var isOpen: Bool

    public var id: GenreGroup { group }
    /// What selecting it selects.
    public var item: SidebarItem { .genreGroup(group) }
}

/// G13: what the Genres header offers while files differ from the library.
public struct GenreFilesOffer: Equatable, Sendable {
    /// "Update files…"
    public var title: String
    /// How many books have files to update.
    public var count: Int
    /// "The genre tags in the files of 3 books differ from the library."
    public var help: String
}

/// One change to the library's list of genres.
public enum GenreListChange: Equatable, Sendable {
    case rename(String, to: String)
    case merge(String, into: String)
    case move(String, to: GenreGroup)
    case delete(String)
    /// Puts every built-in name back.
    case reset

    /// What is shown while it runs.
    var busyLabel: String {
        switch self {
        case .rename: "Renaming genre…"
        case .merge: "Merging genres…"
        case .move: "Moving genre…"
        case .delete: "Deleting genre…"
        case .reset: "Resetting genre names…"
        }
    }

    /// What Undo calls it, as the library records it.
    var undoLabel: String {
        switch self {
        case .rename: "Rename genre"
        case .merge: "Merge genres"
        case .move: "Move genre"
        case .delete: "Delete genre"
        case .reset: "Reset genre names"
        }
    }
}

/// How a change to the list went.
public enum GenreChangeOutcome: Equatable, Sendable {
    case done
    /// G24: the new name is another genre's, as the list names it. Nothing was changed.
    case nameInUse(String)
    /// It was refused, with why as a sentence. Nothing was changed.
    case refused(String)
    /// It was not tried: something else has the library.
    case notTried
}

/// A genre's name on the sidebar becoming another.
struct GenreRenamed: Equatable {
    var from: String
    var to: String
}

/// A sidebar selection to go back to, while the selection is still where it was left.
struct GenreSelectionReturn: Equatable {
    var expect: SidebarItem
    var back: SidebarItem
}

/// GH-b: where the sidebar selection goes when the list has been read again.
struct GenreFollow: Equatable {
    var renames: [GenreRenamed] = []
    var selection: GenreSelectionReturn?
    /// The item that was selected when the change was made, when moving from it is to
    /// be remembered for Undo.
    var remembering: SidebarItem?
}

/// GH-b: how the selection goes back when the change Undo would reverse is undone.
/// GH27: and how unsaved genres go back with it.
struct GenreUndo: Equatable {
    /// The undo label of the change.
    var label: String
    var renames: [GenreRenamed] = []
    var selection: GenreSelectionReturn?
    /// The unsaved genres as the change found them and as it left them; nil when it
    /// changed none.
    var unsaved: UnsavedGenresChange?
}

/// GH27: what a change to the list does to the names of genres that are not saved yet.
struct GenreNameChange: Equatable {
    var renames: [GenreRenamed] = []
    /// The genres that are no more.
    var drops: [String] = []
    /// The genres among `renames` that were merged into another, not given a new name.
    var merged: [String] = []

    var isEmpty: Bool { renames.isEmpty && drops.isEmpty }

    /// The names as they are after the change, in their order: a renamed or merged
    /// genre by the name it has now, a deleted one left out, and none twice.
    func names(_ names: [String]) -> [String] {
        GenreName.distinct(
            names.compactMap { name in
                if drops.contains(where: { GenreName.same($0, name) }) { return nil }
                return renames.first { GenreName.same($0.from, name) }?.to ?? name
            })
    }
}

/// GH27: the genres that are in the app and not yet in the library: those of the
/// inspector's draft, those to add to and take from several books, and those of the
/// entries of an import being reviewed.
struct UnsavedGenres: Equatable {
    struct Draft: Equatable {
        var bookId: Int64?
        var genres: [String]
        /// The genres of the book the draft was made from.
        var own: [String]
    }

    var draft: Draft?
    var adds: [String]?
    var removes: [String]?
    var entries: [UUID: [String]] = [:]
}

/// GH27: the unsaved genres on either side of a change to the list.
struct UnsavedGenresChange: Equatable {
    var before: UnsavedGenres
    var after: UnsavedGenres
}

extension AppModel {
    // MARK: The sidebar's tree

    /// The library's list of genres as last read, for saying what a name comes to in it.
    public var genreCatalogue: GenreCatalogue {
        GenreCatalogue(sidebar.genres)
    }

    /// G34, G36: each group that has books, with its genres that have books and a count
    /// beside each. GH-a: within a group the built-in genres in their own order, then
    /// the owner's own by name.
    public var genreTree: [GenreTreeGroup] {
        GenreGroup.allCases.compactMap { group in
            let count = sidebar.genreGroupCounts[group] ?? 0
            guard count > 0 else { return nil }
            let genres = sidebar.genres
                .filter { $0.group == group && !$0.isHidden && $0.bookCount > 0 }
                .map { GenreTreeItem(name: $0.name, count: $0.bookCount) }
            return GenreTreeGroup(
                group: group, title: group.title, count: count, genres: genres, isOpen: isOpen(group: group))
        }
    }

    /// G36: how many books have no genre.
    public var noGenreCount: Int {
        sidebar.noGenreCount
    }

    /// G36: whether "No genre" is shown, at the bottom of the tree: while any book has none.
    public var showsNoGenre: Bool {
        noGenreCount > 0
    }

    /// G13: how many books have files whose genre tag differs from what would be written.
    public var genreFilesToUpdate: Int {
        sidebar.genreFilesToUpdate
    }

    /// G13: "Update files…" with its count, for the Genres header; nil when no file differs.
    public var genreFilesOffer: GenreFilesOffer? {
        let count = genreFilesToUpdate
        guard count > 0 else { return nil }
        return GenreFilesOffer(
            title: "Update files…", count: count,
            help: count == 1
                ? "The genre tag in the files of 1 book differs from the library."
                : "The genre tags in the files of \(count) books differ from the library.")
    }

    /// G35: shows the books that have this genre, whatever its place in their lists.
    public func select(genre name: String) {
        sidebarSelection = .browse(.genre, name)
    }

    /// G35: shows every book with a genre of this group, each once.
    public func select(group: GenreGroup) {
        sidebarSelection = .genreGroup(group)
    }

    /// G36: shows the books that have no genre.
    public func selectNoGenre() {
        sidebarSelection = .noGenre
    }

    /// G34: whether a group of the tree is open. Open until the owner closes it.
    public func isOpen(group: GenreGroup) -> Bool {
        !closedGenreGroups.contains(group)
    }

    /// G34: opens or closes a group of the tree. Remembered.
    public func setOpen(_ open: Bool, group: GenreGroup) {
        if open { closedGenreGroups.remove(group) } else { closedGenreGroups.insert(group) }
        defaults.set(
            GenreGroup.allCases.filter(closedGenreGroups.contains).map(\.rawValue), forKey: GenreKeys.closedGroups)
    }

    // MARK: Choosing genres

    /// G21, G22: what the inspector's genre field offers for what has been typed into
    /// it. The genres the inspected book has are left out; with several books
    /// selected, the ones they all have.
    public func genreSuggestions(for typed: String) -> GenreSuggestions {
        let has: [String]
        switch inspecting {
        case .one(_, let draft): has = draft.genres
        case .many(let draft): has = draft.genres.filter { !$0.isMixed }.map(\.name)
        case .nothing, .missing: has = []
        }
        return genreSuggestions(for: typed, excluding: has)
    }

    /// The same for any other place genres are chosen (an entry of the import review):
    /// `excluding` are the genres it has already.
    public func genreSuggestions(for typed: String, excluding: [String]) -> GenreSuggestions {
        genreCatalogue.suggestions(for: typed, excluding: excluding)
    }

    /// G21: puts a genre of the list on the inspected book, at the end, or on every
    /// selected book that lacks it. Nothing is written until the draft is saved.
    ///
    /// G22: a source's name for a genre ("sci-fi") is that genre. A name the list does
    /// not have is not added: it is made first, with `createDraftGenre`.
    public func addDraftGenre(_ name: String) {
        guard let listed = genreCatalogue.listedGenre(forTyped: name) else { return }
        switch inspecting {
        case .one: updateDraft { $0.addGenre(listed) }
        case .many: updateBulkDraft { $0.addGenre(listed) }
        case .nothing, .missing: break
        }
    }

    /// G21: takes a genre from the inspected book, or from every selected book that has it.
    public func removeDraftGenre(_ name: String) {
        switch inspecting {
        case .one: updateDraft { $0.removeGenre(name) }
        case .many: updateBulkDraft { $0.removeGenre(name) }
        case .nothing, .missing: break
        }
    }

    /// G21: puts the inspected book's genre at `source` at `destination`.
    public func moveDraftGenre(from source: Int, to destination: Int) {
        updateDraft { $0.moveGenre(from: source, to: destination) }
    }

    /// G22: makes a genre of the owner's own in a group, and returns its name as the
    /// list has it. A name the list already has, or knows as a source's name for a
    /// genre, is that genre and nothing is made. Nil when the name cannot be a
    /// genre's: `alert` says why.
    ///
    /// The list changes at once and no book does. It is not something Undo reverses.
    @discardableResult
    public func createGenre(_ name: String, group: GenreGroup) async -> String? {
        if let listed = genreCatalogue.listedGenre(forTyped: name) { return listed }
        guard let worker else { return nil }
        do {
            let made = try await worker.addGenre(name, group: group)
            sidebar.genres = try await worker.genreList()
            return made
        } catch {
            show(error)
            return nil
        }
    }

    /// G22: makes the genre and puts it on the inspected book, or the selected books.
    public func createDraftGenre(_ name: String, group: GenreGroup) async {
        guard let made = await createGenre(name, group: group) else { return }
        addDraftGenre(made)
    }

    // MARK: The import review

    /// G19: puts a genre of the list on an entry of the import review, at the end.
    public func addImportGenre(_ name: String, to entry: UUID) {
        guard let listed = genreCatalogue.listedGenre(forTyped: name) else { return }
        changeImportGenres(of: entry) { GenreChips.adding(listed, to: $0) }
    }

    /// G19: takes a genre from an entry of the import review.
    public func removeImportGenre(_ name: String, from entry: UUID) {
        changeImportGenres(of: entry) { GenreChips.removing(name, from: $0) }
    }

    /// G19: puts an entry's genre at `source` at `destination`.
    public func moveImportGenre(from source: Int, to destination: Int, in entry: UUID) {
        changeImportGenres(of: entry) { GenreChips.moving($0, from: source, to: destination) }
    }

    /// G22: makes the genre and puts it on an entry of the import review.
    public func createImportGenre(_ name: String, group: GenreGroup, for entry: UUID) async {
        guard let made = await createGenre(name, group: group) else { return }
        addImportGenre(made, to: entry)
    }

    private func changeImportGenres(of entry: UUID, _ change: ([String]) -> [String]) {
        updateReview { review in
            review.update(entry) { $0.candidate.metadata.genres = change($0.candidate.metadata.genres) }
        }
    }

    // MARK: Changing the list

    /// Whether the list of genres can be changed now: a library is open and nothing
    /// else has it.
    var genresCanChange: Bool {
        isLibraryOpen && busyLabel == nil && layoutPreview == nil && sendSession == nil && mergeSession == nil
            && !layoutChangeIsUnresolved
    }

    /// G23–G27: makes one change to the list of genres, as one operation that Undo
    /// reverses. No file is written. GH-b: the sidebar selection follows a genre that
    /// is renamed or merged, and goes back with it when the change is undone.
    func changeGenreList(_ change: GenreListChange) async -> GenreChangeOutcome {
        let selected = sidebarSelection
        let listBefore = sidebar.genres
        guard genresCanChange, let worker = await begin(change.busyLabel) else { return .notTried }
        var outcome = GenreChangeOutcome.done
        do {
            try await worker.changeGenreList(change)
            followGenres(after: change, selected: selected, listBefore: listBefore)
        } catch LibraryService.GenreChangeError.nameInUse(let other) {
            outcome = .nameInUse(other)
        } catch {
            outcome = .refused(UserMessage.text(for: error))
        }
        await finish()
        return outcome
    }

    /// GH-b: notes where the selection is to go once the list is read again, and how
    /// it goes back if the change is undone.
    private func followGenres(after change: GenreListChange, selected: SidebarItem, listBefore: [GenreEntry]) {
        var follow = GenreFollow()
        var undo = GenreUndo(label: change.undoLabel)
        func isSelected(_ name: String) -> Bool {
            if case .browse(.genre, let now) = selected { return GenreName.same(now, name) }
            return false
        }
        switch change {
        case .rename(let name, let new):
            let new = GenreName.valid(new) ?? new
            follow.renames = [GenreRenamed(from: name, to: new)]
            undo.renames = [GenreRenamed(from: new, to: name)]
        case .merge(let name, let other):
            follow.renames = [GenreRenamed(from: name, to: other)]
            if isSelected(name) { follow.remembering = selected }
        case .delete(let name):
            // The selection falls back by itself: its genre is no longer on the sidebar.
            if isSelected(name) { undo.selection = GenreSelectionReturn(expect: .allBooks, back: selected) }
        case .reset:
            for entry in listBefore {
                guard let shipped = entry.builtInName, !entry.isHidden, shipped != entry.name else { continue }
                follow.renames.append(GenreRenamed(from: entry.name, to: shipped))
                undo.renames.append(GenreRenamed(from: shipped, to: entry.name))
            }
        case .move:
            break
        }
        // GH27: what is not saved yet follows the change now, before it is read again.
        var names = GenreNameChange(renames: follow.renames)
        if case .delete(let name) = change { names.drops = [name] }
        if case .merge(let name, _) = change { names.merged = [name] }
        let before = unsavedGenres
        followUnsavedGenres(names)
        let after = unsavedGenres
        if after != before { undo.unsaved = UnsavedGenresChange(before: before, after: after) }
        genreFollow = follow
        genreUndo = undo
    }

    // MARK: Unsaved genres follow the list (GH27)

    /// The genres that are not saved yet, as they are now.
    var unsavedGenres: UnsavedGenres {
        var unsaved = UnsavedGenres()
        switch inspecting {
        case .one(_, let draft):
            unsaved.draft = UnsavedGenres.Draft(
                bookId: draft.original.id, genres: draft.genres, own: draft.original.genres)
        case .many(let draft):
            unsaved.adds = draft.genreAdds
            unsaved.removes = draft.genreRemoves
        case .nothing, .missing:
            break
        }
        for entry in review?.entries ?? [] { unsaved.entries[entry.id] = entry.genres }
        return unsaved
    }

    /// GH27: gives every unsaved genre the name it has after a change to the list, so
    /// that saving cannot bring back a name the list no longer has: a renamed genre by
    /// its new name, a merged one by the genre it went into, a deleted one not at all.
    func followUnsavedGenres(_ change: GenreNameChange) {
        guard !change.isEmpty else { return }
        switch inspecting {
        case .one: updateDraft { $0.followGenres(change.names) }
        case .many: updateBulkDraft { $0.followGenres(change.names, merged: change.merged) }
        case .nothing, .missing: break
        }
        let entries = (review?.entries ?? []).filter { change.names($0.genres) != $0.genres }.map(\.id)
        guard !entries.isEmpty else { return }
        updateReview { review in
            for id in entries {
                review.update(id) { $0.candidate.metadata.genres = change.names($0.candidate.metadata.genres) }
            }
        }
    }

    /// GH27: when a change to the list has been undone, puts the unsaved genres back as
    /// the change found them. Any that were changed since are left as they are, but
    /// for the names the undo gave back.
    func returnUnsavedGenres(_ undone: GenreUndo) {
        let back = GenreNameChange(renames: undone.renames)
        guard let change = undone.unsaved else {
            followUnsavedGenres(back)
            return
        }
        let now = unsavedGenres
        switch inspecting {
        case .one:
            if let before = change.before.draft, let after = change.after.draft, let draft = now.draft,
               draft.bookId == after.bookId, draft.genres == after.genres {
                updateDraft { $0.restoreGenres(before.genres, original: before.own) }
            } else {
                updateDraft { $0.followGenres(back.names) }
            }
        case .many:
            if let adds = change.before.adds, let removes = change.before.removes,
               now.adds == change.after.adds, now.removes == change.after.removes {
                updateBulkDraft { $0.restoreGenres(adds: adds, removes: removes) }
            } else {
                updateBulkDraft { $0.followGenres(back.names) }
            }
        case .nothing, .missing:
            break
        }
        var genres: [UUID: [String]] = [:]
        for (id, shown) in now.entries {
            let restored = change.after.entries[id] == shown ? change.before.entries[id] : nil
            let wanted = restored ?? back.names(shown)
            if wanted != shown { genres[id] = wanted }
        }
        guard !genres.isEmpty else { return }
        updateReview { review in
            for (id, wanted) in genres {
                review.update(id) { $0.candidate.metadata.genres = wanted }
            }
        }
    }

    /// GH-b: where the sidebar selection goes now that the list has been read again;
    /// nil when it stays. A genre that was renamed or merged takes the selection with
    /// it, when the genre it became is one the sidebar shows.
    func genreSelection(following sidebar: SidebarData) -> SidebarItem? {
        guard let follow = genreFollow else { return nil }
        genreFollow = nil
        let selected = sidebarSelection
        if case .browse(.genre, let name) = selected,
           let renamed = follow.renames.first(where: { GenreName.same($0.from, name) }) {
            let listed = GenreCatalogue(sidebar.genres).listed(renamed.to) ?? renamed.to
            let target = SidebarItem.browse(.genre, listed)
            guard target != selected, sidebar.contains(target) else { return nil }
            if follow.remembering == selected {
                genreUndo?.selection = GenreSelectionReturn(expect: target, back: selected)
            }
            return target
        }
        if let back = follow.selection, back.expect == selected, sidebar.contains(back.back) {
            return back.back
        }
        return nil
    }

    // MARK: The three sheets

    /// Whether none of the three sheets about genres is open. One at a time: what one
    /// shows was read before another could change it.
    var noGenreSheetIsOpen: Bool {
        genreManager == nil && genreFilesUpdate == nil && genreFill == nil
    }

    /// G23: whether Manage Genres can be opened.
    public var canManageGenres: Bool {
        genresCanChange && noGenreSheetIsOpen
    }

    /// G23: opens Manage Genres.
    public func beginManageGenres() {
        guard canManageGenres else { return }
        genreManager = GenreManager(model: self)
    }

    public func closeManageGenres() {
        genreManager = nil
    }

    /// G13: whether there are files to update, and they can be updated now.
    public var canUpdateGenreFiles: Bool {
        genresCanChange && filesCanChange && genreFilesToUpdate > 0 && noGenreSheetIsOpen
    }

    /// G14: opens the preview of "Update files…": what each book's files hold and what
    /// will be written. Nothing is written by opening it.
    public func beginGenreFilesUpdate() async {
        guard genresCanChange, filesCanChange, noGenreSheetIsOpen, let worker else { return }
        do {
            // Read off the main thread: it goes through every book.
            let differences = try await worker.genreFileDifferences()
            guard genresCanChange, noGenreSheetIsOpen else { return }
            genreFilesUpdate = GenreFilesUpdate(model: self, differences: differences)
        } catch {
            show(error)
        }
    }

    /// G29: whether Fill in Genres can be opened.
    public var canFillInGenres: Bool {
        genresCanChange && filesCanChange && noGenreSheetIsOpen
    }

    /// G29: opens Fill in Genres. Nothing is looked up until it is started.
    public func beginGenreFill() async {
        guard canFillInGenres, let worker else { return }
        do {
            let none = try await worker.genreFillCandidates(includingGeneral: false)
            let general = try await worker.genreFillCandidates(includingGeneral: true)
            guard canFillInGenres else { return }
            genreFill = GenreFillSession(model: self, withNoGenre: none, withGeneral: general)
        } catch {
            show(error)
        }
    }

    /// Closes whatever is open about genres: for when another library is opened.
    func closeGenreSheets() {
        genreManager = nil
        genreFilesUpdate = nil
        genreFill?.stop()
        genreFill = nil
        genreFollow = nil
        genreUndo = nil
    }
}
