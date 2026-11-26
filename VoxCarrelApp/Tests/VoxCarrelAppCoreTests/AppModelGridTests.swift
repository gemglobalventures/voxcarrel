import DemoContent
import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// What the grid and the list ask of the model (plan Task 9). K1–K7.
@MainActor
@Suite struct AppModelGridTests {
    // MARK: K1 Empty states (G7)

    /// K1
    @Test func anEmptyLibraryAndAnEmptyResultAreToldApart() async throws {
        let empty = try await Harness.empty()
        #expect(empty.model.emptyState == .emptyLibrary)
        // Whatever part of the sidebar is chosen, the library is what is empty.
        empty.model.sidebarSelection = .finished
        await empty.model.settle()
        #expect(empty.model.emptyState == .emptyLibrary)

        let h = try await Harness.demo()
        #expect(h.model.emptyState == nil)
        h.model.searchText = "no book is called this"
        await h.model.settle()
        #expect(h.model.emptyState == .noMatches)
        h.model.searchText = ""
        await h.model.settle()
        #expect(h.model.emptyState == nil)
    }

    /// K1: nothing is said about books before there are rows to go by.
    @Test func noEmptyStateUntilTheLibraryHasBeenRead() async throws {
        let h = try await Harness.demo(start: false)
        #expect(h.model.emptyState == nil)

        let none = try Harness(root: try makeTempDir(), choose: false)
        await none.model.start()
        #expect(none.model.emptyState == nil)
    }

    /// K1: what the middle of the window shows. The grid or the list is not shown until
    /// there are books for it: a table made empty and filled a moment later complains.
    @Test func booksContentIsNothingUntilReadThenBooksOrAnEmptyState() async throws {
        let h = try await Harness.demo(start: false)
        #expect(h.model.booksContent == .notLoaded)
        await h.model.start()
        #expect(h.model.booksContent == .books)
        h.model.searchText = "no book is called this"
        await h.model.settle()
        #expect(h.model.booksContent == .empty(.noMatches))

        let empty = try await Harness.empty()
        #expect(empty.model.booksContent == .empty(.emptyLibrary))

        // Another library: its own answer, nothing left of the old one's.
        let other = try makeTempDir()
        h.model.searchText = ""
        await h.model.settle()
        await h.model.chooseLibrary(other)
        #expect(h.model.booksContent == .empty(.emptyLibrary))
    }

    /// K1
    @Test func emptyStatesHaveWords() {
        #expect(EmptyState.emptyLibrary.title == "No books yet")
        #expect(EmptyState.emptyLibrary.message == "Drag files or folders here, or choose Import.")
        #expect(EmptyState.noMatches.title == "No books match")
        #expect(!EmptyState.noMatches.message.isEmpty)
    }

    // MARK: K2 Arrow keys (G2)

    /// K2
    @Test func arrowKeysMoveTheSelectionThroughTheRows() async throws {
        let h = try await Harness.demo()
        let ids = h.model.rows.map(\.id)

        #expect(h.model.moveSelection(.right, columns: 4) == ids[0])
        #expect(h.model.selection == [ids[0]])
        #expect(h.model.moveSelection(.down, columns: 4) == ids[4])
        #expect(h.model.moveSelection(.right, columns: 4) == ids[5])
        #expect(h.model.moveSelection(.up, columns: 4) == ids[1])
        #expect(h.model.selection == [ids[1]])
        await h.model.settle()
        #expect(h.detail?.row.id == ids[1])

        // From a selection of several, the move starts where the last click was.
        h.model.click(ids[6], modifiers: [])
        h.model.click(ids[2], modifiers: .command)
        #expect(h.model.moveSelection(.right, columns: 4) == ids[3])
        #expect(h.model.selection == [ids[3]])
        // And a shift-click afterwards extends from the book the keys arrived at.
        h.model.click(ids[5], modifiers: .shift)
        #expect(h.model.selection == Set(ids[3...5]))
    }

    /// K2
    @Test func arrowKeysDoNothingWithNoRows() async throws {
        let h = try await Harness.empty()
        #expect(h.model.moveSelection(.down, columns: 3) == nil)
        #expect(h.model.selection.isEmpty)
    }

    /// K2, A8: with unsaved changes the move waits for an answer, and nothing is reported as selected.
    @Test func arrowKeysAskAboutUnsavedChanges() async throws {
        let h = try await Harness.demo()
        let first = h.model.rows[0]
        try await h.edit(first.book.title, newTitle: "Changed")
        #expect(h.model.moveSelection(.right, columns: 4) == nil)
        #expect(h.model.prompt == .unsavedChanges)
        #expect(h.model.selection == [first.id])
    }

