import Foundation

/// What a merge of entries is about to do to the files of a library: written inside the
/// library's hidden folder before the first file is moved or written into, and removed
/// once the catalogue has been written (or every file is back). One found when a
/// library is opened means the merge was cut short, by a crash or a loss of power, and
/// says how to put the library right.
struct MergeIntent: Codable, Equatable {
    static let currentVersion = 1
    static let fileName = "merge.json"

    var version = MergeIntent.currentVersion
    /// The undo token of the merge: the catalogue was written once the journal holds
    /// the operation it names. Its undo folder holds the files kept whole.
    var token: String
    /// The entry that is kept, and the entries the merge removes.
    var keptId: Int64
    var removedIds: [Int64] = []
    /// The removed entry whose stored cover the kept book takes; nil when it takes none.
    var coverFromId: Int64?
    var moves: [Move] = []
    var written: [Written] = []
    /// Folders the moves make that were not there before, relative to the library.
    var madeFolders: [String] = []

    /// One file the merge moves. Paths are relative to the library, or whole for a
    /// file outside it.
    struct Move: Codable, Equatable {
        var from: String
        var to: String
        /// What the file is, wherever it is: its file number, which a rename does not change.
        var identity: UInt64
        /// Whether the file may have another number by the time it is where it is
        /// going: its tags are written there, or it comes from another disk.
        var mayChange: Bool
    }

    /// One file whose tags the merge writes, kept whole beforehand.
    struct Written: Codable, Equatable {
        /// Where the file was before the merge, and where it is once the merge is made.
        var origin: String
        var path: String
        /// The kept file's name in the merge's undo folder.
        var original: String
        /// The file's own number before it was written.
        var identity: UInt64
        var before: FileStamp
        var keptFileNumber: UInt64?
    }
}

/// What was done about a merge of entries found interrupted.
public struct MergeRecovery: Equatable, Sendable {
    /// True when files were put back where, or as, they were before the interrupted merge.
    public var filesPutBack = false
    /// The files that stopped the library being put right, each where it is now (or
    /// where it was last expected). Empty when all is well.
    public var unresolved: [URL] = []
    /// Why the library could not be put right, as a sentence; nil when it was, or when
    /// there was nothing to put right. While this is set the record of the interrupted
    /// merge is kept, nothing more has been moved, nothing has been deleted, and
    /// operations are refused.
    public var problem: String?

    public init(filesPutBack: Bool = false, unresolved: [URL] = [], problem: String? = nil) {
        self.filesPutBack = filesPutBack
        self.unresolved = unresolved
        self.problem = problem
    }
}

/// A stage of a merge, for tests (`LibraryService.mergeCheckpoint`).
enum MergeCheckpoint: Equatable {
    /// What undo needs is saved; the record of the merge is not written yet.
    case originalsSaved
    /// The record is written; nothing has moved.
    case recorded
    /// Every file is where it is going; no tags have been written.
    case moved
    /// This many files have had their tags written.
    case tagsWritten(Int)
    /// The catalogue is written; nothing has been tidied up.
    case committed
}

extension LibraryService {
    /// Where the record of a merge in progress is kept.
    var mergeIntentURL: URL {
        layout.hiddenFolder.appendingPathComponent(MergeIntent.fileName)
    }

    /// True while the record of an interrupted merge is there: files may not be where
    /// the catalogue says, and every operation that changes the library is refused
    /// until `recoverInterruptedMerge` (or the launch check, which calls it) has put
    /// things right.
    public var hasInterruptedMerge: Bool {
        var info = stat()
        return lstat(mergeIntentURL.path, &info) == 0
    }

    // MARK: The record

    func writeMergeIntent(_ intent: MergeIntent) throws {
        try writeIntent(try JSONEncoder().encode(intent), named: MergeIntent.fileName)
    }

    func removeMergeIntent() {
        removeIntent(named: MergeIntent.fileName)
    }

    private func readMergeIntent() -> MergeIntent? {
        guard let data = try? Data(contentsOf: mergeIntentURL),
              let intent = try? JSONDecoder().decode(MergeIntent.self, from: data),
              intent.version <= MergeIntent.currentVersion
        else { return nil }
        return intent
    }

    /// A file's place as the record has it: relative to the library, or whole for a
    /// file outside it.
    private func recordPath(_ url: URL) -> String {
        layout.relativeComponents(of: url)?.joined(separator: "/") ?? url.path
    }

    private func recordURL(_ path: String) -> URL {
        path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : (path as NSString).pathComponents.reduce(layout.root) { $0.appendingPathComponent($1) }
    }

