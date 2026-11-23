import Foundation

/// One file of the entries being merged, and what it will be to the book that is kept.
public struct MergeFilePlan: Equatable, Sendable {
    public var fileId: Int64
    /// The entry the file belongs to now.
    public var bookId: Int64
    /// The file's name as it is now.
    public var name: String
    /// What it will be: the role given for it, or else the guess.
    public var role: FileRole
    /// What it would be if the owner said nothing.
    public var guessedRole: FileRole

    public init(fileId: Int64, bookId: Int64, name: String, role: FileRole, guessedRole: FileRole) {
        self.fileId = fileId
        self.bookId = bookId
        self.name = name
        self.role = role
        self.guessedRole = guessedRole
    }
}

/// Why entries cannot be merged as asked.
public enum MergeBlocker: Equatable, Sendable {
    /// Fewer than two different entries that are in the library.
    case needsTwoBooks
    /// More than one of the entries has audio files: these are their ids.
    case bothHaveAudio([Int64])
    /// A file that would have to be moved is not on disk: its name.
    case fileMissing(String)
    /// Something that is no part of the merge is already where this file would go.
    case nameClash(String)
    /// A change of folder layout was cut short and has not been put right.
    case layoutChangeInterrupted
}

/// Why the kept book will still need attention when the entries have been merged.
public enum MergeAttention: Equatable, Sendable {
    /// A file of the kept entry is not on disk.
    case fileMissing
    /// A book that is no part of the merge has the folder the merged book belongs in.
    case folderTaken
    /// The library's layout cannot file the merged book: it lacks a detail the layout needs.
    case cannotBeFiled
    /// The entries have no files at all, so the merge leaves the kept entry's flag as it is.
    case asBefore
}

/// What merging entries would do.
public struct MergePlan: Equatable, Sendable {
    /// The entry that is kept.
    public var keepId: Int64
    /// The entry the library would keep if the owner did not say.
    public var suggestedKeepId: Int64
    /// Every file of every entry, the kept entry's first.
    public var files: [MergeFilePlan]
    /// Not empty: the merge cannot be made.
    public var blockers: [MergeBlocker]
    /// The folder the kept book is in afterwards, relative to the library; nil when it
    /// cannot be filed anywhere.
    public var resultFolder: String?
    /// Why the kept book will still need attention afterwards; nil when it will not.
    /// Worked out as the merge itself settles the flag, for a merge nothing blocks.
    public var attention: MergeAttention?
    /// How many of the files the merge would move are outside the library folder now:
    /// they would be moved into it (and undoing the merge would move them back).
    public var filesFromOutside: Int

    public init(
        keepId: Int64, suggestedKeepId: Int64, files: [MergeFilePlan], blockers: [MergeBlocker],
        resultFolder: String?, attention: MergeAttention? = nil, filesFromOutside: Int = 0
    ) {
        self.attention = attention
        self.filesFromOutside = filesFromOutside
        self.keepId = keepId
        self.suggestedKeepId = suggestedKeepId
        self.files = files
        self.blockers = blockers
        self.resultFolder = resultFolder
    }
}

extension LibraryService {
    // MARK: Planning

    /// What merging these entries would do: which is kept, what each file would be to
    /// it, where the book would be, and what stands in the way. Nothing is changed, on
    /// disk or in the catalogue, and no file is opened.
    ///
    /// The entry suggested for keeping is the one with audio files when exactly one has
    /// them; otherwise the one with the most details filled in, and of those the
    /// earliest added. With `keep` nil the suggestion is kept.
    ///
    /// Each file that would come in is given a role: an audio file is audio; an EPUB,
    /// MOBI or AZW3 the ebook; a PDF the ebook, unless its name holds an Audible ID in
    /// brackets (`holdsAudibleId`) or the kept book will already have a PDF for its
    /// ebook, when it is an extra. A file that is an extra of its own entry stays one.
    /// The kept entry's own files keep the roles they have. `roles` (by file id)
    /// overrides any of this.
    ///
    /// - Throws: `LibraryError.bookNotFound` when `keep` is not one of the entries;
    ///   `LibraryError.fileNotFound` when `roles` names a file that is none of theirs;
    ///   `LibraryError.invalidRole` when it gives a file a role its format cannot have.
    public func planMerge(bookIds: [Int64], keep: Int64?, roles: [Int64: FileRole] = [:]) throws -> MergePlan {
        let work = try mergeWork(bookIds: bookIds, keep: keep, roles: roles)
        return MergePlan(
            keepId: work.keepId, suggestedKeepId: work.suggestedKeepId,
            files: work.files.map {
                MergeFilePlan(
                    fileId: $0.row.id ?? 0, bookId: $0.bookId, name: $0.name, role: $0.role,
                    guessedRole: $0.guessedRole)
            },
            blockers: work.blockers, resultFolder: work.folder.map { store.storedPath(for: $0) },
            attention: work.attention,
            filesFromOutside: work.moves.filter { layout.relativeComponents(of: $0.from) == nil }.count)
    }

