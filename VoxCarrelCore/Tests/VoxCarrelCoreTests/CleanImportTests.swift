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
        guard case .imported(let id, _) = outcome else {
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
}
