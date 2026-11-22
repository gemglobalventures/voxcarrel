import Foundation
import Testing
import VoxCarrelCore

@testable import VoxCarrelAppCore

/// The lookup sheet's state with several results in play (plan 7, Task 6). A1–A7.
@Suite struct LookupMixingTests {
    /// "A Perfect Spy", read by Frank Muller: the book with nothing else filled in.
    private func spy() -> BookMetadata {
        var book = BookMetadata(title: "A Perfect Spy", authors: ["John le Carré"])
        book.narrators = ["Frank Muller"]
        return book
    }

    /// The cassette edition the Library of Congress has: the book's own.
    private func cassette() -> LookupCandidate {
        var metadata = BookMetadata(title: "A perfect spy", authors: ["John Le Carré"])
        metadata.narrators = ["Frank Muller"]
        metadata.year = 1987
        metadata.publisher = "Recorded Books"
        metadata.language = "en"
        metadata.durationSeconds = 18 * 3600
        return LookupCandidate(
            id: "libraryOfCongress:5615214", source: .libraryOfCongress, metadata: metadata,
            note: "Library of Congress · Cassette · Unabridged · 18h 0m · 1987",
            edition: EditionFacts(format: .cassette, abridged: false, publisher: "Recorded Books", year: 1987))
    }

    /// A newer recording Audible sells: another edition.
    private func kinnear(cover: Bool = true) -> LookupCandidate {
        var metadata = BookMetadata(title: "A Perfect Spy", authors: ["John le Carré"])
        metadata.narrators = ["Rory Kinnear"]
        metadata.year = 2025
        metadata.publisher = "Penguin"
        metadata.summary = "A spy, perfectly."
        metadata.genre = "Thriller"
        metadata.series = "Standalone Spies"
        metadata.seriesNumber = "3"
        metadata.asin = "B0DM2NJ5SK"
        metadata.isbn = "9780000000019"
        metadata.durationSeconds = 71_940
        return LookupCandidate(
            id: "audible:uk:B0DM2NJ5SK", source: .audible, metadata: metadata,
            coverURL: cover ? URL(string: "https://m.media-amazon.com/images/I/kinnear.jpg") : nil,
            note: "Audible · Unabridged · 19h 59m",
            edition: EditionFacts(format: .digital, abridged: false, publisher: "Penguin", year: 2025, stores: ["uk", "au"]))
    }

    /// A work in Open Library: no reader, no length.
    private func work() -> LookupCandidate {
        var metadata = BookMetadata(title: "A Perfect Spy", authors: ["John le Carré"])
        metadata.year = 1986
        metadata.genre = "Spy fiction"
        metadata.summary = "From Open Library."
        return LookupCandidate(
            id: "openLibrary:/works/OL1W", source: .openLibrary, metadata: metadata,
            coverURL: URL(string: "https://covers.openlibrary.org/b/id/1-L.jpg"), note: "Open Library · 1986")
    }

    private let different = EditionVerdict.differentEdition(reasons: ["read by Rory Kinnear, not Frank Muller", "19h 59m; yours is 18h 0m"])

    private func session(
        _ candidates: [LookupCandidate], book: BookMetadata? = nil, hasCover: Bool = false, seconds: Double? = 18 * 3600,
        editionKind: EditionKindNote? = nil, target: LookupSession.Target = .book(7), partsAppearMissing: Bool = false,
        narratorNotFound: [LookupSource: String] = [:]
    ) -> LookupSession {
        var session = LookupSession(
            target: target, current: book ?? spy(), hasCover: hasCover, hasAudio: true, audioSeconds: seconds,
            editionKind: editionKind, partsAppearMissing: partsAppearMissing)
        session.beginSearch()
        // Judged as the lookup service judges them.
        var verdicts: [String: EditionVerdict] = [:]
        if let context = session.bookContext {
            for candidate in candidates { verdicts[candidate.id] = EditionMatch.verdict(candidate: candidate, book: context) }
        }
        session.finishSearch(
            LookupResults(
                candidates: candidates, searched: [.openLibrary, .audible, .libraryOfCongress],
                found: Dictionary(grouping: candidates, by: \.source).mapValues(\.count), verdicts: verdicts,
                narratorNotFound: narratorNotFound),
            for: session.query)
        return session
    }

