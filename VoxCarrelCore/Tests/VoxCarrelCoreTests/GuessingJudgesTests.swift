import Foundation
import Testing
@testable import VoxCarrelCore

@Suite struct NameShapeTests {
    // IM1
    @Test(arguments: [
        "James F. Dalton", "J.R.R. Tolkien", "Ursula K. Le Guin", "Gabriel García Márquez",
        "Dalton, James F.", "Mick Herron", "John le Carré", "N. K. Jemisin",
        "George R. R. Martin", "Louis de Bernières", "Ludwig van Beethoven", "Flann O'Brien",
        "Jean-Paul Sartre", "Harry S Truman", "Le Guin, Ursula K.", "Martin Luther King Jr.",
        "Douglas Preston & Lincoln Child", "Terry Pratchett and Neil Gaiman",
        "  Andy Weir  ",
    ])
    func namesArePersonShaped(_ text: String) {
        #expect(NameShape.looksLikePerson(text))
    }

    // IM1
    @Test(arguments: [
        "Mind Over Markets", "The Hunt for Red October", "Dune", "1984", "Project Hail Mary",
        "Debt of Honor", "", "   ", "Tolkien", "J.R.R.", "Mind Over Markets: Power Tradin",
        "Mind Over Markets_ Power Tradin", "Pride and Prejudice", "War & Peace", "Catch-22",
        "Fahrenheit 451", "A Brief History", "How Proust Changed", "mick herron", "Dune Messiah 2",
        "Ready Player One [B09WXN61GL]", "Slow Horses (Unabridged)",
        "An Unnecessarily Long Name That Goes On And On Forever",
        "Aaaaaaaaaaaaaaaaaaaaa Bbbbbbbbbbbbbbbbbbbbbbbbbb",
        "One Two Three Four Five", "King, Martin Luther, Jr.", "van der", "F. K.",
        "The Great Courses", "The Beatles", "A Tribe", "An Author",
    ])
    func titlesAndOtherTextAreNot(_ text: String) {
        #expect(!NameShape.looksLikePerson(text))
    }

    // IM2: shape alone cannot tell these apart; the caller must not decide on it.
    @Test func twoCapitalisedWordsAreNameShapedWhateverTheyMean() {
        #expect(NameShape.looksLikePerson("Slow Horses"))
        #expect(NameShape.looksLikePerson("Mick Herron"))
        #expect(NameShape.looksLikePerson("Dune Messiah"))
    }

    // A side that begins with an article is never a person, and may be a group's name.
    @Test func textThatBeginsWithAnArticleIsToldApart() {
        for text in ["The Great Courses", "The Beatles", "a tribe called quest", " An Author Collective"] {
            #expect(NameShape.beginsWithArticle(text), "\(text)")
            #expect(!NameShape.looksLikePerson(text), "\(text)")
        }
        for text in ["Theory Basics", "Ancient Greece", "Abbey Road", "Anne Tyler", "A", "The", "", "A. A. Milne"] {
            #expect(!NameShape.beginsWithArticle(text), "\(text)")
        }
    }

    // IM7
    @Test func aVeryLongTextIsJudgedQuickly() {
        let clock = ContinuousClock()
        for text in [
            String(repeating: "Ab ", count: 33_334), String(repeating: "A", count: 100_000),
            String(repeating: "A. ", count: 33_334), String(repeating: ", ", count: 50_000),
            String(repeating: "A & ", count: 25_000),
        ] {
            var answer = true
            let taken = clock.measure { answer = NameShape.looksLikePerson(text) }
            #expect(!answer)
            #expect(taken < .seconds(2))
        }
    }
}

@Suite struct TitleMatchTests {
    // IM3
    @Test func coreDropsCaseAccentsPunctuationAndALeadingArticle() {
        #expect(TitleMatch.core("Mind Over Markets") == "mind over markets")
        #expect(TitleMatch.core("  The Hobbit! ") == "hobbit")
        #expect(TitleMatch.core("Les Misérables") == "les miserables")
        #expect(TitleMatch.core("Ｄｕｎｅ") == "dune")
        #expect(TitleMatch.core("") == "")
        // The same normalising as the lookup's.
        for title in ["The Hunt for Red October", "A Wizard of Earthsea", "Don't Look Now", "Catch-22"] {
            #expect(TitleMatch.core(title) == LookupText.comparable(title).joined(separator: " "))
        }
    }

