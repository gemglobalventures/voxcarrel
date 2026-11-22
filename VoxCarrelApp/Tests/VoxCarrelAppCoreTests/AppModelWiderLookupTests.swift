import DemoContent
import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// The demo's Salt Road as the Library of Congress might have it: read by the same
/// narrator, so the book's own edition.
private func saltRoadCassette() -> LookupCandidate {
    var candidate = foundBook(.libraryOfCongress, "9000001", title: "Salt road", authors: ["Ines Calloway"]) {
        $0.narrators = ["Marcus Lindqvist"]
        $0.publisher = "Recorded Tides"
        $0.year = 1999
    }
    candidate.edition = EditionFacts(format: .cassette, abridged: false, publisher: "Recorded Tides", year: 1999)
    return candidate
}

/// Another recording of it that several Audible stores sell.
private func saltRoadReread(stores: [String] = ["uk", "us", "au"]) -> LookupCandidate {
    var candidate = foundBook(.audible, "\(stores.first ?? "uk"):B0SALTROAD", title: "Salt Road", authors: ["Ines Calloway"], cover: true) {
        $0.narrators = ["Someone Else"]
        $0.publisher = "Tidewater Audio"
        $0.summary = "A road, and salt."
        $0.asin = "B0SALTROAD"
        $0.year = 2019
    }
    candidate.edition = EditionFacts(format: .digital, abridged: false, publisher: "Tidewater Audio", year: 2019, stores: stores)
    return candidate
}

/// Lookup across several sources and stores, with edition verdicts and mixed results
/// (plan 7, Task 6). A1–A10, A8b, A8c. Every model here looks things up in the
/// harness's `FakeLookup`, which like the real service has a provider only for a
/// source that is on: nothing reaches the network.
@MainActor
@Suite struct AppModelWiderLookupTests {
    private let png = MediaFixtures.makeImage(.png)

    /// A demo library with the Library of Congress on, Salt Road selected, and its
    /// lookup open and answered with the cassette and the re-reading.
    private func lookedUp() async throws -> (Harness, Int64) {
        let h = try await Harness.demo()
        h.model.audibleStore = .uk
        h.model.setLookupSource(.libraryOfCongress, on: true)
        h.lookup.find(.libraryOfCongress, [saltRoadCassette()])
        h.lookup.find(.audible, [saltRoadReread()])
        let id = try await h.select("Salt Road")
        h.model.beginLookup()
        await h.model.settle()
        return (h, id)
    }

    private func savedCover(_ h: Harness, _ id: Int64) throws -> Data? {
        LibraryService(store: try h.store()).covers.image(for: id)?.data
    }

    // MARK: A8 the settings

    @Test func A8_A8c_theSettingsToBeginWith() throws {
        let h = try Harness(root: try makeTempDir())
        // A8c: the Library of Congress is off until it is turned on.
        #expect(h.model.lookupSources == [.openLibrary, .audible])
        #expect(h.model.otherAudibleStores == [.us, .uk, .au])
        #expect(h.defaults.object(forKey: "lookupSources") == nil)
        #expect(h.defaults.object(forKey: "audibleStores") == nil)

        // A8: the user's own store first, then the United States, the United Kingdom and Australia, each once.
        h.model.audibleStore = .de
        #expect(h.model.audibleStores == [.de, .us, .uk, .au])
        h.model.audibleStore = .uk
        #expect(h.model.audibleStores == [.uk, .us, .au])
        h.model.audibleStore = .au
        #expect(h.model.audibleStores == [.au, .us, .uk])
        #expect(h.model.lookupConfiguration == LookupConfiguration(sources: [.openLibrary, .audible], audibleStores: [.au, .us, .uk]))
    }

