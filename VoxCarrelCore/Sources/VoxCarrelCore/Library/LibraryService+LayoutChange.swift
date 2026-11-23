import Foundation

/// One book folder that a change of folder layout moves. Folders are relative to the library.
public struct LayoutMove: Equatable, Sendable {
    public var bookId: Int64
    public var title: String
    public var from: String
    public var to: String

    public init(bookId: Int64, title: String, from: String, to: String) {
        self.bookId = bookId
        self.title = title
        self.from = from
        self.to = to
    }
}

/// One book that a change of folder layout leaves where it is, and why.
public struct LayoutStay: Equatable, Sendable {
    public var bookId: Int64
    public var title: String
    public var reason: String

    public init(bookId: Int64, title: String, reason: String) {
        self.bookId = bookId
        self.title = title
        self.reason = reason
    }
}

/// What changing a library's folder layout would do, or did.
public struct LayoutChangePlan: Equatable, Sendable {
    public var pattern: FolderPattern
    /// The folders that move, in order of destination.
    public var moves: [LayoutMove]
    /// The books that stay where they are although the pattern files them elsewhere, or
    /// cannot file them at all; in the order the books were added.
    public var staying: [LayoutStay]
    /// Books already where the pattern files them.
    public var unchangedCount: Int
    /// Books with no files, which are not filed anywhere.
    public var noFolderCount: Int

    public init(
        pattern: FolderPattern, moves: [LayoutMove] = [], staying: [LayoutStay] = [], unchangedCount: Int = 0,
        noFolderCount: Int = 0
    ) {
        self.pattern = pattern
        self.moves = moves
        self.staying = staying
        self.unchangedCount = unchangedCount
        self.noFolderCount = noFolderCount
    }
}

extension LibraryService {
    /// The reasons a book stays where it is when the folder layout changes.
    enum LayoutReason {
        static let sameFolder = "Another book would use the same folder."
        static let folderExists = "A folder is already there."
        static let folderMissing = "Its folder is missing."
        static let filesMissing = "Its files are missing."
        static let notFiled = "It has not been filed in the library yet."
        static let outsideLibrary = "Its folder is not inside the library folder."
        static let filesElsewhere = "Some of its files are not in its folder."
        static let sharedFolder = "It shares its folder with another book."
        static let holdsAnother = "Another book has files inside its folder."
        static let wouldBeInside = "Its folder would be inside another book's folder."
        static let wouldHoldAnother = "Another book's folder would be inside its folder."
        static let tooLong = "Its folder's name or path would be too long."
        static let otherDisk = "Its folder is on another disk."
    }

    /// FP41: why a book that could be filed is not where the pattern files it.
    public static let folderTakenReason = "Another book uses the folder this book belongs in."

    /// FP41: why a new book is not imported when the folder it belongs in is another
    /// book's, and what to do about it.
    public static let newBookFolderTakenReason =
        "Another book already uses the folder this book belongs in. Add these files to that book instead, "
        + "or change one book's details."

    // MARK: Planning

    /// What changing the library's folder pattern to `pattern` would do. Nothing is
    /// changed, on disk or in the catalogue.
    ///
    /// Each book that has files is looked at: one already where `pattern` files it is
    /// unchanged; one that `pattern` cannot file, or whose folder cannot be moved
    /// without two books ending up in one folder, one inside another, or on top of
    /// something that is already there, stays, with the reason; the rest move. Names
    /// are compared as the library's volume compares them.
    public func planLayoutChange(to pattern: FolderPattern) throws -> LayoutChangePlan {
        try layoutChange(to: pattern).plan
    }

    /// A book folder that is to move, with what is needed to move and record it.
    struct LayoutMover {
        var book: Book
        var rows: [BookFile]
        var from: [String]
        var to: [String]
        var fromKey: [String]
        var toKey: [String]
    }

    /// A planned change of layout, with what carrying it out needs.
    struct LayoutChange {
        var plan: LayoutChangePlan
        /// In the order of `plan.moves`.
        var movers: [LayoutMover] = []
        /// Books that stay behind and are to be flagged as needing attention, not
        /// being flagged already.
        var flagged: [Book] = []
    }

