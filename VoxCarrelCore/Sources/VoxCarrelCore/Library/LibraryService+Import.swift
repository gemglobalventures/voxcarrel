import Foundation

extension LibraryService {
    /// Imports reviewed candidates. One undoable operation.
    ///
    /// Items are handled in order and independently: one that cannot be imported gets
    /// `.failed` and is left exactly as it was. Throws only when the database commit
    /// fails, in which case everything the call did is reversed.
    public func importItems(
        _ items: [ImportItem], options: ImportOptions = ImportOptions()
    ) throws -> ImportResult {
        var operation = PendingOperation()
        // Books already changed by an earlier item of this call.
        var targets = Set<Int64>()
        let prepared = items.map { item -> PreparedItem in
            switch item.target {
            case .newBook:
                return prepareNewBook(item, options: options, into: &operation)
            case .existing(let bookId):
                guard !targets.contains(bookId) else {
                    return .failed("Another item of this import already adds files to that book")
                }
                let result = prepareExistingBook(item, bookId: bookId, options: options, into: &operation)
                if case .imported = result { targets.insert(bookId) }
                return result
            }
        }

        let count = operation.writes.count
        guard count > 0 else {
            // Nothing to commit: the journal and earlier undo data stay as they were.
            removeUndoData(token: operation.token)
            return ImportResult(outcomes: prepared.map(\.failureOutcome))
        }

        let books = try commit(operation, label: count == 1 ? "Import 1 book" : "Import \(count) books")
        return ImportResult(outcomes: prepared.map { item in
            switch item {
            case .failed(let reason):
                return .failed(reason: reason)
            case .imported(let index, let problems):
                return books[index].id.map { .imported(bookId: $0, fileProblems: problems) }
                    ?? .failed(reason: "The book was not saved")
            case .needsAttention(let index):
                return books[index].id.map { .needsAttention(bookId: $0) }
                    ?? .failed(reason: "The book was not saved")
            }
        })
    }

    /// What became of one item before the commit. Indexes point into the operation's writes.
    enum PreparedItem {
        case failed(String)
        case imported(writeIndex: Int, problems: [FileProblem])
        case needsAttention(writeIndex: Int)

        var failureOutcome: ImportOutcome {
            if case .failed(let reason) = self { return .failed(reason: reason) }
            return .failed(reason: "Nothing was imported")
        }
    }

