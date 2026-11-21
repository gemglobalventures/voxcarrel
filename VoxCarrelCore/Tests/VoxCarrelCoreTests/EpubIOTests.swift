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

        // The unique identifier is itself the only ISBN: it is left alone, nothing is added
        // beside it, and the caller is told the ISBN was not written.
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
        let unchanged = try EpubIO.write(mOwn, cover: .keep, to: own)
        #expect(!unchanged.notWritten.contains(.isbn)) // nothing was asked for

        mOwn.isbn = "9783333333333"
        let changedReport = try EpubIO.write(mOwn, cover: .keep, to: own)
        #expect(changedReport.notWritten.contains(.isbn))
        #expect(try opfValues(own, "//*[@id='pub-id']") == ["urn:isbn:9780000000009"])
        #expect(try opfValues(own, "//*[local-name()='identifier']") == ["urn:isbn:9780000000009"])
        #expect(try EpubIO.read(own).metadata.isbn == "9780000000009")

        mOwn.isbn = nil
        let clearedReport = try EpubIO.write(mOwn, cover: .keep, to: own)
        #expect(clearedReport.notWritten.contains(.isbn))
        #expect(try opfValues(own, "//*[local-name()='identifier']") == ["urn:isbn:9780000000009"])
        #expect(try EpubIO.read(own).metadata.isbn == "9780000000009")
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

    // MARK: More fixtures

    /// An EPUB with the given package document, plus the usual chapter, nav and cover.
    func epub(_ name: String, opf: String, cover: (path: String, data: Data)? = (EpubIOTests.coverPath, MediaFixtures.makeImage(.jpeg)),
              in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var files: [(path: String, data: Data)] = [
            (Self.opfPath, Data(opf.utf8)), ("OEBPS/nav.xhtml", Data(MediaFixtures.nav.utf8)),
            ("OEBPS/ch1.xhtml", Data(MediaFixtures.chapter.utf8)), ("OEBPS/toc.ncx", Data(MediaFixtures.ncx.utf8)),
        ]
        if let cover { files.append(cover) }
        try MediaFixtures.makeEPUB(at: url, files: files)
        return url
    }

    // MARK: Character references

    @Test func textMixingCharacterReferencesAndEntitiesIsReadAndKeptExactly() throws {
        let opf = MediaFixtures.opf3
            .replacingOccurrences(of: "Original Title", with: "Tom &amp; Jerry&#8217;s &#xE9;t&#233; &lt;1&gt;")
            .replacingOccurrences(of: "Original &lt;b&gt;description&lt;/b&gt; &amp; more", with: "&#8220;Q&amp;A&#8221; with the author")
            .replacingOccurrences(of: "All rights reserved", with: "&#8220;Q&amp;A&#8221; &#169;2020 Smith &amp; Sons&#8217; Press")
            .replacingOccurrences(of: "content=\"keep me\"", with: "content=\"keep &amp; &quot;me&quot; &#233;\"")
        let url = try epub("refs.epub", opf: opf, in: makeTempDir())
        let rights = "//*[local-name()='rights']"
        let custom = "//*[local-name()='meta'][@name='custom:thing']/@content"
        let rightsBefore = try opfValues(url, rights)
        #expect(rightsBefore == ["\u{201C}Q&A\u{201D} ©2020 Smith & Sons\u{2019} Press"])

        var m = try EpubIO.read(url).metadata
        #expect(m.title == "Tom & Jerry\u{2019}s été <1>")
        #expect(m.summary == "\u{201C}Q&A\u{201D} with the author")

        // Writing back exactly what was read must succeed and change no text.
        try EpubIO.write(m, cover: .keep, to: url)
        #expect(try EpubIO.read(url).metadata == m)
        #expect(try opfValues(url, rights) == rightsBefore)
        #expect(try opfValues(url, custom) == ["keep & \"me\" é"])

        // Changing one field leaves the text of the others exactly as it was.
        m.publisher = "Another Press"
        try EpubIO.write(m, cover: .keep, to: url)
        #expect(try EpubIO.read(url).metadata == m)
        #expect(try opfValues(url, rights) == rightsBefore)
        #expect(try opfValues(url, custom) == ["keep & \"me\" é"])
        #expect(try opfValues(url, "//*[local-name()='title']") == ["Tom & Jerry\u{2019}s été <1>"])
    }

    // MARK: Cover paths

    @Test func coverHrefWithParentFolderIsResolved() throws {
        let dir = try makeTempDir()
        let opf = MediaFixtures.opf3.replacingOccurrences(of: "images/cover%20art.jpg", with: "../images/./cover%20art.jpg")
        let old = MediaFixtures.makeImage(.jpeg)
        let url = try epub("dotdot.epub", opf: opf, cover: ("images/cover art.jpg", old), in: dir)
        let pathsBefore = try entries(url).map(\.path).sorted()

        #expect(try EpubIO.read(url).cover == CoverImage(data: old, mime: "image/jpeg"))

        let new = CoverImage(data: MediaFixtures.makeImage(.jpeg, size: 32, red: 0.1), mime: "image/jpeg")
        let report = try EpubIO.write(try EpubIO.read(url).metadata, cover: .set(new), to: url)

        #expect(!report.notWritten.contains(.cover))
        #expect(try entries(url).map(\.path).sorted() == pathsBefore)
        #expect(try entries(url).allSatisfy { !$0.path.contains("..") })
        #expect(try EpubIO.read(url).cover == new)
    }

    @Test func aCoverItemWhoseFileIsMissingIsLeftAlone() throws {
        let dir = try makeTempDir()
        for (name, href) in [("missing.epub", "images/not-there.jpg"), ("outside.epub", "../../escape.jpg")] {
            let opf = MediaFixtures.opf3.replacingOccurrences(of: "images/cover%20art.jpg", with: href)
            let url = try epub(name, opf: opf, in: dir)
            let pathsBefore = try entries(url).map(\.path).sorted()
            #expect(try EpubIO.read(url).cover == nil, "\(name)")

            var m = try EpubIO.read(url).metadata
            m.title = "Still Written"
            let report = try EpubIO.write(m, cover: .set(jpeg()), to: url)

            #expect(report.notWritten.contains(.cover), "\(name)")
            #expect(try entries(url).map(\.path).sorted() == pathsBefore, "\(name)")
            #expect(try !opfText(url).contains("voxcarrel-cover"), "\(name)")
            #expect(try EpubIO.read(url).metadata.title == "Still Written", "\(name)")
        }
    }

    @Test func aCoverThatCannotBeConvertedIsLeftAlone() throws {
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"/>".utf8)
        let opf = MediaFixtures.opf3.replacingOccurrences(
            of: "href=\"images/cover%20art.jpg\" media-type=\"image/jpeg\"", with: "href=\"images/cover.svg\" media-type=\"image/svg+xml\"")
        try #require(opf.contains("cover.svg"))
        let url = try epub("svg.epub", opf: opf, cover: ("OEBPS/images/cover.svg", svg), in: makeTempDir())

        var m = try EpubIO.read(url).metadata
        m.title = "Still Written"
        let report = try EpubIO.write(m, cover: .set(jpeg()), to: url)

        #expect(report.notWritten.contains(.cover))
        #expect(try EpubIO.read(url).cover?.data == svg)
        #expect(try EpubIO.read(url).metadata.title == "Still Written")
    }

    // MARK: Required elements

    @Test func titleAndLanguageAreNeverRemoved() throws {
        let dir = try makeTempDir()
        for url in [try MediaFixtures.makeEPUB3(in: dir), try MediaFixtures.makeEPUB2(in: dir)] {
            let name = url.lastPathComponent
            let before = try EpubIO.read(url).metadata
            var bare = BookMetadata() // as it might arrive from a sibling audio file or an empty record
            bare.authors = before.authors

            try EpubIO.write(bare, cover: .keep, to: url)

            let after = try EpubIO.read(url).metadata
            #expect(after.title == before.title, "\(name)")
            #expect(after.language == before.language, "\(name)")
            #expect(after.publisher == nil, "\(name)") // optional elements are still removed
            #expect(try opfValues(url, "//*[local-name()='title']") == [before.title], "\(name)")
            #expect(try opfValues(url, "//*[local-name()='language']") == ["en"], "\(name)")
        }
    }

    // MARK: Namespaces

    @Test func epub2WithoutAnOPFPrefixDeclarationGetsOne() throws {
        let opf = MediaFixtures.opf2
            .replacingOccurrences(of: " xmlns:opf=\"http://www.idpf.org/2007/opf\"", with: "")
            .replacingOccurrences(of: " opf:scheme=\"uuid\"", with: "")
            .replacingOccurrences(of: "    <dc:identifier opf:scheme=\"ISBN\">9780000000002</dc:identifier>\n", with: "")
            .replacingOccurrences(of: " opf:role=\"aut\" opf:file-as=\"Author, First\"", with: "")
            .replacingOccurrences(of: " opf:role=\"aut\"", with: "")
            .replacingOccurrences(of: " opf:role=\"bkp\"", with: "")
        try #require(!opf.contains("opf:"))
        let url = try epub("bare2.epub", opf: opf, cover: nil, in: makeTempDir())

        var m = try EpubIO.read(url).metadata
        m.authors = ["New Author"]
        m.isbn = "9781111111111"
        try EpubIO.write(m, cover: .keep, to: url)

        #expect(try EpubIO.read(url).metadata == m)
        let text = try opfText(url)
        #expect(text.contains("xmlns:opf=\"http://www.idpf.org/2007/opf\""))
        #expect(text.contains("<dc:creator opf:role=\"aut\">New Author</dc:creator>"))
        #expect(text.contains("<dc:identifier opf:scheme=\"ISBN\">9781111111111</dc:identifier>"))
        // A namespace-aware parse resolves the new attributes to the OPF namespace.
        let document = try XMLDocument(xmlString: text)
        let creators = try document.nodes(forXPath: "//*[local-name()='creator']").compactMap { $0 as? XMLElement }
        #expect(creators.map { $0.attribute(forLocalName: "role", uri: "http://www.idpf.org/2007/opf")?.stringValue } == ["aut"])
    }

    @Test func prefixedPackageDocumentGetsPrefixedElements() throws {
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opf:package xmlns:opf="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0" unique-identifier="id">
          <opf:metadata>
            <dc:identifier id="id">abc</dc:identifier>
            <dc:title>Prefixed</dc:title>
            <dc:language>en</dc:language>
          </opf:metadata>
          <opf:manifest>
            <opf:item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
          </opf:manifest>
          <opf:spine><opf:itemref idref="ch1"/></opf:spine>
        </opf:package>
        """
        let url = try epub("prefixed.epub", opf: opf, cover: nil, in: makeTempDir())
        var m = try EpubIO.read(url).metadata
        #expect(m.title == "Prefixed")
        m.series = "Ser"
        m.seriesNumber = "2"
        m.authors = ["Ann Author"]
        m.isbn = "9781111111111"

        try EpubIO.write(m, cover: .set(jpeg()), to: url)

        let after = try EpubIO.read(url)
        #expect(after.metadata == m)
        #expect(after.cover == jpeg())
        let text = try opfText(url)
        #expect(text.contains("<opf:meta "))
        #expect(try opfValues(url, "//*[local-name()='meta'][@name='calibre:series']/@content") == ["Ser"])
        #expect(text.contains("<opf:item id=\"voxcarrel-cover\""))
        #expect(!text.contains("<meta "), "new elements must not fall outside the OPF namespace")
        #expect(!text.contains("<item "))
        // Every element directly inside metadata and manifest is in a namespace.
        let document = try XMLDocument(xmlString: text)
        let stray = try document.nodes(forXPath: "/*/*/*[namespace-uri()='']")
        #expect(stray.isEmpty)
        #expect(text.contains("<dc:creator opf:role=\"aut\">Ann Author</dc:creator>"))
    }

    // MARK: The mimetype rule

    @Test func anEPUBThatAlreadyBreaksTheMimetypeRuleCanStillBeWritten() throws {
        let url = try makeTempDir().appendingPathComponent("casual.epub")
        do { // as "zip -r" would make it: mimetype compressed, and not first
            let archive = try Archive(url: url, accessMode: .create)
            for (path, text) in [("META-INF/container.xml", MediaFixtures.container), ("mimetype", "application/epub+zip"),
                                 (Self.opfPath, MediaFixtures.opf2), ("OEBPS/ch1.xhtml", MediaFixtures.chapter)] {
                let data = Data(text.utf8)
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
                    data.subdata(in: Int(position)..<Int(position) + size)
                }
            }
        }
        #expect(throws: (any Error).self) { try EpubIO.validate(url) } // the fixture really does break the rule

        var m = try EpubIO.read(url).metadata
        m.title = "Written Anyway"
        try EpubIO.write(m, cover: .keep, to: url)

        #expect(try EpubIO.read(url).metadata == m)
        #expect(try entries(url).map(\.path).sorted() == ["META-INF/container.xml", "OEBPS/ch1.xhtml", "OEBPS/content.opf", "mimetype"])
    }

    // MARK: Series

    @Test func aSeriesWithoutANumberStaysWithoutOne() throws {
        let dir = try makeTempDir()
        for url in [try MediaFixtures.makeEPUB3(in: dir), try MediaFixtures.makeEPUB2(in: dir)] {
            let name = url.lastPathComponent
            var m = try EpubIO.read(url).metadata
            m.series = "Solo"
            m.seriesNumber = nil

            try EpubIO.write(m, cover: .keep, to: url)

            let after = try EpubIO.read(url).metadata
            #expect(after.series == "Solo", "\(name)")
            #expect(after.seriesNumber == nil, "\(name)")
            let text = try opfText(url)
            #expect(try opfValues(url, "//*[local-name()='meta'][@name='calibre:series']/@content") == ["Solo"], "\(name)")
            #expect(!text.contains("calibre:series_index"), "\(name)")
            #expect(!text.contains("group-position"), "\(name)")
        }
    }

    @Test func aCollectionThatIsNotASeriesIsNotTreatedAsOne() throws {
        let opf = MediaFixtures.opf3.replacingOccurrences(
            of: "<meta refines=\"#c1\" property=\"collection-type\">series</meta>",
            with: "<meta refines=\"#c1\" property=\"collection-type\">set</meta>")
        try #require(opf.contains(">set</meta>"))
        let url = try epub("set.epub", opf: opf, in: makeTempDir())

        var m = try EpubIO.read(url).metadata
        #expect(m.series == nil)
        #expect(m.seriesNumber == nil)

        m.series = "A Real Series"
        m.seriesNumber = "7"
        try EpubIO.write(m, cover: .keep, to: url)

        #expect(try EpubIO.read(url).metadata == m)
        let text = try opfText(url)
        #expect(text.contains("<meta property=\"belongs-to-collection\" id=\"c1\">Original Series</meta>"))
        #expect(text.contains("<meta refines=\"#c1\" property=\"collection-type\">set</meta>"))
        #expect(text.contains("<meta refines=\"#c1\" property=\"group-position\">2</meta>"))

        m.series = nil
        m.seriesNumber = nil
        try EpubIO.write(m, cover: .keep, to: url)
        #expect(try opfText(url).contains("<meta property=\"belongs-to-collection\" id=\"c1\">Original Series</meta>"))
        #expect(try !opfText(url).contains("A Real Series"))
    }

    // MARK: DOCTYPE

    @Test func aDoctypeInThePackageDocumentIsKept() throws {
        let doctype = "<!DOCTYPE package PUBLIC \"+//ISBN 0-9673008-1-9//DTD OEB 1.2 Package//EN\" \"http://openebook.org/dtds/oeb-1.2/oebpkg12.dtd\">"
        let opf = MediaFixtures.opf2.replacingOccurrences(of: "<package ", with: doctype + "\n<package ")
        let url = try epub("doctype.epub", opf: opf, cover: nil, in: makeTempDir())

        var m = try EpubIO.read(url).metadata
        m.title = "With A Doctype"
        try EpubIO.write(m, cover: .keep, to: url)

        let text = try opfText(url)
        #expect(text.contains(doctype + "\n<package "))
        #expect(try EpubIO.read(url).metadata == m)
    }

    // MARK: Verification of the changed copy

    /// What `write` would expect of a copy of `url` after applying `edit` to its metadata.
    func expectation(for url: URL, mimetypeRule: Bool = true, edit: (inout BookMetadata) -> Void = { _ in }) throws -> EpubIO.Expectation {
        let package = try EpubIO.Package(archive: try Archive(url: url, accessMode: .read))
        var m = EpubIO.bookMetadata(from: package.readMetadata())
        edit(&m)
        _ = package.apply(EpubIO.epubMetadata(from: m, existing: package.readMetadata()))
        return package.expectation(mimetypeRule: mimetypeRule)
    }

    @Test func verificationRejectsACopyWhoseUneditedMetadataChanged() throws {
        let dir = try makeTempDir()
        let original = try epub("original.epub", opf: MediaFixtures.opf3, in: dir)
        let expected = try expectation(for: original)
        try EpubIO.verify(original, against: expected) // an identical copy is fine

        let tampered: [(String, String, String)] = [
            ("text.epub", "All rights reserved", "All rights reserved reserved"),
            ("attribute.epub", "content=\"keep me\"", "content=\"keep  me\""),
            ("dropped.epub", "    <dc:rights>All rights reserved</dc:rights>\n", ""),
            ("added.epub", "    <dc:rights>", "    <dc:source>x</dc:source>\n    <dc:rights>"),
        ]
        for (name, from, to) in tampered {
            let opf = MediaFixtures.opf3.replacingOccurrences(of: from, with: to)
            try #require(opf != MediaFixtures.opf3)
            let copy = try epub(name, opf: opf, in: dir)
            #expect(throws: EpubError.self, "\(name)") { try EpubIO.verify(copy, against: expected) }
        }

        // An element the edit did mean to change is free to differ.
        let retitled = try expectation(for: original) { $0.title = "Retitled" }
        let good = try epub("retitled.epub", opf: MediaFixtures.opf3.replacingOccurrences(of: "Original Title", with: "Retitled"), in: dir)
        try EpubIO.verify(good, against: retitled)
        // But the required elements may not come out empty.
        let untitled = try epub("untitled.epub", opf: MediaFixtures.opf3.replacingOccurrences(of: "Original Title", with: " "), in: dir)
        #expect(throws: EpubError.self) { try EpubIO.verify(untitled, against: retitled) }
        let relabelled = try expectation(for: original) { $0.language = "fr" }
        let noLanguage = try epub("nolanguage.epub", opf: MediaFixtures.opf3.replacingOccurrences(of: "<dc:language>en</dc:language>", with: "<dc:language></dc:language>"), in: dir)
        #expect(throws: EpubError.self) { try EpubIO.verify(noLanguage, against: relabelled) }
    }

    @Test func verificationChecksEveryEntryAndTheMimetypeRuleOnlyWhenItHeldBefore() throws {
        let dir = try makeTempDir()
        let marker = "MARKER-MARKER-MARKER-MARKER"

        // A stored entry with one byte flipped: the archive still opens, the CRC no longer matches.
        let damaged = dir.appendingPathComponent("damaged.epub")
        do {
            let archive = try Archive(url: damaged, accessMode: .create)
            for (path, text, method) in [("mimetype", "application/epub+zip", CompressionMethod.none), ("META-INF/container.xml", MediaFixtures.container, .deflate),
                                         (Self.opfPath, MediaFixtures.opf2, .deflate), ("OEBPS/notes.txt", marker, .none)] {
                let data = Data(text.utf8)
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: method) { position, size in
                    data.subdata(in: Int(position)..<Int(position) + size)
                }
            }
        }
        let expected = try expectation(for: damaged)
        try EpubIO.verify(damaged, against: expected)
        var bytes = try Data(contentsOf: damaged)
        let range = try #require(bytes.range(of: Data(marker.utf8)))
        bytes[range.lowerBound] ^= 0xFF
        try bytes.write(to: damaged)
        #expect(throws: (any Error).self) { try EpubIO.verify(damaged, against: expected) }

        // mimetype compressed: acceptable only when the original was like that too.
        let casual = dir.appendingPathComponent("casual.epub")
        do {
            let archive = try Archive(url: casual, accessMode: .create)
            for (path, text) in [("mimetype", "application/epub+zip"), ("META-INF/container.xml", MediaFixtures.container), (Self.opfPath, MediaFixtures.opf2)] {
                let data = Data(text.utf8)
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
                    data.subdata(in: Int(position)..<Int(position) + size)
                }
            }
        }
        try EpubIO.verify(casual, against: try expectation(for: casual, mimetypeRule: false))
        #expect(throws: EpubError.self) { try EpubIO.verify(casual, against: try expectation(for: casual, mimetypeRule: true)) }
    }
}
