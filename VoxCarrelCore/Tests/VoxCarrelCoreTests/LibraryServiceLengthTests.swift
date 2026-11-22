import Foundation
import GRDB
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

extension LibraryFixture {
    /// MP3 parts built to order in one inbox folder, each tagged with `tags`.
    func makeBuiltMP3s(
        folder: String, tags: BookMetadata, parts: [MediaFixtures.MP3Options]
    ) throws -> [URL] {
        let dir = inbox.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try parts.enumerated().map { index, options in
            let url = dir.appendingPathComponent("part\(index + 1).mp3")
            try MediaFixtures.makeMP3(options).data.write(to: url)
            try io.write(tags, to: url)
            return url
        }
    }

    /// A book of MP3 parts with wrong length headers, imported; returns its id.
    func importWrongHeaderBook(
        _ title: String = "Long Book", parts: Int = 3, seconds: Double = 60
    ) throws -> Int64 {
        let tags = Self.meta(title, "An Author")
        let urls = try makeBuiltMP3s(
            folder: title, tags: tags, parts: Array(repeating: .wrongHeader(seconds: seconds), count: parts))
        return try importNew(urls, tags)
    }

    func fileURLs(_ bookId: Int64) throws -> [URL] {
        try store.files(bookId: bookId).map { store.url(for: $0) }
    }
}

@Suite struct LibraryServiceLengthTests {
    /// 60 s of audio is 2297 frames; the wrong header states 100.
    static let trueSeconds = 2297.0 * 1152 / 44_100
    static let statedSeconds = 100.0 * 1152 / 44_100

    // MARK: Import

    @Test func importOfAMultiPartBookWithWrongHeadersGetsTheTrueTotal() throws {
        let f = try LibraryFixture()
        let id = try f.importWrongHeaderBook()

        let book = try #require(try f.store.book(id: id))
        #expect(abs(try #require(book.durationSeconds) - 3 * Self.trueSeconds) < 0.01)
        #expect(!book.needsAttention)
        let files = try f.store.files(bookId: id)
        #expect(files.count == 3)
        for file in files {
            let problem = try #require(file.lengthProblem)
            #expect(problem.repairable)
            #expect(abs(problem.trueSeconds - Self.trueSeconds) < 0.001)
            #expect(abs(problem.statedSeconds - Self.statedSeconds) < 0.01)
            #expect(file.writeProblem == nil)
        }
    }

    /// A candidate carries what its first file says; the total is worked out at import.
    @Test func scanningForImportReadsTheTrueLengthOfAPart() throws {
        let f = try LibraryFixture()
        let tags = LibraryFixture.meta("Long Book", "An Author")
        let urls = try f.makeBuiltMP3s(folder: "Long Book", tags: tags, parts: [.wrongHeader(), .wrongHeader()])
        let scan = f.service.scan([urls[0].deletingLastPathComponent()])
        let candidate = try #require(scan.candidates.first)
        #expect(abs(try #require(candidate.metadata.durationSeconds) - Self.trueSeconds) < 0.01)
    }

    @Test func aHealthyBookHasNoLengthProblem() throws {
        let f = try LibraryFixture()
        let tags = LibraryFixture.meta("Fine Book", "An Author")
        let urls = try f.makeBuiltMP3s(
            folder: "Fine", tags: tags, parts: [.init(), .init(header: .none), .init(header: .vbri)])
        let id = try f.importNew(urls, tags)
        #expect(try f.store.files(bookId: id).allSatisfy { $0.lengthProblem == nil })
        let plain = try f.importNew([try f.makeMP3("plain.mp3", tags: LibraryFixture.meta("Plain", "An Author"))],
                                    LibraryFixture.meta("Plain", "An Author"))
        #expect(try f.store.files(bookId: plain).allSatisfy { $0.lengthProblem == nil })
    }

    @Test func aHeaderThatCannotBeRepairedIsRecordedAsSuch() throws {
        let f = try LibraryFixture()
        let tags = LibraryFixture.meta("VBRI Book", "An Author")
        let urls = try f.makeBuiltMP3s(
            folder: "VBRI", tags: tags, parts: [.init(header: .vbri, statedFrames: 100, statedBytes: 41_700)])
        let id = try f.importNew(urls, tags)
        let problem = try #require(try f.store.files(bookId: id).first?.lengthProblem)
        #expect(!problem.repairable)
        #expect(abs(try #require(try f.store.book(id: id)?.durationSeconds) - Self.trueSeconds) < 0.01)
    }

