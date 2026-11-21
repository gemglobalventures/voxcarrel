import Foundation

extension LibraryService {
    /// The label of the operation that `undoLast` would reverse, or nil.
    public func undoLabel() throws -> String? {
        try store.lastBatch()?.label
    }

    /// Reverses the most recent import or edit. Returns its label.
    ///
    /// Works in this order: the tags inside the files are put back, the files are moved
    /// back, the database is restored in one transaction, and last the stored covers are
    /// put back and the undo data deleted.
    ///
    /// - Throws: `LibraryError.nothingToUndo` when there is nothing recorded;
    ///   `LibraryError.undoBlocked` when the files could not be put back, in which case the
    ///   database and the journal are unchanged and the call can simply be made again once
    ///   the obstacle is gone. If the database commit itself fails its error is thrown;
    ///   that too can be retried.
    @discardableResult
    public func undoLast() throws -> String {
        guard let batch = try store.lastBatch() else { throw LibraryError.nothingToUndo }  // U1

        var snapshot: OperationSnapshot?
        if let data = batch.snapshot {
            do {
                snapshot = try JSONDecoder().decode(OperationSnapshot.self, from: data)
            } catch {
                // Moving files back without restoring the database would leave the two
                // disagreeing; better to do nothing.
                throw LibraryError.undoBlocked("the saved undo information could not be read")
            }
        }

        // U3 (a): tags first, while the files are still where the snapshot says. A copy
        // the batch made is about to be deleted, and a file that is not there (already
        // moved back by an earlier attempt, or gone) is skipped. Failures are ignored.
        if let snapshot {
            let copies = Set(batch.moves.filter(\.wasCopy).map(\.to))
            for state in snapshot.books.flatMap(\.fileStates)
            where !copies.contains(state.pathAfter)
                && FileManager.default.fileExists(atPath: state.pathAfter) {
                try? restoreTags(state, token: snapshot.token)
            }
        }

        // U4 (b)
        do {
            try organiser.undo(batch.moves, pruneRoot: layout.root)
        } catch {
            throw LibraryError.undoBlocked(Self.describe(error))
        }

        // U5 (c)
        var change = LibraryChange()
        change.clearsJournal = true
        for book in snapshot?.books ?? [] {
            if let before = book.bookBefore {
                var write = LibraryChange.BookWrite(book: before, files: book.filesBefore)
                write.restoresFileIds = true
                change.writes.append(write)
            } else {
                change.deletedBookIds.append(book.bookId)
            }
        }
        try beforeCommit?()
        try store.apply(change)

        // U6 (d): the database is restored; what is left cannot fail the undo.
        if let snapshot {
            for book in snapshot.books {
                if book.bookBefore != nil, let name = book.storedCoverBefore {
                    // A saved image that has gone missing leaves the cover as it is.
                    if let image = undoImage(named: name, token: snapshot.token) {
                        try? covers.set(image, for: book.bookId)
                    }
                } else {
                    // The book had no stored cover, or did not exist.
                    try? covers.remove(for: book.bookId)
                }
            }
        }
        // The journal is empty, so no undo data is of use any more.
        discardUndoData(except: nil)
        try? FileManager.default.removeItem(at: layout.undoFolder)
        return batch.label
    }
}
