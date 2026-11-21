import Foundation
import Testing
import UniformTypeIdentifiers
import ZIPFoundation
@testable import VoxCarrelCore

@Suite struct EpubIOTests {
    static let opfPath = "OEBPS/content.opf"
    static let coverPath = "OEBPS/images/cover art.jpg"

    // MARK: Helpers

    struct Entry: Equatable {
        var path: String
        var crc: UInt32
        var compressedSize: UInt64
        var uncompressedSize: UInt64
    }

    func entries(_ url: URL) throws -> [Entry] {
        try Archive(url: url, accessMode: .read).map {
            Entry(path: $0.path, crc: $0.checksum, compressedSize: $0.compressedSize, uncompressedSize: $0.uncompressedSize)
        }
    }

    func opfText(_ url: URL) throws -> String {
        let archive = try Archive(url: url, accessMode: .read)
        return String(decoding: try EpubIO.data(Self.opfPath, in: archive), as: UTF8.self)
    }

    /// The text of every element in the OPF matched by `xpath`, in document order.
    func opfValues(_ url: URL, _ xpath: String) throws -> [String] {
        let document = try XMLDocument(xmlString: try opfText(url))
        return try document.nodes(forXPath: xpath).map { $0.stringValue ?? "" }
    }

    func leftovers(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".voxcarrel-") }
    }

    func jpeg() -> CoverImage { CoverImage(data: MediaFixtures.makeImage(.jpeg), mime: "image/jpeg") }

    /// The fixture's metadata as `read` should report it.
    func fixture3Metadata() -> BookMetadata {
        var m = BookMetadata(title: "Original Title", authors: ["First Author"])
        m.series = "Original Series"
        m.seriesNumber = "2"
        m.publisher = "Original Press"
        m.year = 2019
        m.language = "en"
        m.summary = "Original <b>description</b> & more"
        m.isbn = "9780000000001"
        m.genre = "Fantasy; Adventure"
        return m
    }

    /// Different values for every field an EPUB can hold.
    func changed() -> BookMetadata {
        var m = BookMetadata(title: "New Title & <Tags>", authors: ["Ann Author", "Bob Writer"])
        m.series = "X"
        m.seriesNumber = "2.5"
        m.publisher = "New Press"
        m.year = 2021
        m.language = "en-GB"
        m.summary = "New description"
        m.isbn = "9781111111111"
        m.genre = "A; B"
        return m
    }

    // MARK: Tests

    @Test func readsEPUB3() throws {
        let url = try MediaFixtures.makeEPUB3(in: makeTempDir())
        try EpubIO.validate(url)

        let contents = try EpubIO.read(url)

        let m = contents.metadata
        #expect(m.title == "Original Title")
        #expect(m.authors == ["First Author"]) // role aut only: "Some Editor" is excluded
        #expect(m.series == "Original Series")
        #expect(m.seriesNumber == "2")
        #expect(m.publisher == "Original Press")
        #expect(m.year == 2019)
        #expect(m.language == "en")
        #expect(m.summary == "Original <b>description</b> & more")
        #expect(m.isbn == "9780000000001")
        #expect(m.genre == "Fantasy; Adventure")
        #expect(m == fixture3Metadata())
        #expect(contents.cover == CoverImage(data: MediaFixtures.makeImage(.jpeg), mime: "image/jpeg"))
        #expect(contents.chapters.isEmpty)
    }

    @Test func roundTripEPUB3() throws {
        let url = try MediaFixtures.makeEPUB3(in: makeTempDir())
        let m = changed()
        let png = CoverImage(data: MediaFixtures.makeImage(.png, red: 0.1), mime: "image/png")

        try EpubIO.write(m, cover: .set(png), to: url)

        try EpubIO.validate(url)
        let contents = try EpubIO.read(url)
        #expect(contents.metadata == m)
        #expect(contents.metadata.title == "New Title & <Tags>")
        #expect(contents.metadata.authors == ["Ann Author", "Bob Writer"])
        #expect(contents.metadata.series == "X")
        #expect(contents.metadata.seriesNumber == "2.5")
        #expect(contents.metadata.publisher == "New Press")
        #expect(contents.metadata.year == 2021)
        #expect(contents.metadata.language == "en-GB")
        #expect(contents.metadata.summary == "New description")
        #expect(contents.metadata.isbn == "9781111111111")
        #expect(contents.metadata.genre == "A; B")
        // The manifest says JPEG, so the PNG was converted and the entry path kept.
        #expect(contents.cover?.mime == "image/jpeg")
        #expect(contents.cover?.data.prefix(3) == Data([0xFF, 0xD8, 0xFF]))
        #expect(contents.cover?.data != MediaFixtures.makeImage(.jpeg))

        #expect(try opfValues(url, "//*[local-name()='subject']") == ["A", "B"])
        let opf = try opfText(url)
        #expect(opf.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        #expect(opf.contains("New Title &amp; &lt;Tags&gt;"))
        #expect(!opf.contains("Author, First"), "file-as refinement of the replaced author should be gone")
        #expect(!opf.contains("2020-01-01T00:00:00Z"), "dcterms:modified should be refreshed")
        #expect(opf.contains("voxcarrel-creator-1"))
        #expect(opf.contains("voxcarrel-series"))
        #expect(!opf.contains("\"carrel-"))
    }

    @Test func everyOtherEntryIsByteIdentical() throws {
        let url = try MediaFixtures.makeEPUB3(in: makeTempDir())
        let before = try entries(url)
        let png = CoverImage(data: MediaFixtures.makeImage(.png, red: 0.1), mime: "image/png")

        try EpubIO.write(changed(), cover: .set(png), to: url)

        // Untouched entries keep their bytes and order; the two replaced ones move to the end.
        let after = try entries(url)
        #expect(after.map(\.path) == [
            "mimetype", "META-INF/container.xml", "OEBPS/nav.xhtml", "OEBPS/ch1.xhtml", Self.coverPath, Self.opfPath,
        ])
        #expect(Set(after.map(\.path)) == Set(before.map(\.path)))
        let replaced = [Self.opfPath, Self.coverPath]
        #expect(after.filter { !replaced.contains($0.path) } == before.filter { !replaced.contains($0.path) })
        for path in replaced {
            #expect(after.first { $0.path == path }?.crc != before.first { $0.path == path }?.crc, "\(path)")
        }

        // `mimetype` is still the first entry, stored: the archive's own view, then the raw bytes.
        #expect(after.first?.path == "mimetype")
        #expect(after.first?.compressedSize == after.first?.uncompressedSize)
        try EpubIO.validate(url)
        let head = [UInt8](try Data(contentsOf: url).prefix(58))
        try #require(head.count == 58)
        #expect(Array(head[0...3]) == [0x50, 0x4B, 0x03, 0x04]) // local file header
        #expect(Array(head[8...9]) == [0, 0]) // compression method 0 = stored
        #expect(Array(head[26...27]) == [8, 0]) // file name length
        #expect(Array(head[28...29]) == [0, 0]) // extra field length
        #expect(String(decoding: head[30...], as: UTF8.self) == "mimetypeapplication/epub+zip")

        // The system unzip agrees the archive is sound.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-tq", url.path]
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    @Test func unknownOPFContentSurvives() throws {
        let url = try MediaFixtures.makeEPUB3(in: makeTempDir())
        let png = CoverImage(data: MediaFixtures.makeImage(.png, red: 0.1), mime: "image/png")

        try EpubIO.write(changed(), cover: .set(png), to: url)

        let opf = try opfText(url)
        for keep in [
            "<!-- a comment that must survive -->",
            "<dc:identifier id=\"pub-id\">urn:uuid:12345678-1234-1234-1234-123456789abc</dc:identifier>",
            "<meta refines=\"#t1\" property=\"title-type\">main</meta>",
            "<dc:creator id=\"e1\">Some Editor</dc:creator>",
            "<meta refines=\"#e1\" property=\"role\" scheme=\"marc:relators\">edt</meta>",
            "<dc:rights>All rights reserved</dc:rights>",
            "<meta name=\"custom:thing\" content=\"keep me\"/>",
            "<x:unknown xmlns:x=\"http://example.com/x\" attr='single \"quoted\"'>opaque <![CDATA[<raw>]]></x:unknown>",
            "<spine page-progression-direction=\"ltr\">",
            "<reference type=\"text\" href=\"ch1.xhtml\" title=\"Start\"/>",
            "<item id=\"cover-img\" href=\"images/cover%20art.jpg\" media-type=\"image/jpeg\" properties=\"cover-image\"/>",
            "unique-identifier=\"pub-id\"",
        ] {
            #expect(opf.contains(keep), "lost: \(keep)")
        }
    }

    @Test func writingUnchangedMetadataOnlyTouchesModified() throws {
        let url = try MediaFixtures.makeEPUB3(in: makeTempDir())
        let before = try opfText(url)
        let metadata = try EpubIO.read(url).metadata

        try EpubIO.write(metadata, cover: .keep, to: url)

        let after = try opfText(url)
        let strip = { (s: String) in
            s.replacingOccurrences(
                of: #"<meta property="dcterms:modified">[^<]*</meta>"#, with: "", options: .regularExpression)
        }
        #expect(strip(after) == strip(before))
        #expect(strip(before) != before) // the pattern really matched something
        #expect(after != before, "dcterms:modified should be refreshed")
        #expect(try EpubIO.read(url).metadata == metadata)
    }

    @Test func clearingFieldsRemovesTheirElementsOnly() throws {
        let url = try MediaFixtures.makeEPUB3(in: makeTempDir())
        var m = try EpubIO.read(url).metadata
        m.series = nil
        m.seriesNumber = nil
        m.publisher = nil
        m.isbn = nil
        m.genre = nil

        try EpubIO.write(m, cover: .keep, to: url)

        #expect(try EpubIO.read(url).metadata == m)
        let cleared = try opfText(url)
        #expect(!cleared.contains("belongs-to-collection"))
        #expect(!cleared.contains("group-position"))
        #expect(!cleared.contains("urn:isbn"))
        #expect(!cleared.contains("dc:subject"))
        #expect(!cleared.contains("dc:publisher"))
        #expect(cleared.contains("urn:uuid:12345678"))
        #expect(cleared.contains("<dc:rights>All rights reserved</dc:rights>"))
    }

    @Test func uniqueIdentifierIsNeverRewritten() throws {
        let dir = try makeTempDir()

        // EPUB 3 with a separate ISBN identifier.
        let epub3 = try MediaFixtures.makeEPUB3(in: dir)
        var m3 = try EpubIO.read(epub3).metadata
        m3.isbn = "9781111111111"
        try EpubIO.write(m3, cover: .keep, to: epub3)
        #expect(try opfValues(epub3, "//*[@id='pub-id']") == ["urn:uuid:12345678-1234-1234-1234-123456789abc"])
        #expect(try opfText(epub3).contains("unique-identifier=\"pub-id\""))
        #expect(try EpubIO.read(epub3).metadata.isbn == "9781111111111")

        // EPUB 2.
        let epub2 = try MediaFixtures.makeEPUB2(in: dir)
        var m2 = try EpubIO.read(epub2).metadata
        m2.isbn = "9782222222222"
        try EpubIO.write(m2, cover: .keep, to: epub2)
        #expect(try opfValues(epub2, "//*[@id='uuid_id']") == ["abcdef"])
        #expect(try EpubIO.read(epub2).metadata.isbn == "9782222222222")

        // The unique identifier is itself the only ISBN: a new identifier is added beside it.
        let opf = MediaFixtures.opf3
            .replacingOccurrences(of: "urn:uuid:12345678-1234-1234-1234-123456789abc", with: "urn:isbn:9780000000009")
            .replacingOccurrences(of: "    <dc:identifier>urn:isbn:9780000000001</dc:identifier>\n", with: "")
        try #require(!opf.contains("9780000000001"))
        let own = dir.appendingPathComponent("own-isbn.epub")
        try MediaFixtures.makeEPUB(at: own, files: [
            (Self.opfPath, Data(opf.utf8)), ("OEBPS/nav.xhtml", Data(MediaFixtures.nav.utf8)),
            ("OEBPS/ch1.xhtml", Data(MediaFixtures.chapter.utf8)), (Self.coverPath, MediaFixtures.makeImage(.jpeg)),
        ])
        var mOwn = try EpubIO.read(own).metadata
        #expect(mOwn.isbn == "9780000000009")
        mOwn.isbn = "9783333333333"
        try EpubIO.write(mOwn, cover: .keep, to: own)
        #expect(try opfValues(own, "//*[@id='pub-id']") == ["urn:isbn:9780000000009"])
        #expect(try EpubIO.read(own).metadata.isbn == "9783333333333")

        // Clearing the ISBN there removes only the added identifier.
        mOwn.isbn = nil
        try EpubIO.write(mOwn, cover: .keep, to: own)
        #expect(try opfValues(own, "//*[@id='pub-id']") == ["urn:isbn:9780000000009"])
    }

    @Test func fullDateIsKeptWhenTheYearIsUnchanged() throws {
        let url = try MediaFixtures.makeEPUB3(in: makeTempDir())
        let date = "//*[local-name()='date']"
        #expect(try opfValues(url, date) == ["2019-03-01"])

        var m = try EpubIO.read(url).metadata
        m.title = "Another Title"
        m.year = 2019
        try EpubIO.write(m, cover: .keep, to: url)
        #expect(try opfValues(url, date) == ["2019-03-01"])
        #expect(try opfText(url).contains("<dc:date>2019-03-01</dc:date>"))
        #expect(try EpubIO.read(url).metadata.year == 2019)

        m.year = 2020
        try EpubIO.write(m, cover: .keep, to: url)
        #expect(try opfValues(url, date) == ["2020"])
        #expect(try EpubIO.read(url).metadata.year == 2020)
    }

    @Test func roundTripEPUB2WithoutCover() throws {
        let url = try MediaFixtures.makeEPUB2(in: makeTempDir())
        let before = try EpubIO.read(url)
        #expect(before.metadata.title == "Calibre Book")
        #expect(before.metadata.authors == ["First Author", "Second Author"])
        #expect(before.metadata.series == "Calibre Series")
        #expect(before.metadata.seriesNumber == "3")
        #expect(before.metadata.isbn == "9780000000002")
        #expect(before.metadata.year == 2011)
        #expect(before.cover == nil)

        var m = before.metadata
        m.authors = ["Only Author"]
        m.series = "Renamed"
        m.seriesNumber = "4"
        m.isbn = "9782222222222"
        m.summary = "Added description"
        m.publisher = "Added Press"
        m.genre = "History"
        try EpubIO.write(m, cover: .set(jpeg()), to: url)
        try EpubIO.validate(url)

        let after = try EpubIO.read(url)
        #expect(after.metadata == m)
        #expect(after.cover == jpeg())
        let opf = try opfText(url)
        #expect(opf.contains("<dc:creator opf:role=\"aut\">Only Author</dc:creator>"))
        #expect(opf.contains("<dc:contributor opf:role=\"bkp\">calibre (7.0) [https://calibre-ebook.com]</dc:contributor>"))
        #expect(opf.contains("<meta name=\"calibre:timestamp\" content=\"2024-01-01T00:00:00+00:00\"/>"))
        #expect(opf.contains("<dc:identifier opf:scheme=\"uuid\" id=\"uuid_id\">abcdef</dc:identifier>"))
        #expect(opf.contains("<dc:identifier opf:scheme=\"ISBN\">9782222222222</dc:identifier>"))
        #expect(opf.contains("<dc:date>2011-06-01T00:00:00+00:00</dc:date>"))
        #expect(!opf.contains("belongs-to-collection"), "EPUB 3 collection metadata must not be written into an EPUB 2 package")
        #expect(opf.contains("<spine toc=\"ncx\">"))
        #expect(opf.contains("voxcarrel-cover"))
    }

    @Test func reportsWhatAnEPUBCannotHold() throws {
        let url = try MediaFixtures.makeEPUB3(in: makeTempDir())
        let cannotHold: Set<MetadataField> = [.subtitle, .narrators, .asin]
        #expect(EpubIO.unstorable == cannotHold)
        var m = changed()
        m.subtitle = "A Subtitle"
        m.narrators = ["Some Narrator"]
        m.asin = "B000000000"

        let kept = try EpubIO.write(m, cover: .keep, to: url)
        #expect(kept.notWritten == cannotHold)

        let removed = try EpubIO.write(m, cover: .remove, to: url)
        #expect(removed.notWritten == cannotHold.union([.cover]))
        #expect(removed.notWritten.contains(.cover))
        #expect(try EpubIO.read(url).cover == jpeg()) // the existing cover is still there

        let set = try EpubIO.write(m, cover: .set(jpeg()), to: url)
        #expect(set.notWritten == cannotHold)

        // What cannot be held does not come back.
        let after = try EpubIO.read(url).metadata
        #expect(after.subtitle == nil)
        #expect(after.narrators.isEmpty)
        #expect(after.asin == nil)
    }

    @Test func brokenFilesThrowAndAreLeftAlone() throws {
        let dir = try makeTempDir()
        let url = try touch(dir.appendingPathComponent("x.epub"), "this is not a zip archive")
        let bytes = try Data(contentsOf: url)

        #expect(throws: MetadataIOError.unreadable("x.epub")) { _ = try EpubIO.read(url) }
        #expect(throws: MetadataIOError.unreadable("x.epub")) {
            try EpubIO.write(changed(), cover: .keep, to: url)
        }
        #expect(throws: MetadataIOError.unreadable("x.epub")) {
            try EpubIO.write(changed(), cover: .set(jpeg()), to: url)
        }

        #expect(try Data(contentsOf: url) == bytes)
        #expect(try leftovers(dir).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["x.epub"])
    }
}
