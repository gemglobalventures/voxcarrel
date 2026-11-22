import Foundation

// What kind of edition a book is: unabridged, abridged or a dramatisation.
//
// The kind is kept in the catalogue only. Nothing here opens, moves or writes a file,
// and nothing here asks the network: what lookups found is handed in.

extension LibraryService {
    /// What a candidate's details and the names of its files and folders say about its
    /// edition, as it is imported. Only for a book with audio.
    static func statedEditionKind(of candidate: CandidateBook) -> EditionKindNote? {
        let audio = candidate.files.filter { $0.role == .audio }.map(\.url)
        guard !audio.isEmpty else { return nil }
        return EditionKindGuess.fromFiles(
            title: candidate.metadata.title, subtitle: candidate.metadata.subtitle, comment: candidate.metadata.summary,
            fileNames: Self.names(of: audio))
    }

    /// Whether the candidate's audio files are numbered with gaps, by the names they
    /// have before they are filed.
    static func partsAppearMissing(in candidate: CandidateBook) -> Bool {
        EditionKindGuess.partsAppearMissing(
            fileNames: candidate.files.filter { $0.role == .audio }.map(\.url.lastPathComponent))
    }

    /// The names of the files, without their extensions, and of the folders they are in.
    static func names(of files: [URL]) -> [String] {
        var names: [String] = []
        for file in files {
            let folder = file.deletingLastPathComponent().lastPathComponent
            for name in [file.deletingPathExtension().lastPathComponent, folder] where !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    /// What the book's own files say that bears on its edition. Reads the catalogue
    /// only; a book with no audio files has nothing to say.
    public func editionEvidence(for bookId: Int64) throws -> EditionEvidence {
        guard let book = try store.book(id: bookId) else { throw LibraryError.bookNotFound(bookId) }
        return editionEvidence(for: book, files: try store.files(bookId: bookId))
    }

    func editionEvidence(for book: Book, files: [BookFile]) -> EditionEvidence {
        let audio = files.filter { $0.role == .audio }
        guard !audio.isEmpty else { return EditionEvidence() }
        let urls = audio.map { store.url(for: $0) }
        // A length that could not be measured is only what the file says of itself.
        let measured = audio.allSatisfy { $0.lengthUnmeasured == nil }
        let seconds = book.durationSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return EditionEvidence(
            audioSeconds: measured ? seconds : nil,
            // As recorded at import, or as the names say now (a book catalogued where it
            // was found keeps its files' own names).
            partsAppearMissing: book.partsAppearMissing
                || EditionKindGuess.partsAppearMissing(fileNames: urls.map(\.lastPathComponent)),
            stated: EditionKindGuess.fromFiles(
                title: book.title, subtitle: book.subtitle, comment: book.summary, fileNames: Self.names(of: urls)))
    }

    /// What a check would make of the book's edition, given what a lookup found: the
    /// strongest of what the files say and what the results show. Changes nothing.
    public func assessEdition(of bookId: Int64, results: [LookupCandidate]) throws -> EditionKindAssessment {
        guard let book = try store.book(id: bookId) else { throw LibraryError.bookNotFound(bookId) }
        return assessEdition(of: book, files: try store.files(bookId: bookId), results: results)
    }

    private func assessEdition(of book: Book, files: [BookFile], results: [LookupCandidate]) -> EditionKindAssessment {
        let evidence = editionEvidence(for: book, files: files)
        let found = EditionKindGuess.assess(
            results, book: book.metadata, bookSeconds: evidence.audioSeconds,
            partsAppearMissing: evidence.partsAppearMissing)
        let note = EditionKindNote.stronger(evidence.stated, found.note)
        return EditionKindAssessment(note: note, remark: note == nil ? found.remark : nil)
    }

    /// Works out each book's edition kind from its files and from what a lookup found
    /// for it, and records it: one undoable operation, "Check edition of 3 books", that
    /// changes this one field of the books it changes and nothing else. No file is
    /// touched.
    ///
    /// A kind the user set by hand is never replaced, nor is one that is better founded
    /// than what the check found. A book named twice is checked once; an id that is not
    /// in the library is passed over.
    ///
    /// - Returns: One outcome for each book checked, in the order given.
    @discardableResult
    public func checkEditions(_ checks: [EditionCheck]) throws -> [EditionCheckOutcome] {
        var operation = PendingOperation()
        var outcomes: [EditionCheckOutcome] = []
        var seen = Set<Int64>()
        var title = ""
        for check in checks where seen.insert(check.bookId).inserted {
            guard let book = try store.book(id: check.bookId) else { continue }
            let files = try store.files(bookId: check.bookId)
            let assessment = assessEdition(of: book, files: files, results: check.results)
            guard let note = assessment.note, note.mayReplace(book.editionKind), note != book.editionKind else {
                outcomes.append(
                    EditionCheckOutcome(
                        bookId: check.bookId, kind: book.editionKind, changed: false, remark: assessment.remark))
                continue
            }
            var updated = book
            updated.editionKind = note
            // What undo needs: the stored cover is put back from here, or taken away.
            let storedCoverBefore: String?
            do {
                storedCoverBefore = try saveStoredCoverForUndo(bookId: check.bookId, token: operation.token)
            } catch {
                removeUndoData(token: operation.token)
                throw error
            }
            // The file rows are written back as the rows they were.
            var write = LibraryChange.BookWrite(book: updated, files: files)
            write.restoresFileIds = true
            operation.add(
                write,
                snapshot: BookSnapshot(
                    bookId: check.bookId, bookBefore: book, filesBefore: files, fileStates: [],
                    storedCoverBefore: storedCoverBefore),
                storedCover: .keep, records: [])
            title = book.title
            outcomes.append(EditionCheckOutcome(bookId: check.bookId, kind: note, changed: true))
        }

        let count = operation.writes.count
        guard count > 0 else {
            // Nothing to record: the journal and earlier undo data stay as they were.
            removeUndoData(token: operation.token)
            return outcomes
        }
        _ = try commit(operation, label: Self.checkEditionLabel(count: count, title: title))
        return outcomes
    }

    /// "Check edition of Salt Road", "Check edition of 3 books".
    static func checkEditionLabel(count: Int, title: String) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return count == 1 ? "Check edition of \(name.isEmpty ? "1 book" : name)" : "Check edition of \(count) books"
    }
}
