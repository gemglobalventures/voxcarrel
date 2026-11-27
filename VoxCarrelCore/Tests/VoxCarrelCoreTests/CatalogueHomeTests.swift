import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// CH1–CH6: a library's catalogue kept on the Mac, apart from its books.
@Suite struct CatalogueHomeTests {
    /// A library with one filed book, a cover for it, and where catalogues are kept apart.
    private func made() throws -> (root: URL, libraries: URL, bookId: Int64) {
        let base = try makeTempDir()
        let root = base.appendingPathComponent("Drive/Books", isDirectory: true)
        let store = try LibraryStore(libraryRoot: root)
        let service = LibraryService(store: store)
        let file = root.appendingPathComponent("Ines Calloway/Salt Road/a.m4b")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: file)
        var book = Book(metadata: BookMetadata(title: "Salt Road", authors: ["Ines Calloway"]))
        book.folderPath = "Ines Calloway/Salt Road"
        let id = try #require(try store.insert(
            book, files: [BookFile(path: "Ines Calloway/Salt Road/a.m4b", format: .m4b, role: .audio, position: 0)]).id)
        try service.covers.set(LibraryFixture.jpeg, for: id)
        return (LibraryLayout.canonicalFolder(root), base.appendingPathComponent("Mac/Libraries", isDirectory: true), id)
    }

    // CH1: a tests' run is never given the app's own folder.
    @Test func CH1_aTestIsGivenAFolderOfItsOwn() {
        #expect(!CatalogueHome.standardFolder.path.contains("Application Support/VoxCarrel"))
    }

    // CH2: moved, the catalogue and the covers are on the Mac, the books' folder says
    // which library it is, and the catalogue that was inside it is set aside, not deleted.
    @Test func CH2_theCatalogueMovesToTheMacWithItsCovers() throws {
        let m = try made()
        #expect(CatalogueHome.find(forRoot: m.root, in: m.libraries) == nil && CatalogueHome.isLibraryFolder(m.root))
        let home = try CatalogueHome.moveToMac(libraryAt: m.root, libraries: m.libraries)
        let files = FileManager.default
        #expect(files.fileExists(atPath: home.appendingPathComponent("VoxCarrel.sqlite").path))
        #expect(!files.fileExists(atPath: m.root.appendingPathComponent("VoxCarrel.sqlite").path))
        #expect(files.fileExists(atPath: m.root.appendingPathComponent(".voxcarrel/catalogue-before-move.sqlite").path))
        #expect(CatalogueHome.find(forRoot: m.root, in: m.libraries) == home && CatalogueHome.isLibraryFolder(m.root))
        #expect(CatalogueHome.all(in: m.libraries).map(\.record.root) == [m.root.path])

        let store = try LibraryStore.opening(m.root, libraries: m.libraries)
        #expect(store.catalogueHome == home && store.booksAreReachable)
        #expect(try store.books().map(\.title) == ["Salt Road"] && store.libraryId() == home.lastPathComponent)
        let service = LibraryService(store: store)
        #expect(service.covers.url(for: m.bookId)?.path.hasPrefix(home.path) == true)
        // The books are where they were, and are still found.
        let file = try #require(try store.files(bookId: m.bookId).first)
        #expect(files.fileExists(atPath: store.url(for: file).path))
        // Read-only too, as a program beside the app opens it.
        #expect(try LibraryStore(readingOnly: m.root, libraries: m.libraries).books().count == 1)
        // Moving twice is refused.
        #expect(throws: CatalogueHome.Problem.alreadyThere) { try CatalogueHome.moveToMac(libraryAt: m.root, libraries: m.libraries) }
    }

    // CH3: with the drive away the library still opens and reads, its covers are
    // there, the books' folder is not made, and whatever touches files is refused.
    @Test func CH3_withTheDriveAwayTheLibraryStillOpens() throws {
        let m = try made()
        let home = try CatalogueHome.moveToMac(libraryAt: m.root, libraries: m.libraries)
        let drive = m.root.deletingLastPathComponent()
        let parked = drive.deletingLastPathComponent().appendingPathComponent("Unplugged")
        try FileManager.default.moveItem(at: drive, to: parked)

        #expect(CatalogueHome.find(forRoot: m.root, in: m.libraries) == home)
        let store = try LibraryStore.opening(m.root, libraries: m.libraries)
        #expect(!store.booksAreReachable && !FileManager.default.fileExists(atPath: m.root.path))
        #expect(try store.books().map(\.title) == ["Salt Road"])
        let service = LibraryService(store: store)
        #expect(service.covers.url(for: m.bookId) != nil)
        #expect(throws: LibraryError.booksNotReachable) { try service.importItems([]) }
        #expect(throws: LibraryError.booksNotReachable) { try service.reconcile() }
        #expect(throws: LibraryError.booksNotReachable) { try service.applyHeldEdits() }
        #expect(!FileManager.default.fileExists(atPath: m.root.path))
        // What only the catalogue holds can still be changed.
        try service.setReadStatus(.finished, for: [m.bookId])
        #expect(try store.book(id: m.bookId)?.readStatus == .finished)
        #expect(throws: CatalogueHome.Problem.booksNotReachable) { try CatalogueHome.moveBack(libraryAt: m.root, libraries: m.libraries) }
    }

    // CH4: a drive that comes back under another path is known by what its folder says.
    @Test func CH4_aDriveUnderAnotherNameIsKnownAgain() throws {
        let m = try made()
        let home = try CatalogueHome.moveToMac(libraryAt: m.root, libraries: m.libraries)
        let drive = m.root.deletingLastPathComponent()
        let renamed = drive.deletingLastPathComponent().appendingPathComponent("Drive 1")
        try FileManager.default.moveItem(at: drive, to: renamed)
        let root = LibraryLayout.canonicalFolder(renamed.appendingPathComponent("Books"))
        #expect(CatalogueHome.find(forRoot: root, in: m.libraries) == home)
        #expect(CatalogueHome.all(in: m.libraries).map(\.record.root) == [root.path])
        #expect(try LibraryStore.opening(root, libraries: m.libraries).booksAreReachable)
    }

    // CH5: moved back, the library is as it began, and nothing of it is left on the Mac.
    @Test func CH5_theCatalogueMovesBack() throws {
        let m = try made()
        let home = try CatalogueHome.moveToMac(libraryAt: m.root, libraries: m.libraries)
        do {
            let store = try LibraryStore.opening(m.root, libraries: m.libraries)
            try LibraryService(store: store).setReadStatus(.finished, for: [m.bookId])
        }
        try CatalogueHome.moveBack(libraryAt: m.root, libraries: m.libraries)
        let files = FileManager.default
        #expect(!files.fileExists(atPath: home.path) && CatalogueHome.find(forRoot: m.root, in: m.libraries) == nil)
        #expect(!files.fileExists(atPath: m.root.appendingPathComponent(".voxcarrel/catalogue-on-mac.json").path))
        let store = try LibraryStore.opening(m.root, libraries: m.libraries)
        let status = try store.book(id: m.bookId)?.readStatus
        #expect(store.catalogueHome == nil && status == .finished)
        #expect(LibraryService(store: store).covers.url(for: m.bookId)?.path.hasPrefix(m.root.path) == true)
        #expect(throws: CatalogueHome.Problem.alreadyThere) { try CatalogueHome.moveBack(libraryAt: m.root, libraries: m.libraries) }
    }

    // CH6: a folder with a catalogue of its own is never looked up, and one with none is no library.
    @Test func CH6_aFolderWithItsOwnCatalogueIsItsOwn() throws {
        let m = try made()
        let empty = try makeTempDir().appendingPathComponent("Nothing", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(!CatalogueHome.isLibraryFolder(empty) && CatalogueHome.find(forRoot: empty, in: m.libraries) == nil)
        #expect(throws: CatalogueHome.Problem.noCatalogue) { try CatalogueHome.moveToMac(libraryAt: empty, libraries: m.libraries) }
        #expect(throws: CatalogueHome.Problem.booksNotReachable) {
            try CatalogueHome.moveToMac(libraryAt: empty.appendingPathComponent("gone"), libraries: m.libraries)
        }
        #expect(try LibraryStore.opening(m.root, libraries: m.libraries).catalogueHome == nil)
    }

    // CH8: an edit made while the drive is away is held: the catalogue has it at once,
    // and when the drive is back the files are given it and the book is filed where
    // it now belongs.
    @Test func CH8_editsAreHeldAndCaughtUpWith() throws {
        let base = try makeTempDir()
        let root = base.appendingPathComponent("Drive/Books", isDirectory: true)
        let libraries = base.appendingPathComponent("Mac/Libraries", isDirectory: true)
        let inbox = base.appendingPathComponent("Inbox/Salt Road", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try MediaFixtures.makeSilentMP3(seconds: 1).write(to: inbox.appendingPathComponent("01.mp3"))
        var bookId: Int64 = 0
        do {
            let service = LibraryService(store: try LibraryStore(libraryRoot: root))
            var candidate = try #require(service.scan([inbox]).candidates.first)
            candidate.metadata = BookMetadata(title: "Salt Road", authors: ["Ines Calloway"])
            guard case .imported(let id, _) = try #require(try service.importItems([ImportItem(candidate: candidate)]).outcomes.first)
            else { Issue.record("not imported"); return }
            bookId = id
        }
        try CatalogueHome.moveToMac(libraryAt: root, libraries: libraries)
        let drive = root.deletingLastPathComponent()
        let parked = base.appendingPathComponent("Unplugged")
        try FileManager.default.moveItem(at: drive, to: parked)

        // Away: the edit is taken by the catalogue, and the book is noted as waiting.
        do {
            let store = try LibraryStore.opening(root, libraries: libraries)
            let service = LibraryService(store: store)
            var edit = BookEdit(book: try #require(try store.book(id: bookId)))
            edit.metadata.title = "The Salt Road"
            edit.metadata.narrators = ["Marcus Lindqvist"]
            let outcome = try service.save([edit])
            #expect(outcome == [.saved(bookId: bookId, refiled: false, appOnlyFields: [], fileProblems: [])])
            #expect(try store.book(id: bookId)?.title == "The Salt Road" && service.heldEditCount() == 1)
            // An edit that only the catalogue keeps is owed nothing by the files.
            var rated = BookEdit(book: try #require(try store.book(id: bookId)))
            rated.rating = 4
            _ = try service.save([rated])
            #expect(try service.heldEditCount() == 1 && !FileManager.default.fileExists(atPath: root.path))
            // A held edit is no step for Undo, and nothing is undone while the files are away.
            let labels = try service.undoLabels()
            #expect(!labels.contains { $0.hasPrefix("Edit") })
            #expect(throws: LibraryError.booksNotReachable) { try service.undoLast() }
        }

        // Back: the file is given the details and the folder is named for the new title.
        try FileManager.default.moveItem(at: parked, to: drive)
        let store = try LibraryStore.opening(root, libraries: libraries)
        let service = LibraryService(store: store)
        let before = try #require(try store.files(bookId: bookId).first)
        #expect(before.path.contains("Salt Road") && !before.path.contains("The Salt Road"))
        #expect(try service.applyHeldEdits() == HeldEditsResult(caughtUp: 1, problems: []))
        #expect(try service.heldEditCount() == 0)
        let after = try #require(try store.files(bookId: bookId).first)
        #expect(after.path.contains("The Salt Road") && FileManager.default.fileExists(atPath: store.url(for: after).path))
        let written = try FileMetadataIO().read(store.url(for: after)).metadata
        #expect(written.title == "The Salt Road" && written.narrators == ["Marcus Lindqvist"])
        #expect(try store.book(id: bookId)?.rating == 4)
        // Nothing more is waiting.
        #expect(try service.applyHeldEdits() == HeldEditsResult(caughtUp: 0, problems: []))
    }

    // CH7: a library is never made where a drive that is not connected would be.
    @Test func CH7_noFolderIsMadeWhereADriveWouldBe() {
        let gone = URL(fileURLWithPath: "/Volumes/No Such Drive \(UUID().uuidString)/Books")
        #expect(LibraryStore.unmountedDrive(of: gone) == gone.pathComponents[2])
        #expect(throws: LibraryStoreError.driveNotConnected(gone.pathComponents[2])) { try LibraryStore(libraryRoot: gone) }
        #expect(!FileManager.default.fileExists(atPath: gone.deletingLastPathComponent().path))
        #expect(LibraryStore.unmountedDrive(of: URL(fileURLWithPath: "/Users/Shared/Books")) == nil)
        #expect(LibraryStore.unmountedDrive(of: URL(fileURLWithPath: "/Volumes")) == nil)
    }
}
