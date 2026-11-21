import Foundation
import UniformTypeIdentifiers
import VoxCarrelCore
import VoxCarrelFixtures

public enum DemoError: Error, CustomStringConvertible {
    /// The folder already holds something; demo content is only ever made in a new or empty folder.
    case folderNotEmpty(URL)
    /// The sample books did not import as expected.
    case importFailed(String)

    public var description: String {
        switch self {
        case .folderNotEmpty(let folder):
            return "\(folder.path) already exists and is not empty"
        case .importFailed(let reason):
            return "The sample books could not be imported: \(reason)"
        }
    }
}

/// Generated sample books for trying the app out, so no real book is ever touched.
public enum DemoContent {
    /// The folder, inside the inbox and inside the demo library, that holds the book with
    /// no author. Its name is one the scanner knows as a place, so no author is guessed
    /// from it.
    static let genericFolderName = "Downloads"

    // MARK: Inbox

    /// Loose sample files, not yet imported: the input for an import.
    /// Returns the folder's top-level items.
    @discardableResult
    public static func makeInbox(at folder: URL) throws -> [URL] {
        try prepareEmptyFolder(folder)
        var cover = CoverMaker()

        // Standalone audiobook: one M4B with chapters.
        var lighthouse = BookMetadata(title: "The Lighthouse Keeper", authors: ["Eleanor Marsh"])
        lighthouse.narrators = ["Tom Hale"]
        lighthouse.genre = "Literary Fiction"
        lighthouse.year = 2019
        lighthouse.publisher = "Harbour Audio"
        lighthouse.summary = "A keeper on a remote rock counts the ships that never arrive."
        try makeAudiobook(at: folder.appendingPathComponent("The Lighthouse Keeper.m4b"), lighthouse, cover.next())

        // Series, books 1–3: an M4B each, in one folder.
        let seriesFolder = folder.appendingPathComponent("Tidewater Chronicles", isDirectory: true)
        let seriesTitles = ["Salt Road", "The Drowned Bell", "Harbour of Glass"]
        for (index, title) in seriesTitles.enumerated() {
            var book = BookMetadata(title: title, authors: ["Ines Calloway"])
            book.narrators = ["Marcus Lindqvist"]
            book.series = "Tidewater Chronicles"
            book.seriesNumber = String(index + 1)
            book.genre = "Fantasy"
            book.year = 2014 + index
            try makeAudiobook(at: seriesFolder.appendingPathComponent("\(title).m4b"), book, cover.next())
        }

        // Multi-part audiobook: a folder of four MP3s.
        var train = BookMetadata(title: "Night Train to Vostok", authors: ["Mikhail Orlov"])
        train.narrators = ["Anna Petrova"]
        train.genre = "Thriller"
        train.year = 2008
        let trainFolder = folder.appendingPathComponent("Night Train to Vostok", isDirectory: true)
        let trainCover = cover.next()
        for part in 1...4 {
            let url = trainFolder.appendingPathComponent("Night Train to Vostok - Part \(part).mp3")
            try write(MediaFixtures.makeSilentMP3(seconds: 1), to: url)
            try FileMetadataIO().write(
                train, cover: .set(trainCover), part: PartPosition(index: part, count: 4), to: url)
        }

        // Audiobook with ebook: differently named files that share only their folder,
        // so it is the dedicated folder that makes them one book.
        var clockmaker = BookMetadata(title: "The Clockmaker's Apprentice", authors: ["Ruth Abernathy"])
        clockmaker.narrators = ["Simon Feld"]
        clockmaker.genre = "Historical Fiction"
        clockmaker.year = 2021
        let clockFolder = folder.appendingPathComponent("The Clockmaker's Apprentice", isDirectory: true)
        let clockCover = cover.next()
        try makeAudiobook(
            at: clockFolder.appendingPathComponent("The Clockmaker's Apprentice (Unabridged).m4b"),
            clockmaker, clockCover)
        try makeEbook(at: clockFolder.appendingPathComponent("clockmakers-apprentice.epub"), clockmaker, clockCover)

        // Audiobook with companion: an M4B and a PDF with the same base name.
        var fieldGuide = BookMetadata(title: "A Field Guide to Small Hours", authors: ["Jonas Whitlock"])
        fieldGuide.narrators = ["Jonas Whitlock"]
        fieldGuide.genre = "Nature"
        fieldGuide.year = 2017
        try makeAudiobook(at: folder.appendingPathComponent("A Field Guide to Small Hours.m4b"), fieldGuide, cover.next())
        try makePDF(at: folder.appendingPathComponent("A Field Guide to Small Hours.pdf"), nil)

        // Ebook only.
        var rivers = BookMetadata(title: "Quiet Rivers", authors: ["Amara Okafor"])
        rivers.genre = "Poetry"
        rivers.year = 2012
        rivers.publisher = "Reedbank Press"
        try makeEbook(at: folder.appendingPathComponent("Quiet Rivers.epub"), rivers, cover.next())

        // Ebook in two formats: an EPUB and a PDF with the same base name.
        var cartographer = BookMetadata(title: "The Cartographer's Daughter", authors: ["Lena Voss"])
        cartographer.genre = "Adventure"
        cartographer.year = 2003
        try makeEbook(at: folder.appendingPathComponent("The Cartographer's Daughter.epub"), cartographer, cover.next())
        try makePDF(at: folder.appendingPathComponent("The Cartographer's Daughter.pdf"), cartographer)

        // Two authors.
        var wheel = BookMetadata(title: "Two Hands on the Wheel", authors: ["Priya Nair", "Daniel Brandt"])
        wheel.genre = "Memoir"
        wheel.year = 2022
        try makeEbook(at: folder.appendingPathComponent("Two Hands on the Wheel.epub"), wheel, cover.next())

        // No author: a title only, in a folder whose name is a place and not an author.
        let attic = BookMetadata(title: "Voices from the Attic")
        try makeAudiobook(
            at: folder.appendingPathComponent(genericFolderName, isDirectory: true)
                .appendingPathComponent("voices_from_the_attic.m4b"),
            attic, cover.next())

        // Long title: 90 characters, and a subtitle.
        var history = BookMetadata(
            title: "An Exhaustive and Occasionally Reliable History of the Northern Sea Routes and Their Ports",
            authors: ["Bartholomew Featherstonehaugh"])
        history.subtitle = "Being an Account of Ice, Commerce and Stubbornness from the Earliest Voyages to the Present Day"
        history.narrators = ["Clementine Ashworth-Delacroix"]
        history.genre = "History"
        history.year = 1998
        try makeAudiobook(at: folder.appendingPathComponent("Northern Sea Routes.m4b"), history, cover.next())

        return try topLevelItems(of: folder)
    }

