import Foundation
import VoxCarrelCore

// What the inspector asks of the model (plan Task 10). N1–N10.

/// N3: the cover the inspector shows for a draft.
public enum DraftCover: Equatable, Sendable {
    /// The book's own cover, as stored.
    case stored
    /// An image chosen and not yet saved.
    case chosen(Data)
    /// No cover: the book has none, or it is to be removed.
    case none
}

extension AppModel {
    /// N1: the fields of the one inspected book to mark "saved in app only"; empty when
    /// one book is not what is inspected.
    public var appOnlyMarkers: Set<MetadataField> {
        guard case .one(let detail, let draft) = inspecting else { return [] }
        // R7: a book with no files has no file that "cannot hold" a field.
        guard detail.row.hasFiles else { return [] }
        return draft.appOnlyMarkers(hasCover: detail.row.coverURL != nil)
    }

    /// N3
    public var draftCover: DraftCover {
        guard case .one(let detail, let draft) = inspecting else { return .none }
        switch draft.cover {
        case .keep: return detail.row.coverURL == nil ? .none : .stored
        case .remove: return .none
        case .set(let image): return .chosen(image.data)
        }
    }

    /// N3: whether there is a cover for Remove Cover to take away.
    public var canRemoveCover: Bool {
        draftCover != .none
    }

    /// N11: the books that have edits not yet saved: the inspected book, or every book of
    /// the selection whose shared fields were changed. Empty when there is nothing to save.
    public var editedBookIds: Set<Int64> {
        switch inspecting {
        case .nothing: []
        case .one(let detail, let draft): draft.isDirty ? [detail.row.id] : []
        case .many(let draft): draft.isDirty ? Set(draft.books.compactMap(\.id)) : []
        }
    }

    static let editedText = "Edited · not saved"

    /// N11: what the inspector says at its top while there are edits not yet saved; nil
    /// when there are none.
    public var inspectorEditedText: String? {
        hasUnsavedChanges ? Self.editedText : nil
    }

    /// N11: what the mark beside an edited book's title says when the pointer rests on it.
    public var editedBadgeHelp: String { "Has unsaved changes" }

    /// N8: what a bulk field is given when its text is typed.
    public func setBulkText(_ text: String, for field: BulkField) {
        updateBulkDraft { $0.setText(text, for: field) }
    }
}

extension BookDetail {
    /// N2: why the book needs attention, each reason a line of its own; empty when
    /// there is nothing to say.
    public var attentionReasons: [String] {
        var reasons: [String] = []
        // R7: a book with no files is never filed, and has no file to miss.
        guard row.hasFiles else { return [] }
        if row.book.needsAttention, row.firstAuthorText.isEmpty {
            reasons.append("Add an author to file this book")
        }
        if files.contains(where: \.isMissing) {
            reasons.append("Some files are missing")
        }
        return reasons
    }

    /// N4: whether any file's tags could not be written, so that writing them again is offered.
    public var showsRewriteTags: Bool {
        files.contains { $0.file.writeProblem != nil }
    }

    /// Whether any file's length header is wrong and can be repaired, so that repairing is offered.
    public var showsRepairLength: Bool {
        row.repairableLengthFiles > 0
    }

    /// N5: "7h 42m · 12 chapters" for a book with audio; nil when it has none, or
    /// neither is known.
    public var audioSummaryText: String? {
        guard row.hasAudio else { return nil }
        var parts: [String] = []
        if !row.lengthText.isEmpty { parts.append(row.lengthText) }
        if chapterCount > 0 { parts.append(chapterCount == 1 ? "1 chapter" : "\(chapterCount) chapters") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension Book {
    /// N6: when the book was started and finished, each on a line of its own:
    /// "Started 3 Nov 2026". Dates the book's status does not go with are left out.
    public func readDateLines(locale: Locale = .current, timeZone: TimeZone = .current) -> [String] {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: timeZone)
        var lines: [String] = []
        if readStatus != .unread, let dateStarted {
            lines.append("Started \(dateStarted.formatted(style))")
        }
        if readStatus == .finished, let dateFinished {
            lines.append("Finished \(dateFinished.formatted(style))")
        }
        return lines
    }
}

extension BookDraft {
    /// N7: a click on a star gives that rating; a click on the star that is the rating
    /// already takes the rating away.
    public mutating func clickStar(_ star: Int) {
        let star = min(max(star, 0), 5)
        rating = star == rating ? 0 : star
    }
}

extension FileRole {
    /// N10
    public var title: String {
        switch self {
        case .audio: "Audiobook"
        case .ebook: "Ebook"
        case .extra: "Extra"
        }
    }
}

extension BulkField {
    /// N9: the field's label in the inspector.
    public var title: String {
        switch self {
        case .authors: "Author"
        case .narrators: "Narrator"
        case .series: "Series"
        case .genre: "Genre"
        case .year: "Year"
        case .publisher: "Publisher"
        case .language: "Language"
        case .tags: "Add tags"
        }
    }

    /// N9: whether the field takes several values, separated by semicolons.
    public var takesSeveral: Bool {
        self == .authors || self == .narrators || self == .tags
    }
}

extension BulkDraft {
    /// N9: "5 books selected"
    public var headline: String {
        books.count == 1 ? "1 book selected" : "\(books.count) books selected"
    }

    /// N8: the text in a field's box: what was typed, or for a field not touched, the
    /// value every book has. Tags are added, so their box starts empty.
    public func text(for field: BulkField) -> String {
        if let typed = values[field] { return typed }
        if field != .tags, case .same(let text) = shared(field) { return text }
        return ""
    }

    /// N8: what an empty box says: "Mixed" for a field not touched whose books differ.
    public func placeholder(for field: BulkField) -> String {
        field != .tags && values[field] == nil && shared(field) == .mixed ? "Mixed" : ""
    }

    /// N8: takes the text of a field's box as the field's value.
    ///
    /// A box that says what it said before anything was typed leaves the field
    /// untouched: the value every book has, or for tags, nothing. So does an emptied box
    /// of a field whose books differ: it is back to "Mixed", and never means "clear this
    /// on every book". Emptying a box that showed a value every book has does clear the
    /// field on every book, and `note(for:)` says so.
    public mutating func setText(_ text: String, for field: BulkField) {
        if field == .tags {
            values[field] = text.isEmpty ? nil : text
            return
        }
        let isBlank = field.takesSeveral ? NameListText.names(from: text).isEmpty : text.trimmed.isEmpty
        switch shared(field) {
        case .same(let common):
            // Nothing to clear where no book has a value.
            values[field] = text == common || (isBlank && common.isEmpty) ? nil : text
        case .mixed:
            values[field] = isBlank ? nil : text
        }
    }

    /// N8: what to say under a field's box: that saving will clear the field, and on how
    /// many books. Nil for a field that will be left alone or given a value.
    public func note(for field: BulkField) -> String? {
        guard field != .tags, let value = values[field] else { return nil }
        let isBlank = field.takesSeveral ? NameListText.names(from: value).isEmpty : value.trimmed.isEmpty
        guard isBlank else { return nil }
        return "Will be cleared on \(books.count == 1 ? "1 book" : "\(books.count) books")"
    }
}