    // IM3
    @Test(arguments: [
        "Mind Over Markets (Unabridged)", "Mind over markets", "Mind Over Markets [Unabridged]",
        "Mind Over Markets - Unabridged", "Mind Over Markets, Unabridged", "Mind Over Markets (Abridged)",
        "Mind Over Markets (Audiobook)", "Mind Over Markets [Audio Book]", "Mind Over Markets (Audio Edition)",
        "Mind Over Markets (Dramatized)", "Mind Over Markets (dramatised)", "Mind Over Markets [FULL CAST]",
        "Mind Over Markets ( Unabridged )", "Mind Over Markets (Unabridged) [Audiobook]",
        "Mind Over Markets, Unabridged (Audiobook) ", "MIND OVER MARKETS - audiobook",
    ])
    func editionWordsAtTheEndAreDropped(_ title: String) {
        #expect(TitleMatch.core(title) == "mind over markets")
    }

    // IM3
    @Test func editionWordsElsewhereAndOtherBracketsStay() {
        #expect(TitleMatch.core("Unabridged") == "unabridged")
        #expect(TitleMatch.core("(Unabridged)") == "unabridged")
        #expect(TitleMatch.core("Abridged") == "abridged")
        #expect(TitleMatch.core("The Unabridged Journals") == "unabridged journals")
        #expect(TitleMatch.core("Full Cast and Crew") == "full cast and crew")
        #expect(TitleMatch.core("Dune (Unabridged) Messiah") == "dune unabridged messiah")
        #expect(TitleMatch.core("Dune Unabridged") == "dune unabridged")
        #expect(TitleMatch.core("Dune (Book One)") == "dune book one")
        #expect(TitleMatch.core("Dune (Unabridged Edition)") == "dune unabridged edition")
        #expect(TitleMatch.core("Dune: Unabridged") == "dune unabridged")
        #expect(TitleMatch.core("Dune (Unabridged") == "dune unabridged")
        #expect(TitleMatch.core("Dune [Unabridged)") == "dune unabridged")
    }

    // IM4
    @Test func relationOfTwoTitles() {
        #expect(TitleMatch.relation("Mind Over Markets (Unabridged)", "Mind over markets") == .same)
        #expect(TitleMatch.relation("Dune", "dune") == .same)
        #expect(TitleMatch.relation("The Hobbit", "Hobbit") == .same)
        #expect(TitleMatch.relation("Dune", "Dune: Messiah") == .sameUpToSubtitle)
        #expect(TitleMatch.relation("Dune: Messiah", "Dune") == .sameUpToSubtitle)
        #expect(TitleMatch.relation("Dune Messiah", "Dune") == .different)
        #expect(TitleMatch.relation("Dune", "Dune Messiah") == .different)
        #expect(TitleMatch.relation("Dune: Messiah", "Dune: Children") == .different)
        #expect(TitleMatch.relation("Dune", "Emma") == .different)
        // Each of the separators, and only the first one cuts.
        for subtitle in [
            "Salt Road: A Novel", "Salt Road꞉ A Novel", "Salt Road - A Novel", "Salt Road – A Novel",
            "Salt Road — A Novel", "Salt Road_ A Novel", "Salt Road: A Novel - Part One",
            "Salt Road (Unabridged): A Novel",
        ] {
            #expect(TitleMatch.relation(subtitle, "Salt Road") == .sameUpToSubtitle, "\(subtitle)")
            #expect(TitleMatch.relation("salt road (Unabridged)", subtitle) == .sameUpToSubtitle, "\(subtitle)")
        }
        #expect(TitleMatch.relation("Salt Road: A Novel - Part One", "Salt Road: A Novel") == .different)
        #expect(TitleMatch.relation("Salt Road:A Novel", "Salt Road") == .different)
        // The owner's files.
        #expect(
            TitleMatch.relation("Mind Over Markets: Power Tradin", "Mind Over Markets (Unabridged)")
                == .sameUpToSubtitle)
        #expect(
            TitleMatch.relation(
                "Mind Over Markets꞉ Power Trading with Market Generated Information, Updated Edition",
                "Mind Over Markets (Unabridged)") == .sameUpToSubtitle)
        #expect(TitleMatch.relation("Mind Over Markets", "Mind Over Markets (Unabridged)") == .same)
    }

    // IM4: nothing is the same as nothing.
    @Test func emptyTitlesAreNeverTheSame() {
        #expect(TitleMatch.relation("", "") == .different)
        #expect(TitleMatch.relation("?!", "...") == .different)
        #expect(TitleMatch.relation("", "Dune") == .different)
        #expect(TitleMatch.relation(": A Novel", "") == .different)
        #expect(TitleMatch.relation(": A Novel", "?") == .different)
    }

    // IM5
    @Test func tidyingATitleFromAFileName() {
        #expect(TitleMatch.tidyFromFileName("Mind Over Markets_ Power Tradin") == "Mind Over Markets: Power Tradin")
        #expect(TitleMatch.tidyFromFileName("Mind_Over_Markets") == "Mind Over Markets")
        #expect(TitleMatch.tidyFromFileName("Mind__Over _ Markets_") == "Mind Over Markets")
        #expect(TitleMatch.tidyFromFileName("_Dune_ Messiah") == "Dune: Messiah")
        #expect(TitleMatch.tidyFromFileName("_") == "")
        // Text with no underscore is never changed.
        for text in ["Dune", "  Dune   Messiah ", "", "Dune: Messiah", "Mind Over Markets꞉ Power", " - "] {
            #expect(TitleMatch.tidyFromFileName(text) == text)
        }
    }

    // IM7
    @Test func veryLongTitlesAreHandledQuickly() {
        let clock = ContinuousClock()
        let long = [
            String(repeating: "word ", count: 20_000), String(repeating: "(Unabridged) ", count: 7_700),
            String(repeating: "_ ", count: 50_000), String(repeating: " - ", count: 33_334),
            String(repeating: ", Unabridged", count: 8_400), String(repeating: "(", count: 100_000),
            String(repeating: "[unabridged", count: 9_100) + "]",
        ]
        for text in long {
            let taken = clock.measure {
                _ = TitleMatch.core(text)
                _ = TitleMatch.relation(text, "Dune")
                _ = TitleMatch.relation(text, text)
                _ = TitleMatch.tidyFromFileName(text)
            }
            #expect(taken < .seconds(5))
        }
    }
}

