import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

private let seriesName = "Tidewater Chronicles"

/// Smart shelves and Up Next in the app model. SH10 onwards; SH1–SH9 are the engine's.
///
/// The demo library has three books of "Tidewater Chronicles": "Salt Road" (1) is
/// finished, "The Drowned Bell" (2) is being read and "Harbour of Glass" (3) is unread.
/// "Night Train to Vostok" and "Two Hands on the Wheel" are being read too. It begins
/// with the three starter shelves. Audible's catalogue is a fake.
@MainActor
@Suite struct AppModelShelfTests {
    private typealias Member = FakeCatalogue.Member

    /// A demo library whose series has been checked against Audible's list, which has
    /// two books the library lacks (4 and 5), and whose three books are all finished:
    /// the next of the series is one the library does not have. Up Next is shown.
    private func withMissingNext() async throws -> Harness {
        let h = try await Harness.demo(start: false)
        h.model.audibleStore = .us
        h.model.otherAudibleStores = []
        h.lookup.catalogue.set([
            FakeCatalogue.Series(
                id: "B0TIDEWATR", title: seriesName,
                members: [
                    Member(asin: "B0SALTROAD", title: "Salt Road", number: "1"),
                    Member(asin: "B0DROWNBEL", title: "The Drowned Bell", number: "2"),
                    Member(asin: "B0HARBOURG", title: "Harbour of Glass", number: "3"),
                    Member(asin: "B0GLASSTID", title: "The Glass Tide", number: "4", minutes: 615),
                    Member(asin: "B0LANTERNR", title: "Lantern Reef", number: "5"),
                ])
        ])
        await h.model.start()
        h.model.sidebarSelection = .browse(.series, seriesName)
        await h.model.settle()
        await h.model.checkSeries()
        #expect(h.model.alert == nil)
        await h.model.setReadStatus(.finished, for: try h.ids(["The Drowned Bell", "Harbour of Glass"]))
        await show(.upNext, h)
        return h
    }

    private func show(_ item: SidebarItem, _ h: Harness) async {
        h.model.sidebarSelection = item
        await h.model.settle()
    }

    private func shelf(_ h: Harness, _ name: String) throws -> ShelfRow {
        try #require(h.model.shelves.first { $0.name == name }, "no shelf named \(name)")
    }

    private func missingRow(_ h: Harness, _ title: String) throws -> BookRow {
        try #require(h.model.rows.first { $0.isMissing && $0.book.title == title }, "no missing row titled \(title)")
    }

    private func strays(_ h: Harness) -> [Int64] {
        h.model.worker?.strayIds.withLock { $0 } ?? []
    }

    // MARK: Up Next

    /// SH10: Up Next lists the books being read, and is always in the sidebar with its
    /// number of lines.
    @Test func SH10_upNextShowsTheBooksBeingRead() async throws {
        let h = try await Harness.demo()
        #expect(h.model.upNextCount == 3)
        #expect(h.model.title(of: .upNext) == "Up Next")
        await show(.upNext, h)
        #expect(Set(h.titles) == ["The Drowned Bell", "Night Train to Vostok", "Two Hands on the Wheel"])
        #expect(h.model.windowTitle == "Up Next")
        #expect(h.model.windowSubtitle == "3 books")
        #expect(h.model.seriesHeader == nil)
    }

    /// SH11: the lines are in the list's own order: being read, then the next of each
    /// series begun, which may be a book the library lacks, then those put there by hand.
    @Test func SH11_upNextKeepsItsOwnOrderWithAMissingRow() async throws {
        let h = try await withMissingNext()
        // Books are put on the list from a list that shows them.
        await show(.allBooks, h)
        await h.model.addToUpNext(try h.ids(["Voices from the Attic", "The Clockmaker's Apprentice"]))
        await show(.upNext, h)
        let expected = ["Night Train to Vostok", "Two Hands on the Wheel", "The Glass Tide"]
        #expect(Array(h.titles.prefix(3)) == expected)
        #expect(Set(h.titles.suffix(2)) == ["Voices from the Attic", "The Clockmaker's Apprentice"])
        #expect(h.model.rows.map(\.isMissing) == [false, false, true, false, false])
        let missing = try missingRow(h, "The Glass Tide")
        #expect(missing.id < 0)
        #expect(missing.seriesText == "Tidewater Chronicles #4")
        // The count is of lines; the subtitle is of the library's books.
        #expect(h.model.upNextCount == 5)
        #expect(h.model.windowSubtitle == "4 books")
        #expect(strays(h).isEmpty)
    }