    // MARK: K3 Context menus (G5)

    /// K3: the menu is for the selection when the book is part of it, otherwise for that book alone.
    @Test func contextTargetIsTheSelectionOrTheBook() async throws {
        let h = try await Harness.demo()
        let ids = h.model.rows.map(\.id)
        #expect(h.model.contextTarget(for: ids[0]) == [ids[0]])
        h.model.select([ids[0], ids[1]])
        #expect(h.model.contextTarget(for: ids[1]) == [ids[0], ids[1]])
        #expect(h.model.contextTarget(for: ids[2]) == [ids[2]])
    }

    /// K3: asking for the menu of a book that is not selected selects it.
    @Test func contextClickSelectsABookThatIsNotSelected() async throws {
        let h = try await Harness.demo()
        let ids = h.model.rows.map(\.id)
        h.model.select([ids[0], ids[1]])

        h.model.contextClick(ids[1])
        #expect(h.model.selection == [ids[0], ids[1]])

        h.model.contextClick(ids[2])
        #expect(h.model.selection == [ids[2]])
        await h.model.settle()
        #expect(h.detail?.row.id == ids[2])
        // It is where a shift-click now starts from.
        h.model.click(ids[4], modifiers: .shift)
        #expect(h.model.selection == Set(ids[2...4]))
    }

    /// K3: unsaved changes are not put at risk, or asked about, for a menu; the menu
    /// still acts on the book it was opened on.
    @Test func contextClickLeavesTheSelectionAloneWhileThereAreUnsavedChanges() async throws {
        let h = try await Harness.demo()
        let ids = h.model.rows.map(\.id)
        try await h.edit(h.model.rows[0].book.title, newTitle: "Changed")
        h.model.contextClick(ids[3])
        #expect(h.model.selection == [ids[0]])
        #expect(h.model.prompt == nil)
        #expect(h.model.contextTarget(for: ids[3]) == [ids[3]])
    }

    // MARK: K4 Commands for books other than the selection (G5)

    /// K4
    @Test func commandsAreWorkedOutForTheBooksGiven() async throws {
        let h = try await Harness.demo()
        let audioOnly = try h.id("The Lighthouse Keeper")
        let ebookOnly = try h.id("Quiet Rivers")
        #expect(h.model.selection.isEmpty)

        let audio = h.model.commands(for: [audioOnly])
        #expect(audio.open && audio.listen && !audio.read)
        #expect(audio.reveal && audio.mark && audio.rewriteTags && audio.remove)
        let ebook = h.model.commands(for: [ebookOnly])
        #expect(ebook.open && !ebook.listen && ebook.read)
        let both = h.model.commands(for: [audioOnly, ebookOnly])
        #expect(!both.open && !both.listen && !both.read && both.remove)
        #expect(h.model.commands(for: []) == SelectionCommands())

        // The Book menu's are these, for the selection.
        try await h.select("Quiet Rivers")
        #expect(h.model.selectionCommands == ebook)
    }

    /// K4
    @Test func rewriteTagsActsOnTheBooksGiven() async throws {
        let h = try await Harness.demo()
        let id = try h.id("Quiet Rivers")
        let url = try #require(try h.fileURLs(id).first)
        // The file says something else; rewriting puts the library's title back.
        var other = try FileMetadataIO().readMetadata(at: url)
        other.title = "Scribbled"
        try FileMetadataIO().write(other, to: url)

        h.recordBusyLabels()
        await h.model.rewriteTags(for: [id])
        #expect(h.busyLabels == ["Rewriting tags…"])
        #expect(try FileMetadataIO().readMetadata(at: url).title == "Quiet Rivers")
        #expect(h.model.selection.isEmpty)

        await h.model.rewriteTags(for: [])
        #expect(h.busyLabels == ["Rewriting tags…"])
    }

    // MARK: K5 Opening by double-click and Return (G4)

    /// K5: one book is opened; several, or none, are not.
    @Test func openingBooksOpensOnlyASingleOne() async throws {
        let h = try await Harness.demo()
        let one = try h.id("Quiet Rivers")
        let two = try h.id("Salt Road")

        h.model.openOne(of: [one, two])
        h.model.openOne(of: [])
        await h.model.settle()
        #expect(h.opener.opened.isEmpty)

        h.model.openOne(of: [one])
        await h.model.settle()
        #expect(h.opener.opened == (try h.fileURLs(one)))
    }

    // MARK: K6 Column headers (G3)

