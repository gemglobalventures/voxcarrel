import Foundation
import GRDB

/// What a calibre library says of a book beyond what goes into its files: kept for
/// the book once it is in this library.
public struct CalibreExtras: Equatable, Sendable {
    /// Calibre's tags that are no genre this library knows.
    public var tags: [String] = []
    /// Stars, 0 to 5; 0 for a book that was not rated.
    public var rating = 0
    /// When the book was added to the calibre library.
    public var added: Date?

    public init() {}
}

/// A book of a calibre library, ready to be brought in.
public struct CalibreBook: Equatable, Sendable {
    public var calibreId: Int64
    /// Its files of the kinds this library keeps, its details as calibre's catalogue
    /// has them, and the cover calibre keeps beside it. `sourceFolder` is the book's
    /// own folder in the calibre library, which no two books share.
    public var candidate: CandidateBook
    public var extras: CalibreExtras
}

/// A calibre library as read: nothing in it was changed.
public struct CalibreContents: Equatable, Sendable {
    public var books: [CalibreBook] = []
    /// Titles calibre lists that have no file this library keeps: a format it does
    /// not know, or files that are not in the folder.
    public var withoutFiles: [String] = []
    /// Kinds of file that were passed over, each with how many: "KFX": 3.
    public var formatsLeftOut: [String: Int] = [:]

    public init() {}
}

public enum CalibreLibraryError: Error, Equatable {
    /// The folder has no calibre catalogue (`metadata.db`) in it.
    case notACalibreLibrary
    /// The catalogue is there and could not be read as one.
    case unreadable
}

/// Reads a calibre library: its catalogue, and where its books' files and covers are.
///
/// Nothing in the calibre library is opened for writing. The catalogue is copied to a
/// folder of the system's own and read there, so that calibre, if it is running, is
/// neither waited on nor held up; the books' files are only looked for, not opened.
public enum CalibreLibraryReader {
    public static let catalogueName = "metadata.db"

