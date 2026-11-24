import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// G23–G27: Manage Genres, as its sheet's state decides it.
@MainActor
@Suite struct GenreManagerTests {
    private func row(_ manager: GenreManager, _ name: String) throws -> GenreManagerRow {
        try #require(manager.groups.flatMap(\.rows).first { $0.name == name }, "no row for \(name)")
    }

    // MARK: G23 The list

    @Test func GH23_everyGenreIsListedByGroupWithItsNumberOfBooks() async throws {
        let h = try await Harness.demo()
        #expect(h.model.canManageGenres)
        let manager = try h.manager()
        #expect(manager.title == "Manage Genres")
        #expect(manager.groups.map(\.title) == ["Fiction", "Non-fiction", "Children & Young Adult"])
        #expect(manager.groups.map(\.rows.count) == [10, 15, 2])
        // Every genre, with or without books, in the built-in order.
        #expect(manager.groups[0].rows.map(\.name) == BuiltInGenre.all.filter { $0.group == .fiction }.map(\.name))
        #expect(try row(manager, "Fantasy").countText == "3 books")
        #expect(try row(manager, "Historical Fiction").countText == "1 book")
        #expect(try row(manager, "Classics").countText == "No books")
        #expect(try row(manager, "Fantasy").count == 3)

        h.model.closeManageGenres()
        #expect(h.model.genreManager == nil)
    }

    @Test func GH23_theOwnersOwnGenresAreListedAfterTheBuiltInOnesAndOtherWhenItHasAny() async throws {
        let h = try await Harness.demo()
        try await h.give("Sea Stories", in: .fiction, to: ["Salt Road"])
        #expect(await h.model.createGenre("Pub Quiz", group: .other) == "Pub Quiz")
        let manager = try h.manager()
        #expect(manager.groups.map(\.title) == ["Fiction", "Non-fiction", "Children & Young Adult", "Other"])
        #expect(manager.groups[0].rows.last?.name == "Sea Stories")
        #expect(manager.groups[3].rows.map(\.name) == ["Pub Quiz"])
        #expect(manager.groups[3].rows.map(\.countText) == ["No books"])
    }

    @Test func GH23_eachGenreOffersRenameMergeAndMoveAndOnlyAnOwnOneDelete() async throws {
        let h = try await Harness.demo()
        try await h.give("Sea Stories", in: .fiction, to: ["Salt Road"])
        let manager = try h.manager()

        let fantasy = try row(manager, "Fantasy")
        // G26: a built-in genre offers no Delete.
        #expect(!fantasy.canDelete)
        #expect(fantasy.isBuiltIn)
        #expect(try row(manager, "Sea Stories").canDelete)
        #expect(!(try row(manager, "Sea Stories").isBuiltIn))

        // Every group but its own.
        #expect(manager.moveTargets(for: "Fantasy").map(\.title) == ["Non-fiction", "Children & Young Adult", "Other"])
        #expect(manager.moveTargets(for: "Fantasy").map(\.group) == [.nonFiction, .children, .other])
        // Every other genre that is shown, by group.
        let targets = manager.mergeTargets(for: "Fantasy")
        #expect(targets.map(\.title) == ["Fiction", "Non-fiction", "Children & Young Adult"])
        #expect(targets[0].genres.count == 10)
        #expect(!targets[0].genres.contains("Fantasy"))
        #expect(targets[0].genres.last == "Sea Stories")

        // A built-in genre is never deleted, even if asked.
        manager.requestDelete("Fantasy")
        #expect(manager.question == nil)
    }

    // MARK: G24 Rename

    @Test func GH24_renameChangesTheNameEverywhereAsOneUndoableOperation() async throws {
        let h = try await Harness.demo()
        let manager = try h.manager()
        manager.beginRename("Fantasy")
        #expect(manager.renaming == "Fantasy")
        #expect(manager.renameText == "Fantasy")
        // The same name is nothing to do.
        #expect(!manager.canCommitRename)
        manager.renameText = " Fantastic  Tales "
        #expect(manager.canCommitRename)
        await manager.commitRename()

        #expect(manager.renaming == nil)
        #expect(manager.problem == nil)
        #expect(try row(manager, "Fantastic Tales").countText == "3 books")
        #expect(!manager.groups.flatMap(\.rows).contains { $0.name == "Fantasy" })
        // A renamed built-in genre says what it shipped as.
        #expect(try row(manager, "Fantastic Tales").builtInNote == "Built in as \"Fantasy\"")
        #expect(try row(manager, "History").builtInNote == nil)
        #expect(try h.book(try h.id("Salt Road")).genres == ["Fantastic Tales"])
        #expect(h.treeNames[0].contains("Fantastic Tales"))
        // G27
        #expect(h.model.undoLabel == "Rename genre")
        #expect(manager.undoTitle == "Undo Rename genre")
        #expect(manager.canUndo)

        await manager.undo()
        #expect(try row(manager, "Fantasy").countText == "3 books")
        #expect(try h.book(try h.id("Salt Road")).genres == ["Fantasy"])
        #expect(!manager.canUndo)
    }

