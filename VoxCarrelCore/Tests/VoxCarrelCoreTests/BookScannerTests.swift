import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

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

    // The ebook and the PDF are one book's forms (same title, same author), so the
    // audiobook has one match and takes both.
    @Test func audiobookWithItsEbookInTwoFormsIsOneBookWhicheverIsScannedFirst() throws {
        for folders in [["a", "b", "c"], ["c", "a", "b"], ["b", "c", "a"]] {
            let root = try makeTempDir()
            try touch(root.appendingPathComponent("\(folders[0])/H - Dune.m4b"))
            try touch(root.appendingPathComponent("\(folders[1])/H - Dune.epub"))
            try touch(root.appendingPathComponent("\(folders[2])/H - Dune.pdf"))

            let result = BookScanner().scan([root])

            #expect(result.candidates.count == 1)
            #expect(Set(result.candidates.first?.summary ?? [])
                == ["H - Dune.m4b:audio", "H - Dune.epub:ebook", "H - Dune.pdf:ebook"])
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

    // MARK: Guessing from names (Plan 14)

    private func knowing(authors: [String] = [], titles: [String] = []) -> KnownNames {
        KnownNames(
            authors: Set(authors.map(KnownNames.authorKey)), titles: Set(titles.map(KnownNames.titleKey)))
    }

    /// The one candidate of a file scanned with these tags (none when nil).
    private func scanned(
        _ name: String, tags: BookMetadata? = nil, known: KnownNames = .none, in folder: String = "Downloads"
    ) throws -> CandidateBook {
        let root = try makeTempDir()
        let file = try touch(root.appendingPathComponent("\(folder)/\(name)"))
        let reader = StubReader(byFileName: tags.map { [name: $0] } ?? [:])
        let result = BookScanner(reader: reader, known: known).scan([file])
        #expect(result.candidates.count == 1)
        return try #require(result.candidates.first)
    }

    // IM10: with a title and an author in the tags, the name is not read for them at all.
    @Test func IM10_tagsAreNeverReplacedByAGuess() throws {
        var tagged = BookMetadata(title: "Real Title", authors: ["Real Author"])
        tagged.asin = "B0TAGGED01"
        let c = try scanned(
            "Dune - Frank Herbert [B002V1OF70].m4b", tags: tagged,
            known: knowing(authors: ["Frank Herbert"], titles: ["Dune"]))
        #expect(c.metadata == tagged)
        #expect(c.guessNotes == [])
    }

    // IM10, IM11: only the field the tags leave empty is guessed.
    @Test func IM10_onlyTheGapIsGuessed() throws {
        let titled = try scanned("Catch-22 - Joseph Heller.m4b", tags: BookMetadata(title: "Real Title"))
        #expect(titled.metadata.title == "Real Title")
        #expect(titled.metadata.authors == ["Joseph Heller"])
        #expect(titled.guessNotes == [.fromFileName, .orderSwapped, .orderGuessedByShape])

        let authored = try scanned(
            "Mick Herron - Slow Horses.m4b", tags: BookMetadata(title: "", authors: ["Real Author"]))
        #expect(authored.metadata.title == "Slow Horses")
        #expect(authored.metadata.authors == ["Real Author"])
        #expect(authored.guessNotes == [.fromFileName, .orderUnsure])

        // A title that looks like a person is only a worry when there is no author.
        let person = try scanned("Mick Herron.epub", tags: BookMetadata(title: "", authors: ["Real Author"]))
        #expect(person.metadata.title == "Mick Herron")
        #expect(person.guessNotes == [.fromFileName])
        let untagged = try scanned("Mick Herron.epub")
        #expect(untagged.metadata.title == "Mick Herron")
        #expect(untagged.metadata.authors == [])
        #expect(untagged.guessNotes == [.fromFileName, .titleLooksLikePerson])
    }

    // IM10, IM11: what the tags do say is evidence for reading the name.
    @Test func IM11_theTagsSayWhichSideIsWhich() throws {
        let byAuthor = try scanned(
            "Slow Horses - Mick Herron.m4b", tags: BookMetadata(title: "", authors: ["mick herron", "Other"]))
        #expect(byAuthor.metadata.title == "Slow Horses")
        #expect(byAuthor.metadata.authors == ["mick herron", "Other"])
        #expect(byAuthor.guessNotes == [.fromFileName, .orderSwapped])

        let byTitle = try scanned("Slow Horses - Mick Herron.m4b", tags: BookMetadata(title: "Slow Horses (Unabridged)"))
        #expect(byTitle.metadata.title == "Slow Horses (Unabridged)")
        #expect(byTitle.metadata.authors == ["Mick Herron"])
        #expect(byTitle.guessNotes == [.fromFileName, .orderSwapped])
    }

    // IM10, IM11: an author in the tags is not also made the title when the title is a number.
    @Test func IM11_aNumberIsTheTitleBesideTheAuthorTheTagsGive() throws {
        let book = try scanned("1984 - George Orwell.m4b", tags: BookMetadata(title: "", authors: ["George Orwell"]))
        #expect(book.metadata.title == "1984")
        #expect(book.metadata.authors == ["George Orwell"])
        #expect(book.guessNotes == [.fromFileName, .orderSwapped])
    }

    // IM11: the scanner reads names with what the library knows.
    @Test func IM11_theScannerUsesTheKnownNames() throws {
        let unknown = try scanned("Slow Horses - Mick Herron.epub")
        #expect(unknown.metadata.title == "Mick Herron")
        #expect(unknown.metadata.authors == ["Slow Horses"])
        #expect(unknown.guessNotes == [.fromFileName, .orderUnsure])

        let known = try scanned("Slow Horses - Mick Herron.epub", known: knowing(authors: ["Mick Herron"]))
        #expect(known.metadata.title == "Slow Horses")
        #expect(known.metadata.authors == ["Mick Herron"])
        #expect(known.guessNotes == [.fromFileName, .orderSwapped])

        // A folder of parts is read the same way.
        let root = try makeTempDir()
        let book = root.appendingPathComponent("Slow Horses - Mick Herron", isDirectory: true)
        try touch(book.appendingPathComponent("1.mp3"))
        try touch(book.appendingPathComponent("2.mp3"))
        let parts = try #require(
            BookScanner(known: knowing(authors: ["Mick Herron"])).scan([book]).candidates.first)
        #expect(parts.metadata.title == "Slow Horses")
        #expect(parts.metadata.authors == ["Mick Herron"])
        #expect(parts.guessNotes == [.fromFileName, .orderSwapped])
    }

    // IM13
    @Test func IM13_anAudibleIDFromTheNameFillsOnlyAGap() throws {
        let untagged = try scanned("Dune [B002V1OF70].m4b")
        #expect(untagged.metadata.asin == "B002V1OF70")
        #expect(untagged.metadata.title == "Dune")
        #expect(untagged.guessNotes == [.fromFileName, .audibleIDFromName])

        // Tags with a title and an author but no ID: only the ID is read from the name.
        for blank in [nil, "", "  "] {
            var tagged = BookMetadata(title: "Real Title", authors: ["Real Author"])
            tagged.asin = blank
            let c = try scanned("Dune [B002V1OF70].m4b", tags: tagged)
            #expect(c.metadata.asin == "B002V1OF70")
            #expect(c.metadata.title == "Real Title")
            #expect(c.metadata.authors == ["Real Author"])
            #expect(c.guessNotes == [.audibleIDFromName])
        }

        // The tags' own ID is never overridden.
        var tagged = BookMetadata(title: "")
        tagged.asin = "B0TAGGED01"
        let own = try scanned("Dune [B002V1OF70].m4b", tags: tagged)
        #expect(own.metadata.asin == "B0TAGGED01")
        #expect(own.metadata.title == "Dune")
        #expect(own.guessNotes == [.fromFileName])
    }

    // IM13: a folder of parts named with the ID.
    @Test func IM13_anAudibleIDInAFolderOfParts() throws {
        let root = try makeTempDir()
        let book = root.appendingPathComponent("Frank Herbert/Dune [B002V1OF70]", isDirectory: true)
        try touch(book.appendingPathComponent("1.mp3"))
        try touch(book.appendingPathComponent("2.mp3"))

        let c = try #require(BookScanner().scan([book]).candidates.first)

        #expect(c.metadata.asin == "B002V1OF70")
        #expect(c.metadata.title == "Dune")
        #expect(c.metadata.authors == ["Frank Herbert"])
        #expect(c.guessNotes == [.fromFileName, .audibleIDFromName])
    }

    // IM15: the same Audible ID joins an audiobook and a companion, whatever they are called.
    @Test func IM15_candidatesWithTheSameAudibleIDAreOneBook() throws {
        let root = try makeTempDir()
        let audio = try touch(root.appendingPathComponent("a/Frank Herbert - Dune [B002V1OF70].m4b"))
        let pdf = try touch(root.appendingPathComponent("b/Maps and Glossary [B002V1OF70].pdf"))
        try touch(root.appendingPathComponent("b/Emma [B09WXN61GL].pdf"))

        let result = BookScanner().scan([root])

        #expect(Set(result.candidates.map(\.summary)) == [
            [audio.lastPathComponent + ":audio", pdf.lastPathComponent + ":ebook"], ["Emma [B09WXN61GL].pdf:ebook"],
        ])
        let joined = try #require(result.candidates.first { $0.hasAudio })
        #expect(joined.metadata.title == "Dune")
        #expect(joined.metadata.asin == "B002V1OF70")
    }

    // IM15: only an unambiguous pair is joined, as before.
    @Test func IM15_twoCompanionsWithTheSameAudibleIDAreLeftForTheReview() throws {
        let root = try makeTempDir()
        try touch(root.appendingPathComponent("a/Dune [B002V1OF70].m4b"))
        try touch(root.appendingPathComponent("b/Maps [B002V1OF70].pdf"))
        try touch(root.appendingPathComponent("c/Glossary [B002V1OF70].pdf"))

        #expect(BookScanner().scan([root]).candidates.count == 3)
    }

    // IM15: the same first author and the same title, edition words aside.
    @Test func IM15_editionWordsDoNotKeepABookApart() throws {
        let root = try makeTempDir()
        try touch(root.appendingPathComponent("a/audio.m4b"))
        try touch(root.appendingPathComponent("b/Frank Herbert - the DUNE.epub"))
        let tagged = BookMetadata(title: "Dune (Unabridged)", authors: ["Frank  Herbert"])

        let result = BookScanner(reader: StubReader(byFileName: ["audio.m4b": tagged])).scan([root])

        #expect(result.candidates.map(\.summary) == [["audio.m4b:audio", "Frank Herbert - the DUNE.epub:ebook"]])
        #expect(result.candidates.first?.metadata == tagged)
    }

    // IM15: never on a title that is the other up to a subtitle, nor for another author.
    @Test func IM15_aSubtitleOrAnotherAuthorKeepsBooksApart() throws {
        let root = try makeTempDir()
        try touch(root.appendingPathComponent("a/audio.m4b"))
        try touch(root.appendingPathComponent("b/Frank Herbert - Dune_ Messiah.epub"))
        try touch(root.appendingPathComponent("c/Brian Herbert - Dune.epub"))
        let tagged = BookMetadata(title: "Dune", authors: ["Frank Herbert"])

        let result = BookScanner(reader: StubReader(byFileName: ["audio.m4b": tagged])).scan([root])

        #expect(result.candidates.count == 3)
        #expect(result.candidates.allSatisfy { $0.files.count == 1 })
    }
}
