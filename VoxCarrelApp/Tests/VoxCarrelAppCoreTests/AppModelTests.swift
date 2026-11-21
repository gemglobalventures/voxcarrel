import DemoContent
import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// A1–A6 and A8: the library, browsing and selection.
@MainActor
@Suite struct AppModelTests {
    // MARK: A1 Starting

    /// A1
    @Test func startOpensTheStoredLibrary() async throws {
        let h = try await Harness.demo(fresh: true)
        let model = h.model
        #expect(model.status == .available(h.root))
        #expect(model.openFailure == nil)
        #expect(model.busyLabel == nil)
        #expect(model.sidebar.counts[.allBooks] == 12)
        #expect(model.sidebar.counts[.needsAttention] == 1)
        #expect(model.sidebar.collections.map(\.name) == ["Favourites", "Holiday Listening"])
        #expect(model.rows.count == 12)
        #expect(model.rows == BookSort().sorted(model.rows))
        #expect(model.undoLabel == (try LibraryService(store: h.store()).undoLabel()))
        #expect(model.undoLabel != nil)
        #expect(model.selection.isEmpty)
        #expect(model.inspecting == .nothing)
    }

    /// A1
    @Test func startWithNoLibraryChosenShowsNothing() async throws {
        let h = try Harness(root: try makeTempDir(), choose: false)
        await h.model.start()
        #expect(h.model.status == .notChosen)
        #expect(h.model.rows.isEmpty)
        #expect(h.model.openFailure == nil)
        #expect(h.model.busyLabel == nil)
    }

    /// A1
    @Test func startWithAMissingFolderIsUnavailable() async throws {
        let gone = try makeTempDir().appendingPathComponent("Gone", isDirectory: true)
        let h = try Harness(root: gone)
        await h.model.start()
        #expect(h.model.status == .unavailable(gone))
        #expect(h.model.rows.isEmpty)
        #expect(!exists(gone))
    }

