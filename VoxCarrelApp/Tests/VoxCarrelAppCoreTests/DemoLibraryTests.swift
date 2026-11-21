import DemoContent
import Foundation
import ImageIO
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@Suite struct DemoLibraryTests {
    private func roles(_ candidate: CandidateBook) -> [FileRole] { candidate.files.map(\.role) }

    private func formats(_ candidate: CandidateBook) -> [FileFormat] {
        candidate.files.compactMap { FileFormat(url: $0.url) }
    }

    /// A service on a scratch library, used only to scan.
    private func scanner() throws -> LibraryService {
        LibraryService(store: try LibraryStore(libraryRoot: try makeTempDir()))
    }

    // MARK: The inbox

    @Test func inboxScansIntoTheBooksOfTheTable() throws {
        let inbox = try makeTempDir().appendingPathComponent("Inbox")
        let items = try DemoContent.makeInbox(at: inbox)
        let scan = try scanner().scan(items)

        #expect(scan.skipped.isEmpty)
        #expect(scan.candidates.count == 12)
        let byTitle = Dictionary(grouping: scan.candidates, by: \.metadata.title)
        #expect(byTitle.count == 12, "every demo book has its own title")
        #expect(scan.candidates.allSatisfy { !$0.metadata.title.isEmpty })

        // Standalone audiobook: one M4B with chapters.
        let standalone = try #require(byTitle["The Lighthouse Keeper"]?.first)
        #expect(formats(standalone) == [.m4b])
        #expect(try FileMetadataIO().read(standalone.files[0].url).chapters.count == 3)

        // Series, books 1–3.
        let series = scan.candidates.filter { $0.metadata.series == "Tidewater Chronicles" }
        #expect(series.compactMap(\.metadata.seriesNumber).sorted() == ["1", "2", "3"])
        #expect(series.allSatisfy { formats($0) == [.m4b] })

        // Multi-part audiobook: a folder of four MP3s.
        let parts = try #require(byTitle["Night Train to Vostok"]?.first)
        #expect(formats(parts) == [.mp3, .mp3, .mp3, .mp3])
        #expect(roles(parts) == [.audio, .audio, .audio, .audio])
        #expect(parts.sourceFolder != nil)

        // Audiobook with ebook: one candidate, one audio and one ebook file.
        let pair = try #require(byTitle["The Clockmaker's Apprentice"]?.first)
        #expect(roles(pair) == [.audio, .ebook])
        #expect(formats(pair) == [.m4b, .epub])

        // Audiobook with companion: the PDF is an extra.
        let companion = try #require(byTitle["A Field Guide to Small Hours"]?.first)
        #expect(roles(companion) == [.audio, .extra])
        #expect(formats(companion) == [.m4b, .pdf])

        // Ebook only.
        let ebook = try #require(byTitle["Quiet Rivers"]?.first)
        #expect(roles(ebook) == [.ebook])
        #expect(formats(ebook) == [.epub])

        // Ebook in two formats.
        let twoFormats = try #require(byTitle["The Cartographer's Daughter"]?.first)
        #expect(roles(twoFormats) == [.ebook, .ebook])
        #expect(Set(formats(twoFormats)) == [.epub, .pdf])

        // Two authors.
        let twoAuthors = try #require(byTitle["Two Hands on the Wheel"]?.first)
        #expect(twoAuthors.metadata.authors == ["Priya Nair", "Daniel Brandt"])
        #expect(formats(twoAuthors) == [.epub])

        // No author: a title, and no author guessed from the folder it is in.
        let noAuthor = try #require(byTitle["Voices from the Attic"]?.first)
        #expect(noAuthor.metadata.authors.isEmpty)
        #expect(formats(noAuthor) == [.m4b])
        #expect(scan.candidates.filter { $0.metadata.authors.isEmpty }.count == 1)

        // Long title: 90 characters, and a subtitle.
        let long = try #require(scan.candidates.first { $0.metadata.title.count == 90 })
        #expect(long.metadata.subtitle?.isEmpty == false)
        #expect(formats(long) == [.m4b])
    }

    @Test func inboxGroupsTheSameWhenTheFolderItselfIsDropped() throws {
        let inbox = try makeTempDir().appendingPathComponent("Inbox")
        let items = try DemoContent.makeInbox(at: inbox)
        let service = try scanner()
        let whole = service.scan([inbox])
        #expect(whole.skipped.isEmpty)
        let key: (CandidateBook) -> String = { $0.metadata.title + " " + $0.files.map(\.role.rawValue).joined() }
        #expect(whole.candidates.map(key).sorted() == service.scan(items).candidates.map(key).sorted())
    }

    @Test func everyInboxBookCarriesItsOwnCover() throws {
        let inbox = try makeTempDir().appendingPathComponent("Inbox")
        let scan = try scanner().scan(try DemoContent.makeInbox(at: inbox))
        var covers = Set<Data>()
        for candidate in scan.candidates {
            // A PDF cannot hold a cover; every book has an audio file or an EPUB that does.
            let holder = try #require(candidate.files.first { FileFormat(url: $0.url) != .pdf })
            let cover = try #require(try FileMetadataIO().read(holder.url).cover, "\(candidate.metadata.title)")
            covers.insert(cover.data)
        }
        #expect(covers.count == scan.candidates.count)
    }

    @Test func refusesAFolderThatIsNotEmpty() throws {
        let folder = try makeTempDir()
        try touch(folder.appendingPathComponent("something.txt"))
        #expect(throws: DemoError.self) { try DemoContent.makeInbox(at: folder) }
        #expect(throws: DemoError.self) { try DemoContent.makeLibrary(at: folder) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["something.txt"])
    }

    // MARK: The library

    /// B3
    @Test func libraryIsConsistent() throws {
        let folder = try makeTempDir()  // an existing, empty folder is accepted
        try DemoContent.makeLibrary(at: folder)
        let service = LibraryService(store: try LibraryStore(libraryRoot: folder))

        #expect(try service.reconcile() == ReconcileReport())

        // Every file is where the database says, and holds its book's title and authors.
        let books = try service.store.books()
        #expect(books.count == 12)
        for book in books {
            let id = try #require(book.id)
            let files = try service.store.files(bookId: id)
            #expect(!files.isEmpty)
            for file in files {
                let url = service.store.url(for: file)
                #expect(exists(url), "\(url.path)")
                #expect(file.writeProblem == nil)
                guard file.role != .extra else { continue }
                let inFile = try FileMetadataIO().readMetadata(at: url)
                #expect(inFile.title == book.title)
                #expect(inFile.authors == book.authors)
            }
            #expect(service.covers.url(for: id) != nil, "\(book.title) has a cover")
        }
    }

    /// B4
    @Test func onlyTheBookWithNoAuthorNeedsAttention() throws {
        let folder = try makeTempDir().appendingPathComponent("Library")
        try DemoContent.makeLibrary(at: folder)
        let store = try LibraryStore(libraryRoot: folder)

        let flagged = try store.books(needsAttention: true)
        #expect(flagged.map(\.title) == ["Voices from the Attic"])
        #expect(flagged.first?.authors == [])
        #expect(flagged.first?.folderPath == nil)

        let filed = try store.books(needsAttention: false)
        #expect(filed.count == 11)
        #expect(filed.allSatisfy { $0.folderPath != nil })
    }

    @Test func libraryHasStatusesTagsRatingsAndTwoCollections() throws {
        let folder = try makeTempDir().appendingPathComponent("Library")
        try DemoContent.makeLibrary(at: folder)
        let store = try LibraryStore(libraryRoot: folder)

        #expect(try !store.books(readStatus: .finished).isEmpty)
        #expect(try !store.books(readStatus: .inProgress).isEmpty)
        #expect(try !store.books(readStatus: .unread).isEmpty)
        let books = try store.books()
        #expect(books.filter { !$0.tags.isEmpty }.count >= 3)
        #expect(books.filter { $0.rating > 0 }.count >= 3)

        let collections = try store.collections()
        #expect(collections.count == 2)
        for collection in collections {
            let id = try #require(collection.id)
            #expect(try store.books(inCollection: id).count >= 2)
        }

        // Audiobooks and ebooks lists both have something to show.
        #expect(try store.books(having: .audio).count == 9)
        #expect(try store.books(having: .ebook).count == 4)
    }

    // MARK: Covers

    private func pixelSize(_ data: Data) throws -> (width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    /// The hue, in degrees, of the image's background: the pixel 8 in from its top left
    /// corner, where nothing else is drawn.
    private func backgroundHue(_ data: Data) throws -> Double {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try #require(
            CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // The bitmap's first row is the image's top row.
        let at = 8 * context.bytesPerRow + 8 * 4
        let (r, g, b) = (Double(bytes[at]), Double(bytes[at + 1]), Double(bytes[at + 2]))
        let (high, low) = (max(r, g, b), min(r, g, b))
        try #require(high - low > 20, "the background is a colour, not a grey")
        let sixth: Double
        if high == r {
            sixth = ((g - b) / (high - low)).truncatingRemainder(dividingBy: 6)
        } else if high == g {
            sixth = (b - r) / (high - low) + 2
        } else {
            sixth = (r - g) / (high - low) + 4
        }
        return (sixth * 60 + 360).truncatingRemainder(dividingBy: 360)
    }

    /// G1: covers look like book covers: upright, in colours of their own; two are
    /// square, to show that a square cover is fitted and not cropped.
    @Test func demoCoversAreUprightInDifferentColoursAndTwoAreSquare() throws {
        let folder = try makeTempDir().appendingPathComponent("Library")
        try DemoContent.makeLibrary(at: folder)
        let service = LibraryService(store: try LibraryStore(libraryRoot: folder))

        var square = 0
        var hues = Set<Int>()
        for book in try service.store.books() {
            let id = try #require(book.id)
            let cover = try #require(service.covers.image(for: id), "\(book.title)")
            let size = try pixelSize(cover.data)
            if size.width == size.height {
                square += 1
            } else {
                #expect(size.width * 3 == size.height * 2, "\(book.title) is \(size.width)×\(size.height)")
            }
            #expect(size.height >= 600)
            // Hues within 20 degrees of each other count as one colour.
            hues.insert(Int(try backgroundHue(cover.data) / 20))
        }
        #expect(square == 2)
        #expect(hues.count >= 9)
    }

    // MARK: A large library (G8)

    /// G8
    @Test func aLargeLibraryHasTheBooksAskedForAndNothingForTheLaunchCheckToReport() throws {
        let folder = try makeTempDir().appendingPathComponent("Library")
        try DemoContent.makeLibrary(at: folder, count: 200)
        let service = LibraryService(store: try LibraryStore(libraryRoot: folder))
        let store = service.store

        let books = try store.books()
        #expect(books.count == 200)
        #expect(Set(books.map(\.title)).count == 200, "every book has its own title")
        #expect(try service.reconcile() == ReconcileReport())
        // Still only the one sample book with no author is flagged.
        #expect(try store.books(needsAttention: true).map(\.title) == ["Voices from the Attic"])

        // Every book has files that are there, so that its badges show and it can be opened.
        var withCover = 0
        for book in books {
            let id = try #require(book.id)
            let files = try store.files(bookId: id)
            #expect(!files.isEmpty, "\(book.title)")
            for file in files { #expect(exists(store.url(for: file)), "\(file.path)") }
            if service.covers.url(for: id) != nil { withCover += 1 }
        }
        // Most have a cover; some do not, to show the placeholder.
        #expect(withCover > 100)
        #expect(withCover < 200)

        // Enough variety to sort and browse by.
        #expect(Set(books.compactMap(\.authors.first)).count >= 12)
        #expect(Set(books.compactMap(\.series)).count >= 4)
        #expect(Set(books.map(\.readStatus)) == Set(ReadStatus.allCases))
        #expect(Set(books.compactMap(\.durationSeconds)).count > 20)
        #expect(Set(books.map(\.dateAdded)).count > 100)
        #expect(try store.books(having: .audio).count > 100)
        #expect(try store.books(having: .ebook).count > 40)
        #expect(try store.allFiles().contains { $0.writeProblem != nil })

        // What Undo would reverse is as in the small library.
        #expect(try service.undoLabel() == "Edit 7 books")
    }

    /// G8: a count no larger than the sample books adds none.
    @Test func aCountBelowTheSampleBooksLeavesTheTwelve() throws {
        let folder = try makeTempDir().appendingPathComponent("Library")
        try DemoContent.makeLibrary(at: folder, count: 5)
        #expect(try LibraryStore(libraryRoot: folder).books().count == 12)
    }
}
