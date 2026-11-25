import DemoContent
import Foundation
import Testing
import VoxCarrelAppCore
import VoxCarrelCore
import VoxCarrelFixtures

@Suite struct LibraryWorkerTests {
    /// A worker on a library, and a second connection to the same catalogue for setting
    /// up and checking rows directly. The two are only ever used one after the other.
    private struct Fixture {
        var worker: LibraryWorker
        var store: LibraryStore
        var root: URL { store.libraryRoot }
    }

    private func emptyLibrary() throws -> Fixture {
        let root = try makeTempDir()
        return Fixture(worker: try LibraryWorker(libraryRoot: root), store: try LibraryStore(libraryRoot: root))
    }

    private func demoLibrary() throws -> Fixture {
        let root = try makeTempDir()
        try DemoContent.makeLibrary(at: root, audible: false)
        return Fixture(worker: try LibraryWorker(libraryRoot: root), store: try LibraryStore(libraryRoot: root))
    }

    /// Inserts a catalogue row with file rows; nothing is created on disk.
    @discardableResult
    private func insert(
        _ store: LibraryStore, _ title: String, authors: [String] = ["Ann Author"],
        files: [(path: String, format: FileFormat, role: FileRole)] = [],
        configure: (inout Book) -> Void = { _ in }
    ) throws -> Int64 {
        var book = Book(metadata: BookMetadata(title: title, authors: authors))
        configure(&book)
        let rows = files.enumerated().map { index, file in
            BookFile(path: file.path, format: file.format, role: file.role, position: index)
        }
        return try #require(try store.insert(book, files: rows).id)
    }

    private func id(of title: String, in store: LibraryStore) throws -> Int64 {
        let book = try #require(try store.books().first { $0.title == title }, "\(title)")
        return try #require(book.id)
    }

    // MARK: Opening

    @Test func opensAndCreatesTheLibrary() async throws {
        let root = try makeTempDir().appendingPathComponent("New Library", isDirectory: true)
        let worker = try LibraryWorker(libraryRoot: root)
        #expect(worker.libraryRoot == root)
        #expect(exists(root.appendingPathComponent(LibraryStore.databaseFileName)))
        #expect(try await worker.rows(for: .allBooks, search: "").isEmpty)
    }

    // MARK: Rows

    /// W1
    @Test func fixedItemsUseTheStoresFilters() async throws {
        let library = try demoLibrary()
        let worker = library.worker

        let all = try await worker.rows(for: .allBooks, search: "")
        #expect(all.count == 12)
        #expect(all.map(\.book) == (try library.store.books()))
        #expect(all.allSatisfy { $0.id == $0.book.id })

        let audiobooks = try await worker.rows(for: .audiobooks, search: "")
        #expect(audiobooks.count == 9)
        #expect(audiobooks.allSatisfy { $0.hasAudio })
        #expect(Set(audiobooks.map(\.id)) == Set(all.filter(\.hasAudio).map(\.id)))

        let ebooks = try await worker.rows(for: .ebooks, search: "")
        #expect(ebooks.count == 4)
        #expect(ebooks.allSatisfy { $0.hasEbook })
        #expect(Set(ebooks.map(\.id)) == Set(all.filter(\.hasEbook).map(\.id)))

        let finished = try await worker.rows(for: .finished, search: "")
        #expect(finished.map(\.book.title) == ["Quiet Rivers", "Salt Road", "The Lighthouse Keeper"])
        let inProgress = try await worker.rows(for: .inProgress, search: "")
        #expect(inProgress.map(\.book.title) == ["Night Train to Vostok", "The Drowned Bell", "Two Hands on the Wheel"])
        let unread = try await worker.rows(for: .unread, search: "")
        #expect(unread.count == 6)
        #expect(unread.allSatisfy { $0.book.readStatus == .unread })

        let flagged = try await worker.rows(for: .needsAttention, search: "")
        #expect(flagged.map(\.book.title) == ["Voices from the Attic"])
    }

    // MARK: Books on Audible (plan 6)

