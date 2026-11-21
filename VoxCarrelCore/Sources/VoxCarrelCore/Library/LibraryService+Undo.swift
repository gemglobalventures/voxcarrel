import Foundation

extension LibraryService {
    /// What the journal holds, as far as undo is concerned.
    enum RecordedOperation {
        case none
        /// A batch that can be undone, with its undo data (nil for a batch recorded
        /// without any, by the older `recordBatch`).
        case undoable(OperationBatch, OperationSnapshot?)
        /// A batch that this code cannot undo: its undo data cannot be read or was
        /// written by a newer version, or its files are not in this library (the library
        /// folder was copied or moved since).
        case unusable(OperationBatch)
    }

    func recordedOperation() throws -> RecordedOperation {
        guard let batch = try store.lastBatch() else { return .none }
        var snapshot: OperationSnapshot?
        if let data = batch.snapshot {
            guard let usable = OperationSnapshot.usable(from: data) else { return .unusable(batch) }
            snapshot = usable
        }
        // Every transfer an operation makes ends inside the library. Paths are recorded
        // in full, so a batch whose destinations are elsewhere describes another folder,
        // and undoing it would move files there, not here.
        guard batch.moves.allSatisfy({ layout.relativeComponents(of: URL(fileURLWithPath: $0.to)) != nil })
        else { return .unusable(batch) }
        return .undoable(batch, snapshot)
    }

    /// The label of the operation that `undoLast` would reverse, or nil.
    public func undoLabel() throws -> String? {
        if case .undoable(let batch, _) = try recordedOperation() { return batch.label }
        return nil
    }

    /// Reverses the most recent import or edit. Returns its label.
    ///
    /// Works in this order: the files are moved back, all or nothing; the tags inside
    /// them are put back; the database is restored in one transaction; and last the
    /// stored covers are put back and the undo data deleted.
    ///
    /// A copy the operation made is deleted only while the original still exists;
    /// otherwise it is moved to where the original was.
    ///
    /// Only what the operation changed is restored: a book's read status and dates stay
    /// as they are now, and a book with a file missing from disk stays (or becomes)
    /// flagged as needing attention.
    ///
    /// - Throws: `LibraryError.nothingToUndo` when there is nothing recorded, or what is
    ///   recorded cannot be undone by this code (it is then forgotten);
    ///   `LibraryError.undoBlocked` when the files could not be put back, in which case
    ///   nothing at all has been changed (files, tags, database, journal) and the call can
    ///   simply be made again once the obstacle is gone. If the database commit itself
    ///   fails its error is thrown; the files are then already back, and the call can be
    ///   retried.
    @discardableResult
    public func undoLast() throws -> String {
        let batch: OperationBatch
        let snapshot: OperationSnapshot?
        switch try recordedOperation() {
        case .none:
            throw LibraryError.nothingToUndo  // U1
        case .unusable:
            var change = LibraryChange()
            change.clearsJournal = true
            try store.apply(change)
            forgetUndoData()
            throw LibraryError.nothingToUndo
        case .undoable(let recorded, let data):
            batch = recorded
            snapshot = data
        }

        // U3, U4: files back first, all or nothing, then their tags (best effort).
        do {
            try undoFiles(
                batch.moves, states: snapshot?.books.flatMap(\.fileStates) ?? [], token: snapshot?.token ?? "")
        } catch {
            throw LibraryError.undoBlocked(Self.describe(error))
        }

        // U5
        var change = LibraryChange()
        change.clearsJournal = true
        for book in snapshot?.books ?? [] {
            if var before = book.bookBefore {
                // Not part of undo: where the reader is with the book.
                if let current = try store.book(id: book.bookId) {
                    before.readStatus = current.readStatus
                    before.dateStarted = current.dateStarted
                    before.dateFinished = current.dateFinished
                }
                // A book with a file missing needs attention whatever it was before.
                if book.filesBefore.contains(where: {
                    !FileManager.default.fileExists(atPath: store.url(for: $0).path)
                }) {
                    before.needsAttention = true
                }
                var write = LibraryChange.BookWrite(book: before, files: book.filesBefore)
                write.restoresFileIds = true
                change.writes.append(write)
            } else {
                change.deletedBookIds.append(book.bookId)
            }
        }
        try beforeCommit?()
        try store.apply(change)

        // U6: the database is restored; what is left cannot fail the undo.
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
        forgetUndoData()
        return batch.label
    }

    /// Removes all undo data: the journal is empty, so none of it is of use any more.
    func forgetUndoData() {
        discardUndoData(except: nil)
        try? FileManager.default.removeItem(at: layout.undoFolder)
    }
}
