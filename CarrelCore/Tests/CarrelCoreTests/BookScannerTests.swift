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
        try touch(root.appendingPathComponent("c.mp3"))

        let result = BookScanner().scan([root])

        #expect(result.candidates.count == 3)
        #expect(result.candidates.map(\.summary)
            == [["a.mp3:audio"], ["b.m4a:audio"], ["c.mp3:audio"]])
        #expect(result.candidates.allSatisfy { $0.sourceFolder == nil })
        #expect(result.candidates.map(\.metadata.title) == ["a", "b", "c"])
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

    // MARK: Review fixes: grouping

    @Test func folderOfM4AsIsOneBook() throws {
        let root = try makeTempDir()
        let book = root.appendingPathComponent("Author/Book", isDirectory: true)
        try touch(book.appendingPathComponent("2.m4a"))
        try touch(book.appendingPathComponent("1.M4A"))

        let result = BookScanner().scan([book])

        #expect(result.candidates.map(\.summary) == [["1.M4A:audio", "2.m4a:audio"]])
        #expect(result.candidates.first?.sourceFolder?.lastPathComponent == "Book")
    }

    @Test func baseNamesMatchIgnoringCase() throws {
        let root = try makeTempDir()
        try touch(root.appendingPathComponent("DUNE.M4B"))
        try touch(root.appendingPathComponent("dune.Epub"))
        try touch(root.appendingPathComponent("Circe.EPUB"))
        try touch(root.appendingPathComponent("circe.pdf"))
        try touch(root.appendingPathComponent("Other.m4b"))

        let result = BookScanner().scan([root])

        #expect(Set(result.candidates.map(\.summary)) == [
            ["DUNE.M4B:audio", "dune.Epub:ebook"],
            ["Circe.EPUB:ebook", "circe.pdf:ebook"],
            ["Other.m4b:audio"],
        ])
    }

    @Test func dedicatedFolderDoesNotAttachASecondEbookToTheAudiobook() throws {
        let root = try makeTempDir()
        let book = root.appendingPathComponent("Frank Herbert/Dune", isDirectory: true)
        try touch(book.appendingPathComponent("Dune.m4b"))
        try touch(book.appendingPathComponent("Dune.epub"))
        try touch(book.appendingPathComponent("Messiah.epub"))

        let result = BookScanner().scan([book])

        #expect(Set(result.candidates.map(\.summary))
            == [["Dune.m4b:audio", "Dune.epub:ebook"], ["Messiah.epub:ebook"]])
    }

    @Test func pdfInAFolderWhoseSubfoldersHoldBooksIsItsOwnEbook() throws {
        let root = try makeTempDir()
        let author = root.appendingPathComponent("Author", isDirectory: true)
        try touch(author.appendingPathComponent("Series/Book.epub"))
        try touch(author.appendingPathComponent("Solo.m4b"))
        try touch(author.appendingPathComponent("notes.pdf"))

        let result = BookScanner().scan([author])

        #expect(Set(result.candidates.map(\.summary))
            == [["Book.epub:ebook"], ["Solo.m4b:audio"], ["notes.pdf:ebook"]])
    }

    @Test func genericFolderOfAudioFilesIsNotOneBook() throws {
        let root = try makeTempDir()
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try touch(downloads.appendingPathComponent("x.mp3"))
        try touch(downloads.appendingPathComponent("y.mp3"))

        let result = BookScanner().scan([downloads])

        #expect(result.candidates.map(\.summary) == [["x.mp3:audio"], ["y.mp3:audio"]])
        #expect(result.candidates.allSatisfy { $0.sourceFolder == nil })
    }

    @Test func filesAreOrderedAudioThenEbookThenExtra() throws {
        let root = try makeTempDir()
        let book = root.appendingPathComponent("Author/Dune", isDirectory: true)
        try touch(book.appendingPathComponent("Dune.m4b"))
        try touch(book.appendingPathComponent("Dune.pdf"))  // extra, joined by name first
        try touch(book.appendingPathComponent("The Text.epub"))  // ebook, joined by folder after

        let inFolder = BookScanner().scan([book])
        #expect(inFolder.candidates.map(\.summary)
            == [["Dune.m4b:audio", "The Text.epub:ebook", "Dune.pdf:extra"]])

        let other = try makeTempDir()
        try touch(other.appendingPathComponent("a/H - Dune.m4b"))
        try touch(other.appendingPathComponent("a/H - Dune.pdf"))
        try touch(other.appendingPathComponent("b/H - Dune.epub"))

        let acrossFolders = BookScanner().scan([other])
        #expect(acrossFolders.candidates.map(\.summary)
            == [["H - Dune.m4b:audio", "H - Dune.epub:ebook", "H - Dune.pdf:extra"]])
    }

    // MARK: Review fixes: merging across folders

    @Test func audiobookMergesWithItsOnlyMatchWhicheverIsScannedFirst() throws {
        for (audioFolder, ebookFolder) in [("a", "z"), ("z", "a")] {
            let root = try makeTempDir()
            try touch(root.appendingPathComponent("\(audioFolder)/H - Dune.m4b"))
            try touch(root.appendingPathComponent("\(ebookFolder)/H - Dune.epub"))

            let result = BookScanner().scan([root])

            #expect(result.candidates.map(\.summary)
                == [["H - Dune.m4b:audio", "H - Dune.epub:ebook"]])
        }
    }

    @Test func audiobookWithSeveralMatchesIsLeftForTheUserWhicheverIsScannedFirst() throws {
        for folders in [["a", "b", "c"], ["c", "a", "b"], ["b", "c", "a"]] {
            let root = try makeTempDir()
            try touch(root.appendingPathComponent("\(folders[0])/H - Dune.m4b"))
            try touch(root.appendingPathComponent("\(folders[1])/H - Dune.epub"))
            try touch(root.appendingPathComponent("\(folders[2])/H - Dune.pdf"))

            let result = BookScanner().scan([root])

            #expect(Set(result.candidates.map(\.summary))
                == [["H - Dune.m4b:audio"], ["H - Dune.epub:ebook"], ["H - Dune.pdf:ebook"]])
        }
    }

    @Test func audiobookThatAlreadyHasAnEbookDoesNotTakeAnother() throws {
        for (pairFolder, loneFolder) in [("a", "z"), ("z", "a")] {
            let root = try makeTempDir()
            try touch(root.appendingPathComponent("\(pairFolder)/H - Dune.m4b"))
            try touch(root.appendingPathComponent("\(pairFolder)/H - Dune.epub"))
            try touch(root.appendingPathComponent("\(loneFolder)/H - Dune.epub"))

            let result = BookScanner().scan([root])

            #expect(Set(result.candidates.map(\.summary))
                == [["H - Dune.m4b:audio", "H - Dune.epub:ebook"], ["H - Dune.epub:ebook"]])
        }
    }

    // MARK: Review fixes: odd inputs

    @Test func packagesAndFoldersNamedLikeBooksAreSkippedWhole() throws {
        let root = try makeTempDir()
        let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
        try touch(shelf.appendingPathComponent("Unzipped.epub/mimetype"))
        try touch(shelf.appendingPathComponent("Unzipped.epub/OEBPS/fig.pdf"))
        try touch(shelf.appendingPathComponent("Thing.app/Contents/Resources/manual.pdf"))
        try touch(shelf.appendingPathComponent("Real.epub"))

        let result = BookScanner().scan([shelf])

        #expect(result.candidates.map(\.summary) == [["Real.epub:ebook"]])
        #expect(result.skipped.map(\.lastPathComponent).sorted() == ["Thing.app", "Unzipped.epub"])

        let dropped = BookScanner().scan([shelf.appendingPathComponent("Unzipped.epub")])
        #expect(dropped.candidates.isEmpty)
        #expect(dropped.skipped.map(\.lastPathComponent) == ["Unzipped.epub"])
    }

    @Test func overlappingInputsYieldEachFileOnce() throws {
        let root = try makeTempDir()
        let folder = root.appendingPathComponent("Shelf/X", isDirectory: true)
        let file = try touch(folder.appendingPathComponent("A - B.m4b"))
        let note = try touch(folder.appendingPathComponent("note.txt"))
        let shelf = root.appendingPathComponent("Shelf", isDirectory: true)

        // Inputs that overlap, and how many unsupported files each should report.
        let cases: [(inputs: [URL], skipped: Int)] = [
            ([folder, file], 1), ([file, folder], 1), ([file, file], 0),
            ([shelf, folder, note], 1), ([folder, shelf], 1), ([note, note], 1),
        ]
        for (inputs, skipped) in cases {
            let result = BookScanner().scan(inputs)
            #expect(result.candidates.map(\.summary) == (skipped == 1 && inputs == [note, note]
                ? [] : [["A - B.m4b:audio"]]))
            #expect(result.skipped.count == skipped)
        }
    }

    @Test func looseFilesAreGroupedOnlyWithFilesFromTheSameFolder() throws {
        let root = try makeTempDir()
        let a = try touch(root.appendingPathComponent("a/Dune.epub"))
        let b = try touch(root.appendingPathComponent("b/Dune.epub"))
        let audio = try touch(root.appendingPathComponent("b/Dune.m4b"))
        let pdf = try touch(root.appendingPathComponent("a/Dune.pdf"))

        let result = BookScanner().scan([a, b, audio, pdf])

        #expect(Set(result.candidates.map(\.summary))
            == [["Dune.epub:ebook", "Dune.pdf:ebook"], ["Dune.m4b:audio", "Dune.epub:ebook"]])
    }

    @Test func symlinksAndMissingPathsAreSkipped() throws {
        let root = try makeTempDir()
        let real = try touch(root.appendingPathComponent("real/Z - Real.m4b"))
        let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        let fileLink = shelf.appendingPathComponent("Z - Link.m4b")
        let folderLink = shelf.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: real)
        try FileManager.default.createSymbolicLink(
            at: folderLink, withDestinationURL: root.appendingPathComponent("real"))
        let ghost = root.appendingPathComponent("ghost.m4b")
        let droppedLink = root.appendingPathComponent("dropped.epub")
        try FileManager.default.createSymbolicLink(at: droppedLink, withDestinationURL: real)

        let result = BookScanner().scan([shelf, ghost, droppedLink])

        #expect(result.candidates.isEmpty)
        #expect(result.skipped.map(\.lastPathComponent).sorted()
            == ["Z - Link.m4b", "dropped.epub", "ghost.m4b", "linked"])
    }

    @Test func unreadableFolderIsSkipped() throws {
        let root = try makeTempDir()
        let locked = root.appendingPathComponent("Shelf/Locked", isDirectory: true)
        try touch(locked.appendingPathComponent("Hidden.epub"))
        try touch(root.appendingPathComponent("Shelf/Seen.epub"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }

        let result = BookScanner().scan([root.appendingPathComponent("Shelf")])

        #expect(result.candidates.map(\.summary) == [["Seen.epub:ebook"]])
        #expect(result.skipped.map(\.lastPathComponent) == ["Locked"])
    }

    // MARK: Review fixes: author guesses

    @Test func authorComesFromAboveTheBookFolder() throws {
        let root = try makeTempDir()
        try touch(root.appendingPathComponent("Frank Herbert/Dune/Dune.m4b"))
        try touch(root.appendingPathComponent("Andy Weir/Project Hail Mary/phm.m4b"))
        try touch(root.appendingPathComponent("Andy Weir/Project Hail Mary/Project Hail Mary.epub"))
        try touch(root.appendingPathComponent("Susanna Clarke/Piranesi/Piranesi book.epub"))
        try touch(root.appendingPathComponent("Susanna Clarke/Piranesi/Map.pdf"))
        try touch(root.appendingPathComponent("Madeline Miller/Circe.epub"))
        try touch(root.appendingPathComponent("Madeline Miller/Circe.pdf"))

        let result = BookScanner().scan([root])

        let authors = Dictionary(
            uniqueKeysWithValues: result.candidates.map { ($0.files[0].url.lastPathComponent, $0.metadata.authors) })
        #expect(authors == [
            "Dune.m4b": ["Frank Herbert"],
            "phm.m4b": ["Andy Weir"],
            "Piranesi book.epub": ["Susanna Clarke"],
            "Circe.epub": ["Madeline Miller"],
        ])
    }
}

