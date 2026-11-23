import CoreGraphics
import CoreText
import Foundation
import ImageIO
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
        try makeAudiobook(at: folder.appendingPathComponent("The Lighthouse Keeper.m4b"), lighthouse, cover.next(lighthouse))

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
            try makeAudiobook(at: seriesFolder.appendingPathComponent("\(title).m4b"), book, cover.next(book))
        }

        // Multi-part audiobook: a folder of four MP3s.
        var train = BookMetadata(title: "Night Train to Vostok", authors: ["Mikhail Orlov"])
        train.narrators = ["Anna Petrova"]
        train.genre = "Thriller"
        train.year = 2008
        let trainFolder = folder.appendingPathComponent("Night Train to Vostok", isDirectory: true)
        let trainCover = cover.next(train, square: true)
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
        let clockCover = cover.next(clockmaker)
        try makeAudiobook(
            at: clockFolder.appendingPathComponent("The Clockmaker's Apprentice (Unabridged).m4b"),
            clockmaker, clockCover)
        try makeEbook(at: clockFolder.appendingPathComponent("clockmakers-apprentice.epub"), clockmaker, clockCover)

        // Audiobook with companion: an M4B and a PDF with the same base name.
        var fieldGuide = BookMetadata(title: "A Field Guide to Small Hours", authors: ["Jonas Whitlock"])
        fieldGuide.narrators = ["Jonas Whitlock"]
        fieldGuide.genre = "Nature"
        fieldGuide.year = 2017
        try makeAudiobook(at: folder.appendingPathComponent("A Field Guide to Small Hours.m4b"), fieldGuide, cover.next(fieldGuide))
        try makePDF(at: folder.appendingPathComponent("A Field Guide to Small Hours.pdf"), nil)

        // Ebook only.
        var rivers = BookMetadata(title: "Quiet Rivers", authors: ["Amara Okafor"])
        rivers.genre = "Poetry"
        rivers.year = 2012
        rivers.publisher = "Reedbank Press"
        try makeEbook(at: folder.appendingPathComponent("Quiet Rivers.epub"), rivers, cover.next(rivers, square: true))

        // Ebook in two formats: an EPUB and a PDF with the same base name.
        var cartographer = BookMetadata(title: "The Cartographer's Daughter", authors: ["Lena Voss"])
        cartographer.genre = "Adventure"
        cartographer.year = 2003
        try makeEbook(at: folder.appendingPathComponent("The Cartographer's Daughter.epub"), cartographer, cover.next(cartographer))
        try makePDF(at: folder.appendingPathComponent("The Cartographer's Daughter.pdf"), cartographer)

        // Two authors.
        var wheel = BookMetadata(title: "Two Hands on the Wheel", authors: ["Priya Nair", "Daniel Brandt"])
        wheel.genre = "Memoir"
        wheel.year = 2022
        try makeEbook(at: folder.appendingPathComponent("Two Hands on the Wheel.epub"), wheel, cover.next(wheel))

        // No author: a title only, in a folder whose name is a place and not an author.
        let attic = BookMetadata(title: "Voices from the Attic")
        try makeAudiobook(
            at: folder.appendingPathComponent(genericFolderName, isDirectory: true)
                .appendingPathComponent("voices_from_the_attic.m4b"),
            attic, cover.next(attic))

        // Long title: 90 characters, and a subtitle.
        var history = BookMetadata(
            title: "An Exhaustive and Occasionally Reliable History of the Northern Sea Routes and Their Ports",
            authors: ["Bartholomew Featherstonehaugh"])
        history.subtitle = "Being an Account of Ice, Commerce and Stubbornness from the Earliest Voyages to the Present Day"
        history.narrators = ["Clementine Ashworth-Delacroix"]
        history.genre = "History"
        history.year = 1998
        try makeAudiobook(at: folder.appendingPathComponent("Northern Sea Routes.m4b"), history, cover.next(history))

        return try topLevelItems(of: folder)
    }

    // MARK: Library

    /// A library with the inbox's books already imported, plus read statuses,
    /// tags, ratings and two collections; and two books that are owned on Audible and
    /// have no files here, with one of the imported audiobooks marked as also on Audible.
    ///
    /// - Parameters:
    ///   - count: How many books the library is to have. Above the fourteen sample
    ///     books, the rest are copies of the ones with files under numbered titles, with
    ///     other authors, series, lengths and read statuses: enough to try the app on a
    ///     large library. No audio is encoded for them, so thousands are made in seconds.
    ///   - audible: False leaves out everything to do with Audible: the twelve sample
    ///     books that have files, none of them marked.
    public static func makeLibrary(at folder: URL, count: Int = 0, audible: Bool = true) throws {
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

        if audible { try addAudibleBooks(to: service, alsoOnAudible: try book(alsoOnAudibleTitle)) }

        try addNumberedBooks(to: service, upTo: count)
    }

    // MARK: Books on Audible

    /// The Audible store the demo books are owned in.
    static let audibleStore = AudibleStore.uk.rawValue
    /// The imported audiobook that is marked as also owned on Audible.
    static let alsoOnAudibleTitle = "The Lighthouse Keeper"

    /// Two books that are owned on Audible and have no files here: the fourth book of the
    /// series whose first three are files, and one that stands alone. One book that has
    /// files is marked as also on Audible. The ASINs are made up; nothing is asked of Audible.
    private static func addAudibleBooks(to service: LibraryService, alsoOnAudible local: Book) throws {
        var cover = CoverMaker(startingAt: try service.store.books().count)

        var glassTide = BookMetadata(title: "The Glass Tide", authors: ["Ines Calloway"])
        glassTide.narrators = ["Marcus Lindqvist"]
        glassTide.series = "Tidewater Chronicles"
        glassTide.seriesNumber = "4"
        glassTide.genre = "Fantasy"
        glassTide.year = 2018
        glassTide.publisher = "Tidewater Audio"
        glassTide.language = "en"
        glassTide.summary = "The harbour is rebuilt in glass, and the sea comes back for what it is owed."
        glassTide.durationSeconds = 11 * 3600 + 24 * 60

        var iceShelf = BookMetadata(title: "Letters from the Ice Shelf", authors: ["Solveig Aaberg"])
        iceShelf.narrators = ["Freya Dahl"]
        iceShelf.genre = "Travel"
        iceShelf.year = 2020
        iceShelf.publisher = "Northlight Audio"
        iceShelf.language = "en"
        iceShelf.summary = "A winter at a research station, written home one letter at a time."
        iceShelf.durationSeconds = 8 * 3600 + 5 * 60

        // The series' covers are upright; the other is square, as Audible's covers are.
        let onlyThere: [(metadata: BookMetadata, asin: String, square: Bool)] = [
            (glassTide, "B0DEMO0004", false), (iceShelf, "B0DEMO0002", true),
        ]
        for book in onlyThere {
            let copy = ExternalCopy(kind: .audible, form: .audio, store: audibleStore, itemId: book.asin)
            let outcome = try service.addExternalBook(
                metadata: book.metadata, cover: cover.next(book.metadata, square: book.square), copy: copy)
            guard case .added = outcome else {
                throw DemoError.importFailed("\"\(book.metadata.title)\" was already in the library")
            }
        }

        guard let id = local.id else { return }
        try service.setExternalCopies(
            [ExternalCopy(kind: .audible, form: .audio, store: audibleStore, itemId: "B0DEMO0001")], for: id)
    }

    // MARK: A large library

    private static let authorPool = [
        "Eleanor Marsh", "Ines Calloway", "Mikhail Orlov", "Ruth Abernathy", "Jonas Whitlock", "Amara Okafor",
        "Lena Voss", "Priya Nair", "Daniel Brandt", "Hugo Lindqvist", "Marguerite Bellamy", "Tobias Ferreira",
        "Saoirse Kavanagh", "Kenji Morimoto", "Odalys Rivera", "Wilhelmina Drake", "Farid Rahimi", "Cecily Thorne",
        "Anselm Krüger", "Nadia El-Masri", "Per Østergaard", "Josephine Achebe", "Leopold Varga", "Ysolde Penhallow",
    ]

    private static let seriesPool = [
        "Tidewater Chronicles", "The Lantern Cycle", "Inspector Hallam Mysteries", "Atlas of Winds",
        "The Glass Republic", "Orchard Lane", "Nine Bridges", "Far Meridian",
    ]

    private static let genrePool = [
        "Fantasy", "Thriller", "Literary Fiction", "History", "Science Fiction", "Mystery", "Memoir", "Nature",
        "Poetry", "Adventure",
    ]

    /// Brings the library up to `total` books by copying the sample books that are filed
    /// (those on Audible with no files here have nothing to copy).
    ///
    /// Each new book gets a folder and files of its own, where the library would have
    /// filed them, and a record put straight into the catalogue. The files are copies of
    /// a sample book's, so the tags inside them are that book's; nothing looks inside
    /// them unless the book is opened or its tags are rewritten.
    private static func addNumberedBooks(to service: LibraryService, upTo total: Int) throws {
        let store = service.store
        let fm = FileManager.default
        let existing = try store.books().sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        var templates: [(book: Book, files: [BookFile])] = []
        for book in existing {
            guard let id = book.id, book.folderPath != nil else { continue }
            templates.append((book, try store.files(bookId: id)))
        }
        guard total > existing.count, !templates.isEmpty else { return }

        var cover = CoverMaker(startingAt: existing.count)
        let now = Date()
        for number in (existing.count + 1)...total {
            let template = templates[number % templates.count]
            let hasAudio = template.files.contains { $0.role == .audio }

            var metadata = template.book.metadata
            metadata.title = "\(template.book.title) \(number)"
            metadata.authors = [authorPool[(number * 7) % authorPool.count]]
            if number % 11 == 0 { metadata.authors.append(authorPool[(number * 5 + 3) % authorPool.count]) }
            if number % 3 == 0 {
                metadata.series = seriesPool[(number / 3) % seriesPool.count]
                metadata.seriesNumber = String((number / (3 * seriesPool.count)) % 12 + 1)
            } else {
                metadata.series = nil
                metadata.seriesNumber = nil
            }
            // The template's Audible ID is its own.
            metadata.asin = nil
            metadata.genre = genrePool[number % genrePool.count]
            metadata.year = 1985 + (number * 3) % 40
            // Two to thirty hours for something to listen to.
            metadata.durationSeconds = hasAudio ? Double(7200 + (number * 9973) % 100_800) : nil

            // FP25: the demo library is filed by the standard pattern.
            guard let folderPath = PathBuilder.bookFolder(
                values: FolderPatternValues(metadata: metadata, hasAudio: hasAudio), pattern: .standard)
            else { continue }
            let names = PathBuilder.fileNames(
                title: metadata.title,
                files: template.files.map { CandidateFile(url: store.url(for: $0), role: $0.role) })
            var files: [BookFile] = []
            for (file, name) in zip(template.files, names) {
                var copy = BookFile(
                    path: "\(folderPath)/\(name)", format: file.format, role: file.role, position: file.position)
                copy.originalName = file.originalName
                let destination = store.url(for: copy)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: store.url(for: file), to: destination)
                files.append(copy)
            }
            // A few books whose tags could not be written, to show the warning.
            if number % 40 == 0, !files.isEmpty {
                files[0].writeProblem = "The file could not be changed."
            }

            let added = now.addingTimeInterval(-Double(number) * 13 * 3600)
            var book = Book(metadata: metadata, folderPath: folderPath, dateAdded: added)
            book.appOnlyFields = template.book.appOnlyFields
            switch number % 5 {
            case 2: book.setReadStatus(.inProgress, on: added.addingTimeInterval(86_400))
            case 3:
                book.setReadStatus(.finished, on: added.addingTimeInterval(7 * 86_400))
                book.rating = number % 4 + 2
            default: break
            }
            if number % 6 == 0 { book.tags = ["to sort"] }

            // Three in four have a cover; the rest show the placeholder. Some covers are square.
            guard let id = try store.insert(book, files: files).id, number % 4 != 0 else { continue }
            try service.covers.set(cover.next(metadata, square: number % 9 == 0, width: 400), for: id)
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
        private var count: Int

        init(startingAt count: Int = 0) {
            self.count = count
        }

        /// - Parameters:
        ///   - square: A square cover, as audiobooks often have, in place of an upright one.
        ///   - width: In pixels.
        mutating func next(_ metadata: BookMetadata, square: Bool = false, width: Int = 600) -> CoverImage {
            // Twelve hues; stepping by five of them puts neighbouring books far apart.
            let hue = CGFloat((count * 5) % 12) / 12
            count += 1
            return DemoContent.makeCover(
                title: metadata.title, author: metadata.authors.first, hue: hue,
                width: width, height: square ? width : width * 3 / 2)
        }
    }

    /// A JPEG that looks like a book cover: a plain colour, the title in white, and the
    /// author in a darker band along the bottom.
    private static func makeCover(title: String, author: String?, hue: CGFloat, width: Int, height: Int) -> CoverImage {
        let (w, h) = (CGFloat(width), CGFloat(height))
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

        context.setFillColor(colour(hue: hue, saturation: 0.6, brightness: 0.58))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let band = (h * 0.2).rounded()
        context.setFillColor(colour(hue: hue, saturation: 0.65, brightness: 0.34))
        context.fill(CGRect(x: 0, y: 0, width: w, height: band))
        context.setStrokeColor(white.copy(alpha: 0.35)!)
        context.setLineWidth(w / 200)
        context.stroke(CGRect(x: 0, y: 0, width: w, height: h).insetBy(dx: w * 0.05, dy: w * 0.05))

        // The title, in the largest of these sizes at which all of it fits above the band.
        let margin = w * 0.1
        let titleBox = CGRect(x: margin, y: band + margin / 2, width: w - 2 * margin, height: h - band - 2 * margin)
        let sizes: [CGFloat] = [0.1, 0.085, 0.07, 0.058, 0.048, 0.04].map { $0 * w }
        let fitting = sizes.first { size in
            let needed = CTFramesetterSuggestFrameSizeWithConstraints(
                CTFramesetterCreateWithAttributedString(text(title, font: "Georgia-Bold", size: size, colour: white)),
                CFRange(location: 0, length: 0), nil,
                CGSize(width: titleBox.width, height: .greatestFiniteMagnitude), nil)
            return needed.height <= titleBox.height
        }
        draw(text(title, font: "Georgia-Bold", size: fitting ?? sizes[sizes.count - 1], colour: white), in: titleBox, context)

        if let author {
            let authorBox = CGRect(x: margin, y: 0, width: w - 2 * margin, height: band - w * 0.06)
            draw(
                text(author, font: "HelveticaNeue-Medium", size: w * 0.045, colour: white.copy(alpha: 0.9)!),
                in: authorBox, context)
        }

        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(
            destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return CoverImage(data: data as Data, mime: "image/jpeg")
    }

    /// Centred text for a cover.
    private static func text(_ string: String, font: String, size: CGFloat, colour: CGColor) -> CFAttributedString {
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafePointer(to: &alignment) { pointer in
            CTParagraphStyleCreate(
                [CTParagraphStyleSetting(
                    spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)], 1)
        }
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: CTFontCreateWithName(font as CFString, size, nil),
            kCTForegroundColorAttributeName: colour,
            kCTParagraphStyleAttributeName: paragraph,
        ]
        return CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary)
    }

    /// Draws the text from the top of the box down; what does not fit is left out.
    private static func draw(_ text: CFAttributedString, in box: CGRect, _ context: CGContext) {
        let frame = CTFramesetterCreateFrame(
            CTFramesetterCreateWithAttributedString(text), CFRange(location: 0, length: 0),
            CGPath(rect: box, transform: nil), nil)
        CTFrameDraw(frame, context)
    }

    private static func colour(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> CGColor {
        let sixth = hue * 6
        let chroma = brightness * saturation
        let x = chroma * (1 - abs(sixth.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (CGFloat, CGFloat, CGFloat)
        switch Int(sixth) % 6 {
        case 0: (r, g, b) = (chroma, x, 0)
        case 1: (r, g, b) = (x, chroma, 0)
        case 2: (r, g, b) = (0, chroma, x)
        case 3: (r, g, b) = (0, x, chroma)
        case 4: (r, g, b) = (x, 0, chroma)
        default: (r, g, b) = (chroma, 0, x)
        }
        let lift = brightness - chroma
        return CGColor(srgbRed: r + lift, green: g + lift, blue: b + lift, alpha: 1)
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