    // MARK: The search

    @Test func theSearchCarriesTheFirstNarratorAndTheBookContext() {
        var book = spy()
        book.narrators = ["Full Cast", " Frank Muller ", "Someone Else"]
        let audio = LookupSession(
            target: .book(7), current: book, hasCover: false, hasAudio: true, audioSeconds: 64_800,
            editionKind: EditionKindNote(kind: .abridged, basis: .setByHand))
        // "Full Cast" is not someone to search for.
        #expect(audio.query == LookupQuery(title: "A Perfect Spy", author: "John le Carré", narrator: "Frank Muller", wantsAudioEditions: true))
        #expect(audio.bookContext == LookupBookContext(metadata: book, audioSeconds: 64_800, isAbridged: true))

        let ebook = LookupSession(target: .book(7), current: book, hasCover: false, hasAudio: false, audioSeconds: 64_800)
        #expect(ebook.query == LookupQuery(title: "A Perfect Spy", author: "John le Carré"))
        #expect(ebook.bookContext == LookupBookContext(metadata: book, audioSeconds: nil, isAbridged: nil))

        // A dramatisation is neither abridged nor unabridged.
        let play = LookupSession(
            target: .book(7), current: book, hasCover: false, hasAudio: true,
            editionKind: EditionKindNote(kind: .dramatised, basis: .inferred))
        #expect(play.bookContext?.isAbridged == nil)

        // A book that is being added has no edition to judge against, and nothing but Audible is asked.
        let adding = LookupSession(target: .newAudibleBook, current: BookMetadata(), hasCover: false, hasAudio: true)
        #expect(adding.bookContext == nil)
        #expect(adding.query == LookupQuery())
        #expect(adding.sources == [.audible])
    }

    // MARK: A2 the first ticks

    @Test func A2_aSameOrUnknownEditionIsTickedAsBefore() {
        // The book's own edition: what the book lacks is ticked.
        let own = session([cassette(), kinnear()])
        #expect(own.selectedId == cassette().id)
        #expect(own.verdict(for: cassette().id) == .sameEdition)
        // (The author differs only in a capital, which is no difference.)
        #expect(own.offers.map(\.id) == [.title, .year, .publisher, .language])
        #expect(own.offers.filter(\.ticked).map(\.id) == [.year, .publisher, .language])
        #expect(own.offers.allSatisfy { $0.reason == nil })

        // One that cannot be told: the same.
        let unknown = session([work(), kinnear()])
        #expect(unknown.verdict(for: work().id) == .unknown)
        #expect(unknown.offers.filter(\.ticked).map(\.id) == [.genre, .year, .summary, .cover])
        #expect(unknown.offers.allSatisfy { $0.reason == nil })
    }

    @Test func A2_nothingOfADifferentEditionIsTickedAndItsEditionFieldsSayWhy() {
        var session = session([kinnear(), cassette()])
        #expect(session.selectedId == kinnear().id)
        #expect(session.verdict(for: kinnear().id) == different)
        // Everything is offered, nothing is ticked: not even what the book lacks.
        #expect(session.offers.map(\.id) == [.narrators, .series, .seriesNumber, .genre, .year, .publisher, .summary, .isbn, .asin, .cover])
        #expect(session.offers.allSatisfy { !$0.ticked })
        #expect(session.tickedFields.isEmpty)
        // (The edition kind is its own offer, and comes from the cassette.)
        session.setEditionTicked(false)
        #expect(!session.canApply)

        // The values that belong to an edition say why; the others do not.
        let why = "Different edition: read by Rory Kinnear, not Frank Muller; 19h 59m; yours is 18h 0m"
        for offer in session.offers {
            let isEditionField = [MetadataField.narrators, .year, .publisher, .isbn, .asin].contains(offer.id)
            #expect(offer.reason == (isEditionField ? why : nil), "\(offer.id)")
        }

        // They can still be ticked, deliberately.
        session.setTicked(true, for: .summary)
        session.setTicked(true, for: .narrators)
        #expect(session.tickedFields == [.narrators, .summary])
        #expect(session.canApply)
        #expect(session.applied().metadata.narrators == ["Rory Kinnear"])
    }

