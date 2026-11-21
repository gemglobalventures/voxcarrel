import Foundation
import VoxCarrelCore

/// One book's editable values as the text the inspector's fields hold. Nothing is written
/// until the draft is turned into a `BookEdit` and saved.
///
/// A field counts as changed only when its text, trimmed, differs from the text the book
/// started with. A field that was not changed keeps the book's own value exactly, so
/// opening a book and saving it never alters anything.
public struct BookDraft: Equatable, Sendable {
    public let original: Book
    public var title: String
    public var subtitle: String
    /// "; " separated.
    public var authors: String
    public var narrators: String
    public var series: String
    public var seriesNumber: String
    public var genre: String
    public var year: String
    public var publisher: String
    public var summary: String
    public var language: String
    public var isbn: String
    public var asin: String
    /// "; " separated.
    public var tags: String
    public var rating: Int
    /// `.keep` until the user changes it.
    public var cover: CoverChange

    public init(book: Book) {
        original = book
        title = book.title
        subtitle = book.subtitle ?? ""
        authors = NameListText.text(from: book.authors)
        narrators = NameListText.text(from: book.narrators)
        series = book.series ?? ""
        seriesNumber = book.seriesNumber ?? ""
        genre = book.genre ?? ""
        year = book.year.map(String.init) ?? ""
        publisher = book.publisher ?? ""
        summary = book.summary ?? ""
        language = book.language ?? ""
        isbn = book.isbn ?? ""
        asin = book.asin ?? ""
        tags = NameListText.text(from: book.tags)
        rating = book.rating
        cover = .keep
    }

    public var isDirty: Bool {
        cover != .keep || ratingChanged || yearChanged || titleChanged
            || textChanged(subtitle, original.subtitle) || namesChanged(authors, original.authors)
            || namesChanged(narrators, original.narrators) || textChanged(series, original.series)
            || textChanged(seriesNumber, original.seriesNumber) || textChanged(genre, original.genre)
            || textChanged(publisher, original.publisher) || textChanged(summary, original.summary)
            || textChanged(language, original.language) || textChanged(isbn, original.isbn)
            || textChanged(asin, original.asin) || namesChanged(tags, original.tags)
    }

    /// Problems that stop a save, as sentences. Empty when the draft can be saved.
    public var problems: [String] {
        var problems: [String] = []
        if title.trimmed.isEmpty { problems.append("A book needs a title.") }
        // A year the book already had is never a problem: only what was typed is judged.
        if yearChanged, YearText(year) == .invalid { problems.append(YearText.problem) }
        return problems
    }

    /// Nil when `problems` is not empty.
    public func makeEdit() -> BookEdit? {
        guard problems.isEmpty else { return nil }
        // Starts from the book, so `durationSeconds` and `pageCount` are carried through.
        var edit = BookEdit(book: original, cover: cover)
        if titleChanged { edit.metadata.title = title.trimmed }
        if textChanged(subtitle, original.subtitle) { edit.metadata.subtitle = subtitle.trimmedOrNil }
        if namesChanged(authors, original.authors) { edit.metadata.authors = NameListText.names(from: authors) }
        if namesChanged(narrators, original.narrators) {
            edit.metadata.narrators = NameListText.names(from: narrators)
        }
        if textChanged(series, original.series) { edit.metadata.series = series.trimmedOrNil }
        if textChanged(seriesNumber, original.seriesNumber) { edit.metadata.seriesNumber = seriesNumber.trimmedOrNil }
        if textChanged(genre, original.genre) { edit.metadata.genre = genre.trimmedOrNil }
        if yearChanged {
            if case .year(let value) = YearText(year) { edit.metadata.year = value } else { edit.metadata.year = nil }
        }
        if textChanged(publisher, original.publisher) { edit.metadata.publisher = publisher.trimmedOrNil }
        if textChanged(summary, original.summary) { edit.metadata.summary = summary.trimmedOrNil }
        if textChanged(language, original.language) { edit.metadata.language = language.trimmedOrNil }
        if textChanged(isbn, original.isbn) { edit.metadata.isbn = isbn.trimmedOrNil }
        if textChanged(asin, original.asin) { edit.metadata.asin = asin.trimmedOrNil }
        if namesChanged(tags, original.tags) { edit.tags = NameListText.names(from: tags) }
        if ratingChanged { edit.rating = clampedRating }
        return edit
    }

    /// Fields to mark "saved in app only": the book's own list, without fields that are
    /// empty now (an empty field has nothing to mark). `hasCover`: whether the book has a
    /// stored cover.
    public func appOnlyMarkers(hasCover: Bool) -> Set<MetadataField> {
        Set(original.appOnlyFields.filter { field in
            switch field {
            case .title: !title.trimmed.isEmpty
            case .subtitle: !subtitle.trimmed.isEmpty
            case .authors: !NameListText.names(from: authors).isEmpty
            case .narrators: !NameListText.names(from: narrators).isEmpty
            case .series: !series.trimmed.isEmpty
            case .seriesNumber: !seriesNumber.trimmed.isEmpty
            case .genre: !genre.trimmed.isEmpty
            case .year: !year.trimmed.isEmpty
            case .publisher: !publisher.trimmed.isEmpty
            case .summary: !summary.trimmed.isEmpty
            case .language: !language.trimmed.isEmpty
            case .isbn: !isbn.trimmed.isEmpty
            case .asin: !asin.trimmed.isEmpty
            case .cover: hasCover && cover != .remove
            }
        })
    }

    // MARK: What changed

    private var clampedRating: Int { min(max(rating, 0), 5) }
    private var ratingChanged: Bool { clampedRating != original.rating }
    private var titleChanged: Bool { title.trimmed != original.title.trimmed }
    private var yearChanged: Bool { year.trimmed != (original.year.map(String.init) ?? "") }

    private func textChanged(_ text: String, _ value: String?) -> Bool {
        text.trimmed != (value ?? "").trimmed
    }

    /// Judged by the names the text holds, so spacing around a semicolon is not a change.
    private func namesChanged(_ text: String, _ value: [String]) -> Bool {
        NameListText.names(from: text) != NameListText.names(from: NameListText.text(from: value))
    }
}
