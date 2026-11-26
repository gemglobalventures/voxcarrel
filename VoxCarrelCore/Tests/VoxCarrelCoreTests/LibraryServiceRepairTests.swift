import AVFoundation
import CTagBridge
import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

@Suite struct LibraryServiceRepairTests {
    typealias F = LibraryFixture
    static let trueSeconds = 2297.0 * 1152 / 44_100

    /// What the files of a book hold, byte for byte.
    func contents(_ f: F, _ id: Int64) throws -> [Data] {
        try f.fileURLs(id).map { try f.bytes($0) }
    }

    func problems(_ outcome: SaveOutcome?) -> [FileProblem]? {
        guard case .saved(_, false, _, let problems) = outcome else { return nil }
        return problems
    }

    func noWorkingCopies(_ f: F) -> Bool {
        let all = FileManager.default.enumerator(at: f.root, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? []
        return !all.contains { LibraryService.isWorkingCopy($0) }
    }

    // MARK: Repair

    @Test func repairingABookRewritesEveryWrongHeaderAsOneOperation() async throws {
        let f = try F()
        let id = try f.importWrongHeaderBook()
        let book = try #require(try f.store.book(id: id))
        let before = try contents(f, id)

        let outcomes = try f.service.repairLengthHeaders(for: [id])

        #expect(problems(outcomes.first) == [])
        #expect(outcomes.count == 1)
        #expect(try f.service.undoLabel() == "Repair length headers in 3 files")
        // The book is as it was: its length was the true one already.
        #expect(try f.store.book(id: id) == book)
        let files = try f.store.files(bookId: id)
        #expect(files.count == 3)
        #expect(files.allSatisfy { $0.lengthProblem == nil && $0.writeProblem == nil })
        for (url, was) in zip(try f.fileURLs(id), before) {
            #expect(abs(try CTBTagFile.readMP3(atPath: url.path).durationSeconds - Self.trueSeconds) < 0.01)
            #expect(abs(try await MediaFixtures.avDuration(url) - Self.trueSeconds) < 0.05)
            #expect(try f.bytes(url).count == was.count)
            #expect(try f.tags(url).title == "Long Book")
        }
        #expect(noWorkingCopies(f))

        let snapshot = try f.snapshot()
        let repairs = try #require(snapshot.books.first).headerRepairs
        #expect(repairs.map(\.pathAfter) == (try f.fileURLs(id).map(\.path)))
        #expect(repairs.allSatisfy { $0.originalFrame.count == 417 && $0.originalSHA256.count == 64 })
        #expect(snapshot.books.first?.fileStates.isEmpty == true)

        // The launch check has nothing to say about it.
        #expect(try f.service.reconcile() == ReconcileReport())
    }

    @Test func undoPutsEveryFileBackByteForByte() throws {
        let f = try F()
        let tags = F.meta("Long Book", "An Author")
        let urls = try f.makeBuiltMP3s(folder: "Long", tags: tags, parts: [
            .wrongHeader(), .init(statedFrames: 100, statedBytes: 41_700, lameExtension: true, id3v1: true),
        ])
        let id = try f.importNew(urls, tags, cover: .set(F.jpeg))
        let book = try #require(try f.store.book(id: id))
        let rows = try f.store.files(bookId: id)
        let before = try contents(f, id)
        #expect(rows.allSatisfy { $0.lengthProblem?.repairable == true })

        _ = try f.service.repairLengthHeaders(for: [id])
        #expect(try contents(f, id) != before)
        #expect(try f.service.undoLabel() == "Repair length headers in 2 files")

        let token = try f.snapshot().token
        #expect(try f.service.undoLast() == "Repair length headers in 2 files")

        #expect(try contents(f, id) == before)
        #expect(try f.store.book(id: id) == book)
        let restored = try f.store.files(bookId: id)
        #expect(restored.map(\.lengthProblem) == rows.map(\.lengthProblem))
        #expect(restored.map(\.path) == rows.map(\.path))
        #expect(restored.map(\.id) == rows.map(\.id))
        // The stored cover is still the book's.
        #expect(f.service.covers.image(for: id) == F.jpeg)
        // The repair is undone, and what was kept to undo it is gone.
        #expect(try f.service.undoLabels().allSatisfy { $0.hasPrefix("Import ") })
        #expect(noWorkingCopies(f))
        #expect(!f.hiddenTree().contains { $0.hasPrefix("undo/\(token)") })
    }

    @Test func oneFileIsNamedInTheSingular() throws {
        let f = try F()
        let id = try f.importWrongHeaderBook(parts: 1)
        _ = try f.service.repairLengthHeaders(for: [id])
        #expect(try f.service.undoLabel() == "Repair length header in 1 file")
    }

    @Test func severalBooksAreOneOperation() throws {
        let f = try F()
        let one = try f.importWrongHeaderBook("One", parts: 2)
        let two = try f.importWrongHeaderBook("Two", parts: 1)
        let fine = try f.importNew(
            [try f.makeMP3("fine.mp3", tags: F.meta("Fine", "An Author"))], F.meta("Fine", "An Author"))
        let before = try [one, two, fine].map { try contents(f, $0) }

        let outcomes = try f.service.repairLengthHeaders(for: [one, fine, two, 9999, one])

        #expect(problems(outcomes[0]) == [])
        #expect(problems(outcomes[1]) == [])
        #expect(problems(outcomes[2]) == [])
        #expect(outcomes[3] == .failed(bookId: 9999, reason: "That book is not in the library"))
        #expect(outcomes[4] == .failed(bookId: one, reason: "That book is already being repaired by this call"))
        #expect(try f.service.undoLabel() == "Repair length headers in 3 files")
        #expect(try f.snapshot().books.map(\.bookId) == [one, two])
        #expect(try contents(f, fine) == before[2])

        try f.service.undoLast()
        #expect(try [one, two, fine].map { try contents(f, $0) } == before)
    }

    @Test func aBookWithNothingToRepairRecordsNothing() throws {
        let f = try F()
        let tags = F.meta("Fine", "An Author")
        let id = try f.importNew(try f.makeBuiltMP3s(folder: "Fine", tags: tags, parts: [.init()]), tags)
        let before = try contents(f, id)
        let batch = try #require(try f.store.lastBatch())

        let outcomes = try f.service.repairLengthHeaders(for: [id])

        #expect(problems(outcomes.first) == [])
        #expect(try contents(f, id) == before)
        #expect(try f.store.lastBatch() == batch)
        #expect(try f.service.undoLabel() == batch.label)
        #expect(try f.service.repairLengthHeaders(for: []).isEmpty)
    }

    // MARK: Files that are not repaired

    @Test func aHeaderOfAnotherKindIsReportedAndLeftAlone() throws {
        let f = try F()
        let tags = F.meta("Mixed Book", "An Author")
        let urls = try f.makeBuiltMP3s(folder: "Mixed", tags: tags, parts: [
            .wrongHeader(), .init(header: .vbri, statedFrames: 100, statedBytes: 41_700),
        ])
        let id = try f.importNew(urls, tags)
        let before = try contents(f, id)
        let vbri = try #require(try f.store.files(bookId: id).last?.lengthProblem)
        #expect(!vbri.repairable)

        let outcomes = try f.service.repairLengthHeaders(for: [id])

        let reported = try #require(problems(outcomes.first))
        #expect(reported.count == 1)
        #expect(reported[0].file == (try f.fileURLs(id)[1].lastPathComponent))
        #expect(reported[0].reason.contains("cannot be repaired"))
        #expect(reported[0].reason.contains("left as it is"))
        let after = try contents(f, id)
        #expect(after[0] != before[0])
        #expect(after[1] == before[1])
        #expect(try f.store.files(bookId: id).map(\.lengthProblem) == [nil, vbri])
        #expect(try f.service.undoLabel() == "Repair length header in 1 file")
    }

    @Test func aBookWhoseOnlyWrongHeaderCannotBeRepairedRecordsNothing() throws {
        let f = try F()
        let tags = F.meta("VBRI Book", "An Author")
        let id = try f.importNew(
            try f.makeBuiltMP3s(
                folder: "VBRI", tags: tags, parts: [.init(header: .vbri, statedFrames: 100, statedBytes: 41_700)]),
            tags)
        let before = try contents(f, id)
        let batch = try #require(try f.store.lastBatch())

        let outcomes = try f.service.repairLengthHeaders(for: [id])

        #expect(try #require(problems(outcomes.first)).count == 1)
        #expect(try contents(f, id) == before)
        #expect(try f.store.lastBatch() == batch)
        #expect(noWorkingCopies(f))
    }

    @Test func aFailedCheckLeavesTheFileAndItsRecordAsTheyWere() throws {
        let f = try F()
        let id = try f.importWrongHeaderBook(parts: 2)
        let before = try contents(f, id)
        let rows = try f.store.files(bookId: id)
        let batch = try #require(try f.store.lastBatch())
        // The system's players would still read another length from the second part.
        let second = try f.fileURLs(id)[1].lastPathComponent
        let real = f.service.headerRepair.playbackSeconds
        var seen = 0
        f.service.headerRepair.playbackSeconds = { url in
            seen += 1
            return seen == 2 ? 2.6 : real(url)
        }

        let outcomes = try f.service.repairLengthHeaders(for: [id])

        let reported = try #require(problems(outcomes.first))
        #expect(reported.map(\.file) == [second])
        #expect(reported[0].reason.contains("did not pass its checks"))
        #expect(reported[0].reason.contains("the original was kept"))
        let after = try contents(f, id)
        #expect(after[0] != before[0])
        #expect(after[1] == before[1])
        let now = try f.store.files(bookId: id)
        #expect(now[0].lengthProblem == nil)
        #expect(now[1].lengthProblem == rows[1].lengthProblem)
        #expect(try f.service.undoLabel() == "Repair length header in 1 file")
        #expect(try f.store.lastBatch()?.id != batch.id)
        #expect(noWorkingCopies(f))

        // The part that failed can be repaired by another try, once the obstacle is gone.
        f.service.headerRepair.playbackSeconds = real
        #expect(problems(try f.service.repairLengthHeaders(for: [id]).first) == [])
        #expect(try f.store.files(bookId: id).allSatisfy { $0.lengthProblem == nil })
        #expect(try f.service.undoLabel() == "Repair length header in 1 file")
    }

    @Test func whenEveryFileFailsNothingIsRecorded() throws {
        let f = try F()
        let id = try f.importWrongHeaderBook(parts: 2)
        let before = try contents(f, id)
        let rows = try f.store.files(bookId: id)
        let batch = try #require(try f.store.lastBatch())
        f.service.headerRepair.change = { copy, plan in
            try MP3HeaderRepair.write(copy, plan)
            try MP3HeaderRepair.write(Data([0x01]), at: plan.firstFrame.upperBound + 1000, in: copy)
        }

        let outcomes = try f.service.repairLengthHeaders(for: [id])

        #expect(try #require(problems(outcomes.first)).count == 2)
        #expect(try contents(f, id) == before)
        #expect(try f.store.files(bookId: id) == rows)
        #expect(try f.store.lastBatch() == batch)
        #expect(noWorkingCopies(f))
    }

    @Test func aMissingOrLockedFileIsReported() throws {
        let f = try F()
        let id = try f.importWrongHeaderBook(parts: 2)
        let urls = try f.fileURLs(id)
        let locked = try f.bytes(urls[0])
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: urls[0].path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: urls[0].path) }
        try FileManager.default.removeItem(at: urls[1])

