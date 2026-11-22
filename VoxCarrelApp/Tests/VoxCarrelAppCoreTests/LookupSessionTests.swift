import Foundation
import Testing
import VoxCarrelCore

@testable import VoxCarrelAppCore

/// The lookup sheet's state (plan 5, Task 5). K1–K7.
@Suite struct LookupSessionTests {
    private let coverURL = URL(string: "https://m.media-amazon.com/images/I/cover.jpg")!

    /// What Audible might find for Good Omens: every field filled, all different from `fullBook()`.
    private func audible(_ key: String = "B000000001", title: String = "Good Omens (Full Cast)") -> LookupCandidate {
        var metadata = BookMetadata(title: title, authors: ["Neil Gaiman", "Terry Pratchett"])
        metadata.subtitle = "A Full Cast Production"
        metadata.narrators = ["Rebecca Front", "Michael Sheen"]
        metadata.series = "Omens"
        metadata.seriesNumber = "1"
        metadata.genre = "Comedy"
        metadata.year = 2021
        metadata.publisher = "Audible Studios"
        metadata.summary = "Armageddon, with jokes."
        metadata.language = "fr"
        metadata.isbn = "9780000000002"
        metadata.asin = key
        metadata.durationSeconds = 99_999
        metadata.pageCount = 999
        return LookupCandidate(
            id: "audible:us:\(key)", source: .audible, metadata: metadata, coverURL: coverURL,
            note: "Audible · Unabridged", hasMoreDetails: false)
    }

    private func openLibrary(_ key: String = "/works/OL1W", title: String = "Good Omens") -> LookupCandidate {
        var metadata = BookMetadata(title: title, authors: ["Terry Pratchett", "Neil Gaiman"])
        metadata.year = 1990
        return LookupCandidate(
            id: "openLibrary:\(key)", source: .openLibrary, metadata: metadata, coverURL: nil,
            note: "Open Library · 1990", hasMoreDetails: true)
    }

    private func session(
        current: BookMetadata = fullBook().metadata, target: LookupSession.Target = .book(7),
        hasCover: Bool = true, hasAudio: Bool = true, finding candidates: [LookupCandidate]
    ) -> LookupSession {
        var session = LookupSession(target: target, current: current, hasCover: hasCover, hasAudio: hasAudio)
        session.beginSearch()
        session.finishSearch(
            LookupResults(candidates: candidates, searched: [.openLibrary, .audible]), for: session.query)
        return session
    }

    // MARK: K1

