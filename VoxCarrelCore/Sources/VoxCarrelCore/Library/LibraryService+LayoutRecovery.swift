import Foundation

/// What a change of folder layout, or the undoing of one, is about to do to the folders
/// of a library: written inside the library's hidden folder before the first folder is
/// renamed and removed once the catalogue has been written (or every folder is back).
/// One found when a library is opened means the work was cut short, by a crash or a
/// loss of power, and says how to put the library right.
struct LayoutIntent: Codable, Equatable {
    static let currentVersion = 1
    static let fileName = "layout-change.json"

    var version = LayoutIntent.currentVersion
    /// The undo token of the operation: of the change being made, or of the change
    /// being undone.
    var token: String
    /// How to tell that the catalogue was written. True for a change: it is written
    /// once the journal holds the operation named by `token`. False for undoing one:
    /// it is written once the journal no longer holds it.
    var committedWhenJournalHolds: Bool
    /// The pattern as the catalogue stored it before, and as the work stores it.
    var patternTextBefore: String?
    var patternTextAfter: String?
    var moves: [Move] = []
    /// Folders the moves make on the way to a destination that were not there before
    /// (or were themselves folders being moved), relative to the library.
    var madeFolders: [String] = []

    struct Move: Codable, Equatable {
        /// Where the folder was, and where it is being moved, relative to the library.
        var from: String
        var to: String
        /// Where it is set aside on the way, when it is, relative to the library.
        var parkedAt: String?
        /// What the folder is, whatever it is called at the moment: its file number,
        /// which a rename does not change.
        var identity: UInt64
    }
}

/// What was done about a change of folder layout found interrupted.
public struct LayoutRecovery: Equatable, Sendable {
    /// True when folders were put back where they were before the interrupted change.
    public var foldersPutBack = false
    /// The folders that stopped the library being put right: one that is in none of
    /// the places the change could have left it (`url` is where it was last expected),
    /// or one whose way back is barred (`url` is where it is). Empty when all is well.
    public var unresolved: [StrandedFolder] = []
    /// Why the library could not be put right, as a sentence; nil when it was, or when
    /// there was nothing to put right. While this is set the record of the interrupted
    /// change is kept, nothing has been moved or deleted, and operations are refused.
    public var problem: String?

    public init(foldersPutBack: Bool = false, unresolved: [StrandedFolder] = [], problem: String? = nil) {
        self.foldersPutBack = foldersPutBack
        self.unresolved = unresolved
        self.problem = problem
    }
}

extension LibraryService {
    /// Where the record of a change of folder layout in progress is kept.
    var layoutIntentURL: URL {
        layout.hiddenFolder.appendingPathComponent(LayoutIntent.fileName)
    }

    /// True while the record of an interrupted change of folder layout is there: the
    /// folders of the library may not be where the catalogue says, and every operation
    /// that changes the library is refused until `recoverInterruptedLayoutChange` (or
    /// the launch check, which calls it) has put things right.
    public var hasInterruptedLayoutChange: Bool {
        var info = stat()
        return lstat(layoutIntentURL.path, &info) == 0
    }

    /// Throws `LibraryError.layoutChangeInterrupted` while a change of folder layout
    /// that was cut short has not been put right.
    func refuseWhileLayoutChangeIsInterrupted() throws {
        if hasInterruptedLayoutChange { throw LibraryError.layoutChangeInterrupted }
    }

    // MARK: The record

