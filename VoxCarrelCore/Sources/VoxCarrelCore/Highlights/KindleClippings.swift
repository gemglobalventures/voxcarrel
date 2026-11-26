import CryptoKit
import Foundation

/// Reads the clippings file a Kindle keeps (`documents/My Clippings.txt`): every
/// highlight and note made on the device, for books from the store and books put on
/// it by hand alike. Nothing is asked of Amazon, and the file is only read.
///
/// The file is a run of entries, each closed by a line of equals signs:
///
///     The Title (Author Name)
///     - Your Highlight on page 12 | Location 180-182 | Added on Monday, March 3, 2025 9:14:05 AM
///
///     The words that were marked.
///     ==========
///
/// A note is an entry of its own, at the place its highlight ends; a bookmark has no
/// words and is passed over. A Kindle set to another language writes the second line
/// in that language: the numbers in it are still read, and an entry whose kind cannot
/// be told is taken for a highlight.
public enum KindleClippings {
    public static let fileName = "My Clippings.txt"

    static let divider = "=========="
    /// What a Kindle writes in place of words once a book's publisher's limit is reached.
    static let limitMarks = ["<You have reached the clipping limit for this item>"]

    enum Kind { case highlight, note, bookmark }

    struct Entry {
        var title: String
        var authors: [String]
        var kind: Kind
        var page: Double?
        var start: Double?
        var end: Double?
        var added: Date?
        var text: String
    }

    /// True when the text looks like a clippings file.
    public static func looksLikeClippings(_ text: String) -> Bool {
        text.contains("\n" + divider) || text.contains("\r\n" + divider)
    }

    /// The books of a clippings file, each with its highlights in the order of the book.
    public static func books(from text: String) -> [HighlightedBook] {
        var order: [String] = []
        var byBook: [String: (title: String, authors: [String], entries: [Entry])] = [:]
        for entry in entries(in: text) where entry.kind != .bookmark {
            let key = HighlightMatch.key(entry.title) + "|" + HighlightMatch.key(entry.authors.first ?? "")
            if byBook[key] == nil {
                order.append(key)
                byBook[key] = (entry.title, entry.authors, [])
            }
            byBook[key]!.entries.append(entry)
        }
        return order.compactMap { key in
            let found = byBook[key]!
            var highlights: [IncomingHighlight] = []
            let marked = found.entries.filter { $0.kind == .highlight }
            var notes = found.entries.filter { $0.kind == .note }
            for entry in marked {
                var highlight = incoming(entry, bookKey: key)
                // A note stands at the place its highlight ends.
                if let index = notes.firstIndex(where: { $0.start != nil && ($0.start == entry.end || $0.start == entry.start) }) {
                    highlight.note = notes.remove(at: index).text
                }
                if let same = highlights.firstIndex(where: { $0.sourceId == highlight.sourceId }) {
                    if highlights[same].note == nil { highlights[same].note = highlight.note }
                } else {
                    highlights.append(highlight)
                }
            }
            // A note with no highlight to stand on is kept, as a note on nothing.
            for note in notes {
                var alone = incoming(note, bookKey: key)
                alone.text = ""
                alone.note = note.text
                if !highlights.contains(where: { $0.sourceId == alone.sourceId }) { highlights.append(alone) }
            }
            guard !highlights.isEmpty else { return nil }
            highlights.sort { ($0.location ?? .greatestFiniteMagnitude) < ($1.location ?? .greatestFiniteMagnitude) }
            return HighlightedBook(title: found.title, authors: found.authors, source: .kindle, highlights: highlights)
        }
    }

