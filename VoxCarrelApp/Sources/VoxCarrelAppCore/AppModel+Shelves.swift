import Foundation
import VoxCarrelCore

// Smart shelves and Up Next. SH10 onwards.
//
// A smart shelf is a saved set of conditions; the books on it are worked out each time
// it is looked at. Up Next lists what to pick up now: the books being read, the next
// book of each series that has been begun, whether the library has it or not, and the
// books put there by hand. Its lines keep their own order whatever the sort, and are
// never grouped by series. Nothing here touches a file, and nothing is undone by Undo.

extension AppModel {
    // MARK: The sidebar

    /// The smart shelves as the sidebar lists them, each with its number of books.
    public var shelves: [ShelfRow] {
        sidebar.shelves.compactMap { shelf in
            shelf.id.map { ShelfRow(id: $0, name: shelf.name, count: sidebar.shelfCounts[$0] ?? 0) }
        }
    }

    /// How many lines Up Next has.
    public var upNextCount: Int {
        sidebar.upNextCount
    }

    // MARK: Adding to Up Next by hand

    public var addToUpNextTitle: String { "Add to Up Next" }
    public var removeFromUpNextTitle: String { "Remove from Up Next" }

    /// Whether Up Next can be changed for these books now: they are books of the
    /// library, and nothing is running or in the way.
    private func upNextCanChange(for ids: Set<Int64>) -> Bool {
        isLibraryOpen && !ids.isEmpty && !holdsMissing(ids) && busyLabel == nil && layoutPreview == nil
            && sendSession == nil && mergeSession == nil
    }

    /// Those of these books that can be put on Up Next, in the order shown: the ones
    /// that are not there by hand already and are not finished.
    private func addableToUpNext(_ ids: Set<Int64>) -> [Int64] {
        rows.filter { row in
            ids.contains(row.id) && !sidebar.upNextQueued.contains(row.id) && row.book.readStatus != .finished
        }.map(\.id)
    }

    /// Those of these books that were put on Up Next by hand. A book that is there
    /// because it is being read, or is the next of its series, is not one to take off.
    private func removableFromUpNext(_ ids: Set<Int64>) -> [Int64] {
        ordered(ids.intersection(sidebar.upNextQueued))
    }

    /// Whether any of these books can be put on Up Next. Never for a row that stands
    /// for a book the library does not have.
    public func canAddToUpNext(_ ids: Set<Int64>) -> Bool {
        upNextCanChange(for: ids) && !addableToUpNext(ids).isEmpty
    }

    /// Whether any of these books can be taken off Up Next: one was put there by hand.
    public func canRemoveFromUpNext(_ ids: Set<Int64>) -> Bool {
        upNextCanChange(for: ids) && !removableFromUpNext(ids).isEmpty
    }

    /// The same for the selected books.
    public var canAddToUpNext: Bool { canAddToUpNext(selection) }
    public var canRemoveFromUpNext: Bool { canRemoveFromUpNext(selection) }

    /// Puts those of these books that can be on Up Next, after the ones already there.
    /// The sidebar's count follows and, when Up Next is shown, so do the rows.
    public func addToUpNext(_ ids: Set<Int64>) async {
        guard canAddToUpNext(ids) else { return }
        let adding = addableToUpNext(ids)
        await perform("Updating…") { worker in
            try await worker.addToUpNext(adding)
        }
    }

    /// Takes off Up Next those of these books that were put there by hand.
    public func removeFromUpNext(_ ids: Set<Int64>) async {
        guard canRemoveFromUpNext(ids) else { return }
        let removing = removableFromUpNext(ids)
        await perform("Updating…") { worker in
            try await worker.removeFromUpNext(removing)
        }
    }

    public func addSelectionToUpNext() async {
        await addToUpNext(selection)
    }

    public func removeSelectionFromUpNext() async {
        await removeFromUpNext(selection)
    }

    // MARK: Making and changing a shelf

    /// Whether a shelf can be made, changed or deleted now: a library is open, nothing
    /// is running, no question is waiting, and no sheet of the window is up, the
    /// editor of a shelf included. One sheet at a time.
    public var canBeginShelf: Bool {
        isLibraryOpen && busyLabel == nil && storedPrompt == nil && shelfEditor == nil
            && windowSheet(progressDue: false) == nil
    }

    /// Opens the editor on a new shelf, which has no name and no conditions yet.
    public func beginNewShelf() {
        guard canBeginShelf else { return }
        shelfEditor = ShelfEditor(model: self, shelf: nil)
    }

    /// Opens the editor on the stored shelf with this id. Does nothing when there is none.
    public func beginEditShelf(_ id: Int64) {
        guard canBeginShelf, let shelf = sidebar.shelves.first(where: { $0.id == id }) else { return }
        shelfEditor = ShelfEditor(model: self, shelf: shelf)
    }

    /// Closes the editor. Nothing is stored.
    public func closeShelfEditor() {
        shelfEditor = nil
    }

    /// The library's own values for a kind of condition that is a name, for the editor
    /// to offer; none for any other kind.
    func shelfSuggestions(for kind: ShelfConditionKind) -> [String] {
        switch kind {
        case .genre: sidebar.browse[.genre] ?? []
        case .author: sidebar.browse[.authors] ?? []
        case .narrator: sidebar.browse[.narrators] ?? []
        case .series: sidebar.browse[.series] ?? []
        case .tag: sidebar.tags
        default: []
        }
    }

    /// How many books a shelf would hold now; nil when the library could not say.
    func shelfCount(_ shelf: SmartShelf) async -> Int? {
        guard let worker else { return nil }
        return try? await worker.shelfCount(shelf)
    }

    /// Stores the editor's shelf, reads the sidebar again, shows the shelf's books and
    /// closes the editor. When it cannot be stored the editor stays, and `alert` says why.
    func saveShelf(_ shelf: SmartShelf, from editor: ShelfEditor) async {
        guard shelfEditor === editor, let worker = await begin("Saving shelf…") else { return }
        var stored: SmartShelf?
        do {
            stored = try await worker.saveSmartShelf(shelf)
        } catch {
            show(error)
        }
        if stored != nil { shelfEditor = nil }
        await finish()
        if let id = stored?.id {
            sidebarSelection = .shelf(id)
            await latestReload?.value
        }
    }

    // MARK: Deleting a shelf

    public func canDeleteShelf(_ id: Int64) -> Bool {
        canBeginShelf && sidebar.shelves.contains { $0.id == id }
    }

    /// Asks whether to delete the shelf: `prompt` becomes `.deleteShelf`. Nothing is
    /// deleted until `confirmDeleteShelf`.
    public func deleteShelf(_ id: Int64) {
        guard canDeleteShelf(id), let shelf = sidebar.shelves.first(where: { $0.id == id }) else { return }
        raise(.deleteShelf(id: id, name: shelf.name))
    }

    /// The answer "delete" to `.deleteShelf`. The books stay in the library. When the
    /// shelf is the one being looked at, All Books is shown.
    public func confirmDeleteShelf() async {
        guard busyLabel == nil, case .deleteShelf(let id, _) = storedPrompt else { return }
        storedPrompt = nil
        await perform("Deleting shelf…") { worker in
            try await worker.deleteSmartShelf(id: id)
        }
    }
}
