import Foundation

extension LibraryService {
    /// The folders the library watches, oldest first.
    public func watchFolders() throws -> [WatchFolder] {
        try store.watchFolders()
    }

    /// Starts watching a folder: by Move, enabled, without PDFs. The path stored is the
    /// folder's own, however `url` reaches it (through a link, with `..`).
    ///
    /// Every file in the folder at this moment is recorded as its baseline, with the
    /// folder and in one transaction: what was already there is not an arrival.
    ///
    /// Not an undoable operation, and the one recorded is left as it is. No file is touched.
    ///
    /// - Throws: a `WatchFolderProblem` when the folder cannot be watched. Nothing is
    ///   stored then.
    @discardableResult
    public func addWatchFolder(_ url: URL, now: Date) throws -> WatchFolder {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.standardizedFileURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw WatchFolderProblem.notAFolder }

        let folder = LibraryLayout.canonicalFolder(url)
        let parts = folder.pathComponents
        switch Self.relation(of: parts, to: LibraryLayout.canonicalFolder(layout.root).pathComponents) {
        case .same: throw WatchFolderProblem.isLibrary
        case .inside: throw WatchFolderProblem.insideLibrary
        case .around: throw WatchFolderProblem.containsLibrary
        case .apart: break
        }
        let baseline = listWatchFolder(folder, false)
        // Checked against the folders as they are when this one is stored.
        return try store.insertWatchFolder(path: folder.path, addedAt: now, baseline: baseline) { existing in
            for other in existing where Self.relation(of: parts, to: other.url.pathComponents) != .apart {
                throw WatchFolderProblem.overlaps(existing: other.path)
            }
        }
    }

    /// Changes a watch folder's mode, whether it is enabled and whether PDFs count.
    /// Nothing else about it can be changed: a different path or date is ignored.
    ///
    /// - Throws: `WatchFolderError.notFound` when no folder has the id.
    public func updateWatchFolder(_ folder: WatchFolder) throws {
        try store.updateWatchFolderSettings(folder)
    }

    /// Stops watching a folder and forgets everything recorded about its files. No file
    /// on disk is touched. An id no folder has does nothing.
    public func removeWatchFolder(id: Int64) throws {
        try store.deleteWatchFolder(id: id)
    }

    /// Forgets a folder's baseline, so that the files that were there when it was added
    /// can arrive. What was dismissed or imported stays so. An id no folder has does nothing.
    public func scanExisting(inWatchFolder id: Int64) throws {
        try store.deleteInboxEntries(folderId: id, state: .baseline)
    }

    /// How one folder lies to another.
    enum FolderRelation: Equatable { case same, inside, around, apart }

    /// How the folder with path components `a` lies to the one with components `b`.
    /// Decided name by name, never by comparing path text: `/a/bc` is not inside `/a/b`.
    /// Capitalisation is ignored, as most disks ignore it: at worst two folders that a
    /// disk tells apart by capitals alone cannot both be used.
    static func relation(of a: [String], to b: [String]) -> FolderRelation {
        let shared = zip(a, b).allSatisfy { $0.compare($1, options: [.caseInsensitive]) == .orderedSame }
        guard shared else { return .apart }
        if a.count == b.count { return .same }
        return a.count > b.count ? .inside : .around
    }
}