    /// True when the folder looks like a calibre library.
    public static func isCalibreLibrary(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(catalogueName).path)
    }

    public static func read(_ folder: URL) throws -> CalibreContents {
        let fm = FileManager.default
        let catalogue = folder.appendingPathComponent(catalogueName)
        guard fm.fileExists(atPath: catalogue.path) else { throw CalibreLibraryError.notACalibreLibrary }
        let work = fm.temporaryDirectory.appendingPathComponent("voxcarrel-calibre-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let copy = work.appendingPathComponent(catalogueName)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try fm.copyItem(at: catalogue, to: copy)
            var configuration = Configuration()
            configuration.readonly = true
            let queue = try DatabaseQueue(path: copy.path, configuration: configuration)
            defer { try? queue.close() }
            return try queue.read { db in try contents(db, folder: folder) }
        } catch let error as CalibreLibraryError {
            throw error
        } catch {
            throw CalibreLibraryError.unreadable
        }
    }

    // Every query keeps clear of ordering or comparing text: calibre's catalogue
    // sorts text by rules of its own that only calibre has.
    private static func contents(_ db: Database, folder: URL) throws -> CalibreContents {
        func grouped(_ sql: String) throws -> [Int64: [String]] {
            var found: [Int64: [String]] = [:]
            for row in try Row.fetchAll(db, sql: sql) {
                if let value: String = row["value"] { found[row["book"], default: []].append(value) }
            }
            return found
        }
        let authors = try grouped("""
            SELECT l.book AS book, a.name AS value FROM books_authors_link l JOIN authors a ON a.id = l.author ORDER BY l.id
            """)
        let tags = try grouped("SELECT l.book AS book, t.name AS value FROM books_tags_link l JOIN tags t ON t.id = l.tag ORDER BY l.id")
        let series = try grouped("SELECT l.book AS book, s.name AS value FROM books_series_link l JOIN series s ON s.id = l.series ORDER BY l.id")
        let publishers = try grouped("""
            SELECT l.book AS book, p.name AS value FROM books_publishers_link l JOIN publishers p ON p.id = l.publisher ORDER BY l.id
            """)
        let languages = try grouped("""
            SELECT l.book AS book, g.lang_code AS value FROM books_languages_link l JOIN languages g ON g.id = l.lang_code ORDER BY l.id
            """)
        let comments = try grouped("SELECT book, text AS value FROM comments ORDER BY id")
        var ratings: [Int64: Int] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT l.book AS book, r.rating AS rating FROM books_ratings_link l JOIN ratings r ON r.id = l.rating") {
            ratings[row["book"]] = row["rating"] ?? 0
        }
        var isbns: [Int64: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT book, type, val FROM identifiers ORDER BY id") {
            let type = (row["type"] as String? ?? "").lowercased()
            guard type == "isbn", let value: String = row["val"], isbns[row["book"]] == nil else { continue }
            isbns[row["book"]] = value
        }
        var files: [Int64: [(format: String, name: String)]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT book, format, name FROM data ORDER BY id") {
            guard let format: String = row["format"], let name: String = row["name"] else { continue }
            files[row["book"], default: []].append((format, name))
        }

        var contents = CalibreContents()
        let fm = FileManager.default
        for row in try Row.fetchAll(db, sql: "SELECT id, title, path, has_cover, series_index, pubdate, timestamp FROM books ORDER BY id") {
            let id: Int64 = row["id"]
            let title = LookupText.cleaned(row["title"] as String?, limit: LookupText.lineLimit) ?? ""
            guard let path: String = row["path"], !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..")
            else { continue }
            let bookFolder = folder.appendingPathComponent(path, isDirectory: true)

            var found: [CandidateFile] = []
            for (format, name) in files[id] ?? [] {
                let url = bookFolder.appendingPathComponent("\(name).\(format.lowercased())")
                guard let known = FileFormat(url: url) else {
                    contents.formatsLeftOut[format.uppercased(), default: 0] += 1
                    continue
                }
                if fm.fileExists(atPath: url.path) { found.append(CandidateFile(url: url, role: known.defaultRole)) }
            }
            guard !found.isEmpty, !title.isEmpty else {
                contents.withoutFiles.append(title.isEmpty ? path : title)
                continue
            }

            var metadata = BookMetadata(title: title, authors: LookupText.cleanedNames((authors[id] ?? []).map(name)))
            if let name = LookupText.cleaned(series[id]?.first, limit: LookupText.lineLimit) {
                metadata.series = name
                metadata.seriesNumber = number((row["series_index"] as Double?) ?? 1)
            }
            metadata.publisher = LookupText.cleaned(publishers[id]?.first, limit: LookupText.lineLimit)
            metadata.language = LookupText.cleaned(languages[id]?.first, limit: 40)
            metadata.isbn = LookupText.cleaned(isbns[id], limit: 20)
            metadata.year = year(row["pubdate"] as String?)
            if let html = comments[id]?.first {
                metadata.summary = LookupText.cleaned(LookupText.plainText(fromHTML: html), limit: 20000, multiline: true)
            }
            // A tag that names a genre this library knows is the book's genre; the
            // rest stay tags.
            var extras = CalibreExtras()
            var genres: [String] = []
            for tag in (tags[id] ?? []).compactMap({ LookupText.cleaned($0, limit: 80) }) {
                let known = GenreMapping.map(.subjects([tag])).builtIn
                if known.isEmpty { extras.tags.append(tag) } else { genres += known }
            }
            metadata.genres = GenreName.distinct(genres)
            if !genres.isEmpty { metadata.genreSource = GenreMapping.wording(of: .subjects(tags[id] ?? [])) }
            extras.tags = GenreName.distinct(extras.tags)
            // Calibre counts in half stars.
            extras.rating = min(5, max(0, ((ratings[id] ?? 0) + 1) / 2))
            extras.added = date(row["timestamp"] as String?)

            var candidate = CandidateBook(files: found, metadata: metadata, sourceFolder: bookFolder)
            let cover = bookFolder.appendingPathComponent("cover.jpg")
            if (row["has_cover"] as Bool?) ?? false, fm.fileExists(atPath: cover.path) { candidate.coverBeside = cover }
            contents.books.append(CalibreBook(calibreId: id, candidate: candidate, extras: extras))
        }
        return contents
    }

    /// Calibre keeps a comma inside a name as a bar: "Herron| Mick".
    static func name(_ stored: String) -> String {
        stored.replacingOccurrences(of: "|", with: ",")
    }

    /// "2" for 2.0, "2.5" for 2.5.
    static func number(_ index: Double) -> String? {
        guard index.isFinite, index >= 0, index < 100_000 else { return nil }
        return index == index.rounded() ? String(Int(index)) : String(format: "%g", index)
    }

    /// The year of a date as calibre writes it; nil for the year 101, which is how it
    /// writes "not known".
    static func year(_ text: String?) -> Int? {
        guard let text, let year = Int(text.prefix(4)), year >= 1000, year <= 9999 else { return nil }
        return year
    }

    /// "2020-05-01 12:34:56.789000+00:00", with or without the fraction.
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let tidy = text.replacingOccurrences(of: " ", with: "T")
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: tidy) ?? ISO8601DateFormatter().date(from: tidy) { return date }
        // Six places of fraction are more than the formatter takes: read without them.
        guard let dot = tidy.firstIndex(of: "."), let zone = tidy[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" })
        else { return nil }
        return ISO8601DateFormatter().date(from: String(tidy[..<dot]) + String(tidy[zone...]))
    }
}