    /// K1
    @Test func K1_theQueryIsBuiltFromTheCurrentValues() {
        var metadata = fullBook().metadata
        metadata.title = "  Good Omens "
        let session = LookupSession(target: .book(7), current: metadata, hasCover: true, hasAudio: true)
        #expect(session.target == .book(7))
        #expect(session.query == LookupQuery(
            title: "Good Omens", author: "Terry Pratchett", isbn: "9780575048003", asin: "B0012345"))
        #expect(session.preferAudio)
        #expect(session.phase == .idle)
        #expect(session.candidates.isEmpty)
        #expect(session.selectedId == nil)
        #expect(session.selected == nil)
        #expect(session.offers.isEmpty)
        #expect(session.failureText == nil)
        #expect(!session.canApply)
    }

    /// K1: nothing where the book has nothing; blank text is nothing.
    @Test func K1_aBookWithLittleGivesASmallQuery() {
        var metadata = BookMetadata(title: "Bare", authors: ["  "])
        metadata.isbn = "  "
        let id = UUID()
        let session = LookupSession(target: .importEntry(id), current: metadata, hasCover: false, hasAudio: false)
        #expect(session.target == .importEntry(id))
        #expect(session.query == LookupQuery(title: "Bare"))
        #expect(!session.preferAudio)

        let empty = LookupSession(target: .book(1), current: BookMetadata(), hasCover: false, hasAudio: false)
        #expect(empty.query.isEmpty)
    }

    // MARK: K2

    /// K2
    @Test func K2_finishingSetsTheCandidatesAndSelectsTheFirst() {
        var session = LookupSession(target: .book(7), current: fullBook().metadata, hasCover: true, hasAudio: true)
        session.beginSearch()
        #expect(session.phase == .searching)
        #expect(!session.canApply)
        let found = [audible(), openLibrary()]
        session.finishSearch(LookupResults(candidates: found, searched: [.openLibrary, .audible]), for: session.query)
        #expect(session.phase == .results)
        #expect(session.candidates == found)
        #expect(session.selectedId == found[0].id)
        #expect(session.selected == found[0])
        #expect(!session.offers.isEmpty)
        #expect(session.failureText == nil)
    }

    /// K2
    @Test func K2_noCandidatesIsNoResults() {
        let session = session(finding: [])
        #expect(session.phase == .noResults)
        #expect(session.candidates.isEmpty)
        #expect(session.selectedId == nil)
        #expect(session.offers.isEmpty)
        #expect(!session.canApply)
    }

    /// K2: a late answer, for a query that has been changed since, is ignored.
    @Test func K2_anAnswerForAnotherQueryIsIgnored() {
        var session = LookupSession(target: .book(7), current: fullBook().metadata, hasCover: true, hasAudio: true)
        let asked = session.query
        session.beginSearch()
        session.query.title = "Good Omens 2"
        // Editing the query while a search runs leaves that search behind.
        #expect(session.phase == .idle)
        session.finishSearch(LookupResults(candidates: [audible()], searched: [.audible]), for: asked)
        #expect(session.phase == .idle)
        #expect(session.candidates.isEmpty)
        #expect(session.selectedId == nil)

        session.beginSearch()
        session.finishSearch(LookupResults(candidates: [audible()], searched: [.audible]), for: asked)
        #expect(session.phase == .searching)
        #expect(session.candidates.isEmpty)
        session.finishSearch(LookupResults(candidates: [audible()], searched: [.audible]), for: session.query)
        #expect(session.phase == .results)
    }

    /// K2: a new search clears what the last one found.
    @Test func K2_beginningAgainClearsTheLastAnswer() {
        var session = LookupSession(target: .book(7), current: fullBook().metadata, hasCover: true, hasAudio: true)
        session.beginSearch()
        session.finishSearch(
            LookupResults(candidates: [audible()], failures: [.openLibrary: .notReachable], searched: [.openLibrary, .audible]),
            for: session.query)
        #expect(session.failureText != nil)
        session.beginSearch()
        #expect(session.phase == .searching)
        #expect(session.candidates.isEmpty)
        #expect(session.selectedId == nil)
        #expect(session.offers.isEmpty)
        #expect(session.failureText == nil)
    }

    /// K2: every failed source is named, in one plain sentence each.
    @Test func K2_failuresAreNamedInPlainSentences() {
        var session = LookupSession(target: .book(7), current: fullBook().metadata, hasCover: true, hasAudio: true)
        session.beginSearch()
        session.finishSearch(
            LookupResults(candidates: [openLibrary()], failures: [.audible: .notReachable], searched: [.openLibrary, .audible]),
            for: session.query)
        #expect(session.failureText == "Audible could not be reached.")
        #expect(session.phase == .results)

        session.beginSearch()
        session.finishSearch(
            LookupResults(
                failures: [.audible: .notReachable, .openLibrary: .refused(status: 503)],
                searched: [.audible, .openLibrary]),
            for: session.query)
        #expect(session.failureText == "Audible could not be reached. Open Library answered with an error.")
        #expect(session.phase == .noResults)

        session.beginSearch()
        session.finishSearch(
            LookupResults(failures: [.audible: .unreadable, .openLibrary: .notReachable], searched: [.openLibrary, .audible]),
            for: session.query)
        #expect(session.failureText
            == "Open Library could not be reached. Audible sent an answer VoxCarrel could not read.")
    }

    // MARK: K3

    /// K3: every field the candidate has that differs, in the fixed order, as text.
    @Test func K3_offersInOrderWithBothValuesAsText() {
        let session = session(finding: [audible()])
        #expect(session.offers.map(\.id) == [
            .title, .subtitle, .authors, .narrators, .series, .seriesNumber, .genre, .year, .publisher, .language,
            .summary, .isbn, .asin, .cover,
        ])
        #expect(session.offers.map(\.label) == [
            "Title", "Subtitle", "Authors", "Narrators", "Series", "Series number", "Genre", "Year", "Publisher",
            "Language", "Description", "ISBN", "ASIN", "Cover",
        ])
        #expect(session.offers.map(\.current) == [
            "Good Omens", "The Nice and Accurate Prophecies", "Terry Pratchett; Neil Gaiman", "Martin Jarvis",
            "Standalones", "1.5", "Fantasy", "1990", "Gollancz", "en", "The world will end on Saturday.",
            "9780575048003", "B0012345", "Has a cover",
        ])
        #expect(session.offers.map(\.found) == [
            "Good Omens (Full Cast)", "A Full Cast Production", "Neil Gaiman; Terry Pratchett",
            "Rebecca Front; Michael Sheen", "Omens", "1", "Comedy", "2021", "Audible Studios", "fr",
            "Armageddon, with jokes.", "9780000000002", "B000000001", "Cover from Audible",
        ])
    }

    /// K3: a value the candidate lacks, or that is the book's own, is not offered.
    @Test func K3_onlyValuesThatDifferAreOffered() {
        // Open Library's has a title, authors and a year, all the book's own; no cover.
        #expect(session(finding: [openLibrary()]).offers.isEmpty)

        // Compared trimmed; lists in order, ignoring case.
        var same = fullBook().metadata
        same.title = " Good Omens  "
        same.authors = ["terry pratchett", "NEIL GAIMAN "]
        same.narrators = ["martin jarvis"]
        same.summary = "The world will end on Saturday.\n"
        same.durationSeconds = 1
        same.pageCount = 2
        let candidate = LookupCandidate(id: "audible:us:X", source: .audible, metadata: same)
        #expect(session(finding: [candidate]).offers.isEmpty)

        // The same names in another order are a different list.
        var reordered = BookMetadata(title: "Good Omens", authors: ["Neil Gaiman", "Terry Pratchett"])
        reordered.year = 1991
        let other = LookupCandidate(id: "openLibrary:/works/OL2W", source: .openLibrary, metadata: reordered)
        #expect(session(finding: [other]).offers.map(\.id) == [.authors, .year])

        // A blank found value is no value.
        var blank = BookMetadata(title: "  ", authors: [" "])
        blank.genre = " "
        blank.narrators = [""]
        let nothing = LookupCandidate(id: "audible:us:Y", source: .audible, metadata: blank)
        #expect(session(finding: [nothing]).offers.isEmpty)
    }

    /// K3: the cover is offered whenever the candidate has one; empty current values read as "".
    @Test func K3_theCoverAndEmptyCurrentValues() {
        var found = BookMetadata(title: "Bare")
        found.year = 2001
        found.narrators = ["Someone"]
        let candidate = LookupCandidate(
            id: "openLibrary:/works/OL3W", source: .openLibrary, metadata: found,
            coverURL: URL(string: "https://covers.openlibrary.org/b/id/1-L.jpg"))
        let session = session(current: bareBook().metadata, hasCover: false, finding: [candidate])
        #expect(session.offers.map(\.id) == [.narrators, .year, .cover])
        #expect(session.offers.map(\.current) == ["", "", ""])
        #expect(session.offers.map(\.found) == ["Someone", "2001", "Cover from Open Library"])
    }

    // MARK: K4

    /// K4: ticked exactly when the book has nothing there.
    @Test func K4_preTickedWhereTheBookIsEmpty() {
        var current = BookMetadata(title: "Good Omens", authors: ["Terry Pratchett"])
        current.genre = "Fantasy"
        let session = session(current: current, hasCover: false, finding: [audible()])
        let ticked = Set(session.offers.filter(\.ticked).map(\.id))
        #expect(ticked == [
            .subtitle, .narrators, .series, .seriesNumber, .year, .publisher, .language, .summary, .isbn, .asin, .cover,
        ])
        // Title, authors and genre differ from what the book has: shown, never pre-ticked.
        #expect(Set(session.offers.filter { !$0.ticked }.map(\.id)) == [.title, .authors, .genre])
        #expect(session.canApply)

        // A book that has everything, and a cover: nothing is ticked, so nothing to apply.
        let full = self.session(finding: [audible()])
        #expect(full.offers.count == 14)
        #expect(full.offers.allSatisfy { !$0.ticked })
        #expect(!full.canApply)
    }

    /// K4: another candidate has offers of its own, ticked afresh.
    @Test func K4_selectingAnotherCandidateStartsAfresh() {
        var first = audible("B000000001")
        first.metadata.genre = "Comedy"
        var second = audible("B000000002")
        second.metadata.genre = "Humour"
        var session = session(finding: [first, second])
        session.setTicked(true, for: .genre)
        session.setTicked(true, for: .title)
        #expect(session.canApply)

        session.select(second.id)
        #expect(session.selectedId == second.id)
        #expect(session.selected == second)
        #expect(session.offers.first { $0.id == .genre }?.found == "Humour")
        #expect(session.offers.allSatisfy { !$0.ticked })
        #expect(!session.canApply)

        // Selecting the one that is selected changes nothing.
        session.setTicked(true, for: .genre)
        session.select(second.id)
        #expect(session.offers.first { $0.id == .genre }?.ticked == true)

        // Something that is not among the results is not selected.
        session.select("audible:us:NOPE")
        #expect(session.selectedId == second.id)

        session.select(nil)
        #expect(session.selectedId == nil)
        #expect(session.selected == nil)
        #expect(session.offers.isEmpty)
        #expect(!session.canApply)
    }

    /// K4
    @Test func K4_tickingOneField() {
        var session = session(finding: [audible()])
        session.setTicked(true, for: .publisher)
        #expect(session.offers.filter(\.ticked).map(\.id) == [.publisher])
        #expect(session.tickedFields == [.publisher])
        #expect(session.canApply)
        session.setTicked(false, for: .publisher)
        #expect(!session.canApply)
        // A field that is not offered cannot be ticked.
        var none = self.session(finding: [openLibrary()])
        none.setTicked(true, for: .title)
        #expect(none.offers.isEmpty)
        #expect(!none.canApply)
    }

    // MARK: K5

    /// K5
    @Test func K5_seriesAndItsNumberGoTogether() {
        var session = session(finding: [audible()])
        session.setTicked(true, for: .series)
        #expect(Set(session.tickedFields) == [.series, .seriesNumber])
        session.setTicked(false, for: .seriesNumber)
        #expect(session.tickedFields.isEmpty)
        session.setTicked(true, for: .seriesNumber)
        #expect(Set(session.tickedFields) == [.series, .seriesNumber])

        // Only the number is offered (the series is the book's own): it stands alone.
        var sameSeries = audible()
        sameSeries.metadata.series = "Standalones"
        var alone = self.session(finding: [sameSeries])
        #expect(!alone.offers.contains { $0.id == .series })
        alone.setTicked(true, for: .seriesNumber)
        #expect(alone.tickedFields == [.seriesNumber])
    }

    /// K4, K5: a found number is never pre-ticked onto a series the book already has.
    @Test func K5_theDefaultTickOfThePairIsTheSeries() {
        var hasSeries = BookMetadata(title: "Good Omens")
        hasSeries.series = "Standalones"
        let kept = session(current: hasSeries, finding: [audible()])
        #expect(kept.offers.first { $0.id == .series }?.ticked == false)
        #expect(kept.offers.first { $0.id == .seriesNumber }?.ticked == false)

        var hasNumber = BookMetadata(title: "Good Omens")
        hasNumber.seriesNumber = "9"
        let taken = session(current: hasNumber, finding: [audible()])
        #expect(taken.offers.first { $0.id == .series }?.ticked == true)
        #expect(taken.offers.first { $0.id == .seriesNumber }?.ticked == true)
    }

    // MARK: K6

    /// K6: only ticked fields change; the rest are the book's own, whatever was found.
    @Test func K6_applyingChangesOnlyTickedFields() {
        let current = fullBook().metadata
        var session = session(finding: [audible()])
        #expect(session.applied().metadata == current)
        #expect(!session.applied().wantsCover)

        session.setTicked(true, for: .summary)
        session.setTicked(true, for: .year)
        session.setTicked(true, for: .narrators)
        var expected = current
        expected.summary = "Armageddon, with jokes."
        expected.year = 2021
        expected.narrators = ["Rebecca Front", "Michael Sheen"]
        #expect(session.applied().metadata == expected)
        #expect(!session.applied().wantsCover)

        session.setTicked(true, for: .cover)
        #expect(session.applied().metadata == expected)
        #expect(session.applied().wantsCover)

        for field in MetadataField.allCases { session.setTicked(true, for: field) }
        var everything = audible().metadata
        // Duration and page count describe the files: never taken from what was found.
        everything.durationSeconds = current.durationSeconds
        everything.pageCount = current.pageCount
        #expect(session.applied().metadata == everything)
    }

    /// K6: with nothing selected nothing is applied.
    @Test func K6_nothingSelectedAppliesNothing() {
        var session = session(current: bareBook().metadata, hasCover: false, finding: [audible()])
        #expect(session.canApply)
        session.select(nil)
        #expect(session.applied().metadata == bareBook().metadata)
        #expect(!session.applied().wantsCover)
    }

    /// K6: narrators are for a book that has audio.
    @Test func K6_narratorsAreNotOfferedWithoutAudio() {
        let ebook = session(current: bareBook().metadata, hasCover: false, hasAudio: false, finding: [audible()])
        #expect(!ebook.offers.contains { $0.id == .narrators })
        #expect(ebook.applied().metadata.narrators.isEmpty)

        let audiobook = session(current: bareBook().metadata, hasCover: false, hasAudio: true, finding: [audible()])
        #expect(audiobook.offers.first { $0.id == .narrators }?.ticked == true)
        #expect(audiobook.applied().metadata.narrators == ["Rebecca Front", "Michael Sheen"])

        // The same for an import entry: only when it has an audio file.
        let entry = LookupSession.Target.importEntry(UUID())
        let ebookEntry = session(current: bareBook().metadata, target: entry, hasCover: false, hasAudio: false, finding: [audible()])
        #expect(!ebookEntry.offers.contains { $0.id == .narrators })
        let audioEntry = session(current: bareBook().metadata, target: entry, hasCover: false, hasAudio: true, finding: [audible()])
        #expect(audioEntry.offers.contains { $0.id == .narrators })
    }

    // MARK: K7

    /// K7: details that arrive add offers and leave the user's ticks alone.
    @Test func K7_detailsAddOffersAndKeepTicks() {
        var found = openLibrary()
        found.metadata.year = 1991
        found.metadata.genre = "Humour"
        var current = BookMetadata(title: "Good Omens", authors: ["Terry Pratchett", "Neil Gaiman"])
        current.genre = "Fantasy"
        var session = session(current: current, hasCover: false, finding: [found, audible()])
        #expect(session.offers.map(\.id) == [.genre, .year])
        // Against the defaults: genre on, year off.
        session.setTicked(true, for: .genre)
        session.setTicked(false, for: .year)

        var detailed = found
        detailed.metadata.summary = "The world will end on Saturday. Next Saturday, in fact."
        detailed.hasMoreDetails = false
        session.replaceSelected(with: detailed)
        #expect(session.selected == detailed)
        #expect(session.candidates.first == detailed)
        #expect(session.candidates.count == 2)
        #expect(session.offers.map(\.id) == [.genre, .year, .summary])
        #expect(session.offers.map(\.ticked) == [true, false, true])
        #expect(session.offers.last?.found == "The world will end on Saturday. Next Saturday, in fact.")
    }

    /// K7: details for a candidate that is no longer the selected one are ignored.
    @Test func K7_detailsForAnotherSelectionAreIgnored() {
        let first = openLibrary()
        let second = audible()
        var session = session(finding: [first, second])
        session.select(second.id)
        let before = session

        var detailed = first
        detailed.metadata.summary = "Late."
        session.replaceSelected(with: detailed)
        #expect(session == before)

        session.select(nil)
        session.replaceSelected(with: detailed)
        #expect(session.candidates == [first, second])
        #expect(session.offers.isEmpty)
    }

    // MARK: Applying

    /// A3, A4: while the chosen values are being applied nothing else can be.
    @Test func applyingCannotBeBegunTwice() {
        var session = session(current: bareBook().metadata, hasCover: false, finding: [audible()])
        #expect(session.canApply)
        session.beginApplying()
        #expect(session.phase == .applying)
        #expect(!session.canApply)
        // The choice is still there to be applied.
        #expect(session.applied().wantsCover)
        #expect(session.applied().metadata.subtitle == "A Full Cast Production")

        // Only something that can be applied is.
        var nothing = self.session(finding: [])
        nothing.beginApplying()
        #expect(nothing.phase == .noResults)
    }

    // MARK: What is typed but is not a value

    /// K4: a year box holding text that is no year is not empty: the found year is offered
    /// against what is typed, and is not ticked unasked.
    @Test func K4_textThatIsNoValueIsNotAnEmptyField() {
        var book = fullBook().metadata
        book.year = nil
        var typed = LookupSession(
            target: .book(7), current: book, hasCover: true, hasAudio: true, typed: [.year: " 19x4 "])
        typed.beginSearch()
        typed.finishSearch(LookupResults(candidates: [audible()], searched: [.audible]), for: typed.query)
        let year = typed.offers.first { $0.id == .year }
        #expect(year?.current == "19x4")
        #expect(year?.found == "2021")
        #expect(year?.ticked == false)
        #expect(!typed.tickedFields.contains(.year))

        // With nothing typed it is a gap, and is filled by default.
        let empty = session(current: book, finding: [audible()])
        #expect(empty.offers.first { $0.id == .year }?.current == "")
        #expect(empty.offers.first { $0.id == .year }?.ticked == true)
        // Only space typed is nothing typed.
        let blank = LookupSession(target: .book(7), current: book, hasCover: true, hasAudio: true, typed: [.year: "  "])
        #expect(blank.typed.isEmpty)
    }

    // MARK: What each source made of the search

    @Test func K2_outcomesSayWhatEachSourceFound() {
        var session = LookupSession(target: .book(7), current: fullBook().metadata, hasCover: true, hasAudio: true)
        #expect(session.outcomes.isEmpty)
        #expect(session.answeredQuery == nil)
        session.beginSearch()
        session.finishSearch(
            LookupResults(
                candidates: [audible(), audible("B000000002")], failures: [.openLibrary: .refused(status: 500)],
                searched: [.openLibrary, .audible], found: [.audible: 2]),
            for: session.query)
        #expect(session.outcomes == [
            LookupSession.SourceOutcome(source: .openLibrary, found: 0, failure: .refused(status: 500)),
            LookupSession.SourceOutcome(source: .audible, found: 2, failure: nil),
        ])
        #expect(session.answeredQuery == session.query)
        // A source failed: not every source's answer.
        #expect(!session.isAnswered)

        session.beginSearch()
        #expect(session.outcomes.isEmpty)
        #expect(session.answeredQuery == nil)
        session.finishSearch(
            LookupResults(candidates: [audible()], searched: [.openLibrary, .audible], found: [.openLibrary: 0, .audible: 1]),
            for: session.query)
        #expect(session.isAnswered)
        session.sourcesChanged()
        #expect(!session.isAnswered)
        #expect(session.outcomes.isEmpty)
        #expect(session.candidates.count == 1)
    }
}
