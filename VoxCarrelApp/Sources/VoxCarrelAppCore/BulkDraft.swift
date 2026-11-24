import Foundation
import VoxCarrelCore

/// The fields that can be set on several books at once.
public enum BulkField: String, CaseIterable, Sendable {
    case authors, narrators, series, year, publisher, language, tags
}

/// G21: a genre of the selected books as the bulk field shows it.
public struct BulkGenre: Identifiable, Equatable, Sendable {
    public var name: String
    /// How many of the books have it, or will once the draft is saved.
    public var count: Int
    /// How many books are selected.
    public var of: Int

    public var id: String { name }

    /// True when only some of the books have it.
    public var isMixed: Bool { count < of }

    /// "2 of 3 books" for a genre only some have; nil for one they all have.
    public var detail: String? {
        isMixed ? "\(count) of \(of) books" : nil
    }
}

/// An edit to several books at once. Only a field the user gave a value is applied.
/// Every field replaces the old value on each book, except tags, which are added.
/// Genres are neither: one is added to the books that lack it, or taken from those
/// that have it, and nothing else about each book's list changes.
public struct BulkDraft: Equatable, Sendable {
    public enum Shared: Equatable, Sendable {
        case same(String)
        case mixed
    }

    public let books: [Book]
    /// Nil = untouched. A non-nil value (even empty, which clears the field) is applied.
    /// The tags value is added to each book's tags, so an empty one changes nothing.
    public var values: [BulkField: String] = [:]
    /// G21: the genres to put on every book that lacks them, in the order they were added.
    public private(set) var genreAdds: [String] = []
    /// G21: the genres to take from every book that has them.
    public private(set) var genreRemoves: [String] = []

    public init(books: [Book]) {
        self.books = books
    }

    /// What the selection has in common, for placeholders: the first book's value when
    /// every book has the same one (lists in the same order, ignoring case).
    public func shared(_ field: BulkField) -> Shared {
        guard let first = books.first else { return .same("") }
        let isList = field == .authors || field == .narrators || field == .tags
        let text = Self.text(of: field, in: first)
        let key = isList ? text.lowercased() : text
        let allSame = books.dropFirst().allSatisfy { book in
            let other = Self.text(of: field, in: book)
            return (isList ? other.lowercased() : other) == key
        }
        return allSame ? .same(text) : .mixed
    }

    public var isDirty: Bool {
        !genreAdds.isEmpty || !genreRemoves.isEmpty
            || values.contains { field, value in
                field != .tags || !NameListText.names(from: value).isEmpty
            }
    }

    // MARK: Genres

    /// G21: the genres of the selected books as they would be once the draft is saved,
    /// in the order the books first have them, each plain or mixed.
    public var genres: [BulkGenre] {
        var names: [String] = []
        for name in books.flatMap(\.genres) + genreAdds where !names.contains(where: { GenreName.same($0, name) }) {
            names.append(name)
        }
        return names.compactMap { name in
            guard !Self.holds(genreRemoves, name) else { return nil }
            let count = Self.holds(genreAdds, name) ? books.count : books.filter { Self.holds($0.genres, name) }.count
            return BulkGenre(name: name, count: count, of: books.count)
        }
    }

    /// G21: puts the genre, at the end, on every book that lacks it. Nothing to do when
    /// they all have it.
    public mutating func addGenre(_ name: String) {
        genreRemoves.removeAll { GenreName.same($0, name) }
        guard !Self.holds(genreAdds, name), !books.allSatisfy({ Self.holds($0.genres, name) }) else { return }
        genreAdds.append(name)
    }

    /// G21: takes the genre from every book that has it. Nothing to do when none has.
    public mutating func removeGenre(_ name: String) {
        genreAdds.removeAll { GenreName.same($0, name) }
        guard !Self.holds(genreRemoves, name), books.contains(where: { Self.holds($0.genres, name) }) else { return }
        genreRemoves.append(name)
    }

    /// GH27: the genres to add and to take away after a change to the library's list
    /// of genres: `follow` gives each name as it is now. A genre that is then both to
    /// be added and taken away is added.
    mutating func followGenres(_ follow: ([String]) -> [String]) {
        genreAdds = follow(genreAdds)
        genreRemoves = follow(genreRemoves).filter { !Self.holds(genreAdds, $0) }
    }

    /// GH27: puts them back as they were before a change to the list that has been undone.
    mutating func restoreGenres(adds: [String], removes: [String]) {
        genreAdds = adds
        genreRemoves = removes
    }

    /// Takes the unsaved genre changes of another draft, for when the books are read again.
    mutating func takeGenreChanges(of other: BulkDraft, since sent: BulkDraft? = nil) {
        for name in other.genreAdds where !(sent.map { Self.holds($0.genreAdds, name) } ?? false) { addGenre(name) }
        for name in other.genreRemoves where !(sent.map { Self.holds($0.genreRemoves, name) } ?? false) {
            removeGenre(name)
        }
    }

    private static func holds(_ names: [String], _ name: String) -> Bool {
        names.contains { GenreName.same($0, name) }
    }

    /// Problems that stop a save, as sentences. Empty when the draft can be saved.
    public var problems: [String] {
        if let year = values[.year], YearText(year) == .invalid { return [YearText.problem] }
        return []
    }

    /// One edit per book, in order, each starting from that book's current values.
    /// Nil when `problems` is not empty.
    public func makeEdits() -> [BookEdit]? {
        guard problems.isEmpty else { return nil }
        return books.map { book in
            var edit = BookEdit(book: book)
            for (field, value) in values {
                switch field {
                case .authors: edit.metadata.authors = NameListText.names(from: value)
                case .narrators: edit.metadata.narrators = NameListText.names(from: value)
                // The series number is each book's own, and is left alone.
                case .series: edit.metadata.series = value.trimmedOrNil
                case .year:
                    if case .year(let year) = YearText(value) { edit.metadata.year = year } else { edit.metadata.year = nil }
                case .publisher: edit.metadata.publisher = value.trimmedOrNil
                case .language: edit.metadata.language = value.trimmedOrNil
                case .tags:
                    var present = Set(book.tags.map { $0.lowercased() })
                    for tag in NameListText.names(from: value) where present.insert(tag.lowercased()).inserted {
                        edit.tags.append(tag)
                    }
                }
            }
            if !genreAdds.isEmpty || !genreRemoves.isEmpty {
                var genres = book.genres.filter { !Self.holds(genreRemoves, $0) }
                for name in genreAdds { genres = GenreChips.adding(name, to: genres) }
                edit.metadata.genres = genres
            }
            return edit
        }
    }

    private static func text(of field: BulkField, in book: Book) -> String {
        switch field {
        case .authors: NameListText.text(from: book.authors)
        case .narrators: NameListText.text(from: book.narrators)
        case .series: book.series ?? ""
        case .year: book.year.map(String.init) ?? ""
        case .publisher: book.publisher ?? ""
        case .language: book.language ?? ""
        case .tags: NameListText.text(from: book.tags)
        }
    }
}
