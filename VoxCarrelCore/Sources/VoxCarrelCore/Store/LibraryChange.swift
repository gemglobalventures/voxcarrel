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
    /// When set, this batch is added to the journal as its newest: the one Undo
    /// reverses next. The journal keeps the newest `LibraryStore.journalLimit` batches.
    public var batch: Batch?
    /// When true, empties the journal: no earlier operation can be undone any more.
    public var clearsJournal = false
    /// When set, takes this batch out of the journal and every batch before it: an
    /// operation that cannot be undone has changed a book this batch is about.
    public var cutsJournalThrough: Int64?
    /// When true, takes the newest batch out of the journal, the one an undo has just
    /// reversed: the batch before it is then the newest.
    public var popsJournal = false
    /// When set, the library's folder pattern is stored (or, with no text, forgotten)
    /// in the same transaction as everything else.
    var folderPattern: FolderPatternWrite?

    struct FolderPatternWrite: Sendable {
        /// The pattern's text; nil stores none, which means the standard pattern.
        var text: String?
    }

    /// For undo of an import by copy: files under watch folders that are no longer
    /// imported. The inbox ledger's `imported` entries for them are deleted; an entry
    /// of another kind stays.
    var forgottenImports: [ForgottenImport] = []

    struct ForgottenImport: Sendable {
        var folderId: Int64
        /// As the folder's listing spells it.
        var path: String
    }

    /// For undo of a merge: entries the merge removed, put back under the ids they
    /// carry, and their file rows under theirs. The ids must be free. They are put
    /// back before anything else is done.
    var restoredBooks: [BookWrite] = []

    /// Sent records that become another book's, by their row ids. Made after
    /// `restoredBooks` and before any book is deleted, so that a record never goes
    /// with a book that is removed. A row that is no longer there is passed over.
    var sentRecordMoves: [SentRecordMove] = []

    struct SentRecordMove: Sendable {
        var recordIds: [Int64]
        var toBookId: Int64
    }

    /// Books put in collections. A membership that is already there stays, and one in
    /// a collection that no longer exists is passed over.
    var membershipsAdded: [Membership] = []
    /// Books taken out of collections.
    var membershipsRemoved: [Membership] = []

    struct Membership: Sendable {
        var collectionId: Int64
        var bookId: Int64
    }

    public struct Batch: Sendable {
        public var label: String
        public var moves: [MoveRecord]
        /// Opaque to the store; the service's undo data as JSON.
        public var snapshot: Data?
        /// False for an operation after which no earlier one can be undone (a change
        /// of folder layout, which moves every book): the journal then holds it alone.
        public var keepsEarlier = true

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
    /// Entries a merge removed are put back first (undo only), then sent records and
    /// collection memberships change hands; then
    /// deletions are made, then the writes, then the journal change. Deleting an id
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
            for restored in change.restoredBooks {
                var book = restored.book
                try book.insert(db)
                for var file in restored.files {
                    file.bookId = book.id
                    try file.insert(db)
                }
            }
            for move in change.sentRecordMoves {
                for id in move.recordIds {
                    try db.execute(
                        sql: "UPDATE sentRecord SET bookId = ? WHERE id = ?", arguments: [move.toBookId, id])
                }
            }
            for membership in change.membershipsAdded {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO collectionBook (collectionId, bookId)
                        SELECT ?, ? WHERE EXISTS (SELECT 1 FROM collection WHERE id = ?)
                        """,
                    arguments: [membership.collectionId, membership.bookId, membership.collectionId])
            }
            for membership in change.membershipsRemoved {
                try db.execute(
                    sql: "DELETE FROM collectionBook WHERE collectionId = ? AND bookId = ?",
                    arguments: [membership.collectionId, membership.bookId])
            }

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

            if let pattern = change.folderPattern {
                try Self.setFolderPatternText(db, pattern.text)
            }

            var batchId: Int64?
            if let batch = change.batch {
                let snapshot = try makeSnapshot.map { try $0(books) } ?? batch.snapshot
                batchId = try Self.replaceJournal(
                    db, label: batch.label, moves: batch.moves, snapshot: snapshot,
                    keepingEarlier: batch.keepsEarlier && !change.clearsJournal)
            } else if change.clearsJournal {
                try Self.clearJournal(db)
            } else if change.popsJournal {
                try Self.popJournal(db)
            } else if let through = change.cutsJournalThrough {
                try db.execute(sql: "DELETE FROM operationBatch WHERE id <= ?", arguments: [through])
            }
            return (books, batchId)
        }
    }
}
