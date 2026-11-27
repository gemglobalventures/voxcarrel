import Foundation
import VoxCarrelCore

/// A book's highlights written out as one Markdown note: what the book is at the top,
/// then each highlight as a quotation with its note and where it came from. The note
/// begins with a block of properties (title, author, series), which note-taking apps
/// that keep them read and others show as plain text.
enum HighlightsMarkdown {
    public static let exportTitle = "Export as Markdown…"

    /// A value of the properties block, in quotes, so that a colon or a hash in it is
    /// read as part of it.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ") + "\""
    }

    /// A passage as a quotation: every line of it marked, an empty line kept as part of it.
    static func quotation(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
    }

    /// The day as the properties block has it: "2026-11-26".
    static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The note for `book` with these highlights, in the order given.
    ///
    /// `dated`: whether the properties say the day the note was written. A note that
    /// is written again and again leaves it out, so that it changes only when the book
    /// or its highlights do.
    static func note(
        for book: Book, highlights rows: [HighlightRow], now: Date = Date(), calendar: Calendar = .current,
        dated: Bool = true, properties: Bool = true
    ) -> String {
        let title = book.title.trimmedOrNil ?? "Untitled book"
        // Without the block of properties: for an app that would show it as plain text.
        guard properties else {
            let whole = note(for: book, highlights: rows, now: now, calendar: calendar, dated: dated)
            let parts = whole.components(separatedBy: "\n---\n\n")
            return parts.count > 1 ? parts.dropFirst().joined(separator: "\n---\n\n") : whole
        }
        var lines = ["---", "title: " + quoted(title)]
        if !book.authors.isEmpty {
            lines.append("author: [" + book.authors.map(quoted).joined(separator: ", ") + "]")
        }
        if let series = book.series?.trimmedOrNil {
            lines.append("series: " + quoted(series))
            if let number = book.seriesNumber?.trimmedOrNil { lines.append("series_number: " + quoted(number)) }
        }
        if let year = book.year { lines.append("year: \(year)") }
        lines.append("highlights: \(rows.count)")
        if dated { lines.append("exported: " + day(now, calendar: calendar)) }
        lines.append("---")
        lines.append("")
        lines.append("# " + title)
        if !book.authors.isEmpty {
            lines.append("")
            lines.append(book.authors.joined(separator: ", "))
        }
        lines.append("")
        lines.append("## Highlights")
        for row in rows {
            lines.append("")
            if !row.text.isEmpty {
                lines.append(quotation(row.text))
                lines.append("")
            } else if row.isEmptyMark {
                lines.append("*" + HighlightText.emptyMark + "*")
                lines.append("")
            }
            if let note = row.note {
                lines.append("**Note:** " + note.replacingOccurrences(of: "\n", with: "\n\n"))
                lines.append("")
            }
            let caption = row.sourcedCaptionText
            lines.append(row.link.map { "[\(caption)](\($0.absoluteString))" } ?? caption)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A name for the note's file: the book's title without what a file name cannot
    /// hold, and "highlights".
    static func fileName(for book: Book) -> String {
        let title = (book.title.trimmedOrNil ?? "Untitled book")
            .components(separatedBy: CharacterSet(charactersIn: "/:\\\u{0}\n\r")).joined(separator: " ")
            .split(separator: " ").joined(separator: " ")
        return String(title.prefix(120)) + " highlights.md"
    }
}

/// One book's highlights as a Markdown note, with a name for its file.
public struct HighlightNote: Equatable, Sendable {
    public var bookId: Int64
    public var fileName: String
    public var text: String
}

public enum HighlightNotes {
    /// A note for every book that has a highlight and is not hidden, lowest id first.
    /// The notes carry no date: each changes only when its book or its highlights do.
    /// Only reads the catalogue.
    public static func all(in service: LibraryService) throws -> [HighlightNote] {
        try BookScope.visible {
            try service.booksWithHighlights().compactMap { book -> HighlightNote? in
                guard let id = book.id else { return nil }
                let rows = try service.highlights(forBook: id).map { HighlightRow($0) }
                guard !rows.isEmpty else { return nil }
                return HighlightNote(
                    bookId: id, fileName: HighlightsMarkdown.fileName(for: book),
                    text: HighlightsMarkdown.note(for: book, highlights: rows, dated: false))
            }.sorted { $0.bookId < $1.bookId }
        }
    }
}

/// A book's highlights handed to Bear, the notes app, as a new note.
///
/// Bear keeps its notes in a store of its own, not as files in a folder, so a note is
/// given to it through the address scheme Bear itself offers: `bear://x-callback-url/create`.
/// Nothing leaves the Mac. The note begins with the book's title as its heading, which
/// Bear takes for the note's title, and carries one tag.
public enum BearNote {
    public static let sendTitle = "Send to Bear"
    /// The tag every such note is given.
    public static let tag = "books/highlights"
    /// The longest note that is handed over in an address. A longer one is not cut
    /// short: it is exported as a file instead.
    public static let longest = 150_000

    public static let tooLong =
        "These highlights are too long to hand to Bear in one go. Export them as Markdown, then import the file in Bear."

    /// The address that makes the note in Bear; nil for an empty note or one that is too long.
    public static func url(text: String) -> URL? {
        guard !text.isEmpty, text.count <= longest else { return nil }
        var parts = URLComponents()
        parts.scheme = "bear"
        parts.host = "x-callback-url"
        parts.path = "/create"
        parts.queryItems = [
            URLQueryItem(name: "text", value: text), URLQueryItem(name: "tags", value: tag),
            URLQueryItem(name: "open_note", value: "yes"),
        ]
        // A plus sign would be read as a space by some readers of an address: it is written out.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url
    }
}
