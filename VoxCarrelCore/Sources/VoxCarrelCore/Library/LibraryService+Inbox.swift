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
    /// folder and in one transaction: what was already there is not an arrival. That
    /// includes a file kept elsewhere and not downloaded, which is there all the same.
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
        let baseline = everythingThere(in: folder, includePDFs: false)
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
    ///
    /// When PDFs are turned on, the PDFs in the folder at that moment are added to its
    /// baseline: they were not listed while PDFs were off, and what was already there
    /// is not an arrival.
    public func updateWatchFolder(_ folder: WatchFolder) throws {
        var baseline: [ListedFile] = []
        if folder.includesPDFs,
            let stored = try store.watchFolders().first(where: { $0.id == folder.id }), !stored.includesPDFs
        {
            baseline = everythingThere(in: stored.url, includePDFs: true).filter { FileFormat(url: $0.url) == .pdf }
        }
        try store.updateWatchFolderSettings(folder, baseline: baseline)
    }

    /// The book files under a folder at this moment, downloaded or not, for its baseline.
    private func everythingThere(in folder: URL, includePDFs: Bool) -> [ListedFile] {
        let listed = listWatchFolder(folder, includePDFs).files
        let known = Set(listed.map(\.url.path))
        return listed + listNotDownloaded(folder, includePDFs).filter { !known.contains($0.url.path) }
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

    // MARK: Checking

    /// Looks into every enabled watch folder and returns the books that have arrived:
    /// files that have settled, that the ledger does not hide, grouped as the scanner
    /// groups a drop of the folder's contents. Call it again whenever something may
    /// have changed, and a settle interval after any check that reports `hasUnsettled`.
    ///
    /// The ledger is tidied on the way: an entry for a file that has changed since, or
    /// that is known to have gone from a folder that could be listed, is deleted. A
    /// file that is merely not listed (not downloaded, a PDF while PDFs do not count,
    /// in a sub-folder that cannot be read) keeps its entry, and a folder that is
    /// missing or may not be read keeps every entry. A folder that is not enabled is
    /// not looked at. Nor is one that has come to be the library, inside it or around
    /// it (the library was moved since the folder was added): the library's own books
    /// are not arrivals.
    ///
    /// A file's tags are read once for each state of it (path, size, modification
    /// date) and remembered while it stays listed. No file is moved or changed, and
    /// nothing is journaled.
    public func checkInbox(now: Date) throws -> InboxReport {
        var statuses: [WatchFolderStatus] = []
        var listed: [(folder: WatchFolder, files: [ListedFile])] = []
        let library = LibraryLayout.canonicalFolder(layout.root).pathComponents
        for folder in try store.watchFolders() {
            guard folder.isEnabled else {
                statuses.append(WatchFolderStatus(folder: folder, availability: .available))
                continue
            }
            guard Self.relation(of: folder.url.pathComponents, to: library) == .apart else {
                statuses.append(WatchFolderStatus(folder: folder, availability: .overlapsLibrary))
                continue
            }
            let listing = listWatchFolder(folder.url, folder.includesPDFs)
            statuses.append(WatchFolderStatus(folder: folder, availability: listing.availability))
            if listing.availability == .available { listed.append((folder, listing.files)) }
        }

        let everything = listed.flatMap(\.files)
        let identities = Dictionary(everything.map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })
        let ready = Set(inboxTracker.observe(everything, at: now).map(\.url.path))
        inboxTags = inboxTags.filter { path, tags in
            identities[path].map { $0.size == tags.size && $0.modifiedAt == tags.modifiedAt } ?? false
        }
        inboxSkipped = inboxSkipped.filter { identities[$0.key] == $0.value }

        let scanner = BookScanner(reader: InboxTagReader { [self] url in
            try cachedInboxTags(of: url, as: identities[url.path])
        })
        var arrivals: [InboxArrival] = []
        var outdated: [Int64] = []
        for (folder, files) in listed {
            // The ledger hides a file only as it was when the entry was made.
            var hidden: Set<String> = []
            for entry in try store.inboxEntries(folderId: folder.id) {
                if let file = identities[entry.path], file.size == entry.size, file.modifiedAt == entry.modifiedAt {
                    hidden.insert(entry.path)
                } else if let id = entry.id, identities[entry.path] != nil || Self.hasGone(entry.path, from: folder) {
                    outdated.append(id)
                }
            }
            let waiting = files.filter { file in
                let path = file.url.path
                return ready.contains(path) && !hidden.contains(path) && inboxSkipped[path] == nil
            }
            guard !waiting.isEmpty else { continue }

            // Folder by folder, so that no book is made of files from two of them.
            let result = scanner.scan(files: waiting.map(\.url), under: folder.url)
            for url in result.skipped {
                if let file = identities[url.path] { inboxSkipped[url.path] = file }
            }
            for candidate in result.candidates {
                guard let first = candidate.files.first else { continue }
                let dates = candidate.files.compactMap { identities[$0.url.path]?.modifiedAt }
                arrivals.append(InboxArrival(
                    id: first.url.path, folderId: folder.id, candidate: candidate,
                    files: candidate.files.map(\.url), arrivedAt: dates.max() ?? now))
            }
        }
        try store.deleteInboxEntries(ids: outdated)

        arrivals.sort { ($0.arrivedAt, $1.id) > ($1.arrivedAt, $0.id) }
        inboxArrivals = Dictionary(arrivals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return InboxReport(arrivals: arrivals, folders: statuses, hasUnsettled: inboxTracker.hasUnsettled)
    }

    /// The tags of a file the check has listed as `file`, read only if they have not
    /// been read for that state of it. A failed read is remembered too.
    private func cachedInboxTags(of url: URL, as file: ListedFile?) throws -> BookMetadata {
        let path = url.path
        if let known = inboxTags[path], let file, known.size == file.size, known.modifiedAt == file.modifiedAt {
            guard let metadata = known.metadata else { throw InboxTagsUnreadable() }
            return metadata
        }
        let read = Result { try readInboxTags.map { try $0(url) } ?? metadataIO.readMetadata(at: url) }
        if let file {
            inboxTags[path] = InboxTags(size: file.size, modifiedAt: file.modifiedAt, metadata: try? read.get())
        }
        return try read.get()
    }

    // MARK: Dismissing and remembering

    /// Takes arrivals of the last check out of the inbox for good: each of their files
    /// is recorded as dismissed, as it is now, and is not offered again unless it
    /// changes. An id that was not among the last check's arrivals is ignored, as is a
    /// file that has gone. No file is touched.
    public func dismissArrivals(ids: [String]) throws {
        var files: [(file: ListedFile, folderId: Int64)] = []
        for id in Set(ids) {
            guard let arrival = inboxArrivals[id] else { continue }
            for url in arrival.files {
                if let file = Self.fileAsItIs(url) { files.append((file, arrival.folderId)) }
            }
        }
        try store.replaceInboxEntries(files, state: .dismissed)
    }

    /// Remembers files that were imported and are still where they were (imported by
    /// copying), so that they do not arrive again. A file that no longer exists, or
    /// that is not under a watch folder, is ignored.
    public func recordImported(_ files: [URL]) throws {
        guard !files.isEmpty else { return }
        let folders = try store.watchFolders()
        var found: [(file: ListedFile, folderId: Int64)] = []
        var seen: Set<String> = []
        for url in files {
            guard let (folder, listedAs) = Self.ledgerPlace(of: url, among: folders) else { continue }
            if seen.insert(listedAs.path).inserted, let file = Self.fileAsItIs(listedAs) {
                found.append((file, folder.id))
            }
        }
        try store.replaceInboxEntries(found, state: .imported)
    }

    /// The watch folder a file lies in and the path the ledger knows it by, however
    /// `url` names it: under the folder as its listing spells the path; failing that,
    /// wherever the file really is (reached through a link, say).
    static func ledgerPlace(of url: URL, among folders: [WatchFolder]) -> (WatchFolder, URL)? {
        for spelling in [url.standardizedFileURL, LibraryLayout.canonicalFolder(url)] {
            if let place = place(of: spelling, among: folders) { return place }
        }
        return nil
    }

    /// The watch folder a file lies in, and the file's path as that folder's listing
    /// spells it: the folder's own path with the names below it added.
    private static func place(of file: URL, among folders: [WatchFolder]) -> (WatchFolder, URL)? {
        let parts = file.pathComponents
        for folder in folders {
            let root = folder.url.pathComponents
            guard relation(of: parts, to: root) == .inside else { continue }
            let listedAs = parts[root.count...].dropLast().reduce(folder.url) {
                $0.appendingPathComponent($1, isDirectory: true)
            }.appendingPathComponent(parts[parts.count - 1], isDirectory: false)
            return (folder, listedAs)
        }
        return nil
    }

    /// A file's size and modification date as they are at this moment, read as the
    /// lister reads them so that the two compare equal. Nil unless it is a plain file.
    private static func fileAsItIs(_ url: URL) -> ListedFile? {
        // A new URL: one that has been asked before may answer from memory.
        let fresh = URL(fileURLWithPath: url.path, isDirectory: false)
        guard let values = try? fresh.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
            values.isRegularFile == true, let size = values.fileSize,
            let modifiedAt = values.contentModificationDate
        else { return nil }
        return ListedFile(url: url, size: Int64(size), modifiedAt: modifiedAt)
    }

    /// Whether nothing is at `path` any more while its watch folder is still there: the
    /// file was deleted or moved away. False when that cannot be told, as when the
    /// folder itself has gone (a drive unplugged in the middle of a check).
    private static func hasGone(_ path: String, from folder: WatchFolder) -> Bool {
        var info = stat()
        guard lstat(path, &info) != 0, errno == ENOENT || errno == ENOTDIR else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
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

/// The tags read from one state of a file.
struct InboxTags {
    var size: Int64
    var modifiedAt: Date
    /// Nil when the file could not be read.
    var metadata: BookMetadata?
}

/// Thrown in place of the first failure when a file is known not to be readable.
struct InboxTagsUnreadable: Error {}

/// Gives the scanner its tags by way of the inbox check, which remembers them. Used
/// within one check, on the thread that makes it.
private final class InboxTagReader: MetadataReader, @unchecked Sendable {
    private let read: (URL) throws -> BookMetadata

    init(_ read: @escaping (URL) throws -> BookMetadata) {
        self.read = read
    }

    func readMetadata(at url: URL) throws -> BookMetadata {
        try read(url)
    }
}