    static func incoming(_ entry: Entry, bookKey: String) -> IncomingHighlight {
        // Known again by what it is: the book, where it begins, and its words.
        let place = entry.start ?? entry.page ?? -1
        let said = "\(bookKey)|\(entry.kind == .note ? "n" : "h")|\(place)|\(HighlightMatch.key(entry.text))"
        let id = SHA256.hash(data: Data(said.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        var highlight = IncomingHighlight(sourceId: "clip-" + id, text: entry.text)
        if let start = entry.start {
            highlight.location = start
            highlight.endLocation = entry.end
            highlight.locationKind = .location
        } else if let page = entry.page {
            highlight.location = page
            highlight.locationKind = .page
        }
        highlight.madeAt = entry.added
        return highlight
    }

    // MARK: Reading the file

    static func entries(in text: String) -> [Entry] {
        let clean = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: "")
        var found: [Entry] = []
        var block: [String] = []
        for line in clean.components(separatedBy: "\n") {
            if line.hasPrefix(divider) {
                if let entry = entry(from: block) { found.append(entry) }
                block = []
            } else {
                block.append(line)
            }
        }
        return found
    }

    static func entry(from block: [String]) -> Entry? {
        var lines = block
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        guard lines.count >= 2 else { return nil }
        let (title, authors) = titleAndAuthors(lines[0])
        guard !title.isEmpty else { return nil }
        let about = lines[1]
        let text = lines.dropFirst(2).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limitMarks.contains(text) else { return nil }
        let lower = about.lowercased()
        var kind = Kind.highlight
        if lower.contains("bookmark") { kind = .bookmark } else if lower.contains(" note ") { kind = .note }
        if text.isEmpty { kind = .bookmark }
        var entry = Entry(title: title, authors: authors, kind: kind, text: text)
        let parts = about.components(separatedBy: "|")
        // The pieces that hold numbers and are not the day, in order.
        var places: [[Double]] = []
        for (index, part) in parts.enumerated() {
            // The last piece is the day, whatever language it is written in.
            if parts.count > 1, index == parts.count - 1 {
                entry.added = date(in: part)
                continue
            }
            let numbers = self.numbers(in: part)
            guard !numbers.isEmpty else { continue }
            if part.lowercased().contains("page") { entry.page = numbers[0] } else { places.append(numbers) }
        }
        // Of two that are not called a page, the first is the page and the last the place.
        if let place = places.last {
            entry.start = place[0]
            entry.end = place.count > 1 ? fullEnd(place[1], after: place[0]) : place[0]
            if places.count > 1, entry.page == nil { entry.page = places[0][0] }
        }
        return entry
    }

    /// An older Kindle writes "Loc. 1180-82" for 1180 to 1182: the end is given its
    /// missing first digits.
    static func fullEnd(_ end: Double, after start: Double) -> Double {
        guard end < start else { return end }
        var scale = 10.0
        while scale <= end { scale *= 10 }
        let full = (start / scale).rounded(.down) * scale + end
        return full >= start ? full : end
    }

    /// "The Title (Surname, Forename; Other Author)" as a title and its authors.
    static func titleAndAuthors(_ line: String) -> (String, [String]) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"), let open = trimmed.range(of: " (", options: .backwards) else { return (trimmed, []) }
        let title = String(trimmed[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
        let inside = String(trimmed[open.upperBound...].dropLast())
        let authors = inside.components(separatedBy: ";").compactMap { name -> String? in
            let name = name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            // "Le Guin, Ursula K." is "Ursula K. Le Guin".
            let sides = name.components(separatedBy: ", ")
            return sides.count == 2 ? "\(sides[1]) \(sides[0])" : name
        }
        return (title.isEmpty ? trimmed : title, authors)
    }

    /// The whole numbers of a piece of the line, in order: "Location 180-182" is 180, 182.
    static func numbers(in text: String) -> [Double] {
        var found: [Double] = []
        var digits = ""
        for character in text + " " {
            if character.isASCII, character.isNumber {
                digits.append(character)
            } else {
                if !digits.isEmpty, digits.count < 9, let number = Double(digits) { found.append(number) }
                digits = ""
            }
        }
        return found
    }

    static let dateFormats = [
        "EEEE, MMMM d, yyyy h:mm:ss a", "EEEE, d MMMM yyyy HH:mm:ss", "EEEE, MMMM d, yyyy HH:mm:ss",
        "EEEE, d MMMM yyyy h:mm:ss a", "EEEE, MMMM d, yyyy, h:mm:ss a", "EEEE, d MMMM yyyy 'at' HH:mm:ss",
    ]

    /// The day and time in "Added on Monday, March 3, 2025 9:14:05 AM", in this Mac's
    /// own time zone, since the file does not say which the Kindle was in.
    static func date(in piece: String) -> Date? {
        var text = piece.trimmingCharacters(in: .whitespaces)
        if let marker = text.range(of: "Added on ", options: .caseInsensitive) { text = String(text[marker.upperBound...]) }
        text = text.replacingOccurrences(of: "\u{202F}", with: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in dateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