    @Test func GH24_aNameThatCannotBeAGenresIsRefusedWithTheReason() async throws {
        let h = try await Harness.demo()
        let manager = try h.manager()
        manager.beginRename("Fantasy")
        manager.renameText = "Swords/Sorcery"
        await manager.commitRename()
        #expect(manager.problem == "A genre's name cannot be empty, and cannot have a comma, a semicolon or a slash in it.")
        // Still being renamed, and nothing has changed.
        #expect(manager.renaming == "Fantasy")
        #expect(try h.book(try h.id("Salt Road")).genres == ["Fantasy"])
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
        #expect(h.model.alert == nil)

        // Typing again takes the reason away.
        manager.renameText = "Swords"
        #expect(manager.problem == nil)
        manager.cancelRename()
        #expect(manager.renaming == nil)
        #expect(try row(manager, "Fantasy").count == 3)
    }

    @Test func GH24_renamingOntoAnotherGenresNameAsksWhetherToMerge() async throws {
        let h = try await Harness.demo()
        let manager = try h.manager()
        manager.beginRename("Fantasy")
        manager.renameText = "history"
        await manager.commitRename()

        let question = try #require(manager.question)
        #expect(question.title == "Merge \"Fantasy\" into \"History\"?")
        #expect(
            question.message
                == "There is already a genre called \"History\". Its 3 books move to \"History\", and \"Fantasy\" is "
                + "hidden until you reset the built-in names.")
        #expect(question.confirmTitle == "Merge")
        // Nothing merges without a yes.
        #expect(try row(manager, "Fantasy").count == 3)
        #expect(try row(manager, "History").count == 1)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)

        manager.cancelQuestion()
        #expect(manager.question == nil)
        #expect(try row(manager, "Fantasy").count == 3)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)

