import Foundation

extension LibraryService {
    // MARK: Roles

    /// Changes what a file is to its book (e.g. extra to ebook) and re-files it. Undoable.
    ///
    /// - Throws: `LibraryError.fileNotFound` for an unknown file id; `LibraryError.invalidRole`
    ///   when the format cannot have the role (audio formats are always audio; ebook formats
    ///   are an ebook or an extra); the organiser's error when the file cannot be moved, in
    ///   which case nothing has changed.
    public func setRole(_ role: FileRole, forFile fileId: Int64) throws {
        // M1
        guard let target = try store.file(id: fileId), let bookId = target.bookId,
              let book = try store.book(id: bookId)
        else { throw LibraryError.fileNotFound(fileId) }
        let allowed: Set<FileRole> = target.format.defaultRole == .audio ? [.audio] : [.ebook, .extra]
        guard allowed.contains(role) else { throw LibraryError.invalidRole }
        guard role != target.role else { return }

        // M2: audio, then ebooks, then extras. Each group keeps its order, and the file
        // that changed joins the end of its new group.
        let rows = try store.files(bookId: bookId)
        var moved = target
        moved.role = role
        // A file that was filed as an extra before its name was recorded: the name it
        // has now is the one to give back if it becomes an extra again.
        if target.role == .extra, moved.originalName == nil {
            moved.originalName = store.url(for: target).lastPathComponent
        }
        let ordered = [FileRole.audio, .ebook, .extra].flatMap { wanted in
            rows.filter { $0.id != fileId && $0.role == wanted } + (wanted == role ? [moved] : [])
        }
        // Only the file that becomes an ebook is opened.
        var files = ordered.map { row in
            workingFile(
                at: store.url(for: row), format: row.format, role: row.role, existing: row,
                read: row.id == fileId && role != .extra)
        }
        guard let index = ordered.firstIndex(where: { $0.id == fileId }) else {
            throw LibraryError.fileNotFound(fileId)
        }
        if role == .extra {
            // An extra is never written, so it holds nothing and has no write to fail.
            files[index].holds = []
            files[index].writeProblem = nil
        }

        var operation = PendingOperation()
        let storedCoverBefore: String?
        do {
            storedCoverBefore = try saveStoredCoverForUndo(bookId: bookId, token: operation.token)
        } catch {
            removeUndoData(token: operation.token)
            throw error
        }

        // Re-filed as a save would (E3, E6); a book that is not filed stays where it is.
        // A file that becomes an extra again goes back under the name it first had there.
        var moves: [(index: Int, move: PlannedMove)] = []
        let sources = files.enumerated().map { offset, file in
            FilingSource(
                url: file.url, role: file.role,
                extraName: offset == index && role == .extra ? file.originalName : nil)
        }
        if book.folderPath != nil, let plan = filingPlan(for: sources, metadata: book.metadata) {
            moves = plan.moves
        }
        let records: [MoveRecord]
        do {
            records = try organiser.transfer(moves.map(\.move), mode: .move, pruneRoot: layout.root)
        } catch {
            removeUndoData(token: operation.token)
            throw error
        }
        for (index, move) in moves { files[index].url = move.to }

        if role != .extra {
            let parts = Self.partPositions(for: files.map(\.role))
            writeTags(
                book.metadata, cover: .keep, part: parts[index], to: &files[index],
                restorePart: parts[index], coverBefore: nil)
        }

        var updated = book
        updated.appOnlyFields = keepingCoverMembership(
            of: book, in: Self.appOnlyFields(files: files, hasStoredCover: false))
        operation.add(
            .init(book: updated, files: bookFiles(files)),
            snapshot: BookSnapshot(
                bookId: bookId, bookBefore: book, filesBefore: rows,
                fileStates: files.compactMap(\.state), storedCoverBefore: storedCoverBefore),
            storedCover: .keep, records: records)
        _ = try commit(operation, label: "Change file role")
    }

    /// E9 for a write that keeps the cover: `.cover` stays app-only exactly when it was.
    func keepingCoverMembership(of book: Book, in fields: [MetadataField]) -> [MetadataField] {
        var fields = fields.filter { $0 != .cover }
        if book.appOnlyFields.contains(.cover) { fields.append(.cover) }
        return fields
    }

    // MARK: Read status

    /// Marks books unread, in progress or finished. Not part of undo.
    public func setReadStatus(_ status: ReadStatus, for bookIds: [Int64], on date: Date = Date()) throws {
        try store.setReadStatus(status, for: bookIds, on: date)  // M3
    }

    // MARK: Rewriting tags

