import Foundation

/// The details file written beside a book: `metadata.opf`, in the form other library
/// managers read, so a library can be picked up elsewhere with its details intact.
///
/// The text depends on the book alone: the same book always gives the same bytes.
public enum DetailsFile {
    public static let fileName = "metadata.opf"

    /// The details file written beside a book that has an audiobook: the one
    /// Audiobookshelf reads when it scans a folder of books.
    public static let audiobookFileName = "metadata.json"

    /// What marks an audiobook's details file as written here: a key of its own,
    /// which a reader of the file passes over.
    static let audiobookMark = "\"x-voxcarrel\""

    /// True for the name of a details file, of either kind.
    public static func isOwnName(_ name: String) -> Bool {
        name == fileName || name == audiobookFileName
    }

    /// The picture a details file names as the cover when it lies beside it.
    static let coverName = "cover.jpg"

    /// What marks a details file as written here. One that lacks it is somebody
    /// else's, and is never overwritten or removed.
    static let mark = "opf:scheme=\"voxcarrel\""

    /// True when the file at `url` is a details file written here.
    static func isOurs(at url: URL) -> Bool {
        guard isOwnName(url.lastPathComponent),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size < 2_000_000, let data = try? Data(contentsOf: url)
        else { return false }
        let wanted = url.lastPathComponent == fileName ? mark : audiobookMark
        return data.range(of: Data(wanted.utf8)) != nil
    }

    /// True when a folder that holds only these names holds nothing of anyone's: a
    /// `.DS_Store`, and a details file written here.
    static func holdsNothingElse(_ names: [String], in folder: URL) -> Bool {
        names.allSatisfy { name in
            name == ".DS_Store" || (isOwnName(name) && isOurs(at: folder.appendingPathComponent(name)))
        }
    }