    private func addGlassTide(_ library: Fixture, asin: String? = "B0GLASSTID") throws -> Int64 {
        var metadata = BookMetadata(title: "The Glass Tide", authors: ["Ines Calloway"])
        metadata.durationSeconds = 36_000
        let outcome = try LibraryService(store: library.store).addExternalBook(
            metadata: metadata, cover: nil,
            copy: ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: asin))
        guard case .added(let id) = outcome else { throw LibraryError.bookNotFound(-1) }
        return id
    }

    /// R1, R2: On Audible lists the books marked so; a book with no files is an audiobook with no formats.
    @Test func onAudibleListsMarkedBooksAndRowsSayWhatIsHere() async throws {
        let library = try demoLibrary()
        let worker = library.worker
        #expect(try await worker.rows(for: .onAudible, search: "").isEmpty)
        let glass = try addGlassTide(library)

        let listed = try await worker.rows(for: .onAudible, search: "")
        #expect(listed.map(\.id) == [glass])
        #expect(listed.map(\.book) == (try library.store.books(ownedOn: .audible)))
        let row = try #require(listed.first)
        #expect(row.hasAudio)
        #expect(!row.hasEbook)
        #expect(!row.hasFiles)
        #expect(row.formats.isEmpty)
        #expect(row.isOnAudible)
        // Searching narrows it like any list.
        #expect(try await worker.rows(for: .onAudible, search: "glass").map(\.id) == [glass])
        #expect(try await worker.rows(for: .onAudible, search: "lighthouse").isEmpty)

        let audiobooks = try await worker.rows(for: .audiobooks, search: "")
        #expect(audiobooks.count == 10)
        #expect(audiobooks.allSatisfy { $0.hasAudio })
        let all = try await worker.rows(for: .allBooks, search: "")
        #expect(all.filter { !$0.hasFiles }.map(\.id) == [glass])
        let sidebar = try await worker.sidebar()
        #expect(sidebar.counts[.onAudible] == 1)
        #expect(sidebar.counts[.audiobooks] == 10)
        #expect(sidebar.counts.count == SidebarItem.fixed.count)

        // An ebook-form copy makes a book an ebook in the lists, as the store has it.
        let asEbook = try #require(
            try LibraryService(store: library.store).addExternalBook(
                metadata: BookMetadata(title: "Paper Tide", authors: ["Ines Calloway"]), cover: nil,
                copy: ExternalCopy(kind: .audible, form: .ebook)) as ExternalBookOutcome?)
        guard case .added(let paper) = asEbook else { return }
        let ebooks = try await worker.rows(for: .ebooks, search: "")
        #expect(ebooks.contains { $0.id == paper })
        #expect(ebooks.allSatisfy { $0.hasEbook })
    }

    /// R8: marking and unmarking, and what is refused.
    @Test func setOnAudibleAddsAndRemovesTheAudibleCopy() async throws {
        let library = try demoLibrary()
        let worker = library.worker
        let glass = try addGlassTide(library)
        let salt = try id(of: "Salt Road", in: library.store)

        #expect(try await worker.setOnAudible(true, for: [salt, glass], store: .de).isEmpty)
        #expect(
            try library.store.book(id: salt)?.externalCopies == [ExternalCopy(kind: .audible, form: .audio, store: "de")])
        // Marked already: left as it was.
        #expect(
            try library.store.book(id: glass)?.externalCopies
                == [ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: "B0GLASSTID")])

        // Unmarking: the one with no files would be left with nothing, and is returned.
        #expect(try await worker.setOnAudible(false, for: [glass, salt, 9_999], store: .de) == [glass])
        #expect(try library.store.book(id: salt)?.externalCopies.isEmpty == true)
        #expect(try library.store.book(id: glass)?.isOwned(on: .audible) == true)
        // Not marked: nothing to do.
        #expect(try await worker.setOnAudible(false, for: [salt], store: .de).isEmpty)
    }

    /// R9: the library's own match, which knows a book by its Audible ID whatever its title.
    @Test func existingMatchIsTheEnginesAndKnowsTheAudibleID() async throws {
        let library = try demoLibrary()
        let glass = try addGlassTide(library)
        var details = BookMetadata(title: "Die Glasflut", authors: ["Somebody Else"])
        #expect(try await library.worker.existingMatch(for: details) == nil)
        details.asin = "b0glasstid"
        #expect(try await library.worker.existingMatch(for: details)?.id == glass)
        let byTitle = BookMetadata(title: "the glass tide", authors: ["ines calloway"])
        #expect(try await library.worker.existingMatch(for: byTitle)?.id == glass)
        #expect(
            try await library.worker.existingMatch(for: byTitle)
                == (try LibraryService(store: library.store).existingMatch(for: byTitle)))
    }

    /// W1: the items that are not fixed.
    @Test func browseAndCollectionItemsListTheirBooks() async throws {
        let library = try demoLibrary()
        let byAuthor = try await library.worker.rows(for: .browse(.authors, "Ines Calloway"), search: "")
        #expect(byAuthor.map(\.book.title) == ["Harbour of Glass", "Salt Road", "The Drowned Bell"])
        let secondAuthor = try await library.worker.rows(for: .browse(.authors, "Daniel Brandt"), search: "")
        #expect(secondAuthor.map(\.book.title) == ["Two Hands on the Wheel"])
        let byGenre = try await library.worker.rows(for: .browse(.genre, "Science & Nature"), search: "")
        #expect(byGenre.map(\.book.title) == ["A Field Guide to Small Hours"])

        let favourites = try #require(try library.store.collections().first { $0.name == "Favourites" }?.id)
        let inCollection = try await library.worker.rows(for: .collection(favourites), search: "")
        #expect(inCollection.map(\.book.title) == ["Quiet Rivers", "Salt Road", "The Lighthouse Keeper"])
        #expect(try await library.worker.rows(for: .collection(9_999), search: "").isEmpty)
    }

    /// W2
    @Test func searchNarrowsTheItemsBooksAndKeepsTheirOrder() async throws {
        let library = try demoLibrary()
        let worker = library.worker

        // "sea" is a tag of three books (two of them finished) and a word of one title.
        let sea = try await worker.rows(for: .allBooks, search: "sea").map(\.book.title)
        #expect(sea.count == 4)
        #expect(sea.dropFirst() == ["Salt Road", "The Drowned Bell", "The Lighthouse Keeper"])
        #expect(sea.first?.contains("Northern Sea Routes") == true)
        #expect(try await worker.rows(for: .finished, search: " sea ").map(\.book.title)
            == ["Salt Road", "The Lighthouse Keeper"])
        #expect(try await worker.rows(for: .ebooks, search: "sea").isEmpty)
        #expect(try await worker.rows(for: .browse(.authors, "Ines Calloway"), search: "harb").map(\.book.title)
            == ["Harbour of Glass"])

        // Blank text is no search at all.
        #expect(try await worker.rows(for: .finished, search: "  \n").count == 3)
        // Nothing searchable in it: no rows.
        #expect(try await worker.rows(for: .allBooks, search: "!!!").isEmpty)
        #expect(try await worker.rows(for: .finished, search: "\"").isEmpty)
    }

    /// W3
    @Test func rowFlagsAndFormatsComeFromTheFiles() async throws {
        let library = try emptyLibrary()
        let parts = try insert(library.store, "A Parts", files: [
            ("a/1.mp3", .mp3, .audio), ("a/2.mp3", .mp3, .audio), ("a/0.m4b", .m4b, .audio),
            ("a/map.pdf", .pdf, .extra),
        ])
        let ebook = try insert(library.store, "B Ebook", files: [
            ("b/b.pdf", .pdf, .ebook), ("b/b.epub", .epub, .ebook), ("b/b2.pdf", .pdf, .ebook),
        ])
        let both = try insert(library.store, "C Both", files: [("c/c.m4b", .m4b, .audio), ("c/c.epub", .epub, .ebook)])
        let bare = try insert(library.store, "D Bare")
        let extrasOnly = try insert(library.store, "E Extras", files: [("e/e.pdf", .pdf, .extra)])
        let troubled = try insert(library.store, "F Troubled", files: [("f/1.mp3", .mp3, .audio), ("f/2.mp3", .mp3, .audio)])
        var second = try #require(try library.store.files(bookId: troubled).last)
        second.writeProblem = "The file is locked"
        try library.store.replaceFiles(bookId: troubled, files: [try #require(try library.store.files(bookId: troubled).first), second])

        let rows = try await library.worker.rows(for: .allBooks, search: "")
        #expect(rows.map(\.id) == [parts, ebook, both, bare, extrasOnly, troubled])
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

        #expect(byId[parts]?.formats == [.mp3, .m4b])
        #expect(byId[parts]?.hasAudio == true)
        #expect(byId[parts]?.hasEbook == false)
        #expect(byId[parts]?.hasWriteProblem == false)

        #expect(byId[ebook]?.formats == [.pdf, .epub])
        #expect(byId[ebook]?.hasAudio == false)
        #expect(byId[ebook]?.hasEbook == true)

        #expect(byId[both]?.formats == [.m4b, .epub])
        #expect(byId[both]?.hasAudio == true)
        #expect(byId[both]?.hasEbook == true)

        for id in [bare, extrasOnly] {
            #expect(byId[id]?.formats == [])
            #expect(byId[id]?.hasAudio == false)
            #expect(byId[id]?.hasEbook == false)
            #expect(byId[id]?.hasWriteProblem == false)
        }

        #expect(byId[troubled]?.hasWriteProblem == true)
        #expect(byId[troubled]?.coverURL == nil)
    }

    /// W4
    @Test func coverURLIsTheCoverStores() async throws {
        let library = try demoLibrary()
        let covers = CoverStore(layout: LibraryLayout(root: library.root))
        let rows = try await library.worker.rows(for: .allBooks, search: "")
        for row in rows {
            #expect(row.coverURL != nil, "\(row.book.title)")
            #expect(row.coverURL == covers.url(for: row.id))
        }
        let detail = try #require(try await library.worker.detail(bookId: rows[0].id))
        #expect(detail.row == rows[0])
    }

    // MARK: Sidebar

    /// W5
    @Test func sidebarOfAnEmptyLibraryHasAllEightCountsAtZero() async throws {
        let sidebar = try await emptyLibrary().worker.sidebar()
        let fixed: [SidebarItem] = [
            .allBooks, .audiobooks, .ebooks, .onAudible, .unread, .inProgress, .finished, .needsAttention,
        ]
        #expect(sidebar.counts == Dictionary(uniqueKeysWithValues: fixed.map { ($0, 0) }))
        #expect(sidebar.browse == [.authors: [], .narrators: [], .series: [], .genre: []])
        #expect(sidebar.collections.isEmpty)
    }

    /// W5
    @Test func sidebarCountsBrowseValuesAndCollections() async throws {
        let library = try demoLibrary()
        let sidebar = try await library.worker.sidebar()
        #expect(sidebar.counts == [
            .allBooks: 12, .audiobooks: 9, .ebooks: 4, .onAudible: 0, .unread: 6, .inProgress: 3, .finished: 3,
            .needsAttention: 1,
        ])
        #expect(sidebar.browse[.series] == ["Tidewater Chronicles"])
        #expect(sidebar.browse[.authors]?.contains("Daniel Brandt") == true)
        #expect(sidebar.browse[.authors]?.count == 10)
        #expect(sidebar.browse[.genre]?.contains("Science & Nature") == true)
        #expect(sidebar.browse[.narrators]?.contains("Tom Hale") == true)
        #expect(sidebar.collections.map(\.name) == ["Favourites", "Holiday Listening"])
        #expect(sidebar.collections == (try library.store.collections()))
    }

    /// W5: blank values are left out; values are sorted ignoring case.
    @Test func sidebarBrowseOmitsBlankValues() async throws {
        let library = try emptyLibrary()
        try insert(library.store, "One", authors: ["", "zoe", "  "]) {
            $0.genres = ["   "]
            $0.series = ""
            $0.narrators = ["Bob"]
        }
        try insert(library.store, "Two", authors: ["Adam"]) {
            $0.genres = ["Fantasy"]
            $0.series = "saga"
            $0.narrators = ["alice", ""]
        }
        try insert(library.store, "Three", authors: ["Mia"]) { $0.series = "Arc" }
        let sidebar = try await library.worker.sidebar()
        #expect(sidebar.browse[.authors] == ["Adam", "Mia", "zoe"])
        #expect(sidebar.browse[.narrators] == ["alice", "Bob"])
        #expect(sidebar.browse[.series] == ["Arc", "saga"])
        #expect(sidebar.browse[.genre] == ["Fantasy"])
        #expect(sidebar.counts[.allBooks] == 3)
        #expect(sidebar.counts[.finished] == 0)
    }

    // MARK: Detail

    /// W6
    @Test func detailDescribesTheBookItsFilesAndCollections() async throws {
        let library = try demoLibrary()
        let bookId = try id(of: "The Clockmaker's Apprentice", in: library.store)
        let detail = try #require(try await library.worker.detail(bookId: bookId))

        #expect(detail.row.id == bookId)
        #expect(detail.row.book == (try library.store.book(id: bookId)))
        #expect(detail.row.hasAudio && detail.row.hasEbook)
        #expect(detail.row.formats == [.m4b, .epub])

        let stored = try library.store.files(bookId: bookId)
        #expect(detail.files.map(\.file) == stored)
        #expect(detail.files.map(\.id) == stored.compactMap(\.id))
        #expect(detail.files.map(\.url) == stored.map { library.store.url(for: $0) })
        #expect(detail.files.map(\.name) == stored.map { ($0.path as NSString).lastPathComponent })
        #expect(detail.files.allSatisfy { !$0.isMissing })
        #expect(detail.files.map(\.allowedRoles) == [[.audio], [.ebook, .extra]])

        #expect(detail.chapterCount == 3)
        let holiday = try #require(try library.store.collections().first { $0.name == "Holiday Listening" }?.id)
        #expect(detail.collectionIds == [holiday])

        // An ebook has no chapters to count, and this one is in no collection.
        let ebook = try #require(try await library.worker.detail(bookId: try id(of: "Two Hands on the Wheel", in: library.store)))
        #expect(ebook.chapterCount == 0)
        #expect(ebook.collectionIds.isEmpty)

        #expect(try await library.worker.detail(bookId: 9_999) == nil)
    }

    /// W6: `isMissing` is true when nothing exists at the file's location; an audio file
    /// that cannot be read gives no chapters.
    @Test func detailMarksAFileThatIsNotThere() async throws {
        let library = try demoLibrary()
        let bookId = try id(of: "The Clockmaker's Apprentice", in: library.store)
        let before = try #require(try await library.worker.detail(bookId: bookId))
        try FileManager.default.removeItem(at: before.files[0].url)

        let after = try #require(try await library.worker.detail(bookId: bookId))
        #expect(after.files.map(\.isMissing) == [true, false])
        #expect(after.chapterCount == 0)
    }

    /// One book per format, imported through the worker. MOBI and AZW3 are never opened,
    /// so any bytes will do for them.
    private func importOneFilePerFormat(into worker: LibraryWorker) async throws {
        let inbox = try makeTempDir()
        func candidate(_ title: String, _ files: [URL]) -> ImportItem {
            ImportItem(candidate: CandidateBook(
                files: files.map { CandidateFile(url: $0, role: FileFormat(url: $0)?.defaultRole ?? .extra) },
                metadata: BookMetadata(title: title, authors: ["Mo Reed"])))
        }
        let m4b = inbox.appendingPathComponent("one.m4b")
        try MediaFixtures.makeAAC(at: m4b, seconds: 1)
        let m4a = inbox.appendingPathComponent("two.m4a")
        try MediaFixtures.makeAAC(at: m4a, seconds: 1)
        let mp3 = inbox.appendingPathComponent("three.mp3")
        try MediaFixtures.makeSilentMP3(seconds: 1).write(to: mp3)
        let epub = try MediaFixtures.makeEPUB3(in: inbox, name: "atlas.epub")
        let pdf = inbox.appendingPathComponent("atlas.pdf")
        MediaFixtures.makePDF(at: pdf)
        let mobi = try touch(inbox.appendingPathComponent("atlas.mobi"))
        let azw3 = try touch(inbox.appendingPathComponent("atlas.azw3"))

        let result = try await worker.importItems(
            [
                candidate("One", [m4b]), candidate("Two", [m4a]), candidate("Three", [mp3]),
                candidate("Atlas", [epub, pdf, mobi, azw3]),
            ], options: ImportOptions(mode: .move))
        for outcome in result.outcomes {
            guard case .imported = outcome else {
                Issue.record("not imported: \(outcome)")
                continue
            }
        }
    }

    /// W6: `allowedRoles` is exactly what `LibraryService.setRole` accepts. Every format
    /// is tried with every role: the allowed ones succeed, the others throw `invalidRole`.
    @Test func allowedRolesMatchWhatSetRoleAccepts() async throws {
        let library = try emptyLibrary()
        let worker = library.worker
        try await importOneFilePerFormat(into: worker)

        let expected: [FileFormat: [FileRole]] = [
            .m4b: [.audio], .m4a: [.audio], .mp3: [.audio],
            .epub: [.ebook, .extra], .pdf: [.ebook, .extra], .mobi: [.ebook, .extra], .azw3: [.ebook, .extra],
        ]
        var seen = Set<FileFormat>()
        let rows = try await worker.rows(for: .allBooks, search: "")
        for row in rows {
            let formats = try #require(try await worker.detail(bookId: row.id)).files.map(\.file.format)
            for format in formats {
                seen.insert(format)
                // File ids are replaced by every change, so the file is looked up afresh.
                func current() async throws -> FileRow {
                    let detail = try #require(try await worker.detail(bookId: row.id))
                    return try #require(detail.files.first { $0.file.format == format })
                }
                let allowed = try await current().allowedRoles
                #expect(allowed == expected[format], "\(format)")

                for role in FileRole.allCases where !allowed.contains(role) {
                    let fileId = try await current().id
                    await #expect(throws: LibraryError.invalidRole, "\(format) as \(role)") {
                        try await worker.setRole(role, forFile: fileId)
                    }
                }
                // The role it has now goes last, so each allowed role is a real change
                // where there is more than one, and the file ends as it began.
                let original = try await current().file.role
                for role in allowed.filter({ $0 != original }) + [original] {
                    let fileId = try await current().id
                    try await worker.setRole(role, forFile: fileId)
                    let now = try await current()
                    #expect(now.file.role == role, "\(format) as \(role)")
                    #expect(!now.isMissing, "\(format) as \(role)")
                }
            }
        }
        // The sample library has no file of the kinds added later that are kept as they
        // are; they take the same roles as MOBI and AZW3, which it has.
        #expect(seen == Set(FileFormat.allCases).subtracting([.djvu, .prc, .azw, .fb2, .lit, .chm]))
    }

    // MARK: Importing

    /// W7
    @Test func prepareImportScansAndFindsCovers() async throws {
        let library = try emptyLibrary()
        let inbox = try makeTempDir().appendingPathComponent("Inbox")
        let items = try DemoContent.makeInbox(at: inbox)
        let unsupported = try touch(try makeTempDir().appendingPathComponent("notes.txt"))

        let prepared = try await library.worker.prepareImport(items + [unsupported])
        #expect(prepared.skipped == [unsupported])
        let scan = LibraryService(store: library.store).scan(items)
        #expect(prepared.seeds.map(\.candidate) == scan.candidates)
        #expect(prepared.seeds.count == 12)
        #expect(prepared.seeds.allSatisfy { $0.existingMatch == nil })

        for seed in prepared.seeds {
            let title = seed.candidate.metadata.title
            let cover = try #require(seed.cover, "\(title)")
            // The cover of the first audio or ebook file that has one.
            let first = try seed.candidate.files.filter { $0.role != .extra }
                .lazy.compactMap { try FileMetadataIO().read($0.url).cover }.first
            #expect(cover == first, "\(title)")
        }
        // Each demo book has its own cover.
        #expect(Set(prepared.seeds.compactMap(\.cover?.data)).count == 12)
    }

    /// W7: an extra is never looked in; a file with no cover is passed over for one that has.
    @Test func prepareImportTakesTheCoverFromTheFirstFileThatHasOne() async throws {
        let library = try emptyLibrary()
        let folder = try makeTempDir().appendingPathComponent("Mo Reed/Atlas", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let metadata = BookMetadata(title: "Atlas", authors: ["Mo Reed"])
        let audio = folder.appendingPathComponent("Atlas.m4b")
        try MediaFixtures.makeAAC(at: audio, seconds: 1)
        try FileMetadataIO().write(metadata, to: audio)
        let ebook = try MediaFixtures.makeEPUB3(in: folder, name: "Atlas.epub")
        let image = CoverImage(data: MediaFixtures.makeImage(.png), mime: "image/png")
        try FileMetadataIO().write(metadata, cover: .set(image), to: ebook)

        let prepared = try await library.worker.prepareImport([folder])
        let seed = try #require(prepared.seeds.first)
        #expect(prepared.seeds.count == 1)
        #expect(seed.candidate.files.map(\.role) == [.audio, .ebook])
        #expect(try FileMetadataIO().read(audio).cover == nil)
        #expect(seed.cover == (try FileMetadataIO().read(ebook).cover))
        #expect(seed.cover != nil)
    }

    /// W7: a file that cannot be read gives a nil cover, not an error.
    @Test func prepareImportGivesNoCoverForAnUnreadableFile() async throws {
        let library = try emptyLibrary()
        let inbox = try makeTempDir()
        let broken = try touch(inbox.appendingPathComponent("Broken Book.epub"), "this is not an epub")
        let brokenAudio = try touch(inbox.appendingPathComponent("Broken Audio.m4b"), "nor is this audio")

        let prepared = try await library.worker.prepareImport([broken, brokenAudio])
        #expect(prepared.skipped.isEmpty)
        #expect(prepared.seeds.count == 2)
        #expect(prepared.seeds.allSatisfy { $0.cover == nil })
    }

    /// W7
    @Test func prepareImportLooksUpTheExistingMatch() async throws {
        let library = try emptyLibrary()
        let existing = try insert(library.store, "the lighthouse keeper", authors: ["Eleanor Marsh"])
        let items = try DemoContent.makeInbox(at: try makeTempDir().appendingPathComponent("Inbox"))

        let prepared = try await library.worker.prepareImport(items)
        let matched = prepared.seeds.filter { $0.existingMatch != nil }
        #expect(matched.map(\.candidate.metadata.title) == ["The Lighthouse Keeper"])
        #expect(matched.first?.existingMatch?.id == existing)
    }

    @Test func importItemsFilesTheSeeds() async throws {
        let library = try emptyLibrary()
        let inbox = try makeTempDir().appendingPathComponent("Inbox")
        let prepared = try await library.worker.prepareImport(try DemoContent.makeInbox(at: inbox))
        let result = try await library.worker.importItems(
            prepared.seeds.map { ImportItem(candidate: $0.candidate) }, options: ImportOptions(mode: .copy))

        #expect(result.outcomes.count == 12)
        let needingAttention = result.outcomes.filter {
            if case .needsAttention = $0 { return true } else { return false }
        }
        #expect(needingAttention.count == 1)
        #expect(try await library.worker.rows(for: .allBooks, search: "").count == 12)
        #expect(try await library.worker.undoLabel() != nil)
    }

    // MARK: Changing

    /// W8
    @Test func removeBooksContinuesAfterAFailureAndReportsEach() async throws {
        let library = try demoLibrary()
        let rivers = try id(of: "Quiet Rivers", in: library.store)
        let salt = try id(of: "Salt Road", in: library.store)
        let files = try (library.store.files(bookId: rivers) + library.store.files(bookId: salt))
            .map { library.store.url(for: $0) }

        let failures = await library.worker.removeBooks(ids: [8_888, rivers, 9_999, salt], moveFilesToTrash: false)
        #expect(failures.map(\.id) == [8_888, 9_999])
        #expect(failures.allSatisfy { !$0.reason.isEmpty })
        #expect(failures.allSatisfy { !$0.reason.contains("LibraryError") })

        #expect(try library.store.book(id: rivers) == nil)
        #expect(try library.store.book(id: salt) == nil)
        #expect(try library.store.books().count == 10)
        // Not sent to the Trash: the files stay where they were.
        #expect(files.count == 2)
        #expect(files.allSatisfy { exists($0) })

        #expect(await library.worker.removeBooks(ids: [], moveFilesToTrash: false).isEmpty)
    }

    /// W9
    @Test func failuresThrowTheEnginesOwnErrors() async throws {
        let library = try emptyLibrary()
        let worker = library.worker
        await #expect(throws: LibraryError.fileNotFound(42)) { try await worker.setRole(.ebook, forFile: 42) }
        await #expect(throws: LibraryError.fileNotFound(42)) {
            try await worker.locateFile(fileId: 42, at: URL(fileURLWithPath: "/nowhere.m4b"))
        }
        await #expect(throws: LibraryError.nothingToUndo) { _ = try await worker.undoLast() }
        await #expect(throws: CollectionError.blankName) { try await worker.renameCollection(id: 1, to: "  ") }
        await #expect(throws: CollectionError.notFound(77)) { try await worker.renameCollection(id: 77, to: "Name") }
        // Two collections cannot share a name: the database's own error comes through.
        _ = try await worker.createCollection(name: "Shelf")
        await #expect(throws: (any Error).self) { _ = try await worker.createCollection(name: "Shelf") }
        #expect(try library.store.collections().count == 1)
    }

    @Test func saveRenamesAndUndoPutsItBack() async throws {
        let library = try demoLibrary()
        let worker = library.worker
        let bookId = try id(of: "Quiet Rivers", in: library.store)
        var edit = BookEdit(book: try #require(try library.store.book(id: bookId)))
        edit.metadata.title = "Loud Rivers"

        let outcomes = try await worker.save([edit])
        guard case .saved(bookId, true, _, []) = try #require(outcomes.first), outcomes.count == 1 else {
            Issue.record("not saved and refiled: \(outcomes)")
            return
        }
        #expect(try library.store.book(id: bookId)?.title == "Loud Rivers")
        let after = try #require(try await worker.detail(bookId: bookId))
        #expect(after.files.allSatisfy { !$0.isMissing })
        #expect(after.files.first?.url.path.contains("Loud Rivers") == true)

        let label = try #require(try await worker.undoLabel())
        #expect(try await worker.undoLast() == label)
        #expect(try library.store.book(id: bookId)?.title == "Quiet Rivers")
        #expect(try await worker.undoLabel() == nil)
    }

    @Test func rewriteTagsAndReadStatusGoThrough() async throws {
        let library = try demoLibrary()
        let worker = library.worker
        let bookId = try id(of: "Harbour of Glass", in: library.store)

        let outcomes = try await worker.rewriteTags(for: [bookId])
        #expect(outcomes == [.saved(bookId: bookId, refiled: false, appOnlyFields: [], fileProblems: [])])  // an M4B holds every field

        try await worker.setReadStatus(.finished, for: [bookId])
        #expect(try library.store.book(id: bookId)?.readStatus == .finished)
        #expect(try await worker.rows(for: .finished, search: "").contains { $0.id == bookId })
    }

    @Test func reconcileFindsAMissingFileAndLocateFilePutsItBack() async throws {
        let library = try demoLibrary()
        let worker = library.worker
        let bookId = try id(of: "Quiet Rivers", in: library.store)
        #expect(try await worker.reconcile() == ReconcileReport())

        let file = try #require(try await worker.detail(bookId: bookId)?.files.first)
        let elsewhere = try makeTempDir().appendingPathComponent("found.epub")
        try FileManager.default.moveItem(at: file.url, to: elsewhere)
        #expect(try await worker.reconcile().booksWithMissingFiles == [bookId])
        #expect(try await worker.rows(for: .needsAttention, search: "").contains { $0.id == bookId })

        let missing = try #require(try await worker.detail(bookId: bookId)?.files.first)
        #expect(missing.isMissing)
        try await worker.locateFile(fileId: missing.id, at: elsewhere)
        #expect(exists(file.url))
        #expect(!exists(elsewhere))
        #expect(try await worker.detail(bookId: bookId)?.files.first?.isMissing == false)
        #expect(try library.store.book(id: bookId)?.needsAttention == false)
    }

    @Test func plannedFolderIsTheEngines() async throws {
        let library = try demoLibrary()
        let service = LibraryService(store: library.store)
        var metadata = BookMetadata(title: "A New Tide", authors: ["ines calloway"])
        metadata.series = "Tidewater Chronicles"
        metadata.seriesNumber = "4"
        let planned = await library.worker.plannedFolder(for: metadata)
        #expect(planned != nil)
        #expect(planned == service.plannedFolder(for: metadata))
        #expect(await library.worker.plannedFolder(for: BookMetadata(title: "No Author")) == nil)
    }

    // MARK: Collections

    @Test func collectionsCanBeMadeFilledRenamedAndDeleted() async throws {
        let library = try emptyLibrary()
        let worker = library.worker
        let one = try insert(library.store, "One")
        let two = try insert(library.store, "Two")

        let zed = try #require(try await worker.createCollection(name: "Zed").id)
        let alpha = try #require(try await worker.createCollection(name: "alpha").id)
        #expect(try await worker.sidebar().collections.map(\.name) == ["alpha", "Zed"])

        try await worker.add(bookIds: [one, two], toCollection: zed)
        try await worker.add(bookIds: [two], toCollection: alpha)
        #expect(try await worker.rows(for: .collection(zed), search: "").map(\.id) == [one, two])
        #expect(try await worker.detail(bookId: two)?.collectionIds == [zed, alpha])
        #expect(try await worker.detail(bookId: one)?.collectionIds == [zed])

        try await worker.remove(bookIds: [one], fromCollection: zed)
        #expect(try await worker.rows(for: .collection(zed), search: "").map(\.id) == [two])

        try await worker.renameCollection(id: zed, to: "  Beta ")
        #expect(try await worker.sidebar().collections.map(\.name) == ["alpha", "Beta"])

        try await worker.deleteCollection(id: zed)
        #expect(try await worker.sidebar().collections.map(\.id) == [alpha])
        #expect(try await worker.detail(bookId: two)?.collectionIds == [alpha])
        #expect(try library.store.books().count == 2)
    }
}
