import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// Everything about a library that a change of folder layout could touch, in one
/// comparable value: every path in the library folder (the hidden folder included, the
/// catalogue's own files left out), every file's bytes, the catalogue's books and file
/// rows, the stored pattern and the journal.
struct LayoutState: Equatable {
    var tree: [String]
    var bytes: [String: Data]
    var books: [Book]
    var files: [BookFile]
    var pattern: String?
    var batch: OperationBatch?

    init(_ f: LibraryFixture) throws {
        tree = VoxCarrelCoreTests.tree(f.root).filter { !$0.hasPrefix(LibraryStore.databaseFileName) }
        bytes = [:]
        for path in tree {
            var isDirectory: ObjCBool = false
            let url = f.root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                bytes[path] = try Data(contentsOf: url)
            }
        }
        books = try f.store.books().sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        files = try f.store.allFiles().sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        pattern = try f.store.folderPatternText()
        batch = try f.store.lastBatch()
    }
}

extension LibraryFixture {
    /// A book put straight into the library and its catalogue, with small stand-in files:
    /// a change of layout never opens a file. Filed where the standard pattern files it
    /// unless `folder` says otherwise; one audio file named after the title unless
    /// `files` names others (those under "Extras/" are extras).
    @discardableResult
    func shelve(
        _ title: String, _ author: String, series: String? = nil, number: String? = nil, narrator: String? = nil,
        at folder: String? = nil, files: [String]? = nil, needsAttention: Bool = false
    ) throws -> Int64 {
        var metadata = BookMetadata(title: title, authors: author.isEmpty ? [] : [author])
        metadata.series = series
        metadata.seriesNumber = number
        if let narrator { metadata.narrators = [narrator] }
        let names = files ?? ["\(title).m4b"]
        let hasAudio = names.contains { FileFormat(url: URL(fileURLWithPath: $0))?.defaultRole == .audio }
        let place = try #require(
            folder ?? FolderPattern.standard.folder(for: FolderPatternValues(metadata: metadata, hasAudio: hasAudio)))
        var rows: [BookFile] = []
        for (position, name) in names.enumerated() {
            let url = lib(place).appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("\(title) by \(author): \(name)".utf8).write(to: url)
            let format = try #require(FileFormat(url: url))
            rows.append(
                BookFile(
                    path: "\(place)/\(name)", format: format,
                    role: name.hasPrefix("Extras/") ? .extra : format.defaultRole, position: position))
        }
        return try #require(
            try store.insert(Book(metadata: metadata, folderPath: place, needsAttention: needsAttention), files: rows).id)
    }

    func folder(_ id: Int64) throws -> String? {
        try #require(try store.book(id: id)).folderPath
    }

    func flagged(_ id: Int64) throws -> Bool {
        try #require(try store.book(id: id)).needsAttention
    }

    func rowPaths(_ id: Int64) throws -> [String] {
        try store.files(bookId: id).map(\.path)
    }

    /// The paths of the library's files and folders that are not VoxCarrel's own.
    func shown() -> [String] { libraryTree() }

    /// The names in a library folder exactly as the disk spells them.
    func names(in folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: lib(folder).path)) ?? []).sorted()
    }

    /// Counts the folder renames a change makes, and makes the one numbered `failing`
    /// (from 1) fail.
    @discardableResult
    func countRenames(failing: Int = 0) -> () -> Int {
        var count = 0
        service.renameFolder = { from, to in
            count += 1
            if count == failing { throw Boom() }
            try FolderMover.renameWithoutReplacing(from, to)
        }
        return { count }
    }
}

/// Re-filing the whole library (folder layout plan, Task 3). FP30–FP40.
@Suite struct LibraryServiceLayoutChangeTests {
    typealias F = LibraryFixture

    static let byKind = "{Kind}/{Author}/[{Series}/][{Number} - ]{Title}"
    static let authorTitle = "{Author}/{Title}"

    private func pattern(_ text: String) throws -> FolderPattern { try FolderPattern(text) }

    /// A small library under the standard pattern: two books of a series, a book on its
    /// own with an extra, and an ebook.
    private func smallLibrary() throws -> (f: F, ids: [Int64]) {
        let f = try F()
        let ids = [
            try f.shelve("Dune", "Frank Herbert", series: "Dune Saga", number: "1"),
            try f.shelve("Messiah", "Frank Herbert", series: "Dune Saga", number: "2"),
            try f.shelve("Artemis", "Andy Weir", files: ["Artemis.m4b", "Extras/map.pdf"]),
            try f.shelve("Quiet Rivers", "Ann Author", files: ["Quiet Rivers.epub"]),
        ]
        return (f, ids)
    }

    private func stay(_ plan: LayoutChangePlan, _ id: Int64) -> String? {
        plan.staying.first { $0.bookId == id }?.reason
    }

    private func move(_ plan: LayoutChangePlan, _ id: Int64) -> String? {
        plan.moves.first { $0.bookId == id }.map { "\($0.from) -> \($0.to)" }
    }

    // MARK: FP30 The plan

    @Test func fp30_planningTouchesNothing() throws {
        let (f, _) = try smallLibrary()
        try f.shelve("No Narrator", "Someone")
        let before = try LayoutState(f)
        for text in [Self.byKind, Self.authorTitle, "{Narrator}/{Title}", "{Author}/[{Series}/][{Number} - ]{Title}"] {
            _ = try f.service.planLayoutChange(to: try pattern(text))
            #expect(try LayoutState(f) == before, "\(text)")
        }
    }