    @Test func addingPartsToABookKeepsTheTrueTotal() throws {
        let f = try LibraryFixture()
        let id = try f.importWrongHeaderBook(parts: 2)
        let tags = LibraryFixture.meta("Long Book", "An Author")
        let more = try f.makeBuiltMP3s(folder: "More", tags: tags, parts: [.wrongHeader()])
        let renamed = more[0].deletingLastPathComponent().appendingPathComponent("part3.mp3")
        try FileManager.default.moveItem(at: more[0], to: renamed)
        let result = try f.service.importItems(
            [ImportItem(candidate: f.candidate([renamed], tags), target: .existing(bookId: id))],
            options: ImportOptions())
        _ = try f.importedId(try #require(result.outcomes.first))

        #expect(abs(try #require(try f.store.book(id: id)?.durationSeconds) - 3 * Self.trueSeconds) < 0.01)
        #expect(try f.store.files(bookId: id).map { $0.lengthProblem?.repairable } == [true, true, true])
    }

    // MARK: Saving

    @Test func savingABookKeepsWhatIsKnownAboutItsHeaders() throws {
        let f = try LibraryFixture()
        let id = try f.importWrongHeaderBook(parts: 2)
        let before = try f.store.files(bookId: id).map(\.lengthProblem)

        var edit = BookEdit(book: try #require(try f.store.book(id: id)))
        edit.metadata.title = "Renamed Book"
        edit.metadata.narrators = ["A Narrator"]
        let outcomes = try f.service.save([edit])
        guard case .saved(_, _, _, let problems) = try #require(outcomes.first) else {
            Issue.record("expected .saved, got \(outcomes)")
            return
        }
        #expect(problems.isEmpty)

        let files = try f.store.files(bookId: id)
        #expect(files.map(\.lengthProblem) == before)
        #expect(files.allSatisfy { $0.writeProblem == nil })
        #expect(abs(try #require(try f.store.book(id: id)?.durationSeconds) - 2 * Self.trueSeconds) < 0.01)
        for url in try f.fileURLs(id) {
            #expect(try f.tags(url).narrators == ["A Narrator"])
        }
        // Undo puts the rows back as they were, problems included.
        try f.service.undoLast()
        #expect(try f.store.files(bookId: id).map(\.lengthProblem) == before)
    }

    // MARK: The launch check

    /// A book as an earlier version recorded it: the stated lengths added up, nothing known
    /// about the headers.
    func importAsRecordedBefore(_ f: LibraryFixture, parts: Int = 3) throws -> Int64 {
        let id = try f.importWrongHeaderBook(parts: parts)
        let ids = try f.store.files(bookId: id).compactMap(\.id)
        try f.store.setMeasuredLength(
            bookId: id, durationSeconds: Double(parts) * Self.statedSeconds,
            lengthProblems: Dictionary(uniqueKeysWithValues: ids.map { ($0, nil) }))
        #expect(try f.store.files(bookId: id).allSatisfy { $0.lengthProblem == nil })
        return id
    }

    @Test func theLaunchCheckCorrectsABookRecordedWithTheWrongLength() throws {
        let f = try LibraryFixture()
        let id = try importAsRecordedBefore(f)
        let bytesBefore = try f.fileURLs(id).map { try f.bytes($0) }
        let fileIdsBefore = try f.store.files(bookId: id).map(\.id)
        let batchBefore = try #require(try f.store.lastBatch())

        let report = try f.service.reconcile()

        #expect(report == ReconcileReport(correctedLengths: 1))
        let book = try #require(try f.store.book(id: id))
        #expect(abs(try #require(book.durationSeconds) - 3 * Self.trueSeconds) < 0.01)
        #expect(!book.needsAttention)
        let files = try f.store.files(bookId: id)
        #expect(files.map(\.id) == fileIdsBefore)
        #expect(files.map { $0.lengthProblem?.repairable } == [true, true, true])
        // Nothing is written to a file, and nothing is recorded for undo.
        #expect(try f.fileURLs(id).map { try f.bytes($0) } == bytesBefore)
        let batchAfter = try #require(try f.store.lastBatch())
        #expect(batchAfter.id == batchBefore.id)
        #expect(batchAfter.label == batchBefore.label)
        #expect(batchAfter.snapshot == batchBefore.snapshot)

        // The next launch has nothing to do, and opens nothing.
        var opened: [URL] = []
        f.service.willMeasure = { opened.append($0) }
        #expect(try f.service.reconcile() == ReconcileReport())
        #expect(opened.isEmpty)
    }

    @Test func theLaunchCheckOpensNoFileOfABookWhoseLengthIsPlausible() throws {
        let f = try LibraryFixture()
        let tags = LibraryFixture.meta("Fine Book", "An Author")
        let fine = try f.importNew(
            try f.makeBuiltMP3s(folder: "Fine", tags: tags, parts: [.init(), .init(header: .none)]), tags)
        let m4b = try f.importNew(
            [try f.makeM4B("Other.m4b", tags: LibraryFixture.meta("Other", "An Author"))],
            LibraryFixture.meta("Other", "An Author"))
        let wrong = try importAsRecordedBefore(f, parts: 2)
        let before = try [fine, m4b].map { try f.store.book(id: $0) }

        var opened: [URL] = []
        f.service.willMeasure = { opened.append($0) }
        #expect(try f.service.reconcile().correctedLengths == 1)

        #expect(Set(opened) == Set(try f.fileURLs(wrong)))
        #expect(try [fine, m4b].map { try f.store.book(id: $0) } == before)
    }

    @Test func aBookPickedBySizeThatHasNothingWrongIsLeftAsItIs() throws {
        let f = try LibraryFixture()
        // Two seconds of audio behind a picture of about a megabyte: far more bytes than
        // two seconds of MP3 can be, yet the length is right.
        var noise = SystemRandomNumberGenerator()
        var picture = Data([0xFF, 0xD8, 0xFF, 0xE0])
        picture.append(Data((0..<1_000_000).map { _ in UInt8.random(in: 0...255, using: &noise) }))
        let tag = MediaFixtures.id3v23Tag(frames: [
            ("APIC", MediaFixtures.id3Picture(picture, mime: "image/jpeg", type: 3)),
        ])
        let tags = LibraryFixture.meta("Short Book", "An Author")
        let id = try f.importNew(
            try f.makeBuiltMP3s(folder: "Short", tags: tags, parts: [.init(seconds: 2, prefix: tag)]), tags)
        let before = try #require(try f.store.book(id: id))
        #expect(abs(try #require(before.durationSeconds) - 2) < 0.1)

        var opened = 0
        f.service.willMeasure = { _ in opened += 1 }
        #expect(try f.service.reconcile() == ReconcileReport())
        #expect(opened == 1)
        #expect(try f.store.book(id: id) == before)
        #expect(try f.store.files(bookId: id).first?.lengthProblem == nil)
    }

    @Test func aLengthNoHeaderExplainsIsLeftAsRecorded() throws {
        let f = try LibraryFixture()
        let tags = LibraryFixture.meta("Sample Book", "An Author")
        let id = try f.importNew(try f.makeMP3Parts(folder: "Sample", tags: tags), tags)
        // Eleven hours recorded for two seconds of audio whose headers are right.
        let ids = try f.store.files(bookId: id).compactMap(\.id)
        try f.store.setMeasuredLength(bookId: id, durationSeconds: 11 * 3600, lengthProblems: [:])
        #expect(ids.count == 2)

        #expect(try f.service.reconcile() == ReconcileReport())
        #expect(try f.store.book(id: id)?.durationSeconds == 11 * 3600)
    }

    @Test func aBookWithAPartThatCannotBeReadKeepsItsRecordedLength() throws {
        let f = try LibraryFixture()
        let id = try importAsRecordedBefore(f)
        let recorded = try #require(try f.store.book(id: id)?.durationSeconds)
        // Still there, and the same size, but no longer audio.
        let second = try f.fileURLs(id)[1]
        let size = try f.bytes(second).count
        try Data(repeating: 0x20, count: size).write(to: second)

        #expect(try f.service.reconcile() == ReconcileReport())
        #expect(try f.store.book(id: id)?.durationSeconds == recorded)
        #expect(try f.store.files(bookId: id).allSatisfy { $0.lengthProblem == nil })
    }

    @Test func aBookWithAMissingPartIsReportedMissingAndNotMeasured() throws {
        let f = try LibraryFixture()
        let id = try importAsRecordedBefore(f)
        try FileManager.default.removeItem(at: try f.fileURLs(id)[0])
        var opened = 0
        f.service.willMeasure = { _ in opened += 1 }
        let report = try f.service.reconcile()
        #expect(report.booksWithMissingFiles == [id])
        #expect(report.correctedLengths == 0)
        #expect(opened == 0)
    }

    @Test func aBookFlaggedForAnotherReasonStaysFlaggedWhenItsLengthIsCorrected() throws {
        let f = try LibraryFixture()
        let id = try importAsRecordedBefore(f)
        try f.store.setNeedsAttention(flagging: [id], clearing: [])
        var book = try #require(try f.store.book(id: id))
        book.folderPath = nil  // never filed: the flag is not for a missing file
        try f.store.update(book)
        let report = try f.service.reconcile()
        #expect(report.correctedLengths == 1)
        #expect(report.booksRecovered.isEmpty)
        #expect(try f.store.book(id: id)?.needsAttention == true)
    }

    // MARK: The database

    @Test func aV4DatabaseUpgrades() throws {
        let root = try makeTempDir()
        let path = root.appendingPathComponent(LibraryStore.databaseFileName).path
        do {
            let queue = try DatabaseQueue(path: path)
            try LibraryStore.migrator.migrate(queue, upTo: "v4")
            try queue.write { db in
                #expect(try db.columns(in: "bookFile").contains { $0.name == "lengthProblem" } == false)
                try db.execute(sql: """
                    INSERT INTO book (title, authors, narrators, tags, rating, needsAttention, folderPath,
                                      durationSeconds, dateAdded, readStatus, appOnlyFields, externalCopies)
                    VALUES ('Old Book', '["Old Author"]', '[]', '["kept"]', 4, 0, 'Old Author/Old Book', 7200.5,
                            '2025-01-02 03:04:05.000', 'finished', '[]',
                            '[{"kind":"audible","form":"audio","itemId":"B000000001"}]')
                    """)
                let bookId = db.lastInsertedRowID
                try db.execute(sql: """
                    INSERT INTO bookFile (bookId, path, format, role, position, writeProblem, originalName)
                    VALUES (?, 'Old Author/Old Book/Part 1.mp3', 'mp3', 'audio', 0, 'locked', NULL),
                           (?, 'Old Author/Old Book/Map.pdf', 'pdf', 'extra', 1, NULL, 'Map.pdf')
                    """, arguments: [bookId, bookId])
            }
            try queue.close()
        }

        let store = try LibraryStore(libraryRoot: root)

        let columns = try store.dbQueue.read { db in try db.columns(in: "bookFile") }
        let column = try #require(columns.first { $0.name == "lengthProblem" })
        #expect(!column.isNotNull)
        #expect(column.type.uppercased() == "TEXT")
        let book = try #require(try store.books().first)
        let id = try #require(book.id)
        #expect(book.title == "Old Book")
        #expect(book.durationSeconds == 7200.5)
        #expect(book.externalCopies == [ExternalCopy(kind: .audible, form: .audio, itemId: "B000000001")])
        var files = try store.files(bookId: id)
        #expect(files.map(\.path) == ["Old Author/Old Book/Part 1.mp3", "Old Author/Old Book/Map.pdf"])
        #expect(files.map(\.writeProblem) == ["locked", nil])
        #expect(files.map(\.originalName) == [nil, "Map.pdf"])
        #expect(files.allSatisfy { $0.lengthProblem == nil })

        // The new column holds what it is given, and gives it back.
        let problem = LengthProblem(statedSeconds: 42, trueSeconds: 4368.5, repairable: true)
        try store.setMeasuredLength(
            bookId: id, durationSeconds: 4368.5, lengthProblems: [try #require(files[0].id): problem])
        files = try store.files(bookId: id)
        #expect(files.map(\.lengthProblem) == [problem, nil])
        #expect(files.map(\.writeProblem) == ["locked", nil])
        #expect(try store.book(id: id)?.durationSeconds == 4368.5)
        try store.replaceFiles(bookId: id, files: files)
        #expect(try store.files(bookId: id).map(\.lengthProblem) == [problem, nil])
    }

    @Test func aFileRowSavedBeforeTheFieldExistedStillDecodes() throws {
        let old = #"{"id":7,"bookId":3,"path":"A/B/c.mp3","format":"mp3","role":"audio","position":0}"#
        let row = try JSONDecoder().decode(BookFile.self, from: Data(old.utf8))
        #expect(row.lengthProblem == nil)
        #expect(row.path == "A/B/c.mp3")
        // A value of a shape this code does not know counts as none.
        let odd = #"{"path":"A/B/c.mp3","format":"mp3","role":"audio","lengthProblem":"something new"}"#
        #expect(try JSONDecoder().decode(BookFile.self, from: Data(odd.utf8)).lengthProblem == nil)
        // And a row round-trips with its problem.
        var with = row
        with.lengthProblem = LengthProblem(statedSeconds: 42, trueSeconds: 4368.5, repairable: false)
        #expect(try JSONDecoder().decode(BookFile.self, from: try JSONEncoder().encode(with)) == with)
    }

    @Test func setMeasuredLengthLeavesOtherBooksFilesAlone() throws {
        let f = try LibraryFixture()
        let one = try f.importWrongHeaderBook("One", parts: 1)
        let two = try f.importWrongHeaderBook("Two", parts: 1)
        let otherFile = try #require(try f.store.files(bookId: two).first?.id)
        let before = try f.store.files(bookId: two)
        try f.store.setMeasuredLength(bookId: one, durationSeconds: 1, lengthProblems: [otherFile: nil])
        #expect(try f.store.files(bookId: two) == before)
    }
}
