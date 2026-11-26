import Foundation
import ZIPFoundation

/// A zip of plain text files, for a report the owner saves and sends themselves.
public enum DiagnosticsArchive {
    public struct Entry: Equatable, Sendable {
        /// The file's name inside the zip.
        public var name: String
        public var text: String

        public init(name: String, text: String) {
            self.name = name
            self.text = text
        }
    }

    /// Writes `entries` as a zip at `url`, replacing a file that is there. Written
    /// under another name first, so a failure leaves nothing half made at `url`.
    public static func write(_ entries: [Entry], to url: URL) throws {
        let fm = FileManager.default
        let working = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).zip", isDirectory: false)
        defer { try? fm.removeItem(at: working) }
        do {
            let archive = try Archive(url: working, accessMode: .create)
            for entry in entries {
                let data = Data(entry.text.utf8)
                try archive.addEntry(
                    with: entry.name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate
                ) { position, size in
                    data.subdata(in: Int(position)..<Int(position) + size)
                }
            }
        }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: working)
        } else {
            try fm.moveItem(at: working, to: url)
        }
    }
}

extension LibraryService {
    /// What the library is made of, in words, for a diagnostics report: how many books
    /// and files of each kind, how it is laid out, and the books that need attention
    /// with what is the matter with their files.
    ///
    /// Without `includingTitles` nothing in it names a book, an author or a file:
    /// books are "Book 1", "Book 2", files are known by their kind alone, and a folder
    /// layout the owner wrote is not quoted.
    public func diagnosticsReport(includingTitles: Bool) throws -> String {
        let books = try store.books().sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        let files = try store.allFiles()
        var filesByBook: [Int64: [BookFile]] = [:]
        for file in files {
            if let id = file.bookId { filesByBook[id, default: []].append(file) }
        }

        func tally<T: Hashable>(_ values: [T], _ name: (T) -> String) -> String {
            var counts: [T: Int] = [:]
            for value in values { counts[value, default: 0] += 1 }
            let parts = counts.map { (name($0.key), $0.value) }.sorted { $0.0 < $1.0 }.map { "\($0.0) \($0.1)" }
            return parts.isEmpty ? "none" : parts.joined(separator: ", ")
        }

        var lines: [String] = []
        let withFiles = books.filter { filesByBook[$0.id ?? -1] != nil }.count
        lines.append("Books: \(books.count) (with files here: \(withFiles), owned elsewhere only: \(books.count - withFiles))")
        lines.append("Needing attention: \(books.filter(\.needsAttention).count)")
        lines.append("Not filed in a folder of the library: \(books.filter { $0.folderPath == nil && filesByBook[$0.id ?? -1] != nil }.count)")
        lines.append("Files: \(files.count)")
        lines.append("  by kind: \(tally(files.map(\.format)) { $0.rawValue })")
        lines.append("  by part: \(tally(files.map(\.role)) { $0.rawValue })")
        lines.append("Owned elsewhere: \(tally(books.flatMap { $0.externalCopies.map(\.kind) }) { $0.rawValue })")
        lines.append("Read status: \(tally(books.map(\.readStatus)) { $0.rawValue })")
        lines.append("With a stored cover: \(covers.all().count)")
        lines.append("With words counted: \(books.filter { ($0.wordCount ?? 0) > 0 }.count)")
        let pattern = (try? store.folderPatternText()) ?? nil
        if let pattern {
            lines.append("Folder layout: " + (includingTitles ? pattern : "set by the owner (\(pattern.count) characters)"))
        } else {
            lines.append("Folder layout: the standard one")
        }
        lines.append("Details files written: \(writesDetailsFiles ? "yes" : "no")")

        let flagged = books.filter(\.needsAttention)
        lines.append("")
        lines.append("Books needing attention: \(flagged.count)" + (flagged.count > 200 ? " (the first 200 follow)" : ""))
        let fm = FileManager.default
        for (index, book) in flagged.prefix(200).enumerated() {
            let rows = filesByBook[book.id ?? -1] ?? []
            let name = includingTitles
                ? "\"\(book.title)\" by \(book.authors.joined(separator: ", "))"
                : "Book \(index + 1)"
            var facts: [String] = []
            facts.append(book.folderPath == nil ? "not filed" : "filed")
            if book.title.trimmingCharacters(in: .whitespaces).isEmpty { facts.append("no title") }
            if book.authors.isEmpty { facts.append("no author") }
            lines.append("  \(name): \(facts.joined(separator: ", "))")
            for row in rows {
                let url = store.url(for: row)
                let there = fm.fileExists(atPath: url.path)
                let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64
                var said = "\(row.format.rawValue), \(row.role.rawValue)"
                said += there ? ", \(size ?? 0) bytes" : ", missing from disk"
                if row.lengthProblem != nil { said += ", states the wrong length" }
                if let problem = row.writeProblem {
                    said += includingTitles ? ", tags not written: \(problem)" : ", tags not written"
                }
                // A file kept outside the library is known by its name alone: where it
                // lies would say whose Mac this is.
                let shown = row.path.hasPrefix("/") ? (row.path as NSString).lastPathComponent : row.path
                lines.append("    " + (includingTitles ? "\(shown): " : "") + said)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
