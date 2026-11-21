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
        let prepared = items.map { item -> PreparedItem in
            switch item.target {
            case .newBook:
                return prepareNewBook(item, options: options, into: &operation)
            case .existing:
                return .failed("Adding files to an existing book is not available yet")
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
}
