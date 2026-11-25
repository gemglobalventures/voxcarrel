import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// Reading a messy folder: what a program left in the tags, where books were put, and
/// names as download sites write them. Cases are from a real folder of 238 files.
@Suite struct CleanImportTests {
    @Test func CI1_whatAProgramLeftIsNotATitle() {
        for junk in [
            "Microsoft Word - sfft.doc", "ebook.indd", "sc fwd2.qxd", "jmfeb02v5.dvi", "0071509461.pdf",
            "Bonus Report 2_Examples.PDF", "1", "CHAPTER 1", "Track  1", "Track 12", "CD1", "Disc 2",
            "PII: S1386-4181(00)00007-0", "Untitled", "", "   ",
        ] {
            #expect(TagJudge.isJunkTitle(junk), "\(junk)")
        }
        for real in [
            "1984", "Dune", "Getting Started in Bonds", "Part of the Furniture", "Track Changes",
            "Chapter and Verse", "R-Forex Learn Book", "The Day Trade Forex System", "FGT", "Catch-22",
        ] {
            #expect(!TagJudge.isJunkTitle(real), "\(real)")
        }
    }

    @Test func CI2_whoWasLoggedInIsNotTheAuthor() {
        for junk in ["maryam", "bluejay", "b1cspra", "v-2anges", "Preferred Customer", "Unknown", ".", "ed", "TRADER", "cbass"] {
            #expect(TagJudge.author(junk) == nil, "\(junk)")
        }
        #expect(TagJudge.author("Mark McRae") == "Mark McRae")
        #expect(TagJudge.author("By Robert C. Beckman") == "Robert C. Beckman")
        #expect(TagJudge.author("Duarte, Joe;") == "Duarte, Joe")
        #expect(TagJudge.author("Mark Torrey (bysoundalone.net)") == "Mark Torrey")
        #expect(TagJudge.author("KevinH [ MCKAY ]") == nil)
        #expect(TagJudge.author("Voltaire") == "Voltaire")
        #expect(TagJudge.author("Amar Bhidé") == "Amar Bhidé")
    }

    private func settled(_ title: String, _ authors: [String], file: String, folder: String? = nil) -> BookMetadata {
        var m = BookMetadata()
        m.title = title
        m.authors = authors
        let base = URL(fileURLWithPath: "/x/Shelf", isDirectory: true)
        BookScanner.settingAsideWhatAProgramLeft(
            in: &m, primary: base.appendingPathComponent(file),
            folder: folder.map { base.appendingPathComponent($0, isDirectory: true) })
        return m
    }

    @Test func CI3_aPDFsTitleThatSharesNothingWithATellingNameIsNotBelieved() {
        // Nothing in common, and the name says plenty: the name is read.
        var m = settled("FGT", ["Rob Booker"], file: "Rob Booker - Fairygod Trader Forex Auctions.pdf")
        #expect(m.title.isEmpty)
        #expect(m.authors == ["Rob Booker"])
        m = settled("LIVE @ TAG Workshop Presentation", ["INO.com"], file: "Staying Out Of Trouble Trading Currencies With Channels.pdf")
        #expect(m.title.isEmpty)
        #expect(m.authors.isEmpty)
        // A word in common: the tag stands.
        m = settled("The Art of Trading the Market Swings", ["Jan L. Arps"], file: "Jan L Arps - Surfing The Market Waves.pdf")
        #expect(m.title == "The Art of Trading the Market Swings")
        // A name that says nothing cannot overrule a tag.
        m = settled("Options Trading Practical Guide", [], file: "bk_acx0_196921.pdf")
        #expect(m.title == "Options Trading Practical Guide")
        // Only a PDF's tags are doubted this way.
        m = settled("Le Petit Prince", ["Antoine de Saint-Exupéry"], file: "The Little Prince - English Edition Notes.epub")
        #expect(m.title == "Le Petit Prince")
        // A junk title takes a junk author with it, and leaves a true one.
        m = settled("Microsoft Word - sfft.doc", ["Mark McRae"], file: "Mark Mcrae - Sure Fire Forex Trading.pdf")
        #expect(m.title.isEmpty)
        #expect(m.authors == ["Mark McRae"])
        m = settled("Microsoft Word - Farley - The Master Swing Trader.doc", ["Mazsika"], file: "Alan Farley - The Master Swing Trader.pdf")
        #expect(m.authors.isEmpty)
    }

