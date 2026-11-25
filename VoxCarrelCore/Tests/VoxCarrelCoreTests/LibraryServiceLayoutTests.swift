import Foundation
import GRDB
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// The library files by its own folder pattern (folder layout plan, Task 2). FP20–FP24.
@Suite struct LibraryServiceLayoutTests {
    typealias F = LibraryFixture

    static let kindPattern = "{Kind}/{Author}/{Title}"

    /// A library whose pattern is set straight in the store.
    private func library(_ pattern: String) throws -> F {
        let f = try F()
        try f.store.setFolderPatternText(pattern)
        return f
    }

    private func book(_ f: F, _ id: Int64) throws -> Book {
        try #require(try f.store.book(id: id))
    }

    private func paths(_ f: F, _ id: Int64) throws -> [String] {
        try f.store.files(bookId: id).map(\.path)
    }

    private func importInto(_ f: F, _ id: Int64, _ urls: [URL], mode: TransferMode = .move) throws -> ImportOutcome {
        let item = ImportItem(candidate: f.candidate(urls, BookMetadata()), target: .existing(bookId: id))
        return try #require(try f.service.importItems([item], options: ImportOptions(mode: mode)).outcomes.first)
    }

    // MARK: The pattern a library has

    @Test func fp20_aNewLibraryHasTheStandardPattern() throws {
        let f = try F()
        #expect(try f.store.folderPatternText() == nil)
        #expect(try f.service.folderPattern() == .standard)
    }

    @Test func fp20_theLibrarysPatternIsTheOneStored() throws {
        let f = try library(Self.kindPattern)
        #expect(try f.service.folderPattern() == FolderPattern(Self.kindPattern))
        // It is kept in the catalogue: the library opened again files the same way.
        let again = LibraryService(store: try LibraryStore(libraryRoot: f.root))
        #expect(try again.folderPattern().text == Self.kindPattern)
        try f.store.setFolderPatternText(nil)
        #expect(try f.service.folderPattern() == .standard)
    }

    @Test func aStoredPatternThatNoLongerParsesReadsAsTheStandardOne() throws {
        for broken in ["{Auther}/{Title}", "", "{Author}/[{Title}", "{Author}"] {
            let f = try library(broken)
            #expect(try f.service.folderPattern() == .standard)
            // And the library files by the standard pattern, without throwing.
            let id = try f.importNew([try f.makeM4B("a.m4b", tags: BookMetadata())], F.meta("Artemis", "Andy Weir"))
            #expect(try book(f, id).folderPath == "Andy Weir/Artemis")
        }
    }