extension LibraryService {
    /// What reading a calibre library gives the import: its books as a scan, with the
    /// files this library already holds set aside as for any other scan.
    public struct CalibreScan: Sendable {
        public var scan: ScanResult
        /// What calibre says beyond the files, by the book's folder in the calibre
        /// library (`CandidateBook.sourceFolder`).
        public var extras: [URL: CalibreExtras]
        public var withoutFiles: [String]
        public var formatsLeftOut: [String: Int]
    }

    /// Reads a calibre library for importing. Nothing is changed, here or there.
    public func scanCalibreLibrary(_ folder: URL) throws -> CalibreScan {
        let contents = try CalibreLibraryReader.read(folder)
        var result = ScanResult()
        var extras: [URL: CalibreExtras] = [:]
        // Calibre lists a book again for every time it was added. Two entries with no
        // audio, the same title and the same first author are one book here, as they
        // are in any other scan: their files go together under the first one's details.
        var firstByKey: [String: Int] = [:]
        for book in contents.books {
            var candidate = book.candidate
            // The genres are the library's own names for them.
            candidate.metadata.genres = listedGenres(candidate.metadata.genres)
            let title = KnownNames.titleKey(candidate.metadata.title)
            let author = KnownNames.authorKey(candidate.metadata.authors.first ?? "")
            let key = title.isEmpty || author.isEmpty || candidate.hasAudio ? nil : title + "\u{0}" + author
            if let key, let owner = firstByKey[key], let folder = result.candidates[owner].sourceFolder {
                let held = Set(result.candidates[owner].files.map(\.url.lastPathComponent))
                result.candidates[owner].files += candidate.files.filter { !held.contains($0.url.lastPathComponent) }
                result.candidates[owner].coverBeside = result.candidates[owner].coverBeside ?? candidate.coverBeside
                var joined = extras[folder] ?? CalibreExtras()
                joined.tags = GenreName.distinct(joined.tags + book.extras.tags)
                joined.rating = max(joined.rating, book.extras.rating)
                joined.added = [joined.added, book.extras.added].compactMap { $0 }.min()
                extras[folder] = joined
                continue
            }
            if let key { firstByKey[key] = result.candidates.count }
            result.candidates.append(candidate)
            if let folder = candidate.sourceFolder { extras[folder] = book.extras }
        }
        setAsideWhatTheLibraryHolds(in: &result)
        return CalibreScan(
            scan: result, extras: extras, withoutFiles: contents.withoutFiles, formatsLeftOut: contents.formatsLeftOut)
    }

    /// Gives a book that came from calibre what calibre said of it beyond its files:
    /// its tags are added to the book's own; its rating is taken when the book has
    /// none; and the book is dated from when calibre got it, when that is earlier.
    /// What the book has is never lost. An id no book has does nothing.
    public func apply(_ extras: CalibreExtras, toBook bookId: Int64) throws {
        guard try store.book(id: bookId) != nil else { return }
        _ = try store.modifyBook(id: bookId) { book, _ in
            book.tags = GenreName.distinct(book.tags + extras.tags)
            if book.rating == 0 { book.rating = extras.rating }
            if let added = extras.added, added < book.dateAdded { book.dateAdded = added }
        }
    }
}
