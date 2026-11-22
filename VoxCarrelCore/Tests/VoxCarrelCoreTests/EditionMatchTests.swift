import Foundation
import Testing
@testable import VoxCarrelCore

private func result(
    _ source: LookupSource = .audible, _ key: String = "us:B000000001", title: String = "A Perfect Spy",
    authors: [String] = ["John le Carré"], narrators: [String] = [], hours: Double? = nil, abridged: Bool? = nil
) -> LookupCandidate {
    var metadata = BookMetadata(title: title, authors: authors)
    metadata.narrators = narrators
    metadata.durationSeconds = hours.map { $0 * 3600 }
    return LookupCandidate(
        id: "\(source.rawValue):\(key)", source: source, metadata: metadata, note: source.title,
        edition: EditionFacts(abridged: abridged))
}

private func book(narrators: [String] = []) -> BookMetadata {
    var metadata = BookMetadata(title: "A Perfect Spy", authors: ["John le Carré"])
    metadata.narrators = narrators
    return metadata
}

private func verdict(
    _ candidate: LookupCandidate, narrators: [String] = [], hours: Double? = nil, abridged: Bool? = nil
) -> EditionVerdict {
    EditionMatch.verdict(
        candidate: candidate, book: book(narrators: narrators), bookSeconds: hours.map { $0 * 3600 },
        bookIsAbridged: abridged)
}

@Suite struct EditionMatchTests {
    // MARK: M1 narrators