    /// Writes the record so that it is either wholly there or not there at all, and is
    /// on the disk before this returns: under another name first, forced out, then
    /// renamed into place.
    func writeLayoutIntent(_ intent: LayoutIntent) throws {
        let fm = FileManager.default
        let url = layoutIntentURL
        let folder = url.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(intent)
        let temporary = folder.appendingPathComponent("\(LayoutIntent.fileName).\(UUID().uuidString)")
        guard fm.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            // Through to the disk itself where the volume can; to the system otherwise.
            if fcntl(handle.fileDescriptor, F_FULLFSYNC) != 0, fsync(handle.fileDescriptor) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard Darwin.rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            // And the folder's own entry for it.
            let descriptor = open(folder.path, O_RDONLY)
            if descriptor >= 0 {
                _ = fsync(descriptor)
                close(descriptor)
            }
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    /// Removes the record, what an interrupted write of one may have left, and the
    /// hidden folder itself if that leaves it empty. The removal is forced out to the
    /// disk, so that a record once dealt with cannot come back after a loss of power.
    func removeLayoutIntent() {
        let folder = layout.hiddenFolder
        unlink(layoutIntentURL.path)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix(LayoutIntent.fileName + ".") {
            unlink(folder.appendingPathComponent(name).path)
        }
        let descriptor = open(folder.path, O_RDONLY)
        if descriptor >= 0 {
            if fcntl(descriptor, F_FULLFSYNC) != 0 { _ = fsync(descriptor) }
            close(descriptor)
        }
        _ = rmdir(folder.path)
    }

    /// The record, or nil when it cannot be read or was written by a newer version.
    private func readLayoutIntent() -> LayoutIntent? {
        guard let data = try? Data(contentsOf: layoutIntentURL),
              let intent = try? JSONDecoder().decode(LayoutIntent.self, from: data),
              intent.version <= LayoutIntent.currentVersion
        else { return nil }
        return intent
    }

    // MARK: Folders

    private func libraryURL(_ relative: String) -> URL {
        (relative as NSString).pathComponents.reduce(layout.root) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    private func relativePath(_ url: URL) -> String {
        layout.relativeComponents(of: url)?.joined(separator: "/") ?? url.path
    }

    /// What the folder at `url` is, whatever it is called: its file number. Nil when
    /// no real folder is there.
    static func folderIdentity(_ url: URL) -> UInt64? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return UInt64(info.st_ino)
    }

    /// Makes the moves with the library's folder mover, having first written `intent`,
    /// filled in with the moves, where each folder is set aside and what each folder
    /// is. Nothing is written when there are no moves.
    /// - Returns: The record as written. It is still there: the caller removes it once
    ///   the catalogue is written, or every folder is back.
    /// - Throws: What `FolderMover.move` throws. After `.failed` every folder is where
    ///   it was (the record is still there to remove).
    func moveFolders(_ moves: [PlannedMove], recording intent: LayoutIntent) throws -> LayoutIntent {
        guard !moves.isEmpty else { return intent }
        var written = intent
        try folderMover().move(moves) { preparation in
            written.moves = moves.enumerated().map { index, move in
                LayoutIntent.Move(
                    from: self.relativePath(move.from), to: self.relativePath(move.to),
                    parkedAt: preparation.parkedAt[index].map(self.relativePath),
                    identity: Self.folderIdentity(move.from) ?? 0)
            }
            written.madeFolders = preparation.madeFolders.map(self.relativePath)
            try self.writeLayoutIntent(written)
        }
        return written
    }

    /// Why the folders an interrupted change moved could not be put back.
    struct LayoutRestoreFailure: Error {
        var reason: String
        /// The folders to tell of: those that cannot be found, or whose way back is barred.
        var folders: [StrandedFolder]
        /// Every folder that is not where it was before the change.
        var outOfPlace: [StrandedFolder]
    }

    /// Every folder standing in the place where folders are set aside, by what it is.
    private func foldersSetAside() -> [UInt64: URL] {
        let fm = FileManager.default
        var found: [UInt64: URL] = [:]
        let parking = layout.movingFolder
        for operation in (try? fm.contentsOfDirectory(atPath: parking.path)) ?? [] {
            let folder = parking.appendingPathComponent(operation, isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
                let url = folder.appendingPathComponent(name, isDirectory: true)
                if let identity = Self.folderIdentity(url) { found[identity] = url }
            }
        }
        return found
    }

    /// Removes what is left of the place where folders are set aside once no folder is
    /// in it: each operation's list, its folder, and the place itself. Only ever a
    /// list file and empty folders.
    private func clearEmptyParking() {
        let fm = FileManager.default
        let parking = layout.movingFolder
        for operation in (try? fm.contentsOfDirectory(atPath: parking.path)) ?? [] {
            let folder = parking.appendingPathComponent(operation, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path),
                  names.allSatisfy({ $0 == FolderMover.manifestName })
            else { continue }
            unlink(folder.appendingPathComponent(FolderMover.manifestName).path)
            _ = rmdir(folder.path)
        }
        _ = rmdir(parking.path)
    }

    /// Puts every folder `intent` names back where it came from, wherever the work
    /// left it: at its destination, set aside, or still (or already) in its place. All
    /// or nothing, by the same mover and the same never-replacing rename as the change
    /// itself; folders that were removed are made again, and folders the change made
    /// that are empty are removed.
    ///
    /// A folder is known by what it is, not by where it is, so it does not matter how
    /// far the work had got, or how far an earlier attempt to put it right had got:
    /// this can be interrupted and run again.
    ///
    /// - Returns: Whether any folder had to be moved.
    /// - Throws: `LayoutRestoreFailure` when a folder is in none of those places, or
    ///   a move back is refused. Nothing has then been moved (or what was has been
    ///   moved back), and nothing is ever deleted.
    func restoreFolders(_ intent: LayoutIntent) throws -> Bool {
        let identities = Set(intent.moves.map(\.identity))
        // Folders the change made, deepest first. Only ever removed empty, and never a
        // folder that is one of those being put back.
        let made = intent.madeFolders.map(libraryURL).sorted { $0.pathComponents.count > $1.pathComponents.count }
        func removeMadeFolders() {
            for folder in made {
                if let identity = Self.folderIdentity(folder), identities.contains(identity) { continue }
                _ = rmdir(folder.path)
            }
        }

        let setAside = foldersSetAside()
        var back: [PlannedMove] = []
        var lost: [StrandedFolder] = []
        for move in intent.moves {
            let origin = libraryURL(move.from), destination = libraryURL(move.to)
            if Self.folderIdentity(origin) == move.identity { continue }
            if Self.folderIdentity(destination) == move.identity {
                back.append(PlannedMove(from: destination, to: origin))
            } else if let parked = setAside[move.identity] {
                back.append(PlannedMove(from: parked, to: origin))
            } else {
                lost.append(StrandedFolder(url: destination, belongsAt: move.from, wasMovingTo: move.to))
            }
        }
        func outOfPlace(_ now: [String: String] = [:]) -> [StrandedFolder] {
            back.map { move in
                StrandedFolder(
                    url: URL(fileURLWithPath: now[move.from.path] ?? move.from.path, isDirectory: true),
                    belongsAt: relativePath(move.to))
            } + lost
        }
        guard lost.isEmpty else {
            let names = lost.compactMap(\.belongsAt).map { "\"\($0)\"" }.joined(separator: ", ")
            throw LayoutRestoreFailure(
                reason: "A change of folder layout was interrupted, and a folder it was moving cannot be found: "
                    + names,
                folders: lost, outOfPlace: outOfPlace())
        }
        // An empty folder the change made may stand just where a folder belongs.
        removeMadeFolders()
        do {
            try folderMover().move(back)
        } catch let error as FolderMoveError {
            switch error {
            case .failed(let index, let reason):
                throw LayoutRestoreFailure(
                    reason: "A change of folder layout was interrupted, and the folder \"\(relativePath(back[index].to))\" "
                        + "could not be put back: \(reason)",
                    folders: [StrandedFolder(url: back[index].from, belongsAt: relativePath(back[index].to))],
                    outOfPlace: outOfPlace())
            case .rollbackIncomplete(let index, let reason, let outstanding):
                var now: [String: String] = [:]
                for record in outstanding { now[record.from] = record.to }
                let all = outOfPlace(now)
                throw LayoutRestoreFailure(
                    reason: "A change of folder layout was interrupted, and the folder \"\(relativePath(back[index].to))\" "
                        + "could not be put back: \(reason)",
                    folders: all.filter { folder in outstanding.contains { $0.to == folder.url.path } },
                    outOfPlace: all)
            }
        }
        removeMadeFolders()
        clearEmptyParking()
        return !back.isEmpty
    }

    // MARK: Putting an interrupted change right

    /// Puts right a change of folder layout (or the undoing of one) that was cut short
    /// by a crash or a loss of power. To be called when a library is opened, before
    /// anything else is done with it; the launch check (`reconcile`) calls it first.
    /// Does nothing when no change was interrupted.
    ///
    /// When the catalogue had been written, only the tidying up was missed: it is
    /// finished, and there is nothing to tell. Otherwise the catalogue is as it was
    /// before, and every folder is put back where it was (`restoreFolders`), so that
    /// the library and the catalogue agree again; `foldersPutBack` then says so.
    ///
    /// If a folder cannot be found, or cannot be moved back, nothing is deleted, the
    /// record is kept, and `unresolved` and `problem` say what is wrong: the next call
    /// tries again, and until one succeeds every operation that changes the library
    /// throws `LibraryError.layoutChangeInterrupted`.
    ///
    /// The same when the catalogue no longer files the books where the record says
    /// their folders were: then nothing here can say where the folders belong.
    ///
    /// - Throws: Only when the catalogue cannot be read. Nothing has then been changed.
    @discardableResult
    public func recoverInterruptedLayoutChange() throws -> LayoutRecovery {
        guard hasInterruptedLayoutChange else { return LayoutRecovery() }
        guard let intent = readLayoutIntent() else {
            return LayoutRecovery(
                problem: "A change of folder layout was interrupted, and the record of it cannot be read "
                    + "(\(layoutIntentURL.path))")
        }
        // The token is read from the journal as it is, whatever else the undo data holds.
        struct Token: Decodable { var token: String }
        let journalToken = try store.lastBatch()?.snapshot
            .flatMap { try? JSONDecoder().decode(Token.self, from: $0) }?.token
        if (journalToken == intent.token) == intent.committedWhenJournalHolds {
            // The catalogue was written: every folder is where it says.
            clearEmptyParking()
            removeLayoutIntent()
            return LayoutRecovery()
        }
        // The catalogue was not written, so it must still file every one of these
        // books where the record says its folder was. If it does not (the library was
        // changed in the meantime by something that knows nothing of the record), there
        // is no telling where the folders belong, and they are left as they are.
        let filed = Set(try store.bookFolders().values.compactMap { folderKey(store.url(forFolder: $0)) })
        let unknown = intent.moves.filter { move in folderKey(libraryURL(move.from)).map(filed.contains) != true }
        guard unknown.isEmpty else {
            return LayoutRecovery(
                unresolved: unknown.map {
                    StrandedFolder(url: libraryURL($0.to), belongsAt: $0.from, wasMovingTo: $0.to)
                },
                problem: "A change of folder layout was interrupted, and the catalogue no longer agrees with the "
                    + "record of it, so the folders were left where they are")
        }
        do {
            let moved = try restoreFolders(intent)
            removeLayoutIntent()
            return LayoutRecovery(foldersPutBack: moved)
        } catch let failure as LayoutRestoreFailure {
            return LayoutRecovery(unresolved: failure.folders, problem: failure.reason)
        }
    }

    // MARK: Giving up

    /// Gives up on putting right a change of folder layout that was cut short: for
    /// when `recoverInterruptedLayoutChange` cannot, and the owner would sooner sort
    /// the folders out by hand than leave the library refusing every change.
    ///
    /// Removes the record of the interrupted change, forced out to the disk like every
    /// removal of it, and what is left of a place where folders were set aside once no
    /// folder is in it (its list and the empty folder). No book folder is touched,
    /// wherever it is, nothing is deleted, and the catalogue is left exactly as it is:
    /// it files each book where it was before the change. The launch check
    /// (`reconcile`) then runs as usual, and reports the books whose folders are not
    /// there as missing their files, the files where the folders went as belonging to
    /// no book, and any folder still set aside.
    ///
    /// Does nothing when no change is recorded as interrupted.
    /// - Throws: `LibraryError.layoutChangeInterrupted` when the record could not be removed.
    public func discardInterruptedLayoutChange() throws {
        guard hasInterruptedLayoutChange else { return }
        clearEmptyParking()
        removeLayoutIntent()
        try refuseWhileLayoutChangeIsInterrupted()
    }
}