    @Test func CI4_aPartsNumberBeforeTheTitleOfABookInSeveralFilesIsTakenOff() {
        var m = settled("01 Slow Horses", ["Mick Herron"], file: "01 Slow Horses 001.mp3", folder: "Mick Herron - Slow Horses (Sean Barrett) (2010)")
        #expect(m.title == "Slow Horses")
        // Not when the rest is not what the folder is called, and not for one file.
        m = settled("2001 A Space Odyssey", [], file: "a.mp3", folder: "Space Odyssey")
        #expect(m.title == "2001 A Space Odyssey")
        m = settled("11 Rules", [], file: "a.mp3", folder: "Something Else")
        #expect(m.title == "11 Rules")
        m = settled("01 Slow Horses", [], file: "01 Slow Horses.mp3")
        #expect(m.title == "01 Slow Horses")
    }

    @Test func CI5_whereBooksWerePutIsNotWhoWroteThem() {
        for place in ["White Papers", "Foreign Exchange", "Investing", "14 items", "suggested stocktrader.com", "Swing Trading", "Bonds"] {
            #expect(!FilenameParser.folderIsAnAuthor(place, known: .none), "\(place)")
        }
        for person in ["Mick Herron", "John le Carré", "James F. Dalton", "J.R.R. Tolkien"] {
            #expect(FilenameParser.folderIsAnAuthor(person, known: .none), "\(person)")
        }
        // A file with no author in its name, in such a folder, has none.
        let url = URL(fileURLWithPath: "/x/White Papers/Patterns In Three Centuries Of Stock Market Prices.pdf")
        let guess = FilenameParser.guess(from: url, isFolder: false)
        #expect(guess.title == "Patterns In Three Centuries Of Stock Market Prices")
        #expect(guess.author == nil)
        // An author the library has is an author, whatever the name looks like.
        var known = KnownNames.none
        known.authors.insert(KnownNames.authorKey("Voltaire"))
        #expect(FilenameParser.folderIsAnAuthor("Voltaire", known: known))
    }