    /// Whether a file's name holds an Audible ID in brackets: "[B" followed by nine
    /// letters or digits and "]", anywhere in it. Such a PDF came with an audiobook.
    static func holdsAudibleId(_ name: String) -> Bool {
        name.range(of: "\\[B[A-Za-z0-9]{9}\\]", options: .regularExpression) != nil
    }

    /// One of the entries being merged, with its file rows.
    struct MergeEntry {
        var book: Book
        var rows: [BookFile]

        var hasAudio: Bool { rows.contains { $0.role == .audio } }
    }

    /// One file of the entries being merged.
    struct MergeFile {
        /// The file's row as it is now.
        var row: BookFile
        var bookId: Int64
        /// Whether it is a file of the entry that is kept.
        var isKept: Bool
        /// Where it is now.
        var url: URL
        var isOnDisk: Bool
        var guessedRole: FileRole
        /// What it will be to the kept book.
        var role: FileRole

        var name: String { url.lastPathComponent }
    }

    /// A merge worked out in full, before anything is done: what `planMerge` reports
    /// and what `mergeBooks` carries out are the same piece of work.
    struct MergeWork {
        var keepId: Int64
        var suggestedKeepId: Int64
        /// Every file of every entry, the kept entry's first.
        var files: [MergeFile] = []
        var blockers: [MergeBlocker] = []
        /// The folder the kept book is in afterwards; nil when it has none.
        var folder: URL?
        /// Whether `folder` is the one the layout files the book in, and not the one it
        /// was left in because that one could not be had.
        var isRefiled = false
        /// Whether the book ends up where the library's layout puts it.
        var isWhereTheLayoutPutsIt = false
        /// Why the kept book will still be flagged afterwards; nil when it will not be.
        var attention: MergeAttention?
        var kept: MergeEntry?
        var others: [MergeEntry] = []
        /// The kept entry with the details of the merged book. The facts about its
        /// files, its folder and its flag are settled when the merge is made.
        var merged: Book?
        /// The kept book's files afterwards, in order: indexes into `files`.
        var order: [Int] = []
        /// Where each file of `order` is afterwards.
        var locations: [URL] = []
        /// The moves that takes, in the order of `order`.
        var moves: [PlannedMove] = []
    }