    @Test func fp30_eachBookMovesStaysOrIsAlreadyInPlace() throws {
        let (f, ids) = try smallLibrary()
        guard case .added(let owned) = try f.service.addExternalBook(
            metadata: F.meta("Owned Elsewhere", "Ann Author"), cover: nil, copy: ExternalCopy(kind: .audible, form: .audio))
        else {
            Issue.record("the book was not added")
            return
        }
        _ = owned
        let plan = try f.service.planLayoutChange(to: try pattern(Self.authorTitle))
        #expect(plan.pattern == (try pattern(Self.authorTitle)))
        // By destination.
        #expect(plan.moves == [
            LayoutMove(bookId: ids[0], title: "Dune", from: "Frank Herbert/Dune Saga/1 - Dune", to: "Frank Herbert/Dune"),
            LayoutMove(bookId: ids[1], title: "Messiah", from: "Frank Herbert/Dune Saga/2 - Messiah", to: "Frank Herbert/Messiah"),
        ])
        #expect(plan.staying.isEmpty)
        #expect(plan.unchangedCount == 2)
        #expect(plan.noFolderCount == 1)
    }

    @Test func fp30_aBookThePatternCannotFileStaysWithTheReason() throws {
        let f = try F()
        let narrated = try f.shelve("Artemis", "Andy Weir", narrator: "Rosario Dawson")
        let plain = try f.shelve("The Martian", "Andy Weir")
        let plan = try f.service.planLayoutChange(to: try pattern("{Narrator}/{Title}"))
        #expect(move(plan, narrated) == "Andy Weir/Artemis -> Rosario Dawson/Artemis")
        #expect(plan.staying == [LayoutStay(bookId: plain, title: "The Martian", reason: "No narrator, which the folder layout needs.")])
        #expect(plan.unchangedCount == 0)
    }

    @Test func fp30_kindGoesByTheBooksFiles() throws {
        let (f, ids) = try smallLibrary()
        let plan = try f.service.planLayoutChange(to: try pattern(Self.byKind))
        #expect(plan.moves.map(\.to) == [
            "Audiobooks/Andy Weir/Artemis", "Audiobooks/Frank Herbert/Dune Saga/1 - Dune",
            "Audiobooks/Frank Herbert/Dune Saga/2 - Messiah", "Ebooks/Ann Author/Quiet Rivers",
        ])
        #expect(plan.moves.map(\.bookId) == [ids[2], ids[0], ids[1], ids[3]])
    }

    @Test func fp30_inPlaceIsDecidedAsTheVolumeComparesNames() throws {
        let f = try F()
        // Filed under another capitalisation, and in the other Unicode form, than the
        // details now give: one folder all the same.
        let cased = try f.shelve("Artemis", "Andy Weir", at: "andy weir/ARTEMIS")
        let formed = try f.shelve("\u{C9}cole", "Zo\u{E9}", at: "Zoe\u{301}/E\u{301}cole", files: ["x.m4b"])
        f.service.volumeIsCaseSensitive = false
        var plan = try f.service.planLayoutChange(to: .standard)
        #expect(plan.moves.isEmpty)
        #expect(plan.unchangedCount == 2)
        // Where capitalisation tells names apart, only the Unicode form is ignored.
        f.service.volumeIsCaseSensitive = true
        plan = try f.service.planLayoutChange(to: .standard)
        #expect(stay(plan, formed) == nil)
        #expect(move(plan, formed) == nil)
        #expect(plan.unchangedCount >= 1)
        _ = cased
    }

    // MARK: FP31 Clashes are found in the plan

    @Test func fp31_twoBooksRenderingOneFolderTheEarlierMoves() throws {
        let f = try F()
        let first = try f.shelve("Dune", "Frank Herbert", series: "Dune Saga", number: "1")
        let second = try f.shelve("Dune", "Frank Herbert", series: "Graphic Novels", number: "1", files: ["Dune.epub"])
        let third = try f.shelve("Dune", "Frank Herbert", series: "Radio Plays")
        let plan = try f.service.planLayoutChange(to: try pattern(Self.authorTitle))
        #expect(move(plan, first) == "Frank Herbert/Dune Saga/1 - Dune -> Frank Herbert/Dune")
        #expect(stay(plan, second) == "Another book would use the same folder.")
        #expect(stay(plan, third) == "Another book would use the same folder.")
        #expect(plan.moves.count == 1)
    }

    @Test func fp31_aBookAlreadyInTheFolderKeepsItWhoeverWasAddedFirst() throws {
        let f = try F()
        let mover = try f.shelve("Dune", "Frank Herbert", series: "Dune Saga", number: "1")
        let there = try f.shelve("Dune", "Frank Herbert", files: ["Dune.epub"])
        let plan = try f.service.planLayoutChange(to: try pattern(Self.authorTitle))
        #expect(plan.moves.isEmpty)
        #expect(stay(plan, mover) == "Another book would use the same folder.")
        #expect(stay(plan, there) == nil)
        #expect(plan.unchangedCount == 1)
    }

    @Test func fp31_clashesIgnoreCaseAndUnicodeFormWhereTheVolumeDoes() throws {
        let f = try F()
        let first = try f.shelve("Dune", "Frank Herbert", series: "A", number: "1")
        let second = try f.shelve("DUNE", "frank herbert", series: "B", number: "1")
        let third = try f.shelve("\u{C9}cole", "Zo\u{E9}", series: "A")
        let fourth = try f.shelve("E\u{301}cole", "Zoe\u{301}", series: "B", files: ["x.m4b"])
        f.service.volumeIsCaseSensitive = false
        var plan = try f.service.planLayoutChange(to: try pattern(Self.authorTitle))
        #expect(plan.moves.map(\.bookId).sorted() == [first, third])
        #expect(stay(plan, second) == "Another book would use the same folder.")
        #expect(stay(plan, fourth) == "Another book would use the same folder.")

        // Where capitalisation tells names apart those two are different folders; the
        // Unicode form never does.
        f.service.volumeIsCaseSensitive = true
        plan = try f.service.planLayoutChange(to: try pattern(Self.authorTitle))
        #expect(plan.moves.map(\.bookId).sorted() == [first, second, third])
        #expect(stay(plan, fourth) == "Another book would use the same folder.")
        #expect(try LayoutState(f).batch == nil)
    }

    @Test func fp31_aDestinationThatExistsAndIsNotVacatedStays() throws {
        let f = try F()
        let blocked = try f.shelve("Dune", "Frank Herbert", series: "Dune Saga", number: "1")
        let free = try f.shelve("Messiah", "Frank Herbert", series: "Dune Saga", number: "2")
        // Something of the owner's own is where the first book would go.
        try FileManager.default.createDirectory(at: f.lib("Frank Herbert/Dune"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: f.lib("Frank Herbert/Dune/notes.txt"))
        var plan = try f.service.planLayoutChange(to: try pattern(Self.authorTitle))
        #expect(stay(plan, blocked) == "A folder is already there.")
        #expect(move(plan, free) != nil)

        // An empty folder is something too, and so is a file.
        try FileManager.default.removeItem(at: f.lib("Frank Herbert/Dune/notes.txt"))
        plan = try f.service.planLayoutChange(to: try pattern(Self.authorTitle))
        #expect(stay(plan, blocked) == "A folder is already there.")
        try FileManager.default.removeItem(at: f.lib("Frank Herbert/Dune"))
        try Data("a file".utf8).write(to: f.lib("Frank Herbert/Dune"))
        plan = try f.service.planLayoutChange(to: try pattern(Self.authorTitle))
        #expect(stay(plan, blocked) == "A folder is already there.")
        try FileManager.default.removeItem(at: f.lib("Frank Herbert/Dune"))
        plan = try f.service.planLayoutChange(to: try pattern(Self.authorTitle))
        #expect(stay(plan, blocked) == nil)
    }

    @Test func fp31_aDestinationIsFreeWhenItsBookIsItselfMovingAway() throws {
        let f = try F()
        // "Two" sits where "One" belongs, and belongs elsewhere itself.
        let one = try f.shelve("One", "Ann", at: "Ann/Old One")
        let two = try f.shelve("Two", "Ann", at: "Ann/One")
        var plan = try f.service.planLayoutChange(to: .standard)
        #expect(move(plan, one) == "Ann/Old One -> Ann/One")
        #expect(move(plan, two) == "Ann/One -> Ann/Two")

        // But not when that book cannot move after all: then both stay.
        try Data("a file".utf8).write(to: f.lib("Ann/Two"))
        plan = try f.service.planLayoutChange(to: .standard)
        #expect(stay(plan, two) == "A folder is already there.")
        #expect(stay(plan, one) == "Another book uses the folder this book belongs in.")
        #expect(plan.moves.isEmpty)
    }

    @Test func fp31_oneBooksFolderInsideAnothersBothStay() throws {
        let f = try F()
        // Under "{Author}/[{Series}/]{Title}" the second book's folder would be inside the first's.
        let outer = try f.shelve("Dune", "Frank Herbert", at: "Shelf/Dune")
        let inner = try f.shelve("Messiah", "Frank Herbert", series: "Dune", at: "Shelf/Messiah")
        let apart = try f.shelve("Artemis", "Andy Weir", at: "Shelf/Artemis")
        let plan = try f.service.planLayoutChange(to: try pattern("{Author}/[{Series}/]{Title}"))
        #expect(stay(plan, outer) == "Another book's folder would be inside its folder.")
        #expect(stay(plan, inner) == "Its folder would be inside another book's folder.")
        #expect(move(plan, apart) == "Shelf/Artemis -> Andy Weir/Artemis")

        // The same when the book that would be outside, or inside, is already in place.
        let g = try F()
        let placed = try g.shelve("Dune", "Frank Herbert")
        let entering = try g.shelve("Messiah", "Frank Herbert", series: "Dune", at: "Shelf/Messiah")
        let second = try g.service.planLayoutChange(to: try pattern("{Author}/[{Series}/]{Title}"))
        #expect(stay(second, entering) == "Its folder would be inside another book's folder.")
        #expect(stay(second, placed) == nil)
        #expect(second.unchangedCount == 1)
        #expect(second.moves.isEmpty)
    }

    @Test func fp31_aBookWhoseFolderIsMissingStays() throws {
        let (f, ids) = try smallLibrary()
        try FileManager.default.removeItem(at: f.lib("Andy Weir/Artemis"))
        let plan = try f.service.planLayoutChange(to: try pattern(Self.byKind))
        #expect(stay(plan, ids[2]) == "Its folder is missing.")
        #expect(plan.moves.count == 3)
    }

    @Test func fp31_aBookWhoseFilesAreNotAllItsFoldersOwnStays() throws {
        let f = try F()
        // Every file gone, though the folder is there; a file kept outside the folder;
        // two books in one folder; another book's file inside the folder.
        let empty = try f.shelve("Empty", "Ann")
        try FileManager.default.removeItem(at: f.lib("Ann/Empty/Empty.m4b"))
        let astray = try f.shelve("Astray", "Ann")
        var rows = try f.store.files(bookId: astray)
        rows.append(BookFile(path: "Elsewhere/extra.pdf", format: .pdf, role: .extra, position: 1))
        try f.store.replaceFiles(bookId: astray, files: rows)
        let sharedA = try f.shelve("Shared", "Ann", files: ["Shared.m4b"])
        let sharedB = try f.shelve("Shared", "Ann", files: ["Shared.epub"])
        let host = try f.shelve("Host", "Ann")
        let guest = try f.shelve("Guest", "Ann", at: "Ann/Host/Guest")
        let unfiled = try f.store.insert(
            Book(metadata: F.meta("Unfiled", "Ann"), folderPath: nil, needsAttention: true),
            files: [BookFile(path: f.inbox.appendingPathComponent("u.m4b").path, format: .m4b, role: .audio, position: 0)])

        let plan = try f.service.planLayoutChange(to: try pattern(Self.byKind))
        #expect(stay(plan, empty) == "Its files are missing.")
        #expect(stay(plan, astray) == "Some of its files are not in its folder.")
        #expect(stay(plan, sharedA) == "It shares its folder with another book.")
        #expect(stay(plan, sharedB) == "It shares its folder with another book.")
        #expect(stay(plan, host) == "Another book has files inside its folder.")
        #expect(stay(plan, try #require(unfiled.id)) == "It has not been filed in the library yet.")
        // The book inside is its own folder's only book, and moves out.
        #expect(move(plan, guest) == "Ann/Host/Guest -> Audiobooks/Ann/Guest")
        #expect(plan.moves.count == 1)
    }

    /// A file recorded by its whole path, though it is in its book's folder: what the
    /// catalogue says of it cannot be rewritten by counting folder names, so the book
    /// is left exactly as it is.
    @Test func fp31_aBookWithAFileRecordedByItsWholePathStaysAsItIs() throws {
        let f = try F()
        let odd = try f.shelve("Odd", "Ann", files: ["Odd.m4b", "Extras/map.pdf"])
        var rows = try f.store.files(bookId: odd)
        rows[1].path = f.lib("Ann/Odd/Extras/map.pdf").path
        try f.store.replaceFiles(bookId: odd, files: rows)
        let other = try f.shelve("Other", "Bob")
        let recorded = try f.rowPaths(odd)

        let done = try f.service.applyLayoutChange(to: try pattern(Self.byKind))

        #expect(stay(done, odd) == "Some of its files are not in its folder.")
        #expect(try f.folder(odd) == "Ann/Odd")
        #expect(try f.rowPaths(odd) == recorded)
        #expect(try read(f.lib("Ann/Odd/Extras/map.pdf")) == "Odd by Ann: Extras/map.pdf")
        #expect(try f.folder(other) == "Audiobooks/Bob/Other")
        #expect(try f.service.reconcile() == ReconcileReport())
    }

    @Test func fp31_aBookWhoseFolderNameOrPathWouldBeTooLongStays() throws {
        let f = try F()
        // 200 characters is as long as a folder name is made, and for these it is 400
        // UTF-16 units: more than the 255 a name may be on disk.
        let wide = try f.shelve(String(repeating: "\u{1F642}", count: 200), "Ann", at: "Shelf/Wide", files: ["w.m4b"])
        // 200 of these are 200 units, which fits.
        let cjk = try f.shelve(String(repeating: "\u{5B57}", count: 200), "Ann", at: "Shelf/CJK", files: ["c.m4b"])
        // Each name fits, but six levels of them and the file do not fit in one path.
        let long = String(repeating: "n", count: 190)
        let deep = try f.shelve(long, long, series: long, number: "1", narrator: long, at: "Shelf/Deep", files: ["\(long).m4b"])
        let fine = try f.shelve("Fine", "Ann", at: "Shelf/Fine")
        let target = try pattern("{Narrator}/{Author}/{Series}/{Title}/{Author}/{Title}|{Author}/{Title}")
        let plan = try f.service.planLayoutChange(to: target)
        #expect(stay(plan, wide) == "Its folder's name or path would be too long.")
        #expect(stay(plan, deep) == "Its folder's name or path would be too long.")
        #expect(move(plan, fine) == "Shelf/Fine -> Ann/Fine")
        #expect(move(plan, cjk) != nil)
        // The change goes through for the rest.
        #expect(try f.service.applyLayoutChange(to: target) == plan)
        #expect(try f.folder(wide) == "Shelf/Wide")
        #expect(try f.folder(deep) == "Shelf/Deep")
        #expect(try f.folder(fine) == "Ann/Fine")
    }

    // MARK: FP32 One journaled operation

    @Test func fp32_theChangeIsOneOperationThatMovesTheFoldersAndStoresThePattern() throws {
        let (f, ids) = try smallLibrary()
        let planned = try f.service.planLayoutChange(to: try pattern(Self.byKind))
        let done = try f.service.applyLayoutChange(to: try pattern(Self.byKind))
        #expect(done == planned)
        #expect(done.moves.count == 4)

        #expect(f.shown() == [
            "Audiobooks", "Audiobooks/Andy Weir", "Audiobooks/Andy Weir/Artemis",
            "Audiobooks/Andy Weir/Artemis/Artemis.m4b", "Audiobooks/Andy Weir/Artemis/Extras",
            "Audiobooks/Andy Weir/Artemis/Extras/map.pdf", "Audiobooks/Frank Herbert",
            "Audiobooks/Frank Herbert/Dune Saga", "Audiobooks/Frank Herbert/Dune Saga/1 - Dune",
            "Audiobooks/Frank Herbert/Dune Saga/1 - Dune/Dune.m4b", "Audiobooks/Frank Herbert/Dune Saga/2 - Messiah",
            "Audiobooks/Frank Herbert/Dune Saga/2 - Messiah/Messiah.m4b", "Ebooks", "Ebooks/Ann Author",
            "Ebooks/Ann Author/Quiet Rivers", "Ebooks/Ann Author/Quiet Rivers/Quiet Rivers.epub",
        ])
        #expect(try f.service.folderPattern() == (try pattern(Self.byKind)))
        #expect(try f.store.folderPatternText() == Self.byKind)
        #expect(try f.folder(ids[0]) == "Audiobooks/Frank Herbert/Dune Saga/1 - Dune")
        #expect(try f.rowPaths(ids[2]) == [
            "Audiobooks/Andy Weir/Artemis/Artemis.m4b", "Audiobooks/Andy Weir/Artemis/Extras/map.pdf",
        ])

        // One batch, labelled, holding one move for each folder.
        #expect(try f.service.undoLabel() == "Change Folder Layout")
        let batch = try #require(try f.store.lastBatch())
        #expect(batch.label == "Change Folder Layout")
        #expect(batch.moves.count == 4)
        #expect(batch.moves.contains(
            MoveRecord(
                from: f.lib("Andy Weir/Artemis").path, to: f.lib("Audiobooks/Andy Weir/Artemis").path, wasCopy: false)))
        // Nothing is left of the working places, and the launch check is content.
        #expect(f.hiddenTree().isEmpty)
        #expect(try f.service.reconcile() == ReconcileReport())
    }

    @Test func fp32_booksStayingBehindDoNotStopItAndAreFlaggedOrLeft() throws {
        let f = try F()
        let narrated = try f.shelve("Artemis", "Andy Weir", narrator: "Rosario Dawson")
        let plain = try f.shelve("The Martian", "Andy Weir")
        let first = try f.shelve("Dune", "Frank Herbert", series: "Dune Saga", number: "1", narrator: "Scott Brick")
        let clash = try f.shelve("Dune", "Frank Herbert", series: "Radio Plays", narrator: "Scott Brick")
        let blocked = try f.shelve("Emma", "Jane Austen", narrator: "Juliet Stevenson")
        try FileManager.default.createDirectory(at: f.lib("Juliet Stevenson/Emma"), withIntermediateDirectories: true)

        let done = try f.service.applyLayoutChange(to: try pattern("{Narrator}/{Title}"))
        #expect(done.moves.map(\.bookId).sorted() == [narrated, first])
        #expect(try f.folder(narrated) == "Rosario Dawson/Artemis")
        #expect(try f.folder(first) == "Scott Brick/Dune")

        // Not moved: flagged when the pattern cannot file it or another book has its
        // folder, as it is whenever a book is saved; otherwise left exactly as it was.
        #expect(try f.folder(plain) == "Andy Weir/The Martian")
        #expect(try f.flagged(plain))
        #expect(try f.service.unfiledReason(for: plain) == "No narrator, which the folder layout needs.")
        #expect(try f.folder(clash) == "Frank Herbert/Radio Plays/Dune")
        #expect(try f.flagged(clash))
        #expect(try f.service.unfiledReason(for: clash) == "Another book uses the folder this book belongs in.")
        #expect(try f.folder(blocked) == "Jane Austen/Emma")
        #expect(try !f.flagged(blocked))
        #expect(try !f.flagged(narrated))
        #expect(FileManager.default.fileExists(atPath: f.lib("Andy Weir/The Martian/The Martian.m4b").path))
        #expect(FileManager.default.fileExists(atPath: f.lib("Frank Herbert/Radio Plays/Dune/Dune.m4b").path))
        #expect(f.names(in: "Juliet Stevenson/Emma").isEmpty)
        #expect(try f.service.reconcile() == ReconcileReport())
        // The launch check does not take the flags away again.
        #expect(try f.flagged(plain))
        #expect(try f.flagged(clash))
    }

    @Test func fp32_aBookMovedIntoPlaceLosesAFlagItNoLongerNeeds() throws {
        let f = try F()
        let whole = try f.shelve("Artemis", "Andy Weir", at: "Old/Artemis", needsAttention: true)
        let lacking = try f.shelve(
            "Dune", "Frank Herbert", at: "Old/Dune", files: ["Dune.m4b", "Dune.epub"], needsAttention: true)
        try FileManager.default.removeItem(at: f.lib("Old/Dune/Dune.epub"))
        try f.service.applyLayoutChange(to: try pattern(Self.authorTitle))
        #expect(try f.folder(whole) == "Andy Weir/Artemis")
        #expect(try !f.flagged(whole))
        #expect(try f.folder(lacking) == "Frank Herbert/Dune")
        #expect(try f.flagged(lacking))
    }

    // MARK: FP33 Only folders move

    @Test func fp33_onlyFoldersAreRenamedAndFileRecordsFollow() throws {
        let (f, ids) = try smallLibrary()
        try Data("the owner's".utf8).write(to: f.lib("Andy Weir/Artemis/cover notes.txt"))
        try Data("hidden".utf8).write(to: f.lib("Andy Weir/Artemis/.keep"))
        func identity(_ path: String) throws -> [String] {
            let attributes = try FileManager.default.attributesOfItem(atPath: f.lib(path).path)
            return [
                String(describing: attributes[.systemFileNumber]), String(describing: attributes[.modificationDate]),
                String(describing: attributes[.size]),
            ]
        }
        let before = try LayoutState(f)
        let fileBefore = try identity("Andy Weir/Artemis/Artemis.m4b")
        let extraBefore = try identity("Andy Weir/Artemis/Extras/map.pdf")
        let renames = f.countRenames()

        try f.service.applyLayoutChange(to: try pattern(Self.byKind))

        // One rename for each book folder and nothing else: no copy, no file renamed or rewritten.
        #expect(renames() == 4)
        #expect(try identity("Audiobooks/Andy Weir/Artemis/Artemis.m4b") == fileBefore)
        #expect(try identity("Audiobooks/Andy Weir/Artemis/Extras/map.pdf") == extraBefore)
        let after = try LayoutState(f)
        // The same files with the same bytes, each under its book's new folder; what the
        // owner keeps in a book folder goes with it.
        #expect(after.bytes.count == before.bytes.count)
        for (path, data) in before.bytes {
            let kind = path.hasPrefix("Ann Author") ? "Ebooks" : "Audiobooks"
            #expect(after.bytes["\(kind)/\(path)"] == data, "\(path)")
        }
        #expect(after.bytes["Audiobooks/Andy Weir/Artemis/cover notes.txt"] == Data("the owner's".utf8))
        #expect(after.bytes["Audiobooks/Andy Weir/Artemis/.keep"] == Data("hidden".utf8))

        // The rows are the rows they were, with new paths; nothing else about a book changed.
        #expect(after.files.map(\.id) == before.files.map(\.id))
        for (old, new) in zip(before.files, after.files) {
            var expected = old
            expected.path = (old.path.hasPrefix("Ann Author") ? "Ebooks/" : "Audiobooks/") + old.path
            #expect(new == expected)
        }
        for (old, new) in zip(before.books, after.books) {
            var expected = old
            expected.folderPath = (old.folderPath?.hasPrefix("Ann Author") == true ? "Ebooks/" : "Audiobooks/") + (old.folderPath ?? "")
            #expect(new == expected)
        }
        _ = ids
    }

    // MARK: FP34 Moves that depend on each other

    @Test func fp34_twoBooksSwapFolders() throws {
        let f = try F()
        let one = try f.shelve("One", "Ann", at: "Ann/Two")
        let two = try f.shelve("Two", "Ann", at: "Ann/One")
        let before = try LayoutState(f)
        let done = try f.service.applyLayoutChange(to: .standard)
        #expect(done.moves.map(\.bookId) == [one, two])
        #expect(try read(f.lib("Ann/One/One.m4b")) == "One by Ann: One.m4b")
        #expect(try read(f.lib("Ann/Two/Two.m4b")) == "Two by Ann: Two.m4b")
        #expect(f.shown() == ["Ann", "Ann/One", "Ann/One/One.m4b", "Ann/Two", "Ann/Two/Two.m4b"])
        #expect(try f.rowPaths(one) == ["Ann/One/One.m4b"])
        #expect(try f.rowPaths(two) == ["Ann/Two/Two.m4b"])
        #expect(f.hiddenTree().isEmpty)
        #expect(try f.service.reconcile() == ReconcileReport())
        try expectUndoRestores(f, before)
    }

    @Test func fp34_threeBooksGoRound() throws {
        let f = try F()
        let a = try f.shelve("A", "Ann", at: "Ann/B")
        let b = try f.shelve("B", "Ann", at: "Ann/C")
        let c = try f.shelve("C", "Ann", at: "Ann/A")
        let before = try LayoutState(f)
        let done = try f.service.applyLayoutChange(to: .standard)
        #expect(done.moves.map(\.bookId) == [a, b, c])
        for name in ["A", "B", "C"] {
            #expect(try read(f.lib("Ann/\(name)/\(name).m4b")) == "\(name) by Ann: \(name).m4b")
        }
        #expect(try f.folder(a) == "Ann/A")
        #expect(try f.folder(b) == "Ann/B")
        #expect(try f.folder(c) == "Ann/C")
        #expect(f.hiddenTree().isEmpty)
        #expect(try f.service.reconcile() == ReconcileReport())
        try expectUndoRestores(f, before)
    }

    @Test func fp34_aBookTakesAFolderNameAnotherLeavesThatDiffersOnlyInCapitalisation() throws {
        let f = try F()
        guard !f.service.volumeNaming.caseSensitive else { return }
        // "Other" sits in "Ann/dune" and moves away; "Dune" moves to "Ann/Dune".
        let other = try f.shelve("Other", "Ann", at: "Ann/dune")
        let dune = try f.shelve("Dune", "Ann", at: "Old/Dune")
        let before = try LayoutState(f)
        let done = try f.service.applyLayoutChange(to: .standard)
        #expect(done.moves.map(\.bookId).sorted() == [other, dune])
        #expect(f.names(in: "Ann") == ["Dune", "Other"])
        #expect(try read(f.lib("Ann/Dune/Dune.m4b")) == "Dune by Ann: Dune.m4b")
        #expect(try read(f.lib("Ann/Other/Other.m4b")) == "Other by Ann: Other.m4b")
        #expect(try f.folder(dune) == "Ann/Dune")
        #expect(try f.service.reconcile() == ReconcileReport())
        try expectUndoRestores(f, before)
        #expect(f.names(in: "Ann") == ["dune"])
    }

    @Test func fp34_aBookFiledUnderAnotherCapitalisationIsInPlaceAndIsNotRenamed() throws {
        let f = try F()
        guard !f.service.volumeNaming.caseSensitive else { return }
        let id = try f.shelve("Artemis", "Andy Weir", at: "andy weir/ARTEMIS")
        let other = try f.shelve("The Martian", "Andy Weir", at: "Old/The Martian")
        let done = try f.service.applyLayoutChange(to: .standard)
        // The second book joins the author folder as the disk spells it.
        #expect(done.moves == [LayoutMove(bookId: other, title: "The Martian", from: "Old/The Martian", to: "andy weir/The Martian")])
        #expect(try f.folder(id) == "andy weir/ARTEMIS")
        #expect(f.names(in: "") .filter { !$0.hasPrefix(".") && !$0.hasPrefix("VoxCarrel") } == ["andy weir"])
        #expect(f.names(in: "andy weir") == ["ARTEMIS", "The Martian"])
        #expect(try f.service.reconcile() == ReconcileReport())
    }

    @Test func fp34_aBookMovesDeeperAlongItsOwnPath() throws {
        let f = try F()
        // "Dune" of the series "Dune": from Author/Title to Author/Series/Number - Title.
        let dune = try f.shelve(
            "Dune", "Frank Herbert", series: "Dune", number: "1", at: "Frank Herbert/Dune",
            files: ["Dune.m4b", "Extras/map.pdf"])
        let messiah = try f.shelve("Messiah", "Frank Herbert", series: "Dune", number: "2", at: "Frank Herbert/Messiah")
        try f.store.setFolderPatternText(Self.authorTitle)
        let before = try LayoutState(f)
        let done = try f.service.applyLayoutChange(to: .standard)
        #expect(done.moves.map(\.to) == ["Frank Herbert/Dune/1 - Dune", "Frank Herbert/Dune/2 - Messiah"])
        #expect(f.shown() == [
            "Frank Herbert", "Frank Herbert/Dune", "Frank Herbert/Dune/1 - Dune", "Frank Herbert/Dune/1 - Dune/Dune.m4b",
            "Frank Herbert/Dune/1 - Dune/Extras", "Frank Herbert/Dune/1 - Dune/Extras/map.pdf",
            "Frank Herbert/Dune/2 - Messiah", "Frank Herbert/Dune/2 - Messiah/Messiah.m4b",
        ])
        #expect(try f.rowPaths(dune) == ["Frank Herbert/Dune/1 - Dune/Dune.m4b", "Frank Herbert/Dune/1 - Dune/Extras/map.pdf"])
        #expect(try f.folder(messiah) == "Frank Herbert/Dune/2 - Messiah")
        #expect(f.hiddenTree().isEmpty)
        #expect(try f.service.reconcile() == ReconcileReport())
        try expectUndoRestores(f, before)
    }

    @Test func fp34_aBookMovesShallowerAlongItsOwnPath() throws {
        let f = try F()
        let dune = try f.shelve("Dune", "Frank Herbert", series: "Dune", number: "1")
        let messiah = try f.shelve("Messiah", "Frank Herbert", series: "Dune", number: "2")
        let other = try f.shelve("Artemis", "Andy Weir", series: "Moon")
        let before = try LayoutState(f)
        let done = try f.service.applyLayoutChange(to: try pattern(Self.authorTitle))
        #expect(done.moves.map(\.to) == ["Andy Weir/Artemis", "Frank Herbert/Dune", "Frank Herbert/Messiah"])
        #expect(f.shown() == [
            "Andy Weir", "Andy Weir/Artemis", "Andy Weir/Artemis/Artemis.m4b", "Frank Herbert", "Frank Herbert/Dune",
            "Frank Herbert/Dune/Dune.m4b", "Frank Herbert/Messiah", "Frank Herbert/Messiah/Messiah.m4b",
        ])
        #expect(try f.rowPaths(dune) == ["Frank Herbert/Dune/Dune.m4b"])
        #expect(try f.folder(messiah) == "Frank Herbert/Messiah")
        #expect(try f.folder(other) == "Andy Weir/Artemis")
        #expect(f.hiddenTree().isEmpty)
        #expect(try f.service.reconcile() == ReconcileReport())
        try expectUndoRestores(f, before)
    }

    @Test func fp34_aSeriesFolderThatKeepsSomethingElseIsNotTakenOver() throws {
        let f = try F()
        let dune = try f.shelve("Dune", "Frank Herbert", series: "Dune", number: "1")
        let messiah = try f.shelve("Messiah", "Frank Herbert", series: "Dune", number: "2")
        try Data("the owner's".utf8).write(to: f.lib("Frank Herbert/Dune/reading order.txt"))
        let done = try f.service.applyLayoutChange(to: try pattern(Self.authorTitle))
        #expect(stay(done, dune) == "A folder is already there.")
        #expect(move(done, messiah) == "Frank Herbert/Dune/2 - Messiah -> Frank Herbert/Messiah")
        #expect(f.shown() == [
            "Frank Herbert", "Frank Herbert/Dune", "Frank Herbert/Dune/1 - Dune", "Frank Herbert/Dune/1 - Dune/Dune.m4b",
            "Frank Herbert/Dune/reading order.txt", "Frank Herbert/Messiah", "Frank Herbert/Messiah/Messiah.m4b",
        ])
    }

    // MARK: FP35 All or nothing

    private func expectUnchanged(_ f: F, _ before: LayoutState, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let after = try LayoutState(f)
        #expect(after.tree == before.tree, sourceLocation: sourceLocation)
        #expect(after.bytes == before.bytes, sourceLocation: sourceLocation)
        #expect(after.books == before.books, sourceLocation: sourceLocation)
        #expect(after.files == before.files, sourceLocation: sourceLocation)
        #expect(after.pattern == before.pattern, sourceLocation: sourceLocation)
        #expect(after.batch == before.batch, sourceLocation: sourceLocation)
    }

    /// Twelve books, one of which stays behind and would be flagged.
    private func twelveBooks() throws -> F {
        let f = try F()
        for number in 1...11 {
            try f.shelve(
                "Book \(number)", "Author \(number % 4)", series: number % 2 == 0 ? "Series" : nil,
                number: number % 2 == 0 ? "\(number)" : nil, narrator: "Narrator \(number % 3)",
                files: ["Book \(number).m4b", "Extras/notes \(number).pdf"])
        }
        try f.shelve("Unread Aloud", "Author 0")
        try Data("the owner's".utf8).write(to: f.lib("Author 1/keep.txt"))
        try f.store.setFolderPatternText("{Author}/[{Series}/][{Number} - ]{Title}")
        return f
    }

    @Test(arguments: [1, 6, 11])
    func fp35_aFailureAtTheFirstAMiddleOrTheLastMoveLeavesTheLibraryAsItWas(failing: Int) throws {
        let f = try twelveBooks()
        let target = try pattern("{Narrator}/{Title}")
        let planned = try f.service.planLayoutChange(to: target)
        #expect(planned.moves.count == 11)
        #expect(planned.staying.count == 1)
        let before = try LayoutState(f)
        let renames = f.countRenames(failing: failing)

        #expect { try f.service.applyLayoutChange(to: target) } throws: { error in
            // The error says which book: the one whose folder was being moved.
            guard case LibraryError.layoutChangeFailed(let book, let reason) = error else { return false }
            return book == "“\(planned.moves[failing - 1].title)”" && !reason.isEmpty
        }

        // The failed rename, then one to put each folder already moved back.
        #expect(renames() == failing + (failing - 1))
        try expectUnchanged(f, before)
        #expect(try f.service.folderPattern() == .standard)
        #expect(try f.service.undoLabel() == nil)
        #expect(try f.service.reconcile() == ReconcileReport())

        // Once the obstacle is gone the same change goes through.
        f.countRenames()
        #expect(try f.service.applyLayoutChange(to: target) == planned)
    }

    @Test(arguments: 1...6)
    func fp35_aFailureAmongMovesThatDependOnEachOtherLeavesTheLibraryAsItWas(failing: Int) throws {
        let f = try F()
        try f.shelve("One", "Ann", at: "Ann/Two", files: ["One.m4b", "Extras/a.pdf"])
        try f.shelve("Two", "Ann", at: "Ann/One")
        try f.shelve("Dune", "Frank Herbert", series: "Dune", number: "1", at: "Frank Herbert/Dune")
        let before = try LayoutState(f)
        let renames = f.countRenames(failing: failing)
        #expect { try f.service.applyLayoutChange(to: .standard) } throws: { error in
            guard case LibraryError.layoutChangeFailed = error else { return false }
            return true
        }
        #expect(renames() >= failing)
        try expectUnchanged(f, before)
        #expect(try f.service.reconcile() == ReconcileReport())
    }

    @Test func fp35_aFailureAtCommitPutsEveryFolderBack() throws {
        let f = try twelveBooks()
        // An earlier operation is in the journal, and must still be there afterwards.
        _ = try f.importNew([try f.makeEPUB("in.epub")], F.meta("Quiet Rivers", "Ann Author"))
        let before = try LayoutState(f)
        #expect(before.batch != nil)
        let renames = f.countRenames()
        var commits = 0
        f.service.beforeCommit = {
            commits += 1
            throw Boom()
        }
        #expect(throws: Boom.self) { try f.service.applyLayoutChange(to: try pattern("{Narrator}/{Title}")) }
        #expect(commits == 1)
        // Every folder was moved, and every one was moved back.
        #expect(renames() == 22)
        try expectUnchanged(f, before)
        #expect(try f.service.folderPattern() == .standard)
        #expect(try f.service.undoLabel() == "Import 1 book")

        // The catalogue refusing the write does the same.
        f.service.beforeCommit = nil
        try f.store.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER refuse BEFORE UPDATE ON book BEGIN SELECT RAISE(ABORT, 'refused'); END
                """)
        }
        #expect(throws: (any Error).self) { try f.service.applyLayoutChange(to: try pattern("{Narrator}/{Title}")) }
        try f.store.dbQueue.write { db in try db.execute(sql: "DROP TRIGGER refuse") }
        try expectUnchanged(f, before)
    }

    @Test func fp35_aDestinationThatAppearsBetweenPlanningAndMovingIsNotOverwritten() throws {
        let f = try twelveBooks()
        let target = try pattern("{Narrator}/{Title}")
        let planned = try f.service.planLayoutChange(to: target)
        let before = try LayoutState(f)
        // Just as the fourth folder is about to be renamed, something else makes its destination.
        let intruder = f.lib(planned.moves[3].to)
        var count = 0
        f.service.renameFolder = { from, to in
            count += 1
            if count == 4 {
                try FileManager.default.createDirectory(at: intruder, withIntermediateDirectories: true)
                try Data("not ours".utf8).write(to: intruder.appendingPathComponent("theirs.txt"))
            }
            try FolderMover.renameWithoutReplacing(from, to)
        }
        #expect { try f.service.applyLayoutChange(to: target) } throws: { error in
            guard case LibraryError.layoutChangeFailed(let book, _) = error else { return false }
            return book == "“\(planned.moves[3].title)”"
        }
        // What appeared is untouched, and everything of the library's is as it was.
        #expect(try read(intruder.appendingPathComponent("theirs.txt")) == "not ours")
        #expect(f.names(in: planned.moves[3].to) == ["theirs.txt"])
        let after = try LayoutState(f)
        #expect(after.books == before.books)
        #expect(after.files == before.files)
        #expect(after.pattern == before.pattern)
        #expect(after.batch == before.batch)
        for (path, data) in before.bytes { #expect(after.bytes[path] == data, "\(path)") }
        #expect(after.bytes.count == before.bytes.count + 1)
    }

    @Test func fp35_whenAFolderCannotBePutBackTheErrorNamesItAndNothingIsLost() throws {
        let f = try twelveBooks()
        let target = try pattern("{Narrator}/{Title}")
        let planned = try f.service.planLayoutChange(to: target)
        let before = try LayoutState(f)
        let first = planned.moves[0]
        let root = f.root
        var count = 0
        f.service.renameFolder = { from, to in
            count += 1
            // The third move fails, and then the first folder cannot go back.
            if count == 3 || to.path == root.appendingPathComponent(first.from).path { throw Boom() }
            try FolderMover.renameWithoutReplacing(from, to)
        }
        #expect { try f.service.applyLayoutChange(to: target) } throws: { error in
            guard case LibraryError.rollbackIncomplete(let cause, let stranded) = error else { return false }
            return cause.contains(planned.moves[2].title) && stranded.count == 1
                && stranded[0].hasSuffix("/\(first.to) (from \(root.appendingPathComponent(first.from).path))")
        }
        // The catalogue is as it was, and every file still exists with its bytes.
        let after = try LayoutState(f)
        #expect(after.books == before.books)
        #expect(after.files == before.files)
        #expect(after.pattern == before.pattern)
        // (The one new file is the record of the change, kept until the folder is back.)
        var files = after.bytes
        #expect(files.removeValue(forKey: ".voxcarrel/\(LayoutIntent.fileName)") != nil)
        #expect(Set(files.values) == Set(before.bytes.values))
        #expect(files.count == before.bytes.count)
        // The record of the change is kept, and the launch check says which folder is
        // out of place (and, the obstacle being there still, cannot put it back).
        #expect(f.service.hasInterruptedLayoutChange)
        let report = try f.service.reconcile()
        #expect(report.layoutChangeProblem != nil)
        #expect(report.strandedFolders.map(\.belongsAt) == [first.from])
    }

    // MARK: FP36 Emptied folders

    @Test func fp36_foldersTheChangeEmptiesAreRemovedAndOthersAreLeftAlone() throws {
        let f = try F()
        try f.shelve("Dune", "Frank Herbert", series: "Dune Saga", number: "1")
        try f.shelve("Artemis", "Andy Weir")
        try f.shelve("Emma", "Jane Austen")
        try f.shelve("Ulysses", "James Joyce")
        try f.shelve("Solaris", "Stanislaw Lem")
        // A .DS_Store alone does not keep a folder; anything else does.
        try Data().write(to: f.lib("Frank Herbert/Dune Saga/.DS_Store"))
        try Data().write(to: f.lib("Frank Herbert/.DS_Store"))
        try Data("the owner's".utf8).write(to: f.lib("Andy Weir/notes.txt"))
        try Data().write(to: f.lib("Andy Weir/.DS_Store"))
        try Data().write(to: f.lib("Jane Austen/.hidden"))
        try FileManager.default.createDirectory(at: f.lib("James Joyce/Empty"), withIntermediateDirectories: true)

        try f.service.applyLayoutChange(to: try pattern("Books/{Title}"))

        #expect(f.shown() == [
            "Andy Weir", "Andy Weir/.DS_Store", "Andy Weir/notes.txt", "Books", "Books/Artemis", "Books/Artemis/Artemis.m4b",
            "Books/Dune", "Books/Dune/Dune.m4b", "Books/Emma", "Books/Emma/Emma.m4b", "Books/Solaris",
            "Books/Solaris/Solaris.m4b", "Books/Ulysses", "Books/Ulysses/Ulysses.m4b", "James Joyce", "James Joyce/Empty",
            "Jane Austen", "Jane Austen/.hidden",
        ])
        #expect(FileManager.default.fileExists(atPath: f.root.path))
    }

    @Test func fp36_theLibraryFolderItselfIsNeverRemoved() throws {
        let f = try F()
        let id = try f.shelve("Dune", "Frank Herbert", at: "Dune")
        try f.service.applyLayoutChange(to: .standard)
        #expect(try f.folder(id) == "Frank Herbert/Dune")
        try f.service.applyLayoutChange(to: try pattern("{Title}"))
        #expect(try f.folder(id) == "Dune")
        #expect(f.shown() == ["Dune", "Dune/Dune.m4b"])
        #expect(FileManager.default.fileExists(atPath: f.store.libraryRoot.appendingPathComponent(LibraryStore.databaseFileName).path))
    }

    // MARK: FP37 Undo

    /// Undoes the last operation and checks the library is exactly as `before`, apart
    /// from the journal, which is now empty.
    private func expectUndoRestores(
        _ f: F, _ before: LayoutState, launchCheck: Bool = true, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        #expect(try f.service.undoLabel() == "Change Folder Layout", sourceLocation: sourceLocation)
        #expect(try f.service.undoLast() == "Change Folder Layout", sourceLocation: sourceLocation)
        let after = try LayoutState(f)
        #expect(after.tree == before.tree, sourceLocation: sourceLocation)
        #expect(after.bytes == before.bytes, sourceLocation: sourceLocation)
        #expect(after.books == before.books, sourceLocation: sourceLocation)
        #expect(after.files == before.files, sourceLocation: sourceLocation)
        #expect(after.pattern == before.pattern, sourceLocation: sourceLocation)
        #expect(after.batch == nil, sourceLocation: sourceLocation)
        #expect(try f.service.undoLabel() == nil, sourceLocation: sourceLocation)
        if launchCheck { #expect(try f.service.reconcile() == ReconcileReport(), sourceLocation: sourceLocation) }
    }

    @Test(arguments: [
        "{Kind}/{Author}/[{Series}/][{Number} - ]{Title}", "{Author}/{Title}", "{Narrator}/{Title}",
        "{Series}/[{Number} - ]{Title}|{Author}/{Title}", "Books/{Title}", "{Title}",
    ])
    func fp37_undoRestoresEveryFolderThePatternAndTheCatalogue(text: String) throws {
        let f = try twelveBooks()
        try Data("the owner's".utf8).write(to: f.lib("Author 1/Book 1/own notes.txt"))
        let before = try LayoutState(f)
        let done = try f.service.applyLayoutChange(to: try pattern(text))
        #expect(!done.moves.isEmpty)
        #expect(try LayoutState(f).tree != before.tree)
        #expect(try f.service.reconcile() == ReconcileReport())
        try expectUndoRestores(f, before)
        #expect(try f.service.folderPattern() == .standard)
    }

    @Test func fp37_undoPutsBackAPatternThatWasNotStoredAndFlagsThatWereNotSet() throws {
        let f = try F()
        let narrated = try f.shelve("Artemis", "Andy Weir", narrator: "Rosario Dawson")
        let plain = try f.shelve("The Martian", "Andy Weir")
        let flaggedBefore = try f.shelve("Old", "Andy Weir", narrator: "Someone", at: "Shelf/Old", needsAttention: true)
        let before = try LayoutState(f)
        #expect(before.pattern == nil)
        try f.service.applyLayoutChange(to: try pattern("{Narrator}/{Title}"))
        #expect(try f.flagged(plain))
        #expect(try !f.flagged(flaggedBefore))
        #expect(try f.folder(narrated) == "Rosario Dawson/Artemis")
        // (The launch check would take that last flag away again, as it would have before.)
        try expectUndoRestores(f, before, launchCheck: false)
        #expect(try f.store.folderPatternText() == nil)
        #expect(try !f.flagged(plain))
        #expect(try f.flagged(flaggedBefore))
    }

    @Test func fp37_undoKeepsWhatWasDoneToABookSinceThatIsNotItsToUndo() throws {
        let (f, ids) = try smallLibrary()
        let before = try LayoutState(f)
        try f.service.applyLayoutChange(to: try pattern(Self.byKind))
        try f.service.setReadStatus(.finished, for: [ids[0]])
        try f.service.undoLast()
        let after = try LayoutState(f)
        #expect(after.tree == before.tree)
        #expect(after.files == before.files)
        #expect(try #require(try f.store.book(id: ids[0])).readStatus == .finished)
        #expect(try f.folder(ids[0]) == "Frank Herbert/Dune Saga/1 - Dune")
    }

    @Test func fp37_undoOfALibraryChangedByHandSinceFailsSafely() throws {
        // Something now stands where a folder was; a folder was moved away; a folder's
        // book files were taken out of it.
        for change in ["blocked", "moved away", "emptied"] {
            let (f, ids) = try smallLibrary()
            try f.service.applyLayoutChange(to: try pattern(Self.byKind))
            switch change {
            case "blocked":
                try FileManager.default.createDirectory(at: f.lib("Andy Weir/Artemis"), withIntermediateDirectories: true)
                try Data("new".utf8).write(to: f.lib("Andy Weir/Artemis/new.txt"))
            case "moved away":
                try FileManager.default.moveItem(at: f.lib("Audiobooks/Andy Weir/Artemis"), to: f.base.appendingPathComponent("Away"))
            default:
                try FileManager.default.moveItem(
                    at: f.lib("Audiobooks/Andy Weir/Artemis/Artemis.m4b"), to: f.base.appendingPathComponent("Away.m4b"))
                try FileManager.default.removeItem(at: f.lib("Audiobooks/Andy Weir/Artemis/Extras/map.pdf"))
            }
            let changed = try LayoutState(f)
            #expect("\(change)".isEmpty == false)
            #expect { try f.service.undoLast() } throws: { error in
                guard case LibraryError.undoBlocked(let reason) = error else { return false }
                return !reason.isEmpty
            }
            // Nothing at all was changed, and the undo is still there to try again.
            try expectUnchanged(f, changed)
            #expect(try f.service.undoLabel() == "Change Folder Layout")
            #expect(try f.folder(ids[2]) == "Audiobooks/Andy Weir/Artemis")

            // With the library as the change left it again, undo goes through.
            switch change {
            case "blocked":
                try FileManager.default.removeItem(at: f.lib("Andy Weir"))
            case "moved away":
                try FileManager.default.moveItem(at: f.base.appendingPathComponent("Away"), to: f.lib("Audiobooks/Andy Weir/Artemis"))
            default:
                try FileManager.default.moveItem(
                    at: f.base.appendingPathComponent("Away.m4b"), to: f.lib("Audiobooks/Andy Weir/Artemis/Artemis.m4b"))
            }
            try f.service.undoLast()
            #expect(try f.folder(ids[2]) == "Andy Weir/Artemis")
            #expect(FileManager.default.fileExists(atPath: f.lib("Andy Weir/Artemis/Artemis.m4b").path))
        }
    }

    @Test func fp37_whenUndoCannotWriteTheCatalogueTheFoldersAreLeftAsTheChangeLeftThem() throws {
        let f = try twelveBooks()
        let before = try LayoutState(f)
        try f.service.applyLayoutChange(to: try pattern("{Narrator}/{Title}"))
        let changed = try LayoutState(f)
        f.service.beforeCommit = { throw Boom() }
        #expect(throws: Boom.self) { try f.service.undoLast() }
        try expectUnchanged(f, changed)
        #expect(try f.service.reconcile() == ReconcileReport())
        f.service.beforeCommit = nil
        try expectUndoRestores(f, before)
    }

    @Test func fp37_removingABookTheChangeMovedForgetsTheUndo() throws {
        let (f, ids) = try smallLibrary()
        try f.service.applyLayoutChange(to: try pattern(Self.byKind))
        let trashed = f.base.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)
        f.service.trashItem = { try FileManager.default.moveItem(at: $0, to: trashed.appendingPathComponent($0.lastPathComponent)) }
        try f.service.removeBook(id: ids[2], moveFilesToTrash: true)
        #expect(try f.service.undoLabel() == nil)
        #expect(try f.store.folderPatternText() == Self.byKind)
    }

    @Test func fp37_theUndoDataSaysItIsALayoutChangeSoOlderVersionsLeaveItAlone() throws {
        let (f, ids) = try smallLibrary()
        try f.service.applyLayoutChange(to: try pattern(Self.byKind))
        let snapshot = try f.snapshot()
        #expect(snapshot.version == 2)
        #expect(OperationSnapshot.currentVersion == 5)
        #expect(snapshot.books.isEmpty)
        let saved = try #require(snapshot.layoutChange)
        #expect(saved.patternTextBefore == nil)
        #expect(saved.books.map(\.bookId).sorted() == ids)
        #expect(saved.books.first { $0.bookId == ids[2] } == LayoutChangeSnapshot.BookBefore(
            bookId: ids[2], folderBefore: "Andy Weir/Artemis", folderAfter: "Audiobooks/Andy Weir/Artemis",
            needsAttentionBefore: false))
        // Code that knows only the first version reads the version and refuses, as
        // `usable` does for any version newer than its own.
        let data = try #require(try f.store.lastBatch()?.snapshot)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["version"] as? Int == 2)
        #expect(json["layoutChange"] != nil)
    }

    // MARK: FP38 Nothing to do

    @Test func fp38_thePatternInUseWithEveryBookInPlaceDoesNothingAndRecordsNothing() throws {
        let (f, _) = try smallLibrary()
        _ = try f.importNew([try f.makeEPUB("in.epub")], F.meta("Second Ebook", "Ann Author"))
        let before = try LayoutState(f)
        let renames = f.countRenames()
        var commits = 0
        f.service.beforeCommit = { commits += 1 }
        for same in [FolderPattern.standard, try pattern("{author}/[{SERIES}/][{number} - ]{title}")] {
            let done = try f.service.applyLayoutChange(to: same)
            #expect(done.moves.isEmpty)
            #expect(done.unchangedCount == 5)
        }
        #expect(renames() == 0)
        #expect(commits == 0)
        try expectUnchanged(f, before)
        #expect(try f.service.undoLabel() == "Import 1 book")
        // The earlier operation's undo data is still there to use.
        #expect(try f.service.undoLast() == "Import 1 book")
    }

    @Test func fp38_aNewPatternIsStoredEvenWhenNoBookMoves() throws {
        let f = try F()
        let before = try LayoutState(f)
        let done = try f.service.applyLayoutChange(to: try pattern(Self.byKind))
        #expect(done.moves.isEmpty)
        #expect(try f.store.folderPatternText() == Self.byKind)
        #expect(try f.service.undoLabel() == "Change Folder Layout")
        // And a book imported now follows it.
        let id = try f.importNew([try f.makeEPUB("in.epub")], F.meta("Quiet Rivers", "Ann Author"))
        #expect(try f.folder(id) == "Ebooks/Ann Author/Quiet Rivers")
        _ = before
    }

    @Test func fp38_thePatternInUseStillMovesABookThatIsNotInPlace() throws {
        let f = try F()
        let id = try f.shelve("Artemis", "Andy Weir", at: "Elsewhere/Artemis")
        let before = try LayoutState(f)
        let done = try f.service.applyLayoutChange(to: .standard)
        #expect(done.moves.count == 1)
        #expect(try f.folder(id) == "Andy Weir/Artemis")
        try expectUndoRestores(f, before)
    }

    // MARK: FP39 What is not touched

    @Test func fp39_strandedAndUntrackedFilesStayAndExtrasGoWithTheirBook() throws {
        let (f, ids) = try smallLibrary()
        let strandedName = ".voxcarrel-moving-\(UUID().uuidString)"
        try Data("stranded".utf8).write(to: f.lib("Frank Herbert/\(strandedName)"))
        try Data("untracked".utf8).write(to: f.lib("Frank Herbert/Dune Saga/stray.m4b"))
        try Data("loose".utf8).write(to: f.lib("loose.epub"))
        let catalogue = try FileManager.default.attributesOfItem(atPath: f.lib(LibraryStore.databaseFileName).path)
        try f.service.covers.set(F.jpeg, for: ids[0])
        let hiddenBefore = f.hiddenTree()

        try f.service.applyLayoutChange(to: try pattern(Self.byKind))

        #expect(try read(f.lib("Frank Herbert/\(strandedName)")) == "stranded")
        #expect(try read(f.lib("Frank Herbert/Dune Saga/stray.m4b")) == "untracked")
        #expect(try read(f.lib("loose.epub")) == "loose")
        #expect(f.shown().filter { $0.hasPrefix("Frank Herbert") } == [
            "Frank Herbert", "Frank Herbert/\(strandedName)", "Frank Herbert/Dune Saga", "Frank Herbert/Dune Saga/stray.m4b",
        ].sorted())
        // Extras went with their book.
        #expect(try read(f.lib("Audiobooks/Andy Weir/Artemis/Extras/map.pdf")) == "Artemis by Andy Weir: Extras/map.pdf")
        // The catalogue and the hidden folder are where they were.
        let catalogueAfter = try FileManager.default.attributesOfItem(atPath: f.lib(LibraryStore.databaseFileName).path)
        #expect(catalogueAfter[.systemFileNumber] as? Int == catalogue[.systemFileNumber] as? Int)
        #expect(f.hiddenTree() == hiddenBefore)
        #expect(f.service.covers.image(for: ids[0]) != nil)
        let report = try f.service.reconcile()
        #expect(report.strandedFiles.map(\.lastPathComponent) == [strandedName])
        #expect(report.untrackedFiles.map(\.lastPathComponent) == ["stray.m4b", "loose.epub"])
        #expect(report.booksWithMissingFiles.isEmpty)
    }

    // MARK: FP40 A large library

    @Test func fp40_twoThousandBooksAreRefiledAndPutBackInGoodTime() throws {
        let f = try F()
        for number in 1...2000 {
            let series = number % 3 == 0 ? "Series \(number % 40)" : nil
            try f.shelve(
                "Book \(number)", "Author \(number % 700)", series: series, number: series == nil ? nil : "\(number)",
                files: number % 5 == 0 ? ["Book \(number).epub"] : ["Book \(number).m4b", "Extras/notes.pdf"])
        }
        let before = try LayoutState(f)
        let clock = ContinuousClock()
        var done: LayoutChangePlan?
        let planning = try clock.measure { _ = try f.service.planLayoutChange(to: try pattern(Self.byKind)) }
        let changing = try clock.measure { done = try f.service.applyLayoutChange(to: try pattern(Self.byKind)) }
        #expect(done?.moves.count == 2000)
        #expect(try f.folder(1) == "Audiobooks/Author 1/Book 1")
        #expect(try f.folder(15) == "Ebooks/Author 15/Series 15/15 - Book 15")
        #expect(f.shown().filter { !$0.contains("/") } == ["Audiobooks", "Ebooks"])
        let undoing = try clock.measure { try f.service.undoLast() }
        #expect(planning < .seconds(60))
        #expect(changing < .seconds(60))
        #expect(undoing < .seconds(60))
        let after = try LayoutState(f)
        #expect(after.tree == before.tree)
        #expect(after.bytes == before.bytes)
        #expect(after.books == before.books)
        #expect(after.files == before.files)
        #expect(try f.service.reconcile() == ReconcileReport())
    }

    // MARK: The launch check and folders set aside

    @Test func theLaunchCheckReportsAFolderLeftSetAside() throws {
        let (f, _) = try smallLibrary()
        // As a change interrupted with a folder set aside would leave things.
        let slot = f.service.layout.movingFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: f.lib("Andy Weir/Artemis"), to: slot.appendingPathComponent("1"))
        let list = [FolderMover.ManifestEntry(parkedAs: "1", folder: "Andy Weir/Artemis", movingTo: "Audiobooks/Andy Weir/Artemis")]
        try JSONEncoder().encode(list).write(to: slot.appendingPathComponent(FolderMover.manifestName))
        // And an operation's folder with nothing set aside left in it.
        let finished = f.service.layout.movingFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: finished, withIntermediateDirectories: true)
        try JSONEncoder().encode(list).write(to: finished.appendingPathComponent(FolderMover.manifestName))

        let report = try f.service.reconcile()
        #expect(report.strandedFolders == [
            StrandedFolder(
                url: slot.appendingPathComponent("1", isDirectory: true), belongsAt: "Andy Weir/Artemis",
                wasMovingTo: "Audiobooks/Andy Weir/Artemis"),
        ])
        #expect(report.booksWithMissingFiles.count == 1)
        // The folder is left exactly where it is; the finished operation's folder is cleared away.
        #expect(try read(slot.appendingPathComponent("1/Artemis.m4b")) == "Artemis by Andy Weir: Artemis.m4b")
        #expect(!FileManager.default.fileExists(atPath: finished.path))
        // Said again at every check until it is dealt with.
        #expect(try f.service.reconcile().strandedFolders.count == 1)
    }

    @Test func theLaunchCheckReportsAFolderSetAsideWithoutItsList() throws {
        let (f, _) = try smallLibrary()
        let slot = f.service.layout.movingFolder.appendingPathComponent("anything", isDirectory: true)
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: f.lib("Andy Weir/Artemis"), to: slot.appendingPathComponent("7"))
        #expect(try f.service.reconcile().strandedFolders == [StrandedFolder(url: slot.appendingPathComponent("7", isDirectory: true))])
        // A hidden folder left beside the books under a half-moved name is said too.
        let name = ".voxcarrel-moving-\(UUID().uuidString)"
        try FileManager.default.moveItem(at: f.lib("Ann Author/Quiet Rivers"), to: f.lib("Ann Author/\(name)"))
        #expect(Set(try f.service.reconcile().strandedFolders.map(\.url.lastPathComponent)) == ["7", name])
    }
}
