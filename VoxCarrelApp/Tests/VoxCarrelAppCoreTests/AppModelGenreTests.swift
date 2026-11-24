import DemoContent
import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// G13, G17, G19–G22, G34–G37, GH-a to GH-d: genres in the sidebar, the inspector, the
/// import review and the lookup, in the app model.
@MainActor
@Suite struct AppModelGenreTests {
    static let fiction = [
        "Literary & General", "Crime & Mystery", "Thrillers & Spies", "Fantasy", "Historical Fiction",
    ]
    static let nonFiction = ["Biography & Memoir", "History", "Science & Nature", "Travel & Places"]
    static let tidewater = ["Harbour of Glass", "Salt Road", "The Drowned Bell"]

    // MARK: G34–G36 The sidebar's tree

    @Test func GH34_theTreeHasEachGroupThatHasBooksWithItsGenresAndCounts() async throws {
        let h = try await Harness.demo()
        let tree = h.model.genreTree
        #expect(tree.map(\.group) == [.fiction, .nonFiction])
        #expect(tree.map(\.title) == ["Fiction", "Non-fiction"])
        // GH-a: within a group, in the built-in order.
        #expect(h.treeNames == [Self.fiction, Self.nonFiction])
        #expect(tree[0].genres.map(\.count) == [2, 1, 1, 3, 1])
        #expect(tree[1].genres.map(\.count) == [1, 1, 1, 1])
        // G35: a book with two genres of a group is counted once in the group.
        #expect(tree.map(\.count) == [7, 4])
        // Open until the owner closes one.
        #expect(tree.map(\.isOpen) == [true, true])
        #expect(tree[0].item == .genreGroup(.fiction))
        #expect(tree[0].genres[3].item == .browse(.genre, "Fantasy"))
        #expect(h.model.title(of: .genreGroup(.nonFiction)) == "Non-fiction")
        #expect(h.model.title(of: .noGenre) == "No genre")
    }

    @Test func GH34_anEmptyLibraryHasNoTree() async throws {
        let h = try await Harness.empty()
        #expect(h.model.genreTree.isEmpty)
        #expect(h.model.noGenreCount == 0)
        #expect(!h.model.showsNoGenre)
        #expect(h.model.genreFilesToUpdate == 0)
    }

    @Test func GH34_whetherAGroupIsOpenIsRememberedAcrossLaunches() async throws {
        let h = try await Harness.demo()
        h.model.setOpen(false, group: .fiction)
        #expect(h.model.genreTree.map(\.isOpen) == [false, true])
        #expect(!h.model.isOpen(group: .fiction))

        let again = h.relaunched()
        await again.start()
        #expect(again.genreTree.map(\.isOpen) == [false, true])
        again.setOpen(true, group: .fiction)
        again.setOpen(false, group: .nonFiction)
        let third = h.relaunched()
        await third.start()
        #expect(third.genreTree.map(\.isOpen) == [true, false])
    }

    @Test func GHa_theOwnersOwnGenresComeAfterTheBuiltInOnesByName() async throws {
        let h = try await Harness.demo()
        try await h.give("Zebra Tales", in: .fiction, to: ["Salt Road"])
        try await h.give("atlases of the sea", in: .fiction, to: ["Salt Road", "Quiet Rivers"])
        #expect(h.treeNames[0] == Self.fiction + ["atlases of the sea", "Zebra Tales"])
        #expect(h.model.genreTree[0].genres.suffix(2).map(\.count) == [2, 1])
        // GH-a: the book keeps its genres in its own order.
        #expect(try h.book(try h.id("Salt Road")).genres == ["Fantasy", "Zebra Tales", "atlases of the sea"])
        // Still seven books in Fiction: each once.
        #expect(h.model.genreTree[0].count == 7)
    }