    /// The record of a merge that is about to make `moves` and write the tags of the
    /// files in `written` (each with where it is now, where it will be, and the file
    /// kept whole of it).
    func mergeIntent(
        token: String, keptId: Int64, removedIds: [Int64], coverFromId: Int64?, moves: [PlannedMove],
        written: [(origin: URL, destination: URL, original: SavedOriginal)]
    ) -> MergeIntent {
        var intent = MergeIntent(token: token, keptId: keptId)
        intent.removedIds = removedIds
        intent.coverFromId = coverFromId
        intent.written = written.map {
            MergeIntent.Written(
                origin: recordPath($0.origin), path: recordPath($0.destination), original: $0.original.fileName,
                identity: FileStamp.fileNumber(at: $0.origin) ?? 0, before: $0.original.before,
                keptFileNumber: $0.original.keptFileNumber)
        }
        let writtenOrigins = Set(written.map { $0.origin.standardizedFileURL.path })
        let pending = moves.filter { $0.from.standardizedFileURL != $0.to.standardizedFileURL }
        var made: [String] = []
        for move in pending {
            // The folders on the way to where the file goes that are not there yet.
            var folder = move.to.deletingLastPathComponent().standardizedFileURL
            var missing: [URL] = []
            while layout.relativeComponents(of: folder)?.isEmpty == false,
                  !FileManager.default.fileExists(atPath: folder.path) {
                missing.append(folder)
                folder = folder.deletingLastPathComponent()
            }
            // `folder` is now the nearest one that is there: the disk the file goes to.
            let otherDisk = FolderMover.volumeOf(move.from) != FolderMover.volumeOf(folder)
            intent.moves.append(
                MergeIntent.Move(
                    from: recordPath(move.from), to: recordPath(move.to),
                    identity: FileStamp.fileNumber(at: move.from) ?? 0,
                    mayChange: otherDisk || writtenOrigins.contains(move.from.standardizedFileURL.path)))
            for folder in missing.map(recordPath) where !made.contains(folder) { made.append(folder) }
        }
        intent.madeFolders = made
        return intent
    }

    // MARK: Putting files back

    /// Why the files an interrupted merge moved could not be put back.
    struct MergeRestoreFailure: Error {
        var reason: String
        var files: [URL]
    }