    @Test func M1_noNarratorInCommonIsADifferentEdition() {
        #expect(verdict(result(narrators: ["Rory Kinnear"]), narrators: ["Frank Muller"])
            == .differentEdition(reasons: ["read by Rory Kinnear, not Frank Muller"]))
        #expect(verdict(result(narrators: ["Harriet Walter", "James Fox"]), narrators: ["Frank Muller", "Someone Else"])
            == .differentEdition(reasons: ["read by Harriet Walter and James Fox, not Frank Muller and Someone Else"]))
        #expect(verdict(result(narrators: ["A One", "B Two", "C Three"]), narrators: ["Frank Muller"])
            == .differentEdition(reasons: ["read by A One, B Two and C Three, not Frank Muller"]))
        #expect(verdict(result(narrators: ["A One", "B Two", "C Three", "D Four", "E Five"]), narrators: ["Frank Muller"])
            == .differentEdition(reasons: ["read by A One, B Two and 3 others, not Frank Muller"]))
    }

    @Test func M1_oneNameInCommonIsEnough() {
        #expect(verdict(result(narrators: ["Someone Else", "Muller, Frank,"]), narrators: ["frank muller"], hours: 18) == .sameEdition)
        #expect(verdict(result(narrators: ["Frank Muller"]), narrators: ["Other Reader", "Frank Muller"], hours: 18) == .sameEdition)
    }

    @Test func M1_aSideWithNoNarratorsSaysNothing() {
        #expect(verdict(result(narrators: []), narrators: ["Frank Muller"]) == .unknown)
        #expect(verdict(result(narrators: ["Rory Kinnear"]), narrators: []) == .unknown)
        #expect(verdict(result(narrators: ["  "]), narrators: ["Frank Muller"]) == .unknown)
    }

    /// "Full Cast", in any case, is not a person: it neither matches nor contradicts.
    @Test(arguments: ["Full Cast", "full cast", "FULL CAST", "Full cast", " Full  Cast "])
    func M1_fullCastIsNobody(credit: String) {
        #expect(EditionMatch.isFullCast(credit))
        // Only a full cast on one side: nothing to compare.
        #expect(verdict(result(narrators: [credit]), narrators: ["Frank Muller"]) == .unknown)
        #expect(verdict(result(narrators: ["Frank Muller"]), narrators: [credit]) == .unknown)
        // "Full Cast" on both sides is not a name in common.
        #expect(verdict(result(narrators: [credit, "Harriet Walter"]), narrators: ["Full Cast", "Frank Muller"])
            == .differentEdition(reasons: ["read by Harriet Walter, not Frank Muller"]))
        #expect(verdict(result(narrators: [credit]), narrators: [credit]) == .unknown)
        // And it is not named in the reason.
        #expect(verdict(result(narrators: [credit, "Harriet Walter", "James Fox"]), narrators: ["Frank Muller"])
            == .differentEdition(reasons: ["read by Harriet Walter and James Fox, not Frank Muller"]))
    }

    @Test func M1_aCastThatIsNotFullIsAName() {
        #expect(!EditionMatch.isFullCast("Full Cast Audio"))
        #expect(!EditionMatch.isFullCast("Cast"))
        #expect(!EditionMatch.isFullCast(""))
    }

    // MARK: M2 length

    @Test func M2_aLengthFarFromTheBooksIsADifferentEdition() {
        #expect(verdict(result(hours: 237.0 / 60), hours: 18) == .differentEdition(reasons: ["3h 57m; yours is 18h 0m"]))
        #expect(verdict(result(hours: 36), hours: 18) == .differentEdition(reasons: ["36h 0m; yours is 18h 0m"]))
    }

    /// More than 5% and more than ten minutes: both, not either.
    @Test func M2_bothTheShareAndTheMinutesMustBePassed() {
        // 18 hours: 5% is 54 minutes.
        #expect(verdict(result(hours: 18 + 54.0 / 60), hours: 18) == .sameEdition)
        #expect(verdict(result(hours: 18 + 55.0 / 60), hours: 18) == .differentEdition(reasons: ["18h 55m; yours is 18h 0m"]))
        #expect(verdict(result(hours: 18 - 55.0 / 60), hours: 18) == .differentEdition(reasons: ["17h 5m; yours is 18h 0m"]))
        // A short book: 20% away, but only six minutes.
        #expect(verdict(result(hours: 0.6), hours: 0.5) == .sameEdition)
        #expect(verdict(result(hours: 0.5 + 10.0 / 60), hours: 0.5) == .sameEdition)
        #expect(verdict(result(hours: 0.5 + 11.0 / 60), hours: 0.5) == .differentEdition(reasons: ["41m; yours is 30m"]))
        // A very long one: half an hour away, but under 5%.
        #expect(verdict(result(hours: 40.5), hours: 40) == .sameEdition)
    }

    @Test func M2_aLengthThatIsNotKnownSaysNothing() {
        #expect(verdict(result(hours: 4), hours: nil) == .unknown)
        #expect(verdict(result(hours: nil), hours: 18) == .unknown)
        #expect(verdict(result(hours: 0), hours: 18) == .unknown)
        #expect(verdict(result(hours: 4), hours: 0) == .unknown)
        #expect(verdict(result(hours: -1), hours: .infinity) == .unknown)
    }

    // MARK: M3 abridged

    @Test func M3_abridgedAgainstUnabridgedIsADifferentEdition() {
        #expect(verdict(result(abridged: true), abridged: false) == .differentEdition(reasons: ["abridged; yours is unabridged"]))
        #expect(verdict(result(abridged: false), abridged: true) == .differentEdition(reasons: ["unabridged; yours is abridged"]))
    }

    @Test func M3_unknownOnEitherSideSaysNothing() {
        #expect(verdict(result(abridged: nil), abridged: true) == .unknown)
        #expect(verdict(result(abridged: true), abridged: nil) == .unknown)
        // Agreeing is no contradiction, and on its own no proof either.
        #expect(verdict(result(abridged: true), abridged: true) == .unknown)
        #expect(verdict(result(abridged: false), abridged: false) == .unknown)
    }

    // MARK: M4

    @Test func M4_sameEditionNeedsAMatchAndNoContradiction() {
        #expect(verdict(result(narrators: ["Frank Muller"], hours: 18, abridged: false), narrators: ["Frank Muller"], hours: 18, abridged: false)
            == .sameEdition)
        // The same reader, of the very same title, when the book's own length is known
        // and the result gives none.
        #expect(verdict(result(narrators: ["Frank Muller"]), narrators: ["Frank Muller"], hours: 18) == .sameEdition)
        // A book whose length is not known: the reader alone does not say which of
        // their recordings it is.
        #expect(verdict(result(narrators: ["Frank Muller"]), narrators: ["Frank Muller"]) == .unknown)
        #expect(verdict(result(hours: 18.1), hours: 18) == .sameEdition)
        // Nothing to go on.
        #expect(verdict(result()) == .unknown)
        #expect(verdict(result(narrators: ["Frank Muller"], hours: 18)) == .unknown)
    }

    // MARK: The same work

    @Test(arguments: [
        ("Dune", "Dune", EditionMatch.TitleRelation.same),
        ("The Dune", "dune", .same),
        ("Dune", "Dune: Deluxe Edition", .withSubtitle),
        ("Dune (Unabridged)", "Dune", .withSubtitle),
        ("Dune - Book One", "Dune", .withSubtitle),
        ("Dune: A Novel", "Dune (Unabridged)", .withSubtitle),
        ("Dune", "Dune Messiah", .different),
        ("Dune Messiah", "Dune", .different),
        ("The Hobbit", "The Hobbit and The Lord of the Rings", .different),
        ("Dune", "Dune Messiah: Book Two", .different),
        ("Dune", "Emma", .different),
        ("", "Dune", .same),
    ])
    func titlesOfTheSameWork(first: String, second: String, relation: EditionMatch.TitleRelation) {
        #expect(EditionMatch.titleRelation(first, second) == relation)
        #expect(EditionMatch.titleRelation(second, first) == relation)
    }

    private func dune(_ title: String, narrators: [String] = ["Scott Brick"], hours: Double? = nil, abridged: Bool? = nil) -> LookupCandidate {
        var metadata = BookMetadata(title: title, authors: ["Herbert, Frank"])
        metadata.narrators = narrators
        metadata.durationSeconds = hours.map { $0 * 3600 }
        return LookupCandidate(
            id: "libraryOfCongress:\(title)\(hours ?? 0)\(String(describing: abridged))", source: .libraryOfCongress, metadata: metadata,
            edition: EditionFacts(abridged: abridged))
    }

    private var duneBook: BookMetadata {
        var book = BookMetadata(title: "Dune", authors: ["Frank Herbert"])
        book.narrators = ["Scott Brick"]
        return book
    }

    /// A sequel read by the same reader is not the book's edition, and says nothing of
    /// the book's kind.
    @Test func aSequelByTheSameReaderIsNotTheBooksEdition() {
        let sequel = dune("Dune Messiah", abridged: true)
        #expect(EditionMatch.verdict(candidate: sequel, book: duneBook, bookSeconds: 21 * 3600, bookIsAbridged: nil) == .unknown)
        #expect(EditionKindGuess.assess([sequel], book: duneBook, bookSeconds: 21 * 3600) == EditionKindAssessment())
        // Nor one of the same length.
        let long = dune("Dune Messiah", hours: 21, abridged: true)
        #expect(EditionMatch.verdict(candidate: long, book: duneBook, bookSeconds: 21 * 3600, bookIsAbridged: nil) == .unknown)
        #expect(EditionKindGuess.assess([long], book: duneBook, bookSeconds: 21 * 3600).note == nil)
    }

    @Test func aBoxSetIsNotTheBooksEdition() {
        var book = BookMetadata(title: "The Hobbit", authors: ["J. R. R. Tolkien"])
        book.narrators = ["Rob Inglis"]
        var set = BookMetadata(title: "The Hobbit and The Lord of the Rings", authors: ["JRR Tolkien"])
        set.narrators = ["Rob Inglis"]
        let candidate = LookupCandidate(id: "audible:uk:B0BOXSET00", source: .audible, metadata: set, edition: EditionFacts(abridged: false))
        #expect(EditionMatch.verdict(candidate: candidate, book: book, bookSeconds: 11 * 3600, bookIsAbridged: nil) == .unknown)
        #expect(EditionMatch.verdict(candidate: candidate, book: book, bookSeconds: nil, bookIsAbridged: nil) == .unknown)
        #expect(EditionKindGuess.assess([candidate], book: book, bookSeconds: 11 * 3600).note == nil)
    }

    /// A book whose length is not known, and an abridged and an unabridged recording
    /// by its reader: neither is known to be the book's, and neither gives it a kind.
    @Test func anUnmeasuredBookIsNotMatchedByItsReaderAlone() {
        let whole = dune("Dune", hours: 21, abridged: false), cut = dune("Dune", hours: 6, abridged: true)
        let unsaid = dune("Dune", abridged: true)
        for candidate in [whole, cut, unsaid] {
            #expect(EditionMatch.verdict(candidate: candidate, book: duneBook, bookSeconds: nil, bookIsAbridged: nil) == .unknown)
        }
        #expect(EditionKindGuess.assess([cut, whole, unsaid], book: duneBook, bookSeconds: nil) == EditionKindAssessment())
        // Measured, the length says which; a result with no length gives no kind.
        #expect(EditionKindGuess.assess([cut, whole], book: duneBook, bookSeconds: 21 * 3600).note
            == EditionKindNote(kind: .unabridged, basis: .matched("Library of Congress"), reason: "Library of Congress lists your edition as unabridged."))
        #expect(EditionMatch.verdict(candidate: unsaid, book: duneBook, bookSeconds: 21 * 3600, bookIsAbridged: nil) == .sameEdition)
        #expect(EditionKindGuess.assess([unsaid], book: duneBook, bookSeconds: 21 * 3600).note == nil)
    }

    // MARK: A catalogue's round figure

    /// "18 hr." in a catalogue is compared more loosely: 10% and 45 minutes.
    @Test func aNominalLengthIsComparedLoosely() {
        func nominal(_ hours: Double) -> LookupCandidate {
            var candidate = result(.libraryOfCongress, "1", hours: hours)
            candidate.edition.lengthIsNominal = true
            return candidate
        }
        // 58 minutes short of "18 hr.": the same for a catalogue's figure, different for a measured one.
        let own = 17.0 + 2.0 / 60
        #expect(verdict(nominal(18), hours: own) == .sameEdition)
        #expect(verdict(result(hours: 18), hours: own).isDifferent)
        // Past a tenth and past 45 minutes, it is another edition.
        #expect(verdict(nominal(18), hours: 16).isDifferent)
        #expect(verdict(nominal(18), hours: 20.5).isDifferent)
        // A short book: within 45 minutes, though more than a tenth.
        #expect(verdict(nominal(3), hours: 2.4) == .sameEdition)
        #expect(verdict(nominal(3), hours: 2) .isDifferent)
    }

    /// One contradiction outweighs any match, and every reason is given, in the order
    /// narrators, length, abridged.
    @Test func M4_anyContradictionMakesItDifferent() {
        #expect(verdict(result(narrators: ["Frank Muller"], hours: 4), narrators: ["Frank Muller"], hours: 18)
            == .differentEdition(reasons: ["4h 0m; yours is 18h 0m"]))
        #expect(verdict(result(narrators: ["Rory Kinnear"], hours: 18), narrators: ["Frank Muller"], hours: 18)
            == .differentEdition(reasons: ["read by Rory Kinnear, not Frank Muller"]))
        #expect(verdict(result(narrators: ["Frank Muller"], hours: 18, abridged: true), narrators: ["Frank Muller"], hours: 18, abridged: false)
            == .differentEdition(reasons: ["abridged; yours is unabridged"]))
        #expect(verdict(result(narrators: ["Rory Kinnear"], hours: 3, abridged: true), narrators: ["Frank Muller"], hours: 18, abridged: false)
            == .differentEdition(reasons: ["read by Rory Kinnear, not Frank Muller", "3h 0m; yours is 18h 0m", "abridged; yours is unabridged"]))
    }

    /// A reader or a length in common does not make another book the user's edition.
    @Test func M4_anotherBookIsNeverTheSameEdition() {
        let muller = ["Frank Muller"]
        #expect(verdict(result(title: "Moby-Dick", authors: ["Herman Melville"], narrators: muller, hours: 18), narrators: muller, hours: 18) == .unknown)
        #expect(verdict(result(title: "Smiley’s People", narrators: muller), narrators: muller) == .unknown)
        #expect(verdict(result(authors: ["Someone Else"], hours: 18), hours: 18) == .unknown)
        // A fuller or shorter form of the title, and a name written another way, are the same book.
        #expect(verdict(result(title: "A Perfect Spy: A Novel", narrators: muller, hours: 18), narrators: muller, hours: 18) == .sameEdition)
        // With a subtitle, the reader alone is not enough.
        #expect(verdict(result(title: "A Perfect Spy: A Novel", narrators: muller), narrators: muller, hours: 18) == .unknown)
        #expect(verdict(result(title: "Perfect Spy", authors: ["Le Carré, John, 1931-2020"], hours: 18), hours: 18) == .sameEdition)
        #expect(verdict(result(authors: [], hours: 18), hours: 18) == .sameEdition)
        #expect(verdict(result(authors: ["A Translator", "John Le Carre"], hours: 18), hours: 18) == .sameEdition)
        // A contradiction is still a contradiction.
        #expect(verdict(result(title: "Moby-Dick", narrators: ["Rory Kinnear"]), narrators: muller).isDifferent)
    }

    @Test func M4_theVerdictForABookContextIsTheSame() {
        let candidate = result(narrators: ["Rory Kinnear"], hours: 20, abridged: true)
        let context = LookupBookContext(metadata: book(narrators: ["Frank Muller"]), audioSeconds: 18 * 3600, isAbridged: false)
        #expect(EditionMatch.verdict(candidate: candidate, book: context)
            == EditionMatch.verdict(candidate: candidate, book: context.metadata, bookSeconds: 18 * 3600, bookIsAbridged: false))
        #expect(EditionVerdict.differentEdition(reasons: ["a", "b"]).reasons == ["a", "b"])
        #expect(EditionVerdict.differentEdition(reasons: []).isDifferent)
        #expect(EditionVerdict.sameEdition.reasons.isEmpty)
        #expect(!EditionVerdict.unknown.isDifferent)
    }
}

