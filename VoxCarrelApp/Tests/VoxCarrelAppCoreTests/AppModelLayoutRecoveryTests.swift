import Foundation
import Testing
import VoxCarrelFixtures

@testable import VoxCarrelAppCore
@testable import VoxCarrelCore

/// What the app does about a change of folder layout that was interrupted (folder
/// layout plan, Task 4). FL11–FL13.
@MainActor
@Suite struct AppModelLayoutRecoveryTests {
    static let recovered = "A change of folder layout was interrupted. The folders have been put back as they were."
    static let changesOff = "Importing, saving and other changes are off until this is resolved."

    /// A demo library, not yet opened by the model, in which a change to "Author /
    /// Title" was cut short after two of its three folders had moved.
    private func interrupted() async throws -> Harness {
        let h = try await Harness.demo(start: false)
        let service = LibraryService(store: try h.store())
        var done = 0
        service.renameFolder = { from, to in
            if done == 2 { throw FolderMover.Halted() }
            done += 1
            try FolderMover.renameWithoutReplacing(from, to)
        }
        #expect(throws: FolderMover.Halted.self) {
            try service.applyLayoutChange(to: try FolderPattern("{Author}/{Title}"))
        }
        #expect(service.hasInterruptedLayoutChange)
        return h
    }

    /// The same, with one of the two moved folders then taken out of the library by
    /// hand, so that the folders cannot be put back. Returns where it was taken from
    /// and where it is now.
    private func unrecoverable() async throws -> (h: Harness, from: URL, away: URL) {
        let h = try await interrupted()
        let moved = h.root.appendingPathComponent("Ines Calloway/Harbour of Glass")
        #expect(FileManager.default.fileExists(atPath: moved.path))
        let away = try makeTempDir().appendingPathComponent("Harbour of Glass")
        try FileManager.default.moveItem(at: moved, to: away)
        return (h, moved, away)
    }

    // MARK: FL11 Folders that were put back

    @Test func fl11_aRecoveredLayoutChangeIsToldInTheLaunchCheck() async throws {
        let h = try await interrupted()
        await h.model.start()

        // The folders are back, and the library is as it was.
        #expect(try h.book(try h.id("Harbour of Glass")).folderPath == "Ines Calloway/Tidewater Chronicles/3 - Harbour of Glass")
        #expect(FileManager.default.fileExists(
            atPath: h.root.appendingPathComponent("Ines Calloway/Tidewater Chronicles/3 - Harbour of Glass").path))
        #expect(!FileManager.default.fileExists(atPath: h.root.appendingPathComponent("Ines Calloway/Harbour of Glass").path))

        #expect(h.model.libraryCheck?.recoveredLayoutChange == true)
        let summary = try #require(h.model.libraryCheckSummary)
        #expect(summary.recoveredLayout == Self.recovered)
        #expect(summary.layoutProblem == nil)
        #expect(summary.missing == nil)
        #expect(summary.untracked == nil)
        #expect(summary.stranded == nil)
        // Folders were moved back, so "nothing has been changed" is not what is said.
        #expect(summary.intro == LibraryCheckSummary.noFileChanged)
        #expect(h.model.windowSheet(progressDue: false) == .check(summary))

        // Nothing is switched off.
        #expect(!h.model.layoutChangeIsUnresolved)
        #expect(h.model.canImport)
        #expect(h.model.canUndo)
        #expect(h.model.canChangeFiles)
        h.model.dismissLibraryCheck()
        h.model.chooseLayout("Author / Title")
        #expect(h.model.canChangeLayout)
    }

    @Test func fl11_theSentenceIsOnlySaidWhenFoldersWerePutBack() async throws {
        let h = try await Harness.demo()
        var report = ReconcileReport()
        h.model.libraryCheck = report
        #expect(h.model.libraryCheckSummary == nil)
        report.recoveredLayoutChange = true
        h.model.libraryCheck = report
        #expect(h.model.libraryCheckSummary?.recoveredLayout == Self.recovered)
        // Beside whatever else the check found.
        report.untrackedFiles = [h.root.appendingPathComponent("Stray.epub")]
        h.model.libraryCheck = report
        #expect(h.model.libraryCheckSummary?.recoveredLayout == Self.recovered)
        #expect(h.model.libraryCheckSummary?.untracked != nil)
    }

    // MARK: FL12 Folders that could not be put back

    @Test func fl12_anUnresolvedLayoutChangeIsShownWithItsFoldersAndWhatIsOff() async throws {
        let (h, from, _) = try await unrecoverable()
        await h.model.start()

        #expect(h.model.layoutChangeIsUnresolved)
        let report = try #require(h.model.libraryCheck)
        let reason = try #require(report.layoutChangeProblem)
        let summary = try #require(h.model.libraryCheckSummary)
        let problem = try #require(summary.layoutProblem)
        #expect(problem.section.heading == "A change of folder layout was interrupted")
        // The library's own reason, as a sentence, and what it means for now.
        #expect(problem.section.detail == "\(reason). Nothing was moved or deleted. \(Self.changesOff)")
        #expect(reason.contains("Ines Calloway/Tidewater Chronicles/3 - Harbour of Glass"))
        // The folder is nowhere the change could have left it: where it belongs, and
        // where it was last seen on its way to.
        #expect(problem.section.lines.map(\.text) == [
            "“Ines Calloway/Tidewater Chronicles/3 - Harbour of Glass” cannot be found. "
                + "It was being moved to “Ines Calloway/Harbour of Glass”.",
        ])
        // There is nothing there to show in the Finder.
        #expect(problem.section.lines.map(\.url) == [nil])
        #expect(!FileManager.default.fileExists(atPath: from.path))
        #expect(problem.retryTitle == "Try Again")
        #expect(problem.stopTitle == "Stop Trying…")
        #expect(summary.recoveredLayout == nil)
        #expect(summary.intro == LibraryCheckSummary.nothingChanged)
        #expect(h.model.windowSheet(progressDue: false) == .check(summary))
    }

    @Test func fl12_aFolderThatCannotGoBackIsShownWhereItIsAndWhereItBelongs() async throws {
        let h = try await interrupted()
        // Something else now stands where one of the moved folders was.
        let origin = h.root.appendingPathComponent("Ines Calloway/Tidewater Chronicles/3 - Harbour of Glass")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: origin.appendingPathComponent("new.txt"))
        await h.model.start()

        #expect(h.model.layoutChangeIsUnresolved)
        let problem = try #require(h.model.libraryCheckSummary?.layoutProblem)
        #expect(problem.section.lines.map(\.text) == [
            "“Ines Calloway/Harbour of Glass” belongs at “Ines Calloway/Tidewater Chronicles/3 - Harbour of Glass”",
        ])
        #expect(problem.section.lines.map(\.url?.lastPathComponent) == ["Harbour of Glass"])
        #expect(problem.section.detail.hasSuffix("Nothing was moved or deleted. \(Self.changesOff)"))

        // With the way back clear, Try Again puts the library right.
        try FileManager.default.removeItem(at: origin)
        await h.model.retryLibraryCheck()
        #expect(!h.model.layoutChangeIsUnresolved)
        #expect(h.model.libraryCheckSummary?.recoveredLayout == Self.recovered)
        #expect(h.model.libraryCheckSummary?.layoutProblem == nil)
    }

    @Test func fl13_foldersStillSetAsideAreToldByTheOrdinaryCheck() async throws {
        let h = try await Harness.demo()
        #expect(h.model.libraryCheckSummary == nil)
        let parked = h.root.appendingPathComponent(".voxcarrel/moving/ABC/1")
        var report = ReconcileReport()
        report.strandedFolders = [
            StrandedFolder(url: parked, belongsAt: "Ann/Two", wasMovingTo: "Ann/One"),
            StrandedFolder(url: h.root.appendingPathComponent(".voxcarrel/moving/ABC/2")),
        ]
        h.model.libraryCheck = report
        let section = try #require(h.model.libraryCheckSummary?.setAside)
        #expect(section.heading == "2 book folders were left set aside")
        #expect(section.detail.contains("nothing was deleted"))
        #expect(section.detail.contains("⌘⇧."))
        #expect(section.lines.map(\.text) == [
            "“.voxcarrel/moving/ABC/1” belongs at “Ann/Two”", "A folder at “.voxcarrel/moving/ABC/2”",
        ])
        #expect(section.lines.map(\.url) == report.strandedFolders.map(\.url))
        report.strandedFolders.removeLast()
        h.model.libraryCheck = report
        #expect(h.model.libraryCheckSummary?.setAside?.heading == "1 book folder was left set aside")
    }

    @Test func fl12_everyCommandThatWouldBeRefusedIsOff() async throws {
        let (h, _, _) = try await unrecoverable()
        await h.model.start()
        let tree = layoutTree(h.root)
        let rivers = try h.id("Quiet Rivers")
        // The sheet is closed: the library can be looked at, and is still not to be changed.
        h.model.dismissLibraryCheck()
        #expect(h.model.layoutChangeIsUnresolved)
        h.model.click(rivers, modifiers: [])
        await h.model.settle()
        h.model.updateDraft { $0.title = "Quieter Rivers" }
        #expect(h.model.hasUnsavedChanges)

        #expect(!h.model.canSave)
        #expect(!h.model.canImport)
        #expect(!h.model.canReviewInbox)
        #expect(!h.model.canUndo)
        #expect(!h.model.canLookUp)
        #expect(!h.model.canChangeFiles)
        let commands = h.model.commands(for: [rivers])
        #expect(!commands.remove)
        #expect(!commands.rewriteTags)
        #expect(!commands.repairLengthHeaders)
        h.model.discardChanges()
        h.model.chooseLayout("Author / Title")
        #expect(!h.model.canChangeLayout)
        // What the library does not refuse stays on.
        #expect(commands.open)
        #expect(commands.reveal)
        #expect(commands.mark)

        // Asked all the same, each does nothing, and says nothing.
        h.recordBusyLabels()
        let file = try #require(try h.store().files(bookId: rivers).first?.id)
        h.model.updateDraft { $0.title = "Quieter Rivers" }
        await h.model.save()
        await h.model.undo()
        await h.model.beginImport([try Harness.inbox().appendingPathComponent("Quiet Rivers.epub")])
        await h.model.rewriteTags(for: [rivers])
        await h.model.setRole(.extra, forFile: file)
        await h.model.locate(fileId: file, at: h.root.appendingPathComponent("x.epub"))
        h.model.requestRemove([rivers])
        await h.model.previewLayoutChange()
        #expect(h.busyLabels.isEmpty)
        #expect(h.model.alert == nil)
        #expect(h.model.prompt == nil)
        #expect(h.model.review == nil)
        #expect(h.model.layoutPreview == nil)
        #expect(h.model.hasUnsavedChanges)
        #expect(layoutTree(h.root) == tree)
    }

    @Test func fl12_filesOpenedFromTheFinderAreAnsweredWithASentence() async throws {
        let (h, _, _) = try await unrecoverable()
        await h.model.start()
        h.model.dismissLibraryCheck()
        await h.model.openFiles([try Harness.inbox().appendingPathComponent("Quiet Rivers.epub")])
        await h.model.settle()
        #expect(h.model.review == nil)
        #expect(h.model.alert
            == "Nothing can be imported until the interrupted change of folder layout is resolved. "
            + "Open the library again to see what can be done.")
    }

    @Test func fl12_tryAgainRunsTheCheckAgain() async throws {
        let (h, from, away) = try await unrecoverable()
        await h.model.start()
        let first = h.model.libraryCheckSummary
        h.recordBusyLabels()

        // Still not possible: the same is said, and everything is still off.
        await h.model.retryLibraryCheck()
        #expect(h.busyLabels == ["Checking the library…"])
        #expect(h.model.busyLabel == nil)
        #expect(h.model.layoutChangeIsUnresolved)
        #expect(h.model.libraryCheckSummary == first)
        #expect(!h.model.canImport)

        // With the folder back where it was left, the library is put right.
        try FileManager.default.moveItem(at: away, to: from)
        await h.model.retryLibraryCheck()
        #expect(!h.model.layoutChangeIsUnresolved)
        let summary = try #require(h.model.libraryCheckSummary)
        #expect(summary.layoutProblem == nil)
        #expect(summary.recoveredLayout == AppModelLayoutRecoveryTests.recovered)
        #expect(h.model.alert == nil)
        #expect(h.model.canImport)
        #expect(h.model.canUndo)
        #expect(FileManager.default.fileExists(
            atPath: h.root.appendingPathComponent("Ines Calloway/Tidewater Chronicles/3 - Harbour of Glass").path))
        let rows = h.model.rows.filter { $0.book.series == "Tidewater Chronicles" }
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { !$0.book.needsAttention })
    }

    @Test func fl12_tryAgainDoesNothingWhenNothingIsUnresolved() async throws {
        let h = try await Harness.demo()
        h.recordBusyLabels()
        await h.model.retryLibraryCheck()
        h.model.requestStopLayoutRecovery()
        #expect(h.busyLabels.isEmpty)
        #expect(h.model.prompt == nil)
    }

    // MARK: FL13 Stop trying

    @Test func fl13_stoppingAsksFirstAndSaysPlainlyWhatItMeans() async throws {
        let (h, _, _) = try await unrecoverable()
        await h.model.start()
        let tree = layoutTree(h.root)

        h.model.requestStopLayoutRecovery()
        let prompt = try #require(h.model.prompt)
        #expect(prompt == .stopLayoutRecovery)
        #expect(prompt.title == "Stop trying to put the folders back?")
        #expect(prompt.message
            == "VoxCarrel will stop trying to put the folders back. Books whose folders moved will show as "
            + "missing until you move the folders back or locate the files yourself. Nothing is deleted.")
        #expect(prompt.stopLayoutRecoveryTitle == "Stop Trying")
        #expect(h.model.wantsToBeSeen)

        // Cancel: nothing has changed.
        h.model.prompt = nil
        #expect(h.model.layoutChangeIsUnresolved)
        #expect(layoutTree(h.root) == tree)
        // Without the question having been asked, nothing is done.
        h.recordBusyLabels()
        await h.model.confirmStopLayoutRecovery()
        #expect(h.busyLabels.isEmpty)
        #expect(h.model.layoutChangeIsUnresolved)
    }

    @Test func fl13_stoppingUnlocksTheLibraryAndTheOrdinaryCheckFollows() async throws {
        let (h, _, away) = try await unrecoverable()
        await h.model.start()
        let tree = layoutTree(h.root)
        let folders = Dictionary(uniqueKeysWithValues: try h.store().books().map { ($0.id, $0.folderPath) })
        h.recordBusyLabels()

        h.model.requestStopLayoutRecovery()
        await h.model.confirmStopLayoutRecovery()

        #expect(h.busyLabels == ["Checking the library…"])
        #expect(h.model.busyLabel == nil)
        #expect(h.model.prompt == nil)
        #expect(h.model.alert == nil)
        #expect(!h.model.layoutChangeIsUnresolved)
        // Nothing is deleted: only the record of the change is gone (and the empty
        // place where folders are set aside, had one been made).
        let record = ".voxcarrel/layout-change.json"
        #expect(tree.contains(record))
        #expect(layoutTree(h.root) == tree.filter { $0 != record && !$0.hasPrefix(".voxcarrel/moving") })
        #expect(tree.filter { $0.hasPrefix(".voxcarrel/moving/") }.allSatisfy { !$0.hasSuffix(".m4b") })
        #expect(FileManager.default.fileExists(atPath: away.appendingPathComponent("Harbour of Glass.m4b").path))
        // The catalogue still files each book where it was.
        #expect(Dictionary(uniqueKeysWithValues: try h.store().books().map { ($0.id, $0.folderPath) }) == folders)

        // The ordinary check: the two books whose folders moved are missing their files.
        let summary = try #require(h.model.libraryCheckSummary)
        #expect(summary.layoutProblem == nil)
        #expect(summary.recoveredLayout == nil)
        #expect(summary.missing?.heading == "2 books have missing files")
        #expect(summary.missing?.lines.map(\.text) == ["Harbour of Glass", "Salt Road"])
        #expect(summary.untracked?.lines.map(\.text) == ["Ines Calloway/Salt Road/Salt Road.m4b"])
        #expect(h.model.sidebar.counts[.needsAttention] == 3)

        // And the library can be changed again.
        #expect(h.model.canImport)
        #expect(h.model.canChangeFiles)
        h.model.dismissLibraryCheck()
        await h.model.setReadStatus(.finished, for: [try h.id("Quiet Rivers")])
        try await h.select("Quiet Rivers")
        h.model.updateDraft { $0.title = "Quieter Rivers" }
        #expect(h.model.canSave)
        await h.model.save()
        #expect(h.model.alert == nil)
        #expect(try h.store().books().contains { $0.title == "Quieter Rivers" })
    }
}
