import Foundation
import Testing
@testable import VoxCarrelCore

@Suite struct FileMetadataIOTests {
    let io = FileMetadataIO()

    func tagged(_ title: String, author: String) -> BookMetadata {
        BookMetadata(title: title, authors: [author])
    }

    @Test func routesEachFormatToItsModule() throws {
        let dir = try makeTempDir()
        let m4b = dir.appendingPathComponent("a.M4B")  // extension case must not matter
        try MediaFixtures.makeAAC(at: m4b, seconds: 2)
        let mp3 = dir.appendingPathComponent("a.mp3")
        try MediaFixtures.makeSilentMP3(seconds: 2).write(to: mp3)
        let epub = try MediaFixtures.makeEPUB3(in: dir)
        let pdf = dir.appendingPathComponent("a.pdf")
        MediaFixtures.makePDF(at: pdf, pages: 2)

        for url in [m4b, mp3, epub, pdf] {
            try io.write(tagged("Routed", author: "Ann Author"), to: url)
            let contents = try io.read(url)
            #expect(contents.metadata.title == "Routed")
            #expect(contents.metadata.authors == ["Ann Author"])
        }
    }

    @Test func reportsWhatEachFormatCannotHold() throws {
        let dir = try makeTempDir()
        let m4b = dir.appendingPathComponent("a.m4b")
        try MediaFixtures.makeAAC(at: m4b, seconds: 2)
        let epub = try MediaFixtures.makeEPUB3(in: dir)
        let pdf = dir.appendingPathComponent("a.pdf")
        MediaFixtures.makePDF(at: pdf, pages: 1)

        #expect(try io.write(tagged("T", author: "A B"), to: m4b).notWritten.isEmpty)
        #expect(try io.write(tagged("T", author: "A B"), to: epub).notWritten == EpubIO.unstorable)
        #expect(try io.write(tagged("T", author: "A B"), to: pdf).notWritten == PDFIO.unstorable)
    }

    @Test func mobiAndAzw3AreNeverOpened() throws {
        let dir = try makeTempDir()
        for name in ["a.mobi", "a.azw3"] {
            let url = try touch(dir.appendingPathComponent(name), "opaque bytes")

            #expect(try io.read(url) == FileContents())
            let report = try io.write(tagged("T", author: "A B"), to: url)
            #expect(report.notWritten == Set(MetadataField.allCases).subtracting([.cover]))

            let image = CoverImage(data: Data([1, 2, 3]), mime: "image/png")
            let withCover = try io.write(tagged("T", author: "A B"), cover: .set(image), to: url)
            #expect(withCover.notWritten == Set(MetadataField.allCases))

            #expect(try String(contentsOf: url, encoding: .utf8) == "opaque bytes")
        }
    }

    @Test func unsupportedExtensionsThrow() throws {
        let url = try touch(makeTempDir().appendingPathComponent("notes.txt"))
        #expect(throws: MetadataIOError.unsupportedFormat("txt")) { _ = try io.read(url) }
        #expect(throws: MetadataIOError.unsupportedFormat("txt")) {
            try io.write(tagged("T", author: "A B"), to: url)
        }
    }

    @Test func storableFieldsMatchTheModules() {
        let all = Set(MetadataField.allCases)
        #expect(FileMetadataIO.storableFields(for: .m4b) == all)
        #expect(FileMetadataIO.storableFields(for: .m4a) == all)
        #expect(FileMetadataIO.storableFields(for: .mp3) == all)
        #expect(FileMetadataIO.storableFields(for: .epub) == all.subtracting(EpubIO.unstorable))
        #expect(FileMetadataIO.storableFields(for: .pdf) == [.title, .authors])
        #expect(FileMetadataIO.storableFields(for: .mobi).isEmpty)
        #expect(FileMetadataIO.storableFields(for: .azw3).isEmpty)
    }

    @Test func scannerUsesRealTagsOverFileNames() throws {
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent("Wrong Author - Wrong Title.m4b")
        try MediaFixtures.makeAAC(at: file, seconds: 2)
        var real = BookMetadata(title: "Project Hail Mary", authors: ["Andy Weir"])
        real.narrators = ["Ray Porter"]
        try io.write(real, to: file)

        let candidate = try #require(BookScanner(reader: io).scan([file]).candidates.first)

        #expect(candidate.metadata.title == "Project Hail Mary")
        #expect(candidate.metadata.authors == ["Andy Weir"])
        #expect(candidate.metadata.narrators == ["Ray Porter"])
        #expect((candidate.metadata.durationSeconds ?? 0) > 1)
    }

    @Test func scannerTakesAMultiPartBooksTitleFromTheAlbumTag() throws {
        let book = try makeTempDir().appendingPathComponent("Some Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        for i in 1...2 {
            let part = book.appendingPathComponent("\(i).mp3")
            try MediaFixtures.makeSilentMP3(seconds: 2).write(to: part)
            try io.write(BookMetadata(title: "Dune", authors: ["Frank Herbert"]),
                         part: PartPosition(index: i, count: 2), to: part)
        }

        let candidate = try #require(BookScanner(reader: io).scan([book]).candidates.first)

        #expect(candidate.files.count == 2)
        #expect(candidate.metadata.title == "Dune")
        #expect(candidate.metadata.authors == ["Frank Herbert"])
    }
}
