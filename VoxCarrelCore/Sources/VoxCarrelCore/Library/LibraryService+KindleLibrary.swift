import Foundation

/// What bringing in a Kindle library would do, or did.
public struct KindleLibraryReport: Equatable, Sendable {
    /// Books the library did not have, added as owned on Kindle, with no files.
    public var added: [String] = []
    /// Books the library had, now marked as owned on Kindle too.
    public var marked: [String] = []
    /// Books already marked as owned on Kindle: nothing to do.
    public var alreadyThere = 0

    public init() {}

    public var changesNothing: Bool { added.isEmpty && marked.isEmpty }
}

extension LibraryService {
    /// Brings an Amazon account's Kindle library into this one, or says what doing so
    /// would do (`apply` false: nothing is changed).
    ///
    /// A book the library has (by its Kindle ID, or surely the same by title and first
    /// author) is marked as owned on Kindle, keeping every detail it has; one it lacks
    /// is added with its title, authors and the series its title names, with no files
    /// and no folder. Two editions the account owns are two books. A Kindle ID is never taken for the book's Audible ID. No file is
    /// opened or written. Done again with the same list, it changes nothing.
    ///
    /// Not an undoable operation: a book that was added is removed like any other.
    public func bringInKindleLibrary(_ books: [KindleOwnedBook], apply: Bool, now: Date = Date()) throws -> KindleLibraryReport {
        var report = KindleLibraryReport()
        var byItem: [String: Int64] = [:]
        for book in try store.books() {
            guard let id = book.id else { continue }
            for item in book.externalCopies.filter({ $0.kind == .kindle }).compactMap({ $0.itemId?.trimmingCharacters(in: .whitespaces).uppercased() })
            where !item.isEmpty && byItem[item] == nil { byItem[item] = id }
        }

        var addedHere = Set<Int64>()
        for owned in books {
            let copy = ExternalCopy(kind: .kindle, form: .ebook, itemId: owned.asin)
            var metadata = BookMetadata(title: owned.title, authors: owned.authors)
            metadata.series = owned.series
            metadata.seriesNumber = owned.series == nil ? nil : owned.seriesNumber
            // Two editions in the Kindle library are two books: one added here is not
            // taken for the next by its title.
            var known = byItem[owned.asin.uppercased()]
            if known == nil, let match = try existingMatch(for: metadata)?.id, !addedHere.contains(match) { known = match }
            if let id = known, var book = try store.book(id: id) {
                if Self.give(copy, to: &book) {
                    report.alreadyThere += 1
                    continue
                }
                report.marked.append(book.title)
                byItem[owned.asin.uppercased()] = id
                guard apply else { continue }
                try store.modifyBook(id: id) { stored, _ in Self.give(copy, to: &stored) }
            } else {
                report.added.append(owned.title)
                guard apply else { continue }
                var book = Book(metadata: metadata, folderPath: nil, needsAttention: false, dateAdded: now)
                book.externalCopies = [copy]
                if let id = try store.insert(book, files: []).id {
                    byItem[owned.asin.uppercased()] = id
                    addedHere.insert(id)
                }
            }
        }
        return report
    }
}
