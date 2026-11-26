import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// Editions of one book linked in the app: each stays its own entry, and the
/// inspector of each names the others.
@MainActor
@Suite struct AppEditionsTests {
    @Test func booksAreLinkedAsEditionsAndUnlinked() async throws {
        let h = try await Harness.demo()
        let salt = try h.id("Salt Road")
        let rivers = try h.id("Quiet Rivers")
        let before = h.model.rows.count
        #expect(h.model.canLinkEditions([salt, rivers]) && !h.model.canLinkEditions([salt]))
        #expect(!h.model.canUnlinkEdition([salt]))

        await h.model.linkEditions(for: [salt, rivers])
        #expect(h.model.alert == nil && h.model.busyLabel == nil)
        // Still two entries, each with its own files.
        #expect(h.model.rows.count == before)
        #expect(try h.fileURLs(salt) != h.fileURLs(rivers))
        try await h.select("Salt Road")
        let text = try #require(h.detail?.editionsText)
        #expect(text.hasPrefix("Other editions here: Quiet Rivers"))
        #expect(h.model.canUnlinkEdition([salt]) && h.model.canUnlinkEdition([rivers]))
        #expect(!h.model.canUnlinkEdition([salt, rivers]))

        await h.model.unlinkEdition(for: [salt])
        try await h.select("Salt Road")
        #expect(h.detail?.editionsText == nil)
        #expect(!h.model.canUnlinkEdition([rivers]))
    }
}
