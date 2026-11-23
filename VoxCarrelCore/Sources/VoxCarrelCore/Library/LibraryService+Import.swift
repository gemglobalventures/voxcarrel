import Foundation

extension LibraryService {
    /// Imports reviewed candidates. One undoable operation.
    ///
    /// Items are handled in order and independently: one that cannot be imported gets
    /// `.failed` and is left exactly as it was. Throws only when the library's folder
    /// pattern cannot be read, before anything is done, or when the database commit
    /// fails, in which case everything the call did is reversed.
    public func importItems(
        _ items: [ImportItem], options: ImportOptions = ImportOptions()
    ) throws -> ImportResult {
        let pattern = try folderPattern()
        var operation = PendingOperation()
        // Books already changed by an earlier item of this call.
        var targets = Set<Int64>()
        // Every file that already belongs to a library book, and the files of the items so far.
        var owners: [String: Int64] = [:]
        for row in try store.allFiles() {
            if let bookId = row.bookId { owners[Self.comparablePath(store.url(for: row))] = bookId }
        }
        var seen = Set<String>()
        // Which book has which folder, kept up to date as this call files and moves
        // books: a book already in the library is never filed, or re-filed, into
        // another book's folder (FP41).
        var folderOwners: FolderOwners? = try folderOwners()
        // Worked out for every item before anything moves: a path is resolved through
        // the folders that exist, so it would read differently once its file has gone.
        let itemPaths = items.map { $0.candidate.files.map { Self.comparablePath($0.url) } }
        let prepared = zip(items, itemPaths).map { item, paths -> PreparedItem in
            defer { seen.formUnion(paths) }
            if let reason = claimedFile(of: item, paths: paths, owners: owners, seen: seen) {
                return .failed(reason)
            }
            switch item.target {
            case .newBook:
                let result = prepareNewBook(item, options: options, pattern: pattern, into: &operation)
                // A book of this call has no id yet: it holds its folder under a stand-in.
                if case .imported(let index, _) = result, let path = operation.writes[index].book.folderPath {
                    folderOwners?.set(folderKey(store.url(forFolder: path)), for: Int64(-1 - index))
                }
                return result
            case .existing(let bookId):
                guard !targets.contains(bookId) else {
                    return .failed("Another item of this import already adds files to that book")
                }
                let result = prepareExistingBook(
                    item, bookId: bookId, options: options, pattern: pattern, owners: &folderOwners,
                    into: &operation)
                if case .imported(let index, _) = result {
                    targets.insert(bookId)
                    // Where the book is now, if adding the files filed or re-filed it.
                    if let path = operation.writes[index].book.folderPath {
                        folderOwners?.set(folderKey(store.url(forFolder: path)), for: bookId)
                    }
                }
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

    /// Why an item may not have one of its files: the file already belongs to a library
    /// book, or an earlier item of the same call has it. Nil when all are free.
    private func claimedFile(
        of item: ImportItem, paths: [String], owners: [String: Int64], seen: Set<String>
    ) -> String? {
        for (file, path) in zip(item.candidate.files, paths) {
            let name = "\"\(file.url.lastPathComponent)\""
            if let owner = owners[path] {
                if case .existing(let target) = item.target, target == owner {
                    return "\(name) already belongs to that book"
                }
                let title = (try? store.book(id: owner))?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return "\(name) already belongs to "
                    + (title.isEmpty ? "another book in the library" : "the book \"\(title)\" in the library")
            }
            if seen.contains(path) {
                return "\(name) is also in an earlier item of this import"
            }
        }
        return nil
    }

    /// The candidate's files, checked and read once each. Throws a readable reason.
    func workingFiles(for candidate: CandidateBook) throws -> [WorkingFile] {
        guard !candidate.files.isEmpty else { throw ItemFailure("There are no files to import") }
        return try candidate.files.map { file in
            let name = file.url.lastPathComponent
            guard let format = FileFormat(url: file.url) else {
                throw ItemFailure("\"\(name)\" is not a kind of file VoxCarrel can import")
            }
            // As `setRole` (M1): audio formats are always audio; ebook formats are an
            // ebook or an extra.
            if format.defaultRole == .audio, file.role != .audio {
                throw ItemFailure("\"\(name)\" is an audio file, so it cannot be an ebook or an extra")
            }
            if format.defaultRole != .audio, file.role == .audio {
                throw ItemFailure("\"\(name)\" is not an audio file, so it cannot be an audio part")
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

    // MARK: A new book

    private func prepareNewBook(
        _ item: ImportItem, options: ImportOptions, pattern: FolderPattern, into operation: inout PendingOperation
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

        let sources = candidate.files.map { FilingSource(url: $0.url, role: $0.role) }
        guard let plan = filingPlan(for: sources, metadata: candidate.metadata, pattern: pattern) else {
            // I2: cannot be filed. Catalogued where it is; no file is moved or written,
            // so the reviewed text lives in the database only.
            if case .set = item.cover {
                for index in files.indices { files[index].holdsCover = false }
            }
            var book = Book(metadata: metadata, folderPath: nil, needsAttention: true)
            book.editionKind = Self.statedEditionKind(of: candidate)
            book.partsAppearMissing = Self.partsAppearMissing(in: candidate)
            book.appOnlyFields = Self.appOnlyFields(files: files, hasStoredCover: storedCover != nil)
            operation.add(
                .init(book: book, files: bookFiles(files)),
                snapshot: BookSnapshot(
                    bookId: 0, bookBefore: nil, filesBefore: [], fileStates: [], storedCoverBefore: nil),
                storedCover: storedCover.map { .set($0) } ?? .keep, records: [])
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

        // I4. A file that is already where it belongs (whatever its capitalisation) stays.
        let records: [MoveRecord]
        do {
            records = try organiser.transfer(plan.moves.map(\.move), mode: options.mode, pruneRoot: layout.root)
        } catch {
            return .failed(Self.reason(for: error))
        }
        for index in files.indices { files[index].url = plan.locations[index] }

        // I5, I6
        let parts = Self.partPositions(for: files.map(\.role))
        for index in files.indices {
            writeTags(
                candidate.metadata, cover: item.cover, part: parts[index], to: &files[index],
                restorePart: parts[index], coverBefore: coversBefore[index])
        }

        var book = Book(metadata: metadata, folderPath: store.storedPath(for: plan.folder))
        book.editionKind = Self.statedEditionKind(of: candidate)
        book.partsAppearMissing = Self.partsAppearMissing(in: candidate)
        book.appOnlyFields = Self.appOnlyFields(files: files, hasStoredCover: storedCover != nil)  // I9
        operation.add(
            .init(book: book, files: bookFiles(files)),  // I10
            snapshot: BookSnapshot(
                bookId: 0, bookBefore: nil, filesBefore: [], fileStates: files.compactMap(\.state),
                storedCoverBefore: nil),
            storedCover: storedCover.map { .set($0) } ?? .keep, records: records)
        return .imported(writeIndex: operation.writes.count - 1, problems: Self.fileProblems(files))
    }

    // MARK: Into an existing book

    private func prepareExistingBook(
        _ item: ImportItem, bookId: Int64, options: ImportOptions, pattern: FolderPattern,
        owners: inout FolderOwners?, into operation: inout PendingOperation
    ) -> PreparedItem {
        let book: Book
        let rows: [BookFile]
        var folder: URL
        var files: [WorkingFile]
        let storedCoverBefore: String?
        let hadStoredCover = covers.url(for: bookId) != nil
        // A book that has no files yet (one owned elsewhere) is not filed anywhere: its
        // first files are filed from its own details, as a new book's would be.
        if let entry = try? store.book(id: bookId), entry.folderPath == nil, !entry.needsAttention,
           (try? store.files(bookId: bookId))?.isEmpty == true {
            return prepareFirstFiles(
                item, book: entry, bookId: bookId, options: options, pattern: pattern, owners: &owners,
                into: &operation)
        }
        do {
            // A1, A7
            guard let found = try store.book(id: bookId) else { throw LibraryError.bookNotFound(bookId) }
            guard !found.needsAttention, let folderPath = found.folderPath else {
                throw ItemFailure(
                    "\"\(found.title)\" has not been filed in the library yet, so files cannot be added to it")
            }
            book = found
            rows = try store.files(bookId: bookId)
            folder = store.url(forFolder: folderPath)

            // A5: existing files are read afresh, new ones for the first time (I3).
            let existing = workingFiles(for: rows)
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

        // The folder pattern may file a book by whether it has audio. When these files
        // change that, the pattern files the book somewhere else, and the whole book
        // goes there as part of this item: its own files are moved with the new ones.
        let hadAudio = rows.contains { $0.role == .audio }
        let hasAudio = files.contains { $0.role == .audio }
        var refiledFolder: URL?
        // FP41: the folder the book would be re-filed in is another book's. It is then
        // not re-filed: the new files join it where it is, and it is flagged.
        var folderTaken = false
        if hadAudio != hasAudio {
            func filed(_ audio: Bool) -> String? {
                PathBuilder.bookFolder(
                    values: FolderPatternValues(metadata: book.metadata, hasAudio: audio), pattern: pattern)
            }
            if let now = filed(hasAudio), now != filed(hadAudio),
               let target = bookFolder(for: book.metadata, hasAudio: hasAudio, pattern: pattern) {
                if isAnotherBooksFolder(target, for: bookId, owners: &owners) {
                    folderTaken = true
                } else {
                    refiledFolder = target
                }
            }
        }
        if let refiledFolder { folder = refiledFolder }

        // A2: names are planned over the whole book, in its present folder (or the one
        // it is re-filed in). A file whose planned name differs from the one it has only
        // in capitalisation is left alone.
        let plan = filingPlan(
            for: files.map { FilingSource(url: $0.url, role: $0.role) }, title: book.title, folder: folder)
        let moves = plan.moves.map(\.move)

        // A2, A3: one all-or-nothing batch. In copy mode only the new files are copied;
        // existing files that need a new name are moved first.
        let records: [MoveRecord]
        do {
            if options.mode == .move {
                records = try organiser.transfer(moves, mode: .move, pruneRoot: layout.root)
            } else {
                let renames = plan.moves.filter { files[$0.index].existing != nil }.map(\.move)
                let arrivals = plan.moves.filter { files[$0.index].existing == nil }.map(\.move)
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
        for index in files.indices { files[index].url = plan.locations[index] }

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

        // A5. The duration is only recomputed when every audio file could be read: a
        // sum over some of the parts would be wrong, so the previous value is kept.
        var updated = book
        if refiledFolder != nil { updated.folderPath = store.storedPath(for: plan.folder) }
        if folderTaken { updated.needsAttention = true }
        let audio = files.filter { $0.role == .audio }
        if audio.allSatisfy({ $0.before?.metadata.durationSeconds != nil }),
           let duration = Self.totalDuration(files) {
            updated.durationSeconds = duration
        }
        if updated.pageCount == nil {
            updated.pageCount = files.first {
                $0.existing == nil && $0.format == .pdf && $0.before != nil
            }?.before?.metadata.pageCount
        }
        let newCover = hadStoredCover ? nil : Self.firstCover(in: files.filter { $0.existing == nil })
        // A8
        updated.appOnlyFields = Self.appOnlyFields(
            files: files, hasStoredCover: hadStoredCover || newCover != nil)

        operation.add(
            .init(book: updated, files: bookFiles(files)),
            snapshot: BookSnapshot(  // A6
                bookId: bookId, bookBefore: book, filesBefore: rows,
                fileStates: files.compactMap(\.state), storedCoverBefore: storedCoverBefore),
            storedCover: newCover.map { .set($0) } ?? .keep, records: records)
        return .imported(writeIndex: operation.writes.count - 1, problems: Self.fileProblems(files))
    }

    // MARK: Into a book that has no files yet

    /// The first files of a book that is in the library without any (one owned
    /// elsewhere). The book is filed exactly as a new book with its details would be,
    /// by the same planner: its folder is made and the files are named.
    ///
    /// Nothing a file says about the book is lost. The book's details are kept, and
    /// each one it lacks is taken from the files (`filledIn`); the result is stored on
    /// the book and written into every file, so no tag is ever replaced by nothing. The
    /// item's own reviewed metadata and cover are not used, as for any book already in
    /// the library. The book keeps its external copies. Its stored cover goes into the
    /// files where they can hold one; when it has none the files keep theirs and the
    /// first of them becomes the book's.
    ///
    /// All or nothing: if the book cannot be filed (neither it nor its files name an
    /// author, say, or the folder it belongs in is another book's: FP41) or a file
    /// cannot be transferred, the item fails and nothing has moved. Undo takes the files back out with the tags and covers they had, and
    /// leaves the book as the entry with no files it was.
    private func prepareFirstFiles(
        _ item: ImportItem, book: Book, bookId: Int64, options: ImportOptions, pattern: FolderPattern,
        owners: inout FolderOwners?, into operation: inout PendingOperation
    ) -> PreparedItem {
        var files: [WorkingFile]
        do {
            files = try workingFiles(for: item.candidate)  // I3
        } catch {
            return .failed(Self.reason(for: error))
        }

        // The book's details, with what it lacks taken from the files.
        let details = Self.filledIn(book.metadata, from: files)

        let sources = item.candidate.files.map { FilingSource(url: $0.url, role: $0.role) }
        guard let plan = filingPlan(for: sources, metadata: details, pattern: pattern) else {
            let title = details.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = title.isEmpty ? "That book" : "“\(title)”"
            // What the folder pattern needs beyond a title and an author is said in its own words.
            let missing = pattern.missingTokens(
                for: FolderPatternValues(metadata: details, hasAudio: sources.contains { $0.role == .audio }))
            guard !missing.isEmpty, Set(missing).isSubset(of: [.author, .title]) else {
                return .failed(
                    "\(name) cannot be filed yet, so files cannot be added to it. "
                        + FolderPattern.unfiledReason(missing: missing))
            }
            let hasAuthor = !(details.authors.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return .failed(
                hasAuthor
                    ? "\(name) cannot be filed under its title and author, so files cannot be added to it yet"
                    : "\(name) has no author, and neither have these files, so they cannot be filed: "
                        + "give the book an author first")
        }

        // FP41: the book has no folder yet, and is not given another book's.
        if isAnotherBooksFolder(plan.folder, for: bookId, owners: &owners) {
            let title = details.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(
                "\(title.isEmpty ? "That book" : "“\(title)”") cannot be filed yet, so files cannot be added to it. "
                    + Self.folderTakenReason)
        }

        // What undo needs is saved before anything moves, so a failure here leaves the
        // item untouched.
        let stored = covers.image(for: bookId)
        let cover: CoverChange = stored.map { .set($0) } ?? .keep
        let coversBefore: [CoverBefore?]
        let storedCoverBefore: String?
        do {
            coversBefore = try files.map { try coverBefore(of: $0, change: cover, token: operation.token) }
            storedCoverBefore = try saveStoredCoverForUndo(bookId: bookId, token: operation.token)
        } catch {
            return .failed(Self.reason(for: error))
        }

        // I4
        let records: [MoveRecord]
        do {
            records = try organiser.transfer(plan.moves.map(\.move), mode: options.mode, pruneRoot: layout.root)
        } catch {
            return .failed(Self.reason(for: error))
        }
        for index in files.indices { files[index].url = plan.locations[index] }

        // I5, I6, with the book's details.
        let parts = Self.partPositions(for: files.map(\.role))
        for index in files.indices {
            writeTags(
                details, cover: cover, part: parts[index], to: &files[index],
                restorePart: parts[index], coverBefore: coversBefore[index])
        }

        var updated = book
        // The facts about the files are not details: they are settled below.
        var kept = details
        kept.durationSeconds = book.durationSeconds
        kept.pageCount = book.pageCount
        updated.metadata = kept
        updated.folderPath = store.storedPath(for: plan.folder)
        // As A5: once there are audio files the length is theirs, when every one could
        // be read. Until then (and for ebooks alone) it stays as the book was added.
        let audio = files.filter { $0.role == .audio }
        if !audio.isEmpty, audio.allSatisfy({ $0.before?.metadata.durationSeconds != nil }),
           let duration = Self.totalDuration(files) {
            updated.durationSeconds = duration
        }
        if updated.pageCount == nil {
            updated.pageCount = files.first { $0.format == .pdf && $0.before != nil }?.before?.metadata.pageCount
        }
        let newCover = stored == nil ? Self.firstCover(in: files) : nil
        updated.appOnlyFields = Self.appOnlyFields(files: files, hasStoredCover: stored != nil || newCover != nil)

        operation.add(
            .init(book: updated, files: bookFiles(files)),
            snapshot: BookSnapshot(
                bookId: bookId, bookBefore: book, filesBefore: [], fileStates: files.compactMap(\.state),
                storedCoverBefore: storedCoverBefore),
            storedCover: newCover.map { .set($0) } ?? .keep, records: records)
        return .imported(writeIndex: operation.writes.count - 1, problems: Self.fileProblems(files))
    }

    /// A book's details with each one it lacks taken from its files: the book's own
    /// value wherever it has one, otherwise that of the first file, in filing order
    /// (audio parts, then ebooks), that has one. Extras and files that could not be read
    /// say nothing. The length and the page count are left as the book has them.
    ///
    /// A series and its number go together: a number is only taken from a file that
    /// names the series the book ends up in.
    static func filledIn(_ book: BookMetadata, from files: [WorkingFile]) -> BookMetadata {
        let said = (files.filter { $0.role == .audio } + files.filter { $0.role == .ebook })
            .compactMap { $0.before?.metadata }
        func text(_ value: String?) -> String? {
            let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : value
        }
        func names(_ value: [String]) -> [String]? {
            value.contains { text($0) != nil } ? value : nil
        }
        func first<Value>(_ own: Value?, _ read: (BookMetadata) -> Value?) -> Value? {
            own ?? said.lazy.compactMap(read).first
        }
        func same(_ a: String?, _ b: String?) -> Bool {
            func key(_ value: String?) -> String {
                (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            return key(a) == key(b)
        }

        var merged = book
        merged.title = first(text(book.title)) { text($0.title) } ?? book.title
        merged.subtitle = first(text(book.subtitle)) { text($0.subtitle) }
        merged.authors = first(names(book.authors)) { names($0.authors) } ?? book.authors
        merged.narrators = first(names(book.narrators)) { names($0.narrators) } ?? book.narrators
        merged.series = first(text(book.series)) { text($0.series) }
        if let series = merged.series {
            merged.seriesNumber = first(text(book.seriesNumber)) {
                same($0.series, series) ? text($0.seriesNumber) : nil
            }
        }
        merged.genre = first(text(book.genre)) { text($0.genre) }
        merged.year = first(book.year) { $0.year }
        merged.publisher = first(text(book.publisher)) { text($0.publisher) }
        merged.summary = first(text(book.summary)) { text($0.summary) }
        merged.language = first(text(book.language)) { text($0.language) }
        merged.isbn = first(text(book.isbn)) { text($0.isbn) }
        merged.asin = first(text(book.asin)) { text($0.asin) }
        return merged
    }
}
