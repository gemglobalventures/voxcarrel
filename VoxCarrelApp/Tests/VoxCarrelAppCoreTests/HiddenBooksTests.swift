import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// HD1 onwards: books the owner hides, as the app's model decides it. Nothing here
/// asks the system who is at the Mac: every check is the harness's own.
@MainActor
@Suite struct HiddenBooksTests {
    /// Selects the books and hides them, by the command.
    private func hide(_ titles: [String], in h: Harness) async throws {
        let ids = try await h.select(titles)
        await h.model.toggleHidden(for: ids)
        await h.model.settle()
    }

    /// Every title the model holds anywhere a window would show one.
    private func titlesInSight(_ h: Harness) -> [String] {
        var seen = h.titles
        if let detail = h.detail { seen.append(detail.row.book.title) }
        return seen
    }

    // MARK: Hiding

    @Test func HD1_aHiddenBookLeavesEveryListCountSearchAndTotal() async throws {
        let h = try await Harness.demo()
        let before = h.model.sidebar
        let all = try #require(before.counts[.allBooks])
        #expect(before.browse[.authors]?.contains("Amara Okafor") == true)
        let rivers = try await h.select("Quiet Rivers")
        let length = try h.book(rivers).durationSeconds ?? 0
        #expect(h.model.hideTitle(for: [rivers]) == "Hide" && h.model.canHide([rivers]))

        h.recordBusyLabels()
        await h.model.toggleHidden(for: [rivers])
        await h.model.settle()

        #expect(h.busyLabels == ["Updating…"])
        #expect(try h.book(rivers).isHidden)
        // Gone from the list, and no longer selected or inspected.
        #expect(!h.titles.contains("Quiet Rivers") && h.titles.count == all - 1)
        #expect(h.model.selection.isEmpty && h.model.inspecting == .nothing)
        // Gone from the counts, the browse values and the totals.
        let after = h.model.sidebar
        #expect(after.counts[.allBooks] == all - 1)
        for item in SidebarItem.fixed {
            #expect((after.counts[item] ?? 0) <= (before.counts[item] ?? 0))
        }
        #expect(after.browse[.authors]?.contains("Amara Okafor") == false)
        #expect(abs(before.audioSeconds - after.audioSeconds - length) < 0.001)
        #expect(after.diskBytes < before.diskBytes)
        #expect(h.model.windowSubtitle == "\(all - 1) books")
        let bar = try #require(h.model.statusBar)
        #expect(bar.shown.hasPrefix("\(all - 1) books"))
        #expect(bar.library.hasPrefix("Library: \(all - 1) books"))
        // A search does not find it, by title or by author.
        for words in ["Quiet Rivers", "Okafor"] {
            h.model.searchText = words
            await h.model.settle()
            #expect(h.titles.isEmpty)
        }
        h.model.searchText = ""
        // Nor does any list of the sidebar have it.
        let lists = SidebarItem.fixed + [.upNext, .highlights, .onKindle, .noGenre, .browse(.authors, "Amara Okafor")]
            + after.collections.compactMap { $0.id.map(SidebarItem.collection) }
            + GenreGroup.allCases.map(SidebarItem.genreGroup)
        let worker = try #require(h.model.worker)
        for item in lists {
            #expect(try await !worker.rows(for: item, search: "").contains { $0.id == rivers })
            #expect(try await !worker.shownBooks(for: item, search: "rivers").rows.contains { $0.id == rivers })
        }
        // It is not something Undo reverses.
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
    }

    @Test func HD2_theFirstTimeBooksAreHiddenItIsSaidWhereTheyWentAndNeverAgain() async throws {
        let h = try await Harness.demo()
        try await hide(["Quiet Rivers"], in: h)
        #expect(h.model.alert
            == "Hidden books are left out of every list and search. To see them, choose View > Show Hidden Books…")
        h.model.alert = nil

