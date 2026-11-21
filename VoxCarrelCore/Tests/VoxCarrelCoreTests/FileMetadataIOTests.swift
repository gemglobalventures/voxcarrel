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

    // MARK: Files that must not be written

    @Test func writingThroughASymlinkIsRefusedForEveryFormat() throws {
        let dir = try makeTempDir()
        let store = dir.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let mp3 = store.appendingPathComponent("a.mp3")
        try MediaFixtures.makeSilentMP3(seconds: 2).write(to: mp3)
        let m4b = store.appendingPathComponent("a.m4b")
        try MediaFixtures.makeAAC(at: m4b, seconds: 2)
        let epub = try MediaFixtures.makeEPUB3(in: store, name: "a.epub")
        let pdf = store.appendingPathComponent("a.pdf")
        MediaFixtures.makePDF(at: pdf)

        for real in [mp3, m4b, epub, pdf] {
            let name = real.lastPathComponent
            let link = dir.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "store/" + name)
            let bytes = try Data(contentsOf: real)
            #expect(throws: MetadataIOError.notARegularFile(name), "\(name)") {
                try io.write(BookMetadata(title: "Changed", authors: ["Someone New"]), to: link)
            }
            #expect(try Data(contentsOf: real) == bytes, "\(name)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.path).sorted() == ["a.epub", "a.m4b", "a.mp3", "a.pdf"])
    }

    @Test func readOnlyAndFinderLockedFilesAreLockedForEveryFormat() throws {
        let dir = try makeTempDir()
        let mp3 = dir.appendingPathComponent("a.mp3")
        try MediaFixtures.makeSilentMP3(seconds: 2).write(to: mp3)
        let epub = try MediaFixtures.makeEPUB3(in: dir, name: "a.epub")
        let pdf = dir.appendingPathComponent("a.pdf")
        MediaFixtures.makePDF(at: pdf)

        for url in [mp3, epub, pdf] {
            let name = url.lastPathComponent
            let bytes = try Data(contentsOf: url)
            let metadata = BookMetadata(title: "Changed", authors: ["Someone New"])

            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
            #expect(throws: MetadataIOError.locked(name), "read-only \(name)") { try io.write(metadata, to: url) }
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

            #expect(chflags(url.path, UInt32(UF_IMMUTABLE)) == 0)
            #expect(throws: MetadataIOError.locked(name), "Finder-locked \(name)") { try io.write(metadata, to: url) }
            #expect(chflags(url.path, 0) == 0)

            #expect(try Data(contentsOf: url) == bytes, "\(name)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["a.epub", "a.mp3", "a.pdf"])
    }

    @Test func trackTagsAreReadAndRestoredForAudioOnly() throws {
        let dir = try makeTempDir()
        let m4b = dir.appendingPathComponent("a.m4b")
        try MediaFixtures.makeAAC(at: m4b, seconds: 2)
        let epub = try MediaFixtures.makeEPUB3(in: dir)
        let pdf = dir.appendingPathComponent("a.pdf")
        MediaFixtures.makePDF(at: pdf, pages: 1)
        let mobi = try touch(dir.appendingPathComponent("a.mobi"), "opaque bytes")

        // Audio: read through to the tags, and restored on write.
        try io.write(tagged("Album", author: "A B"), part: PartPosition(index: 1, count: 2), to: m4b)
        #expect(try io.readTrackTags(at: m4b) == TrackTags(title: nil, number: "1/2"))
        try io.write(
            tagged("Album", author: "A B"), restoringTrack: TrackTags(title: "Own Name", number: nil), to: m4b)
        #expect(try io.readTrackTags(at: m4b) == TrackTags(title: "Own Name", number: nil))
        #expect(try io.read(m4b).metadata.title == "Album")

        // Everything else has no track tags, and ignores a restore.
        let track = TrackTags(title: "Ignored", number: "1/2")
        for url in [epub, pdf, mobi] {
            #expect(try io.readTrackTags(at: url) == nil)
            try io.write(tagged("Routed", author: "Ann Author"), restoringTrack: track, to: url)
        }
        #expect(try io.read(epub).metadata.title == "Routed")
        #expect(try io.read(pdf).metadata.title == "Routed")
        #expect(try String(contentsOf: mobi, encoding: .utf8) == "opaque bytes")
        #expect(throws: MetadataIOError.unsupportedFormat("txt")) {
            try io.readTrackTags(at: dir.appendingPathComponent("a.txt"))
        }
    }
}
