import Foundation
import GRDB
import Testing
@testable import VoxCarrelCore

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

    // The journal holds one batch (Plan 3, rules S5 and S6): recording replaces the
    // previous batch, so deleting the latest leaves nothing behind.
    @Test func recordingReplacesThePreviousBatchAndDeletingEmptiesTheJournal() throws {
        let store = try LibraryStore(libraryRoot: makeTempDir())
        try store.recordBatch(label: "first", moves: [moves[0]])
        let second = try store.recordBatch(label: "second", moves: [moves[1]])

        let batch = try #require(try store.lastBatch())
        #expect(batch.id == second)
        #expect(batch.label == "second")
        #expect(batch.moves == [moves[1]])
        let counts = try store.dbQueue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM operationBatch"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM operationMove"))
        }
        #expect(counts.0 == 1)
        #expect(counts.1 == 1)

        try store.deleteBatch(id: second)

        #expect(try store.lastBatch() == nil)
    }
}
