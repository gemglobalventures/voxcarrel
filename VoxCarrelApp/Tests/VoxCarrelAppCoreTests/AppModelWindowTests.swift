import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// What the window shell asks of the model (plan Task 8): titles, and which menu
/// commands apply. W1–W7.
@MainActor
@Suite struct AppModelWindowTests {
    // MARK: W1 Names

    /// W1
    @Test func fixedItemsAndBrowseFieldsHaveNames() async throws {
        let h = try await Harness.demo()
        let names = SidebarItem.fixed.map { h.model.title(of: $0) }
        #expect(
            names == [
                "All Books", "Audiobooks", "Ebooks", "On Audible", "Unread", "In Progress", "Finished",
                "Needs Attention",
            ])
        #expect(BrowseField.sidebarOrder.map(\.title) == ["Authors", "Series", "Narrators", "Genres"])
        #expect(Set(BrowseField.sidebarOrder) == Set(BrowseField.allCases))
    }

    /// W1: a browse value is named by the value, a collection by its name.
    @Test func browseValuesAndCollectionsAreNamedByWhatTheyAre() async throws {
        let h = try await Harness.demo()
        #expect(h.model.title(of: .browse(.authors, "Ines Calloway")) == "Ines Calloway")
        let favourites = try #require(h.model.sidebar.collections.first { $0.name == "Favourites" }?.id)
        #expect(h.model.title(of: .collection(favourites)) == "Favourites")
        // A collection that is not there has no name of its own.
        #expect(h.model.title(of: .collection(-1)) == "Collection")
    }

    // MARK: W2 Window title

    /// W2
    @Test func windowTitleFollowsTheSidebarAndTheSubtitleCountsTheRows() async throws {
        let h = try await Harness.demo()
        #expect(h.model.windowTitle == "All Books")
        #expect(h.model.windowSubtitle == "12 books")

        h.model.sidebarSelection = .needsAttention
        await h.model.settle()
        #expect(h.model.windowTitle == "Needs Attention")
        #expect(h.model.windowSubtitle == "1 book")

        h.model.searchText = "no book is called this"
        await h.model.settle()
        #expect(h.model.windowSubtitle == "No books")
    }

    // MARK: W3 Library folder

    /// W3
    @Test func libraryFolderIsTheChosenFolderWhetherOrNotItIsThere() async throws {
        let h = try await Harness.demo()
        #expect(h.model.libraryFolder == h.root)
        #expect(h.model.isLibraryOpen)

        let gone = try makeTempDir().appendingPathComponent("Gone", isDirectory: true)
        let missing = try Harness(root: gone)
        await missing.model.start()
        #expect(missing.model.libraryFolder == gone)
        #expect(!missing.model.isLibraryOpen)

        let none = try Harness(root: try makeTempDir(), choose: false)
        await none.model.start()
        #expect(none.model.libraryFolder == nil)
        #expect(!none.model.isLibraryOpen)
    }

    /// W3
    @Test func revealLibraryFolderShowsItInTheFinder() async throws {
        let h = try await Harness.demo()
        h.model.revealLibraryFolder()
        #expect(h.opener.revealed == [[h.root]])

        let none = try Harness(root: try makeTempDir(), choose: false)
        none.model.revealLibraryFolder()
        #expect(none.opener.revealed.isEmpty)
    }

    // MARK: W4 Undo

    /// W4
    @Test func undoMenuTitleNamesTheOperation() async throws {
        let h = try await Harness.demo()
        #expect(h.model.undoMenuTitle == "Undo \(Harness.demoUndoLabel)")
        #expect(h.model.canUndo)

        let empty = try await Harness.empty()
        #expect(empty.model.undoLabel == nil)
        #expect(empty.model.undoMenuTitle == "Undo")
        #expect(!empty.model.canUndo)
    }

    /// W4, W5
    @Test func nothingThatChangesTheLibraryIsOfferedWhileBusy() async throws {
        let h = try await Harness.demo()
        try await h.select("Quiet Rivers")
        #expect(h.model.canImport)
        #expect(h.model.selectionCommands.remove)

        let gate = Gate()
        h.model.beforeOperation = { await gate.wait() }
        let operation = Task { await h.model.rewriteTags() }
        await gate.arrival()
        #expect(!h.model.canUndo)
        #expect(!h.model.canImport)
        let commands = h.model.selectionCommands
        #expect(!commands.mark && !commands.addToCollection && !commands.rewriteTags && !commands.remove)
        // Opening and revealing change nothing, so they stay.
        #expect(commands.reveal)
        await gate.release()
        await operation.value
        #expect(h.model.canUndo)
        #expect(h.model.canImport)
    }

    // MARK: W5 Import

    /// W5
    @Test func importNeedsAnOpenLibraryAndNoReviewAlreadyOpen() async throws {
        let none = try Harness(root: try makeTempDir(), choose: false)
        await none.model.start()
        #expect(!none.model.canImport)

        let h = try await Harness.empty()
        #expect(h.model.canImport)
        await h.model.beginImport([try Harness.inbox()])
        #expect(h.model.review != nil)
        #expect(!h.model.canImport)
        h.model.cancelImport()
        #expect(h.model.canImport)
    }

    // MARK: W6 Book commands

    /// W6
    @Test func noCommandAppliesToAnEmptySelection() async throws {
        let h = try await Harness.demo()
        #expect(h.model.selectionCommands == SelectionCommands())
    }

    /// W6: Listen and Read follow the forms the one selected book has.
    @Test func openListenAndReadFollowTheSelectedBooksForms() async throws {
        let h = try await Harness.demo()
        let audioOnly = try #require(h.model.rows.first { $0.hasAudio && !$0.hasEbook })
        let ebookOnly = try #require(h.model.rows.first { !$0.hasAudio && $0.hasEbook })
        let both = try #require(h.model.rows.first { $0.hasAudio && $0.hasEbook })

        h.model.select([audioOnly.id])
        await h.model.settle()
        var commands = h.model.selectionCommands
        #expect(commands.open && commands.listen && !commands.read)
        #expect(commands.reveal && commands.mark && commands.addToCollection && commands.rewriteTags)
        #expect(commands.remove)

        h.model.select([ebookOnly.id])
        await h.model.settle()
        commands = h.model.selectionCommands
        #expect(commands.open && !commands.listen && commands.read)

        h.model.select([both.id])
        await h.model.settle()
        commands = h.model.selectionCommands
        #expect(commands.open && commands.listen && commands.read)
    }

    /// W6: one book is opened at a time; the rest apply to any number.
    @Test func severalBooksCannotBeOpenedAtOnce() async throws {
        let h = try await Harness.demo()
        h.model.select(Set(h.model.rows.prefix(3).map(\.id)))
        await h.model.settle()
        let commands = h.model.selectionCommands
        #expect(!commands.open && !commands.listen && !commands.read)
        #expect(commands.reveal && commands.mark && commands.addToCollection && commands.rewriteTags)
        #expect(commands.remove)
    }

    /// W6
    @Test func addToCollectionNeedsACollection() async throws {
        let h = try await Harness.demo()
        try await h.select("Quiet Rivers")
        for collection in h.model.sidebar.collections {
            await h.model.deleteCollection(id: try #require(collection.id))
        }
        #expect(h.model.sidebar.collections.isEmpty)
        #expect(!h.model.selectionCommands.addToCollection)
        #expect(h.model.selectionCommands.mark)
    }

    // MARK: W7 Acting on the selection

    /// W7
    @Test func openListenAndReadSelectionActOnTheOneSelectedBook() async throws {
        let h = try await Harness.demo()
        let both = try #require(h.model.rows.first { $0.hasAudio && $0.hasEbook })
        h.model.select([both.id])
        await h.model.settle()
        let files = try h.store().files(bookId: both.id)
        let audio = try #require(files.first { $0.role == .audio })
        let ebook = try #require(files.first { $0.role == .ebook })

        h.model.openSelection()
        await h.model.settle()
        h.model.listenSelection()
        await h.model.settle()
        h.model.readSelection()
        await h.model.settle()
        let names = h.opener.opened.map(\.lastPathComponent)
        let audioName = (audio.path as NSString).lastPathComponent
        let ebookName = (ebook.path as NSString).lastPathComponent
        #expect(names == [audioName, audioName, ebookName])
    }

    /// W7
    @Test func openSelectionDoesNothingForSeveralBooksOrNone() async throws {
        let h = try await Harness.demo()
        h.model.openSelection()
        h.model.select(Set(h.model.rows.prefix(2).map(\.id)))
        await h.model.settle()
        h.model.openSelection()
        h.model.listenSelection()
        h.model.readSelection()
        await h.model.settle()
        #expect(h.opener.opened.isEmpty)
        #expect(h.model.alert == nil)
    }

    // MARK: W9 Starting once

    /// W9: the window's task runs again each time the window is opened; the library is
    /// opened only the first time, so reopening the window loses nothing.
    @Test func startIfNeededStartsOnlyTheFirstTime() async throws {
        let h = try await Harness.demo(start: false)
        #expect(!h.model.isLibraryOpen)
        await h.model.startIfNeeded()
        #expect(h.model.isLibraryOpen)
        #expect(h.model.rows.count == 12)

        // What the user has done since is still there after the window is closed and opened again.
        let id = try await h.edit("Quiet Rivers", newTitle: "Loud Rivers")
        h.model.sidebarSelection = .ebooks
        await h.model.settle()
        await h.model.startIfNeeded()
        #expect(h.model.sidebarSelection == .ebooks)
        #expect(h.model.selection == [id])
        #expect(h.draft?.title == "Loud Rivers")
    }
}

