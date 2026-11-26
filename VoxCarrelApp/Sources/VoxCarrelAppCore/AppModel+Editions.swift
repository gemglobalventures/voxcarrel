import Foundation
import VoxCarrelCore

// Editions of one book: the same book in another language, read by another narrator,
// or as a dramatisation. Each is an entry of its own, with its own folder and files;
// linking says they are one work, and the inspector of each then names the others.

extension AppModel {
    public static let linkEditionsTitle = "Link as Editions of One Book"
    public static let unlinkEditionTitle = "Unlink from Other Editions"

    /// Whether these books can be linked as editions: several books of the library,
    /// with nothing running or in the way.
    public func canLinkEditions(_ ids: Set<Int64>) -> Bool {
        canMergeBooks(ids)
    }

    /// Links these books as editions of one work. Nothing else about them changes.
    public func linkEditions(for ids: Set<Int64>) async {
        guard canLinkEditions(ids) else { return }
        await perform("Linking editions…") { worker in
            try await worker.linkEditions(ids.sorted())
        }
    }

    /// Whether this one book can be unlinked: it is linked to other editions, and
    /// nothing is running.
    public func canUnlinkEdition(_ ids: Set<Int64>) -> Bool {
        guard ids.count == 1, let id = ids.first, !holdsMissing(ids), busyLabel == nil, isLibraryOpen else { return false }
        return rows.first { $0.id == id }?.book.workKey != nil
    }

    /// Unlinks this book from the other editions it was linked to.
    public func unlinkEdition(for ids: Set<Int64>) async {
        guard canUnlinkEdition(ids), let id = ids.first else { return }
        await perform("Unlinking edition…") { worker in
            try await worker.unlinkEdition(id)
        }
    }
}
