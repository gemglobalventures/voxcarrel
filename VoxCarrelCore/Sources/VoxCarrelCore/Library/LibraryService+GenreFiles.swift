import Foundation

extension LibraryService {
    /// A book whose files hold another genre tag than the library would write.
    public struct GenreFileDifference: Equatable, Sendable, Identifiable {
        public var id: Int64
        public var title: String
        /// How many of the book's files can hold a genre: the ones that would be written.
        public var fileCount: Int
        /// The genre tag the files hold, as last recorded; nil for none.
        public var tagNow: String?
        /// The tag that would be written; nil when it would be removed.
        public var tagAfter: String?

        public init(id: Int64, title: String, fileCount: Int, tagNow: String?, tagAfter: String?) {
            self.id = id
            self.title = title
            self.fileCount = fileCount
            self.tagNow = tagNow
            self.tagAfter = tagAfter
        }
    }

    /// The books whose files hold another genre tag than their genres would be written
    /// as, sorted by title. No file is opened: what the files hold is what the
    /// catalogue recorded when it last read or wrote them (`Book.genreTag`). No tag and
    /// an empty one are the same. A book none of whose files can hold a genre (a PDF, a
    /// Kindle file, or no file at all) is never listed.
    public func genreFileDifferences() throws -> [GenreFileDifference] {
        var holders: [Int64: Int] = [:]
        for file in try store.allFiles() where Self.canHoldGenre(file.role, file.format) {
            if let bookId = file.bookId { holders[bookId, default: 0] += 1 }
        }
        return try store.books().compactMap { book in
            guard let id = book.id, let count = holders[id] else { return nil }
            let now = Self.tagOrNone(book.genreTag)
            let after = GenreTag.text(book.genres)
            guard now != after else { return nil }
            return GenreFileDifference(id: id, title: book.title, fileCount: count, tagNow: now, tagAfter: after)
        }
    }

    /// Writes the books' genres into those of their files that can hold a genre, as one
    /// undoable operation. A book that does not differ from its files
    /// (`genreFileDifferences()`), or has no file that can hold a genre, is reported as
    /// saved and nothing of it is opened. Nothing is moved.
    ///
    /// Each file is written whole, as every save writes it, by the same verified copy:
    /// in a file whose other tags are as the library last wrote them, only the genre
    /// tag changes. A file that cannot be written is reported among its book's file
    /// problems, as other saves report it, and the rest are still written; its book
    /// stays among those that differ. Undo puts every tag back as it stood.
    public func updateGenreFiles(_ bookIds: [Int64]) throws -> [SaveOutcome] {
        let differing = Set(try genreFileDifferences().map(\.id))
        var known: [Int64: Book] = [:]
        for id in Set(bookIds) { known[id] = try store.book(id: id) }
        // A book that is not in the library goes on, to be reported as other saves do.
        let chosen = bookIds.filter { differing.contains($0) || known[$0] == nil }
        var written = try rewriteTags(
            for: chosen, writing: { Self.canHoldGenre($0.role, $0.format) },
            label: { $0 == 1 ? "Update genre tags" : "Update genre tags for \($0) books" }
        )[...]
        var seen = Set<Int64>()
        return bookIds.map { id in
            if differing.contains(id) || known[id] == nil { return written.removeFirst() }
            guard seen.insert(id).inserted, let book = known[id] else {
                return .failed(bookId: id, reason: "That book is already being updated by this call")
            }
            return .saved(bookId: id, refiled: false, appOnlyFields: Set(book.appOnlyFields), fileProblems: [])
        }
    }

    /// Whether a file of this role and format holds its book's genres.
    static func canHoldGenre(_ role: FileRole, _ format: FileFormat) -> Bool {
        role != .extra && FileMetadataIO.storableFields(for: format).contains(.genre)
    }

    /// A recorded tag, or nil when there is nothing in it.
    private static func tagOrNone(_ tag: String?) -> String? {
        guard let tag, !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return tag
    }
}