/// W8: the words of each question the window puts to the user.
@Suite struct PendingPromptTextTests {
    @Test func unsavedChangesAsksAboutSaving() {
        let prompt = PendingPrompt.unsavedChanges
        #expect(prompt.title == "Do you want to save your changes?")
        #expect(prompt.message == "Your changes will be lost if you do not save them.")
    }

    @Test func removingNamesOneBookAndCountsSeveral() {
        let one = PendingPrompt.removeBooks(ids: [1], titles: ["Quiet Rivers"])
        #expect(one.title == "Remove “Quiet Rivers” from the library?")
        let untitled = PendingPrompt.removeBooks(ids: [1], titles: ["  "])
        #expect(untitled.title == "Remove this book from the library?")
        let several = PendingPrompt.removeBooks(ids: [1, 2, 3], titles: ["A", "B", "C"])
        #expect(several.title == "Remove 3 books from the library?")
        #expect(one.message == several.message)
        #expect(one.message.contains("Trash"))
    }

    @Test func aFolderWithFilesSaysWhatWillHappenToThem() {
        let folder = URL(fileURLWithPath: "/tmp/Old Books", isDirectory: true)
        let one = PendingPrompt.chooseFolderWithFiles(folder, count: 1, bookFiles: 1)
        #expect(one.title == "Use \"Old Books\" as your library?")
        #expect(
            one.message
                == "This folder already holds 1 item, including 1 audiobook or ebook file. "
                + "VoxCarrel will list those files when the library opens and, only if you then choose Import, "
                + "move and rename them into its own layout. To keep them as they are, choose an empty folder "
                + "instead and import with Copy."
        )
        let several = PendingPrompt.chooseFolderWithFiles(folder, count: 14, bookFiles: 230)
        #expect(several.message.hasPrefix("This folder already holds 14 items, including 230 audiobook and ebook files. "))
        let many = PendingPrompt.chooseFolderWithFiles(folder, count: 14, bookFiles: 1001)
        #expect(many.message.contains("including more than 1,000 audiobook and ebook files"))
        let none = PendingPrompt.chooseFolderWithFiles(folder, count: 2, bookFiles: 0)
        #expect(
            none.message
                == "This folder already holds 2 items, none of them audiobooks or ebooks. They will be left as they "
                + "are. An empty folder just for your library is the tidier choice.")
    }
}
