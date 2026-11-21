import Foundation
import Testing
@testable import VoxCarrelCore

@Suite struct LibraryServiceImportTests {
    typealias F = LibraryFixture
    let allText = MetadataField.allCases.filter { $0 != .cover }

    // MARK: New books

    // I2, I4, I5, I7, I10
    @Test func importsASingleFileAudiobook() throws {
        let f = try F()
        let source = try f.makeM4B("download.m4b", tags: F.meta("Old Title", "Old Author"))
        let reviewed = F.fullMeta("Project Hail Mary", "Andy Weir")
        #expect(try f.tags(source) != reviewed)

        let result = try f.service.importItems([ImportItem(candidate: f.candidate([source], reviewed))])

        #expect(result.outcomes.count == 1)
        let id = try f.importedId(result.outcomes[0])
        // I2, I4: filed under Author/Series/N - Title, and gone from the inbox.
        let dest = f.lib("Andy Weir/The Series/2 - Project Hail Mary/Project Hail Mary.m4b")
        #expect(exists(dest))
        #expect(f.inboxTree().isEmpty)
        #expect(f.libraryTree().filter { $0.hasSuffix(".m4b") }
            == ["Andy Weir/The Series/2 - Project Hail Mary/Project Hail Mary.m4b"])

        // I10: rows.
        let book = try #require(try f.store.book(id: id))
        var expected = reviewed
        expected.durationSeconds = book.durationSeconds
        #expect(book.metadata == expected)
        #expect(book.folderPath == "Andy Weir/The Series/2 - Project Hail Mary")
        #expect(book.needsAttention == false)
        #expect(book.appOnlyFields == [])
        let files = try f.store.files(bookId: id)
        #expect(files.map(\.path) == ["Andy Weir/The Series/2 - Project Hail Mary/Project Hail Mary.m4b"])
        #expect(files.map(\.format) == [.m4b])
        #expect(files.map(\.role) == [.audio])
        #expect(files.map(\.position) == [0])
        #expect(files.map(\.writeProblem) == [nil])

