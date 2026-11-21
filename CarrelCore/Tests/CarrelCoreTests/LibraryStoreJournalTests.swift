import Foundation
import Testing
@testable import CarrelCore

@Suite struct LibraryStoreJournalTests {
    let moves = [
        MoveRecord(from: "/in/a.mp3", to: "/lib/01.mp3", wasCopy: false),
        MoveRecord(from: "/in/b.mp3", to: "/lib/02.mp3", wasCopy: true),
    ]

    @Test func emptyJournalHasNoLastBatch() throws {
        let store = try LibraryStore(libraryRoot: makeTempDir())
        #expect(try store.lastBatch() == nil)
    }

    @Test func recordedBatchComesBackWithMovesInOrder() throws {
        let store = try LibraryStore(libraryRoot: makeTempDir())

        let id = try store.recordBatch(label: "Import 2 books", moves: moves)

        let batch = try #require(try store.lastBatch())
        #expect(batch.id == id)
        #expect(batch.label == "Import 2 books")
        #expect(batch.moves == moves)
    }

    @Test func lastBatchIsTheMostRecentOne() throws {
        let store = try LibraryStore(libraryRoot: makeTempDir())
        try store.recordBatch(label: "first", moves: [moves[0]])
        try store.recordBatch(label: "second", moves: [moves[1]])

        #expect(try store.lastBatch()?.label == "second")
    }

    @Test func deletingABatchExposesThePreviousOne() throws {
        let store = try LibraryStore(libraryRoot: makeTempDir())
        try store.recordBatch(label: "first", moves: [moves[0]])
        let second = try store.recordBatch(label: "second", moves: [moves[1]])

        try store.deleteBatch(id: second)

        let batch = try #require(try store.lastBatch())
        #expect(batch.label == "first")
        #expect(batch.moves == [moves[0]])
    }
}
