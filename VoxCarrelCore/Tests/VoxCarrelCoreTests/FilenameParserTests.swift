import Foundation
import Testing
@testable import VoxCarrelCore

@Suite struct FilenameParserTests {
    @Test func authorDashTitleInFileName() {
        let g = FilenameParser.guess(
            from: URL(fileURLWithPath: "/Users/me/Downloads/Andy Weir - Project Hail Mary.m4b"),
            isFolder: false)
        #expect(g.title == "Project Hail Mary")
        #expect(g.author == "Andy Weir")
    }

    @Test func onlyTheFirstDashSplits() {
        let g = FilenameParser.guess(
            from: URL(fileURLWithPath: "/x/Frank Herbert - Dune - Book One.epub"), isFolder: false)
        #expect(g.title == "Dune - Book One")
        #expect(g.author == "Frank Herbert")
    }

    @Test func parentFolderIsTheAuthorForFolderBooks() {
        let g = FilenameParser.guess(
            from: URL(fileURLWithPath: "/Volumes/NAS/Frank Herbert/Dune", isDirectory: true),
            isFolder: true)
        #expect(g.title == "Dune")
        #expect(g.author == "Frank Herbert")
    }

    @Test func genericParentFoldersAreNotAuthors() {
        for parent in ["Downloads", "Desktop", "Documents", "Audiobooks", "Ebooks", "Books"] {
            let g = FilenameParser.guess(
                from: URL(fileURLWithPath: "/Users/me/\(parent)/Dune.epub"), isFolder: false)
            #expect(g.title == "Dune")
            #expect(g.author == nil)
        }
    }

    @Test func folderNamesKeepTheirDots() {
        let g = FilenameParser.guess(
            from: URL(fileURLWithPath: "/x/J.R.R. Tolkien/The Hobbit v1.5", isDirectory: true),
            isFolder: true)
        #expect(g.title == "The Hobbit v1.5")
        #expect(g.author == "J.R.R. Tolkien")
    }

    // MARK: Review fixes

    @Test func fileInAFolderNamedAfterItTakesTheAuthorFromTheGrandparent() {
        for file in ["Dune.m4b", "dune.epub"] {
            let g = FilenameParser.guess(
                from: URL(fileURLWithPath: "/lib/Frank Herbert/Dune/\(file)"), isFolder: false)
            #expect(g.title.lowercased() == "dune")
            #expect(g.author == "Frank Herbert")
        }
    }

    @Test func fileInItsOwnBookFolderTakesTheAuthorFromTheGrandparent() {
        let url = URL(fileURLWithPath: "/lib/Andy Weir/Project Hail Mary/phm.m4b")

        let inBookFolder = FilenameParser.guess(from: url, isFolder: false, parentIsBookFolder: true)
        #expect(inBookFolder.title == "phm")
        #expect(inBookFolder.author == "Andy Weir")

        let inAuthorFolder = FilenameParser.guess(from: url, isFolder: false)
        #expect(inAuthorFolder.author == "Project Hail Mary")
    }

    @Test func genericGrandparentFoldersAreNotAuthors() {
        let named = FilenameParser.guess(
            from: URL(fileURLWithPath: "/Users/me/Downloads/Dune/Dune.m4b"), isFolder: false)
        #expect(named.title == "Dune")
        #expect(named.author == nil)

        let flagged = FilenameParser.guess(
            from: URL(fileURLWithPath: "/Users/me/Audiobooks/Dune/d.m4b"),
            isFolder: false, parentIsBookFolder: true)
        #expect(flagged.author == nil)
    }

    @Test func aNumberBeforeTheDashIsNotAnAuthor() {
        let g = FilenameParser.guess(
            from: URL(fileURLWithPath: "/x/Frank Herbert/01 - Chapter One.mp3"), isFolder: false)
        #expect(g.title == "Chapter One")
        #expect(g.author == "Frank Herbert")

        let generic = FilenameParser.guess(
            from: URL(fileURLWithPath: "/Users/me/Downloads/002 - Dune.m4b"), isFolder: false)
        #expect(generic.title == "Dune")
        #expect(generic.author == nil)
    }

