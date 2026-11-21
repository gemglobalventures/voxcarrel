import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// What the launch-check sheet and the drop target ask of the model (plan Task 11). Q10–Q13.
@MainActor
@Suite struct AppModelLibraryCheckTests {
    // MARK: Q10 What the check has to tell

    /// Q10
    @Test func nothingToTellIsNoSummary() async throws {
        let h = try await Harness.demo()
        #expect(h.model.libraryCheck == nil)
        #expect(h.model.libraryCheckSummary == nil)
    }

    /// Q10: books with missing files are named, whatever the window is showing.
    @Test func booksWithMissingFilesAreListedByTitle() async throws {
        let h = try await Harness.demo(start: false)
        for title in ["Quiet Rivers", "Salt Road"] {
            try FileManager.default.removeItem(at: try #require(try h.fileURLs(try h.id(title)).first))
        }
        await h.model.start()

        let summary = try #require(h.model.libraryCheckSummary)
        let missing = try #require(summary.missing)
        #expect(missing.heading == "2 books have missing files")
        #expect(missing.detail.contains("Needs Attention"))
        #expect(missing.lines.map(\.text) == ["Quiet Rivers", "Salt Road"])
        #expect(summary.untracked == nil)
        #expect(summary.stranded == nil)

        // The names do not depend on the books being among those shown.
        h.model.searchText = "no book is called this"
        await h.model.settle()
        #expect(h.model.rows.isEmpty)
        #expect(h.model.libraryCheckSummary?.missing?.lines.map(\.text) == ["Quiet Rivers", "Salt Road"])
    }

    /// Q10
    @Test func oneBookWithMissingFilesIsSaidInTheSingular() async throws {
        let h = try await Harness.demo(start: false)
        try FileManager.default.removeItem(at: try #require(try h.fileURLs(try h.id("Quiet Rivers")).first))
        await h.model.start()
        #expect(h.model.libraryCheckSummary?.missing?.heading == "1 book has missing files")
    }

    /// Q10: files are named by where they are inside the library folder.
    @Test func untrackedAndStrandedFilesAreListedByTheirPlaceInTheLibrary() async throws {
        let h = try await Harness.demo()
        let stray = h.root.appendingPathComponent("Stray.epub")
        let deep = h.root.appendingPathComponent("Ann Author/Atlas/Atlas.pdf")
        let stranded = h.root.appendingPathComponent("Ann Author/.half-moved.m4b")
        let outside = URL(fileURLWithPath: "/elsewhere/Other.epub")
        h.model.libraryCheck = ReconcileReport(untrackedFiles: [stray, deep, outside], strandedFiles: [stranded])

        let summary = try #require(h.model.libraryCheckSummary)
        #expect(summary.missing == nil)
        let untracked = try #require(summary.untracked)
        #expect(untracked.heading == "3 files in the library folder do not belong to any book")
        #expect(untracked.lines.map(\.text) == ["Stray.epub", "Ann Author/Atlas/Atlas.pdf", "/elsewhere/Other.epub"])
        #expect(untracked.lines.map(\.url) == [stray, deep, outside])
        let half = try #require(summary.stranded)
        #expect(half.heading == "1 file was left half-moved")
        #expect(half.detail.contains("untouched"))
        #expect(half.lines.map(\.text) == ["Ann Author/.half-moved.m4b"])
        #expect(half.lines.map(\.url) == [stranded])

        h.model.libraryCheck = ReconcileReport(untrackedFiles: [stray], strandedFiles: [stranded, deep])
        #expect(
            h.model.libraryCheckSummary?.untracked?.heading
                == "1 file in the library folder does not belong to any book")
        #expect(h.model.libraryCheckSummary?.stranded?.heading == "2 files were left half-moved")
    }

    /// Q10: every line of a section can be told from the others.
    @Test func linesAreNumberedWithinTheirSection() async throws {
        let h = try await Harness.demo()
        let files = ["a.epub", "b.epub", "c.epub"].map { h.root.appendingPathComponent($0) }
        h.model.libraryCheck = ReconcileReport(untrackedFiles: files)
        #expect(h.model.libraryCheckSummary?.untracked?.lines.map(\.id) == [0, 1, 2])
    }

    /// Q10: once everything has been dealt with there is nothing to show.
    @Test func aCheckWithNothingLeftHasNoSummary() async throws {
        let h = try await Harness.demo()
        h.model.libraryCheck = ReconcileReport()
        #expect(h.model.libraryCheckSummary == nil)
        h.model.libraryCheck = ReconcileReport(strandedFiles: [h.root.appendingPathComponent("x.m4b")])
        #expect(h.model.libraryCheckSummary != nil)
        h.model.dismissLibraryCheck()
        #expect(h.model.libraryCheckSummary == nil)
    }

    // MARK: Q11 Show in Needs Attention

    /// Q11
    @Test func showingNeedsAttentionClosesTheCheckAndShowsThoseBooks() async throws {
        let h = try await Harness.demo(start: false)
        let quiet = try h.id("Quiet Rivers")
        try FileManager.default.removeItem(at: try #require(try h.fileURLs(quiet).first))
        await h.model.start()
        h.model.searchText = "salt"
        await h.model.settle()

        h.model.showNeedsAttention()
        await h.model.settle()
        #expect(h.model.libraryCheck == nil)
        #expect(h.model.sidebarSelection == .needsAttention)
        // A search would hide them.
        #expect(h.model.searchText == "")
        #expect(h.model.rows.map(\.id).contains(quiet))
        #expect(h.model.rows.allSatisfy { $0.book.needsAttention })
    }

    // MARK: Q12 Reveal

    /// Q12
    @Test func aFileOfTheCheckIsShownInTheFinder() async throws {
        let h = try await Harness.demo()
        let stranded = h.root.appendingPathComponent(".half-moved.m4b")
        h.model.revealInFinder(stranded)
        #expect(h.opener.revealed == [[stranded]])
        #expect(h.opener.opened.isEmpty)
    }

    // MARK: Q13 Dropped things

    /// Q13: only files and folders can be imported; a link dragged from a browser is not one.
    @Test func droppedLinksAreNotImported() async throws {
        let h = try await Harness.empty()
        h.recordBusyLabels()
        let link = try #require(URL(string: "https://example.com/book.epub"))
        await h.model.beginImport([link])
        #expect(h.busyLabels.isEmpty)
        #expect(h.model.alert == nil)
        #expect(h.model.review == nil)

        // The files dropped with it are still imported.
        let inbox = try Harness.inbox()
        await h.model.beginImport([link, inbox.appendingPathComponent("Quiet Rivers.epub")])
        #expect(h.model.review?.entries.count == 1)
        #expect(h.model.review?.skipped.isEmpty == true)
    }
}
