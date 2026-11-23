import Foundation
import Testing
import VoxCarrelFixtures

@testable import VoxCarrelAppCore
@testable import VoxCarrelCore

/// What the app does about a merge of books that was interrupted: as for a change of
/// folder layout that was (FL11–FL13).
@MainActor
@Suite struct AppModelMergeRecoveryTests {
    typealias L = MergeLibrary

    struct Stopped: Error {}

    static let before = [
        "\(L.audioFolder)/\(L.title) (Unabridged).m4b",
        "James Dalton/\(L.companion)/\(L.companion).pdf",
        "\(L.folder)/\(L.title).pdf",
    ].sorted()

    /// The owner's three entries, in a library not yet opened by the model, whose merge
    /// stopped dead once every file had moved.
    private func interrupted() throws -> (h: Harness, books: (audio: Int64, pdf: Int64, companion: Int64)) {
        let library = try MergeLibrary()
        let books = try library.ownersCase()
        let service = LibraryService(store: try LibraryStore(libraryRoot: library.root))
        service.mergeCheckpoint = { if $0 == .moved { throw Stopped() } }
        #expect(throws: Stopped.self) {
            try service.mergeBooks([books.audio, books.pdf, books.companion], keep: books.audio, roles: [:])
        }
        #expect(service.hasInterruptedMerge)
        let h = try Harness(root: library.root)
        #expect(h.libraryFiles() != Self.before)
        return (h, books)
    }

    /// The same, with something then put where one of the files has to go back to.
    private func unrecoverable() throws -> (h: Harness, books: (audio: Int64, pdf: Int64, companion: Int64), inTheWay: URL) {
        let (h, books) = try interrupted()
        let inTheWay = try touch(
            h.root.appendingPathComponent("James Dalton/\(L.companion)/\(L.companion).pdf"), "in the way")
        return (h, books, inTheWay)
    }

    @Test func aMergeThatWasInterruptedIsPutBackAndToldInTheLaunchCheck() async throws {
        let (h, books) = try interrupted()

        await h.model.start()

        #expect(h.libraryFiles() == Self.before)
        #expect(try h.store().books().count == 3)
        #expect(h.model.libraryCheck?.recoveredMerge == true)
        let summary = try #require(h.model.libraryCheckSummary)
        #expect(summary.recoveredLayout == "A merge of books was interrupted. The files have been put back as they were.")
        #expect(summary.layoutProblem == nil)
        #expect(summary.missing == nil)
        #expect(summary.untracked == nil)
        #expect(h.model.windowSheet(progressDue: false) == .check(summary))
        // Nothing is switched off, and the merge can be made.
        #expect(!h.model.layoutChangeIsUnresolved)
        #expect(!h.model.mergeRecoveryIsUnresolved)
        #expect(h.model.canImport)
        h.model.dismissLibraryCheck()
        await h.select(ids: [books.audio, books.pdf, books.companion])
        #expect(h.model.canMergeBooks)
        await h.model.beginMergeBooks()
        await h.model.confirmMerge()
        #expect(h.model.alert == nil)
        #expect(try h.store().books().compactMap(\.id) == [books.audio])
    }

    @Test func aMergeThatCannotBePutBackIsSaidWithTryAgainAndStopTryingAndSwitchesChangesOff() async throws {
        let (h, books, inTheWay) = try unrecoverable()
        let stopped = h.libraryFiles()

        await h.model.start()

        #expect(h.libraryFiles() == stopped)
        #expect(h.model.layoutChangeIsUnresolved)
        #expect(h.model.mergeRecoveryIsUnresolved)
        let summary = try #require(h.model.libraryCheckSummary)
        let problem = try #require(summary.layoutProblem)
        #expect(problem.section.heading == "A merge of books was interrupted")
        #expect(problem.section.detail.hasPrefix("A merge of books was interrupted, and its files could not be put back: "))
        #expect(problem.section.detail.hasSuffix(
            " Nothing was deleted. Importing, saving and other changes are off until this is resolved."))
        #expect(!problem.section.lines.isEmpty)
        #expect(problem.retryTitle == "Try Again")
        #expect(problem.stopTitle == "Stop Trying…")
        #expect(summary.recoveredLayout == nil)
        // The ordinary check waits: no book is said to be missing its files.
        #expect(summary.missing == nil)
        #expect(h.model.rows.allSatisfy { !$0.book.needsAttention || $0.id == books.audio })

        // Everything the library would refuse is off.
        #expect(!h.model.canImport)
        #expect(!h.model.canChangeFiles)
        h.model.dismissLibraryCheck()
        await h.select(ids: [books.audio, books.pdf])
        #expect(!h.model.canMergeBooks)

        // Try Again, with the way still barred: the same again.
        await h.model.retryLibraryCheck()
        #expect(h.model.layoutChangeIsUnresolved)
        #expect(h.model.libraryCheckSummary?.layoutProblem != nil)
        #expect(try String(contentsOf: inTheWay, encoding: .utf8) == "in the way")

        // And with the way clear: everything is put back, and said.
        try FileManager.default.removeItem(at: inTheWay)
        h.recordBusyLabels()
        await h.model.retryLibraryCheck()
        #expect(h.busyLabels == ["Checking the library…"])
        #expect(!h.model.layoutChangeIsUnresolved)
        #expect(!h.model.mergeRecoveryIsUnresolved)
        #expect(h.libraryFiles() == Self.before)
        #expect(h.model.libraryCheckSummary?.recoveredLayout
            == "A merge of books was interrupted. The files have been put back as they were.")
        #expect(h.model.libraryCheckSummary?.layoutProblem == nil)
        #expect(h.model.canImport)
    }

    @Test func stoppingAsksFirstThenUnlocksTheLibraryAndTheOrdinaryCheckFollows() async throws {
        let (h, _, inTheWay) = try unrecoverable()
        await h.model.start()
        let stopped = h.libraryFiles()

        h.model.requestStopLayoutRecovery()
        let prompt = try #require(h.model.prompt)
        #expect(prompt == .stopMergeRecovery)
        #expect(prompt.title == "Stop trying to put the files back?")
        #expect(prompt.message
            == "VoxCarrel will stop trying to put the files of the interrupted merge back. Books whose files "
            + "moved will show as missing until you move the files back or locate them yourself. Nothing "
            + "is deleted.")
        #expect(prompt.stopLayoutRecoveryTitle == "Stop Trying")

        // Cancel: nothing has changed.
        h.model.prompt = nil
        #expect(h.model.layoutChangeIsUnresolved)
        h.recordBusyLabels()
        await h.model.confirmStopLayoutRecovery()
        #expect(h.busyLabels.isEmpty)
        #expect(h.model.layoutChangeIsUnresolved)

        h.model.requestStopLayoutRecovery()
        await h.model.confirmStopLayoutRecovery()

        #expect(h.busyLabels == ["Checking the library…"])
        #expect(h.model.prompt == nil)
        #expect(h.model.alert == nil)
        #expect(!h.model.layoutChangeIsUnresolved)
        #expect(!h.model.mergeRecoveryIsUnresolved)
        // No file was touched, and the ordinary check says what is where.
        #expect(h.libraryFiles() == stopped)
        #expect(try String(contentsOf: inTheWay, encoding: .utf8) == "in the way")
        let summary = try #require(h.model.libraryCheckSummary)
        #expect(summary.layoutProblem == nil)
        #expect(summary.missing != nil)
        #expect(summary.untracked != nil)
        #expect(h.model.canImport)
        #expect(!LibraryService(store: try h.store()).hasInterruptedMerge)
    }

    @Test func theLibraryRefusingBecauseOfAnInterruptedMergeIsSaidInPlainWords() {
        #expect(UserMessage.text(for: LibraryError.mergeInterrupted)
            == "A merge of books was interrupted and has not been put right yet, so nothing else can be changed "
            + "for now. Close the library and open it again: VoxCarrel will try once more to put every file back.")
    }
}
