import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

@Suite struct LibraryServiceUndoTests {
    typealias F = LibraryFixture

    /// Everything about the library that undo must put back, in one comparable value.
    struct State: Equatable {
        var books: [Book]
        var files: [[BookFile]]
        var library: [String]
        var inbox: [String]
        var covers: [CoverImage?]
    }

    func state(_ f: F) throws -> State {
        let books = try f.store.books().sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        return State(
            books: books,
            files: try books.map { try f.store.files(bookId: try #require($0.id)) },
            library: f.libraryTree(),
            inbox: f.inboxTree(),
            covers: try books.map { f.service.covers.image(for: try #require($0.id)) })
    }

    func importM4B(_ f: F, _ metadata: BookMetadata, cover: CoverImage? = nil, name: String = "in.m4b") throws -> Int64 {
        try f.importNew([try f.makeM4B(name, tags: F.meta("Old", "Old Author"), cover: cover)], metadata)
    }

    func edit(_ f: F, _ id: Int64, cover: CoverChange = .keep, _ change: (inout BookEdit) -> Void = { _ in }) throws -> BookEdit {
        var edit = BookEdit(book: try #require(try f.store.book(id: id)), cover: cover)
        change(&edit)
        return edit
    }

    /// U8, and U6's deleted undo folder.
    func expectNothingLeftToUndo(_ f: F, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(try f.service.undoLabel() == nil, sourceLocation: sourceLocation)
        #expect(throws: LibraryError.nothingToUndo, sourceLocation: sourceLocation) { try f.service.undoLast() }
        #expect(try f.store.lastBatch() == nil, sourceLocation: sourceLocation)
        #expect(!f.hiddenTree().contains { $0.hasPrefix("undo") }, sourceLocation: sourceLocation)
    }

    // U1
    @Test func nothingToUndo() throws {
        let f = try F()
        #expect(try f.service.undoLabel() == nil)
        #expect(throws: LibraryError.nothingToUndo) { try f.service.undoLast() }
    }

    // U3–U6, U8
    @Test func undoImportInMoveMode() throws {
        let f = try F()
        let oneTags = F.fullMeta("First Original", "First Writer")
        let twoTags = F.meta("Second Original", "Second Writer")
        let m4b = try f.makeM4B("one.m4b", tags: oneTags, cover: F.jpeg)
        try f.seedTrackTitle("Own Track Name", in: m4b)
        let parts = try f.makeMP3Parts(folder: "two", tags: twoTags)
        let inboxBefore = f.inboxTree()
        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([m4b], F.meta("One", "Ann Author")), cover: .set(F.png)),
            ImportItem(candidate: f.candidate(parts, F.meta("Two", "Ben Author"))),
        ])
        _ = try f.importedId(result.outcomes[0])
        _ = try f.importedId(result.outcomes[1])
        // The import really did overwrite the tags.
        #expect(try f.tags(f.lib("Ann Author/One/One.m4b")).title == "One")
        #expect(try f.track(f.lib("Ben Author/Two/01 - Two.mp3")) == "1/2")
        #expect(try f.service.undoLabel() == "Import 2 books")

        let label = try f.service.undoLast()

        #expect(label == "Import 2 books")
        // Files are back at their original paths, with their original tags and cover.
        #expect(f.inboxTree() == inboxBefore)
        #expect(try f.tags(m4b) == oneTags)
        #expect(try f.io.read(m4b).cover == F.jpeg)
        #expect(try f.trackTags(m4b) == TrackTags(title: "Own Track Name", number: nil))
        for part in parts {
            #expect(try f.tags(part) == twoTags)
            #expect(try f.track(part) == nil)
        }
        // No rows, no stored covers, no book folders.
        #expect(try f.store.books().isEmpty)
        let fileRows = try f.store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookFile") }
        #expect(fileRows == 0)
        #expect(f.libraryTree().isEmpty)
        #expect(f.hiddenTree().filter { $0.hasPrefix("covers/") }.isEmpty)
        try expectNothingLeftToUndo(f)
    }

    // U3, U5
    @Test func undoImportInCopyMode() throws {
        let f = try F()
        let source = try f.makeM4B("keepme.m4b", tags: F.meta("Original", "Writer"), cover: F.jpeg)
        let bytes = try f.bytes(source)
        _ = try f.importNew([source], F.fullMeta("Copied", "Ann Author"), cover: .set(F.png), mode: .copy)
        #expect(!f.libraryTree().isEmpty)

        #expect(try f.service.undoLast() == "Import 1 book")

        #expect(f.libraryTree().isEmpty)  // the copy is deleted
        #expect(try f.bytes(source) == bytes)  // the original was never touched
        #expect(f.inboxTree() == ["keepme.m4b"])
        #expect(try f.store.books().isEmpty)
        #expect(f.hiddenTree().filter { $0.hasPrefix("covers/") }.isEmpty)
        try expectNothingLeftToUndo(f)
    }

    // U5
    @Test(arguments: [TransferMode.move, .copy])
    func undoAddToExistingBook(mode: TransferMode) throws {
        let f = try F()
        let id = try f.importNew(
            [try f.makeMP3("one.mp3", tags: F.meta("Old", "Old Author"))], F.meta("Dune", "Frank Herbert"))
        let single = f.lib("Frank Herbert/Dune/Dune.mp3")
        try f.seedTrackTitle("My Own Track Name", in: single)
        let second = try f.makeMP3("two.mp3", tags: F.meta("Other", "Other Author"))
        let secondBytes = try f.bytes(second)
        let before = try state(f)
        let singleTags = try f.tags(single)

        let result = try f.service.importItems(
            [ImportItem(candidate: f.candidate([second], F.meta("x", "y")), target: .existing(bookId: id))],
            options: ImportOptions(mode: mode))
        #expect(result.outcomes == [.imported(bookId: id, fileProblems: [])])
        #expect(try f.track(f.lib("Frank Herbert/Dune/01 - Dune.mp3")) == "1/2")

        #expect(try f.service.undoLast() == "Import 1 book")

        // One file again, under its original name, with no track number; the added
        // file is back in the inbox as it was.
        #expect(try state(f) == before)
        #expect(f.libraryTree() == ["Frank Herbert", "Frank Herbert/Dune", "Frank Herbert/Dune/Dune.mp3"])
        #expect(try f.trackTags(single) == TrackTags(title: "My Own Track Name", number: nil))
        #expect(try f.tags(single) == singleTags)
        #expect(f.inboxTree() == ["two.mp3"])
        #expect(try f.tags(second) == F.meta("Other", "Other Author"))
        if mode == .copy { #expect(try f.bytes(second) == secondBytes) }
        try expectNothingLeftToUndo(f)
    }

    // U5, U6: a book that gained its stored cover from an added file loses it again.
    @Test func undoAddToExistingRemovesTheCoverItBrought() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"))
        let before = try state(f)
        let epub = try f.makeEPUB("new.epub")
        _ = try f.service.importItems([
            ImportItem(candidate: f.candidate([epub], F.meta("x", "y")), target: .existing(bookId: id))
        ])
        #expect(f.service.covers.image(for: id) == F.jpeg)

        try f.service.undoLast()

        var expected = before
        expected.inbox = ["new.epub"]
        #expect(try state(f) == expected)
        #expect(f.service.covers.url(for: id) == nil)
        #expect(try f.tags(epub).title == "Original Title")
    }

    // U3–U6
    @Test func undoEditRestoresEverything() throws {
        let f = try F()
        let id = try importM4B(f, F.fullMeta("Artemis", "Andy Weir"), cover: F.jpeg)
        let file = f.lib("Andy Weir/The Series/2 - Artemis/Artemis.m4b")
        try f.seedTrackTitle("Own Track Name", in: file)
        let before = try state(f)
        let tagsBefore = try f.tags(file)

        let outcomes = try f.service.save([
            try edit(f, id, cover: .set(F.png)) {
                $0.metadata.authors = ["Andrew Weir"]
                $0.metadata.genres = ["Thriller"]
                $0.rating = 5
                $0.tags = ["favourite"]
            }
        ])
        #expect(outcomes == [.saved(bookId: id, refiled: true, appOnlyFields: [], fileProblems: [])])
        #expect(try state(f) != before)
        #expect(try f.service.undoLabel() == "Edit Artemis")

        #expect(try f.service.undoLast() == "Edit Artemis")

        // Files back in the old folder, rows equal to before (ids included), stored cover as before.
        #expect(try state(f) == before)
        #expect(before.covers == [F.jpeg])
        #expect(try f.tags(file) == tagsBefore)
        #expect(try f.io.read(file).cover == F.jpeg)
        #expect(try f.trackTags(file) == TrackTags(title: "Own Track Name", number: nil))
        try expectNothingLeftToUndo(f)
    }

    @Test func undoBulkEdit() throws {
        let f = try F()
        let a = try importM4B(f, F.meta("Book A", "Author A"), cover: F.jpeg, name: "a.m4b")
        let b = try importM4B(f, F.meta("Book B", "Author B"), name: "b.m4b")
        let c = try importM4B(f, F.meta("Book C", "Author C"), name: "c.m4b")
        let before = try state(f)
        let aTags = try f.tags(f.lib("Author A/Book A/Book A.m4b"))

        let outcomes = try f.service.save([
            try edit(f, a, cover: .remove) { $0.metadata.authors = ["Author Z"] },
            try edit(f, b) { $0.metadata.title = "Book B Revised" },
            try edit(f, c) { $0.rating = 4 },
        ])
        #expect(outcomes.count == 3)
        #expect(f.service.covers.url(for: a) == nil)

        #expect(try f.service.undoLast() == "Edit 3 books")

        #expect(try state(f) == before)
        #expect(try f.tags(f.lib("Author A/Book A/Book A.m4b")) == aTags)
        #expect(try f.io.read(f.lib("Author A/Book A/Book A.m4b")).cover == F.jpeg)
        #expect(try f.tags(f.lib("Author B/Book B/Book B.m4b")).title == "Book B")
        try expectNothingLeftToUndo(f)
    }

    // Undo after a rating-only save: no moves, no file states, the rating comes back.
    @Test func undoRatingOnlySave() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"), cover: F.jpeg)
        let file = f.lib("Andy Weir/Artemis/Artemis.m4b")
        let before = try state(f)
        let bytes = try f.bytes(file)
        _ = try f.service.save([
            try edit(f, id) {
                $0.rating = 5
                $0.tags = ["favourite"]
            }
        ])
        #expect(try f.store.book(id: id)?.rating == 5)
        let batch = try #require(try f.store.lastBatch())
        #expect(batch.moves.isEmpty)
        #expect(try f.snapshot().books[0].fileStates.isEmpty)

        try f.service.undoLast()

        #expect(try state(f) == before)
        #expect(try f.store.book(id: id)?.rating == 0)
        #expect(try f.bytes(file) == bytes)  // never opened
        try expectNothingLeftToUndo(f)
    }

    // Undo after a save in which a file was locked leaves that file untouched, and puts
    // back appOnlyFields and writeProblem exactly.
    @Test func undoSaveWithLockedFileLeavesTheFileAlone() throws {
        let f = try F()
        let fm = FileManager.default
        let m4b = try f.makeM4B("a.m4b", tags: F.meta("x", "y"))
        let epub = try f.makeEPUB("a.epub")
        let id = try f.importNew([m4b, epub], F.fullMeta("Artemis", "Andy Weir"))
        let folder = "Andy Weir/The Series/2 - Artemis"
        let audio = f.lib("\(folder)/Artemis.m4b")
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: audio.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: audio.path) }
        let before = try state(f)
        let audioBytes = try f.bytes(audio)
        let epubTags = try f.tags(f.lib("\(folder)/Artemis.epub"))

        let outcomes = try f.service.save([try edit(f, id) { $0.metadata.genres = ["Thriller"] }])
        guard case .saved(id, false, let fields, let problems) = try #require(outcomes.first) else {
            Issue.record("expected .saved, got \(outcomes)")
            return
        }
        #expect(problems.map(\.file) == ["Artemis.m4b"])
        #expect(fields.contains(.narrators))
        #expect(try f.store.files(bookId: id).map { $0.writeProblem != nil } == [true, false])
        #expect(try f.tags(f.lib("\(folder)/Artemis.epub")).genreSource == "Thriller")

