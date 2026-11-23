import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

private let seriesName = "Tidewater Chronicles"
private let seriesItem = SidebarItem.browse(.series, seriesName)
private let notChecked = "Not checked against Audible"

/// Series completeness in the app model (plan 9, Task 4). SV1–SV14.
///
/// The demo library has three books of "Tidewater Chronicles", numbered 1 to 3, each
/// with files. Audible's catalogue is a fake: nothing reaches the network.
@MainActor
@Suite struct AppModelSeriesTests {
    private typealias Member = FakeCatalogue.Member

    /// The series as Audible lists it: the library's three books, and two it lacks.
    private func tidewater(
        id: String = "B0TIDEWATR", title: String = seriesName, _ change: (inout [Member]) -> Void = { _ in }
    ) -> FakeCatalogue.Series {
        var members = [
            Member(asin: "B0SALTROAD", title: "Salt Road", number: "1"),
            Member(asin: "B0DROWNBEL", title: "The Drowned Bell", number: "2"),
            Member(asin: "B0HARBOURG", title: "Harbour of Glass", number: "3"),
            Member(asin: "B0GLASSTID", title: "The Glass Tide", number: "4", minutes: 615),
            Member(asin: "B0LANTERNR", title: "Lantern Reef", number: "5"),
        ]
        change(&members)
        return FakeCatalogue.Series(id: id, title: title, members: members)
    }

    /// A demo library that shows its series, with Audible's US store, and no other,
    /// listing `series`. `prepare` changes the library before it is opened.
    private func shown(
        _ series: [FakeCatalogue.Series]? = nil, prepare: (Harness) throws -> Void = { _ in }
    ) async throws -> Harness {
        let h = try await Harness.demo(start: false)
        h.model.audibleStore = .us
        h.model.otherAudibleStores = []
        h.lookup.catalogue.set(series ?? [tidewater()])
        try prepare(h)
        await h.model.start()
        h.model.sidebarSelection = seriesItem
        await h.model.settle()
        return h
    }

    /// The same, with Check Series done.
    private func checked(
        _ series: [FakeCatalogue.Series]? = nil, prepare: (Harness) throws -> Void = { _ in }
    ) async throws -> Harness {
        let h = try await shown(series, prepare: prepare)
        await h.model.checkSeries()
        #expect(h.model.alert == nil)
        return h
    }

    private func missingRow(_ h: Harness, _ title: String) throws -> BookRow {
        try #require(h.model.rows.first { $0.isMissing && $0.book.title == title }, "no missing row titled \(title)")
    }

    /// Clicks the missing row and waits for the inspector.
    @discardableResult
    private func selectMissing(_ h: Harness, _ title: String) async throws -> BookRow {
        let row = try missingRow(h, title)
        h.model.click(row.id, modifiers: [])
        await h.model.settle()
        return row
    }

    /// Adds a book of the series that is on Audible and has no files here.
    @discardableResult
    private func addBook(
        _ h: Harness, _ title: String, number: String?, asin: String? = nil, series: String = seriesName
    ) throws -> Int64 {
        var metadata = BookMetadata(title: title, authors: ["Ines Calloway"])
        metadata.series = series
        metadata.seriesNumber = number
        let copy = ExternalCopy(kind: .audible, form: .audio, store: "us", itemId: asin)
        let outcome = try LibraryService(store: try h.store()).addExternalBook(metadata: metadata, cover: nil, copy: copy)
        guard case .added(let id) = outcome else { throw LibraryError.bookNotFound(0) }
        return id
    }

    private func strays(_ h: Harness) -> [Int64] {
        h.model.worker?.strayIds.withLock { $0 } ?? []
    }

    // MARK: SV1 The header

    /// SV1: there is a header exactly while one series is what the sidebar shows.
    @Test func thereIsAHeaderOnlyForASeries() async throws {
        let h = try await Harness.demo()
        #expect(h.model.seriesHeader == nil)
        h.model.sidebarSelection = .browse(.authors, "Ines Calloway")
        await h.model.settle()
        #expect(h.model.seriesHeader == nil)
        h.model.sidebarSelection = .onAudible
        await h.model.settle()
        #expect(h.model.seriesHeader == nil)

        h.model.sidebarSelection = seriesItem
        await h.model.settle()
        let header = try #require(h.model.seriesHeader)
        #expect(header.summary == notChecked)
        #expect(header.source == nil)
        #expect(header.notes == [])
        #expect(header.canCheck)
        #expect(!header.canUseAudibleNumbers)
        #expect(!header.canUnlink)
        #expect(!header.isLinked)
        #expect(!header.showsHidden)

        h.model.sidebarSelection = .allBooks
        await h.model.settle()
        #expect(h.model.seriesHeader == nil)
    }

    /// SV1, SV2: with Audible off as a lookup source the series cannot be checked, and
    /// asking sends nothing.
    @Test func nothingIsCheckedOrSentWithAudibleOff() async throws {
        let h = try await shown()
        h.model.setLookupSource(.audible, on: false)
        #expect(h.model.seriesHeader?.canCheck == false)
        await h.model.checkSeries()
        #expect(h.lookup.catalogue.requests.isEmpty)
        #expect(h.model.seriesHeader?.summary == notChecked)
        #expect(h.model.alert == nil)
    }

    /// SV1: with no library open there is nothing to check.
    @Test func nothingIsCheckedWithNoLibraryOpen() async throws {
        let h = try Harness(root: try makeTempDir(), choose: false)
        await h.model.start()
        h.model.sidebarSelection = seriesItem
        await h.model.settle()
        #expect(h.model.seriesHeader?.canCheck != true)
        await h.model.checkSeries()
        #expect(h.lookup.catalogue.requests.isEmpty)
    }

    // MARK: SV2 Asking

    /// SV2: a check is an operation: it says what it is doing, and is refused while
    /// another runs.
    @Test func aCheckIsAnOperation() async throws {
        let h = try await shown()
        h.recordBusyLabels()
        await h.model.checkSeries()
        #expect(h.busyLabels == ["Checking the series…"])
        #expect(h.model.busyLabel == nil)

        let busy = try await shown()
        busy.model.busyLabel = "Working…"
        #expect(busy.model.seriesHeader?.canCheck == false)
        await busy.model.checkSeries()
        #expect(busy.lookup.catalogue.requests.isEmpty)
        #expect(busy.model.busyLabel == "Working…")
        busy.model.busyLabel = nil
        #expect(busy.model.seriesHeader?.summary == notChecked)
    }