private struct ListProvider: LookupProvider {
    var source: LookupSource
    var candidates: [LookupCandidate]
    var narratorNotFound: String?

    func search(_ query: LookupQuery) async throws -> [LookupCandidate] { candidates }

    func answer(to query: LookupQuery) async throws -> LookupAnswer {
        LookupAnswer(candidates: candidates, narratorNotFound: narratorNotFound)
    }
}

@Suite struct EditionRankingTests {
    private let query = LookupQuery(title: "A Perfect Spy", author: "John le Carré", narrator: "Frank Muller", wantsAudioEditions: true)
    private let muller = LookupBookContext(
        metadata: book(narrators: ["Frank Muller"]), audioSeconds: 18 * 3600, isAbridged: nil)
    private let unusedHTTP = FakeHTTP(throwing: LookupError.notReachable)

    // MARK: M5 ranking

    @Test func M5_sameEditionThenUnknownThenDifferent() async throws {
        let audible = ListProvider(source: .audible, candidates: [
            result(.audible, "uk:B0DIFFERENT", narrators: ["Rory Kinnear"], hours: 20),
            result(.audible, "uk:B0UNKNOWN01"),
            result(.audible, "uk:B0SAMESAME1", narrators: ["Frank Muller"], hours: 18),
        ])
        let open = ListProvider(source: .openLibrary, candidates: [result(.openLibrary, "/works/OL1W")])
        let service = LookupService(providers: [audible, open], http: unusedHTTP)

        let results = await service.search(query, preferAudio: true, language: "en", book: muller)
        // The book's edition first; then what cannot be told, the preferred kind of
        // source first as before; the plainly different edition last.
        #expect(results.candidates.map(\.id) == [
            "audible:uk:B0SAMESAME1", "audible:uk:B0UNKNOWN01", "openLibrary:/works/OL1W", "audible:uk:B0DIFFERENT",
        ])
        #expect(results.verdicts == [
            "audible:uk:B0SAMESAME1": .sameEdition, "audible:uk:B0UNKNOWN01": .unknown, "openLibrary:/works/OL1W": .unknown,
            "audible:uk:B0DIFFERENT": .differentEdition(reasons: ["read by Rory Kinnear, not Frank Muller", "20h 0m; yours is 18h 0m"]),
        ])
    }

    /// The edition only orders results that match about as well: it never lifts a
    /// worse match over a better one.
    @Test func M5_editionOrdersOnlyWithinAScoreBand() async throws {
        let audible = ListProvider(source: .audible, candidates: [
            result(.audible, "uk:B0OTHERBOOK", title: "A Perfect Spy and Other Stories", narrators: ["Frank Muller"], hours: 18),
            result(.audible, "uk:B0DIFFERENT", narrators: ["Rory Kinnear"]),
        ])
        let results = await LookupService(providers: [audible], http: unusedHTTP)
            .search(query, preferAudio: true, language: nil, book: muller)
        #expect(results.candidates.map(\.id) == ["audible:uk:B0DIFFERENT", "audible:uk:B0OTHERBOOK"])
        // A title that goes on with more words is another book, whatever else agrees.
        #expect(results.verdicts["audible:uk:B0OTHERBOOK"] == .unknown)
    }

    /// The query's own ASIN still leads; among those, the edition orders.
    @Test func M5_theQuerysOwnASINStillLeads() async throws {
        var asked = query
        asked.asin = "B0DIFFERENT"
        var different = result(.audible, "uk:B0DIFFERENT", narrators: ["Rory Kinnear"])
        different.metadata.asin = "B0DIFFERENT"
        let audible = ListProvider(source: .audible, candidates: [
            result(.audible, "uk:B0SAMESAME1", narrators: ["Frank Muller"]), different,
        ])
        let results = await LookupService(providers: [audible], http: unusedHTTP)
            .search(asked, preferAudio: true, language: nil, book: muller)
        #expect(results.candidates.map(\.id) == ["audible:uk:B0DIFFERENT", "audible:uk:B0SAMESAME1"])
    }

    /// M5: with no book, nothing is judged and the order is as it always was.
    @Test func M5_withoutABookRankingIsAsBefore() async throws {
        let candidates = [
            result(.audible, "uk:B0DIFFERENT", narrators: ["Rory Kinnear"], hours: 20),
            result(.audible, "uk:B0UNKNOWN01"),
            result(.audible, "uk:B0SAMESAME1", narrators: ["Frank Muller"], hours: 18),
        ]
        let open = ListProvider(source: .openLibrary, candidates: [result(.openLibrary, "/works/OL1W")])
        let service = LookupService(providers: [ListProvider(source: .audible, candidates: candidates), open], http: unusedHTTP)
        for results in [
            await service.search(query, preferAudio: true, language: "en"),
            await service.search(query, preferAudio: true, language: "en", book: nil),
        ] {
            #expect(results.candidates.map(\.id) == candidates.map(\.id) + ["openLibrary:/works/OL1W"])
            #expect(results.verdicts.isEmpty)
        }
        #expect(LookupService.ranked(candidates, query: query, preferAudio: true, language: "en")
            == LookupService.ranked(candidates, query: query, preferAudio: true, language: "en", verdicts: [:]))
    }

    // MARK: M5 the standard set

    @Test func M5_theStandardSetIsOpenLibraryAudibleStoresAndTheLibraryOfCongress() {
        let all = LookupService.standard(LookupConfiguration(sources: Set(LookupSource.allCases), audibleStores: [.uk, .us, .au]))
        #expect(all.sources == [.openLibrary, .audible, .libraryOfCongress])
        #expect(all.providers[0] is OpenLibraryProvider)
        #expect(all.providers[1] is AudibleStoresProvider)
        #expect(all.providers[2] is LibraryOfCongressProvider)
    }

    /// A source that is off has no provider, and its host is never asked.
    @Test(arguments: [
        ([LookupSource.openLibrary, .audible], ["openlibrary.org", "api.audible.co.uk", "api.audible.com"]),
        ([.audible], ["api.audible.co.uk", "api.audible.com"]),
        ([.openLibrary], ["openlibrary.org"]),
        ([.libraryOfCongress], ["lx2.loc.gov"]),
        ([.openLibrary, .audible, .libraryOfCongress], ["openlibrary.org", "api.audible.co.uk", "api.audible.com", "lx2.loc.gov"]),
        ([], []),
    ] as [([LookupSource], [String])])
    func M5_onlyTheSourcesThatAreOnAreBuiltAndAsked(sources: [LookupSource], hosts: [String]) async throws {
        let http = FakeHTTP { url in
            switch url.host {
            case "lx2.loc.gov": (fixture("loc-none", type: "xml"), 200)
            case "openlibrary.org": (fixture("ol-none"), 200)
            default: (fixture("au-none"), 200)
            }
        }
        let service = LookupService.standard(
            LookupConfiguration(sources: Set(sources), audibleStores: [.uk, .us, .uk]), http: http)
        #expect(Set(service.sources) == Set(sources))
        let results = await service.search(query, preferAudio: true, language: "en", book: muller)
        #expect(Set(results.searched) == Set(sources))
        #expect(Set(http.urls.compactMap(\.host)) == Set(hosts))
    }

    @Test func M5_audibleWithNoStoreIsNotBuilt() {
        let service = LookupService.standard(
            LookupConfiguration(sources: [.audible, .openLibrary], audibleStores: []), http: unusedHTTP)
        #expect(service.sources == [.openLibrary])
        #expect(LookupConfiguration(sources: [], audibleStores: [.uk, .us, .uk, .au, .us]).audibleStores == [.uk, .us, .au])
    }

    // MARK: M6

    @Test func M6_foundCountsEverySourceTheLibraryOfCongressIncluded() async throws {
        let service = LookupService(providers: [
            ListProvider(source: .openLibrary, candidates: []),
            ListProvider(source: .audible, candidates: [result(.audible, "uk:B000000001"), result(.audible, "uk:B000000002")]),
            ListProvider(source: .libraryOfCongress, candidates: [result(.libraryOfCongress, "5615214")]),
        ], http: unusedHTTP)
        let results = await service.search(query, preferAudio: true, language: nil, book: muller)
        #expect(results.searched == [.openLibrary, .audible, .libraryOfCongress])
        #expect(results.found == [.openLibrary: 0, .audible: 2, .libraryOfCongress: 1])
        #expect(results.failures.isEmpty)
    }

    @Test func M6_aLibraryOfCongressFailureIsItsOwn() async throws {
        let http = FakeHTTP { url in
            guard url.host != "lx2.loc.gov" else { throw LookupError.notReachable }
            return (fixture(url.host == "openlibrary.org" ? "ol-none" : "au-none"), 200)
        }
        let service = LookupService.standard(
            LookupConfiguration(sources: Set(LookupSource.allCases), audibleStores: [.uk]), http: http)
        let results = await service.search(query, preferAudio: true, language: nil)
        #expect(results.failures == [.libraryOfCongress: .notReachable])
        #expect(results.found == [.openLibrary: 0, .audible: 0])
    }

    // MARK: The trial, end to end

    /// The real providers over the trial's answers: a book read by Frank Muller, 18
    /// hours long, finds its cassette edition in the Library of Congress first, and the
    /// Audible editions are marked as different, with why.
    @Test func M1toM6_theTrialCase() async throws {
        let http = FakeHTTP { url in
            switch url.host {
            case "lx2.loc.gov":
                return (fixture("loc-perfectspy", type: "xml"), 200)
            case "openlibrary.org":
                return (fixture(url.path.hasSuffix("/editions.json") ? "ol-editions" : "ol-editions-search"), 200)
            case "api.audible.co.uk", "api.audible.com", "api.audible.com.au":
                // Nobody sells the Frank Muller recording.
                guard queryItems(url)["narrator"] == nil else { return (fixture("au-narrator-none"), 200) }
                let store = url.host == "api.audible.co.uk" ? "uk" : url.host == "api.audible.com" ? "us" : "au"
                return (fixture("au-stores-\(store)"), 200)
            default:
                throw LookupError.notReachable
            }
        }
        let service = LookupService.standard(
            LookupConfiguration(sources: Set(LookupSource.allCases), audibleStores: [.uk, .us, .au]), http: http)
        let results = await service.search(query, preferAudio: true, language: "en", book: muller)

        #expect(results.failures.isEmpty)
        #expect(results.searched == [.openLibrary, .audible, .libraryOfCongress])
        #expect(results.found[.libraryOfCongress] == 1)
        #expect(results.found[.audible] == 5)
        #expect(results.narratorNotFound == [.audible: "Frank Muller"])

        // M5: the cassette read by Frank Muller is first, as the book's own edition.
        let first = try #require(results.candidates.first)
        #expect(first.id == "libraryOfCongress:5615214")
        #expect(first.metadata.narrators == ["Frank Muller"])
        #expect(results.verdicts[first.id] == .sameEdition)
        #expect(results.verdicts.values.filter { $0 == .sameEdition }.count == 1)

        // M1, M2: the others are other editions, and say why.
        #expect(results.verdicts["audible:uk:B0DM2NJ5SK"]
            == .differentEdition(reasons: ["read by Rory Kinnear, not Frank Muller", "19h 59m; yours is 18h 0m"]))
        #expect(results.verdicts["audible:us:B0D3MX4TFN"]
            == .differentEdition(reasons: ["read by Shaun Evans, not Frank Muller", "19h 56m; yours is 18h 0m"]))
        // The BBC dramatisations: the full cast is not named as a reader.
        #expect(results.verdicts["audible:uk:B004WPPYP0"] == .differentEdition(reasons: [
            "read by Harriet Walter, James Fox and Julian Rhind-Tutt, not Frank Muller", "3h 57m; yours is 18h 0m",
        ]))
        #expect(results.verdicts["audible:uk:B074JGKNXT"] == .differentEdition(reasons: [
            "read by Michael Maloney, Bill Paterson and Julian Rhind-Tutt, not Frank Muller", "2h 50m; yours is 18h 0m",
        ]))
        // Open Library names no reader and no length: it cannot be told.
        #expect(results.candidates.filter { $0.source == .openLibrary }.allSatisfy { results.verdicts[$0.id] == .unknown })

        // M5: of the results for this very title, every different edition comes after
        // every one that is not known to be different.
        let exact = results.candidates.filter { LookupService.score($0, query: query) == 1 }
        let ranks = exact.map { results.verdicts[$0.id]?.isDifferent == true }
        #expect(ranks == ranks.sorted { !$0 && $1 })
        #expect(ranks.contains(true))
        #expect(ranks.contains(false))
        #expect(results.candidates.count == results.verdicts.count)
    }
}

