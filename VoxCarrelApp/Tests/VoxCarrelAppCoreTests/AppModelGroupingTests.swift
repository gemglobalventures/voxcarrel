import DemoContent
import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// Plan 10, Task 2: series groups in the app model. GS10–GS24.
///
/// The demo library has twelve books; three of them are one series, Tidewater
/// Chronicles: Salt Road (1), The Drowned Bell (2) and Harbour of Glass (3).
@MainActor
@Suite struct AppModelGroupingTests {
    private static let series = "Tidewater Chronicles"
    private static let seriesTitles = ["Salt Road", "The Drowned Bell", "Harbour of Glass"]
    private static let seriesItem = ItemID.series(series)

    /// A demo library with Group by Series on, shown as a list: in the grid a group
    /// is selected whole or not at all (`groupedGrid`).
    private func grouped() async throws -> Harness {
        let h = try await Harness.demo()
        h.model.viewMode = .list
        h.model.groupsBySeries = true
        return h
    }

    /// The same, shown as the grid.
    private func groupedGrid() async throws -> Harness {
        let h = try await Harness.demo()
        h.model.viewMode = .grid
        h.model.groupsBySeries = true
        return h
    }

    private func group(_ h: Harness, _ name: String = series) throws -> SeriesGroup {
        let found = h.model.items.compactMap { item -> SeriesGroup? in
            if case .series(let group) = item, group.name == name { return group }
            return nil
        }
        return try #require(found.first, "no group named \(name)")
    }

    /// The ids of the series' books, in the order of the series.
    private func seriesIds(_ h: Harness) throws -> [Int64] {
        try Self.seriesTitles.map { try h.id($0) }
    }

    private func books(_ ids: [Int64]) -> Set<ItemID> {
        Set(ids.map(ItemID.book))
    }

    /// Where the series' group is among the items.
    private func groupIndex(_ h: Harness) throws -> Int {
        try #require(h.model.items.firstIndex { $0.id == Self.seriesItem })
    }

    /// The id of the book that is the item at this place.
    private func bookId(_ h: Harness, at index: Int) throws -> Int64 {
        guard case .book(let row) = h.model.items[index] else {
            Issue.record("the item at \(index) is not a book")
            return 0
        }
        return row.id
    }

    // MARK: GS10

    /// GS10
    @Test func groupingIsOffAtFirstAndRemembered() async throws {
        let h = try await Harness.demo()
        #expect(!h.model.groupsBySeries)
        #expect(!h.relaunched().groupsBySeries)

        h.model.groupsBySeries = true
        #expect(h.model.groupsBySeries)
        #expect(h.relaunched().groupsBySeries)

        h.model.groupsBySeries = false
        #expect(!h.relaunched().groupsBySeries)
    }

    // MARK: GS11

    /// GS11
    @Test func itemsAreTheRowsUntilGroupingIsOn() async throws {
        let h = try await Harness.demo()
        #expect(!h.model.isGrouping)
        #expect(h.model.items == h.model.rows.map(LibraryItem.book))

        let changed = ChangeFlag()
        withObservationTracking {
            _ = h.model.items
        } onChange: {
            changed.raise()
        }
        h.model.groupsBySeries = true
        #expect(changed.isRaised)
        #expect(h.model.isGrouping)
        #expect(h.model.items == SeriesGrouping.items(from: h.model.rows, sort: h.model.sort, grouped: true))
        #expect(h.model.items.count == 10)
        #expect(try group(h).books.map(\.book.title) == Self.seriesTitles)

        h.model.groupsBySeries = false
        #expect(!h.model.isGrouping)
        #expect(h.model.items == h.model.rows.map(LibraryItem.book))
    }

    /// GS11
    @Test func itemsFollowTheSort() async throws {
        let h = try await grouped()
        for key in BookSortKey.allCases {
            for ascending in [true, false] {
                let sort = BookSort(key: key, ascending: ascending)
                h.model.sort = sort
                #expect(h.model.items == SeriesGrouping.items(from: h.model.rows, sort: sort, grouped: true))
                #expect(h.model.items.count == 10)
            }
        }
    }

    /// GS11: a search shows a flat list.
    @Test func searchingShowsBooksNotGroups() async throws {
        let h = try await grouped()
        h.model.searchText = "Ines Calloway"
        await h.model.settle()
        #expect(!h.model.isGrouping)
        #expect(h.model.rows.count == 3)
        #expect(h.model.items == h.model.rows.map(LibraryItem.book))

        h.model.searchText = ""
        await h.model.settle()
        #expect(h.model.isGrouping)
        #expect(h.model.items.count == 10)
    }

    /// GS11: a single series' own view and the Inbox are never grouped; anything else
    /// in the sidebar is.
    @Test func aSingleSeriesAndTheInboxAreNeverGrouped() async throws {
        let h = try await grouped()
        h.model.sidebarSelection = .browse(.series, Self.series)
        await h.model.settle()
        #expect(!h.model.isGrouping)
        #expect(h.model.items == h.model.rows.map(LibraryItem.book))
        #expect(h.model.items.count == 3)

        h.model.sidebarSelection = .browse(.authors, "Ines Calloway")
        await h.model.settle()
        #expect(h.model.isGrouping)
        #expect(h.model.items.map(\.id) == [Self.seriesItem])

        h.model.sidebarSelection = .inbox
        await h.model.settle()
        #expect(!h.model.isGrouping)
        #expect(h.model.items.isEmpty)

        h.model.sidebarSelection = .audiobooks
        await h.model.settle()
        #expect(h.model.isGrouping)
        #expect(h.model.items == SeriesGrouping.items(from: h.model.rows, sort: h.model.sort, grouped: true))
        #expect(h.model.items.contains { $0.id == Self.seriesItem })
    }

    /// GS11: a list that is made anew for the rows is made anew when the grouping changes.
    @Test func theItemsVersionChangesWithTheRowsVersionAndWithGrouping() async throws {
        let h = try await Harness.demo()
        var version = h.model.itemsVersion
        h.model.groupsBySeries = true
        #expect(h.model.itemsVersion != version)
        version = h.model.itemsVersion

        // Opening a group, and selecting, are not changes of the list.
        h.model.setGroup(Self.series, open: true)
        h.model.clickItem(Self.seriesItem, modifiers: [])
        #expect(h.model.itemsVersion == version)

        h.model.searchText = "Ines"
        await h.model.settle()
        #expect(h.model.itemsVersion != version)
    }

    // MARK: GS12

    /// GS12: the rows, the selection and the rows' version are what they were.
    @Test func groupingLeavesTheRowsAndTheSelectionAlone() async throws {
        let h = try await Harness.demo()
        let ids = try await h.select(["Quiet Rivers", "Night Train to Vostok"])
        let rows = h.model.rows
        let version = h.model.rowsVersion

        h.model.groupsBySeries = true
        #expect(h.model.rows == rows)
        #expect(h.model.rowsVersion == version)
        #expect(h.model.selection == ids)
        #expect(h.bulkDraft?.books.count == 2)

        h.model.groupsBySeries = false
        #expect(h.model.rows == rows)
        #expect(h.model.rowsVersion == version)
        #expect(h.model.selection == ids)
    }

