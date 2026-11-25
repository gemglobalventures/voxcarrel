import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// KI1 onwards: bringing in the Kindle library of the linked account, as the app's
/// model and its sheet decide it. Nothing here reaches Amazon, the Keychain or the
/// home folder.
@MainActor
@Suite struct KindleImportTests {
    // MARK: Reading and the review

    @Test func KI1_theImportSheetReadsTheLibraryAndSaysWhatBringingItInWouldDo() async throws {
        let h = try await Harness.demo()
        try h.link(AudibleSamples.account(.uk))
        // Marked already.
        var rivers = KindleOwnedBook(asin: "B0RIVERS", title: "Quiet Rivers")
        rivers.authors = ["Amara Okafor"]
        _ = try LibraryService(store: try h.store()).bringInKindleLibrary([rivers], apply: true)
        await h.model.reloadAll()
        h.audible.holdsOnKindle([
            KindleSamples.item("B0NEW1", "A New Book"),
            KindleSamples.item("B0NEW2", "Another New Book"),
            KindleSamples.item("B0NEW3", "Caliban's War (The Expanse Book 2)", author: "Corey, James S. A.:"),
            KindleSamples.item("B0LIGHT", "The Lighthouse Keeper", author: "Marsh, Eleanor:"),
            KindleSamples.item("B0RIVERS", "Quiet Rivers", author: "Okafor, Amara:"),
        ])
        let before = try h.store().books().count
        #expect(h.model.canImportKindleLibrary)

        // While Amazon is asked, the sheet says so, and the library is not kept waiting.
        let gate = Gate()
        h.audible.gate = gate
        h.model.beginKindleImport()
        let session = try #require(h.model.kindleImport)
        #expect(h.model.windowSheet(progressDue: false) == .kindleImport(SheetObject(session)))
        await gate.arrival()
        #expect(session.title == "Import Kindle Library")
        #expect(session.source == "Read from Amazon's Kindle web reader, using your Audible link. "
            + "Nothing is changed at Amazon.")
        #expect(session.phase == .reading)
        #expect(session.readingText == "Reading your Kindle library…")
        #expect(!session.canImport && session.closeTitle == "Cancel")
        #expect(h.model.busyLabel == nil)
        h.audible.gate = nil
        await gate.release()
        await session.reading?.value

