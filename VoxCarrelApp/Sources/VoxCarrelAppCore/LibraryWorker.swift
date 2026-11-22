import Foundation
import os
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
    /// What books are looked up with. Not part of the library, and not behind the
    /// actor: a lookup waits on the network and must not keep the library waiting.
    private nonisolated let lookup: OSAllocatedUnfairLock<LookupService>
    /// The ids the worker was asked about that are no book's: zero or less. A row that
    /// stands for a book the library does not have has such an id, and nothing should
    /// ever ask the library about it; whatever does is passed over and noted here.
    public nonisolated let strayIds = OSAllocatedUnfairLock<[Int64]>(initialState: [])

    /// Opens (creating if new) the library at `libraryRoot`.
    ///
    /// - Parameters:
    ///   - trashItem: How a removed book's file is sent to the Trash; nil for the
    ///     system's Trash. Tests give a folder of their own.
    ///   - lookup: What books are looked up with; nil for Open Library and the Audible
    ///     store of the Mac's region, over the network. Tests give fakes.
    public init(
        libraryRoot: URL, trashItem: (@Sendable (URL) throws -> Void)? = nil, lookup: LookupService? = nil
    ) throws {
        self.libraryRoot = libraryRoot
        let store = try LibraryStore(libraryRoot: libraryRoot)
        self.service = trashItem.map { LibraryService(store: store, trashItem: $0) } ?? LibraryService(store: store)
        self.lookup = OSAllocatedUnfairLock(
            initialState: lookup ?? .standard(
                LookupConfiguration(
                    sources: [.openLibrary, .audible],
                    audibleStores: [.forRegion(Locale.current.region?.identifier)])))
    }

    // MARK: Looking up online

    // None of these touches the library, and none runs on the actor: the library goes
    // on answering while a source is slow.

    /// Replaces what books are looked up with: for when the lookup settings change (the
    /// sources that are on, the Audible stores).
    public nonisolated func setLookupService(_ service: LookupService) {
        lookup.withLock { $0 = service }
    }

    /// Never throws; a search whose task is cancelled comes back looking like no matches.
    /// `sources`: the only sources to ask; nil for all of them. `book`: the book the
    /// search is for, so that results are judged and ranked against it; nil for none.
    public nonisolated func lookUp(
        _ query: LookupQuery, preferAudio: Bool, language: String?, sources: Set<LookupSource>? = nil,
        book: LookupBookContext? = nil
    ) async -> LookupResults {
        await lookup.withLock { $0 }.search(
            query, preferAudio: preferAudio, language: language, sources: sources, book: book)
    }

    public nonisolated func lookupDetails(for candidate: LookupCandidate) async throws -> LookupCandidate {
        try await lookup.withLock { $0 }.details(for: candidate)
    }

    public nonisolated func lookupCover(for candidate: LookupCandidate) async throws -> CoverImage {
        try await lookup.withLock { $0 }.cover(for: candidate)
    }

    /// The smaller picture of the candidate's cover, for its row in the results.
    public nonisolated func lookupThumbnail(for candidate: LookupCandidate) async throws -> CoverImage {
        try await lookup.withLock { $0 }.thumbnail(for: candidate)
    }

    /// The Audible series a book is in. Empty, and nothing is sent, when Audible is off
    /// as a lookup source (`LookupService.audibleSeries`).
    public nonisolated func audibleSeries(
        ofBookWithASIN asin: String?, title: String, author: String?
    ) async throws -> [AudibleSeriesRef] {
        try await lookup.withLock { $0 }.audibleSeries(ofBookWithASIN: asin, title: title, author: author)
    }

    /// Every book of an Audible series, asked of the series' own store.
    public nonisolated func audibleSeriesList(_ series: AudibleSeriesRef) async throws -> AudibleSeriesList {
        try await lookup.withLock { $0 }.audibleSeriesList(series)
    }

    // MARK: Ids that are no book's

    /// Whether `id` could be a book's. One that could not is noted in `strayIds`.
    private func isBookId(_ id: Int64) -> Bool {
        if id > 0 { return true }
        strayIds.withLock { $0.append(id) }
        return false
    }

    /// The ids that could be books', in the order given; the others are noted and left out.
    private func bookIds(_ ids: [Int64]) -> [Int64] {
        ids.filter(isBookId)
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

    /// The item's books and, when the item is one series, what the catalogue holds
    /// about that series (plan 9, SV5, SV13): read in one turn, so that the books and
    /// the list are of the same moment. Asks nothing of the network.
    public func shownBooks(for item: SidebarItem, search: String) throws -> ShownBooks {
        let rows = try self.rows(for: item, search: search)
        guard case .browse(.series, let name) = item else { return ShownBooks(rows: rows, series: nil) }
        let books = try service.librarySeriesBooks(named: name)
        return ShownBooks(
            rows: rows,
            series: ShownSeries(
                name: name, completeness: try service.seriesCompleteness(forSeries: name),
                bookIds: Set(books.map(\.id))))
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
        guard isBookId(bookId), let book = try store.book(id: bookId) else { return nil }
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

    /// The folder a book that has no files yet would be filed in if these were its
    /// first files: from its details, with what they lack read from the files.
    public func plannedFolder(for metadata: BookMetadata, firstFiles: [CandidateFile]) -> String? {
        service.plannedFolder(for: metadata, firstFiles: firstFiles)
    }

    private func books(for item: SidebarItem) throws -> [Book] {
        switch item {
        case .allBooks: try store.books()
        case .audiobooks: try store.books(having: .audio)
        case .ebooks: try store.books(having: .ebook)
        case .onAudible: try store.books(ownedOn: .audible)
        case .unread: try store.books(readStatus: .unread)
        case .inProgress: try store.books(readStatus: .inProgress)
        case .finished: try store.books(readStatus: .finished)
        case .needsAttention: try store.books(needsAttention: true)
        case .browse(let field, let value): try store.books(where: field, equals: value)
        case .collection(let id): try store.books(inCollection: id)
        // The inbox lists arrivals, which are not yet books.
        case .inbox: []
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
            // As the store lists them: a book owned elsewhere as an audiobook is one.
            hasAudio: files.contains { $0.role == .audio } || book.externalCopies.contains { $0.form == .audio },
            hasEbook: files.contains { $0.role == .ebook } || book.externalCopies.contains { $0.form == .ebook },
            formats: formats,
            coverURL: cover,
            coverModified: coverModified,
            hasWriteProblem: files.contains { $0.writeProblem != nil },
            // A file left where it was found is recorded by its whole path.
            outsideFiles: files.filter { $0.path.hasPrefix("/") }.map { store.url(for: $0).path },
            hasFiles: !files.isEmpty,
            lengthProblemFiles: files.filter { $0.lengthProblem != nil }.count,
            repairableLengthFiles: files.filter { $0.lengthProblem?.repairable == true }.count,
            unmeasuredLengthFiles: files.filter { $0.lengthUnmeasured != nil }.count)
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
        let seeds = try scan.candidates.map { try seed(for: $0, reader: reader) }
        return (seeds, scan.skipped)
    }

    /// The candidate with what the review shows beside it.
    private func seed(for candidate: CandidateBook, reader: FileMetadataIO) throws -> ImportSeed {
        let cover = candidate.files.lazy
            .filter { $0.role != .extra }
            .compactMap { (try? reader.read($0.url))?.cover }
            .first
        return ImportSeed(
            candidate: candidate, cover: cover, existingMatch: try service.existingMatch(for: candidate),
            measuredAudio: Self.measuredAudio(of: candidate, reader: reader))
    }

    /// The length of the candidate's audio when it is one file whose length could be
    /// measured. The parts of a book in several files are not read here.
    private static func measuredAudio(of candidate: CandidateBook, reader: FileMetadataIO) -> MeasuredAudio? {
        let audio = candidate.files.filter { $0.role == .audio }
        guard audio.count == 1, let contents = try? reader.read(audio[0].url), !contents.lengthCouldNotBeMeasured,
              let seconds = contents.metadata.durationSeconds, seconds.isFinite, seconds > 0
        else { return nil }
        return MeasuredAudio(file: audio[0].url, seconds: seconds)
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

    /// The library book a candidate with these details would be added to: the one with
    /// the same Audible ID, else the same title and first author; nil when neither.
    public func existingMatch(for metadata: BookMetadata) throws -> Book? {
        try service.existingMatch(for: metadata)
    }

    public func importItems(_ items: [ImportItem], options: ImportOptions) throws -> ImportResult {
        try service.importItems(items, options: options)
    }

    // MARK: Changing

    public func save(_ edits: [BookEdit]) throws -> [SaveOutcome] {
        let edits = edits.filter { isBookId($0.bookId) }
        guard !edits.isEmpty else { return [] }
        return try service.save(edits)
    }

    public func rewriteTags(for bookIds: [Int64]) throws -> [SaveOutcome] {
        let ids = self.bookIds(bookIds)
        guard !ids.isEmpty else { return [] }
        return try service.rewriteTags(for: ids)
    }

    public func repairLengthHeaders(for bookIds: [Int64]) throws -> [SaveOutcome] {
        let ids = self.bookIds(bookIds)
        guard !ids.isEmpty else { return [] }
        return try service.repairLengthHeaders(for: ids)
    }

    public func setRole(_ role: FileRole, forFile fileId: Int64) throws {
        try service.setRole(role, forFile: fileId)
    }

    public func setReadStatus(_ status: ReadStatus, for bookIds: [Int64]) throws {
        let ids = self.bookIds(bookIds)
        guard !ids.isEmpty else { return }
        try service.setReadStatus(status, for: ids)
    }

    // MARK: Editions

    /// What the book's own files say that bears on which edition it is. Reads the
    /// catalogue only.
    public func editionEvidence(for bookId: Int64) throws -> EditionEvidence {
        guard isBookId(bookId) else { throw LibraryError.bookNotFound(bookId) }
        return try service.editionEvidence(for: bookId)
    }

    /// What a check of the book's edition would come to, given what a lookup found.
    /// Changes nothing.
    public func assessEdition(of bookId: Int64, results: [LookupCandidate]) throws -> EditionKindAssessment {
        guard isBookId(bookId) else { throw LibraryError.bookNotFound(bookId) }
        return try service.assessEdition(of: bookId, results: results)
    }

    /// Records each book's edition kind, worked out from its files and from what a
    /// lookup found for it, as one undoable operation (`LibraryService.checkEditions`).
    public func checkEditions(_ checks: [EditionCheck]) throws -> [EditionCheckOutcome] {
        let real = checks.filter { isBookId($0.bookId) }
        // A check of no books at all is still a check, as it was before; one of nothing
        // but ids that are no book's is not.
        guard !real.isEmpty || checks.isEmpty else { return [] }
        return try service.checkEditions(real)
    }

    /// Adds a book that is owned elsewhere and has no files here, or, when the library
    /// has the book already, gives that book the copy (`LibraryService.addExternalBook`).
    public func addExternalBook(
        metadata: BookMetadata, cover: CoverImage?, copy: ExternalCopy
    ) throws -> ExternalBookOutcome {
        try service.addExternalBook(metadata: metadata, cover: cover, copy: copy)
    }

    /// Marks each book as owned on Audible, or takes the mark away. Only the catalogue
    /// changes, and it is not an operation Undo reverses.
    ///
    /// Marking gives a book that is not on Audible yet an Audible copy as an audiobook,
    /// in `store`, with the book's own ASIN when it has one; a book that is marked
    /// already is left exactly as it is. Unmarking takes away every Audible copy.
    ///
    /// - Returns: The books that were left marked because they have no files, and with
    ///   no mark would be empty entries. Ids that are not in the library are passed over.
    public func setOnAudible(_ on: Bool, for bookIds: [Int64], store audibleStore: AudibleStore) throws -> [Int64] {
        var refused: [Int64] = []
        for id in self.bookIds(bookIds) {
            guard let book = try store.book(id: id), book.isOwned(on: .audible) != on else { continue }
            var copies = book.externalCopies
            if on {
                copies.append(
                    ExternalCopy(
                        kind: .audible, form: .audio, store: audibleStore.rawValue, itemId: book.asin?.trimmedOrNil))
            } else {
                copies.removeAll { $0.kind == .audible }
            }
            do {
                try service.setExternalCopies(copies, for: id)
            } catch LibraryError.wouldLeaveNothing {
                refused.append(id)
            }
        }
        return refused
    }

    /// Removes each in turn; returns the ids that could not be removed, with why.
    public func removeBooks(ids: [Int64], moveFilesToTrash: Bool) -> [(id: Int64, reason: String)] {
        var failures: [(id: Int64, reason: String)] = []
        for id in bookIds(ids) {
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

    // MARK: Series

    // The series is named exactly as the sidebar names it. None of these is undone by
    // Undo, and none touches a file.

    /// The books of a series as Check Series asks Audible about them, by id.
    public func seriesCheckBooks(named name: String) throws -> [SeriesCheckBook] {
        try service.librarySeriesBooks(named: name).map { book in
            let author = try store.book(id: book.id)?.authors.lazy.compactMap(\.trimmedOrNil).first
            return SeriesCheckBook(
                id: book.id, title: book.title, author: author, number: book.number, asin: book.asins.first)
        }
    }

    public func saveSeriesList(_ list: AudibleSeriesList, forSeries name: String, now: Date) throws {
        try service.saveSeriesList(list, forSeries: name, now: now)
    }

    /// Hides a missing entry of a stored list, or shows it again. `id` is the entry's
    /// own (`MissingEntry.id`), not its row's.
    public func setMissingEntry(id: Int64, hidden: Bool) throws {
        try service.setMissingEntry(id: id, hidden: hidden)
    }

    public func unlinkSeries(named name: String) throws {
        try service.unlinkSeries(named: name)
    }

    /// One edit for each book of the series that Audible numbers differently: to be
    /// saved with `save`.
    public func editsUsingAudibleNumbers(forSeries name: String) throws -> [BookEdit] {
        try service.editsUsingAudibleNumbers(forSeries: name)
    }

    // MARK: Watch folders and the inbox

    public func watchFolders() throws -> [WatchFolder] {
        try service.watchFolders()
    }

    /// Starts watching a folder; returns every watch folder as they are then.
    public func addWatchFolder(_ url: URL, now: Date) throws -> [WatchFolder] {
        try service.addWatchFolder(url, now: now)
        return try service.watchFolders()
    }

    /// Changes the settings of the watch folder as it is stored at this moment, so
    /// that two changes made one straight after the other both hold. Returns every
    /// watch folder as they are then.
    public func updateWatchFolder(
        id: Int64, _ change: @Sendable (inout WatchFolder) -> Void
    ) throws -> [WatchFolder] {
        guard var folder = try service.watchFolders().first(where: { $0.id == id }) else {
            throw WatchFolderError.notFound(id)
        }
        change(&folder)
        try service.updateWatchFolder(folder)
        return try service.watchFolders()
    }

    /// Stops watching a folder; returns the watch folders that are left.
    public func removeWatchFolder(id: Int64) throws -> [WatchFolder] {
        try service.removeWatchFolder(id: id)
        return try service.watchFolders()
    }

    public func scanExisting(inWatchFolder id: Int64) throws {
        try service.scanExisting(inWatchFolder: id)
    }

    /// Looks into the watch folders. The engine remembers, from check to check, what
    /// it saw and the tags it read: every check of a library is made here.
    public func checkInbox(now: Date) throws -> InboxReport {
        try service.checkInbox(now: now)
    }

    public func dismissArrivals(ids: [String]) throws {
        try service.dismissArrivals(ids: ids)
    }

    public func recordImported(_ files: [URL]) throws {
        try service.recordImported(files)
    }

    /// As `prepareImport(_:)` for books that arrived in a watch folder, each already
    /// grouped as the Inbox shows it: the candidates are taken as they are, not
    /// scanned again, so that a folder of parts stays one book. A candidate with a
    /// file that is no longer there is left out.
    public func prepareImport(candidates: [CandidateBook]) throws -> [ImportSeed] {
        let reader = FileMetadataIO()
        return try candidates
            .filter { $0.files.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) } }
            .map { try seed(for: $0, reader: reader) }
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
        for bookId in self.bookIds(bookIds) {
            try store.add(bookId: bookId, toCollection: id)
        }
    }

    public func remove(bookIds: [Int64], fromCollection id: Int64) throws {
        for bookId in self.bookIds(bookIds) {
            try store.remove(bookId: bookId, fromCollection: id)
        }
    }
}
