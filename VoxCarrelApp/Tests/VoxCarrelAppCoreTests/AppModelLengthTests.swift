import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// MP3s whose length header is wrong: what the model shows of them, and repairing them.
@MainActor
@Suite struct AppModelLengthTests {
    typealias Options = MediaFixtures.MP3Options

    static let wrong = Options.wrongHeader(seconds: 30)
    static let vbri = Options(seconds: 30, header: .vbri, statedFrames: 100, statedBytes: 41_700)
    /// 30 s of audio is 1149 frames of 1152 samples at 44.1 kHz.
    static let trueSeconds = 1149.0 * 1152 / 44_100
    static let statedSeconds = 100.0 * 1152 / 44_100

    /// A library holding one book, "Long Book", whose MP3 parts are built to order, and a
    /// model on it that has not started yet.
    /// - Parameter asRecordedBefore: The book is recorded as an earlier version did: with
    ///   the stated lengths added up, and nothing known about its headers.
    func library(
        _ parts: [Options] = [wrong, wrong], asRecordedBefore: Bool = false
    ) throws -> (h: Harness, id: Int64) {
        let root = try makeTempDir()
        let inbox = try makeTempDir()
        let tags = BookMetadata(title: "Long Book", authors: ["An Author"])
        let urls = try parts.enumerated().map { index, options in
            let url = inbox.appendingPathComponent("part\(index + 1).mp3")
            try MediaFixtures.makeMP3(options).data.write(to: url)
            try FileMetadataIO().write(tags, to: url)
            return url
        }
        let store = try LibraryStore(libraryRoot: root)
        let candidate = CandidateBook(files: urls.map { CandidateFile(url: $0, role: .audio) }, metadata: tags)
        let result = try LibraryService(store: store).importItems(
            [ImportItem(candidate: candidate)], options: ImportOptions())
        guard case .imported(let id, _) = try #require(result.outcomes.first) else {
            throw CocoaError(.fileReadUnknown)
        }
        if asRecordedBefore {
            let files = try store.files(bookId: id).compactMap(\.id)
            try store.setMeasuredLength(
                bookId: id, durationSeconds: Double(parts.count) * Self.statedSeconds,
                lengthProblems: Dictionary(uniqueKeysWithValues: files.map { ($0, nil) }))
        }
        return (try Harness(root: root), id)
    }

    // MARK: Wording

    @Test func aLengthUnderAMinuteIsGivenInSeconds() {
        #expect(LengthText.exact(seconds: 42) == "42s")
        #expect(LengthText.exact(seconds: 2.6) == "3s")
        #expect(LengthText.exact(seconds: 0) == "0s")
        #expect(LengthText.exact(seconds: 59.4) == "59s")
        #expect(LengthText.exact(seconds: 59.6) == "1m")
        #expect(LengthText.exact(seconds: 72 * 60 + 20) == "1h 12m")
        #expect(LengthText.exact(seconds: .nan) == "0s")
    }

    @Test func theProblemIsSaidInWords() {
        let repairable = LengthProblem(statedSeconds: 42, trueSeconds: 72 * 60 + 20, repairable: true)
        #expect(
            LengthText.problem(repairable)
                == "Length header is wrong: the file says 42s but holds 1h 12m. Some players will stop early.")
        var other = repairable
        other.repairable = false
        #expect(
            LengthText.problem(other)
                == "Length header is wrong: the file says 42s but holds 1h 12m. Some players will stop early. "
                + "This kind of header cannot be repaired here.")
    }

    @Test func aHeaderThatStatesTooMuchIsNotSaidToStopPlayersEarly() {
        let long = LengthProblem(statedSeconds: 3 * 3600, trueSeconds: 45 * 60, repairable: true)
        #expect(
            LengthText.problem(long)
                == "Length header is wrong: the file says 3h 0m but holds 45m. Some players will show the wrong length.")
    }

    // MARK: What is shown

    // More bytes that are not audio lie among the frames than a measurement tolerates.
    @Test func aFileThatCouldNotBeMeasuredSaysSoAndOffersNoRepair() async throws {
        let junk = Data(repeating: 0x55, count: 64 * 1024 + 1)
        let odd = Options(seconds: 30, statedFrames: 100, statedBytes: 41_700, junk: (afterFrame: 1000, bytes: junk))
        let (h, id) = try library([odd, Options(seconds: 30)])
        await h.model.start()

        let row = try #require(h.model.rows.first { $0.id == id })
        #expect(row.lengthProblemFiles == 0)
        #expect(row.repairableLengthFiles == 0)
        #expect(h.model.libraryCheckSummary == nil)
        try await h.select("Long Book")
        let detail = try #require(h.detail)
        #expect(!detail.showsRepairLength)
        #expect(!h.model.selectionCommands.repairLengthHeaders)
        #expect(detail.files.map(\.lengthProblemText) == [nil, nil])
        #expect(detail.files.map(\.lengthUnmeasuredText) == [
            "VoxCarrel could not measure this file's length; the length shown comes from the file's own header.",
            nil,
        ])
    }

    @Test func aBookWithWrongHeadersShowsTheWarningWithoutNeedingAttention() async throws {
        let (h, id) = try library()
        await h.model.start()

        let row = try #require(h.model.rows.first { $0.id == id })
        #expect(row.lengthProblemFiles == 2)
        #expect(row.repairableLengthFiles == 2)
        #expect(row.warningText == "2 files state the wrong length: some players will stop early")
        #expect(!row.book.needsAttention)
        #expect(h.model.sidebar.counts[.needsAttention] == 0)
        // The true length, not the one the files state.
        #expect(abs(try #require(row.book.durationSeconds) - 2 * Self.trueSeconds) < 0.01)
        #expect(row.lengthText == "1m")
        // Nothing was wrong with what was recorded, so the launch check has nothing to tell.
        #expect(h.model.libraryCheckSummary == nil)

        try await h.select("Long Book")
        let detail = try #require(h.detail)
        #expect(detail.showsRepairLength)
        #expect(detail.attentionReasons.isEmpty)
        #expect(detail.files.map(\.lengthProblemText) == Array(
            repeating: "Length header is wrong: the file says 3s but holds 30s. Some players will stop early.",
            count: 2))
    }

    @Test func oneFileIsSaidInTheSingularAndAHealthyBookShowsNothing() async throws {
        let (h, id) = try library([Self.wrong, Options(seconds: 30)])
        await h.model.start()
        let row = try #require(h.model.rows.first { $0.id == id })
        #expect(row.lengthProblemFiles == 1)
        #expect(row.warningText == "A file states the wrong length: some players will stop early")
        try await h.select("Long Book")
        #expect(h.detail?.files.map { $0.lengthProblemText == nil } == [false, true])

        let demo = try await Harness.demo()
        #expect(demo.model.rows.allSatisfy { $0.lengthProblemFiles == 0 && $0.repairableLengthFiles == 0 })
        try await demo.select("Salt Road")
        #expect(demo.detail?.showsRepairLength == false)
        #expect(demo.detail?.files.allSatisfy { $0.lengthProblemText == nil } == true)
        #expect(!demo.model.selectionCommands.repairLengthHeaders)
    }

    @Test func aHeaderThatCannotBeRepairedIsShownButRepairIsNotOffered() async throws {
        let (h, id) = try library([Self.vbri])
        await h.model.start()
        let row = try #require(h.model.rows.first { $0.id == id })
        #expect(row.lengthProblemFiles == 1)
        #expect(row.repairableLengthFiles == 0)
        #expect(row.warningText != nil)

        try await h.select("Long Book")
        #expect(h.detail?.showsRepairLength == false)
        #expect(h.detail?.files.first?.lengthProblemText?.hasSuffix("This kind of header cannot be repaired here.") == true)
        #expect(!h.model.selectionCommands.repairLengthHeaders)
        #expect(!h.model.commands(for: [id]).repairLengthHeaders)

        // Asking all the same does nothing.
        h.recordBusyLabels()
        await h.model.repairLengthHeaders()
        #expect(h.busyLabels.isEmpty)
    }

    // MARK: The command

    @Test func theCommandAppliesOnlyToBooksWithAFileThatCanBeRepaired() async throws {
        let (h, id) = try library()
        await h.model.start()
        #expect(!h.model.selectionCommands.repairLengthHeaders)
        // For a context menu, whatever is selected.
        #expect(h.model.commands(for: [id]).repairLengthHeaders)
        #expect(!h.model.commands(for: [id + 100]).repairLengthHeaders)

        try await h.select("Long Book")
        #expect(h.model.selectionCommands.repairLengthHeaders)
    }

    // MARK: Repairing

    @Test func repairingRewritesTheHeadersAndReloads() async throws {
        let (h, id) = try library()
        await h.model.start()
        try await h.select("Long Book")
        let before = try h.fileURLs(id).map { try Data(contentsOf: $0) }
        h.recordBusyLabels()

        await h.model.repairLengthHeaders()

        #expect(h.busyLabels == ["Repairing 2 files…"])
        #expect(h.model.alert == nil)
        #expect(h.model.result == nil)
        #expect(h.model.undoLabel == "Repair length headers in 2 files")
        let row = try #require(h.model.rows.first { $0.id == id })
        #expect(row.lengthProblemFiles == 0)
        #expect(row.repairableLengthFiles == 0)
        #expect(row.warningText == nil)
        #expect(abs(try #require(row.book.durationSeconds) - 2 * Self.trueSeconds) < 0.01)
        #expect(h.detail?.showsRepairLength == false)
        #expect(h.detail?.files.allSatisfy { $0.lengthProblemText == nil } == true)
        #expect(!h.model.selectionCommands.repairLengthHeaders)
        for url in try h.fileURLs(id) {
            #expect(try FileMetadataIO().read(url).lengthProblem == nil)
        }

        // Undo puts the files back, and the warning with them.
        await h.model.undo()
        #expect(try h.fileURLs(id).map { try Data(contentsOf: $0) } == before)
        #expect(h.model.rows.first { $0.id == id }?.repairableLengthFiles == 2)
        #expect(h.detail?.showsRepairLength == true)
    }

    @Test func oneFileIsRepairedInTheSingularFromAContextMenu() async throws {
        let (h, id) = try library([Self.wrong])
        await h.model.start()
        h.recordBusyLabels()
        // Not selected: the menu was opened on the book.
        await h.model.repairLengthHeaders(for: [id])
        #expect(h.busyLabels == ["Repairing 1 file…"])
        #expect(h.model.undoLabel == "Repair length header in 1 file")
        #expect(h.model.rows.first { $0.id == id }?.lengthProblemFiles == 0)
    }

    @Test func aFileThatCouldNotBeRepairedIsNamedInTheResult() async throws {
        let (h, id) = try library([Self.wrong, Self.vbri])
        await h.model.start()
        try await h.select("Long Book")
        h.recordBusyLabels()

        await h.model.repairLengthHeaders()

        // Only the one that can be repaired is counted.
        #expect(h.busyLabels == ["Repairing 1 file…"])
        let result = try #require(h.model.result)
        #expect(!result.isClean)
        #expect(result.headline == "1 file could not be repaired")
        #expect(result.problems.map(\.title) == ["Long Book"])
        let second = try #require(try h.fileURLs(id).last?.lastPathComponent)
        #expect(
            result.problems.first?.detail
                == "\(second): The length header cannot be repaired: it is not of a kind that can be rewritten. "
                + "The file was left as it is.")
        let row = try #require(h.model.rows.first { $0.id == id })
        #expect(row.lengthProblemFiles == 1)
        #expect(row.repairableLengthFiles == 0)
    }

    @Test func repairingNeedsABookThatCanBeRepaired() async throws {
        let h = try await Harness.demo()
        h.recordBusyLabels()
        await h.model.repairLengthHeaders()
        try await h.select("Salt Road")
        await h.model.repairLengthHeaders()
        #expect(h.busyLabels.isEmpty)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
        #expect(h.model.result == nil)
    }

    @Test func theRepairSummaryCountsFilesAndBooks() {
        let outcomes: [SaveOutcome] = [
            .saved(bookId: 1, refiled: false, appOnlyFields: [], fileProblems: []),
            .saved(bookId: 2, refiled: false, appOnlyFields: [], fileProblems: [
                FileProblem(file: "a.mp3", reason: "the first reason"), FileProblem(file: "b.mp3", reason: "The second."),
            ]),
            .failed(bookId: 3, reason: "That book is not in the library"),
        ]
        let summary = UserMessage.repairSummary(of: outcomes, titles: [1: "One", 2: "Two"])
        #expect(summary.headline == "2 files could not be repaired, 1 book could not be repaired")
        #expect(!summary.isClean)
        #expect(summary.problems == [
            .init(title: "Two", detail: "a.mp3: The first reason."),
            .init(title: "Two", detail: "b.mp3: The second."),
            .init(title: "Untitled book", detail: "That book is not in the library."),
        ])
        let clean = UserMessage.repairSummary(of: [outcomes[0]], titles: [:])
        #expect(clean.isClean)
        #expect(clean.headline == "Length headers repaired")
    }

    // MARK: The launch check

    @Test func theLaunchCheckSaysHowManyBooksHadTheirLengthCorrected() async throws {
        let (h, id) = try library(asRecordedBefore: true)
        #expect(abs(try #require(try h.book(id).durationSeconds) - 2 * Self.statedSeconds) < 0.01)

        await h.model.start()

        let summary = try #require(h.model.libraryCheckSummary)
        #expect(summary.correctedLengths == "The length of 1 book was corrected: its files stated the wrong length.")
        #expect(
            summary.wrongLengthFiles
                == "2 files were found to state the wrong length. Their books are marked with a warning, "
                + "and the inspector says what is wrong and whether it can be repaired.")
        #expect(summary.intro == "VoxCarrel looked over the library folder as it opened. No file has been changed.")
        #expect(summary.missing == nil)
        #expect(summary.untracked == nil)
        #expect(summary.stranded == nil)
        // The books shown are as corrected.
        let row = try #require(h.model.rows.first { $0.id == id })
        #expect(abs(try #require(row.book.durationSeconds) - 2 * Self.trueSeconds) < 0.01)
        #expect(row.repairableLengthFiles == 2)
        #expect(!row.book.needsAttention)
        #expect(h.model.undoLabel == "Import 1 book")

        h.model.dismissLibraryCheck()
        #expect(h.model.libraryCheckSummary == nil)
        // The next launch has nothing to tell.
        let again = h.relaunched()
        await again.start()
        #expect(again.libraryCheckSummary == nil)
    }

    @Test func theCorrectedLineIsWordedByItsCount() async throws {
        let h = try await Harness.demo()
        h.model.libraryCheck = ReconcileReport(correctedLengths: 2)
        #expect(
            h.model.libraryCheckSummary?.correctedLengths
                == "The length of 2 books was corrected: their files stated the wrong length.")
        h.model.libraryCheck = ReconcileReport(filesWithWrongLength: 1)
        let found = try #require(h.model.libraryCheckSummary)
        #expect(
            found.wrongLengthFiles
                == "1 file was found to state the wrong length. Its book is marked with a warning, "
                + "and the inspector says what is wrong and whether it can be repaired.")
        #expect(found.correctedLengths == nil)
        #expect(found.intro == "VoxCarrel looked over the library folder as it opened. No file has been changed.")
        // With nothing corrected the line is not there, and the files are said to be untouched.
        h.model.libraryCheck = ReconcileReport(untrackedFiles: [h.root.appendingPathComponent("Stray.epub")])
        let summary = try #require(h.model.libraryCheckSummary)
        #expect(summary.correctedLengths == nil)
        #expect(summary.intro == "VoxCarrel looked over the library folder as it opened. Nothing has been changed.")
    }
}