    /// The entry to suggest keeping (MB1).
    static func suggestedKeep(among entries: [MergeEntry]) -> Int64? {
        let withAudio = entries.filter(\.hasAudio)
        if withAudio.count == 1 { return withAudio[0].book.id }
        func filled(_ book: Book) -> Int {
            func has(_ text: String?) -> Bool {
                !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let texts = [
                book.title, book.subtitle, book.series, book.seriesNumber, book.genre, book.publisher,
                book.summary, book.language, book.isbn, book.asin,
            ]
            return texts.filter(has).count + (book.authors.contains(where: has) ? 1 : 0)
                + (book.narrators.contains(where: has) ? 1 : 0) + (book.year == nil ? 0 : 1)
        }
        return entries.min { a, b in
            let (fa, fb) = (filled(a.book), filled(b.book))
            if fa != fb { return fa > fb }
            return (a.book.dateAdded, a.book.id ?? .max) < (b.book.dateAdded, b.book.id ?? .max)
        }?.book.id
    }

    /// The kept entry with the details of the merged book (MB5): its own, with each
    /// one it lacks taken from the others in the order they were chosen. Tags and
    /// "owned elsewhere" notes are joined (of one kind in one form a book has one note,
    /// which takes what it lacked); the most advanced read status wins, with its
    /// dates; the earliest date added and the highest rating are kept.
    static func mergedDetails(kept: Book, others: [Book]) -> Book {
        var merged = kept
        merged.metadata = filledIn(kept.metadata, fromDetails: others.map(\.metadata))

        var seen = Set<String>()
        merged.tags = (kept.tags + others.flatMap(\.tags)).filter {
            seen.insert($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).inserted
        }
        merged.rating = ([kept] + others).map(\.rating).max() ?? kept.rating
        merged.dateAdded = ([kept] + others).map(\.dateAdded).min() ?? kept.dateAdded

        func rank(_ status: ReadStatus) -> Int {
            switch status {
            case .unread: 0
            case .inProgress: 1
            case .finished: 2
            }
        }
        if let furthest = others.max(by: { rank($0.readStatus) < rank($1.readStatus) }),
           rank(furthest.readStatus) > rank(kept.readStatus),
           // Of several as far along, the first chosen.
           let source = others.first(where: { $0.readStatus == furthest.readStatus }) {
            merged.readStatus = source.readStatus
            merged.dateStarted = source.dateStarted
            merged.dateFinished = source.dateFinished
        }

        for other in others {
            for copy in other.externalCopies { give(copy, to: &merged) }
            // Notes a newer version recorded, which this one cannot read, are kept too.
            for value in other.storedCopies.unread where !merged.storedCopies.unread.contains(value) {
                merged.storedCopies.unread.append(value)
            }
        }
        fillASIN(of: &merged, hasFiles: false)
        merged.editionKind = kept.editionKind ?? others.lazy.compactMap(\.editionKind).first
        return merged
    }

    /// Works a merge out in full. Changes nothing.
    func mergeWork(bookIds: [Int64], keep: Int64?, roles: [Int64: FileRole]) throws -> MergeWork {
        let fm = FileManager.default
        var seen = Set<Int64>()
        var entries: [MergeEntry] = []
        for id in bookIds where seen.insert(id).inserted {
            if let book = try store.book(id: id) {
                entries.append(MergeEntry(book: book, rows: try store.files(bookId: id)))
            }
        }
        func files(of entry: MergeEntry, isKept: Bool) -> [MergeFile] {
            entry.rows.map { row in
                let url = store.url(for: row)
                return MergeFile(
                    row: row, bookId: entry.book.id ?? 0, isKept: isKept, url: url,
                    isOnDisk: fm.fileExists(atPath: url.path), guessedRole: row.role, role: row.role)
            }
        }

        // MB3: fewer than two different entries that exist.
        guard entries.count >= 2, let suggested = Self.suggestedKeep(among: entries) else {
            let only = entries.first?.book.id
            var work = MergeWork(
                keepId: keep ?? only ?? bookIds.first ?? 0, suggestedKeepId: only ?? keep ?? bookIds.first ?? 0)
            work.files = entries.flatMap { files(of: $0, isKept: true) }
            work.blockers = [.needsTwoBooks]
            return work
        }
        let keepId = keep ?? suggested
        guard let kept = entries.first(where: { $0.book.id == keepId }) else {
            throw LibraryError.bookNotFound(keepId)
        }
        let others = entries.filter { $0.book.id != keepId }
        var work = MergeWork(keepId: keepId, suggestedKeepId: suggested)
        work.kept = kept
        work.others = others
        work.files = files(of: kept, isKept: true) + others.flatMap { files(of: $0, isKept: false) }

        // MB2: roles. As `setRole` (M1): audio formats are always audio; the others
        // are an ebook or an extra.
        for (fileId, role) in roles.sorted(by: { $0.key < $1.key }) {
            guard let file = work.files.first(where: { $0.row.id == fileId }) else {
                throw LibraryError.fileNotFound(fileId)
            }
            let allowed: Set<FileRole> = file.row.format.defaultRole == .audio ? [.audio] : [.ebook, .extra]
            guard allowed.contains(role) else { throw LibraryError.invalidRole }
        }
        // The kept entry's files come first, so by the time a file that comes in is
        // looked at, what the kept book already has for its ebook is known.
        var hasPDFEbook = false
        for index in work.files.indices {
            let file = work.files[index]
            let guess: FileRole
            if file.isKept || file.row.role == .extra {
                guess = file.row.role
            } else {
                switch file.row.format {
                case .m4b, .m4a, .mp3:
                    guess = .audio
                case .epub, .mobi, .azw3:
                    guess = .ebook
                case .pdf:
                    let named = Self.holdsAudibleId(file.name) || Self.holdsAudibleId(file.row.originalName ?? "")
                    guess = named || hasPDFEbook ? .extra : .ebook
                }
            }
            work.files[index].guessedRole = guess
            work.files[index].role = file.row.id.flatMap { roles[$0] } ?? guess
            if file.row.format == .pdf, work.files[index].role == .ebook { hasPDFEbook = true }
        }

        // MB5
        var merged = Self.mergedDetails(kept: kept.book, others: others.map(\.book))
        // Whether parts seemed to be missing is a fact about the audio as it came in.
        if !kept.hasAudio, let source = others.first(where: \.hasAudio) {
            merged.partsAppearMissing = source.book.partsAppearMissing
        }
        work.merged = merged

        // MB3
        if hasInterruptedLayoutChange { work.blockers.append(.layoutChangeInterrupted) }
        let withAudio = entries.filter(\.hasAudio).compactMap(\.book.id)
        if withAudio.count > 1 { work.blockers.append(.bothHaveAudio(withAudio)) }
        for file in work.files where !file.isOnDisk {
            // A file of the kept entry may be missing, as long as nothing asks for it to move.
            if !file.isKept || file.role != file.row.role { work.blockers.append(.fileMissing(file.name)) }
        }

        // The kept book's files afterwards: audio, then ebooks, then extras; in each,
        // its own, then its own that change role, then those that come in.
        let all = work.files
        work.order = [FileRole.audio, .ebook, .extra].flatMap { role -> [Int] in
            let ofRole = all.indices.filter { all[$0].role == role }
            return ofRole.filter { all[$0].isKept && all[$0].row.role == role }
                + ofRole.filter { all[$0].isKept && all[$0].row.role != role }
                + ofRole.filter { !all[$0].isKept }
        }
        work.locations = work.order.map { all[$0].url }
        guard !all.isEmpty else {
            // MB9: with no files the flag is not this merge's to change.
            work.attention = kept.book.needsAttention ? .asBefore : nil
            return work
        }

        // The folder: where the layout files the merged book, unless a book that is no
        // part of the merge has that folder (FP41, MB8) or a file of the kept entry is
        // missing, so that it cannot be moved as a whole; then where the kept book is.
        let current = kept.book.folderPath.map { store.url(forFolder: $0) }
        work.folder = current
        let pattern = try folderPattern()
        if let wanted = bookFolder(
            for: merged.metadata, hasAudio: all.contains { $0.role == .audio }, pattern: pattern) {
            // The entries being merged away are becoming this book: their folders are no one else's.
            var owners: FolderOwners? = try folderOwners()
            for other in others {
                if let id = other.book.id { owners?.set(nil, for: id) }
            }
            let taken = isAnotherBooksFolder(wanted, for: keepId, owners: &owners)
            let keptIsWhole = all.filter(\.isKept).allSatisfy(\.isOnDisk)
            if keptIsWhole, !taken {
                work.folder = wanted
                work.isRefiled = true
            }
            work.isWhereTheLayoutPutsIt = !taken && work.folder.flatMap { folderKey($0) } == folderKey(wanted)
            // MB9, as `mergeBooks` settles the flag: every file there, and the book
            // where the layout puts it.
            if taken {
                work.attention = .folderTaken
            } else if !keptIsWhole {
                work.attention = .fileMissing
            }
        } else {
            work.attention = .cannotBeFiled
        }
        // Nowhere to file it: nothing moves, and the kept book takes the files where they are.
        guard let folder = work.folder else { return work }

        // MB4: names are planned over the whole book, by the one planner. Only what has
        // to move is moved: the files that come in, the kept entry's own files whose
        // role changes, and all of them when the book is filed in another folder.
        let sources = work.order.map { index -> FilingSource in
            let file = all[index]
            // A file that becomes an extra again goes back under the name it first had there.
            let again = file.role == .extra && file.row.role != .extra
            return FilingSource(url: file.url, role: file.role, extraName: again ? file.row.originalName : nil)
        }
        let plan = filingPlan(for: sources, title: merged.title, folder: folder)
        work.locations = plan.locations
        var moving: [(position: Int, move: PlannedMove)] = []
        for (position, move) in plan.moves {
            let file = all[work.order[position]]
            if file.isKept, !file.isOnDisk || (!work.isRefiled && file.role == file.row.role) {
                // Not there to be moved; or the book stays where it is, and then its own
                // files stay as they are named (FP41). The row is left as it is.
                work.locations[position] = file.url
            } else {
                moving.append((position, move))
            }
        }
        work.moves = moving.map(\.move)

        // Nothing is ever replaced: two files may not end in one place, and nothing
        // that is no part of the merge may be where a file is to go. (A place that
        // another file of the merge leaves is free, as the organiser has it.)
        var clashing = Set<Int>()
        var places = Set<String>()
        for (position, location) in work.locations.enumerated()
        where !places.insert(Self.comparablePath(location)).inserted {
            clashing.insert(position)
        }
        let vacated = Set(moving.map { $0.move.from.standardizedFileURL.path })
        for (position, move) in moving
        where (try? fm.attributesOfItem(atPath: move.to.path)) != nil
            && !vacated.contains(move.to.standardizedFileURL.path) {
            clashing.insert(position)
        }
        for position in clashing.sorted() {
            work.blockers.append(.nameClash(all[work.order[position]].name))
        }
        return work
    }

    // MARK: Merging

    /// Makes the entries one book: `keep` stays, and takes the files, details and
    /// everything attached to the others, which are removed. One undoable operation,
    /// labelled "Merge Books".
    ///
    /// The merge is planned again first (`planMerge`), and refused with its first
    /// blocker. Then, in this order:
    /// 1. What undo needs is saved: the stored covers, and each file whose tags will be
    ///    written, whole.
    /// 2. Every file that has to move is moved, as one batch that is made in full or
    ///    not at all: the files that come in go into the kept book's folder under the
    ///    names the filing rules give them for their roles (audio parts numbered as a
    ///    whole, an extra into `Extras`, a name that is taken given " 2"); the kept
    ///    book's own files move when their role changes or the book is filed in another
    ///    folder. Nothing is ever replaced. Folders left empty are removed.
    /// 3. The kept book's details are written into the files that came in, as into
    ///    files joining a book at import, and into its own files when the merge filled
    ///    in details it lacked.
    /// 4. In one transaction the kept book is written, the others are removed, their
    ///    sent records and collections become the kept book's, and the journal entry
    ///    is recorded.
    ///
    /// A failure at step 1 or 2 leaves everything as it was; a failure at step 4
    /// moves every file back and puts each written file back byte for byte.
    ///
    /// The kept book is filed where the library's layout puts the merged book. The
    /// folders of the entries merged away do not count as another book's; a book that
    /// is no part of the merge and has that folder does, and then the kept book stays
    /// where it is, flagged, with the merge otherwise complete. Afterwards the kept
    /// book is flagged exactly when a file of it is missing or it is not where the
    /// layout puts it.
    ///
    /// - Returns: The kept book's id.
    /// - Throws: `LibraryError.mergeRefused` with the first blocker
    ///   (`LibraryError.layoutChangeInterrupted` for that one); what `planMerge`
    ///   throws; the organiser's error when a file cannot be moved; the database's
    ///   when the commit fails, or `LibraryError.rollbackIncomplete`.
    @discardableResult
    public func mergeBooks(_ bookIds: [Int64], keep: Int64, roles: [Int64: FileRole]) throws -> Int64 {
        let work = try mergeWork(bookIds: bookIds, keep: keep, roles: roles)
        if let blocker = work.blockers.first {
            throw blocker == .layoutChangeInterrupted
                ? LibraryError.layoutChangeInterrupted : LibraryError.mergeRefused(blocker)
        }
        guard let kept = work.kept, let keepId = kept.book.id, let merged = work.merged else {
            throw LibraryError.bookNotFound(keep)
        }
        let fm = FileManager.default
        let ordered = work.order.map { work.files[$0] }

        // Every audio and ebook file is read afresh, as when files join a book (A5).
        var files = ordered.map { entry -> WorkingFile in
            var file = workingFile(at: entry.url, format: entry.row.format, role: entry.role, existing: entry.row)
            if entry.role == .extra, entry.row.role != .extra {
                // An extra is never written, so it holds nothing and has no write to fail.
                file.holds = []
                file.writeProblem = nil
            }
            if entry.role != .extra, entry.row.role == .extra, file.originalName == nil {
                // The name to give back if it becomes an extra again.
                file.originalName = entry.url.lastPathComponent
            }
            return file
        }

        // MB4: the kept book's details go into the files that come in and into its own
        // files that become its ebook; and into all its files when the merge filled in
        // details the kept entry lacked, as a save of those details would.
        let detailsChanged = merged.metadata != kept.book.metadata
        var writes = ordered.map { entry in
            entry.role != .extra && entry.isOnDisk && !FileMetadataIO.storableFields(for: entry.row.format).isEmpty
                && (!entry.isKept || detailsChanged || entry.row.role == .extra)
        }
        for index in files.indices where writes[index] && files[index].before == nil {
            // What could not be read is not written: there would be nothing to put back.
            writes[index] = false
            files[index].wasWritten = true
            files[index].writeProblem = Self.describe(MetadataIOError.unreadable(files[index].url.lastPathComponent))
            files[index].holds = []
        }

        // What undo needs is saved, and what the commit needs is read, before anything
        // moves: a failure here leaves everything untouched.
        var operation = PendingOperation()
        var originals: [Int: SavedOriginal] = [:]
        var removed: [MergeSnapshot.RemovedBook] = []
        let storedCoverBefore: String?
        let keptCollections: Set<Int64>
        do {
            storedCoverBefore = try saveStoredCoverForUndo(bookId: keepId, token: operation.token)
            keptCollections = Set(try store.collectionIds(bookId: keepId))
            for other in work.others {
                guard let id = other.book.id else { continue }
                removed.append(
                    MergeSnapshot.RemovedBook(
                        book: other.book, files: other.rows,
                        storedCover: try saveStoredCoverForUndo(bookId: id, token: operation.token),
                        collectionIds: try store.collectionIds(bookId: id),
                        sentRecordIds: try store.sentRecordIds(bookId: id)))
            }
            for index in files.indices where writes[index] {
                originals[index] = try saveOriginal(of: files[index].url, token: operation.token)
            }
        } catch {
            removeUndoData(token: operation.token)
            throw error
        }
        let removedIds = removed.compactMap(\.book.id)
        let hadCover = covers.url(for: keepId) != nil
        let newCover = hadCover ? nil : removedIds.lazy.compactMap { self.covers.image(for: $0) }.first

        // MB4, MB6: one batch, all or nothing.
        let records: [MoveRecord]
        do {
            records = try organiser.transfer(work.moves, mode: .move, pruneRoot: layout.root)
        } catch {
            removeUndoData(token: operation.token)
            throw error
        }
        for index in files.indices { files[index].url = work.locations[index] }
        // From here to the commit nothing throws.

        // Each file's place among the audio parts of the entry it came from, for undo.
        var partBefore: [Int64: PartPosition] = [:]
        for entry in [kept] + work.others {
            for (row, part) in zip(entry.rows, Self.partPositions(for: entry.rows.map(\.role))) {
                if let id = row.id, let part { partBefore[id] = part }
            }
        }
        let partsAfter = Self.partPositions(for: files.map(\.role))
        for index in files.indices where writes[index] {
            writeTags(
                merged.metadata, cover: .keep, part: partsAfter[index], to: &files[index],
                restorePart: ordered[index].row.id.flatMap { partBefore[$0] }, coverBefore: nil)
            guard var original = originals[index] else { continue }
            if files[index].state != nil {
                original.written = FileStamp(fileAt: files[index].url)
                files[index].state?.original = original
            } else {
                // Nothing was written, so there is nothing to put back.
                try? fm.removeItem(at: undoFolder(operation.token).appendingPathComponent(original.fileName))
            }
        }

        var updated = merged
        if work.isRefiled, let folder = work.folder { updated.folderPath = store.storedPath(for: folder) }
        // The facts about the files. As A5: the length is only recomputed when every
        // audio file could be read.
        let audio = files.filter { $0.role == .audio }
        if !audio.isEmpty {
            if audio.allSatisfy({ $0.before?.metadata.durationSeconds != nil }),
               let duration = Self.totalDuration(files) {
                updated.durationSeconds = duration
            } else if !kept.hasAudio, let source = work.others.first(where: \.hasAudio) {
                updated.durationSeconds = source.book.durationSeconds
            }
        } else if updated.durationSeconds == nil {
            updated.durationSeconds = work.others.lazy.compactMap(\.book.durationSeconds).first
        }
        if updated.pageCount == nil {
            // The pages are the ebook's: an entry whose files all become something
            // else (a companion PDF that is now an extra) says nothing of them.
            let givesAnEbook = Set(ordered.filter { $0.role == .ebook }.map(\.bookId))
            updated.pageCount = work.others.lazy
                .filter { $0.rows.isEmpty || givesAnEbook.contains($0.book.id ?? 0) }
                .compactMap(\.book.pageCount).first
                ?? files.first { $0.role == .ebook && $0.format == .pdf }?.before?.metadata.pageCount
        }
        // MB9. A book with no files is never filed, so its flag is not this merge's to change.
        if !files.isEmpty {
            let allPresent = files.allSatisfy { fm.fileExists(atPath: $0.url.path) }
            updated.needsAttention = !(allPresent && work.isWhereTheLayoutPutsIt)
        }
        // A8, from what the files hold now. What the kept entry had in the app only
        // stays so while its own files were not written.
        var appOnly = Set(Self.appOnlyFields(files: files, hasStoredCover: hadCover || newCover != nil))
        if !kept.rows.isEmpty, !detailsChanged {
            let written = files.indices.filter { writes[$0] && files[$0].writeProblem == nil }
            for field in kept.book.appOnlyFields
            where field != .cover && !written.contains(where: { files[$0].holds.contains(field) }) {
                appOnly.insert(field)
            }
        }
        updated.appOnlyFields = MetadataField.allCases.filter(appOnly.contains)

        operation.add(
            .init(book: updated, files: bookFiles(files)),
            snapshot: BookSnapshot(
                bookId: keepId, bookBefore: kept.book, filesBefore: kept.rows,
                fileStates: files.compactMap(\.state), storedCoverBefore: storedCoverBefore),
            storedCover: newCover.map { .set($0) } ?? .keep, records: records)
        operation.deletedBookIds = removedIds
        // MB11: what was attached to the removed entries is the kept book's.
        var joined: [Int64] = []
        for id in removed.flatMap(\.collectionIds) where !keptCollections.contains(id) && !joined.contains(id) {
            joined.append(id)
        }
        operation.membershipsAdded = joined.map { .init(collectionId: $0, bookId: keepId) }
        operation.sentRecordMoves = [.init(recordIds: removed.flatMap(\.sentRecordIds), toBookId: keepId)]
        operation.merge = MergeSnapshot(removed: removed, collectionsJoined: joined)

        _ = try commit(operation, label: "Merge Books")

        // Committed: the removed entries' stored covers have no book any more.
        for id in removedIds { try? covers.remove(for: id) }
        return keepId
    }

    // MARK: Whose folder

    /// The other book whose folder this one belongs in, when that is why it is
    /// flagged: it has files, the library's layout can file it, and the folder it
    /// would be filed in is that book's (FP41). Nil for a book that is not flagged, or
    /// is flagged for anything else. Of several books in that folder, the one with the
    /// lowest id.
    /// - Throws: `LibraryError.bookNotFound` for an unknown id.
    public func bookUsingFolder(of bookId: Int64) throws -> Book? {
        guard let book = try store.book(id: bookId) else { throw LibraryError.bookNotFound(bookId) }
        guard book.needsAttention else { return nil }
        let files = try store.files(bookId: bookId)
        guard !files.isEmpty,
              let folder = bookFolder(
                  for: book.metadata, hasAudio: files.contains { $0.role == .audio }, pattern: try folderPattern()),
              let key = folderKey(folder)
        else { return nil }
        let owners = try folderOwners()
        guard owners.folder(of: bookId) != key, let other = owners.users(of: key, otherThan: bookId).first
        else { return nil }
        return try store.book(id: other)
    }
}