/// The signal that a search by narrator found nothing and was made again without the name.
@Suite struct NarratorFallbackTests {
    private let query = LookupQuery(title: "A Perfect Spy", author: "John le Carré", narrator: " Frank Muller ")

    /// Answers by narrator from `byNarrator`, and without one from the store's fixture.
    private func http(narratorFound: Set<String> = []) -> FakeHTTP {
        FakeHTTP { url in
            let store = url.host == "api.audible.co.uk" ? "uk" : url.host == "api.audible.com" ? "us" : "au"
            if queryItems(url)["narrator"] != nil {
                return (fixture(narratorFound.contains(store) ? "au-narrator-found" : "au-narrator-none"), 200)
            }
            return (fixture("au-stores-\(store)"), 200)
        }
    }

    @Test func oneStoreSaysWhenItSearchedAgainWithoutTheNarrator() async throws {
        let provider = AudibleProvider(http: http(), store: .us)
        let answer = try await provider.answer(to: query)
        #expect(answer.narratorNotFound == "Frank Muller")
        #expect(answer.candidates.map(\.id) == ["audible:us:B004WPQ4BI", "audible:us:B0D3MX4TFN", "audible:us:B074JD5VBZ"])
        // N2: the candidates themselves are not marked, and `search` gives the same ones.
        #expect(try await provider.search(query) == answer.candidates)
    }

