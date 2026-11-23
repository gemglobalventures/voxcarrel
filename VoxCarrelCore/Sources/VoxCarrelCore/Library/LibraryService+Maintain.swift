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
        try refuseWhileLayoutChangeIsInterrupted()
        // M1
        guard let target = try store.file(id: fileId), let bookId = target.bookId,
              let book = try store.book(id: bookId)
        else { throw LibraryError.fileNotFound(fileId) }
        let allowed: Set<FileRole> = target.format.defaultRole == .audio ? [.audio] : [.ebook, .extra]
        guard allowed.contains(role) else { throw LibraryError.invalidRole }
        guard role != target.role else { return }
        let pattern = try folderPattern()

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
        var folderPath = book.folderPath
        // FP41: a book that belongs in another book's folder is not moved there; it
        // stays where it is, its files as they are named, and is flagged.
        var folderTaken = false
        if book.folderPath != nil,
           let plan = filingPlan(for: sources, metadata: book.metadata, pattern: pattern) {
            var owners: FolderOwners?
            if !plan.moves.isEmpty, isAnotherBooksFolder(plan.folder, for: bookId, owners: &owners) {
                folderTaken = true
            } else {
                moves = plan.moves
                // As a save (E3): the folder the files are moved into is the book's folder.
                if !moves.isEmpty { folderPath = store.storedPath(for: plan.folder) }
            }
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
        updated.folderPath = folderPath
        if folderTaken { updated.needsAttention = true }
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
        try refuseWhileLayoutChangeIsInterrupted()
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
            updated.durationSeconds = Self.remeasuredDuration(files, recorded: book.durationSeconds)
            let newRows = bookFiles(files)

            // Recorded only when a file was really changed or the database would be.
            let changed = files.contains { $0.state != nil }
                || updated.appOnlyFields != book.appOnlyFields
                || updated.durationSeconds != book.durationSeconds
                || newRows.map(\.writeProblem) != rows.map(\.writeProblem)
                || newRows.map(\.lengthProblem) != rows.map(\.lengthProblem)
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
        try refuseWhileLayoutChangeIsInterrupted()
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
           snapshot.books.contains(where: { $0.bookId == bookId })
            || snapshot.layoutChange?.books.contains(where: { $0.bookId == bookId }) == true
            || snapshot.merge?.removed.contains(where: { $0.book.id == bookId }) == true {
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
    /// First of all a change of folder layout that was cut short is put right
    /// (`recoverInterruptedLayoutChange`): `recoveredLayoutChange` and
    /// `layoutChangeProblem` say what came of that. Then a merge of entries that was
    /// cut short is put right (`recoverInterruptedMerge`): `recoveredMerge` and
    /// `mergeProblem`.
    ///
    /// Looks only at names, sizes and whether files exist. No file is opened, except for
    /// what `checkLengths` does: the audio files of a book whose recorded length cannot
    /// be right for their size, or one of whose files is recorded as stating the wrong
    /// length, are read; and once in the life of a library, a few small reads are made
    /// of every MP3 to look at its length header. Records nothing in the journal, and
    /// changes no file other than deleting working copies left by an interrupted tag
    /// write, and the empty remains of the place where a change of folder layout sets
    /// folders aside. Symbolic links are not followed, and packages and hidden folders
    /// are not looked inside; but a book folder left set aside by an interrupted change
    /// of folder layout, or left under a half-moved name, is reported
    /// (`strandedFolders`) and never touched.
    public func reconcile() throws -> ReconcileReport {
        var report = ReconcileReport()
        let fm = FileManager.default

        // FP43: a change of folder layout that was cut short is put right before
        // anything is checked, so that what is checked is the library as it should be.
        let recovery = try recoverInterruptedLayoutChange()
        report.recoveredLayoutChange = recovery.foldersPutBack
        report.layoutChangeProblem = recovery.problem
        report.strandedFolders = recovery.unresolved
        // While that could not be done the folders are known not to be where the
        // catalogue says: checking them against it would only flag every book the
        // change had moved. The check waits until the library has been put right.
        if recovery.problem != nil { return report }
        // The same for a merge of entries that was cut short.
        let merge = try recoverInterruptedMerge()
        report.recoveredMerge = merge.filesPutBack
        report.mergeProblem = merge.problem
        report.mergeFilesOutOfPlace = merge.unresolved
        if merge.problem != nil { return report }

        // R1, R2
        let pattern = try folderPattern()
        let books = try store.books()
        let rowsByBook = Dictionary(grouping: try store.allFiles(), by: \.bookId)
        var tracked = Set<String>()
        var recovered: [Int64] = []
        var newlyFlagged: [Int64] = []
        var owners: FolderOwners?
        for book in books.sorted(by: { ($0.id ?? 0) < ($1.id ?? 0) }) {
            guard let id = book.id else { continue }
            let rows = rowsByBook[id] ?? []
            for row in rows { tracked.insert(Self.comparablePath(store.url(for: row))) }
            switch fileCheck(of: book, files: rows, pattern: pattern, owners: &owners) {
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

        // R7: lengths recorded from MP3 headers that state the wrong length. R8: once for
        // a library, and for a book whose files have come back, every MP3's header is
        // looked at. The library is only noted as looked over once every book has been,
        // so a check that was cut short is simply made again.
        let lookedOver = try store.note(Self.lengthHeadersNote) != nil
        for book in books {
            guard let id = book.id, !report.booksWithMissingFiles.contains(id) else { continue }
            let found = try checkLengths(
                of: book, files: rowsByBook[id] ?? [], lookingAtHeaders: !lookedOver || recovered.contains(id))
            if found.corrected { report.correctedLengths += 1 }
            report.filesWithWrongLength += found.newlyWrong
        }
        if !lookedOver { try store.setNote(Self.lengthHeadersNote, to: "1") }

        // Edition kinds recorded under an older rule, and parts once thought missing.
        try recheckEditions(books: try store.books(), files: rowsByBook)

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
                // A folder under a half-moved name is said, not passed over in silence.
                if Self.isStrandedMove(name) { report.strandedFolders.append(StrandedFolder(url: url)) }
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
        report.strandedFolders += foldersLeftSetAside()
        report.strandedFolders.sort { $0.url.path < $1.url.path }
        return report
    }

    /// Book folders left in the place where a change of folder layout sets folders
    /// aside for a moment (`LibraryLayout.movingFolder`): the change was interrupted
    /// there, or could not put them back. Each is reported with where it belongs, when
    /// the list kept beside it says. They are never moved or deleted here. What is left
    /// of an operation that has no folder set aside any more is cleared away.
    private func foldersLeftSetAside() -> [StrandedFolder] {
        let fm = FileManager.default
        var found: [StrandedFolder] = []
        let parking = layout.movingFolder
        for operation in ((try? fm.contentsOfDirectory(atPath: parking.path)) ?? []).sorted() {
            let folder = parking.appendingPathComponent(operation, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            let listURL = folder.appendingPathComponent(FolderMover.manifestName)
            let list = (try? Data(contentsOf: listURL))
                .flatMap { try? JSONDecoder().decode([FolderMover.ManifestEntry].self, from: $0) } ?? []
            let others = names.filter { $0 != FolderMover.manifestName }
            if others.isEmpty {
                // Only the list, and then only a folder that is empty, is removed.
                try? fm.removeItem(at: listURL)
                _ = rmdir(folder.path)
                continue
            }
            for name in others.sorted() {
                let entry = list.first { $0.parkedAs == name }
                found.append(
                    StrandedFolder(
                        url: folder.appendingPathComponent(name, isDirectory: true), belongsAt: entry?.folder,
                        wasMovingTo: entry?.movingTo))
            }
        }
        _ = rmdir(parking.path)
        return found
    }

    /// The note a library carries once the header of every MP3 in it has been looked at.
    static let lengthHeadersNote = "lengthHeadersChecked"

    /// What `checkLengths` did for one book.
    struct LengthCheck: Equatable {
        /// The book's recorded length was changed.
        var corrected = false
        /// Files that were not recorded as stating the wrong length, and now are.
        var newlyWrong = 0
    }

    /// R7 for one book: as `checkLengths` without looking at headers.
    /// - Returns: Whether the book's recorded length was changed.
    func correctLength(of book: Book, files rows: [BookFile]) throws -> Bool {
        try checkLengths(of: book, files: rows, lookingAtHeaders: false).corrected
    }

    /// R7 and R8 for one book that has MP3s. Its audio files are measured (read, and
    /// their frames counted where the header calls for it) when one of these holds:
    /// - the length recorded for the book cannot be right for the size of its audio files;
    /// - one of its files is recorded as stating the wrong length (the total may then
    ///   have been recorded before that was known);
    /// - `lookingAtHeaders`, and the length header of one of its MP3s is suspect:
    ///   implausible for the file's size, or at odds with the bitrate of the frames
    ///   sampled across the file (`MP3Length.needsScan`). This look costs a few small
    ///   reads a file and does not use the tag library.
    ///
    /// What is found wrong with each file's header is recorded, and the book's length is
    /// changed only when one of the files does state a wrong length: a length recorded
    /// by hand, or for files since replaced, is not this check's to change.
    ///
    /// The first two are judged from the database and file sizes alone, so a book with
    /// nothing wrong costs one `stat` a file. Not every file is opened when the book is
    /// measured: a file recorded as stating the wrong length counts for the length
    /// recorded as measured, unless the book's length is implausible; and a file that
    /// could not be measured before, and has not changed since, counts for the length
    /// it states. A book that is picked and has nothing wrong after all (a short file
    /// with a large picture in it) is read again at the next launch; no frames are
    /// counted for it. Nothing is recorded in the journal and the book is not flagged.
    func checkLengths(of book: Book, files rows: [BookFile], lookingAtHeaders: Bool) throws -> LengthCheck {
        let audio = rows.filter { $0.role == .audio }
        guard let id = book.id, audio.contains(where: { $0.format == .mp3 }) else { return LengthCheck() }
        var bytes: UInt64 = 0
        for row in audio {
            let size = try? FileManager.default.attributesOfItem(atPath: store.url(for: row).path)[.size] as? UInt64
            guard let size else { return LengthCheck() }
            bytes += size
        }
        let recorded = book.durationSeconds ?? 0
        let implausible = recorded > 0 && !MP3Length.isPlausible(seconds: recorded, audioBytes: bytes)
        let knownWrong = audio.contains { $0.lengthProblem != nil }
        guard implausible || knownWrong || (lookingAtHeaders && hasSuspectHeader(audio)) else { return LengthCheck() }

        // As when files are added (A5): a sum over some of the parts would be wrong.
        var total = 0.0
        var anyWrong = false
        var found = LengthCheck()
        var problems: [Int64: LengthProblem?] = [:]
        var unmeasured: [Int64: UnmeasuredLength?] = [:]
        for row in audio {
            let url = store.url(for: row)
            if !implausible, let problem = row.lengthProblem {
                total += problem.trueSeconds
                anyWrong = true
                continue
            }
            if let state = row.lengthUnmeasured, state.describes(fileAt: url) {
                total += state.statedSeconds
                continue
            }
            willMeasure?(url)
            guard let fileId = row.id, let contents = try? metadataIO.read(url),
                  let seconds = contents.metadata.durationSeconds
            else { return LengthCheck() }
            total += seconds
            if contents.lengthProblem != nil { anyWrong = true }
            if contents.lengthProblem != row.lengthProblem {
                problems[fileId] = contents.lengthProblem
                if row.lengthProblem == nil { found.newlyWrong += 1 }
            }
            let state = contents.lengthCouldNotBeMeasured
                ? UnmeasuredLength(fileAt: url, statedSeconds: seconds) : nil
            if state != row.lengthUnmeasured { unmeasured[fileId] = state }
        }
        found.corrected = anyWrong && abs(total - recorded) > 0.5
        guard found.corrected || !problems.isEmpty || !unmeasured.isEmpty else { return LengthCheck() }
        try store.setMeasuredLength(
            bookId: id, durationSeconds: found.corrected ? total : nil, lengthProblems: problems,
            unmeasured: unmeasured)
        return found
    }

    /// Whether the length header of one of these MP3s is suspect, from a few small reads
    /// of each. Files already known to state the wrong length, and files that could not
    /// be measured and have not changed, are not opened.
    private func hasSuspectHeader(_ audio: [BookFile]) -> Bool {
        audio.contains { row in
            guard row.format == .mp3, row.lengthProblem == nil else { return false }
            let url = store.url(for: row)
            if let state = row.lengthUnmeasured, state.describes(fileAt: url) { return false }
            let onRead = didReadHeader.map { seam in { (bytes: Int) in seam(url, bytes) } }
            guard let opening = try? MP3FrameScan.open(url, onRead: onRead) else { return false }
            return MP3Length.needsScan(statedSeconds: nil, opening: opening)
        }
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
    /// still be filed under the library's folder pattern; one that was never filed, or
    /// no longer can be, stays flagged.
    ///
    /// A book with no files (owned elsewhere) has none to miss and none to come back: it
    /// is never reported missing, flagged or recovered, and a flag it has stays.
    /// - Parameters:
    ///   - rows: The book's files, as recorded.
    ///   - pattern: The library's folder pattern, when the caller has it already. If it
    ///     has to be read here and cannot be, a flag is left as it is.
    ///   - owners: Which book has which folder, read when first needed: a caller that
    ///     checks many books passes the same one each time.
    func fileCheck(
        of book: Book, files rows: [BookFile], pattern: FolderPattern? = nil, owners: inout FolderOwners?
    ) -> FileCheck {
        guard !rows.isEmpty else { return .asItWas }
        let fm = FileManager.default
        if rows.contains(where: { !fm.fileExists(atPath: store.url(for: $0).path) }) {
            return .missing(newlyFlagged: !book.needsAttention)
        }
        if book.needsAttention, book.folderPath != nil, let pattern = pattern ?? (try? folderPattern()),
           let folder = bookFolder(
               for: book.metadata, hasAudio: rows.contains { $0.role == .audio }, pattern: pattern),
           // FP41: still flagged while the folder it belongs in is another book's.
           !isAnotherBooksFolder(folder, for: book.id, owners: &owners) {
            return .recovered
        }
        return .asItWas
    }

    func fileCheck(of book: Book, files rows: [BookFile], pattern: FolderPattern? = nil) -> FileCheck {
        var owners: FolderOwners?
        return fileCheck(of: book, files: rows, pattern: pattern, owners: &owners)
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
