import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// G13–G15: "Update files…", as its sheet's state decides it.
@MainActor
@Suite struct GenreFilesUpdateTests {
    /// A demo library whose three Fantasy books have files that still say "Fantasy".
    private func renamed() async throws -> Harness {
        let h = try await Harness.demo()
        try await h.rename("Fantasy", to: "Fantastic")
        return h
    }

    @Test func GH14_thePreviewSaysWhatWillBeWrittenAndWritesNothing() async throws {
        let h = try await renamed()
        #expect(h.model.canUpdateGenreFiles)
        await h.model.beginGenreFilesUpdate()
        let update = try #require(h.model.genreFilesUpdate)
        // GH-d
        #expect(update.title == "Update genre tags in 3 files of 3 books")
        #expect(update.columns == ["Book", "Tag recorded", "Tag after"])
        #expect(update.note == "Other details that differ from the library are written too.")
        #expect(update.rows.map(\.title) == AppModelGenreTests.tidewater)
        #expect(update.rows.map(\.tagNow) == ["Fantasy", "Fantasy", "Fantasy"])
        #expect(update.rows.map(\.tagAfter) == ["Fantastic", "Fantastic", "Fantastic"])
        #expect(update.rows.map(\.filesText) == ["1 file", "1 file", "1 file"])
        #expect(update.updateTitle == "Update")
        #expect(update.canUpdate)
        #expect(update.emptyText == nil)

        // Nothing is written until Update.
        for title in AppModelGenreTests.tidewater {
            #expect(try h.genreTag(title) == "Fantasy")
        }
        update.cancel()
        #expect(h.model.genreFilesUpdate == nil)
        #expect(try h.genreTag("Salt Road") == "Fantasy")
        #expect(h.model.genreFilesToUpdate == 3)
        #expect(h.model.undoLabel == "Rename genre")
    }

    @Test func GH14_updateWritesTheFilesAsOneUndoableOperation() async throws {
        let h = try await renamed()
        await h.model.beginGenreFilesUpdate()
        let update = try #require(h.model.genreFilesUpdate)
        h.recordBusyLabels()
        await update.update()

        #expect(h.busyLabels == ["Updating genre tags…"])
        #expect(h.model.genreFilesUpdate == nil)
        // Nothing went wrong, so there is nothing to read.
        #expect(h.model.result == nil)
        #expect(h.model.alert == nil)
        for title in AppModelGenreTests.tidewater {
            #expect(try h.genreTag(title) == "Fantastic", "\(title)")
        }
        #expect(h.model.genreFilesToUpdate == 0)
        #expect(h.model.genreFilesOffer == nil)
        #expect(!h.model.canUpdateGenreFiles)
        #expect(h.model.undoLabel == "Update genre tags for 3 books")

        await h.model.undo()
        for title in AppModelGenreTests.tidewater {
            #expect(try h.genreTag(title) == "Fantasy", "\(title)")
        }
        #expect(h.model.genreFilesToUpdate == 3)
    }

    @Test func GH14_aFileThatCannotBeWrittenIsReportedAsOtherSavesReportIt() async throws {
        let h = try await renamed()
        let locked = try #require(try h.fileURLs(try h.id("Salt Road")).first)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

        await h.model.beginGenreFilesUpdate()
        await h.model.genreFilesUpdate?.update()
        let result = try #require(h.model.result)
        #expect(!result.isClean)
        #expect(result.problems.map(\.title) == ["Salt Road"])
        // The others were written, and the one that was not is still counted.
        #expect(try h.genreTag("The Drowned Bell") == "Fantastic")
        #expect(h.model.genreFilesToUpdate == 1)
    }

    @Test func GH14_aTagThatWillBeTakenAwayAndOneThatIsNotThereAreSaidInWords() async throws {
        let h = try await Harness.demo()
        try await h.give("Sea Stories", in: .fiction, to: ["Voices from the Attic"])
        let manager = try h.manager()
        manager.requestDelete("Sea Stories")
        await manager.confirmQuestion()
        h.model.closeManageGenres()
        // Another book differs as well.
        try await h.rename("History", to: "The Past")

        await h.model.beginGenreFilesUpdate()
        let update = try #require(h.model.genreFilesUpdate)
        #expect(update.title == "Update genre tags in 2 files of 2 books")
        let attic = try #require(update.rows.first { $0.title == "Voices from the Attic" })
        #expect(attic.tagNow == "Sea Stories")
        #expect(attic.tagAfter == "No tag")
        #expect(update.rows.first { $0.title != "Voices from the Attic" }?.tagNow == "History")
    }

    @Test func GH14_withNothingToUpdateTheSheetSaysSo() async throws {
        let h = try await Harness.demo()
        #expect(!h.model.canUpdateGenreFiles)
        await h.model.beginGenreFilesUpdate()
        let update = try #require(h.model.genreFilesUpdate)
        #expect(update.rows.isEmpty)
        #expect(update.title == "Update genre tags")
        #expect(update.emptyText == "Every file's genre tag matches the library.")
        #expect(!update.canUpdate)
        await update.update()
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
    }

    @Test func GH14_oneFileOfOneBookIsCountedInTheSingular() async throws {
        let h = try await Harness.demo()
        try await h.rename("History", to: "The Past")
        await h.model.beginGenreFilesUpdate()
        #expect(h.model.genreFilesUpdate?.title == "Update genre tags in 1 file of 1 book")
        #expect(h.model.genreFilesOffer?.help == "The genre tag in the files of 1 book differs from the library.")
    }

    @Test func GH14_aBookInSeveralFilesCountsEachFileThatHoldsAGenre() async throws {
        let h = try await Harness.demo()
        // Four MP3s; and an audiobook with an ebook.
        try await h.rename("Thrillers & Spies", to: "Thrillers")
        try await h.rename("Historical Fiction", to: "Period Pieces")
        await h.model.beginGenreFilesUpdate()
        let update = try #require(h.model.genreFilesUpdate)
        #expect(update.title == "Update genre tags in 6 files of 2 books")
        #expect(update.rows.map(\.filesText) == ["4 files", "2 files"])
        #expect(update.rows.first?.tagNow == "Thrillers & Spies; Crime & Mystery")
        #expect(update.rows.first?.tagAfter == "Thrillers; Crime & Mystery")
    }

    /// G15: a book whose only file cannot hold a genre is never counted.
    @Test func GH15_aBookWhoseFilesCannotHoldAGenreIsNotCounted() async throws {
        let (h, id) = try await Harness.merging { try $0.pdf("Dune Notes", "Frank Herbert") }
        await h.select(ids: [id])
        h.model.addDraftGenre("Science Fiction")
        await h.model.save()
        #expect(try h.book(id).genres == ["Science Fiction"])
        #expect(h.model.genreFilesToUpdate == 0)
        try await h.rename("Science Fiction", to: "Space Books")
        #expect(h.model.genreFilesToUpdate == 0)
        #expect(h.model.genreFilesOffer == nil)
    }
}
