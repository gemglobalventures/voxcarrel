import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// What the lookup screens show that is decided here and not in a view (plan 5, Task 6). V2, V4, V6.
@MainActor
@Suite struct LookupDisplayTests {
    private let png = MediaFixtures.makeImage(.png)

    private func found(_ key: String = "B01", cover: Bool = true, _ change: (inout BookMetadata) -> Void = { _ in })
        -> LookupCandidate
    {
        foundBook(.audible, key, title: "Salt Road", authors: ["Ines Calloway"], cover: cover, change)
    }

    private func session(
        _ current: BookMetadata, target: LookupSession.Target = .book(7), finding candidates: [LookupCandidate] = []
    ) -> LookupSession {
        var session = LookupSession(target: target, current: current, hasCover: false, hasAudio: true)
        if !candidates.isEmpty {
            session.beginSearch()
            session.finishSearch(LookupResults(candidates: candidates, searched: [.audible]), for: session.query)
        }
        return session
    }

    /// A demo library with Salt Road selected and its lookup open and answered.
    private func lookedUp(_ candidates: [LookupCandidate]) async throws -> Harness {
        let h = try await Harness.demo()
        h.lookup.find(.audible, candidates)
        try await h.select("Salt Road")
        h.model.beginLookup()
        await h.model.settle()
        return h
    }

    // MARK: V2 The search boxes

    /// V2: Search needs something to search for, and nothing being applied.
    @Test func V2_searchNeedsAQuery() {
        var session = session(BookMetadata(title: "Salt Road"), finding: [found { $0.publisher = "Tidewater" }])
        // Answered: searching again would ask the same and lose the ticks.
        #expect(session.isAnswered)
        #expect(!session.canSearch)
        session.query.author = "Calloway"
        #expect(!session.isAnswered)
        #expect(session.canSearch)
        session.query.author = ""
        #expect(!session.canSearch)
        session.sourcesChanged()
        #expect(session.canSearch)
        session.beginApplying()
        #expect(session.phase == .applying)
        #expect(!session.canSearch)

        var empty = self.session(BookMetadata(title: "  "))
        #expect(!empty.canSearch)
        empty.query.author = "Calloway"
        #expect(empty.canSearch)
    }

    /// V2: a search that found nothing, or that a source failed to answer, can be made again.
    @Test func V2_aSearchThatFellShortCanBeRepeated() {
        var nothing = LookupSession(target: .book(7), current: BookMetadata(title: "Salt Road"), hasCover: false, hasAudio: true)
        #expect(nothing.canSearch)
        nothing.beginSearch()
        #expect(nothing.canSearch)
        nothing.finishSearch(LookupResults(searched: [.openLibrary, .audible], found: [.openLibrary: 0, .audible: 0]), for: nothing.query)
        #expect(nothing.phase == .noResults)
        #expect(nothing.canSearch)

        var partly = nothing
        partly.beginSearch()
        partly.finishSearch(
            LookupResults(
                candidates: [found()], failures: [.openLibrary: .notReachable], searched: [.openLibrary, .audible],
                found: [.audible: 1]),
            for: partly.query)
        #expect(partly.phase == .results)
        #expect(!partly.isAnswered)
        #expect(partly.canSearch)
    }

    /// V1: what the buttons say when the pointer rests on them; V7: what the settings say.
    @Test func V1_V7_theWords() async throws {
        let h = try Harness(root: try makeTempDir())
        #expect(h.model.lookUpHelp == "Look this book up online and choose which details to take")
        #expect(h.model.lookUpHelp(forEntry: UUID()) == h.model.lookUpHelp)
        #expect(h.model.lookupPrivacyText == "Look Up sends the title, author, ISBN or Audible ID you search for to Open Library and Audible, and downloads cover images from them (Open Library’s come from the Internet Archive, Audible’s from Amazon). Nothing is sent until you press Look Up.")
    }

    /// V2: the ISBN and Audible ID boxes are there for a book that has the number, and
    /// stay while the box is emptied, so that it can be typed again.
    @Test func V2_theNumberBoxesAreForABookThatHasTheNumber() {
        var book = BookMetadata(title: "Salt Road")
        #expect(!session(book).showsISBNBox)
        #expect(!session(book).showsAudibleIDBox)
        book.isbn = " 9780000000002 "
        book.asin = "B0SALTROAD"
        var session = session(book)
        #expect(session.showsISBNBox)
        #expect(session.showsAudibleIDBox)
        session.query.isbnText = ""
        session.query.asinText = ""
        #expect(session.showsISBNBox)
        #expect(session.showsAudibleIDBox)
    }