    /// GS12: the book commands select as they did, with grouping on as with it off.
    @Test func clickingAndMovingAmongBooksIsTheSameEitherWay() async throws {
        func run(_ h: Harness) async throws -> [Set<Int64>] {
            var seen: [Set<Int64>] = []
            let ids = h.model.rows.map(\.id)
            h.model.click(ids[1], modifiers: [])
            seen.append(h.model.selection)
            h.model.click(ids[4], modifiers: .shift)
            seen.append(h.model.selection)
            h.model.click(ids[9], modifiers: .command)
            seen.append(h.model.selection)
            h.model.select([ids[0], ids[11]])
            seen.append(h.model.selection)
            _ = h.model.moveSelection(.right, columns: 4)
            seen.append(h.model.selection)
            _ = h.model.moveSelection(.down, columns: 4)
            seen.append(h.model.selection)
            h.model.contextClick(ids[7])
            seen.append(h.model.selection)
            h.model.selectAll()
            seen.append(h.model.selection)
            await h.model.settle()
            return seen
        }
        let off = try await Harness.demo()
        let on = try await grouped()
        // Each library is a copy of the same one, with the same ids.
        #expect(off.model.rows.map(\.id) == on.model.rows.map(\.id))
        #expect(try await run(off) == (try await run(on)))
        #expect(off.model.windowSubtitle == on.model.windowSubtitle)
    }

    /// GS12: a bulk edit of a selected group is saved to its books, and to no other.
    @Test func savingWithAGroupSelectedSavesItsBooks() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        h.recordBusyLabels()
        h.model.clickItem(Self.seriesItem, modifiers: [])
        await h.model.settle()
        #expect(h.model.selection == Set(ids))
        #expect(h.bulkDraft?.books.count == 3)

