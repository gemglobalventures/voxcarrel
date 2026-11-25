import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// CP1–CP6: a print of what a book file holds, its tags aside.
@Suite struct ContentPrintTests {
    private let io = FileMetadataIO()

    private func retagged() -> BookMetadata {
        var m = BookMetadata(title: "Quite Another Title", authors: ["Somebody Else", "And Another"])
        m.narrators = ["A Reader"]
        m.series = "A Series"
        m.seriesNumber = "3"
        m.genres = ["Fantasy", "Horror"]
        m.year = 1999
        m.publisher = "A Press"
        m.summary = String(repeating: "A long description that makes the tags a good deal larger. ", count: 40)
        m.asin = "B000000000"
        return m
    }

    private func cover(_ red: CGFloat) -> CoverImage {
        CoverImage(data: MediaFixtures.makeImage(.jpeg, size: 256, red: red), mime: "image/jpeg")
    }

    /// A PDF with enough words on its pages to be told by.
    private func makeWordyPDF(at url: URL, pages: Int = 4, word: String = "ledger") {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for page in 1...pages {
            context.beginPDFPage(nil)
            for line in 0..<12 {
                let text = NSAttributedString(
                    string: "Page \(page) line \(line): the \(word) of the harbour master was kept daily.",
                    attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 11, nil)])
                context.textPosition = CGPoint(x: 60, y: 720 - CGFloat(line) * 18)
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    @Test func CP1_anM4BsPrintIsItsSoundWhateverIsWrittenIntoItsTags() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("a.m4b")
        try MediaFixtures.makeAAC(at: url, seconds: 2)
        let before = try #require(ContentPrint.of(url))
        #expect(before.hasPrefix("m4b:"))
        try io.write(retagged(), cover: .set(cover(0.2)), to: url)
        #expect(ContentPrint.of(url) == before)
        try io.write(BookMetadata(title: "T"), cover: .remove, to: url)
        #expect(ContentPrint.of(url) == before)
        // Other sound, another print.
        let other = dir.appendingPathComponent("b.m4b")
        try MediaFixtures.makeAAC(at: other, seconds: 3)
        #expect(ContentPrint.of(other) != before)
    }