    // MARK: Library

    /// A library with the inbox's books already imported, plus read statuses,
    /// tags, ratings and two collections.
    public static func makeLibrary(at folder: URL) throws {
        try prepareEmptyFolder(folder)
        let fm = FileManager.default

        let scratch = try makeTempDir()
        defer { try? fm.removeItem(at: scratch) }
        let inbox = scratch.appendingPathComponent("Inbox", isDirectory: true)
        try makeInbox(at: inbox)

        // A book that cannot be filed is catalogued where it lies and never moved, so
        // the one with no author must already be somewhere that outlives the inbox:
        // it goes inside the library folder first, under the same generic name.
        let generic = folder.appendingPathComponent(genericFolderName, isDirectory: true)
        try fm.moveItem(at: inbox.appendingPathComponent(genericFolderName, isDirectory: true), to: generic)

        let service = LibraryService(store: try LibraryStore(libraryRoot: folder))
        let scan = service.scan(try topLevelItems(of: inbox) + [generic])
        guard scan.skipped.isEmpty else {
            throw DemoError.importFailed("skipped " + scan.skipped.map(\.lastPathComponent).joined(separator: ", "))
        }

        let result = try service.importItems(
            scan.candidates.map { ImportItem(candidate: $0) }, options: ImportOptions(mode: .move))
        var unfiled = 0
        for (candidate, outcome) in zip(scan.candidates, result.outcomes) {
            let title = candidate.metadata.title
            switch outcome {
            case .imported(_, let problems):
                if let problem = problems.first {
                    throw DemoError.importFailed("\(title): \(problem.file): \(problem.reason)")
                }
            case .needsAttention:
                unfiled += 1
            case .failed(let reason):
                throw DemoError.importFailed("\(title): \(reason)")
            }
        }
        guard unfiled == 1 else {
            throw DemoError.importFailed("\(unfiled) books could not be filed; exactly one was meant not to be")
        }

        // What the user would have done since: reading, tagging, rating, collecting.
        let store = service.store
        var books: [String: Book] = [:]
        for book in try store.books() { books[book.title] = book }
        func book(_ title: String) throws -> Book {
            guard let book = books[title] else { throw DemoError.importFailed("\"\(title)\" is not in the library") }
            return book
        }
        func ids(_ titles: [String]) throws -> [Int64] {
            try titles.compactMap { try book($0).id }
        }

        try service.setReadStatus(.finished, for: try ids(["The Lighthouse Keeper", "Salt Road", "Quiet Rivers"]))
        try service.setReadStatus(
            .inProgress, for: try ids(["The Drowned Bell", "Night Train to Vostok", "Two Hands on the Wheel"]))

        let marks: [(title: String, tags: [String], rating: Int)] = [
            ("The Lighthouse Keeper", ["favourite", "sea"], 5),
            ("Salt Road", ["sea", "comfort listen"], 4),
            ("The Drowned Bell", ["sea"], 0),
            ("Night Train to Vostok", ["travel", "cold war"], 3),
            ("Quiet Rivers", ["favourite"], 5),
            ("The Clockmaker's Apprentice", ["book club"], 4),
            ("Two Hands on the Wheel", [], 2),
        ]
        let edits = try marks.map { mark -> BookEdit in
            var edit = BookEdit(book: try book(mark.title))
            edit.tags = mark.tags
            edit.rating = mark.rating
            return edit
        }
        for outcome in try service.save(edits) {
            if case .failed(let bookId, let reason) = outcome {
                throw DemoError.importFailed("book \(bookId) could not be marked: \(reason)")
            }
        }

        let collections: [(name: String, titles: [String])] = [
            ("Favourites", ["The Lighthouse Keeper", "Quiet Rivers", "Salt Road"]),
            ("Holiday Listening", [
                "Night Train to Vostok", "The Clockmaker's Apprentice", "A Field Guide to Small Hours",
                "Harbour of Glass",
            ]),
        ]
        for collection in collections {
            guard let id = try store.createCollection(name: collection.name).id else { continue }
            for bookId in try ids(collection.titles) {
                try store.add(bookId: bookId, toCollection: id)
            }
        }
    }