    // MARK: Reading a name either way round (Plan 14)

    private func guess(_ name: String, in folder: String = "/Users/me/Downloads", known: KnownNames = .none)
        -> FilenameGuess
    {
        FilenameParser.guess(from: URL(fileURLWithPath: "\(folder)/\(name)"), isFolder: false, known: known)
    }

    private func knowing(authors: [String] = [], titles: [String] = []) -> KnownNames {
        KnownNames(
            authors: Set(authors.map(KnownNames.authorKey)), titles: Set(titles.map(KnownNames.titleKey)))
    }

    // IM11: a known author decides, whichever side it is on.
    @Test func IM11_aKnownAuthorDecidesTheOrder() {
        let known = knowing(authors: ["James F. Dalton", "Mick Herron"])

        let swapped = guess("Mind Over Markets_ Power Tradin - James F. Dalton.pdf", known: known)
        #expect(swapped.title == "Mind Over Markets: Power Tradin")
        #expect(swapped.author == "James F. Dalton")
        #expect(swapped.notes == [.fromFileName, .orderSwapped])

        // Written another way, it is still the known author; and a known author is not
        // doubted for the title's being shaped like a name (IM12).
        let spelled = guess("Slow Horses - mick  HERRON.epub", known: known)
        #expect(spelled.title == "Slow Horses")
        #expect(spelled.author == "mick  HERRON")
        #expect(spelled.notes == [.fromFileName, .orderSwapped])

        // Both sides are name-shaped, but one is known: decided, and not unsure.
        let usual = guess("Mick Herron - Slow Horses.epub", known: known)
        #expect(usual.title == "Slow Horses")
        #expect(usual.author == "Mick Herron")
        #expect(usual.notes == [.fromFileName])
    }

    // IM11: with no known author, a known title decides; the other side is the author.
    @Test func IM11_aKnownTitleDecidesWhenNoAuthorIsKnown() {
        let known = knowing(titles: ["Slow Horses (Unabridged)", "Dune"])

        let swapped = guess("Slow Horses - Mick Herron.epub", known: known)
        #expect(swapped.title == "Slow Horses")
        #expect(swapped.author == "Mick Herron")
        #expect(swapped.notes == [.fromFileName, .orderSwapped])

        let usual = guess("herbert - dune.epub", known: known)
        #expect(usual.title == "dune")
        #expect(usual.author == "herbert")
        #expect(usual.notes == [.fromFileName])

        // A known author counts before a known title.
        let both = knowing(authors: ["Slow Horses"], titles: ["Slow Horses"])
        let author = guess("Mick Herron - Slow Horses.epub", known: both)
        #expect(author.author == "Slow Horses")
        #expect(author.notes == [.fromFileName, .orderSwapped])
    }

    // IM11: shape decides only when exactly one side is name-shaped.
    @Test func IM11_shapeDecidesOnlyWhenOneSideIsAName() {
        let swapped = guess("The Long Earth - Terry Pratchett.epub")
        #expect(swapped.title == "The Long Earth")
        #expect(swapped.author == "Terry Pratchett")
        #expect(swapped.notes == [.fromFileName, .orderSwapped])

        let usual = guess("Frank Herbert - Dune.epub")
        #expect(usual.title == "Dune")
        #expect(usual.author == "Frank Herbert")
        #expect(usual.notes == [.fromFileName])

        // Both name-shaped: as today, and marked unsure.
        let both = guess("Mick Herron - Slow Horses.epub")
        #expect(both.title == "Slow Horses")
        #expect(both.author == "Mick Herron")
        #expect(both.notes == [.fromFileName, .orderUnsure])
        let bothReversed = guess("Slow Horses - Mick Herron.epub")
        #expect(bothReversed.title == "Mick Herron")
        #expect(bothReversed.author == "Slow Horses")
        #expect(bothReversed.notes == [.fromFileName, .orderUnsure])

        // Neither name-shaped: as today, and marked unsure.
        let neither = guess("The Hunt for Red October - 1984.epub")
        #expect(neither.title == "1984")
        #expect(neither.author == "The Hunt for Red October")
        #expect(neither.notes == [.fromFileName, .orderUnsure])
    }