    /// Writes each book's metadata, as the database has it, into all its audio and ebook
    /// files again (covers are left alone). For files whose tags could not be written
    /// earlier, or that another program has changed. Nothing is moved. Undoable.
    ///
    /// The outcome for a book lists what is now in the app only and the files that still
    /// could not be written; an unknown id gives `.failed`. A book for which nothing was
    /// written and nothing changed is reported as saved without being recorded.
    public func rewriteTags(for bookIds: [Int64]) throws -> [SaveOutcome] {
        var operation = PendingOperation()
        var handled = Set<Int64>()

        enum Prepared {
            case failed(String)
            case done(appOnlyFields: [MetadataField], problems: [FileProblem])
        }
        let prepared = bookIds.map { bookId -> Prepared in
            guard handled.insert(bookId).inserted else {
                return .failed("That book is already being rewritten by this call")
            }
            let book: Book
            let rows: [BookFile]
            var files: [WorkingFile]
            let storedCoverBefore: String?
            do {
                guard let found = try store.book(id: bookId) else { throw LibraryError.bookNotFound(bookId) }
                book = found
                rows = try store.files(bookId: bookId)
                // A book with no files (owned elsewhere) has nothing to write and
                // nothing in the app only: it is as it should be.
                if rows.isEmpty { return .done(appOnlyFields: [], problems: []) }
                files = workingFiles(for: rows)
                storedCoverBefore = try saveStoredCoverForUndo(bookId: bookId, token: operation.token)
            } catch {
                handled.remove(bookId)
                return .failed(Self.reason(for: error))
            }

            let parts = Self.partPositions(for: files.map(\.role))
            for index in files.indices {
                writeTags(
                    book.metadata, cover: .keep, part: parts[index], to: &files[index],
                    restorePart: parts[index], coverBefore: nil)
            }
            var updated = book
            updated.appOnlyFields = keepingCoverMembership(
                of: book, in: Self.appOnlyFields(files: files, hasStoredCover: false))
            let newRows = bookFiles(files)

            // Recorded only when a file was really changed or the database would be.
            let changed = files.contains { $0.state != nil }
                || updated.appOnlyFields != book.appOnlyFields
                || newRows.map(\.writeProblem) != rows.map(\.writeProblem)
            if changed {
                operation.add(
                    .init(book: updated, files: newRows),
                    snapshot: BookSnapshot(
                        bookId: bookId, bookBefore: book, filesBefore: rows,
                        fileStates: files.compactMap(\.state), storedCoverBefore: storedCoverBefore),
                    storedCover: .keep, records: [])
            }
            return .done(appOnlyFields: updated.appOnlyFields, problems: Self.fileProblems(files))
        }

        let count = operation.writes.count
        if count > 0 {
            _ = try commit(operation, label: count == 1 ? "Rewrite tags" : "Rewrite tags for \(count) books")
        } else {
            removeUndoData(token: operation.token)
        }
        return zip(bookIds, prepared).map { bookId, result in
            switch result {
            case .failed(let reason):
                return .failed(bookId: bookId, reason: reason)
            case .done(let fields, let problems):
                return .saved(bookId: bookId, refiled: false, appOnlyFields: Set(fields), fileProblems: problems)
            }
        }
    }

    // MARK: Removing a book

    /// Removes a book from the library. Its files go to the Trash, or stay where they are.
    /// A book with no files (owned elsewhere) is simply removed, with its stored cover:
    /// there is nothing to send to the Trash, whatever `moveFilesToTrash` says.
    ///
    /// Not undoable through VoxCarrel: use the Finder's Put Back. If the last recorded
    /// operation involved this book, it can no longer be undone and is forgotten.
    ///
    /// - Throws: `LibraryError.bookNotFound` for an unknown id. If a file cannot be moved
    ///   to the Trash, that error: the book then stays in the database, and files already
    ///   in the Trash stay there.
    public func removeBook(id: Int64, moveFilesToTrash: Bool) throws {
        guard try store.book(id: id) != nil else { throw LibraryError.bookNotFound(id) }
        let urls = try store.files(bookId: id).map { store.url(for: $0) }

        if moveFilesToTrash {
            let fm = FileManager.default
            for url in urls where fm.fileExists(atPath: url.path) {
                try trashItem(url)  // M5: stops here, before the database is touched
            }
            for url in urls {
                removeEmptyFolders(from: url.deletingLastPathComponent())
            }
        }

        // M4: an undo that involves this book could no longer be honoured.
        var change = LibraryChange()
        change.deletedBookIds = [id]
        change.clearsJournal = try lastBatchInvolves(bookId: id, files: urls)
        try beforeCommit?()
        try store.apply(change)

        try? covers.remove(for: id)
        if change.clearsJournal { forgetUndoData() }
    }

    /// True when the recorded batch changed this book or moved one of its files. A batch
    /// whose undo data cannot be read says nothing about which books it changed (and can
    /// never be undone, see `undoLast`): only its moves are looked at.
    func lastBatchInvolves(bookId: Int64, files: [URL]) throws -> Bool {
        guard let batch = try store.lastBatch() else { return false }
        if let data = batch.snapshot, let snapshot = OperationSnapshot.usable(from: data),
           snapshot.books.contains(where: { $0.bookId == bookId }) {
            return true
        }
        let paths = Set(files.map { Self.comparablePath($0) })
        return batch.moves.contains { move in
            [move.from, move.to].contains { paths.contains(Self.comparablePath(URL(fileURLWithPath: $0))) }
        }
    }

