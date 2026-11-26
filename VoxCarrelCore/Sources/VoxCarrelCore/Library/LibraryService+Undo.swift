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
        // The same goes for the files undo would write into, which an operation that
        // moved nothing (an edit of the tags, a repair of length headers) also names in full.
        if let snapshot, try !writesOnlyToThisLibrary(snapshot) { return .unusable(batch) }
        return .undoable(batch, snapshot)
    }

    /// Whether every file that undoing `snapshot` would write into (to put tags back, or
    /// a length header) belongs to this library: it is inside the library folder, or it
    /// is a file of the same book that this library records where it was found.
    private func writesOnlyToThisLibrary(_ snapshot: OperationSnapshot) throws -> Bool {
        for book in snapshot.books {
            let paths = book.fileStates.map(\.pathAfter) + book.headerRepairs.map(\.pathAfter)
            let outside = paths.filter { layout.relativeComponents(of: URL(fileURLWithPath: $0)) == nil }
            guard !outside.isEmpty else { continue }
            // Files left where they were found are recorded by their whole path.
            let known = Set(
                (try store.files(bookId: book.bookId) + book.filesBefore).filter { $0.path.hasPrefix("/") }
                    .map { Self.comparablePath(store.url(for: $0)) })
            guard outside.allSatisfy({ known.contains(Self.comparablePath(URL(fileURLWithPath: $0))) })
            else { return false }
        }
        return true
    }

    /// The label of the operation that `undoLast` would reverse, or nil.
    ///
    /// Inside `BookScope.visible` a label that names a book which is hidden now says
    /// "1 book" in place of its title: "Edit 1 book".
    public func undoLabel() throws -> String? {
        guard case .undoable(let batch, let snapshot) = try recordedOperation() else { return nil }
        guard BookScope.visibleOnly else { return batch.label }
        var label = batch.label
        for book in snapshot?.books ?? [] {
            guard let current = try store.book(id: book.bookId), current.isHidden else { continue }
            // The title it had when the operation was named, and the one it has now:
            // the longer first, since one may be the start of the other.
            let titles = [book.bookBefore?.title, current.title]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted { $0.count > $1.count }
            for name in titles {
                label = label.replacingOccurrences(of: name, with: "1 book")
            }
        }
        return label
    }

    /// Reverses the most recent import or edit. Returns its label. (A change of folder
    /// layout is reversed by `undoLayoutChange`, which see.)
    ///
    /// Works in this order: the files are moved back, all or nothing; the tags inside
    /// them are put back, and the length headers a repair rewrote; the database is
    /// restored in one transaction; the restored books' lengths are checked against
    /// their files (`checkLengths`); and last the stored covers are put back and the
    /// undo data deleted.
    ///
    /// A copy the operation made is deleted only while the original still exists;
    /// otherwise it is moved to where the original was. An original under a watch
    /// folder is no longer remembered as imported, in the same transaction as the rest:
    /// it arrives in the inbox again.
    ///
    /// A merge of entries is undone whole: the entries it removed come back under their
    /// own ids with their details, file rows, covers, collections and sent records, the
    /// kept book is exactly the entry it was (read status and external copies included),
    /// and every file whose tags the merge wrote is put back byte for byte.
    ///
    /// For every other operation,
    /// only what the operation changed is restored: a book's read status and dates, and
    /// its external copies (where else it is owned), stay as they are now, except that
    /// the Audible copies' item ID follows the ASIN back when undo changes it to another
    /// one (a book that goes back to having none leaves its copies their ID). A book
    /// with a file missing from disk stays (or becomes) flagged as needing attention.
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
        try refuseWhileLayoutChangeIsInterrupted()
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
            // A change of folder layout moved whole folders, and is undone its own way.
            if let data, let saved = data.layoutChange {
                return try undoLayoutChange(recorded, token: data.token, saved)
            }
            // A change to the list of genres touched no file, and is undone its own way.
            if let saved = data?.genreList {
                return try undoGenreListChange(recorded, saved)
            }
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

        // Length headers a repair rewrote are put back, each file only when that makes it
        // byte for byte what it was. Best effort, as for tags: a file that has changed
        // since, or cannot be written, stays repaired, and is recorded as it is.
        var stillRepaired = Set<String>()
        for repair in snapshot?.books.flatMap(\.headerRepairs) ?? [] {
            do {
                try headerRepair.restore(repair, at: URL(fileURLWithPath: repair.pathAfter))
            } catch {
                stillRepaired.insert(repair.pathAfter)
            }
        }

        // U5
        var change = LibraryChange()
        change.clearsJournal = true
        // A merge joined the entries' read status and where else they are owned: undoing
        // it puts those back with the rest, for the kept book as for the others.
        let merge = snapshot?.merge
        // Not part of undo either: whether a book is hidden. An entry a merge removed
        // comes back hidden when the book it was merged into is hidden now.
        var keptIsHidden = false
        for book in snapshot?.books ?? [] {
            if var before = book.bookBefore {
                if let current = try store.book(id: book.bookId) {
                    before.isHidden = current.isHidden
                    keptIsHidden = keptIsHidden || current.isHidden
                }
                // Not part of undo: where the reader is with the book.
                if merge == nil, let current = try store.book(id: book.bookId) {
                    before.readStatus = current.readStatus
                    before.dateStarted = current.dateStarted
                    before.dateFinished = current.dateFinished
                    // Nor where else the book is owned: it keeps the copies it has now.
                    // But a book that goes back to having no files must stay owned
                    // somewhere, so if it has since lost every copy it gets back the
                    // ones it had.
                    // (Copies a newer version recorded, which this one cannot read,
                    // are always the ones the book has now.)
                    let copiesBefore = before.externalCopies
                    before.storedCopies = current.storedCopies
                    if book.filesBefore.isEmpty && current.externalCopies.isEmpty {
                        before.externalCopies = copiesBefore
                    }
                    // The ASIN does go back, and the Audible copies' IDs with it; but a
                    // book that goes back to having no ASIN leaves its copies theirs.
                    if !(before.asin ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Self.keepAudibleIdInStep(&before, asinBefore: current.asin)
                    }
                }
                // A book with a file missing needs attention whatever it was before.
                if book.filesBefore.contains(where: {
                    !FileManager.default.fileExists(atPath: store.url(for: $0).path)
                }) {
                    before.needsAttention = true
                }
                let files = book.filesBefore.map { row -> BookFile in
                    var row = row
                    // It holds for the file as it was then, and is found again if need be.
                    row.lengthUnmeasured = nil
                    row.lengthMeasured = nil
                    if stillRepaired.contains(store.url(for: row).path) { row.lengthProblem = nil }
                    return row
                }
                var write = LibraryChange.BookWrite(book: before, files: files)
                write.restoresFileIds = true
                change.writes.append(write)
            } else {
                change.deletedBookIds.append(book.bookId)
            }
        }
        // The entries a merge removed come back under their own ids, with their file
        // rows, their collections and their sent records; and the kept book leaves the
        // collections the merge put it in.
        for removed in merge?.removed ?? [] {
            guard let id = removed.book.id else { continue }
            var book = removed.book
            if keptIsHidden { book.isHidden = true }
            if removed.files.contains(where: { !FileManager.default.fileExists(atPath: store.url(for: $0).path) }) {
                book.needsAttention = true
            }
            let files = removed.files.map { row -> BookFile in
                var row = row
                row.lengthUnmeasured = nil
                row.lengthMeasured = nil
                return row
            }
            change.restoredBooks.append(LibraryChange.BookWrite(book: book, files: files))
            change.sentRecordMoves.append(.init(recordIds: removed.sentRecordIds, toBookId: id))
            change.membershipsAdded += removed.collectionIds.map { .init(collectionId: $0, bookId: id) }
        }
        if let merge, let keptId = snapshot?.books.first?.bookId {
            change.membershipsRemoved = merge.collectionsJoined.map { .init(collectionId: $0, bookId: keptId) }
        }
        // The originals of an import by copy are not imported any more.
        let copied = batch.moves.filter(\.wasCopy).map { URL(fileURLWithPath: $0.from) }
        if !copied.isEmpty {
            let folders = try store.watchFolders()
            change.forgottenImports = copied.compactMap { url in
                Self.ledgerPlace(of: url, among: folders).map {
                    LibraryChange.ForgottenImport(folderId: $0.0.id, path: $0.1.path)
                }
            }
        }
        try beforeCommit?()
        try store.apply(change)

        // What has been learnt since about the length of the restored books' files, and
        // the correction made of a length a wrong header gave, must not go back with the
        // rest: the books are checked again as the launch check would, headers included.
        let restoredIds = (snapshot?.books ?? []).filter { $0.bookBefore != nil }.map(\.bookId)
            + (merge?.removed ?? []).compactMap(\.book.id)
        for bookId in restoredIds {
            guard let restored = try? store.book(id: bookId),
                  let rows = try? store.files(bookId: bookId),
                  rows.allSatisfy({ FileManager.default.fileExists(atPath: store.url(for: $0).path) })
            else { continue }
            _ = try? checkLengths(of: restored, files: rows, lookingAtHeaders: true)
        }

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
            for removed in snapshot.merge?.removed ?? [] {
                guard let id = removed.book.id else { continue }
                if let name = removed.storedCover, let image = undoImage(named: name, token: snapshot.token) {
                    try? covers.set(image, for: id)
                } else {
                    try? covers.remove(for: id)
                }
            }
        }
        forgetUndoData()
        refreshDetailsFiles(
            ofBooks: (snapshot?.books.map(\.bookId) ?? []) + (merge?.removed.compactMap(\.book.id) ?? []))
        return batch.label
    }

    /// Removes all undo data: the journal is empty, so none of it is of use any more.
    func forgetUndoData() {
        discardUndoData(except: nil)
        try? FileManager.default.removeItem(at: layout.undoFolder)
    }
}