    /// SH12: no sort re-orders Up Next, and it is never grouped by series.
    @Test func SH12_upNextIsNeitherSortedNorGrouped() async throws {
        let h = try await withMissingNext()
        let before = h.titles
        #expect(before.count == 3)
        h.model.sort = BookSort(key: .title, ascending: false)
        #expect(h.titles == before)
        h.model.sort = BookSort(key: .author, ascending: true)
        #expect(h.titles == before)
        h.model.groupsBySeries = true
        #expect(!h.model.isGrouping)
        #expect(h.model.items.count == 3)
        await h.model.reloadAll()
        #expect(h.titles == before)
        // A shelf is sorted like any other list.
        h.model.groupsBySeries = false
        await show(try shelf(h, "Recently Added").item, h)
        h.model.sort = BookSort(key: .title, ascending: true)
        let ascending = h.titles
        #expect(ascending.count > 3)
        h.model.sort = BookSort(key: .title, ascending: false)
        #expect(h.titles == ascending.reversed())
    }

    /// SH13: a search narrows Up Next, its missing rows too.
    @Test func SH13_aSearchNarrowsUpNext() async throws {
        let h = try await withMissingNext()
        h.model.searchText = "vostok"
        await h.model.settle()
        #expect(h.titles == ["Night Train to Vostok"])
        // "Harbour of Glass" is in the library and not in Up Next.
        h.model.searchText = "GLASS"
        await h.model.settle()
        #expect(h.titles == ["The Glass Tide"])
        #expect(h.model.rows.first?.isMissing == true)
        h.model.searchText = "calloway"
        await h.model.settle()
        #expect(h.titles == ["The Glass Tide"])
        h.model.searchText = "no such book"
        await h.model.settle()
        #expect(h.titles.isEmpty)
        #expect(h.model.emptyState == .noMatches)
        #expect(strays(h).isEmpty)
    }

    /// SH14: a missing row of Up Next is inspected, shown on Audible, hidden and added
    /// as it is in its series, and Up Next then shows what is next now.
    @Test func SH14_theMissingBookActionsWorkFromUpNext() async throws {
        let h = try await withMissingNext()
        let glass = try missingRow(h, "The Glass Tide")
        h.model.click(glass.id, modifiers: [])
        await h.model.settle()
        let info = try #require(h.model.missingBook)
        #expect(info.title == "The Glass Tide")
        #expect(info.seriesText == "Tidewater Chronicles #4")
        #expect(info.storeText == "Audible US")
        #expect(info.canChange)
        let actions = try #require(h.model.missingActions(for: [glass.id]))
        #expect(actions.canAdd && actions.canShow && actions.canSetHidden)
        #expect(!h.model.canAddToUpNext && !h.model.canRemoveFromUpNext)

        h.model.showMissingOnAudible()
        #expect(h.opener.openedWeb.count == 1)

        // Hidden, it is no longer next: the one after it is.
        await h.model.setSelectedMissingHidden(true)
        #expect(h.titles == ["Night Train to Vostok", "Two Hands on the Wheel", "Lantern Reef"])
        #expect(h.model.missingBook == nil)

        // Added from a context menu, without being selected, it is a book of the library.
        let reef = try missingRow(h, "Lantern Reef")
        #expect(h.model.missingActions(for: [reef.id])?.canAdd == true)
        await h.model.addMissingAsAudibleBook(for: [reef.id])
        #expect(h.model.alert == nil)
        #expect(h.titles == ["Night Train to Vostok", "Two Hands on the Wheel", "Lantern Reef"])
        #expect(h.model.rows.allSatisfy { !$0.isMissing })
        #expect(try h.book(try h.id("Lantern Reef")).seriesNumber == "5")
        #expect(strays(h).isEmpty)
    }