    @Test func pathBuilderFilesByThePatternItIsGiven() throws {
        var m = F.meta("Dune", "Frank Herbert")
        m.series = "Dune Saga"
        m.seriesNumber = "1"
        let audio = FolderPatternValues(metadata: m, hasAudio: true)
        #expect(PathBuilder.bookFolder(values: audio, pattern: .standard) == "Frank Herbert/Dune Saga/1 - Dune")
        #expect(PathBuilder.bookFolder(values: audio, pattern: try FolderPattern(Self.kindPattern))
            == "Audiobooks/Frank Herbert/Dune")
        #expect(PathBuilder.bookFolder(
            values: FolderPatternValues(metadata: BookMetadata(title: "Dune"), hasAudio: true), pattern: .standard) == nil)
    }

    @Test func aPatternSaysEveryTokenItUses() throws {
        #expect(FolderPattern.standard.usedTokens == [.author, .series, .number, .title])
        #expect(try FolderPattern("{Series}/[{Year} ]{Title}|{Kind}/{Title}").usedTokens == [.series, .year, .title, .kind])
    }

    // MARK: FP20 Import

    @Test func fp20_importFilesANewBookByTheLibrarysPattern() throws {
        let f = try library(Self.kindPattern)
        var meta = F.meta("Artemis", "Andy Weir")
        meta.series = "Not Used"
        meta.seriesNumber = "4"
        let audio = try f.importNew([try f.makeM4B("a.m4b", tags: BookMetadata())], meta)
        let ebook = try f.importNew([try f.makeEPUB("q.epub")], F.meta("Quiet Rivers", "Ann Author"))
        let both = try f.importNew(
            [try f.makeEPUB("b.epub"), try f.makeM4B("b.m4b", tags: BookMetadata())], F.meta("Both", "Ann Author"))

        #expect(try book(f, audio).folderPath == "Audiobooks/Andy Weir/Artemis")
        #expect(try book(f, ebook).folderPath == "Ebooks/Ann Author/Quiet Rivers")
        #expect(try book(f, both).folderPath == "Audiobooks/Ann Author/Both")
        #expect(f.libraryTree().filter { $0.contains(".") } == [
            "Audiobooks/Andy Weir/Artemis/Artemis.m4b",
            "Audiobooks/Ann Author/Both/Both.epub",
            "Audiobooks/Ann Author/Both/Both.m4b",
            "Ebooks/Ann Author/Quiet Rivers/Quiet Rivers.epub",
        ])
        #expect(try [audio, ebook, both].allSatisfy { try !book(f, $0).needsAttention })
    }

    @Test func fp20_organiserPlansByThePatternItIsGiven() throws {
        let root = URL(fileURLWithPath: "/library")
        let files = [CandidateFile(url: URL(fileURLWithPath: "/in/x.epub"), role: .ebook)]
        let moves = try #require(Organiser.plan(
            files: files, metadata: F.meta("Dune", "Frank Herbert"), pattern: try FolderPattern(Self.kindPattern),
            libraryRoot: root))
        #expect(moves.map(\.to.path) == ["/library/Ebooks/Frank Herbert/Dune/Dune.epub"])
        let audio = [CandidateFile(url: URL(fileURLWithPath: "/in/x.m4b"), role: .audio)] + files
        #expect(Organiser.plan(
            files: audio, metadata: F.meta("Dune", "Frank Herbert"), pattern: try FolderPattern(Self.kindPattern),
            libraryRoot: root)?.map(\.to.path)
            == ["/library/Audiobooks/Frank Herbert/Dune/Dune.m4b", "/library/Audiobooks/Frank Herbert/Dune/Dune.epub"])
    }

    // MARK: FP20 The planned folder

    @Test func fp20_thePlannedFolderFollowsThePatternAndIsWhereImportFiles() throws {
        let f = try library(Self.kindPattern)
        let meta = F.meta("Artemis", "Andy Weir")
        #expect(f.service.plannedFolder(for: meta, hasAudio: true) == "Audiobooks/Andy Weir/Artemis")
        #expect(f.service.plannedFolder(for: meta, hasAudio: false) == "Ebooks/Andy Weir/Artemis")
        #expect(f.service.plannedFolder(for: BookMetadata(title: "No Author"), hasAudio: true) == nil)
        #expect(f.libraryTree().isEmpty)

        let id = try f.importNew([try f.makeEPUB("a.epub")], meta)
        #expect(try book(f, id).folderPath == f.service.plannedFolder(for: meta, hasAudio: false))
    }

    @Test func fp20_thePlannedFolderAdoptsAnExistingFoldersCapitalisation() throws {
        let f = try library(Self.kindPattern)
        try FileManager.default.createDirectory(at: f.lib("audiobooks/ANDY WEIR"), withIntermediateDirectories: true)
        let meta = F.meta("Artemis", "Andy Weir")
        #expect(f.service.plannedFolder(for: meta, hasAudio: true) == "audiobooks/ANDY WEIR/Artemis")
        let id = try f.importNew([try f.makeM4B("a.m4b", tags: BookMetadata())], meta)
        #expect(try book(f, id).folderPath == "audiobooks/ANDY WEIR/Artemis")
    }

    @Test func fp20_theFirstFilesOfABookWithNoneAreFiledByThePattern() throws {
        let f = try library(Self.kindPattern)
        let copy = ExternalCopy(kind: .audible, form: .audio)
        guard case .added(let id) = try f.service.addExternalBook(
            metadata: F.meta("The Glass Tide", "Ines Calloway"), cover: nil, copy: copy)
        else {
            Issue.record("the book was not added")
            return
        }
        // Only on Audible: it has no folder at all.
        #expect(try book(f, id).folderPath == nil)

        let ebook = try f.makeEPUB("glass.epub")
        let audio = try f.makeM4B("glass.m4b", tags: BookMetadata())
        let details = try book(f, id).metadata
        #expect(f.service.plannedFolder(for: details, firstFiles: f.candidate([ebook], BookMetadata()).files)
            == "Ebooks/Ines Calloway/The Glass Tide")
        #expect(f.service.plannedFolder(for: details, firstFiles: f.candidate([audio, ebook], BookMetadata()).files)
            == "Audiobooks/Ines Calloway/The Glass Tide")

        #expect(try f.importedId(try importInto(f, id, [ebook])) == id)
        #expect(try book(f, id).folderPath == "Ebooks/Ines Calloway/The Glass Tide")
        #expect(try paths(f, id) == ["Ebooks/Ines Calloway/The Glass Tide/The Glass Tide.epub"])
    }

    // MARK: FP20 Save

    @Test func fp20_saveRefilesByTheLibrarysPattern() throws {
        let f = try library(Self.kindPattern)
        let id = try f.importNew([try f.makeM4B("a.m4b", tags: BookMetadata())], F.meta("Artemis", "Andy Weir"))

        var edit = BookEdit(book: try book(f, id))
        edit.metadata.title = "Artemis Rising"
        edit.metadata.series = "Moon"
        edit.metadata.seriesNumber = "1"
        guard case .saved(_, let refiled, _, _) = try #require(try f.service.save([edit]).first) else {
            Issue.record("the edit was not saved")
            return
        }
        #expect(refiled)
        #expect(try book(f, id).folderPath == "Audiobooks/Andy Weir/Artemis Rising")
        #expect(try paths(f, id) == ["Audiobooks/Andy Weir/Artemis Rising/Artemis Rising.m4b"])
        #expect(f.libraryTree().filter { $0.hasSuffix(".m4b") } == ["Audiobooks/Andy Weir/Artemis Rising/Artemis Rising.m4b"])

        // What the pattern does not use does not move the book.
        var series = BookEdit(book: try book(f, id))
        series.metadata.series = "Luna"
        guard case .saved(_, let again, _, _) = try #require(try f.service.save([series]).first) else {
            Issue.record("the edit was not saved")
            return
        }
        #expect(!again)
        #expect(try book(f, id).folderPath == "Audiobooks/Andy Weir/Artemis Rising")
    }

    @Test func fp20_changingAFilesRoleFilesByTheLibrarysPattern() throws {
        let f = try library(Self.kindPattern)
        let id = try f.importNew(
            [try f.makeEPUB("a.epub"), try f.makePDF("map.pdf")], F.meta("Atlas", "Ann Author"))
        let pdf = try #require(try f.store.files(bookId: id).first { $0.format == .pdf })
        try f.service.setRole(pdf.role == .extra ? .ebook : .extra, forFile: try #require(pdf.id))
        // Still an ebook-only book, in the folder the pattern gives it.
        #expect(try book(f, id).folderPath == "Ebooks/Ann Author/Atlas")
        #expect(try paths(f, id).allSatisfy { $0.hasPrefix("Ebooks/Ann Author/Atlas/") })
    }

    @Test func fp20_aRoleChangeThatRefilesTheBookRecordsItsNewFolder() throws {
        // Filed under the standard pattern; then the library's pattern is another.
        let f = try F()
        let id = try f.importNew(
            [try f.makeEPUB("a.epub"), try f.makePDF("map.pdf")], F.meta("Atlas", "Ann Author"))
        #expect(try book(f, id).folderPath == "Ann Author/Atlas")
        let treeBefore = f.libraryTree()
        try f.store.setFolderPatternText(Self.kindPattern)

        let pdf = try #require(try f.store.files(bookId: id).first { $0.format == .pdf })
        try f.service.setRole(.extra, forFile: try #require(pdf.id))

        // Re-filed as a save would: every file is in the pattern's folder, and so is the record.
        #expect(try book(f, id).folderPath == "Ebooks/Ann Author/Atlas")
        #expect(try paths(f, id) == ["Ebooks/Ann Author/Atlas/Atlas.epub", "Ebooks/Ann Author/Atlas/Extras/Atlas.pdf"])
        #expect(f.libraryTree().filter { $0.contains(".") } == [
            "Ebooks/Ann Author/Atlas/Atlas.epub", "Ebooks/Ann Author/Atlas/Extras/Atlas.pdf",
        ])
        try f.service.undoLast()
        #expect(f.libraryTree() == treeBefore)
        #expect(try book(f, id).folderPath == "Ann Author/Atlas")
    }

    @Test func fp20_aSaveFilesABookWhereThePatternNowPutsIt() throws {
        let f = try F()
        let id = try f.importNew([try f.makeM4B("a.m4b", tags: BookMetadata())], F.meta("Artemis", "Andy Weir"))
        try f.store.setFolderPatternText(Self.kindPattern)

        var edit = BookEdit(book: try book(f, id))
        edit.rating = 5
        _ = try f.service.save([edit])

        #expect(try book(f, id).folderPath == "Audiobooks/Andy Weir/Artemis")
        #expect(f.libraryTree().filter { $0.contains(".") } == ["Audiobooks/Andy Weir/Artemis/Artemis.m4b"])
    }

    // MARK: FP22 Kind follows the files as they will be

    @Test func fp22_addingAudioToAnEbookOnlyBookRefilesItInThatOneOperation() throws {
        let f = try library(Self.kindPattern)
        let epub = try f.makeEPUB("a.epub")
        let pdf = try f.makePDF("map.pdf")
        let result = try f.service.importItems(
            [ImportItem(candidate: f.candidate([epub, pdf], F.meta("Atlas", "Ann Author"), roles: [pdf: .extra]))])
        let id = try f.importedId(try #require(result.outcomes.first))
        #expect(try book(f, id).folderPath == "Ebooks/Ann Author/Atlas")
        let treeBefore = f.libraryTree()
        let rowsBefore = try f.store.files(bookId: id)
        let audio = try f.makeM4B("atlas.m4b", tags: BookMetadata())

        #expect(try f.importedId(try importInto(f, id, [audio])) == id)

        #expect(try book(f, id).folderPath == "Audiobooks/Ann Author/Atlas")
        #expect(try paths(f, id) == [
            "Audiobooks/Ann Author/Atlas/Atlas.m4b",
            "Audiobooks/Ann Author/Atlas/Atlas.epub",
            "Audiobooks/Ann Author/Atlas/Extras/map.pdf",
        ])
        #expect(f.libraryTree() == [
            "Audiobooks", "Audiobooks/Ann Author", "Audiobooks/Ann Author/Atlas",
            "Audiobooks/Ann Author/Atlas/Atlas.epub", "Audiobooks/Ann Author/Atlas/Atlas.m4b",
            "Audiobooks/Ann Author/Atlas/Extras", "Audiobooks/Ann Author/Atlas/Extras/map.pdf",
        ])
        #expect(f.inboxTree().isEmpty)
        // One journal entry carries the whole of it.
        let batch = try #require(try f.store.lastBatch())
        #expect(batch.label == "Import 1 book")
        #expect(batch.moves.count == 3)
        #expect(try f.snapshot().books.map(\.bookId) == [id])

        // And undo puts every file back where it was.
        try f.service.undoLast()
        #expect(f.libraryTree() == treeBefore)
        #expect(try book(f, id).folderPath == "Ebooks/Ann Author/Atlas")
        #expect(try f.store.files(bookId: id) == rowsBefore)
        #expect(f.inboxTree() == ["atlas.m4b"])
    }

    @Test func fp22_whenCopyingTheBooksOwnFilesMoveAndTheNewOnesAreCopied() throws {
        let f = try library(Self.kindPattern)
        let id = try f.importNew([try f.makeEPUB("a.epub")], F.meta("Atlas", "Ann Author"))
        let audio = try f.makeM4B("atlas.m4b", tags: BookMetadata())

        #expect(try f.importedId(try importInto(f, id, [audio], mode: .copy)) == id)

        #expect(try book(f, id).folderPath == "Audiobooks/Ann Author/Atlas")
        #expect(f.libraryTree().filter { $0.contains(".") } == [
            "Audiobooks/Ann Author/Atlas/Atlas.epub", "Audiobooks/Ann Author/Atlas/Atlas.m4b",
        ])
        #expect(f.inboxTree() == ["atlas.m4b"])
    }

    @Test func fp22_addingFilesThatDoNotChangeTheKindLeavesTheBookWhereItIs() throws {
        let f = try library(Self.kindPattern)
        let ebook = try f.importNew([try f.makeEPUB("a.epub")], F.meta("Atlas", "Ann Author"))
        #expect(try f.importedId(try importInto(f, ebook, [try f.makePDF("map.pdf")])) == ebook)
        #expect(try book(f, ebook).folderPath == "Ebooks/Ann Author/Atlas")

        let audio = try f.importNew([try f.makeM4B("r.m4b", tags: BookMetadata())], F.meta("Rivers", "Ann Author"))
        #expect(try f.importedId(try importInto(f, audio, [try f.makeEPUB("r.epub")])) == audio)
        #expect(try book(f, audio).folderPath == "Audiobooks/Ann Author/Rivers")
        #expect(try paths(f, audio) == [
            "Audiobooks/Ann Author/Rivers/Rivers.m4b", "Audiobooks/Ann Author/Rivers/Rivers.epub",
        ])
    }

    @Test func fp22_underAPatternWithoutKindAddingAudioMovesNothing() throws {
        let f = try F()
        let id = try f.importNew([try f.makeEPUB("a.epub")], F.meta("Atlas", "Ann Author"))
        #expect(try f.importedId(try importInto(f, id, [try f.makeM4B("atlas.m4b", tags: BookMetadata())])) == id)
        #expect(try book(f, id).folderPath == "Ann Author/Atlas")
        #expect(try paths(f, id) == ["Ann Author/Atlas/Atlas.m4b", "Ann Author/Atlas/Atlas.epub"])
        #expect(try #require(try f.store.lastBatch()).moves.count == 1)
    }

    @Test func fp22_aNewFolderThatIsTakenFailsTheItemAndMovesNothing() throws {
        let f = try library(Self.kindPattern)
        let id = try f.importNew([try f.makeEPUB("a.epub")], F.meta("Atlas", "Ann Author"))
        // Something of the owner's is already where the ebook would have to go.
        let taken = f.lib("Audiobooks/Ann Author/Atlas/Atlas.epub")
        try FileManager.default.createDirectory(at: taken.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("theirs".utf8).write(to: taken)
        let treeBefore = f.libraryTree()

        let outcome = try importInto(f, id, [try f.makeM4B("atlas.m4b", tags: BookMetadata())])

        #expect(isFailed(outcome) != nil)
        #expect(f.libraryTree() == treeBefore)
        #expect(try Data(contentsOf: taken) == Data("theirs".utf8))
        #expect(try book(f, id).folderPath == "Ebooks/Ann Author/Atlas")
        #expect(f.inboxTree() == ["atlas.m4b"])
    }

    // MARK: FP23 A book the pattern cannot file

    static let narratorPattern = "{Narrator}/{Title}"

    @Test func fp23_theReasonNamesWhatIsMissing() throws {
        let pattern = try FolderPattern("{Narrator}/{Author}/{Year}/{Title}")
        func reason(_ m: BookMetadata) -> String? {
            pattern.unfiledReason(for: FolderPatternValues(metadata: m, hasAudio: true))
        }
        var m = F.meta("Dune", "Frank Herbert")
        #expect(reason(m) == "No narrator or year, which the folder layout needs.")
        m.year = 1965
        #expect(reason(m) == "No narrator, which the folder layout needs.")
        m.authors = []
        m.title = ""
        #expect(reason(m) == "No narrator, author or title, which the folder layout needs.")
        m = F.meta("Dune", "Frank Herbert")
        m.narrators = ["Scott Brick"]
        m.year = 1965
        #expect(reason(m) == nil)
        #expect(try FolderPattern("{Number} - {Title}").unfiledReason(
            for: FolderPatternValues(metadata: m, hasAudio: true)) == "No series number, which the folder layout needs.")
        #expect(FolderPattern.standard.unfiledReason(
            for: FolderPatternValues(metadata: BookMetadata(title: "Dune"), hasAudio: true))
            == "No author, which the folder layout needs.")
    }

    @Test func fp23_anImportedBookThePatternCannotFileStaysWhereItIsAndIsFlagged() throws {
        let f = try library(Self.narratorPattern)
        let audio = try f.makeM4B("a.m4b", tags: BookMetadata())
        let result = try f.service.importItems([ImportItem(candidate: f.candidate([audio], F.meta("Artemis", "Andy Weir")))])
        guard case .needsAttention(let id) = try #require(result.outcomes.first) else {
            Issue.record("expected the book to need attention, got \(result.outcomes)")
            return
        }
        // Exactly as a book with no author under the standard pattern.
        #expect(try book(f, id).needsAttention)
        #expect(try book(f, id).folderPath == nil)
        #expect(f.libraryTree().isEmpty)
        #expect(f.inboxTree() == ["a.m4b"])
        #expect(try paths(f, id).count == 1)
        #expect(try f.store.files(bookId: id).map { f.store.url(for: $0).lastPathComponent } == ["a.m4b"])
        #expect(try f.service.unfiledReason(for: id) == "No narrator, which the folder layout needs.")

        // Given what was missing, it is filed and the flag goes.
        var edit = BookEdit(book: try book(f, id))
        edit.metadata.narrators = ["Rosario Dawson"]
        _ = try f.service.save([edit])
        #expect(try book(f, id).folderPath == "Rosario Dawson/Artemis")
        #expect(try !book(f, id).needsAttention)
        #expect(try paths(f, id) == ["Rosario Dawson/Artemis/Artemis.m4b"])
        #expect(try f.service.unfiledReason(for: id) == nil)
    }

    @Test func fp23_aFiledBookThatLosesWhatThePatternNeedsIsNotMovedAndIsFlagged() throws {
        let f = try library(Self.narratorPattern)
        var meta = F.meta("Artemis", "Andy Weir")
        meta.narrators = ["Rosario Dawson"]
        let id = try f.importNew([try f.makeM4B("a.m4b", tags: BookMetadata())], meta)
        #expect(try book(f, id).folderPath == "Rosario Dawson/Artemis")
        let tree = f.libraryTree()

        var edit = BookEdit(book: try book(f, id))
        edit.metadata.narrators = []
        edit.metadata.title = "Artemis Rising"
        _ = try f.service.save([edit])

        #expect(f.libraryTree() == tree)
        #expect(try book(f, id).folderPath == "Rosario Dawson/Artemis")
        #expect(try book(f, id).needsAttention)
        #expect(try f.service.unfiledReason(for: id) == "No narrator, which the folder layout needs.")
        // A book with no author is no trouble to this pattern.
        var other = F.meta("Beowulf", "")
        other.authors = []
        other.narrators = ["Seamus Heaney"]
        let anonymous = try f.importNew([try f.makeM4B("b.m4b", tags: BookMetadata())], other)
        #expect(try book(f, anonymous).folderPath == "Seamus Heaney/Beowulf")
        #expect(try !book(f, anonymous).needsAttention)
    }

    @Test func fp23_firstFilesThePatternCannotFileAreRefusedWithTheReason() throws {
        let f = try library(Self.narratorPattern)
        guard case .added(let id) = try f.service.addExternalBook(
            metadata: F.meta("The Glass Tide", "Ines Calloway"), cover: nil,
            copy: ExternalCopy(kind: .audible, form: .audio))
        else {
            Issue.record("the book was not added")
            return
        }
        let ebook = try f.makeEPUB("glass.epub")
        let files = f.candidate([ebook], BookMetadata()).files
        #expect(f.service.plannedFolder(for: try book(f, id).metadata, firstFiles: files) == nil)
        let reason = try #require(isFailed(try importInto(f, id, [ebook])))
        #expect(reason.contains("No narrator, which the folder layout needs."))
        #expect(f.inboxTree() == ["glass.epub"])
        #expect(f.libraryTree().isEmpty)
    }

    @Test func fp23_theLaunchCheckKeepsABookFlaggedWhileThePatternCannotFileIt() throws {
        let f = try F()
        var meta = F.meta("Artemis", "Andy Weir")
        let noNarrator = try f.importNew([try f.makeM4B("a.m4b", tags: BookMetadata())], meta)
        meta.title = "Rivers"
        meta.narrators = ["Rosario Dawson"]
        let narrated = try f.importNew([try f.makeM4B("r.m4b", tags: BookMetadata())], meta)

        // Both lose a file and are flagged; then the files come back.
        let hidden = f.base.appendingPathComponent("away")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        for (id, name) in [(noNarrator, "a"), (narrated, "r")] {
            let file = f.store.url(for: try #require(try f.store.files(bookId: id).first))
            try FileManager.default.moveItem(at: file, to: hidden.appendingPathComponent(name))
        }
        #expect(Set(try f.service.reconcile().booksWithMissingFiles) == [noNarrator, narrated])
        for (id, name) in [(noNarrator, "a"), (narrated, "r")] {
            let file = f.store.url(for: try #require(try f.store.files(bookId: id).first))
            try FileManager.default.moveItem(at: hidden.appendingPathComponent(name), to: file)
        }

        // Under a pattern that needs a narrator, only the book that has one is in order again.
        try f.store.setFolderPatternText(Self.narratorPattern)
        let report = try f.service.reconcile()
        #expect(report.booksRecovered == [narrated])
        #expect(try book(f, noNarrator).needsAttention)
        #expect(try !book(f, narrated).needsAttention)
        // Nothing was moved by looking.
        #expect(try book(f, noNarrator).folderPath == "Andy Weir/Artemis")
        #expect(try book(f, narrated).folderPath == "Andy Weir/Rivers")

        // Under the standard pattern the other is in order too.
        try f.store.setFolderPatternText(nil)
        #expect(try f.service.reconcile().booksRecovered == [noNarrator])
    }

    // MARK: FP24 Migration

    @Test func fp24_aLibraryFromBeforePatternsOpensWithTheStandardOneAndNothingMoves() throws {
        let root = try makeTempDir()
        let path = root.appendingPathComponent(LibraryStore.databaseFileName).path
        let tables = [
            "book", "bookFile", "collection", "collectionBook", "operationBatch", "operationMove", "libraryNote",
            "watchFolder", "inboxEntry", "seriesLink", "seriesEntry",
        ]
        func rows(_ db: Database) throws -> [String: [EarlierRow]] {
            var all: [String: [EarlierRow]] = [:]
            for table in tables { all[table] = try earlierRows(db, of: table) }
            return all
        }
        func schema(_ db: Database) throws -> [String] {
            try String.fetchAll(
                db, sql: "SELECT sql FROM sqlite_master WHERE tbl_name IN (\(earlierSchemaTables(tables))) AND sql IS NOT NULL ORDER BY name")
        }
        // A book filed where no pattern would put it: it must not be touched either.
        let file = root.appendingPathComponent("Somewhere Odd/Patriot Games.m4b")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: file)

        var before: [String: [EarlierRow]] = [:]
        var schemaBefore: [String] = []
        do {
            let queue = try DatabaseQueue(path: path)
            try LibraryStore.migrator.migrate(queue, upTo: "v9")
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO book (title, authors, narrators, series, seriesNumber, tags, rating, needsAttention,
                                      folderPath, durationSeconds, dateAdded, readStatus, appOnlyFields, externalCopies,
                                      editionKind, partsAppearMissing)
                    VALUES ('Patriot Games', '["Tom Clancy"]', '[]', 'Jack Ryan', '2', '["kept"]', 4, 0,
                            'Somewhere Odd', 4368.5, '2025-01-02 03:04:05.000', 'finished', '[]', '[]', NULL, 1);
                    INSERT INTO bookFile (bookId, path, format, role, position)
                    VALUES (1, 'Somewhere Odd/Patriot Games.m4b', 'm4b', 'audio', 0);
                    INSERT INTO collection (name) VALUES ('To Read');
                    INSERT INTO collectionBook (collectionId, bookId) VALUES (1, 1);
                    INSERT INTO operationBatch (label, createdAt) VALUES ('Import 1 Book', '2025-01-02 03:04:05.000');
                    INSERT INTO operationMove (batchId, fromPath, toPath, wasCopy) VALUES (1, '/from', '/to', 0);
                    INSERT INTO libraryNote (key, value) VALUES ('lengthHeadersChecked', '1');
                    INSERT INTO watchFolder (path, mode, isEnabled, includesPDFs, addedAt)
                    VALUES ('/somewhere/watched', 'move', 1, 0, 700000000.25);
                    INSERT INTO inboxEntry (folderId, path, size, modifiedAt, state)
                    VALUES (1, '/somewhere/watched/a.m4b', 10, 700000000.5, 'dismissed');
                    INSERT INTO seriesLink (seriesKey, seriesName, audibleSeriesId, audibleSeriesTitle, store, checkedAt)
                    VALUES ('Jack Ryan', 'Jack Ryan', 'B00SERIES', 'Jack Ryan', 'us', 700000001.5);
                    INSERT INTO seriesEntry (linkId, position, number, sort, title, asins, titles, authors, narrators)
                    VALUES (1, 0, '2', 2.0, 'Patriot Games', '["B00"]', '["Patriot Games"]', '["Tom Clancy"]', '[]');
                    """)
                before = try rows(db)
                schemaBefore = try schema(db)
                let hasSettings = try db.tableExists("librarySetting")
                #expect(!hasSettings)
            }
        }
        let treeBefore = tree(root).filter { !$0.hasPrefix(LibraryStore.databaseFileName) }

        let store = try LibraryStore(libraryRoot: root)
        let service = LibraryService(store: store)

        try store.dbQueue.read { db in
            let rowsAfter = try rows(db)
            let schemaAfter = try schema(db)
            let hasSettings = try db.tableExists("librarySetting")
            let columns = try db.columns(in: "librarySetting").map(\.name)
            let key = try db.primaryKey("librarySetting").columns
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM librarySetting")
            #expect(rowsAfter == before)
            #expect(schemaAfter == schemaBefore)
            #expect(hasSettings)
            #expect(columns == ["key", "value"])
            #expect(key == ["key"])
            #expect(count == 0)
        }
        #expect(try service.folderPattern() == .standard)
        // The launch check moves nothing, and finds nothing wrong with the book.
        let report = try service.reconcile()
        #expect(report.booksWithMissingFiles.isEmpty)
        // The catalogue's own files aside, the copy kept before genres (GP7) among them.
        let treeAfter = tree(root).filter {
            !$0.hasPrefix(LibraryStore.databaseFileName) && !$0.hasPrefix("VoxCarrel before genres")
        }
        #expect(treeAfter == treeBefore)
        #expect(try store.book(id: 1)?.folderPath == "Somewhere Odd")
        #expect(try store.files(bookId: 1).map(\.path) == ["Somewhere Odd/Patriot Games.m4b"])
    }

    @Test func fp24_theSettingRoundTripsAndIsOneRow() throws {
        let f = try F()
        try f.store.setFolderPatternText("{Author}/{Title}")
        try f.store.setFolderPatternText(Self.kindPattern)
        #expect(try f.store.folderPatternText() == Self.kindPattern)
        let stored = try f.store.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT key, value FROM librarySetting WHERE key = 'folderPattern'")
                .map { [$0["key"] as String, $0["value"] as String] }
        }
        #expect(stored == [["folderPattern", Self.kindPattern]])
    }
}
