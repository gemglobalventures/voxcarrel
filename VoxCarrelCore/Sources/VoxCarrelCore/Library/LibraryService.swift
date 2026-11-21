import Foundation

/// Performs every library operation end to end, keeping the files, the tags inside them
/// and the database consistent with one another.
///
/// Every operation follows one sequence: plan, snapshot, move files, write tags, then
/// commit the database and the undo record in a single transaction. If the commit fails,
/// the file moves are reversed, book by book; if some file cannot be put back the
/// caller is told which (`LibraryError.rollbackIncomplete`).
///
/// Calls block while they work (moving and re-tagging large files takes seconds); run them
/// off the main thread, one at a time.
public final class LibraryService {
    public let store: LibraryStore
    public let layout: LibraryLayout
    public let covers: CoverStore

    let metadataIO: FileMetadataIO
    let organiser: Organiser

    /// Test seam: called immediately before every `store.apply`. Throwing from it stands
    /// in for a failed commit.
    var beforeCommit: (() throws -> Void)?

    /// Test seam: how `removeBook` sends one file to the Trash.
    var trashItem: (URL) throws -> Void = { _ = try LibraryService.moveToSystemTrash($0) }

    /// Moves a file to the user's Trash; returns where it now is, when the system says.
    @discardableResult
    static func moveToSystemTrash(_ url: URL) throws -> URL? {
        var landed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
        return landed as URL?
    }

    public convenience init(store: LibraryStore) {
        self.init(store: store, metadataIO: FileMetadataIO(), organiser: Organiser())
    }

    /// For tests: inject collaborators.
    init(store: LibraryStore, metadataIO: FileMetadataIO, organiser: Organiser) {
        self.store = store
        self.layout = LibraryLayout(root: store.libraryRoot)
        self.covers = CoverStore(layout: layout)
        self.metadataIO = metadataIO
        self.organiser = organiser
    }

    /// Scans dropped files and folders using the real tags inside them.
    public func scan(_ urls: [URL]) -> ScanResult {
        BookScanner(reader: metadataIO).scan(urls)
    }

