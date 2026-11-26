import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

@Suite struct LibraryServiceMaintainTests {
    typealias F = LibraryFixture
    let allText = Set(MetadataField.allCases).subtracting([.cover])

    func importM4B(_ f: F, _ metadata: BookMetadata, cover: CoverImage? = nil, name: String = "in.m4b") throws -> Int64 {
        try f.importNew([try f.makeM4B(name, tags: F.meta("Old", "Old Author"), cover: cover)], metadata)
    }

    /// A book with an M4B, an EPUB and a PDF extra called "Star Map.pdf".
    func importTrio(_ f: F) throws -> Int64 {
        let m4b = try f.makeM4B("a.m4b", tags: F.meta("x", "y"))
        let epub = try f.makeEPUB("a.epub")
        let map = try f.makePDF("Star Map.pdf")
        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([m4b, epub, map], F.meta("Artemis", "Andy Weir"), roles: [map: .extra]))
        ])
        return try f.importedId(result.outcomes[0])
    }

    func fileId(_ f: F, _ bookId: Int64, endingWith suffix: String) throws -> Int64 {
        let file = try #require(try f.store.files(bookId: bookId).first { $0.path.hasSuffix(suffix) })
        return try #require(file.id)
    }

    func totalChanges(_ f: F) throws -> Int {
        try f.store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT total_changes()") ?? -1 }
    }

    // MARK: Roles

    // M2
    @Test func extraBecomesEbookAndBack() throws {
        let f = try F()
        let id = try importTrio(f)
        let folder = "Andy Weir/Artemis"
        #expect(try f.store.files(bookId: id).map(\.path) == [
            "\(folder)/Artemis.m4b", "\(folder)/Artemis.epub", "\(folder)/Extras/Star Map.pdf",
        ])
        #expect(try f.tags(f.lib("\(folder)/Extras/Star Map.pdf")).title == "Original Title")
        let audioBytes = try f.bytes(f.lib("\(folder)/Artemis.m4b"))
        let epubBytes = try f.bytes(f.lib("\(folder)/Artemis.epub"))
        let bookBefore = try #require(try f.store.book(id: id))

        try f.service.setRole(.ebook, forFile: try fileId(f, id, endingWith: "Star Map.pdf"))

        // Out of Extras/, named for the book, and carrying the book's title.
        #expect(f.libraryTree() == [
            "Andy Weir", folder, "\(folder)/Artemis.epub", "\(folder)/Artemis.m4b", "\(folder)/Artemis.pdf",
        ])
        var files = try f.store.files(bookId: id)
        #expect(files.map(\.path) == ["\(folder)/Artemis.m4b", "\(folder)/Artemis.epub", "\(folder)/Artemis.pdf"])
        #expect(files.map(\.role) == [.audio, .ebook, .ebook])
        #expect(files.map(\.position) == [0, 1, 2])
        let asEbook = try f.tags(f.lib("\(folder)/Artemis.pdf"))
        #expect(asEbook.title == "Artemis")
        #expect(asEbook.authors == ["Andy Weir"])
        // Only the file whose role changed is written.
        #expect(try f.bytes(f.lib("\(folder)/Artemis.m4b")) == audioBytes)
        #expect(try f.bytes(f.lib("\(folder)/Artemis.epub")) == epubBytes)
        #expect(try f.store.book(id: id) == bookBefore)
        let batch = try #require(try f.store.lastBatch())
        #expect(batch.label == "Change file role")
        #expect(batch.moves == [
            MoveRecord(
                from: f.lib("\(folder)/Extras/Star Map.pdf").path, to: f.lib("\(folder)/Artemis.pdf").path,
                wasCopy: false)
        ])
        let states = try f.snapshot().books[0].fileStates
        #expect(states.map(\.pathAfter) == [f.lib("\(folder)/Artemis.pdf").path])
        #expect(states.first?.metadataBefore.title == "Original Title")

        // The EPUB becomes an extra: it moves behind the PDF and is left unwritten.
        try f.service.setRole(.extra, forFile: try fileId(f, id, endingWith: "Artemis.epub"))
        files = try f.store.files(bookId: id)
        #expect(files.map(\.path) == ["\(folder)/Artemis.m4b", "\(folder)/Artemis.pdf", "\(folder)/Extras/Artemis.epub"])
        #expect(files.map(\.role) == [.audio, .ebook, .extra])
        #expect(files.map(\.position) == [0, 1, 2])
        #expect(try f.bytes(f.lib("\(folder)/Extras/Artemis.epub")) == epubBytes)
        #expect(try f.snapshot().books[0].fileStates.isEmpty)

        // And the PDF goes back to Extras/ under the name it first had there, unwritten.
        let pdfBytes = try f.bytes(f.lib("\(folder)/Artemis.pdf"))
        try f.service.setRole(.extra, forFile: try fileId(f, id, endingWith: "Artemis.pdf"))
        files = try f.store.files(bookId: id)
        #expect(files.map(\.path) == [
            "\(folder)/Artemis.m4b", "\(folder)/Extras/Artemis.epub", "\(folder)/Extras/Star Map.pdf",
        ])
        #expect(files.map(\.role) == [.audio, .extra, .extra])
        #expect(files.map(\.position) == [0, 1, 2])
        #expect(files.map(\.originalName) == [nil, "Artemis.epub", "Star Map.pdf"])
        #expect(try f.bytes(f.lib("\(folder)/Extras/Star Map.pdf")) == pdfBytes)
        #expect(f.libraryTree() == [
            "Andy Weir", folder, "\(folder)/Artemis.m4b", "\(folder)/Extras",
            "\(folder)/Extras/Artemis.epub", "\(folder)/Extras/Star Map.pdf",
        ])
        // The audio file holds everything, so nothing became app-only along the way.
        #expect(try #require(try f.store.book(id: id)).appOnlyFields == [])
    }

    // M2: what the book's files hold is recomputed.
    @Test func roleChangeUpdatesAppOnlyFields() throws {
        let f = try F()
        let id = try f.importNew([try f.makeEPUB("a.epub")], F.fullMeta("Artemis", "Andy Weir"))
        let before = try #require(try f.store.book(id: id)).appOnlyFields
        #expect(!before.contains(.title))

        try f.service.setRole(.extra, forFile: try fileId(f, id, endingWith: ".epub"))
        // An extra holds nothing for the book.
        #expect(Set(try #require(try f.store.book(id: id)).appOnlyFields) == allText)

        try f.service.setRole(.ebook, forFile: try fileId(f, id, endingWith: ".epub"))
        let after = try #require(try f.store.book(id: id)).appOnlyFields
        #expect(!after.contains(.title))
        #expect(after.contains(.narrators))
        #expect(try f.store.files(bookId: id).map(\.path) == ["Andy Weir/The Series/2 - Artemis/Artemis.epub"])
    }

    // M1
    @Test func invalidRolesAreRejected() throws {
        let f = try F()
        let id = try importTrio(f)
        let m4b = try fileId(f, id, endingWith: ".m4b")
        let epub = try fileId(f, id, endingWith: ".epub")
        let pdf = try fileId(f, id, endingWith: ".pdf")
        let rows = try f.store.files(bookId: id)
        let tree = f.libraryTree()
        let batch = try f.store.lastBatch()

        #expect(throws: LibraryError.invalidRole) { try f.service.setRole(.ebook, forFile: m4b) }
        #expect(throws: LibraryError.invalidRole) { try f.service.setRole(.extra, forFile: m4b) }
        #expect(throws: LibraryError.invalidRole) { try f.service.setRole(.audio, forFile: epub) }
        #expect(throws: LibraryError.invalidRole) { try f.service.setRole(.audio, forFile: pdf) }
        #expect(throws: LibraryError.fileNotFound(987_654)) { try f.service.setRole(.ebook, forFile: 987_654) }
        // The role a file already has: nothing happens, and no batch is recorded.
        try f.service.setRole(.audio, forFile: m4b)
        try f.service.setRole(.ebook, forFile: epub)
        try f.service.setRole(.extra, forFile: pdf)

        #expect(try f.store.files(bookId: id) == rows)
        #expect(f.libraryTree() == tree)
        #expect(try f.store.lastBatch() == batch)
        #expect(try f.service.undoLabel() == "Import 1 book")
    }

    // M2, E6: a move that cannot be made changes nothing and is reported.
    @Test func roleChangeThatCannotMoveThrowsAndChangesNothing() throws {
        let f = try F()
        let id = try importTrio(f)
        try touch(f.lib("Andy Weir/Artemis/Artemis.pdf"), "in the way")
        let rows = try f.store.files(bookId: id)
        let batch = try f.store.lastBatch()

        #expect(throws: OrganiserError.self) {
            try f.service.setRole(.ebook, forFile: try fileId(f, id, endingWith: "Star Map.pdf"))
        }

        #expect(try f.store.files(bookId: id) == rows)
        #expect(exists(f.lib("Andy Weir/Artemis/Extras/Star Map.pdf")))
        #expect(try f.store.lastBatch() == batch)
    }

    // M2
    @Test func roleChangeIsUndoable() throws {
        let f = try F()
        let id = try importTrio(f)
        let bookBefore = try f.store.book(id: id)
        let rowsBefore = try f.store.files(bookId: id)
        let treeBefore = f.libraryTree()
        try f.service.setRole(.ebook, forFile: try fileId(f, id, endingWith: "Star Map.pdf"))
        #expect(try f.service.undoLabel() == "Change file role")

        #expect(try f.service.undoLast() == "Change file role")

        #expect(f.libraryTree() == treeBefore)
        #expect(try f.store.files(bookId: id) == rowsBefore)
        #expect(try f.store.book(id: id) == bookBefore)
        #expect(try f.tags(f.lib("Andy Weir/Artemis/Extras/Star Map.pdf")).title == "Original Title")
        #expect(try f.service.undoLabels().allSatisfy { $0.hasPrefix("Import ") })
    }

    // MARK: Read status

    // M3
    @Test func readStatusForSeveralBooks() throws {
        let f = try F()
        let a = try importM4B(f, F.meta("Book A", "Author A"), name: "a.m4b")
        let b = try importM4B(f, F.meta("Book B", "Author B"), name: "b.m4b")
        let c = try importM4B(f, F.meta("Book C", "Author C"), name: "c.m4b")
        let batch = try f.store.lastBatch()
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let day2 = day1.addingTimeInterval(86_400)
        let day3 = day2.addingTimeInterval(86_400)
        func book(_ id: Int64) throws -> Book { try #require(try f.store.book(id: id)) }

        try f.service.setReadStatus(.inProgress, for: [a, b, 987_654], on: day1)
        #expect(try book(a).readStatus == .inProgress)
        #expect(try book(a).dateStarted == day1)
        #expect(try book(a).dateFinished == nil)
        #expect(try book(b).readStatus == .inProgress)
        #expect(try book(c).readStatus == .unread)
        #expect(try book(c).dateStarted == nil)

        try f.service.setReadStatus(.finished, for: [a, c], on: day2)
        #expect(try book(a).readStatus == .finished)
        #expect(try book(a).dateStarted == day1)  // kept
        #expect(try book(a).dateFinished == day2)
        #expect(try book(c).dateStarted == day2)  // never started: starts on the day it finished
        #expect(try book(c).dateFinished == day2)
        #expect(try book(b).readStatus == .inProgress)

        try f.service.setReadStatus(.unread, for: [a], on: day3)
        #expect(try book(a).readStatus == .unread)
        #expect(try book(a).dateStarted == nil)
        #expect(try book(a).dateFinished == nil)

        try f.service.setReadStatus(.finished, for: [], on: day3)
        try f.service.setReadStatus(.finished, for: [987_654], on: day3)
        // Not part of undo.
        #expect(try f.store.lastBatch() == batch)
        #expect(try f.store.books(readStatus: .finished).map(\.id) == [c])
    }

    // MARK: Removing

    // M4
    @Test func removeToTrash() throws {
        let f = try F()
        let id = try importTrio(f)
        let other = try importM4B(f, F.meta("Other", "Other Author"), name: "o.m4b")
        let shelf = try #require(try f.store.createCollection(name: "Shelf").id)
        try f.store.add(bookId: id, toCollection: shelf)
        // A stored cover, and a file that is already gone.
        _ = try f.service.save([BookEdit(book: try #require(try f.store.book(id: id)), cover: .set(F.png))])
        #expect(f.service.covers.url(for: id) != nil)
        try FileManager.default.removeItem(at: f.lib("Andy Weir/Artemis/Artemis.epub"))
        // A stand-in Trash inside the test's own folder: the user's Trash is never touched.
        let trash = f.base.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        var trashed: [URL] = []
        f.service.trashItem = { url in
            let landed = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: landed)
            trashed.append(landed)
        }

        try f.service.removeBook(id: id, moveFilesToTrash: true)

        // The files are no longer in the library, and the emptied folders are gone.
        #expect(!exists(f.lib("Andy Weir/Artemis/Artemis.m4b")))
        #expect(!exists(f.lib("Andy Weir/Artemis/Extras/Star Map.pdf")))
        #expect(f.libraryTree() == ["Other Author", "Other Author/Other", "Other Author/Other/Other.m4b"])
        // Row, files, membership and stored cover are gone.
        #expect(try f.store.book(id: id) == nil)
        #expect(try f.store.files(bookId: id).isEmpty)
        #expect(try f.store.books(inCollection: shelf).isEmpty)
        #expect(f.service.covers.url(for: id) == nil)
        #expect(try f.store.books().map(\.id) == [other])
        #expect(trashed.count == 2)  // the missing file was skipped
        #expect(trashed.allSatisfy { exists($0) })
        #expect(tree(trash) == ["Artemis.m4b", "Star Map.pdf"])
    }

    // M4
    @Test func removeKeepingFiles() throws {
        let f = try F()
        let id = try importTrio(f)
        let tree = f.libraryTree()
        let bytes = try f.bytes(f.lib("Andy Weir/Artemis/Artemis.m4b"))
        var trashCalls = 0
        f.service.trashItem = { _ in trashCalls += 1 }

        try f.service.removeBook(id: id, moveFilesToTrash: false)

        #expect(trashCalls == 0)
        #expect(f.libraryTree() == tree)
        #expect(try f.bytes(f.lib("Andy Weir/Artemis/Artemis.m4b")) == bytes)
        #expect(try f.store.book(id: id) == nil)
        #expect(try f.store.files(bookId: id).isEmpty)
        #expect(throws: LibraryError.bookNotFound(id)) { try f.service.removeBook(id: id, moveFilesToTrash: false) }
        #expect(throws: LibraryError.bookNotFound(987_654)) { try f.service.removeBook(id: 987_654, moveFilesToTrash: true) }
    }

    // M5: an app (or its tests) can give its own way of sending a file to the Trash.
    @Test func aServiceCanBeGivenItsOwnTrash() throws {
        let f = try F()
        let id = try importTrio(f)
        final class Calls: @unchecked Sendable { var urls: [URL] = [] }
        let calls = Calls()
        let service = LibraryService(store: f.store) { url in
            calls.urls.append(url)
            try FileManager.default.removeItem(at: url)
        }
        try service.removeBook(id: id, moveFilesToTrash: true)
        #expect(Set(calls.urls.map(\.lastPathComponent)) == ["Artemis.m4b", "Artemis.epub", "Star Map.pdf"])
        #expect(try f.store.book(id: id) == nil)
        #expect(!exists(f.lib("Andy Weir/Artemis/Artemis.m4b")))
    }

    // M4: files of a book catalogued in place can be trashed too; folders outside the
    // library are never removed.
    @Test func removeToTrashLeavesFoldersOutsideTheLibrary() throws {
        let f = try F()
        let source = try f.makeM4B("loose/mystery.m4b", tags: F.meta("Old", "Old Author"))
        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([source], BookMetadata(title: "Mystery")))
        ])
        guard case .needsAttention(let id) = result.outcomes[0] else {
            Issue.record("expected .needsAttention, got \(result.outcomes)")
            return
        }
        var asked: [URL] = []
        f.service.trashItem = { url in
            asked.append(url)
            try FileManager.default.removeItem(at: url)
        }

        try f.service.removeBook(id: id, moveFilesToTrash: true)

        #expect(asked.map(\.standardizedFileURL) == [source.standardizedFileURL])
        #expect(f.inboxTree() == ["loose"])
        #expect(try f.store.books().isEmpty)
    }

    // M5
    @Test func trashFailureKeepsTheBook() throws {
        let f = try F()
        let id = try importTrio(f)
        let bookBefore = try f.store.book(id: id)
        let rowsBefore = try f.store.files(bookId: id)
        let batchBefore = try f.store.lastBatch()
        _ = try f.service.save([BookEdit(book: try #require(bookBefore), cover: .set(F.png))])
        let journal = try f.store.lastBatch()
        _ = batchBefore
        var calls = 0
        f.service.trashItem = { url in
            calls += 1
            // The first file goes; the second cannot.
            if calls == 2 { throw Boom() }
            try FileManager.default.removeItem(at: url)
        }

        #expect(throws: Boom.self) { try f.service.removeBook(id: id, moveFilesToTrash: true) }

        #expect(calls == 2)
        // The book is still in the database, with its cover and its journal entry.
        #expect(try f.store.book(id: id)?.title == "Artemis")
        #expect(try f.store.files(bookId: id).map(\.path) == rowsBefore.map(\.path))
        #expect(f.service.covers.image(for: id) == F.png)
        #expect(try f.store.lastBatch() == journal)
        // What was trashed stays trashed; the rest is where it was.
        #expect(!exists(f.lib("Andy Weir/Artemis/Artemis.m4b")))
        #expect(exists(f.lib("Andy Weir/Artemis/Artemis.epub")))
        #expect(exists(f.lib("Andy Weir/Artemis/Extras/Star Map.pdf")))
    }

    // M4
    @Test func removingABookInTheLastBatchClearsTheJournal() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"), cover: F.jpeg)
        _ = try f.service.save([BookEdit(book: try #require(try f.store.book(id: id)), cover: .set(F.png))])
        #expect(try f.service.undoLabel() == "Edit Artemis")
        #expect(f.hiddenTree().contains { $0.hasPrefix("undo/") })

        try f.service.removeBook(id: id, moveFilesToTrash: false)

        #expect(try f.service.undoLabel() == nil)
        #expect(throws: LibraryError.nothingToUndo) { try f.service.undoLast() }
        #expect(!f.hiddenTree().contains { $0.hasPrefix("undo") })
    }

    // M4: a batch about other books can still be undone.
    @Test func removingAnotherBookKeepsTheJournal() throws {
        let f = try F()
        let old = try importM4B(f, F.meta("Old Book", "Ann Author"), name: "old.m4b")
        let recent = try importM4B(f, F.meta("Recent", "Ben Author"), name: "recent.m4b")

        try f.service.removeBook(id: old, moveFilesToTrash: false)

        #expect(try f.service.undoLabel() == "Import 1 book")
        try f.service.undoLast()
        #expect(try f.store.book(id: recent) == nil)
        #expect(f.inboxTree() == ["recent.m4b"])
    }

    // M4: a legacy batch (no snapshot) that moved one of the book's files is cleared too.
    @Test func removingABookTouchedByALegacyBatchClearsTheJournal() throws {
        let f = try F()
        let id = try importM4B(f, F.meta("Artemis", "Andy Weir"))
        try f.store.recordBatch(label: "Legacy", moves: [
            MoveRecord(from: "/somewhere/in.m4b", to: f.lib("Andy Weir/Artemis/Artemis.m4b").path, wasCopy: false)
        ])
        try f.service.removeBook(id: id, moveFilesToTrash: false)
        #expect(try f.service.undoLabel() == nil)
    }

    // MARK: Rewriting tags

    @Test func rewriteTagsClearsAProblemOnceTheFileIsWritable() throws {
        let f = try F()
        let fm = FileManager.default
        let source = try f.makeM4B("locked.m4b", tags: F.meta("Old", "Old Author"))
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: source.path)
        let dest = f.lib("Andy Weir/The Series/2 - Artemis/Artemis.m4b")
        defer {
            for url in [source, dest] { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        }
        let reviewed = F.fullMeta("Artemis", "Andy Weir")
        let imported = try f.service.importItems([ImportItem(candidate: f.candidate([source], reviewed))])
        guard case .imported(let id, let problems) = imported.outcomes[0] else {
            Issue.record("expected .imported, got \(imported.outcomes)")
            return
        }
        #expect(problems.count == 1)
        #expect(try f.tags(dest) == F.meta("Old", "Old Author"))
        let bookBefore = try #require(try f.store.book(id: id))
        let rowsBefore = try f.store.files(bookId: id)
        #expect(rowsBefore.first?.writeProblem != nil)
        let tree = f.libraryTree()

        // Still locked: the call succeeds, the problem stays, nothing is committed.
        let stillLocked = try f.service.rewriteTags(for: [id])
        guard case .saved(id, false, let lockedFields, let lockedProblems) = try #require(stillLocked.first) else {
            Issue.record("expected .saved, got \(stillLocked)")
            return
        }
        #expect(lockedFields == allText)
        #expect(lockedProblems.map(\.file) == ["Artemis.m4b"])
        #expect(try f.store.files(bookId: id) == rowsBefore)
        #expect(try f.store.book(id: id) == bookBefore)
        #expect(try f.service.undoLabel() == "Import 1 book")

        // Writable: the database's metadata goes into the file and the problem clears.
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dest.path)
        let outcomes = try f.service.rewriteTags(for: [id])

        #expect(outcomes == [.saved(bookId: id, refiled: false, appOnlyFields: [], fileProblems: [])])
        #expect(try f.tags(dest) == reviewed)
        #expect(try f.store.files(bookId: id).map(\.writeProblem) == [nil])
        #expect(try f.store.files(bookId: id).map(\.path) == rowsBefore.map(\.path))
        #expect(try #require(try f.store.book(id: id)).appOnlyFields == [])
        #expect(f.libraryTree() == tree)  // nothing moves
        let batch = try #require(try f.store.lastBatch())
        #expect(batch.label == "Rewrite tags")
        #expect(batch.moves.isEmpty)

        // Undo restores the file's previous tags and the previous problem.
        #expect(try f.service.undoLast() == "Rewrite tags")
        #expect(try f.tags(dest) == F.meta("Old", "Old Author"))
        #expect(try f.store.files(bookId: id) == rowsBefore)
        #expect(try f.store.book(id: id) == bookBefore)
    }

    @Test func rewriteTagsForSeveralBooks() throws {
        let f = try F()
        let parts = try f.makeMP3Parts(folder: "rip", tags: F.meta("Old", "Old Author"))
        let a = try f.importNew(parts, F.meta("Dune", "Frank Herbert"))
        let b = try f.importNew([try f.makePDF("p.pdf")], F.meta("Paper", "Ann Author"), cover: .set(F.png))
        let first = f.lib("Frank Herbert/Dune/01 - Dune.mp3")
        // Another app scribbles over one file's tags.
        try f.io.write(F.meta("Scribble", "Someone"), to: first)
        let coverBytes = try f.bytes(try #require(f.service.covers.url(for: b)))

        let outcomes = try f.service.rewriteTags(for: [a, 987_654, b, a])

        #expect(outcomes.count == 4)
        #expect(outcomes[0] == .saved(bookId: a, refiled: false, appOnlyFields: [], fileProblems: []))
        guard case .failed(987_654, let reason) = outcomes[1] else {
            Issue.record("expected .failed, got \(outcomes[1])")
            return
        }
        #expect(reason.contains("not in the library"))
        guard case .saved(b, false, let fields, _) = outcomes[2] else {
            Issue.record("expected .saved, got \(outcomes[2])")
            return
        }
        // The cover is kept: stored, and still only in the app for a PDF.
        #expect(fields.contains(.cover))
        #expect(fields.contains(.narrators))
        #expect(!fields.contains(.title))
        #expect(try f.bytes(try #require(f.service.covers.url(for: b))) == coverBytes)
        guard case .failed(a, _) = outcomes[3] else {
            Issue.record("expected the repeat to fail, got \(outcomes[3])")
            return
        }
        // Part positions as in I5.
        #expect(try f.tags(first) == F.meta("Dune", "Frank Herbert"))
        #expect(try f.track(first) == "1/2")
        #expect(try f.track(f.lib("Frank Herbert/Dune/02 - Dune.mp3")) == "2/2")
        #expect(try f.store.lastBatch()?.label == "Rewrite tags for 2 books")
        #expect(try f.snapshot().books.map(\.bookId) == [a, b])

        try f.service.undoLast()
        #expect(try f.tags(first) == F.meta("Scribble", "Someone"))
    }

    @Test func rewriteTagsWithNothingToWriteCommitsNothing() throws {
        let f = try F()
        // A book whose only file is of a format that is never opened.
        let mobi = try f.importNew(
            [try touch(f.inbox.appendingPathComponent("k.mobi"), "opaque")], F.meta("Kindle", "Ann Author"))
        let mobiBefore = try f.store.book(id: mobi)
        let batch = try f.store.lastBatch()
        var commits = 0
        f.service.beforeCommit = { commits += 1 }

        #expect(try f.service.rewriteTags(for: []).isEmpty)
        let outcomes = try f.service.rewriteTags(for: [987_654])
        guard case .failed(987_654, _) = try #require(outcomes.first) else {
            Issue.record("expected .failed, got \(outcomes)")
            return
        }
        let untouched = try f.service.rewriteTags(for: [mobi])
        #expect(untouched == [
            .saved(bookId: mobi, refiled: false, appOnlyFields: allText, fileProblems: [])
        ])
        #expect(try f.store.book(id: mobi) == mobiBefore)
        #expect(try read(f.lib("Ann Author/Kindle/Kindle.mobi")) == "opaque")
        #expect(commits == 0)
        #expect(try f.store.lastBatch() == batch)
    }

    // MARK: The launch check

    // R1, R2
    @Test func missingFileIsFlaggedAndRecovers() throws {
        let f = try F()
        let id = try importTrio(f)
        let other = try importM4B(f, F.meta("Other", "Other Author"), name: "o.m4b")
        let batch = try f.store.lastBatch()
        let file = f.lib("Andy Weir/Artemis/Artemis.epub")
        let away = f.base.appendingPathComponent("away.epub")
        try FileManager.default.moveItem(at: file, to: away)

        var report = try f.service.reconcile()

        #expect(report.booksWithMissingFiles == [id])
        #expect(report.booksRecovered.isEmpty)
        #expect(report.untrackedFiles.isEmpty)
        #expect(try f.store.book(id: id)?.needsAttention == true)
        #expect(try f.store.book(id: other)?.needsAttention == false)

        // Still missing: still listed, and nothing more is written.
        let changes = try totalChanges(f)
        report = try f.service.reconcile()
        #expect(report.booksWithMissingFiles == [id])
        #expect(try totalChanges(f) == changes)

        try FileManager.default.moveItem(at: away, to: file)
        report = try f.service.reconcile()

        #expect(report.booksWithMissingFiles.isEmpty)
        #expect(report.booksRecovered == [id])
        #expect(try f.store.book(id: id)?.needsAttention == false)
        // And then it is simply a clean library.
        #expect(try f.service.reconcile() == ReconcileReport())
        #expect(try f.store.lastBatch() == batch)  // R5
    }

    // R2: a book that is flagged for another reason stays flagged.
    @Test func unfiledOrUnfileableBooksAreNotRecovered() throws {
        let f = try F()
        let source = try f.makeM4B("mystery.m4b", tags: F.meta("Old", "Old Author"))
        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([source], BookMetadata(title: "Mystery")))
        ])
        guard case .needsAttention(let unfiled) = result.outcomes[0] else {
            Issue.record("expected .needsAttention, got \(result.outcomes)")
            return
        }
        let filed = try importM4B(f, F.meta("Artemis", "Andy Weir"))
        var edit = BookEdit(book: try #require(try f.store.book(id: filed)))
        edit.metadata.authors = []
        _ = try f.service.save([edit])  // filed, but no longer fileable
        // A library notes, the first time, that its MP3 headers have been looked at.
        _ = try f.service.reconcile()
        let changes = try totalChanges(f)

        let report = try f.service.reconcile()

        #expect(report == ReconcileReport())
        #expect(try f.store.book(id: unfiled)?.needsAttention == true)
        #expect(try f.store.book(id: filed)?.needsAttention == true)
        #expect(try totalChanges(f) == changes)

        // A missing file of the book catalogued in place is found through its absolute path (R1).
        try FileManager.default.removeItem(at: source)
        #expect(try f.service.reconcile().booksWithMissingFiles == [unfiled])
    }

    // R3
    @Test func untrackedFilesAreListed() throws {
        let f = try F()
        let fm = FileManager.default
        let id = try importTrio(f)
        _ = try f.service.save([BookEdit(book: try #require(try f.store.book(id: id)), cover: .set(F.png))])
        // The rows refer to the files with other capitalisation than the disk has. On a
        // volume that tells capitals apart those are other files, which do not exist.
        let volume = try f.root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        guard let caseSensitive = volume.volumeSupportsCaseSensitiveNames else {
            Issue.record("the volume does not say whether it tells capitals apart")
            return
        }
        let rows = try f.store.files(bookId: id)
        try f.store.replaceFiles(bookId: id, files: rows.map {
            var row = $0
            row.path = $0.path.uppercased()
            return row
        })
        #expect(exists(f.lib(rows[0].path.uppercased())) == !caseSensitive)

        let dropped = try touch(f.lib("Dropped/New Book.epub"))
        let beside = try touch(f.lib("Andy Weir/Artemis/Bonus.MP3"))
        try touch(f.lib("Dropped/notes.txt"))
        try touch(f.lib("Dropped/.hidden.epub"))
        try touch(f.lib(".hidden folder/inside.epub"))
        try touch(f.service.layout.hiddenFolder.appendingPathComponent("stray.epub"))
        // A package, and a folder named like a book, are single opaque items.
        try touch(f.lib("Thing.app/Contents/inner.epub"))
        try touch(f.lib("Folder.epub/inner.pdf"))
        // Links are never followed.
        let outside = f.base.appendingPathComponent("Outside", isDirectory: true)
        try touch(outside.appendingPathComponent("elsewhere.epub"))
        try fm.createSymbolicLink(at: f.lib("Linked Folder"), withDestinationURL: outside)
        try fm.createSymbolicLink(
            at: f.lib("Dropped/link.epub"), withDestinationURL: outside.appendingPathComponent("elsewhere.epub"))

        let report = try f.service.reconcile()

        // R3 compares ignoring capitalisation on either kind of volume, so the book's own
        // files are never listed as untracked.
        #expect(report.untrackedFiles.map(\.standardizedFileURL.path)
            == [beside, dropped].map(\.standardizedFileURL.path))
        // R1 asks the disk: the differently spelled rows only resolve where capitals do not count.
        #expect(report.booksWithMissingFiles == (caseSensitive ? [id] : []))
        #expect(report.booksRecovered.isEmpty)
        #expect(report.removedWorkingCopies == 0)
        #expect(report.strandedFiles.isEmpty)
        // R5: nothing is touched.
        #expect(exists(dropped))
        #expect(exists(outside.appendingPathComponent("elsewhere.epub")))
        #expect(exists(f.service.layout.hiddenFolder.appendingPathComponent("stray.epub")))
    }

    // R4
    @Test func workingCopiesAreSweptButStrandedFilesAreKept() throws {
        let f = try F()
        _ = try importM4B(f, F.meta("Artemis", "Andy Weir"))
        let batch = try f.store.lastBatch()
        let folder = f.lib("Andy Weir/Artemis")
        let uuid = UUID().uuidString
        let working = try touch(folder.appendingPathComponent(".voxcarrel-\(uuid).m4b"), "half-written copy")
        let workingAtRoot = try touch(f.lib(".voxcarrel-\(UUID().uuidString.lowercased()).epub"))
        let stranded = try touch(folder.appendingPathComponent(".voxcarrel-moving-\(uuid)"), "a real file")
        // Names that only resemble a working copy are never deleted.
        let lookalikes = try [
            ".voxcarrel-notes.m4b",
            ".voxcarrel-\(uuid)",
            ".voxcarrel-\(uuid).",
            ".voxcarrel-\(uuid)-extra.m4b",
            ".voxcarrel-\(String(uuid.dropLast())).m4b",
            ".voxcarrel-moving-\(uuid).m4b",
            ".voxcarrel-moving-notes",
            "voxcarrel-\(uuid).m4b",
            ".Voxcarrel-\(UUID().uuidString).m4b",
        ].map { try touch(folder.appendingPathComponent($0)) }
        // A folder with a working copy's name is not a working copy.
        let folderLookalike = folder.appendingPathComponent(".voxcarrel-\(UUID().uuidString).m4b")
        try touch(folderLookalike.appendingPathComponent("inside.txt"))

        let report = try f.service.reconcile()

        #expect(report.removedWorkingCopies == 2)
        #expect(!exists(working))
        #expect(!exists(workingAtRoot))
        #expect(report.strandedFiles.map(\.standardizedFileURL.path) == [stranded.standardizedFileURL.path])
        #expect(try read(stranded) == "a real file")
        #expect(lookalikes.allSatisfy { exists($0) })
        #expect(exists(folderLookalike.appendingPathComponent("inside.txt")))
        // "voxcarrel-<UUID>.m4b" is not hidden: it is simply an untracked audio file.
        #expect(report.untrackedFiles.map(\.lastPathComponent) == ["voxcarrel-\(uuid).m4b"])
        #expect(report.booksWithMissingFiles.isEmpty)
        #expect(try f.store.lastBatch() == batch)  // R5

        // Swept once; the stranded file is reported every time.
        let again = try f.service.reconcile()
        #expect(again.removedWorkingCopies == 0)
        #expect(again.strandedFiles.count == 1)
    }

    // R5, R6
    @Test func cleanLibraryIsANoOp() throws {
        let f = try F()
        let id = try importTrio(f)
        _ = try f.service.save([BookEdit(book: try #require(try f.store.book(id: id)), cover: .set(F.png))])
        let books = try f.store.books()
        let rows = try f.store.files(bookId: id)
        let batch = try f.store.lastBatch()
        let tree = f.libraryTree()
        let hidden = f.hiddenTree()
        // The first check of a library notes that its MP3 headers have been looked at:
        // that, once, is all it writes.
        #expect(try f.service.reconcile() == ReconcileReport())
        #expect(try f.store.note(LibraryService.lengthHeadersNote) != nil)
        let changes = try totalChanges(f)

        let report = try f.service.reconcile()

        #expect(report == ReconcileReport())
        #expect(report.booksWithMissingFiles.isEmpty)
        #expect(report.untrackedFiles.isEmpty)
        #expect(report.removedWorkingCopies == 0)
        #expect(try f.store.books() == books)
        #expect(try f.store.files(bookId: id) == rows)
        #expect(try f.store.lastBatch() == batch)
        #expect(f.libraryTree() == tree)
        #expect(f.hiddenTree() == hidden)
        #expect(try totalChanges(f) == changes)  // R6: nothing written

        // An empty library is clean too.
        #expect(try F().service.reconcile() == ReconcileReport())
    }

    // The check reads no file contents: it copes with many files, none of them real books.
    @Test func reconcileCopesWithManyFiles() throws {
        let f = try F()
        var count = 0
        for author in 0..<40 {
            for title in 0..<25 { try touch(f.lib("Author \(author)/Book \(title)/Book \(title).m4b")) }
        }
        try f.store.dbQueue.write { db in
            for author in 0..<40 {
                for title in 0..<25 {
                    let folder = "Author \(author)/Book \(title)"
                    var book = Book(metadata: F.meta("Book \(title)", "Author \(author)"), folderPath: folder)
                    try book.insert(db)
                    var file = BookFile(path: "\(folder)/Book \(title).m4b", format: .m4b, role: .audio, position: 0)
                    file.bookId = book.id
                    try file.insert(db)
                    count += 1
                }
            }
        }
        try FileManager.default.removeItem(at: f.lib("Author 7/Book 3/Book 3.m4b"))
        try touch(f.lib("Author 9/Loose.epub"))

        let report = try f.service.reconcile()

        #expect(report.booksWithMissingFiles.count == 1)
        #expect(report.untrackedFiles.map(\.lastPathComponent) == ["Loose.epub"])
        #expect(count == 1000)
    }
}