    /// Plan 6, V5: adding an Audible book starts from nothing, so the book has no number;
    /// the Audible ID box is there all the same, for an ASIN to be pasted into. No ISBN
    /// box: an Audible book is not looked for by ISBN.
    @Test func V5_addingAnAudibleBookHasAnAudibleIDBox() {
        let adding = session(BookMetadata(), target: .newAudibleBook)
        #expect(adding.showsAudibleIDBox)
        #expect(!adding.showsISBNBox)
        #expect(!session(BookMetadata(title: "Salt Road"), target: .importEntry(UUID())).showsAudibleIDBox)
    }

    /// Plan 6, V5: what the sheet says of itself when it is for adding an Audible book.
    @Test func V5_theWordsOfTheSheetWhenAdding() {
        let adding = session(BookMetadata(), target: .newAudibleBook)
        #expect(adding.headingText == "Add Audible Book")
        #expect(adding.idleText == "Search the Audible catalogue for the book you own.")
        #expect(adding.noSelectionText == "Select a match to see its details.")
        #expect(adding.reminderText == "The book is added to your library without files.")

        for target in [LookupSession.Target.book(7), .importEntry(UUID())] {
            let looking = session(BookMetadata(title: "Salt Road"), target: target)
            #expect(looking.headingText == nil)
            #expect(looking.idleText == "Press Search to look for this book.")
            #expect(looking.noSelectionText == "Select a match to see what it offers.")
        }
    }

    /// V2: an emptied number box is no number, not an empty one.
    @Test func V2_anEmptiedNumberBoxIsNoNumber() {
        var query = LookupQuery(title: "Salt Road", isbn: "9780000000002", asin: "B0SALTROAD")
        #expect(query.isbnText == "9780000000002")
        #expect(query.asinText == "B0SALTROAD")
        query.isbnText = "  "
        query.asinText = ""
        #expect(query.isbn == nil)
        #expect(query.asin == nil)
        #expect(query.isbnText == "")
        #expect(query.asinText == "")
        query.isbnText = "978"
        query.asinText = "B0"
        #expect(query.isbn == "978")
        #expect(query.asin == "B0")
    }

    // MARK: V2 Results and offers

    /// V2: a result's row.
    @Test func V2_aResultsTitleAndAuthors() {
        let both = foundBook(.audible, "1", title: " Good Omens ", authors: ["Terry Pratchett", " ", "Neil Gaiman"])
        #expect(both.titleText == "Good Omens")
        #expect(both.authorsText == "Terry Pratchett, Neil Gaiman")
        let bare = foundBook(.openLibrary, "2", title: " ")
        #expect(bare.titleText == "Untitled")
        #expect(bare.authorsText == "No author")
    }

    /// V2: what the book has now, with a dash when it has nothing.
    @Test func V2_anOffersCurrentValue() throws {
        var book = BookMetadata(title: "Salt Road", authors: ["Ines Calloway"])
        book.publisher = "Harbour Press"
        let session = session(
            book,
            finding: [
                found {
                    $0.publisher = "Tidewater Audio"
                    $0.genre = "Travel"
                }
            ])
        let publisher = try #require(session.offers.first { $0.id == .publisher })
        #expect(publisher.currentText == "Now: Harbour Press")
        let genre = try #require(session.offers.first { $0.id == .genre })
        #expect(genre.currentText == "Now: —")
    }

    // MARK: V4

