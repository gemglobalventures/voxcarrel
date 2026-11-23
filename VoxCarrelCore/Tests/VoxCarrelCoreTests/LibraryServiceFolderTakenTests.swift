import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// FP41: a book is never filed into another book's folder.
@Suite struct LibraryServiceFolderTakenTests {
    typealias F = LibraryFixture

    static let reason = "Another book uses the folder this book belongs in."

    private func book(_ f: F, _ id: Int64) throws -> Book {
        try #require(try f.store.book(id: id))
    }

    /// An ebook "Dune" and an audiobook "Dune Audio", both by Frank Herbert, with real files.
    private func ebookAndAudiobook(_ f: F) throws -> (ebook: Int64, audio: Int64) {
        let ebook = try f.importNew([try f.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))
        let audio = try f.importNew(
            [try f.makeM4B("dune.m4b", tags: BookMetadata())], F.meta("Dune Audio", "Frank Herbert"))
        #expect(f.libraryTree().filter { $0.contains(".") } == [
            "Frank Herbert/Dune Audio/Dune Audio.m4b", "Frank Herbert/Dune/Dune.epub",
        ])
        return (ebook, audio)
    }

    // MARK: Save

    @Test func fp41_aSaveDoesNotFileABookIntoAnotherBooksFolder() throws {
        let f = try F()
        let (ebook, audio) = try ebookAndAudiobook(f)
        let tree = f.libraryTree()

        // Retitled, the audiobook belongs in the ebook's folder, where no file name is in its way.
        var edit = BookEdit(book: try book(f, audio))
        edit.metadata.title = "Dune"
        let outcome = try #require(try f.service.save([edit]).first)
        guard case .saved(_, let refiled, _, _) = outcome else {
            Issue.record("expected the edit to be saved, got \(outcome)")
            return
        }
        #expect(!refiled)

        // It stays where it is, is flagged, and says why. The edit itself is kept.
        #expect(f.libraryTree() == tree)
        #expect(try book(f, audio).title == "Dune")
        #expect(try book(f, audio).folderPath == "Frank Herbert/Dune Audio")
        #expect(try f.store.files(bookId: audio).map(\.path) == ["Frank Herbert/Dune Audio/Dune Audio.m4b"])
        #expect(try book(f, audio).needsAttention)
        #expect(try f.service.unfiledReason(for: audio) == Self.reason)
        #expect(try f.tags(f.lib("Frank Herbert/Dune Audio/Dune Audio.m4b")).title == "Dune")
        // The book whose folder it is knows nothing of it.
        #expect(try !book(f, ebook).needsAttention)
        #expect(try f.service.unfiledReason(for: ebook) == nil)
        #expect(try f.store.files(bookId: ebook).map(\.path) == ["Frank Herbert/Dune/Dune.epub"])

        // Saved again, in any way, it still does not move; nor does the launch check clear the flag.
        var again = BookEdit(book: try book(f, audio))
        again.rating = 4
        _ = try f.service.save([again])
        #expect(f.libraryTree() == tree)
        #expect(try book(f, audio).needsAttention)
        #expect(try f.service.reconcile() == ReconcileReport())
        #expect(try book(f, audio).needsAttention)

        // Undo puts the flag back as it was.
        try f.service.undoLast()
        #expect(try book(f, audio).rating == 0)
        #expect(try book(f, audio).needsAttention)
    }

    @Test func fp41_onceTheFolderIsFreeTheBookIsFiledAndTheFlagGoes() throws {
        let f = try F()
        let (ebook, audio) = try ebookAndAudiobook(f)
        var edit = BookEdit(book: try book(f, audio))
        edit.metadata.title = "Dune"
        _ = try f.service.save([edit])
        #expect(try book(f, audio).needsAttention)

        // The other book is renamed away: its folder goes with it.
        var away = BookEdit(book: try book(f, ebook))
        away.metadata.title = "Dune Ebook"
        _ = try f.service.save([away])
        #expect(try book(f, ebook).folderPath == "Frank Herbert/Dune Ebook")
        #expect(try f.service.unfiledReason(for: audio) == nil)

        var rating = BookEdit(book: try book(f, audio))
        rating.rating = 5
        _ = try f.service.save([rating])
        #expect(try book(f, audio).folderPath == "Frank Herbert/Dune")
        #expect(try f.store.files(bookId: audio).map(\.path) == ["Frank Herbert/Dune/Dune.m4b"])
        #expect(try !book(f, audio).needsAttention)
        #expect(f.libraryTree().filter { $0.contains(".") } == [
            "Frank Herbert/Dune Ebook/Dune Ebook.epub", "Frank Herbert/Dune/Dune.m4b",
        ])
    }

    @Test func fp41_theLaunchCheckClearsTheFlagOnceTheFolderIsFree() throws {
        let f = try F()
        let (ebook, audio) = try ebookAndAudiobook(f)
        var edit = BookEdit(book: try book(f, audio))
        edit.metadata.title = "Dune"
        _ = try f.service.save([edit])
        #expect(try f.service.reconcile().booksRecovered.isEmpty)
        try f.service.removeBook(id: ebook, moveFilesToTrash: false)
        #expect(try f.service.reconcile().booksRecovered == [audio])
        #expect(try !book(f, audio).needsAttention)
    }

    @Test func fp41_twoEditsOfOneSaveThatWouldSwapFoldersBothStay() throws {
        let f = try F()
        let (ebook, audio) = try ebookAndAudiobook(f)
        let tree = f.libraryTree()
        var first = BookEdit(book: try book(f, audio))
        first.metadata.title = "Dune"
        var second = BookEdit(book: try book(f, ebook))
        second.metadata.title = "Dune Audio"
        _ = try f.service.save([first, second])
        #expect(f.libraryTree() == tree)
        #expect(try book(f, audio).needsAttention)
        #expect(try book(f, ebook).needsAttention)
    }

    @Test func fp41_aBookMovedAwayEarlierInTheSameSaveLeavesItsFolderFree() throws {
        let f = try F()
        let (ebook, audio) = try ebookAndAudiobook(f)
        var away = BookEdit(book: try book(f, ebook))
        away.metadata.title = "Dune Ebook"
        var into = BookEdit(book: try book(f, audio))
        into.metadata.title = "Dune"
        _ = try f.service.save([away, into])
        #expect(try book(f, ebook).folderPath == "Frank Herbert/Dune Ebook")
        #expect(try book(f, audio).folderPath == "Frank Herbert/Dune")
        #expect(try !book(f, audio).needsAttention)
        // And one moved into a folder earlier in the same save keeps it.
        let third = try f.importNew([try f.makeEPUB("third.epub")], F.meta("Third", "Frank Herbert"))
        var one = BookEdit(book: try book(f, ebook))
        one.metadata.title = "Fresh"
        var two = BookEdit(book: try book(f, third))
        two.metadata.title = "Fresh"
        _ = try f.service.save([one, two])
        #expect(try book(f, ebook).folderPath == "Frank Herbert/Fresh")
        #expect(try book(f, third).folderPath == "Frank Herbert/Third")
        #expect(try book(f, third).needsAttention)
        #expect(try f.service.unfiledReason(for: third) == Self.reason)
    }

    @Test func fp41_aBookFiledWhereItAlreadyIsEarlierInTheSameSaveKeepsItsFolder() throws {
        let f = try F()
        // Catalogued but never filed, though its file is where the pattern files it.
        let file = f.lib("Ann/Title/Title.m4b")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stand-in".utf8).write(to: file)
        let unfiled = try #require(try f.store.insert(
            Book(metadata: F.meta("Title", "Ann"), folderPath: nil, needsAttention: true),
            files: [BookFile(path: "Ann/Title/Title.m4b", format: .m4b, role: .audio, position: 0)]).id)
        let other = try f.importNew([try f.makeEPUB("other.epub")], F.meta("Other", "Ann"))

        var first = BookEdit(book: try book(f, unfiled))
        first.rating = 3
        var second = BookEdit(book: try book(f, other))
        second.metadata.title = "Title"
        _ = try f.service.save([first, second])

        #expect(try book(f, unfiled).folderPath == "Ann/Title")
        #expect(try book(f, other).folderPath == "Ann/Other")
        #expect(try book(f, other).needsAttention)
        #expect(f.libraryTree().filter { $0.contains(".") } == ["Ann/Other/Other.epub", "Ann/Title/Title.m4b"])
    }

    @Test func fp41_aBookAlreadySharingItsFolderIsLeftAsItWas() throws {
        let f = try F()
        // Two books in one folder, as two imports of one title can leave them.
        let ebook = try f.importNew([try f.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))
        let audio = try f.importNew([try f.makeM4B("dune.m4b", tags: BookMetadata())], F.meta("Dune", "Frank Herbert"))
        #expect(try book(f, ebook).folderPath == book(f, audio).folderPath)
        var edit = BookEdit(book: try book(f, audio))
        edit.rating = 3
        edit.metadata.genre = "Science Fiction"
        _ = try f.service.save([edit])
        #expect(try !book(f, audio).needsAttention)
        #expect(try f.service.unfiledReason(for: audio) == nil)
        #expect(try f.service.unfiledReason(for: ebook) == nil)
    }

    // MARK: Role change

    @Test func fp41_aRoleChangeDoesNotFileABookIntoAnotherBooksFolder() throws {
        let f = try F()
        let ebook = try f.importNew([try f.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))
        let audio = try f.importNew(
            [try f.makeM4B("dune.m4b", tags: BookMetadata()), try f.makePDF("map.pdf")], F.meta("Dune Audio", "Frank Herbert"))
        // Left behind: its details now file it in the ebook's folder.
        var stored = try book(f, audio)
        stored.title = "Dune"
        try f.store.update(stored)
        let tree = f.libraryTree()
        let pdf = try #require(try f.store.files(bookId: audio).first { $0.format == .pdf })

        try f.service.setRole(pdf.role == .extra ? .ebook : .extra, forFile: try #require(pdf.id))

        #expect(f.libraryTree() == tree)
        #expect(try book(f, audio).folderPath == "Frank Herbert/Dune Audio")
        #expect(try book(f, audio).needsAttention)
        #expect(try f.service.unfiledReason(for: audio) == Self.reason)
        #expect(try f.store.files(bookId: ebook).map(\.path) == ["Frank Herbert/Dune/Dune.epub"])
        let changed = try #require(try f.store.files(bookId: audio).first { $0.format == .pdf })
        #expect(changed.role != pdf.role)
    }

    // MARK: Adding files

    @Test func fp41_addingFilesDoesNotRefileABookIntoAnotherBooksFolder() throws {
        let f = try F()
        try f.store.setFolderPatternText("{Kind}/{Author}/{Title}")
        // Two books of one title, an audiobook and an ebook: each in its own folder.
        let audio = try f.importNew([try f.makeM4B("dune.m4b", tags: BookMetadata())], F.meta("Dune", "Frank Herbert"))
        let ebook = try f.importNew([try f.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))
        #expect(try book(f, audio).folderPath == "Audiobooks/Frank Herbert/Dune")
        #expect(try book(f, ebook).folderPath == "Ebooks/Frank Herbert/Dune")

        // Audio added to the ebook makes it an audiobook, which belongs in the other book's folder.
        let more = try f.makeMP3("more.mp3", tags: BookMetadata())
        let item = ImportItem(candidate: f.candidate([more], BookMetadata()), target: .existing(bookId: ebook))
        let outcome = try #require(try f.service.importItems([item]).outcomes.first)
        _ = try f.importedId(outcome)

        #expect(try book(f, ebook).folderPath == "Ebooks/Frank Herbert/Dune")
        #expect(try f.store.files(bookId: ebook).map(\.path) == [
            "Ebooks/Frank Herbert/Dune/Dune.mp3", "Ebooks/Frank Herbert/Dune/Dune.epub",
        ])
        #expect(try book(f, ebook).needsAttention)
        #expect(try f.service.unfiledReason(for: ebook) == Self.reason)
        #expect(try f.store.files(bookId: audio).map(\.path) == ["Audiobooks/Frank Herbert/Dune/Dune.m4b"])
        #expect(f.libraryTree().filter { $0.contains(".") } == [
            "Audiobooks/Frank Herbert/Dune/Dune.m4b", "Ebooks/Frank Herbert/Dune/Dune.epub", "Ebooks/Frank Herbert/Dune/Dune.mp3",
        ])
    }

    @Test func fp41_addingFilesDoesNotRefileABookIntoTheFolderOfABookImportedInTheSameCall() throws {
        let f = try F()
        try f.store.setFolderPatternText("{Kind}/{Author}/{Title}")
        let ebook = try f.importNew([try f.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))
        // One call: a new audiobook of the same title, and audio added to the ebook.
        let new = ImportItem(candidate: f.candidate([try f.makeM4B("new.m4b", tags: BookMetadata())], F.meta("Dune", "Frank Herbert")))
        let join = ImportItem(
            candidate: f.candidate([try f.makeMP3("more.mp3", tags: BookMetadata())], BookMetadata()),
            target: .existing(bookId: ebook))
        let outcomes = try f.service.importItems([new, join]).outcomes
        let audio = try f.importedId(outcomes[0])
        _ = try f.importedId(outcomes[1])
        #expect(try book(f, audio).folderPath == "Audiobooks/Frank Herbert/Dune")
        #expect(try f.store.files(bookId: audio).map(\.path) == ["Audiobooks/Frank Herbert/Dune/Dune.m4b"])
        #expect(try book(f, ebook).folderPath == "Ebooks/Frank Herbert/Dune")
        #expect(try book(f, ebook).needsAttention)
        #expect(f.libraryTree().filter { $0.contains(".") } == [
            "Audiobooks/Frank Herbert/Dune/Dune.m4b", "Ebooks/Frank Herbert/Dune/Dune.epub", "Ebooks/Frank Herbert/Dune/Dune.mp3",
        ])
    }

    // MARK: The first files of a book that has none

    private func ownedElsewhere(_ f: F, _ title: String, _ author: String) throws -> Int64 {
        guard case .added(let id) = try f.service.addExternalBook(
            metadata: F.meta(title, author), cover: nil, copy: ExternalCopy(kind: .audible, form: .audio))
        else {
            Issue.record("the book was not added")
            throw F.FixtureError.unexpectedOutcome
        }
        return id
    }

    @Test func fp41_theFirstFilesOfABookAreNotFiledIntoAnotherBooksFolder() throws {
        let f = try F()
        // An ebook "Dune", and a "Dune" owned elsewhere with no files: two books.
        let ebook = try f.importNew([try f.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))
        var stored = try book(f, ebook)
        stored.needsAttention = true  // so that the entry is not taken for the same book
        try f.store.update(stored)
        let owned = try ownedElsewhere(f, "Dune", "Frank Herbert")
        stored.needsAttention = false
        try f.store.update(stored)
        #expect(owned != ebook)
        let tree = f.libraryTree()

        // Its first file would be filed in the ebook's folder, where no name is in its way.
        let audio = try f.makeM4B("dune.m4b", tags: BookMetadata())
        let item = ImportItem(candidate: f.candidate([audio], BookMetadata()), target: .existing(bookId: owned))
        let outcome = try #require(try f.service.importItems([item]).outcomes.first)
        let reason = try #require(isFailed(outcome))
        #expect(reason.contains(Self.reason))
        #expect(reason.contains("Dune"))

        // Nothing moved, and the book is as it was.
        #expect(f.libraryTree() == tree)
        #expect(f.inboxTree() == ["dune.m4b"])
        #expect(try f.store.files(bookId: owned).isEmpty)
        #expect(try book(f, owned).folderPath == nil)
        #expect(try f.store.files(bookId: ebook).map(\.path) == ["Frank Herbert/Dune/Dune.epub"])

        // Once the folder is free the same files are taken.
        var away = BookEdit(book: try book(f, ebook))
        away.metadata.title = "Dune Ebook"
        _ = try f.service.save([away])
        _ = try f.importedId(try #require(try f.service.importItems([item]).outcomes.first))
        #expect(try book(f, owned).folderPath == "Frank Herbert/Dune")
        #expect(try f.store.files(bookId: owned).map(\.path) == ["Frank Herbert/Dune/Dune.m4b"])
    }

    /// FL14: what is shown before an import can ask whether a folder is another book's.
    @Test func fl14_aPlannedFolderCanBeAskedWhetherAnotherBookHasIt() throws {
        let f = try F()
        let ebook = try f.importNew([try f.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))
        let owned = try ownedElsewhere(f, "Dune Messiah", "Frank Herbert")
        let folder = try #require(f.service.plannedFolder(for: F.meta("Dune", "Frank Herbert"), hasAudio: true))
        #expect(folder == "Frank Herbert/Dune")
        #expect(f.service.isFolderOfAnotherBook(folder, than: owned))
        #expect(f.service.isFolderOfAnotherBook(folder, than: nil))
        // Compared as the volume compares names.
        #expect(f.service.isFolderOfAnotherBook("frank herbert/DUNE", than: owned))
        // Its own folder is not another book's, and nor is a folder no book has.
        #expect(!f.service.isFolderOfAnotherBook(folder, than: ebook))
        #expect(!f.service.isFolderOfAnotherBook("Frank Herbert/Dune Messiah", than: owned))
        #expect(!f.service.isFolderOfAnotherBook("Frank Herbert", than: owned))
    }

    @Test func fp41_theFirstFilesOfABookAreNotFiledIntoTheFolderOfABookImportedInTheSameCall() throws {
        let f = try F()
        let owned = try ownedElsewhere(f, "Dune", "Frank Herbert")
        // One call: a new ebook that is given the folder, then the first file of the entry.
        var separate = F.meta("Dune", "Frank Herbert")
        separate.asin = "B000000001"
        let new = ImportItem(candidate: f.candidate([try f.makeEPUB("dune.epub")], separate))
        let first = ImportItem(
            candidate: f.candidate([try f.makeM4B("dune.m4b", tags: BookMetadata())], BookMetadata()),
            target: .existing(bookId: owned))
        let outcomes = try f.service.importItems([new, first]).outcomes
        _ = try f.importedId(outcomes[0])
        #expect(try #require(isFailed(outcomes[1])).contains(Self.reason))
        #expect(f.libraryTree().filter { $0.contains(".") } == ["Frank Herbert/Dune/Dune.epub"])
        #expect(f.inboxTree() == ["dune.m4b"])
    }

    // MARK: Changing the layout

    @Test func fp41_aBookLeftBehindByAChangeOfLayoutIsNotMergedByALaterSave() throws {
        let f = try F()
        let ebook = try f.importNew([try f.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))
        var meta = F.meta("Dune", "Frank Herbert")
        meta.series = "Dune Saga"
        meta.seriesNumber = "1"
        let audio = try f.importNew([try f.makeM4B("dune.m4b", tags: BookMetadata())], meta)
        let done = try f.service.applyLayoutChange(to: try FolderPattern("{Author}/{Title}"))
        #expect(done.moves.isEmpty)
        #expect(done.staying.map(\.bookId) == [audio])
        #expect(try book(f, audio).needsAttention)
        let tree = f.libraryTree()

        var edit = BookEdit(book: try book(f, audio))
        edit.metadata.genre = "Science Fiction"
        _ = try f.service.save([edit])
        #expect(f.libraryTree() == tree)
        #expect(try book(f, audio).folderPath == "Frank Herbert/Dune Saga/1 - Dune")
        #expect(try f.service.unfiledReason(for: audio) == Self.reason)
        #expect(try f.store.files(bookId: ebook).map(\.path) == ["Frank Herbert/Dune/Dune.epub"])
    }

    @Test func fp41_namesAreComparedAsTheVolumeComparesThem() throws {
        let f = try F()
        guard !f.service.volumeNaming.caseSensitive else { return }
        let (ebook, audio) = try ebookAndAudiobook(f)
        _ = ebook
        let tree = f.libraryTree()
        var edit = BookEdit(book: try book(f, audio))
        edit.metadata.title = "DUNE"
        edit.metadata.authors = ["FRANK HERBERT"]
        _ = try f.service.save([edit])
        #expect(f.libraryTree() == tree)
        #expect(try book(f, audio).needsAttention)
        #expect(try f.service.unfiledReason(for: audio) == Self.reason)
    }
}
