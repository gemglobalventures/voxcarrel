import Foundation
import GRDB
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures
import ZIPFoundation

/// A book's genres as a list, with the wording they came from: in the record, in the
/// files' tags, in the catalogue and its list of genres, and in what undo keeps.
@Suite struct GenreBooksTests {
    typealias F = LibraryFixture

    static let thrillers = "Thrillers & Spies"
    static let crime = "Crime & Mystery"

    func edit(_ f: F, _ id: Int64, _ change: (inout BookEdit) -> Void) throws {
        var edit = BookEdit(book: try #require(try f.store.book(id: id)))
        change(&edit)
        let outcomes = try f.service.save([edit])
        guard case .saved = try #require(outcomes.first) else {
            Issue.record("expected .saved, got \(outcomes)")
            return
        }
    }

    /// A book of one M4B whose file carries `tag` as its genre tag.
    func importM4B(_ f: F, title: String = "Slow Horses", tag: String?) throws -> Int64 {
        var tags = F.meta(title, "Mick Herron")
        tags.genres = tag.map { [$0] } ?? []
        let url = try f.makeM4B("\(title).m4b", tags: tags)
        let candidate = try #require(f.service.scan([url]).candidates.first)
        let result = try f.service.importItems([ImportItem(candidate: candidate)])
        return try f.importedId(try #require(result.outcomes.first))
    }

    func file(_ f: F, _ id: Int64) throws -> URL {
        f.store.url(for: try #require(try f.store.files(bookId: id).first))
    }

    /// The genre tag inside a file, exactly as it stands.
    func tag(_ url: URL) throws -> String? {
        try FileMetadataIO().read(url).metadata.genreSource
    }

    // MARK: G1 A list, no genre twice

    @Test func G1_aBookKeepsItsGenresInOrderAndNoneTwice() throws {
        var details = BookMetadata(title: "Bad Actors", authors: ["Mick Herron"])
        details.genres = [Self.thrillers, " Crime  &  Mystery ", "thrillers & spies", "", Self.crime]
        let book = Book(metadata: details)
        #expect(book.genres == [Self.thrillers, Self.crime])
        #expect(book.metadata.genres == [Self.thrillers, Self.crime])

        var none = Book(metadata: BookMetadata(title: "Untagged"))
        #expect(none.genres.isEmpty)
        none.metadata = details
        #expect(none.genres == [Self.thrillers, Self.crime])
    }

    @Test func G1_theCatalogueStoresTheListAndASaveKeepsItsOrder() throws {
        let f = try F()
        let id = try importM4B(f, tag: nil)
        try edit(f, id) { $0.metadata.genres = [Self.crime, Self.thrillers, "crime & mystery"] }
        #expect(try f.store.book(id: id)?.genres == [Self.crime, Self.thrillers])
        // Opened afresh, the list is as it was stored.
        let again = try LibraryStore(libraryRoot: f.root)
        #expect(try again.book(id: id)?.genres == [Self.crime, Self.thrillers])
    }

    @Test func G1_aGenreIsSpelledAsTheLibrarysListSpellsIt() throws {
        let f = try F()
        let first = try importM4B(f, title: "One", tag: nil)
        let second = try importM4B(f, title: "Two", tag: nil)
        try edit(f, first) { $0.metadata.genres = ["Pub Quiz"] }
        try edit(f, second) { $0.metadata.genres = ["PUB QUIZ", "fantasy"] }
        #expect(try f.store.book(id: second)?.genres == ["Pub Quiz", "Fantasy"])
        #expect(try tag(try file(f, second)) == "Pub Quiz; Fantasy")
        #expect(try f.service.genreList().filter { GenreName.same($0.name, "pub quiz") }.count == 1)
    }

    @Test func G1_aNameThatCouldNotBeToldApartInATagIsRefused() throws {
        let f = try F()
        let id = try importM4B(f, tag: "Fantasy")
        let before = try #require(try f.store.book(id: id))
        for name in ["Crime, Mystery", "Mystery/Thriller", "A; B"] {
            var edit = BookEdit(book: before)
            edit.metadata.genres = [name]
            let outcomes = try f.service.save([edit])
            guard case .failed(_, let reason) = try #require(outcomes.first) else {
                Issue.record("expected .failed for \(name), got \(outcomes)")
                continue
            }
            #expect(reason.contains(name))
        }
        #expect(try f.store.book(id: id) == before)
        #expect(try tag(try file(f, id)) == "Fantasy")
    }

    // MARK: G2, G3, G28 The library's list

    @Test func G2_G3_aNewLibraryHasTheBuiltInGenresInTheirGroups() throws {
        let f = try F()
        let list = try f.service.genreList()
        #expect(list.map(\.name) == BuiltInGenre.all.map(\.name))
        #expect(list.map(\.group) == BuiltInGenre.all.map(\.group))
        #expect(list.allSatisfy { $0.builtInName == $0.name && !$0.isHidden && $0.bookCount == 0 })
        #expect(Set(list.map(\.group)) == [.fiction, .nonFiction, .children])
    }

    @Test func G3_G9_anUnknownNameOnAStoredBookJoinsTheListAsTheOwnersOwnInOther() throws {
        let f = try F()
        let id = try importM4B(f, tag: "Pub Quiz; Fantasy")
        #expect(try f.store.book(id: id)?.genres == ["Fantasy", "Pub Quiz"])
        let list = try f.service.genreList()
        let own = try #require(list.first { $0.name == "Pub Quiz" })
        #expect(own.group == .other)
        #expect(own.builtInName == nil)
        #expect(own.bookCount == 1)
        #expect(list.count == BuiltInGenre.all.count + 1)
        // The owner's own come after the built-in ones, in their group.
        #expect(list.last?.name == "Pub Quiz")
        #expect(list.first { $0.name == "Fantasy" }?.bookCount == 1)

        // Stored again, under any capitalisation, it is the same one entry.
        let other = try importM4B(f, title: "Another", tag: nil)
        try edit(f, other) { $0.metadata.genres = ["pub quiz"] }
        let after = try f.service.genreList()
        #expect(after.count == list.count)
        #expect(after.first { $0.name == "Pub Quiz" }?.bookCount == 2)
    }

    @Test func G28_theListIsInTheLibrarysDatabaseAndTravelsWithIt() throws {
        let f = try F()
        _ = try importM4B(f, tag: "Pub Quiz")
        let list = try f.service.genreList()

        // The library folder copied elsewhere and opened there has the same list.
        let elsewhere = try makeTempDir().appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.copyItem(at: f.root, to: elsewhere)
        let moved = LibraryService(store: try LibraryStore(libraryRoot: elsewhere))
        #expect(try moved.genreList() == list)
        #expect(try moved.genreList().contains { $0.name == "Pub Quiz" && $0.group == .other })
    }

    @Test func G35_G36_booksAreFoundByGenreByGroupAndByHavingNone() throws {
        let f = try F()
        let spies = try importM4B(f, title: "Slow Horses", tag: "Thrillers & Spies; Crime & Mystery")
        let history = try importM4B(f, title: "A History", tag: "History")
        let own = try importM4B(f, title: "Gears", tag: "Pub Quiz")
        let none = try importM4B(f, title: "Zed", tag: "Audiobook")

        // Whatever its place in the book's list, and however it is capitalised.
        #expect(try f.service.books(inGenre: Self.crime) == [spies])
        #expect(try f.service.books(inGenre: "crime & mystery") == [spies])
        #expect(try f.service.books(inGenre: "Romance").isEmpty)
        // Each book once, though it has two genres of the group; sorted by title.
        #expect(try f.service.books(inGroup: .fiction) == [spies])
        #expect(try f.service.books(inGroup: .nonFiction) == [history])
        #expect(try f.service.books(inGroup: .other) == [own])
        #expect(try f.service.books(inGroup: .children).isEmpty)
        #expect(try f.service.booksWithNoGenre() == [none])

        // The sidebar's flat list: one entry for each genre, a book counted under each of its own.
        #expect(try f.store.distinctValues(.genre) == [Self.crime, "History", "Pub Quiz", Self.thrillers])
        #expect(try f.store.books(where: .genre, equals: Self.thrillers).map(\.id) == [spies])
        #expect(try f.store.books(where: .genre, equals: Self.crime).map(\.id) == [spies])
    }

    // MARK: G4 The wording

    @Test func G4_theWordingABookCameWithStaysWhenItsGenresAreChanged() throws {
        let f = try F()
        let id = try importM4B(f, tag: "Mystery, Thriller & Suspense, Mystery")
        var book = try #require(try f.store.book(id: id))
        #expect(book.genres == [Self.crime])
        #expect(book.genreSource == "Mystery, Thriller & Suspense, Mystery")

        try edit(f, id) { $0.metadata.genres = ["Horror"] }
        book = try #require(try f.store.book(id: id))
        #expect(book.genres == ["Horror"])
        #expect(book.genreSource == "Mystery, Thriller & Suspense, Mystery")
        // And it is what a re-run of the mapping reads.
        #expect(GenreMapping.map(.text(try #require(book.genreSource))).names == [Self.crime])
    }

    // MARK: G12 The first conversion

    /// The eleven genre values of the owner's library, with what each comes to (GP4).
    static let owners: [(old: String?, genres: [String])] = [
        ("Audiobook", []),
        ("Mystery, Thriller & Suspense", [thrillers]),
        ("International Mystery & Crime, Espionage, Traditional Detectives", [thrillers, crime]),
        ("War & Military, Military, Political, Suspense", [thrillers]),
        ("Suspense, Crime Thrillers, Modern Detectives, Espionage, Political", [thrillers, crime]),
        ("Politics & Social Sciences", ["Politics & Society"]),
        ("Mystery, Thriller & Suspense, Mystery", [crime]),
        ("Money & Finance, Investing & Trading", ["Money & Investing"]),
        ("Literature & Fiction", ["Literary & General"]),
        ("International Mystery & Crime, Espionage", [thrillers, crime]),
        (nil, []),
    ]

    /// A catalogue as the version before this one left it, holding one book for each of
    /// `genres`, the n-th titled "Book n". Returns the library folder.
    func earlierLibrary(_ genres: [String?], also extra: (Database) throws -> Void = { _ in }) throws -> URL {
        let root = try makeTempDir()
        let queue = try DatabaseQueue(path: root.appendingPathComponent(LibraryStore.databaseFileName).path)
        try LibraryStore.migrator.migrate(queue, upTo: "v11")
        try queue.write { db in
            for (index, genre) in genres.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO book (title, authors, narrators, genre, tags, rating, needsAttention, dateAdded,
                                          readStatus)
                        VALUES (?, '["An Author"]', '[]', ?, '[]', 0, 0, '2025-01-02 03:04:05.000', 'unread')
                        """,
                    arguments: ["Book \(index + 1)", genre])
            }
            try extra(db)
        }
        try queue.close()
        return root
    }

    // MARK: GP7 A copy before the conversion

    /// The copies of the catalogue made before its genres were converted, by name.
    func copies(in root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("VoxCarrel before genres") }.sorted()
    }

    @Test func GP7_anExistingLibraryIsCopiedBeforeItsGenresAreConverted() throws {
        let root = try earlierLibrary(["Mystery, Thriller & Suspense", nil])
        let day = Date(timeIntervalSince1970: 1_795_000_000)
        let store = try LibraryStore(libraryRoot: root, today: day)
        #expect(try store.book(id: 1)?.genres == [Self.thrillers])

        let name = LibraryStore.copyBeforeGenresName(on: day, taken: [])
        #expect(name.hasPrefix("VoxCarrel before genres 20"))
        #expect(name.hasSuffix(".sqlite"))
        #expect(name.count == "VoxCarrel before genres 2026-01-01.sqlite".count)
        #expect(try copies(in: store.libraryRoot) == [name])

        // The copy is a whole database as the earlier version left it: the old text is
        // in it, and nothing of the conversion.
        let copy = try DatabaseQueue(path: store.libraryRoot.appendingPathComponent(name).path)
        struct Held { var genres: [String?]; var hasList: Bool; var applied: Set<String>; var check: String? }
        let held = try copy.read { db in
            Held(
                genres: try Optional<String>.fetchAll(db, sql: "SELECT genre FROM book ORDER BY id"),
                hasList: try db.tableExists("genre"),
                applied: try LibraryStore.migrator.appliedIdentifiers(db),
                check: try String.fetchOne(db, sql: "PRAGMA integrity_check"))
        }
        #expect(held.genres == ["Mystery, Thriller & Suspense", nil])
        #expect(!held.hasList)
        #expect(held.applied.contains("v11"))
        #expect(!held.applied.contains("v12"))
        #expect(held.check == "ok")
    }

    @Test func GP7_aLibraryFromAnyEarlierVersionIsCopied() throws {
        let root = try makeTempDir()
        let queue = try DatabaseQueue(path: root.appendingPathComponent(LibraryStore.databaseFileName).path)
        try LibraryStore.migrator.migrate(queue, upTo: "v9")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO book (title, authors, narrators, genre, tags, rating, needsAttention, dateAdded, readStatus)
                VALUES ('Old', '[]', '[]', 'Horror', '[]', 0, 0, '2025-01-02 03:04:05.000', 'unread')
                """)
        }
        try queue.close()
        let store = try LibraryStore(libraryRoot: root)
        #expect(try store.book(id: 1)?.genres == ["Horror"])
        #expect(try copies(in: store.libraryRoot).count == 1)
    }