    // IM11: shape alone never turns round a name whose first side may be a person named
    // alone or by surname; it is left as it reads, and asked about.
    @Test func IM11_shapeNeverSwapsAwayAFirstSideThatMayBeALoneName() {
        for (name, author, title) in [
            ("Aristotle - Nicomachean Ethics", "Aristotle", "Nicomachean Ethics"),
            ("Herbert - Dune Messiah", "Herbert", "Dune Messiah"),
            ("Dune - Frank Herbert", "Dune", "Frank Herbert"),
            ("O'Brian - Master Commander", "O'Brian", "Master Commander"),
        ] {
            let g = guess("\(name).epub")
            #expect(g.title == title)
            #expect(g.author == author)
            #expect(g.notes == [.fromFileName, .orderUnsure, .titleLooksLikePerson], "\(name)")
        }
        // What is known still decides.
        let known = guess("Dune - Frank Herbert.epub", known: knowing(authors: ["Frank Herbert"]))
        #expect(known.title == "Dune")
        #expect(known.author == "Frank Herbert")
        #expect(known.notes == [.fromFileName, .orderSwapped])
        // A first side that is no name at all is turned round.
        for name in ["dune - Frank Herbert", "Catch-22 - Joseph Heller", "Mind Over Markets - James F. Dalton"] {
            let g = guess("\(name).epub")
            #expect(g.notes == [.fromFileName, .orderSwapped], "\(name)")
        }
    }

    // IM11: when the same is known of both sides, that evidence decides nothing.
    @Test func IM11_evidenceOnBothSidesDecidesNothing() {
        let authors = knowing(authors: ["Mick Herron", "Slow Horses"])
        #expect(guess("Slow Horses - Mick Herron.epub", known: authors).notes == [.fromFileName, .orderUnsure])
        let titles = knowing(titles: ["Dune", "Frank Herbert"])
        // Both are known titles, so shape decides.
        let shaped = guess("The Dune - Frank Herbert.epub", known: titles)
        #expect(shaped.author == "Frank Herbert")
        #expect(shaped.notes == [.fromFileName, .orderSwapped])
        // An empty side of the known names never counts.
        let empty = KnownNames(authors: [""], titles: [""])
        #expect(guess("?! - Dune.epub", known: empty).notes == [.fromFileName, .orderUnsure])
    }

    // IM11, IM5: each side is tidied.
    @Test func IM11_sidesAreTidied() {
        let g = guess("Frank_Herbert - Dune_ Messiah.epub")
        #expect(g.title == "Dune: Messiah")
        #expect(g.author == "Frank Herbert")
        #expect(g.notes == [.fromFileName])
    }

    // IM12
    @Test func IM12_aTitleThatLooksLikeAPersonIsNoted() {
        // No " - ": a title only, as before.
        let alone = guess("Mick Herron.epub")
        #expect(alone.title == "Mick Herron")
        #expect(alone.author == nil)
        #expect(alone.notes == [.fromFileName, .titleLooksLikePerson])

        // With an author from the folder there is nothing to note.
        let filed = guess("Mick Herron.epub", in: "/lib/Somebody Else")
        #expect(filed.author == "Somebody Else")
        #expect(filed.notes == [.fromFileName])

        #expect(guess("Dune.epub").notes == [.fromFileName])
        #expect(guess("Mind Over Markets.epub").notes == [.fromFileName])

        // After IM11: the chosen title is name-shaped and the chosen author is not.
        let known = knowing(titles: ["Frank Herbert"])
        let odd = guess("Dune - Frank Herbert.epub", known: known)
        #expect(odd.title == "Frank Herbert")
        #expect(odd.author == "Dune")
        #expect(odd.notes == [.fromFileName, .titleLooksLikePerson])
        // Not when both are name-shaped: that is IM11's "unsure".
        #expect(guess("Mick Herron - Slow Horses.epub").notes == [.fromFileName, .orderUnsure])
    }

