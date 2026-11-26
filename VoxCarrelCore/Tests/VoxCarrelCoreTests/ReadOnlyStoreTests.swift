import Foundation
import GRDB
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// RO1–RO4: a catalogue opened for reading only.
@Suite struct ReadOnlyStoreTests {
    typealias F = LibraryFixture

    // RO1: it reads what the library holds, while the library's own store is open.
    @Test func RO1_itReadsTheLibraryBesideTheStoreThatOwnsIt() throws {
        let f = try F()
        let id = try f.importNew([try f.makeEPUB("one.epub")], F.meta("Salt Road", "Ines Calloway"))
        let reader = try LibraryStore(readingOnly: f.root)
        #expect(try reader.book(id: id)?.title == "Salt Road")
        #expect(try reader.search("salt").map(\.id) == [id])
        #expect(reader.libraryRoot == f.store.libraryRoot)
        // What the owner writes afterwards is seen.
        _ = try f.store.modifyBook(id: id) { book, _ in book.rating = 4 }
        #expect(try reader.book(id: id)?.rating == 4)
    }

    // RO2: nothing can be written through it.
    @Test func RO2_nothingCanBeWrittenThroughIt() throws {
        let f = try F()
        let id = try f.importNew([try f.makeEPUB("one.epub")], F.meta("Salt Road", "Ines Calloway"))
        let reader = try LibraryStore(readingOnly: f.root)
        #expect(throws: (any Error).self) { _ = try reader.modifyBook(id: id) { book, _ in book.rating = 1 } }
        #expect(throws: (any Error).self) { try reader.setNote("x", to: "y") }
        #expect(try f.store.book(id: id)?.rating == 0)
    }

    // RO3: a folder with no catalogue is refused, and none is made there.
    @Test func RO3_aFolderThatIsNoLibraryIsRefusedAndLeftAsItIs() throws {
        let f = try F()
        let empty = f.base.appendingPathComponent("not a library", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: LibraryStoreError.noCatalogue) { _ = try LibraryStore(readingOnly: empty) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: empty.path).isEmpty)
        #expect(throws: LibraryStoreError.noCatalogue) {
            _ = try LibraryStore(readingOnly: f.base.appendingPathComponent("no such folder"))
        }
    }

    // RO4: a catalogue an earlier version left is not read, and is not brought up to date.
    @Test func RO4_anOlderCatalogueIsNotReadAndNotChanged() throws {
        let f = try F()
        let folder = f.base.appendingPathComponent("older", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(LibraryStore.databaseFileName)
        let queue = try DatabaseQueue(path: file.path)
        try queue.write { db in try db.execute(sql: "CREATE TABLE book (id INTEGER PRIMARY KEY, title TEXT)") }
        try queue.close()
        let before = try Data(contentsOf: file)
        #expect(throws: LibraryStoreError.catalogueNeedsOpening) { _ = try LibraryStore(readingOnly: folder) }
        #expect(try Data(contentsOf: file) == before)
    }
}