    // MARK: Folders

    /// Creates the folder if it is not there; throws if it holds anything.
    private static func prepareEmptyFolder(_ folder: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.path) {
            // Throws for something that is not a folder, too.
            guard try fm.contentsOfDirectory(atPath: folder.path).isEmpty else {
                throw DemoError.folderNotEmpty(folder)
            }
        } else {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    private static func topLevelItems(of folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    // MARK: Sample files

    /// Hands out a cover of a different colour each time it is asked.
    private struct CoverMaker {
        private var count = 0

        mutating func next() -> CoverImage {
            // `MediaFixtures.makeImage` varies only the red channel; stepping by 5/12
            // and wrapping puts neighbouring books far apart.
            let red = CGFloat((count * 5) % 12) / 11
            count += 1
            return CoverImage(data: MediaFixtures.makeImage(.jpeg, size: 600, red: red), mime: "image/jpeg")
        }
    }

    /// A two-second M4B with three chapters, tagged and with a cover.
    private static func makeAudiobook(at url: URL, _ metadata: BookMetadata, _ cover: CoverImage) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MediaFixtures.makeChapteredM4B(at: url, seconds: 2, chapters: [
            (start: 0, title: "Opening"), (start: 0.7, title: "Chapter One"), (start: 1.4, title: "Chapter Two"),
        ])
        try FileMetadataIO().write(metadata, cover: .set(cover), to: url)
    }

    private static func makeEbook(at url: URL, _ metadata: BookMetadata, _ cover: CoverImage) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MediaFixtures.makeEPUB(at: url, files: [
            ("OEBPS/content.opf", Data(blankOPF().utf8)),
            ("OEBPS/nav.xhtml", Data(MediaFixtures.nav.utf8)),
            ("OEBPS/ch1.xhtml", Data(MediaFixtures.chapter.utf8)),
        ])
        try FileMetadataIO().write(metadata, cover: .set(cover), to: url)
    }

    /// - Parameter metadata: Nil leaves the PDF as generated (a companion is never tagged).
    private static func makePDF(at url: URL, _ metadata: BookMetadata?) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        MediaFixtures.makePDF(at: url)
        if let metadata { try FileMetadataIO().write(metadata, to: url) }
    }

    /// A minimal EPUB 3 package for `FileMetadataIO` to fill in.
    private static func blankOPF() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id" xml:lang="en">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="pub-id">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier>
            <dc:title>Untitled</dc:title>
            <dc:language>en</dc:language>
            <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="ch1"/>
          </spine>
        </package>
        """
    }
}