    // IM13
    @Test func IM13_anAudibleIDInTheNameIsTakenOutOfTheTitle() {
        let owner = guess(
            "Mind Over Markets꞉ Power Trading with Market Generated Information, Updated Edition [B09WXN61GL].pdf")
        #expect(owner.asin == "B09WXN61GL")
        #expect(owner.title == "Mind Over Markets꞉ Power Trading with Market Generated Information, Updated Edition")
        #expect(owner.author == nil)
        #expect(owner.notes == [.fromFileName, .audibleIDFromName])

        let dashed = guess("Frank Herbert - Dune [B002V1OF70].m4b")
        #expect(dashed.asin == "B002V1OF70")
        #expect(dashed.title == "Dune")
        #expect(dashed.author == "Frank Herbert")
        #expect(dashed.notes == [.fromFileName, .audibleIDFromName])

        // A name that is nothing but the ID keeps it as its title.
        let bare = guess("B002V1OF70.m4b")
        #expect(bare.asin == "B002V1OF70")
        #expect(bare.title == "B002V1OF70")

        #expect(guess("Dune.m4b").asin == nil)
        #expect(guess("Dune 9780593135204.m4b").asin == nil)
    }

    // IM13: failing the file's own name, the name of the folder that is the book's own.
    @Test func IM13_anAudibleIDInTheBooksOwnFolderName() {
        // A folder that is the book.
        let folder = FilenameParser.guess(
            from: URL(fileURLWithPath: "/lib/Frank Herbert/Dune [B002V1OF70]", isDirectory: true), isFolder: true)
        #expect(folder.asin == "B002V1OF70")
        #expect(folder.title == "Dune")
        #expect(folder.author == "Frank Herbert")
        #expect(folder.notes == [.fromFileName, .audibleIDFromName])

        // A file in the folder that holds just this book.
        let inside = FilenameParser.guess(
            from: URL(fileURLWithPath: "/lib/Frank Herbert/Dune [B002V1OF70]/audio.m4b"), isFolder: false,
            parentIsBookFolder: true)
        #expect(inside.asin == "B002V1OF70")
        #expect(inside.title == "audio")
        #expect(inside.author == "Frank Herbert")

        // The file's own name comes first.
        let own = FilenameParser.guess(
            from: URL(fileURLWithPath: "/lib/Frank Herbert/Dune [B002V1OF70]/Dune [B09WXN61GL].m4b"), isFolder: false,
            parentIsBookFolder: true)
        #expect(own.asin == "B09WXN61GL")

        // A folder that may hold other books too gives no ID to the files in it.
        let shared = FilenameParser.guess(
            from: URL(fileURLWithPath: "/lib/Shelf [B002V1OF70]/Emma.epub"), isFolder: false)
        #expect(shared.asin == nil)
        #expect(!shared.notes.contains(.audibleIDFromName))
    }

    // IM14: folder readings are as before, but tidied.
    @Test func IM14_folderNamesAreTidied() {
        let folder = FilenameParser.guess(
            from: URL(fileURLWithPath: "/lib/Frank_Herbert/Dune_ Messiah", isDirectory: true), isFolder: true)
        #expect(folder.title == "Dune: Messiah")
        #expect(folder.author == "Frank Herbert")
        #expect(folder.notes == [.fromFileName])

        let series = FilenameParser.guess(
            from: URL(fileURLWithPath: "/lib/Frank Herbert/Dune/Dune_Messiah/part.m4b"), isFolder: false)
        #expect(series.title == "part")
        #expect(series.author == "Dune Messiah")

        // A number before the dash is still a part number, not a side to judge.
        let numbered = guess("01 - Frank Herbert.mp3", in: "/x/Somebody")
        #expect(numbered.title == "Frank Herbert")
        #expect(numbered.author == "Somebody")
        #expect(numbered.notes == [.fromFileName])
    }
}
