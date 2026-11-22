import Foundation
import VoxCarrelCore

// Books owned on Audible (plan 6, Task 3). R7, R8.
//
// Marking a book changes only the catalogue: no file is opened, moved or written, and it
// is not an operation Undo reverses. Taking the mark away again is the way back.

extension AppModel {
    // MARK: R8 Marking

    /// R8: marks these books as owned on Audible, or takes the mark away. Applied at
    /// once, with no Save, and unsaved edits are kept (as for read status).
    ///
    /// Marking gives each book that is not on Audible yet an Audible copy, as an
    /// audiobook, in the store of the settings, with the book's ASIN when it has one. A
    /// book that is marked already is left exactly as it is.
    ///
    /// Unmarking a book that has no files would leave an empty entry: it stays marked,
    /// and `alert` names it and says to remove it instead.
    public func setOnAudible(_ on: Bool, for ids: Set<Int64>) async {
        let ids = ordered(ids)
        guard !ids.isEmpty else { return }
        let store = audibleStore
        var refused: [Int64] = []
        await perform("Updating…") { worker in
            refused = try await worker.setOnAudible(on, for: ids, store: store)
        }
        guard !refused.isEmpty else { return }
        if refused.count == 1 {
            let title = rows.first { $0.id == refused[0] }?.book.title.trimmedOrNil
            let book = title.map { "“\($0)”" } ?? "This book"
            alert = "\(book) has no files, so it would vanish from the library. Remove it instead."
        } else {
            alert = "\(refused.count) books have no files, so they would vanish from the library. "
                + "Remove them instead."
        }
    }

    /// R8: whether the selected books can be marked or unmarked now: a library is open,
    /// there is a selection, and nothing is running.
    public var canMarkOnAudible: Bool {
        canMarkOnAudible(for: selection)
    }

    /// The same for these books: for a context menu.
    public func canMarkOnAudible(for ids: Set<Int64>) -> Bool {
        isLibraryOpen && busyLabel == nil && !ids.isEmpty
    }

    /// R8: what the menu item says: "Unmark as on Audible" when every selected book is
    /// on Audible already, "Mark as on Audible" otherwise.
    public var markOnAudibleTitle: String {
        markOnAudibleTitle(for: selection)
    }

    /// The same for these books: for a context menu.
    public func markOnAudibleTitle(for ids: Set<Int64>) -> String {
        areAllOnAudible(ids) ? "Unmark as on Audible" : "Mark as on Audible"
    }

    /// R8: does what `markOnAudibleTitle` says, for the selection.
    public func toggleOnAudible() async {
        await toggleOnAudible(for: selection)
    }

    /// The same for these books: for a context menu.
    public func toggleOnAudible(for ids: Set<Int64>) async {
        await setOnAudible(!areAllOnAudible(ids), for: ids)
    }

    /// True when there are books and every one of them is shown and on Audible.
    private func areAllOnAudible(_ ids: Set<Int64>) -> Bool {
        let chosen = rows.filter { ids.contains($0.id) }
        return !ids.isEmpty && chosen.count == ids.count && chosen.allSatisfy(\.isOnAudible)
    }

    // MARK: R7 The inspector

    /// R7: where the one inspected book is owned other than as files:
    /// "On Audible (United Kingdom) · not on this Mac". Nil when it is not on Audible,
    /// and when one book is not what is inspected.
    public var inspectorOwnershipText: String? {
        guard case .one(let detail, _) = inspecting else { return nil }
        return detail.ownershipText
    }

    /// R7: whether the inspector's "On Audible" switch is on: the one inspected book is
    /// marked. Changed with `setOnAudible`.
    public var inspectorIsOnAudible: Bool {
        guard case .one(let detail, _) = inspecting else { return false }
        return detail.row.isOnAudible
    }
}

extension BookDetail {
    /// R7: "On Audible (United Kingdom)", with " · not on this Mac" for a book that has
    /// no files. The store is the one the book's Audible copy names; when it names none
    /// (or one this version does not know) no country is given. Nil for a book that is
    /// not on Audible.
    public var ownershipText: String? {
        guard let copy = row.book.externalCopies.first(where: { $0.kind == .audible }) else { return nil }
        var text = "On \(copy.kind.title)"
        if let store = copy.store.flatMap(AudibleStore.init(rawValue:)) { text += " (\(store.title))" }
        return row.hasFiles ? text : text + " · not on this Mac"
    }
}
