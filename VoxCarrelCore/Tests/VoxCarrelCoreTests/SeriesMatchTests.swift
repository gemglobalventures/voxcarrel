import Foundation
import Testing
@testable import VoxCarrelCore

@Suite struct SeriesMatchTests {
    static func day(_ year: Int, _ month: Int = 1, _ day: Int = 1) -> Date {
        AudibleSeriesProviderTests.day(year, month, day)
    }

    /// An edition: unabridged, ten hours, released in 2010, unless said otherwise.
    static func edition(
        _ asin: String, _ title: String, _ number: String?, sort: Double? = nil, minutes: Int? = 600,
        abridged: Bool? = false, released: Date? = day(2010), narrators: [String] = []
    ) -> AudibleSeriesEdition {
        AudibleSeriesEdition(
            asin: asin, title: title, number: number, sort: sort ?? SeriesNumber.value(number) ?? 1000, authors: ["An Author"],
            narrators: narrators, minutes: minutes, isAbridged: abridged, releaseDate: released)
    }

    static func entry(_ number: String?, _ title: String, _ asins: [String], sort: Double? = nil, titles: [String]? = nil)
        -> SeriesEntry
    {
        SeriesEntry(
            number: number, sort: sort ?? SeriesNumber.value(number) ?? 1000,
            preferred: edition(asins[0], title, number, sort: sort), asins: asins, titles: titles ?? [title])
    }

    static func book(_ id: Int64, _ title: String, _ number: String? = nil, _ asins: [String] = []) -> LibrarySeriesBook {
        LibrarySeriesBook(id: id, title: title, number: number, asins: asins)
    }

    /// The recorded series, as the provider reads them.
    static func recorded(_ ref: AudibleSeriesRef) async throws -> [AudibleSeriesEdition] {
        try await AudibleSeriesProvider(http: AudibleSeriesProviderTests.recorded(), store: .us).list(ref).editions
    }

    // MARK: SC10