    /// V4: what applying leaves to be done, which is Save for a library book and the
    /// import itself for a book being imported.
    @Test func V4_theReminder() {
        let book = BookMetadata(title: "Salt Road")
        #expect(
            session(book, target: .book(7)).reminderText
                == "Ticked values are saved into the book. Edit ▸ Undo reverses it.")
        #expect(
            session(book, target: .importEntry(UUID())).reminderText
                == "Applied values are imported with the book.")
        // N6 (plan 6): adding an Audible book saves at once, and there are no files.
        #expect(
            LookupSession(target: .newAudibleBook, current: BookMetadata(), hasCover: false, hasAudio: true)
                .reminderText == "The book is added to your library without files.")
    }

    /// V4: the button says what it does: for a book in the library it saves too.
    @Test func V4_theApplyButton() {
        let book = BookMetadata(title: "Salt Road")
        let inLibrary = session(book, target: .book(7))
        #expect(inLibrary.applyTitle == "Apply and Save")
        #expect(inLibrary.applyHelp == "Save the ticked values into the book (⌘Return)")
        let importing = session(book, target: .importEntry(UUID()))
        #expect(importing.applyTitle == "Apply")
        #expect(importing.applyHelp == "Put the ticked values into the book (⌘Return)")
    }

    // MARK: V6 Thumbnails

    /// V6: a result's cover is fetched once, through the library's lookup service, and kept.
    @Test func V6_aThumbnailIsFetchedOnceAndKept() async throws {
        let h = try await lookedUp([found()])
        h.lookup.cover(png)
        let candidate = try #require(h.model.lookup?.selected)
        #expect(h.model.cachedLookupThumbnail(for: candidate) == nil)
        #expect(h.lookup.coverURLs.isEmpty)

        let first = await h.model.lookupThumbnail(for: candidate)
        #expect(first == png)
        #expect(h.model.cachedLookupThumbnail(for: candidate) == png)
        let second = await h.model.lookupThumbnail(for: candidate)
        #expect(second == png)
        #expect(h.lookup.coverURLs == [try #require(candidate.coverURL)])
        // Fetching a thumbnail changes nothing about the lookup or the book.
        #expect(h.model.lookup?.phase == .results)
        #expect(h.draft?.isDirty == false)
        #expect(h.model.busyLabel == nil)
    }

    /// V6: a result with no cover asks for nothing.
    @Test func V6_noCoverNoRequest() async throws {
        let h = try await lookedUp([found(cover: false)])
        h.lookup.cover(png)
        let candidate = try #require(h.model.lookup?.selected)
        let data = await h.model.lookupThumbnail(for: candidate)
        #expect(data == nil)
        #expect(h.lookup.coverURLs.isEmpty)
    }

    /// V6: a cover that cannot be fetched, or is no image, is none; it is tried again when asked again.
    @Test func V6_aThumbnailThatFailsIsNotKept() async throws {
        let h = try await lookedUp([found()])
        let candidate = try #require(h.model.lookup?.selected)
        // Not reachable, which is what the fake answers until told otherwise.
        let unreachable = await h.model.lookupThumbnail(for: candidate)
        #expect(unreachable == nil)
        h.lookup.cover(Data("<html>".utf8))
        let notAnImage = await h.model.lookupThumbnail(for: candidate)
        #expect(notAnImage == nil)
        #expect(h.model.cachedLookupThumbnail(for: candidate) == nil)
        #expect(h.model.alert == nil)

        h.lookup.cover(png)
        let third = await h.model.lookupThumbnail(for: candidate)
        #expect(third == png)
        #expect(h.lookup.coverURLs.count == 3)
    }

    /// V6: two rows asking for the same cover at once make one request.
    @Test func V6_oneRequestForOneCover() async throws {
        let h = try await lookedUp([found()])
        let candidate = try #require(h.model.lookup?.selected)
        let gate = Gate()
        let png = png
        h.lookup.cover { _ in
            await gate.wait()
            return (png, 200)
        }
        let one = Task { await h.model.lookupThumbnail(for: candidate) }
        await gate.arrival()
        let two = Task { await h.model.lookupThumbnail(for: candidate) }
        await Task.yield()
        await gate.release()
        #expect(await one.value == png)
        #expect(await two.value == png)
        #expect(h.lookup.coverURLs.count == 1)
    }

    /// V6: covers are kept only while the lookup is open, and none is fetched without one.
    @Test func V6_thumbnailsGoWhenTheLookupCloses() async throws {
        let h = try await lookedUp([found()])
        h.lookup.cover(png)
        let candidate = try #require(h.model.lookup?.selected)
        _ = await h.model.lookupThumbnail(for: candidate)
        h.model.cancelLookup()
        #expect(h.model.cachedLookupThumbnail(for: candidate) == nil)
        let closed = await h.model.lookupThumbnail(for: candidate)
        #expect(closed == nil)
        #expect(h.lookup.coverURLs.count == 1)

        // One that arrives after the lookup has closed is not kept either.
        h.model.beginLookup()
        await h.model.settle()
        let gate = Gate()
        let png = png
        h.lookup.cover { _ in
            await gate.wait()
            return (png, 200)
        }
        let late = Task { await h.model.lookupThumbnail(for: candidate) }
        await gate.arrival()
        h.model.cancelLookup()
        await gate.release()
        #expect(await late.value == nil)
        #expect(h.model.cachedLookupThumbnail(for: candidate) == nil)
    }
}
