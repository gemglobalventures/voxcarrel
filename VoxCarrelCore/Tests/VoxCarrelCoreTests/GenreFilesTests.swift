import Foundation
import GRDB
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// The books whose files hold another genre tag than the library would write, and
/// bringing those files in line when asked.
@Suite struct GenreFilesTests {
    typealias F = LibraryFixture

    static let thrillers = "Thrillers & Spies"

    /// A book of one M4B whose file carries `tag` as its genre tag.
    func importM4B(_ f: F, title: String, tag: String?) throws -> Int64 {
        var tags = F.meta(title, "Mick Herron")
        tags.genres = tag.map { [$0] } ?? []
        let url = try f.makeM4B("\(title).m4b", tags: tags)
        let candidate = try #require(f.service.scan([url]).candidates.first)
        let result = try f.service.importItems([ImportItem(candidate: candidate)])
        return try f.importedId(try #require(result.outcomes.first))
    }

    func urls(_ f: F, _ id: Int64) throws -> [URL] {
        try f.store.files(bookId: id).map { f.store.url(for: $0) }
    }

    /// The genre tag inside a file, exactly as it stands.
    func tag(_ url: URL) throws -> String? {
        try FileMetadataIO().read(url).metadata.genreSource
    }

    /// Gives a book other genres in the catalogue only, as a change to the list does.
    func setGenres(_ f: F, _ id: Int64, _ genres: [String]) throws {
        var book = try #require(try f.store.book(id: id))
        book.genres = genres
        try f.store.update(book)
    }

    func saved(_ outcome: SaveOutcome?, sourceLocation: SourceLocation = #_sourceLocation) -> [FileProblem]? {
        guard case .saved(_, let refiled, _, let problems) = outcome else {
            Issue.record("expected .saved, got \(String(describing: outcome))", sourceLocation: sourceLocation)
            return nil
        }
        #expect(!refiled, sourceLocation: sourceLocation)
        return problems
    }

    // MARK: G13 Counting

    @Test func G13_aBookIsCountedWhenItsFilesHoldAnotherTagThanWouldBeWritten() throws {
        let f = try F()
        let same = try importM4B(f, title: "Same", tag: "Horror")
        let other = try importM4B(f, title: "Other", tag: "Fantasy")
        #expect(try f.service.genreFileDifferences().isEmpty)

        try setGenres(f, other, [Self.thrillers, "Fantasy"])
        let differences = try f.service.genreFileDifferences()
        #expect(differences == [
            LibraryService.GenreFileDifference(
                id: other, title: "Other", fileCount: 1, tagNow: "Fantasy", tagAfter: "Thrillers & Spies; Fantasy"),
        ])
        _ = same
    }

    @Test func G13_listChangesLeaveTheirBooksCounted() throws {
        let f = try F()
        let renamed = try importM4B(f, title: "Renamed", tag: "Pub Quiz")
        let merged = try importM4B(f, title: "Merged", tag: "Trivia")
        let deleted = try importM4B(f, title: "Deleted", tag: "Oddments")
        let moved = try importM4B(f, title: "Moved", tag: "Horror")
        try f.service.renameGenre("Pub Quiz", to: "Quizzes")
        try f.service.mergeGenre("Trivia", into: "Reference & Learning")
        try f.service.deleteGenre("Oddments")
        try f.service.moveGenre("Horror", to: .other)
        let differences = try f.service.genreFileDifferences()
        // By title. The one that only moved to another group is as its file has it.
        #expect(differences.map(\.id) == [deleted, merged, renamed])
        #expect(differences.map(\.tagNow) == ["Oddments", "Trivia", "Pub Quiz"])
        #expect(differences.map(\.tagAfter) == [nil, "Reference & Learning", "Quizzes"])
        _ = moved
    }

    @Test func G13_noTagAndAnEmptyTagAreTheSame() throws {
        let f = try F()
        let id = try importM4B(f, title: "Untagged", tag: nil)
        #expect(try f.store.book(id: id)?.genreTag == nil)
        var book = try #require(try f.store.book(id: id))
        book.genreTag = ""
        try f.store.update(book)
        #expect(try f.service.genreFileDifferences().isEmpty)
        book.genreTag = "  "
        try f.store.update(book)
        #expect(try f.service.genreFileDifferences().isEmpty)
    }

    @Test func G13_aBookCataloguedWhereItIsIsCountedByTheTagItsFileHolds() throws {
        let f = try F()
        var tags = F.meta("Loose", "Mick Herron")
        tags.genres = ["Fantasy"]
        let url = try f.makeM4B("loose/Loose.m4b", tags: tags)
        let bytes = try Data(contentsOf: url)
        // No author: it cannot be filed, so it is catalogued where it is and not written.
        let result = try f.service.importItems([ImportItem(candidate: f.candidate([url], BookMetadata(title: "Loose")))])
        guard case .needsAttention(let id) = try #require(result.outcomes.first) else {
            Issue.record("expected the book to be catalogued in place, got \(result.outcomes)")
            return
        }
        #expect(try Data(contentsOf: url) == bytes)
        let book = try #require(try f.store.book(id: id))
        #expect(book.genres == [])
        #expect(book.genreTag == "Fantasy")
        #expect(try f.service.genreFileDifferences() == [
            LibraryService.GenreFileDifference(id: id, title: "Loose", fileCount: 1, tagNow: "Fantasy", tagAfter: nil),
        ])
    }

    @Test func G13_theCountOpensNoFile() throws {
        let f = try F()
        let id = try importM4B(f, title: "Gone", tag: "Fantasy")
        try setGenres(f, id, ["Horror"])
        let expected = try f.service.genreFileDifferences()
        #expect(expected.count == 1)
        // With nothing there to open, it says the same.
        let url = try #require(try urls(f, id).first)
        try FileManager.default.removeItem(at: url)
        try Data("not audio".utf8).write(to: url)
        let stamp = try #require(FileStamp(fileAt: url))
        #expect(try f.service.genreFileDifferences() == expected)
        #expect(FileStamp(fileAt: url) == stamp)
        try FileManager.default.removeItem(at: url)
        #expect(try f.service.genreFileDifferences() == expected)
    }

    @Test func G13_G12_aLibraryJustConvertedCountsTheBooksWhoseOldTextWasMapped() throws {
        let root = try makeTempDir()
        let queue = try DatabaseQueue(path: root.appendingPathComponent(LibraryStore.databaseFileName).path)
        try LibraryStore.migrator.migrate(queue, upTo: "v11")
        try queue.write { db in
            for (index, genre) in ["Mystery, Thriller & Suspense", "Horror", "Audiobook", nil].enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO book (title, authors, narrators, genre, tags, rating, needsAttention, dateAdded,
                                          readStatus, folderPath)
                        VALUES (?, '["An Author"]', '[]', ?, '[]', 0, 0, '2025-01-02 03:04:05.000', 'unread', ?)
                        """,
                    arguments: ["Book \(index + 1)", genre, "An Author/Book \(index + 1)"])
                try db.execute(
                    sql: "INSERT INTO bookFile (bookId, path, format, role, position) VALUES (?, ?, 'm4b', 'audio', 0)",
                    arguments: [index + 1, "An Author/Book \(index + 1)/Book \(index + 1).m4b"])
            }
        }
        try queue.close()
        let service = LibraryService(store: try LibraryStore(libraryRoot: root))
        let differences = try service.genreFileDifferences()
        // "Horror" is what would be written; a book with no text has nothing to change.
        #expect(differences.map(\.title) == ["Book 1", "Book 3"])
        #expect(differences.map(\.tagNow) == ["Mystery, Thriller & Suspense", "Audiobook"])
        #expect(differences.map(\.tagAfter) == [Self.thrillers, nil])
    }

    // MARK: G15 Files that cannot hold a genre

    @Test func G15_aBookWhoseFilesCannotHoldAGenreIsNotCountedAndNotWritten() throws {
        let f = try F()
        let pdf = try f.importNew([try f.makePDF("Paper.pdf")], F.meta("Paper", "An Author"))
        var elsewhere = Book(metadata: F.meta("Elsewhere", "An Author"))
        elsewhere.externalCopies = [ExternalCopy(kind: .audible, form: .audio)]
        let noFiles = try #require(try f.store.insert(elsewhere, files: []).id)
        for id in [pdf, noFiles] {
            var book = try #require(try f.store.book(id: id))
            book.genres = ["Horror"]
            book.genreTag = "Something Else"
            try f.store.update(book)
        }
        #expect(try f.service.genreFileDifferences().isEmpty)

        let url = try #require(try urls(f, pdf).first)
        let bytes = try Data(contentsOf: url)
        let before = try f.store.books()
        let label = try f.service.undoLabel()
        let outcomes = try f.service.updateGenreFiles([pdf, noFiles])
        #expect(saved(outcomes.first) == [])
        #expect(saved(outcomes.last) == [])
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try f.store.books() == before)
        #expect(try f.service.undoLabel() == label)
    }

    @Test func G15_onlyTheFilesThatCanHoldAGenreAreCountedAndWritten() throws {
        let f = try F()
        let audio = try f.makeM4B("Both.m4b", tags: F.meta("Both", "An Author"))
        let pdf = try f.makePDF("Both.pdf")
        let id = try f.importNew([audio, pdf], F.meta("Both", "An Author"))
        try setGenres(f, id, ["Horror"])
        let differences = try f.service.genreFileDifferences()
        #expect(differences.map(\.fileCount) == [1])

        let places = try urls(f, id)
        let paper = try #require(places.first { $0.pathExtension == "pdf" })
        let bytes = try Data(contentsOf: paper)
        let stamp = FileStamp(fileAt: paper)
        #expect(saved(try f.service.updateGenreFiles([id]).first) == [])
        #expect(try tag(try #require(places.first { $0.pathExtension == "m4b" })) == "Horror")
        #expect(try Data(contentsOf: paper) == bytes)
        #expect(FileStamp(fileAt: paper) == stamp)
        #expect(try f.service.genreFileDifferences().isEmpty)
    }

    @Test func G15_anEbookKeptAsAnExtraIsNotCountedAndNotWritten() throws {
        let f = try F()
        var tags = F.meta("Both", "An Author")
        tags.genres = ["Fantasy"]
        let audio = try f.makeM4B("Both.m4b", tags: tags)
        let extra = try f.makeEPUB("Both.epub")
        let result = try f.service.importItems(
            [ImportItem(candidate: f.candidate([audio, extra], tags, roles: [extra: .extra]))])
        let id = try f.importedId(try #require(result.outcomes.first))
        #expect(try f.store.files(bookId: id).map(\.role) == [.audio, .extra])
        try setGenres(f, id, ["Horror"])
        #expect(try f.service.genreFileDifferences().map(\.fileCount) == [1])

        let places = try urls(f, id)
        let kept = try #require(places.first { $0.pathExtension == "epub" })
        let bytes = try Data(contentsOf: kept)
        let stamp = FileStamp(fileAt: kept)
        #expect(saved(try f.service.updateGenreFiles([id]).first) == [])
        #expect(try tag(try #require(places.first { $0.pathExtension == "m4b" })) == "Horror")
        #expect(try Data(contentsOf: kept) == bytes)
        #expect(FileStamp(fileAt: kept) == stamp)
        #expect(try f.service.genreFileDifferences().isEmpty)
    }

    // MARK: G14 Update files

    @Test func G14_theChosenBooksFilesAreWrittenAsOneOperationInEveryFormat() throws {
        let f = try F()
        let m4b = try importM4B(f, title: "Single", tag: "Fantasy")
        let parts = try f.importNew(
            try f.makeMP3Parts(folder: "Parts", tags: F.meta("Parts", "An Author")), F.meta("Parts", "An Author"))
        let epub = try f.importNew([try f.makeEPUB("Read.epub")], F.meta("Read", "An Author"))
        let untouched = try importM4B(f, title: "Not Chosen", tag: "Romance")
        try setGenres(f, m4b, [Self.thrillers, "Pub Quiz"])
        try setGenres(f, parts, ["Horror"])
        try setGenres(f, epub, ["History", "Biography & Memoir"])
        try setGenres(f, untouched, ["Classics"])
        #expect(try f.service.genreFileDifferences().count == 4)
        #expect(try f.service.genreFileDifferences().first { $0.id == parts }?.fileCount == 2)

        let outcomes = try f.service.updateGenreFiles([m4b, parts, epub])
        #expect(outcomes.count == 3)
        for outcome in outcomes { #expect(saved(outcome) == []) }
        #expect(try urls(f, m4b).map(tag) == ["Thrillers & Spies; Pub Quiz"])
        #expect(try urls(f, parts).map(tag) == ["Horror", "Horror"])
        #expect(try urls(f, epub).map(tag) == ["History; Biography & Memoir"])
        #expect(try f.store.book(id: m4b)?.genreTag == "Thrillers & Spies; Pub Quiz")
        // The one that was not chosen is as it was, and still counted.
        #expect(try urls(f, untouched).map(tag) == ["Romance"])
        #expect(try f.service.genreFileDifferences().map(\.id) == [untouched])
        #expect(try f.service.undoLabel() == "Update genre tags for 3 books")
    }

    @Test func G14_nothingButTheGenreTagChangesInAFileTheLibraryWrote() throws {
        let f = try F()
        let url = try f.makeM4B("Full.m4b", tags: F.fullMeta("Full", "An Author"), cover: F.jpeg)
        let id = try f.importNew([url], F.fullMeta("Full", "An Author"))
        let place = try #require(try urls(f, id).first)
        let before = try f.io.read(place)
        let track = try f.trackTags(place)
        try setGenres(f, id, ["Horror", "Fantasy"])
        let record = try #require(try f.store.book(id: id))

        _ = try f.service.updateGenreFiles([id])
        let after = try f.io.read(place)
        var expected = before.metadata
        expected.genres = GenreMapping.map(.text("Horror; Fantasy")).names
        expected.genreSource = "Horror; Fantasy"
        #expect(after.metadata == expected)
        #expect(after.cover == before.cover)
        #expect(after.chapters == before.chapters)
        #expect(try f.trackTags(place) == track)
        // The record changes in what it knows of the files, and in nothing else.
        var expectedRecord = record
        expectedRecord.genreTag = "Horror; Fantasy"
        #expect(try f.store.book(id: id) == expectedRecord)
        #expect(place == (try urls(f, id).first))
    }

    @Test func G14_aBookWithNoGenresHasTheTagRemoved() throws {
        let f = try F()
        let id = try importM4B(f, title: "Cleared", tag: "Fantasy")
        try setGenres(f, id, [])
        #expect(try f.service.genreFileDifferences().map(\.tagAfter) == [nil])
        _ = try f.service.updateGenreFiles([id])
        #expect(try urls(f, id).map(tag) == [nil])
        #expect(try f.store.book(id: id)?.genreTag == nil)
        #expect(try f.service.genreFileDifferences().isEmpty)
    }

    @Test func G14_aBookThatDoesNotDifferIsNotWritten() throws {
        let f = try F()
        let id = try importM4B(f, title: "Fine", tag: "Fantasy")
        let url = try #require(try urls(f, id).first)
        let bytes = try Data(contentsOf: url)
        let stamp = FileStamp(fileAt: url)
        let label = try f.service.undoLabel()
        #expect(saved(try f.service.updateGenreFiles([id]).first) == [])
        #expect(try Data(contentsOf: url) == bytes)
        #expect(FileStamp(fileAt: url) == stamp)
        #expect(try f.service.undoLabel() == label)
    }

    @Test func G14_aBookThatIsNotInTheLibraryIsReportedAndTheRestAreWritten() throws {
        let f = try F()
        let id = try importM4B(f, title: "Here", tag: "Fantasy")
        try setGenres(f, id, ["Horror"])
        let outcomes = try f.service.updateGenreFiles([9_999, id, id])
        guard case .failed(let missing, _) = outcomes[0] else {
            Issue.record("expected .failed, got \(outcomes[0])")
            return
        }
        #expect(missing == 9_999)
        #expect(saved(outcomes[1]) == [])
        guard case .failed = outcomes[2] else {
            Issue.record("expected the repeat to fail, got \(outcomes[2])")
            return
        }
        #expect(try urls(f, id).map(tag) == ["Horror"])
        #expect(try f.service.undoLabel() == "Update genre tags")
    }

    @Test func G14_aFileThatCannotBeWrittenIsReportedAndTheRestAreStillWritten() throws {
        let f = try F()
        let fm = FileManager.default
        let locked = try importM4B(f, title: "Locked", tag: "Fantasy")
        let free = try importM4B(f, title: "Free", tag: "Fantasy")
        try setGenres(f, locked, ["Horror"])
        try setGenres(f, free, ["Horror"])
        let stuck = try #require(try urls(f, locked).first)
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: stuck.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stuck.path) }

        let outcomes = try f.service.updateGenreFiles([locked, free])
        let problems = try #require(saved(outcomes.first))
        #expect(problems.map(\.file) == ["Locked.m4b"])
        #expect(problems.first?.reason.contains("locked") == true)
        #expect(saved(outcomes.last) == [])
        #expect(try tag(stuck) == "Fantasy")
        #expect(try urls(f, free).map(tag) == ["Horror"])
        // The one that could not be written is still known to differ, and says why.
        #expect(try f.store.book(id: locked)?.genreTag == "Fantasy")
        #expect(try f.store.files(bookId: locked).first?.writeProblem?.contains("locked") == true)
        #expect(try f.service.genreFileDifferences().map(\.id) == [locked])

        // Once it can be written, asking again brings it in line.
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stuck.path)
        #expect(saved(try f.service.updateGenreFiles([locked]).first) == [])
        #expect(try tag(stuck) == "Horror")
        #expect(try f.service.genreFileDifferences().isEmpty)
    }

    @Test func G14_aBookOneOfWhoseFilesCouldNotBeWrittenIsStillCounted() throws {
        let f = try F()
        let fm = FileManager.default
        let id = try f.importNew(
            try f.makeMP3Parts(folder: "Parts", tags: F.meta("Parts", "An Author")), F.meta("Parts", "An Author"))
        try setGenres(f, id, ["Horror"])
        let places = try urls(f, id)
        #expect(places.count == 2)
        let stuck = places[1]
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: stuck.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stuck.path) }

        let problems = try #require(saved(try f.service.updateGenreFiles([id]).first))
        #expect(problems.map(\.file) == [stuck.lastPathComponent])
        #expect(try places.map(tag) == ["Horror", nil])
        // One file took the tag and one did not: the book still differs from its files.
        #expect(try f.store.book(id: id)?.genreTag == nil)
        #expect(try f.service.genreFileDifferences().map(\.id) == [id])

        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stuck.path)
        #expect(saved(try f.service.updateGenreFiles([id]).first) == [])
        #expect(try places.map(tag) == ["Horror", "Horror"])
        #expect(try f.store.book(id: id)?.genreTag == "Horror")
        #expect(try f.service.genreFileDifferences().isEmpty)
    }

    @Test func G14_undoRestoresTheSameRecordsTheSameListAndTheSameTags() throws {
        let f = try F()
        // A tag as another app wrote it, which the library reads as one genre.
        let m4b = try importM4B(f, title: "Single", tag: "Fantasy")
        let parts = try f.importNew(
            try f.makeMP3Parts(folder: "Parts", tags: F.meta("Parts", "An Author")), F.meta("Parts", "An Author"))
        let epub = try f.importNew([try f.makeEPUB("Read.epub")], F.meta("Read", "An Author"))
        try f.service.renameGenre("Fantasy", to: "Magic")
        try setGenres(f, parts, ["Horror", "Pub Quiz"])
        try setGenres(f, epub, ["History"])
        let ids = [m4b, parts, epub]
        let places = try ids.flatMap { try urls(f, $0) }
        let tagsBefore = try places.map(tag)
        let detailsBefore = try places.map { try f.io.read($0).metadata }
        let booksBefore = try f.store.books()
        let filesBefore = try f.store.allFiles()
        let listBefore = try f.store.genreRows()
        #expect(tagsBefore == ["Fantasy", nil, nil, nil])

        _ = try f.service.updateGenreFiles(ids)
        #expect(try places.map(tag) == ["Magic", "Horror; Pub Quiz", "Horror; Pub Quiz", "History"])
        #expect(try f.store.books() != booksBefore)

        #expect(try f.service.undoLast() == "Update genre tags for 3 books")
        #expect(try places.map(tag) == tagsBefore)
        #expect(try places.map { try f.io.read($0).metadata } == detailsBefore)
        #expect(try f.store.books() == booksBefore)
        #expect(try f.store.allFiles().map(\.path) == filesBefore.map(\.path))
        #expect(try f.store.genreRows() == listBefore)
        #expect(try f.service.genreFileDifferences().count == 3)
    }

    @Test func G14_theRecordOfWhatTheFilesHoldIsRightAfterASaveToo() throws {
        let f = try F()
        // G17: a book the owner edits is written on save, and is then not counted.
        let id = try importM4B(f, title: "Edited", tag: "Fantasy")
        let other = try importM4B(f, title: "Counted", tag: "Fantasy")
        try setGenres(f, other, ["Horror"])
        var edit = BookEdit(book: try #require(try f.store.book(id: id)))
        edit.metadata.genres = ["Romance"]
        _ = try f.service.save([edit])
        #expect(try f.service.genreFileDifferences().map(\.id) == [other])
        #expect(try urls(f, other).map(tag) == ["Fantasy"])
    }
}
