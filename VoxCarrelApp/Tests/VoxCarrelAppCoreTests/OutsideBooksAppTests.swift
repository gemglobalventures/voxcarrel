import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// Books added where their files are, in the app: the choice in the review, the list
/// of them, and bringing them into the library.
@MainActor
@Suite struct OutsideBooksAppTests {
    @Test func aBookIsAddedWhereItIsAndBroughtInLater() async throws {
        let h = try await Harness.empty()
        let inbox = try Harness.inbox()
        let file = inbox.appendingPathComponent("Quiet Rivers.epub")
        let before = try Data(contentsOf: file)

        await h.model.beginImport([file])
        var review = try #require(h.model.review)
        #expect(review.offersInPlace && !review.leavesInPlace && review.options.mode == .move && !review.options.leavesInPlace)
        h.model.updateReview { $0.leavesInPlace = true }
        review = try #require(h.model.review)
        #expect(review.options.leavesInPlace)
        let entry = try #require(review.entries.first)
        #expect(review.destinationText(of: entry.id) == "Stays where it is, outside the library: \(file.deletingLastPathComponent().path)")
        await h.model.confirmImport()
        await h.model.settle()
        #expect(h.model.alert == nil)

        // In the catalogue; its file is where it was, as it was; nothing is in the library folder.
        let row = try #require(h.model.rows.first { $0.book.title == "Quiet Rivers" })
        #expect(row.book.keptOutside && row.outsideFiles.count == 1 && !row.book.needsAttention)
        #expect(try Data(contentsOf: file) == before)
        #expect(h.model.sidebar.tidy.contains { $0.check == .outsideLibrary && $0.count == 1 })
        #expect(h.model.canBringIntoLibrary([row.id]) && !h.model.canBringIntoLibrary([]))
        #expect(row.outsideText == "Kept outside the library, where its files are" && !row.isOutOfReach)

        // Its drive goes: the row says so, and the book is not flagged for it.
        let parked = inbox.appendingPathComponent("away.epub")
        try FileManager.default.moveItem(at: file, to: parked)
        await h.model.reloadAll()
        await h.model.settle()
        let away = try #require(h.model.rows.first { $0.id == row.id })
        #expect(away.isOutOfReach && away.outsideText?.contains("the drive may not be connected") == true)
        #expect(!away.book.needsAttention && away.warningText == nil)
        try FileManager.default.moveItem(at: parked, to: file)
        await h.model.reloadAll()
        await h.model.settle()

        // Brought in as a copy: filed in the library, and the original still there.
        await h.model.bringIntoLibrary([row.id], copying: true)
        await h.model.settle()
        #expect(h.model.alert == nil)
        let after = try #require(h.model.rows.first { $0.id == row.id })
        #expect(!after.book.keptOutside && after.outsideFiles.isEmpty && after.book.folderPath != nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!h.model.sidebar.tidy.contains { $0.check == .outsideLibrary })
        #expect(!h.model.canBringIntoLibrary([row.id]))
        #expect(h.model.undoLabel == "Bring Quiet Rivers into the library")
    }
}
