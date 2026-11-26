import Foundation

extension LibraryService {
    // MARK: Where a book would be filed

    /// The folder, relative to the library, that a book with these details would be
    /// filed in under the library's folder pattern; nil when it cannot be filed (under
    /// the standard pattern: no title or no author). Uses the same planner as import,
    /// so an existing folder's capitalisation is adopted.
    ///
    /// Only looks at folder names: nothing is created.
    /// - Parameter hasAudio: Whether the book's files include any audio file.
    public func plannedFolder(for metadata: BookMetadata, hasAudio: Bool) -> String? {
        // Without the pattern there is no saying where: nil, as for a book that cannot be filed.
        guard let pattern = try? folderPattern() else { return nil }
        // C3: exactly what `importItems` records as a new book's `folderPath`.
        return bookFolder(for: metadata, hasAudio: hasAudio, pattern: pattern).map { store.storedPath(for: $0) }
    }

    /// The folder a book that has no files yet would be filed in if it were given these
    /// as its first files (`importItems` into such a book): planned from its details
    /// with what they lack taken from the files, exactly as the import does. Nil when
    /// it could not be filed: neither the book nor the files name an author, say.
    ///
    /// The audio and ebook files are opened to read their tags. Nothing is changed.
    public func plannedFolder(for metadata: BookMetadata, firstFiles: [CandidateFile]) -> String? {
        let files = firstFiles.compactMap { file in
            FileFormat(url: file.url).map { workingFile(at: file.url, format: $0, role: file.role) }
        }
        return plannedFolder(
            for: Self.filledIn(metadata, from: files), hasAudio: firstFiles.contains { $0.role == .audio })
    }

    /// Whether `folder` (as `plannedFolder` gives it) is the folder of a book other
    /// than `bookId`, names compared as the library's volume compares them. A book is
    /// never filed into such a folder (FP41): an import that would file the first
    /// files of a book there is refused. Reads the catalogue only.
    public func isFolderOfAnotherBook(_ folder: String, than bookId: Int64?) -> Bool {
        var owners: FolderOwners?
        return isAnotherBooksFolder(store.url(forFolder: folder), for: bookId, owners: &owners)
    }

    // MARK: Putting a missing file back

    /// Puts a missing file back: `chosen` is moved (or, for a file kept outside the
    /// library, simply recorded) so the book's file is where the database says.
    ///
    /// The chosen file is taken on its name alone: it is not opened, and no tags are
    /// written. Afterwards the book's needs-attention flag is settled as the launch check
    /// (`reconcile`) would settle it.
    ///
    /// Not undoable. If the last recorded operation involved this book, it can no longer
    /// be undone and is forgotten.
    ///
    /// - Throws: `LibraryError.fileNotFound` for an unknown file id.
    ///   `LibraryError.cannotLocate`, saying why, when the recorded file is not missing,
    ///   when `chosen` is not a plain file of the same format or already belongs to a
    ///   book, or when it cannot be moved to the recorded place (nothing there is ever
    ///   overwritten). In each case nothing has changed. If the database cannot be
    ///   written, that error, after the file has been moved back.
    public func locateFile(fileId: Int64, at chosen: URL) throws {
        try refuseWhileLayoutChangeIsInterrupted()
        let fm = FileManager.default
        // L1
        guard let row = try store.file(id: fileId), let bookId = row.bookId,
              let book = try store.book(id: bookId)
        else { throw LibraryError.fileNotFound(fileId) }
        let rows = try store.files(bookId: bookId)
        let recorded = store.url(for: row)
        let name = "\"\(chosen.lastPathComponent)\""

        // L2: by the same test the launch check uses.
        guard !fm.fileExists(atPath: recorded.path) else {
            throw LibraryError.cannotLocate("the file is not missing (\(recorded.path))")
        }
        // L3: judged without following a link and without opening anything (L7).
        guard let type = (try? fm.attributesOfItem(atPath: chosen.path))?[.type] as? FileAttributeType else {
            throw LibraryError.cannotLocate("\(name) could not be found (\(chosen.path))")
        }
        guard type == .typeRegular else {
            throw LibraryError.cannotLocate("\(name) is not a plain file")
        }
        guard FileFormat(url: chosen) == row.format else {
            throw LibraryError.cannotLocate(
                "\(name) is not a file of the same type as the missing one (.\(row.format.rawValue))")
        }
        // L4
        let chosenPath = Self.comparablePath(chosen)
        if let owner = try store.allFiles().first(where: { Self.comparablePath(store.url(for: $0)) == chosenPath }) {
            let title = try owner.bookId.flatMap { try store.book(id: $0) }?
                .title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw LibraryError.cannotLocate(
                "\(name) already belongs to "
                    + (title.isEmpty ? "a book in the library" : "the book \"\(title)\" in the library"))
        }

        var updatedRows = rows
        var records: [MoveRecord] = []
        if row.path.hasPrefix("/") {
            // L6: a book left where it was. Its file is recorded where it now is.
            for index in updatedRows.indices where updatedRows[index].id == fileId {
                updatedRows[index].path = store.storedPath(for: chosen)
            }
        } else {
            // L5: to exactly the recorded place. The organiser makes the folders and
            // never overwrites.
            do {
                records = try organiser.transfer(
                    [PlannedMove(from: chosen, to: recorded)], mode: .move, pruneRoot: layout.root)
            } catch {
                throw LibraryError.cannotLocate(Self.describe(error))
            }
        }

        // L8: the launch check's verdict on this book, with the file where it now is.
        var updated = book
        switch fileCheck(of: book, files: updatedRows) {
        case .missing: updated.needsAttention = true
        case .recovered: updated.needsAttention = false
        case .asItWas: break
        }

        // One transaction. The rows keep their ids: only this file's path can differ.
        var write = LibraryChange.BookWrite(book: updated, files: updatedRows)
        write.restoresFileIds = true
        var change = LibraryChange()
        change.writes = [write]
        do {
            // L9: an undo that involves this book could no longer be honoured.
            change.cutsJournalThrough = try newestBatchInvolving(bookId: bookId, files: rows.map { store.url(for: $0) })
            try beforeCommit?()
            try store.apply(change)
        } catch {
            do {
                try organiser.undo(records, pruneRoot: layout.root)
            } catch {
                throw LibraryError.rollbackIncomplete(
                    cause: Self.describe(error), stranded: records.map { "\($0.to) (from \($0.from))" })
            }
            throw error
        }
        if change.cutsJournalThrough != nil { forgetUndoData() }
        refreshDetailsFiles(ofBooks: [bookId])
    }
}