    @Test func nothingIsSaidWhenTheNarratorWasFound() async throws {
        let answer = try await AudibleProvider(http: http(narratorFound: ["us"]), store: .us).answer(to: query)
        #expect(answer.narratorNotFound == nil)
        #expect(answer.candidates.map(\.id) == ["audible:us:B09XN7T3FP"])
    }

    @Test func nothingIsSaidWhenNoNarratorWasAskedFor() async throws {
        for narrator in [nil, "", "  "] as [String?] {
            var asked = query
            asked.narrator = narrator
            let answer = try await AudibleProvider(http: http(), store: .us).answer(to: asked)
            #expect(answer.narratorNotFound == nil)
            #expect(answer.candidates.count == 3)
        }
    }

    /// The narrator was looked for and nothing at all was found, with or without: still said.
    @Test func itIsSaidEvenWhenTheSecondSearchFindsNothing() async throws {
        let answer = try await AudibleProvider(http: FakeHTTP(data: fixture("au-narrator-none")), store: .uk).answer(to: query)
        #expect(answer == LookupAnswer(candidates: [], narratorNotFound: "Frank Muller"))
    }

    @Test func anASINThatIsFoundSaysNothing() async throws {
        var asked = query
        asked.asin = "B08G9PRS1K"
        let answer = try await AudibleProvider(http: FakeHTTP(data: fixture("au-asin")), store: .us).answer(to: asked)
        #expect(answer.narratorNotFound == nil)
        #expect(answer.candidates.count == 1)
    }

