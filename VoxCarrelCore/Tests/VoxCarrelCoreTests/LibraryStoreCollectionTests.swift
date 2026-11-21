import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

@Suite struct LibraryStoreCollectionTests {
    func makeStore() throws -> LibraryStore {
        try LibraryStore(libraryRoot: makeTempDir())
    }

    func addBook(_ title: String, to store: LibraryStore) throws -> Int64 {
        let book = try store.insert(Book(metadata: BookMetadata(title: title, authors: ["Ann Author"])), files: [])
        return try #require(book.id)
    }

    func memberships(in store: LibraryStore) throws -> Int {
        try store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collectionBook") ?? -1 }
    }

    // C1
    @Test func renameTrimsTheNameAndKeepsTheBooks() throws {
        let store = try makeStore()
        let id = try #require(try store.createCollection(name: "To Read").id)
        let book = try addBook("Dune", to: store)
        try store.add(bookId: book, toCollection: id)

        try store.renameCollection(id: id, to: "  Up Next \n")

        let all = try store.collections()
        #expect(all.map(\.name) == ["Up Next"])
        #expect(all.map(\.id) == [id])
        #expect(try store.books(inCollection: id).map(\.id) == [book])
    }

    // C1
    @Test func blankRenameThrowsAndChangesNothing() throws {
        let store = try makeStore()
        let id = try #require(try store.createCollection(name: "To Read").id)
        let before = try store.collections()

        #expect(throws: CollectionError.blankName) { try store.renameCollection(id: id, to: "") }
        #expect(throws: CollectionError.blankName) { try store.renameCollection(id: id, to: " \n\t ") }

        #expect(try store.collections() == before)
    }

    // C1: "Throws if no collection has that id."
    @Test func renamingAnUnknownCollectionThrowsAndChangesNothing() throws {
        let store = try makeStore()
        _ = try store.createCollection(name: "To Read")
        let before = try store.collections()

        #expect(throws: CollectionError.notFound(999)) { try store.renameCollection(id: 999, to: "Other") }

        #expect(try store.collections() == before)
    }

    // C1: names stay unique; a rename that would repeat one changes nothing.
    @Test func renamingToAnExistingNameThrowsAndChangesNothing() throws {
        let store = try makeStore()
        _ = try store.createCollection(name: "Favourites")
        let id = try #require(try store.createCollection(name: "To Read").id)
        let before = try store.collections()

        #expect(throws: (any Error).self) { try store.renameCollection(id: id, to: "Favourites") }

        #expect(try store.collections() == before)
    }

    // C1
    @Test func collectionsAreSortedByNameIgnoringCase() throws {
        let store = try makeStore()
        for name in ["zebra", "Apple", "mango", "Banana"] { _ = try store.createCollection(name: name) }
        let mango = try #require(try store.collections().first { $0.name == "mango" }?.id)

        #expect(try store.collections().map(\.name) == ["Apple", "Banana", "mango", "zebra"])

        try store.renameCollection(id: mango, to: "aardvark")
        #expect(try store.collections().map(\.name) == ["aardvark", "Apple", "Banana", "zebra"])
    }

    // C2
    @Test func deleteRemovesTheCollectionAndItsMembershipsOnly() throws {
        let store = try makeStore()
        let doomed = try #require(try store.createCollection(name: "Doomed").id)
        let kept = try #require(try store.createCollection(name: "Kept").id)
        let dune = try addBook("Dune", to: store)
        let emma = try addBook("Emma", to: store)
        try store.add(bookId: dune, toCollection: doomed)
        try store.add(bookId: emma, toCollection: doomed)
        try store.add(bookId: dune, toCollection: kept)
        let booksBefore = try store.books()

        try store.deleteCollection(id: doomed)

        #expect(try store.collections().map(\.name) == ["Kept"])
        #expect(try store.books(inCollection: doomed).isEmpty)
        #expect(try store.books(inCollection: kept).map(\.id) == [dune])
        #expect(try memberships(in: store) == 1)
        #expect(try store.books() == booksBefore)  // the books themselves are untouched

        // Deleting it again, or one that never was, does nothing.
        try store.deleteCollection(id: doomed)
        #expect(try store.collections().map(\.name) == ["Kept"])
        #expect(try memberships(in: store) == 1)
    }
}