    @Test func A8_theSettingsAreRemembered() throws {
        let h = try Harness(root: try makeTempDir())
        h.model.audibleStore = .uk
        h.model.setLookupSource(.libraryOfCongress, on: true)
        h.model.setLookupSource(.openLibrary, on: false)
        h.model.setAudibleStore(.de, searched: true)
        h.model.setAudibleStore(.us, searched: false)
        #expect(h.model.lookupSources == [.audible, .libraryOfCongress])
        #expect(h.model.audibleStores == [.uk, .au, .de])
        #expect(h.defaults.array(forKey: "lookupSources") as? [String] == ["audible", "libraryOfCongress"])
        #expect(h.defaults.array(forKey: "audibleStores") as? [String] == ["uk", "au", "de"])

        let again = h.relaunched()
        #expect(again.lookupSources == [.audible, .libraryOfCongress])
        #expect(again.audibleStores == [.uk, .au, .de])

        // Every source off is remembered as that, not as the defaults.
        h.model.lookupSources = []
        h.model.otherAudibleStores = []
        #expect(h.relaunched().lookupSources.isEmpty)
        #expect(h.relaunched().audibleStores == [.uk])
        // What cannot be read is passed over.
        h.defaults.set(["audible", "atlantis"], forKey: "lookupSources")
        h.defaults.set(["jp", "moon"], forKey: "audibleStores")
        #expect(h.relaunched().lookupSources == [.audible])
        #expect(h.relaunched().audibleStores == [.uk, .jp])
    }

    /// A8: the user's own store cannot be switched off in the list of stores.
    @Test func A8_theStoresList() throws {
        let h = try Harness(root: try makeTempDir())
        h.model.audibleStore = .uk
        let rows = h.model.audibleStoreRows
        #expect(rows.map(\.title) == AppModel.audibleStoreChoices.map(\.title))
        #expect(rows.map(\.title).first == "Australia")
        #expect(Set(rows.filter(\.isOn).map(\.store)) == [.uk, .us, .au])
        #expect(rows.filter(\.isOwn).map(\.store) == [.uk])
        #expect(rows.filter { !$0.isEnabled }.map(\.store) == [.uk])
        #expect(h.model.audibleStoresAreEnabled)

        h.model.setAudibleStore(.uk, searched: false)
        #expect(h.model.audibleStores == [.uk, .us, .au])
        h.model.setAudibleStore(.ca, searched: true)
        #expect(h.model.audibleStores == [.uk, .us, .au, .ca])
        #expect(h.model.audibleStoreRows.first { $0.store == .ca }?.isOn == true)
        // The same again changes nothing.
        h.model.setAudibleStore(.ca, searched: true)
        #expect(h.model.audibleStores == [.uk, .us, .au, .ca])

        // A8b: with Audible off the whole list is disabled, and still says what is chosen.
        h.model.setLookupSource(.audible, on: false)
        #expect(!h.model.audibleStoresAreEnabled)
        #expect(h.model.audibleStoreRows.allSatisfy { !$0.isEnabled })
        #expect(Set(h.model.audibleStoreRows.filter(\.isOn).map(\.store)) == [.uk, .us, .au, .ca])
    }

    /// A8: changing the sources or the stores rebuilds what the library looks books up with.
    @Test func A8_changingASettingRebuildsTheLookupService() async throws {
        let h = try Harness(root: try makeTempDir())
        h.model.audibleStore = .uk
        h.model.setLookupSource(.libraryOfCongress, on: true)
        // No library is open: there is nothing to rebuild.
        #expect(h.lookup.built.isEmpty)
        await h.model.start()
        #expect(h.lookup.built == [LookupConfiguration(sources: Set(LookupSource.allCases), audibleStores: [.uk, .us, .au])])

        h.model.setLookupSource(.openLibrary, on: false)
        #expect(h.lookup.built.last == LookupConfiguration(sources: [.audible, .libraryOfCongress], audibleStores: [.uk, .us, .au]))
        h.model.setAudibleStore(.au, searched: false)
        #expect(h.lookup.built.last == LookupConfiguration(sources: [.audible, .libraryOfCongress], audibleStores: [.uk, .us]))
        h.model.audibleStore = .us
        #expect(h.lookup.built.last == LookupConfiguration(sources: [.audible, .libraryOfCongress], audibleStores: [.us, .uk]))
        #expect(h.lookup.built.count == 4)
        // A change that changes nothing builds nothing.
        h.model.setLookupSource(.openLibrary, on: false)
        h.model.setAudibleStore(.au, searched: false)
        h.model.audibleStore = .us
        #expect(h.lookup.built.count == 4)
    }

    // MARK: A8b sources on and off

