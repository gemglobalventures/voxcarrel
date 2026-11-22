import Foundation
import GRDB
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

private let h = 3600.0

private func found(
    _ source: LookupSource = .audible, _ key: String, title: String = "A Perfect Spy", author: String? = "John le Carré",
    narrators: [String] = [], hours: Double? = nil, abridged: Bool? = nil, language: String? = nil, pages: Int? = nil,
    subtitle: String? = nil
) -> LookupCandidate {
    var metadata = BookMetadata(title: title, authors: author.map { [$0] } ?? [])
    metadata.narrators = narrators
    metadata.durationSeconds = hours.map { $0 * h }
    metadata.language = language
    metadata.pageCount = pages
    metadata.subtitle = subtitle
    return LookupCandidate(
        id: "\(source.rawValue):\(key)", source: source, metadata: metadata, note: source.title,
        edition: EditionFacts(abridged: abridged))
}

private func book(
    _ title: String = "A Perfect Spy", author: String? = "John le Carré", narrators: [String] = [], language: String? = nil
) -> BookMetadata {
    var metadata = BookMetadata(title: title, authors: author.map { [$0] } ?? [])
    metadata.narrators = narrators
    metadata.language = language
    return metadata
}

/// The owner's "A Perfect Spy": what the stores list for it.
private let kinnear = found(.audible, "uk:B0DM2NJ5SK", narrators: ["Rory Kinnear"], hours: 1199.0 / 60, abridged: false)
private let bbcLong = found(
    .audible, "uk:B004WPPYP0", narrators: ["Full Cast", "Harriet Walter", "James Fox"], hours: 237.0 / 60, abridged: false)
private let bbcShort = found(
    .audible, "uk:B074JGKNXT", narrators: ["Full Cast", "Michael Maloney"], hours: 170.0 / 60, abridged: true)

@Suite struct EditionKindNoteTests {
    private func note(_ basis: EditionKindNote.Basis, _ kind: EditionKind = .abridged) -> EditionKindNote {
        EditionKindNote(kind: kind, basis: basis, reason: "why")
    }

    // MARK: K1

    @Test func K1_statedBeatsMatchedBeatsInferredBeatsEstimated() {
        let order: [EditionKindNote.Basis] = [.estimated, .inferred, .matched("Audible"), .stated("the file's tags")]
        for (weaker, stronger) in zip(order, order.dropFirst()) {
            #expect(note(stronger).mayReplace(note(weaker)))
            #expect(!note(weaker).mayReplace(note(stronger)))
            #expect(EditionKindNote.stronger(note(weaker), note(stronger)) == note(stronger))
            #expect(EditionKindNote.stronger(note(stronger), note(weaker)) == note(stronger))
        }
        #expect(!note(.estimated).mayReplace(note(.stated("x"))))
        #expect(note(.stated("x")).mayReplace(note(.estimated)))
    }

    @Test func K1_anythingReplacesNothingAndANewerFindingOfTheSameStrengthReplacesAnOlder() {
        for basis in [EditionKindNote.Basis.estimated, .inferred, .matched("Audible"), .stated("x"), .setByHand] {
            #expect(note(basis).mayReplace(nil))
        }
        #expect(note(.inferred, .unabridged).mayReplace(note(.inferred, .abridged)))
        #expect(note(.matched("Audible")).mayReplace(note(.matched("Library of Congress"))))
        #expect(EditionKindNote.stronger(note(.inferred, .unabridged), note(.inferred, .abridged)) == note(.inferred, .unabridged))
        #expect(EditionKindNote.stronger(nil, note(.inferred)) == note(.inferred))
        #expect(EditionKindNote.stronger(note(.inferred), nil) == note(.inferred))
        #expect(EditionKindNote.stronger(nil, nil) == nil)
    }

    /// K1: what was set by hand is never replaced by anything worked out.
    @Test func K1_setByHandIsNeverReplaced() {
        let byHand = note(.setByHand, .unabridged)
        for basis in [EditionKindNote.Basis.estimated, .inferred, .matched("Audible"), .stated("x"), .setByHand] {
            #expect(!note(basis).mayReplace(byHand))
        }
        #expect(byHand.isSetByHand)
        #expect(!note(.stated("x")).isSetByHand)
    }

    @Test func onlyAnEstimateIsProbable() {
        #expect(note(.estimated).isProbable)
        for basis in [EditionKindNote.Basis.inferred, .matched("Audible"), .stated("x"), .setByHand] {
            #expect(!note(basis).isProbable)
        }
    }

    @Test func theKindsAndWhatTheySayOfAbridgement() {
        #expect(EditionKind.allCases == [.unabridged, .abridged, .dramatised])
        #expect(EditionKind.allCases.map(\.title) == ["Unabridged", "Abridged", "Dramatised"])
        #expect(EditionKind.allCases.map(\.isAbridged) == [false, true, nil])
    }

    // MARK: Storing

    @Test func aNoteIsStoredAsOneFlatObjectAndReadBack() throws {
        let notes = [
            EditionKindNote(kind: .abridged, basis: .stated("the file's tags"), reason: "The title says “Abridged”."),
            EditionKindNote(kind: .unabridged, basis: .matched("Library of Congress"), reason: nil),
            EditionKindNote(kind: .dramatised, basis: .inferred, reason: "3h"),
            EditionKindNote(kind: .abridged, basis: .estimated, reason: "x"),
            EditionKindNote(kind: .unabridged, basis: .setByHand),
        ]
        for note in notes {
            let data = try JSONEncoder().encode(note)
            #expect(try JSONDecoder().decode(EditionKindNote.self, from: data) == note)
        }
        let stored = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(notes[0])) as? [String: String])
        #expect(stored == ["kind": "abridged", "basis": "stated", "source": "the file's tags", "reason": "The title says “Abridged”."])
        let byHand = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(notes[4])) as? [String: String])
        #expect(byHand == ["kind": "unabridged", "basis": "setByHand"])
    }

    @Test(arguments: [
        #"{"kind": "abridged", "basis": "hearsay"}"#, #"{"kind": "condensed", "basis": "stated"}"#, #"{"basis": "stated"}"#,
        #"{"kind": "abridged"}"#, #"[]"#, #""abridged""#,
    ])
    func aNoteThisCodeCannotReadIsRefused(json: String) {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(EditionKindNote.self, from: Data(json.utf8)) }
    }
}

