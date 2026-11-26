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
    static func note(for book: Book, highlights rows: [HighlightRow], now: Date = Date(), calendar: Calendar = .current) -> String {
        let title = book.title.trimmedOrNil ?? "Untitled book"
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
        lines.append("exported: " + day(now, calendar: calendar))
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
