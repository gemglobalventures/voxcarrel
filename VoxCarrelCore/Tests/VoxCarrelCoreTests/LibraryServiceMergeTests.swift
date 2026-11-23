import Foundation
import GRDB
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// A file manager whose moves fail for destinations ending in one of the given texts.
final class EndingFailingFileManager: FileManager, @unchecked Sendable {
    var failMovesEndingIn: [String] = []
    private(set) var refused = 0

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if failMovesEndingIn.contains(where: { dstURL.path.hasSuffix($0) }) {
            refused += 1
            throw CocoaError(.fileWriteUnknown)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

/// MB1–MB11: entries that are one book become one entry.
@Suite struct LibraryServiceMergeTests {
    typealias F = LibraryFixture

    static let author = "James Dalton"
    static let title = "Mind Over Markets"
    static let folder = "James Dalton/Mind Over Markets"
    static let audioFolder = "James Dalton/Mind Over Markets (Unabridged)"
    static let companion = "Mind Over Markets [B09WXN61GL]"

    // MARK: Support

    /// Everything a merge may touch, in one comparable value.
    struct Whole: Equatable {
        var books: [Book]
        /// Each book's file rows, with their ids.
        var files: [[BookFile]]
        var tree: [String]
        /// Every file in the library folder, by its path there.
        var bytes: [String: Data]
        var covers: [Int64: Data]
        /// "collection:book" for every membership.
        var memberships: [String]
        /// "record:book" for every sent record.
        var sent: [String]
    }

    private func whole(_ f: F) throws -> Whole {
        let books = try f.store.books().sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        var bytes: [String: Data] = [:]
        for path in f.libraryTree() {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: f.lib(path).path, isDirectory: &isDirectory), !isDirectory.boolValue {
                bytes[path] = try f.bytes(f.lib(path))
            }
        }
        var covers: [Int64: Data] = [:]
        for book in books {
            let id = try #require(book.id)
            if let image = f.service.covers.image(for: id) { covers[id] = image.data }
        }
        let rows = try f.store.dbQueue.read { db in
            (
                try Row.fetchAll(db, sql: "SELECT collectionId, bookId FROM collectionBook ORDER BY 1, 2")
                    .map { "\($0[0] as Int64):\($0[1] as Int64)" },
                try Row.fetchAll(db, sql: "SELECT id, bookId FROM sentRecord ORDER BY 1")
                    .map { "\($0[0] as Int64):\($0[1] as Int64)" }
            )
        }
        return Whole(
            books: books, files: try books.map { try f.store.files(bookId: try #require($0.id)) },
            tree: f.libraryTree(), bytes: bytes, covers: covers, memberships: rows.0, sent: rows.1)
    }

    private func book(_ f: F, _ id: Int64) throws -> Book {
        try #require(try f.store.book(id: id))
    }

    private func paths(_ f: F, _ id: Int64) throws -> [String] {
        try f.store.files(bookId: id).map(\.path)
    }

    private func fileId(_ f: F, _ id: Int64, _ index: Int = 0) throws -> Int64 {
        try #require(try f.store.files(bookId: id)[index].id)
    }

    /// The files of a tree listing: the paths that are not folders.
    private func filesOnly(_ f: F) -> [String] {
        f.libraryTree().filter { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: f.lib(path).path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
    }

    private func refused(_ blocker: MergeBlocker, _ body: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: LibraryError.mergeRefused(blocker), sourceLocation: sourceLocation) { try body() }
    }

    /// The owner's case. A: an audiobook titled "Mind Over Markets", its folder still
    /// "…/Mind Over Markets (Unabridged)", flagged because the folder it belongs in is
    /// B's. B: a PDF "Mind Over Markets". C: a PDF whose name holds "[B09WXN61GL]".
    private func ownersCase(_ f: F) throws -> (a: Int64, b: Int64, c: Int64) {
        let a = try f.importNew(
            [try f.makeM4B("mom.m4b", tags: BookMetadata(), cover: F.jpeg)],
            F.meta("\(Self.title) (Unabridged)", Self.author))
        let b = try f.importNew([try f.makePDF("mom.pdf")], F.meta(Self.title, Self.author))
        let c = try f.importNew([try f.makePDF("companion.pdf", pages: 2)], F.meta(Self.companion, Self.author))
        var edit = BookEdit(book: try book(f, a))
        edit.metadata.title = Self.title
        _ = try f.service.save([edit])
        #expect(try book(f, a).needsAttention)
        #expect(try book(f, a).folderPath == Self.audioFolder)
        #expect(try f.service.unfiledReason(for: a) == LibraryService.folderTakenReason)
        #expect(filesOnly(f) == [
            "\(Self.audioFolder)/\(Self.title) (Unabridged).m4b",
            "James Dalton/\(Self.companion)/\(Self.companion).pdf",
            "\(Self.folder)/\(Self.title).pdf",
        ].sorted())
        return (a, b, c)
    }

    /// An ebook "Dune" and a PDF "Dune Notes", both by Frank Herbert.
    private func ebookAndNotes(_ f: F) throws -> (ebook: Int64, notes: Int64) {
        let ebook = try f.importNew([try f.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))
        let notes = try f.importNew([try f.makePDF("notes.pdf")], F.meta("Dune Notes", "Frank Herbert"))
        return (ebook, notes)
    }

    // MARK: MB1

    @Test func mb1_planningChangesNothingAndSuggestsTheEntryWithAudio() throws {
        let f = try F()
        let (a, b, c) = try ownersCase(f)
        let before = try whole(f)
        let batch = try f.store.lastBatch()
        let hidden = f.hiddenTree()

        let plan = try f.service.planMerge(bookIds: [b, c, a], keep: nil)

        #expect(try whole(f) == before)
        #expect(try f.store.lastBatch() == batch)
        #expect(f.hiddenTree() == hidden)
        #expect(plan.suggestedKeepId == a)
        #expect(plan.keepId == a)
        #expect(plan.blockers.isEmpty)
        #expect(plan.resultFolder == Self.folder)
        // Every file of every entry, the kept entry's first, the others in the order chosen.
        #expect(plan.files.map(\.bookId) == [a, b, c])
        #expect(plan.files.map(\.name) == [
            "\(Self.title) (Unabridged).m4b", "\(Self.title).pdf", "\(Self.companion).pdf",
        ])
        #expect(plan.files.map(\.fileId) == [try fileId(f, a), try fileId(f, b), try fileId(f, c)])