        let outcomes = try f.service.repairLengthHeaders(for: [id])

        let reported = try #require(problems(outcomes.first))
        #expect(reported.count == 2)
        #expect(reported[0].reason.contains("locked"))
        #expect(reported[1].reason.contains("could not be read"))
        #expect(try f.bytes(urls[0]) == locked)
        #expect(try f.store.files(bookId: id).allSatisfy { $0.lengthProblem?.repairable == true })
    }

    @Test func aRecordThatIsOutOfDateIsPutRightWithoutAnOperation() throws {
        let f = try F()
        // Recorded as wrong, but the file's header is right (another program repaired it).
        let tags = F.meta("Fine", "An Author")
        let id = try f.importNew(try f.makeBuiltMP3s(folder: "Fine", tags: tags, parts: [.init()]), tags)
        let fileId = try #require(try f.store.files(bookId: id).first?.id)
        try f.store.setMeasuredLength(
            bookId: id, durationSeconds: nil,
            lengthProblems: [fileId: LengthProblem(statedSeconds: 2.6, trueSeconds: 60, repairable: true)])
        let before = try contents(f, id)
        let batch = try #require(try f.store.lastBatch())

        #expect(problems(try f.service.repairLengthHeaders(for: [id]).first) == [])

        #expect(try contents(f, id) == before)
        let rows = try f.store.files(bookId: id)
        #expect(rows.map(\.lengthProblem) == [nil])
        #expect(rows.map(\.id) == [fileId])
        #expect(try f.store.lastBatch() == batch)
    }

    // MARK: A commit that fails

    @Test func ifTheOperationCannotBeRecordedEveryFileIsPutBack() throws {
        let f = try F()
        let id = try f.importWrongHeaderBook()
        let before = try contents(f, id)
        let rows = try f.store.files(bookId: id)
        let batch = try #require(try f.store.lastBatch())

        f.service.beforeCommit = { throw Boom() }
        #expect(throws: Boom.self) { try f.service.repairLengthHeaders(for: [id]) }
        f.service.beforeCommit = nil

        #expect(try contents(f, id) == before)
        #expect(try f.store.files(bookId: id) == rows)
        #expect(try f.store.lastBatch() == batch)
        #expect(noWorkingCopies(f))
    }

    // MARK: Undo

    @Test func undoLeavesAFileChangedSinceTheRepairAsItIs() throws {
        let f = try F()
        let id = try f.importWrongHeaderBook()
        let rows = try f.store.files(bookId: id)
        let before = try contents(f, id)
        _ = try f.service.repairLengthHeaders(for: [id])
        // Another program rewrites the tags of the second part.
        let urls = try f.fileURLs(id)
        try f.seedTrackTitle(String(repeating: "A much longer track title. ", count: 200), in: urls[1])
        let changed = try f.bytes(urls[1])

        #expect(try f.service.undoLast() == "Repair length headers in 3 files")

        let after = try contents(f, id)
        #expect(after[0] == before[0])
        #expect(after[1] == changed)
        #expect(after[2] == before[2])
        // The record says what each file is now.
        let restored = try f.store.files(bookId: id)
        #expect(restored[0].lengthProblem == rows[0].lengthProblem)
        #expect(restored[1].lengthProblem == nil)
        #expect(restored[2].lengthProblem == rows[2].lengthProblem)
        #expect(try f.io.read(urls[1]).lengthProblem == nil)
        #expect(noWorkingCopies(f))
    }

    /// A copy of the fixture's library folder, database and journal included, opened as
    /// a library of its own.
    func copyOfLibrary(_ f: F) throws -> (root: URL, store: LibraryStore, service: LibraryService) {
        let root = try makeTempDir().appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.copyItem(at: f.root, to: root)
        let store = try LibraryStore(libraryRoot: root)
        return (root, store, LibraryService(store: store, metadataIO: FileMetadataIO(), organiser: Organiser()))
    }

    // The journal names the repaired files in full: in a copy of the library folder they
    // are the files of the folder it was copied from, and must not be written to.
    @Test func aRepairMadeInTheLibraryThisOneWasCopiedFromIsNotUndoable() throws {
        let f = try F()
        let id = try f.importWrongHeaderBook(parts: 2)
        _ = try f.service.repairLengthHeaders(for: [id])
        let repaired = try contents(f, id)
        let copy = try copyOfLibrary(f)
        let copied = try copy.store.files(bookId: id).map { copy.store.url(for: $0) }
        let rows = try copy.store.files(bookId: id)

        #expect(try copy.service.undoLabel() == nil)
        #expect(throws: LibraryError.nothingToUndo) { try copy.service.undoLast() }

        // Nothing was written in either folder, and the record is forgotten.
        #expect(try contents(f, id) == repaired)
        #expect(try copied.map { try Data(contentsOf: $0) } == repaired)
        #expect(try copy.store.files(bookId: id) == rows)
        #expect(try copy.store.lastBatch() == nil)
        // The library it was made in can still undo it.
        #expect(try f.service.undoLabel() == "Repair length headers in 2 files")
    }

    @Test func tagsWrittenInTheLibraryThisOneWasCopiedFromAreNotPutBack() throws {
        let f = try F()
        let tags = F.meta("Dune", "Frank Herbert")
        let id = try f.importNew([try f.makeM4B("in.m4b", tags: tags)], tags)
        var edit = BookEdit(book: try #require(try f.store.book(id: id)), cover: .keep)
        edit.metadata.genres = ["SF"]
        _ = try f.service.save([edit])
        #expect(try #require(try f.store.lastBatch()).moves.isEmpty)
        let written = try contents(f, id)
        let copy = try copyOfLibrary(f)
        let copied = try copy.store.files(bookId: id).map { copy.store.url(for: $0) }

        #expect(try copy.service.undoLabel() == nil)
        #expect(throws: LibraryError.nothingToUndo) { try copy.service.undoLast() }

        #expect(try contents(f, id) == written)
        #expect(try copied.map { try Data(contentsOf: $0) } == written)
        #expect(try copy.store.book(id: id)?.genres == ["SF"])
        #expect(try f.service.undoLabel() == "Edit Dune")
    }

    @Test func aSnapshotSavedBeforeRepairsExistedStillDecodes() throws {
        let old = """
            {"version":1,"token":"T","books":[{"bookId":4,"filesBefore":[],"fileStates":[]}]}
            """
        let snapshot = try #require(OperationSnapshot.usable(from: Data(old.utf8)))
        #expect(snapshot.books.first?.headerRepairs == [])
        // And one with repairs round-trips.
        let state = HeaderRepairState(
            pathAfter: "/a/b.mp3", frameOffset: 4096, originalFrame: Data([0xFF, 0xFB, 0x90, 0xC4]),
            originalSHA256: "abc")
        let with = OperationSnapshot(token: "T", books: [
            BookSnapshot(
                bookId: 4, bookBefore: nil, filesBefore: [], fileStates: [], storedCoverBefore: nil,
                headerRepairs: [state]),
        ])
        #expect(OperationSnapshot.usable(from: try JSONEncoder().encode(with)) == with)
    }

    // MARK: Afterwards

    @Test func savingAfterARepairKeepsTheRepair() throws {
        let f = try F()
        let id = try f.importWrongHeaderBook(parts: 2)
        _ = try f.service.repairLengthHeaders(for: [id])

        var edit = BookEdit(book: try #require(try f.store.book(id: id)), cover: .set(F.png))
        edit.metadata.title = "Renamed Book"
        edit.metadata.summary = String(repeating: "A long description. ", count: 300)
        _ = try f.service.save([edit])
        _ = try f.service.rewriteTags(for: [id])

        #expect(try f.store.files(bookId: id).allSatisfy { $0.lengthProblem == nil && $0.writeProblem == nil })
        for url in try f.fileURLs(id) {
            #expect(try f.tags(url).title == "Renamed Book")
            #expect(try f.io.read(url).lengthProblem == nil)
            #expect(abs(try CTBTagFile.readMP3(atPath: url.path).durationSeconds - Self.trueSeconds) < 0.01)
        }
        #expect(abs(try #require(try f.store.book(id: id)?.durationSeconds) - 2 * Self.trueSeconds) < 0.01)
    }
}