    // MARK: A1 ticks for each result

    @Test func A1_eachResultHasItsOwnTicksAndTheyAreKept() {
        var session = session([cassette(), work(), kinnear()])
        // Something is unticked on the first: its ticks are now the user's.
        session.setTicked(false, for: .language)
        #expect(session.tickedFields(on: cassette().id) == [.year, .publisher])

        session.select(work().id)
        // The work's own offers, with its own ticks: what the first has ticked is not taken from it.
        #expect(session.offers.map(\.id) == [.genre, .year, .summary, .cover])
        #expect(session.offers.filter(\.ticked).map(\.id) == [.genre, .summary, .cover])
        #expect(session.tickedFields(on: cassette().id) == [.year, .publisher])

        session.setTicked(false, for: .genre)
        session.select(kinnear().id)
        #expect(session.offers.allSatisfy { !$0.ticked })
        // A1: the ticks made on the others are all still there.
        #expect(session.tickedFields(on: cassette().id) == [.year, .publisher])
        #expect(session.tickedFields(on: work().id) == [.summary, .cover])
        #expect(session.tickedFields == [.year, .publisher, .summary, .cover])

        // And they are there when a result is selected again.
        session.select(cassette().id)
        #expect(session.offers.filter(\.ticked).map(\.id) == [.year, .publisher])
        session.select(work().id)
        #expect(session.offers.filter(\.ticked).map(\.id) == [.summary, .cover])
        session.select(nil)
        #expect(session.offers.isEmpty)
        #expect(session.canApply)
        #expect(session.tickedFields == [.year, .publisher, .summary, .cover])
        #expect(session.offers(for: cassette().id).filter(\.ticked).map(\.id) == [.year, .publisher])
        #expect(session.offers(for: "audible:uk:NOPE").isEmpty)
    }