    /// Removes `folder` if it is empty (ignoring .DS_Store), then its parents, stopping at
    /// the first folder that is not empty. Only folders strictly inside the library.
    private func removeEmptyFolders(from folder: URL) {
        let fm = FileManager.default
        let rootPrefix = layout.root.standardizedFileURL.path + "/"
        var current = folder.standardizedFileURL
        while current.path.hasPrefix(rootPrefix) {
            guard let contents = try? fm.contentsOfDirectory(atPath: current.path),
                  contents.allSatisfy({ $0 == ".DS_Store" }),
                  (try? fm.removeItem(at: current)) != nil
            else { return }
            current = current.deletingLastPathComponent()
        }
    }

    // MARK: The launch check

    /// Checks the library folder against the database. Run at launch.
    ///
    /// Looks only at names and whether files exist: no file is opened. Records nothing in
    /// the journal, and changes no file other than deleting working copies left by an
    /// interrupted tag write. Symbolic links are not followed, and packages and hidden
    /// folders are not looked inside.
    public func reconcile() throws -> ReconcileReport {
        var report = ReconcileReport()
        let fm = FileManager.default

        // R1, R2
        let books = try store.books()
        let rowsByBook = Dictionary(grouping: try store.allFiles(), by: \.bookId)
        var tracked = Set<String>()
        var recovered: [Int64] = []
        var newlyFlagged: [Int64] = []
        for book in books.sorted(by: { ($0.id ?? 0) < ($1.id ?? 0) }) {
            guard let id = book.id else { continue }
            let urls = (rowsByBook[id] ?? []).map { store.url(for: $0) }
            for url in urls { tracked.insert(Self.comparablePath(url)) }
            switch fileCheck(of: book, files: urls) {
            case .missing(let newly):
                report.booksWithMissingFiles.append(id)
                if newly { newlyFlagged.append(id) }
            case .recovered:
                recovered.append(id)
            case .asItWas:
                break
            }
        }
        report.booksRecovered = recovered
        if !newlyFlagged.isEmpty || !recovered.isEmpty {  // R6: otherwise nothing is written
            try store.setNeedsAttention(flagging: newlyFlagged, clearing: recovered)
        }

        // R3, R4: one pass over the folder, by name only.
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isRegularFileKey, .isHiddenKey]
        guard let walker = fm.enumerator(at: layout.root, includingPropertiesForKeys: keys, options: []) else {
            return report
        }
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let name = url.lastPathComponent
            let hidden = name.hasPrefix(".") || values.isHidden == true
            if values.isSymbolicLink == true {
                walker.skipDescendants()
                continue
            }
            if values.isDirectory == true {
                // As the scanner: hidden folders, packages and folders named like a book
                // file are not looked inside.
                if hidden || values.isPackage == true || FileFormat(url: url) != nil {
                    walker.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            if hidden {
                if Self.isStrandedMove(name) {
                    report.strandedFiles.append(url)
                } else if Self.isWorkingCopy(name), (try? fm.removeItem(at: url)) != nil {
                    report.removedWorkingCopies += 1
                }
            } else if FileFormat(url: url) != nil, !tracked.contains(Self.comparablePath(url)) {
                report.untrackedFiles.append(url)
            }
        }
        report.untrackedFiles.sort { $0.path < $1.path }
        report.strandedFiles.sort { $0.path < $1.path }
        return report
    }

    /// What the launch check finds for one book.
    enum FileCheck: Equatable {
        /// At least one file is missing. `newlyFlagged` when the book was not flagged yet.
        case missing(newlyFlagged: Bool)
        /// Every file is present and the book was flagged only because one was missing:
        /// the flag can be cleared.
        case recovered
        /// Every file is present, and the flag (set or not) stays as it is.
        case asItWas
    }

    /// R1, R2 for one book, by whether its files exist: none is opened.
    ///
    /// A flagged book counts as flagged only for missing files when it is filed and can
    /// still be filed; one that was never filed, or no longer can be, stays flagged.
    ///
    /// A book with no files (owned elsewhere) has none to miss and none to come back: it
    /// is never reported missing, flagged or recovered, and a flag it has stays.
    /// - Parameter urls: Where each of the book's files is recorded to be.
    func fileCheck(of book: Book, files urls: [URL]) -> FileCheck {
        guard !urls.isEmpty else { return .asItWas }
        let fm = FileManager.default
        if urls.contains(where: { !fm.fileExists(atPath: $0.path) }) {
            return .missing(newlyFlagged: !book.needsAttention)
        }
        if book.needsAttention, book.folderPath != nil,
           PathBuilder.bookFolder(metadata: book.metadata) != nil {
            return .recovered
        }
        return .asItWas
    }

    private static let uuidPattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"

    /// `.voxcarrel-<UUID>.<ext>`: the working copy of a tag write (`SafeFileUpdate`).
    static func isWorkingCopy(_ name: String) -> Bool {
        name.range(of: "^\\.voxcarrel-\(uuidPattern)\\.[A-Za-z0-9]+$", options: .regularExpression) != nil
    }

    /// `.voxcarrel-moving-<UUID>`: a real file parked mid-move by the organiser.
    static func isStrandedMove(_ name: String) -> Bool {
        name.range(of: "^\\.voxcarrel-moving-\(uuidPattern)$", options: .regularExpression) != nil
    }
}
