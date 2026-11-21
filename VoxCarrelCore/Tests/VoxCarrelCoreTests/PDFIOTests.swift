import Foundation
import PDFKit
import Testing
@testable import VoxCarrelCore

@Suite struct PDFIOTests {
    func fixture(pages: Int = 3) throws -> URL {
        let url = try makeTempDir().appendingPathComponent("book.pdf")
        MediaFixtures.makePDF(at: url, pages: pages)
        return url
    }

    @Test func readsTitleAuthorsAndPageCount() throws {
        let url = try fixture(pages: 4)
        let m = BookMetadata(title: "Sapiens", authors: ["Yuval Noah Harari", "Second Author"])
        try PDFIO.write(m, cover: .keep, to: url)

        let contents = try PDFIO.read(url)
        #expect(contents.metadata.title == "Sapiens")
        #expect(contents.metadata.authors == ["Yuval Noah Harari", "Second Author"])
        #expect(contents.metadata.pageCount == 4)
        #expect(contents.cover == nil)
        #expect(contents.chapters.isEmpty)
    }

    @Test func clearingTitleAndAuthorsRemovesThem() throws {
        let url = try fixture()
        try PDFIO.write(BookMetadata(title: "T", authors: ["A B"]), cover: .keep, to: url)
        try PDFIO.write(BookMetadata(), cover: .keep, to: url)

        let contents = try PDFIO.read(url)
        #expect(contents.metadata.title == "")
        #expect(contents.metadata.authors.isEmpty)
    }

    @Test func reportsEverythingElseAsNotWritten() throws {
        let url = try fixture()
        let everythingElse = Set(MetadataField.allCases).subtracting([.title, .authors, .cover])

        let kept = try PDFIO.write(BookMetadata(title: "T"), cover: .keep, to: url)
        #expect(kept.notWritten == everythingElse)

        let image = CoverImage(data: MediaFixtures.makeImage(.jpeg), mime: "image/jpeg")
        let withCover = try PDFIO.write(BookMetadata(title: "T"), cover: .set(image), to: url)
        #expect(withCover.notWritten == everythingElse.union([.cover]))
    }