        h.model.updateBulkDraft { $0.values[.genre] = "Sea Stories" }
        await h.model.save()
        #expect(h.busyLabels == ["Saving 3 books…"])
        for id in ids {
            #expect(try h.book(id).genre == "Sea Stories")
        }
        #expect(try h.store().books().filter { $0.genre == "Sea Stories" }.count == 3)
        #expect(!h.model.hasUnsavedChanges)
        // The group is still there, still selected.
        #expect(h.model.itemSelection == [Self.seriesItem])
    }

    /// GS12
    @Test func readStatusWithAGroupSelectedMarksItsBooks() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        h.model.clickItem(Self.seriesItem, modifiers: [])
        await h.model.settle()
        #expect(h.model.selectionCommands.mark)

        await h.model.setReadStatus(.finished, for: h.model.selection)
        for id in ids {
            #expect(try h.book(id).readStatus == .finished)
        }
        #expect(try h.store().books().filter { $0.readStatus == .finished }.count >= 3)
        #expect(try group(h).statusText == "All finished")
        #expect(h.model.itemSelection == [Self.seriesItem])
    }

    /// GS12
    @Test func removingWithAGroupSelectedRemovesItsBooks() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        h.model.setGroup(Self.series, open: true)
        h.model.clickItem(Self.seriesItem, modifiers: [])
        await h.model.settle()

        h.model.requestRemoveSelection()
        guard case .removeBooks(let asked, _, _, _) = h.model.prompt else {
            Issue.record("no question about removing: \(String(describing: h.model.prompt))")
            return
        }
        #expect(Set(asked) == Set(ids))

        await h.model.confirmRemove(moveFilesToTrash: false)
        #expect(h.model.rows.count == 9)
        #expect(try h.store().books().count == 9)
        #expect(!h.model.items.contains { $0.id == Self.seriesItem })
        #expect(h.model.items.count == 9)
        #expect(h.model.selection.isEmpty)
        // GS13: the group is gone, and so is its name.
        #expect(h.model.openGroups.isEmpty)
    }

    /// GS12: Look Up is for one book. A selected group is several, as its books would
    /// be were they selected one by one; a book of an open group is looked up as ever.
    @Test func lookUpWithAGroupSelectedIsAsForItsBooks() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        h.model.clickItem(Self.seriesItem, modifiers: [])
        await h.model.settle()
        #expect(!h.model.canLookUp)
        h.model.beginLookup()
        #expect(h.model.lookup == nil)

        h.model.setGroup(Self.series, open: true)
        h.model.clickItem(.book(ids[1]), modifiers: [])
        await h.model.settle()
        #expect(h.model.canLookUp)
        h.model.beginLookup()
        #expect(h.model.lookup?.target == .book(ids[1]))
        h.model.cancelLookup()
    }

    // MARK: GS13

    /// GS13
    @Test func groupsAreClosedAtFirstAndOpenedByName() async throws {
        let h = try await grouped()
        #expect(h.model.openGroups.isEmpty)

        h.model.setGroup(Self.series, open: true)
        #expect(h.model.openGroups == [Self.series])
        h.model.setGroup(Self.series, open: true)
        #expect(h.model.openGroups == [Self.series])
        // No group has this name.
        h.model.setGroup("No such series", open: true)
        #expect(h.model.openGroups == [Self.series])

        // Not saved.
        #expect(h.relaunched().openGroups.isEmpty)

        h.model.setGroup(Self.series, open: false)
        #expect(h.model.openGroups.isEmpty)
    }

    /// GS13: a name is dropped when the list its group was seen in is grouped again
    /// and no longer has the group.
    @Test func theNameOfAGroupThatHasGoneIsDropped() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        h.model.setGroup(Self.series, open: true)

        // Kept while its group is still among the items, however they are ordered.
        h.model.sort = BookSort(key: .length, ascending: false)
        #expect(h.model.openGroups == [Self.series])

        // Two of its three books are removed: one book is not a group.
        h.model.requestRemove([ids[1], ids[2]])
        await h.model.confirmRemove(moveFilesToTrash: false)
        await h.model.settle()
        #expect(!h.model.items.contains { $0.id == Self.seriesItem })
        #expect(h.model.openGroups.isEmpty)
    }

    /// GS13: the open groups are kept while the list is not grouped: a search, a
    /// series' own view, the setting turned off.
    @Test func openGroupsSurviveWhileTheListIsNotGrouped() async throws {
        let h = try await grouped()
        h.model.setGroup(Self.series, open: true)

        h.model.searchText = "salt"
        await h.model.settle()
        #expect(!h.model.isGrouping)
        #expect(h.model.openGroups == [Self.series])
        h.model.searchText = ""
        await h.model.settle()
        #expect(h.model.isGrouping)
        #expect(h.model.openGroups == [Self.series])

        h.model.groupsBySeries = false
        #expect(h.model.openGroups == [Self.series])
        h.model.groupsBySeries = true
        #expect(h.model.openGroups == [Self.series])

        // The series' own view, and back: the group is as it was left, and selected.
        h.model.openSeries(Self.series)
        await h.model.settle()
        #expect(!h.model.isGrouping)
        #expect(h.model.openGroups == [Self.series])
        h.model.goBackFromSeries()
        await h.model.settle()
        #expect(h.model.sidebarSelection == .allBooks)
        #expect(h.model.openGroups == [Self.series])
        #expect(h.model.selection == Set(try seriesIds(h)))
        #expect(h.model.itemSelection == books(try seriesIds(h)).union([Self.seriesItem]))
        // GS20: all of it is selected, and its own row is where it starts.
        #expect(h.model.itemScrollTarget == Self.seriesItem)
    }

    /// GS13: a list that never had the group does not close it in the list that has.
    @Test func openGroupsSurviveAVisitToAnotherList() async throws {
        let h = try await grouped()
        h.model.setGroup(Self.series, open: true)
        h.model.sidebarSelection = .ebooks
        await h.model.settle()
        #expect(h.model.isGrouping)
        #expect(!h.model.items.contains { $0.id == Self.seriesItem })
        #expect(h.model.openGroups == [Self.series])
        // However often that list is made again.
        h.model.sort = BookSort(key: .author)
        #expect(h.model.openGroups == [Self.series])

        h.model.sidebarSelection = .allBooks
        await h.model.settle()
        #expect(h.model.items.contains { $0.id == Self.seriesItem })
        #expect(h.model.openGroups == [Self.series])
    }

    /// GS13: a group that went while the list was not grouped is dropped when the
    /// list is grouped again.
    @Test func aGroupThatWentDuringASearchIsDroppedAfterIt() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        h.model.setGroup(Self.series, open: true)
        h.model.searchText = "Tidewater"
        await h.model.settle()
        #expect(Set(h.model.rows.map(\.id)) == Set(ids))
        h.model.requestRemove([ids[1], ids[2]])
        await h.model.confirmRemove(moveFilesToTrash: false)
        await h.model.settle()
        #expect(h.model.rows.map(\.id) == [ids[0]])
        #expect(h.model.openGroups == [Self.series])

        h.model.searchText = ""
        await h.model.settle()
        #expect(h.model.isGrouping)
        #expect(h.model.openGroups.isEmpty)
    }

    // MARK: In the grid a group is one stack

    /// In the grid a group is drawn as one stack, open or not, so none of its books
    /// is selected without the rest: selecting one selects them all.
    @Test func inTheGridSelectingABookOfAGroupSelectsTheGroup() async throws {
        let h = try await groupedGrid()
        let ids = try seriesIds(h)
        let other = try h.id("Quiet Rivers")
        h.model.select([ids[1], other])
        #expect(h.model.selection == Set(ids + [other]))
        #expect(h.model.itemSelection.contains(Self.seriesItem))
        #expect(!h.model.isPartlySelected(try group(h)))
        await h.model.settle()
        #expect(h.bulkDraft?.books.count == 4)

        // A book that is in no group is selected alone, as ever.
        h.model.click(other, modifiers: [])
        #expect(h.model.selection == [other])
        await h.model.settle()
        #expect(h.draft?.title == "Quiet Rivers")
    }

    /// The same when the list becomes the grid.
    @Test func switchingToTheGridCompletesAPartlySelectedGroup() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        h.model.setGroup(Self.series, open: true)
        h.model.clickItem(.book(ids[2]), modifiers: [])
        await h.model.settle()
        #expect(h.model.selection == [ids[2]])

        h.model.viewMode = .grid
        #expect(h.model.selection == Set(ids))
        #expect(h.model.itemSelection.contains(Self.seriesItem))
        await h.model.settle()
        #expect(h.bulkDraft?.books.count == 3)

        // The list does not take it back.
        h.model.viewMode = .list
        #expect(h.model.selection == Set(ids))
    }

    /// The same when the items change: grouping is turned on over a selection.
    @Test func inTheGridTurningGroupingOnCompletesAPartlySelectedGroup() async throws {
        let h = try await Harness.demo()
        let chosen = try await h.select(["Salt Road", "Quiet Rivers"])
        #expect(h.model.selection == chosen)
        h.model.groupsBySeries = true
        #expect(h.model.selection == chosen.union(try seriesIds(h)))
        #expect(!h.model.isPartlySelected(try group(h)))
    }

    /// With unsaved edits nothing is selected and nothing is asked: the stack is
    /// drawn as selected in part, until the edits are discarded or saved.
    @Test func inTheGridUnsavedEditsLeaveAGroupPartlySelected() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        h.model.setGroup(Self.series, open: true)
        h.model.clickItem(.book(ids[0]), modifiers: [])
        await h.model.settle()
        h.model.updateDraft { $0.title = "Salt Roads" }

        h.model.viewMode = .grid
        #expect(h.model.prompt == nil)
        #expect(h.model.selection == [ids[0]])
        #expect(h.model.isPartlySelected(try group(h)))
        #expect(!h.model.itemSelection.contains(Self.seriesItem))
        #expect(h.draft?.title == "Salt Roads")
        // Nor when the items are made again.
        h.model.sort = BookSort(key: .author)
        #expect(h.model.prompt == nil)
        #expect(h.model.selection == [ids[0]])

        h.model.discardChanges()
        #expect(h.model.selection == Set(ids))
        #expect(!h.model.isPartlySelected(try group(h)))
        await h.model.settle()
        #expect(h.bulkDraft?.books.count == 3)
    }

    /// The same after a save.
    @Test func inTheGridASaveCompletesThePartlySelectedGroup() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        h.model.setGroup(Self.series, open: true)
        h.model.clickItem(.book(ids[0]), modifiers: [])
        await h.model.settle()
        h.model.updateDraft { $0.title = "Salt Roads" }
        h.model.viewMode = .grid
        #expect(h.model.selection == [ids[0]])

        await h.model.save()
        await h.model.settle()
        #expect(try h.store().book(id: ids[0])?.title == "Salt Roads")
        #expect(!h.model.hasUnsavedChanges)
        #expect(h.model.selection == Set(ids))
        #expect(h.bulkDraft?.books.count == 3)
    }

    /// GS18: in the grid a group is one cell however many columns there are, and
    /// whether or not the list would show it open.
    @Test func inTheGridArrowKeysTakeAGroupAsOneCellInOneColumn() async throws {
        let h = try await groupedGrid()
        let ids = try seriesIds(h)
        let items = h.model.items.map(\.id)
        let at = try groupIndex(h)
        h.model.setGroup(Self.series, open: true)

        h.model.clickItem(items[at - 1], modifiers: [])
        #expect(h.model.moveItemSelection(.down, columns: 1) == Self.seriesItem)
        #expect(h.model.selection == Set(ids))
        #expect(h.model.moveItemSelection(.down, columns: 1) == items[at + 1])
        #expect(h.model.moveItemSelection(.up, columns: 1) == Self.seriesItem)
        #expect(h.model.moveItemSelection(.up, columns: 1) == items[at - 1])
    }

    /// GS20: in the grid the group is what is scrolled to, open or not.
    @Test func inTheGridTheScrollTargetIsTheGroup() async throws {
        let h = try await groupedGrid()
        h.model.setGroup(Self.series, open: true)
        h.model.clickItem(Self.seriesItem, modifiers: [])
        #expect(h.model.itemScrollTarget == Self.seriesItem)
    }

    // MARK: The list's column headers, over items

    /// K6: a click on a column header of the table of items becomes the sort, as it
    /// does in a table of books.
    @Test func theItemTablesSortOrderIsTheModelsSort() async throws {
        let h = try await grouped()
        #expect(h.model.itemTableSortOrder == BookSort(key: .title, ascending: true).itemSortOrder)

        h.model.itemTableSortOrder =
            BookSort(key: .author, ascending: false).itemSortOrder + BookSort(key: .title).itemSortOrder
        #expect(h.model.sort == BookSort(key: .author, ascending: false))
        #expect(h.model.itemTableSortOrder == BookSort(key: .author, ascending: false).itemSortOrder)
        #expect(h.model.tableSortOrder == BookSort(key: .author, ascending: false).tableSortOrder)
        #expect(h.model.rows == BookSort(key: .author, ascending: false).sorted(h.model.rows))
        #expect(
            h.model.items
                == SeriesGrouping.items(
                    from: h.model.rows, sort: BookSort(key: .author, ascending: false), grouped: true))
        #expect(h.relaunched().sort == BookSort(key: .author, ascending: false))

        // An order that is not one of the sorts changes nothing.
        h.model.itemTableSortOrder = []
        #expect(h.model.sort == BookSort(key: .author, ascending: false))
    }

    // MARK: GS13a

    /// GS13a: closing a group some of whose books are selected selects them all.
    @Test func closingAPartlySelectedGroupSelectsAllItsBooks() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        let other = try h.id("Quiet Rivers")
        h.model.setGroup(Self.series, open: true)
        h.model.clickItem(.book(ids[1]), modifiers: [])
        h.model.clickItem(.book(other), modifiers: .command)
        #expect(h.model.selection == [ids[1], other])
        #expect(h.model.isPartlySelected(try group(h)))

        h.model.setGroup(Self.series, open: false)
        #expect(h.model.openGroups.isEmpty)
        #expect(h.model.selection == Set(ids + [other]))
        #expect(h.model.itemSelection == [Self.seriesItem, .book(other)])
        #expect(!h.model.isPartlySelected(try group(h)))
        await h.model.settle()
        #expect(h.bulkDraft?.books.count == 4)
    }

    /// GS13a: a group none or all of whose books are selected simply closes.
    @Test func closingAGroupThatIsNotPartlySelectedChangesNoSelection() async throws {
        let h = try await grouped()
        let other = try await h.select("Quiet Rivers")
        h.model.setGroup(Self.series, open: true)
        h.model.setGroup(Self.series, open: false)
        #expect(h.model.openGroups.isEmpty)
        #expect(h.model.selection == [other])

        h.model.setGroup(Self.series, open: true)
        h.model.clickItem(Self.seriesItem, modifiers: [])
        h.model.setGroup(Self.series, open: false)
        #expect(h.model.openGroups.isEmpty)
        #expect(h.model.selection == Set(try seriesIds(h)))
    }

    /// GS13a: selecting the rest is refused while there are unsaved edits, and then
    /// the group stays open: the selected book is never hidden.
    @Test func aGroupStaysOpenWhenSelectingTheRestIsRefused() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        h.model.setGroup(Self.series, open: true)
        h.model.clickItem(.book(ids[0]), modifiers: [])
        await h.model.settle()
        h.model.updateDraft { $0.title = "Salt Roads" }

        h.model.setGroup(Self.series, open: false)
        #expect(h.model.prompt == .unsavedChanges)
        #expect(h.model.openGroups == [Self.series])
        #expect(h.model.selection == [ids[0]])
        #expect(h.model.itemSelection == [.book(ids[0])])

        await h.model.resolveUnsaved(.cancel)
        #expect(h.model.openGroups == [Self.series])
        #expect(h.model.selection == [ids[0]])
        #expect(h.draft?.title == "Salt Roads")

        // Asked again, and answered Discard: the rest are selected, and it can be closed.
        h.model.setGroup(Self.series, open: false)
        #expect(h.model.prompt == .unsavedChanges)
        await h.model.resolveUnsaved(.discard)
        #expect(h.model.selection == Set(ids))
        #expect(!h.model.hasUnsavedChanges)
        h.model.setGroup(Self.series, open: false)
        #expect(h.model.openGroups.isEmpty)
        #expect(h.model.itemSelection == [Self.seriesItem])
    }

    /// GS13a: turning grouping on over a selection that is part of a series opens its group.
    @Test func turningGroupingOnOpensAPartlySelectedGroup() async throws {
        let h = try await Harness.demo()
        h.model.viewMode = .list
        let ids = try await h.select(["Salt Road", "Quiet Rivers"])
        h.model.groupsBySeries = true
        #expect(h.model.openGroups == [Self.series])
        #expect(h.model.selection == ids)
        #expect(h.model.itemSelection == Set(ids.map(ItemID.book)))
    }

    /// GS13a: so does a reload that leaves a closed group with only some of its books selected.
    @Test func aReloadOpensAGroupThatBecomesPartlySelected() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        await h.model.setReadStatus(.unread, for: Set(ids))
        await h.model.setReadStatus(.finished, for: [ids[0]])

        // Among the unread books the group is of two, both selected, and closed.
        h.model.sidebarSelection = .unread
        await h.model.settle()
        #expect(try group(h).books.map(\.id) == [ids[1], ids[2]])
        h.model.clickItem(Self.seriesItem, modifiers: [])
        await h.model.settle()
        #expect(h.model.openGroups.isEmpty)
        #expect(h.model.itemSelection == [Self.seriesItem])

        // Among all the books it is of three, of which two are selected.
        h.model.sidebarSelection = .allBooks
        await h.model.settle()
        #expect(h.model.selection == [ids[1], ids[2]])
        #expect(h.model.openGroups == [Self.series])
        #expect(h.model.itemSelection == [.book(ids[1]), .book(ids[2])])
    }

    /// GS13a: so does a selection made by anything that names books, not items.
    @Test func selectingABookOfAClosedGroupOpensIt() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        h.model.select([ids[2]])
        #expect(h.model.openGroups == [Self.series])
        #expect(h.model.itemSelection == [.book(ids[2])])

        // A sort changes the items, not which groups are open.
        h.model.sort = BookSort(key: .dateAdded)
        #expect(h.model.openGroups == [Self.series])
    }

    // MARK: GS14

    /// GS14
    @Test func theItemSelectionNamesBooksAndWholeGroups() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        let other = try h.id("Quiet Rivers")
        #expect(h.model.itemSelection.isEmpty)

        // A book that is in no group.
        h.model.select([other])
        #expect(h.model.itemSelection == [.book(other)])

        // A closed group, all of whose books are selected: the group, and not its books.
        h.model.select(Set(ids + [other]))
        #expect(h.model.itemSelection == [Self.seriesItem, .book(other)])

        // Open: the group and each of its books.
        h.model.setGroup(Self.series, open: true)
        #expect(h.model.itemSelection == books(ids + [other]).union([Self.seriesItem]))

        // Open, and only some selected: those books.
        h.model.select([ids[0], ids[2]])
        #expect(h.model.itemSelection == books([ids[0], ids[2]]))
    }

    /// GS14: with grouping off the item selection is the selection.
    @Test func ungroupedTheItemSelectionIsTheSelection() async throws {
        let h = try await Harness.demo()
        let ids = try await h.select(["Salt Road", "The Drowned Bell", "Harbour of Glass", "Quiet Rivers"])
        #expect(h.model.itemSelection == Set(ids.map(ItemID.book)))
    }

    /// GS14: whatever is done, no selected book is out of sight: each is named itself,
    /// or its group is.
    @Test func noSelectedBookIsEverHidden() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        let other = try h.id("Quiet Rivers")

        func check(_ what: Comment) throws {
            let named = h.model.itemSelection
            let saga = try group(h)
            let open = h.model.openGroups.contains(Self.series)
            for id in h.model.selection {
                let inGroup = saga.books.contains { $0.id == id }
                if inGroup && !open {
                    #expect(named.contains(Self.seriesItem), what)
                } else {
                    #expect(named.contains(.book(id)), what)
                }
            }
            if named.contains(Self.seriesItem) {
                #expect(Set(ids).isSubset(of: h.model.selection), what)
            }
        }

        h.model.select([ids[0]])
        try check("a book of a closed group selected")
        h.model.click(ids[2], modifiers: .command)
        try check("another added")
        h.model.setGroup(Self.series, open: false)
        try check("closed")
        h.model.click(ids[1], modifiers: .command)
        try check("one taken away by a click on the book")
        h.model.selectAll()
        h.model.setGroup(Self.series, open: false)
        try check("everything selected")
        h.model.sort = BookSort(key: .author, ascending: false)
        try check("sorted")
        h.model.selectItems([.book(other), .book(ids[1])])
        try check("items selected")
        _ = h.model.moveItemSelection(.right, columns: 3)
        try check("moved")
        h.model.groupsBySeries = false
        h.model.select([ids[1], other])
        h.model.groupsBySeries = true
        try check("grouped again")
    }

    // MARK: GS15

    /// GS15
    @Test func selectingItemsSelectsBooksAndTheBooksOfGroups() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        let other = try h.id("Quiet Rivers")

        h.model.selectItems([Self.seriesItem])
        #expect(h.model.selection == Set(ids))
        await h.model.settle()
        #expect(h.bulkDraft?.books.count == 3)

        h.model.selectItems([Self.seriesItem, .book(other)])
        #expect(h.model.selection == Set(ids + [other]))

        // The group is deselected: its books go with it.
        h.model.selectItems([.book(other)])
        #expect(h.model.selection == [other])

        h.model.selectItems([])
        #expect(h.model.selection.isEmpty)
    }

    /// GS15: a group that is deselected keeps the books that are named themselves.
    @Test func deselectingAGroupKeepsTheBooksThatAreNamed() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        h.model.setGroup(Self.series, open: true)
        h.model.selectItems([Self.seriesItem])
        #expect(h.model.itemSelection == books(ids).union([Self.seriesItem]))

        // A click on one of its books: the table names that book alone.
        h.model.selectItems([.book(ids[1])])
        #expect(h.model.selection == [ids[1]])
    }

    /// GS15: in an open group that is selected whole, a book can be taken out of the
    /// selection, and the group's own row can.
    @Test func booksAndTheGroupRowCanBeDeselectedInAnOpenGroup() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        let other = try h.id("Quiet Rivers")
        h.model.setGroup(Self.series, open: true)
        h.model.selectItems([Self.seriesItem, .book(other)])
        #expect(h.model.itemSelection == books(ids + [other]).union([Self.seriesItem]))

        // Command-click on one of its books: the table leaves that book out.
        h.model.selectItems(books([ids[0], ids[2], other]).union([Self.seriesItem]))
        #expect(h.model.selection == [ids[0], ids[2], other])
        #expect(h.model.itemSelection == books([ids[0], ids[2], other]))

        // Command-click on the group's row, all selected again: the table leaves the row out.
        h.model.selectItems([Self.seriesItem, .book(other)])
        #expect(h.model.selection == Set(ids + [other]))
        h.model.selectItems(books(ids + [other]))
        #expect(h.model.selection == [other])

        // A click on the group's row when all are selected names the row alone: all stay.
        h.model.selectItems([Self.seriesItem])
        h.model.selectItems([Self.seriesItem])
        #expect(h.model.selection == Set(ids))
    }

    /// GS15: the unsaved-edits rules apply as they do to `select`.
    @Test func selectingItemsAsksAboutUnsavedChanges() async throws {
        let h = try await grouped()
        let other = try await h.edit("Quiet Rivers", newTitle: "Loud Rivers")
        h.model.selectItems([Self.seriesItem])
        #expect(h.model.prompt == .unsavedChanges)
        #expect(h.model.selection == [other])

        await h.model.resolveUnsaved(.discard)
        #expect(h.model.selection == Set(try seriesIds(h)))
        #expect(try h.book(other).title == "Quiet Rivers")
    }

    /// GS15: with grouping off it is `select`.
    @Test func ungroupedSelectingItemsIsSelectingBooks() async throws {
        let h = try await Harness.demo()
        let ids = try h.ids(["Salt Road", "Quiet Rivers"])
        h.model.selectItems(Set(ids.map(ItemID.book)))
        #expect(h.model.selection == ids)
        // A series is no item of a list that is not grouped.
        h.model.selectItems([Self.seriesItem])
        #expect(h.model.selection.isEmpty)
    }

    // MARK: GS16

    /// GS16
    @Test func aClickOnABookIsAClickOnABook() async throws {
        let h = try await grouped()
        let first = try bookId(h, at: 0)
        let third = try bookId(h, at: 2)
        h.model.clickItem(.book(first), modifiers: [])
        #expect(h.model.selection == [first])
        h.model.clickItem(.book(third), modifiers: .command)
        #expect(h.model.selection == [first, third])
        h.model.clickItem(.book(first), modifiers: .command)
        #expect(h.model.selection == [third])
        await h.model.settle()
        #expect(h.detail?.row.id == third)
    }

    /// GS16
    @Test func aClickOnAGroupSelectsExactlyItsBooks() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        try await h.select("Quiet Rivers")
        h.model.clickItem(Self.seriesItem, modifiers: [])
        #expect(h.model.selection == Set(ids))
        #expect(h.model.itemSelection == [Self.seriesItem])
        await h.model.settle()
        #expect(h.bulkDraft?.books.count == 3)
    }

    /// GS16
    @Test func aCommandClickOnAGroupTogglesAllItsBooks() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        let other = try await h.select("Quiet Rivers")

        h.model.clickItem(Self.seriesItem, modifiers: .command)
        #expect(h.model.selection == Set(ids + [other]))
        h.model.clickItem(Self.seriesItem, modifiers: .command)
        #expect(h.model.selection == [other])

        // Some selected: on, not off.
        h.model.setGroup(Self.series, open: true)
        h.model.clickItem(.book(ids[1]), modifiers: .command)
        #expect(h.model.selection == [other, ids[1]])
        h.model.clickItem(Self.seriesItem, modifiers: .command)
        #expect(h.model.selection == Set(ids + [other]))
    }

    /// GS16: a shift-click selects the items between, in the order of the items, a
    /// group standing for all its books.
    @Test func aShiftClickSelectsTheRangeOfItems() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        let at = try groupIndex(h)
        #expect(at >= 2 && at + 2 < h.model.items.count)
        let before = [try bookId(h, at: at - 2), try bookId(h, at: at - 1)]
        let after = [try bookId(h, at: at + 1), try bookId(h, at: at + 2)]

        // From a book to the group.
        h.model.clickItem(.book(before[0]), modifiers: [])
        h.model.clickItem(Self.seriesItem, modifiers: .shift)
        #expect(h.model.selection == Set(before + ids))
        // The anchor stays: on to a book past the group, and back.
        h.model.clickItem(.book(after[0]), modifiers: .shift)
        #expect(h.model.selection == Set(before + ids + [after[0]]))
        h.model.clickItem(.book(before[1]), modifiers: .shift)
        #expect(h.model.selection == Set(before))

        // From the group to a book.
        h.model.clickItem(Self.seriesItem, modifiers: [])
        h.model.clickItem(.book(after[1]), modifiers: .shift)
        #expect(h.model.selection == Set(ids + after))
        h.model.clickItem(.book(before[1]), modifiers: .shift)
        #expect(h.model.selection == Set(ids + [before[1]]))

        // With Command as well the range is added.
        h.model.clickItem(.book(after[1]), modifiers: [])
        h.model.clickItem(.book(before[0]), modifiers: .command)
        h.model.clickItem(Self.seriesItem, modifiers: [.shift, .command])
        #expect(h.model.selection == Set(before + ids + [after[1]]))
    }

    /// GS16: an open group lies before its own books.
    @Test func aShiftClickCountsAnOpenGroupBeforeItsBooks() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        let at = try groupIndex(h)
        let before = try bookId(h, at: at - 1)
        let after = try bookId(h, at: at + 1)
        h.model.setGroup(Self.series, open: true)

        // From its second book down to the book after it: the group's row is not between.
        h.model.clickItem(.book(ids[1]), modifiers: [])
        h.model.clickItem(.book(after), modifiers: .shift)
        #expect(h.model.selection == [ids[1], ids[2], after])
        // And up to the book before it: the row is between, and stands for all its books.
        h.model.clickItem(.book(before), modifiers: .shift)
        #expect(h.model.selection == Set(ids + [before]))

        // With no anchor a shift-click is a plain click.
        h.model.select([])
        h.model.clickItem(Self.seriesItem, modifiers: .shift)
        #expect(h.model.selection == Set(ids))
    }

    /// GS16: with grouping off a click on an item is a click on the book.
    @Test func ungroupedAClickOnAnItemIsAClickOnTheBook() async throws {
        let h = try await Harness.demo()
        let ids = h.model.rows.map(\.id)
        h.model.clickItem(.book(ids[2]), modifiers: [])
        h.model.clickItem(.book(ids[5]), modifiers: .shift)
        #expect(h.model.selection == Set(ids[2...5]))
        h.model.clickItem(.book(ids[8]), modifiers: .command)
        #expect(h.model.selection == Set(ids[2...5] + [ids[8]]))
        // The Command-click moved the anchor: the range added runs from there.
        h.model.clickItem(.book(ids[0]), modifiers: [.shift, .command])
        #expect(h.model.selection == Set(ids[0...8]))
        // No group to click.
        h.model.clickItem(Self.seriesItem, modifiers: [])
        #expect(h.model.selection == Set(ids[0...8]))

        // Each click is what a click on the book would have been.
        let other = try await Harness.demo()
        other.model.click(ids[2], modifiers: [])
        other.model.click(ids[5], modifiers: .shift)
        other.model.click(ids[8], modifiers: .command)
        other.model.click(ids[0], modifiers: [.shift, .command])
        #expect(other.model.selection == h.model.selection)
    }

    /// GS16: the unsaved-edits rules apply to a click on a group.
    @Test func aClickOnAGroupAsksAboutUnsavedChanges() async throws {
        let h = try await grouped()
        let other = try await h.edit("Quiet Rivers", newTitle: "Loud Rivers")
        h.model.clickItem(Self.seriesItem, modifiers: [])
        #expect(h.model.prompt == .unsavedChanges)
        #expect(h.model.selection == [other])
        await h.model.resolveUnsaved(.cancel)
        #expect(h.model.selection == [other])
        #expect(h.draft?.title == "Loud Rivers")
    }

    // MARK: GS17

    /// GS17
    @Test func openingOneBookOpensItAndOneGroupOpensItsSeries() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        let one = try h.id("Quiet Rivers")
        let two = try h.id("Night Train to Vostok")

        // Several things: nothing, as today.
        h.model.openItems([.book(one), .book(two)])
        h.model.openItems([])
        h.model.openItems([Self.seriesItem, .book(one)])
        await h.model.settle()
        #expect(h.opener.opened.isEmpty)
        #expect(h.model.sidebarSelection == .allBooks)

        h.model.openItems([.book(one)])
        await h.model.settle()
        #expect(h.opener.opened == (try h.fileURLs(one)))
        #expect(h.model.sidebarSelection == .allBooks)

        h.model.openItems([Self.seriesItem])
        await h.model.settle()
        #expect(h.model.sidebarSelection == .browse(.series, Self.series))
        #expect(h.model.rows.map(\.id) == ids)
        #expect(h.opener.opened == (try h.fileURLs(one)))
    }

    /// GS17: an open group that is selected whole is named with its books, and is
    /// still exactly one group.
    @Test func openingAGroupNamedWithItsOwnBooksOpensItsSeries() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        h.model.setGroup(Self.series, open: true)
        h.model.clickItem(Self.seriesItem, modifiers: [])
        h.model.openItems(h.model.itemSelection)
        await h.model.settle()
        #expect(h.model.sidebarSelection == .browse(.series, Self.series))
        #expect(h.model.rows.map(\.id) == ids)
        #expect(h.opener.opened.isEmpty)
    }

    // MARK: GS18

    /// GS18: in the grid a group is one cell.
    @Test func arrowKeysMoveAmongItemsInTheGrid() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        let items = h.model.items.map(\.id)
        let at = try groupIndex(h)
        // Open or not, it is one cell of the grid.
        h.model.setGroup(Self.series, open: true)

        #expect(h.model.moveItemSelection(.right, columns: 4) == items[0])
        #expect(h.model.itemSelection == [items[0]])
        #expect(h.model.moveItemSelection(.down, columns: 4) == items[4])
        #expect(h.model.moveItemSelection(.up, columns: 4) == items[0])

        h.model.clickItem(items[at - 1], modifiers: [])
        #expect(h.model.moveItemSelection(.right, columns: 4) == Self.seriesItem)
        #expect(h.model.selection == Set(ids))
        await h.model.settle()
        #expect(h.bulkDraft?.books.count == 3)
        #expect(h.model.moveItemSelection(.right, columns: 4) == items[at + 1])
        #expect(h.model.selection.count == 1)
        #expect(h.model.moveItemSelection(.left, columns: 4) == Self.seriesItem)
        #expect(h.model.moveItemSelection(.up, columns: 4) == items[at - 4])
        #expect(h.model.moveItemSelection(.down, columns: 4) == Self.seriesItem)
        #expect(h.model.selection == Set(ids))
        // A shift-click afterwards extends from the group the keys arrived at.
        h.model.clickItem(items[at + 2], modifiers: .shift)
        #expect(h.model.selection.count == 5)
    }

    /// GS18: in the list an open group's books are steps between the group and the next item.
    @Test func arrowKeysStepThroughAnOpenGroupInTheList() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        let items = h.model.items.map(\.id)
        let at = try groupIndex(h)

        // Closed: from the item before, to the group, to the item after.
        h.model.clickItem(items[at - 1], modifiers: [])
        #expect(h.model.moveItemSelection(.down, columns: 1) == Self.seriesItem)
        #expect(h.model.moveItemSelection(.down, columns: 1) == items[at + 1])
        #expect(h.model.moveItemSelection(.up, columns: 1) == Self.seriesItem)

        h.model.setGroup(Self.series, open: true)
        #expect(h.model.moveItemSelection(.down, columns: 1) == .book(ids[0]))
        #expect(h.model.selection == [ids[0]])
        #expect(h.model.moveItemSelection(.down, columns: 1) == .book(ids[1]))
        #expect(h.model.moveItemSelection(.down, columns: 1) == .book(ids[2]))
        #expect(h.model.moveItemSelection(.down, columns: 1) == items[at + 1])
        #expect(h.model.moveItemSelection(.up, columns: 1) == .book(ids[2]))
        #expect(h.model.moveItemSelection(.up, columns: 1) == .book(ids[1]))
        #expect(h.model.moveItemSelection(.up, columns: 1) == .book(ids[0]))
        #expect(h.model.moveItemSelection(.up, columns: 1) == Self.seriesItem)
        #expect(h.model.selection == Set(ids))
        #expect(h.model.moveItemSelection(.up, columns: 1) == items[at - 1])
    }

    /// GS18: nothing to move among, and unsaved changes.
    @Test func arrowKeysAmongItemsAskAboutUnsavedChanges() async throws {
        let empty = try await Harness.empty()
        empty.model.groupsBySeries = true
        #expect(empty.model.moveItemSelection(.down, columns: 3) == nil)

        let h = try await grouped()
        let at = try groupIndex(h)
        let before = try bookId(h, at: at - 1)
        h.model.clickItem(.book(before), modifiers: [])
        await h.model.settle()
        h.model.updateDraft { $0.title = "Changed" }
        #expect(h.model.moveItemSelection(.right, columns: 4) == nil)
        #expect(h.model.prompt == .unsavedChanges)
        #expect(h.model.selection == [before])
    }

    /// GS18: with grouping off it is `moveSelection`.
    @Test func ungroupedArrowKeysMoveAmongTheBooks() async throws {
        let h = try await Harness.demo()
        let ids = h.model.rows.map(\.id)
        #expect(h.model.moveItemSelection(.right, columns: 4) == .book(ids[0]))
        #expect(h.model.moveItemSelection(.down, columns: 4) == .book(ids[4]))
        #expect(h.model.moveItemSelection(.right, columns: 4) == .book(ids[5]))
        #expect(h.model.moveItemSelection(.up, columns: 4) == .book(ids[1]))
        #expect(h.model.selection == [ids[1]])
    }

    // MARK: GS19

    /// GS19
    @Test func openingASeriesAndGoingBack() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        #expect(h.model.seriesBackTitle == nil)
        h.model.clickItem(Self.seriesItem, modifiers: [])
        await h.model.settle()

        h.model.openSeries(Self.series)
        await h.model.settle()
        #expect(h.model.sidebarSelection == .browse(.series, Self.series))
        #expect(h.model.rows.map(\.id) == ids)
        #expect(h.model.seriesHeader != nil)
        #expect(h.model.seriesBackTitle == "All Books")
        #expect(h.model.prompt == nil)

        // Something else is selected there meanwhile.
        h.model.click(ids[1], modifiers: [])
        await h.model.settle()

        h.model.goBackFromSeries()
        await h.model.settle()
        #expect(h.model.sidebarSelection == .allBooks)
        #expect(h.model.searchText == "")
        #expect(h.model.rows.count == 12)
        #expect(h.model.seriesBackTitle == nil)
        #expect(h.model.selection == Set(ids))
        // GS13: closed, as it was when its series was opened.
        #expect(h.model.openGroups.isEmpty)
        #expect(h.model.itemSelection == [Self.seriesItem])
        #expect(h.model.itemScrollTarget == Self.seriesItem)
        #expect(h.bulkDraft?.books.count == 3)

        // There is nothing to go back from now.
        h.model.goBackFromSeries()
        await h.model.settle()
        #expect(h.model.sidebarSelection == .allBooks)
    }

    /// GS19: the list gone back to is the one that was shown, by its own name.
    @Test func goingBackReturnsToTheListThatWasShown() async throws {
        let h = try await grouped()
        h.model.sidebarSelection = .audiobooks
        await h.model.settle()
        let shown = h.model.rows.map(\.id)

        h.model.openSeries(Self.series)
        await h.model.settle()
        #expect(h.model.seriesBackTitle == "Audiobooks")
        // A search in the series is still the series.
        h.model.searchText = "salt"
        await h.model.settle()
        #expect(h.model.rows.count == 1)
        #expect(h.model.seriesBackTitle == "Audiobooks")

        h.model.goBackFromSeries()
        await h.model.settle()
        #expect(h.model.sidebarSelection == .audiobooks)
        #expect(h.model.searchText == "")
        #expect(h.model.rows.map(\.id) == shown)
        #expect(h.model.itemSelection == [Self.seriesItem])
    }

    /// GS19: the search text is remembered too. A search shows a flat list: the
    /// series' books that are among the results are what is selected.
    @Test func goingBackPutsTheSearchTextBack() async throws {
        let h = try await grouped()
        h.model.searchText = "salt"
        await h.model.settle()
        #expect(h.titles == ["Salt Road"])

        h.model.openSeries(Self.series)
        await h.model.settle()
        #expect(h.model.searchText == "")
        #expect(h.model.rows.count == 3)
        #expect(h.model.seriesBackTitle == "All Books")

        h.model.goBackFromSeries()
        await h.model.settle()
        #expect(h.model.sidebarSelection == .allBooks)
        #expect(h.model.searchText == "salt")
        #expect(h.titles == ["Salt Road"])
        #expect(h.model.selection == [try h.id("Salt Road")])
    }

    /// GS19: there is no way back once the owner has chosen something in the sidebar
    /// themselves, the same series included.
    @Test func thereIsNoWayBackAfterTheOwnerChoosesInTheSidebar() async throws {
        let h = try await grouped()
        h.model.openSeries(Self.series)
        await h.model.settle()
        #expect(h.model.seriesBackTitle == "All Books")

        h.model.sidebarSelection = .unread
        await h.model.settle()
        #expect(h.model.seriesBackTitle == nil)

        h.model.sidebarSelection = .browse(.series, Self.series)
        await h.model.settle()
        #expect(h.model.seriesBackTitle == nil)
        h.model.goBackFromSeries()
        await h.model.settle()
        #expect(h.model.sidebarSelection == .browse(.series, Self.series))
    }

    /// GS19: opening a series asks about unsaved edits as choosing it in the sidebar does.
    @Test func openingASeriesAsksAboutUnsavedChanges() async throws {
        let h = try await grouped()
        let other = try await h.edit("Quiet Rivers", newTitle: "Loud Rivers")

        h.model.openSeries(Self.series)
        await h.model.settle()
        #expect(h.model.prompt == .unsavedChanges)
        #expect(h.model.rows.count == 12)
        await h.model.resolveUnsaved(.cancel)
        #expect(h.model.sidebarSelection == .allBooks)
        #expect(h.model.seriesBackTitle == nil)
        #expect(h.model.selection == [other])
        #expect(h.draft?.title == "Loud Rivers")

        // Chosen by hand after that, the series has no way back.
        h.model.sidebarSelection = .browse(.series, Self.series)
        await h.model.settle()
        #expect(h.model.prompt == .unsavedChanges)
        await h.model.resolveUnsaved(.cancel)
        #expect(h.model.seriesBackTitle == nil)

        h.model.openSeries(Self.series)
        await h.model.settle()
        #expect(h.model.prompt == .unsavedChanges)
        await h.model.resolveUnsaved(.discard)
        #expect(h.model.sidebarSelection == .browse(.series, Self.series))
        #expect(h.model.rows.count == 3)
        #expect(h.model.seriesBackTitle == "All Books")
        #expect(try h.book(other).title == "Quiet Rivers")
    }

    /// GS19: going back asks nothing when the edited book is in the list gone back to,
    /// as choosing that list in the sidebar asks nothing; the edits and the selection
    /// are kept as they are.
    @Test func goingBackKeepsUnsavedEditsOfABookThatIsStillShown() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        h.model.openSeries(Self.series)
        await h.model.settle()
        h.model.click(ids[1], modifiers: [])
        await h.model.settle()
        h.model.updateDraft { $0.title = "The Drowned Bells" }

        h.model.goBackFromSeries()
        await h.model.settle()
        #expect(h.model.prompt == nil)
        #expect(h.model.sidebarSelection == .allBooks)
        #expect(h.model.selection == [ids[1]])
        #expect(h.draft?.title == "The Drowned Bells")
        // GS13a: the edited book is not hidden in a closed group.
        #expect(h.model.openGroups == [Self.series])
        #expect(h.model.itemSelection == [.book(ids[1])])
        #expect(h.model.itemScrollTarget == .book(ids[1]))
    }

    /// GS19: going back asks when it would take the edited book out of sight, and
    /// Cancel leaves the series, and the way back, as they were.
    @Test func goingBackAsksAboutUnsavedChangesAsTheSidebarDoes() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        h.model.sidebarSelection = .ebooks
        await h.model.settle()
        #expect(!h.model.rows.contains { ids.contains($0.id) })

        h.model.openSeries(Self.series)
        await h.model.settle()
        #expect(h.model.seriesBackTitle == "Ebooks")
        h.model.click(ids[0], modifiers: [])
        await h.model.settle()
        h.model.updateDraft { $0.title = "Salt Roads" }

        h.model.goBackFromSeries()
        await h.model.settle()
        #expect(h.model.prompt == .unsavedChanges)
        await h.model.resolveUnsaved(.cancel)
        #expect(h.model.sidebarSelection == .browse(.series, Self.series))
        #expect(h.model.seriesBackTitle == "Ebooks")
        #expect(h.model.selection == [ids[0]])
        #expect(h.draft?.title == "Salt Roads")

        h.model.goBackFromSeries()
        await h.model.settle()
        #expect(h.model.prompt == .unsavedChanges)
        await h.model.resolveUnsaved(.discard)
        #expect(h.model.sidebarSelection == .ebooks)
        #expect(h.model.seriesBackTitle == nil)
        #expect(h.model.selection.isEmpty)
        #expect(try h.book(ids[0]).title == "Salt Road")
    }

    /// GS19: answered Save, the edits are saved and the way back is taken, to the
    /// series' books as it is taken at any other time.
    @Test func goingBackAfterSavingSelectsTheSeriesBooks() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        h.model.searchText = "Drowned"
        await h.model.settle()
        #expect(h.titles == ["The Drowned Bell"])
        h.model.openSeries(Self.series)
        await h.model.settle()
        h.model.click(ids[0], modifiers: [])
        await h.model.settle()
        h.model.updateDraft { $0.title = "Salt Roads" }

        h.model.goBackFromSeries()
        await h.model.settle()
        #expect(h.model.prompt == .unsavedChanges)
        await h.model.resolveUnsaved(.save)
        await h.model.settle()
        #expect(try h.book(ids[0]).title == "Salt Roads")
        #expect(h.model.sidebarSelection == .allBooks)
        #expect(h.model.searchText == "Drowned")
        #expect(h.model.seriesBackTitle == nil)
        #expect(h.model.selection == [ids[1]])
        #expect(!h.model.hasUnsavedChanges)
    }

    // MARK: GS20

    /// GS20
    @Test func theScrollTargetIsTheGroupWhenItsBookIsOutOfSight() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        #expect(h.model.itemScrollTarget == nil)

        let other = try await h.select("Quiet Rivers")
        #expect(h.model.itemScrollTarget == .book(other))

        h.model.clickItem(Self.seriesItem, modifiers: [])
        #expect(h.model.itemScrollTarget == Self.seriesItem)

        // Open, and all of it selected: its own row is where it starts.
        h.model.setGroup(Self.series, open: true)
        #expect(h.model.itemScrollTarget == Self.seriesItem)
        // Open, and one of its books selected: the book, which is in sight.
        h.model.clickItem(.book(ids[1]), modifiers: [])
        #expect(h.model.itemScrollTarget == .book(ids[1]))

        h.model.groupsBySeries = false
        #expect(h.model.itemScrollTarget == .book(ids[1]))
    }

    // MARK: GS21

    /// GS21
    @Test func aGroupIsMarkedEditedWhenAnyOfItsBooksIs() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        try await makeSeries(h, "Pair", ["Quiet Rivers", "Night Train to Vostok"])
        #expect(!h.model.editedMark(for: try group(h)))

        h.model.setGroup(Self.series, open: true)
        h.model.clickItem(.book(ids[2]), modifiers: [])
        await h.model.settle()
        h.model.updateDraft { $0.title = "Harbour of Glasses" }
        #expect(h.model.editedMark(for: try group(h)))
        #expect(!h.model.editedMark(for: try group(h, "Pair")))

        h.model.discardChanges()
        #expect(!h.model.editedMark(for: try group(h)))

        h.model.clickItem(.series("Pair"), modifiers: [])
        await h.model.settle()
        h.model.updateBulkDraft { $0.values[.genre] = "Travel" }
        #expect(h.model.editedMark(for: try group(h, "Pair")))
        #expect(!h.model.editedMark(for: try group(h)))
    }

    /// Gives these books a series of their own, through the model, and selects nothing.
    private func makeSeries(_ h: Harness, _ name: String, _ titles: [String]) async throws {
        try await h.select(titles)
        h.model.updateBulkDraft { $0.values[.series] = name }
        await h.model.save()
        h.model.selectItems([])
        await h.model.settle()
        #expect(try group(h, name).books.count == titles.count)
    }

    // MARK: GS22

    /// GS22
    @Test func aContextClickOnAGroupSelectsItsBooks() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        let other = try await h.select("Quiet Rivers")
        #expect(h.model.contextTarget(forItem: Self.seriesItem) == Set(ids))

        h.model.contextClickItem(Self.seriesItem)
        #expect(h.model.selection == Set(ids))
        await h.model.settle()
        #expect(h.bulkDraft?.books.count == 3)

        // Selected whole, with another book: the selection is what the menu is for.
        h.model.clickItem(.book(other), modifiers: .command)
        h.model.contextClickItem(Self.seriesItem)
        #expect(h.model.selection == Set(ids + [other]))
        #expect(h.model.contextTarget(forItem: Self.seriesItem) == Set(ids + [other]))

        // A book: as ever.
        let third = try h.id("Night Train to Vostok")
        #expect(h.model.contextTarget(forItem: .book(third)) == [third])
        h.model.contextClickItem(.book(third))
        #expect(h.model.selection == [third])
        h.model.contextClickItem(.book(third))
        #expect(h.model.selection == [third])
    }

    /// GS22: a group only some of whose books are selected is not fully selected.
    @Test func aContextClickOnAPartlySelectedGroupSelectsAllItsBooks() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        let other = try h.id("Quiet Rivers")
        h.model.setGroup(Self.series, open: true)
        h.model.select([ids[0], other])
        h.model.contextClickItem(Self.seriesItem)
        #expect(h.model.selection == Set(ids))
    }

    /// GS22: unsaved changes are not put at risk, or asked about, for a menu.
    @Test func aContextClickOnAGroupLeavesUnsavedChangesAlone() async throws {
        let h = try await grouped()
        let ids = try seriesIds(h)
        let other = try await h.edit("Quiet Rivers", newTitle: "Loud Rivers")
        h.model.contextClickItem(Self.seriesItem)
        #expect(h.model.selection == [other])
        #expect(h.model.prompt == nil)
        // The menu still acts on what it was opened on.
        #expect(h.model.contextTarget(forItem: Self.seriesItem) == Set(ids))
        #expect(h.model.bookIds(of: [Self.seriesItem, .book(other)]) == Set(ids + [other]))
    }

    // MARK: GS23

    /// GS23
    @Test func selectAllSelectsEveryBookGroupedOrNot() async throws {
        let h = try await grouped()
        h.model.selectAll()
        #expect(h.model.selection == Set(h.model.rows.map(\.id)))
        #expect(h.model.selection.count == 12)
        #expect(h.model.itemSelection.count == 10)
        #expect(h.model.itemSelection.contains(Self.seriesItem))
        #expect(h.model.openGroups.isEmpty)

        // The table's own Select All names every row it has.
        h.model.select([])
        h.model.selectItems(Set(h.model.items.map(\.id)))
        #expect(h.model.selection.count == 12)
    }

    // MARK: GS24

    /// GS24: books are counted, not items.
    @Test func theWindowCountsBooks() async throws {
        let h = try await grouped()
        #expect(h.model.items.count == 10)
        #expect(h.model.windowSubtitle == "12 books")
        #expect(h.model.windowTitle == "All Books")
    }
}

/// Raised from wherever a change is noticed.
private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isRaised: Bool { lock.withLock { raised } }

    func raise() {
        lock.withLock { raised = true }
    }
}