    /// K6: a click on a column header becomes the sort, is remembered, and re-orders the rows.
    @Test func theListsSortOrderIsTheModelsSort() async throws {
        let h = try await Harness.demo()
        #expect(h.model.tableSortOrder == BookSort(key: .title, ascending: true).tableSortOrder)

        h.model.tableSortOrder =
            BookSort(key: .author, ascending: false).tableSortOrder + BookSort(key: .title).tableSortOrder
        #expect(h.model.sort == BookSort(key: .author, ascending: false))
        #expect(h.model.tableSortOrder == BookSort(key: .author, ascending: false).tableSortOrder)
        #expect(h.model.rows == BookSort(key: .author, ascending: false).sorted(h.model.rows))
        #expect(h.relaunched().sort == BookSort(key: .author, ascending: false))

        // An order the model has no sort for changes nothing.
        h.model.tableSortOrder = []
        #expect(h.model.sort == BookSort(key: .author, ascending: false))
    }

    /// Sorting by pages: fewest first or most first, with books that have no page
    /// count after those that have, whichever way round.
    @Test func booksAreSortedByTheirPages() async throws {
        let h = try await Harness.demo()
        h.model.groupsBySeries = false
        h.model.sort = BookSort(key: .pages, ascending: true)
        await h.model.settle()
        let rising = h.model.rows.map { $0.book.pageCount ?? 0 }
        let known = rising.filter { $0 > 0 }
        #expect(!known.isEmpty && known == known.sorted())
        // Those with none come last.
        #expect(Array(rising.prefix(known.count)) == known)
        h.model.sort = BookSort(key: .pages, ascending: false)
        await h.model.settle()
        let falling = h.model.rows.map { $0.book.pageCount ?? 0 }
        #expect(Array(falling.prefix(known.count)) == known.sorted(by: >))
    }

    /// K6: a table that is shown a sort order sets the same one back. That is not a
    /// change: were the rows put in order again each time, the two would never stop.
    @Test func settingTheSortOrderItAlreadyHasChangesNothing() async throws {
        let h = try await Harness.demo()
        h.model.sort = BookSort(key: .length, ascending: false)
        let changed = Flag()
        withObservationTracking {
            _ = h.model.rows
            _ = h.model.sort
        } onChange: {
            changed.raise()
        }
        h.model.tableSortOrder = BookSort(key: .length, ascending: false).tableSortOrder
        #expect(!changed.isRaised)

        h.model.tableSortOrder = BookSort(key: .length, ascending: true).tableSortOrder
        #expect(changed.isRaised)
    }

    // MARK: K8 A list that changes a lot (G8)

    /// K8: a few books coming or going is a small change; a different order, or many, is not.
    @Test func aSmallChangeOfRowsIsAFewInsertedOrRemovedInTheSameOrder() {
        let ids = Array(Int64(1)...100)
        var generator = Generator()
        #expect(RowsChange.isSmall(from: ids, to: ids))
        #expect(RowsChange.isSmall(from: [], to: []))
        #expect(RowsChange.isSmall(from: ids, to: ids.filter { $0 != 40 }))
        #expect(RowsChange.isSmall(from: ids, to: [0] + ids + [200, 201]))
        // Some gone and some new at once.
        #expect(RowsChange.isSmall(from: ids, to: ids.filter { $0 % 10 != 0 } + [500, 501]))

        #expect(RowsChange.isSmall(from: ids, to: Array(ids.dropLast(RowsChange.limit))))
        #expect(!RowsChange.isSmall(from: ids, to: Array(ids.dropLast(RowsChange.limit + 1))))
        #expect(!RowsChange.isSmall(from: [], to: ids))
        #expect(!RowsChange.isSmall(from: ids, to: []))
        // The same books in a very different order.
        #expect(!RowsChange.isSmall(from: ids, to: ids.reversed()))
        #expect(!RowsChange.isSmall(from: ids, to: ids.shuffled(using: &generator)))
    }

    /// K8: a few books that change place are a small change too: a book that is given a
    /// new title moves, and the list must not be made again for that.
    @Test func aFewBooksThatMoveAreASmallChange() {
        let ids = Array(Int64(1)...100)
        #expect(RowsChange.isSmall(from: [1, 2, 3], to: [2, 1, 3]))
        #expect(RowsChange.isSmall(from: [1, 2, 3, 4], to: [2, 3, 4, 1]))
        // One book moved from the top to the bottom.
        #expect(RowsChange.isSmall(from: ids, to: Array(ids.dropFirst()) + [1]))
        // Moved, removed and inserted books are counted together.
        let moved = Array(ids.dropFirst(RowsChange.limit)) + ids.prefix(RowsChange.limit)
        #expect(RowsChange.isSmall(from: ids, to: moved))
        #expect(!RowsChange.isSmall(from: ids, to: moved + [500]))
        #expect(!RowsChange.isSmall(from: ids, to: Array(ids.dropFirst(RowsChange.limit + 1)) + ids.prefix(RowsChange.limit + 1)))
        // Twelve books turned round: eleven of them moved.
        #expect(RowsChange.isSmall(from: Array(ids.prefix(12)), to: ids.prefix(12).reversed()))
    }