    @Test func severalStoresSayItOnlyWhenNoneFoundTheNarrator() async throws {
        let none = try await AudibleStoresProvider(http: http(), stores: [.uk, .us, .au]).answer(to: query)
        #expect(none.narratorNotFound == "Frank Muller")
        #expect(none.candidates.count == 5)

        let one = try await AudibleStoresProvider(http: http(narratorFound: ["us"]), stores: [.uk, .us, .au]).answer(to: query)
        #expect(one.narratorNotFound == nil)
        #expect(one.candidates.contains { $0.id == "audible:us:B09XN7T3FP" })
    }

    /// A store that failed says nothing either way: the ones that answered decide.
    @Test func aStoreThatFailedDoesNotDecide() async throws {
        let inner = http()
        let failing = FakeHTTP { url in
            guard url.host != "api.audible.com" else { throw LookupError.notReachable }
            return try inner.answerForTest(url)
        }
        let answer = try await AudibleStoresProvider(http: failing, stores: [.uk, .us]).answer(to: query)
        #expect(answer.narratorNotFound == "Frank Muller")
        #expect(answer.candidates.allSatisfy { $0.edition.stores == ["uk"] })
        #expect(try await AudibleStoresProvider(http: failing, stores: []).answer(to: query) == LookupAnswer())
    }