    @Test func A8b_A8c_theRowsOfTheSettingsPage() throws {
        let h = try Harness(root: try makeTempDir())
        #expect(h.model.lookupSourceRows == [
            LookupSourceRow(
                source: .openLibrary, title: "Open Library", detail: "Books and their print and audio editions; covers",
                note: nil, isOn: true),
            LookupSourceRow(
                source: .audible, title: "Audible", detail: "Audiobook editions, narrators, series and covers", note: nil,
                isOn: true),
            // A8c
            LookupSourceRow(
                source: .libraryOfCongress, title: "Library of Congress", detail: "Cassette and CD editions with their narrators",
                note: "Searches to this source are sent unencrypted, so the title, author and narrator you look up can be seen on your network.",
                isOn: false),
        ])
        h.model.setLookupSource(.libraryOfCongress, on: true)
        h.model.setLookupSource(.audible, on: false)
        #expect(h.model.lookupSourceRows.map(\.isOn) == [true, false, true])
        #expect(h.model.lookupSourceRows.map(\.id) == LookupSource.allCases)
    }

    /// A8b: a source that is off is never contacted.
    @Test func A8b_aSourceThatIsOffIsNeverAsked() async throws {
        let h = try await Harness.demo()
        h.lookup.find(.libraryOfCongress, [saltRoadCassette()])
        h.lookup.find(.audible, [saltRoadReread()])
        try await h.select("Salt Road")

        // To begin with: Open Library and Audible, and not the Library of Congress (A8c).
        h.model.beginLookup()
        await h.model.settle()
        #expect(Set(h.lookup.asked.map(\.source)) == [.openLibrary, .audible])
        #expect(h.model.lookup?.candidates.map(\.source) == [.audible])
        #expect(h.model.lookup?.outcomes.map(\.source) == [.openLibrary, .audible])
        h.model.cancelLookup()

        // Turned on, it is asked.
        h.model.setLookupSource(.libraryOfCongress, on: true)
        h.model.beginLookup()
        await h.model.settle()
        #expect(h.lookup.asked.dropFirst(2).map(\.source).sorted { $0.rawValue < $1.rawValue } == [.audible, .libraryOfCongress, .openLibrary])
        #expect(Set(h.model.lookup?.candidates.map(\.source) ?? []) == [.audible, .libraryOfCongress])
        h.model.cancelLookup()

        // Open Library and Audible off: only the Library of Congress hears of it.
        h.model.setLookupSource(.openLibrary, on: false)
        h.model.setLookupSource(.audible, on: false)
        let before = h.lookup.asked.count
        h.model.beginLookup()
        await h.model.settle()
        #expect(h.lookup.asked.dropFirst(before).map(\.source) == [.libraryOfCongress])
        #expect(h.model.lookup?.outcomes.map(\.source) == [.libraryOfCongress])
        #expect(h.model.lookupSourcesText == "Library of Congress: 1 match")
    }

    @Test func A8b_withEverySourceOffNothingCanBeLookedUp() async throws {
        let h = try await Harness.demo()
        try await h.select("Salt Road")
        #expect(h.model.canLookUp)
        #expect(h.model.lookUpDisabledReason == nil)
        #expect(h.model.lookUpHelp == "Look this book up online and choose which details to take")

        h.model.lookupSources = []
        #expect(!h.model.canLookUp)
        #expect(h.model.lookUpDisabledReason == "Turn on a lookup source in Settings.")
        #expect(h.model.lookUpHelp == "Turn on a lookup source in Settings.")
        #expect(h.model.lookUpHelp(forEntry: UUID()) == "Turn on a lookup source in Settings.")
        #expect(h.model.lookupSourcesText == "No lookup source is turned on")
        h.model.beginLookup()
        #expect(h.model.lookup == nil)
        #expect(h.lookup.asked.isEmpty)

        // Check Edition still reads what the files say, and asks nobody.
        try await h.select(["Salt Road", "The Clockmaker's Apprentice"])
        await h.model.checkEdition()
        #expect(h.lookup.asked.isEmpty)
        #expect(try h.book(try h.id("The Clockmaker's Apprentice")).editionKind?.kind == .unabridged)

        h.model.setLookupSource(.libraryOfCongress, on: true)
        try await h.select("Salt Road")
        #expect(h.model.canLookUp)
        #expect(h.model.lookUpDisabledReason == nil)
    }

    @Test func A8b_anImportEntryCannotBeLookedUpWithEverySourceOff() async throws {
        let h = try await Harness.empty()
        let inbox = try Harness.inbox()
        await h.model.beginImport([inbox])
        await h.model.settle()
        let entry = try #require(h.model.review?.entries.first)
        #expect(h.model.canLookUpEntry(entry.id))
        h.model.lookupSources = []
        #expect(!h.model.canLookUpEntry(entry.id))
        #expect(h.model.lookUpHelp(forEntry: entry.id) == "Turn on a lookup source in Settings.")
        h.model.beginLookup(forEntry: entry.id)
        #expect(h.model.lookup == nil)
        #expect(h.lookup.asked.isEmpty)
    }

    @Test func A8b_withAudibleOffNoAudibleBookCanBeAdded() async throws {
        let h = try await Harness.demo()
        #expect(h.model.canAddAudibleBook)
        #expect(h.model.addAudibleBookDisabledReason == nil)
        #expect(h.model.addAudibleBookHelp == "Add a book you own on Audible, without its files")

        h.model.setLookupSource(.audible, on: false)
        #expect(!h.model.canAddAudibleBook)
        #expect(h.model.addAudibleBookDisabledReason == "Turn on Audible as a lookup source in Settings.")
        #expect(h.model.addAudibleBookHelp == "Turn on Audible as a lookup source in Settings.")
        h.model.beginAddAudibleBook()
        #expect(h.model.lookup == nil)
        // Look Up still works, with what is left.
        try await h.select("Salt Road")
        #expect(h.model.canLookUp)
        h.model.beginLookup()
        await h.model.settle()
        #expect(h.lookup.asked.map(\.source) == [.openLibrary])
        #expect(h.model.lookupSourcesText == "Open Library: no matches")
    }

    /// A8, A8b, A8c: the privacy sentence names what is on.
    @Test(arguments: [
        ([LookupSource.openLibrary, .audible, .libraryOfCongress],
         "Look Up sends the title, author, narrator, ISBN or Audible ID you search for to Open Library, Audible and the Library of Congress, and downloads cover images from Open Library and Audible. Nothing is sent until you press Look Up. Searches to the Library of Congress are not encrypted."),
        ([.openLibrary, .audible],
         "Look Up sends the title, author, narrator, ISBN or Audible ID you search for to Open Library and Audible, and downloads cover images from Open Library and Audible. Nothing is sent until you press Look Up."),
        ([.audible],
         "Look Up sends the title, author, narrator, ISBN or Audible ID you search for to Audible, and downloads cover images from Audible. Nothing is sent until you press Look Up."),
        ([.openLibrary],
         "Look Up sends the title, author, narrator, ISBN or Audible ID you search for to Open Library, and downloads cover images from Open Library. Nothing is sent until you press Look Up."),
        ([.audible, .libraryOfCongress],
         "Look Up sends the title, author, narrator, ISBN or Audible ID you search for to Audible and the Library of Congress, and downloads cover images from Audible. Nothing is sent until you press Look Up. Searches to the Library of Congress are not encrypted."),
        ([.libraryOfCongress],
         "Look Up sends the title, author, narrator, ISBN or Audible ID you search for to the Library of Congress. Nothing is sent until you press Look Up. Searches to the Library of Congress are not encrypted."),
        ([], "Look Up is off. Turn on a lookup source to use it."),
    ] as [([LookupSource], String)])
    func A8_A8b_A8c_thePrivacySentence(sources: [LookupSource], text: String) throws {
        let h = try Harness(root: try makeTempDir())
        h.model.lookupSources = Set(sources)
        #expect(h.model.lookupPrivacyText == text)
    }

    // MARK: The search, the verdicts and what the rows say

    /// The query carries the narrator; the results are judged against the book.
    @Test func A2_A6_theSearchIsForTheBookAndItsResultsAreJudged() async throws {
        let (h, id) = try await lookedUp()
        let session = try #require(h.model.lookup)
        #expect(session.query == LookupQuery(
            title: "Salt Road", author: "Ines Calloway", narrator: "Marcus Lindqvist", wantsAudioEditions: true))
        #expect(h.lookup.asked.allSatisfy { $0.query == session.query })
        // The stores searched, the user's own first.
        #expect(h.lookup.asked.first { $0.source == .audible }?.stores == [.uk, .us, .au])
        // What the results are compared with: the files' measured length.
        #expect(session.audioSeconds == (try h.book(id).durationSeconds))
        #expect(session.audioSeconds != nil)

        // A6: the book's own edition is first and says so; the other is marked different, with why.
        #expect(session.candidates.map(\.id) == [saltRoadCassette().id, saltRoadReread().id])
        #expect(session.selectedId == saltRoadCassette().id)
        #expect(h.model.lookupBadgeText(for: saltRoadCassette()) == "Your edition")
        #expect(h.model.lookupBadgeHelp(for: saltRoadCassette()) == nil)
        #expect(h.model.lookupBadgeText(for: saltRoadReread()) == "Different edition")
        #expect(h.model.lookupBadgeHelp(for: saltRoadReread()) == "Read by Someone Else, not Marcus Lindqvist")
        // A6: the stores that list it, when more than the user's own.
        #expect(h.model.lookupStoresText(for: saltRoadReread()) == "UK, US, Australia")
        #expect(h.model.lookupStoresText(for: saltRoadReread(stores: ["uk"])) == nil)
        #expect(h.model.lookupStoresText(for: saltRoadCassette()) == nil)

        // A2: the book's own edition has its first ticks; the different one has none, and says why.
        #expect(session.tickedFields(on: saltRoadCassette().id) == [.publisher])
        h.model.cancelLookup()
        #expect(h.model.lookupBadgeText(for: saltRoadCassette()) == nil)
    }

    @Test func A2_nothingOfADifferentEditionIsTicked() async throws {
        let (h, _) = try await lookedUp()
        await h.model.selectLookupCandidate(saltRoadReread().id)
        let session = try #require(h.model.lookup)
        #expect(session.offers.map(\.id) == [.narrators, .year, .publisher, .summary, .asin, .cover])
        #expect(session.offers.allSatisfy { !$0.ticked })
        for offer in session.offers {
            let belongsToTheEdition = offer.id != .summary && offer.id != .cover
            #expect(offer.reason == (belongsToTheEdition ? "Different edition: read by Someone Else, not Marcus Lindqvist" : nil))
        }
    }

    @Test func A7_theSheetSaysTheNarratorWasNotFound() async throws {
        let h = try await Harness.demo()
        h.model.audibleStore = .uk
        h.lookup.find(.audible, [saltRoadReread()])
        h.lookup.narratorNotFound(.audible, "Marcus Lindqvist")
        try await h.select("Salt Road")
        h.model.beginLookup()
        #expect(h.model.lookupNarratorFallbackText == nil)
        await h.model.settle()
        #expect(h.model.lookupNarratorFallbackText == "Audible: nothing read by Marcus Lindqvist; showing other editions.")
        #expect(h.model.lookupSourcesText
            == "Open Library: no matches · Audible (UK, US, Australia): nothing read by Marcus Lindqvist; showing other editions")

        // Nothing found the second time either: just no matches.
        h.lookup.find(.audible, [])
        h.model.updateLookupQuery { $0.author = "" }
        await h.model.searchLookup()
        #expect(h.model.lookupNarratorFallbackText == nil)
        #expect(h.model.lookupSourcesText == "Open Library: no matches · Audible (UK, US, Australia): no matches")

        // The narrator was found: nothing to say.
        h.lookup.find(.audible, [saltRoadReread()])
        h.lookup.narratorNotFound(.audible, nil)
        h.model.updateLookupQuery { $0.author = "Ines Calloway" }
        await h.model.searchLookup()
        #expect(h.model.lookupNarratorFallbackText == nil)
        #expect(h.model.lookupSourcesText == "Open Library: no matches · Audible (UK, US, Australia): 1 match")
        h.model.cancelLookup()
        #expect(h.model.lookupNarratorFallbackText == nil)
    }

    // MARK: A1, A3, A4, A5 taking from several results

    @Test func A1toA5_fieldsFromSeveralResultsAreAppliedAndSavedAsOne() async throws {
        let (h, id) = try await lookedUp()
        h.lookup.cover(png)
        let before = try h.book(id)
        #expect(h.model.lookupApplySummary == "Publisher and edition from Library of Congress")

        // A1: the other result's own ticks; what is ticked on the first stays.
        await h.model.selectLookupCandidate(saltRoadReread().id)
        h.model.setLookupTicked(true, for: .summary)
        h.model.setLookupTicked(true, for: .cover)
        #expect(h.model.lookup?.tickedFields(on: saltRoadCassette().id) == [.publisher])
        #expect(h.model.lookup?.tickedFields(on: saltRoadReread().id) == [.summary, .cover])
        // A4
        #expect(h.model.lookupApplySummary == "Publisher and edition from Library of Congress; description and cover from Audible")

        // A3: the year from one, then from the other.
        h.model.setLookupTicked(true, for: .year)
        #expect(h.model.lookup?.tickedFields(on: saltRoadReread().id) == [.year, .summary, .cover])
        await h.model.selectLookupCandidate(saltRoadCassette().id)
        h.model.setLookupTicked(true, for: .year)
        #expect(h.model.lookup?.tickedFields(on: saltRoadCassette().id) == [.year, .publisher])
        #expect(h.model.lookup?.tickedFields(on: saltRoadReread().id) == [.summary, .cover])
        #expect(h.model.lookupApplySummary
            == "Year, publisher and edition from Library of Congress; description and cover from Audible")
        // A10: nothing has been written yet.
        #expect(try h.book(id) == before)
        #expect(h.draft?.isDirty == false)

        // A5: one Apply takes all of it, and saves as before.
        await h.model.applyLookup()
        #expect(h.model.lookup == nil)
        #expect(h.model.alert == nil)
        let saved = try h.book(id)
        var expected = before.metadata
        expected.year = 1999
        expected.publisher = "Recorded Tides"
        expected.summary = "A road, and salt."
        #expect(saved.metadata == expected)
        // The narrator, the length and everything unticked are the book's own.
        #expect(saved.narrators == ["Marcus Lindqvist"])
        #expect(saved.durationSeconds == before.durationSeconds)
        #expect(saved.asin == nil)
        // The cover is the one of the result whose cover was ticked.
        #expect(h.lookup.coverURLs == [try #require(saltRoadReread().coverURL)])
        #expect(try savedCover(h, id) == png)
        // K3: the edition of the book's own result, as it was found (not by hand).
        #expect(saved.editionKind == EditionKindNote(
            kind: .unabridged, basis: .matched("Library of Congress"), reason: "Library of Congress lists your edition as unabridged."))
        #expect(!h.model.editionKindIsAppOnly)
        #expect(!h.model.hasUnsavedChanges)

        // One operation, undone whole.
        #expect(h.model.undoLabel == "Edit Salt Road")
        await h.model.undo()
        #expect(try h.book(id) == before)
    }

    /// K3: the edition alone can be applied; unticked, it is left alone.
    @Test func K3_theEditionOfferIsAppliedWithTheRest() async throws {
        let (h, id) = try await lookedUp()
        #expect(h.model.lookup?.editionOffer?.found == "Unabridged")
        #expect(h.model.lookup?.editionOffer?.ticked == true)
        h.model.setLookupEditionTicked(false)
        #expect(h.model.lookup?.editionOffer?.ticked == false)
        await h.model.applyLookup()
        #expect(try h.book(id).publisher == "Recorded Tides")
        #expect(try h.book(id).editionKind == nil)

        // Again, and now only the edition.
        h.model.beginLookup()
        await h.model.settle()
        #expect(h.model.lookup?.tickedFields.isEmpty == true)
        #expect(h.model.lookup?.canApply == true)
        #expect(h.model.lookupApplySummary == "Edition from Library of Congress")
        await h.model.applyLookup()
        #expect(try h.book(id).editionKind?.basis == .matched("Library of Congress"))
        #expect(h.model.rows.first { $0.id == id }?.editionLabel == nil)

        // A kind set by hand is what the book has: the offer is there, unticked.
        h.model.setEditionKind(.abridged)
        await h.model.save()
        h.model.beginLookup()
        await h.model.settle()
        #expect(h.model.lookup?.editionOffer?.current == "Abridged")
        #expect(h.model.lookup?.editionOffer?.ticked == false)
        #expect(h.model.lookup?.canApply == false)
    }

    /// A10: selecting, ticking and cancelling write nothing.
    @Test func A10_nothingIsWrittenBeforeApply() async throws {
        let (h, id) = try await lookedUp()
        let before = try h.book(id)
        let undoBefore = h.model.undoLabel
        await h.model.selectLookupCandidate(saltRoadReread().id)
        for field in MetadataField.allCases { h.model.setLookupTicked(true, for: field) }
        h.model.setLookupEditionTicked(true)
        await h.model.selectLookupCandidate(saltRoadCassette().id)
        #expect(try h.book(id) == before)
        #expect(h.draft?.isDirty == false)
        #expect(h.lookup.coverURLs.isEmpty)
        h.model.cancelLookup()
        #expect(try h.book(id) == before)
        #expect(h.draft?.isDirty == false)
        #expect(h.model.undoLabel == undoBefore)
        #expect(h.model.lookupApplySummary == nil)
    }

    /// A10: an answer that arrives after the sources were changed is for the lookup as it was.
    @Test func A10_changingTheSourcesLetsTheSameSearchBeMadeAgain() async throws {
        let (h, _) = try await lookedUp()
        #expect(h.model.lookup?.canSearch == false)
        h.model.setLookupSource(.openLibrary, on: false)
        #expect(h.model.lookup?.canSearch == true)
        #expect(h.model.lookupSourcesText == "Results from Audible (UK, US, Australia) and Library of Congress")
        let asked = h.lookup.asked.count
        await h.model.searchLookup()
        #expect(h.lookup.asked.dropFirst(asked).map(\.source).sorted { $0.rawValue < $1.rawValue } == [.audible, .libraryOfCongress])
        #expect(h.model.lookupSourcesText == "Audible (UK, US, Australia): 1 match · Library of Congress: 1 match")
    }

    // MARK: A9 adding an Audible book

    @Test func A9_addingAsksOnlyAudibleAcrossTheStoresAndKeepsTheStoreOfTheChosenASIN() async throws {
        let h = try await Harness.demo()
        h.model.audibleStore = .uk
        h.model.setLookupSource(.libraryOfCongress, on: true)
        // Only the Australian and American stores list this one.
        var found = foundBook(.audible, "au:B0GLASSTID", title: "The Glass Tide", authors: ["Ines Calloway"]) {
            $0.narrators = ["Marcus Lindqvist"]
            $0.asin = "B0GLASSTID"
        }
        found.edition = EditionFacts(format: .digital, abridged: false, stores: ["au", "us"])
        h.lookup.find(.audible, [found])
        h.lookup.find(.openLibrary, [foundBook(.openLibrary, "/works/OL9W", title: "The Glass Tide")])
        h.lookup.find(.libraryOfCongress, [saltRoadCassette()])

        h.model.beginAddAudibleBook()
        #expect(h.model.lookupSourcesText == "Results from Audible (UK, US, Australia)")
        h.model.updateLookupQuery { $0.title = "The Glass Tide" }
        await h.model.searchLookup()
        // Audible alone, in every store chosen.
        #expect(h.lookup.asked.map(\.source) == [.audible])
        #expect(h.lookup.asked.first?.stores == [.uk, .us, .au])
        #expect(h.lookup.asked.first?.query == LookupQuery(title: "The Glass Tide"))
        #expect(h.model.lookup?.candidates == [found])
        // No book to compare with: no badge, but the stores are said.
        #expect(h.model.lookupBadgeText(for: found) == nil)
        #expect(h.model.lookupStoresText(for: found) == "Australia, US")

        await h.model.addLookupSelection()
        let added = try #require(try h.store().books().first { $0.title == "The Glass Tide" })
        #expect(added.externalCopies == [ExternalCopy(kind: .audible, form: .audio, store: "au", itemId: "B0GLASSTID")])
        #expect(added.asin == "B0GLASSTID")
    }

    @Test func A9_aBookAddedByHandIsInTheUsersOwnStore() async throws {
        let h = try await Harness.demo()
        h.model.audibleStore = .de
        h.model.beginAddAudibleBook()
        h.model.updateLookupQuery {
            $0.title = "Typed by Hand"
            $0.author = "An Author"
        }
        await h.model.searchLookup()
        await h.model.addAudibleBookByHand()
        let added = try #require(try h.store().books().first { $0.title == "Typed by Hand" })
        #expect(added.externalCopies == [ExternalCopy(kind: .audible, form: .audio, store: "de", itemId: nil)])
    }

    // MARK: The book's length, for comparing

    @Test func aLengthIsComparedOnlyWhenTheFilesWereMeasured() async throws {
        let h = try await Harness.demo()
        let row = try #require(h.model.rows.first { $0.book.title == "Salt Road" })
        #expect(row.measuredAudioSeconds == row.book.durationSeconds)
        #expect(row.unmeasuredLengthFiles == 0)
        var unmeasured = row
        unmeasured.unmeasuredLengthFiles = 1
        #expect(unmeasured.measuredAudioSeconds == nil)
        // A book with no audio file here has no measured length, whatever its catalogue length.
        var external = row
        external.formats = []
        #expect(external.measuredAudioSeconds == nil)
        var ebook = try #require(h.model.rows.first { $0.book.title == "Quiet Rivers" })
        ebook.book.durationSeconds = 3600
        #expect(ebook.measuredAudioSeconds == nil)
    }
}
