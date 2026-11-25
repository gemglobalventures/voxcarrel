import Foundation
import VoxCarrelCore

// Import Calibre Library: the books of a calibre library are copied into this one
// through the import review, with the details calibre's catalogue holds. Nothing in
// the calibre library is ever changed.
extension AppModel {
    /// What the File menu calls the command. It can be chosen whenever Import… can
    /// (`canImport`).
    public static let calibreImportMenuTitle = "Import Calibre Library…"

    static let notACalibreLibrary = "That folder is not a calibre library: it has no metadata.db."
    static let calibreUnreadable = "The calibre library's catalogue could not be read."
    static let calibreAllHere = "Everything in that calibre library is already in your library."
    static let calibreNothingToKeep = "That calibre library has no books VoxCarrel can keep."

    /// Reads the calibre library in this folder and opens the review on its books.
    /// Does nothing when an import could not be begun: while one is being reviewed,
    /// while an operation runs, or with no library open.
    public func beginCalibreImport(_ folder: URL) async {
        // FL12: the import itself would be refused.
        guard folder.isFileURL, review == nil, !layoutChangeIsUnresolved,
              let worker = await begin("Reading the calibre library…")
        else { return }
        do {
            let read = try await worker.prepareCalibreImport(folder)
            if read.scan.seeds.isEmpty {
                alert = read.scan.alreadyInLibrary.isEmpty ? Self.calibreNothingToKeep : Self.calibreAllHere
            } else {
                reviewIsOfUntracked = false
                await openReview(
                    ImportReview(
                        seeds: read.scan.seeds, skipped: read.scan.skipped, copyInsteadOfMove: true,
                        alreadyInLibrary: read.scan.alreadyInLibrary.count,
                        calibre: ImportReview.CalibreSource(
                            extras: read.extras, withoutFiles: read.withoutFiles.count,
                            formatsLeftOut: read.formatsLeftOut)))
            }
        } catch CalibreLibraryError.notACalibreLibrary {
            alert = Self.notACalibreLibrary
        } catch CalibreLibraryError.unreadable {
            alert = Self.calibreUnreadable
        } catch {
            show(error)
        }
        // Reading changes nothing in the library, so there is nothing to reload.
        busyLabel = nil
    }

    /// Gives each book that was imported what calibre said of it beyond its files:
    /// also a book of the library that an item was added to. An item that failed
    /// brought nothing in, and gives nothing.
    ///
    /// - Parameter outcomes: One for each item, in the items' order, as the import
    ///   answers them.
    func applyCalibreExtras(
        _ calibre: ImportReview.CalibreSource, to items: [ImportItem], outcomes: [ImportOutcome],
        with worker: LibraryWorker
    ) async throws {
        for (item, outcome) in zip(items, outcomes) {
            let bookId: Int64
            switch outcome {
            case .imported(let id, _), .needsAttention(let id): bookId = id
            case .failed: continue
            }
            for extras in calibre.extras(for: item.candidate) {
                try await worker.applyCalibreExtras(extras, toBook: bookId)
            }
        }
    }
}