        // Writable again by the time of the undo: it must still not be written.
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: audio.path)
        try f.service.undoLast()

        #expect(try f.bytes(audio) == audioBytes)
        #expect(try f.tags(f.lib("\(folder)/Artemis.epub")) == epubTags)
        #expect(try state(f) == before)
        #expect(try #require(try f.store.book(id: id)).appOnlyFields == [])
        #expect(try f.store.files(bookId: id).map(\.writeProblem) == [nil, nil])
    }

    // Undo restores appOnlyFields, writeProblem, needsAttention and folderPath exactly.
    @Test func undoRestoresFlagsAndProblemsExactly() throws {
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
        guard case .imported(let id, _) = imported.outcomes[0] else {
            Issue.record("expected .imported, got \(imported.outcomes)")
            return
        }
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dest.path)
        let before = try state(f)
        #expect(before.files[0][0].writeProblem != nil)
        #expect(before.books[0].appOnlyFields.count == MetadataField.allCases.count - 1)
        let tagsBefore = try f.tags(dest)

        // A save that clears the problem and the app-only fields...
        _ = try f.service.save([try edit(f, id) { $0.metadata.genres = ["Thriller"] }])
        #expect(try #require(try f.store.book(id: id)).appOnlyFields == [])
        #expect(try f.store.files(bookId: id).map(\.writeProblem) == [nil])
        try f.service.undoLast()
        // ...is undone to exactly what was there, in the database and in the file.
        #expect(try state(f) == before)
        #expect(try f.tags(dest) == tagsBefore)

        // A save that flags the book (no author) and keeps its folder...
        _ = try f.service.save([try edit(f, id) { $0.metadata.authors = [] }])
        #expect(try f.store.book(id: id)?.needsAttention == true)
        try f.service.undoLast()
        #expect(try state(f) == before)
        #expect(before.books[0].needsAttention == false)
        #expect(before.books[0].folderPath == "Andy Weir/Artemis")
        try expectNothingLeftToUndo(f)
    }

    // U4
    @Test func undoIsRetryableWhenBlocked() throws {
        // What a clean undo leaves, for comparison.
        func prepare() throws -> (F, Int64, URL) {
            let f = try F()
            let id = try importM4B(f, F.fullMeta("Artemis", "Andy Weir"), cover: F.jpeg)
            let file = f.lib("Andy Weir/The Series/2 - Artemis/Artemis.m4b")
            try f.seedTrackTitle("Own Track Name", in: file)
            return (f, id, file)
        }
        func change(_ f: F, _ id: Int64) throws {
            _ = try f.service.save([
                try edit(f, id, cover: .set(F.png)) {
                    $0.metadata.authors = ["Andrew Weir"]
                    $0.metadata.genres = ["Thriller"]
                }
            ])
        }
        let (clean, cleanId, cleanFile) = try prepare()
        try change(clean, cleanId)
        try clean.service.undoLast()
        let cleanState = try state(clean)
        let cleanTags = try clean.io.read(cleanFile)
        let cleanTrack = try clean.trackTags(cleanFile)

        let (f, id, file) = try prepare()
        let before = try state(f)
        try change(f, id)
        let after = try state(f)
        let batch = try #require(try f.store.lastBatch())
        let moved = f.lib("Andrew Weir/The Series/2 - Artemis/Artemis.m4b")
        // Something now sits where the moved file must return.
        let stray = try touch(file, "in the way")

        #expect {
            try f.service.undoLast()
        } throws: { error in
            guard case LibraryError.undoBlocked(let reason)? = error as? LibraryError else { return false }
            return reason.contains("Artemis.m4b")
        }

        // Rows and journal are unchanged; the file is still where the edit put it.
        var blocked = try state(f)
        #expect(blocked.books == after.books)
        #expect(blocked.files == after.files)
        #expect(blocked.covers == after.covers)
        #expect(try f.store.lastBatch() == batch)
        #expect(try f.service.undoLabel() == "Edit Artemis")
        #expect(exists(moved))
        #expect(try read(stray) == "in the way")
        // A blocked undo changes nothing: the tags inside the file are still the edit's.
        #expect(try f.tags(moved).genreSource == "Thriller")
        #expect(try f.tags(moved).authors == ["Andrew Weir"])
        #expect(try f.io.read(moved).cover == F.png)

        try FileManager.default.removeItem(at: stray)
        #expect(try f.service.undoLast() == "Edit Artemis")

        // Exactly what a clean undo leaves, tags included.
        blocked = try state(f)
        #expect(blocked == before)
        #expect(blocked.library == cleanState.library)
        #expect(blocked.covers == cleanState.covers)
        #expect(try f.io.read(file) == cleanTags)
        #expect(try f.trackTags(file) == cleanTrack)
        #expect(try f.io.read(file).cover == F.jpeg)
        try expectNothingLeftToUndo(f)
    }

    // U2: tags and files are put back before the commit; covers and undo data after it.
    @Test func undoWorksInOrderAndSurvivesACommitFailure() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"), cover: F.jpeg)
        let file = f.lib("Andy Weir/Artemis/Artemis.m4b")
        let before = try state(f)
        _ = try f.service.save([
            try edit(f, id, cover: .set(F.png)) { $0.metadata.authors = ["Andrew Weir"] }
        ])
        let after = try state(f)
        let token = try f.snapshot().token

        var seen: [String] = []
        f.service.beforeCommit = {
            // (a) and (b) are done...
            if exists(file) { seen.append("file back") }
            if try f.tags(file).authors == ["Andy Weir"] { seen.append("tags back") }
            if try f.io.read(file).cover == F.jpeg { seen.append("file cover back") }
            // ...(c) and (d) are not.
            if try f.store.book(id: id)?.authors == ["Andrew Weir"] { seen.append("row not yet") }
            if f.service.covers.image(for: id) == F.png { seen.append("stored cover not yet") }
            if f.hiddenTree().contains("undo/\(token)") { seen.append("undo data not yet") }
            throw Boom()
        }
        #expect(throws: Boom.self) { try f.service.undoLast() }
        #expect(seen == [
            "file back", "tags back", "file cover back", "row not yet", "stored cover not yet", "undo data not yet",
        ])
        // The database and journal still describe the edit; undo can be tried again.
        #expect(try state(f).books == after.books)
        #expect(try f.service.undoLabel() == "Edit Artemis")

        f.service.beforeCommit = nil
        try f.service.undoLast()
        #expect(try state(f) == before)
        try expectNothingLeftToUndo(f)
    }

    // U7
    @Test func undoOfLegacyBatch() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"))
        let booksBefore = try f.store.books()
        let rowsBefore = try f.store.files(bookId: id)
        let loose = try touch(f.inbox.appendingPathComponent("loose.txt"), "moved by hand")
        let parked = f.lib("Parked/loose.txt")
        let records = try Organiser().transfer([PlannedMove(from: loose, to: parked)], mode: .move)
        try f.store.recordBatch(label: "Legacy move", moves: records)
        #expect(try f.service.undoLabel() == "Legacy move")

        #expect(try f.service.undoLast() == "Legacy move")

        #expect(try read(loose) == "moved by hand")
        #expect(!exists(parked))
        #expect(!exists(f.lib("Parked")))  // pruned
        // Nothing else is touched.
        #expect(try f.store.books() == booksBefore)
        #expect(try f.store.files(bookId: id) == rowsBefore)
        try expectNothingLeftToUndo(f)
    }

    // U4 applies to a legacy batch too.
    @Test func blockedLegacyUndoKeepsTheJournal() throws {
        let f = try F()
        let loose = try touch(f.inbox.appendingPathComponent("loose.txt"), "moved by hand")
        let records = try Organiser().transfer([PlannedMove(from: loose, to: f.lib("Parked/loose.txt"))], mode: .move)
        try f.store.recordBatch(label: "Legacy move", moves: records)
        try touch(loose, "in the way")

        #expect { try f.service.undoLast() } throws: { error in
            if case LibraryError.undoBlocked? = error as? LibraryError { return true }
            return false
        }
        #expect(try f.service.undoLabel() == "Legacy move")
        #expect(exists(f.lib("Parked/loose.txt")))
    }

    @Test func undoAfterNeedsAttentionImport() throws {
        let f = try F()
        let source = try f.makeM4B("mystery.m4b", tags: F.meta("Old", "Old Author"), cover: F.jpeg)
        let bytes = try f.bytes(source)
        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([source], BookMetadata(title: "Mystery")))
        ])
        guard case .needsAttention(let id) = result.outcomes[0] else {
            Issue.record("expected .needsAttention, got \(result.outcomes)")
            return
        }
        #expect(f.service.covers.image(for: id) == F.jpeg)

        #expect(try f.service.undoLast() == "Import 1 book")

        #expect(try f.store.books().isEmpty)
        #expect(try f.bytes(source) == bytes)  // never moved, never written
        #expect(f.inboxTree() == ["mystery.m4b"])
        #expect(f.service.covers.url(for: id) == nil)
        #expect(f.libraryTree().isEmpty)
        try expectNothingLeftToUndo(f)
    }

    @Test func undoFixOfUnfiledBook() throws {
        let f = try F()
        let source = try f.makeM4B("mystery.m4b", tags: F.meta("Old", "Old Author"))
        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([source], BookMetadata(title: "Mystery")))
        ])
        guard case .needsAttention(let id) = result.outcomes[0] else {
            Issue.record("expected .needsAttention, got \(result.outcomes)")
            return
        }
        let before = try state(f)
        let tagsBefore = try f.tags(source)
        _ = try f.service.save([try edit(f, id) { $0.metadata.authors = ["Ann Author"] }])
        #expect(exists(f.lib("Ann Author/Mystery/Mystery.m4b")))

        #expect(try f.service.undoLast() == "Edit Mystery")

        // The file is back outside the library, and the row back to needs-attention
        // with its absolute path.
        #expect(try state(f) == before)
        #expect(f.libraryTree().isEmpty)
        #expect(exists(source))
        #expect(try f.tags(source) == tagsBefore)
        let book = try #require(try f.store.book(id: id))
        #expect(book.needsAttention)
        #expect(book.folderPath == nil)
        #expect(book.authors == [])
        let row = try #require(try f.store.files(bookId: id).first)
        #expect(row.path.hasPrefix("/"))
        #expect(f.store.url(for: row).standardizedFileURL == source.standardizedFileURL)
        try expectNothingLeftToUndo(f)
    }

    // U3: a file that has gone missing since does not block the undo.
    @Test func undoToleratesAFileThatCannotBeRestored() throws {
        let f = try F()
        let m4b = try f.makeM4B("a.m4b", tags: F.meta("x", "y"))
        let epub = try f.makeEPUB("a.epub")
        let id = try f.importNew([m4b, epub], F.meta("Artemis", "Andy Weir"))
        let before = try state(f)
        _ = try f.service.save([try edit(f, id) { $0.metadata.genres = ["Thriller"] }])
        // The EPUB is replaced by something that is no EPUB: restoring its tags fails.
        try Data("not an epub".utf8).write(to: f.lib("Andy Weir/Artemis/Artemis.epub"))

        try f.service.undoLast()

        #expect(try state(f) == before)
        #expect(try f.tags(f.lib("Andy Weir/Artemis/Artemis.m4b")).genreSource == nil)
        #expect(try read(f.lib("Andy Weir/Artemis/Artemis.epub")) == "not an epub")
        try expectNothingLeftToUndo(f)
    }

    // Undo data that cannot be read is not undoable: nothing is offered, nothing is
    // half-done, and asking forgets it.
    @Test func unreadableUndoDataIsNotUndoable() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"))
        var change = LibraryChange()
        change.batch = .init(
            label: "Broken", moves: [
                MoveRecord(from: f.inbox.appendingPathComponent("in.m4b").path,
                           to: f.lib("Andy Weir/Artemis/Artemis.m4b").path, wasCopy: false)
            ], snapshot: Data("not json".utf8))
        try f.store.apply(change)
        try touch(f.service.undoFolder("stale").appendingPathComponent("old.img"))

        #expect(try f.service.undoLabel() == nil)
        #expect(throws: LibraryError.nothingToUndo) { try f.service.undoLast() }

        #expect(exists(f.lib("Andy Weir/Artemis/Artemis.m4b")))
        #expect(f.inboxTree().isEmpty)
        #expect(try f.store.book(id: id) != nil)
        // The journal and its undo folder are gone.
        #expect(try f.store.lastBatch() == nil)
        #expect(!f.hiddenTree().contains { $0.hasPrefix("undo") })
    }
}