@Suite struct AudibleIDInNameTests {
    private func found(_ name: String) -> [String]? {
        AudibleIDInName.find(in: name).map { [$0.id, $0.cleaned] }
    }

    // IM6
    @Test func findsAnIDInBracketsOrAsAWord() {
        #expect(
            found("Mind Over Markets꞉ Power Trading with Market Generated Information, Updated Edition [B09WXN61GL]")
                == ["B09WXN61GL", "Mind Over Markets꞉ Power Trading with Market Generated Information, Updated Edition"])
        #expect(found("Dune (B002V1OF70)") == ["B002V1OF70", "Dune"])
        #expect(found("Dune B002V1OF70") == ["B002V1OF70", "Dune"])
        #expect(found("B002V1OF70") == ["B002V1OF70", ""])
        #expect(found("[B002V1OF70] Dune") == ["B002V1OF70", "Dune"])
        #expect(found("Dune [ B002V1OF70 ] Messiah") == ["B002V1OF70", "Dune Messiah"])
        #expect(found("Dune - B002V1OF70") == ["B002V1OF70", "Dune"])
        #expect(found("B002V1OF70 - Dune") == ["B002V1OF70", "Dune"])
        #expect(found("Frank Herbert - Dune [B002V1OF70]") == ["B002V1OF70", "Frank Herbert - Dune"])
        // A space stands where the ID was, so what was either side of it is not run together.
        #expect(found("Dune_B002V1OF70_x") == ["B002V1OF70", "Dune_ _x"])
        #expect(found("Dune  (Unabridged)  [B002V1OF70]") == ["B002V1OF70", "Dune (Unabridged)"])
        // The first one, and brackets that are not the ID's stay.
        #expect(found("Dune () [B002V1OF70] (B09WXN61GL)") == ["B002V1OF70", "Dune () (B09WXN61GL)"])
        #expect(found("Dune (B002V1OF70]") == ["B002V1OF70", "Dune ( ]"])
    }

    // IM6
    @Test(arguments: [
        "Mind Over Markets_ Power Tradin - James F. Dalton", "Mind Over Markets (Unabridged)", "Dune", "",
        "XB09WXN61GL", "B09WXN61GLX", "B09WXN61GL1", "1B09WXN61GL", "éB09WXN61GL", "B09WXN61GLé",
        "B09WXN61G", "b09wxn61gl", "B09wxn61gl", "B19WXN61GL", "BO9WXN61GL",
        "9780593135204", "0306406152", "ISBN 978-0-593-13520-4", "[0593135202]", "B0", "B0 9WXN61GL",
    ])
    func otherTextIsNotAnID(_ name: String) {
        #expect(AudibleIDInName.find(in: name) == nil)
    }

    // IM6: what it finds is an Audible ID as the lookup knows one.
    @Test func whatIsFoundIsAValidASIN() throws {
        let id = try #require(AudibleIDInName.find(in: "Dune [B002V1OF70]")?.id)
        #expect(AudibleProvider.asin(id) == id)
    }

    // IM7
    @Test func aVeryLongNameIsSearchedQuickly() {
        let clock = ContinuousClock()
        for text in [
            String(repeating: "B0", count: 50_000), String(repeating: "B09WXN61G ", count: 10_000),
            String(repeating: "[", count: 100_000), String(repeating: " ", count: 50_000) + "B002V1OF70"
                + String(repeating: " ", count: 50_000),
            "B002V1OF70" + String(repeating: "  -", count: 33_000),
        ] {
            let taken = clock.measure { _ = AudibleIDInName.find(in: text) }
            #expect(taken < .seconds(2))
        }
    }
}