    @Test func GP7_aNewLibraryAndOneWithNoBooksGetNoCopy() throws {
        let new = try LibraryStore(libraryRoot: try makeTempDir())
        #expect(try copies(in: new.libraryRoot).isEmpty)

        let empty = try LibraryStore(libraryRoot: try earlierLibrary([]))
        #expect(try copies(in: empty.libraryRoot).isEmpty)
        #expect(try empty.genreNames().count == BuiltInGenre.all.count)
    }

    @Test func GP7_noSecondCopyIsMadeOnALaterOpen() throws {
        let root = try earlierLibrary(["Horror"])
        var store: LibraryStore? = try LibraryStore(libraryRoot: root)
        let first = try copies(in: try #require(store).libraryRoot)
        #expect(first.count == 1)
        store = nil
        let again = try LibraryStore(libraryRoot: root)
        #expect(try copies(in: again.libraryRoot) == first)
    }

    @Test func GP7_aNameThatIsTakenGetsANumber() throws {
        let day = Date(timeIntervalSince1970: 1_795_000_000)
        let plain = LibraryStore.copyBeforeGenresName(on: day, taken: [])
        let stem = String(plain.dropLast(".sqlite".count))
        #expect(LibraryStore.copyBeforeGenresName(on: day, taken: [plain]) == "\(stem) 2.sqlite")
        #expect(LibraryStore.copyBeforeGenresName(on: day, taken: [plain, "\(stem) 2.sqlite"]) == "\(stem) 3.sqlite")
        // Capitalisation does not make a name free: the disk may not tell them apart.
        #expect(LibraryStore.copyBeforeGenresName(on: day, taken: [plain.uppercased()]) == "\(stem) 2.sqlite")

        // On disk: a file of that name is left alone and the copy goes beside it.
        let root = try earlierLibrary(["Horror"])
        try Data("mine".utf8).write(to: LibraryLayout.canonicalFolder(root).appendingPathComponent(plain))
        let store = try LibraryStore(libraryRoot: root, today: day)
        #expect(try copies(in: store.libraryRoot) == [plain, "\(stem) 2.sqlite"].sorted())
        #expect(try Data(contentsOf: store.libraryRoot.appendingPathComponent(plain)) == Data("mine".utf8))
    }

    @Test func GP7_aCopyThatFailsStopsTheConversionAndLeavesTheLibraryAsItWas() throws {
        let root = try earlierLibrary(["Mystery, Thriller & Suspense"])
        let file = LibraryLayout.canonicalFolder(root).appendingPathComponent(LibraryStore.databaseFileName)
        let before = try Data(contentsOf: file)

        #expect(throws: LibraryStoreError.self) {
            _ = try LibraryStore(libraryRoot: root, copyBeforeGenres: { _, _ in throw Boom() })
        }
        do {
            _ = try LibraryStore(libraryRoot: root, copyBeforeGenres: { _, _ in throw Boom() })
        } catch let error as LibraryStoreError {
            guard case .copyBeforeGenresFailed = error else {
                Issue.record("expected .copyBeforeGenresFailed, got \(error)")
                return
            }
            #expect(error.localizedDescription.contains("copy"))
            #expect(!LibraryStore.isDatabaseError(error))
        }
        #expect(try Data(contentsOf: file) == before)
        #expect(try copies(in: LibraryLayout.canonicalFolder(root)).isEmpty)
        let queue = try DatabaseQueue(path: file.path)
        #expect(try queue.read { db in try String.fetchOne(db, sql: "SELECT genre FROM book") }
            == "Mystery, Thriller & Suspense")
        #expect(try queue.read { db in try LibraryStore.migrator.appliedIdentifiers(db) }.contains("v12") == false)
        try queue.close()

