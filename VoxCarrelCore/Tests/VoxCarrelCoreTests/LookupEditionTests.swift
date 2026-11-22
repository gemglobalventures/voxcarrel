import Foundation
import Testing
@testable import VoxCarrelCore

@Suite struct LookupEditionTests {
    // MARK: The types

    @Test func theLibraryOfCongressIsASource() {
        #expect(LookupSource.libraryOfCongress.title == "Library of Congress")
        #expect(LookupSource.libraryOfCongress.rawValue == "libraryOfCongress")
        #expect(LookupSource.allCases == [.openLibrary, .audible, .libraryOfCongress])
    }

    @Test func editionFactsStartUnknown() {
        let facts = EditionFacts()
        #expect(facts.format == nil)
        #expect(facts.abridged == nil)
        #expect(facts.publisher == nil)
        #expect(facts.year == nil)
        #expect(facts.stores.isEmpty)
        // A candidate made as before has nothing known about its edition.
        let candidate = LookupCandidate(id: "audible:us:B08G9PRS1K", source: .audible, metadata: BookMetadata(title: "T"))
        #expect(candidate.edition == EditionFacts())

        var other = candidate
        other.edition = EditionFacts(format: .cassette, abridged: false, publisher: "Recorded Books", year: 1987, stores: ["us"])
        #expect(other != candidate)
        #expect(other.edition.format == .cassette)
        #expect(EditionFormat(rawValue: "mp3CD") == .mp3CD)
        #expect([EditionFormat.digital, .cassette, .cd, .mp3CD, .other].map(\.label)
            == ["Digital", "Cassette", "CD", "MP3 CD", "Audio"])
    }

    @Test func aQueryHasNoNarratorUnlessGiven() {
        let plain = LookupQuery(title: "A Perfect Spy", author: "John le Carré")
        #expect(plain.narrator == nil)
        #expect(plain.wantsAudioEditions == false)
        var asked = plain
        asked.narrator = "Frank Muller"
        #expect(asked != plain)
        // A narrator alone is nothing to search with.
        #expect(LookupQuery(narrator: "Frank Muller").isEmpty)
        #expect(LookupQuery(wantsAudioEditions: true).isEmpty)
    }

    // MARK: E1

    @Test(arguments: [
        ("Le Carre\u{301}, John,", "John Le Carré"),
        ("Le Carre\u{301}, John, 1931-2020", "John Le Carré"),
        ("Muller, Frank, 1951-", "Frank Muller"),
        ("Muller, Frank,", "Frank Muller"),
        ("Muller, Frank.", "Frank Muller"),
        ("Clancy, Tom, 1947-2013.", "Tom Clancy"),
        ("  Chancellor,   Edward,  1962- ", "Edward Chancellor"),
        ("Tolkien, J. R. R.", "J. R. R. Tolkien"),
        ("Tolkien, J. R. R. (John Ronald Reuel), 1892-1973", "J. R. R. Tolkien"),
        ("King, Martin Luther, Jr., 1929-1968", "Martin Luther King Jr."),
        // Already in natural order: unchanged.
        ("Frank Muller", "Frank Muller"),
        ("John le Carré", "John le Carré"),
        ("J. R. R. Tolkien", "J. R. R. Tolkien"),
        ("Frank Muller.", "Frank Muller"),
        ("Homer", "Homer"),
        ("", ""),
        (" , ", ""),
    ])
    func E1_aCatalogueNameInNaturalOrder(raw: String, expected: String) {
        let name = LookupText.personName(fromCatalogue: raw)
        #expect(name == expected)
        // One composed character, not a letter and a separate accent.
        #expect(name.unicodeScalars.elementsEqual(expected.precomposedStringWithCanonicalMapping.unicodeScalars))
    }

    @Test func E1_theAccentIsComposed() {
        let name = LookupText.personName(fromCatalogue: "Le Carre\u{301}, John,")
        #expect(!name.unicodeScalars.contains("\u{301}"))
        #expect(name.unicodeScalars.contains("\u{E9}"))
    }

    @Test func E1_whatIsTakenIsCleaned() {
        #expect(LookupText.personName(fromCatalogue: "Muller,\u{202E} Frank\u{0},\n1951-") == "Frank Muller")
        #expect(LookupText.personName(fromCatalogue: String(repeating: "a", count: 5000)).count == LookupText.nameLimit)
    }

    // MARK: E2

    @Test(arguments: [
        ("Frank Muller", "Muller, Frank,"),
        ("Frank Muller", "frank muller"),
        ("Frank Muller", "Muller, Frank, 1951-"),
        ("John le Carré", "John Le Carre"),
        ("John le Carré", "Le Carre\u{301}, John, 1931-2020"),
        ("J. R. R. Tolkien", "JRR Tolkien"),
        ("J.R.R. Tolkien", "Tolkien, J. R. R."),
        ("Julian Rhind-Tutt", "julian rhind tutt"),
        ("Flann O'Brien", "Flann O’Brien"),
    ])
    func E2_theSamePerson(a: String, b: String) {
        #expect(LookupText.samePerson(a, b))
        #expect(LookupText.samePerson(b, a))
    }

    @Test(arguments: [
        ("Frank Muller", "Rory Kinnear"),
        ("Frank Muller", "Frank Herbert"),
        ("Frank Muller", "Frank"),
        ("John le Carré", "John Carré"),
        ("Frank Muller", ""),
        ("", ""),
        ("  ", " . "),
        (",", ","),
    ])
    func E2_differentPeopleAndEmptyNames(a: String, b: String) {
        #expect(!LookupText.samePerson(a, b))
        #expect(!LookupText.samePerson(b, a))
    }

    // MARK: E3

    @Test(arguments: [
        ("12 sound cassettes (18 hr.) : analog.", 64_800.0),
        ("18 hr.", 64_800.0),
        ("9 hr., 30 min.", 34_200.0),
        ("ca. 90 min.", 5_400.0),
        ("1 hr. 15 min", 4_500.0),
        ("8 sound discs (ca. 9 hrs., 30 mins.) : digital ; 4 3/4 in.", 34_200.0),
        ("1 sound disc (45 min.)", 2_700.0),
        ("10 1/2 hr.", 37_800.0),
        ("7.5 hours", 27_000.0),
        ("2 hours, 5 minutes", 7_500.0),
        ("1 online resource (1 audio file (11 hr., 25 min., 10 sec.))", 41_110.0),
        ("1000 hr.", 3_600_000.0),
    ])
    func E3_aLengthFromAnExtent(text: String, seconds: Double) {
        #expect(LookupText.seconds(fromExtent: text) == seconds)
    }

    @Test(arguments: [
        "", "463 p. ; 24 cm.", "12 sound cassettes : analog.", "xiv, 386 p. cm.", "0 hr.", "0 min.",
        "1001 hr.", "99999999999999999999 hr.", "24 cm", "3 hrefs", "5 minims",
        // The whole is not known when the time is for each part.
        "2 sound cassettes (ca. 90 min. each)",
    ])
    func E3_noTimeIsNil(text: String) {
        #expect(LookupText.seconds(fromExtent: text) == nil)
    }

    @Test func E3_neverNegativeNeverOverAThousandHours() {
        // A sign is not part of a time: the number alone is read.
        #expect(LookupText.seconds(fromExtent: "-5 hr.") == 18_000)
        #expect(LookupText.seconds(fromExtent: "3 hr") == 10_800)
        for text in ["999 hr. 59 min.", "1000 hr. 1 min.", "999999 min.", "5 hr. 4000000 min.", "1 hr. 99999999999 sec."] {
            if let seconds = LookupText.seconds(fromExtent: text) {
                #expect(seconds > 0)
                #expect(seconds <= 3_600_000)
            }
        }
        #expect(LookupText.seconds(fromExtent: "1000 hr. 1 min.") == nil)
        // Hostile length: answered quickly, whatever it holds.
        #expect(LookupText.seconds(fromExtent: String(repeating: "9", count: 200_000) + " hr.") == nil)
        #expect(LookupText.seconds(fromExtent: String(repeating: "1 ", count: 200_000)) == nil)
    }

    // MARK: E4

    /// The fixtures made for the wider lookup hold facts only: none of the sellers' or
    /// cataloguers' own sentences. Only the first three words of each are kept here.
    @Test func E4_fixturesHoldNoneOfTheOriginalProse() throws {
        let phrases = ["Magnus Pym, Counsellor", "Julian Rhind-Tutt is", "Brought to you", "In the small", "When British intelligence"]
        let folder = try #require(Bundle.module.resourceURL?.appendingPathComponent("Fixtures/Lookup"))
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let names = Set(files.map(\.lastPathComponent))
        for wanted in [
            "loc-perfectspy.xml", "loc-none.xml", "ol-editions.json", "au-stores-us.json", "au-stores-uk.json",
            "au-stores-au.json", "au-narrator-found.json", "au-narrator-none.json",
        ] {
            #expect(names.contains(wanted), "missing \(wanted)")
        }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8).lowercased()
            for phrase in phrases {
                #expect(!text.contains(phrase.lowercased()), "\(file.lastPathComponent) holds “\(phrase)…”")
            }
        }
    }

    /// The facts are still there.
    @Test func E4_fixturesKeepTheFacts() throws {
        let record = try #require(String(data: fixture("loc-perfectspy", type: "xml"), encoding: .utf8))
        for fact in ["Narrated by Frank Muller.", "12 sound cassettes (18 hr.) : analog.", "Unabridged.", "Recorded Books", "5615214"] {
            #expect(record.contains(fact))
        }
        let editions = try #require(try JSONSerialization.jsonObject(with: fixture("ol-editions")) as? [String: Any])
        #expect((editions["entries"] as? [Any])?.count == 23)
        for (name, count) in [("au-stores-us", 3), ("au-stores-uk", 4), ("au-stores-au", 4), ("au-narrator-found", 1), ("au-narrator-none", 0)] {
            let answer = try #require(try JSONSerialization.jsonObject(with: fixture(name)) as? [String: Any])
            #expect((answer["products"] as? [Any])?.count == count)
        }
    }
}
