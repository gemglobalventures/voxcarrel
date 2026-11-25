import Foundation
import GRDB
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// The launch check's look at length headers, what operations do with what they read,
/// and files that cannot be measured.
@Suite struct LibraryServiceLengthCheckTests {
    typealias F = LibraryFixture
    typealias Options = MediaFixtures.MP3Options

    static let frameSeconds = 1152.0 / 44_100
    /// 60 s of audio is 2297 frames; the wrong header states 100.
    static let trueSeconds = 2297 * frameSeconds
    static let statedSeconds = 100 * frameSeconds

    /// Puts a book back as a version that knew nothing of length headers recorded it.
    func recordAsBefore(_ f: F, _ id: Int64, seconds: Double, keepingProblems: Bool = false) throws {
        let ids = try f.store.files(bookId: id).compactMap(\.id)
        try f.store.setMeasuredLength(
            bookId: id, durationSeconds: seconds,
            lengthProblems: keepingProblems ? [:] : Dictionary(uniqueKeysWithValues: ids.map { ($0, nil) }))
    }

    func length(_ f: F, _ id: Int64) throws -> Double {
        try #require(try f.store.book(id: id)?.durationSeconds)
    }

    func edit(_ f: F, _ id: Int64, genre: String) throws {
        var edit = BookEdit(book: try #require(try f.store.book(id: id)), cover: .keep)
        edit.metadata.genres = [genre]
        _ = try f.service.save([edit])
    }

    /// Four healthy parts of a minute and one whose header states 2.6 s.
    func importMixedBook(_ f: F) throws -> (id: Int64, trueTotal: Double, recordedBefore: Double) {
        let tags = F.meta("Mixed Book", "An Author")
        let urls = try f.makeBuiltMP3s(
            folder: "Mixed", tags: tags, parts: [.init(), .init(), .init(), .init(), .wrongHeader()])
        let id = try f.importNew(urls, tags)
        let total = try length(f, id)
        #expect(abs(total - 5 * Self.trueSeconds) < 0.01)
        return (id, total, total - Self.trueSeconds + Self.statedSeconds)
    }

    // MARK: One wrong part among healthy ones

    // The total is 242.6 s for five minutes of audio: a bitrate an MP3 can have, so only
    // the file's own header gives it away.
    @Test func theFirstLaunchCheckFindsOneWrongPartAmongHealthyOnes() throws {
        let f = try F()
        let (id, trueTotal, before) = try importMixedBook(f)
        try recordAsBefore(f, id, seconds: before)

        #expect(try f.service.reconcile() == ReconcileReport(correctedLengths: 1, filesWithWrongLength: 1))

        #expect(abs(try length(f, id) - trueTotal) < 0.01)
        #expect(try f.store.files(bookId: id).map { $0.lengthProblem != nil } == [false, false, false, false, true])
        #expect(try f.service.reconcile() == ReconcileReport())
    }

    @Test func savingABookWithAWrongPartPutsItsTotalRight() throws {
        let f = try F()
        let (id, trueTotal, before) = try importMixedBook(f)
        _ = try f.service.reconcile()  // the library's headers have been looked at
        try recordAsBefore(f, id, seconds: before)
        #expect(try f.service.reconcile() == ReconcileReport())
        #expect(try length(f, id) == before)

        try edit(f, id, genre: "SF")

        #expect(abs(try length(f, id) - trueTotal) < 0.01)
        #expect(try f.store.files(bookId: id).map { $0.lengthProblem != nil } == [false, false, false, false, true])
        // And undo of the save does not bring the wrong total back.
        try f.service.undoLast()
        #expect(abs(try length(f, id) - trueTotal) < 0.01)
        #expect(try f.store.files(bookId: id).last?.lengthProblem != nil)
        #expect(try f.store.book(id: id)?.genres == [])
    }

    @Test func rewritingTagsPutsTheTotalRightToo() throws {
        let f = try F()
        let (id, trueTotal, before) = try importMixedBook(f)
        _ = try f.service.reconcile()
        try recordAsBefore(f, id, seconds: before)

        _ = try f.service.rewriteTags(for: [id])

        #expect(abs(try length(f, id) - trueTotal) < 0.01)
        #expect(try f.store.files(bookId: id).last?.lengthProblem != nil)
    }

    @Test func aBookRecordedAsHavingAWrongPartIsCorrectedAtLaunchWithoutCountingFramesAgain() throws {
        let f = try F()
        let (id, trueTotal, before) = try importMixedBook(f)
        _ = try f.service.reconcile()
        // The part is known to be wrong, but the total was recorded before it was.
        try recordAsBefore(f, id, seconds: before, keepingProblems: true)
        var opened: [URL] = []
        f.service.willMeasure = { opened.append($0) }

        #expect(try f.service.reconcile() == ReconcileReport(correctedLengths: 1))

        #expect(abs(try length(f, id) - trueTotal) < 0.01)
        // The wrong part counts for what was measured, and the others for what they
        // were found to be at the launch before: none is opened.
        #expect(opened.isEmpty)
    }

    @Test func partsReadThroughAndFoundRightAreNotReadAgainWhileTheyStayAsTheyAre() throws {
        let f = try F()
        let (id, trueTotal, _) = try importMixedBook(f)
        var opened: [URL] = []
        f.service.willMeasure = { opened.append($0) }
        let good = Array(try f.fileURLs(id).prefix(4))

        // The first launch reads the four good parts, and remembers each as right.
        _ = try f.service.reconcile()
        #expect(opened == good)
        let rows = try f.store.files(bookId: id)
        #expect(rows.prefix(4).allSatisfy { $0.lengthMeasured != nil } && rows[4].lengthMeasured == nil)
        #expect(abs((rows[0].lengthMeasured?.seconds ?? 0) - Self.trueSeconds) < 0.01)
        #expect(rows[0].lengthMeasured?.describes(fileAt: good[0]) == true)

        // Every launch after that opens none, and the total stays right.
        for _ in 0..<2 {
            opened = []
            #expect(try f.service.reconcile() == ReconcileReport())
            #expect(opened.isEmpty)
            #expect(abs(try length(f, id) - trueTotal) < 0.01)
        }

        // A part that has changed since is read again, and only that one.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: good[1].path)
        opened = []
        _ = try f.service.reconcile()
        #expect(opened == [good[1]])
        #expect(try f.store.files(bookId: id)[1].lengthMeasured?.describes(fileAt: good[1]) == true)
        opened = []
        _ = try f.service.reconcile()
        #expect(opened.isEmpty)
    }

    @Test func aPartWhoseTagsWereRewrittenIsReadOnceMoreAndThenRemembered() throws {
        let f = try F()
        let (id, trueTotal, _) = try importMixedBook(f)
        _ = try f.service.reconcile()
        try edit(f, id, genre: "Fantasy")
        var opened = 0
        f.service.willMeasure = { _ in opened += 1 }
        _ = try f.service.reconcile()
        let afterEdit = opened
        opened = 0
        _ = try f.service.reconcile()
        // Whatever the save left to be read, the launch after it reads nothing.
        #expect(opened == 0 && afterEdit <= 4)
        #expect(abs(try length(f, id) - trueTotal) < 0.01)
        // What is remembered is of the files as they are now.
        for (row, url) in zip(try f.store.files(bookId: id), try f.fileURLs(id)) {
            if let state = row.lengthMeasured { #expect(state.describes(fileAt: url)) }
        }
    }

    @Test func aRememberedLengthIsNotUsedForAFileThatHasBecomeWrong() throws {
        // Recorded as right, then recorded as wrong: the wrong record is the one that counts.
        let state = MeasuredLength(size: 10, modified: 5, seconds: 60)
        #expect(state == MeasuredLength(size: 10, modified: 5, seconds: 60))
        let folder = try makeTempDir()
        let file = folder.appendingPathComponent("a.mp3")
        try Data(count: 10).write(to: file)
        let now = try #require(MeasuredLength(fileAt: file, seconds: 60))
        #expect(now.describes(fileAt: file) && now.size == 10)
        try Data(count: 11).write(to: file)
        #expect(!now.describes(fileAt: file))
        #expect(MeasuredLength(fileAt: folder.appendingPathComponent("none.mp3"), seconds: 1) == nil)
        #expect(!now.describes(fileAt: folder.appendingPathComponent("none.mp3")))
    }

    @Test func repairingPutsTheTotalRightAndItStaysRight() throws {
        let f = try F()
        let (id, trueTotal, before) = try importMixedBook(f)
        _ = try f.service.reconcile()
        try recordAsBefore(f, id, seconds: before, keepingProblems: true)

        _ = try f.service.repairLengthHeaders(for: [id])

        #expect(abs(try length(f, id) - trueTotal) < 0.01)
        #expect(try f.store.files(bookId: id).allSatisfy { $0.lengthProblem == nil })
        #expect(try f.service.reconcile() == ReconcileReport())
        #expect(abs(try length(f, id) - trueTotal) < 0.01)
        // Undo gives the wrong header back, and the total is still the audio's.
        try f.service.undoLast()
        #expect(try f.store.files(bookId: id).last?.lengthProblem != nil)
        #expect(abs(try length(f, id) - trueTotal) < 0.01)
    }

    @Test func aRepairThatFailsItsChecksStillPutsTheTotalRight() throws {
        let f = try F()
        let (id, trueTotal, before) = try importMixedBook(f)
        _ = try f.service.reconcile()
        try recordAsBefore(f, id, seconds: before, keepingProblems: true)
        f.service.headerRepair.playbackSeconds = { _ in nil }

        _ = try f.service.repairLengthHeaders(for: [id])

        #expect(abs(try length(f, id) - trueTotal) < 0.01)
        #expect(try f.store.files(bookId: id).last?.lengthProblem != nil)
        #expect(try f.service.undoLabel() != "Repair length header in 1 file")
    }

    // MARK: Undo and what was corrected since

    @Test func undoingAnEarlierEditKeepsTheCorrectedLength() throws {
        let f = try F()
        let id = try f.importWrongHeaderBook(parts: 2)
        try recordAsBefore(f, id, seconds: 2 * Self.statedSeconds)
        try edit(f, id, genre: "SF")
        // As an earlier version left it: the edit recorded, the lengths as the headers state.
        try recordAsBefore(f, id, seconds: 2 * Self.statedSeconds)
        #expect(try f.service.reconcile().correctedLengths == 1)
        #expect(abs(try length(f, id) - 2 * Self.trueSeconds) < 0.01)

        #expect(try f.service.undoLast() == "Edit Long Book")

        #expect(try f.store.book(id: id)?.genres == [])
        #expect(abs(try length(f, id) - 2 * Self.trueSeconds) < 0.01)
        #expect(try f.store.files(bookId: id).allSatisfy { $0.lengthProblem?.repairable == true })
        // The next launch has nothing to correct, and so nothing to say.
        #expect(try f.service.reconcile() == ReconcileReport())
    }

    // MARK: A file that cannot be measured

    /// A part whose header is wrong and whose frames cannot be counted: more bytes that
    /// are not audio lie among them than is tolerated.
    func importUnmeasurableBook(_ f: F) throws -> Int64 {
        let tags = F.meta("Odd Book", "An Author")
        let junk = Data(repeating: 0x55, count: MP3FrameScan.junkTolerance + 1)
        return try f.importNew(
            try f.makeBuiltMP3s(folder: "Odd", tags: tags, parts: [
                Options(statedFrames: 100, statedBytes: 41_700, junk: (afterFrame: 2000, bytes: junk)),
            ]), tags)
    }

    @Test func aFileThatCannotBeMeasuredIsRecordedAsSuchAndLeftAloneAtLaunch() throws {
        let f = try F()
        let id = try importUnmeasurableBook(f)
        let url = try f.fileURLs(id)[0]
        let row = try #require(try f.store.files(bookId: id).first)
        let state = try #require(row.lengthUnmeasured)
        #expect(row.lengthProblem == nil)
        #expect(abs(state.statedSeconds - Self.statedSeconds) < 0.01)
        #expect(state.describes(fileAt: url))
        #expect(abs(try length(f, id) - Self.statedSeconds) < 0.01)

        var opened = 0
        var headerReads = 0
        f.service.willMeasure = { _ in opened += 1 }
        f.service.didReadHeader = { _, _ in headerReads += 1 }
        for _ in 0..<3 { #expect(try f.service.reconcile() == ReconcileReport()) }
        #expect(opened == 0)
        #expect(headerReads == 0)
        #expect(try f.store.files(bookId: id).first == row)

        // A file that has changed since is measured again, once.
        var bytes = try f.bytes(url)
        bytes.append(0)
        try bytes.write(to: url)
        #expect(!state.describes(fileAt: url))
        for _ in 0..<2 { #expect(try f.service.reconcile() == ReconcileReport()) }
        #expect(opened == 1)
        #expect(try #require(try f.store.files(bookId: id).first?.lengthUnmeasured).describes(fileAt: url))
    }

    @Test func aSaveKeepsWhatIsKnownOfAFileThatCannotBeMeasured() throws {
        let f = try F()
        let id = try importUnmeasurableBook(f)
        try edit(f, id, genre: "SF")
        let url = try f.fileURLs(id)[0]
        #expect(try #require(try f.store.files(bookId: id).first?.lengthUnmeasured).describes(fileAt: url))
        // A change that opens no file leaves the record as it is.
        var rated = BookEdit(book: try #require(try f.store.book(id: id)), cover: .keep)
        rated.rating = 4
        _ = try f.service.save([rated])
        #expect(try #require(try f.store.files(bookId: id).first?.lengthUnmeasured).describes(fileAt: url))
        var opened = 0
        f.service.willMeasure = { _ in opened += 1 }
        #expect(try f.service.reconcile() == ReconcileReport())
        #expect(opened == 0)
    }

    @Test func aFileThatCanBeMeasuredAfterAllLosesTheRecord() throws {
        let f = try F()
        let id = try importUnmeasurableBook(f)
        let url = try f.fileURLs(id)[0]
        // Replaced by a file with the same wrong header and nothing in the way.
        try MediaFixtures.makeMP3(.wrongHeader()).data.write(to: url)

        #expect(try f.service.reconcile() == ReconcileReport(correctedLengths: 1, filesWithWrongLength: 1))

        let row = try #require(try f.store.files(bookId: id).first)
        #expect(row.lengthUnmeasured == nil)
        #expect(row.lengthProblem?.repairable == true)
        #expect(abs(try length(f, id) - Self.trueSeconds) < 0.01)
    }

    // MARK: The one look at every header

    @Test func theFirstLaunchCheckLooksAtEveryMP3HeaderWithAFewSmallReads() throws {
        let f = try F()
        let author = "An Author"
        let healthy = try f.importNew(
            try f.makeBuiltMP3s(folder: "Fine", tags: F.meta("Fine Book", author), parts: [
                .init(), .init(header: .none), .init(seconds: 600, variableBitrate: true), .init(header: .info),
            ]), F.meta("Fine Book", author))
        let m4b = try f.importNew(
            [try f.makeM4B("Other.m4b", tags: F.meta("Other", author))], F.meta("Other", author))
        // A header with a frame count only: the tag library sets it aside, so the length
        // recorded is right, but players that go by the header stop after 2.6 s.
        let framesOnly = try f.importNew(
            try f.makeBuiltMP3s(folder: "Frames", tags: F.meta("Frames Only", author), parts: [
                .init(statedFrames: 100, xingFlags: 1),
            ]), F.meta("Frames Only", author))
        try recordAsBefore(f, framesOnly, seconds: try length(f, framesOnly))
        // Ten minutes at 128 kbit/s stating five: 256 kbit/s, which an MP3 can be.
        let half = try f.importNew(
            try f.makeBuiltMP3s(folder: "Half", tags: F.meta("Half Book", author), parts: [
                .init(seconds: 600, statedFrames: 11_484), .init(seconds: 600, statedFrames: 11_484),
            ]), F.meta("Half Book", author))
        let trueHalf = try length(f, half)
        try recordAsBefore(f, half, seconds: trueHalf / 2)
        let untouched = try [healthy, m4b].map { try f.store.book(id: $0) }
        let mp3s = Set(try [healthy, framesOnly, half].flatMap { try f.fileURLs($0) })

        var reads: [URL: [Int]] = [:]
        var opened: [URL] = []
        f.service.didReadHeader = { reads[$0, default: []].append($1) }
        f.service.willMeasure = { opened.append($0) }

        let report = try f.service.reconcile()

        #expect(report == ReconcileReport(correctedLengths: 1, filesWithWrongLength: 3))
        #expect(abs(try length(f, half) - trueHalf) < 0.01)
        #expect(try f.store.files(bookId: half).allSatisfy { $0.lengthProblem?.repairable == true })
        let flagged = try #require(try f.store.files(bookId: framesOnly).first?.lengthProblem)
        #expect(abs(flagged.statedSeconds - Self.statedSeconds) < 0.01)
        #expect(abs(flagged.trueSeconds - Self.trueSeconds) < 0.01)
        #expect(try [healthy, m4b].map { try f.store.book(id: $0) } == untouched)
        #expect(try f.store.files(bookId: healthy).allSatisfy { $0.lengthProblem == nil })

        // Only MP3s were looked at, every healthy one, each with a few small reads; and
        // only the files of the two books with a suspect header were read in full.
        #expect(Set(reads.keys).isSubset(of: mp3s))
        #expect(Set(reads.keys).isSuperset(of: try f.fileURLs(healthy)))
        #expect(reads.values.allSatisfy { $0.count <= 16 && $0.reduce(0, +) <= 200_000 })
        #expect(Set(opened) == Set(try [framesOnly, half].flatMap { try f.fileURLs($0) }))

        // It is done once for a library.
        reads = [:]
        opened = []
        #expect(try f.service.reconcile() == ReconcileReport())
        #expect(reads.isEmpty)
        #expect(opened.isEmpty)

        // A check that was cut short left no note, and is made again: what was found
        // already is not looked for twice, and nothing changes.
        try f.store.setNote(LibraryService.lengthHeadersNote, to: nil)
        let rows = try f.store.allFiles()
        #expect(try f.service.reconcile() == ReconcileReport())
        #expect(Set(reads.keys) == Set(try f.fileURLs(healthy)))
        #expect(opened.isEmpty)
        #expect(try f.store.allFiles() == rows)
        #expect(try f.store.note(LibraryService.lengthHeadersNote) != nil)
    }

    @Test func aBookWhoseFilesComeBackHasItsHeadersLookedAt() throws {
        let f = try F()
        let tags = F.meta("Frames Only", "An Author")
        let id = try f.importNew(
            try f.makeBuiltMP3s(folder: "Frames", tags: tags, parts: [.init(statedFrames: 100, xingFlags: 1)]), tags)
        try recordAsBefore(f, id, seconds: try length(f, id))
        let url = try f.fileURLs(id)[0]
        let away = f.inbox.appendingPathComponent("away.mp3")
        try FileManager.default.moveItem(at: url, to: away)
        // The library is looked over while the file is away.
        #expect(try f.service.reconcile().booksWithMissingFiles == [id])
        #expect(try f.store.note(LibraryService.lengthHeadersNote) != nil)
        try FileManager.default.moveItem(at: away, to: url)

        let report = try f.service.reconcile()

        #expect(report.booksRecovered == [id])
        #expect(report.filesWithWrongLength == 1)
        #expect(try f.store.files(bookId: id).first?.lengthProblem != nil)
    }

    // MARK: The database

    @Test func aV5DatabaseUpgrades() throws {
        let root = try makeTempDir()
        let path = root.appendingPathComponent(LibraryStore.databaseFileName).path
        let problem = LengthProblem(statedSeconds: 42, trueSeconds: 4368.5, repairable: true)
        do {
            let queue = try DatabaseQueue(path: path)
            try LibraryStore.migrator.migrate(queue, upTo: "v5")
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO book (title, authors, narrators, tags, rating, needsAttention, folderPath,
                                      durationSeconds, dateAdded, readStatus, appOnlyFields, externalCopies)
                    VALUES ('Old Book', '["Old Author"]', '[]', '[]', 0, 0, 'Old Author/Old Book', 4368.5,
                            '2025-01-02 03:04:05.000', 'unread', '[]', '[]')
                    """)
                try db.execute(sql: """
                    INSERT INTO bookFile (bookId, path, format, role, position, lengthProblem)
                    VALUES (?, 'Old Author/Old Book/Part 1.mp3', 'mp3', 'audio', 0, ?)
                    """, arguments: [db.lastInsertedRowID, String(decoding: try JSONEncoder().encode(problem), as: UTF8.self)])
            }
            try queue.close()
        }

        let store = try LibraryStore(libraryRoot: root)

        let id = try #require(try store.books().first?.id)
        var row = try #require(try store.files(bookId: id).first)
        #expect(row.lengthProblem == problem)
        #expect(row.lengthUnmeasured == nil)
        #expect(try store.note("anything") == nil)

        // The new column and the notes hold what they are given.
        let state = UnmeasuredLength(size: 49_500_000, modified: 771_234_567.25, statedSeconds: 42)
        try store.setMeasuredLength(
            bookId: id, durationSeconds: nil, lengthProblems: [:], unmeasured: [try #require(row.id): state])
        row = try #require(try store.files(bookId: id).first)
        #expect(row.lengthUnmeasured == state)
        #expect(row.lengthProblem == problem)
        try store.setMeasuredLength(
            bookId: id, durationSeconds: nil, lengthProblems: [try #require(row.id): nil],
            unmeasured: [try #require(row.id): nil])
        #expect(try store.files(bookId: id).first.map { $0.lengthProblem == nil && $0.lengthUnmeasured == nil } == true)
        try store.setNote("k", to: "1")
        try store.setNote("k", to: "2")
        #expect(try store.note("k") == "2")
        try store.setNote("k", to: nil)
        #expect(try store.note("k") == nil)
    }

    @Test func whatCannotBeReadInTheNewColumnsCountsAsNothing() throws {
        let f = try F()
        let id = try f.importWrongHeaderBook(parts: 1)
        for text in ["not json", "{\"size\": \"x\"}", "{}", "[1,2]", "42"] {
            try f.store.dbQueue.write { db in
                try db.execute(sql: "UPDATE bookFile SET lengthProblem = ?, lengthUnmeasured = ?", arguments: [text, text])
            }
            let rows = try f.store.files(bookId: id)
            #expect(rows.count == 1)
            #expect(rows.first?.lengthProblem == nil)
            #expect(rows.first?.lengthUnmeasured == nil)
        }
        // An undo snapshot holding such a row is still read.
        var row = try #require(try f.store.files(bookId: id).first)
        row.lengthUnmeasured = UnmeasuredLength(size: 1, modified: 2, statedSeconds: 3)
        var json = try #require(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(row)) as? [String: Any])
        json["lengthUnmeasured"] = "later"
        let decoded = try JSONDecoder().decode(BookFile.self, from: try JSONSerialization.data(withJSONObject: json))
        #expect(decoded.lengthUnmeasured == nil)
        #expect(decoded.path == row.path)
    }
}