    /// SH15: with nothing being read, begun or waiting, Up Next says what will be listed.
    @Test func SH15_anEmptyUpNextSaysWhatWillBeListed() async throws {
        let h = try await Harness.demo()
        let begun = ["The Drowned Bell", "Night Train to Vostok", "Two Hands on the Wheel", "Salt Road"]
        await h.model.setReadStatus(.unread, for: try h.ids(begun))
        #expect(h.model.upNextCount == 0)
        await show(.upNext, h)
        #expect(h.titles.isEmpty)
        #expect(h.model.emptyState == .nothingUpNext)
        #expect(h.model.booksContent == .empty(.nothingUpNext))
        #expect(EmptyState.nothingUpNext.title == "Nothing up next")
        #expect(
            EmptyState.nothingUpNext.message
                == "Books you are reading, the next book of a series you have begun, and books you add here will be listed.")
        #expect(h.model.sidebarSelection == .upNext)
        #expect(h.model.windowSubtitle == "No books")
    }

    // MARK: Adding by hand

    /// SH16: a book is put on Up Next and taken off; only one put there by hand can be
    /// taken off, and a finished book cannot be put there. Undo is left as it was.
    @Test func SH16_booksAreAddedToAndRemovedFromUpNext() async throws {
        let h = try await Harness.demo()
        #expect(!h.model.canAddToUpNext && !h.model.canRemoveFromUpNext)
        #expect(h.model.addToUpNextTitle == "Add to Up Next")
        #expect(h.model.removeFromUpNextTitle == "Remove from Up Next")

        let attic = try await h.select("Voices from the Attic")
        #expect(h.model.canAddToUpNext)
        #expect(!h.model.canRemoveFromUpNext)
        await h.model.addSelectionToUpNext()
        #expect(h.model.upNextCount == 4)
        #expect(try LibraryService(store: try h.store()).queuedForUpNext([attic]) == [attic])
        #expect(!h.model.canAddToUpNext)
        #expect(h.model.canRemoveFromUpNext)
        #expect(h.model.undoMenuTitle == "Undo \(Harness.demoUndoLabel)")

        // A finished book cannot be added; one being read can, and cannot be removed.
        try await h.select("Quiet Rivers")
        #expect(!h.model.canAddToUpNext && !h.model.canRemoveFromUpNext)
        try await h.select("Night Train to Vostok")
        #expect(h.model.canAddToUpNext)
        #expect(!h.model.canRemoveFromUpNext)

        // Of several, those that can be are added; any that is queued can be removed.
        let both = try await h.select(["Voices from the Attic", "Quiet Rivers", "The Cartographer's Daughter"])
        #expect(h.model.canAddToUpNext && h.model.canRemoveFromUpNext)
        await h.model.addSelectionToUpNext()
        #expect(h.model.sidebar.upNextQueued == both.subtracting([try h.id("Quiet Rivers")]))
        #expect(h.model.upNextCount == 5)

        // Shown in Up Next, the rows follow.
        await show(.upNext, h)
        #expect(h.titles.suffix(2) == ["Voices from the Attic", "The Cartographer's Daughter"])
        try await h.select("Voices from the Attic")
        await h.model.removeSelectionFromUpNext()
        #expect(h.model.upNextCount == 4)
        #expect(h.titles.last == "The Cartographer's Daughter")
        #expect(!h.titles.contains("Voices from the Attic"))
        #expect(h.model.undoMenuTitle == "Undo \(Harness.demoUndoLabel)")
    }

    // MARK: Shelves in the sidebar

    /// SH17: the sidebar lists the shelves, each with the number of books it holds now.
    @Test func SH17_theSidebarListsTheShelvesWithTheirCounts() async throws {
        let h = try await Harness.demo()
        #expect(h.model.shelves.map(\.name) == SmartShelf.starters.map(\.name))
        let service = LibraryService(store: try h.store())
        for row in h.model.shelves {
            let stored = try #require(try service.smartShelves().first { $0.id == row.id })
            let books = try service.books(on: stored)
            #expect(row.count == books.count)
            #expect(row.item == .shelf(row.id))
            await show(row.item, h)
            #expect(Set(h.titles) == Set(books.map(\.title)))
            #expect(h.model.windowTitle == row.name)
        }
        // Worked out fresh: a book that is finished joins "Finished, Not Rated".
        let unrated = try shelf(h, "Finished, Not Rated")
        await h.model.setReadStatus(.finished, for: try h.ids(["Voices from the Attic"]))
        #expect(try shelf(h, "Finished, Not Rated").count == unrated.count + 1)
        let recent = try shelf(h, "Recently Added")
        #expect(recent.count == 12)
        // A search narrows a shelf like any other list.
        await show(recent.item, h)
        h.model.searchText = "vostok"
        await h.model.settle()
        #expect(h.titles == ["Night Train to Vostok"])
    }

    /// SH18: deleting a shelf asks first; when it was the one shown, All Books is shown.
    @Test func SH18_deletingTheShownShelfFallsBackToAllBooks() async throws {
        let h = try await Harness.demo()
        let short = try shelf(h, "Short Listens")
        await show(short.item, h)
        #expect(h.model.canDeleteShelf(short.id))
        #expect(!h.model.canDeleteShelf(9_999))
        h.model.deleteShelf(short.id)
        let question = try #require(h.model.prompt)
        #expect(question == .deleteShelf(id: short.id, name: "Short Listens"))
        #expect(question.title == "Delete the shelf \"Short Listens\"?")
        #expect(question.message == "The books on it stay in the library.")
        #expect(question.deleteShelfTitle == "Delete")
        // Nothing is deleted until the answer, and no other shelf can be meanwhile.
        #expect(h.model.shelves.count == 3)
        #expect(!h.model.canDeleteShelf(short.id))

        h.model.prompt = nil
        #expect(h.model.shelves.count == 3)
        await h.model.confirmDeleteShelf()
        #expect(h.model.shelves.count == 3)

        h.model.deleteShelf(short.id)
        await h.model.confirmDeleteShelf()
        #expect(h.model.prompt == nil)
        #expect(h.model.shelves.map(\.name) == ["Recently Added", "Finished, Not Rated"])
        #expect(h.model.sidebarSelection == .allBooks)
        #expect(h.titles.count == 12)
        #expect(try h.store().books().count == 12)
    }
}