    @Test func lockedAndEncryptedPDFsAreRefusedAndLeftAlone() throws {
        let dir = try makeTempDir()
        let plain = dir.appendingPathComponent("plain.pdf")
        MediaFixtures.makePDF(at: plain)
        let source = try #require(PDFDocument(url: plain))

        // User password: cannot be opened without it.
        let locked = dir.appendingPathComponent("locked.pdf")
        #expect(source.write(to: locked, withOptions: [.userPasswordOption: "user", .ownerPasswordOption: "owner"]))
        // Owner password only: opens freely, but is encrypted with restricted permissions.
        let restricted = dir.appendingPathComponent("restricted.pdf")
        #expect(source.write(to: restricted, withOptions: [.ownerPasswordOption: "owner"]))

        let lockedDoc = try #require(PDFDocument(url: locked))
        #expect(lockedDoc.isLocked)
        let restrictedDoc = try #require(PDFDocument(url: restricted))
        #expect(restrictedDoc.isEncrypted)
        #expect(!restrictedDoc.isLocked)

        let image = CoverImage(data: MediaFixtures.makeImage(.jpeg), mime: "image/jpeg")
        for url in [locked, restricted] {
            let name = url.lastPathComponent
            let bytes = try Data(contentsOf: url)
            #expect(throws: MetadataIOError.locked(name)) {
                try PDFIO.write(BookMetadata(title: "x", authors: ["y"]), cover: .keep, to: url)
            }
            #expect(throws: MetadataIOError.locked(name)) {
                try PDFIO.write(BookMetadata(), cover: .set(image), to: url)
            }
            #expect(try Data(contentsOf: url) == bytes)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
            == ["locked.pdf", "plain.pdf", "restricted.pdf"])

        // The owner-password-only file reads normally.
        let open = try PDFIO.read(restricted)
        #expect(open.metadata.title == "Original Title")
        #expect(open.metadata.authors == ["Original Author"])
        #expect(open.metadata.pageCount == 3)

        // A locked file gives up its page count and nothing else.
        let closed = try PDFIO.read(locked)
        #expect(closed.metadata.pageCount == 3)
        #expect(closed.metadata.title == "")
        #expect(closed.metadata.authors.isEmpty)
    }

    @Test func notAPDFThrowsUnreadable() throws {
        let url = try touch(makeTempDir().appendingPathComponent("fake.pdf"), "not a pdf")
        #expect(throws: MetadataIOError.unreadable("fake.pdf")) { _ = try PDFIO.read(url) }
        #expect(throws: MetadataIOError.unreadable("fake.pdf")) {
            try PDFIO.write(BookMetadata(title: "T"), cover: .keep, to: url)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "not a pdf")
    }

    @Test func otherContentSurvives() throws {
        let url = try fixture()

        // Add an outline and a link annotation so we can see whether a rewrite keeps them.
        do {
            let doc = try #require(PDFDocument(url: url))
            let root = PDFOutline()
            let item = PDFOutline()
            item.label = "Second page"
            let second = try #require(doc.page(at: 1))
            item.destination = PDFDestination(page: second, at: CGPoint(x: 0, y: 792))
            root.insertChild(item, at: 0)
            doc.outlineRoot = root
            let link = PDFAnnotation(
                bounds: CGRect(x: 72, y: 600, width: 200, height: 20), forType: .link, withProperties: nil)
            link.url = URL(string: "https://example.com/")
            let first = try #require(doc.page(at: 0))
            first.addAnnotation(link)
            #expect(doc.write(to: url))
        }

        let before = try PDFIO.read(url)
        #expect(before.metadata.title == "Original Title")
        #expect(before.metadata.authors == ["Original Author"])
        #expect(before.metadata.pageCount == 3)
        let docBefore = try #require(PDFDocument(url: url))
        let textBefore = (0..<3).map { docBefore.page(at: $0)?.string }
        #expect(docBefore.outlineRoot?.child(at: 0)?.label == "Second page")
        #expect(docBefore.page(at: 0)?.annotations.first?.url?.absoluteString == "https://example.com/")

        try PDFIO.write(BookMetadata(title: "New Tïtle", authors: ["New Author"]), cover: .keep, to: url)

        let after = try PDFIO.read(url)
        #expect(after.metadata.title == "New Tïtle")
        #expect(after.metadata.authors == ["New Author"])
        #expect(after.metadata.pageCount == 3)
        let doc = try #require(PDFDocument(url: url))
        let attributes = try #require(doc.documentAttributes)
        #expect(attributes[PDFDocumentAttribute.keywordsAttribute] as? [String] == ["alpha", "beta"])
        #expect(attributes[PDFDocumentAttribute.subjectAttribute] as? String == "Original Subject")
        #expect(doc.outlineRoot?.child(at: 0)?.label == "Second page")
        #expect(doc.outlineRoot?.child(at: 0)?.destination?.page.map { doc.index(for: $0) } == 1)
        #expect(doc.page(at: 0)?.annotations.first?.url?.absoluteString == "https://example.com/")
        #expect(doc.page(at: 2)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) == "Page 3 of the fixture")
        #expect((0..<3).map { doc.page(at: $0)?.string } == textBefore)
        for page in 0..<3 {
            #expect(doc.page(at: page)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
                == "Page \(page + 1) of the fixture")
        }
    }

    @Test func noTempFilesAreLeftBehind() throws {
        let url = try fixture()
        try PDFIO.write(BookMetadata(title: "T"), cover: .keep, to: url)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(names == ["book.pdf"])
    }

    // MARK: Awkward author names

    @Test func authorNamesWithSeparatorCharactersCanBeWritten() throws {
        let url = try fixture()
        // What is written, and what a later read legitimately reports for it.
        let cases: [([String], [String])] = [
            (["Simon & Schuster"], ["Simon & Schuster"]),
            (["Penn & Teller", "Tolkien, J. R. R."], ["Penn & Teller", "Tolkien, J. R. R."]),
            (["Smith; Jones"], ["Smith", "Jones"]),
            (["Neil Gaiman, Terry Pratchett"], ["Neil Gaiman", "Terry Pratchett"]),
            (["  Padded Name ", "", "   "], ["Padded Name"]),
        ]
        for (written, readBack) in cases {
            try PDFIO.write(BookMetadata(title: "T", authors: written), cover: .keep, to: url)
            #expect(try PDFIO.read(url).metadata.authors == readBack, "\(written)")
        }

        // Only blank names: the author is removed rather than written as an empty string.
        try PDFIO.write(BookMetadata(title: "T", authors: ["", " "]), cover: .keep, to: url)
        #expect(try PDFIO.read(url).metadata.authors.isEmpty)
        let attributes = try #require(PDFDocument(url: url)?.documentAttributes)
        #expect(attributes[PDFDocumentAttribute.authorAttribute] == nil)
    }
}