    /// A1: the folder is there but the catalogue in it cannot be opened.
    @Test func aLibraryThatWillNotOpenSaysSoAndLoadsNothing() async throws {
        let root = try makeTempDir()
        try touch(root.appendingPathComponent(LibraryStore.databaseFileName), "this is not a database")
        let h = try Harness(root: root)
        await h.model.start()
        #expect(h.model.status == .available(root))
        let failure = try #require(h.model.openFailure)
        #expect(
            failure
                == "The library in \"\(root.lastPathComponent)\" could not be opened. The library's database "
                + "could not be read. It may be damaged, or not a VoxCarrel library.")
        for word in ["SQL", "sqlite_master", "SELECT", "error 26"] {
            #expect(!failure.contains(word))
        }
        #expect(h.model.rows.isEmpty)
        #expect(h.model.sidebar.counts.isEmpty)
        #expect(h.model.libraryCheck == nil)
        #expect(h.model.busyLabel == nil)

    }

    /// A1: retrying after the folder comes back opens it.
    @Test func retryOpensALibraryThatHasComeBack() async throws {
        let parent = try makeTempDir()
        let root = parent.appendingPathComponent("Library", isDirectory: true)
        let h = try Harness(root: root)
        await h.model.start()
        #expect(h.model.status == .unavailable(root))

        try DemoContent.makeLibrary(at: root)
        await h.model.retryLibrary()
        #expect(h.model.status == .available(root))
        #expect(h.model.rows.count == 12)
    }

    // MARK: A2 The launch check

    /// A1, A2
    @Test func aCleanLibraryHasNothingToTell() async throws {
        let h = try await Harness.demo()
        #expect(h.model.libraryCheck == nil)
    }

    /// A1, A2: the check runs, its findings are shown, and the rows show what it flagged.
    @Test func missingFilesAreReportedAndFlagged() async throws {
        let h = try await Harness.demo(start: false)
        let id = try h.id("Quiet Rivers")
        for url in try h.fileURLs(id) { try FileManager.default.removeItem(at: url) }

        await h.model.start()
        let check = try #require(h.model.libraryCheck)
        #expect(check.booksWithMissingFiles == [id])
        #expect(h.model.rows.first { $0.id == id }?.book.needsAttention == true)
        #expect(h.model.sidebar.counts[.needsAttention] == 2)
    }

    /// A2
    @Test func untrackedFilesAreReported() async throws {
        let h = try await Harness.demo(start: false)
        let stray = try MediaFixtures.makeEPUB3(in: h.root, name: "Stray.epub")
        await h.model.start()
        let check = try #require(h.model.libraryCheck)
        #expect(check.untrackedFiles.map(\.lastPathComponent) == [stray.lastPathComponent])
    }

    /// A2: a file the organiser parked mid-move.
    @Test func strandedFilesAreReported() async throws {
        let h = try await Harness.demo(start: false)
        let name = ".voxcarrel-moving-\(UUID().uuidString)"
        try touch(h.root.appendingPathComponent(name))
        await h.model.start()
        #expect(h.model.libraryCheck?.strandedFiles.map(\.lastPathComponent) == [name])
    }

    /// A2: working copies that were cleared away are not worth telling.
    @Test func removedWorkingCopiesAloneAreNotReported() async throws {
        let h = try await Harness.demo(start: false)
        let copy = try touch(h.root.appendingPathComponent(".voxcarrel-\(UUID().uuidString).m4b"))
        await h.model.start()
        #expect(!exists(copy))
        #expect(h.model.libraryCheck == nil)
    }

    /// A2: the view dismisses the check.
    @Test func theLibraryCheckCanBeDismissed() async throws {
        let h = try await Harness.demo(start: false)
        _ = try MediaFixtures.makeEPUB3(in: h.root, name: "Stray.epub")
        await h.model.start()
        #expect(h.model.libraryCheck != nil)
        h.model.dismissLibraryCheck()
        #expect(h.model.libraryCheck == nil)
    }

    // MARK: A3 Choosing a library

    /// A3
    @Test func choosingAnExistingLibraryAdoptsItAtOnce() async throws {
        let h = try Harness(root: try makeTempDir(), choose: false)
        await h.model.start()
        let library = try makeTempDir()
        try DemoContent.makeLibrary(at: library)

        await h.model.chooseLibrary(library)
        #expect(h.model.prompt == nil)
        #expect(h.model.status == .available(library))
        #expect(h.defaults.string(forKey: LibraryLocation.defaultsKey) == library.path)
        #expect(h.model.rows.count == 12)
        #expect(h.model.sidebar.collections.count == 2)
    }

    /// A3
    @Test func choosingAnEmptyFolderMakesItTheLibrary() async throws {
        let h = try await Harness.demo()
        let folder = try makeTempDir()
        await h.model.chooseLibrary(folder)
        #expect(h.model.status == .available(folder))
        #expect(exists(folder.appendingPathComponent(LibraryStore.databaseFileName)))
        #expect(h.model.rows.isEmpty)
        #expect(h.model.sidebar.counts[.allBooks] == 0)
        #expect(h.model.sidebar.collections.isEmpty)
    }

    /// A3
    @Test func aFolderWithOtherFilesAsksFirst() async throws {
        let h = try await Harness.demo()
        let folder = try makeTempDir()
        try touch(folder.appendingPathComponent("notes.txt"))
        try touch(folder.appendingPathComponent("more.txt"))

        await h.model.chooseLibrary(folder)
        #expect(h.model.prompt == .chooseFolderWithFiles(folder, count: 2, bookFiles: 0))
        #expect(h.model.status == .available(h.root))
        #expect(h.model.rows.count == 12)
        #expect(!exists(folder.appendingPathComponent(LibraryStore.databaseFileName)))

        await h.model.confirmChooseLibrary(folder)
        #expect(h.model.prompt == nil)
        #expect(h.model.status == .available(folder))
        #expect(h.model.rows.isEmpty)
        #expect(h.defaults.string(forKey: LibraryLocation.defaultsKey) == folder.path)
    }

    /// A3
    @Test func aFolderThatCannotBeUsedSaysWhy() async throws {
        let h = try await Harness.demo()
        let file = try touch(try makeTempDir().appendingPathComponent("a file.txt"))
        await h.model.chooseLibrary(file)
        #expect(h.model.alert == "\"a file.txt\" is not a folder.")
        #expect(h.model.prompt == nil)
        #expect(h.model.status == .available(h.root))
        #expect(h.model.rows.count == 12)
    }

    /// A3: a folder that must not become a library is refused in words, and nothing changes.
    @Test func aFolderInsideALibraryOrAProtectedPlaceCannotBeChosen() async throws {
        let h = try await Harness.demo()
        let other = try await Harness.demo(start: false)
        let inner = other.root.appendingPathComponent("Amara Okafor", isDirectory: true)
        await h.model.chooseLibrary(inner)
        #expect(h.model.alert?.contains("inside the VoxCarrel library") == true)
        #expect(h.model.prompt == nil)
        #expect(h.model.status == .available(h.root))
        #expect(!exists(inner.appendingPathComponent(LibraryStore.databaseFileName)))

        h.model.alert = nil
        let home = try makeTempDir()
        try touch(home.appendingPathComponent("Documents/report.pdf"))
        h.model.places = ProtectedPlaces(home: home, systemFolders: [], isVolumeRoot: { _ in false })
        await h.model.chooseLibrary(home)
        #expect(h.model.alert?.contains("home folder") == true)
        // Nor by answering a question asked before.
        await h.model.confirmChooseLibrary(home.appendingPathComponent("Documents"))
        #expect(h.model.status == .available(h.root))
        #expect(h.model.rows.count == 12)
    }

    /// A3: nothing of the old library is left showing.
    @Test func adoptingClearsSelectionSearchAndInspector() async throws {
        let h = try await Harness.demo()
        h.model.sidebarSelection = .collection(try #require(h.model.sidebar.collections.first?.id))
        h.model.searchText = "salt"
        await h.model.settle()
        try await h.select("Salt Road")
        #expect(h.draft != nil)

        let other = try makeTempDir()
        try DemoContent.makeLibrary(at: other)
        await h.model.chooseLibrary(other)
        #expect(h.model.selection.isEmpty)
        #expect(h.model.searchText == "")
        #expect(h.model.sidebarSelection == .allBooks)
        #expect(h.model.inspecting == .nothing)
        #expect(h.model.rows.count == 12)
    }

    // MARK: A4

    /// A4
    @Test func choosingALibraryWithUnsavedChangesAsksFirst() async throws {
        let h = try await Harness.demo()
        try await h.edit("Salt Road", newTitle: "Salt Road Revised")
        let other = try makeTempDir()

        await h.model.chooseLibrary(other)
        #expect(h.model.prompt == .unsavedChanges)
        #expect(h.model.status == .available(h.root))

        await h.model.resolveUnsaved(.cancel)
        #expect(h.model.prompt == nil)
        #expect(h.model.status == .available(h.root))
        #expect(h.draft?.title == "Salt Road Revised")

        await h.model.chooseLibrary(other)
        await h.model.resolveUnsaved(.discard)
        #expect(h.model.status == .available(other))
        #expect(h.model.rows.isEmpty)
        #expect(h.model.inspecting == .nothing)
    }

    /// A4: Save writes the edit to the old library, then moves on.
    @Test func savingThenChoosingALibrary() async throws {
        let h = try await Harness.demo()
        let id = try await h.edit("Salt Road", newTitle: "Salt Road Revised")
        let other = try makeTempDir()
        await h.model.chooseLibrary(other)
        await h.model.resolveUnsaved(.save)
        #expect(h.model.status == .available(other))
        #expect(try h.book(id).title == "Salt Road Revised")
    }

    // MARK: A5 Browsing

    /// A5
    @Test func theSidebarSelectionDecidesTheRows() async throws {
        let h = try await Harness.demo()
        h.model.sidebarSelection = .ebooks
        await h.model.settle()
        #expect(h.model.rows.count == 4)
        #expect(h.model.rows.allSatisfy { $0.hasEbook })

        h.model.sidebarSelection = .needsAttention
        await h.model.settle()
        #expect(h.titles == ["Voices from the Attic"])

        let favourites = try #require(h.model.sidebar.collections.first { $0.name == "Favourites" }?.id)
        h.model.sidebarSelection = .collection(favourites)
        await h.model.settle()
        #expect(h.titles == ["Quiet Rivers", "Salt Road", "The Lighthouse Keeper"])

        h.model.sidebarSelection = .browse(.authors, "Ines Calloway")
        await h.model.settle()
        #expect(h.titles == ["Harbour of Glass", "Salt Road", "The Drowned Bell"])
    }

    /// A5
    @Test func theSearchTextNarrowsTheRows() async throws {
        let h = try await Harness.demo()
        h.model.searchText = "calloway"
        await h.model.settle()
        #expect(h.titles == ["Harbour of Glass", "Salt Road", "The Drowned Bell"])

        h.model.sidebarSelection = .finished
        await h.model.settle()
        #expect(h.titles == ["Salt Road"])

        h.model.searchText = ""
        await h.model.settle()
        #expect(h.titles == ["Quiet Rivers", "Salt Road", "The Lighthouse Keeper"])
    }

    /// A5: sorting is immediate.
    @Test func theSortOrdersTheRows() async throws {
        let h = try await Harness.demo()
        h.model.sort = BookSort(key: .title, ascending: false)
        #expect(h.titles.first == "Voices from the Attic")
        #expect(h.model.rows == BookSort(key: .title, ascending: false).sorted(h.model.rows))

        h.model.sort = BookSort(key: .author, ascending: true)
        #expect(h.model.rows == BookSort(key: .author, ascending: true).sorted(h.model.rows))
        #expect(h.model.rows.last?.book.title == "Voices from the Attic")

        // Rows that arrive later are sorted the same way.
        h.model.searchText = "calloway"
        await h.model.settle()
        h.model.sort = BookSort(key: .series, ascending: false)
        #expect(h.titles == ["Harbour of Glass", "The Drowned Bell", "Salt Road"])
        h.model.searchText = ""
        await h.model.settle()
        #expect(h.model.rows == BookSort(key: .series, ascending: false).sorted(h.model.rows))
    }

    /// A5
    @Test func selectedBooksThatLeaveTheRowsAreDropped() async throws {
        let h = try await Harness.demo()
        let ids = try await h.select(["Salt Road", "Quiet Rivers", "Night Train to Vostok"])
        #expect(h.model.selection == ids)

        h.model.sidebarSelection = .finished
        await h.model.settle()
        #expect(h.model.selection == (try h.ids(["Salt Road", "Quiet Rivers"])))
        #expect(h.bulkDraft?.books.map(\.title) == ["Quiet Rivers", "Salt Road"])

        h.model.searchText = "salt"
        await h.model.settle()
        #expect(h.model.selection == [try h.id("Salt Road")])
        #expect(h.draft?.title == "Salt Road")

        h.model.searchText = "zzzz"
        await h.model.settle()
        #expect(h.model.rows.isEmpty)
        #expect(h.model.selection.isEmpty)
        #expect(h.model.inspecting == .nothing)
    }

    /// A5: a slow answer to an old question does not replace the answer to a newer one.
    @Test func anOlderReloadThatFinishesLastIsDiscarded() async throws {
        let h = try await Harness.demo()
        let gate = Gate()
        h.model.beforeApplyingRows = { search in
            if search == "salt" { await gate.wait() }
        }

        h.model.searchText = "salt"
        await gate.arrival()
        h.model.searchText = "quiet"
        await h.model.latestReload?.value
        #expect(h.titles == ["Quiet Rivers"])

        await gate.release()
        await h.model.settle()
        #expect(h.titles == ["Quiet Rivers"])
        #expect(h.model.searchText == "quiet")
    }

    /// A5: setting the same value again asks nothing of the library.
    @Test func settingTheSameValueDoesNotReload() async throws {
        let h = try await Harness.demo()
        let before = h.model.latestReload
        h.model.searchText = ""
        h.model.sidebarSelection = .allBooks
        #expect(h.model.latestReload == before)
    }

    // MARK: A6 Remembered settings

    /// A6
    @Test func settingsStartWithTheirDefaults() throws {
        let h = try Harness(root: try makeTempDir(), choose: false)
        #expect(h.model.viewMode == .grid)
        #expect(h.model.sort == BookSort(key: .title, ascending: true))
        #expect(h.model.copyOnImport == false)
    }

    /// A6
    @Test func settingsAreStoredAndRestored() throws {
        let h = try Harness(root: try makeTempDir(), choose: false)
        h.model.viewMode = .list
        h.model.sort = BookSort(key: .dateAdded, ascending: false)
        h.model.copyOnImport = true

        #expect(h.defaults.string(forKey: "viewMode") == "list")
        #expect(h.defaults.string(forKey: "sortKey") == "dateAdded")
        #expect(h.defaults.object(forKey: "sortAscending") as? Bool == false)
        #expect(h.defaults.object(forKey: "copyOnImport") as? Bool == true)

        let again = h.relaunched()
        #expect(again.viewMode == .list)
        #expect(again.sort == BookSort(key: .dateAdded, ascending: false))
        #expect(again.copyOnImport == true)
    }

    /// A6: a stored value this version does not know is ignored.
    @Test func unknownStoredSettingsFallBackToDefaults() throws {
        let h = try Harness(root: try makeTempDir(), choose: false)
        h.defaults.set("carousel", forKey: "viewMode")
        h.defaults.set("colour", forKey: "sortKey")
        let again = h.relaunched()
        #expect(again.viewMode == .grid)
        #expect(again.sort == BookSort())
    }

    // MARK: Selecting (A7 through the model)

    /// A7
    @Test func clicksSelectInRowOrder() async throws {
        let h = try await Harness.demo()
        let order = h.model.rows.map(\.id)
        h.model.click(order[1], modifiers: [])
        #expect(h.model.selection == [order[1]])
        h.model.click(order[4], modifiers: .shift)
        #expect(h.model.selection == Set(order[1...4]))
        h.model.click(order[2], modifiers: .command)
        #expect(h.model.selection == [order[1], order[3], order[4]])
        // The command-click moved the anchor.
        h.model.click(order[0], modifiers: .shift)
        #expect(h.model.selection == Set(order[0...2]))
    }

    /// A7: the list view and the keyboard set a selection outright.
    @Test func selectAndSelectAll() async throws {
        let h = try await Harness.demo()
        let order = h.model.rows.map(\.id)
        h.model.select([order[0], order[5], 999_999])
        #expect(h.model.selection == [order[0], order[5]])

        h.model.searchText = "calloway"
        await h.model.settle()
        h.model.selectAll()
        #expect(h.model.selection == Set(h.model.rows.map(\.id)))
        #expect(h.model.selection.count == 3)

        h.model.select([])
        #expect(h.model.selection.isEmpty)
    }

    // MARK: A8 Unsaved changes

    /// A8
    @Test func aSelectionChangeWithUnsavedChangesWaitsForAnAnswer() async throws {
        let h = try await Harness.demo()
        let salt = try await h.edit("Salt Road", newTitle: "Salt Road Revised")
        let quiet = try h.id("Quiet Rivers")
        #expect(h.model.hasUnsavedChanges)

        h.model.click(quiet, modifiers: [])
        #expect(h.model.prompt == .unsavedChanges)
        #expect(h.model.selection == [salt])
        #expect(h.draft?.title == "Salt Road Revised")

        // Clicking the book that is already selected asks nothing.
        await h.model.resolveUnsaved(.cancel)
        h.model.click(salt, modifiers: [])
        #expect(h.model.prompt == nil)
    }

    /// A8
    @Test func cancelForgetsTheRequestedSelection() async throws {
        let h = try await Harness.demo()
        let salt = try await h.edit("Salt Road", newTitle: "Salt Road Revised")
        h.model.click(try h.id("Quiet Rivers"), modifiers: [])

        await h.model.resolveUnsaved(.cancel)
        #expect(h.model.prompt == nil)
        #expect(h.model.selection == [salt])
        #expect(h.draft?.title == "Salt Road Revised")
        #expect(h.model.hasUnsavedChanges)
        #expect(try h.book(salt).title == "Salt Road")
    }

    /// A8: dismissing the question without answering it is a cancel.
    @Test func dismissingTheQuestionIsACancel() async throws {
        let h = try await Harness.demo()
        let salt = try await h.edit("Salt Road", newTitle: "Salt Road Revised")
        h.model.searchText = "quiet"
        await h.model.settle()
        #expect(h.model.prompt == .unsavedChanges)

        h.model.prompt = nil
        #expect(h.model.searchText == "")
        #expect(h.model.selection == [salt])
        #expect(h.model.hasUnsavedChanges)
    }

    /// A8
    @Test func discardAppliesTheRequestedSelection() async throws {
        let h = try await Harness.demo()
        let salt = try await h.edit("Salt Road", newTitle: "Salt Road Revised")
        let quiet = try h.id("Quiet Rivers")
        h.model.click(quiet, modifiers: [])

        await h.model.resolveUnsaved(.discard)
        #expect(h.model.prompt == nil)
        #expect(h.model.selection == [quiet])
        #expect(h.draft?.title == "Quiet Rivers")
        #expect(!h.model.hasUnsavedChanges)
        #expect(try h.book(salt).title == "Salt Road")
    }

    /// A8
    @Test func saveSavesAndThenAppliesTheRequestedSelection() async throws {
        let h = try await Harness.demo()
        let salt = try await h.edit("Salt Road", newTitle: "Salt Road Revised")
        let quiet = try h.id("Quiet Rivers")
        h.model.click(quiet, modifiers: [])

        await h.model.resolveUnsaved(.save)
        #expect(h.model.alert == nil)
        #expect(try h.book(salt).title == "Salt Road Revised")
        #expect(h.model.selection == [quiet])
        #expect(h.draft?.title == "Quiet Rivers")
        #expect(h.titles.contains("Salt Road Revised"))
    }

    /// A8: a save that leaves the edits unsaved leaves the selection where it was.
    @Test func aSaveThatDoesNotGoThroughKeepsTheSelection() async throws {
        let h = try await Harness.demo()
        let salt = try await h.edit("Salt Road", newTitle: "   ")
        h.model.click(try h.id("Quiet Rivers"), modifiers: [])

        await h.model.resolveUnsaved(.save)
        #expect(h.model.alert == "A book needs a title.")
        #expect(h.model.prompt == nil)
        #expect(h.model.selection == [salt])
        #expect(h.model.hasUnsavedChanges)
        #expect(try h.book(salt).title == "Salt Road")
    }

    /// A8: a command-click that would add to the selection also waits, and so does Select All.
    @Test func everyKindOfSelectionChangeWaits() async throws {
        let h = try await Harness.demo()
        let salt = try await h.edit("Salt Road", newTitle: "Salt Road Revised")
        let quiet = try h.id("Quiet Rivers")

        h.model.click(quiet, modifiers: .command)
        #expect(h.model.prompt == .unsavedChanges)
        await h.model.resolveUnsaved(.cancel)

        h.model.selectAll()
        #expect(h.model.prompt == .unsavedChanges)
        await h.model.resolveUnsaved(.cancel)

        h.model.select([quiet])
        #expect(h.model.prompt == .unsavedChanges)
        #expect(h.model.selection == [salt])
        await h.model.resolveUnsaved(.discard)
        #expect(h.model.selection == [quiet])
    }

    /// A8: a search that would drop the edited book from the selection.
    @Test func aSearchThatWouldDropTheEditedBookWaits() async throws {
        let h = try await Harness.demo()
        let salt = try await h.edit("Salt Road", newTitle: "Salt Road Revised")

        h.model.searchText = "quiet"
        await h.model.settle()
        #expect(h.model.prompt == .unsavedChanges)
        #expect(h.model.rows.count == 12)
        #expect(h.model.selection == [salt])
        #expect(h.draft?.title == "Salt Road Revised")

        await h.model.resolveUnsaved(.cancel)
        #expect(h.model.searchText == "")
        #expect(h.model.rows.count == 12)
        #expect(h.model.hasUnsavedChanges)

        h.model.searchText = "quiet"
        await h.model.settle()
        await h.model.resolveUnsaved(.discard)
        #expect(h.model.searchText == "quiet")
        #expect(h.titles == ["Quiet Rivers"])
        #expect(h.model.selection.isEmpty)
        #expect(h.model.inspecting == .nothing)
        #expect(try h.book(salt).title == "Salt Road")
    }

    /// A8: a search that keeps the edited book in view asks nothing and keeps the edits.
    @Test func aSearchThatKeepsTheEditedBookDoesNotAsk() async throws {
        let h = try await Harness.demo()
        let salt = try await h.edit("Salt Road", newTitle: "Salt Road Revised")
        h.model.searchText = "calloway"
        await h.model.settle()
        #expect(h.model.prompt == nil)
        #expect(h.model.rows.count == 3)
        #expect(h.model.selection == [salt])
        #expect(h.draft?.title == "Salt Road Revised")
    }

    /// A8: the same for the sidebar; Save saves and then shows the new rows.
    @Test func aSidebarChangeThatWouldDropTheEditedBookWaits() async throws {
        let h = try await Harness.demo()
        let salt = try await h.edit("Salt Road", newTitle: "Salt Road Revised")

        h.model.sidebarSelection = .ebooks
        await h.model.settle()
        #expect(h.model.prompt == .unsavedChanges)
        #expect(h.model.rows.count == 12)

        await h.model.resolveUnsaved(.cancel)
        #expect(h.model.sidebarSelection == .allBooks)

        h.model.sidebarSelection = .ebooks
        await h.model.settle()
        await h.model.resolveUnsaved(.save)
        #expect(try h.book(salt).title == "Salt Road Revised")
        #expect(h.model.sidebarSelection == .ebooks)
        #expect(h.model.rows.count == 4)
        #expect(h.model.selection.isEmpty)

        // A change that keeps the edited book asks nothing.
        h.model.sidebarSelection = .allBooks
        await h.model.settle()
        try await h.edit("Quiet Rivers", newTitle: "Quieter Rivers")
        h.model.sidebarSelection = .ebooks
        await h.model.settle()
        #expect(h.model.prompt == nil)
        #expect(h.draft?.title == "Quieter Rivers")
    }

    /// A8: an edit to several books is protected in the same way.
    @Test func aBulkEditIsProtectedToo() async throws {
        let h = try await Harness.demo()
        let ids = try await h.select(["Salt Road", "Quiet Rivers"])
        h.model.updateBulkDraft { $0.values[.genre] = "Sea Stories" }
        #expect(h.model.hasUnsavedChanges)

        h.model.click(try h.id("Night Train to Vostok"), modifiers: [])
        #expect(h.model.prompt == .unsavedChanges)
        #expect(h.model.selection == ids)
        await h.model.resolveUnsaved(.cancel)
        #expect(h.bulkDraft?.values[.genre] == "Sea Stories")

        h.model.searchText = "salt"
        await h.model.settle()
        #expect(h.model.prompt == .unsavedChanges)
        await h.model.resolveUnsaved(.save)
        let genres = try ids.map { try h.book($0).genre }
        #expect(genres == ["Sea Stories", "Sea Stories"])
        #expect(h.model.searchText == "salt")
        #expect(h.model.selection == [try h.id("Salt Road")])
    }

    // MARK: A24 One question at a time

    /// A24: nothing asks a second question while one is waiting; here, removing while
    /// the unsaved-changes question is up.
    @Test func aRemoveRequestWaitsForTheUnsavedChangesQuestion() async throws {
        let h = try await Harness.demo()
        try await h.edit("Salt Road", newTitle: "Salt Road X")
        h.model.sidebarSelection = .ebooks
        await h.model.settle()
        #expect(h.model.prompt == .unsavedChanges)
        #expect(!h.model.commands(for: [try h.id("Quiet Rivers")]).remove)

        h.model.requestRemove([try h.id("Quiet Rivers")])
        #expect(h.model.prompt == .unsavedChanges)

        h.model.prompt = nil
        await h.model.settle()
        #expect(h.model.pending == nil)
        #expect(h.model.sidebarSelection == .allBooks)
        #expect(h.model.rows.count == 12)
        #expect(h.draft?.title == "Salt Road X")
        #expect(h.model.commands(for: [try h.id("Quiet Rivers")]).remove)
    }

    /// A24: the other order. A change of sidebar or search that would need the
    /// unsaved-changes question while another question is up is taken back.
    @Test func aBrowseChangeDuringAnotherQuestionIsTakenBack() async throws {
        let h = try await Harness.demo()
        try await h.edit("Salt Road", newTitle: "Salt Road X")
        let quiet = try h.id("Quiet Rivers")
        h.model.requestRemove([quiet])
        let question = h.model.prompt
        #expect(question == .removeBooks(ids: [quiet], titles: ["Quiet Rivers"]))

        h.model.sidebarSelection = .ebooks
        h.model.searchText = "quiet"
        await h.model.settle()
        #expect(h.model.prompt == question)
        #expect(h.model.pending == nil)
        #expect(h.model.sidebarSelection == .allBooks)
        #expect(h.model.searchText == "")
        #expect(h.model.rows.count == 12)

        // Nor does a click replace the question.
        h.model.click(quiet, modifiers: [])
        await h.model.settle()
        #expect(h.model.prompt == question)
        #expect(h.model.pending == nil)
        #expect(h.model.selection == [try h.id("Salt Road")])

        await h.model.confirmRemove(moveFilesToTrash: false)
        #expect(try h.store().book(id: quiet) == nil)
        #expect(h.draft?.title == "Salt Road X")
    }

    /// A24: a second change of search while the unsaved-changes question about the first
    /// is up is the one the answer applies.
    @Test func theLatestBrowseChangeIsTheOneAsked() async throws {
        let h = try await Harness.demo()
        try await h.edit("Salt Road", newTitle: "Salt Road X")
        h.model.searchText = "q"
        await h.model.settle()
        #expect(h.model.prompt == .unsavedChanges)
        h.model.searchText = "quiet"
        await h.model.settle()
        #expect(h.model.prompt == .unsavedChanges)
        await h.model.resolveUnsaved(.discard)
        #expect(h.model.searchText == "quiet")
        #expect(h.titles == ["Quiet Rivers"])
    }

    /// A24: a library is not chosen while a question is waiting.
    @Test func aLibraryIsNotChosenWhileAQuestionIsWaiting() async throws {
        let h = try await Harness.demo()
        let other = try await Harness.demo(start: false)
        let id = try h.id("Salt Road")
        h.model.requestRemove([id])
        #expect(!h.model.canChooseLibrary)

        await h.model.chooseLibrary(other.root)
        #expect(h.model.status == .available(h.root))
        #expect(h.model.alert == "Answer the question in the VoxCarrel window first, then choose the library folder again.")
        #expect(h.model.prompt == .removeBooks(ids: [id], titles: ["Salt Road"]))
        h.model.prompt = nil
        #expect(h.model.canChooseLibrary)
    }

    /// A24, A1: opening a library leaves nothing of the one before: no question, no
    /// message, no result and no import under review.
    @Test func openingALibraryForgetsQuestionsAndMessages() async throws {
        let h = try await Harness.demo()
        let id = try h.id("Salt Road")
        await h.model.beginImport([try Harness.inbox()])
        #expect(h.model.review != nil)
        h.model.requestRemove([id])
        h.model.alert = "Something about the old library."
        h.model.result = ResultSummary(headline: "Old", problems: [], isClean: false)

        await h.model.start()
        #expect(h.model.prompt == nil)
        #expect(h.model.alert == nil)
        #expect(h.model.result == nil)
        #expect(h.model.review == nil)
        #expect(h.model.pending == nil)

        // An answer to the question that is gone does nothing.
        await h.model.confirmRemove(moveFilesToTrash: false)
        #expect(try h.store().book(id: id) != nil)
    }

    /// A24: "use this folder" is an answer only to the question that was asked.
    @Test func usingAFolderNeedsItsQuestion() async throws {
        let h = try await Harness.demo()
        let folder = try makeTempDir()
        try touch(folder.appendingPathComponent("notes.txt"))
        await h.model.confirmChooseLibrary(folder)
        #expect(h.model.status == .available(h.root))
        await h.model.chooseLibrary(folder)
        await h.model.confirmChooseLibrary(try makeTempDir())
        #expect(h.model.status == .available(h.root))
        await h.model.confirmChooseLibrary(folder)
        #expect(h.model.status == .available(folder))
    }
}