        // Once the copy can be made, the library opens and is converted.
        let store = try LibraryStore(libraryRoot: root)
        #expect(try store.book(id: 1)?.genres == [Self.thrillers])
        #expect(try copies(in: store.libraryRoot).count == 1)
    }

    @Test func G12_GP4_eachBooksOldTextBecomesItsWordingAndTheMappingGivesItsGenres() throws {
        let root = try earlierLibrary(Self.owners.map(\.old))
        let store = try LibraryStore(libraryRoot: root)

        let books = try store.books().sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        #expect(books.count == 11)
        for (book, expected) in zip(books, Self.owners) {
            #expect(book.genres == expected.genres, "\(expected.old ?? "no text")")
            #expect(book.genreSource == expected.old, "\(expected.old ?? "no text")")
            // The files were written with the old text, and that is recorded.
            #expect(book.genreTag == expected.old, "\(expected.old ?? "no text")")
        }
        // Nothing but the genres changed on a book.
        #expect(books.map(\.title) == (1...11).map { "Book \($0)" })
        #expect(books.allSatisfy { $0.authors == ["An Author"] })

        // The list: the built-in genres, and nothing else, since every name was known.
        let list = try LibraryService(store: store).genreList()
        #expect(list.map(\.name) == BuiltInGenre.all.map(\.name))
        #expect(list.first { $0.name == Self.thrillers }?.bookCount == 5)
        #expect(list.first { $0.name == Self.crime }?.bookCount == 4)
        #expect(try store.bookIdsWithNoGenre().count == 2)
    }

    @Test func G12_G9_aNameTheMappingDoesNotKnowBecomesTheOwnersOwnInOther() throws {
        let root = try earlierLibrary(["Pub Quiz; Fantasy", "pub quiz", "  ", "Loans"])
        let store = try LibraryStore(libraryRoot: root)
        let books = try store.books().sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        #expect(books.map(\.genres) == [["Fantasy", "Pub Quiz"], ["Pub Quiz"], [], ["Loans"]])
        // A text with nothing in it was no genre, and is no wording.
        #expect(books.map(\.genreSource) == ["Pub Quiz; Fantasy", "pub quiz", nil, "Loans"])

        let list = try LibraryService(store: store).genreList()
        let own = list.filter { $0.builtInName == nil }
        #expect(own.map(\.name) == ["Loans", "Pub Quiz"])
        #expect(own.allSatisfy { $0.group == .other && !$0.isHidden })
        #expect(own.map(\.bookCount) == [1, 2])
        #expect(list.count == BuiltInGenre.all.count + 2)
    }

    @Test func G12_noFileIsReadOrWrittenAndItHappensOnce() throws {
        // A book whose file is in the library, with a tag the conversion would change.
        var root = try earlierLibrary(["Mystery, Thriller & Suspense"]) { db in
            try db.execute(sql: """
                UPDATE book SET folderPath = 'An Author/Book 1';
                INSERT INTO bookFile (bookId, path, format, role, position)
                VALUES (1, 'An Author/Book 1/Book 1.m4b', 'm4b', 'audio', 0);
                """)
        }
        root = LibraryLayout.canonicalFolder(root)
        let url = root.appendingPathComponent("An Author/Book 1/Book 1.m4b")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MediaFixtures.makeAAC(at: url, seconds: 1)
        var tags = BookMetadata(title: "Book 1", authors: ["An Author"])
        tags.genres = ["Mystery, Thriller & Suspense"]
        try FileMetadataIO().write(tags, to: url)
        let bytes = try Data(contentsOf: url)
        let stamp = try #require(FileStamp(fileAt: url))

        var store: LibraryStore? = try LibraryStore(libraryRoot: root)
        #expect(try store?.book(id: 1)?.genres == [Self.thrillers])
        #expect(try Data(contentsOf: url) == bytes)
        #expect(FileStamp(fileAt: url) == stamp)
        #expect(try tag(url) == "Mystery, Thriller & Suspense")

        // It is recorded, and is not done again: a change made since stays.
        var book = try #require(try store?.book(id: 1))
        book.genres = ["Horror"]
        try store?.update(book)
        store = nil
        let again = try LibraryStore(libraryRoot: root)
        let after = try #require(try again.book(id: 1))
        #expect(after.genres == ["Horror"])
        #expect(after.genreSource == "Mystery, Thriller & Suspense")
        let applied = try again.dbQueue.read { db in try LibraryStore.migrator.appliedIdentifiers(db) }
        #expect(applied.contains("v12"))
    }

    @Test func G12_everythingElseInAnEarlierCatalogueIsAsItWas() throws {
        let root = try earlierLibrary(["Mystery, Thriller & Suspense"]) { db in
            try db.execute(sql: """
                UPDATE book SET subtitle = 'A Novel', series = 'Slough House', seriesNumber = '1', year = 2010,
                    tags = '["kept"]', rating = 4, readStatus = 'finished', folderPath = 'An Author/Book 1';
                INSERT INTO collection (name) VALUES ('To Read');
                INSERT INTO collectionBook (collectionId, bookId) VALUES (1, 1);
                """)
        }
        let store = try LibraryStore(libraryRoot: root)
        let book = try #require(try store.book(id: 1))
        #expect(book.subtitle == "A Novel")
        #expect(book.series == "Slough House" && book.seriesNumber == "1" && book.year == 2010)
        #expect(book.tags == ["kept"] && book.rating == 4 && book.readStatus == .finished)
        #expect(book.folderPath == "An Author/Book 1")
        #expect(try store.books(inCollection: 1).map(\.id) == [1])
        // The search index was made again, and finds the book as before and by its genre.
        #expect(try store.search("slough").map(\.id) == [1])
        #expect(try store.search("spies").map(\.id) == [1])
    }

    // MARK: G16, G18 What is written, and read back

    static let writable: [(name: String, make: (F) throws -> URL)] = [
        ("m4b", { try $0.makeM4B("book.m4b", tags: F.meta("Title", "Author")) }),
        ("mp3", { try $0.makeMP3("book.mp3", tags: F.meta("Title", "Author")) }),
        ("epub", { try $0.makeEPUB("book.epub") }),
    ]

    @Test func G16_G18_theTagHoldsTheGenresInOrderAndReadsBackAsTheSame() throws {
        let io = FileMetadataIO()
        for (name, make) in Self.writable {
            let f = try F()
            let url = try make(f)
            var details = try io.read(url).metadata
            for genres in [[Self.thrillers], [Self.crime, Self.thrillers, "History"], ["Young Adult", "Fantasy"]] {
                details.genres = genres
                try io.write(details, to: url)
                let read = try io.read(url).metadata
                #expect(read.genreSource == genres.joined(separator: "; "), "\(name)")
                #expect(read.genres == genres, "\(name)")
            }
        }
    }

    @Test func G16_aBookWithNoGenresHasTheTagRemoved() throws {
        let io = FileMetadataIO()
        for (name, make) in Self.writable {
            let f = try F()
            let url = try make(f)
            var details = try io.read(url).metadata
            details.genres = ["Horror"]
            try io.write(details, to: url)
            #expect(try io.read(url).metadata.genreSource == "Horror", "\(name)")

            details.genres = []
            try io.write(details, to: url)
            let read = try io.read(url).metadata
            #expect(read.genreSource == nil, "\(name)")
            #expect(read.genres.isEmpty, "\(name)")
        }
    }

    @Test func G16_anEpubHasOneSubjectForEachGenre() throws {
        let f = try F()
        let url = try f.makeEPUB("book.epub")
        var details = try EpubIO.read(url).metadata
        details.genres = [Self.thrillers, Self.crime]
        try EpubIO.write(details, cover: .keep, to: url)
        let archive = try Archive(url: url, accessMode: .read)
        let package = String(decoding: try EpubIO.data("OEBPS/content.opf", in: archive), as: UTF8.self)
        #expect(package.contains("<dc:subject>Thrillers &amp; Spies</dc:subject>"))
        #expect(package.contains("<dc:subject>Crime &amp; Mystery</dc:subject>"))
        #expect(package.components(separatedBy: "<dc:subject>").count == 3)
    }

    @Test func G18_inALibraryATagOfItsOwnNamesReadsBackAsWritten() throws {
        for (name, make) in Self.writable {
            let f = try F()
            let source = try make(f)
            let candidate = try #require(f.service.scan([source]).candidates.first)
            let id = try f.importedId(
                try #require(try f.service.importItems([ImportItem(candidate: candidate)]).outcomes.first))
            // One of the owner's own first: the mapping alone would put the built-in one first.
            try edit(f, id) { $0.metadata.genres = ["Pub Quiz", "Fantasy"] }
            let url = try file(f, id)
            #expect(try tag(url) == "Pub Quiz; Fantasy", "\(name)")

            #expect(f.service.genres(fromTag: try tag(url)) == ["Pub Quiz", "Fantasy"], "\(name)")
            #expect(try f.tags(url).genres == ["Pub Quiz", "Fantasy"], "\(name)")
            // Without the library's list the mapping decides, and knows only its own names.
            #expect(try FileMetadataIO().read(url).metadata.genres == ["Fantasy", "Pub Quiz"], "\(name)")
        }
    }

    @Test func G18_aTagIsTakenAsWrittenOnlyWhenEveryNameIsOnTheList() throws {
        let f = try F()
        _ = try importM4B(f, tag: "Pub Quiz")
        #expect(f.service.genres(fromTag: "pub quiz;  fantasy ;") == ["Pub Quiz", "Fantasy"])
        #expect(f.service.genres(fromTag: "Pub Quiz; Fantasy; Pub Quiz") == ["Pub Quiz", "Fantasy"])
        // One name the list lacks, and the whole tag goes to the mapping.
        #expect(f.service.genres(fromTag: "Pub Quiz; Fantasy; Loans") == ["Fantasy", "Pub Quiz", "Loans"])
        // A known name with a comma in it is not on the list, so the mapping reads it.
        #expect(f.service.genres(fromTag: "Mystery, Thriller & Suspense") == [Self.thrillers])
        #expect(f.service.genres(fromTag: "Audiobook").isEmpty)
        #expect(f.service.genres(fromTag: nil).isEmpty)
        #expect(f.service.genres(fromTag: "  ").isEmpty)
    }

    // MARK: G17 A save writes the tag

    @Test func G17_aSaveWritesTheBooksGenresIntoItsFilesAndNoOtherBooks() throws {
        let f = try F()
        let id = try importM4B(f, title: "Edited", tag: "Mystery, Thriller & Suspense")
        let other = try importM4B(f, title: "Left Alone", tag: "Mystery, Thriller & Suspense")
        let otherFile = try file(f, other)
        let otherBytes = try f.bytes(otherFile)
        let otherStamp = try #require(FileStamp(fileAt: otherFile))
        let otherBook = try #require(try f.store.book(id: other))

        try edit(f, id) { $0.metadata.genres = [Self.crime, Self.thrillers] }

        #expect(try tag(try file(f, id)) == "Crime & Mystery; Thrillers & Spies")
        #expect(try f.store.book(id: id)?.genres == [Self.crime, Self.thrillers])
        #expect(try f.bytes(otherFile) == otherBytes)
        #expect(FileStamp(fileAt: otherFile) == otherStamp)
        #expect(try f.store.book(id: other) == otherBook)

        // Taking every genre away takes the tag away.
        try edit(f, id) { $0.metadata.genres = [] }
        #expect(try tag(try file(f, id)) == nil)
        #expect(try f.store.book(id: id)?.genres == [])
    }

    // MARK: The tag the files hold

    @Test func G13_theTagTheFilesHoldIsRecordedAtImportAndAfterEveryWrite() throws {
        let f = try F()
        // At import the file is written with the book's genres.
        let id = try importM4B(f, tag: "Mystery, Thriller & Suspense")
        var book = try #require(try f.store.book(id: id))
        #expect(book.genreSource == "Mystery, Thriller & Suspense")
        #expect(book.genreTag == Self.thrillers)
        #expect(try tag(try file(f, id)) == book.genreTag)

        try edit(f, id) { $0.metadata.genres = [Self.crime, Self.thrillers] }
        book = try #require(try f.store.book(id: id))
        #expect(book.genreTag == "Crime & Mystery; Thrillers & Spies")
        #expect(try tag(try file(f, id)) == book.genreTag)

        // An edit that opens no file leaves the record alone.
        try edit(f, id) { $0.rating = 3 }
        #expect(try f.store.book(id: id)?.genreTag == "Crime & Mystery; Thrillers & Spies")

        try edit(f, id) { $0.metadata.genres = [] }
        #expect(try f.store.book(id: id)?.genreTag == nil)

        // Undo puts back the file and the record of what it holds together.
        try f.service.undoLast()
        book = try #require(try f.store.book(id: id))
        #expect(book.genreTag == "Crime & Mystery; Thrillers & Spies")
        #expect(try tag(try file(f, id)) == book.genreTag)
    }

    @Test func G13_aFileThatCouldNotBeWrittenLeavesTheRecordAsItWas() throws {
        let f = try F()
        let id = try importM4B(f, tag: "History")
        let url = try file(f, id)
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        var edit = BookEdit(book: try #require(try f.store.book(id: id)))
        edit.metadata.genres = ["Horror"]
        guard case .saved(_, _, _, let problems) = try #require(try f.service.save([edit]).first) else {
            Issue.record("expected .saved")
            return
        }
        #expect(problems.count == 1)
        let book = try #require(try f.store.book(id: id))
        #expect(book.genres == ["Horror"])
        // The file still says History, and the book is known to differ from it.
        #expect(book.genreTag == "History")
        #expect(try tag(url) == "History")

        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        _ = try f.service.rewriteTags(for: [id])
        #expect(try f.store.book(id: id)?.genreTag == "Horror")
        #expect(try tag(url) == "Horror")
    }

    @Test func G15_aBookWhoseFilesCannotHoldAGenreRecordsNoTag() throws {
        let f = try F()
        var details = F.meta("Notes", "An Author")
        details.genres = ["History"]
        let id = try f.importNew([try f.makePDF("notes.pdf")], details)
        let book = try #require(try f.store.book(id: id))
        #expect(book.genres == ["History"])
        #expect(book.genreTag == nil)
        #expect(book.appOnlyFields.contains(.genre))
    }

    // MARK: Import and merge

    @Test func G19_filesOfOneBookThatDisagreeOnGenreGiveTheFirstFiles() throws {
        let f = try F()
        var one = F.meta("Long Book", "Ann Author")
        one.genres = ["History"]
        var two = one
        two.genres = ["Horror", "Fantasy"]
        var three = one
        three.genres = []
        let parts = [
            try f.makeMP3("long/part1.mp3", tags: three), try f.makeMP3("long/part2.mp3", tags: one),
            try f.makeMP3("long/part3.mp3", tags: two),
        ]
        // A book with no files and no genres takes what it lacks from its first files:
        // the genres of the first file that has any, whole, with their wording.
        guard case .added(let id) = try f.service.addExternalBook(
            metadata: F.meta("Long Book", "Ann Author"), cover: nil,
            copy: ExternalCopy(kind: .audible, form: .audio))
        else {
            Issue.record("expected .added")
            return
        }
        let result = try f.service.importItems(
            [ImportItem(candidate: f.candidate(parts, three), target: .existing(bookId: id))])
        #expect(try f.importedId(try #require(result.outcomes.first)) == id)

        let book = try #require(try f.store.book(id: id))
        #expect(book.genres == ["History"])
        #expect(book.genreSource == "History")
        // Every part now says the same.
        for row in try f.store.files(bookId: id) { #expect(try tag(f.store.url(for: row)) == "History") }
        #expect(book.genreTag == "History")
    }

    @Test func G19_filesAddedToABookThatHasGenresDoNotChangeThem() throws {
        var book = BookMetadata(title: "Kept", authors: ["An Author"])
        book.genres = ["History"]
        book.genreSource = "History"
        var file = book
        file.genres = ["Horror"]
        file.genreSource = "Horror"
        let filled = LibraryService.filledIn(book, fromDetails: [file])
        #expect(filled.genres == ["History"])
        #expect(filled.genreSource == "History")
    }

    @Test func mergingKeepsTheKeptBooksGenresAndAddsTheOthersThatItLacks() throws {
        var kept = Book(metadata: BookMetadata(title: "Dune", authors: ["Frank Herbert"]))
        kept.genres = ["Science Fiction", "Classics"]
        kept.genreSource = "Sci-Fi; Classics"
        var other = kept
        other.genres = ["classics", "Fantasy", "Science Fiction", "Pub Quiz"]
        other.genreSource = "Fantasy"
        var third = kept
        third.genres = ["Fantasy", "Horror"]

        let merged = LibraryService.mergedDetails(kept: kept, others: [other, third])
        #expect(merged.genres == ["Science Fiction", "Classics", "Fantasy", "Pub Quiz", "Horror"])
        #expect(merged.genreSource == "Sci-Fi; Classics")

        // A kept book with none takes the others', and the first wording there is.
        kept.genres = []
        kept.genreSource = nil
        third.genreSource = nil
        let filled = LibraryService.mergedDetails(kept: kept, others: [third, other])
        #expect(filled.genres == ["Fantasy", "Horror", "classics", "Science Fiction", "Pub Quiz"])
        #expect(filled.genreSource == "Fantasy")
    }

    @Test func mergingTwoBooksWritesTheJoinedGenresIntoTheKeptBooksFiles() throws {
        let f = try F()
        let ebook = try f.importNew([try f.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))
        let notes = try f.importNew([try f.makePDF("notes.pdf")], F.meta("Dune Notes", "Frank Herbert"))
        try edit(f, ebook) { $0.metadata.genres = ["Science Fiction"] }
        try edit(f, notes) { $0.metadata.genres = ["Classics", "science fiction"] }

        _ = try f.service.mergeBooks([ebook, notes], keep: ebook, roles: [:])

        let merged = try #require(try f.store.book(id: ebook))
        #expect(merged.genres == ["Science Fiction", "Classics"])
        let epub = f.store.url(for: try #require(try f.store.files(bookId: ebook).first { $0.format == .epub }))
        #expect(try tag(epub) == "Science Fiction; Classics")
        #expect(merged.genreTag == "Science Fiction; Classics")

        try f.service.undoLast()
        #expect(try f.store.book(id: ebook)?.genres == ["Science Fiction"])
        #expect(try f.store.book(id: notes)?.genres == ["Classics", "Science Fiction"])
        #expect(try tag(epub) == "Science Fiction")
    }

    // MARK: G37 Search

    @Test func G37_searchMatchesAnyOfABooksGenreNames() throws {
        let f = try F()
        let spies = try importM4B(f, title: "Slow Horses", tag: "Thrillers & Spies; Crime & Mystery")
        let history = try importM4B(f, title: "A Past", tag: "History")
        #expect(try f.store.search("spies").map(\.id) == [spies])
        #expect(try f.store.search("mystery").map(\.id) == [spies])
        #expect(try f.store.search("crime myst").map(\.id) == [spies])
        #expect(try f.store.search("history").map(\.id) == [history])
        #expect(try f.store.search("romance").isEmpty)

        // The index follows a change of genres.
        try edit(f, history) { $0.metadata.genres = ["Romance"] }
        #expect(try f.store.search("romance").map(\.id) == [history])
        #expect(try f.store.search("history").isEmpty)
    }

    // MARK: G38 Folder layouts

    @Test func G38_theGenreTokenIsTheFirstGenreAndHasNoValueWhenThereIsNone() throws {
        var book = BookMetadata(title: "Bad Actors", authors: ["Mick Herron"])
        book.genres = [Self.thrillers, Self.crime]
        func folder(_ pattern: String) throws -> String? {
            try FolderPattern(pattern).folder(for: FolderPatternValues(metadata: book, hasAudio: true))
        }
        #expect(try folder("{Genre}/{Title}") == "Thrillers & Spies/Bad Actors")
        #expect(try folder("[{Genre}]/{Author}/{Title}") == "Thrillers & Spies/Mick Herron/Bad Actors")

        book.genres = []
        // A part in brackets is left out; without them the book cannot be filed.
        #expect(try folder("[{Genre}]/{Author}/{Title}") == "Mick Herron/Bad Actors")
        #expect(try folder("{Genre}/{Title}") == nil)
    }

    @Test func G38_aLibraryLaidOutByGenreFilesABookUnderItsFirst() throws {
        let f = try F()
        try f.service.applyLayoutChange(to: try FolderPattern("[{Genre}]/{Author}/{Title}"))
        let two = try importM4B(f, tag: "Thrillers & Spies; Crime & Mystery")
        let none = try importM4B(f, title: "Untagged", tag: nil)
        #expect(try f.store.book(id: two)?.folderPath == "Thrillers & Spies/Mick Herron/Slow Horses")
        #expect(try f.store.book(id: none)?.folderPath == "Mick Herron/Untagged")
    }

    // MARK: GP6 Undo records from before

    @Test func GP6_detailsSavedWithOneGenreTextDecodeAsItsWordingAndItsGenres() throws {
        let old = Data(#"{"title": "Bad Actors", "authors": ["Mick Herron"], "genre": "International Mystery & Crime, Espionage"}"#.utf8)
        let details = try JSONDecoder().decode(BookMetadata.self, from: old)
        #expect(details.genreSource == "International Mystery & Crime, Espionage")
        #expect(details.genres == [Self.thrillers, Self.crime])
        #expect(details.title == "Bad Actors")

        let book = try JSONDecoder().decode(Book.self, from: old)
        #expect(book.genreSource == "International Mystery & Crime, Espionage")
        #expect(book.genres == [Self.thrillers, Self.crime])
        #expect(book.genreTag == "International Mystery & Crime, Espionage")

        // No text at all is no genre; and the new form is read as it is.
        let none = try JSONDecoder().decode(Book.self, from: Data(#"{"title": "Bare"}"#.utf8))
        #expect(none.genres.isEmpty && none.genreSource == nil && none.genreTag == nil)
        var now = BookMetadata(title: "New")
        now.genres = ["Pub Quiz", "Fantasy"]
        now.genreSource = "Fantasy, Pub Quiz"
        #expect(try JSONDecoder().decode(BookMetadata.self, from: JSONEncoder().encode(now)) == now)
    }

    @Test func GP6_anUndoRecordFromBeforeRestoresItsTextAsTheWordingAndMapsIt() throws {
        let f = try F()
        let id = try importM4B(f, tag: nil)
        try edit(f, id) { $0.metadata.genres = ["Horror"] }
        let old = "Mystery, Thriller & Suspense, Mystery"

        // The record as the version before this one wrote it: one genre text for the
        // book and for what its file held, and the first layout.
        let batch = try #require(try f.store.lastBatch())
        let data = try #require(batch.snapshot)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var books = try #require(json["books"] as? [[String: Any]])
        var before = try #require(books[0]["bookBefore"] as? [String: Any])
        for key in ["genres", "genreSource", "genreTag"] { before[key] = nil }
        before["genre"] = old
        books[0]["bookBefore"] = before
        var states = try #require(books[0]["fileStates"] as? [[String: Any]])
        #expect(states.count == 1)
        var held = try #require(states[0]["metadataBefore"] as? [String: Any])
        for key in ["genres", "genreSource"] { held[key] = nil }
        held["genre"] = old
        states[0]["metadataBefore"] = held
        books[0]["fileStates"] = states
        json["books"] = books
        json["version"] = 1
        var replacement = LibraryChange()
        replacement.batch = .init(
            label: batch.label, moves: batch.moves, snapshot: try JSONSerialization.data(withJSONObject: json))
        try f.store.apply(replacement)

        try f.service.undoLast()

        let book = try #require(try f.store.book(id: id))
        #expect(book.genreSource == old)
        #expect(book.genres == [Self.crime])
        #expect(book.genreTag == old)
        // The file has the text back exactly as it was, not the genres it maps to.
        #expect(try tag(try file(f, id)) == old)
    }

    @Test func GP6_undoPutsAFilesOwnTagBackExactlyAsItStood() throws {
        let f = try F()
        // Brought in as it is, with a tag the mapping reads as something else.
        let old = "Mystery,  Thriller & Suspense / Audiobook"
        var tags = F.meta("Slow Horses", "Mick Herron")
        tags.genres = [old]
        let source = try f.makeM4B("in.m4b", tags: tags)
        #expect(try tag(source) == old)
        let candidate = try #require(f.service.scan([source]).candidates.first)
        #expect(candidate.metadata.genres == [Self.thrillers])
        _ = try f.importedId(try #require(try f.service.importItems([ImportItem(candidate: candidate)]).outcomes.first))
        #expect(try tag(f.lib("Mick Herron/Slow Horses/Slow Horses.m4b")) == Self.thrillers)

        try f.service.undoLast()
        #expect(try tag(source) == old)
    }

    @Test func GP6_aRecordOfBooksIsMarkedSoThatAnEarlierVersionLeavesItAlone() throws {
        let f = try F()
        let id = try importM4B(f, tag: nil)
        #expect(try f.snapshot().version == 4)
        try edit(f, id) { $0.metadata.genres = ["Horror"] }
        #expect(try f.snapshot().version == 4)
        #expect(OperationSnapshot.currentVersion == 5)
        // One this version cannot act on is still refused.
        var newer = try f.snapshot()
        newer.version = OperationSnapshot.currentVersion + 1
        #expect(OperationSnapshot.usable(from: try JSONEncoder().encode(newer)) == nil)
        #expect(OperationSnapshot.usable(from: try JSONEncoder().encode(try f.snapshot())) != nil)
    }

    // MARK: GP7 A catalogue from a newer version

    @Test func GP7_aCatalogueChangedByANewerVersionIsOpenedAsItIsNotRefused() throws {
        let root = try makeTempDir()
        do {
            let store = try LibraryStore(libraryRoot: root)
            var details = BookMetadata(title: "Kept", authors: ["An Author"])
            details.genres = ["History"]
            try store.insert(Book(metadata: details), files: [])
            // What a later version would leave: a change this one has never heard of.
            try store.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO grdb_migrations (identifier) VALUES ('v99');
                    ALTER TABLE book ADD COLUMN somethingNew TEXT;
                    UPDATE book SET somethingNew = 'kept';
                    """)
            }
        }

        // The store does not refuse it: it opens, runs nothing, and reads what it knows.
        let store = try LibraryStore(libraryRoot: root)
        #expect(try store.books().map(\.title) == ["Kept"])
        #expect(try store.books().first?.genres == ["History"])
        try store.dbQueue.read { db in
            let applied = try LibraryStore.migrator.appliedIdentifiers(db)
            let superseded = try LibraryStore.migrator.hasBeenSuperseded(db)
            let kept = try String.fetchOne(db, sql: "SELECT somethingNew FROM book")
            #expect(applied.contains("v99"))
            #expect(superseded)
            #expect(kept == "kept")
        }
        // A change it makes leaves what it does not know where it was.
        var book = try #require(try store.books().first)
        book.rating = 5
        try store.update(book)
        let kept = try store.dbQueue.read { db in try String.fetchOne(db, sql: "SELECT somethingNew FROM book") }
        #expect(kept == "kept")
    }
}
