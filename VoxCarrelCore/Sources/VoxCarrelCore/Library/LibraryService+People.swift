import Foundation

// One person written one way. An author or a narrator is whatever the books say, so
// "Ray Porter" and "Raymond Porter" are two people until every book that says one is
// made to say the other. Renaming does that for a whole library at once.

extension LibraryService {
    /// Writes an author or a narrator another way on every book that names them:
    /// `name` becomes `newName` wherever it is that book's author (or narrator),
    /// exactly as written apart from capital letters and the spaces around it. Renaming
    /// to a name other books already use makes the two one person. A book that would
    /// name the person twice names them once.
    ///
    /// One operation, which Undo takes back; the books' files are given the new name
    /// and re-filed where the folder layout uses it. Returns how many books changed.
    /// Only `.authors` and `.narrators` are people: any other field changes nothing.
    @discardableResult
    public func renamePerson(_ field: BrowseField, from name: String, to newName: String) throws -> Int {
        let old = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard field == .authors || field == .narrators, !old.isEmpty, !new.isEmpty, old != new else { return 0 }
        func rewritten(_ names: [String]) -> [String]? {
            guard names.contains(where: { Self.samePerson($0, old) }) else { return nil }
            var seen = Set<String>()
            var result: [String] = []
            for written in names {
                let now = Self.samePerson(written, old) ? new : written
                if seen.insert(now.lowercased()).inserted { result.append(now) }
            }
            return result
        }
        var edits: [BookEdit] = []
        for book in try store.books() {
            var edit = BookEdit(book: book)
            if field == .authors, let authors = rewritten(book.authors) {
                edit.metadata.authors = authors
                edits.append(edit)
            } else if field == .narrators, let narrators = rewritten(book.narrators) {
                edit.metadata.narrators = narrators
                edits.append(edit)
            }
        }
        guard !edits.isEmpty else { return 0 }
        let outcomes = try save(edits, named: "Rename \(old)")
        return outcomes.filter { if case .saved = $0 { true } else { false } }.count
    }

    static func samePerson(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines).compare(
            b.trimmingCharacters(in: .whitespacesAndNewlines), options: .caseInsensitive) == .orderedSame
    }
}
