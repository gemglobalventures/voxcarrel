import Foundation
import VoxCarrelCore

// Books kept where their files are, outside the library folder. They are added that
// way at import ("Leave the files where they are"); their files are never moved or
// written to, and their details are the catalogue's alone. They can be brought into
// the library later, as copies that leave the originals where they were, or by moving.

extension AppModel {
    public static let bringInCopyTitle = "Bring into the Library (Copy)"
    public static let bringInMoveTitle = "Bring into the Library (Move)"

    /// The books among these that are kept outside the library.
    func outside(_ ids: Set<Int64>) -> [Int64] {
        rows.filter { ids.contains($0.id) && $0.book.keptOutside }.map(\.id)
    }

    /// Whether any of these books can be brought into the library now.
    public func canBringIntoLibrary(_ ids: Set<Int64>) -> Bool {
        isLibraryOpen && busyLabel == nil && !libraryIsAway && !holdsMissing(ids) && !outside(ids).isEmpty
    }

    /// Brings the books among these that are kept outside into the library: filed
    /// under its folder layout, with the catalogue's details written into them. One
    /// operation, which Undo takes back. What could not be brought in is said in `alert`.
    public func bringIntoLibrary(_ ids: Set<Int64>, copying: Bool) async {
        guard canBringIntoLibrary(ids) else { return }
        let books = outside(ids)
        var outcome: BroughtIn?
        await perform(copying ? "Copying into the library…" : "Moving into the library…") { worker in
            outcome = try await worker.withService { try $0.bringIntoLibrary(books, mode: copying ? .copy : .move) }
        }
        guard let outcome, !outcome.problems.isEmpty else { return }
        let done = outcome.brought == 1 ? "1 book was brought into the library." : "\(outcome.brought) books were brought into the library."
        alert = ([done] + outcome.problems).joined(separator: "\n")
    }
}
