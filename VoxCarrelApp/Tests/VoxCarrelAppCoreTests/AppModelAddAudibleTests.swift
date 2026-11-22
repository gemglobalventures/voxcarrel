import DemoContent
import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// Adding a book that is owned on Audible and has no files here (plan 6, Task 4). N1–N8.
/// Every model here looks things up in the harness's `FakeLookup`: nothing reaches the network.
@MainActor
@Suite struct AppModelAddAudibleTests {
    private let png = MediaFixtures.makeImage(.png)

    /// What Audible finds for The Glass Tide, a book the demo library does not have.
    private func glassTide(cover: Bool = true, thumbnail: Bool = false, moreDetails: Bool = false) -> LookupCandidate {
        foundBook(
            .audible, "uk:B0GLASSTID", title: "The Glass Tide", authors: ["Ines Calloway"], cover: cover,
            thumbnail: thumbnail, moreDetails: moreDetails
        ) {
            $0.subtitle = "A Tidewater Novel"
            $0.narrators = ["Marcus Lindqvist"]
            $0.series = "Tidewater Chronicles"
            $0.seriesNumber = "4"
            $0.publisher = "Tidewater Audio"
            $0.summary = "The tide comes in."
            $0.language = "en"
            $0.year = 2018
            $0.asin = "B0GLASSTID"
            $0.durationSeconds = 36_000
        }
    }

    /// What Audible finds for Salt Road, which the demo library has as files.
    private func saltRoad() -> LookupCandidate {
        foundBook(.audible, "uk:B0SALTROAD", title: "Salt Road", authors: ["Ines Calloway"], cover: true) {
            $0.narrators = ["Someone Else"]
            $0.asin = "B0SALTROAD"
            $0.durationSeconds = 99_999
        }
    }

    /// A demo library with the add sheet open and a search for `title` answered with `candidates`.
    private func searched(_ candidates: [LookupCandidate], title: String = "The Glass Tide") async throws -> Harness {
        let h = try await Harness.demo()
        h.model.audibleStore = .uk
        h.lookup.find(.audible, candidates)
        h.lookup.find(.openLibrary, [foundBook(.openLibrary, "/works/OL9W", title: title)])
        h.model.beginAddAudibleBook()
        h.model.updateLookupQuery { $0.title = title }
        await h.model.searchLookup()
        return h
    }

