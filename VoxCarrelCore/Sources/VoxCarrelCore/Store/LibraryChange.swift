import Foundation
import GRDB

/// Everything one operation changes in the database, applied in a single transaction.
public struct LibraryChange: Sendable {
    public struct BookWrite: Sendable {
        /// `book.id == nil` inserts; otherwise updates that book.
        public var book: Book
        /// The complete new file list for the book (replaces any existing rows).
        public var files: [BookFile]
        /// For undo: insert the file rows under the ids they carry instead of fresh ones,
        /// so that a restored book's files are the rows they were. The ids must be free.
        var restoresFileIds = false

        public init(book: Book, files: [BookFile]) {
            self.book = book
            self.files = files
        }
    }

    public var writes: [BookWrite] = []
    public var deletedBookIds: [Int64] = []
    /// When set, replaces the whole journal with this one batch.
    public var batch: Batch?
    /// When true, empties the journal (used after an undo).
    public var clearsJournal = false
    /// For undo of an import by copy: files under watch folders that are no longer
    /// imported. The inbox ledger's `imported` entries for them are deleted; an entry
    /// of another kind stays.
    var forgottenImports: [ForgottenImport] = []

    struct ForgottenImport: Sendable {
        var folderId: Int64
        /// As the folder's listing spells it.
        var path: String
    }

    public struct Batch: Sendable {
        public var label: String
        public var moves: [MoveRecord]
        /// Opaque to the store; the service's undo data as JSON.
        public var snapshot: Data?

        public init(label: String, moves: [MoveRecord], snapshot: Data?) {
            self.label = label
            self.moves = moves
            self.snapshot = snapshot
        }
    }

    public init() {}
}

extension LibraryStore {
    /// Applies the change atomically. Returns the written books (with ids) in the
    /// order of `writes`, and the new batch id if a batch was recorded.
    ///
    /// Deletions are made first, then the writes, then the journal change. Deleting an id
    /// that is not in the database does nothing; updating one throws, and then nothing at
    /// all is changed.
    @discardableResult
    public func apply(_ change: LibraryChange) throws -> (books: [Book], batchId: Int64?) {
        try apply(change, snapshot: nil)
    }

    /// As `apply(_:)`, for a caller whose undo data must name books that this very change
    /// creates. When the change records a batch and `snapshot` is given, it is called inside
    /// the transaction with the written books (ids assigned, in the order of `writes`) and
    /// its result is stored as the batch's snapshot in place of `change.batch.snapshot`.
    /// If it throws, nothing is changed.
    @discardableResult
    func apply(
        _ change: LibraryChange, snapshot makeSnapshot: (([Book]) throws -> Data?)?
    ) throws -> (books: [Book], batchId: Int64?) {
        try dbQueue.write { db in
            if !change.deletedBookIds.isEmpty {
                try Book.deleteAll(db, keys: change.deletedBookIds)
            }

            var books: [Book] = []
            for write in change.writes {
                var book = write.book
                if book.id == nil {
                    try book.insert(db)
                } else {
                    try book.update(db)
                }
                try BookFile.filter(Column("bookId") == book.id).deleteAll(db)
                for var file in write.files {
                    if !write.restoresFileIds { file.id = nil }
                    file.bookId = book.id
                    try file.insert(db)
                }
                books.append(book)
            }

            for file in change.forgottenImports {
                try InboxEntryRecord
                    .filter(
                        Column("folderId") == file.folderId && Column("path") == file.path
                            && Column("state") == InboxEntryState.imported.rawValue)
                    .deleteAll(db)
            }

            var batchId: Int64?
            if let batch = change.batch {
                let snapshot = try makeSnapshot.map { try $0(books) } ?? batch.snapshot
                batchId = try Self.replaceJournal(
                    db, label: batch.label, moves: batch.moves, snapshot: snapshot)
            } else if change.clearsJournal {
                try Self.clearJournal(db)
            }
            return (books, batchId)
        }
    }
}