    @Test func CP2_anMP3sPrintIsItsSoundWhateverIsWrittenIntoItsTags() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("a.mp3")
        try MediaFixtures.makeSilentMP3(seconds: 2).write(to: url)
        let before = try #require(ContentPrint.of(url))
        #expect(before.hasPrefix("mp3:"))
        try io.write(retagged(), cover: .set(cover(0.6)), part: PartPosition(index: 2, count: 9), to: url)
        #expect(ContentPrint.of(url) == before)
        // An old tag at the end, as other programs leave one.
        var tail = Data("TAG".utf8)
        tail.append(Data(repeating: 0x20, count: 125))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: tail)
        try handle.close()
        #expect(ContentPrint.of(url) == before)
        let other = dir.appendingPathComponent("b.mp3")
        try MediaFixtures.makeSilentMP3(seconds: 3).write(to: other)
        #expect(ContentPrint.of(other) != before)
    }

    @Test func CP3_anEPUBsPrintIsItsTextWhateverItsDetailsAndCoverAre() throws {
        let dir = try makeTempDir()
        let url = try MediaFixtures.makeEPUB3(in: dir)
        let before = try #require(ContentPrint.of(url))
        #expect(before.hasPrefix("epub:"))
        try io.write(retagged(), cover: .set(cover(0.9)), to: url)
        #expect(ContentPrint.of(url) == before)
        // Another book.
        let other = try MediaFixtures.makeEPUB2(in: dir)
        #expect(ContentPrint.of(other) != before)
    }

    @Test func CP4_aPDFsPrintIsItsWordsWhateverItsTitleIs() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("a.pdf")
        makeWordyPDF(at: url)
        let before = try #require(ContentPrint.of(url))
        #expect(before.hasPrefix("pdf:4:"))
        try io.write(retagged(), to: url)
        #expect(ContentPrint.of(url) == before)
        let other = dir.appendingPathComponent("b.pdf")
        makeWordyPDF(at: other, word: "journal")
        #expect(ContentPrint.of(other) != before)
        let longer = dir.appendingPathComponent("c.pdf")
        makeWordyPDF(at: longer, pages: 5)
        #expect(ContentPrint.of(longer) != before)
    }

    @Test func CP5_whatCannotBeToldByItsContentsHasNoPrint() throws {
        let dir = try makeTempDir()
        // A PDF with next to no words: two scanned books must never be taken for one.
        let sparse = dir.appendingPathComponent("sparse.pdf")
        MediaFixtures.makePDF(at: sparse)
        #expect(ContentPrint.of(sparse) == nil)
        // Not what its name says, missing, or a kind that is kept as it is.
        let fake = dir.appendingPathComponent("fake.m4b")
        try Data(repeating: 1, count: 5000).write(to: fake)
        #expect(ContentPrint.of(fake) == nil)
        let notZip = dir.appendingPathComponent("fake.epub")
        try Data(repeating: 1, count: 5000).write(to: notZip)
        #expect(ContentPrint.of(notZip) == nil)
        #expect(ContentPrint.of(dir.appendingPathComponent("missing.mp3")) == nil)
        let mobi = dir.appendingPathComponent("a.mobi")
        try Data(repeating: 1, count: 5000).write(to: mobi)
        #expect(ContentPrint.key(of: mobi) == nil)
        // An MP3 that is nothing but tags has no sound to tell it by.
        let onlyTags = dir.appendingPathComponent("tags.mp3")
        try Data([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0]).write(to: onlyTags)
        #expect(ContentPrint.of(onlyTags) == nil)
    }

    @Test func CP6_thePrefixIsThePrintWithoutItsDigestAndIsSharedOnlyByFilesThatCouldBeTheSame() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("a.mp3")
        try MediaFixtures.makeSilentMP3(seconds: 2).write(to: url)
        let key = try #require(ContentPrint.key(of: url))
        let full = try #require(key.full())
        #expect(ContentPrint.prefix(of: full) == key.prefix)
        #expect(full.hasPrefix(key.prefix + ":"))
        #expect(ContentPrint.prefix(of: "nothing") == nil)
        let other = dir.appendingPathComponent("b.mp3")
        try MediaFixtures.makeSilentMP3(seconds: 3).write(to: other)
        #expect(ContentPrint.key(of: other)?.prefix != key.prefix)
    }

    // MARK: In a library

    @Test func CP7_aFileTheLibraryHasTaggedIsKnownAgainByWhatItHolds() throws {
        let f = try LibraryFixture().knowsFilesAgain()
        let source = f.inbox.appendingPathComponent("Shelf/Ann Author - Far Stars.m4b")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MediaFixtures.makeAAC(at: source, seconds: 2)
        let keptAside = try makeTempDir().appendingPathComponent("the original.m4b")
        try FileManager.default.copyItem(at: source, to: keptAside)

        // Imported, with other details and a cover written into the library's copy.
        var candidate = try #require(f.service.scan([source]).candidates.first)
        candidate.metadata = retagged()
        let outcome = try #require(try f.service.importItems(
            [ImportItem(candidate: candidate, cover: .set(cover(0.3)))], options: ImportOptions(mode: .copy)).outcomes.first)
        let id = try f.importedId(outcome)
        let filed = try #require(try f.store.files(bookId: id).first)
        #expect(filed.contentPrint?.hasPrefix("m4b:") == true)
        // The library's copy no longer has the bytes it came with.
        #expect(BookScanner.fingerprint(of: f.store.url(for: filed)) != filed.arrivedPrint)

        // A copy of the original, tagged differently again by some other program.
        let elsewhere = f.inbox.appendingPathComponent("Later/whatever it is called.m4b")
        try FileManager.default.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: keptAside, to: elsewhere)
        try io.write(BookMetadata(title: "Retitled Elsewhere", authors: ["Another Name"]), to: elsewhere)
        // And a different book beside it.
        let other = f.inbox.appendingPathComponent("Later/Bob Writer - Something Else.m4b")
        try MediaFixtures.makeAAC(at: other, seconds: 3)

        let result = f.service.scan([elsewhere.deletingLastPathComponent()])
        #expect(result.alreadyInLibrary.map(\.lastPathComponent) == ["whatever it is called.m4b"])
        #expect(result.candidates.map { $0.files[0].url.lastPathComponent } == [other.lastPathComponent])

        // A library told not to set aside what it has offers everything.
        try f.store.setKnowsFilesAgain(false)
        let all = f.service.scan([elsewhere.deletingLastPathComponent()])
        #expect(all.alreadyInLibrary.isEmpty && all.candidates.count == 2)
        try f.store.setKnowsFilesAgain(true)
        #expect(try f.store.knowsFilesAgain())
    }

    @Test func CP8_booksThatCameInBeforePrintsWereKeptAreGivenTheirs() throws {
        let f = try LibraryFixture().knowsFilesAgain()
        var ids: [Int64] = []
        for (index, seconds) in [2.0, 3.0, 4.0].enumerated() {
            let source = f.inbox.appendingPathComponent("Ann Author - Book \(index).m4b")
            try MediaFixtures.makeAAC(at: source, seconds: seconds)
            let candidate = try #require(f.service.scan([source]).candidates.first)
            ids.append(try f.importedId(try #require(
                try f.service.importItems([ImportItem(candidate: candidate)], options: ImportOptions(mode: .copy)).outcomes.first)))
        }
        // As a library from before: no print recorded, of either kind.
        try f.store.dbQueue.write { db in try db.execute(sql: "UPDATE bookFile SET contentPrint = NULL, arrivedPrint = NULL") }
        let again = f.inbox.appendingPathComponent("Ann Author - Book 1.m4b")
        #expect(f.service.scan([again]).alreadyInLibrary.isEmpty)

        // A few at a time, until none is left.
        #expect(try f.service.fillInContentPrints(limit: 2) == 2)
        #expect(try f.service.fillInContentPrints(limit: 2) == 1)
        #expect(try f.service.fillInContentPrints(limit: 2) == 0)
        #expect(try f.store.contentPrints().count == 3)
        // Now the book is known again, though the library's copy has been tagged.
        #expect(f.service.scan([again]).alreadyInLibrary.map(\.lastPathComponent) == [again.lastPathComponent])

        // A file that is missing waits; one with nothing to tell it by is marked done.
        try f.store.dbQueue.write { db in try db.execute(sql: "UPDATE bookFile SET contentPrint = NULL") }
        let first = try #require(try f.store.files(bookId: ids[0]).first)
        try FileManager.default.removeItem(at: f.store.url(for: first))
        #expect(try f.service.fillInContentPrints(limit: 10) == 2)
        #expect(try f.service.fillInContentPrints(limit: 10) == 0)
        #expect(try f.store.filesLackingContentPrint(limit: 10).map(\.id) == [first.id])
    }

    @Test func CP9_inOneScanTwoFilesThatDifferOnlyInTheirTagsAreOneFileAndACopy() throws {
        let root = try makeTempDir()
        let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
        try FileManager.default.createDirectory(at: shelf.appendingPathComponent("More"), withIntermediateDirectories: true)
        let first = shelf.appendingPathComponent("Ann Author - Far Stars.m4b")
        try MediaFixtures.makeAAC(at: first, seconds: 2)
        let second = shelf.appendingPathComponent("More/far stars (tagged).m4b")
        try FileManager.default.copyItem(at: first, to: second)
        try io.write(retagged(), cover: .set(cover(0.4)), to: second)
        let other = shelf.appendingPathComponent("More/Bob Writer - Something Else.m4b")
        try MediaFixtures.makeAAC(at: other, seconds: 3)

        let result = BookScanner().scan([shelf])
        #expect(result.candidates.count == 2)
        let kept = try #require(result.candidates.first { !$0.copies.isEmpty })
        #expect(kept.files.count == 1 && kept.copies.count == 1)
        #expect(Set([kept.files[0].url.lastPathComponent, kept.copies[0].lastPathComponent])
            == [first.lastPathComponent, second.lastPathComponent])
        #expect(result.candidates.contains { $0.files[0].url.lastPathComponent == other.lastPathComponent && $0.copies.isEmpty })
    }
}
