import Foundation
import GRDB

// Edits made while the drive the books are on is away.
//
// The catalogue is on this Mac, so it can be changed; the files cannot be reached, so
// they cannot. An edit made then is held: the catalogue takes the change at once, and
// the book is noted as having files that are behind. When the drive is back,
// `applyHeldEdits` writes the details into the files and files the books where they now
// belong, as one operation.
//
// A held edit cannot be undone: what Undo needs is a copy of the files as they were,
// which it keeps on the books' own drive.

extension LibraryStore {
    /// The books with changes waiting for their files, each with whether its cover is
    /// one of the changes.
    public func heldEdits() throws -> [Int64: Bool] {
        try dbQueue.read { db in
            var found: [Int64: Bool] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT bookId, coverChanged FROM heldEdit") {
                found[row["bookId"]] = row["coverChanged"]
            }
            return found
        }
    }

    func hold(bookId: Int64, coverChanged: Bool, now: Date) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO heldEdit (bookId, coverChanged, since) VALUES (?, ?, ?)
                    ON CONFLICT(bookId) DO UPDATE SET coverChanged = heldEdit.coverChanged OR excluded.coverChanged
                    """,
                arguments: [bookId, coverChanged, now])
        }
    }

    func clearHeld(_ bookIds: [Int64]) throws {
        try dbQueue.write { db in
            for id in bookIds { try db.execute(sql: "DELETE FROM heldEdit WHERE bookId = ?", arguments: [id]) }
        }
    }
}

/// How catching up with held edits went.
public struct HeldEditsResult: Equatable, Sendable {
    /// Books whose files now have what the catalogue has.
    public var caughtUp: Int
    /// A sentence for each book that could not be written; it is still waiting.
    public var problems: [String]
}

extension LibraryService {
    /// How many books have changes waiting for their files.
    public func heldEditCount() throws -> Int {
        try store.heldEdits().count
    }

    /// Saves edits in the catalogue alone, because the files cannot be reached now.
    /// Each book that changed, and has files, is noted as waiting. An edit that
    /// changes nothing is reported as saved, as ever.
    func saveHeld(_ edits: [BookEdit], now: Date = Date()) throws -> [SaveOutcome] {
        var outcomes: [SaveOutcome] = []
        var changed: [Int64] = []
        for edit in edits {
            guard let book = try store.book(id: edit.bookId) else {
                outcomes.append(.failed(bookId: edit.bookId, reason: "That book is no longer in the library"))
                continue
            }
            var metadata = edit.metadata
            metadata.durationSeconds = book.durationSeconds
            metadata.pageCount = book.pageCount
            guard !metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                outcomes.append(.failed(bookId: edit.bookId, reason: "A book needs a title"))
                continue
            }
            let saved = SaveOutcome.saved(bookId: edit.bookId, refiled: false, appOnlyFields: [], fileProblems: [])
            if metadata == book.metadata, edit.cover == .keep, edit.tags == book.tags, edit.rating == book.rating,
               edit.editionKind == book.editionKind, edit.editionSuffix == book.editionSuffix {
                outcomes.append(saved)
                continue
            }
            var updated = book
            updated.metadata = metadata
            updated.editionSuffix = edit.editionSuffix
            updated.tags = edit.tags
            updated.rating = edit.rating
            updated.editionKind = edit.editionKind
            try store.update(updated)
            // The covers are kept beside the catalogue, on this Mac.
            switch edit.cover {
            case .keep: break
            case .remove: try? covers.remove(for: edit.bookId)
            case .set(let image): try? covers.set(image, for: edit.bookId)
            }
            // Only what goes into the files, or decides where they are filed, is owed
            // to them; and a book with no files is owed nothing.
            let owesFiles = metadata != book.metadata || edit.cover != .keep || edit.editionSuffix != book.editionSuffix
            if owesFiles, try !store.files(bookId: edit.bookId).isEmpty {
                try store.hold(bookId: edit.bookId, coverChanged: edit.cover != .keep, now: now)
            }
            changed.append(edit.bookId)
            outcomes.append(saved)
        }
        return outcomes
    }

    /// Gives the files what the catalogue has, for every book with changes waiting:
    /// their details are written into them, a changed cover with them, and each book
    /// is filed where it now belongs. One operation. A book that could not be written
    /// is still waiting afterwards. Does nothing while the books cannot be reached.
    @discardableResult
    public func applyHeldEdits() throws -> HeldEditsResult {
        guard store.booksAreReachable else { throw LibraryError.booksNotReachable }
        let held = try store.heldEdits()
        var edits: [BookEdit] = []
        var gone: [Int64] = []
        for (id, coverChanged) in held.sorted(by: { $0.key < $1.key }) {
            guard let book = try store.book(id: id) else {
                gone.append(id)
                continue
            }
            var cover = CoverChange.keep
            if coverChanged { cover = covers.image(for: id).map(CoverChange.set) ?? .remove }
            edits.append(BookEdit(book: book, cover: cover))
        }
        try store.clearHeld(gone)
        guard !edits.isEmpty else { return HeldEditsResult(caughtUp: 0, problems: []) }
        forcedWrites = Set(edits.map(\.bookId))
        defer { forcedWrites = [] }
        let outcomes = try save(edits) { count, _ in
            count == 1 ? "Catch up 1 book with changes made while its drive was away"
                : "Catch up \(count) books with changes made while their drive was away"
        }
        var result = HeldEditsResult(caughtUp: 0, problems: [])
        var done: [Int64] = []
        for outcome in outcomes {
            switch outcome {
            case .saved(let bookId, _, _, _):
                // Only those asked for: an edition named afresh beside them was not waiting.
                if held[bookId] != nil {
                    done.append(bookId)
                    result.caughtUp += 1
                }
            case .failed(let bookId, let reason):
                let title = (try? store.book(id: bookId))??.title ?? "A book"
                result.problems.append("“\(title)” is still waiting: \(reason)")
            }
        }
        try store.clearHeld(done)
        return result
    }
}
