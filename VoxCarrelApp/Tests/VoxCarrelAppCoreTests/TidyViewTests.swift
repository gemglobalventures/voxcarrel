import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// The Tidy list in the app: what the sidebar lists, what a check shows, and letting
/// books off it.
@MainActor
@Suite struct TidyViewTests {
    @Test func aCheckListsItsBooksAndLetsThemOff() async throws {
        let h = try await Harness.demo()
        // The demo library has a book with no author, one with no year, and several
        // with no description; nothing else is untidy about it.
        #expect(h.model.showsTidy)
        #expect(h.model.sidebar.tidy.map(\.check) == [.noAuthor, .noYear, .noDescription])
        let undescribed = try #require(h.model.sidebar.tidy.last?.count)
        #expect(h.model.tidyCount == 2 + undescribed && h.model.tidyHeader == nil)

        h.model.sidebarSelection = .tidy(.noYear)
        await h.model.settle()
        #expect(h.model.windowTitle == "No Year" && h.model.rows.count == 1)
        var header = try #require(h.model.tidyHeader)
        #expect(header.title == "No Year" && header.countText == "1 book" && !header.canMarkFine)
        #expect(header.explanation == TidyCheck.noYear.explanation)

        // The one book is fine as it is: the check finds nothing more and its line goes.
        let id = try #require(h.model.rows.first?.id)
        h.model.click(id, modifiers: [])
        await h.model.settle()
        #expect(h.model.tidyHeader?.canMarkFine == true)
        await h.model.markSelectionFine()
        #expect(h.model.alert == nil && h.model.busyLabel == nil)
        // Its line stays, with no count, for as long as the book can be put back.
        #expect(h.model.sidebar.tidy.map(\.check) == [.noAuthor, .noYear, .noDescription])
        #expect(h.model.sidebar.tidy[1].count == 0 && h.model.sidebar.tidy[1].letOff == 1)
        #expect(h.model.sidebarSelection == .tidy(.noYear) && h.model.rows.isEmpty)
        #expect(h.model.tidyHeader?.putBackTitle == "List the 1 Let Off Again")
        await h.model.putBackLetOff()
        await h.model.settle()
        #expect(h.model.rows.map(\.id) == [id] && h.model.tidyHeader?.putBackTitle == nil)
        #expect(h.model.sidebar.tidy[1].count == 1)

        // Of a longer list, the ones let off go and the rest stay listed.
        h.model.sidebarSelection = .tidy(.noDescription)
        await h.model.settle()
        header = try #require(h.model.tidyHeader)
        #expect(header.countText == "\(undescribed) books" && h.model.rows.count == undescribed)
        let first = try #require(h.model.rows.first?.id)
        h.model.click(first, modifiers: [])
        await h.model.settle()
        await h.model.markSelectionFine()
        await h.model.settle()
        #expect(h.model.sidebarSelection == .tidy(.noDescription))
        #expect(h.model.rows.count == undescribed - 1 && !h.model.rows.contains { $0.id == first })
        #expect(h.model.sidebar.tidy.last?.count == undescribed - 1)
        // The book itself is as it was.
        let summary = try h.book(first).summary ?? ""
        #expect(summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
