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

    /// How a length header is rewritten and put back. A test seam: each of its steps
    /// can be replaced.
    var headerRepair = MP3HeaderRepair()

    /// Test seam: called with each file the launch check opens to measure its length.
    var willMeasure: ((URL) -> Void)?

    /// Test seam: called with the file, and the number of bytes, of each read the
    /// launch check makes when it only looks at an MP3's length header.
    var didReadHeader: ((URL, Int) -> Void)?

    /// Test seam: how `removeBook` sends one file to the Trash.
    var trashItem: (URL) throws -> Void = { _ = try LibraryService.moveToSystemTrash($0) }

    /// How the files under a watch folder are listed: given the folder and whether PDFs
    /// count. A test seam.
    var listWatchFolder: (_ folder: URL, _ includePDFs: Bool) -> FolderListing = {
        FolderLister().list($0, includePDFs: $1)
    }

    /// How the files under a watch folder that are kept elsewhere and not downloaded are
    /// listed: `listWatchFolder` leaves them out. A test seam.
    var listNotDownloaded: (_ folder: URL, _ includePDFs: Bool) -> [ListedFile] = {
        FolderLister().listNotDownloaded($0, includePDFs: $1)
    }

    /// Test seam: how the inbox check reads a file's tags, in place of `metadataIO`.
    var readInboxTags: ((URL) throws -> BookMetadata)?

    /// Test seam: whether names that differ only in capitalisation are different names
    /// on the library's volume. Nil asks the volume.
    var volumeIsCaseSensitive: Bool?

    /// What the library's volume said of itself, once asked.
    private var volumeNamingAsked: VolumeNaming?

    /// How names are told apart on the library's volume.
    var volumeNaming: VolumeNaming {
        if let volumeIsCaseSensitive { return VolumeNaming(caseSensitive: volumeIsCaseSensitive) }
        if let volumeNamingAsked { return volumeNamingAsked }
        let asked = VolumeNaming.of(layout.root)
        volumeNamingAsked = asked
        return asked
    }

    /// How a book folder is renamed when the folder layout changes: to a path where
    /// nothing exists, and never by copying. A test seam.
    var renameFolder: (URL, URL) throws -> Void = FolderMover.renameWithoutReplacing

    /// Which disk a folder is on (`FolderMover.volume`). A test seam.
    var volumeOfFolder: (URL) -> UInt64? = FolderMover.volumeOf

    /// How the folder renames of a change of folder layout are forced out to the disk
    /// before the catalogue is written. A test seam.
    var forceFoldersToDisk: (() -> Void)?

    /// Test seam: called once a change of folder layout (or the undoing of one) has
    /// written the catalogue, before it tidies up after itself.
    var afterLayoutCommit: (() throws -> Void)?

    /// Test seam: called at each stage of a merge. Throwing from it stands in for the
    /// app stopping dead there: the merge ends at once, with nothing put back and
    /// nothing tidied up.
    var mergeCheckpoint: ((MergeCheckpoint) throws -> Void)?

    /// How the squared cover is put into a copy made for sending, in place of
    /// `AudioTagIO.setCover`. A test seam.
    var sendCoverWriter: ((CoverImage, URL) throws -> Void)?

    /// The size in bytes over which a send to the phone is warned of as large. A test seam.
    var sendLargeOver = LibraryService.largeSendBytes

    /// The stored folder pattern last logged as unreadable, so it is said once.
    var unreadablePatternLogged: String?

    /// What the inbox checks so far have seen of each file, to tell when it has settled.
    var inboxTracker = SettleTracker()

    /// The tags the inbox check has read, by path, each for one state of its file.
    var inboxTags: [String: InboxTags] = [:]

    /// The files the scanner passed over, by path, each as it was then: not looked at
    /// again until it changes.
    var inboxSkipped: [String: ListedFile] = [:]

    /// The arrivals of the last inbox check, by id.
    var inboxArrivals: [String: InboxArrival] = [:]

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

    /// As `init(store:)`, with another way of sending a file to the Trash: for an app
    /// that has its own, and for tests, which must never touch the real Trash.
    /// `trashItem` throws when the file could not be sent there.
    public convenience init(store: LibraryStore, trashItem: @escaping (URL) throws -> Void) {
        self.init(store: store)
        self.trashItem = trashItem
    }

    /// For tests: inject collaborators.
    init(store: LibraryStore, metadataIO: FileMetadataIO, organiser: Organiser) {
        self.store = store
        self.layout = LibraryLayout(root: store.libraryRoot)
        self.covers = CoverStore(layout: layout)
        self.metadataIO = metadataIO
        self.organiser = organiser
    }

    /// Scans dropped files and folders using the real tags inside them. What the tags
    /// leave out is guessed from names, read with the authors and titles the library
    /// already has (`knownNames()`).
    public func scan(_ urls: [URL]) -> ScanResult {
        // G19: what a file's genre tag comes to is for the library's list to say.
        let reader = LibraryTagReader { [self] url in inLibrary(try metadataIO.readMetadata(at: url), from: url) }
        var result = BookScanner(reader: reader, known: (try? knownNames()) ?? .none).scan(urls)
        setAsideWhatTheLibraryHolds(in: &result)
        return result
    }

    /// Takes out of a scan every file the library already has, and lists it under
    /// `alreadyInLibrary`; a candidate left with no audio and no ebook is dropped, its
    /// extras with it. A file is one the library has when it is byte for byte what a
    /// library file was when it arrived (`BookFile.arrivedPrint`), or holds the same
    /// sound or text as a library file, tags aside (`BookFile.contentPrint`). No
    /// library file is opened. A file kept in iCloud and not here is not read, and a
    /// file that is itself the library's is no copy of it. Nothing is set aside in a
    /// library that was told not to (`LibraryStore.knowsFilesAgain`).
    func setAsideWhatTheLibraryHolds(in result: inout ScanResult) {
        guard (try? store.knowsFilesAgain()) ?? true,
              let arrived = try? store.arrivedPrints(), let contents = try? store.contentPrints(),
              !arrived.isEmpty || !contents.isEmpty, let rows = try? store.allFiles()
        else { return }
        let own = Set(rows.filter { $0.bookId != nil }.map { Self.comparablePath(store.url(for: $0)) })
        // Only a file whose cheap measure a library file shares is read through.
        let prefixes = Set(contents.compactMap(ContentPrint.prefix(of:)))
        func isHeld(_ url: URL) -> Bool {
            if let key = ContentPrint.key(of: url) {
                if prefixes.contains(key.prefix), let print = key.full(), contents.contains(print) { return true }
            }
            guard !arrived.isEmpty, let print = BookScanner.fingerprint(of: url) else { return false }
            return arrived[print] != nil
        }
        var kept: [CandidateBook] = []
        for var candidate in result.candidates {
            var files: [CandidateFile] = []
            for file in candidate.files {
                guard !own.contains(Self.comparablePath(file.url)), BookScanner.isOnThisMac(file.url), isHeld(file.url)
                else {
                    files.append(file)
                    continue
                }
                result.alreadyInLibrary.append(file.url)
            }
            candidate.files = files
            if files.contains(where: { $0.role != .extra }) {
                kept.append(candidate)
            } else {
                // What is left is only what came along with a book the library has.
                result.alreadyInLibrary += files.map(\.url) + candidate.copies
            }
        }
        result.candidates = kept
    }

    /// Works out the content print of up to `limit` library files that have none yet
    /// (books that came in before prints were kept), and records it. A file that
    /// cannot be found, or is kept in iCloud and not here, is left for another time.
    ///
    /// - Returns: How many files were looked at; 0 when there is nothing left to do
    ///   that can be done now.
    @discardableResult
    public func fillInContentPrints(limit: Int = 25) throws -> Int {
        var done = 0
        // More are fetched than asked for, so that files that must wait do not stall the rest.
        for file in try store.filesLackingContentPrint(limit: limit * 4) {
            guard done < limit, let id = file.id else { break }
            let url = store.url(for: file)
            guard FileManager.default.fileExists(atPath: url.path), BookScanner.isOnThisMac(url) else { continue }
            try store.setContentPrint(ContentPrint.of(url) ?? "", forFile: id)
            done += 1
        }
        return done
    }

    /// Every author and every title in the library, normalised for comparing
    /// (`KnownNames.authorKey`, `KnownNames.titleKey`): evidence for which side of a
    /// name "A - B" is the author. One query for each.
    public func knownNames() throws -> KnownNames {
        let authors = try store.distinctValues(.authors).map(KnownNames.authorKey)
        let titles = try store.distinctTitles().map(KnownNames.titleKey)
        return KnownNames(
            authors: Set(authors.filter { !$0.isEmpty }), titles: Set(titles.filter { !$0.isEmpty }))
    }

    /// The library book a candidate belongs to, when that is sure enough to join it
    /// without asking: `existingMatch(for:)` for the candidate's details. So a candidate
    /// without an ASIN is matched by first author and title, edition words aside; one
    /// whose tags or name carry an ASIN finds the book with that Audible ID even if its
    /// title differs. A possible match (`existingMatches(for:)`) is none here.
    ///
    /// Of several matches the earliest added is returned. Books flagged as needing
    /// attention are never matched.
    public func existingMatch(for candidate: CandidateBook) throws -> Book? {
        try existingMatch(for: candidate.metadata)
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
        /// `BookFile.arrivedPrint`: as recorded, or for a file that is new to the
        /// library as it is now, before anything is written into it.
        var arrivedPrint: String?
        /// `BookFile.contentPrint`: as recorded, or for a file that is new to the
        /// library as it is now.
        var contentPrint: String?
        /// What is wrong with an MP3's length header: as just read, or, for a file the
        /// operation did not read, as recorded.
        var lengthProblem: LengthProblem?
    }

    /// A working file for something on disk, read once unless it is an extra.
    /// - Parameters:
    ///   - existing: The file's row, when it already belongs to a library book.
    ///   - read: Pass false when the operation will not write the file's tags; the file
    ///     is then not opened at all.
    func workingFile(
        at url: URL, format: FileFormat, role: FileRole, existing: BookFile? = nil, read: Bool = true
    ) -> WorkingFile {
        var before = role == .extra || !read ? nil : try? metadataIO.read(url)
        // G18: what a file's tag comes to is for the library's list to say.
        if let read = before?.metadata { before?.metadata = inLibrary(read, from: url) }
        var file = WorkingFile(url: url, format: format, role: role, existing: existing, before: before)
        if before != nil { file.trackBefore = try? metadataIO.readTrackTags(at: url) }
        file.writeProblem = existing?.writeProblem
        file.originalName = existing?.originalName ?? (role == .extra ? url.lastPathComponent : nil)
        file.arrivedPrint = existing != nil ? existing?.arrivedPrint : BookScanner.fingerprint(of: url)
        file.contentPrint = existing != nil ? existing?.contentPrint : (ContentPrint.of(url) ?? "")
        file.holdsCover = before?.cover != nil
        file.lengthProblem = before.map(\.lengthProblem) ?? existing?.lengthProblem
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
        // The genres go into the file as the book keeps them.
        var metadata = metadata
        metadata.genres = GenreName.distinct(metadata.genres)
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
    ///
    /// A book with no files at all has none: there is no file that "cannot hold" a field.
    static func appOnlyFields(files: [WorkingFile], hasStoredCover: Bool) -> [MetadataField] {
        guard !files.isEmpty else { return [] }
        let held = files.filter { $0.role != .extra }
        return MetadataField.allCases.filter { field in
            if field == .cover {
                return hasStoredCover && !held.contains { $0.holdsCover }
            }
            return !held.contains { $0.holds.contains(field) }
        }
    }

    /// The genre tag a book's files hold once an operation is done with them
    /// (`Book.genreTag`): the book's genres as a tag, when every file that can hold a
    /// genre was written by the operation and took it; otherwise `recorded`, what was
    /// known before. So a book one of whose files could not be written is still known
    /// to differ from its files.
    static func genreTag(after files: [WorkingFile], of book: Book, recorded: String?) -> String? {
        let holders = files.filter {
            $0.role != .extra && FileMetadataIO.storableFields(for: $0.format).contains(.genre)
        }
        guard !holders.isEmpty, holders.allSatisfy({ $0.wasWritten && $0.holds.contains(.genre) }) else {
            return recorded
        }
        return GenreTag.text(book.genres)
    }

    /// The genre tag of files being brought in, as they were read: that of the first,
    /// in filing order, that has one.
    static func genreTagRead(from files: [WorkingFile]) -> String? {
        (files.filter { $0.role == .audio } + files.filter { $0.role == .ebook })
            .lazy.compactMap { $0.before?.metadata.genreSource }.first
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
            row.arrivedPrint = file.arrivedPrint
            row.contentPrint = file.contentPrint
            row.lengthProblem = file.role == .audio ? file.lengthProblem : nil
            if file.role == .audio {
                if let before = file.before {
                    // As just read, and for the file as the operation leaves it.
                    row.lengthUnmeasured = before.lengthCouldNotBeMeasured
                        ? UnmeasuredLength(fileAt: file.url, statedSeconds: before.metadata.durationSeconds ?? 0)
                        : nil
                } else {
                    row.lengthUnmeasured = file.existing?.lengthUnmeasured
                }
            }
            return row
        }
    }

    /// The sum of the audio files' durations as read, or nil when none could be read.
    static func totalDuration(_ files: [WorkingFile]) -> Double? {
        let durations = files.filter { $0.role == .audio }.compactMap { $0.before?.metadata.durationSeconds }
        return durations.isEmpty ? nil : durations.reduce(0, +)
    }

    /// The length of a book whose files an operation has read, when a length header is
    /// involved: one of its audio files is recorded as stating the wrong length, or was
    /// just read as stating it. The length is then the sum of what was read, so that it
    /// can never stay the one a wrong header gave. Otherwise, and when not every audio
    /// file could be read (a sum over some of the parts would be wrong), `recorded`.
    static func remeasuredDuration(_ files: [WorkingFile], recorded: Double?) -> Double? {
        let audio = files.filter { $0.role == .audio }
        guard audio.contains(where: { $0.lengthProblem != nil || $0.existing?.lengthProblem != nil }),
              audio.allSatisfy({ $0.before?.metadata.durationSeconds != nil }),
              let total = totalDuration(files)
        else { return recorded }
        return total
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
            state.metadataBefore.asReadFromFile, cover: cover, part: state.part, restoringTrack: state.trackBefore,
            to: URL(fileURLWithPath: path))
    }

    /// Keeps a file whole, as it is now, among the operation's undo data, so that it
    /// can be put back byte for byte once its tags have been written. On the library's
    /// own (APFS) volume the copy shares the file's storage until one of them changes.
    func saveOriginal(of url: URL, token: String) throws -> SavedOriginal {
        let fm = FileManager.default
        guard let before = FileStamp(fileAt: url) else { throw OrganiserError.sourceMissing(url.path) }
        let folder = undoFolder(token)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).orig"
        let copy = folder.appendingPathComponent(name)
        try fm.copyItem(at: url, to: copy)
        // The copy is the library's own: a lock copied with it would stop it being
        // put back or cleared away. Its date is the file's, so that the file put back
        // is the file that was.
        var info = stat()
        if lstat(copy.path, &info) == 0, info.st_flags & UInt32(UF_IMMUTABLE) != 0 {
            _ = chflags(copy.path, info.st_flags & ~UInt32(UF_IMMUTABLE))
        }
        if FileStamp(fileAt: copy) != before { before.setTime(ofFileAt: copy) }
        return SavedOriginal(
            fileName: name, before: before, written: nil, keptFileNumber: FileStamp.fileNumber(at: copy))
    }

    /// Puts a file back as it was before the operation wrote into it.
    ///
    /// When the operation kept the file whole (`FileState.original`) and the file is
    /// still exactly what the operation left, the kept file takes its place, in one
    /// step: it is then byte for byte what it was. A file that has already been put
    /// back so is left alone. Otherwise (nothing was kept, the kept file has gone, or
    /// something else has changed the file since) its earlier tags are written back
    /// into it (`restoreTags`).
    /// - Parameter path: Where the file is now.
    func restoreFile(_ state: FileState, at path: String, token: String) throws {
        if let original = state.original {
            let url = URL(fileURLWithPath: path)
            let now = FileStamp(fileAt: url)
            let kept = undoFolder(token).appendingPathComponent(original.fileName)
            // Put back by an earlier attempt: the file is the kept one itself.
            if let number = original.keptFileNumber, now == original.before,
               FileStamp.fileNumber(at: url) == number, !FileManager.default.fileExists(atPath: kept.path) {
                return
            }
            if let written = original.written, now == written, FileManager.default.fileExists(atPath: kept.path),
               putKeptFile(kept, inPlaceOf: url, before: original.before) {
                return
            }
            // Put back by an earlier attempt. (Only where the disk tells the file as it
            // was from the file as written.)
            if now == original.before, original.written != original.before { return }
        }
        try restoreTags(state, at: path, token: token)
    }

    /// Puts a file kept whole in the place of the file at `url`, in one step: the file
    /// is the old one or the new, never neither.
    /// - Returns: False when it could not be done; the file at `url` is then as it was.
    func putKeptFile(_ kept: URL, inPlaceOf url: URL, before: FileStamp) -> Bool {
        // On one volume, a rename.
        if rename(kept.path, url.path) == 0 { return true }
        // On another, a copy beside the file first, under a working copy's name.
        let beside = url.deletingLastPathComponent()
            .appendingPathComponent(".voxcarrel-\(UUID().uuidString).\(url.pathExtension)")
        if (try? FileManager.default.copyItem(at: kept, to: beside)) != nil {
            before.setTime(ofFileAt: beside)
            if rename(beside.path, url.path) == 0 { return true }
            try? FileManager.default.removeItem(at: beside)
        }
        return false
    }

    /// Reverses one set of transfers and then puts the earlier tags back into the files,
    /// each where it then is.
    ///
    /// The transfers are reversed first, all or nothing (`Organiser.undo`): if that
    /// throws, nothing has been changed and no tag is touched. Restoring tags afterwards
    /// is best effort: a failure there is ignored. A file the operation kept whole is put
    /// back whole (`restoreFile`). A copy that is deleted is skipped; a
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
            try? restoreFile(state, at: path, token: token)
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
        /// For a merge: what undoing it needs besides the kept book's snapshot.
        var merge: MergeSnapshot?
        /// For a merge: the sent records that become the kept book's.
        var sentRecordMoves: [LibraryChange.SentRecordMove] = []
        /// For a merge: the collections the kept book joins.
        var membershipsAdded: [LibraryChange.Membership] = []

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
        change.sentRecordMoves = operation.sentRecordMoves
        change.membershipsAdded = operation.membershipsAdded
        change.batch = .init(label: label, moves: operation.records, snapshot: nil)

        let books: [Book]
        do {
            try beforeCommit?()
            books = try store.apply(change) { written in
                var snapshot = OperationSnapshot(token: operation.token, books: operation.snapshots)
                snapshot.merge = operation.merge
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
            // Length headers the operation rewrote go back first: no file was moved since.
            for repair in operation.snapshots[index].headerRepairs {
                try? headerRepair.restore(repair, at: URL(fileURLWithPath: repair.pathAfter))
            }
            do {
                try undoFiles(records, states: states, token: operation.token)
            } catch {
                // The book's files stay where the operation put them, but get their
                // earlier tags back all the same (a copy has an untouched original).
                let copies = Set(records.filter(\.wasCopy).map(\.to))
                for state in states
                where !copies.contains(state.pathAfter) && fm.fileExists(atPath: state.pathAfter) {
                    try? restoreFile(state, at: state.pathAfter, token: operation.token)
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
            case .cannotLocate(let reason): return "The file could not be put back: \(reason)"
            case .wouldLeaveNothing:
                return "That book has no files, so it must stay marked as owned somewhere"
            case .invalidDetails(let reason): return reason
            case .layoutChangeInterrupted:
                return "A change of folder layout was interrupted and has not been put right yet, so nothing "
                    + "else can be changed"
            case .layoutChangeFailed(let book, let reason):
                return "The folder of \(book) could not be moved, so the folder layout was not changed: \(reason)"
            case .mergeRefused(let blocker): return describe(blocker)
            case .mergeInterrupted:
                return "A merge of books was interrupted and has not been put right yet, so nothing else can be "
                    + "changed"
            }
        default:
            return error.localizedDescription
        }
    }

    /// Why entries cannot be merged, as a sentence.
    public static func describe(_ blocker: MergeBlocker) -> String {
        switch blocker {
        case .needsTwoBooks:
            return "Merging needs two or more entries that are in the library"
        case .bothHaveAudio:
            return "More than one of these entries has audio files, and two recordings cannot be merged into one book"
        case .fileMissing(let name):
            return "The file \"\(name)\" could not be found, so it cannot be moved"
        case .nameClash(let name):
            return "Something else is already where \"\(name)\" would go, and nothing is ever replaced"
        case .layoutChangeInterrupted:
            return describe(LibraryError.layoutChangeInterrupted)
        case .mergeInterrupted:
            return describe(LibraryError.mergeInterrupted)
        }
    }
}