        #expect(session.phase == .review)
        #expect(session.problem == nil)
        #expect(session.summary == "5 books in your Kindle library.")
        #expect(session.lines == [
            "3 will be added as books you own on Kindle.",
            "1 book you already have will be marked as owned on Kindle.",
            "1 is already here.",
        ])
        #expect(session.titlesToAdd == ["A New Book", "Another New Book", "Caliban's War"])
        #expect(session.titlesToMark == ["The Lighthouse Keeper"])
        #expect(session.addTitle == "To be added" && session.markTitle == "To be marked as owned on Kindle")
        #expect(session.note == "No file is added or changed. Books that are added have no files.")
        #expect(session.canImport && session.closeTitle == "Cancel")
        #expect(session.importTitle == "Import")
        // A session was asked of the account's own store, and the list of its web reader.
        #expect(h.audible.asked.first?.url?.absoluteString == "https://www.amazon.co.uk/ap/exchangetoken/cookies")
        #expect(h.audible.asked.dropFirst().allSatisfy { $0.url?.host == "read.amazon.co.uk" })
        // Nothing has changed, and no cover was asked for.
        #expect(try h.store().books().count == before)
        #expect(h.covers.asked.isEmpty)

        session.cancel()
        #expect(h.model.kindleImport == nil)
        #expect(try h.store().books().count == before)
        #expect(h.covers.asked.isEmpty)
    }

    @Test func KI2_oneOfEachIsSaidAsOne() {
        var report = KindleLibraryReport()
        report.added = ["One"]
        report.marked = ["Two"]
        report.alreadyThere = 1
        #expect(KindleImportText.summary(total: 1, report: report) == "1 book in your Kindle library.")
        #expect(KindleImportText.lines(for: report) == [
            "1 will be added as a book you own on Kindle.",
            "1 book you already have will be marked as owned on Kindle.",
            "1 is already here.",
        ])
        #expect(KindleImportText.outcome(of: report) == "Added 1 book and marked 1 as owned on Kindle.")

        report.added = (1...597).map { "Book \($0)" }
        report.marked = (1...20).map { "Had \($0)" }
        report.alreadyThere = 76
        #expect(KindleImportText.summary(total: 693, report: report) == "693 books in your Kindle library.")
        #expect(KindleImportText.lines(for: report) == [
            "597 will be added as books you own on Kindle.",
            "20 books you already have will be marked as owned on Kindle.",
            "76 are already here.",
        ])
        #expect(KindleImportText.outcome(of: report) == "Added 597 books and marked 20 as owned on Kindle.")
        report.marked = []
        #expect(KindleImportText.lines(for: report) == [
            "597 will be added as books you own on Kindle.", "76 are already here.",
        ])
        #expect(KindleImportText.outcome(of: report) == "Added 597 books.")
        report.added = []
        report.marked = ["Two", "Three"]
        #expect(KindleImportText.outcome(of: report) == "Marked 2 books as owned on Kindle.")
        report.marked = ["Two"]
        #expect(KindleImportText.outcome(of: report) == "Marked 1 book as owned on Kindle.")
        report.marked = []
        #expect(KindleImportText.outcome(of: report) == "Everything is already in your library.")
        #expect(KindleImportText.summary(total: 76, report: report)
            == "76 books in your Kindle library. Everything is already in your library.")
        #expect(KindleImportText.summary(total: 0, report: KindleLibraryReport()) == "Your Kindle library has no books.")
    }

    @Test func KI2_aLongListOfTitlesIsCutShort() async throws {
        let h = try await Harness.empty()
        try h.link()
        h.audible.holdsOnKindle((1...620).map { KindleSamples.item("B\($0)", "Book \($0)", cover: nil) })
        let session = try await h.kindleImportRead()
        #expect(session.titlesToAdd.count == 500)
        #expect(session.moreToAdd == "and 120 more")
        #expect(session.titlesToMark.isEmpty && session.moreToMark == nil)
        session.cancel()
    }

    // MARK: Importing

    @Test func KI3_importingAddsTheBooksMarksTheOnesHeldAndSaysWhatItDid() async throws {
        let h = try await Harness.demo()
        try h.link()
        h.audible.holdsOnKindle([
            KindleSamples.item("B0NEW1", "A New Book", cover: nil),
            KindleSamples.item("B0NEW2", "Caliban's War (The Expanse Book 2)", author: "Corey, James S. A.:", cover: nil),
            KindleSamples.item("B0LIGHT", "The Lighthouse Keeper", author: "Marsh, Eleanor:", cover: nil),
        ])
        let before = try h.store().books().count
        let session = try await h.kindleImportRead()
        h.recordBusyLabels()
        await session.apply()

        #expect(h.busyLabels == ["Importing your Kindle library…"])
        #expect(h.model.kindleImport == nil)
        #expect(h.model.busyLabel == nil)
        #expect(h.model.alert == "Added 2 books and marked 1 as owned on Kindle.")
        #expect(h.model.result == nil)

        let books = try h.store().books()
        #expect(books.count == before + 2)
        let new = try #require(books.first { $0.title == "A New Book" })
        // A Kindle ID is not an Audible ID.
        #expect(new.asin == nil && new.folderPath == nil)
        #expect(new.externalCopies == [ExternalCopy(kind: .kindle, form: .ebook, itemId: "B0NEW1")])
        let war = try #require(books.first { $0.title == "Caliban's War" })
        #expect(war.authors == ["James S. A. Corey"] && war.series == "The Expanse" && war.seriesNumber == "2")
        let held = try h.book(try h.id("The Lighthouse Keeper"))
        #expect(held.externalCopies == [ExternalCopy(kind: .kindle, form: .ebook, itemId: "B0LIGHT")])
        #expect(try !h.fileURLs(try #require(held.id)).isEmpty)
        // The rows were read again.
        #expect(h.titles.contains("A New Book"))
        await h.model.audibleCovers?.value
    }

    @Test func KI4_whenEverythingIsThereAlreadyThereIsNothingToImport() async throws {
        let h = try await Harness.empty()
        try h.link()
        h.audible.holdsOnKindle([KindleSamples.item("B0ONE", "One Book"), KindleSamples.item("B0TWO", "Two Book")])
        let first = try await h.kindleImportRead()
        await first.apply()
        await h.model.audibleCovers?.value
        h.model.alert = nil

        let session = try await h.kindleImportRead()
        #expect(session.phase == .review)
        #expect(session.summary == "2 books in your Kindle library. Everything is already in your library.")
        #expect(session.lines == ["2 are already here."])
        #expect(session.titlesToAdd.isEmpty && session.titlesToMark.isEmpty)
        #expect(!session.canImport && session.closeTitle == "Close")
        await session.apply()
        #expect(h.model.kindleImport === session)
        #expect(h.model.alert == nil)

        // An account with no Kindle books.
        session.cancel()
        h.audible.holdsOnKindle([])
        let none = try await h.kindleImportRead()
        #expect(none.summary == "Your Kindle library has no books.")
        #expect(none.lines.isEmpty && !none.canImport && none.closeTitle == "Close")
    }

    // MARK: Failures

    @Test func KI5_whyTheLibraryCouldNotBeReadIsSaidInTheSheet() async throws {
        let h = try await Harness.empty()
        try h.link()

        // Amazon gives no session for the link.
        h.audible.answer("/ap/exchangetoken/cookies", with: [:] as [String: Any], status: 401)
        let refused = try await h.kindleImportRead()
        #expect(refused.problem == "Amazon no longer accepts this link. Unlink the Audible account in Settings "
            + "and link it again.")
        #expect(refused.phase == .failed && refused.closeTitle == "Close")
        #expect(!refused.canImport && refused.summary == nil && refused.lines.isEmpty)
        refused.cancel()
        #expect(h.model.kindleImport == nil)

        // The web reader sends the session to its sign-in page.
        h.audible.holdsOnKindle([])
        h.audible.answer("/kindle-library/search", with: [:] as [String: Any], status: 302)
        let turnedAway = try await h.kindleImportRead()
        #expect(turnedAway.problem == refused.problem && turnedAway.phase == .failed)
        turnedAway.cancel()

        h.audible.fails = true
        let offline = try await h.kindleImportRead()
        #expect(offline.problem == "Amazon could not be reached. Check your internet connection.")
        #expect(offline.phase == .failed)
        offline.cancel()

        h.audible.fails = false
        h.audible.answer("/kindle-library/search", with: ["nothing": "useful"])
        let unreadable = try await h.kindleImportRead()
        #expect(unreadable.problem == "Your Kindle library could not be read.")
        #expect(unreadable.phase == .failed)
        unreadable.cancel()

        #expect(UserMessage.kindleLibraryProblem(AudibleAccountError.unusableKey) == "Your Kindle library could not be read.")
        #expect(try h.store().books().isEmpty)
        #expect(h.covers.asked.isEmpty)
    }

    // MARK: When it can be done

    @Test func KI6_theLibraryCanBeImportedOnlyWhenLinkedWithALibraryOpenAndNothingElseUp() async throws {
        let h = try await Harness.demo()
        #expect(h.model.kindleMenuTitle == "Import Kindle Library…")
        // Not linked: it is not offered.
        #expect(!h.model.canImportKindleLibrary)
        h.model.beginKindleImport()
        #expect(h.model.kindleImport == nil)
        #expect(h.audible.asked.isEmpty)

        try h.link()
        h.audible.holdsOnKindle([KindleSamples.item("B0ONE", "One Book")])
        #expect(h.model.canImportKindleLibrary)

        // Another sheet is up.
        h.model.beginNewShelf()
        #expect(!h.model.canImportKindleLibrary)
        h.model.beginKindleImport()
        #expect(h.model.kindleImport == nil)
        h.model.closeShelfEditor()

        // A question is waiting.
        h.model.unlinkAudible()
        #expect(!h.model.canImportKindleLibrary)
        h.model.prompt = nil

        // One sheet at a time, and the account is not unlinked under it.
        let session = try await h.kindleImportRead()
        #expect(!h.model.canImportKindleLibrary && !h.model.canImportAudibleLibrary && !h.model.canUseAudibleMenu)
        #expect(!h.model.canBeginShelf && !h.model.canUnlinkAudible && !h.model.canImportHighlights)
        #expect(!h.model.canManageGenres && !h.model.canFillInGenres)
        h.model.beginKindleImport()
        #expect(h.model.kindleImport === session)
        h.model.beginAudibleImport()
        #expect(h.model.audibleImport == nil)
        session.cancel()
        #expect(h.model.canImportKindleLibrary && h.model.canImportAudibleLibrary)
    }

    @Test func KI6_withNoLibraryOpenNothingIsImported() async throws {
        let h = try Harness(root: try makeTempDir(), choose: false)
        await h.model.start()
        try h.link()
        #expect(!h.model.isLibraryOpen && !h.model.canImportKindleLibrary)
        h.model.beginKindleImport()
        #expect(h.model.kindleImport == nil)
    }

    @Test func KI6_theImportSheetGoesWhenAnotherLibraryIsOpened() async throws {
        let h = try await Harness.empty()
        try h.link()
        h.audible.holdsOnKindle([KindleSamples.item("B0ONE", "One Book")])
        _ = try await h.kindleImportRead()
        await h.model.chooseLibrary(try makeTempDir())
        #expect(h.model.kindleImport == nil)
        #expect(h.model.isAudibleLinked)
    }

    // MARK: Covers

    @Test func KI7_coversComeOnlyFromAmazonsImageHostsAndOnlyForBooksWithoutOne() async throws {
        let h = try await Harness.empty()
        try h.link()
        let good = "https://m.media-amazon.com/images/I/good._SY400_.jpg"
        let alsoGood = "https://images-na.ssl-images-amazon.com/images/I/also.jpg"
        let big = "https://m.media-amazon.com/images/I/big.jpg"
        let notAPicture = "https://m.media-amazon.com/images/I/text.jpg"
        h.audible.holdsOnKindle([
            KindleSamples.item("B0GOOD", "Good Cover", cover: good),
            KindleSamples.item("B0ALSO", "Also Good", cover: alsoGood),
            KindleSamples.item("B0ELSE", "Elsewhere", cover: "https://example.com/images/I/x.jpg"),
            KindleSamples.item("B0WISE", "Not Amazon's", cover: "https://readwise.io/x.jpg"),
            KindleSamples.item("B0LOOK", "Lookalike", cover: "https://notmedia-amazon.com/x.jpg"),
            KindleSamples.item("B0TAIL", "Tail", cover: "https://m.media-amazon.com.example.com/x.jpg"),
            KindleSamples.item("B0OPEN", "In the Open", cover: "http://m.media-amazon.com/images/I/open.jpg"),
            KindleSamples.item("B0BIG", "Too Big", cover: big),
            KindleSamples.item("B0TEXT", "Not a Picture", cover: notAPicture),
            KindleSamples.item("B0NONE", "No Cover", cover: nil),
        ])
        h.covers.give(AudibleSamples.jpeg + Data(count: 5_000_001), for: big)
        h.covers.give(Data("<html>".utf8), for: notAPicture)
        let session = try await h.kindleImportRead()
        // Nothing is fetched while the list is looked over.
        #expect(h.covers.asked.isEmpty)
        await session.apply()
        // The owner is not kept waiting for the covers.
        #expect(h.model.busyLabel == nil)
        await h.model.audibleCovers?.value

        #expect(Set(h.covers.asked.map(\.absoluteString)) == [good, alsoGood, big, notAPicture])
        let covers = CoverStore(layout: LibraryLayout(root: h.root))
        #expect(covers.url(for: try h.id("Good Cover")) != nil)
        #expect(covers.url(for: try h.id("Also Good")) != nil)
        for title in ["Elsewhere", "Not Amazon's", "Lookalike", "Tail", "In the Open", "Too Big", "Not a Picture", "No Cover"] {
            #expect(covers.url(for: try h.id(title)) == nil, "\(title) was given a cover")
        }
        // The rows show them.
        #expect(h.model.rows.first { $0.book.title == "Good Cover" }?.coverURL != nil)

        // A book that has a cover is not asked for again, when more books are brought in.
        let later = "https://m.media-amazon.com/images/I/later.jpg"
        h.audible.holdsOnKindle([
            KindleSamples.item("B0GOOD", "Good Cover", cover: "https://m.media-amazon.com/images/I/other.jpg"),
            KindleSamples.item("B0LATER", "A Later Book", cover: later),
        ])
        let asked = h.covers.asked.count
        let again = try await h.kindleImportRead()
        await again.apply()
        await h.model.audibleCovers?.value
        #expect(h.covers.asked.dropFirst(asked).map(\.absoluteString) == [later])
        #expect(covers.url(for: try h.id("A Later Book")) != nil)
    }

    @Test func KI7_aKindleCoverIsNotGivenToABookOwnedOnAudibleUnderTheSameID() async throws {
        let h = try await Harness.empty()
        try h.link()
        h.covers.everything = nil
        h.audible.holds([AudibleSamples.item("B0SAME", "Heard Not Read")])
        let audible = try await h.audibleImportRead()
        await audible.apply()
        await h.model.audibleCovers?.value
        h.covers.everything = AudibleSamples.jpeg

        let cover = "https://m.media-amazon.com/images/I/read.jpg"
        h.audible.holdsOnKindle([KindleSamples.item("B0SAME", "Read Not Heard", cover: cover)])
        let session = try await h.kindleImportRead()
        await session.apply()
        await h.model.audibleCovers?.value
        let covers = CoverStore(layout: LibraryLayout(root: h.root))
        #expect(covers.url(for: try h.id("Read Not Heard")) != nil)
        #expect(covers.url(for: try h.id("Heard Not Read")) == nil)
    }

    @Test func KI7_theCoversStopWhenAnotherLibraryIsOpened() async throws {
        let h = try await Harness.empty()
        try h.link()
        h.audible.holdsOnKindle([KindleSamples.item("B0ONE", "One Book"), KindleSamples.item("B0TWO", "Two Book")])
        let session = try await h.kindleImportRead()
        let gate = Gate()
        let covers = h.covers
        h.model.audibleCoverFetch = { url in
            await gate.wait()
            return await covers.fetch(url)
        }
        await session.apply()
        await gate.arrival()
        let fetching = try #require(h.model.audibleCovers)
        await h.model.chooseLibrary(try makeTempDir())
        await gate.release()
        await fetching.value
        // The one that was on its way, and no more; nothing was stored.
        #expect(h.covers.asked.count == 1)
        let store = CoverStore(layout: LibraryLayout(root: h.root))
        #expect(store.url(for: try h.id("One Book")) == nil)
        #expect(store.url(for: try h.id("Two Book")) == nil)
    }
}