    /// A generator that gives the same numbers every time.
    private struct Generator: RandomNumberGenerator {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    /// K8: the list is given a new identity when its rows change a lot, and only then:
    /// a table shown a very different list is very slow to work out what moved.
    @Test func rowsVersionChangesOnlyWhenTheRowsChangeALot() async throws {
        let h = try await Harness.demo()
        let version = h.model.rowsVersion

        // Selecting, and a change to a book that leaves the order alone, are not changes of rows.
        let id = try await h.select("Quiet Rivers")
        await h.model.setReadStatus(.inProgress, for: [id])
        #expect(h.model.rowsVersion == version)
        h.model.sort = h.model.sort
        #expect(h.model.rowsVersion == version)
        h.model.select([])
        await h.model.settle()

        // Twelve books turned round is still few; so is one book that moves when it is renamed.
        h.model.sort = BookSort(key: .title, ascending: false)
        #expect(h.model.rowsVersion == version)
        h.model.sort = BookSort(key: .title, ascending: true)
        try await h.edit("Quiet Rivers", newTitle: "Zebra Rivers")
        await h.model.save()
        #expect(h.titles.last == "Zebra Rivers")
        #expect(h.model.rowsVersion == version)
        #expect(h.model.scrollTarget == (try h.id("Zebra Rivers")))
        h.model.select([])
        await h.model.settle()
        #expect(h.model.scrollTarget == nil)

        h.model.searchText = "salt"
        await h.model.settle()
        #expect(h.model.rows.count == 1)
        // Twelve books down to one: eleven removed, which is few.
        #expect(h.model.rowsVersion == version)

        h.model.sidebarSelection = .audiobooks
        h.model.searchText = ""
        await h.model.settle()
        #expect(h.model.rows.count == 9)
        #expect(h.model.rowsVersion == version)

        // One book removed from the library.
        h.model.requestRemove([try h.id("Salt Road")])
        await h.model.confirmRemove(moveFilesToTrash: false)
        #expect(h.model.rows.count == 8)
        #expect(h.model.rowsVersion == version)
    }

    /// K8: a big library put in the opposite order is a very different list.
    @Test func aBigListTurnedRoundIsMadeAgain() async throws {
        let root = try makeTempDir()
        try DemoContent.makeLibrary(at: root, count: 60, audible: false)
        let h = try Harness(root: root)
        await h.model.start()
        #expect(h.model.rows.count == 60)
        let version = h.model.rowsVersion
        let last = try #require(h.model.rows.last?.id)
        h.model.click(last, modifiers: [])
        await h.model.settle()
        h.model.sort = BookSort(key: .title, ascending: false)
        #expect(h.model.rowsVersion != version)
        // The list is to scroll to what is selected once it has been made again.
        #expect(h.model.scrollTarget == last)
    }

    // MARK: K7 Covers (G6)

    /// K7: a row says when its cover was last written, so a replaced cover is seen to be new.
    @Test func aReplacedCoverChangesTheRow() async throws {
        let h = try await Harness.demo()
        let id = try await h.select("Quiet Rivers")
        let before = try #require(h.model.rows.first { $0.id == id })
        #expect(before.coverURL != nil)
        let stamp = try #require(before.coverModified)

        // Stored covers are stamped to the second on some volumes: make the new one clearly later.
        let url = try #require(before.coverURL)
        try FileManager.default.setAttributes(
            [.modificationDate: stamp.addingTimeInterval(-10)], ofItemAtPath: url.path)
        h.model.setCover(data: MediaFixtures.makeImage(.jpeg, size: 32, red: 0.1))
        await h.model.save()

        let after = try #require(h.model.rows.first { $0.id == id })
        #expect(after.coverURL == url)
        let newStamp = try #require(after.coverModified)
        #expect(newStamp > stamp.addingTimeInterval(-10))
        #expect(after != before)

        // No cover, no date.
        h.model.removeCover()
        await h.model.save()
        let none = try #require(h.model.rows.first { $0.id == id })
        #expect(none.coverURL == nil)
        #expect(none.coverModified == nil)
    }
}

/// Raised from wherever a change is noticed.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isRaised: Bool { lock.withLock { raised } }

    func raise() {
        lock.withLock { raised = true }
    }
}