    /// Puts every file `intent` names back where, and as, it was before the merge,
    /// wherever the merge left it: where it was going, set aside under a temporary
    /// name on the way, or still (or already) in its place. The moves back are made
    /// all or nothing, by the same organiser as the merge itself, which never replaces
    /// anything; then each file whose tags were written is put back whole from the
    /// file kept of it; then folders the merge made that are empty are removed.
    ///
    /// A file is known by what it is where the disk can say (a file that was written,
    /// or came from another disk, by its being where it was going with nothing where it
    /// came from), so it does not matter how far the merge had got, or how far an
    /// earlier attempt to put it right had got: this can be interrupted and run again.
    ///
    /// - Returns: Whether anything had to be put back.
    /// - Throws: `MergeRestoreFailure` when a file is in none of those places, or
    ///   cannot be put back. Nothing is ever deleted or replaced by anything but the
    ///   file kept whole of it.
    func restoreMergedFiles(_ intent: MergeIntent) throws -> Bool {
        let fm = FileManager.default
        let written = Dictionary(intent.written.map { ($0.origin, $0) }) { first, _ in first }

        // Files set aside on the way (the organiser parks one that is in another's way).
        var parked: [UInt64: URL] = [:]
        for folder in Set(intent.moves.map { recordURL($0.to).deletingLastPathComponent() }) {
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where Self.isStrandedMove(name) {
                let url = folder.appendingPathComponent(name)
                if let number = FileStamp.fileNumber(at: url) { parked[number] = url }
            }
        }

        // A place a file of the merge was going to: whatever is there is expected to leave.
        let destinations = Set(intent.moves.map(\.to))
        var back: [PlannedMove] = []
        var lost: [URL] = []
        for move in intent.moves {
            let origin = recordURL(move.from), destination = recordURL(move.to)
            let atOrigin = FileStamp.fileNumber(at: origin), atDestination = FileStamp.fileNumber(at: destination)
            let kept = written[move.from]?.keptFileNumber
            func isIt(_ number: UInt64?) -> Bool {
                guard let number else { return false }
                return number == move.identity || number == kept
            }
            if isIt(atOrigin) { continue }
            if isIt(atDestination) {
                back.append(PlannedMove(from: destination, to: origin))
            } else if let aside = parked[move.identity] {
                back.append(PlannedMove(from: aside, to: origin))
            } else if move.mayChange, atDestination != nil, atOrigin == nil || destinations.contains(move.from) {
                back.append(PlannedMove(from: destination, to: origin))
            } else if move.mayChange, atOrigin != nil {
                continue
            } else {
                lost.append(destination)
            }
        }
        guard lost.isEmpty else {
            let names = lost.map { "\"\($0.lastPathComponent)\"" }.joined(separator: ", ")
            throw MergeRestoreFailure(
                reason: "A merge of books was interrupted, and a file it was moving cannot be found: " + names,
                files: lost)
        }
        do {
            try organiser.transfer(back, mode: .move, pruneRoot: layout.root)
        } catch {
            var files = back.map(\.from)
            if case OrganiserError.rollbackIncomplete(_, let outstanding) = error {
                files = outstanding.map { URL(fileURLWithPath: $0.to) }
            }
            throw MergeRestoreFailure(
                reason: "A merge of books was interrupted, and its files could not be put back: "
                    + Self.describe(error),
                files: files)
        }

        // Each written file, whole again. A file that is still the one it was, or is
        // already the kept one, is left alone; so is one whose kept file has gone.
        var restored = false
        for file in intent.written {
            let url = recordURL(file.origin)
            guard let now = FileStamp.fileNumber(at: url), now != file.identity, now != file.keptFileNumber
            else { continue }
            let kept = undoFolder(intent.token).appendingPathComponent(file.original)
            guard fm.fileExists(atPath: kept.path) else { continue }
            guard putKeptFile(kept, inPlaceOf: url, before: file.before) else {
                throw MergeRestoreFailure(
                    reason: "A merge of books was interrupted, and \"\(url.lastPathComponent)\" could not be put "
                        + "back as it was",
                    files: [url])
            }
            restored = true
        }

        // Folders the merge made, deepest first: only ever removed empty.
        for folder in intent.madeFolders.map(recordURL).sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            _ = rmdir(folder.path)
        }
        return restored || !back.isEmpty
    }

    // MARK: Putting an interrupted merge right

    /// Puts right a merge of entries that was cut short by a crash or a loss of power.
    /// To be called when a library is opened, before anything else is done with it; the
    /// launch check (`reconcile`) calls it. Does nothing when no merge was interrupted.
    ///
    /// When the catalogue had been written, only the tidying up was missed: the stored
    /// covers are brought up to date, and there is nothing to tell. Otherwise the
    /// catalogue is as it was before, and every file is put back where and as it was
    /// (`restoreMergedFiles`), so that the library and the catalogue agree again;
    /// `filesPutBack` then says so.
    ///
    /// If a file cannot be found, or cannot be put back, nothing is deleted, the record
    /// is kept, and `unresolved` and `problem` say what is wrong: the next call tries
    /// again, and until one succeeds every operation that changes the library throws
    /// `LibraryError.mergeInterrupted`.
    ///
    /// - Throws: Only when the catalogue cannot be read. Nothing has then been changed.
    @discardableResult
    public func recoverInterruptedMerge() throws -> MergeRecovery {
        guard hasInterruptedMerge else { return MergeRecovery() }
        guard let intent = readMergeIntent() else {
            return MergeRecovery(
                problem: "A merge of books was interrupted, and the record of it cannot be read "
                    + "(\(mergeIntentURL.path))")
        }
        struct Token: Decodable { var token: String }
        let journalToken = try store.lastBatch()?.snapshot
            .flatMap { try? JSONDecoder().decode(Token.self, from: $0) }?.token
        if journalToken == intent.token {
            // The catalogue was written: what was left is the stored covers.
            if let source = intent.coverFromId, covers.url(for: intent.keptId) == nil,
               let image = covers.image(for: source) {
                try? covers.set(image, for: intent.keptId)
            }
            for id in intent.removedIds where try store.book(id: id) == nil {
                try? covers.remove(for: id)
            }
            removeMergeIntent()
            return MergeRecovery()
        }
        do {
            let changed = try restoreMergedFiles(intent)
            removeUndoData(token: intent.token)
            removeMergeIntent()
            return MergeRecovery(filesPutBack: changed)
        } catch let failure as MergeRestoreFailure {
            return MergeRecovery(unresolved: failure.files, problem: failure.reason)
        }
    }

    /// Gives up on putting right a merge that was cut short: for when
    /// `recoverInterruptedMerge` cannot, and the owner would sooner sort the files out
    /// by hand than leave the library refusing every change.
    ///
    /// Removes the record of the interrupted merge. No file is touched, wherever it
    /// is, nothing is deleted, and the catalogue is left exactly as it is. The launch
    /// check (`reconcile`) then runs as usual, and reports the books whose files are
    /// not where the catalogue has them and the files that belong to no book.
    ///
    /// Does nothing when no merge is recorded as interrupted.
    /// - Throws: `LibraryError.mergeInterrupted` when the record could not be removed.
    public func discardInterruptedMerge() throws {
        guard hasInterruptedMerge else { return }
        removeMergeIntent()
        if hasInterruptedMerge { throw LibraryError.mergeInterrupted }
    }
}