        try await hide(["Salt Road", "The Drowned Bell"], in: h)
        #expect(h.model.alert == nil)
        #expect(try h.store().hiddenBookCount() == 3)
        // Nor after the app has been quit and opened again.
        let again = h.relaunched()
        await again.start()
        let id = try h.id("Night Train to Vostok")
        again.click(id, modifiers: [])
        await again.settle()
        await again.toggleHidden(for: [id])
        #expect(again.alert == nil && !again.rows.contains { $0.id == id })
    }

    @Test func HD3_hidingWaitsForUnsavedChangesAndForWhateverIsRunning() async throws {
        let h = try await Harness.demo()
        let rivers = try h.id("Quiet Rivers")
        #expect(!h.model.canHide([]))
        // A row that stands for a book the library does not have cannot be hidden.
        #expect(!h.model.canHide([-1]) && !h.model.canHide([rivers, -1]))
        try await h.edit("Quiet Rivers", newTitle: "Loud Rivers")
        #expect(!h.model.canHide([rivers]))
        await h.model.toggleHidden(for: [rivers])
        #expect(try !h.book(rivers).isHidden)
        h.model.discardChanges()
        #expect(h.model.canHide([rivers]))
        h.model.busyLabel = "Working…"
        #expect(!h.model.canHide([rivers]))
        h.model.busyLabel = nil

        // An edit of a hidden book leaves it hidden.
        try await hide(["Quiet Rivers"], in: h)
        await h.model.showHiddenBooks()
        try await h.edit("Quiet Rivers", newTitle: "Loud Rivers")
        await h.model.save()
        #expect(try h.book(rivers).isHidden && h.book(rivers).title == "Loud Rivers")
        #expect(h.titles == ["Loud Rivers"])
    }

    // MARK: Showing

    @Test func HD4_theHiddenListIsNotThereUntilHiddenBooksAreShown() async throws {
        let h = try await Harness.demo()
        try await hide(["Quiet Rivers"], in: h)
        #expect(!h.model.showsHiddenBooks && h.model.hiddenBookCount == 0)
        #expect(h.model.hiddenBooksMenuTitle == "Show Hidden Books…")
        // It cannot be chosen, by anything.
        h.model.sidebarSelection = .hidden
        await h.model.settle()
        #expect(h.model.sidebarSelection == .allBooks && !h.titles.contains("Quiet Rivers"))
        #expect(h.ownerCheck.reasons.isEmpty)
    }

    @Test func HD5_aCheckThatConfirmsShowsTheHiddenListAndSelectsIt() async throws {
        let h = try await Harness.demo()
        try await hide(["Quiet Rivers", "Salt Road"], in: h)
        h.model.alert = nil
        h.model.searchText = "bell"
        await h.model.settle()

        // While the owner is being asked nothing is shown, and they are not asked twice.
        let gate = Gate()
        h.ownerCheck.gate = gate
        let asking = Task { await h.model.showHiddenBooks() }
        await gate.arrival()
        #expect(!h.model.showsHiddenBooks && !h.model.canToggleHiddenBooks)
        await h.model.showHiddenBooks()
        #expect(h.ownerCheck.reasons == ["show hidden books"])
        h.ownerCheck.gate = nil
        await gate.release()
        await asking.value
        await h.model.settle()

        #expect(h.model.showsHiddenBooks && h.model.hiddenBookCount == 2)
        #expect(h.model.sidebarSelection == .hidden && h.model.searchText == "")
        #expect(h.model.windowTitle == "Hidden" && h.model.title(of: .hidden) == "Hidden")
        #expect(h.titles.sorted() == ["Quiet Rivers", "Salt Road"])
        #expect(h.model.windowSubtitle == "2 books")
        #expect(h.model.hiddenBooksMenuTitle == "Stop Showing Hidden Books")
        #expect(h.model.alert == nil)
        // The rows are the books as they are, files and all.
        #expect(h.model.rows.allSatisfy { $0.hasFiles && $0.book.isHidden })
        // A search narrows among the hidden books only.
        h.model.searchText = "road"
        await h.model.settle()
        #expect(h.titles == ["Salt Road"])
        h.model.searchText = "bell"
        await h.model.settle()
        #expect(h.titles.isEmpty)
        // The other lists are as they were: no hidden book is in them.
        h.model.searchText = ""
        h.model.sidebarSelection = .allBooks
        await h.model.settle()
        #expect(!h.titles.contains("Quiet Rivers") && !h.titles.contains("Salt Road"))
        #expect(h.model.statusBar?.library.hasPrefix("Library: \(h.titles.count) books") == true)
    }

    @Test func HD6_aCheckThatIsRefusedShowsNothingAndSaysNothing() async throws {
        let h = try await Harness.demo()
        try await hide(["Quiet Rivers"], in: h)
        h.model.alert = nil
        h.ownerCheck.answer = .refused
        await h.model.toggleHiddenBooks()
        await h.model.settle()
        #expect(h.ownerCheck.reasons.count == 1)
        #expect(!h.model.showsHiddenBooks && h.model.hiddenBookCount == 0)
        #expect(h.model.sidebarSelection == .allBooks && !h.titles.contains("Quiet Rivers"))
        #expect(h.model.alert == nil && h.model.prompt == nil)
        #expect(h.model.hiddenBooksMenuTitle == "Show Hidden Books…" && h.model.canToggleHiddenBooks)
    }

    @Test func HD7_onAMacThatCannotCheckTheyAreShownWithout() async throws {
        let h = try await Harness.demo()
        try await hide(["Quiet Rivers"], in: h)
        h.ownerCheck.answer = .unavailable
        await h.model.toggleHiddenBooks()
        await h.model.settle()
        #expect(h.model.showsHiddenBooks && h.model.sidebarSelection == .hidden)
        #expect(h.titles == ["Quiet Rivers"])
    }

    @Test func HD8_stoppingPutsThemOutOfSightAndLeavesNoneSelected() async throws {
        let h = try await Harness.demo()
        try await hide(["Quiet Rivers"], in: h)
        await h.model.showHiddenBooks()
        let rivers = try await h.select("Quiet Rivers")
        #expect(h.detail?.row.id == rivers)
        #expect(h.detail?.files.isEmpty == false)

        await h.model.toggleHiddenBooks()
        // Asked nothing: only showing is checked.
        #expect(h.ownerCheck.reasons.count == 1)
        #expect(!h.model.showsHiddenBooks && h.model.hiddenBookCount == 0)
        #expect(h.model.sidebarSelection == .allBooks && h.model.windowTitle == "All Books")
        #expect(h.model.selection.isEmpty && h.model.inspecting == .nothing)
        #expect(!titlesInSight(h).contains("Quiet Rivers") && !h.titles.isEmpty)
        #expect(h.model.hiddenBooksMenuTitle == "Show Hidden Books…")

        // From another list, the list stays and only the Hidden list goes.
        await h.model.showHiddenBooks()
        h.model.sidebarSelection = .audiobooks
        await h.model.settle()
        let salt = try await h.select("Salt Road")
        await h.model.stopShowingHiddenBooks()
        #expect(h.model.sidebarSelection == .audiobooks && h.model.selection == [salt])
        #expect(!h.model.showsHiddenBooks)
    }

    @Test func HD9_theListIsBlankAtOnceWhenShowingStops() async throws {
        let h = try await Harness.demo()
        try await hide(["Quiet Rivers"], in: h)
        await h.model.showHiddenBooks()
        try await h.select("Quiet Rivers")
        // The library is kept from answering: what is seen before it does.
        let gate = Gate()
        h.model.beforeApplyingRows = { _ in await gate.wait() }
        let stopping = Task { await h.model.stopShowingHiddenBooks() }
        await gate.arrival()
        #expect(h.model.rows.isEmpty && h.model.booksContent == .notLoaded)
        #expect(h.model.selection.isEmpty && h.model.inspecting == .nothing)
        await gate.release()
        await stopping.value
        #expect(!h.titles.isEmpty && !h.titles.contains("Quiet Rivers"))
    }

    @Test func HD10_unhidingBringsTheBookBackWithAllItHad() async throws {
        let h = try await Harness.demo()
        let all = try #require(h.model.sidebar.counts[.allBooks])
        let before = try h.book(try h.id("Quiet Rivers"))
        try await hide(["Quiet Rivers", "Salt Road"], in: h)
        h.model.alert = nil
        await h.model.showHiddenBooks()
        let rivers = try await h.select("Quiet Rivers")
        #expect(h.model.hideTitle(for: [rivers]) == "Unhide" && h.model.canHide([rivers]))

        await h.model.toggleHiddenForSelection()
        await h.model.settle()

        #expect(try h.book(rivers) == before)
        // It has left the Hidden list, which stays, with the one book still hidden.
        #expect(h.model.sidebarSelection == .hidden && h.titles == ["Salt Road"])
        #expect(h.model.hiddenBookCount == 1 && h.model.selection.isEmpty)
        #expect(h.model.alert == nil)
        #expect(h.model.sidebar.counts[.allBooks] == all - 1)
        #expect(h.model.sidebar.browse[.authors]?.contains("Amara Okafor") == true)
        h.model.sidebarSelection = .allBooks
        await h.model.settle()
        #expect(h.titles.contains("Quiet Rivers") && !h.titles.contains("Salt Road"))

        // With the last one brought back the list is empty, and says so.
        h.model.sidebarSelection = .hidden
        await h.model.settle()
        await h.model.toggleHidden(for: [try await h.select("Salt Road")])
        await h.model.settle()
        #expect(h.titles.isEmpty && h.model.emptyState == .noHiddenBooks)
        #expect(EmptyState.noHiddenBooks.title == "No hidden books")
    }

    @Test func HD11_anotherLibraryAndAnotherLaunchBeginWithThemOutOfSight() async throws {
        let h = try await Harness.demo()
        try await hide(["Quiet Rivers"], in: h)
        await h.model.showHiddenBooks()
        #expect(h.model.showsHiddenBooks && h.model.sidebarSelection == .hidden)

        // Quit and opened again: nothing was kept.
        let again = h.relaunched()
        await again.start()
        #expect(!again.showsHiddenBooks && again.sidebarSelection == .allBooks)
        #expect(!again.rows.contains { $0.book.title == "Quiet Rivers" })

        // The library looked for again while they are shown.
        await h.model.retryLibrary()
        #expect(!h.model.showsHiddenBooks && h.model.sidebarSelection == .allBooks)
        #expect(!h.titles.contains("Quiet Rivers"))

        // Another library chosen while they are shown.
        await h.model.showHiddenBooks()
        #expect(h.model.showsHiddenBooks)
        await h.model.chooseLibrary(try makeTempDir())
        #expect(!h.model.showsHiddenBooks && h.model.hiddenBookCount == 0)
        #expect(h.model.sidebarSelection == .allBooks && h.titles.isEmpty)
    }

    @Test func HD12_theAnswerToACheckIsNotForALibraryOpenedMeanwhile() async throws {
        let h = try await Harness.demo()
        try await hide(["Quiet Rivers"], in: h)
        let gate = Gate()
        h.ownerCheck.gate = gate
        let asking = Task { await h.model.showHiddenBooks() }
        await gate.arrival()
        await h.model.chooseLibrary(try makeTempDir())
        await gate.release()
        await asking.value
        #expect(!h.model.showsHiddenBooks && h.model.sidebarSelection == .allBooks)
    }

    // MARK: The menus

    @Test func HD13_theViewMenusItemAppliesWhenALibraryIsOpenAndNothingIsInTheWay() async throws {
        let h = try await Harness.demo(start: false)
        #expect(!h.model.canToggleHiddenBooks && h.model.hiddenBooksMenuTitle == "Show Hidden Books…")
        await h.model.toggleHiddenBooks()
        #expect(h.ownerCheck.reasons.isEmpty)
        await h.model.start()
        #expect(h.model.canToggleHiddenBooks)

        h.model.busyLabel = "Working…"
        #expect(!h.model.canToggleHiddenBooks)
        h.model.busyLabel = nil
        // A question that is waiting, a sheet of the window, unsaved changes.
        h.model.requestRemove(try await h.select(["Quiet Rivers"]))
        #expect(h.model.prompt != nil && !h.model.canToggleHiddenBooks)
        h.model.prompt = nil
        h.model.beginNewShelf()
        #expect(!h.model.canToggleHiddenBooks)
        h.model.shelfEditor = nil
        try await h.edit("Quiet Rivers", newTitle: "Loud Rivers")
        #expect(!h.model.canToggleHiddenBooks)
        await h.model.toggleHiddenBooks()
        #expect(h.ownerCheck.reasons.isEmpty && !h.model.showsHiddenBooks)
        h.model.discardChanges()
        #expect(h.model.canToggleHiddenBooks)

        // No library: nothing to show.
        let none = try Harness(root: try makeTempDir(), choose: false)
        await none.model.start()
        #expect(!none.model.canToggleHiddenBooks)
    }

    @Test func HD14_theBookCommandSaysHideOrUnhideAndUndoNamesNoHiddenBook() async throws {
        let h = try await Harness.demo()
        let rivers = try await h.edit("Quiet Rivers", newTitle: "Loud Rivers")
        await h.model.save()
        #expect(h.model.undoMenuTitle == "Undo Edit Loud Rivers")
        #expect(h.model.hideTitle(for: []) == "Hide" && h.model.hideTitle(for: [rivers]) == "Hide")

        await h.model.toggleHidden(for: [rivers])
        h.model.alert = nil
        // What Undo would reverse was done to a book that is hidden now.
        #expect(h.model.undoMenuTitle == "Undo Edit 1 book")
        // Undone, the book has its old title and is hidden still.
        await h.model.undo()
        #expect(try h.book(rivers).title == "Quiet Rivers" && h.book(rivers).isHidden)
        #expect(!h.titles.contains("Quiet Rivers") && !h.titles.contains("Loud Rivers"))

        await h.model.showHiddenBooks()
        let salt = try h.id("Salt Road")
        // Of the rows shown, which are all hidden ones.
        #expect(h.model.hideTitle(for: [rivers]) == "Unhide")
        // A book that is not among them cannot be acted on from here.
        #expect(!h.model.canHide([salt]))
    }

    // MARK: What the library's own work still knows

    @Test func HD15_aHiddenBookIsNotBroughtInAgainFromKindle() async throws {
        let h = try await Harness.demo()
        try h.link()
        try await hide(["The Lighthouse Keeper"], in: h)
        h.model.alert = nil
        let lighthouse = try h.id("The Lighthouse Keeper")
        h.audible.holdsOnKindle([
            KindleSamples.item("B0NEW1", "A New Book", cover: nil),
            KindleSamples.item("B0LIGHT", "The Lighthouse Keeper", author: "Marsh, Eleanor:", cover: nil),
        ])
        let before = try h.store().books().count

        let session = try await h.kindleImportRead()
        #expect(session.titlesToAdd == ["A New Book"])
        await session.apply()
        await h.model.audibleCovers?.value

        // One book was added; the hidden one was known, marked, and is hidden still.
        #expect(try h.store().books().count == before + 1)
        let held = try h.book(lighthouse)
        #expect(held.isHidden)
        #expect(held.externalCopies == [ExternalCopy(kind: .kindle, form: .ebook, itemId: "B0LIGHT")])
        #expect(h.titles.contains("A New Book") && !h.titles.contains("The Lighthouse Keeper"))
        // Owned on Kindle, and still in no list: On Kindle counts the new book alone.
        #expect(h.model.onKindleCount == 1)
    }

    @Test func HD16_whatIsListedForGenresShelvesAndSeriesLeavesHiddenBooksOut() async throws {
        let h = try await Harness.demo()
        let worker = try #require(h.model.worker)
        let salt = try h.id("Salt Road")
        let fillBefore = try await worker.genreFillCandidates(includingGeneral: true).map(\.id)
        let shelves = h.model.sidebar.shelves
        #expect(!shelves.isEmpty)
        let seriesBefore = try await worker.seriesCheckBooks(named: "Tidewater Chronicles").map(\.id)
        #expect(seriesBefore.contains(salt))

        try await hide(["Salt Road"], in: h)

        #expect(try await !worker.seriesCheckBooks(named: "Tidewater Chronicles").contains { $0.id == salt })
        #expect(try await worker.seriesCheckBooks(named: "Tidewater Chronicles").count == seriesBefore.count - 1)
        #expect(try await !worker.genreFillCandidates(includingGeneral: true).contains { $0.id == salt })
        #expect(try await worker.genreFillCandidates(includingGeneral: true).count
            == fillBefore.count - (fillBefore.contains(salt) ? 1 : 0))
        #expect(try await !worker.genreFileDifferences().contains { $0.id == salt })
        for shelf in shelves {
            let held = try await worker.rows(for: .shelf(try #require(shelf.id)), search: "").map(\.id)
            #expect(!held.contains(salt))
            #expect(try await worker.shelfCount(shelf) == held.count)
        }
        #expect(try await worker.genreList().map(\.bookCount).reduce(0, +)
            <= h.model.sidebar.genres.map(\.bookCount).reduce(0, +))
        // The book shown with a folder layout is never a hidden one.
        #expect(try await worker.layoutSample() != nil)
        try await hide(["The Drowned Bell", "Harbour of Glass"], in: h)
        let sample = try await worker.layoutSample()
        #expect(sample?.metadata.series != "Tidewater Chronicles")
        // By its id a hidden book is still the book it is: the Hidden list needs it.
        #expect(try await worker.detail(bookId: salt)?.row.book.isHidden == true)
        #expect(try await worker.rows(for: .hidden, search: "").map(\.id).contains(salt))
    }
}