        manager.beginRename("Fantasy")
        manager.renameText = "History"
        await manager.commitRename()
        await manager.confirmQuestion()
        #expect(manager.question == nil)
        #expect(manager.renaming == nil)
        #expect(try row(manager, "History").count == 4)
        #expect(!manager.groups.flatMap(\.rows).contains { $0.name == "Fantasy" })
        #expect(h.model.undoLabel == "Merge genres")
    }

    @Test func GH24_resetPutsEveryBuiltInNameBackAndLeavesTheOwnersOwnAlone() async throws {
        let h = try await Harness.demo()
        try await h.give("Sea Stories", in: .fiction, to: ["Salt Road"])
        let manager = try h.manager()
        #expect(!manager.canReset)
        #expect(manager.resetTitle == "Reset to Built-in Names")

        manager.beginRename("Fantasy")
        manager.renameText = "Fantastic"
        await manager.commitRename()
        #expect(manager.canReset)

        await manager.reset()
        #expect(!manager.canReset)
        #expect(try row(manager, "Fantasy").count == 3)
        #expect(try row(manager, "Sea Stories").count == 1)
        #expect(try h.book(try h.id("Salt Road")).genres == ["Fantasy", "Sea Stories"])
        #expect(h.model.undoLabel == "Reset genre names")
    }

    // MARK: G25 Merge

    @Test func GH25_mergeMovesEveryBookWithoutADuplicateAndHidesABuiltInGenre() async throws {
        let h = try await Harness.demo()
        let manager = try h.manager()
        // Night Train to Vostok has both.
        await manager.merge("Thrillers & Spies", into: "Crime & Mystery")
        #expect(manager.problem == nil)
        #expect(try h.book(try h.id("Night Train to Vostok")).genres == ["Crime & Mystery"])
        #expect(try row(manager, "Crime & Mystery").count == 1)
        #expect(!manager.groups.flatMap(\.rows).contains { $0.name == "Thrillers & Spies" })
        #expect(h.model.undoLabel == "Merge genres")
        // A built-in genre merged away is hidden, not lost: Reset restores it, empty.
        #expect(manager.canReset)
        await manager.reset()
        #expect(try row(manager, "Thrillers & Spies").countText == "No books")
        #expect(try h.book(try h.id("Night Train to Vostok")).genres == ["Crime & Mystery"])
    }

    @Test func GH25_mergingIsUndoneWhole() async throws {
        let h = try await Harness.demo()
        let manager = try h.manager()
        await manager.merge("Thrillers & Spies", into: "Crime & Mystery")
        await manager.undo()
        #expect(try h.book(try h.id("Night Train to Vostok")).genres == ["Thrillers & Spies", "Crime & Mystery"])
        #expect(try row(manager, "Thrillers & Spies").count == 1)
    }

    // MARK: Move

    @Test func GH23_moveChangesAGenresGroupAndNothingOfABook() async throws {
        let h = try await Harness.demo()
        let manager = try h.manager()
        await manager.move("Fantasy", to: .children)
        #expect(manager.groups[2].rows.map(\.name) == ["Fantasy", "Children", "Young Adult"])
        #expect(h.model.genreTree.map(\.group) == [.fiction, .nonFiction, .children])
        #expect(h.model.genreTree.map(\.count) == [4, 4, 3])
        #expect(try h.book(try h.id("Salt Road")).genres == ["Fantasy"])
        #expect(h.model.undoLabel == "Move genre")
        // G27: its files hold the same tag: the group is not written.
        #expect(h.model.genreFilesToUpdate == 0)

        await manager.undo()
        #expect(h.model.genreTree.map(\.count) == [7, 4])
    }

    // MARK: G26 Delete

    @Test func GH26_deleteSaysHowManyBooksLoseTheGenreBeforeItRemovesIt() async throws {
        let h = try await Harness.demo()
        try await h.give("Sea Stories", in: .fiction, to: ["Salt Road", "Quiet Rivers"])
        let manager = try h.manager()
        manager.requestDelete("Sea Stories")
        let question = try #require(manager.question)
        #expect(question.title == "Delete \"Sea Stories\"?")
        #expect(question.message == "2 books lose this genre. Their files are not changed until you update them.")
        #expect(question.confirmTitle == "Delete")
        // Not yet.
        #expect(try row(manager, "Sea Stories").count == 2)

        await manager.confirmQuestion()
        #expect(!manager.groups.flatMap(\.rows).contains { $0.name == "Sea Stories" })
        #expect(try h.book(try h.id("Salt Road")).genres == ["Fantasy"])
        #expect(try h.book(try h.id("Quiet Rivers")).genres == ["Literary & General"])
        #expect(h.model.undoLabel == "Delete genre")
        // G27: the files that now differ are counted, not rewritten.
        #expect(h.model.genreFilesToUpdate == 2)
        #expect(manager.filesNote == "The files of 2 books now hold other genre tags. Choose Update files… in the sidebar to write them.")

        await manager.undo()
        #expect(try row(manager, "Sea Stories").count == 2)
        #expect(h.model.genreFilesToUpdate == 0)
        #expect(manager.filesNote == nil)
    }

    @Test func GH26_theQuestionCountsOneBookAndNone() async throws {
        let h = try await Harness.demo()
        try await h.give("Sea Stories", in: .fiction, to: ["Salt Road"])
        #expect(await h.model.createGenre("Pub Quiz", group: .other) == "Pub Quiz")
        let manager = try h.manager()
        manager.requestDelete("Sea Stories")
        #expect(manager.question?.message == "1 book loses this genre. Its files are not changed until you update them.")
        manager.cancelQuestion()
        manager.requestDelete("Pub Quiz")
        #expect(manager.question?.message == "No book has this genre.")
        await manager.confirmQuestion()
        #expect(manager.groups.map(\.title) == ["Fiction", "Non-fiction", "Children & Young Adult"])
    }

    // MARK: Standing

    @Test func GH23_manageGenresIsNotOpenedWhileSomethingElseHasTheLibrary() async throws {
        let h = try await Harness.demo()
        let gate = Gate()
        h.model.beforeOperation = { await gate.wait() }
        let ids = try h.ids(["Salt Road"])
        let running = Task { await h.model.setReadStatus(.finished, for: ids) }
        await gate.arrival()
        #expect(!h.model.canManageGenres)
        h.model.beginManageGenres()
        #expect(h.model.genreManager == nil)
        await gate.release()
        await running.value
        #expect(h.model.canManageGenres)
    }

    @Test func GH23_theManagerClosesWhenAnotherLibraryIsOpened() async throws {
        let h = try await Harness.demo()
        _ = try h.manager()
        await h.model.chooseLibrary(try makeTempDir())
        #expect(h.model.genreManager == nil)
    }
}