    /// The library book a candidate most likely belongs to: same title and first
    /// author, ignoring case and surrounding spaces. Nil when either is missing.
    ///
    /// Of several matches the earliest added is returned. Books flagged as needing
    /// attention are never matched.
    public func existingMatch(for candidate: CandidateBook) throws -> Book? {
        func key(_ text: String?) -> String {
            (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let title = key(candidate.metadata.title)
        let author = key(candidate.metadata.authors.first)
        guard !title.isEmpty, !author.isEmpty else { return nil }
        return try store.books(needsAttention: false)
            .filter { key($0.title) == title && key($0.authors.first) == author }
            .min { ($0.dateAdded, $0.id ?? .max) < ($1.dateAdded, $1.id ?? .max) }
    }

    // MARK: Files of a book during an operation

    /// One file of a book while an operation works on it.
    struct WorkingFile {
        /// Where the file is now; updated once it has been transferred.
        var url: URL
        var format: FileFormat
        var role: FileRole
        /// The file's row before the operation; nil for a file the operation brings in.
        var existing: BookFile?
        /// What the file held when the operation read it, before changing anything.
        /// Nil for extras (never opened) and for files that could not be read.
        var before: FileContents?
        /// An audio file's own track title and number, read together with `before`.
        var trackBefore: TrackTags?
        /// Why the last attempt to write the file's tags failed, or nil.
        var writeProblem: String?
        /// The text fields held inside the file once the operation is done.
        var holds: Set<MetadataField> = []
        /// Whether the file has a cover inside it once the operation is done.
        var holdsCover = false
        /// What undo must write back; set when this operation changed the file's tags.
        var state: FileState?
        /// True when this operation tried to write the file's tags.
        var wasWritten = false
        /// The name the file had when it was first filed as an extra (`BookFile.originalName`).
        var originalName: String?
    }

    /// A working file for something on disk, read once unless it is an extra.
    /// - Parameters:
    ///   - existing: The file's row, when it already belongs to a library book.
    ///   - read: Pass false when the operation will not write the file's tags; the file
    ///     is then not opened at all.
    func workingFile(
        at url: URL, format: FileFormat, role: FileRole, existing: BookFile? = nil, read: Bool = true
    ) -> WorkingFile {
        let before = role == .extra || !read ? nil : try? metadataIO.read(url)
        var file = WorkingFile(url: url, format: format, role: role, existing: existing, before: before)
        if before != nil { file.trackBefore = try? metadataIO.readTrackTags(at: url) }
        file.writeProblem = existing?.writeProblem
        file.originalName = existing?.originalName ?? (role == .extra ? url.lastPathComponent : nil)
        file.holdsCover = before?.cover != nil
        // Until it is written, a file is taken to hold what its format can, unless the
        // last write to it failed.
        if role != .extra, existing != nil, existing?.writeProblem == nil {
            file.holds = FileMetadataIO.storableFields(for: format).subtracting([.cover])
        }
        return file
    }

    /// Working files for a library book's rows, at their real current locations.
    func workingFiles(for rows: [BookFile], read: Bool = true) -> [WorkingFile] {
        rows.map {
            workingFile(at: store.url(for: $0), format: $0.format, role: $0.role, existing: $0, read: read)
        }
    }

    /// The position of each file among the book's audio parts: 1-based, in file order,
    /// and nil for everything when the book has at most one audio file.
    static func partPositions(for roles: [FileRole]) -> [PartPosition?] {
        let count = roles.filter { $0 == .audio }.count
        guard count > 1 else { return roles.map { _ in nil } }
        var index = 0
        return roles.map { role in
            guard role == .audio else { return nil }
            index += 1
            return PartPosition(index: index, count: count)
        }
    }

    /// Writes `metadata` into one audio or ebook file where it now is, and records the
    /// outcome on `file`: what it holds, the problem if the write failed, and the state
    /// undo needs. Extras are left alone. Never throws: a failed write does not fail the
    /// operation.
    ///
    /// - Parameters:
    ///   - part: The file's place among the audio parts now.
    ///   - restorePart: The part to give when undo writes the old tags back (see `FileState.part`).
    ///   - coverBefore: The file's cover before, already saved for undo; needed whenever
    ///     `cover` is not `.keep`.
    func writeTags(
        _ metadata: BookMetadata, cover: CoverChange, part: PartPosition?,
        to file: inout WorkingFile, restorePart: PartPosition?, coverBefore: CoverBefore?
    ) {
        guard file.role != .extra else { return }
        file.wasWritten = true
        do {
            let report = try metadataIO.write(metadata, cover: cover, part: part, to: file.url)
            file.writeProblem = nil
            file.holds = Set(MetadataField.allCases).subtracting(report.notWritten).subtracting([.cover])
            let coverChanged = cover != .keep && !report.notWritten.contains(.cover)
            switch cover {
            case .keep: break
            // A file that could not take the new cover does not hold it, whatever it has.
            case .set: file.holdsCover = coverChanged
            case .remove: if coverChanged { file.holdsCover = false }
            }
            // A format that is never opened has nothing in it to put back.
            if let before = file.before, !FileMetadataIO.storableFields(for: file.format).isEmpty {
                file.state = FileState(
                    pathAfter: file.url.path, metadataBefore: before.metadata, part: restorePart,
                    trackBefore: file.trackBefore, coverBefore: coverChanged ? coverBefore : nil)
            }
        } catch {
            file.writeProblem = Self.describe(error)
            file.holds = []
            if case .set = cover { file.holdsCover = false }
        }
    }

    /// The fields that live in the database only: those no file of the book holds.
    /// `.cover` is listed when the book has a stored cover and no file has one inside.
    /// In the order of `MetadataField.allCases`.
    static func appOnlyFields(files: [WorkingFile], hasStoredCover: Bool) -> [MetadataField] {
        let held = files.filter { $0.role != .extra }
        return MetadataField.allCases.filter { field in
            if field == .cover {
                return hasStoredCover && !held.contains { $0.holdsCover }
            }
            return !held.contains { $0.holds.contains(field) }
        }
    }

    /// The database rows for a book's files, in the given order. A file that has not
    /// moved keeps its stored path exactly as it was.
    func bookFiles(_ files: [WorkingFile]) -> [BookFile] {
        files.enumerated().map { index, file in
            let unmoved = file.existing.flatMap { store.url(for: $0) == file.url ? $0.path : nil }
            var row = BookFile(
                path: unmoved ?? store.storedPath(for: file.url), format: file.format, role: file.role,
                position: index)
            row.writeProblem = file.writeProblem
            row.originalName = file.originalName
            return row
        }
    }

    /// The sum of the audio files' durations as read, or nil when none could be read.
    static func totalDuration(_ files: [WorkingFile]) -> Double? {
        let durations = files.filter { $0.role == .audio }.compactMap { $0.before?.metadata.durationSeconds }
        return durations.isEmpty ? nil : durations.reduce(0, +)
    }

    /// The first cover found in the files as read: audio files first, then ebooks.
    static func firstCover(in files: [WorkingFile]) -> CoverImage? {
        (files.filter { $0.role == .audio } + files.filter { $0.role == .ebook })
            .lazy.compactMap { $0.before?.cover }.first
    }

    /// The problems to report for the files this operation tried to write.
    static func fileProblems(_ files: [WorkingFile]) -> [FileProblem] {
        files.filter(\.wasWritten).compactMap { file in
            file.writeProblem.map { FileProblem(file: file.url.lastPathComponent, reason: $0) }
        }
    }

    // MARK: Undo data on disk

    func undoFolder(_ token: String) -> URL {
        layout.undoFolder.appendingPathComponent(token, isDirectory: true)
    }

    /// Saves an image among the operation's undo data; returns its file name there.
    func saveUndoImage(_ image: CoverImage, token: String) throws -> String {
        let folder = undoFolder(token)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).img"
        try image.data.write(to: folder.appendingPathComponent(name), options: .atomic)
        return name
    }

    /// An image saved with `saveUndoImage`, or nil when it is gone.
    func undoImage(named name: String, token: String) -> CoverImage? {
        (try? Data(contentsOf: undoFolder(token).appendingPathComponent(name))).map(CoverImage.stored)
    }

    /// What to remember about a file's own cover before a write that will change it.
    /// Nil when the cover is being kept or the file could not be read.
    func coverBefore(of file: WorkingFile, change: CoverChange, token: String) throws -> CoverBefore? {
        guard change != .keep, file.role != .extra, let before = file.before else { return nil }
        guard let cover = before.cover else { return CoverBefore.none }
        return .saved(fileName: try saveUndoImage(cover, token: token))
    }

    /// Saves a book's stored cover among the undo data; nil when it has none.
    func saveStoredCoverForUndo(bookId: Int64, token: String) throws -> String? {
        guard let image = covers.image(for: bookId) else { return nil }
        return try saveUndoImage(image, token: token)
    }

    /// Removes one operation's undo data, and the undo folder itself once it is empty.
    func removeUndoData(token: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: undoFolder(token))
        if let left = try? fm.contentsOfDirectory(atPath: layout.undoFolder.path), left.isEmpty {
            try? fm.removeItem(at: layout.undoFolder)
        }
    }

