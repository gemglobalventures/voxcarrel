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
        await h.model.confirmImport()
        await h.model.settle()
        #expect(h.model.alert == nil)

        // In the catalogue; its file is where it was, as it was; nothing is in the library folder.
        let row = try #require(h.model.rows.first { $0.book.title == "Quiet Rivers" })
        #expect(row.book.keptOutside && row.outsideFiles.count == 1 && !row.book.needsAttention)
        #expect(try Data(contentsOf: file) == before)
        #expect(h.model.sidebar.tidy.contains { $0.check == .outsideLibrary && $0.count == 1 })
        #expect(h.model.canBringIntoLibrary([row.id]) && !h.model.canBringIntoLibrary([]))

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