    /// SV2: the books with an Audible ID are asked about first, by that ID, then the
    /// others by number, by title and author; the asking stops once the answers agree.
    @Test func booksWithAnAudibleIdAreAskedAboutFirst() async throws {
        let h = try await shown { h in
            var book = try h.book(try h.id("Harbour of Glass"))
            book.asin = "B0HARBOURG"
            try h.store().update(book)
        }
        await h.model.checkSeries()
        let asked = h.lookup.catalogue.bookRequests
        // Two of the three books: their answers name the same one series.
        try #require(asked.count == 2)
        #expect(asked[0].path.hasSuffix("/products/B0HARBOURG"))
        #expect(asked[1].path.hasSuffix("/products"))
        let query = URLComponents(url: asked[1], resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "title" }?.value == "Salt Road")
        #expect(query.first { $0.name == "author" }?.value == "Ines Calloway")
        #expect(h.model.seriesHeader?.isLinked == true)
    }

    /// SV2: at most five books are asked about, however many the series has.
    @Test func atMostFiveBooksAreAskedAbout() async throws {
        let titles = ["Salt Road", "The Drowned Bell", "Harbour of Glass", "Four", "Five", "Six", "Seven"]
        let members = titles.enumerated().map { index, title in
            Member(asin: "B0MEMBER0\(index)", title: title, number: String(index + 1))
        }
        // Two series hold every book, so the answers never settle on one.
        let series = [
            FakeCatalogue.Series(id: "B0SERIESAA", title: "Tidewater, as published", members: members),
            FakeCatalogue.Series(id: "B0SERIESBB", title: "Tidewater, in story order", members: members),
        ]
        let h = try await shown(series) { h in
            for (index, title) in titles.enumerated().dropFirst(3) {
                try self.addBook(h, title, number: String(index + 1))
            }
        }
        #expect(h.model.rows.count == 7)
        await h.model.checkSeries()
        #expect(h.lookup.catalogue.bookRequests.count == 5)
        #expect(h.model.seriesChoices?.count == 2)
    }

    // MARK: SV3 Which series

    /// SV3: the one series that holds the most of the books is used without asking.
    @Test func theSeriesWithTheMostBooksIsUsedWithoutAsking() async throws {
        let omnibus = FakeCatalogue.Series(
            id: "B0OMNIBUSS", title: "Tidewater Omnibus",
            members: [Member(asin: "B0SALTROAD", title: "Salt Road", number: "1")])
        let h = try await checked([omnibus, tidewater()])
        #expect(h.model.seriesChoices == nil)
        #expect(h.model.seriesHeader?.summary == "3 of 5 on Audible's list")
        #expect(h.model.seriesHeader?.source?.hasPrefix("Tidewater Chronicles · Audible US · checked ") == true)
    }

    /// SV3, SV4: when two series tie, the owner chooses, and nothing is fetched or
    /// stored until then. Cancelling changes nothing.
    @Test func aTieIsPutToTheOwner() async throws {
        let published = tidewater(id: "B0PUBLISHD", title: "Tidewater (publication order)")
        let story = tidewater(id: "B0STORYORD", title: "Tidewater (chronological order)") { members in
            members.append(Member(asin: "B0PREQUEL1", title: "Before the Tide", number: "0.5"))
        }
        let h = try await shown([published, story])
        h.recordBusyLabels()
        await h.model.checkSeries()

        let choices = try #require(h.model.seriesChoices)
        #expect(choices.map(\.title) == ["Tidewater (chronological order)", "Tidewater (publication order)"])
        #expect(choices.allSatisfy { $0.detail == "Audible US · your books are numbers 1, 2 and 3 here" })
        #expect(Set(choices.map(\.id)).count == 2)
        #expect(h.lookup.catalogue.listRequests.isEmpty)
        #expect(h.model.seriesHeader?.summary == notChecked)
        #expect(h.model.busyLabel == nil)
        #expect(h.model.rows.count == 3)

        // A choice that was not offered is no choice.
        await h.model.chooseSeries("us:B0NOSUCHID")
        #expect(h.model.seriesChoices == choices)
        #expect(h.lookup.catalogue.listRequests.isEmpty)

        let sent = h.lookup.catalogue.requests.count
        h.model.cancelSeriesChoice()
        #expect(h.model.seriesChoices == nil)
        #expect(h.model.seriesHeader?.summary == notChecked)
        #expect(h.lookup.catalogue.requests.count == sent)
        #expect(try LibraryService(store: try h.store()).seriesCompleteness(forSeries: seriesName) == nil)

        // Asked again, and answered.
        await h.model.checkSeries()
        let again = try #require(h.model.seriesChoices)
        await h.model.chooseSeries(again[0].id)
        #expect(h.model.seriesChoices == nil)
        #expect(h.model.busyLabel == nil)
        #expect(h.busyLabels == ["Checking the series…", "Checking the series…", "Checking the series…"])
        #expect(h.model.seriesHeader?.summary == "3 of 6 on Audible's list")
        #expect(h.model.seriesHeader?.source?.hasPrefix("Tidewater (chronological order) · Audible US") == true)
        #expect(h.model.rows.filter(\.isMissing).map(\.book.title) == ["Before the Tide", "The Glass Tide", "Lantern Reef"])
        #expect(h.model.alert == nil)
    }

    /// SV3: each choice says which numbers the owner's books are in that Audible series,
    /// whatever numbers the owner has given them.
    @Test func aChoiceSaysTheBooksNumbersInThatSeries() async throws {
        let published = tidewater(id: "B0PUBLISHD", title: "Tidewater (publication order)")
        let story = tidewater(id: "B0STORYORD", title: "Tidewater (chronological order)") { members in
            members[0].number = "2"
            members[1].number = "4"
            members[2].number = "5"
        }
        let h = try await shown([published, story])
        await h.model.checkSeries()
        #expect(h.model.seriesChoices?.map(\.detail) == [
            "Audible US · your books are numbers 2, 4 and 5 here",
            "Audible US · your books are numbers 1, 2 and 3 here",
        ])
    }

    /// SV3: while the owner is being asked which series, no lookup is begun beneath
    /// the question: its sheet would come up only when the question had been answered.
    @Test func noLookupBeginsWhileTheChoiceIsAsked() async throws {
        let published = tidewater(id: "B0PUBLISHD", title: "Tidewater (publication order)")
        let story = tidewater(id: "B0STORYORD", title: "Tidewater (chronological order)")
        let h = try await shown([published, story])
        try await h.select("Salt Road")
        #expect(h.model.canLookUp)
        #expect(h.model.canAddAudibleBook)

        await h.model.checkSeries()
        #expect(h.model.seriesChoices != nil)
        #expect(!h.model.canLookUp)
        #expect(!h.model.canAddAudibleBook)
        h.model.beginLookup()
        h.model.beginAddAudibleBook()
        #expect(h.model.lookup == nil)

        h.model.cancelSeriesChoice()
        #expect(h.model.canLookUp)
        #expect(h.model.canAddAudibleBook)
    }

    // MARK: SV4 The list

    /// SV4: the list is fetched and stored, the header and the rows show it, and it is
    /// still there, with no request, when the app is opened again.
    @Test func aCheckStoresTheListAndShowsIt() async throws {
        let h = try await checked()
        let header = try #require(h.model.seriesHeader)
        #expect(header.summary == "3 of 5 on Audible's list")
        #expect(header.isLinked)
        #expect(header.canCheck)
        #expect(header.canUnlink)
        #expect(header.notes == [])
        #expect(h.titles == ["Salt Road", "The Drowned Bell", "Harbour of Glass", "The Glass Tide", "Lantern Reef"])
        #expect(h.model.busyLabel == nil)
        // SC27: storing a list is not something Undo reverses.
        #expect(h.model.undoLabel == Harness.demoUndoLabel)

        let sent = h.lookup.catalogue.requests.count
        let again = h.relaunched()
        await again.start()
        again.sidebarSelection = seriesItem
        await again.settle()
        #expect(again.seriesHeader?.summary == "3 of 5 on Audible's list")
        #expect(again.rows.map(\.book.title) == h.titles)
        #expect(h.lookup.catalogue.requests.count == sent)
    }

    /// SV4: Audible lists no series for any of the books.
    @Test func noSeriesIsFound() async throws {
        let h = try await shown([])
        await h.model.checkSeries()
        #expect(h.model.alert == "Audible does not list a series for these books.")
        #expect(h.model.seriesHeader?.summary == notChecked)
        #expect(h.model.seriesChoices == nil)
        #expect(h.model.busyLabel == nil)
        #expect(h.lookup.catalogue.listRequests.isEmpty)
    }

    /// SV4: when Audible cannot be reached the alert is the lookup's own for that, and
    /// what was stored before stays as it was.
    @Test func aNetworkFailureChangesNothing() async throws {
        let h = try await checked()
        let before = h.model.seriesHeader
        let rows = h.model.rows
        h.lookup.catalogue.fail(.notReachable)
        await h.model.checkSeries()
        #expect(h.model.alert == UserMessage.text(for: LookupError.notReachable, source: .audible))
        #expect(h.model.alert == "Audible could not be reached.")
        #expect(h.model.seriesHeader == before)
        #expect(h.model.rows == rows)
        #expect(h.model.busyLabel == nil)

        // The same for a series that has never been checked.
        let fresh = try await shown()
        fresh.lookup.catalogue.fail(.refused(status: 503))
        await fresh.model.checkSeries()
        #expect(fresh.model.alert == "Audible answered with an error.")
        #expect(fresh.model.seriesHeader?.summary == notChecked)
        #expect(fresh.model.rows.count == 3)
    }

    /// SV4: a list that fails to arrive after the series was found stores nothing.
    @Test func aChosenSeriesThatCannotBeFetchedStoresNothing() async throws {
        let h = try await shown([tidewater(id: "B0PUBLISHD", title: "One"), tidewater(id: "B0STORYORD", title: "Two")])
        await h.model.checkSeries()
        let choices = try #require(h.model.seriesChoices)
        h.lookup.catalogue.fail(.notReachable)
        await h.model.chooseSeries(choices[0].id)
        #expect(h.model.alert == "Audible could not be reached.")
        #expect(h.model.seriesChoices == nil)
        #expect(h.model.seriesHeader?.summary == notChecked)
        #expect(h.model.busyLabel == nil)
    }

    /// SV2: Audible is turned off while the owner is being asked which series: the
    /// answer sends nothing, and says why.
    @Test func aChoiceMadeWithAudibleOffSendsNothing() async throws {
        let h = try await shown([tidewater(id: "B0PUBLISHD", title: "One"), tidewater(id: "B0STORYORD", title: "Two")])
        await h.model.checkSeries()
        let choices = try #require(h.model.seriesChoices)
        let sent = h.lookup.catalogue.requests.count
        h.model.setLookupSource(.audible, on: false)
        h.recordBusyLabels()
        await h.model.chooseSeries(choices[0].id)
        #expect(h.lookup.catalogue.requests.count == sent)
        #expect(h.busyLabels == [])
        #expect(h.model.seriesChoices == nil)
        #expect(h.model.alert == "Turn on Audible as a lookup source in Settings.")
        #expect(h.model.seriesHeader?.summary == notChecked)
    }

    // MARK: SV5 The rows

    /// SV5: one row for each missing entry, with a negative id of its own and a book
    /// built from the entry, under the owner's name for the series.
    @Test func aMissingEntryIsARow() async throws {
        let h = try await checked([tidewater(title: "The Tidewater Chronicles (Audible)")])
        let missing = h.model.rows.filter(\.isMissing)
        #expect(missing.map(\.book.title) == ["The Glass Tide", "Lantern Reef"])
        #expect(missing.allSatisfy { $0.id < 0 })
        #expect(Set(missing.map(\.id)).count == 2)
        #expect(h.model.rows.filter { !$0.isMissing }.allSatisfy { $0.id > 0 && $0.missing == nil })

        let row = try missingRow(h, "The Glass Tide")
        let entry = try #require(row.missing)
        #expect(row.id == -entry.id)
        #expect(entry.entry.preferred.asin == "B0GLASSTID")
        #expect(row.book.id == nil)
        #expect(row.book.series == seriesName)
        #expect(row.book.seriesNumber == "4")
        #expect(row.book.authors == ["Ines Calloway"])
        #expect(row.book.narrators == ["Marcus Lindqvist"])
        #expect(row.book.durationSeconds == 36_900)
        #expect(row.book.externalCopies.isEmpty)
        #expect(!row.hasFiles)
        #expect(!row.hasAudio)
        #expect(!row.hasEbook)
        #expect(row.formats.isEmpty)
        #expect(row.coverURL == nil)
        #expect(row.outsideFiles.isEmpty)
        #expect(!row.isOnAudible)
    }

    /// SV5: in series order a missing row falls in place by its number; under any
    /// other sort the missing rows come after the library's books, in series order.
    @Test func missingRowsFallInPlaceByNumber() async throws {
        let h = try await checked([
            tidewater { members in
                members.insert(Member(asin: "B0LOWWATER", title: "Low Water", number: "2.5"), at: 2)
                members.append(Member(asin: "B0UNNUMBER", title: "A Tidewater Companion", number: nil))
            },
        ])
        let inSeriesOrder = [
            "Salt Road", "The Drowned Bell", "Low Water", "Harbour of Glass", "The Glass Tide", "Lantern Reef",
            "A Tidewater Companion",
        ]
        #expect(h.titles == inSeriesOrder)
        let missing = ["Low Water", "The Glass Tide", "Lantern Reef", "A Tidewater Companion"]

        h.model.sort = BookSort(key: .title, ascending: false)
        #expect(h.titles == Array(inSeriesOrder.dropLast().reversed()) + ["A Tidewater Companion"])

        h.model.sort = BookSort(key: .length, ascending: false)
        #expect(Array(h.titles.suffix(4)) == missing)
        #expect(h.model.rows.prefix(3).allSatisfy { !$0.isMissing })

        h.model.sort = BookSort(key: .dateAdded)
        #expect(Array(h.titles.suffix(4)) == missing)
        h.model.sort = BookSort(key: .author, ascending: false)
        #expect(Array(h.titles.suffix(4)) == missing)

        h.model.sort = BookSort()
        #expect(h.titles == inSeriesOrder)
    }

    /// SV5, SV8: a hidden entry has no row, unless hidden entries are shown; hiding
    /// and showing work on the one selected missing row.
    @Test func aMissingEntryCanBeHiddenAndShownAgain() async throws {
        let h = try await checked()
        let sent = h.lookup.catalogue.requests.count
        let row = try await selectMissing(h, "Lantern Reef")
        await h.model.setSelectedMissingHidden(true)
        #expect(h.titles == ["Salt Road", "The Drowned Bell", "Harbour of Glass", "The Glass Tide"])
        #expect(h.model.selection.isEmpty)
        #expect(h.model.inspecting == .nothing)
        var header = try #require(h.model.seriesHeader)
        #expect(header.summary == "3 of 4 on Audible's list")
        #expect(header.notes == ["1 hidden"])
        #expect(header.hiddenCount == 1)
        #expect(!header.showsHidden)

        h.model.showsHiddenMissing = true
        #expect(h.model.seriesHeader?.showsHidden == true)
        #expect(h.titles == ["Salt Road", "The Drowned Bell", "Harbour of Glass", "The Glass Tide", "Lantern Reef"])
        let hidden = try missingRow(h, "Lantern Reef")
        #expect(hidden.id == row.id)
        #expect(hidden.missing?.isHidden == true)

        // Shown again; it stays selected, since it is still a row.
        h.model.click(hidden.id, modifiers: [])
        await h.model.settle()
        await h.model.setSelectedMissingHidden(false)
        header = try #require(h.model.seriesHeader)
        #expect(header.summary == "3 of 5 on Audible's list")
        #expect(header.notes == [])
        #expect(h.model.selection == [hidden.id])
        #expect(try missingRow(h, "Lantern Reef").missing?.isHidden == false)
        if case .missing(let entry) = h.model.inspecting {
            #expect(!entry.isHidden)
        } else {
            Issue.record("the missing row is not what is inspected")
        }

        // Hidden once more, and the hidden rows put away: the row goes, and its selection with it.
        await h.model.setSelectedMissingHidden(true)
        #expect(h.model.selection == [hidden.id])
        h.model.showsHiddenMissing = false
        await h.model.settle()
        #expect(h.titles == ["Salt Road", "The Drowned Bell", "Harbour of Glass", "The Glass Tide"])
        #expect(h.model.selection.isEmpty)
        #expect(h.model.inspecting == .nothing)
        #expect(h.lookup.catalogue.requests.count == sent)
        #expect(h.model.alert == nil)
        #expect(strays(h).isEmpty)
    }

    /// Showing the hidden rows, or putting them away, lets go of rows that are no longer
    /// shown and of nothing else: a book with unsaved edits that the series no longer
    /// shows stays selected, with its edits.
    @Test func showingHiddenRowsKeepsABookWithUnsavedEdits() async throws {
        let h = try await checked()
        try await selectMissing(h, "Lantern Reef")
        await h.model.setSelectedMissingHidden(true)
        let salt = try await h.edit("Salt Road", newTitle: "Salt Roads")
        // The book leaves the series while its edits wait.
        var book = try h.book(salt)
        book.series = "Somewhere Else"
        try h.store().update(book)
        await h.model.reloadAll()
        #expect(!h.model.rows.contains { $0.id == salt })
        #expect(h.model.selection == [salt])
        #expect(h.model.hasUnsavedChanges)

        h.model.showsHiddenMissing = true
        await h.model.settle()
        #expect(h.model.rows.contains { $0.isMissing && $0.book.title == "Lantern Reef" })
        #expect(h.model.selection == [salt])
        #expect(h.model.hasUnsavedChanges)
        #expect(h.draft?.title == "Salt Roads")

        h.model.showsHiddenMissing = false
        await h.model.settle()
        #expect(h.model.selection == [salt])
        #expect(h.draft?.title == "Salt Roads")
        #expect(h.model.prompt == nil)
    }

    // MARK: SV6 Nowhere else

    /// SV6: missing rows are in their own series' view and nowhere else, and count
    /// for nothing.
    @Test func missingRowsAreOnlyInTheirSeries() async throws {
        let plain = try await shown()
        let counts = plain.model.sidebar.counts
        let h = try await checked()
        #expect(h.model.rows.filter(\.isMissing).count == 2)
        #expect(h.model.sidebar.counts == counts)
        #expect(h.model.windowSubtitle == "3 books")
        #expect(h.model.emptyState == nil)

        // A search of the series finds the library's books only.
        h.model.searchText = "Glass"
        await h.model.settle()
        #expect(h.titles == ["Harbour of Glass"])
        #expect(h.model.windowSubtitle == "1 book")
        h.model.searchText = "Lantern"
        await h.model.settle()
        #expect(h.model.rows.isEmpty)
        #expect(h.model.emptyState == .noMatches)
        h.model.searchText = ""
        await h.model.settle()
        #expect(h.model.rows.filter(\.isMissing).count == 2)

        var items: [SidebarItem] = SidebarItem.fixed
        items.append(.browse(.authors, "Ines Calloway"))
        items.append(.browse(.narrators, "Marcus Lindqvist"))
        items.append(.browse(.genre, "Fantasy"))
        items += h.model.sidebar.collections.compactMap(\.id).map(SidebarItem.collection)
        for item in items {
            h.model.sidebarSelection = item
            await h.model.settle()
            #expect(h.model.rows.filter(\.isMissing).isEmpty, "\(item)")
            #expect(h.model.rows.allSatisfy { $0.id > 0 }, "\(item)")
        }
        h.model.sidebarSelection = .allBooks
        h.model.searchText = "Lantern Reef"
        await h.model.settle()
        #expect(h.model.rows.isEmpty)
    }

    // MARK: SV7 Book commands

    /// One value that says whether a book command applies.
    private struct Can: Sendable {
        var name: String
        var value: @MainActor @Sendable (AppModel, Set<Int64>) -> Bool
    }

    /// Every value the model has that says whether a command on the selected books, or
    /// on the books a context menu is for, applies. A command that is added goes here.
    private static let commandValues: [Can] = [
        Can(name: "canSave") { model, _ in model.canSave },
        Can(name: "canLookUp") { model, _ in model.canLookUp },
        Can(name: "canCheckEdition") { model, _ in model.canCheckEdition },
        Can(name: "canCheckEdition(for:)") { model, ids in model.canCheckEdition(for: ids) },
        Can(name: "canMarkOnAudible") { model, _ in model.canMarkOnAudible },
        Can(name: "canMarkOnAudible(for:)") { model, ids in model.canMarkOnAudible(for: ids) },
        Can(name: "canRemoveCover") { model, _ in model.canRemoveCover },
        Can(name: "showsEditionKind") { model, _ in model.showsEditionKind },
        Can(name: "inspectorIsOnAudible") { model, _ in model.inspectorIsOnAudible },
        Can(name: "hasUnsavedChanges") { model, _ in model.hasUnsavedChanges },
        Can(name: "selectionCommands.open") { model, _ in model.selectionCommands.open },
        Can(name: "selectionCommands.listen") { model, _ in model.selectionCommands.listen },
        Can(name: "selectionCommands.read") { model, _ in model.selectionCommands.read },
        Can(name: "selectionCommands.reveal") { model, _ in model.selectionCommands.reveal },
        Can(name: "selectionCommands.mark") { model, _ in model.selectionCommands.mark },
        Can(name: "selectionCommands.addToCollection") { model, _ in model.selectionCommands.addToCollection },
        Can(name: "selectionCommands.removeFromCollection") { model, _ in model.selectionCommands.removeFromCollection },
        Can(name: "selectionCommands.rewriteTags") { model, _ in model.selectionCommands.rewriteTags },
        Can(name: "selectionCommands.repairLengthHeaders") { model, _ in model.selectionCommands.repairLengthHeaders },
        Can(name: "selectionCommands.remove") { model, _ in model.selectionCommands.remove },
        Can(name: "commands(for:).open") { model, ids in model.commands(for: ids).open },
        Can(name: "commands(for:).listen") { model, ids in model.commands(for: ids).listen },
        Can(name: "commands(for:).read") { model, ids in model.commands(for: ids).read },
        Can(name: "commands(for:).reveal") { model, ids in model.commands(for: ids).reveal },
        Can(name: "commands(for:).mark") { model, ids in model.commands(for: ids).mark },
        Can(name: "commands(for:).addToCollection") { model, ids in model.commands(for: ids).addToCollection },
        Can(name: "commands(for:).removeFromCollection") { model, ids in model.commands(for: ids).removeFromCollection },
        Can(name: "commands(for:).rewriteTags") { model, ids in model.commands(for: ids).rewriteTags },
        Can(name: "commands(for:).repairLengthHeaders") { model, ids in model.commands(for: ids).repairLengthHeaders },
        Can(name: "commands(for:).remove") { model, ids in model.commands(for: ids).remove },
    ]

    /// The selections with a missing row in them: one, two, and one beside a book.
    private func selectionsWithMissing(_ h: Harness) throws -> [Set<Int64>] {
        let glass = try missingRow(h, "The Glass Tide").id
        let lantern = try missingRow(h, "Lantern Reef").id
        return [[glass], [glass, lantern], [glass, try h.id("Salt Road")], [lantern, try h.id("Salt Road"), try h.id("The Drowned Bell")]]
    }

    /// SV7: with a missing row in the selection, or among the books a context menu is
    /// for, no book command applies.
    @Test func noBookCommandAppliesToASelectionWithAMissingRow() async throws {
        let h = try await checked()
        // A collection to be put in, so that nothing is off merely for want of one.
        #expect(!h.model.sidebar.collections.isEmpty)
        for ids in try selectionsWithMissing(h) {
            h.model.select(ids)
            await h.model.settle()
            #expect(h.model.selection == ids)
            for can in Self.commandValues {
                #expect(!can.value(h.model, ids), "\(can.name) for \(ids.sorted())")
            }
            // A context menu on a missing row that is not selected is for that row.
            h.model.select([])
            await h.model.settle()
            for can in Self.commandValues where can.name.contains("for:") {
                #expect(!can.value(h.model, ids), "\(can.name) for \(ids.sorted()), not selected")
            }
            #expect(h.model.listenTitle(for: ids) == "Listen")
            #expect(h.model.markOnAudibleTitle(for: ids) == "Mark as on Audible")
        }
        #expect(strays(h).isEmpty)
    }

    /// SV7: the table is not empty words: for a book of the library the commands apply.
    @Test func theCommandsApplyToABookOfTheSeries() async throws {
        let h = try await checked()
        let ids: Set<Int64> = [try await h.select("Salt Road")]
        let off: Set<String> = [
            "canSave", "hasUnsavedChanges", "inspectorIsOnAudible", "selectionCommands.read", "commands(for:).read",
            "selectionCommands.removeFromCollection", "commands(for:).removeFromCollection",
            "selectionCommands.repairLengthHeaders", "commands(for:).repairLengthHeaders",
        ]
        for can in Self.commandValues {
            #expect(can.value(h.model, ids) == !off.contains(can.name), "\(can.name)")
        }
    }

    /// SV7: with a missing row among them, the actions do nothing at all: no operation
    /// begins, nothing is opened, asked or changed, and the library is asked nothing
    /// about an id that is no book's.
    @Test func noBookActionDoesAnythingWithAMissingRow() async throws {
        let h = try await checked()
        let salt = try h.id("Salt Road")
        let before = try h.book(salt)
        let store = try h.store()
        let collection = try #require(
            try h.model.sidebar.collections.compactMap(\.id).first { try !store.books(inCollection: $0).isEmpty })
        let collections = h.model.sidebar.collections
        let inCollection = try h.store().books(inCollection: collection).compactMap(\.id)
        let sent = h.lookup.catalogue.requests.count
        h.recordBusyLabels()

        for ids in try selectionsWithMissing(h) {
            h.model.select(ids)
            await h.model.settle()
            let missing = try #require(ids.first { $0 < 0 })

            h.model.openSelection()
            h.model.listenSelection()
            h.model.readSelection()
            h.model.openOne(of: [missing])
            h.model.listenOne(of: [missing])
            h.model.readOne(of: [missing])
            h.model.open(missing)
            h.model.listen(missing)
            h.model.read(missing)
            h.model.reveal(ids)
            await h.model.settle()

            await h.model.save()
            h.model.updateDraft { $0.title = "Changed" }
            h.model.updateBulkDraft { $0.setText("Changed", for: .genre) }
            h.model.discardChanges()
            h.model.removeCover()
            h.model.setCover(data: MediaFixtures.makeImage(.jpeg))
            h.model.setEditionKind(.abridged)
            h.model.beginLookup()
            #expect(h.model.lookup == nil)
            await h.model.checkEdition()
            await h.model.checkEdition(for: ids)
            await h.model.rewriteTags()
            await h.model.rewriteTags(for: ids)
            await h.model.repairLengthHeaders()
            await h.model.repairLengthHeaders(for: ids)
            await h.model.setReadStatus(.finished, for: ids)
            await h.model.setOnAudible(true, for: ids)
            await h.model.toggleOnAudible()
            await h.model.toggleOnAudible(for: ids)
            await h.model.add(ids, toCollection: collection)
            await h.model.remove(ids, fromCollection: collection)
            await h.model.createCollection(name: "Wanted", adding: ids)

            h.model.requestRemoveSelection()
            #expect(h.model.prompt == nil)
            h.model.requestRemove(ids)
            #expect(h.model.prompt == nil)
            // Even a question that should never have been asked is not acted on.
            h.model.prompt = .removeBooks(ids: ids.sorted(), titles: ids.map { _ in "A book" })
            await h.model.confirmRemove(moveFilesToTrash: false)
            h.model.prompt = nil

            await h.model.settle()
            #expect(h.model.selection == ids)
            #expect(h.model.alert == nil, "\(ids.sorted())")
            #expect(h.model.result == nil)
            #expect(!h.model.hasUnsavedChanges)
        }

        // The collection that is shown, too.
        h.model.sidebarSelection = .collection(collection)
        await h.model.settle()
        await h.model.removeFromShownCollection([-1, inCollection[0]])

        #expect(h.busyLabels == [])
        #expect(h.opener.opened.isEmpty)
        #expect(h.opener.openedWeb.isEmpty)
        #expect(h.opener.revealed.isEmpty)
        #expect(try h.book(salt) == before)
        #expect(h.model.sidebar.collections == collections)
        #expect(try h.store().books(inCollection: collection).compactMap(\.id) == inCollection)
        #expect(try h.store().books().count == 12)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
        #expect(h.lookup.catalogue.requests.count == sent)
        #expect(h.lookup.asked.isEmpty)
        #expect(strays(h).isEmpty)
    }

    /// SV7: Select All in a series selects the library's books only.
    @Test func selectAllSelectsTheLibrarysBooksOnly() async throws {
        let h = try await checked()
        h.model.selectAll()
        await h.model.settle()
        #expect(h.model.selection == (try h.ids(["Salt Road", "The Drowned Bell", "Harbour of Glass"])))
        #expect(h.bulkDraft?.books.count == 3)
        #expect(h.model.selectionCommands.mark)
    }

    /// SV7: Select All in the list is the table's own, and comes to the model as every
    /// row that is shown: it selects the library's books only, as in the grid.
    @Test func everyRowAtOnceIsTheLibrarysBooksOnly() async throws {
        let h = try await checked()
        #expect(h.model.rows.count == 5)
        h.model.select(Set(h.model.rows.map(\.id)))
        await h.model.settle()
        #expect(h.model.selection == (try h.ids(["Salt Road", "The Drowned Bell", "Harbour of Glass"])))
        #expect(h.bulkDraft?.books.count == 3)
        #expect(h.model.selectionCommands.mark)

        // Anything less is what was asked for.
        let glass = try missingRow(h, "The Glass Tide").id
        let lantern = try missingRow(h, "Lantern Reef").id
        h.model.select([glass, lantern])
        await h.model.settle()
        #expect(h.model.selection == [glass, lantern])
        let most = Set(h.model.rows.map(\.id)).subtracting([lantern])
        h.model.select(most)
        await h.model.settle()
        #expect(h.model.selection == most)

        // A series with nothing missing, and any other list of books: all of them.
        h.model.sidebarSelection = .allBooks
        await h.model.settle()
        h.model.select(Set(h.model.rows.map(\.id)))
        await h.model.settle()
        #expect(h.model.selection.count == 12)
    }

    /// SV7: a length header is not repaired either, for a selection with a missing row
    /// beside a book whose files could be repaired.
    @Test func noLengthHeaderIsRepairedWithAMissingRow() async throws {
        let (h, id) = try AppModelLengthTests().library()
        var book = try h.book(id)
        book.series = seriesName
        book.seriesNumber = "1"
        try h.store().update(book)
        h.model.audibleStore = .us
        h.model.otherAudibleStores = []
        h.lookup.catalogue.set([
            FakeCatalogue.Series(
                id: "B0TIDEWATR", title: seriesName,
                members: [
                    Member(asin: "B0LONGBOOK", title: "Long Book", number: "1"),
                    Member(asin: "B0GLASSTID", title: "The Glass Tide", number: "2"),
                    Member(asin: "B0LANTERNR", title: "Lantern Reef", number: "3"),
                ]),
        ])
        await h.model.start()
        h.model.sidebarSelection = seriesItem
        await h.model.settle()
        await h.model.checkSeries()
        let missing = try missingRow(h, "The Glass Tide").id
        // The book's files can be repaired, when it is the book alone.
        #expect(h.model.commands(for: [id]).repairLengthHeaders)
        let files = try h.fileURLs(id)
        let before = try files.map { try Data(contentsOf: $0) }
        h.recordBusyLabels()

        h.model.select([missing, id])
        await h.model.settle()
        #expect(h.model.selection == [missing, id])
        #expect(!h.model.selectionCommands.repairLengthHeaders)
        await h.model.repairLengthHeaders()
        await h.model.repairLengthHeaders(for: [missing, id])

        #expect(h.busyLabels == [])
        #expect(try files.map { try Data(contentsOf: $0) } == before)
        #expect(h.model.result == nil)
        #expect(h.model.alert == nil)
        #expect(strays(h).isEmpty)
    }

    // MARK: SV8 One missing row

    /// SV8: one missing row selected is what is inspected; several are nothing.
    @Test func oneMissingRowIsInspected() async throws {
        let h = try await checked()
        // At once, before anything has been fetched: never, even for a moment, as a
        // book of the library with fields to edit.
        let first = try missingRow(h, "The Glass Tide")
        h.model.click(first.id, modifiers: [])
        #expect(h.model.inspecting == .missing(try #require(first.missing)))
        h.model.select([])
        await h.model.settle()

        let glass = try await selectMissing(h, "The Glass Tide")
        #expect(h.model.selection == [glass.id])
        #expect(h.model.inspecting == .missing(try #require(glass.missing)))
        let info = try #require(h.model.missingBook)
        #expect(info.title == "The Glass Tide")
        #expect(info.seriesText == "Tidewater Chronicles #4")
        #expect(info.storeText == "Audible US")
        #expect(info.lengthText == "10h 15m")
        #expect(info.canChange)
        h.model.busyLabel = "Working…"
        #expect(h.model.missingBook?.canChange == false)
        h.model.busyLabel = nil

        let lantern = try missingRow(h, "Lantern Reef")
        h.model.click(lantern.id, modifiers: .command)
        await h.model.settle()
        #expect(h.model.selection == [glass.id, lantern.id])
        #expect(h.model.inspecting == .nothing)
        #expect(h.model.missingBook == nil)

        // A missing row beside a book: nothing of either to edit.
        h.model.select([glass.id, try h.id("Salt Road")])
        await h.model.settle()
        #expect(h.model.inspecting == .nothing)

        // And back to a book.
        try await h.select("Salt Road")
        #expect(h.detail?.row.book.title == "Salt Road")
        #expect(h.detail?.files.count == 1)
        #expect(strays(h).isEmpty)
    }

    /// SV8, SV9: the missing book is added as a book that is on Audible and has no
    /// files, under the owner's series name with Audible's number, and is selected.
    /// It is then owned: the count rises by one, with nothing asked of Audible.
    @Test func aMissingBookIsAddedAsAnAudibleBook() async throws {
        let h = try await checked([tidewater(title: "The Tidewater Chronicles (Audible)")])
        #expect(h.model.seriesHeader?.summary == "3 of 5 on Audible's list")
        try await selectMissing(h, "The Glass Tide")
        let sent = h.lookup.catalogue.requests.count
        h.recordBusyLabels()

        await h.model.addMissingAsAudibleBook()

        let id = try h.id("The Glass Tide")
        let book = try h.book(id)
        #expect(book.authors == ["Ines Calloway"])
        #expect(book.narrators == ["Marcus Lindqvist"])
        #expect(book.series == seriesName)
        #expect(book.seriesNumber == "4")
        #expect(book.asin == "B0GLASSTID")
        #expect(book.durationSeconds == 36_900)
        #expect(book.externalCopies == [ExternalCopy(kind: .audible, form: .audio, store: "us", itemId: "B0GLASSTID")])
        #expect(try h.fileURLs(id).isEmpty)

        #expect(h.busyLabels == ["Adding book…"])
        #expect(h.model.busyLabel == nil)
        #expect(h.model.alert == nil)
        #expect(h.model.sidebarSelection == seriesItem)
        #expect(h.model.selection == [id])
        #expect(h.detail?.row.id == id)
        #expect(h.titles == ["Salt Road", "The Drowned Bell", "Harbour of Glass", "The Glass Tide", "Lantern Reef"])
        #expect(h.model.rows.filter(\.isMissing).map(\.book.title) == ["Lantern Reef"])
        #expect(h.model.seriesHeader?.summary == "4 of 5 on Audible's list")
        #expect(h.lookup.catalogue.requests.count == sent)
        #expect(h.lookup.asked.isEmpty)
        #expect(strays(h).isEmpty)
    }

    /// SV8: a missing book that the library has already, filed under another series, is
    /// marked as on Audible as Add Audible Book marks one. Its own series name and
    /// number are left exactly as they are, and no second book is made of it.
    @Test func addingAMissingBookTheLibraryHasElsewhereLeavesItsSeriesAlone() async throws {
        let h = try await checked(prepare: { h in
            var metadata = BookMetadata(title: "The Glass Tide", authors: ["Ines Calloway"])
            metadata.series = "Deep Water"
            metadata.seriesNumber = "9"
            _ = try h.store().insert(Book(metadata: metadata), files: [])
        })
        let id = try h.id("The Glass Tide")
        try await selectMissing(h, "The Glass Tide")

        await h.model.addMissingAsAudibleBook()

        #expect(h.model.alert == "“The Glass Tide” was already in your library. It is now marked as also on Audible.")
        let book = try h.book(id)
        #expect(book.series == "Deep Water")
        #expect(book.seriesNumber == "9")
        #expect(book.isOwned(on: .audible))
        #expect(try h.store().books().count == 13)
        #expect(h.model.selection == [id])
        #expect(h.model.busyLabel == nil)

        // It now holds the entry's Audible ID, so the entry is one the library has. The
        // book is still no book of the series: it has no row there.
        h.model.sidebarSelection = seriesItem
        await h.model.settle()
        #expect(h.model.seriesHeader?.summary == "4 of 5 on Audible's list")
        #expect(h.titles == ["Salt Road", "The Drowned Bell", "Harbour of Glass", "Lantern Reef"])
        #expect(strays(h).isEmpty)
    }

    /// SV8: the store's page for the missing book is opened in the browser.
    @Test func aMissingBookIsShownOnAudible() async throws {
        let h = try await checked()
        try await selectMissing(h, "The Glass Tide")
        h.model.showMissingOnAudible()
        #expect(h.opener.openedWeb == [try #require(URL(string: "https://www.audible.com/pd/B0GLASSTID"))])
        #expect(h.opener.opened.isEmpty)
    }

    /// SV8: the three actions are for exactly one missing row.
    @Test func theMissingActionsNeedOneMissingRow() async throws {
        let h = try await checked()
        let glass = try missingRow(h, "The Glass Tide").id
        let lantern = try missingRow(h, "Lantern Reef").id
        h.recordBusyLabels()
        for ids in [[], [glass, lantern], [try h.id("Salt Road")], [glass, try h.id("Salt Road")]] as [Set<Int64>] {
            h.model.select(ids)
            await h.model.settle()
            await h.model.addMissingAsAudibleBook()
            h.model.showMissingOnAudible()
            await h.model.setSelectedMissingHidden(true)
        }
        #expect(h.busyLabels == [])
        #expect(h.opener.openedWeb.isEmpty)
        #expect(try h.store().books().count == 12)
        #expect(h.model.seriesHeader?.summary == "3 of 5 on Audible's list")
        #expect(h.model.seriesHeader?.notes == [])
    }

    /// SV8: a context menu on missing rows offers the three actions in place of the
    /// book commands, and they are for the one missing row it was opened on, selected
    /// or not.
    @Test func aContextMenuOnAMissingRowOffersItsActions() async throws {
        let h = try await checked()
        let glass = try missingRow(h, "The Glass Tide").id
        let lantern = try missingRow(h, "Lantern Reef").id
        let salt = try h.id("Salt Road")
        let off = MissingActions(canAdd: false, canShow: false, canSetHidden: false, hideTitle: "Hide", isHidden: false)

        // A book's menu is the book commands.
        #expect(h.model.missingActions(for: [salt]) == nil)
        #expect(h.model.missingActions(for: []) == nil)
        let on = MissingActions(canAdd: true, canShow: true, canSetHidden: true, hideTitle: "Hide", isHidden: false)
        // Not selected: offered all the same.
        #expect(h.model.missingActions(for: [glass]) == on)
        // An id that is no row's: nothing can be done with it.
        #expect(h.model.missingActions(for: [-999]) == off)

        try await selectMissing(h, "The Glass Tide")
        #expect(
            h.model.missingActions(for: [glass])
                == MissingActions(canAdd: true, canShow: true, canSetHidden: true, hideTitle: "Hide", isHidden: false))
        // Another row than the selected one is that row's menu; more than one is nobody's.
        #expect(h.model.missingActions(for: [lantern]) == on)
        #expect(h.model.missingActions(for: [glass, lantern]) == off)
        #expect(h.model.missingActions(for: [glass, salt]) == off)

        // While something runs, the book can still be shown on Audible.
        h.model.busyLabel = "Working…"
        #expect(
            h.model.missingActions(for: [glass])
                == MissingActions(canAdd: false, canShow: true, canSetHidden: false, hideTitle: "Hide", isHidden: false))
        h.model.busyLabel = nil

        // Hidden, and shown among the rows: Hide is Show.
        await h.model.setSelectedMissingHidden(true)
        h.model.showsHiddenMissing = true
        await h.model.settle()
        let hidden = try await selectMissing(h, "The Glass Tide").id
        #expect(
            h.model.missingActions(for: [hidden])
                == MissingActions(canAdd: true, canShow: true, canSetHidden: true, hideTitle: "Show", isHidden: true))

        h.model.select([glass, lantern])
        await h.model.settle()
        #expect(h.model.missingActions(for: [glass, lantern]) == off)
    }

    /// SV8: the context menu's actions act on the row the menu was opened on, whatever
    /// is selected: a row in the list is not selected by opening its menu.
    @Test func theContextMenusActionsActOnTheRowClicked() async throws {
        let h = try await checked()
        let glass = try missingRow(h, "The Glass Tide").id
        let lantern = try missingRow(h, "Lantern Reef").id
        let salt = try await h.select("Salt Road")
        let sent = h.lookup.catalogue.requests.count

        h.model.showMissingOnAudible(for: [lantern])
        #expect(h.opener.openedWeb == [try #require(URL(string: "https://www.audible.com/pd/B0LANTERNR"))])
        #expect(h.model.selection == [salt])

        await h.model.setMissingHidden(true, for: [lantern])
        #expect(h.model.seriesHeader?.summary == "3 of 4 on Audible's list")
        #expect(h.model.rows.filter(\.isMissing).map(\.id) == [glass])
        #expect(h.model.selection == [salt])
        // It is no row now: nothing more is done with it.
        await h.model.setMissingHidden(false, for: [lantern])
        #expect(h.model.seriesHeader?.summary == "3 of 4 on Audible's list")
        h.model.showsHiddenMissing = true
        #expect(h.model.missingActions(for: [lantern])?.hideTitle == "Show")
        await h.model.setMissingHidden(false, for: [lantern])
        #expect(h.model.seriesHeader?.summary == "3 of 5 on Audible's list")

        await h.model.addMissingAsAudibleBook(for: [glass])
        let added = try h.id("The Glass Tide")
        #expect(try h.book(added).series == seriesName)
        #expect(try h.book(added).seriesNumber == "4")
        #expect(h.model.selection == [added])
        #expect(h.model.seriesHeader?.summary == "4 of 5 on Audible's list")
        #expect(h.model.alert == nil)
        #expect(h.lookup.catalogue.requests.count == sent)
        #expect(strays(h).isEmpty)
    }

    /// SV8: the row-based actions do nothing for anything but one missing row that is
    /// shown: not for a book, several rows, or an id that is no row's.
    @Test func theContextMenusActionsNeedOneShownMissingRow() async throws {
        let h = try await checked()
        let glass = try missingRow(h, "The Glass Tide").id
        let lantern = try missingRow(h, "Lantern Reef").id
        let salt = try h.id("Salt Road")
        h.recordBusyLabels()
        for ids in [[], [glass, lantern], [salt], [glass, salt], [-999], [-glass]] as [Set<Int64>] {
            await h.model.addMissingAsAudibleBook(for: ids)
            h.model.showMissingOnAudible(for: ids)
            await h.model.setMissingHidden(true, for: ids)
        }
        // Nor while something else runs, but for showing it on Audible.
        h.model.busyLabel = "Working…"
        await h.model.addMissingAsAudibleBook(for: [glass])
        await h.model.setMissingHidden(true, for: [glass])
        h.model.busyLabel = nil
        // Nor in another list of books, where the row is not shown.
        h.model.sidebarSelection = .allBooks
        await h.model.settle()
        #expect(h.model.missingActions(for: [glass])?.canAdd == false)
        await h.model.addMissingAsAudibleBook(for: [glass])
        h.model.showMissingOnAudible(for: [glass])
        await h.model.setMissingHidden(true, for: [glass])

        #expect(h.busyLabels == [])
        #expect(h.opener.openedWeb.isEmpty)
        #expect(try h.store().books().count == 12)
        h.model.sidebarSelection = seriesItem
        await h.model.settle()
        #expect(h.model.seriesHeader?.summary == "3 of 5 on Audible's list")
        #expect(h.model.seriesHeader?.notes == [])
        #expect(strays(h).isEmpty)
    }

    // MARK: The picker as a sheet

    /// V5, SV3: the choice between series is the window's sheet while it is asked, after
    /// progress, a review, a result and the launch check, and gone when it is answered.
    @Test func theChoiceIsOneOfTheWindowsSheets() async throws {
        let published = tidewater(id: "B0PUBLISHD", title: "Tidewater (publication order)")
        let story = tidewater(id: "B0STORYORD", title: "Tidewater (chronological order)")
        let h = try await shown([published, story])
        #expect(h.model.windowSheet(progressDue: true) == nil)

        await h.model.checkSeries()
        let choices = try #require(h.model.seriesChoices)
        #expect(h.model.windowSheet(progressDue: false) == .seriesChoice(choices))
        #expect(h.model.windowSheet(progressDue: true) == .seriesChoice(choices))
        #expect(WindowSheet.seriesChoice(choices).id == WindowSheet.seriesChoice([]).id)
        #expect(Set([WindowSheet.seriesChoice([]).id, WindowSheet.progress("").id]).count == 2)

        // A result comes first, and the choice is back when it has been read.
        let result = ResultSummary(headline: "Done", problems: [], isClean: true)
        h.model.result = result
        #expect(h.model.windowSheet(progressDue: false) == .result(result))
        h.model.result = nil
        #expect(h.model.windowSheet(progressDue: false) == .seriesChoice(choices))

        // Progress comes before everything, once it is due.
        h.model.busyLabel = "Working…"
        #expect(h.model.windowSheet(progressDue: false) == .seriesChoice(choices))
        #expect(h.model.windowSheet(progressDue: true) == .progress("Working…"))
        h.model.busyLabel = nil

        h.model.cancelSeriesChoice()
        #expect(h.model.windowSheet(progressDue: true) == nil)
    }

    // MARK: SV10 Audible's numbers

    private func numberedDifferently() -> [FakeCatalogue.Series] {
        [
            tidewater { members in
                members[2].number = "4"
                members[3].number = "5"
                members[4].number = "6"
            },
        ]
    }

    /// Each book of the series says on its own row how it stands with Audible's list,
    /// and stops saying it when it no longer holds.
    @Test func theRowsSayWhichBooksDifferFromTheList() async throws {
        let h = try await shown(numberedDifferently(), prepare: { h in
            try self.addBook(h, "A Stray Tale", number: "9")
        })
        #expect(h.model.rows.allSatisfy { $0.seriesNote == nil })
        await h.model.checkSeries()
        func notes() -> [String: String] {
            Dictionary(uniqueKeysWithValues: h.model.rows.compactMap { row in row.seriesNote.map { (row.book.title, $0) } })
        }
        #expect(notes() == ["Harbour of Glass": "Audible: #4", "A Stray Tale": "Not on Audible's list"])
        #expect(h.model.seriesHeader?.notes == ["1 book is numbered differently on Audible.", "1 book is not on Audible's list."])
        // In a search of the series too, where no missing row is shown.
        h.model.searchText = "harbour"
        await h.model.settle()
        #expect(h.model.rows.map(\.seriesNote) == ["Audible: #4"])
        h.model.searchText = ""
        await h.model.settle()
        // With hidden rows shown or not.
        h.model.showsHiddenMissing = true
        #expect(notes().count == 2)
        h.model.showsHiddenMissing = false

        await h.model.useAudibleNumbers()
        #expect(notes() == ["A Stray Tale": "Not on Audible's list"])
        await h.model.unlinkSeries()
        #expect(notes().isEmpty)
        // And nowhere but in the series.
        await h.model.checkSeries()
        h.model.sidebarSelection = .allBooks
        await h.model.settle()
        #expect(h.model.rows.allSatisfy { $0.seriesNote == nil })
    }

    /// SV10: the books numbered differently are saved with Audible's numbers, as one
    /// ordinary save that Undo reverses. A check alone changes no number.
    @Test func audiblesNumbersAreUsedOnlyWhenAsked() async throws {
        let h = try await checked(numberedDifferently())
        let harbour = try h.id("Harbour of Glass")
        #expect(try h.book(harbour).seriesNumber == "3")
        var header = try #require(h.model.seriesHeader)
        #expect(header.notes == ["1 book is numbered differently on Audible."])
        #expect(header.canUseAudibleNumbers)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
        let sent = h.lookup.catalogue.requests.count
        h.recordBusyLabels()

        await h.model.useAudibleNumbers()
        #expect(h.busyLabels == ["Saving…"])
        #expect(h.model.busyLabel == nil)
        #expect(h.model.result == nil)
        #expect(h.model.alert == nil)
        #expect(try h.book(harbour).seriesNumber == "4")
        #expect(try h.book(try h.id("Salt Road")).seriesNumber == "1")
        // Written into the file, as a save writes it.
        let file = try #require(try h.fileURLs(harbour).first)
        #expect(try FileMetadataIO().read(file).metadata.seriesNumber == "4")
        #expect(h.model.undoLabel != Harness.demoUndoLabel)
        header = try #require(h.model.seriesHeader)
        #expect(header.notes == [])
        #expect(!header.canUseAudibleNumbers)
        #expect(h.titles == ["Salt Road", "The Drowned Bell", "Harbour of Glass", "The Glass Tide", "Lantern Reef"])

        // Nothing left to change: asking again does nothing.
        await h.model.useAudibleNumbers()
        #expect(h.busyLabels == ["Saving…"])

        await h.model.undo()
        #expect(try h.book(harbour).seriesNumber == "3")
        #expect(h.model.seriesHeader?.canUseAudibleNumbers == true)
        #expect(h.lookup.catalogue.requests.count == sent)
    }

    /// FL12: not while a change of folder layout that was interrupted is unresolved:
    /// the save would be refused.
    @Test func audiblesNumbersAreNotOfferedWhileALayoutChangeIsUnresolved() async throws {
        let h = try await checked(numberedDifferently())
        #expect(h.model.seriesHeader?.canUseAudibleNumbers == true)
        h.model.layoutChangeIsUnresolved = true
        let header = try #require(h.model.seriesHeader)
        #expect(!header.canUseAudibleNumbers)
        // What touches no file is still offered.
        #expect(header.canCheck)
        #expect(header.canUnlink)
        h.recordBusyLabels()
        await h.model.useAudibleNumbers()
        #expect(h.busyLabels.isEmpty)
        #expect(h.model.alert == nil)
    }

    /// SV10: not while a book of the series has unsaved edits.
    @Test func audiblesNumbersWaitForUnsavedEdits() async throws {
        let h = try await checked(numberedDifferently())
        try await h.edit("Salt Road", newTitle: "Salt Roads")
        #expect(h.model.seriesHeader?.canUseAudibleNumbers == false)
        h.recordBusyLabels()
        await h.model.useAudibleNumbers()
        #expect(h.busyLabels == [])
        #expect(try h.book(try h.id("Harbour of Glass")).seriesNumber == "3")
        #expect(h.draft?.title == "Salt Roads")

        h.model.discardChanges()
        #expect(h.model.seriesHeader?.canUseAudibleNumbers == true)
    }

    // MARK: SV12 Unlinking

    /// SV12: the link goes, the missing rows with it, and the header is as before a check.
    @Test func unlinkingForgetsTheList() async throws {
        let h = try await checked()
        try await selectMissing(h, "Lantern Reef")
        let sent = h.lookup.catalogue.requests.count
        await h.model.unlinkSeries()
        let header = try #require(h.model.seriesHeader)
        #expect(header.summary == notChecked)
        #expect(!header.isLinked)
        #expect(!header.canUnlink)
        #expect(header.canCheck)
        #expect(h.titles == ["Salt Road", "The Drowned Bell", "Harbour of Glass"])
        #expect(h.model.selection.isEmpty)
        #expect(h.model.inspecting == .nothing)
        #expect(h.model.busyLabel == nil)
        #expect(h.lookup.catalogue.requests.count == sent)
        #expect(try LibraryService(store: try h.store()).seriesCompleteness(forSeries: seriesName) == nil)
        #expect(strays(h).isEmpty)

        // With no link there is nothing to unlink.
        h.recordBusyLabels()
        await h.model.unlinkSeries()
        #expect(h.busyLabels == [])
    }

    // MARK: SV13 Keeping up

    /// SV13: whatever changes the library while the series is shown, the header and
    /// the missing rows are read again from the catalogue, and Audible is not asked.
    @Test func theSeriesKeepsUpWithTheLibrary() async throws {
        let h = try await checked()
        let sent = h.lookup.catalogue.requests.count

        // A book that was missing has come into the library some other way.
        try addBook(h, "Lantern Reef", number: "5")
        await h.model.setReadStatus(.finished, for: [try h.id("Salt Road")])
        #expect(h.model.seriesHeader?.summary == "4 of 5 on Audible's list")
        #expect(h.model.rows.filter(\.isMissing).map(\.book.title) == ["The Glass Tide"])
        #expect(h.titles == ["Salt Road", "The Drowned Bell", "Harbour of Glass", "The Glass Tide", "Lantern Reef"])

        // An import, begun as a drop on the window is.
        let inbox = try Harness.inbox()
        await h.model.beginImport([inbox])
        #expect(h.model.review != nil)
        await h.model.confirmImport()
        h.model.result = nil
        h.model.sidebarSelection = seriesItem
        await h.model.settle()
        #expect(h.model.seriesHeader?.isLinked == true)
        #expect(h.model.rows.filter(\.isMissing).map(\.book.title).contains("The Glass Tide"))
        let afterImport = h.model.seriesHeader

        // A save and an undo.
        try await h.edit("The Drowned Bell", newTitle: "The Drowned Bells")
        await h.model.save()
        #expect(h.model.seriesHeader?.isLinked == true)
        #expect(h.model.rows.contains { $0.isMissing && $0.book.title == "The Glass Tide" })
        await h.model.undo()
        #expect(h.model.seriesHeader == afterImport)
        #expect(h.model.rows.contains { $0.isMissing && $0.book.title == "The Glass Tide" })

        // A book of the series that is removed is no longer owned.
        h.model.requestRemove([try h.id("Lantern Reef")])
        await h.model.confirmRemove(moveFilesToTrash: false)
        #expect(h.model.rows.filter(\.isMissing).map(\.book.title).contains("Lantern Reef"))
        #expect(h.lookup.catalogue.requests.count == sent)
        #expect(strays(h).isEmpty)
    }

    /// A check made again gives the entries new ids: a missing row that was selected
    /// is let go, so that nothing stays selected under an id that may now be another's.
    @Test func checkingAgainLetsGoOfSelectedMissingRows() async throws {
        let h = try await checked()
        let salt = try h.id("Salt Road")
        h.model.select([try missingRow(h, "The Glass Tide").id, salt])
        await h.model.settle()
        await h.model.checkSeries()
        #expect(h.model.selection == [salt])
        #expect(h.detail?.row.id == salt)
        #expect(h.model.rows.filter(\.isMissing).count == 2)
    }

    // MARK: SV14 Nothing to show

    /// SV14: a missing row is a book with nothing to show, and the library is never
    /// asked about its id: not by the inspector, the markers, the keyboard or a menu.
    @Test func aMissingRowHasNothingToShow() async throws {
        let h = try await checked()
        let glass = try missingRow(h, "The Glass Tide")
        let harbour = try h.id("Harbour of Glass")

        // The keyboard: from the last book of the library on to the first missing row.
        try await h.select("Harbour of Glass")
        #expect(h.model.moveSelection(.right, columns: 3) == glass.id)
        await h.model.settle()
        #expect(h.model.selection == [glass.id])
        #expect(h.model.scrollTarget == glass.id)
        #expect(h.model.moveSelection(.left, columns: 3) == harbour)
        await h.model.settle()
        #expect(h.detail?.row.id == harbour)

        // A context menu opened on a missing row that is not selected.
        #expect(h.model.contextTarget(for: glass.id) == [glass.id])
        h.model.contextClick(glass.id)
        await h.model.settle()
        #expect(h.model.selection == [glass.id])
        #expect(h.model.contextTarget(for: glass.id) == [glass.id])
        #expect(h.model.commands(for: h.model.contextTarget(for: glass.id)) == SelectionCommands())

        #expect(h.model.editedBookIds.isEmpty)
        #expect(h.model.inspectorEditedText == nil)
        #expect(h.model.appOnlyMarkers.isEmpty)
        #expect(h.model.draftCover == .none)
        #expect(h.model.inspectorOwnershipText == nil)
        #expect(h.model.inspectorEditionKind == nil)
        #expect(h.model.inspectorEditionLabel == nil)
        #expect(h.model.inspectorEditionHelp == nil)
        #expect(!h.model.editionKindIsAppOnly)
        #expect(h.model.inspectorLookup == nil)

        // A shift-click from a book across missing rows selects them all, and nothing is asked.
        h.model.click(harbour, modifiers: [])
        h.model.click(try missingRow(h, "Lantern Reef").id, modifiers: .shift)
        await h.model.settle()
        #expect(h.model.selection.count == 3)
        #expect(h.model.inspecting == .nothing)

        // Everything read again, with missing rows selected.
        await h.model.reloadAll()
        #expect(h.model.selection.count == 3)
        #expect(h.model.inspecting == .nothing)
        h.model.select([glass.id])
        await h.model.settle()
        await h.model.reloadAll()
        #expect(h.model.inspecting == .missing(try #require(glass.missing)))

        // Leaving the series lets go of the missing row.
        h.model.sidebarSelection = .allBooks
        await h.model.settle()
        #expect(h.model.selection.isEmpty)
        #expect(h.model.inspecting == .nothing)
        #expect(h.model.alert == nil)
        #expect(strays(h).isEmpty)
    }

    /// SV14: asked about an id that is no book's, the library's worker passes it over
    /// and notes it, whatever asked.
    @Test func theWorkerPassesOverIdsThatAreNoBooks() async throws {
        let h = try await Harness.demo()
        let worker = try #require(h.model.worker)
        let salt = try h.id("Salt Road")
        #expect(try await worker.detail(bookId: -3) == nil)
        try await worker.setReadStatus(.finished, for: [-4, salt])
        #expect(try h.book(salt).readStatus == .finished)
        #expect(try await worker.rewriteTags(for: [-5]).isEmpty)
        #expect(try await worker.repairLengthHeaders(for: [-6]).isEmpty)
        #expect(try await worker.setOnAudible(true, for: [-7], store: .us).isEmpty)
        #expect(await worker.removeBooks(ids: [-8], moveFilesToTrash: false).isEmpty)
        let collection = try #require(h.model.sidebar.collections.first?.id)
        try await worker.add(bookIds: [-9], toCollection: collection)
        try await worker.remove(bookIds: [-10], fromCollection: collection)
        #expect(try await worker.checkEditions([EditionCheck(bookId: -11, results: [])]).isEmpty)
        var edit = BookEdit(book: try h.book(salt))
        edit.bookId = -12
        #expect(try await worker.save([edit]).isEmpty)
        #expect(strays(h) == [-3, -4, -5, -6, -7, -8, -9, -10, -11, -12])
        #expect(try h.store().books().count == 12)
    }
}