    @Test func GH35_selectingAGroupShowsEachOfItsBooksOnce() async throws {
        let h = try await Harness.demo()
        h.model.select(group: .fiction)
        await h.model.settle()
        #expect(h.model.sidebarSelection == .genreGroup(.fiction))
        #expect(h.titles == [
            "Harbour of Glass", "Night Train to Vostok", "Quiet Rivers", "Salt Road", "The Clockmaker's Apprentice",
            "The Drowned Bell", "The Lighthouse Keeper",
        ])
        #expect(h.model.windowTitle == "Fiction")
        #expect(h.model.windowSubtitle == "7 books")

        h.model.select(group: .nonFiction)
        await h.model.settle()
        #expect(h.titles.count == 4)
    }

    @Test func GH35_selectingAGenreShowsTheBooksThatHaveItWhateverItsPlace() async throws {
        let h = try await Harness.demo()
        // The book's second genre.
        h.model.select(genre: "Crime & Mystery")
        await h.model.settle()
        #expect(h.model.sidebarSelection == .browse(.genre, "Crime & Mystery"))
        #expect(h.titles == ["Night Train to Vostok"])
        #expect(h.model.windowTitle == "Crime & Mystery")

        h.model.select(genre: "Fantasy")
        await h.model.settle()
        #expect(h.titles == Self.tidewater)
    }

    @Test func GH36_noGenreIsShownOnlyWhileABookHasNone() async throws {
        let h = try await Harness.demo()
        #expect(h.model.noGenreCount == 1)
        #expect(h.model.showsNoGenre)
        h.model.selectNoGenre()
        await h.model.settle()
        #expect(h.model.sidebarSelection == .noGenre)
        #expect(h.titles == ["Voices from the Attic"])
        #expect(h.model.windowTitle == "No genre")

        // The book is given a genre: there is no such entry any more, and nothing to show under it.
        try await h.select("Voices from the Attic")
        h.model.addDraftGenre("Horror")
        await h.model.save()
        #expect(h.model.noGenreCount == 0)
        #expect(!h.model.showsNoGenre)
        #expect(h.model.sidebarSelection == .allBooks)
    }

    @Test func GH36_otherIsShownOnlyWhenItHasBooks() async throws {
        let h = try await Harness.demo()
        #expect(!h.model.genreTree.contains { $0.group == .other })
        // A genre in Other that no book has does not bring the group into sight.
        #expect(await h.model.createGenre("Pub Quiz", group: .other) == "Pub Quiz")
        #expect(!h.model.genreTree.contains { $0.group == .other })

        try await h.give("Pub Quiz", in: .other, to: ["Quiet Rivers"])
        let other = try #require(h.model.genreTree.last)
        #expect(other.group == .other)
        #expect(other.title == "Other")
        #expect(other.count == 1)
        #expect(other.genres.map(\.name) == ["Pub Quiz"])
    }

    // MARK: G37 The list

    @Test func GH37_theGenreColumnJoinsABooksGenresAndSortsByTheFirst() async throws {
        let h = try await Harness.demo()
        let train = try #require(h.model.rows.first { $0.book.title == "Night Train to Vostok" })
        // GH-a: in the book's order.
        #expect(train.genreText == "Thrillers & Spies, Crime & Mystery")
        #expect(train.genreSortKey == "Thrillers & Spies")
        #expect(h.model.rows.first { $0.book.title == "Voices from the Attic" }?.genreText == "")

        h.model.sort = BookSort(key: .genre)
        let firsts = h.model.rows.map { $0.book.genres.first ?? "" }
        // By the first genre, ignoring case; a book with none comes last.
        #expect(firsts == [
            "Biography & Memoir", "Fantasy", "Fantasy", "Fantasy", "Historical Fiction", "History",
            "Literary & General", "Literary & General", "Science & Nature", "Thrillers & Spies", "Travel & Places", "",
        ])
        h.model.sort = BookSort(key: .genre, ascending: false)
        #expect(h.model.rows.first?.book.title == "The Cartographer's Daughter")
        #expect(h.model.rows.last?.book.title == "Voices from the Attic")
        // The column's header is the table's own way of asking for the same sort.
        #expect(BookSort(tableSortOrder: BookSort(key: .genre).tableSortOrder) == BookSort(key: .genre))
        #expect(BookSort(itemSortOrder: BookSort(key: .genre).itemSortOrder) == BookSort(key: .genre))
    }

    @Test func GH37_searchMatchesAnyGenreOfABook() async throws {
        let h = try await Harness.demo()
        h.model.searchText = "mystery"
        await h.model.settle()
        #expect(h.titles == ["Night Train to Vostok"])
    }

    // MARK: G21, G22 The inspector

    @Test func GH21_suggestionsLeaveOutTheGenresTheInspectedBookHas() async throws {
        let h = try await Harness.demo()
        #expect(h.model.genreSuggestions(for: "fan").groups.flatMap(\.genres).map(\.name) == ["Fantasy"])
        try await h.select("Salt Road")
        #expect(h.model.genreSuggestions(for: "fan").groups.isEmpty)
        h.model.removeDraftGenre("Fantasy")
        #expect(h.model.genreSuggestions(for: "fan").groups.flatMap(\.genres).map(\.name) == ["Fantasy"])
        // For any other place genres are chosen, what to leave out is said.
        let offered = h.model.genreSuggestions(for: "", excluding: Self.fiction)
        #expect(offered.groups.first?.genres.map(\.name) == [
            "Classics", "Science Fiction", "Romance", "Horror", "Humour",
        ])
    }

    @Test func GH21_aChosenGenreGoesIntoTheDraftAndIsSavedWithTheBook() async throws {
        let h = try await Harness.demo()
        let id = try await h.select("Salt Road")
        h.model.addDraftGenre("history")
        // G22: a source's name for a genre is that genre, without asking.
        h.model.addDraftGenre("sci-fi")
        // A name that is not on the list is not added this way: it has to be created.
        h.model.addDraftGenre("Sea Stories")
        #expect(h.draft?.genres == ["Fantasy", "History", "Science Fiction"])
        #expect(h.model.hasUnsavedChanges)
        #expect(try h.book(id).genres == ["Fantasy"])

        h.model.moveDraftGenre(from: 2, to: 0)
        h.model.removeDraftGenre("Fantasy")
        #expect(h.draft?.genres == ["Science Fiction", "History"])
        await h.model.save()
        #expect(try h.book(id).genres == ["Science Fiction", "History"])
        #expect(!h.model.hasUnsavedChanges)
        // G17: written into the book's file as it is saved.
        #expect(try h.genreTag("Salt Road") == "Science Fiction; History")
    }

    @Test func GH22_createMakesTheGenreInItsGroupAndAddsItToTheDraft() async throws {
        let h = try await Harness.demo()
        let id = try await h.select("Salt Road")
        #expect(h.model.genreSuggestions(for: "Sea Stories").createName == "Sea Stories")

        await h.model.createDraftGenre(" Sea  Stories ", group: .nonFiction)
        #expect(h.draft?.genres == ["Fantasy", "Sea Stories"])
        #expect(h.model.alert == nil)
        let made = try #require(h.model.genreCatalogue.shown.first { $0.name == "Sea Stories" })
        #expect(made.group == .nonFiction)
        #expect(made.builtInName == nil)
        // It is on the list at once, and is no longer something to create.
        #expect(h.model.genreSuggestions(for: "Sea Stories").createName == nil)
        // The book has it only when it is saved.
        #expect(try h.book(id).genres == ["Fantasy"])
        await h.model.save()
        #expect(try h.book(id).genres == ["Fantasy", "Sea Stories"])
        #expect(h.treeNames[1].contains("Sea Stories"))
    }

    @Test func GH22_createGivesTheGenreASourceNameMeansAndRefusesABadName() async throws {
        let h = try await Harness.demo()
        let before = h.model.genreCatalogue
        #expect(await h.model.createGenre("Sci-Fi", group: .other) == "Science Fiction")
        #expect(h.model.genreCatalogue == before)

        #expect(await h.model.createGenre("Cops/Robbers", group: .other) == nil)
        #expect(h.model.alert == "A genre's name cannot be empty, and cannot have a comma, a semicolon or a slash in it.")
        #expect(h.model.genreCatalogue == before)
    }

    @Test func GH21_withSeveralBooksAGenreIsAddedToOrRemovedFromAllOfThem() async throws {
        let h = try await Harness.demo()
        let ids = try await h.select(["Salt Road", "Night Train to Vostok", "Voices from the Attic"])
        let shown = try #require(h.bulkDraft).genres
        #expect(shown.map(\.name) == ["Thrillers & Spies", "Crime & Mystery", "Fantasy"])
        #expect(shown.map(\.isMixed) == [true, true, true])
        // What every one of them has is left out of what is offered; a mixed one is not.
        #expect(h.model.genreSuggestions(for: "fan").groups.flatMap(\.genres).map(\.name) == ["Fantasy"])

        h.model.addDraftGenre("Fantasy")
        h.model.removeDraftGenre("Crime & Mystery")
        #expect(h.model.hasUnsavedChanges)
        #expect(h.model.editedBookIds == ids)
        #expect(h.bulkDraft?.genres.map(\.name) == ["Thrillers & Spies", "Fantasy"])
        #expect(h.bulkDraft?.genres.map(\.isMixed) == [true, false])
        #expect(h.model.genreSuggestions(for: "fan").groups.isEmpty)

        await h.model.save()
        #expect(try h.book(try h.id("Salt Road")).genres == ["Fantasy"])
        #expect(try h.book(try h.id("Night Train to Vostok")).genres == ["Thrillers & Spies", "Fantasy"])
        #expect(try h.book(try h.id("Voices from the Attic")).genres == ["Fantasy"])
        #expect(!h.model.hasUnsavedChanges)
        #expect(h.bulkDraft?.genres.map(\.name) == ["Thrillers & Spies", "Fantasy"])
        #expect(h.bulkDraft?.genres.map(\.isMixed) == [true, false])
    }

    @Test func GH21_genresChangedOnSeveralBooksAreKeptWhileTheLibraryIsReadAgain() async throws {
        let h = try await Harness.demo()
        let ids = try await h.select(["Salt Road", "Quiet Rivers"])
        h.model.addDraftGenre("History")
        h.model.removeDraftGenre("Fantasy")
        await h.model.setReadStatus(.inProgress, for: ids)
        #expect(h.bulkDraft?.genreAdds == ["History"])
        #expect(h.bulkDraft?.genreRemoves == ["Fantasy"])
        #expect(h.model.hasUnsavedChanges)
        h.model.discardChanges()
        #expect(!h.model.hasUnsavedChanges)
    }

    // MARK: G13, G17 Files

    @Test func GH13_theHeaderCountsTheBooksWhoseFilesDiffer() async throws {
        let h = try await Harness.demo()
        // GH-c: a demo library has nothing to update.
        #expect(h.model.genreFilesToUpdate == 0)
        #expect(h.model.genreFilesOffer == nil)

        try await h.rename("Fantasy", to: "Fantastic")
        #expect(h.model.genreFilesToUpdate == 3)
        let offer = try #require(h.model.genreFilesOffer)
        #expect(offer.title == "Update files…")
        #expect(offer.count == 3)
        #expect(offer.help == "The genre tags in the files of 3 books differ from the library.")

        // G27: nothing was written into a file on the spot.
        #expect(try h.genreTag("Salt Road") == "Fantasy")
        await h.model.undo()
        #expect(h.model.genreFilesToUpdate == 0)
    }

    @Test func GH17_savingOneEditedBookWritesItsFilesAndLeavesTheOtherDifferingBooksAlone() async throws {
        let h = try await Harness.demo()
        try await h.rename("Fantasy", to: "Fantastic")
        #expect(h.model.genreFilesToUpdate == 3)

        // A book that does not differ: only its own file is written.
        try await h.select("Quiet Rivers")
        h.model.addDraftGenre("History")
        await h.model.save()
        #expect(try h.genreTag("Quiet Rivers") == "Literary & General; History")
        #expect(h.model.genreFilesToUpdate == 3)
        for title in Self.tidewater {
            #expect(try h.genreTag(title) == "Fantasy", "\(title)")
            #expect(try h.book(try h.id(title)).genres == ["Fantastic"], "\(title)")
        }

        // One of the three is edited and saved: its file is brought in line, the others' are not.
        try await h.select("Salt Road")
        h.model.updateDraft { $0.publisher = "Tidewater Press" }
        await h.model.save()
        #expect(try h.genreTag("Salt Road") == "Fantastic")
        #expect(try h.genreTag("The Drowned Bell") == "Fantasy")
        #expect(try h.genreTag("Harbour of Glass") == "Fantasy")
        #expect(h.model.genreFilesToUpdate == 2)
        #expect(h.model.genreFilesOffer?.help == "The genre tags in the files of 2 books differ from the library.")
    }

    // MARK: GH-b The selection follows the list

    @Test func GHb_theSelectionFollowsARenamedGenreAndItsUndo() async throws {
        let h = try await Harness.demo()
        h.model.select(genre: "Fantasy")
        await h.model.settle()

        try await h.rename("Fantasy", to: "Fantastic")
        #expect(h.model.sidebarSelection == .browse(.genre, "Fantastic"))
        #expect(h.titles == Self.tidewater)
        #expect(h.model.windowTitle == "Fantastic")

        await h.model.undo()
        #expect(h.model.sidebarSelection == .browse(.genre, "Fantasy"))
        #expect(h.titles == Self.tidewater)
    }

    @Test func GHb_theSelectionFollowsARenameThatWasMadeBeforeItWasChosen() async throws {
        let h = try await Harness.demo()
        try await h.rename("Fantasy", to: "Fantastic")
        h.model.select(genre: "Fantastic")
        await h.model.settle()
        await h.model.undo()
        #expect(h.model.sidebarSelection == .browse(.genre, "Fantasy"))
        #expect(h.titles == Self.tidewater)
    }

    @Test func GHb_theSelectionMovesToTheTargetOfAMergeAndBackWhenItIsUndone() async throws {
        let h = try await Harness.demo()
        h.model.select(genre: "Fantasy")
        await h.model.settle()

        let manager = try h.manager()
        await manager.merge("Fantasy", into: "History")
        #expect(h.model.sidebarSelection == .browse(.genre, "History"))
        #expect(h.titles.count == 4)

        await h.model.undo()
        #expect(h.model.sidebarSelection == .browse(.genre, "Fantasy"))
        #expect(h.titles == Self.tidewater)
    }

    @Test func GHb_anotherSelectionIsLeftAloneByAMergeAndItsUndo() async throws {
        let h = try await Harness.demo()
        h.model.select(genre: "History")
        await h.model.settle()
        let manager = try h.manager()
        await manager.merge("Fantasy", into: "History")
        #expect(h.model.sidebarSelection == .browse(.genre, "History"))
        await h.model.undo()
        #expect(h.model.sidebarSelection == .browse(.genre, "History"))
        #expect(h.titles.count == 1)

        h.model.sidebarSelection = .audiobooks
        await h.model.settle()
        await manager.merge("Fantasy", into: "History")
        #expect(h.model.sidebarSelection == .audiobooks)
    }

    @Test func GHb_theSelectionFallsBackToAllBooksWhenItsGenreIsDeletedAndReturnsOnUndo() async throws {
        let h = try await Harness.demo()
        try await h.give("Sea Stories", in: .fiction, to: ["Salt Road", "Quiet Rivers"])
        h.model.select(genre: "Sea Stories")
        await h.model.settle()
        #expect(h.titles == ["Quiet Rivers", "Salt Road"])

        let manager = try h.manager()
        manager.requestDelete("Sea Stories")
        await manager.confirmQuestion()
        #expect(h.model.sidebarSelection == .allBooks)
        #expect(h.titles.count == 12)

        await h.model.undo()
        #expect(h.model.sidebarSelection == .browse(.genre, "Sea Stories"))
        #expect(h.titles == ["Quiet Rivers", "Salt Road"])
    }

    @Test func GHb_aGroupThatLosesItsLastBookIsNoLongerSelected() async throws {
        let h = try await Harness.demo()
        try await h.give("Pub Quiz", in: .other, to: ["Quiet Rivers"])
        h.model.select(group: .other)
        await h.model.settle()
        #expect(h.titles == ["Quiet Rivers"])
        let manager = try h.manager()
        await manager.move("Pub Quiz", to: .fiction)
        #expect(h.model.sidebarSelection == .allBooks)
    }

    // MARK: G19 Import

    /// An ebook whose genre tag is `tag`, loose in a folder of its own.
    private func taggedBook(_ title: String, tag: String) throws -> URL {
        let url = try MediaFixtures.makeEPUB3(in: try makeTempDir(), name: "\(title).epub")
        var metadata = BookMetadata(title: title, authors: ["Ann Lee"])
        metadata.genres = [tag]
        _ = try FileMetadataIO().write(metadata, to: url)
        return url
    }

    @Test func GH19_theImportReviewShowsTheGenresAFilesTagComesTo() async throws {
        let h = try await Harness.demo()
        await h.model.beginImport([try taggedBook("Far Stars", tag: "Sci-Fi, Pub Quiz")])
        let entry = try #require(h.model.review?.entries.first)
        #expect(entry.genres == ["Science Fiction", "Pub Quiz"])

        // G19: the chips can be edited.
        h.model.addImportGenre("history", to: entry.id)
        h.model.addImportGenre("Science Fiction", to: entry.id)
        h.model.addImportGenre("Not On The List", to: entry.id)
        #expect(h.model.review?.entry(entry.id)?.genres == ["Science Fiction", "Pub Quiz", "History"])
        h.model.moveImportGenre(from: 2, to: 0, in: entry.id)
        h.model.removeImportGenre("pub quiz", from: entry.id)
        #expect(h.model.review?.entry(entry.id)?.genres == ["History", "Science Fiction"])
        // What the entry has is not offered again.
        #expect(h.model.genreSuggestions(for: "History", excluding: ["History", "Science Fiction"]).groups.isEmpty)

        await h.model.confirmImport()
        #expect(try h.book(try h.id("Far Stars")).genres == ["History", "Science Fiction"])
        // The wording the file had is kept beside them.
        #expect(try h.book(try h.id("Far Stars")).genreSource == "Sci-Fi, Pub Quiz")
    }

    @Test func GH19_anImportsGenresAreNamedAsTheLibraryNamesThem() async throws {
        let h = try await Harness.demo()
        try await h.rename("Science Fiction", to: "Space Books")
        let manager = try h.manager()
        await manager.merge("Horror", into: "Fantasy")
        h.model.closeManageGenres()

        await h.model.beginImport([
            try taggedBook("Far Stars", tag: "Sci-Fi"), try taggedBook("Night Things", tag: "Horror"),
        ])
        let genres = try #require(h.model.review).entries.map(\.genres)
        #expect(Set(genres) == [["Space Books"], ["Fantasy"]])
    }

    // MARK: G20 Lookup

    @Test func GH20_aLookupsGenresAreNamedAsTheLibraryNamesThemAndApplied() async throws {
        let h = try await Harness.demo()
        try await h.rename("Humour", to: "Comedy")
        let id = try await h.select("Salt Road")
        h.lookup.find(.audible, [
            foundBook(.audible, "us:B1", title: "Salt Road", authors: ["Ines Calloway"]) {
                $0.genres = ["Humour", "History"]
                $0.genreSource = "Comedy & Humor; History"
            }
        ])
        h.model.beginLookup()
        await h.model.settle()
        let offer = try #require(h.model.lookup?.offers.first { $0.id == .genre })
        #expect(offer.foundGenres == ["Comedy", "History"])
        #expect(offer.found == "Comedy, History")
        #expect(offer.currentGenres == ["Fantasy"])
        // The book has genres: its own are kept unless the row is ticked.
        #expect(!offer.ticked)

        h.model.setLookupTicked(true, for: .genre)
        await h.model.applyLookup()
        #expect(try h.book(id).genres == ["Comedy", "History"])
        #expect(try h.book(id).genreSource == "Comedy & Humor; History")
    }

    @Test func GH20_theDetailsThatArriveLaterAreNamedAsTheLibraryNamesThemToo() async throws {
        let h = try await Harness.demo()
        try await h.rename("Humour", to: "Comedy")
        try await h.select("Voices from the Attic")
        h.lookup.find(.audible, [foundBook(.audible, "us:B1", title: "Voices from the Attic", moreDetails: true)])
        h.lookup.details { candidate in
            var detailed = candidate
            detailed.metadata.genres = ["Humour"]
            detailed.hasMoreDetails = false
            return detailed
        }
        h.model.beginLookup()
        await h.model.settle()
        let offer = try #require(h.model.lookup?.offers.first { $0.id == .genre })
        #expect(offer.foundGenres == ["Comedy"])
        // The book has none: ticked to begin with.
        #expect(offer.ticked)
    }

    // MARK: GH-c Demo content

    @Test func GHc_theDemoBooksHaveGenresFromTheListInTwoGroups() async throws {
        let h = try await Harness.demo()
        let books = try h.store().books()
        let builtIn = Set(BuiltInGenre.all.map(\.name))
        #expect(books.flatMap(\.genres).allSatisfy(builtIn.contains))
        #expect(Set(books.flatMap(\.genres).compactMap { BuiltInGenre.named($0)?.group }) == [.fiction, .nonFiction])
        #expect(books.filter { $0.genres.count == 2 }.map(\.title) == ["Night Train to Vostok"])
        #expect(books.filter { $0.genres.isEmpty }.map(\.title) == ["Voices from the Attic"])
        #expect(h.model.genreFilesToUpdate == 0)
    }

    @Test func GHc_aLargeDemoLibraryHasNothingToUpdateInItsFiles() async throws {
        let root = try makeTempDir()
        try DemoContent.makeLibrary(at: root, count: 40)
        let worker = try LibraryWorker(libraryRoot: root)
        #expect(try await worker.genreFileDifferences().isEmpty)
        let sidebar = try await worker.sidebar()
        #expect(sidebar.genreFilesToUpdate == 0)
        #expect(sidebar.counts[.allBooks] == 40)
        let builtIn = Set(BuiltInGenre.all.map(\.name))
        #expect(try LibraryStore(libraryRoot: root).books().flatMap(\.genres).allSatisfy(builtIn.contains))
    }

    // MARK: GH-d Wordings

    @Test func GHd_whyAGenreCouldNotBeChangedIsSaidInASentence() {
        typealias E = LibraryService.GenreChangeError
        #expect(
            UserMessage.text(for: E.invalidName)
                == "A genre's name cannot be empty, and cannot have a comma, a semicolon or a slash in it.")
        #expect(UserMessage.text(for: E.nameInUse("History")) == "There is already a genre called \"History\".")
        #expect(
            UserMessage.text(for: E.builtIn)
                == "A built-in genre cannot be deleted. It can be renamed, or merged into another genre.")
        #expect(UserMessage.text(for: E.unknownGenre) == "That genre is no longer on the list.")
    }

    @Test func GHd_aLibraryThatCouldNotBeCopiedBeforeItsGenresAreConvertedSaysSo() {
        let error = LibraryStoreError.copyBeforeGenresFailed("VoxCarrel before genres 2026-11-24.sqlite")
        let said = UserMessage.text(for: error)
        #expect(said == error.errorDescription)
        #expect(said.contains("The copy could not be made, so nothing was changed."))
        // Not taken for a damaged database.
        #expect(!said.contains("damaged"))
        #expect(!LibraryStore.isDatabaseError(error))
    }
}
