import Foundation
import GRDB
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

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

    // The journal holds the newest batches, the last recorded being the one Undo
    // reverses next: recording adds one, and deleting the latest leaves the one before.
    @Test func recordingAddsABatchAndDeletingTheLatestLeavesTheOneBefore() throws {
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
        #expect(counts.0 == 2)
        #expect(counts.1 == 2)
        #expect(try store.batches().map(\.label) == ["second", "first"])

        try store.deleteBatch(id: second)

        #expect(try store.lastBatch()?.label == "first")
        #expect(try store.lastBatch()?.moves == [moves[0]])
    }

    // No more than the limit is kept: the oldest go as new ones come, with their moves.
    @Test func theJournalKeepsOnlyTheNewestBatches() throws {
        let store = try LibraryStore(libraryRoot: makeTempDir())
        for number in 1...(LibraryStore.journalLimit + 5) {
            try store.recordBatch(label: "batch \(number)", moves: [moves[0]])
        }
        let labels = try store.batches().map(\.label)
        #expect(labels.count == LibraryStore.journalLimit && LibraryStore.journalLimit == 20)
        #expect(labels.first == "batch 25" && labels.last == "batch 6")
        let kept = try store.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM operationMove") }
        #expect(kept == LibraryStore.journalLimit)
    }

    // An undo takes off the newest alone; an operation that cannot be undone cuts the
    // journal through the newest batch about its book, and leaves those after it.
    @Test func theNewestIsTakenOffAndTheJournalIsCutThroughABatch() throws {
        let store = try LibraryStore(libraryRoot: makeTempDir())
        let ids = try (1...5).map { try store.recordBatch(label: "batch \($0)", moves: [moves[0]]) }
        var pop = LibraryChange()
        pop.popsJournal = true
        _ = try store.apply(pop)
        #expect(try store.batches().map(\.label) == ["batch 4", "batch 3", "batch 2", "batch 1"])
        var cut = LibraryChange()
        cut.cutsJournalThrough = ids[1]
        _ = try store.apply(cut)
        #expect(try store.batches().map(\.label) == ["batch 4", "batch 3"])
        var alone = LibraryChange()
        alone.batch = .init(label: "stands alone", moves: [], snapshot: nil)
        alone.batch?.keepsEarlier = false
        _ = try store.apply(alone)
        #expect(try store.batches().map(\.label) == ["stands alone"])
    }
}
