import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

@Suite struct LibraryServiceSaveTests {
    typealias F = LibraryFixture
    let allText = Set(MetadataField.allCases).subtracting([.cover])

    /// Imports one M4B as a new book and returns its id.
    func importM4B(_ f: F, _ metadata: BookMetadata, cover: CoverImage? = nil, name: String = "in.m4b") throws -> Int64 {
        try f.importNew([try f.makeM4B(name, tags: F.meta("Old", "Old Author"), cover: cover)], metadata)
    }

    func edit(_ f: F, _ id: Int64, cover: CoverChange = .keep, _ change: (inout BookEdit) -> Void = { _ in }) throws -> BookEdit {
        var edit = BookEdit(book: try #require(try f.store.book(id: id)), cover: cover)
        change(&edit)
        return edit
    }

    func batchCount(_ f: F) throws -> Int {
        try f.store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM operationBatch") ?? 0 }
    }

    /// The names directly inside the library folder, as spelled on disk, without VoxCarrel's own.
    func topLevel(_ f: F) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: f.root.path)
            .filter { !$0.hasPrefix(LibraryStore.databaseFileName) && !$0.hasPrefix(".") }.sorted()
    }

    @Test func bookEditStartsFromTheBook() throws {
        var book = Book(metadata: F.fullMeta("Artemis", "Andy Weir"))
        book.id = 42
        book.tags = ["favourite", "space"]
        book.rating = 4
        let edit = BookEdit(book: book)
        #expect(edit.bookId == 42)
        #expect(edit.metadata == book.metadata)
        #expect(edit.cover == .keep)
        #expect(edit.tags == ["favourite", "space"])
        #expect(edit.rating == 4)
        #expect(BookEdit(book: book, cover: .remove).cover == .remove)
    }

    // E7
    @Test func editWritesDatabaseAndTags() throws {
        let f = try F()
        let id = try importM4B(f, F.fullMeta("Artemis", "Andy Weir"))
        let path = "Andy Weir/The Series/2 - Artemis/Artemis.m4b"
        let treeBefore = f.libraryTree()
        let rowsBefore = try f.store.files(bookId: id)
        var expected = F.fullMeta("Artemis", "Andy Weir")
        expected.genres = ["Thriller"]
        // The wording the book had stays with the book (G4); in the file it is the tag.
        expected.genreSource = "Thriller"
        expected.narrators = ["Rosario Dawson"]

        let outcomes = try f.service.save([
            try edit(f, id) {
                $0.metadata.genres = ["Thriller"]
                $0.metadata.narrators = ["Rosario Dawson"]
            }
        ])

        #expect(outcomes == [.saved(bookId: id, refiled: false, appOnlyFields: [], fileProblems: [])])
        let book = try #require(try f.store.book(id: id))
        #expect(book.genres == ["Thriller"])
        #expect(book.narrators == ["Rosario Dawson"])
        #expect(book.folderPath == "Andy Weir/The Series/2 - Artemis")
        #expect(try f.tags(f.lib(path)) == expected)
        #expect(f.libraryTree() == treeBefore)
        #expect(try f.store.files(bookId: id).map(\.path) == rowsBefore.map(\.path))
        // E10: one batch named after the book, with nothing to move back.
        let batch = try #require(try f.store.lastBatch())
        #expect(batch.label == "Edit Artemis")
        #expect(batch.moves.isEmpty)
        #expect(try batchCount(f) == 1)
    }

    // E3, E6
    @Test func changingAuthorMovesTheBookAndPrunes() throws {
        let f = try F()
        let m4b = try f.makeM4B("a.m4b", tags: F.meta("x", "y"))
        let epub = try f.makeEPUB("a.epub")
        let map = try f.makePDF("Map.pdf")
        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([m4b, epub, map], F.meta("Artemis", "Andy Weir"), roles: [map: .extra]))
        ])
        let id = try f.importedId(result.outcomes[0])
        let mapBytes = try f.bytes(f.lib("Andy Weir/Artemis/Extras/Map.pdf"))

        let outcomes = try f.service.save([try edit(f, id) { $0.metadata.authors = ["Andrew Weir"] }])

        guard case .saved(id, true, _, let problems) = try #require(outcomes.first) else {
            Issue.record("expected a refiled save, got \(outcomes)")
            return
        }
        #expect(problems.isEmpty)
        // E6: the emptied author folder is gone.
        #expect(f.libraryTree() == [
            "Andrew Weir", "Andrew Weir/Artemis", "Andrew Weir/Artemis/Artemis.epub",
            "Andrew Weir/Artemis/Artemis.m4b", "Andrew Weir/Artemis/Extras",
            "Andrew Weir/Artemis/Extras/Map.pdf",
        ])
        let book = try #require(try f.store.book(id: id))
        #expect(book.authors == ["Andrew Weir"])
        #expect(book.folderPath == "Andrew Weir/Artemis")
        #expect(book.needsAttention == false)
        let files = try f.store.files(bookId: id)
        #expect(files.map(\.path) == [
            "Andrew Weir/Artemis/Artemis.m4b", "Andrew Weir/Artemis/Artemis.epub",
            "Andrew Weir/Artemis/Extras/Map.pdf",
        ])
        #expect(files.map(\.role) == [.audio, .ebook, .extra])
        #expect(try f.tags(f.lib("Andrew Weir/Artemis/Artemis.m4b")).authors == ["Andrew Weir"])
        #expect(try f.tags(f.lib("Andrew Weir/Artemis/Artemis.epub")).authors == ["Andrew Weir"])
        #expect(try f.bytes(f.lib("Andrew Weir/Artemis/Extras/Map.pdf")) == mapBytes)
        // E10: every move is recorded.
        let moves = try #require(try f.store.lastBatch()).moves
        #expect(moves.count == 3)
        #expect(moves.allSatisfy { !$0.wasCopy })
        #expect(moves.first == MoveRecord(
            from: f.lib("Andy Weir/Artemis/Artemis.m4b").path,
            to: f.lib("Andrew Weir/Artemis/Artemis.m4b").path, wasCopy: false))
    }

    // E3
    @Test func changingSeriesNumberRenamesTheFolder() throws {
        let f = try F()
        var metadata = F.meta("Artemis", "Andy Weir")
        metadata.series = "Moon"
        metadata.seriesNumber = "1"
        let id = try importM4B(f, metadata)
        #expect(exists(f.lib("Andy Weir/Moon/1 - Artemis/Artemis.m4b")))

        let outcomes = try f.service.save([try edit(f, id) { $0.metadata.seriesNumber = "2" }])

        #expect(outcomes == [.saved(bookId: id, refiled: true, appOnlyFields: [], fileProblems: [])])
        #expect(f.libraryTree() == [
            "Andy Weir", "Andy Weir/Moon", "Andy Weir/Moon/2 - Artemis", "Andy Weir/Moon/2 - Artemis/Artemis.m4b",
        ])
        #expect(try f.store.book(id: id)?.folderPath == "Andy Weir/Moon/2 - Artemis")
        #expect(try f.store.files(bookId: id).map(\.path) == ["Andy Weir/Moon/2 - Artemis/Artemis.m4b"])
        #expect(try f.tags(f.lib("Andy Weir/Moon/2 - Artemis/Artemis.m4b")).seriesNumber == "2")
    }

    // E3: a title change renames the files inside the folder too.
    @Test func changingTitleRenamesFolderAndFiles() throws {
        let f = try F()
        let parts = try f.makeMP3Parts(folder: "rip", tags: F.meta("Old", "Old Author"))
        let id = try f.importNew(parts, F.meta("Dune", "Frank Herbert"))

        let outcomes = try f.service.save([try edit(f, id) { $0.metadata.title = "Dune Messiah" }])

        #expect(outcomes == [.saved(bookId: id, refiled: true, appOnlyFields: [], fileProblems: [])])
        #expect(f.libraryTree() == [
            "Frank Herbert", "Frank Herbert/Dune Messiah",
            "Frank Herbert/Dune Messiah/01 - Dune Messiah.mp3", "Frank Herbert/Dune Messiah/02 - Dune Messiah.mp3",
        ])
        // E7: part positions as in I5.
        #expect(try f.track(f.lib("Frank Herbert/Dune Messiah/01 - Dune Messiah.mp3")) == "1/2")
        #expect(try f.track(f.lib("Frank Herbert/Dune Messiah/02 - Dune Messiah.mp3")) == "2/2")
        #expect(try f.tags(f.lib("Frank Herbert/Dune Messiah/02 - Dune Messiah.mp3")).title == "Dune Messiah")
        // The parts' own track titles are still theirs.
        #expect(try f.trackTitle(f.lib("Frank Herbert/Dune Messiah/01 - Dune Messiah.mp3")) == "Old")
    }

    // E3
    @Test func capitalisationOnlyChangeDoesNotRename() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("artemis", "andy weir"))
        #expect(try topLevel(f) == ["andy weir"])
        let rowsBefore = try f.store.files(bookId: id)

        let outcomes = try f.service.save([
            try edit(f, id) {
                $0.metadata.authors = ["Andy Weir"]
                $0.metadata.title = "Artemis"
            }
        ])

        #expect(outcomes == [.saved(bookId: id, refiled: false, appOnlyFields: [], fileProblems: [])])
        // On disk nothing is renamed: folders and the file keep their spelling.
        #expect(try topLevel(f) == ["andy weir"])
        #expect(f.libraryTree() == ["andy weir", "andy weir/artemis", "andy weir/artemis/artemis.m4b"])
        // Stored paths are exactly as they were.
        #expect(try f.store.files(bookId: id) .map(\.path) == rowsBefore.map(\.path))
        #expect(try f.store.files(bookId: id).map(\.path) == ["andy weir/artemis/artemis.m4b"])
        let book = try #require(try f.store.book(id: id))
        #expect(book.folderPath == "andy weir/artemis")
        // The database and the tags carry the new capitalisation.
        #expect(book.authors == ["Andy Weir"])
        #expect(book.title == "Artemis")
        let tags = try f.tags(f.lib("andy weir/artemis/artemis.m4b"))
        #expect(tags.authors == ["Andy Weir"])
        #expect(tags.title == "Artemis")
        #expect(try #require(try f.store.lastBatch()).moves.isEmpty)
    }

    // E3
    @Test func sharedAuthorFolderKeepsItsCapitalisation() throws {
        let f = try F()
        let first = try importM4B(f, F.meta("First", "andy weir"), name: "1.m4b")
        let second = try importM4B(f, F.meta("Second", "andy weir"), name: "2.m4b")

        let outcomes = try f.service.save([
            try edit(f, first) {
                $0.metadata.authors = ["Andy Weir"]
                $0.metadata.title = "New Title"
            }
        ])

        #expect(outcomes == [.saved(bookId: first, refiled: true, appOnlyFields: [], fileProblems: [])])
        #expect(try topLevel(f) == ["andy weir"])
        #expect(f.libraryTree() == [
            "andy weir", "andy weir/New Title", "andy weir/New Title/New Title.m4b",
            "andy weir/Second", "andy weir/Second/Second.m4b",
        ])
        #expect(try f.store.book(id: first)?.folderPath == "andy weir/New Title")
        #expect(try f.store.files(bookId: first).map(\.path) == ["andy weir/New Title/New Title.m4b"])
        #expect(try f.store.book(id: first)?.authors == ["Andy Weir"])
        // The other book is untouched.
        #expect(try f.store.files(bookId: second).map(\.path) == ["andy weir/Second/Second.m4b"])
    }

    // E7
    @Test func ratingAndTagsOnlyOpensNoFile() throws {
        let f = try F()
        let fm = FileManager.default
        let source = try f.makeM4B("locked.m4b", tags: F.meta("Old", "Old Author"))
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: source.path)
        let dest = f.lib("Andy Weir/Artemis/Artemis.m4b")
        defer {
            for url in [source, dest] { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        }
        let imported = try f.service.importItems([
            ImportItem(candidate: f.candidate([source], F.meta("Artemis", "Andy Weir")))
        ])
        guard case .imported(let id, let problems) = imported.outcomes[0] else {
            Issue.record("expected .imported, got \(imported.outcomes)")
            return
        }
        let problem = try #require(problems.first?.reason)
        let bytes = try f.bytes(dest)
        let fieldsBefore = try #require(try f.store.book(id: id)).appOnlyFields
        #expect(Set(fieldsBefore) == allText)
        var calls = 0
        f.service.beforeCommit = { calls += 1 }

        // Still read-only: no problem is reported, because no file is opened.
        let outcomes = try f.service.save([
            try edit(f, id) {
                $0.rating = 5
                $0.tags = ["favourite"]
            }
        ])
        #expect(outcomes == [.saved(bookId: id, refiled: false, appOnlyFields: allText, fileProblems: [])])
        #expect(try f.store.files(bookId: id).map(\.writeProblem) == [problem])

        // Even writable, a rating-only save does not touch it: the old problem stays.
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dest.path)
        let again = try f.service.save([try edit(f, id) { $0.rating = 3 }])
        #expect(again == [.saved(bookId: id, refiled: false, appOnlyFields: allText, fileProblems: [])])
        #expect(try f.store.files(bookId: id).map(\.writeProblem) == [problem])
        #expect(try f.bytes(dest) == bytes)

        let book = try #require(try f.store.book(id: id))
        #expect(book.rating == 3)
        #expect(book.tags == ["favourite"])
        #expect(book.appOnlyFields == fieldsBefore)
        #expect(calls == 2)
        // E10: nothing to restore in the files.
        #expect(try f.snapshot().books[0].fileStates.isEmpty)
    }

    // E4
    @Test func emptiedAuthorFlagsButDoesNotMove() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"))
        let treeBefore = f.libraryTree()

        let outcomes = try f.service.save([try edit(f, id) { $0.metadata.authors = [] }])

        #expect(outcomes == [.saved(bookId: id, refiled: false, appOnlyFields: [], fileProblems: [])])
        #expect(f.libraryTree() == treeBefore)
        let book = try #require(try f.store.book(id: id))
        #expect(book.needsAttention)
        #expect(book.authors == [])
        #expect(book.folderPath == "Andy Weir/Artemis")
        #expect(try f.store.files(bookId: id).map(\.path) == ["Andy Weir/Artemis/Artemis.m4b"])
        #expect(try f.tags(f.lib("Andy Weir/Artemis/Artemis.m4b")).authors == [])
        #expect(try #require(try f.store.lastBatch()).moves.isEmpty)

        // Giving the author back clears the flag, and the book is where it should be.
        let fixed = try f.service.save([try edit(f, id) { $0.metadata.authors = ["Andy Weir"] }])
        #expect(fixed == [.saved(bookId: id, refiled: false, appOnlyFields: [], fileProblems: [])])
        #expect(try f.store.book(id: id)?.needsAttention == false)
        #expect(f.libraryTree() == treeBefore)
    }

    // E4: an emptied title is the other way to become unfileable.
    @Test func emptiedTitleFlagsButDoesNotMove() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"))
        let outcomes = try f.service.save([try edit(f, id) { $0.metadata.title = "  " }])
        guard case .saved(id, false, _, _) = try #require(outcomes.first) else {
            Issue.record("expected an unmoved save, got \(outcomes)")
            return
        }
        #expect(exists(f.lib("Andy Weir/Artemis/Artemis.m4b")))
        let book = try #require(try f.store.book(id: id))
        #expect(book.needsAttention)
        #expect(book.folderPath == "Andy Weir/Artemis")
    }

    // E5
    @Test func fixingAnUnfiledBookFilesIt() throws {
        let f = try F()
        let source = try f.makeM4B("mystery.m4b", tags: F.meta("Old", "Old Author"))
        let imported = try f.service.importItems([
            ImportItem(candidate: f.candidate([source], BookMetadata(title: "Mystery")))
        ])
        guard case .needsAttention(let id) = imported.outcomes[0] else {
            Issue.record("expected .needsAttention, got \(imported.outcomes)")
            return
        }
        #expect(try f.store.files(bookId: id).first?.path.hasPrefix("/") == true)

        let outcomes = try f.service.save([try edit(f, id) { $0.metadata.authors = ["Ann Author"] }])

        #expect(outcomes == [.saved(bookId: id, refiled: true, appOnlyFields: [], fileProblems: [])])
        #expect(f.inboxTree().isEmpty)
        #expect(f.libraryTree() == ["Ann Author", "Ann Author/Mystery", "Ann Author/Mystery/Mystery.m4b"])
        let book = try #require(try f.store.book(id: id))
        #expect(book.needsAttention == false)
        #expect(book.folderPath == "Ann Author/Mystery")
        #expect(try f.store.files(bookId: id).map(\.path) == ["Ann Author/Mystery/Mystery.m4b"])
        var expected = BookMetadata(title: "Mystery", authors: ["Ann Author"])
        expected.durationSeconds = nil
        #expect(try f.tags(f.lib("Ann Author/Mystery/Mystery.m4b")) == expected)
        #expect(try #require(try f.store.lastBatch()).moves == [
            MoveRecord(from: source.path, to: f.lib("Ann Author/Mystery/Mystery.m4b").path, wasCopy: false)
        ])
    }

    // E5: "provided its files exist". With a file gone the edit is still saved, in place.
    @Test func unfiledBookWithAMissingFileStaysUnfiled() throws {
        let f = try F()
        let source = try f.makeM4B("mystery.m4b", tags: F.meta("Old", "Old Author"))
        let imported = try f.service.importItems([
            ImportItem(candidate: f.candidate([source], BookMetadata(title: "Mystery")))
        ])
        guard case .needsAttention(let id) = imported.outcomes[0] else {
            Issue.record("expected .needsAttention, got \(imported.outcomes)")
            return
        }
        let rowsBefore = try f.store.files(bookId: id).map(\.path)
        try FileManager.default.removeItem(at: source)

        let outcomes = try f.service.save([try edit(f, id) { $0.metadata.authors = ["Ann Author"] }])

        guard case .saved(id, false, _, let problems) = try #require(outcomes.first) else {
            Issue.record("expected an unmoved save, got \(outcomes)")
            return
        }
        #expect(problems.map(\.file) == ["mystery.m4b"])
        #expect(f.libraryTree().isEmpty)
        let book = try #require(try f.store.book(id: id))
        #expect(book.authors == ["Ann Author"])
        #expect(book.needsAttention)
        #expect(book.folderPath == nil)
        #expect(try f.store.files(bookId: id).map(\.path) == rowsBefore)
    }

    // E6
    @Test func moveFailureLeavesBookUnchanged() throws {
        let f = try F()
        let id = try importM4B(f, F.fullMeta("Artemis", "Andy Weir"), cover: F.jpeg)
        let path = "Andy Weir/The Series/2 - Artemis/Artemis.m4b"
        let occupied = try touch(f.lib("Andrew Weir/The Series/2 - Artemis/Artemis.m4b"), "in the way")
        let bytes = try f.bytes(f.lib(path))
        let bookBefore = try f.store.book(id: id)
        let rowsBefore = try f.store.files(bookId: id)
        let batchBefore = try f.store.lastBatch()
        let treeBefore = f.libraryTree()
        let hiddenBefore = f.hiddenTree().filter { !$0.hasPrefix("undo") }

        let outcomes = try f.service.save([
            try edit(f, id, cover: .set(F.png)) {
                $0.metadata.authors = ["Andrew Weir"]
                $0.rating = 5
            }
        ])

        #expect(outcomes.count == 1)
        guard case .failed(id, let reason) = outcomes[0] else {
            Issue.record("expected .failed, got \(outcomes)")
            return
        }
        #expect(reason.contains("already exists"))
        #expect(reason.contains("Artemis.m4b"))
        #expect(try f.store.book(id: id) == bookBefore)
        #expect(try f.store.files(bookId: id) == rowsBefore)
        #expect(try f.bytes(f.lib(path)) == bytes)
        #expect(f.libraryTree() == treeBefore)
        #expect(try read(occupied) == "in the way")
        #expect(f.service.covers.image(for: id) == F.jpeg)
        #expect(f.hiddenTree().filter { !$0.hasPrefix("undo") } == hiddenBefore)
        // E12
        #expect(try f.store.lastBatch() == batchBefore)
    }

    // E7, E9
    @Test func lockedFileSavesInAppOnly() throws {
        let f = try F()
        let fm = FileManager.default
        let id = try importM4B(f, F.fullMeta("Artemis", "Andy Weir"))
        let dest = f.lib("Andy Weir/The Series/2 - Artemis/Artemis.m4b")
        #expect(try #require(try f.store.book(id: id)).appOnlyFields == [])
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dest.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dest.path) }
        let bytes = try f.bytes(dest)

        let outcomes = try f.service.save([try edit(f, id) { $0.metadata.genres = ["Thriller"] }])

        guard case .saved(id, false, let fields, let problems) = try #require(outcomes.first) else {
            Issue.record("expected .saved, got \(outcomes)")
            return
        }
        // The database is updated all the same; the file is flagged.
        #expect(fields == allText)
        #expect(problems.map(\.file) == ["Artemis.m4b"])
        let reason = try #require(problems.first?.reason)
        #expect(reason.contains("locked"))
        var book = try #require(try f.store.book(id: id))
        #expect(book.genres == ["Thriller"])
        #expect(Set(book.appOnlyFields) == allText)
        #expect(try f.store.files(bookId: id).map(\.writeProblem) == [reason])
        #expect(try f.bytes(dest) == bytes)
        #expect(try f.snapshot().books[0].fileStates.isEmpty)

        // Writable again: the next save that writes tags clears the problem.
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dest.path)
        let again = try f.service.save([try edit(f, id) { $0.metadata.genres = ["Heist"] }])
        #expect(again == [.saved(bookId: id, refiled: false, appOnlyFields: [], fileProblems: [])])
        book = try #require(try f.store.book(id: id))
        #expect(book.appOnlyFields == [])
        #expect(try f.store.files(bookId: id).map(\.writeProblem) == [nil])
        #expect(try f.tags(dest).genreSource == "Heist")
    }

    // E8, E9
    @Test func coverSetRemoveKeep() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"), cover: F.jpeg)
        let file = f.lib("Andy Weir/Artemis/Artemis.m4b")
        #expect(f.service.covers.image(for: id) == F.jpeg)

        // .set: stored and written into the file.
        var outcomes = try f.service.save([try edit(f, id, cover: .set(F.png))])
        #expect(outcomes == [.saved(bookId: id, refiled: false, appOnlyFields: [], fileProblems: [])])
        #expect(f.service.covers.image(for: id) == F.png)
        #expect(try f.io.read(file).cover == F.png)

        // .keep: neither changes, though the tags are rewritten.
        outcomes = try f.service.save([try edit(f, id) { $0.metadata.genres = ["Thriller"] }])
        #expect(outcomes == [.saved(bookId: id, refiled: false, appOnlyFields: [], fileProblems: [])])
        #expect(f.service.covers.image(for: id) == F.png)
        #expect(try f.io.read(file).cover == F.png)
        #expect(try f.tags(file).genreSource == "Thriller")

        // .remove: gone from the store and from the file.
        outcomes = try f.service.save([try edit(f, id, cover: .remove)])
        #expect(outcomes == [.saved(bookId: id, refiled: false, appOnlyFields: [], fileProblems: [])])
        #expect(f.service.covers.url(for: id) == nil)
        #expect(try f.io.read(file).cover == nil)
        #expect(try f.tags(file).genreSource == "Thriller")

        // E9: a PDF cannot hold a cover, so a set cover is in the app only...
        let pdfId = try f.importNew([try f.makePDF("paper.pdf")], F.meta("Paper", "Ann Author"))
        #expect(!(try #require(try f.store.book(id: pdfId)).appOnlyFields.contains(.cover)))
        outcomes = try f.service.save([try edit(f, pdfId, cover: .set(F.jpeg))])
        guard case .saved(pdfId, false, let fields, let problems) = try #require(outcomes.first) else {
            Issue.record("expected .saved, got \(outcomes)")
            return
        }
        #expect(problems.isEmpty)
        #expect(fields.contains(.cover))
        #expect(!fields.contains(.title))
        #expect(f.service.covers.image(for: pdfId) == F.jpeg)
        #expect(try #require(try f.store.book(id: pdfId)).appOnlyFields.contains(.cover))

        // ...and with .keep that membership is carried over when the tags are rewritten.
        outcomes = try f.service.save([try edit(f, pdfId) { $0.metadata.genres = ["Essays"] }])
        guard case .saved(pdfId, false, let kept, _) = try #require(outcomes.first) else {
            Issue.record("expected .saved, got \(outcomes)")
            return
        }
        #expect(kept.contains(.cover))
        #expect(f.service.covers.image(for: pdfId) == F.jpeg)

        // ...until the cover is removed.
        outcomes = try f.service.save([try edit(f, pdfId, cover: .remove)])
        guard case .saved(pdfId, false, let removed, _) = try #require(outcomes.first) else {
            Issue.record("expected .saved, got \(outcomes)")
            return
        }
        #expect(!removed.contains(.cover))
        #expect(f.service.covers.url(for: pdfId) == nil)
    }

    // E2
    @Test func durationAndPageCountAreNotEditable() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"))
        let pdfId = try f.importNew([try f.makePDF("paper.pdf", pages: 4)], F.meta("Paper", "Ann Author"))
        let before = try #require(try f.store.book(id: id))
        let pdfBefore = try #require(try f.store.book(id: pdfId))
        #expect(pdfBefore.pageCount == 4)
        let batchBefore = try f.store.lastBatch()

        // Changing only those is no change at all.
        let outcomes = try f.service.save([
            try edit(f, id) {
                $0.metadata.durationSeconds = 5
                $0.metadata.pageCount = 999
            },
            try edit(f, pdfId) {
                $0.metadata.durationSeconds = 5
                $0.metadata.pageCount = nil
            },
        ])
        #expect(outcomes == [
            .saved(bookId: id, refiled: false, appOnlyFields: [], fileProblems: []),
            .saved(bookId: pdfId, refiled: false, appOnlyFields: Set(pdfBefore.appOnlyFields), fileProblems: []),
        ])
        #expect(try f.store.book(id: id) == before)
        #expect(try f.store.book(id: pdfId) == pdfBefore)
        #expect(try f.store.lastBatch() == batchBefore)

        // Alongside a real change they are still ignored.
        _ = try f.service.save([
            try edit(f, id) {
                $0.metadata.genres = ["Thriller"]
                $0.metadata.durationSeconds = 5
                $0.metadata.pageCount = 999
            }
        ])
        let after = try #require(try f.store.book(id: id))
        #expect(after.genres == ["Thriller"])
        #expect(after.durationSeconds == before.durationSeconds)
        #expect(after.pageCount == nil)
    }

    // E1, E10
    @Test func bulkEditIsOneBatch() throws {
        let f = try F()
        let a = try importM4B(f, F.meta("Book A", "Author A"), name: "a.m4b")
        let b = try importM4B(f, F.meta("Book B", "Author B"), name: "b.m4b")
        let c = try importM4B(f, F.meta("Book C", "Author C"), name: "c.m4b")
        try touch(f.lib("Author Z/Book B/Book B.m4b"))
        let bBefore = try f.store.book(id: b)
        var commits = 0
        f.service.beforeCommit = { commits += 1 }

        let outcomes = try f.service.save([
            try edit(f, a) { $0.metadata.authors = ["Author A2"] },
            try edit(f, b) { $0.metadata.authors = ["Author Z"] },
            try edit(f, c) { $0.rating = 4 },
        ])

        #expect(outcomes.count == 3)
        #expect(outcomes[0] == .saved(bookId: a, refiled: true, appOnlyFields: [], fileProblems: []))
        guard case .failed(b, let reason) = outcomes[1] else {
            Issue.record("expected .failed for the second edit, got \(outcomes[1])")
            return
        }
        #expect(reason.contains("already exists"))
        #expect(outcomes[2] == .saved(bookId: c, refiled: false, appOnlyFields: [], fileProblems: []))
        #expect(try f.store.book(id: b) == bBefore)
        #expect(exists(f.lib("Author B/Book B/Book B.m4b")))
        #expect(exists(f.lib("Author A2/Book A/Book A.m4b")))
        #expect(try f.store.book(id: c)?.rating == 4)

        #expect(commits == 1)
        let batch = try #require(try f.store.lastBatch())
        #expect(batch.label == "Edit 2 books")
        #expect(batch.moves == [
            MoveRecord(
                from: f.lib("Author A/Book A/Book A.m4b").path,
                to: f.lib("Author A2/Book A/Book A.m4b").path, wasCopy: false)
        ])
        #expect(try batchCount(f) == 1)
        let snapshot = try f.snapshot()
        #expect(snapshot.books.map(\.bookId) == [a, c])
    }

    // E1
    @Test func unknownBookFailsAndRepeatedBookFailsTheSecond() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"))
        var ghost = Book(metadata: F.meta("Ghost", "Nobody"))
        ghost.id = 987_654

        let outcomes = try f.service.save([
            BookEdit(book: ghost),
            try edit(f, id) { $0.rating = 2 },
            try edit(f, id) { $0.rating = 5 },
        ])

        guard case .failed(987_654, let reason) = outcomes[0] else {
            Issue.record("expected .failed, got \(outcomes[0])")
            return
        }
        #expect(reason.contains("not in the library"))
        #expect(outcomes[1] == .saved(bookId: id, refiled: false, appOnlyFields: [], fileProblems: []))
        guard case .failed(id, _) = outcomes[2] else {
            Issue.record("expected .failed for the repeat, got \(outcomes[2])")
            return
        }
        #expect(try f.store.book(id: id)?.rating == 2)
        #expect(try f.store.lastBatch()?.label == "Edit Artemis")
    }

    // E10
    @Test func snapshotHoldsWhatUndoNeeds() throws {
        let f = try F()
        let id = try importM4B(f, F.fullMeta("Artemis", "Andy Weir"), cover: F.jpeg)
        let oldFile = f.lib("Andy Weir/The Series/2 - Artemis/Artemis.m4b")
        let bookBefore = try #require(try f.store.book(id: id))
        let filesBefore = try f.store.files(bookId: id)
        let tagsBefore = try f.io.read(oldFile).metadata
        let trackBefore = try f.trackTags(oldFile)

        _ = try f.service.save([
            try edit(f, id, cover: .set(F.png)) {
                $0.metadata.title = "Artemis Rising"
                $0.metadata.genres = ["Thriller"]
                $0.rating = 5
            }
        ])

        let newFile = f.lib("Andy Weir/The Series/2 - Artemis Rising/Artemis Rising.m4b")
        let snapshot = try f.snapshot()
        #expect(snapshot.books.count == 1)
        let saved = snapshot.books[0]
        #expect(saved.bookId == id)
        #expect(saved.bookBefore == bookBefore)
        #expect(saved.filesBefore == filesBefore)
        #expect(saved.fileStates.count == 1)
        let state = try #require(saved.fileStates.first)
        #expect(state.pathAfter == newFile.path)
        #expect(state.metadataBefore == tagsBefore)
        #expect(state.metadataBefore.title == "Artemis")
        #expect(state.trackBefore == trackBefore)
        let folder = f.service.layout.undoFolder.appendingPathComponent(snapshot.token)
        guard case .saved(let coverName)? = state.coverBefore else {
            Issue.record("expected a saved cover, got \(String(describing: state.coverBefore))")
            return
        }
        #expect(try f.bytes(folder.appendingPathComponent(coverName)) == F.jpeg.data)
        let storedName = try #require(saved.storedCoverBefore)
        #expect(try f.bytes(folder.appendingPathComponent(storedName)) == F.jpeg.data)
        // The store and the file now have the new cover.
        #expect(f.service.covers.image(for: id) == F.png)
        #expect(try f.io.read(newFile).cover == F.png)
    }

    // E10: with the cover kept, no cover is recorded on the file states; a file that had
    // no cover records exactly that when one is set.
    @Test func snapshotCoverStatesFollowTheChange() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"))
        _ = try f.service.save([try edit(f, id) { $0.metadata.genres = ["Thriller"] }])
        var saved = try f.snapshot().books[0]
        #expect(saved.fileStates.map(\.coverBefore) == [nil])
        #expect(saved.storedCoverBefore == nil)

        _ = try f.service.save([try edit(f, id, cover: .set(F.png))])
        saved = try f.snapshot().books[0]
        #expect(saved.fileStates.map(\.coverBefore) == [CoverBefore.none])
        #expect(saved.storedCoverBefore == nil)  // it had none
    }

    // E11
    @Test func commitFailureRollsBack() throws {
        let f = try F()
        let id = try importM4B(f, F.fullMeta("Artemis", "Andy Weir"), cover: F.jpeg)
        let other = try importM4B(f, F.meta("Other", "Ann Author"), name: "o.m4b")
        let file = f.lib("Andy Weir/The Series/2 - Artemis/Artemis.m4b")
        try f.seedTrackTitle("Own Track Name", in: file)
        let tagsBefore = try f.tags(file)
        let booksBefore = try f.store.books()
        let rowsBefore = try f.store.files(bookId: id)
        let batchBefore = try f.store.lastBatch()
        let treeBefore = f.libraryTree()
        let hiddenBefore = f.hiddenTree()
        var movedBeforeCommit = false
        f.service.beforeCommit = {
            movedBeforeCommit = exists(f.lib("Andrew Weir/The Series/2 - Artemis/Artemis.m4b"))
            throw Boom()
        }

        #expect(throws: Boom.self) {
            try f.service.save([
                try edit(f, id, cover: .set(F.png)) {
                    $0.metadata.authors = ["Andrew Weir"]
                    $0.metadata.genres = ["Thriller"]
                },
                try edit(f, other, cover: .remove) { $0.rating = 1 },
            ])
        }

        #expect(movedBeforeCommit)
        // Files are back in the old folder, with their old tags and cover.
        #expect(f.libraryTree() == treeBefore)
        #expect(try f.tags(file) == tagsBefore)
        #expect(try f.io.read(file).cover == F.jpeg)
        #expect(try f.trackTags(file) == TrackTags(title: "Own Track Name", number: nil))
        // Rows unchanged, stored cover as before, journal and undo data as before.
        #expect(try f.store.books() == booksBefore)
        #expect(try f.store.files(bookId: id) == rowsBefore)
        #expect(f.service.covers.image(for: id) == F.jpeg)
        #expect(try f.store.lastBatch() == batchBefore)
        #expect(f.hiddenTree() == hiddenBefore)
    }

    // E12
    @Test func nothingSavedLeavesTheJournalAlone() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"), cover: F.jpeg)
        try touch(f.lib("Andrew Weir/Artemis/Artemis.m4b"))
        let batchBefore = try f.store.lastBatch()
        let hiddenBefore = f.hiddenTree()
        var commits = 0
        f.service.beforeCommit = { commits += 1 }
        var ghost = Book(metadata: F.meta("Ghost", "Nobody"))
        ghost.id = 555

        // One edit fails, one names no book, one changes nothing, and an empty call.
        let outcomes = try f.service.save([
            try edit(f, id, cover: .set(F.png)) { $0.metadata.authors = ["Andrew Weir"] },
            BookEdit(book: ghost),
        ])
        let unchanged = try f.service.save([try edit(f, id)])
        let none = try f.service.save([])

        #expect(outcomes.count == 2)
        guard case .failed(id, _) = outcomes[0], case .failed(555, _) = outcomes[1] else {
            Issue.record("expected two failures, got \(outcomes)")
            return
        }
        #expect(unchanged == [.saved(bookId: id, refiled: false, appOnlyFields: [], fileProblems: [])])
        #expect(none.isEmpty)
        #expect(commits == 0)
        #expect(try f.store.lastBatch() == batchBefore)
        #expect(f.hiddenTree() == hiddenBefore)
    }

    // E13
    @Test func olderUndoDataIsRemoved() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"), cover: F.jpeg)
        func undoFolders() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: f.service.layout.undoFolder.path)) ?? []).sorted()
        }

        _ = try f.service.save([try edit(f, id, cover: .set(F.png))])
        let first = try f.snapshot().token
        #expect(undoFolders() == [first])

        _ = try f.service.save([try edit(f, id, cover: .set(F.jpeg))])
        let second = try f.snapshot().token

        #expect(second != first)
        #expect(undoFolders() == [second])
        #expect(try batchCount(f) == 1)
    }
}