enum KindleSamples {
    /// One item of a Kindle library, as Amazon's web reader answers.
    static func item(
        _ asin: String, _ title: String, author: String = "Author, Ann:",
        cover: String? = "https://m.media-amazon.com/images/I/x._SY400_.jpg"
    ) -> [String: Any] {
        var item: [String: Any] = [
            "asin": asin, "title": title, "authors": [author], "resourceType": "EBOOK", "originType": "PURCHASE",
            "webReaderUrl": "https://read.amazon.com/?asin=\(asin)",
        ]
        if let cover { item["productUrl"] = cover }
        return item
    }
}

extension FakeAudibleTransport {
    /// Amazon gives the account a web session, and its Kindle library holds these
    /// items, on one page.
    func holdsOnKindle(_ items: [[String: Any]]) {
        answer("/ap/exchangetoken/cookies", with: ["response": ["tokens": ["cookies": [
            ".amazon.com": [["Name": "at-main", "Value": "Atza|token"], ["Name": "x-main", "Value": "abc123"]],
        ]]]])
        answer("/kindle-library/search", with: ["itemsList": items, "libraryType": "BOOKS", "sortType": "recency"])
    }
}

extension Harness {
    /// Opens the Kindle import sheet and waits for it to have read the library.
    func kindleImportRead() async throws -> KindleImportSession {
        model.beginKindleImport()
        let session = try #require(model.kindleImport)
        await session.reading?.value
        return session
    }
}