    @Test func SC10_editionsWithTheSameNumberAreOneEntry() {
        let entries = SeriesMatch.entries(from: [
            Self.edition("B00000000A", "One", "1"),
            Self.edition("B00000000B", "One Again", " 01 "),
            Self.edition("B00000000C", "One Once More", "1.0"),
            Self.edition("B00000000D", "One And A Half", "1.5"),
            Self.edition("B00000000E", "Half Again", "1.50"),
            Self.edition("B00000000F", "Ten", "10"),
            Self.edition("B00000000G", "A Word", "Prequel"),
            Self.edition("B00000000H", "The Same Word", " prequel "),
        ], preferring: [])
        #expect(entries.map(\.asins) == [
            ["B00000000A", "B00000000B", "B00000000C"], ["B00000000D", "B00000000E"], ["B00000000F"],
            ["B00000000G", "B00000000H"],
        ])
        #expect(entries.map(\.number) == ["1", "1.5", "10", "Prequel"])
        #expect(entries[0].titles == ["One", "One Again", "One Once More"])
    }

    @Test func SC10_editionsWithNoNumberFoldOnlyByTitle() {
        let entries = SeriesMatch.entries(from: [
            Self.edition("B00000000A", "The Short Story", nil, sort: 5),
            Self.edition("B00000000B", "short story!", "", sort: 5),
            Self.edition("B00000000C", "Another Story", nil, sort: 5),
            Self.edition("B00000000D", "Another Story", "3", sort: 5),
            Self.edition("B00000000E", "?!", nil, sort: 6),
            Self.edition("B00000000F", "...", "  ", sort: 6),
        ], preferring: [])
        #expect(entries.map(\.asins) == [
            ["B00000000D"], ["B00000000C"], ["B00000000A", "B00000000B"], ["B00000000F"], ["B00000000E"],
        ])
        #expect(entries.map(\.number) == ["3", nil, nil, nil, nil])
    }

    // MARK: SC11

    @Test func SC11_thePreferredEdition() {
        func preferred(_ editions: [AudibleSeriesEdition], owned: Set<String> = []) -> [String] {
            let entries = SeriesMatch.entries(from: editions, preferring: owned)
            #expect(entries.count == 1)
            #expect(entries.first?.preferred.asin == entries.first?.asins.first)
            return entries.first?.asins ?? []
        }
        let abridged = Self.edition("B00000000A", "Book", "1", minutes: 900, abridged: true, released: Self.day(2001))
        let short = Self.edition("B00000000B", "Book", "1", minutes: 500, released: Self.day(2002))
        let long = Self.edition("B00000000C", "Book", "1", minutes: 700, released: Self.day(2012))
        let longToo = Self.edition("B00000000D", "Book", "1", minutes: 700, released: Self.day(2011))
        let unknownKind = Self.edition("B00000000E", "Book", "1", minutes: 700, abridged: nil, released: Self.day(2011))
        let undated = Self.edition("B00000000F", "Book", "1", minutes: 700, released: nil)

        // Unabridged over abridged, though the abridged is longer and older.
        #expect(preferred([abridged, short]) == ["B00000000B", "B00000000A"])
        // Then the longest.
        #expect(preferred([abridged, short, long]) == ["B00000000C", "B00000000B", "B00000000A"])
        // Then the earliest released; one with no date after those with one.
        #expect(preferred([long, longToo, undated]) == ["B00000000D", "B00000000C", "B00000000F"])
        // An edition that does not say is taken with the unabridged; then the lowest ASIN.
        #expect(preferred([unknownKind, longToo, abridged]) == ["B00000000D", "B00000000E", "B00000000A"])
        // One the library has comes before all of that; of two it has, the usual order.
        #expect(preferred([abridged, short, long], owned: ["B00000000A"]) == ["B00000000A", "B00000000C", "B00000000B"])
        #expect(preferred([abridged, short, long], owned: ["B00000000A", "B00000000B", "B0NOTINLST"])
            == ["B00000000B", "B00000000A", "B00000000C"])
    }

    @Test func SC11_aPlaceholderIsPreferredOnlyWhenThereIsNoOther() {
        let real = Self.edition("B00000000Z", "Book", "1", minutes: 10, abridged: true, released: Self.day(2020))
        let noLength = Self.edition("B00000000A", "Book", "1", minutes: nil, released: Self.day(2000))
        let farOff = Self.edition("B00000000B", "Book", "1", minutes: 5000, released: Self.day(2200))
        let nextCentury = Self.edition("B00000000C", "Book", "1", minutes: 5000, released: Self.day(2101))
        let lastDay = Self.edition("B00000000D", "Book", "1", minutes: 20, abridged: true, released: Self.day(2100, 12, 31))

        func asins(_ editions: [AudibleSeriesEdition], owned: Set<String> = []) -> [String] {
            SeriesMatch.entries(from: editions, preferring: owned).first?.asins ?? []
        }
        #expect(asins([noLength, farOff, nextCentury, real]).first == "B00000000Z")
        // Even one the library is said to have.
        #expect(asins([noLength, real], owned: ["B00000000A"]) == ["B00000000Z", "B00000000A"])
        // The last day of 2100 is not after 2100.
        #expect(asins([real, lastDay, nextCentury]) == ["B00000000D", "B00000000Z", "B00000000C"])
        // With no other, a placeholder is all there is.
        #expect(asins([noLength]) == ["B00000000A"])
        #expect(asins([farOff, noLength], owned: ["B00000000A"]) == ["B00000000A", "B00000000B"])
    }

    // MARK: SC12

    @Test func SC12_entriesAreOrderedBySortThenNumberThenTitle() {
        let entries = SeriesMatch.entries(from: [
            Self.edition("B00000000A", "Zebra", "10", sort: 2),
            Self.edition("B00000000B", "Yak", "9", sort: 2),
            Self.edition("B00000000C", "Xerus", "9.5", sort: 2),
            Self.edition("B00000000D", "Wolf", "1-3", sort: 2),
            Self.edition("B00000000E", "Vole", nil, sort: 2),
            Self.edition("B00000000F", "The Aardvark", nil, sort: 2),
            Self.edition("B00000000G", "Last", "1", sort: 3),
            // The lowest ordering value among an entry's editions places it.
            Self.edition("B00000000H", "First", "50", sort: 7),
            Self.edition("B00000000I", "First", "50", sort: 1, minutes: 5),
        ], preferring: [])
        #expect(entries.map(\.preferred.title) == ["First", "Yak", "Xerus", "Zebra", "Wolf", "The Aardvark", "Vole", "Last"])
        #expect(entries.map(\.sort) == [1, 2, 2, 2, 2, 2, 2, 3])
        #expect(entries[0].preferred.asin == "B00000000H")
    }

    // MARK: SC13

    @Test func SC13_aRangeIsItsOwnEntry() {
        let entries = SeriesMatch.entries(from: [
            Self.edition("B00000000A", "One", "1"),
            Self.edition("B00000000B", "Two", "2"),
            Self.edition("B00000000C", "Three", "3"),
            Self.edition("B00000000D", "Books One to Three", "1-3", sort: 1),
            Self.edition("B00000000E", "The Trilogy", " 1-3 ", sort: 1),
            Self.edition("B00000000F", "Books One and Two", "1-2", sort: 1),
        ], preferring: [])
        #expect(entries.map(\.asins) == [
            ["B00000000A"], ["B00000000F"], ["B00000000D", "B00000000E"], ["B00000000B"], ["B00000000C"],
        ])
        #expect(entries.map(\.number) == ["1", "1-2", "1-3", "2", "3"])
    }

    // MARK: SC14

    @Test func SC14_aBookMatchesByASINThenTitleThenSubtitleAndNumber() {
        let entries = [
            Self.entry("1", "The First Book", ["B00000000A", "B00000000B"]),
            Self.entry("2", "Second Book: A Subtitle", ["B00000000C"]),
            Self.entry("3", "Third Book", ["B00000000D"], titles: ["Third Book", "Book the Third (Series, 3)"]),
            Self.entry("4", "Fourth Book", ["B00000000E"]),
            Self.entry("5", "Fifth Book", ["B00000000F"]),
            Self.entry("6", "Sixth Book - The End", ["B00000000G"]),
            Self.entry("7", "Seventh", ["B00000000H"]),
        ]
        let result = SeriesMatch.match(entries, with: [
            // Any edition's ASIN, however it is written, whatever the title.
            Self.book(1, "Something Else Entirely", "1", ["B0UNKNOWN1", " b00000000b "]),
            // The title as the lookup compares titles.
            Self.book(2, "  second book a SUBTITLE!", "2"),
            // The title of an edition folded in.
            Self.book(3, "Book The Third (series 3)"),
            // A subtitle on the book's side, and the same number.
            Self.book(4, "Fourth Book: Being the Fourth", "04"),
            // A subtitle and another number: not the same book.
            Self.book(5, "Fifth Book: Being the Fifth", "6"),
            // A subtitle on the entry's side, and the same number.
            Self.book(6, "The Sixth Book", "6.0"),
            // A longer title with nothing dividing it is another title.
            Self.book(7, "Seventh Heaven", "7"),
            // An ASIN the list does not have falls back on the title.
            Self.book(8, "Seventh", nil, ["B0UNKNOWN2"]),
        ])
        #expect(result.owned.map(\.bookId) == [1, 2, 3, 4, 6, 8])
        #expect(result.owned.map(\.entry.number) == ["1", "2", "3", "4", "6", "7"])
        #expect(result.owned.allSatisfy { !$0.numberDiffers })
        #expect(result.missing.map(\.number) == ["5"])
        #expect(result.notInList == [5, 7])
    }

    @Test func SC14_whatDividesATitleFromItsSubtitle() {
        func matches(_ entry: String, _ book: String) -> Bool {
            !SeriesMatch.match([Self.entry("1", entry, ["B00000000A"])], with: [Self.book(1, book, "1")]).owned.isEmpty
        }
        #expect(matches("Dune: Book One", "Dune"))
        #expect(matches("Dune - Book One", "Dune"))
        #expect(matches("Dune – Book One", "Dune"))
        #expect(matches("Dune — Book One", "Dune"))
        #expect(matches("Dune (Book One)", "Dune"))
        #expect(matches("Dune [Dramatized]", "Dune"))
        #expect(matches("Dune", "Dune: Book One"))
        #expect(matches("Tom Clancy: Power and Empire: A Jack Ryan Novel", "Tom Clancy Power and Empire"))
        // Not a subtitle: a longer title, a hyphenated word, the other half.
        #expect(!matches("Dune Messiah", "Dune"))
        #expect(!matches("Dune-Messiah", "Dune"))
        #expect(!matches("Dune: Book One", "Book One"))
        #expect(!matches("Dune: Book One", "Dune: Book Two"))
        // No guessing an author's name off the front.
        #expect(!matches("Tom Clancy Commander in Chief", "Commander in Chief"))
        // A title of nothing but punctuation is no title.
        #expect(!matches("?!", "..."))
        #expect(!matches(": Book One", ""))
    }

    // A subtitle is not enough without a number on both sides.
    @Test func SC14_aSubtitleMatchNeedsANumberOnBothSides() {
        let numbered = [Self.entry("1", "Dune: Book One", ["B00000000A"])]
        let unnumbered = [Self.entry(nil, "Dune: Book One", ["B00000000A"])]
        #expect(SeriesMatch.match(numbered, with: [Self.book(1, "Dune", nil)]).owned.isEmpty)
        #expect(SeriesMatch.match(unnumbered, with: [Self.book(1, "Dune", "1")]).owned.isEmpty)
        #expect(SeriesMatch.match(unnumbered, with: [Self.book(1, "Dune", nil)]).owned.isEmpty)
        #expect(SeriesMatch.match(numbered, with: [Self.book(1, "Dune", "1")]).owned.map(\.bookId) == [1])
    }

    // MARK: SC15

    @Test func SC15_oneBookToAnEntryAndASINsBeforeTitles() {
        let entries = [
            Self.entry("1", "First", ["B00000000A"]),
            Self.entry("2", "Second", ["B00000000B"]),
            Self.entry("3", "Second", ["B00000000C"]),
        ]
        // Book 1 has the title, book 2 the ASIN: the ASIN wins though its id is higher.
        var result = SeriesMatch.match(entries, with: [Self.book(1, "First"), Self.book(2, "Other", nil, ["B00000000A"])])
        #expect(result.owned.map(\.bookId) == [2])
        #expect(result.notInList == [1])
        // Two books with the title: the lower id.
        result = SeriesMatch.match(entries, with: [Self.book(9, "First"), Self.book(4, "First")])
        #expect(result.owned.map(\.bookId) == [4])
        #expect(result.notInList == [9])
        // Two books with the same ASIN: the lower id; the other may still match by title elsewhere.
        result = SeriesMatch.match(entries, with: [
            Self.book(8, "Second", nil, ["B00000000A"]), Self.book(7, "Whatever", nil, ["B00000000A"]),
        ])
        #expect(result.owned.map(\.bookId) == [7, 8])
        #expect(result.owned.map(\.entry.number) == ["1", "2"])
        // Two entries with one title: each book gets one, the entry with the book's number first.
        result = SeriesMatch.match(entries, with: [Self.book(1, "Second", "3"), Self.book(2, "Second")])
        #expect(result.owned.map(\.bookId) == [2, 1])
        #expect(result.owned.map(\.entry.number) == ["2", "3"])
        #expect(result.missing.map(\.number) == ["1"])
        // A book holding the ASINs of two entries is one book: it takes the first.
        result = SeriesMatch.match(entries, with: [Self.book(1, "Second", nil, ["B00000000C", "B00000000B"])])
        #expect(result.owned.map(\.entry.number) == ["2"])
        #expect(result.missing.map(\.number) == ["1", "3"])
        // An equal title is taken before a subtitle and number.
        result = SeriesMatch.match(
            [Self.entry("1", "Dune: Book One", ["B00000000A"])],
            with: [Self.book(1, "Dune", "1"), Self.book(2, "Dune Book One", "5")])
        #expect(result.owned.map(\.bookId) == [2])
        #expect(result.notInList == [1])
    }

    // MARK: SC16

    @Test func SC16_whenTheNumbersDiffer() {
        let entries = [
            Self.entry("1", "One", ["B00000000A"]), Self.entry("02", "Two", ["B00000000B"]),
            Self.entry("3", "Three", ["B00000000C"]), Self.entry(nil, "Extra", ["B00000000D"], sort: 4),
            Self.entry("1-3", "Omnibus", ["B00000000E"], sort: 5), Self.entry("6", "Six", ["B00000000F"]),
        ]
        let result = SeriesMatch.match(entries, with: [
            Self.book(1, "One", "1.0"), Self.book(2, "Two", "2"), Self.book(3, "Three", "4"), Self.book(4, "Extra", "9"),
            Self.book(5, "Omnibus", " 1-3"), Self.book(6, "Six", nil),
        ])
        #expect(result.owned.map(\.bookId) == [1, 2, 3, 4, 5, 6])
        #expect(result.owned.map(\.numberDiffers) == [false, false, true, false, false, false])
        let other = SeriesMatch.match(entries, with: [Self.book(5, "Omnibus", "1"), Self.book(6, "Six", "  ")])
        #expect(other.owned.map(\.numberDiffers) == [true, false])
    }

    // MARK: SC17

    @Test func SC17_whatIsMissingAndWhatIsNotInTheList() {
        let entries = [
            Self.entry("3", "Three", ["B00000000C"]), Self.entry("1", "One", ["B00000000A"]),
            Self.entry("2", "Two", ["B00000000B"]), Self.entry("10", "Ten", ["B00000000D"]),
        ]
        let result = SeriesMatch.match(entries, with: [
            Self.book(30, "Unknown"), Self.book(20, "Two"), Self.book(10, "Also Unknown", "1"),
        ])
        #expect(result.owned == [
            SeriesMatchResult.Owned(bookId: 20, entry: Self.entry("2", "Two", ["B00000000B"]), numberDiffers: false),
        ])
        #expect(result.missing.map(\.number) == ["1", "3", "10"])
        #expect(result.notInList == [10, 30])
        // Nothing in the list, and nothing in the library.
        #expect(SeriesMatch.match([], with: [Self.book(2, "Two"), Self.book(1, "One")])
            == SeriesMatchResult(owned: [], missing: [], notInList: [1, 2]))
        #expect(SeriesMatch.match(entries, with: []).missing.map(\.number) == ["1", "2", "3", "10"])
        #expect(SeriesMatch.entries(from: [], preferring: ["B00000000A"]).isEmpty)
    }

    // MARK: SC18

    @Test func SC18_theSameWhateverTheOrderOfWhatIsGiven() async throws {
        let editions = try await Self.recorded(AudibleSeriesProviderTests.ryan)
            + [Self.edition("B0EXTRA001", "A Short Story", nil), Self.edition("B0EXTRA002", "A Short Story", nil)]
        let owned: Set<String> = ["B078XLLJBN", "B017JCMF2C"]
        let entries = SeriesMatch.entries(from: editions, preferring: owned)
        let books = [
            Self.book(5, "Debt of Honor", "7"), Self.book(3, "The Hunt for Red October", "1", ["B078XLLJBN"]),
            Self.book(9, "The Hunt for Red October", "1"), Self.book(1, "Without Remorse", "6"),
            Self.book(4, "Patriot Games: A Jack Ryan Novel", "2"), Self.book(2, "Patriot Games", "2"),
        ]
        let result = SeriesMatch.match(entries, with: books)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            let shuffled = SeriesMatch.entries(from: editions.shuffled(using: &generator), preferring: owned)
            #expect(shuffled == entries)
            #expect(SeriesMatch.match(shuffled.shuffled(using: &generator), with: books.shuffled(using: &generator)) == result)
        }
        // An edition given twice is one edition.
        #expect(SeriesMatch.entries(from: editions + editions.reversed(), preferring: owned) == entries)
    }

    // MARK: The recorded series

    @Test func recorded_twoEditionsOfANumberReadByDifferentPeople() async throws {
        let editions = try await Self.recorded(AudibleSeriesProviderTests.ryan)
        let entries = SeriesMatch.entries(from: editions, preferring: [])
        // Forty-nine editions, twenty-seven books.
        #expect(entries.map(\.number) == (1...27).map(String.init))
        #expect(entries.flatMap(\.asins).count == 49)
        // "The Hunt for Red October": 17h 19m read by Lance C. Fuller, 18h 42m by Scott Brick.
        #expect(entries[0].asins == ["B07D2HN6PP", "B078XLLJBN"])
        #expect(entries[0].preferred.narrators == ["Scott Brick"])
        #expect(entries[0].titles == ["The Hunt for Red October"])
        // The one the library has is preferred.
        let owning = SeriesMatch.entries(from: editions, preferring: ["B078XLLJBN"])
        #expect(owning[0].asins == ["B078XLLJBN", "B07D2HN6PP"])
        #expect(owning[0].preferred.narrators == ["Lance C. Fuller"])
        #expect(owning.dropFirst() == entries.dropFirst())
        // Equal in kind, length and date: the lower ASIN.
        #expect(entries[12].asins == ["B00GM3L0DU", "B00GWT4UAY"])
    }

    @Test func recorded_twoTitlesOfOneBookAreOneEntry() async throws {
        let entries = SeriesMatch.entries(from: try await Self.recorded(AudibleSeriesProviderTests.ryan), preferring: [])
        let entry = entries[14]
        #expect(entry.number == "15")
        #expect(entry.asins == ["B011PVT3A0", "B017JCMF2C"])
        #expect(entry.preferred.title == "Tom Clancy Commander-in-Chief")
        #expect(entry.titles == ["Tom Clancy Commander-in-Chief", "Tom Clancy Commander in Chief: Jack Ryan, Book 11"])
        // A library book under either title is that entry, whatever number it carries.
        for (title, number) in [
            ("Tom Clancy Commander in Chief", "15"), ("Tom Clancy Commander in Chief: Jack Ryan, Book 11", "11"),
            ("Tom Clancy Commander-in-Chief", nil),
        ] {
            let result = SeriesMatch.match(entries, with: [Self.book(1, title, number)])
            #expect(result.owned.map(\.entry) == [entry])
            #expect(result.owned.map(\.numberDiffers) == [number == "11"])
            #expect(result.missing.count == 26)
            #expect(result.notInList.isEmpty)
        }
    }

    @Test func recorded_aPlaceholderDatedTwentyTwoHundredWithNoLength() async throws {
        let editions = try await Self.recorded(AudibleSeriesProviderTests.chrono)
        let entries = SeriesMatch.entries(from: editions, preferring: [])
        #expect(entries.map(\.number) == ["19", "20", "21"])
        #expect(entries[1].asins == ["0593106792", "B07RC4LDGB"])
        #expect(entries[1].preferred.minutes == 819)
        // Not even when the library is said to have it.
        #expect(SeriesMatch.entries(from: editions, preferring: ["B07RC4LDGB"])[1].asins == ["0593106792", "B07RC4LDGB"])
        // Alone, it is the entry.
        let alone = SeriesMatch.entries(from: editions.filter { $0.asin == "B07RC4LDGB" }, preferring: [])
        #expect(alone.map(\.preferred.asin) == ["B07RC4LDGB"])
        #expect(alone.first?.preferred.minutes == nil)
    }

    // The owner's "Without Remorse", numbered 6 in their Jack Ryan series: Audible's list
    // leaves the book out and has "Debt of Honor" as its number 6.
    @Test func recorded_aLibraryBookTheListDoesNotInclude() async throws {
        let entries = SeriesMatch.entries(from: try await Self.recorded(AudibleSeriesProviderTests.ryan), preferring: [])
        let result = SeriesMatch.match(entries, with: [
            Self.book(1, "The Hunt for Red October", "1"),
            Self.book(2, "Without Remorse", "6", ["B004FG2QGQ"]),
            Self.book(3, "Debt of Honor", "7"),
            Self.book(4, "Unrelated Title", nil, ["B00GWT4UAY"]),
            Self.book(5, "Patriot Games: A Jack Ryan Novel", "2"),
            Self.book(6, "Clear and Present Danger - Unabridged", "9"),
        ])
        #expect(result.notInList == [2, 6])
        #expect(result.owned.map(\.bookId) == [1, 5, 3, 4])
        #expect(result.owned.map(\.entry.number) == ["1", "2", "6", "13"])
        #expect(result.owned.map(\.entry.preferred.title) == [
            "The Hunt for Red October", "Patriot Games", "Debt of Honor", "Command Authority",
        ])
        // "Debt of Honor" is 7 to the owner and 6 to Audible.
        #expect(result.owned.map(\.numberDiffers) == [false, false, true, false])
        // Number 6 is not taken for missing because "Without Remorse" is numbered 6, nor owned because of it.
        #expect(result.missing.count == 23)
        #expect(!result.missing.contains { $0.number == "6" })
        #expect(result.missing.contains { $0.preferred.title == "Clear and Present Danger" })
    }
}
