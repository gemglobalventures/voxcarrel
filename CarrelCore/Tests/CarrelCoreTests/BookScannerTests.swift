import Foundation
import Testing
@testable import CarrelCore

/// Returns canned metadata keyed by file name; throws for everything else.
struct StubReader: MetadataReader {
    var byFileName: [String: BookMetadata] = [:]
    struct NoTags: Error {}
    func readMetadata(at url: URL) throws -> BookMetadata {
        guard let m = byFileName[url.lastPathComponent] else { throw NoTags() }
        return m
    }
}

extension CandidateBook {
    /// "name:role" for each file, for compact assertions.
    var summary: [String] {
        files.map { "\($0.url.lastPathComponent):\($0.role.rawValue)" }
    }
}

@Suite struct BookScannerTests {
    // MARK: Audio grouping

    @Test func folderOfMP3sIsOneBookInNaturalOrder() throws {
        let root = try makeTempDir()
        let book = root.appendingPathComponent("Frank Herbert/Dune", isDirectory: true)
        try touch(book.appendingPathComponent("10.mp3"))
        try touch(book.appendingPathComponent("2.mp3"))
        try touch(book.appendingPathComponent("1.mp3"))

        let result = BookScanner().scan([book])

        #expect(result.candidates.count == 1)
        let c = try #require(result.candidates.first)
        #expect(c.summary == ["1.mp3:audio", "2.mp3:audio", "10.mp3:audio"])
        #expect(c.hasAudio)
        #expect(c.sourceFolder?.lastPathComponent == "Dune")
        #expect(c.metadata.title == "Dune")
        #expect(c.metadata.authors == ["Frank Herbert"])
    }

    @Test func m4bFilesAreSeparateBooksEvenInOneFolder() throws {
        let root = try makeTempDir()
        try touch(root.appendingPathComponent("A - One.m4b"))
        try touch(root.appendingPathComponent("B - Two.m4b"))

        let result = BookScanner().scan([root])

        #expect(result.candidates.count == 2)
        #expect(Set(result.candidates.map(\.metadata.title)) == ["One", "Two"])
        #expect(result.candidates.allSatisfy { $0.files.count == 1 && $0.sourceFolder == nil })
    }

    @Test func mixedAudioFormatsAreNotGrouped() throws {
        let root = try makeTempDir()
        try touch(root.appendingPathComponent("a.mp3"))
        try touch(root.appendingPathComponent("b.m4a"))

        #expect(BookScanner().scan([root]).candidates.count == 2)
    }

    @Test func singleMP3IsASingleFileBook() throws {
        let root = try makeTempDir()
        try touch(root.appendingPathComponent("Author - Solo.mp3"))

        let c = try #require(BookScanner().scan([root]).candidates.first)
        #expect(c.files.count == 1)
        #expect(c.sourceFolder == nil)
        #expect(c.metadata.title == "Solo")
    }

    @Test func parentWithAudioSubfoldersDoesNotSwallowThem() throws {
        let root = try makeTempDir()
        let author = root.appendingPathComponent("Author", isDirectory: true)
        try touch(author.appendingPathComponent("Book One/1.mp3"))
        try touch(author.appendingPathComponent("Book One/2.mp3"))
        try touch(author.appendingPathComponent("Book Two/1.mp3"))
        try touch(author.appendingPathComponent("Book Two/2.mp3"))

        let result = BookScanner().scan([author])

        #expect(result.candidates.count == 2)
        #expect(Set(result.candidates.map(\.metadata.title)) == ["Book One", "Book Two"])
        #expect(result.candidates.allSatisfy { $0.metadata.authors == ["Author"] })
    }

    // MARK: One entry for audio, ebook and extras