    func layoutChange(to pattern: FolderPattern) throws -> LayoutChange {
        let naming = volumeNaming
        let fm = FileManager.default
        let books = try store.books().sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        let rowsByBook = Dictionary(grouping: try store.allFiles(), by: \.bookId)

        var plan = LayoutChangePlan(pattern: pattern)
        var movers: [Int64: LayoutMover] = [:]
        var stays: [Int64: String] = [:]
        var flagged = Set<Int64>()
        var booksById: [Int64: Book] = [:]
        /// Where each book that has a folder inside the library is now.
        var folders: [Int64: [String]] = [:]
        /// Where the pattern files each book that is already in place.
        var inPlace = Set<Int64>()
        // One spelling for each folder the moves make, whichever book names it first.
        var spelling: [[String]: String] = [:]
        // Planning changes nothing on disk, so what each folder holds is looked up once.
        let names = FolderNames()

        for book in books {
            guard let id = book.id else { continue }
            booksById[id] = book
            let rows = rowsByBook[id] ?? []
            guard !rows.isEmpty else {
                plan.noFolderCount += 1
                continue
            }
            let values = Self.patternValues(of: book, files: rows)
            guard let folderPath = book.folderPath else {
                // Catalogued where it was found: filing it means moving its files one
                // by one, which a change of layout does not do.
                if let reason = unfiledReason(
                    for: book.metadata, hasAudio: rows.contains { $0.role == .audio }, pattern: pattern) {
                    stays[id] = reason
                    flagged.insert(id)
                } else {
                    stays[id] = LayoutReason.notFiled
                }
                continue
            }
            guard let from = layout.relativeComponents(of: store.url(forFolder: folderPath)),
                  !from.contains(where: { $0.hasPrefix(".") })
            else {
                stays[id] = LayoutReason.outsideLibrary
                continue
            }
            let fromKey = naming.key(from)
            folders[id] = fromKey
            guard let destination = bookFolder(
                for: book.metadata, hasAudio: rows.contains { $0.role == .audio }, pattern: pattern, names: names),
                  var to = layout.relativeComponents(of: destination)
            else {
                stays[id] = unfiledReason(
                    for: book.metadata, hasAudio: rows.contains { $0.role == .audio }, pattern: pattern)
                    ?? FolderPattern.unfiledReason(missing: [])
                flagged.insert(id)
                continue
            }
            if naming.key(to) == fromKey {
                inPlace.insert(id)
                plan.unchangedCount += 1
                continue
            }
            // The book's own folder is made by the move, so it is spelled as the
            // pattern spells it, whatever folder of that name may be there now (one
            // that is itself moving away, or the move is not made).
            if let rendered = PathBuilder.bookFolder(values: values, pattern: pattern),
               let name = (rendered as NSString).pathComponents.last {
                to[to.count - 1] = name
            }
            for depth in to.indices {
                let key = naming.key(Array(to.prefix(depth + 1)))
                if let chosen = spelling[key] { to[depth] = chosen } else { spelling[key] = to[depth] }
            }
            movers[id] = LayoutMover(
                book: book, rows: rows, from: from, to: to, fromKey: fromKey, toKey: naming.key(to))
        }

        func stay(_ id: Int64, _ reason: String, flag: Bool = false) {
            guard movers.removeValue(forKey: id) != nil else { return }
            stays[id] = reason
            if flag { flagged.insert(id) }
        }

        // What can be told from each book alone.
        for (id, mover) in movers {
            let folder = store.url(forFolder: mover.book.folderPath ?? "")
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                stay(id, LayoutReason.folderMissing)
                continue
            }
            let places = mover.rows.map { row -> [String]? in
                // A file recorded by its whole path is one the catalogue keeps where it
                // was found, wherever that is: its record is not rewritten by counting
                // folder names, so its book is not moved.
                guard !row.path.hasPrefix("/"),
                      let place = layout.relativeComponents(of: store.url(for: row))
                else { return nil }
                let key = naming.key(place)
                return key.count > mover.fromKey.count && Array(key.prefix(mover.fromKey.count)) == mover.fromKey
                    ? place : nil
            }
            if places.contains(where: { $0 == nil }) {
                stay(id, LayoutReason.filesElsewhere)
            } else if !mover.rows.contains(where: { fm.fileExists(atPath: store.url(for: $0).path) }) {
                stay(id, LayoutReason.filesMissing)
            } else if !Self.fitsOnDisk(folderURL(mover.to), below: places.compactMap { $0?.dropFirst(mover.from.count) }) {
                stay(id, LayoutReason.tooLong)
            }
        }

