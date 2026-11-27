import Foundation

// A better copy of a book the library already has.
//
// When audio arrives for a book that has audio already, it can take that audio's
// place: a clearer recording, or one file in place of many. The book keeps its entry,
// so its highlights, series, tags and read status are as they were. The new audio is
// brought in first, as files added to the book; only then is the old audio taken out
// of the catalogue and sent to the Trash, and the book's files named afresh.
//
// Like joining a book's parts, this cannot be undone through VoxCarrel: the old audio
// is in the Trash, from where it can be put back by hand.

/// Why a book's audio is not replaced.
struct SwapRefusal: Error {
    var reason: String
}

extension LibraryService {
    /// How much shorter the new audio may be than the old before it is refused: a
    /// tenth. Shorter than that, it is very likely abridged, or not all there.
    static let swapShortfall = 0.9

    /// The audio a book has that the candidate's audio would replace, or why it will not.
    func audioToRetire(ofBook bookId: Int64, for candidate: CandidateBook) -> Result<[BookFile], SwapRefusal> {
        guard let book = try? store.book(id: bookId) else {
            return .failure(SwapRefusal(reason: "The book this is a better copy of is no longer in the library"))
        }
        guard candidate.files.contains(where: { $0.role == .audio }) else {
            return .failure(SwapRefusal(reason: "This copy has no audio to put in place of that book's"))
        }
        let old = ((try? store.files(bookId: bookId)) ?? []).filter { $0.role == .audio }
        guard !old.isEmpty, book.folderPath != nil, !book.keptOutside else {
            return .failure(SwapRefusal(reason: "\"\(book.title)\" has no audio filed in the library to replace"))
        }
        if let had = book.durationSeconds, had > 0, let new = candidate.metadata.durationSeconds, new > 0,
           new < had * Self.swapShortfall {
            return .failure(SwapRefusal(
                reason: "This copy is much shorter than the audio \"\(book.title)\" has, so it was not put in its place. "
                    + "It may be abridged, or not all of it"))
        }
        return .success(old)
    }

    /// Takes a book's old audio out of the catalogue and sends it to the Trash, then
    /// names the book's files afresh. The new audio is already the book's. Nothing is
    /// thrown: a file that will not go to the Trash stays in the folder, no longer the
    /// book's, and is found by the library's check.
    func retireAudio(_ old: [BookFile], ofBook bookId: Int64) {
        guard let book = try? store.book(id: bookId), let rows = try? store.files(bookId: bookId) else { return }
        // Files added to a book come after the files of their kind that it had: the
        // audio it had is the first so many of its audio files now, whatever they have
        // been renamed to beside the new ones.
        let audio = rows.filter { $0.role == .audio }.sorted { $0.position < $1.position }
        guard audio.count > old.count else { return }
        let retired = Array(audio.prefix(old.count))
        let retiredIds = Set(retired.compactMap(\.id))
        let oldURLs = retired.map { store.url(for: $0) }
        var kept: [BookFile] = []
        for var row in rows.sorted(by: { $0.position < $1.position }) where !(row.id.map(retiredIds.contains) ?? false) {
            row.position = kept.count
            kept.append(row)
        }
        let files = workingFiles(for: kept)
        var updated = book
        updated.durationSeconds = Self.totalDuration(files) ?? book.durationSeconds
        do {
            var change = LibraryChange()
            change.writes = [.init(book: updated, files: kept)]
            // The import that brought the new audio in can no longer be undone.
            change.cutsJournalThrough = try newestBatchInvolving(bookId: bookId, files: oldURLs)
            try store.apply(change)
            if change.cutsJournalThrough != nil { forgetUndoData() }
        } catch {
            return
        }
        for url in oldURLs where FileManager.default.fileExists(atPath: url.path) { try? trashItem(url) }
        // Named as the one audiobook they now are, not as parts beside what is gone.
        if let current = try? store.book(id: bookId) {
            forcedWrites = [bookId]
            defer { forcedWrites = [] }
            _ = try? save([BookEdit(book: current)]) { _, title in "Name the files of \(title)" }
        }
        refreshDetailsFiles(ofBooks: [bookId])
    }
}