    /// Removes the undo data of every operation but the one named.
    func discardUndoData(except token: String?) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: layout.undoFolder.path) else { return }
        for name in names where name != token {
            try? fm.removeItem(at: layout.undoFolder.appendingPathComponent(name))
        }
    }

    /// Writes a file's earlier tags (and cover, if the operation changed it) back into it.
    /// An audio file's own track title and number are put back exactly as they were.
    /// - Parameter path: Where the file is now.
    func restoreTags(_ state: FileState, at path: String, token: String) throws {
        let cover: CoverChange
        switch state.coverBefore {
        case nil: cover = .keep
        case .some(.none): cover = .remove
        case .some(.saved(let name)):
            // A saved image that has gone missing leaves the file's cover as it is.
            cover = undoImage(named: name, token: token).map { .set($0) } ?? .keep
        }
        try metadataIO.write(
            state.metadataBefore, cover: cover, part: state.part, restoringTrack: state.trackBefore,
            to: URL(fileURLWithPath: path))
    }

    /// Reverses one set of transfers and then puts the earlier tags back into the files,
    /// each where it then is.
    ///
    /// The transfers are reversed first, all or nothing (`Organiser.undo`): if that
    /// throws, nothing has been changed and no tag is touched. Restoring tags afterwards
    /// is best effort: a failure there is ignored. A copy that is deleted is skipped; a
    /// copy that takes the place of an original that has gone gets the original's tags back.
    /// Safe to repeat.
    func undoFiles(_ records: [MoveRecord], states: [FileState], token: String) throws {
        let fm = FileManager.default
        // Where a file at a record's destination is once the record is undone.
        var movedBack: [String: String] = [:]
        // Copies that are deleted (or already were), so have nothing to restore.
        var deleted = Set<String>()
        for record in records {
            if !record.wasCopy {
                movedBack[record.to] = record.from
            } else if fm.fileExists(atPath: record.to), !fm.fileExists(atPath: record.from) {
                movedBack[record.to] = record.from
            } else {
                deleted.insert(record.to)
            }
        }
        try organiser.undo(records, pruneRoot: layout.root)
        for state in states where !deleted.contains(state.pathAfter) {
            let path = movedBack[state.pathAfter] ?? state.pathAfter
            guard fm.fileExists(atPath: path) else { continue }
            try? restoreTags(state, at: path, token: token)
        }
    }

    // MARK: Committing

    /// Everything one operation has done on disk and wants written to the database.
    struct PendingOperation {
        /// Names this operation's undo data folder.
        var token = UUID().uuidString
        var writes: [LibraryChange.BookWrite] = []
        /// One per write, in the same order. `bookId` is filled in at commit for new books.
        var snapshots: [BookSnapshot] = []
        /// One per write: what to do with the book's stored cover once it is committed.
        var storedCovers: [CoverChange] = []
        var deletedBookIds: [Int64] = []
        /// One per write: the transfers completed for that book, in the order made.
        var itemRecords: [[MoveRecord]] = []
        /// Every completed transfer, in the order made.
        var records: [MoveRecord] { itemRecords.flatMap { $0 } }

        mutating func add(
            _ write: LibraryChange.BookWrite, snapshot: BookSnapshot, storedCover: CoverChange,
            records: [MoveRecord]
        ) {
            writes.append(write)
            snapshots.append(snapshot)
            storedCovers.append(storedCover)
            itemRecords.append(records)
        }
    }

    /// Commits an operation: the database rows and one journal batch carrying the moves
    /// and the snapshot, in a single `store.apply`. Then the stored covers are brought up
    /// to date and older undo data is discarded.
    ///
    /// If the commit throws, the operation is rolled back (`rollBack`) and the error
    /// rethrown; or, when some file could not be put back, `LibraryError.rollbackIncomplete`
    /// is thrown instead, naming those files.
    /// - Returns: The written books, with ids, in the order of `operation.writes`.
    func commit(_ operation: PendingOperation, label: String) throws -> [Book] {
        var change = LibraryChange()
        change.writes = operation.writes
        change.deletedBookIds = operation.deletedBookIds
        change.batch = .init(label: label, moves: operation.records, snapshot: nil)

        let books: [Book]
        do {
            try beforeCommit?()
            books = try store.apply(change) { written in
                var snapshot = OperationSnapshot(token: operation.token, books: operation.snapshots)
                for (index, book) in written.enumerated() {
                    if let id = book.id { snapshot.books[index].bookId = id }
                }
                return try JSONEncoder().encode(snapshot)
            }.books
        } catch {
            let stranded = rollBack(operation)
            guard stranded.isEmpty else {
                throw LibraryError.rollbackIncomplete(cause: Self.describe(error), stranded: stranded)
            }
            throw error
        }

        // The database is committed; what follows cannot fail the operation.
        for (book, cover) in zip(books, operation.storedCovers) {
            guard let id = book.id else { continue }
            switch cover {
            case .keep:
                break
            case .remove:
                try? covers.remove(for: id)
            case .set(let image):
                do {
                    try covers.set(image, for: id)
                } catch {
                    // Without a stored cover there is nothing "in the app only".
                    var corrected = book
                    corrected.appOnlyFields.removeAll { $0 == .cover }
                    try? store.update(corrected)
                }
            }
        }
        discardUndoData(except: operation.token)
        return books
    }

    /// Puts the disk back as it was before an operation that could not be committed:
    /// book by book, newest first, the transfers are reversed and the earlier tags written
    /// back on a best-effort basis; then the operation's undo data is removed. The cover
    /// store has not been touched yet.
    ///
    /// A book whose files cannot be put back does not stop the others.
    /// - Returns: The files that could not be put back, each as
    ///   "<where it is> (from <where it was>)"; empty when everything is as it was.
    func rollBack(_ operation: PendingOperation) -> [String] {
        let fm = FileManager.default
        var stranded: [String] = []
        for index in operation.writes.indices.reversed() {
            let records = operation.itemRecords[index]
            let states = operation.snapshots[index].fileStates
            do {
                try undoFiles(records, states: states, token: operation.token)
            } catch {
                // The book's files stay where the operation put them, but get their
                // earlier tags back all the same (a copy has an untouched original).
                let copies = Set(records.filter(\.wasCopy).map(\.to))
                for state in states
                where !copies.contains(state.pathAfter) && fm.fileExists(atPath: state.pathAfter) {
                    try? restoreTags(state, at: state.pathAfter, token: operation.token)
                }
                stranded += records.filter { fm.fileExists(atPath: $0.to) }.map { "\($0.to) (from \($0.from))" }
            }
        }
        removeUndoData(token: operation.token)
        return stranded
    }

    // MARK: Messages

    /// A sentence a person can read for an error from the units the service drives.
    static func describe(_ error: Error) -> String {
        func name(_ path: String) -> String { "\"\((path as NSString).lastPathComponent)\"" }
        switch error {
        case let error as OrganiserError:
            switch error {
            case .destinationExists(let path):
                return "A file named \(name(path)) already exists at the destination (\(path))"
            case .sourceMissing(let path):
                return "The file \(name(path)) could not be found (\(path))"
            case .notARegularFile(let path):
                return "\(name(path)) is not a plain file (\(path))"
            case .cannotBeChanged(let path):
                return "\(name(path)) is locked, or its folder cannot be changed (\(path))"
            case .rollbackIncomplete(let cause, let outstanding):
                let left = outstanding.map { "\(name($0.from)) is now at \($0.to)" }.joined(separator: "; ")
                return "The files could not be moved (\(cause)), and some could not be put back: \(left)"
            }
        case let error as MetadataIOError:
            switch error {
            case .unsupportedFormat(let ext):
                return "Files of type \"\(ext)\" are not supported"
            case .unreadable(let file):
                return "\(name(file)) could not be read: it may be damaged or not what its name says"
            case .locked(let file):
                return "\(name(file)) is locked, read-only or protected, so it could not be changed"
            case .notARegularFile(let file):
                return "\(name(file)) is not a plain file"
            case .verificationFailed(let reason):
                return "The changed file did not pass its checks (\(reason)), so the original was kept"
            case .cleanupFailed(let path):
                return "The file was left unchanged, but a working copy could not be removed (\(path))"
            }
        case let error as LibraryError:
            switch error {
            case .bookNotFound: return "That book is not in the library"
            case .fileNotFound: return "That file is not in the library"
            case .invalidRole: return "A file of that type cannot have that role"
            case .nothingToUndo: return "There is nothing to undo"
            case .undoBlocked(let reason): return "Undo could not put the files back: \(reason)"
            case .rollbackIncomplete(let cause, let stranded):
                return "The change could not be saved (\(cause)), and some files could not be put back: "
                    + stranded.joined(separator: "; ")
            }
        default:
            return error.localizedDescription
        }
    }
}