    /// Every file under the library folder with its size and when it was last changed,
    /// but for the catalogue's own files (the database, where an added book is written).
    private func filesOnDisk(_ h: Harness) throws -> [String: String] {
        var files: [String: String] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let all = try #require(FileManager.default.enumerator(at: h.root, includingPropertiesForKeys: keys))
        for case let url as URL in all {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(h.root.standardizedFileURL.path.count))
            let isCatalogue = path.hasPrefix("/.voxcarrel/") && !path.hasPrefix("/.voxcarrel/covers/")
                && !path.hasPrefix("/.voxcarrel/undo/")
            if isCatalogue || path.hasPrefix("/" + LibraryStore.databaseFileName) { continue }
            files[path] = "\(values.fileSize ?? -1) \(values.contentModificationDate?.timeIntervalSinceReferenceDate ?? -1)"
        }
        return files
    }

    private func added(_ h: Harness, _ title: String = "The Glass Tide") throws -> Book {
        try #require(try h.store().books().first { $0.title == title }, "no book titled \(title)")
    }

    // MARK: N1 Beginning

    /// N1
    @Test func N1_beginningOpensAnEmptySheetAndAsksNothing() async throws {
        let h = try await Harness.demo()
        #expect(h.model.canAddAudibleBook)
        h.model.beginAddAudibleBook()
        let session = try #require(h.model.lookup)
        #expect(session.target == .newAudibleBook)
        #expect(session.isAddMode)
        #expect(session.query.isEmpty)
        #expect(session.phase == .idle)
        #expect(h.model.addAudibleLookup == session)
        #expect(h.model.inspectorLookup == nil)
        #expect(h.model.importLookup == nil)
        await h.model.settle()
        #expect(h.lookup.asked.isEmpty)
        #expect(h.model.busyLabel == nil)
        // Searching for nothing asks nothing.
        await h.model.searchLookup()
        #expect(h.lookup.asked.isEmpty)
        #expect(h.model.lookup?.phase == .idle)
    }

    /// N1: only Audible is asked: what Open Library finds cannot be added as an Audible book.
    @Test func N1_onlyAudibleIsAsked() async throws {
        let h = try await searched([glassTide()])
        #expect(h.lookup.asked.map(\.source) == [.audible])
        #expect(h.lookup.asked.map(\.store) == [.uk])
        #expect(h.lookup.asked.map(\.query) == [LookupQuery(title: "The Glass Tide")])
        let session = try #require(h.model.lookup)
        #expect(session.phase == .results)
        #expect(session.candidates == [glassTide()])
        #expect(session.outcomes == [LookupSession.SourceOutcome(source: .audible, found: 1, failure: nil)])
        #expect(session.selectedId == glassTide().id)
        #expect(session.canAdd)

        // A lookup for a book still asks every source.
        h.model.cancelLookup()
        try await h.select("Salt Road")
        h.model.beginLookup()
        await h.model.settle()
        #expect(h.lookup.asked.dropFirst().map(\.source).sorted { $0.rawValue < $1.rawValue } == [.audible, .openLibrary])
    }

    /// N1: the worker's lookup takes the sources to ask.
    @Test func N1_theWorkerAsksOnlyTheSourcesItIsGiven() async throws {
        let fake = FakeLookup()
        fake.find(.audible, [glassTide()])
        fake.find(.openLibrary, [foundBook(.openLibrary, "/works/OL9W", title: "The Glass Tide")])
        let worker = try LibraryWorker(libraryRoot: try makeTempDir(), lookup: fake.service(store: .uk))
        let query = LookupQuery(title: "The Glass Tide")
        let audible = await worker.lookUp(query, preferAudio: true, language: "en", sources: [.audible])
        #expect(audible.candidates == [glassTide()])
        #expect(audible.searched == [.audible])
        #expect(fake.asked.map(\.source) == [.audible])
        let all = await worker.lookUp(query, preferAudio: true, language: "en", sources: nil)
        #expect(all.searched == [.openLibrary, .audible])
        #expect(fake.asked.count == 3)
    }

    /// The Book menu's item: a library that is open and quiet; no selection is needed.
    @Test func N1_canAddNeedsAQuietLibraryAndNoUnsavedEdits() async throws {
        let closed = try Harness(root: try makeTempDir(), choose: false)
        await closed.model.start()
        #expect(!closed.model.canAddAudibleBook)
        closed.model.beginAddAudibleBook()
        #expect(closed.model.lookup == nil)

        let h = try await Harness.demo()
        #expect(h.model.selection.isEmpty)
        #expect(h.model.canAddAudibleBook)

        // Not over unsaved edits: the added book becomes the selection.
        try await h.edit("Salt Road", newTitle: "Salt Roads")
        #expect(!h.model.canAddAudibleBook)
        h.model.beginAddAudibleBook()
        #expect(h.model.lookup == nil)
        h.model.discardChanges()
        #expect(h.model.canAddAudibleBook)

        // Not over a question.
        h.model.requestRemoveSelection()
        #expect(h.model.prompt != nil)
        #expect(!h.model.canAddAudibleBook)
        h.model.prompt = nil

        // Not over an import being reviewed.
        let inbox = try Harness.inbox()
        await h.model.beginImport([inbox.appendingPathComponent("Quiet Rivers.epub")])
        #expect(h.model.review != nil)
        #expect(!h.model.canAddAudibleBook)
        h.model.cancelImport()
        #expect(h.model.canAddAudibleBook)

        // Not while something runs.
        let gate = Gate()
        h.model.beforeOperation = { await gate.wait() }
        let running = Task { await h.model.setReadStatus(.finished, for: h.model.selection) }
        await gate.arrival()
        #expect(!h.model.canAddAudibleBook)
        h.model.beginAddAudibleBook()
        #expect(h.model.lookup == nil)
        await gate.release()
        await running.value
        h.model.beforeOperation = nil
        #expect(h.model.canAddAudibleBook)
    }

    // MARK: N2 Choosing

    /// N2: nothing to tick; the selected result's details are there to read, and more is fetched when there is more.
    @Test func N2_theSelectedResultIsShownAndDetailsAreStillFetched() async throws {
        let other = foundBook(.audible, "uk:B0OTHERONE", title: "The Glass Tides", authors: ["Someone"], moreDetails: true)
        let h = try await Harness.demo()
        h.lookup.find(.audible, [glassTide(), other])
        h.lookup.details { candidate in
            var detailed = candidate
            detailed.metadata.summary = "More about it."
            detailed.hasMoreDetails = false
            return detailed
        }
        h.model.beginAddAudibleBook()
        h.model.updateLookupQuery { $0.title = "The Glass Tide" }
        await h.model.searchLookup()
        let session = try #require(h.model.lookup)
        #expect(session.offers.isEmpty)
        #expect(!session.canApply)
        #expect(session.canAdd)
        #expect(session.detailLines.first == LookupSession.DetailLine(label: "Title", value: "The Glass Tide"))
        #expect(session.detailLines.contains(LookupSession.DetailLine(label: "Series", value: "Tidewater Chronicles #4")))
        #expect(session.detailLines.contains(LookupSession.DetailLine(label: "Length", value: "10h 0m")))
        // Audible's results are complete: nothing more was asked for.
        #expect(h.lookup.detailsAsked.isEmpty)

        h.model.setLookupTicked(true, for: .title)
        await h.model.applyLookup()
        #expect(h.model.lookup?.phase == .results)

        await h.model.selectLookupCandidate(other.id)
        #expect(h.lookup.detailsAsked == [other.id])
        #expect(h.model.lookup?.detailLines.last == LookupSession.DetailLine(label: "Description", value: "More about it."))
        #expect(h.model.lookup?.offers.isEmpty == true)
        await h.model.selectLookupCandidate(nil)
        #expect(h.model.lookup?.canAdd == false)
        await h.model.addLookupSelection()
        #expect(h.model.lookup != nil)
        #expect(try h.store().books().count == 12)
    }

    // MARK: N3 Adding

    /// N3
    @Test func N3_addingMakesABookWithTheResultsDetailsAndCover() async throws {
        let h = try await searched([glassTide()])
        h.lookup.cover(png)
        h.recordBusyLabels()
        #expect(h.model.sidebarSelection == .allBooks)

        await h.model.addLookupSelection()
        #expect(h.model.lookup == nil)
        #expect(h.model.alert == nil)
        #expect(h.model.result == nil)
        #expect(h.model.busyLabel == nil)
        #expect(h.busyLabels == ["Adding book…"])

        let book = try added(h)
        let id = try #require(book.id)
        var expected = glassTide().metadata
        expected.asin = "B0GLASSTID"
        #expect(book.metadata == expected)
        #expect(book.durationSeconds == 36_000)
        #expect(book.externalCopies == [ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: "B0GLASSTID")])
        #expect(book.folderPath == nil)
        #expect(!book.needsAttention)
        #expect(book.readStatus == .unread)
        #expect(try h.fileURLs(id).isEmpty)

        // Shown where the user is, selected, with its cover.
        #expect(h.model.sidebarSelection == .allBooks)
        #expect(h.model.selection == [id])
        #expect(h.model.scrollTarget == id)
        #expect(h.detail?.row.id == id)
        let row = try #require(h.model.rows.first { $0.id == id })
        #expect(!row.hasFiles)
        #expect(row.whereaboutsText == "On Audible, not on this Mac")
        #expect(h.lookup.coverURLs == [try #require(glassTide().coverURL)])
        #expect(try Data(contentsOf: try #require(row.coverURL)) == png)
        #expect(h.model.sidebar.counts[.onAudible] == 1)
        #expect(h.model.sidebar.counts[.allBooks] == 13)
        #expect(h.model.canAddAudibleBook)
    }

    /// N3, and plan 7, A9: the copy's store is the one the chosen result's ASIN belongs
    /// to, whatever the settings say when the book is added.
    @Test func N3_theCopyNamesTheStoreOfTheChosenASIN() async throws {
        let h = try await searched([glassTide(cover: false)])
        h.model.audibleStore = .au
        // The results came from the stores as they were: the search is made again at once.
        await h.model.settle()
        await h.model.addLookupSelection()
        #expect(try added(h).externalCopies == [ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: "B0GLASSTID")])
        #expect(h.lookup.coverURLs.isEmpty)
        #expect(h.model.alert == nil)
    }

    /// N3: the sidebar moves to On Audible when the book is not among the books shown.
    @Test func N3_theSidebarMovesToOnAudibleWhenTheBookIsNotShown() async throws {
        let h = try await Harness.demo()
        h.lookup.find(.audible, [glassTide(cover: false)])
        h.model.sidebarSelection = .ebooks
        await h.model.settle()
        h.model.beginAddAudibleBook()
        h.model.updateLookupQuery { $0.title = "The Glass Tide" }
        await h.model.searchLookup()
        await h.model.addLookupSelection()
        let id = try #require(try added(h).id)
        #expect(h.model.sidebarSelection == .onAudible)
        #expect(h.model.windowTitle == "On Audible")
        #expect(h.model.rows.map(\.id) == [id])
        #expect(h.model.selection == [id])
        #expect(h.detail?.row.id == id)
    }

    /// N3: a search that hides the new book is cleared when On Audible would not show it either.
    @Test func N3_aSearchThatHidesTheBookIsCleared() async throws {
        let h = try await Harness.demo()
        h.lookup.find(.audible, [glassTide(cover: false)])
        h.model.searchText = "lighthouse"
        await h.model.settle()
        #expect(h.titles == ["The Lighthouse Keeper"])
        h.model.beginAddAudibleBook()
        h.model.updateLookupQuery { $0.title = "The Glass Tide" }
        await h.model.searchLookup()
        await h.model.addLookupSelection()
        let id = try #require(try added(h).id)
        #expect(h.model.sidebarSelection == .onAudible)
        #expect(h.model.searchText == "")
        #expect(h.model.rows.map(\.id) == [id])
        #expect(h.model.selection == [id])

        // A search that does show it is left as it is.
        let kept = try await Harness.demo()
        kept.lookup.find(.audible, [glassTide(cover: false)])
        kept.model.searchText = "tide"
        await kept.model.settle()
        kept.model.beginAddAudibleBook()
        kept.model.updateLookupQuery { $0.title = "The Glass Tide" }
        await kept.model.searchLookup()
        await kept.model.addLookupSelection()
        #expect(kept.model.sidebarSelection == .allBooks)
        #expect(kept.model.searchText == "tide")
        #expect(kept.model.selection == [try #require(try added(kept).id)])
    }

    /// N3: the row's picture, when it is the cover itself, is not fetched again.
    @Test func N3_aCoverAlreadyFetchedForItsRowIsNotFetchedAgain() async throws {
        let h = try await searched([glassTide()])
        h.lookup.cover(png)
        #expect(await h.model.lookupThumbnail(for: glassTide()) == png)
        await h.model.addLookupSelection()
        #expect(h.lookup.coverURLs.count == 1)
        let row = try #require(h.model.rows.first { $0.book.title == "The Glass Tide" })
        #expect(try Data(contentsOf: try #require(row.coverURL)) == png)
        #expect(h.model.alert == nil)
    }

    /// N3: a cover that cannot be downloaded does not stop the book being added.
    @Test func N3_aCoverThatCannotBeDownloadedDoesNotStopTheAdd() async throws {
        // Not reachable, which is what the fake answers until told otherwise.
        let h = try await searched([glassTide()])
        await h.model.addLookupSelection()
        #expect(h.model.lookup == nil)
        let book = try added(h)
        #expect(book.isOwned(on: .audible))
        let row = try #require(h.model.rows.first { $0.id == book.id })
        #expect(row.coverURL == nil)
        #expect(h.model.selection == [try #require(book.id)])
        #expect(h.model.alert == "The book was added, but its cover could not be downloaded.")

        // The smaller picture already fetched for its row is better than none, and nothing is said.
        let jpeg = MediaFixtures.makeImage(.jpeg)
        let candidate = glassTide(thumbnail: true)
        let small = try await searched([candidate])
        small.lookup.cover { url in
            guard url == candidate.thumbnailURL else { throw LookupError.notReachable }
            return (jpeg, 200)
        }
        #expect(await small.model.lookupThumbnail(for: candidate) == jpeg)
        await small.model.addLookupSelection()
        let smallRow = try #require(small.model.rows.first { $0.book.title == "The Glass Tide" })
        #expect(try Data(contentsOf: try #require(smallRow.coverURL)) == jpeg)
        #expect(small.model.alert == nil)
    }

    // MARK: N4 Already in the library

    /// N4
    @Test func N4_aBookAlreadyInTheLibraryIsMarkedInstead() async throws {
        let h = try await searched([saltRoad()], title: "Salt Road")
        h.lookup.cover(png)
        let salt = try h.id("Salt Road")
        let before = try h.book(salt)
        let files = try filesOnDisk(h)
        h.model.sidebarSelection = .ebooks
        await h.model.settle()

        await h.model.addLookupSelection()
        #expect(h.model.lookup == nil)
        #expect(
            h.model.alert == "“Salt Road” was already in your library. It is now marked as also on Audible.")
        #expect(try h.store().books().count == 12)
        var expected = before
        expected.externalCopies = [ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: "B0SALTROAD")]
        expected.asin = "B0SALTROAD"
        // No file was opened: the ASIN is in the app only until the tags are written.
        expected.appOnlyFields = MetadataField.allCases.filter { (before.appOnlyFields + [.asin]).contains($0) }
        #expect(expected.appOnlyFields.contains(.asin))
        // Its own details, cover and files are as they were.
        #expect(try h.book(salt) == expected)
        #expect(try h.book(salt).narrators == ["Marcus Lindqvist"])
        #expect(try filesOnDisk(h) == files)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
        // It is selected, where it can be seen.
        #expect(h.model.sidebarSelection == .onAudible)
        #expect(h.model.selection == [salt])
        #expect(h.detail?.row.whereaboutsText == "Also on Audible")
    }

    /// N4: a book with files that is marked already is told so, and gets no second copy;
    /// the ASIN marking gave it shows in the inspector as in the app only.
    @Test func N4_aBookThatIsAlreadyMarkedIsToldSo() async throws {
        let h = try await searched([saltRoad()], title: "Salt Road")
        h.lookup.cover(png)
        let salt = try h.id("Salt Road")
        h.model.cancelLookup()
        await h.model.setOnAudible(true, for: [salt])
        let marked = try h.book(salt)
        #expect(marked.externalCopies == [ExternalCopy(kind: .audible, form: .audio, store: "uk")])

        h.model.beginAddAudibleBook()
        h.model.updateLookupQuery { $0.title = "Salt Road" }
        await h.model.searchLookup()
        await h.model.addLookupSelection()
        #expect(h.model.alert == "“Salt Road” is already in your library and marked as on Audible.")
        #expect(try h.store().books().count == 12)
        // The copy it had is filled in; there is still one.
        #expect(
            try h.book(salt).externalCopies
                == [ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: "B0SALTROAD")])
        #expect(try h.book(salt).asin == "B0SALTROAD")
        #expect(h.model.selection == [salt])
        // The files do not hold that ASIN yet, and the inspector says so.
        #expect(h.model.appOnlyMarkers.contains(.asin))
        #expect(h.model.selectionCommands.rewriteTags)
    }

    /// N4: adding the same book a second time says so too, and adds nothing.
    @Test func N4_addingTheSameBookAgainAddsNothing() async throws {
        let h = try await searched([glassTide(cover: false)])
        await h.model.addLookupSelection()
        let id = try #require(try added(h).id)
        #expect(h.model.alert == nil)

        h.model.beginAddAudibleBook()
        // Found again under another title: it is the same Audible book.
        var again = glassTide(cover: false)
        again.metadata.title = "The Glass Tide (Unabridged)"
        h.lookup.find(.audible, [again])
        h.model.updateLookupQuery { $0.title = "Glass Tide" }
        await h.model.searchLookup()
        await h.model.addLookupSelection()
        #expect(h.model.alert == "“The Glass Tide” is already in your library and marked as on Audible.")
        #expect(try h.store().books().count == 13)
        #expect(try h.book(id).externalCopies.count == 1)
        #expect(h.model.selection == [id])
    }

    // MARK: N5 By hand

    /// N5
    @Test func N5_aBookTheCatalogueDoesNotHaveIsAddedByHand() async throws {
        let h = try await Harness.demo()
        h.model.audibleStore = .de
        let files = try filesOnDisk(h)
        h.model.beginAddAudibleBook()
        h.model.updateLookupQuery {
            $0.title = "  A Rare Recording "
            $0.author = " Ines Calloway "
        }
        // Not before the catalogue has been tried.
        #expect(h.model.lookup?.canAddByHand == false)
        await h.model.addAudibleBookByHand()
        #expect(h.model.lookup != nil)
        #expect(try h.store().books().count == 12)

        await h.model.searchLookup()
        #expect(h.model.lookup?.phase == .noResults)
        #expect(h.model.lookup?.canAddByHand == true)
        await h.model.addAudibleBookByHand()
        #expect(h.model.lookup == nil)
        #expect(h.model.alert == nil)

        let book = try added(h, "A Rare Recording")
        #expect(book.metadata == BookMetadata(title: "A Rare Recording", authors: ["Ines Calloway"]))
        #expect(book.asin == nil)
        #expect(book.externalCopies == [ExternalCopy(kind: .audible, form: .audio, store: "de")])
        #expect(h.model.selection == [try #require(book.id)])
        let row = try #require(h.model.rows.first { $0.id == book.id })
        #expect(row.coverURL == nil)
        #expect(h.lookup.coverURLs.isEmpty)
        // N8
        #expect(try filesOnDisk(h) == files)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
    }

    /// N5: offered when Audible could not be reached; a title and an author are needed.
    @Test func N5_byHandWhenAudibleCannotBeReached() async throws {
        let h = try await Harness.demo()
        h.lookup.fail(.audible, .notReachable)
        h.model.beginAddAudibleBook()
        h.model.updateLookupQuery { $0.title = "Unreachable" }
        await h.model.searchLookup()
        #expect(h.model.lookup?.failureText == "Audible could not be reached.")
        // Offered, but not to be had without an author; the model says what is missing.
        #expect(h.model.lookup?.offersAddByHand == true)
        #expect(h.model.lookup?.canAddByHand == false)
        #expect(h.model.lookup?.addByHandHelp == "Type the book’s author above to add it without a match.")
        await h.model.addAudibleBookByHand()
        #expect(h.model.lookup != nil)
        #expect(try h.store().books().count == 12)

        // Both can be changed after the search, but neither emptied.
        h.model.updateLookupQuery { $0.author = "Ines Calloway" }
        #expect(h.model.lookup?.canAddByHand == true)
        h.model.updateLookupQuery { $0.title = " " }
        #expect(h.model.lookup?.canAddByHand == false)
        await h.model.addAudibleBookByHand()
        #expect(h.model.lookup != nil)
        h.model.updateLookupQuery { $0.title = "Still Unreachable" }
        #expect(h.model.lookup?.canAddByHand == true)
        await h.model.addAudibleBookByHand()
        let book = try added(h, "Still Unreachable")
        #expect(book.authors == ["Ines Calloway"])
        #expect(book.isOwned(on: .audible))
        #expect(!book.needsAttention)
        #expect(h.model.selection == [try #require(book.id)])
    }

    /// N5: an Audible ID typed in its box goes with a book added by hand, when it is a
    /// well-formed one: it is the book's ASIN and its copy's item ID.
    @Test func N5_byHandTheTypedAudibleIDGoesWithTheBook() async throws {
        let h = try await Harness.demo()
        h.model.audibleStore = .uk
        h.lookup.fail(.audible, .notReachable)
        h.model.beginAddAudibleBook()
        h.model.updateLookupQuery {
            $0.title = "Pasted"
            $0.author = "Ines Calloway"
            $0.asin = " b0pasted01 "
        }
        await h.model.searchLookup()
        #expect(h.model.lookup?.typedAudibleID == "B0PASTED01")
        await h.model.addAudibleBookByHand()
        let book = try added(h, "Pasted")
        #expect(book.asin == "B0PASTED01")
        #expect(book.externalCopies == [ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: "B0PASTED01")])

        // Anything that is not an Audible ID is left out.
        h.model.beginAddAudibleBook()
        h.model.updateLookupQuery {
            $0.title = "Mistyped"
            $0.author = "Ines Calloway"
            $0.asin = "not/an id"
        }
        await h.model.searchLookup()
        #expect(h.model.lookup?.typedAudibleID == nil)
        await h.model.addAudibleBookByHand()
        let other = try added(h, "Mistyped")
        #expect(other.asin == nil)
        #expect(other.externalCopies == [ExternalCopy(kind: .audible, form: .audio, store: "uk")])
    }

    /// N5, N4: typed by hand, a book the library has is marked, not added twice.
    @Test func N5_byHandABookAlreadyInTheLibraryIsMarked() async throws {
        let h = try await Harness.demo()
        h.model.beginAddAudibleBook()
        h.model.updateLookupQuery {
            $0.title = "quiet rivers"
            $0.author = "Amara Okafor"
        }
        await h.model.searchLookup()
        await h.model.addAudibleBookByHand()
        let rivers = try h.id("Quiet Rivers")
        #expect(
            h.model.alert == "“Quiet Rivers” was already in your library. It is now marked as also on Audible.")
        #expect(try h.store().books().count == 12)
        #expect(try h.book(rivers).isOwned(on: .audible))
        #expect(h.model.selection == [rivers])
    }

    // MARK: N6 The sources, in words

    /// N6
    @Test func N6_theBottomLineNamesOnlyAudible() async throws {
        let h = try await Harness.demo()
        h.model.audibleStore = .uk
        h.lookup.find(.audible, [glassTide()])
        h.model.beginAddAudibleBook()
        #expect(h.model.lookupSourcesText == "Results from Audible (UK, US, Australia)")
        #expect(h.model.lookup?.reminderText == "The book is added to your library without files.")
        h.model.updateLookupQuery { $0.title = "The Glass Tide" }
        await h.model.searchLookup()
        #expect(h.model.lookupSourcesText == "Audible (UK, US, Australia): 1 match")
        h.model.audibleStore = .de
        #expect(h.model.lookupSourcesText == "Results from Audible (Germany, US, UK, Australia)")

        // A lookup for a book names both, as before.
        h.model.cancelLookup()
        try await h.select("Salt Road")
        h.model.beginLookup()
        #expect(h.model.lookupSourcesText == "Results from Open Library and Audible (Germany, US, UK, Australia)")
    }

    // MARK: N7 The sheet's life

    /// N7: one sheet at a time.
    @Test func N7_oneSheetAtATime() async throws {
        let h = try await Harness.demo()
        try await h.select("Salt Road")
        h.model.beginAddAudibleBook()
        #expect(h.model.lookup?.target == .newAudibleBook)
        #expect(!h.model.canAddAudibleBook)
        #expect(!h.model.canLookUp)
        h.model.beginLookup()
        h.model.beginAddAudibleBook()
        #expect(h.model.lookup?.target == .newAudibleBook)

        // The inspected book changing is nothing to an add.
        try await h.select("Quiet Rivers")
        h.model.select([])
        await h.model.settle()
        #expect(h.model.lookup?.target == .newAudibleBook)

        h.model.cancelLookup()
        #expect(h.model.lookup == nil)
        try await h.select("Salt Road")
        h.model.beginLookup()
        #expect(!h.model.canAddAudibleBook)
        h.model.beginAddAudibleBook()
        #expect(h.model.lookup?.target == .book(try h.id("Salt Road")))
    }

    /// N7: an import to review takes the window, and the library changing closes the sheet.
    @Test func N7_anImportOrAnotherLibraryClosesTheSheet() async throws {
        let h = try await searched([glassTide()])
        let inbox = try Harness.inbox()
        await h.model.beginImport([inbox.appendingPathComponent("Quiet Rivers.epub")])
        #expect(h.model.review != nil)
        #expect(h.model.lookup == nil)
        await h.model.addLookupSelection()
        #expect(try h.store().books().count == 12)
        h.model.cancelImport()

        h.model.beginAddAudibleBook()
        #expect(h.model.lookup != nil)
        await h.model.chooseLibrary(try makeTempDir())
        #expect(h.model.lookup == nil)
        #expect(h.model.canAddAudibleBook)
    }

    /// N7: an answer that arrives after the sheet closed is not shown in the next one.
    @Test func N7_aLateAnswerIsNotUsedByAnotherSheet() async throws {
        let h = try await Harness.demo()
        let gate = Gate()
        h.lookup.hold(.audible, at: gate, then: [glassTide()])
        h.model.beginAddAudibleBook()
        h.model.updateLookupQuery { $0.title = "The Glass Tide" }
        let searching = Task { await h.model.searchLookup() }
        await gate.arrival()
        #expect(h.model.lookup?.phase == .searching)
        #expect(h.model.lookup?.canAddByHand == false)
        h.model.cancelLookup()
        h.model.beginAddAudibleBook()
        await gate.release()
        await searching.value
        await h.model.settle()
        #expect(h.model.lookup?.phase == .idle)
        #expect(h.model.lookup?.candidates.isEmpty == true)
        #expect(h.model.lookup?.hasSearched == false)
    }

    /// N7: while the cover is on its way the sheet says so, and the book cannot be added twice.
    @Test func N7_addingTwiceIsImpossible() async throws {
        let h = try await searched([glassTide()])
        let gate = Gate()
        let png = png
        h.lookup.cover { _ in
            await gate.wait()
            return (png, 200)
        }
        let adding = Task { await h.model.addLookupSelection() }
        await gate.arrival()
        #expect(h.model.lookup?.phase == .applying)
        #expect(h.model.lookup?.canAdd == false)
        #expect(h.model.lookup?.canAddByHand == false)
        #expect(h.model.busyLabel == "Adding book…")

        // A second Add, by either button, and anything else in the sheet, does nothing.
        await h.model.addLookupSelection()
        await h.model.addAudibleBookByHand()
        h.model.updateLookupQuery { $0.title = "Other" }
        await h.model.searchLookup()
        await h.model.selectLookupCandidate(nil)
        #expect(h.model.lookup?.phase == .applying)
        #expect(h.model.lookup?.query.title == "The Glass Tide")
        #expect(try h.store().books().count == 12)

        await gate.release()
        await adding.value
        #expect(h.model.lookup == nil)
        #expect(h.model.busyLabel == nil)
        #expect(h.lookup.coverURLs.count == 1)
        #expect(try h.store().books().count == 13)
        await h.model.addLookupSelection()
        #expect(try h.store().books().count == 13)
    }

    /// V5: while a book is being added the add sheet shows its own progress, and stays
    /// up: the window's progress sheet is not wanted in its place. Any other operation
    /// is the progress sheet's to show.
    @Test func V5_theAddSheetShowsItsOwnProgressWhileAdding() async throws {
        let h = try await searched([glassTide()])
        #expect(h.model.progressSheetLabel == nil)
        let gate = Gate()
        let png = png
        h.lookup.cover { _ in
            await gate.wait()
            return (png, 200)
        }
        let adding = Task { await h.model.addLookupSelection() }
        await gate.arrival()
        #expect(h.model.addAudibleLookup?.phase == .applying)
        #expect(h.model.busyLabel == "Adding book…")
        #expect(h.model.progressSheetLabel == nil)
        await gate.release()
        await adding.value
        #expect(h.model.progressSheetLabel == nil)

        let other = Gate()
        let salt = try h.id("Salt Road")
        h.model.beforeOperation = { await other.wait() }
        let marking = Task { await h.model.setOnAudible(true, for: [salt]) }
        await other.arrival()
        #expect(h.model.progressSheetLabel == "Updating…")
        #expect(h.model.progressSheetLabel == h.model.busyLabel)
        await other.release()
        await marking.value
        h.model.beforeOperation = nil
        #expect(h.model.progressSheetLabel == nil)
    }

    /// V5: an add sheet that is only open, or searching, does not hide another operation's progress.
    @Test func V5_anOpenAddSheetDoesNotHideProgress() async throws {
        let h = try await Harness.demo()
        let salt = try h.id("Salt Road")
        h.model.beginAddAudibleBook()
        #expect(h.model.addAudibleLookup?.phase == .idle)
        let gate = Gate()
        h.model.beforeOperation = { await gate.wait() }
        let marking = Task { await h.model.setOnAudible(true, for: [salt]) }
        await gate.arrival()
        #expect(h.model.addAudibleLookup != nil)
        #expect(h.model.progressSheetLabel == "Updating…")
        await gate.release()
        await marking.value
        h.model.beforeOperation = nil
    }

    /// N7: closing the sheet while the cover is on its way adds nothing, cancels the
    /// download, and ends the operation there and then: nothing is busy while a
    /// download nobody wants runs out.
    @Test func N7_closingWhileAddingAddsNothing() async throws {
        let h = try await searched([glassTide()])
        let gate = Gate()
        let cancelled = Gate()
        let png = png
        h.lookup.cover { _ in
            await gate.wait()
            if Task.isCancelled { await cancelled.release() }
            return (png, 200)
        }
        let adding = Task { await h.model.addLookupSelection() }
        await gate.arrival()
        #expect(h.model.busyLabel == "Adding book…")
        h.model.cancelLookup()
        // At once, with the download still on its way.
        #expect(h.model.lookup == nil)
        #expect(h.model.busyLabel == nil)
        #expect(h.model.progressSheetLabel == nil)
        #expect(h.model.canAddAudibleBook)

        // Something else can be done meanwhile, and the late cover does not disturb it.
        let salt = try h.id("Salt Road")
        await h.model.setOnAudible(true, for: [salt])
        #expect(try h.book(salt).isOwned(on: .audible))
        h.model.beginAddAudibleBook()
        #expect(h.model.addAudibleLookup?.phase == .idle)

        await gate.release()
        await adding.value
        await cancelled.wait()
        #expect(h.model.addAudibleLookup?.phase == .idle)
        #expect(h.model.busyLabel == nil)
        #expect(h.model.alert == nil)
        #expect(try h.store().books().count == 12)
        #expect(h.model.sidebar.counts[.onAudible] == 1)
    }

    /// N7: unsaved edits made while the sheet was open are not taken out of the inspector.
    @Test func N7_unsavedEditsKeepTheSelection() async throws {
        let h = try await searched([glassTide(cover: false)])
        let salt = try await h.edit("Salt Road", newTitle: "Salt Roads")
        await h.model.addLookupSelection()
        #expect(h.model.lookup == nil)
        #expect(try added(h).isOwned(on: .audible))
        #expect(h.model.selection == [salt])
        #expect(h.draft?.title == "Salt Roads")
        #expect(h.model.sidebarSelection == .allBooks)
        #expect(h.model.prompt == nil)
    }

    // MARK: N8 What adding writes

    /// N8: only the stored cover is written, and Undo has nothing new to reverse.
    @Test func N8_addingWritesOnlyTheCoverAndRecordsNoUndo() async throws {
        let h = try await searched([glassTide()])
        h.lookup.cover(png)
        let before = try filesOnDisk(h)
        await h.model.addLookupSelection()
        let after = try filesOnDisk(h)
        let new = Set(after.keys).subtracting(before.keys)
        #expect(new.count == 1)
        #expect(new.allSatisfy { $0.hasPrefix("/.voxcarrel/covers/") })
        #expect(after.filter { !new.contains($0.key) } == before)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
        #expect(h.model.canUndo)

        // Nothing at launch finds fault with the new book.
        await h.model.retryLibrary()
        #expect(h.model.libraryCheck == nil)
        #expect(h.model.sidebar.counts[.needsAttention] == 1)
        #expect(h.model.sidebar.counts[.onAudible] == 1)
    }
}