@Suite struct EditionKindFromFilesTests {
    private func kind(title: String = "A Perfect Spy", subtitle: String? = nil, comment: String? = nil, names: [String] = []) -> EditionKindNote? {
        EditionKindGuess.fromFiles(title: title, subtitle: subtitle, comment: comment, fileNames: names)
    }

    // MARK: K2

    @Test(arguments: [
        ("A Perfect Spy (Unabridged)", EditionKind.unabridged, "Unabridged"),
        ("A Perfect Spy [UNABRIDGED]", .unabridged, "UNABRIDGED"),
        ("A Perfect Spy - unabridged", .unabridged, "unabridged"),
        ("A Perfect Spy (Abridged)", .abridged, "Abridged"),
        ("A Perfect Spy: abridged edition", .abridged, "abridged"),
        ("A Perfect Spy (Full Cast)", .dramatised, "Full Cast"),
        ("A Perfect Spy: A BBC Radio 4 full-cast dramatisation", .dramatised, "full cast"),
        ("A Perfect Spy (Dramatization)", .dramatised, "Dramatization"),
        ("A Perfect Spy: a radio play", .dramatised, "radio play"),
        ("A Perfect Spy (BBC Radio)", .dramatised, "BBC Radio"),
        ("A Perfect Spy (Dramatised)", .dramatised, "Dramatised"),
    ])
    func K2_theTitleSaysWhatItIs(title: String, kind: EditionKind, said: String) {
        #expect(self.kind(title: title) == EditionKindNote(
            kind: kind, basis: .stated("the file's tags"), reason: "The title says “\(said)”."))
    }

    @Test func K2_theSubtitleAndTheCommentSayItToo() {
        #expect(kind(subtitle: "Unabridged") == EditionKindNote(
            kind: .unabridged, basis: .stated("the file's tags"), reason: "The subtitle says “Unabridged”."))
        #expect(kind(comment: "An abridged reading.") == EditionKindNote(
            kind: .abridged, basis: .stated("the file's tags"), reason: "The description says “abridged”."))
    }

    @Test func K2_aFileOrFolderNameSaysIt() {
        #expect(kind(names: ["01 - Chapter One", "A Perfect Spy (Unabridged)"]) == EditionKindNote(
            kind: .unabridged, basis: .stated("the file's name"), reason: "A file or folder name says “Unabridged”."))
        #expect(kind(names: ["A_Perfect_Spy_abridged_01"])?.kind == .abridged)
        #expect(kind(names: ["perfect.spy.full_cast.part1"])?.kind == .dramatised)
        #expect(kind(names: ["BBC-Radio-Drama-01"])?.kind == .dramatised)
    }

    /// "Unabridged" holds the word "abridged", and is looked for first.
    @Test func K2_unabridgedIsCheckedBeforeAbridged() {
        #expect(kind(title: "A Perfect Spy (Unabridged)")?.kind == .unabridged)
        #expect(kind(title: "Unabridged", comment: "Not the abridged one.")?.kind == .unabridged)
        #expect(kind(title: "A Perfect Spy (Abridged)", names: ["Unabridged"])?.kind == .unabridged)
        // And either before a dramatisation.
        #expect(kind(title: "A Perfect Spy (Full Cast, Unabridged)")?.kind == .unabridged)
        #expect(kind(title: "A Perfect Spy (Abridged, BBC Radio)")?.kind == .abridged)
    }

    /// Whole words only.
    @Test(arguments: [
        "A Perfect Spy", "Unabridgedness", "Abridgedly", "The Bridge", "Abridge", "Fullcastle", "Radioplayer", "BBC Radiophonic",
        "Dramatic", "Cast in Full", "",
    ])
    func K2_nothingIsReadIntoOtherWords(title: String) {
        #expect(kind(title: title) == nil)
        #expect(kind(subtitle: title, comment: title, names: [title]) == nil)
    }

    /// K2: nothing is taken out of the title: it is only read.
    @Test func K2_theTitleIsNotChanged() {
        let title = "A Perfect Spy (Unabridged)"
        _ = kind(title: title)
        #expect(title == "A Perfect Spy (Unabridged)")
        #expect(kind(title: title)?.reason?.contains("Unabridged") == true)
    }
}

@Suite struct EditionKindFromResultsTests {
    private func assess(
        _ candidates: [LookupCandidate], _ book: BookMetadata = book(), hours: Double?, partsMissing: Bool = false
    ) -> EditionKindAssessment {
        EditionKindGuess.assess(candidates, book: book, bookSeconds: hours.map { $0 * h }, partsAppearMissing: partsMissing)
    }

    // MARK: K3 matched