        // I5: the moved file carries the reviewed tags, and no track number.
        #expect(try f.tags(dest) == reviewed)
        #expect(try f.track(dest) == nil)
        // I7
        let duration = try #require(book.durationSeconds)
        let onDisk = try #require(try f.io.read(dest).metadata.durationSeconds)
        #expect(abs(duration - onDisk) < 0.05)
        #expect(duration > 0.5)
        #expect(book.pageCount == nil)
    }

    // I5, I7
    @Test func importsMultiPartWithTrackNumbers() throws {
        let f = try F()
        let parts = try f.makeMP3Parts(folder: "rip", tags: F.meta("Old Album", "Old Author"))
        let reviewed = F.meta("Dune", "Frank Herbert")

        let id = try f.importNew(parts, reviewed)

        let first = f.lib("Frank Herbert/Dune/01 - Dune.mp3")
        let second = f.lib("Frank Herbert/Dune/02 - Dune.mp3")
        #expect(f.libraryTree() == [
            "Frank Herbert", "Frank Herbert/Dune",
            "Frank Herbert/Dune/01 - Dune.mp3", "Frank Herbert/Dune/02 - Dune.mp3",
        ])
        #expect(f.inboxTree() == ["rip"])  // source folders outside the library are left alone
        for (url, track) in [(first, "1/2"), (second, "2/2")] {
            #expect(try f.tags(url) == reviewed)
            #expect(try f.track(url) == track)
            // The part's own track title is not overwritten.
            #expect(try f.trackTitle(url) == "Old Album")
        }
        let book = try #require(try f.store.book(id: id))
        let d1 = try #require(try f.io.read(first).metadata.durationSeconds)
        let d2 = try #require(try f.io.read(second).metadata.durationSeconds)
        let total = try #require(book.durationSeconds)
        #expect(abs(total - (d1 + d2)) < 0.1)
        #expect(total > d1 + 0.5)
        #expect(try f.store.files(bookId: id).map(\.position) == [0, 1])
    }

    // I5, I9, I10
    @Test func importsAudioEbookAndExtraTogether() throws {
        let g = try F()
        let reviewed = F.fullMeta("Artemis", "Andy Weir")
        let gm4b = try g.makeM4B("book.m4b", tags: F.meta("Old", "Old Author"))
        let gepub = try g.makeEPUB("book.epub")
        let gextra = try g.makePDF("Star Map.pdf")
        let extraBytes = try g.bytes(gextra)
        let result = try g.service.importItems([
            ImportItem(candidate: g.candidate([gm4b, gepub, gextra], reviewed, roles: [gextra: .extra]))
        ])
        let gid = try g.importedId(result.outcomes[0])

        let folder = "Andy Weir/The Series/2 - Artemis"
        #expect(try g.store.books().count == 1)
        let files = try g.store.files(bookId: gid)
        #expect(files.map(\.path) == [
            "\(folder)/Artemis.m4b", "\(folder)/Artemis.epub", "\(folder)/Extras/Star Map.pdf",
        ])
        #expect(files.map(\.role) == [.audio, .ebook, .extra])
        #expect(files.map(\.format) == [.m4b, .epub, .pdf])
        #expect(files.map(\.position) == [0, 1, 2])
        #expect(files.allSatisfy { $0.writeProblem == nil })

        // I5: the extra is never written; the audio and the ebook carry the tags.
        #expect(try g.bytes(g.lib("\(folder)/Extras/Star Map.pdf")) == extraBytes)
        #expect(try g.tags(g.lib("\(folder)/Artemis.m4b")) == reviewed)
        let inEpub = try g.tags(g.lib("\(folder)/Artemis.epub"))
        #expect(inEpub.title == "Artemis")
        #expect(inEpub.authors == ["Andy Weir"])
        #expect(inEpub.series == "The Series")
        #expect(inEpub.publisher == "Audible Studios")
        #expect(inEpub.narrators == [])  // an EPUB cannot hold narrators

        // I9: the M4B holds everything, so nothing is app-only. The cover found in the
        // EPUB is stored (I8) and a file holds it.
        let book = try #require(try g.store.book(id: gid))
        #expect(book.appOnlyFields == [])
        #expect(g.service.covers.image(for: gid) != nil)
        #expect(g.inboxTree().isEmpty)
    }

    // I5: a PDF that is the book (not an extra) is written.
    @Test func pdfAsEbookIsWritten() throws {
        let f = try F()
        let pdf = try f.makePDF("paper.pdf")
        _ = try f.importNew([pdf], F.meta("Paper", "Ann Author"))
        let written = try f.tags(f.lib("Ann Author/Paper/Paper.pdf"))
        #expect(written.title == "Paper")
        #expect(written.authors == ["Ann Author"])
    }

    // I9: an EPUB-only book keeps what the format cannot hold in the app only.
    @Test func ebookOnlyBookListsWhatEpubCannotHold() throws {
        let f = try F()
        let epub = try f.makeEPUB("book.epub")
        let id = try f.importNew([epub], F.fullMeta("Artemis", "Andy Weir"))
        let fields = try #require(try f.store.book(id: id)).appOnlyFields
        #expect(Set(fields).isSuperset(of: [.subtitle, .narrators, .asin]))
        #expect(!fields.contains(.title))
        #expect(!fields.contains(.authors))
        #expect(!fields.contains(.cover))  // the stored cover came from the EPUB itself
        // Listed in the order of MetadataField.allCases.
        #expect(fields == MetadataField.allCases.filter { fields.contains($0) })
    }

    // I8, I9
    @Test func coverRules() throws {
        let f = try F()
        let jpeg = F.jpeg
        let png = F.png

        // .keep: the embedded cover is stored; the file's cover is untouched.
        let kept = try f.makeM4B("keep.m4b", tags: F.meta("x", "y"), cover: jpeg)
        let keptId = try f.importNew([kept], F.meta("Keep", "Ann Author"), cover: .keep)
        #expect(f.service.covers.image(for: keptId) == jpeg)
        #expect(try f.io.read(f.lib("Ann Author/Keep/Keep.m4b")).cover == jpeg)
        #expect(try #require(try f.store.book(id: keptId)).appOnlyFields == [])

        // .keep with no cover anywhere: nothing stored, nothing listed.
        let bare = try f.makeM4B("bare.m4b", tags: F.meta("x", "y"))
        let bareId = try f.importNew([bare], F.meta("Bare", "Ann Author"), cover: .keep)
        #expect(f.service.covers.url(for: bareId) == nil)
        #expect(try f.io.read(f.lib("Ann Author/Bare/Bare.m4b")).cover == nil)
        #expect(try #require(try f.store.book(id: bareId)).appOnlyFields == [])

        // .set: stored and embedded, replacing the file's own.
        let set = try f.makeM4B("set.m4b", tags: F.meta("x", "y"), cover: jpeg)
        let setId = try f.importNew([set], F.meta("Set", "Ann Author"), cover: .set(png))
        #expect(f.service.covers.image(for: setId) == png)
        #expect(try f.io.read(f.lib("Ann Author/Set/Set.m4b")).cover == png)
        #expect(try #require(try f.store.book(id: setId)).appOnlyFields == [])

        // .remove: none stored, and stripped from the file.
        let removed = try f.makeM4B("remove.m4b", tags: F.meta("x", "y"), cover: jpeg)
        let removedId = try f.importNew([removed], F.meta("Remove", "Ann Author"), cover: .remove)
        #expect(f.service.covers.url(for: removedId) == nil)
        #expect(try f.io.read(f.lib("Ann Author/Remove/Remove.m4b")).cover == nil)
        #expect(!(try #require(try f.store.book(id: removedId)).appOnlyFields.contains(.cover)))

        // .keep takes audio covers before ebook covers.
        let audio = try f.makeM4B("both.m4b", tags: F.meta("x", "y"), cover: png)
        let epub = try f.makeEPUB("both.epub")  // has a JPEG cover
        let bothId = try f.importNew([audio, epub], F.meta("Both", "Ann Author"), cover: .keep)
        #expect(f.service.covers.image(for: bothId) == png)

        // I9: a PDF cannot hold a cover, so a set cover lives in the app only.
        let pdf = try f.makePDF("paper.pdf")
        let pdfId = try f.importNew([pdf], F.meta("Paper", "Ann Author"), cover: .set(png))
        #expect(f.service.covers.image(for: pdfId) == png)
        let pdfBook = try #require(try f.store.book(id: pdfId))
        #expect(pdfBook.appOnlyFields.contains(.cover))
        #expect(!pdfBook.appOnlyFields.contains(.title))
        #expect(pdfBook.appOnlyFields.contains(.narrators))

        // Each book has exactly one stored cover file.
        #expect(f.hiddenTree().filter { $0.hasPrefix("covers/") }.count == 4)
    }

    // I7
    @Test func pageCountAndDurationComeFromTheFiles() throws {
        let f = try F()
        let pdf = try f.makePDF("paper.pdf", pages: 5)
        let id = try f.importNew([pdf], F.meta("Paper", "Ann Author"))
        let book = try #require(try f.store.book(id: id))
        #expect(book.pageCount == 5)
        #expect(book.durationSeconds == nil)  // no audio

        // The reviewed page count wins over the file's; a stale reviewed duration does not survive.
        let other = try f.makePDF("other.pdf", pages: 2)
        var reviewed = F.meta("Other", "Ann Author")
        reviewed.pageCount = 321
        reviewed.durationSeconds = 99_999
        let otherId = try f.importNew([other], reviewed)
        let otherBook = try #require(try f.store.book(id: otherId))
        #expect(otherBook.pageCount == 321)
        #expect(otherBook.durationSeconds == nil)
    }

    // I2
    @Test func unfileableBookIsCataloguedInPlace() throws {
        let f = try F()
        let source = try f.makeM4B("mystery.m4b", tags: F.meta("Old Title", "Old Author"), cover: F.jpeg)
        let before = try f.bytes(source)
        var reviewed = BookMetadata(title: "Mystery")  // no author: cannot be filed
        reviewed.genre = "Unknown"

        let result = try f.service.importItems([ImportItem(candidate: f.candidate([source], reviewed))])

        guard case .needsAttention(let id) = try #require(result.outcomes.first) else {
            Issue.record("expected .needsAttention, got \(result.outcomes)")
            return
        }
        #expect(exists(source))
        #expect(try f.bytes(source) == before)  // no tags written
        #expect(f.libraryTree().isEmpty)
        let book = try #require(try f.store.book(id: id))
        #expect(book.needsAttention)
        #expect(book.folderPath == nil)
        #expect(book.title == "Mystery")
        #expect(book.genre == "Unknown")
        #expect((book.durationSeconds ?? 0) > 0.5)  // I7 still applies
        let files = try f.store.files(bookId: id)
        #expect(files.count == 1)
        let stored = try #require(files.first)
        #expect(stored.path.hasPrefix("/"))
        #expect(f.store.url(for: stored).standardizedFileURL == source.standardizedFileURL)
        #expect(stored.role == .audio)
        #expect(stored.writeProblem == nil)
        // Nothing was written, so every text field is in the app only; the cover is in the file.
        #expect(book.appOnlyFields == allText)
        #expect(f.service.covers.image(for: id) == F.jpeg)

        // I11: still one undoable operation, with nothing to move back.
        let batch = try #require(try f.store.lastBatch())
        #expect(batch.label == "Import 1 book")
        #expect(batch.moves.isEmpty)
        let snapshot = try f.snapshot()
        #expect(snapshot.books.map(\.bookId) == [id])
        #expect(snapshot.books[0].bookBefore == nil)
        #expect(snapshot.books[0].fileStates.isEmpty)
    }

    // I1, I4
    @Test func oneFailureDoesNotStopTheOthers() throws {
        let f = try F()
        let a = try f.makeM4B("a.m4b", tags: F.meta("x", "y"))
        let b = try f.makeM4B("b.m4b", tags: F.meta("x", "y"), cover: F.jpeg)
        let c = try f.makeM4B("c.m4b", tags: F.meta("x", "y"))
        let bBytes = try f.bytes(b)
        let occupied = try touch(f.lib("Author B/Book B/Book B.m4b"), "already here")

        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([a], F.meta("Book A", "Author A"))),
            ImportItem(candidate: f.candidate([b], F.meta("Book B", "Author B")), cover: .set(F.png)),
            ImportItem(candidate: f.candidate([c], F.meta("Book C", "Author C"))),
        ])

        #expect(result.outcomes.count == 3)
        let aId = try f.importedId(result.outcomes[0])
        let cId = try f.importedId(result.outcomes[2])
        // I4: a readable reason, naming the file.
        let reason = try #require(isFailed(result.outcomes[1]))
        #expect(reason.contains("already exists"))
        #expect(reason.contains("Book B.m4b"))
        #expect(!reason.contains("destinationExists"))

        // The second book: file still in the inbox as it was, nothing in the database,
        // the occupying file untouched.
        #expect(f.inboxTree() == ["b.m4b"])
        #expect(try f.bytes(b) == bBytes)
        #expect(try read(occupied) == "already here")
        #expect(try f.store.books().map(\.title) == ["Book A", "Book C"])
        #expect(try f.store.books().compactMap(\.id) == [aId, cId])
        #expect(exists(f.lib("Author A/Book A/Book A.m4b")))
        #expect(exists(f.lib("Author C/Book C/Book C.m4b")))
        #expect(f.hiddenTree().filter { $0.hasPrefix("covers/") }.isEmpty)

        // I11: the batch counts and records only what was imported.
        let batch = try #require(try f.store.lastBatch())
        #expect(batch.label == "Import 2 books")
        #expect(batch.moves.map(\.from) == [a.path, c.path])
        #expect(try f.snapshot().books.map(\.bookId) == [aId, cId])
    }

    // I4: a move that fails part-way leaves no trace of the book in the library.
    @Test func failedMoveLeavesNoTraceOfTheBook() throws {
        let fm = FailingFileManager()
        let f = try F(organiser: Organiser(fileManager: fm))
        let parts = try f.makeMP3Parts(folder: "rip", tags: F.meta("Old", "Old Author"))
        let before = try parts.map { try f.bytes($0) }
        fm.failMovesTo = [f.lib("Frank Herbert/Dune/02 - Dune.mp3").path]

        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate(parts, F.meta("Dune", "Frank Herbert")))
        ])

        let reason = try #require(isFailed(result.outcomes[0]))
        #expect(!reason.isEmpty)
        #expect(f.libraryTree().isEmpty)
        #expect(f.inboxTree() == ["rip", "rip/part1.mp3", "rip/part2.mp3"])
        #expect(try parts.map { try f.bytes($0) } == before)
        #expect(try f.store.books().isEmpty)
        #expect(try f.store.lastBatch() == nil)  // I13
    }

    // I1: a candidate that cannot be imported at all fails on its own.
    @Test func missingOrUnsupportedFilesFailTheItem() throws {
        let f = try F()
        let good = try f.makeM4B("good.m4b", tags: F.meta("x", "y"))
        let text = try touch(f.inbox.appendingPathComponent("notes.txt"))
        let gone = f.inbox.appendingPathComponent("gone.m4b")

        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([gone], F.meta("Gone", "Ann Author"))),
            ImportItem(candidate: f.candidate([text], F.meta("Notes", "Ann Author"))),
            ImportItem(candidate: CandidateBook(files: [], metadata: F.meta("Empty", "Ann Author"))),
            ImportItem(candidate: f.candidate([gone], BookMetadata(title: "Unfiled and gone"))),
            ImportItem(candidate: f.candidate([good], F.meta("Good", "Ann Author"))),
        ])

        #expect(try #require(isFailed(result.outcomes[0])).contains("gone.m4b"))
        #expect(try #require(isFailed(result.outcomes[1])).contains("notes.txt"))
        #expect(isFailed(result.outcomes[2]) != nil)
        #expect(try #require(isFailed(result.outcomes[3])).contains("gone.m4b"))
        _ = try f.importedId(result.outcomes[4])
        #expect(try f.store.books().map(\.title) == ["Good"])
        #expect(exists(text))
    }

    // I6, I9
    @Test func lockedFileStillImports() throws {
        let f = try F()
        let fm = FileManager.default
        let locked = try f.makeM4B("locked.m4b", tags: F.meta("Old Title", "Old Author"))
        let lockedToo = try f.makeM4B("locked2.m4b", tags: F.meta("Old Title", "Old Author"))
        let dest = f.lib("Ann Author/Locked/Locked.m4b")
        let dest2 = f.lib("Ann Author/Locked Too/Locked Too.m4b")
        for url in [locked, lockedToo] {
            try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        }
        // Make the files writable again wherever they end up, so the temp folder can be cleaned.
        defer {
            for url in [locked, lockedToo, dest, dest2] {
                try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            }
        }
        let before = try f.bytes(locked)

        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([locked], F.fullMeta("Locked", "Ann Author"))),
            ImportItem(candidate: f.candidate([lockedToo], F.meta("Locked Too", "Ann Author")), cover: .set(F.png)),
        ])

        // I6: moved into the library all the same, with the problem recorded twice over.
        guard case .imported(let id, let problems) = result.outcomes[0],
              case .imported(let id2, let problems2) = result.outcomes[1]
        else {
            Issue.record("expected two imports, got \(result.outcomes)")
            return
        }
        #expect(!exists(locked))
        let lockedDest = f.lib("Ann Author/The Series/2 - Locked/Locked.m4b")
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockedDest.path) }
        #expect(exists(lockedDest))
        #expect(try f.bytes(lockedDest) == before)  // nothing was written into it
        #expect(problems.map(\.file) == ["Locked.m4b"])
        let reason = try #require(problems.first?.reason)
        #expect(reason.contains("locked") || reason.contains("read-only"))
        let file = try #require(try f.store.files(bookId: id).first)
        #expect(file.writeProblem == reason)
        #expect(file.path == "Ann Author/The Series/2 - Locked/Locked.m4b")

        // I9: no file was written, so every text field is in the app only. There is no
        // stored cover, so the cover is not listed.
        let book = try #require(try f.store.book(id: id))
        #expect(book.title == "Locked")
        #expect(book.appOnlyFields == allText)
        #expect(f.service.covers.url(for: id) == nil)

        // I9: with a cover set that the locked file could not take, every field is listed.
        #expect(problems2.map(\.file) == ["Locked Too.m4b"])
        #expect(exists(dest2))
        #expect(try #require(try f.store.book(id: id2)).appOnlyFields == MetadataField.allCases)
        #expect(f.service.covers.image(for: id2) == F.png)
        #expect(try f.io.read(dest2).cover == nil)

        // I11: a file that was not written has no state to restore.
        #expect(try f.snapshot().books.map(\.fileStates.count) == [0, 0])
    }

    // I3, I6: a file that is not what its extension says is filed, flagged, and offers nothing.
    @Test func unreadableFileStillImports() throws {
        let f = try F()
        let fake = try touch(f.inbox.appendingPathComponent("fake.epub"), "this is not an EPUB")
        let m4b = try f.makeM4B("real.m4b", tags: F.meta("Old", "Old Author"))

        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([m4b, fake], F.meta("Mixed", "Ann Author")))
        ])

        guard case .imported(let id, let problems) = try #require(result.outcomes.first) else {
            Issue.record("expected .imported, got \(result.outcomes)")
            return
        }
        #expect(problems.map(\.file) == ["Mixed.epub"])
        #expect(try read(f.lib("Ann Author/Mixed/Mixed.epub")) == "this is not an EPUB")
        let files = try f.store.files(bookId: id)
        #expect(files.map { $0.writeProblem == nil } == [true, false])
        // The audio file was written, so nothing is app-only.
        #expect(try #require(try f.store.book(id: id)).appOnlyFields == [])
        // I3: only the readable, written file has a state.
        let states = try f.snapshot().books[0].fileStates
        #expect(states.map(\.pathAfter) == [f.lib("Ann Author/Mixed/Mixed.m4b").path])
    }

    // I9: formats that are never opened hold nothing.
    @Test func mobiOnlyBookListsEveryField() throws {
        let f = try F()
        let mobi = try touch(f.inbox.appendingPathComponent("book.mobi"), "opaque bytes")

        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([mobi], F.fullMeta("Kindle Book", "Ann Author")), cover: .set(F.jpeg))
        ])

        let id = try f.importedId(result.outcomes[0])
        let dest = f.lib("Ann Author/The Series/2 - Kindle Book/Kindle Book.mobi")
        #expect(try read(dest) == "opaque bytes")
        let book = try #require(try f.store.book(id: id))
        #expect(book.appOnlyFields == MetadataField.allCases)
        #expect(try f.store.files(bookId: id).map(\.writeProblem) == [nil])
        #expect(f.service.covers.image(for: id) == F.jpeg)
    }

    // I14
    @Test func copyModeLeavesOriginalsUntouched() throws {
        let f = try F()
        let original = F.meta("Old Title", "Old Author")
        let source = try f.makeM4B("keepme.m4b", tags: original, cover: F.jpeg)
        let before = try f.bytes(source)
        let reviewed = F.fullMeta("Copied", "Ann Author")

        let id = try f.importNew([source], reviewed, cover: .set(F.png), mode: .copy)

        #expect(exists(source))
        #expect(try f.bytes(source) == before)
        #expect(try f.tags(source) == original)
        let dest = f.lib("Ann Author/The Series/2 - Copied/Copied.m4b")
        #expect(try f.tags(dest) == reviewed)
        #expect(try f.io.read(dest).cover == F.png)
        #expect(try f.store.files(bookId: id).map(\.path) == ["Ann Author/The Series/2 - Copied/Copied.m4b"])
        let batch = try #require(try f.store.lastBatch())
        #expect(batch.moves == [MoveRecord(from: source.path, to: dest.path, wasCopy: true)])
    }

    // I2
    @Test func adoptsExistingAuthorFolderCapitalisation() throws {
        let f = try F()
        try FileManager.default.createDirectory(at: f.lib("andy weir"), withIntermediateDirectories: true)
        let source = try f.makeM4B("a.m4b", tags: F.meta("x", "y"))

        let id = try f.importNew([source], F.meta("Artemis", "Andy Weir"))

        #expect(f.libraryTree() == ["andy weir", "andy weir/Artemis", "andy weir/Artemis/Artemis.m4b"])
        let book = try #require(try f.store.book(id: id))
        #expect(book.folderPath == "andy weir/Artemis")
        #expect(book.authors == ["Andy Weir"])  // the database keeps the reviewed spelling
        let files = try f.store.files(bookId: id)
        #expect(files.map(\.path) == ["andy weir/Artemis/Artemis.m4b"])
        #expect(exists(f.store.url(for: try #require(files.first))))
        #expect(try f.tags(f.lib("andy weir/Artemis/Artemis.m4b")).authors == ["Andy Weir"])
        #expect(try f.store.lastBatch()?.moves.map(\.to) == [f.lib("andy weir/Artemis/Artemis.m4b").path])
    }

    // I11
    @Test func journalAndSnapshot() throws {
        let f = try F()
        let firstTags = F.fullMeta("First Original", "First Writer")
        let secondTags = F.meta("Second Original", "Second Writer")
        let m4b = try f.makeM4B("one.m4b", tags: firstTags, cover: F.jpeg)
        let parts = try f.makeMP3Parts(folder: "two", tags: secondTags)
        let m4bRead = try f.io.read(m4b).metadata
        let partReads = try parts.map { try f.io.read($0).metadata }
        try f.store.recordBatch(label: "older", moves: [])

        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([m4b], F.meta("One", "Ann Author")), cover: .set(F.png)),
            ImportItem(candidate: f.candidate(parts, F.meta("Two", "Ben Author"))),
        ])
        let one = try f.importedId(result.outcomes[0])
        let two = try f.importedId(result.outcomes[1])

        let oneDest = f.lib("Ann Author/One/One.m4b")
        let twoDests = [f.lib("Ben Author/Two/01 - Two.mp3"), f.lib("Ben Author/Two/02 - Two.mp3")]
        let batch = try #require(try f.store.lastBatch())
        #expect(batch.label == "Import 2 books")
        #expect(batch.moves == [
            MoveRecord(from: m4b.path, to: oneDest.path, wasCopy: false),
            MoveRecord(from: parts[0].path, to: twoDests[0].path, wasCopy: false),
            MoveRecord(from: parts[1].path, to: twoDests[1].path, wasCopy: false),
        ])
        // S5: the older batch was replaced.
        let batches = try f.store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM operationBatch")
        }
        #expect(batches == 1)

        let snapshot = try f.snapshot()
        #expect(!snapshot.token.isEmpty)
        #expect(snapshot.books.count == 2)
        #expect(snapshot.books.map(\.bookId) == [one, two])
        #expect(snapshot.books.allSatisfy { $0.bookBefore == nil })
        #expect(snapshot.books.allSatisfy { $0.filesBefore.isEmpty })
        #expect(snapshot.books.allSatisfy { $0.storedCoverBefore == nil })

        let oneStates = snapshot.books[0].fileStates
        #expect(oneStates.map(\.pathAfter) == [oneDest.path])
        #expect(oneStates.map(\.metadataBefore) == [m4bRead])
        #expect(oneStates[0].metadataBefore.title == "First Original")
        // The cover inside the file was replaced, so the old one is kept for undo.
        guard case .saved(let fileName)? = oneStates[0].coverBefore else {
            Issue.record("expected a saved cover, got \(String(describing: oneStates[0].coverBefore))")
            return
        }
        let saved = f.service.layout.undoFolder
            .appendingPathComponent(snapshot.token).appendingPathComponent(fileName)
        #expect(try f.bytes(saved) == F.jpeg.data)

        let twoStates = snapshot.books[1].fileStates
        #expect(twoStates.map(\.pathAfter) == twoDests.map(\.path))
        #expect(twoStates.map(\.metadataBefore) == partReads)
        #expect(twoStates.allSatisfy { $0.metadataBefore.title == "Second Original" })
        // The cover was not touched in these files.
        #expect(twoStates.allSatisfy { $0.coverBefore == nil })
    }

    // Decision "Undo depth": a new operation discards the previous one's undo data.
    @Test func newOperationDiscardsOlderUndoData() throws {
        let f = try F()
        let a = try f.makeM4B("a.m4b", tags: F.meta("x", "y"), cover: F.jpeg)
        _ = try f.importNew([a], F.meta("A", "Ann Author"), cover: .set(F.png))
        let firstToken = try f.snapshot().token
        #expect(f.hiddenTree().contains("undo/\(firstToken)"))

        let b = try f.makeM4B("b.m4b", tags: F.meta("x", "y"), cover: F.jpeg)
        _ = try f.importNew([b], F.meta("B", "Ann Author"), cover: .remove)
        let secondToken = try f.snapshot().token

        #expect(secondToken != firstToken)
        #expect(!f.hiddenTree().contains("undo/\(firstToken)"))
        #expect(f.hiddenTree().contains("undo/\(secondToken)"))
    }

    // I12
    @Test func commitFailureRollsEverythingBack() throws {
        let f = try F()
        let m4bTags = F.fullMeta("First Original", "First Writer")
        let m4b = try f.makeM4B("one.m4b", tags: m4bTags, cover: F.jpeg)
        let parts = try f.makeMP3Parts(folder: "two", tags: F.meta("Second Original", "Second Writer"))
        let copied = try f.makeM4B("three.m4b", tags: F.meta("Third", "Third Writer"))
        let unfiled = try f.makeM4B("four.m4b", tags: F.meta("Fourth", "Fourth Writer"), cover: F.jpeg)
        let earlier = try f.store.recordBatch(
            label: "earlier", moves: [MoveRecord(from: "/a", to: "/b", wasCopy: false)])
        let inboxBefore = f.inboxTree()
        var calls = 0
        f.service.beforeCommit = {
            calls += 1
            throw Boom()
        }
        let items = [
            ImportItem(candidate: f.candidate([m4b], F.meta("One", "Ann Author")), cover: .set(F.png)),
            ImportItem(candidate: f.candidate(parts, F.meta("Two", "Ben Author"))),
            ImportItem(candidate: f.candidate([unfiled], BookMetadata(title: "No Author"))),
        ]

        #expect(throws: Boom.self) { try f.service.importItems(items) }
        // And a copy-mode call, whose copies must be deleted again.
        let copiedBytes = try f.bytes(copied)
        #expect(throws: Boom.self) {
            try f.service.importItems(
                [ImportItem(candidate: f.candidate([copied], F.meta("Three", "Cat Author")))],
                options: ImportOptions(mode: .copy))
        }
        #expect(calls == 2)

        // Files are back where they were, and the library has no book folders.
        #expect(f.inboxTree() == inboxBefore)
        #expect(f.libraryTree().isEmpty)
        #expect(try f.bytes(copied) == copiedBytes)
        // No rows, no stored covers, no undo data; the journal is as it was.
        #expect(try f.store.books().isEmpty)
        let fileRows = try f.store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookFile")
        }
        #expect(fileRows == 0)
        #expect(f.hiddenTree().filter { $0.hasPrefix("covers/") || $0.hasPrefix("undo/") }.isEmpty)
        let batch = try #require(try f.store.lastBatch())
        #expect(batch.id == earlier)
        #expect(batch.label == "earlier")
        // Best effort: the tags and cover written before the commit are put back.
        #expect(try f.tags(m4b) == m4bTags)
        #expect(try f.io.read(m4b).cover == F.jpeg)
        for part in parts {
            #expect(try f.tags(part) == F.meta("Second Original", "Second Writer"))
        }

        // The same call then succeeds once the commit works.
        f.service.beforeCommit = nil
        let result = try f.service.importItems(items)
        _ = try f.importedId(result.outcomes[0])
        _ = try f.importedId(result.outcomes[1])
        #expect(try f.store.books().count == 3)
    }

    // I11: the seam runs once per committing call, before the database changes.
    @Test func beforeCommitRunsOncePerCommit() throws {
        let f = try F()
        let a = try f.makeM4B("a.m4b", tags: F.meta("x", "y"))
        var seen: [Int] = []
        f.service.beforeCommit = { [store = f.store] in
            seen.append(try store.books().count)
        }
        _ = try f.importNew([a], F.meta("A", "Ann Author"))
        #expect(seen == [0])
        // I13: nothing to commit, so the seam is not reached.
        let result = try f.service.importItems([])
        #expect(result.outcomes.isEmpty)
        #expect(seen == [0])
    }

    // I13
    @Test func nothingImportedLeavesJournalAlone() throws {
        let f = try F()
        let b = try f.makeM4B("b.m4b", tags: F.meta("x", "y"), cover: F.jpeg)
        try touch(f.lib("Author B/Book B/Book B.m4b"))
        let moves = [MoveRecord(from: "/in/a.mp3", to: "/lib/a.mp3", wasCopy: false)]
        let earlier = try f.store.recordBatch(label: "earlier", moves: moves)
        // Undo data of the earlier operation must survive too.
        let earlierData = try touch(
            f.service.layout.undoFolder.appendingPathComponent("earlier-token/cover.img"))

        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([b], F.meta("Book B", "Author B")), cover: .set(F.png)),
            ImportItem(candidate: f.candidate([f.inbox.appendingPathComponent("gone.m4b")], F.meta("G", "H"))),
        ])

        #expect(result.outcomes.count == 2)
        #expect(result.outcomes.allSatisfy { isFailed($0) != nil })
        let batch = try #require(try f.store.lastBatch())
        #expect(batch.id == earlier)
        #expect(batch.label == "earlier")
        #expect(batch.moves == moves)
        #expect(exists(earlierData))
        #expect(f.hiddenTree() == ["undo", "undo/earlier-token", "undo/earlier-token/cover.img"])
        #expect(try f.store.books().isEmpty)
    }

    // I15
    @Test func existingMatchRules() throws {
        let f = try F()
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        func add(_ title: String, _ authors: [String], daysLater: Double, needsAttention: Bool = false) throws -> Int64 {
            let book = Book(
                metadata: BookMetadata(title: title, authors: authors),
                needsAttention: needsAttention, dateAdded: day.addingTimeInterval(daysLater * 86_400))
            return try #require(try f.store.insert(book, files: []).id)
        }
        func match(_ title: String, _ authors: [String]) throws -> Int64? {
            try f.service.existingMatch(
                for: CandidateBook(files: [], metadata: BookMetadata(title: title, authors: authors)))?.id
        }
        // Inserted out of date order, so "earliest added" is not simply the lowest id.
        let later = try add("Project Hail Mary", ["Andy Weir", "Someone Else"], daysLater: 5)
        let earliest = try add("project hail mary", ["ANDY WEIR"], daysLater: 1)
        _ = try add("Project Hail Mary", ["Andy Weir"], daysLater: 0, needsAttention: true)
        let dune = try add("Dune", ["Frank Herbert"], daysLater: 2)
        let untitled = try add("", ["Nobody"], daysLater: 3)
        _ = (later, untitled)

        // Case and surrounding spaces are ignored; only the first author counts.
        #expect(try match("  PROJECT hail MARY ", [" andy weir  ", "Other"]) == earliest)
        #expect(try match("Dune", ["frank herbert"]) == dune)
        // Different title or first author: no match.
        #expect(try match("Dune Messiah", ["Frank Herbert"]) == nil)
        #expect(try match("Dune", ["Brian Herbert", "Frank Herbert"]) == nil)
        // Nil when the candidate lacks a title or an author.
        #expect(try match("", ["Nobody"]) == nil)
        #expect(try match("   ", ["Nobody"]) == nil)
        #expect(try match("Dune", []) == nil)
        #expect(try match("Dune", ["  "]) == nil)

        // A needs-attention book alone is never a match.
        _ = try add("Lonely", ["Ann Author"], daysLater: 0, needsAttention: true)
        #expect(try match("Lonely", ["Ann Author"]) == nil)
    }

    @Test func scanUsesRealTags() throws {
        let f = try F()
        var tags = F.meta("Real Title", "Real Author")
        tags.series = "Real Series"
        let url = try f.makeM4B("Wrong Person - Misleading Name.m4b", tags: tags)

        let result = f.service.scan([url])

        #expect(result.skipped.isEmpty)
        #expect(result.candidates.count == 1)
        let candidate = try #require(result.candidates.first)
        #expect(candidate.metadata.title == "Real Title")
        #expect(candidate.metadata.authors == ["Real Author"])
        #expect(candidate.metadata.series == "Real Series")
        #expect(candidate.files == [CandidateFile(url: url, role: .audio)])
    }

    // The public initialiser wires the same collaborators around the store's library.
    @Test func publicInitUsesTheStoresLibrary() throws {
        let root = try makeTempDir()
        let store = try LibraryStore(libraryRoot: root)
        let service = LibraryService(store: store)
        #expect(service.store === store)
        #expect(service.layout.root == root)
        #expect(service.covers.url(for: 1) == nil)
        #expect(service.beforeCommit == nil)
        #expect(ImportOptions().mode == .move)
        let item = ImportItem(candidate: CandidateBook(files: [], metadata: BookMetadata()))
        #expect(item.target == .newBook)
        #expect(item.cover == .keep)
    }
}