    /// Takes the details file written here out of `folder`, if that is all the folder
    /// holds besides a `.DS_Store`. A folder with anything else in it is left as it is.
    static func removeIfAlone(in folder: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path), names.contains(where: isOwnName),
              holdsNothingElse(names, in: folder)
        else { return }
        for name in names where isOwnName(name) {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// An audiobook's details file for `book`, as Audiobookshelf reads it: what the
    /// book is, and nothing of its chapters, which that program reads from the audio
    /// itself. A series is written with its number after it, as in "Tidewater #2".
    public static func audiobookData(for book: Book) -> Data {
        func said(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        var details: [String: Any] = ["x-voxcarrel": book.id ?? 0, "title": said(book.title) ?? "Unknown"]
        if let subtitle = said(book.subtitle) { details["subtitle"] = subtitle }
        if !book.authors.isEmpty { details["authors"] = book.authors }
        if !book.narrators.isEmpty { details["narrators"] = book.narrators }
        if let series = said(book.series) {
            // A number with a space or a "#" in it would be read as part of the name.
            let number = said(book.seriesNumber).flatMap { $0.contains(" ") || $0.contains("#") ? nil : $0 }
            details["series"] = [number.map { "\(series) #\($0)" } ?? series]
        }
        if !book.genres.isEmpty { details["genres"] = book.genres }
        if !book.tags.isEmpty { details["tags"] = book.tags }
        if let year = book.year, (1...9999).contains(year) { details["publishedYear"] = String(year) }
        if let publisher = said(book.publisher) { details["publisher"] = publisher }
        if let summary = said(book.summary) { details["description"] = summary }
        if let isbn = said(book.isbn) { details["isbn"] = isbn }
        if let asin = said(book.asin) { details["asin"] = asin }
        if let language = said(book.language) { details["language"] = language }
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = (try? JSONSerialization.data(withJSONObject: details, options: options)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    /// The details file's text for `book`.
    /// - Parameter hasCoverBeside: Whether a `cover.jpg` lies in the book's folder.
    public static func text(for book: Book, hasCoverBeside: Bool = false) -> String {
        var lines: [String] = []
        func add(_ name: String, _ value: String?, _ attributes: String = "") {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            lines.append("    <dc:\(name)\(attributes)>\(escaped(value))</dc:\(name)>")
        }
        func meta(_ name: String, _ content: String?) {
            guard let content = content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { return }
            lines.append("    <meta name=\"\(name)\" content=\"\(escaped(content))\"/>")
        }

        lines.append("    <dc:identifier id=\"voxcarrel_id\" opf:scheme=\"voxcarrel\">\(book.id ?? 0)</dc:identifier>")
        add("title", book.title.isEmpty ? "Unknown" : book.title)
        for author in book.authors {
            add("creator", author, " opf:role=\"aut\" opf:file-as=\"\(escaped(fileAs(author)))\"")
        }
        for narrator in book.narrators { add("contributor", narrator, " opf:role=\"nrt\"") }
        add("publisher", book.publisher)
        if let year = book.year, (1...9999).contains(year) {
            add("date", String(format: "%04d-01-01T00:00:00+00:00", year))
        }
        add("language", book.language)
        add("description", book.summary)
        add("identifier", book.isbn, " opf:scheme=\"ISBN\"")
        add("identifier", book.asin, " opf:scheme=\"ASIN\"")
        var seen = Set<String>()
        for subject in book.genres + book.tags where seen.insert(subject.lowercased()).inserted {
            add("subject", subject)
        }
        if let series = book.series?.trimmingCharacters(in: .whitespacesAndNewlines), !series.isEmpty {
            meta("calibre:series", series)
            if let number = book.seriesNumber.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
               number.isFinite, number >= 0 {
                meta("calibre:series_index", number == number.rounded() ? String(Int(number)) : String(number))
            }
        }
        // Out of ten there, out of five here.
        if (1...5).contains(book.rating) { meta("calibre:rating", String(book.rating * 2)) }
        meta("calibre:timestamp", timestamp(book.dateAdded))
        meta("voxcarrel:subtitle", book.subtitle)
        // Which other editions in the library are of the same book.
        meta("voxcarrel:work", book.workKey)
        if let number = book.seriesNumber { meta("voxcarrel:series_number", number) }

        var text = "<?xml version='1.0' encoding='utf-8'?>\n"
        text += "<package xmlns=\"http://www.idpf.org/2007/opf\" unique-identifier=\"voxcarrel_id\" version=\"2.0\">\n"
        text += "  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:opf=\"http://www.idpf.org/2007/opf\">\n"
        text += lines.joined(separator: "\n") + "\n"
        text += "  </metadata>\n"
        if hasCoverBeside {
            text += "  <guide>\n    <reference type=\"cover\" title=\"Cover\" href=\"\(coverName)\"/>\n  </guide>\n"
        }
        text += "</package>\n"
        return text
    }

    /// "Le Guin, Ursula K." for "Ursula K. Le Guin" is beyond guessing: the last word
    /// goes first, and a name of one word stays as it is.
    static func fileAs(_ name: String) -> String {
        let words = name.split(separator: " ").map(String.init)
        guard words.count > 1, !name.contains(",") else { return name }
        return words[words.count - 1] + ", " + words.dropLast().joined(separator: " ")
    }

    /// Made once: making one is slow, and it is safe to use from anywhere.
    private static let stamper: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func timestamp(_ date: Date) -> String {
        stamper.string(from: date).replacingOccurrences(of: "Z", with: "+00:00")
    }

    /// Text made safe for XML: the five characters that mean something there, and the
    /// control characters XML does not allow, which are dropped.
    static func escaped(_ text: String) -> String {
        // Most text has nothing in it to change.
        guard text.unicodeScalars.contains(where: { scalar in
            scalar == "&" || scalar == "<" || scalar == ">" || scalar == "\"" || scalar == "'" || scalar.value < 0x20
                || scalar.value == 0xFFFE || scalar.value == 0xFFFF
        }) else { return text }
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