        // A folder is moved whole, so it must be one book's alone: no other book may
        // share it, or have a file anywhere inside it.
        let sharing = Dictionary(grouping: folders.keys, by: { folders[$0] ?? [] }).values.filter { $0.count > 1 }
        for id in sharing.joined() { stay(id, LayoutReason.sharedFolder) }
        var filePlaces: [(bookId: Int64, key: [String])] = []
        for (bookId, rows) in rowsByBook {
            guard let bookId else { continue }
            for row in rows {
                guard let place = layout.relativeComponents(of: store.url(for: row)) else { continue }
                filePlaces.append((bookId, naming.key(place)))
            }
        }

        // Each pass may make more books stay, and a book that stays keeps its folder,
        // which may be in another's way: repeated until a pass changes nothing.
        let mover = folderMover()
        var settled = false
        while !settled {
            let before = movers.count
            let ordered = movers.keys.sorted()

            // Folders that are not going anywhere.
            var held: [[String]: Int64] = [:]
            for (id, key) in folders where movers[id] == nil { held[key] = id }
            var bySource: [[String]: Int64] = [:]
            for id in ordered { bySource[movers[id]?.fromKey ?? []] = id }

            // Another book's files inside a folder that would move.
            for (bookId, key) in filePlaces {
                for depth in 1..<max(key.count, 1) {
                    if let id = bySource[Array(key.prefix(depth))], id != bookId { stay(id, LayoutReason.holdsAnother) }
                }
            }

            // FP31: two books in one folder. A book that is already there keeps it; of
            // books moving there, the one added first.
            var claimed: [[String]: Int64] = [:]
            for id in ordered {
                guard let key = movers[id]?.toKey else { continue }
                if let holder = held[key] {
                    stay(id, inPlace.contains(holder) ? LayoutReason.sameFolder : Self.folderTakenReason, flag: true)
                } else if claimed[key] != nil {
                    stay(id, LayoutReason.sameFolder, flag: true)
                } else {
                    claimed[key] = id
                }
            }

            // FP31: one book's folder inside another's, once the moves are made.
            var finals = held
            for (key, id) in claimed where movers[id] != nil { finals[key] = id }
            for (key, inner) in finals {
                for depth in 1..<max(key.count, 1) {
                    guard let outer = finals[Array(key.prefix(depth))], outer != inner else { continue }
                    // Two books that are both staying put are as they were.
                    guard movers[inner] != nil || movers[outer] != nil else { continue }
                    stay(inner, LayoutReason.wouldBeInside)
                    stay(outer, LayoutReason.wouldHoldAnother)
                }
            }

            // FP31: what is on disk.
            let remaining = movers.keys.sorted()
            let blockers = mover.blockers(for: remaining.compactMap { movers[$0] }.map(plannedMove))
            for (index, blocker) in blockers {
                switch blocker {
                case .sourceMissing: stay(remaining[index], LayoutReason.folderMissing)
                case .destinationExists: stay(remaining[index], LayoutReason.folderExists)
                case .outsideLibrary: stay(remaining[index], LayoutReason.outsideLibrary)
                case .otherVolume: stay(remaining[index], LayoutReason.otherDisk)
                }
            }
            settled = movers.count == before
        }