        // The owner's choice of entry to keep is kept; the suggestion stays what it was.
        let other = try f.service.planMerge(bookIds: [b, c, a], keep: b)
        #expect(other.keepId == b)
        #expect(other.suggestedKeepId == a)
        #expect(other.files.map(\.bookId) == [b, c, a])
        #expect(throws: LibraryError.bookNotFound(999)) { try f.service.planMerge(bookIds: [a, b], keep: 999) }
    }

    @Test func mb1_withoutAudioTheFullestEntryIsSuggestedAndTiesGoToTheEarliestAdded() throws {
        let f = try F()
        let (ebook, notes) = try ebookAndNotes(f)
        // Equally filled: the earlier added.
        #expect(try f.service.planMerge(bookIds: [notes, ebook], keep: nil).suggestedKeepId == ebook)
        var later = try book(f, ebook)
        later.dateAdded = try book(f, notes).dateAdded.addingTimeInterval(60)
        try f.store.update(later)
        #expect(try f.service.planMerge(bookIds: [ebook, notes], keep: nil).suggestedKeepId == notes)

        // More filled wins over earlier added.
        var edit = BookEdit(book: try book(f, ebook))
        edit.metadata.genre = "Science Fiction"
        edit.metadata.year = 1965
        _ = try f.service.save([edit])
        #expect(try f.service.planMerge(bookIds: [notes, ebook], keep: nil).suggestedKeepId == ebook)

        // Two entries with audio: neither is "the one with audio", so details decide.
        let one = try f.importNew([try f.makeM4B("one.m4b", tags: BookMetadata())], F.meta("One", "A Writer"))
        let two = try f.importNew([try f.makeM4B("two.m4b", tags: BookMetadata())], F.fullMeta("Two", "A Writer"))
        #expect(try f.service.planMerge(bookIds: [one, two], keep: nil).suggestedKeepId == two)
    }

    // MARK: MB2

    @Test func mb2_anAudibleIdInBracketsIsBThenNineLettersOrDigits() {
        #expect(LibraryService.holdsAudibleId("Mind Over Markets [B09WXN61GL].pdf"))
        #expect(LibraryService.holdsAudibleId("[B09WXN61GL] Mind Over Markets.pdf"))
        #expect(LibraryService.holdsAudibleId("x[Babcdefghi]y"))
        #expect(!LibraryService.holdsAudibleId("Mind Over Markets [B09WXN61G].pdf"))
        #expect(!LibraryService.holdsAudibleId("Mind Over Markets [B09WXN61GLX].pdf"))
        #expect(!LibraryService.holdsAudibleId("Mind Over Markets B09WXN61GL.pdf"))
        #expect(!LibraryService.holdsAudibleId("Mind Over Markets [A09WXN61GL].pdf"))
        #expect(!LibraryService.holdsAudibleId("Mind Over Markets [B09WXN-1GL].pdf"))
    }

    @Test func mb2_rolesAreGuessedFromTheFormatTheNameAndWhatTheKeptBookHas() throws {
        let f = try F()
        let (a, b, c) = try ownersCase(f)
        // Keeping the audiobook: the PDF is the ebook, the one named with an Audible ID an extra.
        let plan = try f.service.planMerge(bookIds: [a, b, c], keep: a)
        #expect(plan.files.map(\.guessedRole) == [.audio, .ebook, .extra])
        #expect(plan.files.map(\.role) == [.audio, .ebook, .extra])

        // Keeping the PDF: the audio is audio; the kept entry's own file keeps its role.
        let keepB = try f.service.planMerge(bookIds: [a, b, c], keep: b)
        #expect(keepB.files.map(\.bookId) == [b, a, c])
        #expect(keepB.files.map(\.guessedRole) == [.ebook, .audio, .extra])

        // A second plain PDF is an extra, because the kept book will already have a PDF ebook.
        let d = try f.importNew([try f.makePDF("slides.pdf")], F.meta("Markets Slides", Self.author))
        let withD = try f.service.planMerge(bookIds: [a, b, d], keep: a)
        #expect(withD.files.map(\.guessedRole) == [.audio, .ebook, .extra])
        // In the other order it is the first PDF that becomes the ebook.
        let dFirst = try f.service.planMerge(bookIds: [a, d, b], keep: a)
        #expect(dFirst.files.map(\.bookId) == [a, d, b])
        #expect(dFirst.files.map(\.guessedRole) == [.audio, .ebook, .extra])

        // The owner's role for a file is used; the guess stays what it would be without it,
        // and the guesses for the files after it follow what the book will have.
        let pdfOfB = try fileId(f, b)
        let chosen = try f.service.planMerge(bookIds: [a, b, d], keep: a, roles: [pdfOfB: .extra])
        #expect(chosen.files.map(\.role) == [.audio, .extra, .ebook])
        #expect(chosen.files.map(\.guessedRole) == [.audio, .ebook, .ebook])
    }

    @Test func mb2_ebookFormatsAreEbooksAndExtrasStayExtras() throws {
        let f = try F()
        let kept = try f.importNew(
            [try f.makeM4B("dune.m4b", tags: BookMetadata())], F.meta("Dune", "Frank Herbert"))
        let epub = try f.importNew([try f.makeEPUB("dune.epub")], F.meta("Dune Ebook", "Frank Herbert"))
        let mobiURL = try touch(f.inbox.appendingPathComponent("dune.mobi"), "mobi")
        let mapURL = try f.makePDF("map.pdf")
        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([mobiURL, mapURL], F.meta("Dune Kindle", "Frank Herbert"), roles: [mapURL: .extra]))
        ])
        let mobi = try f.importedId(try #require(result.outcomes.first))

        let plan = try f.service.planMerge(bookIds: [kept, epub, mobi], keep: kept)
        #expect(plan.files.map(\.name) == ["Dune.m4b", "Dune Ebook.epub", "Dune Kindle.mobi", "map.pdf"])
        // The map was an extra of its own entry: it stays one, though no PDF is the ebook yet.
        #expect(plan.files.map(\.guessedRole) == [.audio, .ebook, .ebook, .extra])

        // A role a file's format cannot have, and a file that is no part of the merge, are refused.
        let audio = try fileId(f, kept)
        #expect(throws: LibraryError.invalidRole) {
            try f.service.planMerge(bookIds: [kept, epub], keep: kept, roles: [audio: .ebook])
        }
        #expect(throws: LibraryError.invalidRole) {
            try f.service.mergeBooks([kept, epub], keep: kept, roles: [try fileId(f, epub): .audio])
        }
        #expect(throws: LibraryError.fileNotFound(98765)) {
            try f.service.mergeBooks([kept, epub], keep: kept, roles: [98765: .extra])
        }
        #expect(try f.store.books().count == 3)
    }

    // MARK: MB3

    @Test func mb3_fewerThanTwoDifferentEntriesIsABlocker() throws {
        let f = try F()
        let (ebook, notes) = try ebookAndNotes(f)
        #expect(try f.service.planMerge(bookIds: [ebook], keep: nil).blockers == [.needsTwoBooks])
        #expect(try f.service.planMerge(bookIds: [ebook, ebook], keep: ebook).blockers == [.needsTwoBooks])
        #expect(try f.service.planMerge(bookIds: [ebook, 4321], keep: nil).blockers == [.needsTwoBooks])
        #expect(try f.service.planMerge(bookIds: [], keep: nil).blockers == [.needsTwoBooks])
        #expect(try f.service.planMerge(bookIds: [ebook, notes], keep: nil).blockers.isEmpty)
        let before = try whole(f)
        refused(.needsTwoBooks) { try f.service.mergeBooks([ebook, ebook], keep: ebook, roles: [:]) }
        refused(.needsTwoBooks) { try f.service.mergeBooks([ebook, 4321], keep: ebook, roles: [:]) }
        #expect(try whole(f) == before)
    }

    @Test func mb3_twoEntriesWithAudioCannotBeMerged() throws {
        let f = try F()
        let one = try f.importNew([try f.makeM4B("one.m4b", tags: BookMetadata())], F.meta("Dune", "Frank Herbert"))
        let two = try f.importNew(
            try f.makeMP3Parts(folder: "two", tags: BookMetadata()), F.meta("Dune Parts", "Frank Herbert"))
        let (ebook, _) = try ebookAndNotes2(f)
        let before = try whole(f)
        let batch = try f.store.lastBatch()

        #expect(try f.service.planMerge(bookIds: [ebook, two, one], keep: ebook).blockers == [.bothHaveAudio([two, one])])
        // MB4: the merge re-plans and refuses with the first blocker; nothing is changed.
        refused(.bothHaveAudio([one, two])) { try f.service.mergeBooks([one, two, ebook], keep: one, roles: [:]) }
        #expect(try whole(f) == before)
        #expect(try f.store.lastBatch() == batch)
        // One entry with audio is no blocker.
        #expect(try f.service.planMerge(bookIds: [ebook, one], keep: ebook).blockers.isEmpty)
    }

    /// As `ebookAndNotes`, under titles that are in no other book's way.
    private func ebookAndNotes2(_ f: F) throws -> (ebook: Int64, notes: Int64) {
        let ebook = try f.importNew([try f.makeEPUB("d2.epub")], F.meta("Dune Text", "Frank Herbert"))
        let notes = try f.importNew([try f.makePDF("n2.pdf")], F.meta("Dune Notes", "Frank Herbert"))
        return (ebook, notes)
    }

    @Test func mb3_aFileToBeMovedThatIsNotOnDiskIsABlocker() throws {
        let f = try F()
        let (ebook, notes) = try ebookAndNotes(f)
        try FileManager.default.removeItem(at: f.lib("Frank Herbert/Dune Notes/Dune Notes.pdf"))
        let before = try whole(f)

        #expect(try f.service.planMerge(bookIds: [ebook, notes], keep: ebook).blockers == [.fileMissing("Dune Notes.pdf")])
        refused(.fileMissing("Dune Notes.pdf")) { try f.service.mergeBooks([ebook, notes], keep: ebook, roles: [:]) }
        #expect(try whole(f) == before)
    }

    @Test func mb3_mb9_aKeptEntryMayHaveAFileMissingAndKeepsItsFlag() throws {
        let f = try F()
        let (ebook, notes) = try ebookAndNotes(f)
        try FileManager.default.removeItem(at: f.lib("Frank Herbert/Dune/Dune.epub"))
        #expect(try f.service.reconcile().booksWithMissingFiles == [ebook])
        #expect(try book(f, ebook).needsAttention)

        let plan = try f.service.planMerge(bookIds: [ebook, notes], keep: ebook)
        #expect(plan.blockers.isEmpty)
        #expect(plan.resultFolder == "Frank Herbert/Dune")
        try f.service.mergeBooks([ebook, notes], keep: ebook, roles: [:])

        #expect(try f.store.books().map(\.id) == [ebook])
        #expect(try paths(f, ebook) == ["Frank Herbert/Dune/Dune.epub", "Frank Herbert/Dune/Dune.pdf"])
        #expect(filesOnly(f) == ["Frank Herbert/Dune/Dune.pdf"])
        // MB9: a file is still missing, so the flag stays.
        #expect(try book(f, ebook).needsAttention)
        // A role change for the kept entry's own files cannot be carried out while one is missing.
        try f.service.undoLast()
        let missing = try fileId(f, ebook)
        #expect(try f.service.planMerge(bookIds: [ebook, notes], keep: ebook, roles: [missing: .extra]).blockers
            == [.fileMissing("Dune.epub")])
    }

    @Test func mb3_anUnresolvedLayoutChangeIsABlocker() throws {
        let f = try F()
        let (ebook, notes) = try ebookAndNotes(f)
        try FileManager.default.createDirectory(
            at: f.service.layoutIntentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a record".utf8).write(to: f.service.layoutIntentURL)
        let before = try whole(f)

        #expect(try f.service.planMerge(bookIds: [ebook, notes], keep: ebook).blockers == [.layoutChangeInterrupted])
        #expect(throws: LibraryError.layoutChangeInterrupted) {
            try f.service.mergeBooks([ebook, notes], keep: ebook, roles: [:])
        }
        #expect(try whole(f) == before)
    }

    @Test func mb3_aBookWithNoFilesCanBeMergedInEitherDirection() throws {
        for keepTheOneWithFiles in [true, false] {
            let f = try F()
            var details = F.meta("Dune", "Frank Herbert")
            details.narrators = ["Scott Brick"]
            let copy = ExternalCopy(kind: .audible, form: .audio, store: "us", itemId: "B000000001")
            guard case .added(let owned) = try f.service.addExternalBook(metadata: details, cover: F.png, copy: copy)
            else {
                Issue.record("the entry owned elsewhere was not added")
                return
            }
            let filed = try f.importNew([try f.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))
            let keep = keepTheOneWithFiles ? filed : owned
            let other = keepTheOneWithFiles ? owned : filed

            let plan = try f.service.planMerge(bookIds: [filed, owned], keep: keep)
            #expect(plan.blockers.isEmpty)
            #expect(plan.resultFolder == "Frank Herbert/Dune")
            #expect(try f.service.mergeBooks([filed, owned], keep: keep, roles: [:]) == keep)

            let merged = try book(f, keep)
            #expect(try f.store.book(id: other) == nil)
            #expect(try f.store.books().count == 1)
            #expect(merged.folderPath == "Frank Herbert/Dune")
            #expect(!merged.needsAttention)
            #expect(try paths(f, keep) == ["Frank Herbert/Dune/Dune.epub"])
            #expect(filesOnly(f) == ["Frank Herbert/Dune/Dune.epub"])
            #expect(merged.externalCopies == [copy])
            #expect(merged.narrators == ["Scott Brick"])
            #expect(merged.asin == "B000000001")
            #expect(try f.service.reconcile() == ReconcileReport())

            try f.service.undoLast()
            #expect(try f.store.books().compactMap(\.id).sorted() == [owned, filed].sorted())
            #expect(try book(f, owned).externalCopies == [copy])
            #expect(try book(f, filed).externalCopies.isEmpty)
            #expect(try book(f, owned).folderPath == nil)
            #expect(try paths(f, filed) == ["Frank Herbert/Dune/Dune.epub"])
            #expect(f.service.covers.image(for: owned)?.data == F.png.data)
        }
    }

    // MARK: MB4, MB8, MB9: the owner's case

    @Test func mb4_mb8_mb9_theOwnersThreeEntriesBecomeOneBookFiledOnceAndUnflagged() throws {
        let f = try F()
        let (a, b, c) = try ownersCase(f)
        let companionBytes = try f.bytes(f.lib("James Dalton/\(Self.companion)/\(Self.companion).pdf"))
        let audioBytes = try f.bytes(f.lib("\(Self.audioFolder)/\(Self.title) (Unabridged).m4b"))
        var commits = 0
        f.service.beforeCommit = { commits += 1 }

        #expect(try f.service.mergeBooks([a, b, c], keep: a, roles: [:]) == a)

        // One book, in the folder it belongs in, holding the audio, B's PDF as the ebook
        // and C's PDF among the extras. B's and C's old folders, and A's, are gone.
        #expect(f.libraryTree() == [
            "James Dalton",
            Self.folder,
            "\(Self.folder)/Extras",
            "\(Self.folder)/Extras/\(Self.companion).pdf",
            "\(Self.folder)/\(Self.title).m4b",
            "\(Self.folder)/\(Self.title).pdf",
        ].sorted())
        #expect(try f.store.books().map(\.id) == [a])
        #expect(try f.store.book(id: b) == nil)
        #expect(try f.store.book(id: c) == nil)
        let merged = try book(f, a)
        #expect(merged.title == Self.title)
        #expect(merged.folderPath == Self.folder)
        let rows = try f.store.files(bookId: a)
        #expect(rows.map(\.path) == [
            "\(Self.folder)/\(Self.title).m4b", "\(Self.folder)/\(Self.title).pdf",
            "\(Self.folder)/Extras/\(Self.companion).pdf",
        ])
        #expect(rows.map(\.role) == [.audio, .ebook, .extra])
        #expect(rows.map(\.position) == [0, 1, 2])
        #expect(rows.map(\.format) == [.m4b, .pdf, .pdf])
        #expect(rows.allSatisfy { $0.writeProblem == nil })
        // MB9, MB8: unflagged; the folder was B's, and B is now this book.
        #expect(!merged.needsAttention)
        #expect(try f.service.unfiledReason(for: a) == nil)
        #expect(try f.service.bookUsingFolder(of: a) == nil)
        // The facts about the files: the PDF's pages are the book's.
        #expect(merged.pageCount == 3)
        // The ebook carries the kept book's details; the extra and the audio were never written.
        #expect(try f.tags(f.lib("\(Self.folder)/\(Self.title).pdf")).title == Self.title)
        #expect(try f.tags(f.lib("\(Self.folder)/\(Self.title).pdf")).authors == [Self.author])
        #expect(try f.bytes(f.lib("\(Self.folder)/Extras/\(Self.companion).pdf")) == companionBytes)
        #expect(try f.bytes(f.lib("\(Self.folder)/\(Self.title).m4b")) == audioBytes)
        // ONE journaled operation, labelled "Merge Books", in one commit.
        #expect(commits == 1)
        #expect(try f.service.undoLabel() == "Merge Books")
        #expect(try f.store.lastBatch()?.moves.count == 2)
        #expect(try f.service.reconcile() == ReconcileReport())
        #expect(!(try book(f, a)).needsAttention)
        #expect(f.service.covers.image(for: a)?.data == F.jpeg.data)
    }

    @Test func mb4_audioPartsAreRenumberedAsAWholeWhenTheKeptBookGainsAudio() throws {
        let f = try F()
        let ebook = try f.importNew([try f.makeEPUB("dune.epub")], F.fullMeta("Dune", "Frank Herbert"))
        let parts = try f.importNew(
            try f.makeMP3Parts(folder: "parts", tags: F.meta("Old", "Old Author"), count: 3),
            F.meta("Dune Audio", "Frank Herbert"))
        let folder = "Frank Herbert/The Series/2 - Dune"
        #expect(try paths(f, parts) == (1...3).map { "Frank Herbert/Dune Audio/0\($0) - Dune Audio.mp3" })

        try f.service.mergeBooks([ebook, parts], keep: ebook, roles: [:])

        #expect(try paths(f, ebook) == (1...3).map { "\(folder)/0\($0) - Dune.mp3" } + ["\(folder)/Dune.epub"])
        #expect(try paths(f, ebook).sorted() == filesOnly(f))
        #expect(!f.libraryTree().contains("Frank Herbert/Dune Audio"))
        // The files that moved in carry the kept book's details, as files joining at import do.
        for index in 1...3 {
            let url = f.lib("\(folder)/0\(index) - Dune.mp3")
            #expect(try f.tags(url) == F.fullMeta("Dune", "Frank Herbert"))
            #expect(try f.track(url) == "\(index)/3")
        }
        let merged = try book(f, ebook)
        #expect(!merged.needsAttention)
        // Its length is that of the audio it now has.
        #expect(abs((merged.durationSeconds ?? 0) - 3) < 0.5)
        #expect(try f.service.reconcile() == ReconcileReport())
    }

    @Test func mb4_aClashOfNamesGetsANumberAndNothingIsReplaced() throws {
        let f = try F()
        let keptNotes = try f.makePDF("k/notes.pdf")
        let keptResult = try f.service.importItems([
            ImportItem(candidate: f.candidate(
                [try f.makeEPUB("k/dune.epub"), keptNotes], F.meta("Dune", "Frank Herbert"), roles: [keptNotes: .extra]))
        ])
        let kept = try f.importedId(try #require(keptResult.outcomes.first))
        let otherNotes = try f.makePDF("o/notes.pdf", pages: 5)
        let otherResult = try f.service.importItems([
            ImportItem(candidate: f.candidate(
                [try f.makeEPUB("o/dune.epub"), otherNotes], F.meta("Dune Again", "Frank Herbert"),
                roles: [otherNotes: .extra]))
        ])
        let other = try f.importedId(try #require(otherResult.outcomes.first))
        let keptEpub = try f.bytes(f.lib("Frank Herbert/Dune/Dune.epub"))
        let keptExtra = try f.bytes(f.lib("Frank Herbert/Dune/Extras/notes.pdf"))
        let otherExtra = try f.bytes(f.lib("Frank Herbert/Dune Again/Extras/notes.pdf"))

        try f.service.mergeBooks([kept, other], keep: kept, roles: [:])

        #expect(try paths(f, kept) == [
            "Frank Herbert/Dune/Dune.epub", "Frank Herbert/Dune/Dune 2.epub",
            "Frank Herbert/Dune/Extras/notes.pdf", "Frank Herbert/Dune/Extras/notes 2.pdf",
        ])
        #expect(try paths(f, kept).sorted() == filesOnly(f))
        #expect(try f.bytes(f.lib("Frank Herbert/Dune/Dune.epub")) == keptEpub)
        #expect(try f.bytes(f.lib("Frank Herbert/Dune/Extras/notes.pdf")) == keptExtra)
        #expect(try f.bytes(f.lib("Frank Herbert/Dune/Extras/notes 2.pdf")) == otherExtra)
        #expect(try f.service.reconcile() == ReconcileReport())
    }

    @Test func mb4_somethingElseWhereAFileWouldGoRefusesTheMerge() throws {
        let f = try F()
        let (ebook, notes) = try ebookAndNotes(f)
        // No book's file, and in the way of the PDF that would become the ebook.
        let stray = try touch(f.lib("Frank Herbert/Dune/Dune.pdf"), "someone's own file")
        let before = try whole(f)

        #expect(try f.service.planMerge(bookIds: [ebook, notes], keep: ebook).blockers == [.nameClash("Dune Notes.pdf")])
        refused(.nameClash("Dune Notes.pdf")) { try f.service.mergeBooks([ebook, notes], keep: ebook, roles: [:]) }
        #expect(try whole(f) == before)
        #expect(try read(stray) == "someone's own file")
    }

    @Test func mb4_roleChangesAreAppliedToTheKeptEntrysOwnFiles() throws {
        let f = try F()
        let kept = try f.importNew([try f.makePDF("dune.pdf")], F.meta("Dune", "Frank Herbert"))
        let other = try f.importNew([try f.makePDF("scan.pdf", pages: 7)], F.meta("Dune Scan", "Frank Herbert"))
        let own = try fileId(f, kept)
        // Left alone, the kept PDF stays the ebook and the incoming one is an extra.
        #expect(try f.service.planMerge(bookIds: [kept, other], keep: kept).files.map(\.role) == [.ebook, .extra])

        let plan = try f.service.planMerge(bookIds: [kept, other], keep: kept, roles: [own: .extra])
        #expect(plan.files.map(\.role) == [.extra, .ebook])
        #expect(plan.files.map(\.guessedRole) == [.ebook, .ebook])
        try f.service.mergeBooks([kept, other], keep: kept, roles: [own: .extra])

        let rows = try f.store.files(bookId: kept)
        #expect(rows.map(\.path) == ["Frank Herbert/Dune/Dune.pdf", "Frank Herbert/Dune/Extras/Dune.pdf"])
        #expect(rows.map(\.role) == [.ebook, .extra])
        #expect(filesOnly(f) == rows.map(\.path).sorted())
        // The scan is the ebook now, and says so of itself.
        #expect(try f.io.read(f.lib("Frank Herbert/Dune/Dune.pdf")).metadata.pageCount == 7)
        #expect(try f.tags(f.lib("Frank Herbert/Dune/Dune.pdf")).title == "Dune")
        #expect(try f.service.reconcile() == ReconcileReport())

        // Undo puts both files back where and what they were.
        try f.service.undoLast()
        #expect(try paths(f, kept) == ["Frank Herbert/Dune/Dune.pdf"])
        #expect(try paths(f, other) == ["Frank Herbert/Dune Scan/Dune Scan.pdf"])
        #expect(try f.io.read(f.lib("Frank Herbert/Dune/Dune.pdf")).metadata.pageCount == 3)
    }

    @Test func mb4_mb7_theKeptBookIsRefiledWhenItsFolderUnderTheLayoutChanges() throws {
        let f = try F()
        try f.store.setFolderPatternText("{Kind}/{Author}/{Title}")
        let ebook = try f.importNew([try f.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))
        let audio = try f.importNew(
            [try f.makeM4B("dune.m4b", tags: F.meta("Old", "Old Author"), cover: F.png)], F.meta("Dune", "Frank Herbert"))
        #expect(filesOnly(f) == ["Audiobooks/Frank Herbert/Dune/Dune.m4b", "Ebooks/Frank Herbert/Dune/Dune.epub"])
        let before = try whole(f)

        // Kept, the ebook gains audio: it belongs among the audiobooks now.
        let plan = try f.service.planMerge(bookIds: [ebook, audio], keep: ebook)
        #expect(plan.suggestedKeepId == audio)
        #expect(plan.resultFolder == "Audiobooks/Frank Herbert/Dune")
        try f.service.mergeBooks([ebook, audio], keep: ebook, roles: [:])

        #expect(f.libraryTree() == [
            "Audiobooks", "Audiobooks/Frank Herbert", "Audiobooks/Frank Herbert/Dune",
            "Audiobooks/Frank Herbert/Dune/Dune.epub", "Audiobooks/Frank Herbert/Dune/Dune.m4b",
        ])
        #expect(try book(f, ebook).folderPath == "Audiobooks/Frank Herbert/Dune")
        #expect(try paths(f, ebook) == ["Audiobooks/Frank Herbert/Dune/Dune.m4b", "Audiobooks/Frank Herbert/Dune/Dune.epub"])
        #expect(!(try book(f, ebook)).needsAttention)
        #expect(try f.service.reconcile() == ReconcileReport())

        // MB7: undo after a merge that re-filed the kept book.
        #expect(try f.service.undoLast() == "Merge Books")
        #expect(try whole(f) == before)
        #expect(try f.service.reconcile() == ReconcileReport())
    }

    @Test func mb4_whenTheBookCannotBeFiledAnywhereNothingMovesAndItIsFlagged() throws {
        let f = try F()
        // Neither entry has an author: both are catalogued where they are.
        let one = try f.makeEPUB("loose/one.epub")
        let two = try f.makePDF("loose/two.pdf")
        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([one], BookMetadata(title: "Loose"))),
            ImportItem(candidate: f.candidate([two], BookMetadata(title: "Loose Notes"))),
        ])
        guard case .needsAttention(let kept) = result.outcomes[0], case .needsAttention(let other) = result.outcomes[1]
        else {
            Issue.record("expected both to be catalogued in place, got \(result.outcomes)")
            return
        }
        let inbox = f.inboxTree()
        let before = try whole(f)

        let plan = try f.service.planMerge(bookIds: [kept, other], keep: kept)
        #expect(plan.blockers.isEmpty)
        #expect(plan.resultFolder == nil)
        try f.service.mergeBooks([kept, other], keep: kept, roles: [:])

        #expect(f.inboxTree() == inbox)
        #expect(try f.store.books().map(\.id) == [kept])
        #expect(try book(f, kept).needsAttention)
        #expect(try book(f, kept).folderPath == nil)
        #expect(try f.store.files(bookId: kept).map { f.store.url(for: $0).lastPathComponent } == ["one.epub", "two.pdf"])

        try f.service.undoLast()
        #expect(try whole(f) == before)
        #expect(f.inboxTree() == inbox)
    }

    // MARK: MB5

    @Test func mb5_emptyDetailsAreFilledFromTheOthersInTheOrderChosen() throws {
        for reversed in [false, true] {
            let f = try F()
            let kept = try f.importNew([try f.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))
            var first = F.meta("Dune Notes", "Someone Else")
            first.year = 1965
            first.genre = "Science Fiction"
            first.series = "Dune Chronicles"
            first.seriesNumber = "1"
            var second = F.meta("Dune Maps", "Another Writer")
            second.year = 1970
            second.publisher = "Ace"
            second.series = "Maps"
            second.seriesNumber = "9"
            second.language = "en"
            let one = try f.importNew([try f.makePDF("one.pdf")], first)
            let two = try f.importNew([try f.makePDF("two.pdf")], second)

            try f.service.mergeBooks(reversed ? [kept, two, one] : [kept, one, two], keep: kept, roles: [:])

            let merged = try book(f, kept)
            // What the kept entry had stays; what it lacked comes from the first that has it.
            #expect(merged.title == "Dune")
            #expect(merged.authors == ["Frank Herbert"])
            #expect(merged.year == (reversed ? 1970 : 1965))
            #expect(merged.genre == "Science Fiction")
            #expect(merged.publisher == "Ace")
            #expect(merged.language == "en")
            // A series and its number come from the same entry.
            #expect(merged.series == (reversed ? "Maps" : "Dune Chronicles"))
            #expect(merged.seriesNumber == (reversed ? "9" : "1"))
            // The kept entry's own file is given the details it now has.
            let folder = try #require(merged.folderPath)
            let inFile = try f.tags(f.lib("\(folder)/Dune.epub"))
            #expect(inFile.title == "Dune")
            #expect(inFile.publisher == "Ace")
            #expect(inFile.series == merged.series)
            #expect(!merged.needsAttention)
            #expect(filesOnly(f).count == 3)
            #expect(try f.service.reconcile() == ReconcileReport())
        }
    }

    @Test func mb5_tagsCollectionsNotesStatusDateAndRatingAreJoined() throws {
        let f = try F()
        let s = try attachments(f)

        try f.service.mergeBooks([s.a, s.b, s.c], keep: s.a, roles: [:])

        let merged = try book(f, s.a)
        // Tags are joined, the kept entry's first, none twice.
        #expect(merged.tags == ["trading", "pdf", "companion"])
        // The highest rating, the most advanced read status with its dates, the earliest date added.
        #expect(merged.rating == 4)
        #expect(merged.readStatus == .finished)
        #expect(merged.dateStarted == s.started)
        #expect(merged.dateFinished == s.finished)
        #expect(merged.dateAdded == s.earliest)
        // "Owned elsewhere" notes are joined; of Audible audio there is one for a book, and
        // it takes what it lacked.
        #expect(merged.externalCopies == [
            ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: "B09WXN61GL"),
            ExternalCopy(kind: .audible, form: .ebook, store: "us", itemId: "B0EBOOK001"),
        ])
        #expect(merged.asin == "B09WXN61GL")
        // The kept book is in every collection any of them was in.
        #expect(try f.store.books(inCollection: s.shelf).map(\.id) == [s.a])
        #expect(try f.store.books(inCollection: s.wishes).map(\.id) == [s.a])
        // Its own stored cover stays.
        #expect(f.service.covers.image(for: s.a)?.data == F.jpeg.data)
        #expect(try f.service.reconcile() == ReconcileReport())
    }

    @Test func mb5_withoutACoverOfItsOwnTheKeptBookTakesTheFirstOfTheOthers() throws {
        let f = try F()
        let (ebook, notes) = try ebookAndNotes(f)
        let audio = try f.importNew(
            [try f.makeM4B("dune.m4b", tags: BookMetadata(), cover: F.png)], F.meta("Dune Audio", "Frank Herbert"))
        try f.service.covers.remove(for: ebook)
        #expect(f.service.covers.image(for: notes) == nil)
        #expect(f.service.covers.image(for: audio)?.data == F.png.data)

        try f.service.mergeBooks([ebook, notes, audio], keep: ebook, roles: [:])

        #expect(f.service.covers.image(for: ebook)?.data == F.png.data)
        // The removed entries leave no cover behind.
        #expect(f.hiddenTree().filter { $0.hasPrefix("covers/") }.count == 1)

        try f.service.undoLast()
        #expect(f.service.covers.image(for: ebook) == nil)
        #expect(f.service.covers.image(for: audio)?.data == F.png.data)
    }

    /// The owner's case with everything that can be attached to an entry attached to
    /// one of them.
    private struct Attached {
        var a: Int64
        var b: Int64
        var c: Int64
        var shelf: Int64
        var wishes: Int64
        var started: Date
        var finished: Date
        var earliest: Date
    }

    private func attachments(_ f: F) throws -> Attached {
        let (a, b, c) = try ownersCase(f)
        var editA = BookEdit(book: try book(f, a))
        editA.tags = ["trading"]
        editA.rating = 2
        var editB = BookEdit(book: try book(f, b))
        editB.tags = ["pdf", "Trading"]
        editB.rating = 4
        var editC = BookEdit(book: try book(f, c))
        editC.tags = ["companion", "pdf"]
        _ = try f.service.save([editA, editB, editC])

        let started = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let finished = Date(timeIntervalSinceReferenceDate: 700_500_000)
        try f.service.setReadStatus(.inProgress, for: [b, c], on: started)
        try f.service.setReadStatus(.finished, for: [b], on: finished)

        let earliest = Date(timeIntervalSinceReferenceDate: 600_000_000)
        var older = try book(f, c)
        older.dateAdded = earliest
        try f.store.update(older)

        try f.service.setExternalCopies([ExternalCopy(kind: .audible, form: .audio, store: "uk")], for: a)
        try f.service.setExternalCopies(
            [
                ExternalCopy(kind: .audible, form: .audio, store: "us", itemId: "B09WXN61GL"),
                ExternalCopy(kind: .audible, form: .ebook, store: "us", itemId: "B0EBOOK001"),
            ], for: c)

        let shelf = try #require(try f.store.createCollection(name: "Shelf").id)
        let wishes = try #require(try f.store.createCollection(name: "Wishes").id)
        try f.store.add(bookId: a, toCollection: shelf)
        try f.store.add(bookId: b, toCollection: shelf)
        try f.store.add(bookId: b, toCollection: wishes)
        try f.store.add(bookId: c, toCollection: wishes)

        try f.service.covers.set(F.png, for: b)
        let sentFile = SentFile(name: "x.m4b", bytes: 10, seconds: 1, chapters: [])
        try f.service.recordSent(
            bookId: a, method: .share, fingerprint: SendFingerprint(files: [sentFile]), at: started)
        try f.service.recordSent(
            bookId: b, method: .link, fingerprint: SendFingerprint(files: [sentFile]), at: finished)
        try f.service.recordSent(
            bookId: c, method: .share, fingerprint: SendFingerprint(files: []), at: earliest)
        return Attached(
            a: a, b: b, c: c, shelf: shelf, wishes: wishes, started: started, finished: finished, earliest: earliest)
    }

    // MARK: MB6

    enum FailurePoint: String, CaseIterable {
        case firstMove, middleMove, lastMove, commit
    }

    @Test(arguments: FailurePoint.allCases)
    func mb6_aFailureAtAnyMoveOrAtTheCommitLeavesEverythingAsItWas(_ point: FailurePoint) throws {
        let files = EndingFailingFileManager()
        let f = try F(organiser: Organiser(fileManager: files))
        let s = try attachments(f)
        // A fourth entry, so that three files have to move: the audio (first), this ebook
        // (in the middle) and the companion PDF (last).
        let d = try f.importNew([try f.makeEPUB("mom.epub")], F.meta("\(Self.title) Ebook", Self.author))
        let ids = [s.a, s.b, d, s.c]
        let plan = try f.service.planMerge(bookIds: ids, keep: s.a)
        #expect(plan.blockers.isEmpty)
        #expect(plan.files.map(\.role) == [.audio, .ebook, .ebook, .extra])

        let before = try whole(f)
        let batch = try f.store.lastBatch()
        // (An empty undo folder may be cleared away: it holds nothing.)
        let hidden = f.hiddenTree().filter { $0 != "undo" }
        #expect(before.books.count == 4)
        #expect(before.bytes.count == 4)

        switch point {
        case .firstMove: files.failMovesEndingIn = ["/\(Self.folder)/\(Self.title).m4b"]
        case .middleMove: files.failMovesEndingIn = ["/\(Self.folder)/\(Self.title).epub"]
        case .lastMove: files.failMovesEndingIn = ["/\(Self.folder)/Extras/\(Self.companion).pdf"]
        case .commit: f.service.beforeCommit = { throw Boom() }
        }

        if point == .commit {
            #expect(throws: Boom.self) { try f.service.mergeBooks(ids, keep: s.a, roles: [:]) }
        } else {
            #expect(throws: CocoaError.self) { try f.service.mergeBooks(ids, keep: s.a, roles: [:]) }
            #expect(files.refused == 1)
        }

        // The full tree, every file's bytes, and every catalogue row are what they were.
        let after = try whole(f)
        #expect(after.tree == before.tree)
        #expect(after.bytes == before.bytes)
        #expect(after.books == before.books)
        #expect(after.files == before.files)
        #expect(after.covers == before.covers)
        #expect(after.memberships == before.memberships)
        #expect(after.sent == before.sent)
        #expect(try f.store.lastBatch() == batch)
        #expect(f.hiddenTree().filter { $0 != "undo" } == hidden)
        #expect(try f.service.reconcile().untrackedFiles.isEmpty)

        // With the obstacle gone the same merge goes through.
        files.failMovesEndingIn = []
        f.service.beforeCommit = nil
        try f.service.mergeBooks(ids, keep: s.a, roles: [:])
        #expect(try f.store.books().map(\.id) == [s.a])
        #expect(filesOnly(f) == [
            "\(Self.folder)/Extras/\(Self.companion).pdf", "\(Self.folder)/\(Self.title).epub",
            "\(Self.folder)/\(Self.title).m4b", "\(Self.folder)/\(Self.title).pdf",
        ])
    }

    // MARK: MB7

    @Test func mb7_undoRestoresEveryEntryWithItsOwnIdAndEverythingAttachedToIt() throws {
        let f = try F()
        let s = try attachments(f)
        let before = try whole(f)
        #expect(before.covers.keys.sorted() == [s.a, s.b])
        #expect(before.memberships.count == 4)
        #expect(before.sent.count == 3)

        try f.service.mergeBooks([s.a, s.b, s.c], keep: s.a, roles: [:])
        #expect(try f.store.books().map(\.id) == [s.a])
        // The ebook was written: undo has bytes to put back.
        #expect(try f.bytes(f.lib("\(Self.folder)/\(Self.title).pdf")) != before.bytes["\(Self.folder)/\(Self.title).pdf"])

        #expect(try f.service.undoLast() == "Merge Books")

        // Entries with their own ids, details, read status, notes, tags, file rows and
        // paths; covers; collections; sent records; the tree; and every file's bytes.
        let after = try whole(f)
        #expect(after.books == before.books)
        #expect(after.files == before.files)
        #expect(after.tree == before.tree)
        #expect(after.bytes == before.bytes)
        #expect(after.covers == before.covers)
        #expect(after.memberships == before.memberships)
        #expect(after.sent == before.sent)
        #expect(try f.service.reconcile() == ReconcileReport())
        #expect(try whole(f) == before)
        // The entries can be found again.
        #expect(try f.store.search("companion").map(\.id) == [s.c])
        // Nothing is left to undo, and no undo data is kept.
        #expect(try f.service.undoLabel() == nil)
        #expect(try f.store.lastBatch() == nil)
        #expect(!f.hiddenTree().contains { $0.hasPrefix("undo") })
    }

    @Test func mb7_undoPutsBackTheBytesOfAudioThatWasGivenTheKeptBooksDetails() throws {
        let f = try F()
        let ebook = try f.importNew([try f.makeEPUB("dune.epub")], F.fullMeta("Dune", "Frank Herbert"))
        let single = try f.importNew(
            [try f.makeM4B("dune.m4b", tags: F.meta("Old", "Old Author"), cover: F.jpeg)],
            F.meta("Dune Audio", "Frank Herbert"))
        let before = try whole(f)

        try f.service.mergeBooks([single, ebook], keep: ebook, roles: [:])
        let folder = "Frank Herbert/The Series/2 - Dune"
        #expect(try f.tags(f.lib("\(folder)/Dune.m4b")) == F.fullMeta("Dune", "Frank Herbert"))
        try f.service.undoLast()
        #expect(try whole(f) == before)

        // And for parts, each of which was renumbered.
        let f2 = try F()
        let text = try f2.importNew([try f2.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))
        let parts = try f2.importNew(
            try f2.makeMP3Parts(folder: "parts", tags: F.fullMeta("Old", "Old Author")),
            F.meta("Dune Audio", "Frank Herbert"))
        let before2 = try whole(f2)
        try f2.service.mergeBooks([text, parts], keep: text, roles: [:])
        try f2.service.undoLast()
        #expect(try whole(f2) == before2)
        #expect(try f2.service.reconcile() == ReconcileReport())
    }

    @Test func mb7_anUndoThatIsBlockedChangesNothingAndCanBeMadeAgain() throws {
        let f = try F()
        let s = try attachments(f)
        let before = try whole(f)
        try f.service.mergeBooks([s.a, s.b, s.c], keep: s.a, roles: [:])
        let merged = try whole(f)
        let batch = try f.store.lastBatch()

        // Something has since been put where the audio has to go back to.
        let inTheWay = try touch(f.lib("\(Self.audioFolder)/\(Self.title) (Unabridged).m4b"), "in the way")
        #expect(throws: LibraryError.self) { try f.service.undoLast() }
        var blocked = try whole(f)
        #expect(blocked.bytes.removeValue(forKey: "\(Self.audioFolder)/\(Self.title) (Unabridged).m4b") == Data("in the way".utf8))
        blocked.tree.removeAll { $0.hasPrefix(Self.audioFolder) }
        #expect(blocked == merged)
        #expect(try f.store.lastBatch() == batch)

        try FileManager.default.removeItem(at: inTheWay.deletingLastPathComponent())
        try f.service.undoLast()
        #expect(try whole(f) == before)
    }

    @Test func mb7_anUndoWhoseCommitFailsCanBeMadeAgainAndStillPutsEveryByteBack() throws {
        let f = try F()
        let s = try attachments(f)
        let before = try whole(f)
        try f.service.mergeBooks([s.a, s.b, s.c], keep: s.a, roles: [:])

        // The files go back first; then the catalogue cannot be written.
        f.service.beforeCommit = { throw Boom() }
        #expect(throws: Boom.self) { try f.service.undoLast() }
        #expect(try whole(f).bytes == before.bytes)
        #expect(try f.store.books().map(\.id) == [s.a])
        #expect(try f.service.undoLabel() == "Merge Books")

        f.service.beforeCommit = nil
        try f.service.undoLast()
        let after = try whole(f)
        #expect(after.bytes == before.bytes)
        #expect(after.books == before.books)
        #expect(after.files == before.files)
        #expect(after.tree == before.tree)
        #expect(after.covers == before.covers)
        #expect(after.memberships == before.memberships)
        #expect(after.sent == before.sent)
        #expect(try f.service.reconcile() == ReconcileReport())
    }

    @Test func mb7_aFileChangedSinceTheMergeIsNotReplacedByUndo() throws {
        let f = try F()
        let (ebook, notes) = try ebookAndNotes(f)
        try f.service.mergeBooks([ebook, notes], keep: ebook, roles: [:])
        // Another program has rewritten the PDF since: its tags go back, the rest of it stays.
        let pdf = f.lib("Frank Herbert/Dune/Dune.pdf")
        #expect(try f.tags(pdf).title == "Dune")
        MediaFixtures.makePDF(at: pdf, pages: 9)

        try f.service.undoLast()

        let back = f.lib("Frank Herbert/Dune Notes/Dune Notes.pdf")
        #expect(try f.io.read(back).metadata.pageCount == 9)
        #expect(try f.tags(back).title == "Dune Notes")
        #expect(try paths(f, notes) == ["Frank Herbert/Dune Notes/Dune Notes.pdf"])
    }

    @Test func mb7_aMergeIsRecordedInAFormOlderVersionsWillNotTryToUndo() throws {
        let f = try F()
        let (ebook, notes) = try ebookAndNotes(f)
        #expect(OperationSnapshot.currentVersion == 3)
        try f.service.mergeBooks([ebook, notes], keep: ebook, roles: [:])
        let data = try #require(try f.store.lastBatch()?.snapshot)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["version"] as? Int == 3)
        let snapshot = try f.snapshot()
        #expect(snapshot.books.map(\.bookId) == [ebook])
        #expect(snapshot.merge?.removed.map(\.book.id) == [notes])
    }

    // MARK: MB8

    @Test func mb8_aThirdBookInTheFolderLeavesTheKeptBookWhereItIsAndFlagged() throws {
        let f = try F()
        let (a, b, c) = try ownersCase(f)
        let bBefore = try book(f, b)
        let bBytes = try f.bytes(f.lib("\(Self.folder)/\(Self.title).pdf"))

        // B is no part of this merge: the folder the kept book belongs in is still B's.
        let plan = try f.service.planMerge(bookIds: [a, c], keep: a)
        #expect(plan.blockers.isEmpty)
        #expect(plan.resultFolder == Self.audioFolder)
        try f.service.mergeBooks([a, c], keep: a, roles: [:])

        // The merge is otherwise complete: C's file is with A, where A is.
        #expect(try f.store.books().compactMap(\.id).sorted() == [a, b].sorted())
        #expect(try paths(f, a) == [
            "\(Self.audioFolder)/\(Self.title) (Unabridged).m4b", "\(Self.audioFolder)/Extras/\(Self.companion).pdf",
        ])
        #expect(try book(f, a).folderPath == Self.audioFolder)
        #expect(try book(f, a).needsAttention)
        #expect(try f.service.unfiledReason(for: a) == LibraryService.folderTakenReason)
        #expect(try f.service.bookUsingFolder(of: a)?.id == b)
        // B and its file are untouched.
        #expect(try book(f, b) == bBefore)
        #expect(try paths(f, b) == ["\(Self.folder)/\(Self.title).pdf"])
        #expect(try f.bytes(f.lib("\(Self.folder)/\(Self.title).pdf")) == bBytes)
        #expect(filesOnly(f) == [
            "\(Self.audioFolder)/Extras/\(Self.companion).pdf", "\(Self.audioFolder)/\(Self.title) (Unabridged).m4b",
            "\(Self.folder)/\(Self.title).pdf",
        ].sorted())
        #expect(try f.service.reconcile() == ReconcileReport())
        #expect(try book(f, a).needsAttention)
    }

    // MARK: MB10

    @Test func mb10_theBookWhoseFolderThisOneBelongsInIsNamedOnlyWhenThatIsWhyItIsFlagged() throws {
        let f = try F()
        let (a, b, c) = try ownersCase(f)
        #expect(try f.service.bookUsingFolder(of: a)?.id == b)
        #expect(try f.service.bookUsingFolder(of: a) == (try book(f, b)))
        // Not flagged; and the book whose folder it is.
        #expect(try f.service.bookUsingFolder(of: b) == nil)
        #expect(try f.service.bookUsingFolder(of: c) == nil)
        #expect(throws: LibraryError.bookNotFound(999)) { try f.service.bookUsingFolder(of: 999) }

        // Flagged for another reason: a file is missing.
        try FileManager.default.removeItem(at: f.lib("James Dalton/\(Self.companion)/\(Self.companion).pdf"))
        _ = try f.service.reconcile()
        #expect(try book(f, c).needsAttention)
        #expect(try f.service.bookUsingFolder(of: c) == nil)

        // A book with no files is never filed, so it is never in the way of one.
        guard case .added(let owned) = try f.service.addExternalBook(
            metadata: F.meta("Elsewhere", "A Writer"), cover: nil, copy: ExternalCopy(kind: .audible, form: .audio))
        else {
            Issue.record("the entry owned elsewhere was not added")
            return
        }
        #expect(try f.service.bookUsingFolder(of: owned) == nil)

        // Once the two are one book there is no other.
        try f.service.mergeBooks([a, b], keep: a, roles: [:])
        #expect(try f.service.bookUsingFolder(of: a) == nil)
        #expect(!(try book(f, a)).needsAttention)
    }

    // MARK: MB11

    @Test func mb11_nothingRefersToAnEntryThatIsGone() throws {
        let f = try F()
        let s = try attachments(f)
        let sentBefore = try [s.a, s.b, s.c].flatMap { try f.service.sentRecords(for: $0) }
        #expect(sentBefore.count == 3)

        try f.service.mergeBooks([s.a, s.b, s.c], keep: s.a, roles: [:])

        // Sent records of the removed entries are the kept book's now, newest first.
        let sent = try f.service.sentRecords(for: s.a)
        #expect(sent.map(\.sentAt) == [s.finished, s.started, s.earliest])
        #expect(sent.map(\.method) == [.link, .share, .share])
        #expect(sent.allSatisfy { $0.bookId == s.a })
        // No table has a row for a book that is gone.
        let gone = [s.b, s.c]
        let left = try f.store.dbQueue.read { db in
            try ["bookFile", "collectionBook", "sentRecord"].map { table in
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM \(table) WHERE bookId IN (?, ?)", arguments: [gone[0], gone[1]]) ?? -1
            } + [
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book WHERE id IN (?, ?)", arguments: [gone[0], gone[1]]) ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookSearch WHERE rowid IN (?, ?)", arguments: [gone[0], gone[1]]) ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sentRecord WHERE bookId NOT IN (SELECT id FROM book)") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collectionBook WHERE bookId NOT IN (SELECT id FROM book)") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookFile WHERE bookId NOT IN (SELECT id FROM book)") ?? -1,
            ]
        }
        #expect(left == [0, 0, 0, 0, 0, 0, 0, 0])
        // Searching finds the one book, by a tag that came from a removed entry too.
        #expect(try f.store.search("Mind").map(\.id) == [s.a])
        #expect(try f.store.search("companion").map(\.id) == [s.a])
        // The journal holds the merge alone, and names only books that exist or that it can restore.
        let snapshot = try f.snapshot()
        #expect(snapshot.books.map(\.bookId) == [s.a])
        #expect(snapshot.merge?.removed.compactMap(\.book.id) == [s.b, s.c])

        // A send made after the merge stays with the kept book when the merge is undone.
        let later = Date(timeIntervalSinceReferenceDate: 710_000_000)
        try f.service.recordSent(bookId: s.a, method: .share, fingerprint: SendFingerprint(files: []), at: later)
        // A collection deleted since is not brought back, and does not stop the undo.
        try f.store.deleteCollection(id: s.wishes)
        try f.service.undoLast()
        #expect(try f.service.sentRecords(for: s.a).map(\.sentAt) == [later, s.started])
        #expect(try f.service.sentRecords(for: s.b).map(\.sentAt) == [s.finished])
        #expect(try f.service.sentRecords(for: s.c).map(\.sentAt) == [s.earliest])
        #expect(try f.store.books(inCollection: s.shelf).compactMap(\.id).sorted() == [s.a, s.b].sorted())
        #expect(try f.store.collections().compactMap(\.id) == [s.shelf])
    }

    @Test func mb11_aSeriesIsCountedFromTheBooksThatAreThere() throws {
        let f = try F()
        var inSeries = F.meta("Dune", "Frank Herbert")
        inSeries.series = "Dune Chronicles"
        inSeries.seriesNumber = "1"
        let ebook = try f.importNew([try f.makeEPUB("dune.epub")], inSeries)
        var same = F.meta("Dune Notes", "Frank Herbert")
        same.series = "Dune Chronicles"
        same.seriesNumber = "1"
        let notes = try f.importNew([try f.makePDF("notes.pdf")], same)
        #expect(try f.service.librarySeriesBooks(named: "Dune Chronicles").count == 2)

        try f.service.mergeBooks([ebook, notes], keep: ebook, roles: [:])

        #expect(try f.service.librarySeriesBooks(named: "Dune Chronicles").map(\.id) == [ebook])
        #expect(try f.store.books(where: .series, equals: "Dune Chronicles").map(\.id) == [ebook])
    }
}