    /// The candidate's files, checked and read once each. Throws a readable reason.
    func workingFiles(for candidate: CandidateBook) throws -> [WorkingFile] {
        guard !candidate.files.isEmpty else { throw ItemFailure("There are no files to import") }
        return try candidate.files.map { file in
            let name = file.url.lastPathComponent
            guard let format = FileFormat(url: file.url) else {
                throw ItemFailure("\"\(name)\" is not a kind of file VoxCarrel can import")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { throw ItemFailure("The file \"\(name)\" could not be found (\(file.url.path))") }
            return workingFile(at: file.url, format: format, role: file.role)
        }
    }

    /// A reason one item failed, already worded for a person.
    struct ItemFailure: Error {
        var reason: String
        init(_ reason: String) { self.reason = reason }
    }

    static func reason(for error: Error) -> String {
        (error as? ItemFailure)?.reason ?? describe(error)
    }

    /// Where a book with this metadata is filed: its folder and one destination per file,
    /// using the capitalisation of folders that already exist. Nil when it cannot be filed.
    func destinations(
        for files: [CandidateFile], metadata: BookMetadata
    ) -> (folder: URL, moves: [PlannedMove])? {
        guard let planned = Organiser.plan(files: files, metadata: metadata, libraryRoot: layout.root),
              let relative = PathBuilder.bookFolder(metadata: metadata)
        else { return nil }
        // The folder itself is the last component of nothing we move, so adopt it as
        // the parent of a stand-in file name.
        let folder = layout.adoptingExistingCapitalisation(
            layout.root.appendingPathComponent(relative, isDirectory: true)
                .appendingPathComponent("x")
        ).deletingLastPathComponent()
        let moves = planned.map {
            PlannedMove(from: $0.from, to: layout.adoptingExistingCapitalisation($0.to))
        }
        return (folder, moves)
    }

    // MARK: A new book

    private func prepareNewBook(
        _ item: ImportItem, options: ImportOptions, into operation: inout PendingOperation
    ) -> PreparedItem {
        let candidate = item.candidate
        var files: [WorkingFile]
        do {
            files = try workingFiles(for: candidate)  // I3
        } catch {
            return .failed(Self.reason(for: error))
        }

        // I7: facts about the files come from the files.
        var metadata = candidate.metadata
        metadata.durationSeconds = Self.totalDuration(files)
        metadata.pageCount = candidate.metadata.pageCount
            ?? files.first { $0.format == .pdf && $0.before != nil }?.before?.metadata.pageCount

        // I8: which cover the app keeps for the book.
        let storedCover: CoverImage?
        switch item.cover {
        case .set(let image): storedCover = image
        case .keep: storedCover = Self.firstCover(in: files)
        case .remove: storedCover = nil
        }

        guard let plan = destinations(for: candidate.files, metadata: candidate.metadata) else {
            // I2: cannot be filed. Catalogued where it is; no file is moved or written,
            // so the reviewed text lives in the database only.
            if case .set = item.cover {
                for index in files.indices { files[index].holdsCover = false }
            }
            var book = Book(metadata: metadata, folderPath: nil, needsAttention: true)
            book.appOnlyFields = Self.appOnlyFields(files: files, hasStoredCover: storedCover != nil)
            operation.add(
                .init(book: book, files: bookFiles(files)),
                snapshot: BookSnapshot(
                    bookId: 0, bookBefore: nil, filesBefore: [], fileStates: [], storedCoverBefore: nil),
                storedCover: storedCover.map { .set($0) } ?? .keep)
            return .needsAttention(writeIndex: operation.writes.count - 1)
        }

        // Covers about to be replaced or removed inside the files are saved for undo
        // before anything moves, so a failure here leaves the item untouched.
        var coversBefore: [CoverBefore?]
        do {
            coversBefore = try files.map {
                try coverBefore(of: $0, change: item.cover, token: operation.token)
            }
        } catch {
            return .failed(Self.reason(for: error))
        }

        // I4
        let records: [MoveRecord]
        do {
            records = try organiser.transfer(plan.moves, mode: options.mode, pruneRoot: layout.root)
        } catch {
            return .failed(Self.reason(for: error))
        }
        for index in files.indices { files[index].url = plan.moves[index].to }

        // I5, I6
        let parts = Self.partPositions(for: files.map(\.role))
        for index in files.indices {
            writeTags(
                candidate.metadata, cover: item.cover, part: parts[index], to: &files[index],
                restorePart: parts[index], coverBefore: coversBefore[index])
        }

        var book = Book(metadata: metadata, folderPath: store.storedPath(for: plan.folder))
        book.appOnlyFields = Self.appOnlyFields(files: files, hasStoredCover: storedCover != nil)  // I9
        operation.records += records
        operation.add(
            .init(book: book, files: bookFiles(files)),  // I10
            snapshot: BookSnapshot(
                bookId: 0, bookBefore: nil, filesBefore: [], fileStates: files.compactMap(\.state),
                storedCoverBefore: nil),
            storedCover: storedCover.map { .set($0) } ?? .keep)
        return .imported(writeIndex: operation.writes.count - 1, problems: Self.fileProblems(files))
    }

    // MARK: Into an existing book

    private func prepareExistingBook(
        _ item: ImportItem, bookId: Int64, options: ImportOptions, into operation: inout PendingOperation
    ) -> PreparedItem {
        let book: Book
        let rows: [BookFile]
        let folder: URL
        var files: [WorkingFile]
        let storedCoverBefore: String?
        let hadStoredCover = covers.url(for: bookId) != nil
        do {
            // A1, A7
            guard let found = try store.book(id: bookId) else { throw LibraryError.bookNotFound(bookId) }
            guard !found.needsAttention, let folderPath = found.folderPath else {
                throw ItemFailure(
                    "\"\(found.title)\" has not been filed in the library yet, so files cannot be added to it")
            }
            book = found
            rows = try store.files(bookId: bookId)
            folder = layout.root.appendingPathComponent(folderPath, isDirectory: true)

            // A5: existing files are read afresh, new ones for the first time (I3).
            let existing = rows.map {
                workingFile(at: store.url(for: $0), format: $0.format, role: $0.role, existing: $0)
            }
            let added = try workingFiles(for: item.candidate)
            let current = Set(existing.map { $0.url.standardizedFileURL.path })
            if let own = added.first(where: { current.contains($0.url.standardizedFileURL.path) }) {
                throw ItemFailure("\"\(own.url.lastPathComponent)\" already belongs to that book")
            }
            // A2: audio, then ebooks, then extras; new files after the existing ones of their kind.
            files = [FileRole.audio, .ebook, .extra].flatMap { role in
                existing.filter { $0.role == role } + added.filter { $0.role == role }
            }
            storedCoverBefore = try saveStoredCoverForUndo(bookId: bookId, token: operation.token)
        } catch {
            return .failed(Self.reason(for: error))
        }

        // A2: names are planned over the whole book, in its present folder.
        let names = PathBuilder.fileNames(
            title: book.title, files: files.map { CandidateFile(url: $0.url, role: $0.role) })
        let moves = zip(files, names).map { file, name in
            PlannedMove(
                from: file.url,
                to: layout.adoptingExistingCapitalisation(folder.appendingPathComponent(name)))
        }

        // A2, A3: one all-or-nothing batch. In copy mode only the new files are copied;
        // existing files that need a new name are moved first.
        let records: [MoveRecord]
        do {
            if options.mode == .move {
                records = try organiser.transfer(moves, mode: .move, pruneRoot: layout.root)
            } else {
                let isNew = files.map { $0.existing == nil }
                let renames = zip(moves, isNew).filter { !$0.1 }.map(\.0)
                let arrivals = zip(moves, isNew).filter { $0.1 }.map(\.0)
                let renamed = try organiser.transfer(renames, mode: .move, pruneRoot: layout.root)
                do {
                    records = renamed + (try organiser.transfer(arrivals, mode: .copy))
                } catch {
                    do {
                        try organiser.undo(renamed)
                    } catch let undoError {
                        throw ItemFailure(
                            Self.describe(error) + ". The book's own files were renamed and could not "
                                + "be renamed back: " + Self.describe(undoError))
                    }
                    throw error
                }
            }
        } catch {
            return .failed(Self.reason(for: error))
        }
        for index in files.indices { files[index].url = moves[index].to }

        // A4: the book's metadata goes into the new files, and into the existing audio
        // files too when the number of parts changed.
        let partsBefore = Self.partPositions(for: rows.map(\.role))
        let partBefore = Dictionary(
            uniqueKeysWithValues: zip(rows, partsBefore).compactMap { row, part in
                row.id.map { ($0, part) }
            })
        let partsAfter = Self.partPositions(for: files.map(\.role))
        let audioCountChanged = rows.filter { $0.role == .audio }.count
            != files.filter { $0.role == .audio }.count
        for index in files.indices {
            let file = files[index]
            let restorePart: PartPosition?
            if let row = file.existing {
                guard file.role == .audio, audioCountChanged else { continue }
                restorePart = row.id.flatMap { partBefore[$0] } ?? nil
            } else {
                restorePart = partsAfter[index]
            }
            writeTags(
                book.metadata, cover: .keep, part: partsAfter[index], to: &files[index],
                restorePart: restorePart, coverBefore: nil)
        }

        // A5
        var updated = book
        if let duration = Self.totalDuration(files) { updated.durationSeconds = duration }
        if updated.pageCount == nil {
            updated.pageCount = files.first {
                $0.existing == nil && $0.format == .pdf && $0.before != nil
            }?.before?.metadata.pageCount
        }
        let newCover = hadStoredCover ? nil : Self.firstCover(in: files.filter { $0.existing == nil })
        // A8
        updated.appOnlyFields = Self.appOnlyFields(
            files: files, hasStoredCover: hadStoredCover || newCover != nil)

        operation.records += records
        operation.add(
            .init(book: updated, files: bookFiles(files)),
            snapshot: BookSnapshot(  // A6
                bookId: bookId, bookBefore: book, filesBefore: rows,
                fileStates: files.compactMap(\.state), storedCoverBefore: storedCoverBefore),
            storedCover: newCover.map { .set($0) } ?? .keep)
        return .imported(writeIndex: operation.writes.count - 1, problems: Self.fileProblems(files))
    }
}