    /// The first ticks of a result that was only looked at are nobody's choice: they go
    /// when another is selected, so that what is applied is what was chosen.
    @Test func A1_aResultThatWasOnlyLookedAtKeepsNothing() {
        var other = work()
        other.id = "openLibrary:/works/OL2W"
        other.metadata.publisher = "A Publisher"
        var session = session([work(), other, kinnear()])
        #expect(session.tickedFields(on: work().id) == [.genre, .year, .summary, .cover])
        session.select(other.id)
        #expect(session.tickedFields(on: work().id).isEmpty)
        // The other has its first ticks in full.
        #expect(session.tickedFields == [.genre, .year, .publisher, .summary, .cover])
        // (The edition, which the re-reading's length shows, is its own offer.)
        #expect(session.applySummary
            == "Genre, year, publisher, description and cover from Open Library; edition from its running time")
        // Back again: the first's ticks, afresh.
        session.select(work().id)
        #expect(session.tickedFields(on: other.id).isEmpty)
        #expect(session.tickedFields == [.genre, .year, .summary, .cover])
    }

    /// The book's own edition is different: its first ticks stay while another result
    /// is looked at, so that the cover or the description can be taken from that one.
    @Test func A1_theBooksOwnEditionKeepsItsFirstTicks() {
        var session = session([cassette(), work(), kinnear()])
        #expect(session.tickedFields(on: cassette().id) == [.year, .publisher, .language])
        session.select(work().id)
        #expect(session.tickedFields(on: cassette().id) == [.year, .publisher, .language])
        // The work's first ticks: what the cassette does not already give.
        #expect(session.tickedFields(on: work().id) == [.genre, .summary, .cover])
        session.select(kinnear().id)
        // The work was only looked at; the cassette is still the book's own.
        #expect(session.tickedFields(on: work().id).isEmpty)
        #expect(session.tickedFields == [.year, .publisher, .language])
        session.setTicked(true, for: .cover)
        #expect(session.applySummary
            == "Year, publisher, language and edition from Library of Congress; cover from Audible")
    }

    // MARK: A3 one result for each field

    @Test func A3_tickingAFieldUnticksItOnEveryOtherResult() {
        var session = session([cassette(), work(), kinnear()])
        session.setTicked(true, for: .title)
        #expect(session.tickedFields(on: cassette().id) == [.title, .year, .publisher, .language])

        session.select(kinnear().id)
        session.setTicked(true, for: .year)
        session.setTicked(true, for: .cover)
        #expect(session.tickedFields(on: kinnear().id) == [.year, .cover])
        #expect(session.tickedFields(on: cassette().id) == [.title, .publisher, .language])

        // The work's first ticks leave what is ticked elsewhere where it is.
        session.select(work().id)
        #expect(session.tickedFields(on: work().id) == [.genre, .summary])
        session.setTicked(true, for: .cover)
        #expect(session.tickedFields(on: work().id) == [.genre, .summary, .cover])
        #expect(session.tickedFields(on: kinnear().id) == [.year])

        // Unticking takes nothing from anyone, and gives nothing back.
        session.setTicked(false, for: .cover)
        #expect(session.tickedFields(on: kinnear().id) == [.year])
        #expect(!session.tickedFields.contains(.cover))

        // A result that is not selected can be ticked too.
        session.setTicked(true, for: .year, on: cassette().id)
        #expect(session.tickedFields(on: cassette().id) == [.title, .year, .publisher, .language])
        #expect(session.tickedFields(on: kinnear().id).isEmpty)
        // A value the result does not offer, or a result that is not there, changes nothing.
        let before = session
        session.setTicked(true, for: .asin, on: cassette().id)
        session.setTicked(true, for: .year, on: "audible:uk:NOPE")
        #expect(session == before)
        // No field is ever ticked on two results.
        for field in MetadataField.allCases {
            #expect(session.candidates.filter { session.tickedFields(on: $0.id).contains(field) }.count <= 1)
        }
    }

    @Test func A3_theSeriesPairMovesTogetherAcrossResults() {
        var other = work()
        other.metadata.series = "Smiley and Others"
        other.metadata.seriesNumber = "9"
        var session = session([other, kinnear()])
        #expect(Set(session.tickedFields(on: other.id)).isSuperset(of: [.series, .seriesNumber]))
        session.setTicked(false, for: .genre)

        session.select(kinnear().id)
        session.setTicked(true, for: .seriesNumber)
        // Both halves moved, and both halves left the other result.
        #expect(Set(session.tickedFields(on: kinnear().id)) == [.series, .seriesNumber])
        #expect(Set(session.tickedFields(on: other.id)).isDisjoint(with: [.series, .seriesNumber]))
        let applied = session.applied().metadata
        #expect(applied.series == "Standalone Spies")
        #expect(applied.seriesNumber == "3")

        session.setTicked(false, for: .series)
        #expect(Set(session.tickedFields).isDisjoint(with: [.series, .seriesNumber]))
    }

    // MARK: A4 the summary

    @Test func A4_theSummaryNamesWhatComesFromWhere() {
        var session = session([cassette(), kinnear(), work()])
        // The cassette is the book's own edition and says it is unabridged: that is offered too.
        #expect(session.applySummary == "Year, publisher, language and edition from Library of Congress")
        session.setEditionTicked(false)
        #expect(session.applySummary == "Year, publisher and language from Library of Congress")
        session.setTicked(false, for: .language)
        session.select(kinnear().id)
        session.setTicked(true, for: .summary)
        session.setTicked(true, for: .cover)
        #expect(session.applySummary == "Year and publisher from Library of Congress; description and cover from Audible")
        session.setTicked(true, for: .asin)
        session.select(work().id)
        #expect(session.applySummary
            == "Year and publisher from Library of Congress; description, ASIN and cover from Audible; genre from Open Library")
        session.setTicked(false, for: .genre)
        session.setTicked(true, for: .genre, on: kinnear().id)
        #expect(session.applySummary == "Year and publisher from Library of Congress; genre, description, ASIN and cover from Audible")

        for candidate in session.candidates {
            for field in MetadataField.allCases { session.setTicked(false, for: field, on: candidate.id) }
        }
        #expect(session.applySummary == nil)
        #expect(!session.canApply)
        // The edition alone can be applied.
        session.setEditionTicked(true)
        #expect(session.applySummary == "Edition from Library of Congress")
        #expect(session.canApply)
    }

    /// Two results of one source are named once.
    @Test func A4_resultsOfOneSourceAreNamedTogether() {
        var second = kinnear()
        second.id = "audible:us:B0D3MX4TFN"
        second.metadata.narrators = ["Shaun Evans"]
        var session = session([kinnear(), second])
        session.setEditionTicked(false)
        session.setTicked(true, for: .summary)
        session.setTicked(true, for: .year, on: second.id)
        #expect(session.applySummary == "Year and description from Audible")
        #expect(session.applied().metadata.year == 2025)
    }

    // MARK: A5 applying

    @Test func A5_appliedMergesEveryTickedFieldAcrossResults() {
        var book = spy()
        book.genre = "Fiction"
        book.durationSeconds = 64_800
        book.pageCount = 12
        var session = session([cassette(), kinnear(), work()], book: book)
        session.setTicked(false, for: .language)
        session.select(kinnear().id)
        session.setTicked(true, for: .summary)
        session.setTicked(true, for: .cover)
        session.setEditionTicked(false)

        let applied = session.applied()
        var expected = book
        expected.year = 1987
        expected.publisher = "Recorded Books"
        expected.summary = "A spy, perfectly."
        // What is not ticked is the book's own, whatever the results say: narrator, length, genre.
        #expect(applied.metadata == expected)
        #expect(applied.metadata.narrators == ["Frank Muller"])
        #expect(applied.fields == [.year, .publisher, .summary, .cover])
        // The cover is that of the result whose cover is ticked.
        #expect(applied.coverCandidate == kinnear())
        #expect(applied.wantsCover)
        #expect(applied.editionKind == nil)

        // The cover ticked on another result is then that one's.
        session.setTicked(true, for: .cover, on: work().id)
        #expect(session.applied().coverCandidate == work())
        session.setTicked(false, for: .cover, on: work().id)
        #expect(session.applied().coverCandidate == nil)
        #expect(!session.applied().wantsCover)
        #expect(session.applied().fields == [.year, .publisher, .summary])
    }

    @Test func A5_nothingCanBeChangedWhileApplying() {
        var session = session([cassette(), kinnear()])
        session.beginApplying()
        #expect(session.phase == .applying)
        let before = session
        session.setTicked(true, for: .title)
        session.setTicked(true, for: .cover, on: kinnear().id)
        session.setEditionTicked(false)
        session.select(kinnear().id)
        #expect(session == before)
        #expect(!session.canApply)
    }

    // MARK: A6 badges and stores

    @Test func A6_theBadgeOfEachResult() {
        let session = session([cassette(), work(), kinnear()])
        #expect(session.badgeText(for: cassette().id) == "Your edition")
        #expect(session.badgeText(for: work().id) == nil)
        #expect(session.badgeText(for: kinnear().id) == "Different edition")
        #expect(session.badgeHelp(for: kinnear().id) == "Read by Rory Kinnear, not Frank Muller; 19h 59m; yours is 18h 0m")
        #expect(session.badgeHelp(for: cassette().id) == nil)
        #expect(session.badgeHelp(for: work().id) == nil)
        #expect(session.badgeText(for: "audible:uk:NOPE") == nil)

        // A book that is being added has no edition for a result to be.
        let adding = self.session([kinnear()], target: .newAudibleBook)
        #expect(adding.verdicts.isEmpty)
        #expect(adding.badgeText(for: kinnear().id) == nil)
    }

    @Test func A6_theStoresThatListAResult() {
        var result = kinnear()
        #expect(result.storesText(own: .uk) == "UK, Australia")
        #expect(result.storesText(own: .us) == "UK, Australia")
        result.edition.stores = ["us", "uk", "au"]
        #expect(result.storesText(own: .us) == "US, UK, Australia")
        result.edition.stores = ["de", "ca", "jp"]
        #expect(result.storesText(own: .uk) == "Germany, Canada, Japan")
        // Only the user's own store: nothing to say.
        result.edition.stores = ["uk"]
        #expect(result.storesText(own: .uk) == nil)
        // Only another: that is worth saying.
        #expect(result.storesText(own: .us) == "UK")
        result.edition.stores = []
        #expect(result.storesText(own: .uk) == nil)
        #expect(cassette().storesText(own: .uk) == nil)
        #expect(AudibleStore.allCases.map(\.shortTitle) == [
            "US", "UK", "Australia", "Canada", "Germany", "France", "Italy", "Spain", "Japan", "India", "Brazil",
        ])

        // A9: the store a result's ASIN belongs to.
        #expect(kinnear().audibleStore == .uk)
        result.edition.stores = ["au", "uk"]
        #expect(result.audibleStore == .au)
        result.edition.stores = []
        #expect(result.audibleStore == .uk)
        result.id = "audible:B0DM2NJ5SK"
        #expect(result.audibleStore == nil)
        #expect(cassette().audibleStore == nil)
    }

    // MARK: A7 the narrator was not found

    @Test func A7_theOutcomeSaysTheNarratorWasNotFound() {
        let session = session([kinnear()], narratorNotFound: [.audible: "Frank Muller"])
        #expect(session.outcomes == [
            LookupSession.SourceOutcome(source: .openLibrary, found: 0, failure: nil),
            LookupSession.SourceOutcome(source: .audible, found: 1, failure: nil, narratorNotFound: "Frank Muller"),
            LookupSession.SourceOutcome(source: .libraryOfCongress, found: 0, failure: nil),
        ])
    }

    // MARK: The edition kind, offered

    @Test func K3_theEditionOfTheBooksOwnResultIsOffered() {
        var session = session([cassette(), kinnear()])
        let note = EditionKindNote(
            kind: .unabridged, basis: .matched("Library of Congress"), reason: "Library of Congress lists your edition as unabridged.")
        #expect(session.editionOffer == LookupSession.EditionOffer(
            label: "Edition", current: "", found: "Unabridged",
            reason: "Library of Congress lists your edition as unabridged. Matched with a result from Library of Congress.",
            ticked: true, note: note))
        #expect(session.editionOffer?.currentText == "Now: —")
        #expect(session.editionRemark == nil)
        #expect(session.applied().editionKind == note)
        #expect(session.applySummary == "Year, publisher, language and edition from Library of Congress")

        session.setEditionTicked(false)
        #expect(session.editionOffer?.ticked == false)
        #expect(session.applied().editionKind == nil)
        // Its tick is its own, whichever result is selected.
        session.select(kinnear().id)
        #expect(session.editionOffer?.ticked == false)
        #expect(session.editionOffer?.note == note)
    }

    /// K4: with no result that is the book's own, what its running time shows is offered.
    @Test func K4_theInferredEditionIsOfferedTickedOnlyWhenTheBookHasNone() {
        let unknown = session([kinnear(), work()])
        let offer = try? #require(unknown.editionOffer)
        #expect(offer?.found == "Unabridged")
        #expect(offer?.note == EditionKindNote(kind: .unabridged, basis: .inferred, reason: "18h 0m; the unabridged edition runs 19h 59m."))
        #expect(offer?.reason == "18h 0m; the unabridged edition runs 19h 59m. Worked out from its running time.")
        #expect(offer?.ticked == true)
        // Nothing else is ticked for a different edition, but the edition can be applied.
        #expect(unknown.canApply)
        #expect(unknown.applySummary == "Edition from its running time")

        // The book has a kind already: offered, not ticked.
        var known = session([kinnear()], editionKind: EditionKindNote(kind: .abridged, basis: .setByHand))
        #expect(known.editionOffer?.current == "Abridged")
        #expect(known.editionOffer?.currentText == "Now: Abridged")
        #expect(known.editionOffer?.found == "Unabridged")
        #expect(known.editionOffer?.ticked == false)
        #expect(!known.canApply)
        known.setEditionTicked(true)
        #expect(known.applied().editionKind?.kind == .unabridged)
        #expect(known.canApply)

        // What the book already is, is not offered again.
        let same = session([kinnear()], editionKind: EditionKindNote(kind: .unabridged, basis: .setByHand))
        #expect(same.editionOffer == nil)
        #expect(!same.canApply)
    }

    @Test func K5_aPageCountGivesAProbableOffer() {
        var printed = work()
        printed.metadata.pageCount = 612
        let session = session([printed], seconds: 3 * 3600)
        #expect(session.editionOffer?.found == "Probably abridged")
        #expect(session.editionOffer?.note.basis == .estimated)
        #expect(session.applySummary?.hasSuffix("edition from the length of the printed book") == true)
    }

    @Test func theEditionIsOfferedOnlyForALibraryAudiobookWithSomethingToGoOn() {
        // No measured length and no result that is the book's own: nothing to offer.
        #expect(session([kinnear()], seconds: nil).editionOffer == nil)
        // An import entry has nowhere to keep it.
        #expect(session([cassette()], target: .importEntry(UUID())).editionOffer == nil)
        #expect(session([cassette()], target: .newAudibleBook).editionOffer == nil)
        // An ebook has no edition of this kind.
        var ebook = LookupSession(target: .book(7), current: spy(), hasCover: false, hasAudio: false)
        ebook.beginSearch()
        ebook.finishSearch(LookupResults(candidates: [cassette()], searched: [.libraryOfCongress]), for: ebook.query)
        #expect(ebook.editionOffer == nil)
        // No results, nothing.
        #expect(session([]).editionOffer == nil)
        var none = session([])
        none.setEditionTicked(true)
        #expect(none.applied().editionKind == nil)
    }

    @Test func K4_K7_whatIsSaidWhenThereIsNoVerdict() {
        let between = session([kinnear()], seconds: 13 * 3600)
        #expect(between.editionOffer == nil)
        #expect(between.editionRemark == "13h 0m; shorter than the unabridged editions (19h 59m), so it may be abridged or incomplete.")
        let missing = session([kinnear()], seconds: 3 * 3600, partsAppearMissing: true)
        #expect(missing.editionOffer == nil)
        #expect(missing.editionRemark == "Parts appear to be missing, so the length does not show whether it is abridged.")
        #expect(session([cassette()]).editionRemark == nil)
    }

    // MARK: A10 a new search starts again

    @Test func A10_aNewSearchForgetsEveryTick() {
        var session = session([cassette(), kinnear()])
        session.setTicked(true, for: .title)
        session.setTicked(true, for: .cover, on: kinnear().id)
        session.setEditionTicked(false)
        session.beginSearch()
        #expect(session.tickedFields.isEmpty)
        #expect(session.verdicts.isEmpty)
        #expect(session.editionOffer == nil)
        session.finishSearch(LookupResults(candidates: [cassette(), kinnear()], searched: [.audible]), for: session.query)
        // First ticks again; no verdicts came with this answer, so the second result is not known to differ.
        #expect(session.tickedFields(on: cassette().id) == [.year, .publisher, .language])
        #expect(session.tickedFields(on: kinnear().id).isEmpty)
        #expect(session.badgeText(for: kinnear().id) == nil)
        #expect(session.editionOffer?.ticked == true)
    }

    /// K7 of plan 5 still holds: more about the selected result adds offers with their
    /// first ticks and leaves the user's ticks alone; but not a field ticked elsewhere.
    @Test func A1_moreAboutTheSelectedResultKeepsTheTicks() {
        var bare = work()
        bare.metadata.summary = nil
        bare.metadata.genre = nil
        var session = session([cassette(), bare])
        session.setTicked(true, for: .title)
        session.select(bare.id)
        #expect(session.offers.map(\.id) == [.year, .cover])
        session.setTicked(false, for: .cover)

        var detailed = bare
        detailed.metadata.summary = "From Open Library."
        detailed.metadata.publisher = "A Publisher"
        session.replaceSelected(with: detailed)
        #expect(session.offers.map(\.id) == [.year, .publisher, .summary, .cover])
        // The description is new and the book has none: ticked. The publisher is the cassette's already.
        #expect(session.tickedFields(on: bare.id) == [.summary])
        #expect(session.tickedFields(on: cassette().id) == [.title, .year, .publisher, .language])
    }
}
