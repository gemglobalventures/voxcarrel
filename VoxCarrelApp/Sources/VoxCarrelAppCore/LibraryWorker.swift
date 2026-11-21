import Foundation
import VoxCarrelCore

/// Owns the library engine and runs it off the main thread, one call at a time.
///
/// `LibraryService` blocks while it moves and re-tags files and must never be called by
/// two threads at once; an actor gives both. Everything that crosses into or out of the
/// worker is a plain value.
public actor LibraryWorker {
    public nonisolated let libraryRoot: URL

    private let service: LibraryService
    private var store: LibraryStore { service.store }

    /// Opens (creating if new) the library at `libraryRoot`.
    ///
    /// - Parameter trashItem: How a removed book's file is sent to the Trash; nil for
    ///   the system's Trash. Tests give a folder of their own.
    public init(libraryRoot: URL, trashItem: (@Sendable (URL) throws -> Void)? = nil) throws {
        self.libraryRoot = libraryRoot
        let store = try LibraryStore(libraryRoot: libraryRoot)
        self.service = trashItem.map { LibraryService(store: store, trashItem: $0) } ?? LibraryService(store: store)
    }

    // MARK: Reading

    /// The item's books in the store's order (by title), narrowed to those that match
    /// `search` when it is not blank.
    public func rows(for item: SidebarItem, search: String) throws -> [BookRow] {
        var books = try self.books(for: item)
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // W2: text with nothing searchable in it matches nothing.
            let matching = Set(try store.search(search).compactMap(\.id))
            books = books.filter { $0.id.map(matching.contains) ?? false }
        }
        // W3: one read of every file row, however many books there are.
        let files = Dictionary(grouping: try store.allFiles(), by: \.bookId)
        return books.compactMap { book in
            book.id.map { row(for: book, id: $0, files: files[$0] ?? []) }
        }
    }

    public func sidebar() throws -> SidebarData {
        var counts: [SidebarItem: Int] = [:]
        for item in SidebarItem.fixed {
            counts[item] = try books(for: item).count
        }
        var browse: [BrowseField: [String]] = [:]
        for field in BrowseField.allCases {
            browse[field] = try store.distinctValues(field)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        return SidebarData(counts: counts, browse: browse, collections: try store.collections())
    }

    /// The book and its files as they are now; nil when no book has that id.
    public func detail(bookId: Int64) throws -> BookDetail? {
        guard let book = try store.book(id: bookId) else { return nil }
        let files = try store.files(bookId: bookId)
        let fileRows = files.compactMap { file -> FileRow? in
            guard let id = file.id else { return nil }
            let url = store.url(for: file)
            return FileRow(
                id: id, file: file, url: url, name: url.lastPathComponent,
                isMissing: !FileManager.default.fileExists(atPath: url.path),
                allowedRoles: FileRow.allowedRoles(for: file.format))
        }
        let firstAudio = files.first { $0.role == .audio }.map { store.url(for: $0) }
        let chapters = firstAudio.flatMap { try? FileMetadataIO().read($0).chapters } ?? []
        var collectionIds = Set<Int64>()
        for collection in try store.collections() {
            guard let id = collection.id else { continue }
            if try store.books(inCollection: id).contains(where: { $0.id == bookId }) {
                collectionIds.insert(id)
            }
        }
        return BookDetail(
            row: row(for: book, id: bookId, files: files), files: fileRows, chapterCount: chapters.count,
            collectionIds: collectionIds)
    }

    public func plannedFolder(for metadata: BookMetadata) -> String? {
        service.plannedFolder(for: metadata)
    }

    private func books(for item: SidebarItem) throws -> [Book] {
        switch item {
        case .allBooks: try store.books()
        case .audiobooks: try store.books(having: .audio)
        case .ebooks: try store.books(having: .ebook)
        case .unread: try store.books(readStatus: .unread)
        case .inProgress: try store.books(readStatus: .inProgress)
        case .finished: try store.books(readStatus: .finished)
        case .needsAttention: try store.books(needsAttention: true)
        case .browse(let field, let value): try store.books(where: field, equals: value)
        case .collection(let id): try store.books(inCollection: id)
        }
    }

    private func row(for book: Book, id: Int64, files: [BookFile]) -> BookRow {
        var formats: [FileFormat] = []
        for file in files where file.role != .extra && !formats.contains(file.format) {
            formats.append(file.format)
        }
        let cover = service.covers.url(for: id)
        let coverModified = cover.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return BookRow(
            id: id, book: book,
            hasAudio: files.contains { $0.role == .audio },
            hasEbook: files.contains { $0.role == .ebook },
            formats: formats,
            coverURL: cover,
            coverModified: coverModified,
            hasWriteProblem: files.contains { $0.writeProblem != nil },
            // A file left where it was found is recorded by its whole path.
            outsideFiles: files.filter { $0.path.hasPrefix("/") }.map { store.url(for: $0).path })
    }

    /// For each half-moved file, the name of the file it very likely was: the one file
    /// of a library book that is missing from the folder it lies in, when that folder
    /// has exactly one missing file and one half-moved file. (A file is set aside under
    /// a hidden name in the folder it was going to, which is most often its own.)
    public func likelyNames(ofStranded files: [URL]) throws -> [URL: String] {
        guard !files.isEmpty else { return [:] }
        func folder(_ url: URL) -> String {
            url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        }
        var missing: [String: [String]] = [:]
        for row in try store.allFiles() {
            let url = store.url(for: row)
            if !FileManager.default.fileExists(atPath: url.path) {
                missing[folder(url), default: []].append(url.lastPathComponent)
            }
        }
        let stranded = Dictionary(grouping: files, by: folder)
        var names: [URL: String] = [:]
        for (place, here) in stranded where here.count == 1 {
            if let gone = missing[place], gone.count == 1 { names[here[0]] = gone[0] }
        }
        return names
    }

    // MARK: Importing

    /// Scans what was dropped. Each candidate comes with the cover of its first audio or
    /// ebook file that has one (a file that cannot be read has none) and the library book
    /// it most likely belongs to.
    public func prepareImport(_ urls: [URL]) throws -> (seeds: [ImportSeed], skipped: [URL]) {
        let scan = service.scan(urls)
        let reader = FileMetadataIO()
        let seeds = try scan.candidates.map { candidate in
            let cover = candidate.files.lazy
                .filter { $0.role != .extra }
                .compactMap { (try? reader.read($0.url))?.cover }
                .first
            return ImportSeed(
                candidate: candidate, cover: cover, existingMatch: try service.existingMatch(for: candidate))
        }
        return (seeds, scan.skipped)
    }

    /// As `prepareImport(_:)` for files found loose in the library folder: a folder in
    /// which no library book has a file is scanned as a folder (`UntrackedInputs`), so
    /// that the parts of one audiobook are one candidate.
    public func prepareImport(untracked files: [URL]) throws -> (seeds: [ImportSeed], skipped: [URL]) {
        let tracked = try store.allFiles().map { store.url(for: $0) }
        return try prepareImport(
            UntrackedInputs.grouped(untracked: files, tracked: tracked, root: store.libraryRoot))
    }

    /// Whether every one of these files is inside the library folder, however it is spelled.
    public func areInsideLibrary(_ files: [URL]) -> Bool {
        files.allSatisfy { !store.storedPath(for: $0).hasPrefix("/") }
    }

    /// The library book a candidate with these details would be added to; nil when
    /// no book has that title and first author.
    public func existingMatch(for metadata: BookMetadata) throws -> Book? {
        try service.existingMatch(for: CandidateBook(files: [], metadata: metadata))
    }

    public func importItems(_ items: [ImportItem], options: ImportOptions) throws -> ImportResult {
        try service.importItems(items, options: options)
    }

    // MARK: Changing

    public func save(_ edits: [BookEdit]) throws -> [SaveOutcome] {
        try service.save(edits)
    }

    public func rewriteTags(for bookIds: [Int64]) throws -> [SaveOutcome] {
        try service.rewriteTags(for: bookIds)
    }

    public func setRole(_ role: FileRole, forFile fileId: Int64) throws {
        try service.setRole(role, forFile: fileId)
    }

    public func setReadStatus(_ status: ReadStatus, for bookIds: [Int64]) throws {
        try service.setReadStatus(status, for: bookIds)
    }

    /// Removes each in turn; returns the ids that could not be removed, with why.
    public func removeBooks(ids: [Int64], moveFilesToTrash: Bool) -> [(id: Int64, reason: String)] {
        var failures: [(id: Int64, reason: String)] = []
        for id in ids {
            do {
                try service.removeBook(id: id, moveFilesToTrash: moveFilesToTrash)
            } catch {
                failures.append((id, UserMessage.text(for: error)))
            }
        }
        return failures
    }

    public func locateFile(fileId: Int64, at url: URL) throws {
        try service.locateFile(fileId: fileId, at: url)
    }

    public func undoLabel() throws -> String? {
        try service.undoLabel()
    }

    public func undoLast() throws -> String {
        try service.undoLast()
    }

    public func reconcile() throws -> ReconcileReport {
        try service.reconcile()
    }

    // MARK: Collections

    public func createCollection(name: String) throws -> BookCollection {
        try store.createCollection(name: name)
    }

    public func renameCollection(id: Int64, to name: String) throws {
        try store.renameCollection(id: id, to: name)
    }

    public func deleteCollection(id: Int64) throws {
        try store.deleteCollection(id: id)
    }

    public func add(bookIds: [Int64], toCollection id: Int64) throws {
        for bookId in bookIds {
            try store.add(bookId: bookId, toCollection: id)
        }
    }

    public func remove(bookIds: [Int64], fromCollection id: Int64) throws {
        for bookId in bookIds {
            try store.remove(bookId: bookId, fromCollection: id)
        }
    }
}