    @Test func K3_aResultThatIsTheSameEditionSaysWhatItIs() {
        let cassette = found(.libraryOfCongress, "5615214", title: "A perfect spy", narrators: ["Frank Muller"], hours: 18, abridged: false)
        let mine = book(narrators: ["Frank Muller"])
        #expect(assess([kinnear, cassette], mine, hours: 18) == EditionKindAssessment(note: EditionKindNote(
            kind: .unabridged, basis: .matched("Library of Congress"),
            reason: "Library of Congress lists your edition as unabridged.")))
        let abridged = found(.audible, "uk:B000000009", narrators: ["Frank Muller"], hours: 3, abridged: true)
        #expect(assess([abridged], mine, hours: 3).note == EditionKindNote(
            kind: .abridged, basis: .matched("Audible"), reason: "Audible lists your edition as abridged."))
        #expect(EditionKindGuess.fromResults([abridged], book: mine, bookSeconds: 3 * h) == assess([abridged], mine, hours: 3).note)
    }

    /// K3: only a result judged the same edition, and only when it says.
    @Test func K3_aDifferentOrUnknownEditionOrASilentOneIsNotTaken() {
        let mine = book(narrators: ["Frank Muller"])
        // Another reader's abridgement says nothing about this book.
        let other = found(.audible, "uk:B000000009", narrators: ["Rory Kinnear"], hours: 3, abridged: true)
        #expect(assess([other], mine, hours: nil).note == nil)
        // Not known to be the same.
        #expect(assess([found(.audible, "uk:B000000008", abridged: true)], mine, hours: nil).note == nil)
        // The same, but it does not say.
        let silent = found(.libraryOfCongress, "1", narrators: ["Frank Muller"], abridged: nil)
        #expect(assess([silent], mine, hours: nil).note == nil)
    }

    @Test func K3_theSameEditionWithAFullCastIsADramatisation() {
        let mine = book(narrators: ["Harriet Walter", "James Fox"])
        #expect(assess([bbcLong], mine, hours: 237.0 / 60).note == EditionKindNote(
            kind: .dramatised, basis: .matched("Audible"), reason: "Audible lists your edition as a full-cast production."))
    }

    // MARK: K4 inferred from the running time

    /// The owner's case: 18 hours, against a 20-hour unabridged reading and a 4-hour play.
    @Test func K4_withinTwelvePercentOfAnUnabridgedEditionIsUnabridged() {
        #expect(assess([bbcLong, kinnear, bbcShort], hours: 18) == EditionKindAssessment(note: EditionKindNote(
            kind: .unabridged, basis: .inferred, reason: "18h 0m; the unabridged edition runs 19h 59m.")))
        // The edges: 12% either side of 20 hours is 17h 36m to 22h 24m.
        let twenty = found(.audible, "us:B000000020", hours: 20, abridged: false)
        #expect(assess([twenty], hours: 17.6).note?.kind == .unabridged)
        #expect(assess([twenty], hours: 22.4).note?.kind == .unabridged)
        #expect(assess([twenty], hours: 22.5).note == nil)
        #expect(assess([twenty], hours: 17.5).note == nil)
    }

    /// The owner's case: 36 hours, once the true length is known.
    @Test func K4_theThirtySixHourBook() {
        let debt = book("Debt of Honor", author: "Tom Clancy")
        let listed = found(.audible, "us:B00DEBT0001", title: "Debt of Honor", author: "Tom Clancy", narrators: ["John MacDonald"], hours: 36.1, abridged: false)
        // The same length: it is that edition (K3).
        #expect(assess([listed], debt, hours: 36).note == EditionKindNote(
            kind: .unabridged, basis: .matched("Audible"), reason: "Audible lists your edition as unabridged."))
        // Read by someone else, or some way off in length: unabridged all the same, by its length.
        #expect(assess([listed], book("Debt of Honor", author: "Tom Clancy", narrators: ["Another Reader"]), hours: 36).note
            == EditionKindNote(kind: .unabridged, basis: .inferred, reason: "36h 0m; the unabridged edition runs 36h 6m."))
        #expect(assess([listed], debt, hours: 33).note
            == EditionKindNote(kind: .unabridged, basis: .inferred, reason: "33h 0m; the unabridged edition runs 36h 6m."))
        // With the two hours a wrong header gave, it would have been called abridged.
        #expect(assess([listed], debt, hours: 2).note == EditionKindNote(
            kind: .abridged, basis: .inferred, reason: "2h 0m; unabridged editions run about 36h."))
    }

    @Test func K4_theNearestUnabridgedEditionIsTheOneNamed() {
        let editions = [found(.audible, "us:B000000022", hours: 22, abridged: false), found(.audible, "us:B000000020", hours: 20, abridged: false)]
        #expect(assess(editions, hours: 18.5).note?.reason == "18h 30m; the unabridged edition runs 20h 0m.")
    }

    @Test func K4_underSixtyPercentOfTheShortestUnabridgedEditionIsAbridged() {
        let editions = [found(.audible, "us:B000000020", hours: 20, abridged: false), found(.audible, "us:B000000018", hours: 18, abridged: false)]
        #expect(assess(editions, hours: 3.2) == EditionKindAssessment(note: EditionKindNote(
            kind: .abridged, basis: .inferred, reason: "3h 12m; unabridged editions run about 18h.")))
        // 60% of 18 hours is 10h 48m.
        #expect(assess(editions, hours: 10.7).note?.kind == .abridged)
        #expect(assess(editions, hours: 10.8).note == nil)
    }

    /// The owner's case: a play of about four hours that the store calls unabridged.
    @Test func K4_aShortBookBesideADramatisationOfItsLengthIsDramatised() {
        #expect(assess([kinnear, bbcLong, bbcShort], hours: 3.6) == EditionKindAssessment(note: EditionKindNote(
            kind: .dramatised, basis: .inferred,
            reason: "3h 36m; Audible lists a dramatisation of that length, and unabridged editions run about 20h.")))
        // The play is no measure of an unabridged reading, though the store calls it one.
        #expect(assess([bbcLong], hours: 3.6).note == nil)
        #expect(assess([bbcLong], hours: 18).note == nil)
        #expect(assess([bbcLong], hours: 1).note == nil)
        // A short book that is no play's length is an abridgement.
        #expect(assess([kinnear, bbcLong, bbcShort], hours: 6).note?.kind == .abridged)
        // A result that calls itself a dramatisation counts as one.
        let named = found(.audible, "us:B000000004", hours: 4, abridged: nil, subtitle: "A BBC Radio 4 dramatisation")
        #expect(assess([kinnear, named], hours: 4).note?.kind == .dramatised)
    }

    @Test func K4_aShortBookReadByAFullCastIsDramatised() {
        let mine = book(narrators: ["Full cast", "Someone Unlisted"])
        #expect(assess([kinnear], mine, hours: 3) == EditionKindAssessment(note: EditionKindNote(
            kind: .dramatised, basis: .inferred, reason: "3h 0m, read by a full cast; unabridged editions run about 20h.")))
    }

    @Test func K4_betweenSixtyAndEightyEightPercentThereIsNoVerdictButAReason() {
        let twenty = found(.audible, "us:B000000020", hours: 20, abridged: false)
        #expect(assess([twenty], hours: 13) == EditionKindAssessment(
            note: nil, remark: "13h 0m; shorter than the unabridged editions (20h 0m), so it may be abridged or incomplete."))
        #expect(assess([twenty], hours: 12).remark != nil)
        #expect(assess([twenty], hours: 17.5).remark != nil)
        // Longer than every edition: nothing to say.
        #expect(assess([twenty], hours: 30) == EditionKindAssessment())
    }

    @Test func K4_onlyUnabridgedResultsForTheSameTitleAndFirstAuthorWithALengthCount() {
        let mine = book()
        let others = [
            found(.audible, "us:B000000001", title: "A Perfect Spy and Others", hours: 20, abridged: false),
            found(.audible, "us:B000000002", author: "Someone Else", hours: 20, abridged: false),
            found(.audible, "us:B000000003", author: nil, hours: 20, abridged: false),
            found(.audible, "us:B000000004", hours: nil, abridged: false),
            found(.audible, "us:B000000005", hours: 20, abridged: nil),
            found(.audible, "us:B000000006", hours: 20, abridged: true),
        ]
        // 18 hours is within 12% of 20, but none of these is a measure.
        #expect(assess(others, mine, hours: 18) == EditionKindAssessment())
        #expect(assess(others, mine, hours: 3) == EditionKindAssessment())
        // The title ignoring case and a leading article, the author by `samePerson`.
        let same = found(.libraryOfCongress, "7", title: "a perfect spy", author: "Le Carré, John, 1931-2020", hours: 20, abridged: false)
        #expect(assess([same], mine, hours: 18).note == EditionKindNote(
            kind: .unabridged, basis: .inferred, reason: "18h 0m; the unabridged edition runs 20h 0m."))
        // A book with no author goes by its title.
        #expect(assess([same], book(author: nil), hours: 18).note?.basis == .inferred)
        #expect(assess([same], book(""), hours: 18).note == nil)
    }

    @Test func K4_resultsInAnotherLanguageAreNotUsed() {
        let german = found(.audible, "de:B000000001", hours: 20, abridged: false, language: "de")
        #expect(assess([german], book(language: "en"), hours: 18) == EditionKindAssessment())
        #expect(assess([german], book(language: "English"), hours: 3) == EditionKindAssessment())
        // The same language, or one side that does not say, is used.
        #expect(assess([german], book(language: "ger"), hours: 18).note?.basis == .inferred)
        #expect(assess([german], book(language: nil), hours: 18).note?.basis == .inferred)
    }

    @Test func K4_withoutAMeasuredLengthNothingIsInferred() {
        #expect(assess([kinnear, bbcLong], hours: nil) == EditionKindAssessment())
        #expect(assess([kinnear], hours: 0) == EditionKindAssessment())
        #expect(EditionKindGuess.fromResults([kinnear], book: book(), bookSeconds: nil) == nil)
    }

    // MARK: K5 from a page count

    @Test func K5_withNoAudioEditionAPageCountGivesAProbableVerdict() {
        // 612 pages at 34 pages an hour: 18 hours.
        let work = found(.openLibrary, "/works/OL1W", pages: 612)
        #expect(assess([work], hours: 18) == EditionKindAssessment(note: EditionKindNote(
            kind: .unabridged, basis: .estimated, reason: "18h 0m; a book of 612 pages probably runs about 18h unabridged.")))
        #expect(assess([work], hours: 3) == EditionKindAssessment(note: EditionKindNote(
            kind: .abridged, basis: .estimated, reason: "3h 0m; a book of 612 pages probably runs about 18h unabridged.")))
        #expect(assess([work], hours: 18).note?.isProbable == true)
        #expect(assess([work], hours: 3).note?.isProbable == true)
    }

    @Test func K5_theBands() {
        let work = found(.openLibrary, "/works/OL1W", pages: 340)  // 10 hours
        #expect(assess([work], hours: 3.9).note?.kind == .abridged)
        #expect(assess([work], hours: 4).note == nil)
        #expect(assess([work], hours: 6.9).note == nil)
        #expect(assess([work], hours: 7).note?.kind == .unabridged)
        #expect(assess([work], hours: 14).note?.kind == .unabridged)
        #expect(assess([work], hours: 14.1).note == nil)
    }

    /// K5: an estimate never counts as stated or matched, and an audio edition is always preferred to it.
    @Test func K5_onlyWhenNoUnabridgedAudioEditionIsFound() {
        let work = found(.openLibrary, "/works/OL1W", pages: 612)
        // 13 hours would be "probably unabridged" by pages; the audio edition says otherwise.
        #expect(assess([work, kinnear], hours: 13).note == nil)
        #expect(assess([work, kinnear], hours: 19).note?.basis == .inferred)
        let estimate = assess([work], hours: 18).note
        #expect(estimate?.basis == .estimated)
        #expect(estimate?.mayReplace(EditionKindNote(kind: .abridged, basis: .inferred)) == false)
        // Another work's pages, or none, say nothing.
        #expect(assess([found(.openLibrary, "/works/OL2W", title: "Another Book", pages: 612)], hours: 18) == EditionKindAssessment())
        #expect(assess([found(.openLibrary, "/works/OL1W", pages: nil)], hours: 18) == EditionKindAssessment())
        #expect(assess([work], hours: nil) == EditionKindAssessment())
    }

    // MARK: K7 missing parts

    @Test(arguments: [
        (["Part 1.mp3", "Part 2.mp3", "Part 4.mp3"], true),
        (["Spy 01.mp3", "Spy 02.mp3", "Spy 03.mp3"], false),
        (["Spy - 2 of 12.mp3", "Spy - 3 of 12.mp3", "Spy - 9 of 12.mp3"], true),
        (["CD1 Track 01.mp3", "CD1 Track 02.mp3", "CD2 Track 01.mp3"], false),
        (["Disc 1.m4b", "Disc 3.m4b"], true),
        (["Disc 0.m4b", "Disc 1.m4b"], false),
        (["Only.m4b"], false),
        (["Part 7.mp3"], false),
        (["Intro.mp3", "Chapter 2.mp3", "Chapter 4.mp3"], false),
        (["One.mp3", "Two.mp3", "Four.mp3"], false),
        (["1987 - Part 1.mp3", "1987 - Part 2.mp3", "1987 - Part 3.mp3"], false),
        (["Part 1.mp3", "Part 1.m4b", "Part 3.mp3"], false),
        ([], false),
    ] as [([String], Bool)])
    func K7_numberedPartsWithGaps(names: [String], missing: Bool) {
        #expect(EditionKindGuess.partsAppearMissing(fileNames: names) == missing)
    }

    @Test func K7_missingPartsStopAnAbridgedVerdictAndSaySo() {
        let said = "Parts appear to be missing, so the length does not show whether it is abridged."
        #expect(assess([kinnear], hours: 3, partsMissing: true) == EditionKindAssessment(note: nil, remark: said))
        #expect(assess([kinnear, bbcLong], hours: 3.6, partsMissing: true) == EditionKindAssessment(note: nil, remark: said))
        #expect(assess([found(.openLibrary, "/works/OL1W", pages: 612)], hours: 3, partsMissing: true)
            == EditionKindAssessment(note: nil, remark: said))
        #expect(assess([], hours: 3, partsMissing: true) == EditionKindAssessment(note: nil, remark: said))
        // A whole length is still a whole length, and what a source states still stands.
        #expect(assess([kinnear], hours: 19.5, partsMissing: true).note?.kind == .unabridged)
        let abridged = found(.audible, "uk:B000000009", narrators: ["Frank Muller"], hours: 3, abridged: true)
        #expect(assess([abridged], book(narrators: ["Frank Muller"]), hours: 3, partsMissing: true).note?.kind == .abridged)
    }
}

