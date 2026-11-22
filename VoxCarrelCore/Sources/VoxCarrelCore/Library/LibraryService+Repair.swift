import Foundation

extension LibraryService {
    /// Rewrites the length header of every MP3 of these books that is recorded as stating
    /// the wrong length (`BookFile.lengthProblem`) and can be repaired. Undoable as one
    /// operation: undo puts each file back byte for byte.
    ///
    /// Only the header in the file's first frame changes (`MP3HeaderRepair`), and a file
    /// is replaced only once its changed copy has passed every check; a file that fails
    /// one is left exactly as it was and is listed in the book's outcome with the reason.
    /// A file whose header is of a kind that cannot be rewritten is listed too.
    ///
    /// A repaired file has no length problem any more. The book's length is the sum of
    /// the measured lengths of its audio files, as it normally was already; a length that
    /// was recorded before a wrong header was known of is put right here.
    ///
    /// The outcome for a book lists the files that could not be repaired; an unknown id
    /// gives `.failed`. Nothing is recorded for undo when no file was changed.
    public func repairLengthHeaders(for bookIds: [Int64]) throws -> [SaveOutcome] {
        var operation = PendingOperation()
        var handled = Set<Int64>()
        var repairedFiles = 0
        // Rows to correct for books in which no file was changed: not an operation.
        var corrections: [(bookId: Int64, seconds: Double?, problems: [Int64: LengthProblem?])] = []

        enum Prepared {
            case failed(String)
            case done(appOnlyFields: [MetadataField], problems: [FileProblem])
        }
        let prepared = bookIds.map { bookId -> Prepared in
            guard handled.insert(bookId).inserted else {
                return .failed("That book is already being repaired by this call")
            }
            let book: Book
            let rows: [BookFile]
            let storedCoverBefore: String?
            do {
                guard let found = try store.book(id: bookId) else { throw LibraryError.bookNotFound(bookId) }
                book = found
                rows = try store.files(bookId: bookId)
                guard rows.contains(where: { $0.lengthProblem != nil }) else {
                    return .done(appOnlyFields: book.appOnlyFields, problems: [])
                }
                // Before any file is touched, so that a failure here changes nothing.
                storedCoverBefore = try saveStoredCoverForUndo(bookId: bookId, token: operation.token)
            } catch {
                handled.remove(bookId)
                return .failed(Self.reason(for: error))
            }

            var newRows = rows
            var repairs: [HeaderRepairState] = []
            var problems: [FileProblem] = []
            for index in rows.indices {
                guard let problem = rows[index].lengthProblem else { continue }
                let url = store.url(for: rows[index])
                let name = url.lastPathComponent
                func cannot(_ why: String) {
                    problems.append(FileProblem(
                        file: name,
                        reason: "The length header cannot be repaired: \(why). The file was left as it is"))
                }
                guard rows[index].format == .mp3, problem.repairable else {
                    cannot(MP3HeaderRepair.Refusal.noHeader.reason)
                    continue
                }
                do {
                    // Nil: the header states the right length already.
                    if let state = try headerRepair.repair(url) { repairs.append(state) }
                    newRows[index].lengthProblem = nil
                } catch let refusal as MP3HeaderRepair.Refusal {
                    cannot(refusal.reason)
                    newRows[index].lengthProblem?.repairable = false
                } catch {
                    problems.append(FileProblem(file: name, reason: Self.describe(error)))
                }
            }

            var updated = book
            if let total = measuredLength(of: rows), abs(total - (book.durationSeconds ?? 0)) > 0.5 {
                updated.durationSeconds = total
            }
            if !repairs.isEmpty {
                operation.add(
                    .init(book: updated, files: newRows),
                    snapshot: BookSnapshot(
                        bookId: bookId, bookBefore: book, filesBefore: rows, fileStates: [],
                        storedCoverBefore: storedCoverBefore, headerRepairs: repairs),
                    storedCover: .keep, records: [])
                repairedFiles += repairs.count
            } else if newRows != rows || updated.durationSeconds != book.durationSeconds {
                var changed: [Int64: LengthProblem?] = [:]
                for (old, new) in zip(rows, newRows) where old.lengthProblem != new.lengthProblem {
                    if let id = old.id { changed[id] = new.lengthProblem }
                }
                let seconds = updated.durationSeconds != book.durationSeconds ? updated.durationSeconds : nil
                corrections.append((bookId, seconds, changed))
            }
            return .done(appOnlyFields: book.appOnlyFields, problems: problems)
        }

        if repairedFiles > 0 {
            _ = try commit(
                operation,
                label: repairedFiles == 1
                    ? "Repair length header in 1 file" : "Repair length headers in \(repairedFiles) files")
        } else {
            removeUndoData(token: operation.token)
        }
        for correction in corrections {
            try store.setMeasuredLength(
                bookId: correction.bookId, durationSeconds: correction.seconds,
                lengthProblems: correction.problems)
        }
        return zip(bookIds, prepared).map { bookId, result in
            switch result {
            case .failed(let reason):
                return .failed(bookId: bookId, reason: reason)
            case .done(let fields, let problems):
                return .saved(bookId: bookId, refiled: false, appOnlyFields: Set(fields), fileProblems: problems)
            }
        }
    }

    /// The length of a book from its audio files as they were recorded before a repair:
    /// a file recorded as stating the wrong length counts for the length measured then
    /// (a repair does not change it), a file that could not be measured for the length
    /// it states, and every other file is read. Nil when a file cannot be read: a sum
    /// over some of the parts would be wrong.
    private func measuredLength(of rows: [BookFile]) -> Double? {
        var total = 0.0
        for row in rows where row.role == .audio {
            let url = store.url(for: row)
            if let problem = row.lengthProblem {
                total += problem.trueSeconds
            } else if let state = row.lengthUnmeasured, state.describes(fileAt: url) {
                total += state.statedSeconds
            } else if let seconds = (try? metadataIO.read(url))?.metadata.durationSeconds {
                total += seconds
            } else {
                return nil
            }
        }
        return total
    }
}