    @Test func aProviderThatSaysNothingAnswersWithItsCandidates() async throws {
        struct Plain: LookupProvider {
            let source = LookupSource.openLibrary
            func search(_ query: LookupQuery) async throws -> [LookupCandidate] { [result(.openLibrary, "/works/OL1W")] }
        }
        #expect(try await Plain().answer(to: query) == LookupAnswer(candidates: [result(.openLibrary, "/works/OL1W")]))
    }

    @Test func theServiceSaysWhichSourceSearchedAgain() async throws {
        let service = LookupService(providers: [
            ListProvider(source: .openLibrary, candidates: [result(.openLibrary, "/works/OL1W")]),
            ListProvider(source: .audible, candidates: [result(.audible, "uk:B000000001")], narratorNotFound: "Frank Muller"),
        ], http: FakeHTTP(throwing: LookupError.notReachable))
        let results = await service.search(query, preferAudio: true, language: nil)
        #expect(results.narratorNotFound == [.audible: "Frank Muller"])
        #expect(results.found == [.openLibrary: 1, .audible: 1])

        let found = LookupService(providers: [
            ListProvider(source: .audible, candidates: [result(.audible, "uk:B000000001")]),
        ], http: FakeHTTP(throwing: LookupError.notReachable))
        #expect(await found.search(query, preferAudio: true, language: nil).narratorNotFound.isEmpty)
    }
}
