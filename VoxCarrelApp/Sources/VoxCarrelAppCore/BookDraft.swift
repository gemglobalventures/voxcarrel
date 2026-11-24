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
    /// The genres as one line of text (`GenreText`), until the field holds chips.
    public var genre: String
    /// The wording the genres came from: the book's own, or a lookup's once its genres
    /// have been taken into the draft.
    public var genreSource: String?
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
    /// Whether the audiobook is unabridged, abridged or a dramatisation, with how that
    /// is known; nil for not known. Changed by hand with `chooseEditionKind`.
    public var editionKind: EditionKindNote?

    public init(book: Book) {
        original = book
        title = book.title
        subtitle = book.subtitle ?? ""
        authors = NameListText.text(from: book.authors)
        narrators = NameListText.text(from: book.narrators)
        series = book.series ?? ""
        seriesNumber = book.seriesNumber ?? ""
        genre = GenreText.shown(book.genres)
        genreSource = book.genreSource
        year = book.year.map(String.init) ?? ""
        publisher = book.publisher ?? ""
        summary = book.summary ?? ""
        language = book.language ?? ""
        isbn = book.isbn ?? ""
        asin = book.asin ?? ""
        tags = NameListText.text(from: book.tags)
        rating = book.rating
        cover = .keep
        editionKind = book.editionKind
    }

    /// K9: the user's own choice of what kind of edition the book is; nil for "Not
    /// known". Choosing the kind the book is already taken to be makes it the user's
    /// word, which nothing worked out later replaces. Choosing what was already chosen
    /// by hand changes nothing.
    ///
    /// "Not known" is the user's word too, and is kept: nothing worked out later (at
    /// import, by a lookup, by Check Edition) gives the book a kind again until the
    /// user chooses one. For a book nothing was ever known of, it is simply no kind.
    public mutating func chooseEditionKind(_ kind: EditionKind?) {
        guard let kind, kind != .notKnown else {
            if let own = original.editionKind {
                editionKind = own.isNotKnown ? own : .notKnownByHand
            } else {
                editionKind = nil
            }
            return
        }
        if let now = editionKind, now.kind == kind, now.isSetByHand { return }
        // Back to the book's own value, when that is the same choice.
        if let own = original.editionKind, own.kind == kind, own.isSetByHand {
            editionKind = own
            return
        }
        editionKind = EditionKindNote(kind: kind, basis: .setByHand)
    }

    /// K9: whether the edition kind is to be marked "saved in app only": only a kind
    /// set by hand is.
    public var editionKindIsAppOnly: Bool {
        guard let editionKind else { return false }
        return editionKind.isSetByHand && !editionKind.isNotKnown
    }

    var editionKindChanged: Bool { editionKind != original.editionKind }

    /// MG6: whether there is a title or an author to put in the other's place.
    public var canSwapTitleAndAuthor: Bool {
        !title.trimmed.isEmpty || !NameListText.names(from: authors).isEmpty
    }

    /// MG6: exchanges the title with the first author, for a book whose file had them
    /// in each other's place. The old title becomes the first author; any other
    /// authors stay after it. A title that holds a semicolon is still one author
    /// (`NameListText.oneName`).
    ///
    /// With no title, the first author becomes the title and is an author no more;
    /// with no author, the title becomes the author and the title is left empty, to
    /// be filled in before the book is saved. Nothing when both are blank.
    public mutating func swapTitleAndAuthor() {
        guard canSwapTitleAndAuthor else { return }
        var names = NameListText.names(from: authors)
        let old = title.trimmed
        title = names.isEmpty ? "" : names.removeFirst()
        authors = NameListText.text(from: (old.isEmpty ? [] : [NameListText.oneName(old)]) + names)
    }

    public var isDirty: Bool {
        cover != .keep || ratingChanged || yearChanged || titleChanged || editionKindChanged
            || textChanged(subtitle, original.subtitle) || namesChanged(authors, original.authors)
            || namesChanged(narrators, original.narrators) || textChanged(series, original.series)
            || textChanged(seriesNumber, original.seriesNumber) || genreChanged
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
        if genreChanged {
            edit.metadata.genres = GenreText.genres(typed: genre)
            edit.metadata.genreSource = genreSource
        }
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
        if editionKindChanged { edit.editionKind = editionKind }
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

    /// This draft's edits over another version of the book: every field whose text was
    /// changed here keeps its text, as does a cover change; every other field has the
    /// value `book` has. For when the book changes underneath an unsaved draft (its read
    /// status, say), so the edits are neither lost nor mistaken for the book's own values.
    public func reapplied(onto book: Book) -> BookDraft {
        var fresh = BookDraft(book: book)
        if titleChanged { fresh.title = title }
        if textChanged(subtitle, original.subtitle) { fresh.subtitle = subtitle }
        if namesChanged(authors, original.authors) { fresh.authors = authors }
        if namesChanged(narrators, original.narrators) { fresh.narrators = narrators }
        if textChanged(series, original.series) { fresh.series = series }
        if textChanged(seriesNumber, original.seriesNumber) { fresh.seriesNumber = seriesNumber }
        if genreChanged {
            fresh.genre = genre
            fresh.genreSource = genreSource
        }
        if yearChanged { fresh.year = year }
        if textChanged(publisher, original.publisher) { fresh.publisher = publisher }
        if textChanged(summary, original.summary) { fresh.summary = summary }
        if textChanged(language, original.language) { fresh.language = language }
        if textChanged(isbn, original.isbn) { fresh.isbn = isbn }
        if textChanged(asin, original.asin) { fresh.asin = asin }
        if namesChanged(tags, original.tags) { fresh.tags = tags }
        if ratingChanged { fresh.rating = rating }
        if editionKindChanged { fresh.editionKind = editionKind }
        fresh.cover = cover
        return fresh
    }

    /// What was typed into this draft after `sent` was taken from it, over the book as
    /// it is once `sent` has been saved: every field whose text now differs from what
    /// was sent keeps its text; every other field has the value `book` has. For text
    /// typed while a save was running, which is neither saved nor to be lost.
    public func reapplied(changedSince sent: BookDraft, onto book: Book) -> BookDraft {
        var fresh = BookDraft(book: book)
        let texts: [WritableKeyPath<BookDraft, String>] = [
            \.title, \.subtitle, \.authors, \.narrators, \.series, \.seriesNumber, \.genre, \.year,
            \.publisher, \.summary, \.language, \.isbn, \.asin, \.tags,
        ]
        for text in texts where self[keyPath: text] != sent[keyPath: text] {
            fresh[keyPath: text] = self[keyPath: text]
        }
        if genre != sent.genre { fresh.genreSource = genreSource }
        if rating != sent.rating { fresh.rating = rating }
        if editionKind != sent.editionKind { fresh.editionKind = editionKind }
        if cover != sent.cover { fresh.cover = cover }
        return fresh
    }

    // MARK: What changed

    private var clampedRating: Int { min(max(rating, 0), 5) }
    private var ratingChanged: Bool { clampedRating != original.rating }
    private var titleChanged: Bool { title.trimmed != original.title.trimmed }
    private var yearChanged: Bool { year.trimmed != (original.year.map(String.init) ?? "") }
    /// Whether the genre line is no longer the book's genres as they are shown.
    var genreChanged: Bool { textChanged(genre, GenreText.shown(original.genres)) }

    private func textChanged(_ text: String, _ value: String?) -> Bool {
        text.trimmed != (value ?? "").trimmed
    }

    /// Judged by the names the text holds, so spacing around a semicolon is not a change.
    private func namesChanged(_ text: String, _ value: [String]) -> Bool {
        NameListText.names(from: text) != NameListText.names(from: NameListText.text(from: value))
    }
}
