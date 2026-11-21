import Foundation
import GRDB

/// Everything one operation changes in the database, applied in a single transaction.
public struct LibraryChange: Sendable {
    public struct BookWrite: Sendable {
        /// `book.id == nil` inserts; otherwise updates that book.
        public var book: Book
        /// The complete new file list for the book (replaces any existing rows).
        public var files: [BookFile]

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
                    file.id = nil
                    file.bookId = book.id
                    try file.insert(db)
                }
                books.append(book)
            }

            var batchId: Int64?
            if let batch = change.batch {
                batchId = try Self.replaceJournal(
                    db, label: batch.label, moves: batch.moves, snapshot: batch.snapshot)
            } else if change.clearsJournal {
                try Self.clearJournal(db)
            }
            return (books, batchId)
        }
    }
}