    @Test func dedicatedFolderWithAudioEbookAndPDFIsOneBook() throws {
        let root = try makeTempDir()
        let book = root.appendingPathComponent("Project Hail Mary", isDirectory: true)
        try touch(book.appendingPathComponent("phm.m4b"))
        try touch(book.appendingPathComponent("Project Hail Mary.epub"))
        try touch(book.appendingPathComponent("Star Map.pdf"))

        let result = BookScanner().scan([book])

        #expect(result.candidates.count == 1)
        #expect(result.candidates[0].summary
            == ["phm.m4b:audio", "Project Hail Mary.epub:ebook", "Star Map.pdf:extra"])
    }

    @Test func multiPartAudiobookFolderKeepsItsEbookAndExtras() throws {
        let root = try makeTempDir()
        let book = root.appendingPathComponent("Frank Herbert/Dune", isDirectory: true)
        try touch(book.appendingPathComponent("1.mp3"))
        try touch(book.appendingPathComponent("2.mp3"))
        try touch(book.appendingPathComponent("Dune.epub"))
        try touch(book.appendingPathComponent("Maps.pdf"))

        let result = BookScanner().scan([book])

        #expect(result.candidates.count == 1)
        let c = result.candidates[0]
        #expect(c.summary == ["1.mp3:audio", "2.mp3:audio", "Dune.epub:ebook", "Maps.pdf:extra"])
        #expect(c.sourceFolder?.lastPathComponent == "Dune")
        #expect(c.metadata.title == "Dune")
    }

    @Test func filesNamedLikeAnAudiobookJoinItEvenAmongOtherBooks() throws {
        let root = try makeTempDir()
        try touch(root.appendingPathComponent("A - One.m4b"))
        try touch(root.appendingPathComponent("A - One.epub"))
        try touch(root.appendingPathComponent("A - One.pdf"))
        try touch(root.appendingPathComponent("B - Two.m4b"))

        let result = BookScanner().scan([root])

        #expect(result.candidates.count == 2)
        let one = try #require(result.candidates.first { $0.metadata.title == "One" })
        #expect(Set(one.summary) == ["A - One.m4b:audio", "A - One.epub:ebook", "A - One.pdf:extra"])
    }

    @Test func ebookWithAppendixPDFInItsOwnFolderIsOneBook() throws {
        let root = try makeTempDir()
        let book = root.appendingPathComponent("Some Book", isDirectory: true)
        try touch(book.appendingPathComponent("Some Book.epub"))
        try touch(book.appendingPathComponent("Appendix.pdf"))

        let result = BookScanner().scan([book])

        #expect(result.candidates.count == 1)
        #expect(Set(result.candidates[0].summary) == ["Some Book.epub:ebook", "Appendix.pdf:extra"])
        #expect(result.candidates[0].hasAudio == false)
    }

    @Test func genericFoldersDoNotAttachUnrelatedPDFs() throws {
        let root = try makeTempDir()
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try touch(downloads.appendingPathComponent("X - Audio.m4b"))
        try touch(downloads.appendingPathComponent("washing machine manual.pdf"))

        let result = BookScanner().scan([downloads])

        #expect(result.candidates.count == 2)
        #expect(result.candidates.allSatisfy { $0.files.count == 1 })
    }

    @Test func twoUnrelatedPDFsAreTwoBooks() throws {
        let root = try makeTempDir()
        let folder = root.appendingPathComponent("Papers", isDirectory: true)
        try touch(folder.appendingPathComponent("a.pdf"))
        try touch(folder.appendingPathComponent("b.pdf"))

        let result = BookScanner().scan([folder])

        #expect(result.candidates.count == 2)
        #expect(result.candidates.allSatisfy { $0.summary.first?.hasSuffix(":ebook") == true })
    }

    @Test func ebookFormatsWithSameBaseNameAreOneBook() throws {
        let root = try makeTempDir()
        try touch(root.appendingPathComponent("Piranesi.epub"))
        try touch(root.appendingPathComponent("Piranesi.pdf"))
        try touch(root.appendingPathComponent("Circe.epub"))

        let result = BookScanner().scan([root])

        #expect(result.candidates.count == 2)
        let piranesi = try #require(result.candidates.first { $0.metadata.title == "Piranesi" })
        #expect(Set(piranesi.summary) == ["Piranesi.epub:ebook", "Piranesi.pdf:ebook"])
    }

    @Test func audiobookAndEbookInDifferentFoldersMergeByTitleAndAuthor() throws {
        let root = try makeTempDir()
        try touch(root.appendingPathComponent("listen/Frank Herbert - Dune.m4b"))
        try touch(root.appendingPathComponent("read/frank herbert - DUNE.epub"))
        try touch(root.appendingPathComponent("read/Frank Herbert - Children of Dune.epub"))

        let result = BookScanner().scan([root])

        #expect(result.candidates.count == 2)
        let dune = try #require(result.candidates.first { $0.hasAudio })
        #expect(dune.summary == ["Frank Herbert - Dune.m4b:audio", "frank herbert - DUNE.epub:ebook"])
        #expect(dune.metadata.title == "Dune")
    }

    // MARK: Skipping, loose files, tags

    @Test func unsupportedFilesAreSkippedAndHiddenFilesIgnored() throws {
        let root = try makeTempDir()
        try touch(root.appendingPathComponent("Dune.epub"))
        try touch(root.appendingPathComponent("cover.jpg"))
        try touch(root.appendingPathComponent(".DS_Store"))

        let result = BookScanner().scan([root])

        #expect(result.candidates.count == 1)
        #expect(result.skipped.map(\.lastPathComponent) == ["cover.jpg"])
    }

    @Test func looseFilesDroppedDirectlyAreScanned() throws {
        let root = try makeTempDir()
        let a = try touch(root.appendingPathComponent("X - A.m4b"))
        let b = try touch(root.appendingPathComponent("notes.txt"))
        let c = try touch(root.appendingPathComponent("unrelated.pdf"))

        let result = BookScanner().scan([a, b, c])

        #expect(result.candidates.count == 2)  // loose files never become extras
        #expect(result.skipped == [b])
    }

    @Test func tagsWinOverFilenameGuessesAndGapsAreFilled() throws {
        let root = try makeTempDir()
        let file = try touch(root.appendingPathComponent("Wrong Author - Wrong Title.m4b"))
        var tagged = BookMetadata(title: "Project Hail Mary")
        tagged.narrators = ["Ray Porter"]
        let reader = StubReader(byFileName: [file.lastPathComponent: tagged])

        let c = try #require(BookScanner(reader: reader).scan([file]).candidates.first)

        #expect(c.metadata.title == "Project Hail Mary")
        #expect(c.metadata.narrators == ["Ray Porter"])
        #expect(c.metadata.authors == ["Wrong Author"])  // gap filled from the name
    }
}
