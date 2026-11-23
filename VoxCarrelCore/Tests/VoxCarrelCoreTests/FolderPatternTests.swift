import Foundation
import Testing
@testable import VoxCarrelCore

/// The fixed filing rule as it was before folders followed a pattern, kept word for
/// word so that the standard pattern can be held to it (FP7). Not to be "improved".
///
/// One correction has been made to it, the same one made to `PathBuilder.sanitise`
/// (FP42): "/" and ":" are replaced one Unicode scalar at a time, so that one followed
/// by a combining mark is replaced too.
enum FixedRuleReference {
    static let maxComponentLength = 200

    static func sanitise(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
            scalars.append(scalar == "/" || scalar == ":" ? "-" : scalar)
        }
        var s = String(scalars)
        s = String(s.prefix(maxComponentLength))
        while let first = s.first, first == "." || first == " " { s.removeFirst() }
        while let last = s.last, last == "." || last == " " { s.removeLast() }
        return s
    }

    private static func capped(_ sanitised: String, to length: Int) -> String {
        var s = String(sanitised.prefix(max(length, 1)))
        while let last = s.last, last == "." || last == " " { s.removeLast() }
        return s
    }

    static func bookFolder(metadata: BookMetadata) -> String? {
        let title = sanitise(metadata.title)
        let author = sanitise(metadata.authors.first ?? "")
        guard !title.isEmpty, !author.isEmpty else { return nil }

        var parts = [author]
        let series = sanitise(metadata.series ?? "")
        if series.isEmpty {
            parts.append(title)
        } else {
            parts.append(series)
            let number = sanitise(metadata.seriesNumber ?? "")
            parts.append(
                number.isEmpty ? title : capped("\(number) - \(title)", to: maxComponentLength))
        }
        return parts.joined(separator: "/")
    }
}

