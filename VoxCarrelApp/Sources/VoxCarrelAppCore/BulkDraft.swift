import Foundation
import VoxCarrelCore

/// The fields that can be set on several books at once.
public enum BulkField: String, CaseIterable, Sendable {
    case authors, narrators, series, genre, year, publisher, language, tags
}

/// An edit to several books at once. Only a field the user gave a value is applied.
/// Every field replaces the old value on each book, except tags, which are added.
public struct BulkDraft: Equatable, Sendable {
    public enum Shared: Equatable, Sendable {
        case same(String)
        case mixed
    }

    public let books: [Book]
    /// Nil = untouched. A non-nil value (even empty, which clears the field) is applied.
    /// The tags value is added to each book's tags, so an empty one changes nothing.
    public var values: [BulkField: String] = [:]

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
        values.contains { field, value in
            field != .tags || !NameListText.names(from: value).isEmpty
        }
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
                case .genre: edit.metadata.genre = value.trimmedOrNil
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
            return edit
        }
    }

    private static func text(of field: BulkField, in book: Book) -> String {
        switch field {
        case .authors: NameListText.text(from: book.authors)
        case .narrators: NameListText.text(from: book.narrators)
        case .series: book.series ?? ""
        case .genre: book.genre ?? ""
        case .year: book.year.map(String.init) ?? ""
        case .publisher: book.publisher ?? ""
        case .language: book.language ?? ""
        case .tags: NameListText.text(from: book.tags)
        }
    }
}