        var change = LayoutChange(plan: plan)
        change.movers = movers.values.sorted {
            ($0.to.joined(separator: "/"), $0.book.id ?? 0) < ($1.to.joined(separator: "/"), $1.book.id ?? 0)
        }
        change.plan.moves = change.movers.map {
            LayoutMove(
                bookId: $0.book.id ?? 0, title: $0.book.title, from: $0.from.joined(separator: "/"),
                to: $0.to.joined(separator: "/"))
        }
        change.plan.staying = stays.keys.sorted().map {
            LayoutStay(bookId: $0, title: booksById[$0]?.title ?? "", reason: stays[$0] ?? "")
        }
        change.flagged = flagged.sorted().compactMap { booksById[$0] }.filter { !$0.needsAttention }
        return change
    }

    /// Whether a folder can be made at `folder` with these files below it: no name in
    /// its path is longer than a name may be (255 UTF-16 units, the limit of the
    /// volumes macOS keeps libraries on), and no file's whole path is longer than a
    /// path may be (`PATH_MAX` bytes). Counted in the form names are given to the disk.
    /// A sanitised name is at most 200 characters, which can still be too many units.
    static func fitsOnDisk(_ folder: URL, below files: [ArraySlice<String>]) -> Bool {
        func inDiskForm(_ text: String) -> String { text.decomposedStringWithCanonicalMapping }
        guard folder.pathComponents.allSatisfy({ inDiskForm($0).utf16.count <= 255 }) else { return false }
        let longest = files.map { $0.reduce(0) { $0 + 1 + inDiskForm($1).utf8.count } }.max() ?? 0
        return inDiskForm(folder.path).utf8.count + longest < Int(PATH_MAX)
    }

    private func plannedMove(_ mover: LayoutMover) -> PlannedMove {
        PlannedMove(from: folderURL(mover.from), to: folderURL(mover.to))
    }

    private func folderURL(_ components: [String]) -> URL {
        components.reduce(layout.root) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    func folderMover() -> FolderMover {
FolderMover(
            root: layout.root, parking: layout.movingFolder, naming: volumeNaming, rename: renameFolder,
            volume: volumeOfFolder)
    }

    // MARK: Changing

    /// Changes the library's folder pattern and re-files the whole library by it, as
    /// one undoable operation labelled "Change Folder Layout".
    ///
    /// The change is planned afresh (`planLayoutChange`) and then carried out: the book
    /// folders that move are renamed, whole, so everything inside a book folder goes
    /// with it and no file is renamed, opened or copied; folders the moves leave empty
    /// are removed; and the pattern, the books' new folders and their files' new paths
    /// are stored with the undo record in a single transaction.
    ///
    /// Books that stay behind do not stop the change. One that the new pattern cannot
    /// file, or whose folder under it belongs to another book, is flagged as needing
    /// attention; a book that is moved into place and has all its files loses the flag.
    ///
    /// All or nothing: if a folder cannot be moved, or the catalogue cannot be written,
    /// every folder already moved is put back and the pattern stays as it was. Nothing
    /// is ever replaced. Changing to the pattern already in use, with every book in
    /// place, does nothing and records nothing.
    ///
    /// - Returns: What was done.
    /// - Throws: `LibraryError.layoutChangeFailed` naming the book whose folder could
    ///   not be moved; `LibraryError.rollbackIncomplete` when folders already moved
    ///   could not all be put back; the catalogue's own error when the commit fails.
    @discardableResult
    public func applyLayoutChange(to pattern: FolderPattern) throws -> LayoutChangePlan {
        try refuseWhileLayoutChangeIsInterrupted()
        let patternBefore = try folderPattern()
        let textBefore = try store.folderPatternText()
        let work = try layoutChange(to: pattern)
        // FP38. A stored pattern that cannot be read is replaced all the same: the
        // pattern asked for is then stored, though it is the one already in use.
        let storedIsReadable = textBefore.map { (try? FolderPattern($0)) != nil } ?? true
        if work.movers.isEmpty, work.flagged.isEmpty, pattern == patternBefore, storedIsReadable { return work.plan }

        // What the catalogue is to say afterwards is worked out before any folder
        // moves, so that nothing can fail between the moves and the commit but the
        // commit itself.
        var change = LibraryChange()
        var saved = LayoutChangeSnapshot(patternTextBefore: textBefore, books: [])
        let fm = FileManager.default
        for item in work.movers {
            guard let id = item.book.id else { continue }
            let folderAfter = item.to.joined(separator: "/")
            var book = item.book
            book.folderPath = folderAfter
            // In place and whole, a book has nothing left to attend to. (Its files go
            // with its folder: one that is there now will be there then.)
            if book.needsAttention,
               item.rows.allSatisfy({ fm.fileExists(atPath: store.url(for: $0).path) }) {
                book.needsAttention = false
            }
            let files = item.rows.map { row -> BookFile in
                var row = row
                row.path = Self.path(row.path, movedFrom: item.from.count, to: item.to)
                return row
            }
            var write = LibraryChange.BookWrite(book: book, files: files)
            write.restoresFileIds = true
            change.writes.append(write)
            saved.books.append(
                .init(
                    bookId: id, folderBefore: item.book.folderPath, folderAfter: folderAfter,
                    needsAttentionBefore: item.book.needsAttention))
        }
        for var book in work.flagged {
            guard let id = book.id else { continue }
            saved.books.append(
                .init(
                    bookId: id, folderBefore: book.folderPath, folderAfter: book.folderPath,
                    needsAttentionBefore: book.needsAttention))
            book.needsAttention = true
            var write = LibraryChange.BookWrite(book: book, files: try store.files(bookId: id))
            write.restoresFileIds = true
            change.writes.append(write)
        }
        change.folderPattern = .init(text: pattern.text)
        let moves = work.movers.map(plannedMove)
        var snapshot = OperationSnapshot(token: UUID().uuidString, books: [])
        snapshot.layoutChange = saved
        change.batch = .init(
            label: Self.layoutChangeLabel,
            moves: moves.map { MoveRecord(from: $0.from.path, to: $0.to.path, wasCopy: false) },
            snapshot: try JSONEncoder().encode(snapshot))

        // FP43: what is about to be done is on disk before the first folder moves, so
        // that a crash at any point from here to the commit can be put right when the
        // library is next opened. The record goes once the catalogue is written, or
        // every folder is back.
        var intent = LayoutIntent(
            token: snapshot.token, committedWhenJournalHolds: true, patternTextBefore: textBefore,
            patternTextAfter: pattern.text)
        do {
            intent = try moveFolders(moves, recording: intent)
        } catch let error as FolderMoveError {
            // Put back in full, there is nothing left to put right; if not, the record
            // stays, and the next launch tries again.
            if case .failed = error { removeLayoutIntent() }
            throw layoutError(error, books: work.movers.map(\.book))
        }

        do {
            try beforeCommit?()
            try store.apply(change)
        } catch {
            if error is FolderMover.Halted { throw error }
            // The catalogue is as it was; so must the folders be.
            if !moves.isEmpty {
                do {
                    _ = try restoreFolders(intent)
                } catch let failure as LayoutRestoreFailure {
                    throw LibraryError.rollbackIncomplete(
                        cause: Self.describe(error),
                        stranded: failure.outOfPlace.map { "\($0.url.path) (from \($0.belongsAt ?? "?"))" })
                }
                removeLayoutIntent()
            }
            throw error
        }
        try afterLayoutCommit?()
        removeLayoutIntent()
        // The journal now holds this change: the undo data of earlier ones is of no use.
        forgetUndoData()
        return work.plan
    }

    static let layoutChangeLabel = "Change Folder Layout"

    /// A file's stored path once its book's folder, the first `depth` names of it, has
    /// become `folder`. What follows the folder is kept exactly as stored.
    static func path(_ path: String, movedFrom depth: Int, to folder: [String]) -> String {
        let names = (path as NSString).pathComponents
        return (folder + names.dropFirst(depth)).joined(separator: "/")
    }

    private func layoutError(_ error: FolderMoveError, books: [Book]) -> LibraryError {
        func title(_ index: Int) -> String {
            let title = books.indices.contains(index)
                ? books[index].title.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return title.isEmpty ? "a book" : "“\(title)”"
        }
        switch error {
        case .failed(let index, let reason):
            return .layoutChangeFailed(book: title(index), reason: reason)
        case .rollbackIncomplete(let index, let reason, let outstanding):
            return .rollbackIncomplete(
                cause: "The folder of \(title(index)) could not be moved: \(reason)",
                stranded: outstanding.map { "\($0.to) (from \($0.from))" })
        }
    }

    // MARK: Undoing

    /// Reverses a change of folder layout: every folder goes back to where it was, all
    /// or nothing; then the pattern, the books' folders and their files' paths are put
    /// back in one transaction. Folders the change removed are made again, and folders
    /// it made are removed once empty.
    ///
    /// Only what the change changed is put back: everything else about a book stays as
    /// it is now. A book with a file missing from disk stays (or becomes) flagged.
    ///
    /// The library must be as the change left it. If a folder is no longer where the
    /// change put it, or something now stands where a folder was, nothing is changed
    /// and `LibraryError.undoBlocked` says why. If the catalogue cannot be written the
    /// folders are moved to where the change put them again, so that the undo can be
    /// tried again, and the error is thrown.
    func undoLayoutChange(_ batch: OperationBatch, token: String, _ saved: LayoutChangeSnapshot) throws -> String {
        let fm = FileManager.default
        // Each book the change moved must still be where it was put: undoing moves
        // whole folders, and must not move a folder that is something else by now.
        var current: [(book: Book, rows: [BookFile], before: LayoutChangeSnapshot.BookBefore)] = []
        for before in saved.books {
            let moved = before.folderBefore != before.folderAfter
            guard let book = try store.book(id: before.bookId) else {
                // A book that was only flagged and is gone has nothing to put back; a
                // folder whose book is gone is nobody's to move.
                if moved {
                    throw LibraryError.undoBlocked("A book the change of layout moved is no longer in the library")
                }
                continue
            }
            let rows = try store.files(bookId: before.bookId)
            if moved {
                guard book.folderPath == before.folderAfter,
                      rows.contains(where: { fm.fileExists(atPath: store.url(for: $0).path) })
                else {
                    throw LibraryError.undoBlocked(
                        "The folder of “\(book.title)” is no longer where the change of layout put it")
                }
            }
            current.append((book, rows, before))
        }

        let back = batch.moves.reversed().map {
            PlannedMove(
                from: URL(fileURLWithPath: $0.to, isDirectory: true),
                to: URL(fileURLWithPath: $0.from, isDirectory: true))
        }
        // FP43, as for the change itself: here the catalogue is written once the
        // journal no longer holds the change being undone.
        var intent = LayoutIntent(
            token: token, committedWhenJournalHolds: false, patternTextBefore: try store.folderPatternText(),
            patternTextAfter: saved.patternTextBefore)
        do {
            intent = try moveFolders(back, recording: intent)
        } catch let error as FolderMoveError {
            switch error {
            case .failed(_, let reason):
                removeLayoutIntent()
                throw LibraryError.undoBlocked(reason)
            case .rollbackIncomplete(_, let reason, let outstanding):
                throw LibraryError.rollbackIncomplete(
                    cause: reason, stranded: outstanding.map { "\($0.to) (from \($0.from))" })
            }
        }

        var change = LibraryChange()
        change.clearsJournal = true
        change.folderPattern = .init(text: saved.patternTextBefore)
        for (book, rows, before) in current {
            var restored = book
            restored.folderPath = before.folderBefore
            var files = rows
            if let folderBefore = before.folderBefore, let folderAfter = before.folderAfter,
               folderBefore != folderAfter {
                let after = (folderAfter as NSString).pathComponents
                let folder = (folderBefore as NSString).pathComponents
                files = rows.map { row in
                    var row = row
                    // Only a file that is in the folder the change made goes back with it.
                    if Array((row.path as NSString).pathComponents.prefix(after.count)) == after {
                        row.path = Self.path(row.path, movedFrom: after.count, to: folder)
                    }
                    return row
                }
            }
            // A book with a file missing needs attention whatever it was before.
            restored.needsAttention = before.needsAttentionBefore
                || files.contains { !fm.fileExists(atPath: store.url(for: $0).path) }
            var write = LibraryChange.BookWrite(book: restored, files: files)
            write.restoresFileIds = true
            change.writes.append(write)
        }
        do {
            try beforeCommit?()
            try store.apply(change)
        } catch {
            if error is FolderMover.Halted { throw error }
            // The catalogue still describes the library as the change left it: the
            // folders go there again. If they cannot, the record stays, and the next
            // launch tries again.
            if !back.isEmpty, (try? restoreFolders(intent)) != nil { removeLayoutIntent() }
            throw error
        }
        try afterLayoutCommit?()
        removeLayoutIntent()
        forgetUndoData()
        return batch.label
    }
}
