import Foundation
import VoxCarrelCore

public enum BookSortKey: String, CaseIterable, Sendable {
    case title, author, series, formats, length, dateAdded
}

/// How the grid and the list order their books.
public struct BookSort: Equatable, Sendable {
    public var key: BookSortKey = .title
    public var ascending = true

    public init(key: BookSortKey = .title, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }

    /// The rows in this order. Text is compared ignoring case, with numbers inside it in
    /// natural order. Every key breaks ties by title and then id, so the result does not
    /// depend on the order the rows arrive in.
    ///
    /// Rows that have no value for the key (no author, no series, no audio or ebook
    /// file, no duration) come last. Descending reverses the whole order, ties included,
    /// except that those rows still come last.
    public func sorted(_ rows: [BookRow]) -> [BookRow] {
        var valued: [BookRow] = []
        var valueless: [BookRow] = []
        for row in rows {
            if hasValue(row) { valued.append(row) } else { valueless.append(row) }
        }
        return ordered(valued) + ordered(valueless)
    }

    private func ordered(_ rows: [BookRow]) -> [BookRow] {
        rows.sorted { a, b in
            let result = compare(a, b)
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    // MARK: Values

    private static func text(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func firstAuthor(_ row: BookRow) -> String? { text(row.book.authors.first) }

    /// 0 audio only, 1 audio and ebook, 2 ebook only; nil when the book has neither.
    private static func formatRank(_ row: BookRow) -> Int? {
        switch (row.hasAudio, row.hasEbook) {
        case (true, false): 0
        case (true, true): 1
        case (false, true): 2
        case (false, false): nil
        }
    }

    private func hasValue(_ row: BookRow) -> Bool {
        switch key {
        case .title, .dateAdded: true
        case .author: Self.firstAuthor(row) != nil
        case .series: Self.text(row.book.series) != nil
        case .formats: Self.formatRank(row) != nil
        case .length: row.book.durationSeconds != nil
        }
    }

    // MARK: Comparing

    private static func compareText(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: [.caseInsensitive, .numeric])
    }

    private static func compareValues<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    /// Numbers first, in numeric order; then numbers that are not numbers ("1-3") as
    /// text; then books with no number.
    private static func compareSeriesNumbers(_ a: String?, _ b: String?) -> ComparisonResult {
        func parts(_ value: String?) -> (group: Int, number: Double, text: String) {
            guard let value = text(value) else { return (2, 0, "") }
            if let number = Double(value), number.isFinite { return (0, number, value) }
            return (1, 0, value)
        }
        let (x, y) = (parts(a), parts(b))
        if x.group != y.group { return compareValues(x.group, y.group) }
        if x.number != y.number { return compareValues(x.number, y.number) }
        return compareText(x.text, y.text)
    }

    /// The ascending order for the key, ending with title and then id.
    private func compare(_ a: BookRow, _ b: BookRow) -> ComparisonResult {
        var result: ComparisonResult = .orderedSame
        switch key {
        case .title:
            break
        case .author:
            result = Self.compareText(Self.firstAuthor(a) ?? "", Self.firstAuthor(b) ?? "")
        case .series:
            result = Self.compareText(Self.text(a.book.series) ?? "", Self.text(b.book.series) ?? "")
            if result == .orderedSame {
                result = Self.compareSeriesNumbers(a.book.seriesNumber, b.book.seriesNumber)
            }
        case .formats:
            result = Self.compareValues(Self.formatRank(a) ?? .max, Self.formatRank(b) ?? .max)
        case .length:
            result = Self.compareValues(a.book.durationSeconds ?? 0, b.book.durationSeconds ?? 0)
        case .dateAdded:
            result = Self.compareValues(a.book.dateAdded, b.book.dateAdded)
        }
        if result == .orderedSame { result = Self.compareText(a.book.title, b.book.title) }
        if result == .orderedSame { result = Self.compareValues(a.id, b.id) }
        return result
    }
}