    @Test func CI6_namesAsDownloadSitesWriteThem() throws {
        var read = try #require(FilenameParser.downloadSiteName(
            "5 (Little Books. Big Profits) Jack D. Schwager-The Little Book of Market Wizards_ Lessons from the Greatest Traders-Wiley (2014)"))
        #expect(read.author == "Jack D. Schwager")
        #expect(read.title == "The Little Book of Market Wizards: Lessons from the Greatest Traders")
        read = try #require(FilenameParser.downloadSiteName("12 Michael Lewis-Flash boys_ a Wall Street revolt-W. W. Norton & Company (2014)"))
        #expect(read.author == "Michael Lewis")
        #expect(read.title == "Flash boys: a Wall Street revolt")
        read = try #require(FilenameParser.downloadSiteName(
            "19 Roger Lowenstein-When Genius Failed_ The Rise and Fall of Long-Term Capital Management-Random House (2000)"))
        #expect(read.author == "Roger Lowenstein")
        #expect(read.title == "When Genius Failed: The Rise and Fall of Long-Term Capital Management")
        read = try #require(FilenameParser.downloadSiteName(
            "16 (Barnes & Noble Library of Essential Reading) Charles Mackay, David J. Schneider-Extraordinary Popular Delusions and the Madness of Crowds-Barnes & Noble (2004)"))
        #expect(read.author == "Charles Mackay")
        // Other names are left to the usual reading.
        #expect(FilenameParser.downloadSiteName("Mick Herron - Slow Horses (2010)") == nil)
        #expect(FilenameParser.downloadSiteName("Catch-22 (1961)") == nil)
        #expect(FilenameParser.downloadSiteName("Spider-Man-The Novel-Marvel") == nil)
    }

    // MARK: An audiobook kept disc by disc

    @Test func CI7_discFoldersAreOneAudiobookWithItsPartsInDiscOrder() throws {
        typealias F = LibraryFixture
        let f = try F()
        var tags = BookMetadata()
        tags.title = "Track  1"
        let book = "Way of the Turtle - The Secret Methods"
        for disc in ["CD1", "CD2", "CD10"] {
            for part in ["01.mp3", "02.mp3"] { _ = try f.makeMP3("\(book)/\(disc)/\(part)", tags: tags) }
        }
        try Data("%PDF".utf8).write(to: f.inbox.appendingPathComponent("\(book)/notes.txt"))

        let result = f.service.scan([f.inbox.appendingPathComponent(book, isDirectory: true)])
        #expect(result.candidates.count == 1)
        let candidate = try #require(result.candidates.first)
        let order = candidate.files.map { $0.url.deletingLastPathComponent().lastPathComponent + "/" + $0.url.lastPathComponent }
        #expect(order == ["CD1/01.mp3", "CD1/02.mp3", "CD2/01.mp3", "CD2/02.mp3", "CD10/01.mp3", "CD10/02.mp3"])
        #expect(candidate.sourceFolder?.lastPathComponent == book)
        // "Track  1" is not the book's title: the folder's name is read.
        #expect(!candidate.metadata.title.lowercased().contains("track"))

        // Every part arrives, though the discs use the same names.
        let outcome = try #require(try f.service.importItems([ImportItem(candidate: candidate)]).outcomes.first)
        // (The folder's name gives no author, so the book arrives needing one.)
        let id: Int64
        switch outcome {
        case .imported(let bookId, _), .needsAttention(let bookId): id = bookId
        default:
            Issue.record("not imported: \(outcome)")
            return
        }
        #expect(try f.store.files(bookId: id).filter { $0.role == .audio }.count == 6)
    }

    @Test func CI7_foldersThatAreNotDiscsAreLeftAsTheyWere() throws {
        #expect(BookScanner.isDiscName("CD1") && BookScanner.isDiscName("Disc 03") && BookScanner.isDiscName("disk-4"))
        #expect(BookScanner.isDiscName("Part 2"))
        #expect(!BookScanner.isDiscName("Dune") && !BookScanner.isDiscName("CD") && !BookScanner.isDiscName("Partners 2"))
        #expect(!BookScanner.isDiscName("Disc 1 - Extras"))
        let root = try makeTempDir()
        // Two books side by side are two books.
        for book in ["Dune", "Emma"] {
            for part in ["1.mp3", "2.mp3"] { try touch(root.appendingPathComponent("Shelf/\(book)/\(part)")) }
        }
        #expect(BookScanner().scan([root.appendingPathComponent("Shelf")]).candidates.count == 2)
        // A disc folder beside something that is not one: nothing is gathered.
        for folder in ["CD1", "Bonus"] {
            for part in ["1.mp3", "2.mp3"] { try touch(root.appendingPathComponent("Mixed/\(folder)/\(part)")) }
        }
        #expect(BookScanner().scan([root.appendingPathComponent("Mixed")]).candidates.count == 2)
    }

    // MARK: What lies beside a book

    private static let opf = """
    <?xml version='1.0' encoding='utf-8'?>
    <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uuid_id" version="2.0">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
        <dc:title>Japanese Candlestick Charting Techniques</dc:title>
        <dc:creator opf:role="aut">Steve Nison</dc:creator>
        <dc:publisher>Prentice Hall</dc:publisher>
        <dc:date>2001-10-01T00:00:00+00:00</dc:date>
        <dc:description>&lt;p&gt;A &lt;b&gt;classic&lt;/b&gt;.&lt;/p&gt;</dc:description>
        <dc:identifier opf:scheme="ISBN">9780735201811</dc:identifier>
        <dc:language>en</dc:language>
        <dc:subject>to-read</dc:subject>
        <meta name="calibre:series" content="Candles"/>
        <meta name="calibre:series_index" content="2.0"/>
      </metadata>
    </package>
    """

    @Test func CI8_theDetailsCalibreKeepsBesideABookAreRead() throws {
        let root = try makeTempDir()
        let book = root.appendingPathComponent("Shelf/Japanese Candlestick Charting - Steve Nison", isDirectory: true)
        try touch(book.appendingPathComponent("jcc.epub"))
        try touch(book.appendingPathComponent("jcc.mobi"))
        try Data(Self.opf.utf8).write(to: book.appendingPathComponent("metadata.opf"))
        try Data([0xFF, 0xD8]).write(to: book.appendingPathComponent("cover.jpg"))

        let result = BookScanner().scan([root.appendingPathComponent("Shelf")])
        #expect(result.candidates.count == 1)
        let candidate = try #require(result.candidates.first)
        let m = candidate.metadata
        #expect(m.title == "Japanese Candlestick Charting Techniques")
        #expect(m.authors == ["Steve Nison"])
        #expect(m.series == "Candles" && m.seriesNumber == "2")
        #expect(m.publisher == "Prentice Hall" && m.year == 2001 && m.isbn == "9780735201811")
        #expect(m.summary == "A classic.")
        #expect(m.genres.isEmpty)
        #expect(candidate.guessNotes.isEmpty)
        #expect(candidate.coverBeside?.lastPathComponent == "cover.jpg")
    }

    @Test func CI8_detailsBesideSeveralBooksBelongToNone() throws {
        let root = try makeTempDir()
        let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
        try touch(shelf.appendingPathComponent("One - Ann Author.epub"))
        try touch(shelf.appendingPathComponent("Two - Bob Writer.epub"))
        try Data(Self.opf.utf8).write(to: shelf.appendingPathComponent("metadata.opf"))
        try Data([0xFF, 0xD8]).write(to: shelf.appendingPathComponent("cover.jpg"))
        let result = BookScanner().scan([shelf])
        #expect(result.candidates.count == 2)
        #expect(result.candidates.allSatisfy { $0.coverBeside == nil && !$0.metadata.title.contains("Candlestick") })
        // What cannot be read changes nothing.
        #expect(Sidecar.details(at: shelf.appendingPathComponent("missing.opf")) == nil)
        try Data("<not xml".utf8).write(to: shelf.appendingPathComponent("broken.opf"))
        #expect(Sidecar.details(at: shelf.appendingPathComponent("broken.opf")) == nil)
    }

    // MARK: The same file, and the same book, twice

    @Test func CI9_aFileThatIsACopyOfAnotherIsNotABookOfItsOwn() throws {
        let root = try makeTempDir()
        let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
        let first = shelf.appendingPathComponent("How to Day Trade - Andrew Aziz.epub")
        let copy = shelf.appendingPathComponent("14 items/How to Day Trade - Andrew Aziz.epub")
        let renamed = shelf.appendingPathComponent("14 items/htdt.epub")
        let other = shelf.appendingPathComponent("Another Book - Ann Author.epub")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let same = Data(repeating: 7, count: 5000)
        try same.write(to: first)
        try same.write(to: copy)
        try same.write(to: renamed)
        try Data(repeating: 9, count: 5000).write(to: other)   // the same size, not the same

        let result = BookScanner().scan([shelf])
        #expect(result.candidates.count == 2)
        let kept = try #require(result.candidates.first { $0.metadata.title.contains("Day Trade") || $0.files.count == 1 && $0.copies.count == 2 })
        #expect(kept.files.count == 1)
        #expect(Set(kept.copies.map(\.lastPathComponent)) == ["How to Day Trade - Andrew Aziz.epub", "htdt.epub"])
        #expect(result.candidates.contains { $0.files[0].url.lastPathComponent == other.lastPathComponent && $0.copies.isEmpty })
        // The result does not depend on how often it is asked for.
        #expect(BookScanner().scan([shelf]) == result)
    }

    @Test func CI9_emptyFilesAndUnreadableOnesAreNeverCalledCopies() throws {
        let root = try makeTempDir()
        try touch(root.appendingPathComponent("Shelf/A - Ann Author.epub"))
        try touch(root.appendingPathComponent("Shelf/B - Bob Writer.epub"))
        let result = BookScanner().scan([root.appendingPathComponent("Shelf")])
        #expect(result.candidates.count == 2)
        #expect(result.candidates.allSatisfy { $0.copies.isEmpty })
        #expect(BookScanner.fingerprint(of: root.appendingPathComponent("missing")) == nil)
    }

    @Test func CI10_theSameBookFoundTwiceIsOneBookWithItsForms() throws {
        let root = try makeTempDir()
        let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
        func write(_ path: String, _ text: String) throws {
            let url = shelf.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("Mark Mcrae - Sure Fire Forex Trading.pdf", "one")
        // (Small files are never compared, so these stand for three different files.)
        try write("More/Mark McRae - Sure Fire Forex Trading (Unabridged).pdf", "two!")
        try write("More/Mark Mcrae - Sure Fire Forex Trading.epub", "three")
        try write("Mark Mcrae - Another Title.pdf", "four")

        let result = BookScanner().scan([shelf])
        #expect(result.candidates.count == 2)
        let joined = try #require(result.candidates.first { $0.files.count == 3 })
        #expect(Set(joined.files.map { $0.url.pathExtension }) == ["pdf", "epub"])
        #expect(joined.files.allSatisfy { $0.role != .audio })
    }

    @Test func CI10_twoAudiobooksOfOneTitleStayTwo() throws {
        let root = try makeTempDir()
        try touch(root.appendingPathComponent("Shelf/One/Ann Author - Dune.m4b"))
        try touch(root.appendingPathComponent("Shelf/Two/Ann Author - Dune.m4b"))
        try Data("a".utf8).write(to: root.appendingPathComponent("Shelf/One/Ann Author - Dune.m4b"))
        try Data("bb".utf8).write(to: root.appendingPathComponent("Shelf/Two/Ann Author - Dune.m4b"))
        #expect(BookScanner().scan([root.appendingPathComponent("Shelf")]).candidates.count == 2)
    }

    @Test func CI6_theAuthorInBracketsAtTheEnd() throws {
        var read = try #require(FilenameParser.authorInBracketsAtTheEnd("Street Smarts (Laurence Connors)"))
        #expect(read.title == "Street Smarts" && read.author == "Laurence Connors")
        read = try #require(FilenameParser.authorInBracketsAtTheEnd(
            "Buffett and Munger Unscripted Three Decades (Warren E. Buffett, Charlie Munger) "))
        #expect(read.author == "Warren E. Buffett")
        #expect(FilenameParser.authorInBracketsAtTheEnd("Mind Over Markets (Unabridged)") == nil)
        #expect(FilenameParser.authorInBracketsAtTheEnd("Dune (1965)") == nil)
        #expect(FilenameParser.authorInBracketsAtTheEnd("Mick Herron - Slow Horses (Sean Barrett)") == nil)
        #expect(FilenameParser.authorInBracketsAtTheEnd("The Lord of the Rings (Illustrated Edition)") == nil)
    }

    @Test func CI2_aStandInForTheAuthorInANameIsNoAuthor() {
        let url = URL(fileURLWithPath: "/x/Downloads/Think and Trade Like a Champion - Unknown.epub")
        let guess = FilenameParser.guess(from: url, isFolder: false)
        #expect(guess.author == nil)
    }

    // MARK: Files kept in iCloud

    @Test func CI11_aFileThatIsNotOnThisMacIsNotReadAndIsCounted() throws {
        let root = try makeTempDir()
        let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
        let away = shelf.appendingPathComponent("Ann Author - Far Away.epub")
        let here = shelf.appendingPathComponent("Bob Writer - Right Here.epub")
        try FileManager.default.createDirectory(at: shelf.appendingPathComponent("More"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5000).write(to: away)
        try Data(repeating: 1, count: 5000).write(to: shelf.appendingPathComponent("More/copy.epub"))
        try Data(repeating: 2, count: 5000).write(to: here)
        var tagged = BookMetadata()
        tagged.title = "From The Tags"
        tagged.authors = ["Tag Author"]
        let reader = StubReader(byFileName: [away.lastPathComponent: tagged, here.lastPathComponent: tagged])
        let awayName = away.lastPathComponent

        let result = BookScanner(reader: reader, isOnThisMac: { $0.lastPathComponent != awayName }).scan([shelf])
        let far = try #require(result.candidates.first { $0.files[0].url.lastPathComponent == away.lastPathComponent })
        // Its tags were not asked for: the name is read. It is not compared with others.
        #expect(far.metadata.title == "Far Away" && far.metadata.authors == ["Ann Author"])
        #expect(far.filesNotOnThisMac == 1)
        #expect(far.copies.isEmpty)
        let near = try #require(result.candidates.first { $0.files[0].url.lastPathComponent == here.lastPathComponent })
        #expect(near.metadata.title == "From The Tags" && near.filesNotOnThisMac == 0)
        #expect(result.candidates.count == 3)
        // An ordinary file is on this Mac.
        #expect(BookScanner.isOnThisMac(here))
    }

    // MARK: Names that were still read wrongly

    private func guess(_ name: String) -> FilenameGuess {
        FilenameParser.guess(from: URL(fileURLWithPath: "/x/Downloads/\(name).pdf"), isFolder: false)
    }

    @Test func CI14_aTitleAndWhatFollowsItIsNotAnAuthorAndATitle() {
        let g = guess("Way of the Turtle - The Secret Methods that Turned Ordinary People into Legendary Traders")
        #expect(g.author == nil)
        #expect(g.title == "Way of the Turtle - The Secret Methods that Turned Ordinary People into Legendary Traders")
        #expect(!g.notes.contains(.orderUnsure))
        // One word, or a group's name with its article, may still be who made it.
        #expect(guess("Aristotle - Nicomachean Ethics").author == "Aristotle")
        #expect(guess("The Great Courses - Ancient Greece").author == "The Great Courses")
        // A person on either side is read as before.
        #expect(guess("Mick Herron - Slow Horses").author == "Mick Herron")
        #expect(guess("Slow Horses - Mick Herron").author == "Mick Herron" || guess("Slow Horses - Mick Herron").notes.contains(.orderUnsure))
        // And a name with no capital anywhere gives nothing to go by.
        #expect(guess("frank herbert - dune").author == "frank herbert")
    }

    @Test func CI15_wordsOfASubjectAreNotAPersonsName() {
        var g = guess("Stock Trading & Investing Using - Anna Coulling")
        #expect(g.author == "Anna Coulling" && g.title == "Stock Trading & Investing Using")
        g = guess("S A Mccrary - Hedge Fund Course")
        // Initials without their full stops do not make a name by shape, so this one
        // is still read the usual way round, and asked about.
        #expect(g.author == "S A Mccrary" && g.title == "Hedge Fund Course")
        #expect(!FilenameParser.looksLikeAnAuthor("Money Management"))
        #expect(FilenameParser.looksLikeAnAuthor("Ryan Jones") && FilenameParser.looksLikeAnAuthor("James F. Dalton"))
    }

    @Test func CI6_aDownloadSiteNameWithABareYear() throws {
        let read = try #require(FilenameParser.downloadSiteName("14 Nassim Nicholas Taleb-Incerto [4-Book Bundle]2016"))
        #expect(read.author == "Nassim Nicholas Taleb")
        #expect(read.title == "Incerto [4-Book Bundle]")
        #expect(FilenameParser.downloadSiteName("Catch-22 1961") == nil)
        #expect(FilenameParser.downloadSiteName("Blade Runner 2049") == nil)
        #expect(FilenameParser.downloadSiteName("Spider-Man 2002") == nil)
        #expect(FilenameParser.downloadSiteName("Frank Herbert-Dune 1965") == nil)   // no number before it: left alone
    }

    // MARK: Files the library already has

    @Test func CI16_aFileTheLibraryAlreadyHasIsNotOfferedAgain() throws {
        let f = try LibraryFixture().knowsFilesAgain()
        let first = try f.makeEPUB("Shelf/First.epub")
        let candidate = try #require(f.service.scan([first]).candidates.first)
        _ = try f.service.importItems([ImportItem(candidate: candidate)], options: ImportOptions(mode: .copy))

        // The same bytes under another name, and beside them a book the library lacks.
        let again = f.inbox.appendingPathComponent("Later/the same book.epub")
        try FileManager.default.createDirectory(at: again.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: first, to: again)
        let other = f.inbox.appendingPathComponent("Later/Ann Author - Something Else.epub")
        try Data(repeating: 3, count: 6000).write(to: other)

        let result = f.service.scan([again.deletingLastPathComponent()])
        #expect(result.alreadyInLibrary.map(\.lastPathComponent) == ["the same book.epub"])
        #expect(result.candidates.count == 1)
        #expect(result.candidates.first?.files.first?.url.lastPathComponent == other.lastPathComponent)
        // Nothing was changed by looking.
        #expect(FileManager.default.fileExists(atPath: again.path))
        // The library's own files are not copies of themselves.
        let own = try f.store.allFiles().map { f.store.url(for: $0) }
        #expect(f.service.scan(own).alreadyInLibrary.isEmpty)
    }

    // MARK: An ebook's subjects

    @Test func CI18_anEbooksSubjectsThatAreNotGenresAreLeftOut() throws {
        // As found in real files: headings and keywords among the genres.
        #expect(GenreTag.genres(from: "Invest", asSubjects: true).isEmpty)
        #expect(GenreTag.genres(from: "LCSH: Corporations—Finance.", asSubjects: true).isEmpty)
        #expect(GenreTag.genres(
            from: "Trading Psychology; Self Development For Traders; Trading discipline; Science fiction", asSubjects: true)
            == ["Science Fiction"])
        #expect(GenreTag.genres(from: "Business & Careers; Financial crises; History", asSubjects: true)
            == ["Business & Careers", "History"])
        // What the app wrote reads back as it was, an own genre among them.
        #expect(GenreTag.genres(from: "Pub Quiz; Fantasy", listed: ["Pub Quiz"], asSubjects: true) == ["Pub Quiz", "Fantasy"])
        // A subject that is one of the owner's own genres is kept beside an unknown one.
        #expect(GenreTag.genres(from: "Pub Quiz; Large type books; Fantasy", listed: ["Pub Quiz"], asSubjects: true)
            == ["Pub Quiz", "Fantasy"])
        // A tag in an audio file is still read as before: an unknown name is a genre of the owner's.
        #expect(GenreTag.genres(from: "Steampunk Noir; Fantasy") == ["Fantasy", "Steampunk Noir"])

        // In a library, an EPUB with such subjects adds no genre to the list.
        let f = try LibraryFixture()
        let before = try f.service.genreList().count
        #expect(f.service.genres(fromTag: "Invest; Financial crises", asSubjects: true).isEmpty)
        #expect(try f.service.genreList().count == before)
    }

    // MARK: Ebooks that are kept as they are

    @Test func CI19_djvuAndTheLikeAreFiledAndNeverOpenedOrChanged() throws {
        for ending in ["djvu", "prc", "azw", "fb2", "lit", "chm", "mobi", "azw3"] {
            let format = try #require(FileFormat(rawValue: ending))
            #expect(format.isKeptAsItIs && format.defaultRole == .ebook)
            #expect(FileMetadataIO.storableFields(for: format).isEmpty)
        }
        #expect(!FileFormat.epub.isKeptAsItIs && !FileFormat.pdf.isKeptAsItIs && !FileFormat.mp3.isKeptAsItIs)
        #expect(FileFormat(url: URL(fileURLWithPath: "/x/notes.doc")) == nil)

        let f = try LibraryFixture()
        let source = f.inbox.appendingPathComponent("Mark Douglas - The Disciplined Trader.djvu")
        let bytes = Data(repeating: 5, count: 6000)
        try bytes.write(to: source)
        let candidate = try #require(f.service.scan([source]).candidates.first)
        #expect(candidate.metadata.title == "The Disciplined Trader" && candidate.metadata.authors == ["Mark Douglas"])
        #expect(candidate.files.map(\.role) == [.ebook])
        let outcome = try #require(try f.service.importItems([ImportItem(candidate: candidate)]).outcomes.first)
        guard case .imported(let id, _) = outcome else {
            Issue.record("not imported: \(outcome)")
            return
        }
        let filed = try #require(try f.store.files(bookId: id).first)
        #expect(filed.format == .djvu)
        // Not a byte of it was changed.
        #expect(try Data(contentsOf: f.store.url(for: filed)) == bytes)
    }
}
