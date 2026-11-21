import DemoContent
import Foundation
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
}