/// Random numbers that are the same on every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct FolderPatternTests {
    // MARK: Support

    static func book(
        _ title: String, _ authors: [String] = ["Andy Weir"], series: String? = nil, number: String? = nil,
        narrators: [String] = [], year: Int? = nil, genre: String? = nil, publisher: String? = nil,
        language: String? = nil
    ) -> BookMetadata {
        var m = BookMetadata(title: title, authors: authors)
        m.series = series
        m.seriesNumber = number
        m.narrators = narrators
        m.year = year
        m.genre = genre
        m.publisher = publisher
        m.language = language
        return m
    }

    static func folder(_ pattern: String, _ metadata: BookMetadata, hasAudio: Bool = true) throws -> String? {
        try FolderPattern(pattern).folder(for: FolderPatternValues(metadata: metadata, hasAudio: hasAudio))
    }

    static func problem(_ text: String) -> FolderPatternProblem? {
        do {
            _ = try FolderPattern(text)
            return nil
        } catch {
            return error as? FolderPatternProblem
        }
    }

    // MARK: FP1 Tokens, fixed text and optional parts

    @Test func fp1_everyTokenIsReadWhateverItsCapitals() throws {
        for token in FolderToken.allCases {
            for name in [token.rawValue, token.rawValue.lowercased(), token.rawValue.uppercased()] {
                let pattern = try FolderPattern("{\(name)}/{Title}")
                #expect(pattern.requiredTokens == [token, .title])
            }
        }
    }

    @Test func fp1_anyOtherBracedNameIsAnUnknownToken() {
        #expect(Self.problem("{Auther}/{Title}") == .unknownToken("{Auther}"))
        #expect(Self.problem("{}/{Title}") == .unknownToken("{}"))
        #expect(Self.problem("{ Author }/{Title}") == .unknownToken("{ Author }"))
    }

    @Test func fp1_textOutsideTokensIsKeptAsItIs() throws {
        let m = Self.book("Dune", ["Frank Herbert"], year: 1965)
        #expect(try Self.folder("Books by {Author}/{Title} ({Year})", m) == "Books by Frank Herbert/Dune (1965)")
    }

    @Test func fp1_anOptionalPartMaySpanASlashButNotNest() throws {
        let m = Self.book("Dune", ["Frank Herbert"], series: "Dune Saga", number: "1")
        #expect(try Self.folder("{Author}/[{Series}/{Number} - ]{Title}", m) == "Frank Herbert/Dune Saga/1 - Dune")
        #expect(Self.problem("{Author}/[{Series}[{Number}]]/{Title}") == .nestedBracket)
    }

    // MARK: FP2 Problems

    @Test func fp2_eachProblemIsFound() {
        #expect(Self.problem("") == .empty)
        #expect(Self.problem("   \n ") == .empty)
        #expect(Self.problem("{Auther}/{Title}") == .unknownToken("{Auther}"))
        #expect(Self.problem("{Author/{Title}") == .unclosedBrace)
        #expect(Self.problem("{Author}/{Title") == .unclosedBrace)
        #expect(Self.problem("{Author}/[{Series}/{Title}") == .unclosedBracket)
        #expect(Self.problem("{Author}/[[{Series}]/]{Title}") == .nestedBracket)
        #expect(Self.problem("{Author}]/{Title}") == .strayClosing)
        #expect(Self.problem("{Author}}/{Title}") == .strayClosing)
        #expect(Self.problem("{Author}//{Title}") == .emptyLevel)
        #expect(Self.problem("/{Author}/{Title}") == .emptyLevel)
        #expect(Self.problem("{Author}/{Title}/") == .emptyLevel)
        #expect(Self.problem("{Author}/ /{Title}") == .emptyLevel)
        #expect(Self.problem("a/b/c/d/e/f/{Title}") == .tooManyLevels(7))
        #expect(Self.problem("a/b/c/d/e/{Title}") == nil)
        #expect(Self.problem("{Author}/{Series}") == .lastLevelNeedsTitle)
        #expect(Self.problem("{Author}/[{Title}]") == .lastLevelNeedsTitle)
        #expect(Self.problem("{Title}/{Author}") == .lastLevelNeedsTitle)
        #expect(Self.problem("{Author}/./{Title}") == .dotLevel)
        #expect(Self.problem("../{Title}") == .dotLevel)
        #expect(Self.problem("{Author}/ .. /{Title}") == .dotLevel)
        #expect(Self.problem(String(repeating: "a", count: 494) + "{Title}") == .tooLong)
        #expect(Self.problem(String(repeating: "a", count: 493) + "{Title}") == nil)
        #expect(Self.problem("{Title}|{Title}|{Title}|{Title}") == .tooManyAlternatives)
    }

    @Test func fp2_theFirstProblemInReadingOrderIsTheOneThrown() {
        // An unknown token, then a stray bracket, then no title in the last level.
        #expect(Self.problem("{Auther}]/x") == .unknownToken("{Auther}"))
        #expect(Self.problem("{Author}]/{Auther}") == .strayClosing)
        #expect(Self.problem("{Author}//{Auther}") == .emptyLevel)
        #expect(Self.problem("{Author}/[{Series}/{Auther}") == .unclosedBracket)
        #expect(Self.problem("{Author}/{Auther}/") == .unknownToken("{Auther}"))
        #expect(Self.problem("{Author}/x/") == .emptyLevel)
        #expect(Self.problem("./{Author}//") == .dotLevel)
        // In a later alternative only once the earlier ones are sound.
        #expect(Self.problem("{Title}|{Auther}") == .unknownToken("{Auther}"))
        #expect(Self.problem("{Author}|{Auther}") == .lastLevelNeedsTitle)
    }

    @Test func fp2_aLevelOfFixedTextThatLeavesNoNameIsAnEmptyLevel() {
        #expect(Self.problem("{Author}/.../{Title}") == .emptyLevel)
        #expect(Self.problem("{Author}/. ./{Title}") == .emptyLevel)
    }

    // MARK: FP3 Values

    @Test func fp3_valuesAreMadeSafeSoTheyNeverMakeALevel() throws {
        let m = Self.book("AC/DC: Live", ["Smith/Jones: A Life"], series: "a/b", number: "1/2")
        #expect(try Self.folder("{Author}/{Series}/{Number} - {Title}", m)
            == "Smith-Jones- A Life/a-b/1-2 - AC-DC- Live")
        #expect(try Self.folder("{Author}/{Title}", Self.book("../../etc", [".."])) == nil)
        #expect(try Self.folder("{Author}/{Title}", Self.book("../../etc", ["../x"])) == "-x/-..-etc")
    }

    @Test func fp3_authorAndNarratorAreTheFirstOfTheirLists() throws {
        let m = Self.book("Dune", ["Frank Herbert", "Brian Herbert"], narrators: ["Scott Brick", "Simon Vance"])
        #expect(try Self.folder("{Narrator}/{Author}/{Title}", m) == "Scott Brick/Frank Herbert/Dune")
        // The first, even when it is empty and a later one is not.
        #expect(try Self.folder("{Author}/{Title}", Self.book("Dune", ["", "Brian Herbert"])) == nil)
    }

    @Test func fp3_yearIsFourDigitsOrNothing() throws {
        #expect(try Self.folder("{Year}/{Title}", Self.book("Dune", year: 1965)) == "1965/Dune")
        #expect(try Self.folder("{Year}/{Title}", Self.book("Dune", year: 868)) == "0868/Dune")
        for year in [nil, 0, -44, 10_000, 123_456] as [Int?] {
            #expect(try Self.folder("{Year}/{Title}", Self.book("Dune", year: year)) == nil)
            #expect(try Self.folder("[{Year}/]{Title}", Self.book("Dune", year: year)) == "Dune")
        }
    }

    @Test func fp3_kindGoesByWhetherTheBookHasAudio() throws {
        let m = Self.book("Dune")
        #expect(try Self.folder("{Kind}/{Title}", m, hasAudio: true) == "Audiobooks/Dune")
        #expect(try Self.folder("{Kind}/{Title}", m, hasAudio: false) == "Ebooks/Dune")
        #expect(try FolderPattern("{Kind}/{Title}").usesKind)
        #expect(try FolderPattern("{Title}|[{Kind}/]{Title}").usesKind)
        #expect(try !FolderPattern("{Author}/{Title}").usesKind)
    }

    @Test func fp3_theOtherTokensTakeTheBooksOwnText() throws {
        let m = Self.book("Dune", genre: "Science Fiction", publisher: "Ace: Books", language: "en")
        #expect(try Self.folder("{Genre}/{Publisher}/{Language}/{Title}", m) == "Science Fiction/Ace- Books/en/Dune")
    }

    @Test func fp3_aNumberSaysNothingWithoutASeries() throws {
        // As the fixed rule: a number is only used inside its series.
        let m = Self.book("Dune", number: "3")
        #expect(try Self.folder("{Author}/[{Number} - ]{Title}", m) == "Andy Weir/Dune")
        #expect(try Self.folder("{Author}/{Number} - {Title}", m) == nil)
        #expect(try FolderPattern("{Number} - {Title}")
            .missingTokens(for: FolderPatternValues(metadata: m, hasAudio: true)) == [.number])
    }

    // MARK: FP4 Optional parts and required values

    @Test func fp4_anOptionalPartGoesWholeWhenAnyTokenInItHasNoValue() throws {
        let pattern = "{Author}/[{Series} ({Year})/]{Title}"
        #expect(try Self.folder(pattern, Self.book("Dune", series: "Saga", year: 1965)) == "Andy Weir/Saga (1965)/Dune")
        #expect(try Self.folder(pattern, Self.book("Dune", series: "Saga")) == "Andy Weir/Dune")
        #expect(try Self.folder(pattern, Self.book("Dune", year: 1965)) == "Andy Weir/Dune")
        // Empty once made safe counts as no value.
        #expect(try Self.folder(pattern, Self.book("Dune", series: " .. ", year: 1965)) == "Andy Weir/Dune")
        // An optional part with no token in it always stays.
        #expect(try Self.folder("{Author}/[Books/]{Title}", Self.book("Dune")) == "Andy Weir/Books/Dune")
    }

    @Test func fp4_aRequiredTokenWithNoValueMeansNoFolder() throws {
        let pattern = try FolderPattern("{Narrator}/{Author}/[{Series}/]{Title} - {Narrator} {Year}")
        let values = FolderPatternValues(metadata: Self.book("Dune", []), hasAudio: true)
        #expect(pattern.folder(for: values) == nil)
        // In pattern order, each once; tokens in brackets are never missing.
        #expect(pattern.missingTokens(for: values) == [.narrator, .author, .year])
        #expect(pattern.requiredTokens == [.narrator, .author, .title, .year])

        let full = FolderPatternValues(
            metadata: Self.book("Dune", narrators: ["Scott Brick"], year: 1965), hasAudio: true)
        #expect(pattern.missingTokens(for: full) == [])
        #expect(pattern.folder(for: full) == "Scott Brick/Andy Weir/Dune - Scott Brick 1965")
    }

    // MARK: FP5 Levels

    @Test func fp5_eachLevelIsTrimmedAndMadeSafeAsAWhole() throws {
        let m = Self.book("Dune", year: 1965)
        #expect(try Self.folder(" . {Author} . / {Title} ...", m) == "Andy Weir/Dune")
        #expect(try Self.folder("{Author}/{Title}: {Year}.", m) == "Andy Weir/Dune- 1965")
    }

    @Test func fp5_aLevelIsCappedAsTheFixedRuleCaps() throws {
        var m = Self.book(String(repeating: "t", count: 300), series: "S", number: String(repeating: "9", count: 100))
        let folder = try #require(try Self.folder("{Author}/{Series}/{Number} - {Title}", m))
        let last = try #require(folder.split(separator: "/").last)
        #expect(last == String(repeating: "9", count: 100) + " - " + String(repeating: "t", count: 97))

        // Cut at a space or a dot, the level does not end in one.
        m.seriesNumber = "1"
        m.title = String(repeating: "t", count: 190) + " .  . and more"
        let cut = try #require(try Self.folder("{Author}/{Series}/{Number} - {Title}", m))
        #expect(cut.split(separator: "/").last.map(String.init) == "1 - " + String(repeating: "t", count: 190))
        #expect(PathBuilder.maxComponentLength == 200)
    }

    @Test func fp5_aLevelLeftEmptyIsRemoved() throws {
        #expect(try Self.folder("{Author}/[{Series}]/{Title}", Self.book("Dune")) == "Andy Weir/Dune")
        #expect(try Self.folder("[{Series}]/[{Genre}]/{Title}", Self.book("Dune")) == "Dune")
        #expect(try Self.folder("[{Series}]/[{Genre}]/{Title}", Self.book("Dune", genre: "SF")) == "SF/Dune")
    }

    @Test func fp5_noFolderWhenTheLastLevelIsLeftEmpty() throws {
        // The title is cut away by the cap: nothing is left of the last level.
        let dots = String(repeating: ".", count: 200)
        let pattern = try FolderPattern("{Author}/\(dots){Title}")
        let values = FolderPatternValues(metadata: Self.book("Dune"), hasAudio: true)
        #expect(pattern.folder(for: values) == nil)
        #expect(pattern.missingTokens(for: values) == [])
    }

    // MARK: FP6 Staying inside the library

    @Test func fp6_noLevelIsEverADotOrTwo() throws {
        #expect(Self.problem(".") == .dotLevel)
        #expect(Self.problem("../{Author}/{Title}") == .dotLevel)
        #expect(Self.problem("{Author}/[..]/{Title}") == .dotLevel)
        #expect(Self.problem("{Author}/[../]{Title}") == .dotLevel)

        let hostile = [".", "..", "...", " .. ", "../..", "..\u{0}", "\u{7}..", ". .", ".. /.."]
        let patterns = try [
            "{Author}/{Title}", "{Author}/[{Series}/]{Title}", ".{Author}/..{Title}", "{Series}{Author}/.{Series}/{Title}",
            "{Genre}/{Publisher}/{Language}/{Narrator}/{Number}/{Title}",
        ].map { try FolderPattern($0) }
        for a in hostile {
            for b in hostile {
                var m = Self.book(a + "x", [b + "y"], series: a, number: b, narrators: [a + "n"])
                m.genre = b + "g"
                m.publisher = a + "p"
                m.language = b + "l"
                for pattern in patterns {
                    guard let folder = pattern.folder(for: FolderPatternValues(metadata: m, hasAudio: false)) else { continue }
                    let levels = folder.components(separatedBy: "/")
                    #expect(!levels.contains("."), "\(pattern.text) gave \(folder)")
                    #expect(!levels.contains(".."), "\(pattern.text) gave \(folder)")
                    #expect(!levels.contains(""), "\(pattern.text) gave \(folder)")
                    #expect(levels.allSatisfy { !$0.hasPrefix(".") && !$0.hasPrefix(" ") })
                    #expect(levels.allSatisfy { !$0.hasSuffix(".") && !$0.hasSuffix(" ") })
                    #expect(!folder.hasPrefix("/"))
                }
            }
        }
    }

    // MARK: FP7 The standard pattern is the fixed rule

    static let oddValues: [String] = [
        "", " ", "   ", "\t", ".", "..", "...", " . ", "Dune", "Project Hail Mary", "AC/DC: Live", "a/b/c", "/", ":",
        "::/", "../..", "../../etc/passwd", ".hidden", "..hidden. ", "  spaced  ", "ends in dot.", "ends in dots...",
        "ends in space ", ". leading", " . . both . . ", "Du\u{0}ne\nPart\tOne\r", "\u{0}", "\u{7}\u{8}", "line\nbreak",
        "1", "2.5", "1-3", "10", "Book 1", "0", "- -", "Über", "Émile Zola", "e\u{301}cole", "\u{301}start", "naïve/\u{308}x",
        "a/\u{301}b", "/\u{301}", ":\u{301}", "x:\u{20DD}y/\u{301}z", "\u{301}/\u{301}:\u{301}",
        "日本語のタイトル", "👩‍👩‍👧‍👦 family", "🇳🇱🇧🇪 flags", "zero\u{200B}width", "soft\u{AD}hyphen", "\u{FEFF}bom",
        "Tolkien, J.R.R.", "J.R.R. Tolkien", "The Hobbit, or There and Back Again", "a  b", "a - b", " - ",
    ]

    /// One value: usually from the list, sometimes long, sometimes random characters.
    static func value(using rng: inout SeededGenerator) -> String {
        let pieces: [String] = [
            "a", "B", " ", ".", "/", ":", "-", "\u{0}", "\n", "é", "\u{301}", "字", "🙂", "1", "t", "/\u{301}", ":\u{308}",
        ]
        switch Int.random(in: 0..<10, using: &rng) {
        case 0...5:
            return oddValues.randomElement(using: &rng) ?? ""
        case 6:
            // Long, with spaces and dots where the cap falls.
            let length = [150, 190, 195, 196, 197, 198, 199, 200, 201, 204, 300].randomElement(using: &rng) ?? 300
            var s = ""
            for _ in 0..<length {
                s += Int.random(in: 0..<12, using: &rng) == 0 ? ([" ", ".", "/"].randomElement(using: &rng) ?? " ") : "t"
            }
            return s
        case 7:
            return String(repeating: oddValues.randomElement(using: &rng) ?? "x", count: Int.random(in: 1...60, using: &rng))
        default:
            return (0..<Int.random(in: 0...12, using: &rng)).map { _ in pieces.randomElement(using: &rng) ?? "" }.joined()
        }
    }

    static func generatedBooks(count: Int, seed: UInt64) -> [BookMetadata] {
        var rng = SeededGenerator(seed: seed)
        return (0..<count).map { _ in
            var m = BookMetadata()
            m.title = value(using: &rng)
            m.authors = (0..<Int.random(in: 0...3, using: &rng)).map { _ in value(using: &rng) }
            if Int.random(in: 0..<3, using: &rng) > 0 { m.series = value(using: &rng) }
            if Int.random(in: 0..<3, using: &rng) > 0 { m.seriesNumber = value(using: &rng) }
            m.narrators = (0..<Int.random(in: 0...2, using: &rng)).map { _ in value(using: &rng) }
            if Bool.random(using: &rng) { m.year = Int.random(in: -5...12_000, using: &rng) }
            if Bool.random(using: &rng) { m.genre = value(using: &rng) }
            return m
        }
    }

    @Test func fp7_theStandardPatternFilesEveryBookWhereTheFixedRuleDid() {
        let books = Self.generatedBooks(count: 6000, seed: 0x5EED_F01D_E12A_2026)
        var filed = 0, unfiled = 0, inSeries = 0, numbered = 0, capped = 0
        for m in books {
            let expected = FixedRuleReference.bookFolder(metadata: m)
            for hasAudio in [true, false] {
                let values = FolderPatternValues(metadata: m, hasAudio: hasAudio)
                let got = FolderPattern.standard.folder(for: values)
                #expect(got == expected, "title \(m.title.debugDescription) authors \(m.authors) series \(String(describing: m.series)) number \(String(describing: m.seriesNumber))")
                #expect((got == nil) == !FolderPattern.standard.missingTokens(for: values).isEmpty)
            }
            guard let expected else {
                unfiled += 1
                continue
            }
            filed += 1
            let levels = expected.components(separatedBy: "/")
            if levels.count >= 3 { inSeries += 1 }
            if levels.count >= 3, levels.last?.contains(" - ") == true { numbered += 1 }
            if levels.last?.count == 200 { capped += 1 }
        }
        // The books are a fair mix: every branch of the fixed rule is well covered.
        #expect(filed > 1000)
        #expect(unfiled > 500)
        #expect(inSeries > 500)
        #expect(numbered > 200)
        #expect(capped > 20)
    }

    /// FP42: no generated book is filed with more levels than the standard pattern has,
    /// counted as the disk counts them, and the generator does make the case that matters.
    @Test func fp42_noGeneratedValueAddsALevel() {
        let books = Self.generatedBooks(count: 6000, seed: 0x5EED_F01D_E12A_2026)
        var slashBeforeMark = 0
        for m in books {
            let scalars = Array(m.title.unicodeScalars)
            if zip(scalars, scalars.dropFirst()).contains(where: {
                ($0 == "/" || $0 == ":") && $1.properties.canonicalCombiningClass != .notReordered
            }) { slashBeforeMark += 1 }
            guard let folder = FolderPattern.standard.folder(for: FolderPatternValues(metadata: m, hasAudio: true))
            else { continue }
            let levels = folder.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
            #expect(levels.count == 2 || levels.count == 3, "\(folder.debugDescription)")
            #expect(!levels.contains { $0.isEmpty })
            #expect(!folder.unicodeScalars.contains(":"))
        }
        #expect(slashBeforeMark > 100)
    }

    @Test func fp7_theReferenceIsStillTodaysSanitise() {
        // The pattern makes values safe with `PathBuilder.sanitise`; the reference has its own copy.
        for value in Self.oddValues {
            #expect(PathBuilder.sanitise(value) == FixedRuleReference.sanitise(value))
        }
    }

    @Test func fp7_theFixedRulesOwnExamples() {
        func standard(_ m: BookMetadata) -> String? {
            FolderPattern.standard.folder(for: FolderPatternValues(metadata: m, hasAudio: true))
        }
        #expect(standard(Self.book("Project Hail Mary", ["Andy Weir", "Someone Else"])) == "Andy Weir/Project Hail Mary")
        #expect(standard(Self.book("Dune", ["Frank Herbert"], series: "Dune", number: "1")) == "Frank Herbert/Dune/1 - Dune")
        #expect(standard(Self.book("The Hobbit", ["J.R.R. Tolkien"], series: "Middle-earth")) == "J.R.R. Tolkien/Middle-earth/The Hobbit")
        #expect(standard(BookMetadata(title: "Dune")) == nil)
        #expect(standard(Self.book("...", ["A"])) == nil)
        #expect(standard(Self.book("Dune", ["A"], series: "S", number: "../..")) == "A/S/- - Dune")
        #expect(standard(Self.book("Dune", ["A"], number: "4")) == "A/Dune")
    }

    // MARK: FP8 Presets

    @Test func fp8_thePresetsInOrder() throws {
        let presets = FolderPattern.presets
        #expect(presets.map(\.name) == [
            "Author / Series / Title", "Author / Title", "Series / Title", "Kind / Author / Series / Title",
        ])
        #expect(presets.map(\.pattern.text) == [
            "{Author}/[{Series}/][{Number} - ]{Title}",
            "{Author}/{Title}",
            "{Series}/[{Number} - ]{Title}|{Author}/{Title}",
            "{Kind}/{Author}/[{Series}/][{Number} - ]{Title}",
        ])
        #expect(presets[0].pattern == FolderPattern.standard)
        #expect(FolderPattern.standard.text == "{Author}/[{Series}/][{Number} - ]{Title}")
        for preset in presets {
            // Each parses from its own text, and names itself.
            let parsed = try FolderPattern(preset.pattern.text)
            #expect(parsed == preset.pattern)
            #expect(parsed.presetName == preset.name)
        }
        #expect(try FolderPattern("{Title}").presetName == nil)
        #expect(presets.map(\.pattern.usesKind) == [false, false, false, true])
    }

    // MARK: FP9 Equality

    @Test func fp9_equalByTrimmedTextIgnoringTheCaseOfTokenNames() throws {
        let a = try FolderPattern("  {Author}/{Title}\n")
        let b = try FolderPattern("{author}/{TITLE}")
        #expect(a.text == "{Author}/{Title}")
        #expect(b.text == "{author}/{TITLE}")
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(Set([a, b]).count == 1)
        // Fixed text is compared as it is written.
        #expect(try FolderPattern("Books/{Title}") != FolderPattern("books/{Title}"))
        #expect(try FolderPattern("{Author}/{Title}") != FolderPattern("{Author}/ {Title}"))
    }

    // MARK: Alternatives

    @Test func alternativesAreTriedInOrder() throws {
        let pattern = "{Series}/[{Number} - ]{Title}|{Narrator}/{Title}|{Author}/{Title}"
        #expect(try Self.folder(pattern, Self.book("Dune", series: "Saga", number: "1", narrators: ["N"])) == "Saga/1 - Dune")
        #expect(try Self.folder(pattern, Self.book("Dune", narrators: ["N"])) == "N/Dune")
        #expect(try Self.folder(pattern, Self.book("Dune")) == "Andy Weir/Dune")
        #expect(try Self.folder(pattern, Self.book("Dune", [])) == nil)
    }

    @Test func alternativesAreOnlyAtTheTopLevelAndAtMostThree() {
        #expect(Self.problem("{Title}|{Title}|{Title}") == nil)
        #expect(Self.problem("{Title}|{Title}|{Title}|{Title}") == .tooManyAlternatives)
        // Inside brackets a bar ends the alternative, bracket and all.
        #expect(Self.problem("{Author}/[{Series}|{Genre}/]{Title}") == .unclosedBracket)
        #expect(Self.problem("{Author|Narrator}/{Title}") == .unclosedBrace)
    }

    @Test func eachAlternativeIsCheckedByEveryRule() {
        #expect(Self.problem("{Title}|") == .empty)
        #expect(Self.problem("|{Title}") == .empty)
        #expect(Self.problem("{Title}| |{Title}") == .empty)
        #expect(Self.problem("{Title}|{Author}") == .lastLevelNeedsTitle)
        #expect(Self.problem("{Title}|{Author}//{Title}") == .emptyLevel)
        #expect(Self.problem("{Title}|../{Title}") == .dotLevel)
        #expect(Self.problem("{Title}|a/b/c/d/e/f/{Title}") == .tooManyLevels(7))
        #expect(Self.problem("{Title}|[{Title}") == .unclosedBracket)
    }

    @Test func requiredTokensAreThoseEveryAlternativeNeeds() throws {
        let pattern = try FolderPattern("{Series}/[{Number} - ]{Title}|{Author}/{Title}")
        #expect(pattern.requiredTokens == [.title])
        #expect(try FolderPattern("{Author}/{Year}/{Title}|{Author}/{Title}").requiredTokens == [.author, .title])
    }

    @Test func missingTokensAreThoseOfTheLastAlternativeTried() throws {
        let pattern = try FolderPattern("{Series}/{Title}|{Author}/{Narrator}/{Title}")
        func missing(_ m: BookMetadata) -> [FolderToken] {
            pattern.missingTokens(for: FolderPatternValues(metadata: m, hasAudio: true))
        }
        #expect(missing(Self.book("Dune", series: "Saga")) == [])
        #expect(missing(Self.book("Dune", narrators: ["N"])) == [])
        #expect(missing(Self.book("Dune", [])) == [.author, .narrator])
        #expect(missing(Self.book("", [], series: "Saga")) == [.author, .narrator, .title])
    }

    // MARK: The table

    struct Row: Sendable, CustomTestStringConvertible {
        var pattern: String
        var book: BookMetadata
        var hasAudio = true
        var expected: String?
        var testDescription: String { "\(pattern) for \(book.title.debugDescription) by \(book.authors)" }
    }

    static let standalone = book("Project Hail Mary", ["Andy Weir"], narrators: ["Ray Porter"], year: 2021, genre: "Science Fiction")
    static let inSeries = book("Red Rabbit", ["Tom Clancy"], series: "Jack Ryan", number: "3", narrators: ["Scott Brick"], year: 2002)
    static let unnumbered = book("The Hobbit", ["J.R.R. Tolkien"], series: "Middle-earth")
    static let noAuthor = book("Beowulf", [])
    static let noTitle = book(" ", ["Anonymous"], series: "Sagas")
    static let awkward = book("What If?: Serious Answers", ["Munroe/Randall"], series: "What If...", number: "1.")

    static let table: [Row] = {
        let standard = "{Author}/[{Series}/][{Number} - ]{Title}"
        let authorTitle = "{Author}/{Title}"
        let seriesTitle = "{Series}/[{Number} - ]{Title}|{Author}/{Title}"
        let kind = "{Kind}/{Author}/[{Series}/][{Number} - ]{Title}"
        return [
            // Author / Series / Title
            Row(pattern: standard, book: standalone, expected: "Andy Weir/Project Hail Mary"),
            Row(pattern: standard, book: inSeries, expected: "Tom Clancy/Jack Ryan/3 - Red Rabbit"),
            Row(pattern: standard, book: unnumbered, expected: "J.R.R. Tolkien/Middle-earth/The Hobbit"),
            Row(pattern: standard, book: noAuthor, expected: nil),
            Row(pattern: standard, book: noTitle, expected: nil),
            Row(pattern: standard, book: awkward, expected: "Munroe-Randall/What If/1 - What If?- Serious Answers"),
            // Author / Title
            Row(pattern: authorTitle, book: standalone, expected: "Andy Weir/Project Hail Mary"),
            Row(pattern: authorTitle, book: inSeries, expected: "Tom Clancy/Red Rabbit"),
            Row(pattern: authorTitle, book: unnumbered, expected: "J.R.R. Tolkien/The Hobbit"),
            Row(pattern: authorTitle, book: noAuthor, expected: nil),
            Row(pattern: authorTitle, book: noTitle, expected: nil),
            Row(pattern: authorTitle, book: awkward, expected: "Munroe-Randall/What If?- Serious Answers"),
            // Series / Title: series books under their series, the others under their author
            Row(pattern: seriesTitle, book: standalone, expected: "Andy Weir/Project Hail Mary"),
            Row(pattern: seriesTitle, book: inSeries, expected: "Jack Ryan/3 - Red Rabbit"),
            Row(pattern: seriesTitle, book: unnumbered, expected: "Middle-earth/The Hobbit"),
            Row(pattern: seriesTitle, book: noAuthor, expected: nil),
            Row(pattern: seriesTitle, book: book("Beowulf", [], series: "Sagas"), expected: "Sagas/Beowulf"),
            Row(pattern: seriesTitle, book: noTitle, expected: nil),
            Row(pattern: seriesTitle, book: awkward, expected: "What If/1 - What If?- Serious Answers"),
            // Kind / Author / Series / Title
            Row(pattern: kind, book: standalone, expected: "Audiobooks/Andy Weir/Project Hail Mary"),
            Row(pattern: kind, book: standalone, hasAudio: false, expected: "Ebooks/Andy Weir/Project Hail Mary"),
            Row(pattern: kind, book: inSeries, expected: "Audiobooks/Tom Clancy/Jack Ryan/3 - Red Rabbit"),
            Row(pattern: kind, book: unnumbered, hasAudio: false, expected: "Ebooks/J.R.R. Tolkien/Middle-earth/The Hobbit"),
            Row(pattern: kind, book: noAuthor, expected: nil),
            Row(pattern: kind, book: noTitle, hasAudio: false, expected: nil),
            // Patterns of the owner's own
            Row(pattern: "{Narrator}/{Title}", book: inSeries, expected: "Scott Brick/Red Rabbit"),
            Row(pattern: "{Narrator}/{Title}", book: unnumbered, expected: nil),
            Row(pattern: "{Genre}/{Author}/{Title} ({Year})", book: standalone, expected: "Science Fiction/Andy Weir/Project Hail Mary (2021)"),
            Row(pattern: "{Genre}/{Author}/{Title} ({Year})", book: inSeries, expected: nil),
            Row(pattern: "[{Genre}/]{Author}/{Title}[ ({Year})]", book: inSeries, expected: "Tom Clancy/Red Rabbit (2002)"),
            Row(pattern: "[{Genre}/]{Author}/{Title}[ ({Year})]", book: unnumbered, expected: "J.R.R. Tolkien/The Hobbit"),
            Row(pattern: "Books/{Author} - {Title}", book: standalone, expected: "Books/Andy Weir - Project Hail Mary"),
            Row(pattern: "{author}/[{series} #{number}/]{title}", book: inSeries, expected: "Tom Clancy/Jack Ryan #3/Red Rabbit"),
            Row(pattern: "{author}/[{series} #{number}/]{title}", book: unnumbered, expected: "J.R.R. Tolkien/The Hobbit"),
            Row(pattern: "{Title}", book: noAuthor, expected: "Beowulf"),
            Row(pattern: "{Language}/{Title}|Unsorted/{Title}", book: noAuthor, expected: "Unsorted/Beowulf"),
        ]
    }()

    @Test(arguments: table)
    func theTable(_ row: Row) throws {
        #expect(try Self.folder(row.pattern, row.book, hasAudio: row.hasAudio) == row.expected)
    }
}
