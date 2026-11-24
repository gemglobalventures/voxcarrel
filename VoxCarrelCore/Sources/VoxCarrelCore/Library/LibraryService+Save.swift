import Foundation

extension LibraryService {
    /// Saves one or more edits as a single undoable operation.
    ///
    /// Edits are handled in order and independently: one that cannot be saved gets
    /// `.failed` and its book is left exactly as it was. An edit that changes nothing is
    /// reported as saved without being written. Throws only when the library's folder
    /// pattern cannot be read, before anything is done, or when the database commit
    /// fails, in which case everything the call did is reversed.
    public func save(_ edits: [BookEdit]) throws -> [SaveOutcome] {
        try refuseWhileLayoutChangeIsInterrupted()
        let pattern = try folderPattern()
        var operation = PendingOperation()
        // Books an earlier edit of this call has already dealt with.
        var handled = Set<Int64>()
        var title = ""
        // Which book has which folder, kept up to date as this call moves books (FP41).
        var owners: FolderOwners?
        let prepared = edits.map { edit -> PreparedEdit in
            guard !handled.contains(edit.bookId) else {
                return .failed("Another edit in the same save already changes that book")
            }
            let result = prepareEdit(edit, pattern: pattern, owners: &owners, into: &operation)
            switch result {
            case .failed: break
            case .unchanged: handled.insert(edit.bookId)
            case .saved(let index, _, _):
                handled.insert(edit.bookId)
                title = operation.writes[index].book.title
            }
            return result
        }

        var books: [Book] = []
        let count = operation.writes.count
        if count > 0 {
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = count == 1 ? "Edit \(name.isEmpty ? "book" : name)" : "Edit \(count) books"
            books = try commit(operation, label: label)
        } else {
            // E12: nothing to commit; the journal and earlier undo data stay as they were.
            removeUndoData(token: operation.token)
        }

        return zip(edits, prepared).map { edit, result in
            switch result {
            case .failed(let reason):
                return .failed(bookId: edit.bookId, reason: reason)
            case .unchanged(let fields):
                return .saved(bookId: edit.bookId, refiled: false, appOnlyFields: fields, fileProblems: [])
            case .saved(let index, let refiled, let problems):
                return .saved(
                    bookId: edit.bookId, refiled: refiled,
                    appOnlyFields: Set(books[index].appOnlyFields), fileProblems: problems)
            }
        }
    }

    /// What became of one edit before the commit.
    private enum PreparedEdit {
        case failed(String)
        /// The edit asks for nothing the book does not already have.
        case unchanged(Set<MetadataField>)
        case saved(writeIndex: Int, refiled: Bool, problems: [FileProblem])
    }

