import Foundation

// Books kept where their files are, outside the library folder.
//
// A book can be added without bringing its files in: it is catalogued where they are,
// and they are never moved or written to. Its details, cover, series and everything
// else are the catalogue's. Later it can be brought into the library, as a copy that
// leaves the originals where they were or by moving them: the files are then filed
// like any other book's and given the details the catalogue has.

/// How bringing books into the library went.
public struct BroughtIn: Equatable, Sendable {
    public var brought: Int
    /// A sentence for each book that could not be brought in; it is still outside.
    public var problems: [String]
}

extension LibraryService {
    /// The books kept outside the library folder, lowest id first.
    public func booksKeptOutside() throws -> [Int64] {
        try store.books().filter(\.keptOutside).compactMap(\.id).sorted()
    }

    /// Brings books that are kept outside into the library: their files are filed
    /// under the library's folder layout and given the catalogue's details and cover.
    /// `.copy` leaves the originals where they were; `.move` takes them. One operation,
    /// which Undo takes back. Books that are not kept outside are passed over. A book
    /// whose files cannot all be found, or that cannot be filed, stays outside, and
    /// why is said.
    @discardableResult
    public func bringIntoLibrary(_ bookIds: [Int64], mode: TransferMode) throws -> BroughtIn {
        try refuseWhileLayoutChangeIsInterrupted()
        var edits: [BookEdit] = []
        var result = BroughtIn(brought: 0, problems: [])
        var outside: [Book] = []
        for id in Set(bookIds).sorted() {
            guard let book = try store.book(id: id), book.keptOutside else { continue }
            let rows = try store.files(bookId: id)
            let lost = rows.filter { !FileManager.default.fileExists(atPath: store.url(for: $0).path) }
            if let first = lost.first {
                let name = store.url(for: first).lastPathComponent
                result.problems.append(
                    "“\(book.title)” was left where it is: “\(name)” cannot be found. Its drive may not be connected.")
                continue
            }
            outside.append(book)
            let cover = covers.image(for: id).map(CoverChange.set) ?? .keep
            edits.append(BookEdit(book: book, cover: cover))
        }
        guard !edits.isEmpty else { return result }
        bringingIn = Set(edits.map(\.bookId))
        forcedWrites = bringingIn
        saveTransferMode = mode
        defer {
            bringingIn = []
            forcedWrites = []
            saveTransferMode = .move
        }
        let outcomes = try save(edits) { count, title in
            count == 1 ? "Bring \(title.isEmpty ? "1 book" : title) into the library" : "Bring \(count) books into the library"
        }
        for outcome in outcomes {
            switch outcome {
            case .saved(let bookId, _, _, _):
                guard let book = outside.first(where: { $0.id == bookId }) else { continue }
                // In the library once it has a folder there; a book that could not be
                // given one is still outside, as it was.
                if (try? store.book(id: bookId))??.keptOutside == false {
                    result.brought += 1
                } else {
                    result.problems.append(
                        "“\(book.title)” was left where it is: it cannot be filed until it has what the folder layout needs.")
                }
            case .failed(let bookId, let reason):
                guard let book = outside.first(where: { $0.id == bookId }) else { continue }
                result.problems.append("“\(book.title)” was left where it is: \(reason)")
            }
        }
        return result
    }
}

extension LibraryStore {
    func setKeptOutside(_ kept: Bool, bookIds: [Int64]) throws {
        try dbQueue.write { db in
            for id in bookIds {
                try db.execute(sql: "UPDATE book SET keptOutside = ? WHERE id = ?", arguments: [kept, id])
            }
        }
    }
}
