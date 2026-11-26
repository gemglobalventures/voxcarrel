import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// WC1–WC7: the words of an ebook, counted from its text, and the pages they make.
@Suite struct WordCountTests {
    typealias F = LibraryFixture

    /// An EPUB whose one chapter holds `words` words.
    private func epub(_ f: F, _ name: String, words: Int) throws -> URL {
        let url = f.base.appendingPathComponent(name)
        let text = Array(repeating: "word", count: words).joined(separator: " ")
        let chapter = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body><p>\(text)</p></body></html>"
        try MediaFixtures.makeEPUB(at: url, files: [
            ("OEBPS/content.opf", Data(MediaFixtures.opf3.utf8)), ("OEBPS/nav.xhtml", Data(MediaFixtures.nav.utf8)),
            ("OEBPS/ch1.xhtml", Data(chapter.utf8)), ("OEBPS/images/cover art.jpg", MediaFixtures.makeImage(.jpeg)),
        ])
        return url
    }

    private func imported(_ f: F, _ url: URL, _ title: String) throws -> Int64 {
        try f.importNew([url], F.meta(title, "Ann Author"))
    }

    // WC1: what is text and what is not.
    @Test func WC1_wordsAreCountedFromTextAlone() {
        func words(_ html: String) -> Int { WordCount.words(inHTML: Data(html.utf8)) }
        #expect(words("") == 0)
        #expect(words("<p>One two  three</p>") == 3)
        #expect(words("<p>One</p><p>two</p>") == 2)
        #expect(words("<p class=\"a b c\">don't stop&nbsp;now</p>") == 2)
        #expect(words("<head><title>Not text</title><style>p { color: red }</style></head><body>Yes</body>") == 1)
        #expect(words("<SCRIPT>var a = 1;</SCRIPT>after it") == 2)
        #expect(words("one<br/>two\nthree\tfour") == 4)
        // Writing with no spaces between its words: each character is a word.
        #expect(words("<p>吾輩は猫である</p>") == 7)
        #expect(words("<p>café naïve</p>") == 2)
    }

    // WC2: pages from words.
    @Test func WC2_pagesAreWordsOverThreeHundredRoundedUp() {
        #expect(WordCount.pages(forWords: 0) == nil)
        #expect(WordCount.pages(forWords: 1) == 1)
        #expect(WordCount.pages(forWords: 300) == 1)
        #expect(WordCount.pages(forWords: 301) == 2)
        #expect(WordCount.pages(forWords: 90_000) == 300)
    }

    // WC3: an imported EPUB is counted, and gives the book its pages.
    @Test func WC3_anEPUBIsCountedAndGivesTheBookItsPages() throws {
        let f = try F()
        let id = try imported(f, try epub(f, "long.epub", words: 1_000), "Long")
        #expect(try f.store.book(id: id)?.wordCount == nil)
        #expect(try f.service.countWords() == 1)
        let book = try #require(try f.store.book(id: id))
        #expect(book.wordCount == 1_000 && book.pageCount == 4)
        // Once counted, not counted again.
        #expect(try f.service.countWords() == 0)
    }

    // WC4: a few at a time, lowest id first, until there are none.
    @Test func WC4_booksAreCountedAFewAtATime() throws {
        let f = try F()
        let ids = try (1...5).map { try imported(f, try epub(f, "b\($0).epub", words: $0 * 10), "Book \($0)") }
        #expect(try f.service.countWords(limit: 2) == 2)
        #expect(try ids.map { try f.store.book(id: $0)?.wordCount } == [10, 20, nil, nil, nil])
        #expect(try f.service.countWords(limit: 2) == 2)
        #expect(try f.service.countWords(limit: 2) == 1)
        #expect(try f.service.countWords(limit: 2) == 0)
    }

    // WC5: an EPUB that cannot be read is recorded as tried, and has no pages from it.
    @Test func WC5_anEPUBThatCannotBeReadIsTriedOnce() throws {
        let f = try F()
        let id = try imported(f, try epub(f, "bad.epub", words: 50), "Bad")
        let file = f.store.url(for: try #require(try f.store.files(bookId: id).first))
        try Data("not a zip".utf8).write(to: file)
        #expect(try f.service.countWords() == 1)
        let book = try #require(try f.store.book(id: id))
        #expect(book.wordCount == 0 && book.pageCount == nil)
        #expect(try f.service.countWords() == 0)
    }

    // WC6: a book whose EPUB is not on disk is left for another time, and does not
    // hold up the rest.
    @Test func WC6_aMissingEPUBIsLeftForAnotherTime() throws {
        let f = try F()
        let gone = try imported(f, try epub(f, "gone.epub", words: 50), "Gone")
        let here = try imported(f, try epub(f, "here.epub", words: 60), "Here")
        try FileManager.default.removeItem(at: f.store.url(for: try #require(try f.store.files(bookId: gone).first)))
        #expect(try f.service.countWords(limit: 1) == 0)
        #expect(try f.service.countWords(limit: 1) == 1)
        #expect(try f.store.book(id: gone)?.wordCount == nil && f.store.book(id: here)?.wordCount == 60)
    }

    // WC7: the pages a PDF gave are the book's pages; books with no EPUB are not asked about.
    @Test func WC7_aPDFsPagesAreKeptAndOtherBooksAreNotCounted() throws {
        let f = try F()
        let pdf = try f.makePDF("paper.pdf", pages: 3)
        let both = try f.importNew([pdf, try epub(f, "paper.epub", words: 3_000)], F.meta("Paper", "Ann Author"))
        let audio = try f.importNew([try f.makeM4B("a.m4b", tags: F.meta("Heard", "Ann Author"))], F.meta("Heard", "Ann Author"))
        #expect(try f.service.countWords() == 1)
        let book = try #require(try f.store.book(id: both))
        #expect(book.wordCount == 3_000 && book.pageCount == 3)
        #expect(try f.store.book(id: audio)?.wordCount == nil)
    }
}