    private func prepareEdit(
        _ edit: BookEdit, pattern: FolderPattern, owners: inout FolderOwners?,
        into operation: inout PendingOperation
    ) -> PreparedEdit {
        let book: Book
        let rows: [BookFile]
        do {
            guard let found = try store.book(id: edit.bookId) else {  // E1
                throw LibraryError.bookNotFound(edit.bookId)
            }
            book = found
            rows = try store.files(bookId: edit.bookId)
        } catch {
            return .failed(Self.reason(for: error))
        }
        var edit = edit
        // G1: no genre twice, each spelled as the library's list has it. A new name
        // that could not be told from two in a file's tag is refused.
        edit.metadata.genres = listedGenres(edit.metadata.genres)
        let added = edit.metadata.genres.filter { !book.genres.contains($0) }
        if let name = added.first(where: { GenreName.valid($0) == nil }) {
            return .failed("A genre's name cannot have a comma, a semicolon or a slash in it: \"\(name)\"")
        }
        if rows.isEmpty { return prepareEditWithoutFiles(edit, book: book, into: &operation) }

        // E2: the facts about the files are not editable.
        var metadata = edit.metadata
        metadata.durationSeconds = book.durationSeconds
        metadata.pageCount = book.pageCount
        let metadataChanged = metadata != book.metadata
        // E7: files are opened only when what goes inside them changed.
        let writesTags = metadataChanged || edit.cover != .keep

        // E3: plan over the files where they really are; a move that differs from its
        // source only in capitalisation is not made (`filingPlan`).
        let current = rows.map { FilingSource(url: store.url(for: $0), role: $0.role) }
        var moves: [(index: Int, move: PlannedMove)] = []
        var folderPath = book.folderPath
        let plan = filingPlan(for: current, metadata: metadata, pattern: pattern)
        // FP41: the folder the book would be filed in is another book's.
        var folderTaken = false
        if let plan {
            // E5: a book catalogued in place is only filed while all its files are there.
            let canFile = book.folderPath != nil
                || current.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) }
            if canFile, book.folderPath == nil || !plan.moves.isEmpty,
               isAnotherBooksFolder(plan.folder, for: book.id, owners: &owners) {
                // Not moved at all: it stays where it is, and is flagged.
                folderTaken = true
            } else if canFile {
                moves = plan.moves
                if book.folderPath == nil || !moves.isEmpty {
                    folderPath = store.storedPath(for: plan.folder)
                }
            }
        }

        // E4, E5: flagged while it cannot be filed or is not filed; cleared once an edit
        // has made it fileable or filed it, but never while one of its files is missing
        // from disk. Otherwise the flag is left as it is.
        let needsAttention: Bool
        if plan == nil || folderPath == nil || folderTaken {
            needsAttention = true
        } else if book.folderPath == nil || metadataChanged || !moves.isEmpty {
            needsAttention = book.needsAttention
                && !current.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) }
        } else {
            needsAttention = book.needsAttention
        }

        if !writesTags, moves.isEmpty, edit.tags == book.tags, edit.rating == book.rating,
           edit.editionKind == book.editionKind,
           needsAttention == book.needsAttention, folderPath == book.folderPath {
            return .unchanged(Set(book.appOnlyFields))
        }

        // E10: what undo needs is saved before anything is overwritten.
        var files = workingFiles(for: rows, read: writesTags)
        let coversBefore: [CoverBefore?]
        let storedCoverBefore: String?
        do {
            coversBefore = try files.map {
                try coverBefore(of: $0, change: edit.cover, token: operation.token)
            }
            storedCoverBefore = try saveStoredCoverForUndo(bookId: edit.bookId, token: operation.token)
        } catch {
            return .failed(Self.reason(for: error))
        }

        // E6
        let records: [MoveRecord]
        do {
            records = try organiser.transfer(moves.map(\.move), mode: .move, pruneRoot: layout.root)
        } catch {
            return .failed(Self.reason(for: error))
        }
        for (index, move) in moves { files[index].url = move.to }
        // The folder is this book's from here on, for the edits of this call that follow.
        if folderPath != book.folderPath, let folderPath, let id = book.id {
            owners?.set(folderKey(store.url(forFolder: folderPath)), for: id)
        }

        // E7, E8
        var updated = book
        if writesTags {
            let parts = Self.partPositions(for: files.map(\.role))
            for index in files.indices {
                writeTags(
                    metadata, cover: edit.cover, part: parts[index], to: &files[index],
                    restorePart: parts[index], coverBefore: coversBefore[index])
            }
            // E9: from what the writes really stored.
            let hasStoredCover: Bool
            switch edit.cover {
            case .set: hasStoredCover = true
            case .remove: hasStoredCover = false
            case .keep: hasStoredCover = false  // decided below
            }
            var fields = Self.appOnlyFields(files: files, hasStoredCover: hasStoredCover)
            if edit.cover == .keep, book.appOnlyFields.contains(.cover) { fields.append(.cover) }
            updated.appOnlyFields = fields
        }
        updated.metadata = metadata
        if writesTags { updated.genreTag = Self.genreTag(after: files, of: updated, recorded: book.genreTag) }
        // The length is not editable, but what the files were just read to hold counts.
        if writesTags { updated.durationSeconds = Self.remeasuredDuration(files, recorded: book.durationSeconds) }
        Self.keepAudibleIdInStep(&updated, asinBefore: book.asin)
        updated.tags = edit.tags
        updated.rating = edit.rating
        // In the catalogue only: no file is opened for it.
        updated.editionKind = edit.editionKind
        updated.folderPath = folderPath
        updated.needsAttention = needsAttention

        operation.add(
            .init(book: updated, files: bookFiles(files)),
            snapshot: BookSnapshot(
                bookId: edit.bookId, bookBefore: book, filesBefore: rows,
                fileStates: files.compactMap(\.state), storedCoverBefore: storedCoverBefore),
            storedCover: edit.cover, records: records)
        return .saved(
            writeIndex: operation.writes.count - 1, refiled: !moves.isEmpty,
            problems: Self.fileProblems(files))
    }

    /// An edit to a book with no files (one owned elsewhere): only the database and the
    /// stored cover change. There are no tags to write and nothing to file, so no file
    /// problems and nothing "in the app only"; and the book is never flagged for lacking
    /// what filing would need (a title, an author), since it is not filed. A flag it
    /// already has is left alone.
    private func prepareEditWithoutFiles(
        _ edit: BookEdit, book: Book, into operation: inout PendingOperation
    ) -> PreparedEdit {
        // E2 holds here too: the length and page count are not editable. For a book
        // with no audio file the length is the one it was added with.
        var metadata = edit.metadata
        metadata.durationSeconds = book.durationSeconds
        metadata.pageCount = book.pageCount
        if metadata == book.metadata, edit.cover == .keep, edit.tags == book.tags, edit.rating == book.rating,
           edit.editionKind == book.editionKind {
            return .unchanged([])
        }

        // E10
        let storedCoverBefore: String?
        do {
            storedCoverBefore = try saveStoredCoverForUndo(bookId: edit.bookId, token: operation.token)
        } catch {
            return .failed(Self.reason(for: error))
        }

        var updated = book
        updated.metadata = metadata
        Self.keepAudibleIdInStep(&updated, asinBefore: book.asin)
        updated.tags = edit.tags
        updated.rating = edit.rating
        updated.editionKind = edit.editionKind
        updated.appOnlyFields = []
        operation.add(
            .init(book: updated, files: []),
            snapshot: BookSnapshot(
                bookId: edit.bookId, bookBefore: book, filesBefore: [], fileStates: [],
                storedCoverBefore: storedCoverBefore),
            storedCover: edit.cover, records: [])
        return .saved(writeIndex: operation.writes.count - 1, refiled: false, problems: [])
    }

    /// A book's ASIN is its Audible ID: when it changes, the item ID of each of the
    /// book's Audible copies changes with it, and clearing it clears theirs. So what
    /// opens on the Audible website is always the book the ASIN names. Nothing changes
    /// when the ASIN is as it was (ignoring surrounding spaces).
    static func keepAudibleIdInStep(_ book: inout Book, asinBefore: String?) {
        func tidy(_ text: String?) -> String? {
            let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let now = tidy(book.asin)
        guard now != tidy(asinBefore) else { return }
        book.externalCopies = book.externalCopies.map { copy in
            var copy = copy
            if copy.kind == .audible { copy.itemId = now }
            return copy
        }
    }
}