/// The edition kind in the library: stored, saved, undone, found at import, and checked.
@Suite struct LibraryServiceEditionTests {
    typealias F = LibraryFixture

    private func importBook(
        _ f: F, _ metadata: BookMetadata = F.meta("A Perfect Spy", "John le Carré"), files: [String] = ["in.m4b"]
    ) throws -> Int64 {
        try f.importNew(try files.map { try f.makeM4B($0, tags: F.meta("Old", "Old Author")) }, metadata)
    }

    /// Gives the book a length, as if its files were that long, and narrators.
    private func set(_ f: F, _ id: Int64, hours: Double?, narrators: [String] = [], kind: EditionKindNote? = nil) throws {
        var book = try #require(try f.store.book(id: id))
        book.durationSeconds = hours.map { $0 * h }
        book.narrators = narrators
        book.editionKind = kind
        try f.store.update(book)
    }

    private func kind(_ f: F, _ id: Int64) throws -> EditionKindNote? {
        try #require(try f.store.book(id: id)).editionKind
    }

    private let byHand = EditionKindNote(kind: .abridged, basis: .setByHand)

    // MARK: The catalogue

    @Test func aV6DatabaseUpgradesAndNoBookHasAKind() throws {
        let root = try makeTempDir()
        let path = root.appendingPathComponent(LibraryStore.databaseFileName).path
        do {
            let queue = try DatabaseQueue(path: path)
            try LibraryStore.migrator.migrate(queue, upTo: "v6")
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO book (title, authors, narrators, tags, rating, needsAttention, folderPath,
                                      durationSeconds, dateAdded, readStatus, appOnlyFields, externalCopies)
                    VALUES ('Old Book', '["Old Author"]', '[]', '[]', 0, 0, 'Old Author/Old Book', 4368.5,
                            '2025-01-02 03:04:05.000', 'unread', '[]', '[]')
                    """)
            }
            try queue.close()
        }
        let store = try LibraryStore(libraryRoot: root)
        var book = try #require(try store.books().first)
        #expect(book.title == "Old Book")
        #expect(book.editionKind == nil)

        // The new column holds what it is given, and gives it back.
        let note = EditionKindNote(kind: .dramatised, basis: .matched("Audible"), reason: "Audible lists your edition as a full-cast production.")
        book.editionKind = note
        try store.update(book)
        #expect(try store.books().first?.editionKind == note)
        let raw = try store.dbQueue.read { db in try String.fetchOne(db, sql: "SELECT editionKind FROM book") }
        #expect(raw?.contains(#""basis":"matched""#) == true)
        book.editionKind = nil
        try store.update(book)
        #expect(try store.dbQueue.read { db in try String.fetchOne(db, sql: "SELECT editionKind FROM book") } == nil)
    }

    /// A value a newer version wrote, which this one cannot read, counts as not known.
    @Test(arguments: [#"{"kind":"condensed","basis":"stated"}"#, "nonsense", "[]", #"{"kind":"abridged","basis":"rumour"}"#])
    func aKindThisCodeCannotReadIsNotKnown(stored: String) throws {
        let f = try F()
        let id = try importBook(f)
        try f.store.dbQueue.write { db in
            try db.execute(sql: "UPDATE book SET editionKind = ? WHERE id = ?", arguments: [stored, id])
        }
        let book = try #require(try f.store.book(id: id))
        #expect(book.title == "A Perfect Spy")
        #expect(book.editionKind == nil)
    }

    /// A book saved in an undo snapshot before the field existed still reads.
    @Test func aSnapshotWithoutTheFieldStillDecodes() throws {
        var book = Book(metadata: F.meta("A Perfect Spy", "John le Carré"))
        book.id = 7
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any])
        #expect(object["editionKind"] == nil)
        book.editionKind = byHand
        object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any])
        #expect(object["editionKind"] != nil)
        object["editionKind"] = nil
        let old = try JSONDecoder().decode(Book.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.editionKind == nil)
        #expect(old.title == "A Perfect Spy")
        object["editionKind"] = ["kind": "something new", "basis": "stated"]
        #expect(try JSONDecoder().decode(Book.self, from: JSONSerialization.data(withJSONObject: object)).editionKind == nil)
    }

    // MARK: K9 saved by hand, in the catalogue only

    @Test func K9_anEditCarriesTheKindAndSaveKeepsItInTheCatalogueOnly() throws {
        let f = try F()
        let id = try importBook(f, F.fullMeta("A Perfect Spy", "John le Carré"))
        let url = f.store.url(for: try #require(try f.store.files(bookId: id).first))
        let bytesBefore = try f.bytes(url)
        let before = try #require(try f.store.book(id: id))
        #expect(BookEdit(book: before).editionKind == nil)

        var edit = BookEdit(book: before)
        edit.editionKind = byHand
        let outcomes = try f.service.save([edit])
        #expect(outcomes == [.saved(bookId: id, refiled: false, appOnlyFields: [], fileProblems: [])])
        let after = try #require(try f.store.book(id: id))
        #expect(after.editionKind == byHand)
        // Nothing else about the book changed, and no file was opened to write.
        var expected = before
        expected.editionKind = byHand
        #expect(after == expected)
        #expect(try f.bytes(url) == bytesBefore)
        #expect(BookEdit(book: after).editionKind == byHand)
        #expect(try f.service.undoLabel() == "Edit A Perfect Spy")

        // Saving the same again changes nothing and records nothing.
        #expect(try f.service.save([BookEdit(book: after)]) == [.saved(bookId: id, refiled: false, appOnlyFields: [], fileProblems: [])])

        // Undo puts back "not known".
        try f.service.undoLast()
        #expect(try kind(f, id) == nil)
        #expect(try f.bytes(url) == bytesBefore)
    }

    @Test func K9_savingOtherFieldsLeavesTheKindAlone() throws {
        let f = try F()
        let id = try importBook(f)
        try set(f, id, hours: 18, kind: byHand)
        var edit = BookEdit(book: try #require(try f.store.book(id: id)))
        edit.metadata.genre = "Thriller"
        _ = try f.service.save([edit])
        #expect(try kind(f, id) == byHand)
        // And "not known" can be chosen again.
        var clear = BookEdit(book: try #require(try f.store.book(id: id)))
        clear.editionKind = nil
        _ = try f.service.save([clear])
        #expect(try kind(f, id) == nil)
        try f.service.undoLast()
        #expect(try kind(f, id) == byHand)
    }

    @Test func K9_aBookWithNoFilesKeepsAKindToo() throws {
        let f = try F()
        guard case .added(let id) = try f.service.addExternalBook(
            metadata: F.meta("A Perfect Spy", "John le Carré"), cover: nil,
            copy: ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: "B0DM2NJ5SK"))
        else { Issue.record("not added"); return }
        var edit = BookEdit(book: try #require(try f.store.book(id: id)))
        edit.editionKind = byHand
        #expect(try f.service.save([edit]) == [.saved(bookId: id, refiled: false, appOnlyFields: [], fileProblems: [])])
        #expect(try kind(f, id) == byHand)
        #expect(try f.service.save([edit]) == [.saved(bookId: id, refiled: false, appOnlyFields: [], fileProblems: [])])
        try f.service.undoLast()
        #expect(try kind(f, id) == nil)
    }

    // MARK: K2 at import

    @Test func K2_aNewBooksTitleSaysItsKindAtImport() throws {
        let f = try F()
        let id = try importBook(f, F.meta("A Perfect Spy (Unabridged)", "John le Carré"))
        #expect(try kind(f, id) == EditionKindNote(
            kind: .unabridged, basis: .stated("the file's tags"), reason: "The title says “Unabridged”."))
        // The title is left as it is.
        #expect(try f.store.book(id: id)?.title == "A Perfect Spy (Unabridged)")
    }

    @Test func K2_theNamesOfTheFilesAndTheirFolderSayIt() throws {
        let f = try F()
        let inFolder = try importBook(f, F.meta("First", "An Author"), files: ["First [Abridged]/01.m4b", "First [Abridged]/02.m4b"])
        #expect(try kind(f, inFolder) == EditionKindNote(
            kind: .abridged, basis: .stated("the file's name"), reason: "A file or folder name says “Abridged”."))
        let inName = try importBook(f, F.meta("Second", "An Author"), files: ["second_full_cast.m4b"])
        #expect(try kind(f, inName)?.kind == .dramatised)
        let plain = try importBook(f, F.meta("Third", "An Author"), files: ["third.m4b"])
        #expect(try kind(f, plain) == nil)
    }

    @Test func K2_aBookThatCannotBeFiledIsStillRead() throws {
        let f = try F()
        // No author: catalogued where it is.
        let url = try f.makeM4B("loose (unabridged).m4b", tags: BookMetadata(title: "Loose"))
        let result = try f.service.importItems(
            [ImportItem(candidate: f.candidate([url], BookMetadata(title: "Loose")), cover: .keep)], options: ImportOptions(mode: .move))
        guard case .needsAttention(let id) = try #require(result.outcomes.first) else { Issue.record("filed"); return }
        #expect(try kind(f, id)?.kind == .unabridged)
    }

    @Test func K2_anEbookHasNoKind() throws {
        let f = try F()
        let id = try f.importNew([try f.makeEPUB("Unabridged.epub")], F.meta("A Perfect Spy (Unabridged)", "John le Carré"))
        #expect(try kind(f, id) == nil)
    }

    // MARK: K6, K7 what the files say

    @Test func K6_K7_theEvidenceOfABooksFiles() throws {
        let f = try F()
        let id = try importBook(f, files: ["Spy/Part 1.m4b", "Spy/Part 2.m4b", "Spy/Part 4.m4b"])
        try set(f, id, hours: 18)
        // K7: the gap is remembered from the names the files came with; filing renames them.
        #expect(try f.store.book(id: id)?.partsAppearMissing == true)
        #expect(try f.store.files(bookId: id).map { ($0.path as NSString).lastPathComponent }
            == ["01 - A Perfect Spy.m4b", "02 - A Perfect Spy.m4b", "03 - A Perfect Spy.m4b"])
        #expect(try f.service.editionEvidence(for: id) == EditionEvidence(audioSeconds: 18 * h, partsAppearMissing: true, stated: nil))
        let whole = try importBook(f, F.meta("Whole", "An Author"), files: ["Whole/Part 1.m4b", "Whole/Part 2.m4b"])
        #expect(try f.store.book(id: whole)?.partsAppearMissing == false)
        #expect(try f.service.editionEvidence(for: whole).partsAppearMissing == false)

        // K6: one file whose length could not be measured: the length is not relied on.
        var rows = try f.store.files(bookId: id)
        rows[1].lengthUnmeasured = UnmeasuredLength(size: 1, modified: 1, statedSeconds: 60)
        var change = LibraryChange()
        change.writes = [.init(book: try #require(try f.store.book(id: id)), files: rows)]
        try f.store.apply(change)
        #expect(try f.service.editionEvidence(for: id).audioSeconds == nil)

        // A book with no audio has nothing to say.
        let ebook = try f.importNew([try f.makeEPUB("book.epub")], F.meta("An Ebook (Unabridged)", "An Author"))
        #expect(try f.service.editionEvidence(for: ebook) == EditionEvidence())
        #expect(throws: LibraryError.bookNotFound(999)) { try f.service.editionEvidence(for: 999) }
    }

    @Test func K6_aBookWithAnUnmeasuredFileGetsNoInferredVerdict() throws {
        let f = try F()
        let id = try importBook(f, F.meta("Debt of Honor", "Tom Clancy"))
        try set(f, id, hours: 2)
        let listed = found(.audible, "us:B00DEBT0001", title: "Debt of Honor", author: "Tom Clancy", hours: 36, abridged: false)
        // Measured, two hours would be an abridgement.
        #expect(try f.service.assessEdition(of: id, results: [listed]).note?.kind == .abridged)

        var rows = try f.store.files(bookId: id)
        rows[0].lengthUnmeasured = UnmeasuredLength(size: 1, modified: 1, statedSeconds: 2 * h)
        var change = LibraryChange()
        change.writes = [.init(book: try #require(try f.store.book(id: id)), files: rows)]
        try f.store.apply(change)
        #expect(try f.service.assessEdition(of: id, results: [listed]) == EditionKindAssessment())
        #expect(try f.service.checkEditions([EditionCheck(bookId: id, results: [listed])])
            == [EditionCheckOutcome(bookId: id, kind: nil, changed: false)])
        #expect(try kind(f, id) == nil)

        // Once its true length is known, it is the unabridged edition.
        rows[0].lengthUnmeasured = nil
        var book = try #require(try f.store.book(id: id))
        book.durationSeconds = 36 * h
        change.writes = [.init(book: book, files: rows)]
        try f.store.apply(change)
        #expect(try f.service.checkEditions([EditionCheck(bookId: id, results: [listed])]).first?.kind?.kind == .unabridged)
    }

    @Test func K7_missingPartsAreSaidAndNoAbridgementIsInferred() throws {
        let f = try F()
        let id = try importBook(f, files: ["Spy/Part 1.m4b", "Spy/Part 2.m4b", "Spy/Part 4.m4b"])
        try set(f, id, hours: 9)
        let outcomes = try f.service.checkEditions([EditionCheck(bookId: id, results: [kinnear])])
        #expect(outcomes == [EditionCheckOutcome(
            bookId: id, kind: nil, changed: false,
            remark: "Parts appear to be missing, so the length does not show whether it is abridged.")])
        #expect(try kind(f, id) == nil)
        #expect(try f.service.undoLabel() != "Check edition of A Perfect Spy")
    }

    // MARK: K8 checking a selection

    @Test func K8_checkingWritesOnlyTheKindAsOneUndoableOperation() throws {
        let f = try F()
        let spy = try importBook(f, F.fullMeta("A Perfect Spy", "John le Carré"), files: ["spy.m4b"])
        let debt = try importBook(f, F.meta("Debt of Honor", "Tom Clancy"), files: ["debt.m4b"])
        let silent = try importBook(f, F.meta("Nothing Known", "An Author"), files: ["nothing.m4b"])
        try set(f, spy, hours: 18, narrators: ["Frank Muller"])
        try set(f, debt, hours: 3)
        try set(f, silent, hours: nil)
        let before = try [spy, debt, silent].map { try #require(try f.store.book(id: $0)) }
        let filesBefore = try [spy, debt, silent].map { try f.store.files(bookId: $0) }
        let urls = filesBefore.flatMap { $0 }.map { f.store.url(for: $0) }
        let bytesBefore = try urls.map { try f.bytes($0) }
        let treeBefore = f.libraryTree()

        let cassette = found(.libraryOfCongress, "5615214", narrators: ["Frank Muller"], hours: 18, abridged: false)
        let listed = found(.audible, "us:B00DEBT0001", title: "Debt of Honor", author: "Tom Clancy", hours: 36, abridged: false)
        let outcomes = try f.service.checkEditions([
            EditionCheck(bookId: spy, results: [cassette, kinnear]),
            EditionCheck(bookId: debt, results: [listed]),
            EditionCheck(bookId: silent, results: [kinnear]),
            EditionCheck(bookId: spy, results: []),
            EditionCheck(bookId: 999, results: [kinnear]),
        ])

        let matched = EditionKindNote(
            kind: .unabridged, basis: .matched("Library of Congress"), reason: "Library of Congress lists your edition as unabridged.")
        let inferred = EditionKindNote(kind: .abridged, basis: .inferred, reason: "3h 0m; unabridged editions run about 36h.")
        #expect(outcomes == [
            EditionCheckOutcome(bookId: spy, kind: matched, changed: true),
            EditionCheckOutcome(bookId: debt, kind: inferred, changed: true),
            EditionCheckOutcome(bookId: silent, kind: nil, changed: false),
        ])

        // Only this field changed, in the books that changed; no file was touched or renumbered.
        var expected = before
        expected[0].editionKind = matched
        expected[1].editionKind = inferred
        #expect(try [spy, debt, silent].map { try #require(try f.store.book(id: $0)) } == expected)
        #expect(try [spy, debt, silent].map { try f.store.files(bookId: $0) } == filesBefore)
        #expect(try urls.map { try f.bytes($0) } == bytesBefore)
        #expect(f.libraryTree() == treeBefore)

        // One operation, and Undo takes all of it back.
        #expect(try f.service.undoLabel() == "Check edition of 2 books")
        #expect(try f.service.undoLast() == "Check edition of 2 books")
        #expect(try [spy, debt, silent].map { try #require(try f.store.book(id: $0)) } == before)
        #expect(try [spy, debt, silent].map { try f.store.files(bookId: $0) } == filesBefore)
        #expect(try urls.map { try f.bytes($0) } == bytesBefore)
    }

    @Test func K8_oneBookIsNamedAndACoverSurvivesUndo() throws {
        let f = try F()
        let id = try f.importNew(
            [try f.makeM4B("spy.m4b", tags: F.meta("Old", "Old Author"), cover: F.jpeg)], F.meta("A Perfect Spy", "John le Carré"))
        try set(f, id, hours: 19.5)
        #expect(f.service.covers.image(for: id) != nil)
        _ = try f.service.checkEditions([EditionCheck(bookId: id, results: [kinnear])])
        #expect(try f.service.undoLabel() == "Check edition of A Perfect Spy")
        #expect(try kind(f, id)?.kind == .unabridged)
        try f.service.undoLast()
        #expect(try kind(f, id) == nil)
        #expect(f.service.covers.image(for: id) != nil)
        #expect(LibraryService.checkEditionLabel(count: 1, title: "  ") == "Check edition of 1 book")
    }

    @Test func K8_aCheckThatChangesNothingRecordsNothing() throws {
        let f = try F()
        let id = try importBook(f)
        try set(f, id, hours: nil)
        let labelBefore = try f.service.undoLabel()
        #expect(try f.service.checkEditions([EditionCheck(bookId: id, results: [kinnear])])
            == [EditionCheckOutcome(bookId: id, kind: nil, changed: false)])
        #expect(try f.service.checkEditions([]) == [])
        #expect(try f.service.undoLabel() == labelBefore)
        // Found again exactly as it is: still nothing.
        try set(f, id, hours: 19.5)
        let first = try #require(try f.service.checkEditions([EditionCheck(bookId: id, results: [kinnear])]).first)
        #expect(first.changed)
        try f.service.undoLast()
        try set(f, id, hours: 19.5, kind: first.kind)
        #expect(try f.service.checkEditions([EditionCheck(bookId: id, results: [kinnear])]).first?.changed == false)
        #expect(try f.service.undoLabel() == nil)
    }

    /// K1, K8: a kind set by hand is never overwritten, nor a better-founded one by a weaker.
    @Test func K1_K8_checkingNeverOverwritesWhatWasSetByHandOrIsBetterFounded() throws {
        let f = try F()
        let id = try importBook(f, F.meta("A Perfect Spy (Unabridged)", "John le Carré"))
        let stated = try #require(try kind(f, id))
        #expect(stated.basis == .stated("the file's tags"))

        // The files say unabridged; three hours against twenty would infer abridged. Stated wins.
        try set(f, id, hours: 3, kind: stated)
        #expect(try f.service.checkEditions([EditionCheck(bookId: id, results: [kinnear])])
            == [EditionCheckOutcome(bookId: id, kind: stated, changed: false)])

        // Set by hand: nothing replaces it, not even what the files state.
        try set(f, id, hours: 3, kind: byHand)
        #expect(try f.service.checkEditions([EditionCheck(bookId: id, results: [kinnear])])
            == [EditionCheckOutcome(bookId: id, kind: byHand, changed: false)])
        #expect(try kind(f, id) == byHand)

        // An inferred kind gives way to what the files state (K2, on demand).
        try set(f, id, hours: 3, kind: EditionKindNote(kind: .abridged, basis: .inferred))
        #expect(try f.service.checkEditions([EditionCheck(bookId: id, results: [])])
            == [EditionCheckOutcome(bookId: id, kind: stated, changed: true)])
        // And a matched one is not replaced by an inference.
        let plain = try importBook(f, F.meta("Debt of Honor", "Tom Clancy"), files: ["debt.m4b"])
        let matched = EditionKindNote(kind: .unabridged, basis: .matched("Audible"))
        try set(f, plain, hours: 3, kind: matched)
        let listed = found(.audible, "us:B00DEBT0001", title: "Debt of Honor", author: "Tom Clancy", hours: 36, abridged: false)
        #expect(try f.service.checkEditions([EditionCheck(bookId: plain, results: [listed])]).first?.changed == false)
        #expect(try kind(f, plain) == matched)
    }
}
