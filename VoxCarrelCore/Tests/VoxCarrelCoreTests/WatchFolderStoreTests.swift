import Foundation
import GRDB
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// Watch folders and the inbox ledger in the catalogue (rules IB1–IB8).
@Suite struct WatchFolderStoreTests {
    typealias F = LibraryFixture

    let now = Date(timeIntervalSinceReferenceDate: 800_000_000.123456)

    /// A new, empty folder beside the library.
    private func folder(_ f: F, _ name: String) throws -> URL {
        let url = f.base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func link(_ f: F, _ name: String, to target: URL) throws -> URL {
        let url = f.base.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        return url
    }

    /// The path the catalogue should hold for a folder.
    private func stored(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func listed(_ folder: URL, _ name: String, size: Int64 = 10, modified: TimeInterval = 700_000_000.5) -> ListedFile {
        ListedFile(
            url: URL(fileURLWithPath: stored(folder)).appendingPathComponent(name), size: size,
            modifiedAt: Date(timeIntervalSinceReferenceDate: modified))
    }

    private func entries(_ f: F, _ folderId: Int64) throws -> [InboxEntryRecord] {
        try f.store.inboxEntries(folderId: folderId)
    }

    private func entryCount(_ f: F) throws -> Int {
        try f.store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inboxEntry") ?? -1 }
    }

    /// Gives a folder one ledger entry of each state; returns the folder.
    private func folderWithEveryState(_ f: F, _ name: String = "Watched") throws -> WatchFolder {
        let url = try folder(f, name)
        f.service.listWatchFolder = { [self] _, _ in .found([listed(url, "old1.m4b"), listed(url, "old2.m4b")]) }
        let added = try f.service.addWatchFolder(url, now: now)
        f.service.listWatchFolder = { _, _ in .found([]) }
        try f.store.recordInboxEntries([listed(url, "no.m4b")], state: .dismissed, folderId: added.id)
        try f.store.recordInboxEntries([listed(url, "done.m4b")], state: .imported, folderId: added.id)
        return added
    }

    // MARK: IB1

    @Test func IB1_aNewFolderIsStoredWithItsDefaults() throws {
        let f = try F()
        let url = try folder(f, "Watched")

        let added = try f.service.addWatchFolder(url, now: now)

        #expect(added.path == stored(url))
        #expect(!added.path.hasSuffix("/"))
        #expect(added.mode == .move)
        #expect(added.isEnabled)
        #expect(!added.includesPDFs)
        #expect(added.addedAt == now)
        #expect(try f.service.watchFolders() == [added])
    }

    @Test func IB1_thePathIsStandardisedWithLinksResolved() throws {
        let f = try F()
        let url = try folder(f, "Watched")
        _ = try folder(f, "Other")
        let viaLink = try link(f, "Link", to: url)
        let roundabout = URL(fileURLWithPath: viaLink.path + "/../Other/../Link/", isDirectory: true)

        let added = try f.service.addWatchFolder(roundabout, now: now)

        #expect(added.path == stored(url))
        #expect(try f.service.watchFolders().map(\.path) == [stored(url)])
    }

    @Test func IB1_foldersAreListedOldestFirst() throws {
        let f = try F()
        let later = try f.service.addWatchFolder(try folder(f, "A"), now: now.addingTimeInterval(60))
        let earlier = try f.service.addWatchFolder(try folder(f, "B"), now: now)
        let same = try f.service.addWatchFolder(try folder(f, "C"), now: now)

        #expect(try f.service.watchFolders().map(\.id) == [earlier.id, same.id, later.id])
    }

    // MARK: IB2

    private func expectRefused(
        _ f: F, _ url: URL, _ problem: WatchFolderProblem, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let before = try f.service.watchFolders()
        let entriesBefore = try entryCount(f)
        f.service.listWatchFolder = { [self] folder, _ in .found([listed(folder, "x.m4b")]) }
        #expect(throws: problem, sourceLocation: sourceLocation) {
            try f.service.addWatchFolder(url, now: now)
        }
        #expect(try f.service.watchFolders() == before, sourceLocation: sourceLocation)
        #expect(try entryCount(f) == entriesBefore, sourceLocation: sourceLocation)
    }

    @Test func IB2_aPathThatIsNotAnExistingFolderIsRefused() throws {
        let f = try F()
        try expectRefused(f, f.base.appendingPathComponent("Nowhere", isDirectory: true), .notAFolder)
        let file = try touch(f.base.appendingPathComponent("file.m4b"))
        try expectRefused(f, file, .notAFolder)
        // A link that leads nowhere, and one that leads to a file.
        try expectRefused(f, try link(f, "Dangling", to: f.base.appendingPathComponent("Gone")), .notAFolder)
        try expectRefused(f, try link(f, "ToFile", to: file), .notAFolder)
    }

    @Test func IB2_theLibraryFolderIsRefused() throws {
        let f = try F()
        try expectRefused(f, f.root, .isLibrary)
        try expectRefused(f, URL(fileURLWithPath: f.root.path + "/../Library/"), .isLibrary)
    }

    @Test func IB2_aFolderInsideTheLibraryIsRefused() throws {
        let f = try F()
        let inside = f.root.appendingPathComponent("Author/Book", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try expectRefused(f, inside, .insideLibrary)
        try expectRefused(f, inside.deletingLastPathComponent(), .insideLibrary)
    }

    @Test func IB2_aFolderThatContainsTheLibraryIsRefused() throws {
        let f = try F()
        try expectRefused(f, f.base, .containsLibrary)
        try expectRefused(f, f.base.deletingLastPathComponent(), .containsLibrary)
    }

    @Test func IB2_aFolderEqualToInsideOrAroundAWatchFolderIsRefused() throws {
        let f = try F()
        let outer = try folder(f, "Area/Watched")
        let existing = try f.service.addWatchFolder(outer, now: now)

        // Equal, however it is spelled.
        try expectRefused(f, outer, .overlaps(existing: existing.path))
        try expectRefused(
            f, URL(fileURLWithPath: outer.path + "/../Watched/"), .overlaps(existing: existing.path))
        // Inside.
        try expectRefused(f, try folder(f, "Area/Watched/Sub/Deeper"), .overlaps(existing: existing.path))
        // Around.
        try expectRefused(f, f.base.appendingPathComponent("Area"), .overlaps(existing: existing.path))
    }

    @Test func IB2_aDisabledWatchFolderStillCountsForOverlap() throws {
        let f = try F()
        var existing = try f.service.addWatchFolder(try folder(f, "Watched"), now: now)
        existing.isEnabled = false
        try f.service.updateWatchFolder(existing)

        try expectRefused(f, try folder(f, "Watched/Sub"), .overlaps(existing: existing.path))
    }

    /// `/a/bc` is not inside `/a/b`: paths are compared by components, not as text.
    @Test func IB2_aFolderWhoseNameOnlyStartsTheSameIsAccepted() throws {
        let f = try F()
        let b = try f.service.addWatchFolder(try folder(f, "a/b"), now: now)
        let bc = try f.service.addWatchFolder(try folder(f, "a/bc"), now: now)
        // The same near-miss against the library ("Library" and "Library2", "Lib").
        let beside = try f.service.addWatchFolder(try folder(f, "Library2"), now: now)
        let shorter = try f.service.addWatchFolder(try folder(f, "Lib"), now: now)
        // And the shorter name added after the longer one.
        let longFirst = try f.service.addWatchFolder(try folder(f, "c/de"), now: now)
        let shortAfter = try f.service.addWatchFolder(try folder(f, "c/d"), now: now)

        #expect(
            try f.service.watchFolders().map(\.id)
                == [b.id, bc.id, beside.id, shorter.id, longFirst.id, shortAfter.id])
    }

    @Test func IB2_aPathReachedThroughASymbolicLinkIsJudgedByWhereItLeads() throws {
        let f = try F()
        let inside = f.root.appendingPathComponent("Author", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let watched = try folder(f, "Watched")
        let sub = try folder(f, "Watched/Sub")
        let existing = try f.service.addWatchFolder(watched, now: now)

        try expectRefused(f, try link(f, "ToLibrary", to: f.root), .isLibrary)
        try expectRefused(f, try link(f, "ToInside", to: inside), .insideLibrary)
        try expectRefused(f, try link(f, "ToBase", to: f.base), .containsLibrary)
        try expectRefused(f, try link(f, "ToWatched", to: watched), .overlaps(existing: existing.path))
        try expectRefused(f, try link(f, "ToSub", to: sub), .overlaps(existing: existing.path))
        // A link on the way down.
        try expectRefused(
            f, try link(f, "ToWatched2", to: watched).appendingPathComponent("Sub"),
            .overlaps(existing: existing.path))
    }

    /// Where the disk ignores capitalisation, another spelling of a folder is that folder.
    @Test func IB2_anotherCapitalisationOfAWatchFolderIsTheSameFolder() throws {
        let f = try F()
        let watched = try folder(f, "Watched")
        let existing = try f.service.addWatchFolder(watched, now: now)
        let shouted = f.base.appendingPathComponent("WATCHED", isDirectory: true)
        // On a disk that tells the two apart there is no such folder, and nothing to test.
        guard exists(shouted) else { return }

        try expectRefused(f, shouted, .overlaps(existing: existing.path))
    }

    // MARK: IB3

    @Test func IB3_whatIsThereWhenAFolderIsAddedIsRecordedAsBaseline() throws {
        let f = try F()
        let url = try folder(f, "Watched")
        let files = [listed(url, "a.m4b", size: 123_456_789_012, modified: 700_000_000.123456789),
                     listed(url, "Book/part1.mp3", size: 1, modified: 1)]
        var asked: [(URL, Bool)] = []
        f.service.listWatchFolder = { folder, includePDFs in
            asked.append((folder, includePDFs))
            return .found(files)
        }

        let added = try f.service.addWatchFolder(url, now: now)

        // Asked once, for the stored folder, without PDFs (a new folder has them off).
        #expect(asked.count == 1)
        #expect(asked.first?.0.path == added.path)
        #expect(asked.first?.1 == false)
        let recorded = try entries(f, added.id)
        #expect(recorded.map(\.path) == files.map(\.url.path))
        #expect(recorded.map(\.size) == files.map(\.size))
        // Dates come back exactly, so a file can later be compared with its entry.
        #expect(recorded.map(\.modifiedAt) == files.map(\.modifiedAt))
        #expect(recorded.allSatisfy { $0.state == .baseline && $0.folderId == added.id })
    }

    /// With the lister the service has unless a test replaces it: the real one.
    @Test func IB3_theSupportedFilesReallyInTheFolderAreItsBaseline() throws {
        let f = try F()
        let url = try folder(f, "Watched")
        let book = try touch(url.appendingPathComponent("a.m4b"), "four")
        let part = try touch(url.appendingPathComponent("Book/part 1.MP3"), "sixsix")
        try touch(url.appendingPathComponent("paper.pdf"))
        try touch(url.appendingPathComponent("notes.txt"))
        try touch(url.appendingPathComponent(".hidden.m4b"))
        try touch(url.appendingPathComponent("empty.m4b"), "")
        try touch(url.appendingPathComponent("book.m4b.crdownload"))

        let added = try f.service.addWatchFolder(url, now: now)

        let recorded = try entries(f, added.id).sorted { $0.path < $1.path }
        // Paths are under the stored folder, as text; PDFs are off for a new folder.
        #expect(recorded.map(\.path) == [added.path + "/Book/part 1.MP3", added.path + "/a.m4b"])
        #expect(recorded.map(\.size) == [6, 4])
        let dates = try [part, book].map {
            try #require(try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        }
        #expect(recorded.map(\.modifiedAt) == dates)
        #expect(recorded.allSatisfy { $0.state == .baseline && $0.folderId == added.id })
        // And they are what the lister reports for the stored folder now.
        let listed = FolderLister().list(added.url, includePDFs: false).files
        #expect(listed.map(\.url.path) == recorded.map(\.path))
        #expect(listed.map(\.modifiedAt) == recorded.map(\.modifiedAt))
    }

    @Test func IB3_withAListerThatFindsNothingNothingIsRecorded() throws {
        let f = try F()
        let url = try folder(f, "Watched")
        try touch(url.appendingPathComponent("a.m4b"))
        f.service.listWatchFolder = { _, _ in .found([]) }

        let added = try f.service.addWatchFolder(url, now: now)

        #expect(try f.service.watchFolders() == [added])
        #expect(try entryCount(f) == 0)
    }

    /// One transaction: when the baseline cannot be stored, neither is the folder.
    @Test func IB3_theFolderAndItsBaselineAreStoredTogetherOrNotAtAll() throws {
        let f = try F()
        let url = try folder(f, "Watched")
        // The same path twice breaks the ledger's rule of one entry per file.
        f.service.listWatchFolder = { [self] _, _ in .found([listed(url, "a.m4b"), listed(url, "a.m4b")]) }

        #expect(throws: (any Error).self) { try f.service.addWatchFolder(url, now: now) }

        #expect(try f.service.watchFolders().isEmpty)
        #expect(try entryCount(f) == 0)
    }

    @Test func IB3_twoFoldersMayHoldEntriesOfTheSameName() throws {
        let f = try F()
        let one = try folder(f, "One")
        let two = try folder(f, "Two")
        f.service.listWatchFolder = { [self] folder, _ in .found([listed(folder, "a.m4b")]) }

        let first = try f.service.addWatchFolder(one, now: now)
        let second = try f.service.addWatchFolder(two, now: now)

        #expect(try entries(f, first.id).map(\.path) == [first.path + "/a.m4b"])
        #expect(try entries(f, second.id).map(\.path) == [second.path + "/a.m4b"])
    }

    // MARK: IB4

    @Test func IB4_updateChangesModeEnabledAndPDFsOnly() throws {
        let f = try F()
        let url = try folder(f, "Watched")
        let other = try folder(f, "Elsewhere")
        let added = try f.service.addWatchFolder(url, now: now)
        let untouched = try f.service.addWatchFolder(try folder(f, "Second"), now: now)

        var changed = added
        changed.mode = .copy
        changed.isEnabled = false
        changed.includesPDFs = true
        changed.path = stored(other)
        changed.addedAt = now.addingTimeInterval(999)
        try f.service.updateWatchFolder(changed)

        var expected = added
        expected.mode = .copy
        expected.isEnabled = false
        expected.includesPDFs = true
        #expect(try f.service.watchFolders() == [expected, untouched])

        // And back again.
        try f.service.updateWatchFolder(added)
        #expect(try f.service.watchFolders() == [added, untouched])
    }

    @Test func IB4_updatingAnUnknownFolderThrowsAndChangesNothing() throws {
        let f = try F()
        let added = try f.service.addWatchFolder(try folder(f, "Watched"), now: now)
        var unknown = added
        unknown.id = 999
        unknown.mode = .copy

        #expect(throws: WatchFolderError.notFound(999)) { try f.service.updateWatchFolder(unknown) }

        #expect(try f.service.watchFolders() == [added])
    }

    // MARK: IB5

    @Test func IB5_removingAFolderDeletesItAndItsLedgerAndTouchesNoFile() throws {
        let f = try F()
        let doomed = try folderWithEveryState(f, "Doomed")
        let kept = try folderWithEveryState(f, "Kept")
        let onDisk = try touch(URL(fileURLWithPath: doomed.path).appendingPathComponent("old1.m4b"), "audio")
        #expect(try entries(f, doomed.id).count == 4)

        try f.service.removeWatchFolder(id: doomed.id)

        #expect(try f.service.watchFolders() == [kept])
        #expect(try entries(f, doomed.id).isEmpty)
        #expect(try entries(f, kept.id).count == 4)
        #expect(try entryCount(f) == 4)
        #expect(try read(onDisk) == "audio")
        #expect(tree(URL(fileURLWithPath: doomed.path)) == ["old1.m4b"])

        // Removing it again, or one that never was, does nothing.
        try f.service.removeWatchFolder(id: doomed.id)
        try f.service.removeWatchFolder(id: 999)
        #expect(try f.service.watchFolders() == [kept])
    }

    /// A folder removed and added again starts afresh.
    @Test func IB5_aFolderCanBeAddedAgainAfterItIsRemoved() throws {
        let f = try F()
        let first = try folderWithEveryState(f)
        try f.service.removeWatchFolder(id: first.id)

        let again = try f.service.addWatchFolder(URL(fileURLWithPath: first.path), now: now)

        #expect(again.path == first.path)
        #expect(try entries(f, again.id).isEmpty)
    }

    // MARK: IB6

    @Test func IB6_scanExistingDeletesThatFoldersBaselineOnly() throws {
        let f = try F()
        let scanned = try folderWithEveryState(f, "Scanned")
        let other = try folderWithEveryState(f, "Other")

        try f.service.scanExisting(inWatchFolder: scanned.id)

        let left = try entries(f, scanned.id)
        #expect(left.map(\.state) == [.dismissed, .imported])
        #expect(left.map(\.path) == [scanned.path + "/no.m4b", scanned.path + "/done.m4b"])
        #expect(try entries(f, other.id).map(\.state) == [.baseline, .baseline, .dismissed, .imported])
        #expect(try f.service.watchFolders() == [scanned, other])

        // Again, and for a folder that is not there: nothing more happens.
        try f.service.scanExisting(inWatchFolder: scanned.id)
        try f.service.scanExisting(inWatchFolder: 999)
        #expect(try entryCount(f) == 6)
    }

    // MARK: IB7

    @Test func IB7_aV7DatabaseOpensUnchangedAndHasNoWatchFolders() throws {
        let root = try makeTempDir()
        let path = root.appendingPathComponent(LibraryStore.databaseFileName).path
        let tables = ["book", "bookFile", "collection", "collectionBook", "operationBatch", "operationMove", "libraryNote"]
        func contents(_ db: Database) throws -> [String: [Row]] {
            var all: [String: [Row]] = [:]
            for table in tables {
                all[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map { $0.copy() }
            }
            return all
        }
        func schema(_ db: Database) throws -> [String] {
            try String.fetchAll(
                db, sql: "SELECT sql FROM sqlite_master WHERE tbl_name IN (\(tables.map { "'\($0)'" }.joined(separator: ","))) AND sql IS NOT NULL ORDER BY name")
        }
        var before: [String: [Row]] = [:]
        var schemaBefore: [String] = []
        do {
            let queue = try DatabaseQueue(path: path)
            try LibraryStore.migrator.migrate(queue, upTo: "v7")
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO book (title, authors, narrators, tags, rating, needsAttention, folderPath,
                                      durationSeconds, dateAdded, readStatus, appOnlyFields, externalCopies,
                                      editionKind, partsAppearMissing)
                    VALUES ('Old Book', '["Old Author"]', '[]', '["kept"]', 4, 0, 'Old Author/Old Book', 4368.5,
                            '2025-01-02 03:04:05.000', 'finished', '[]', '[]', NULL, 1);
                    INSERT INTO bookFile (bookId, path, format, role, position)
                    VALUES (1, 'Old Author/Old Book/Old Book.m4b', 'm4b', 'audio', 0);
                    INSERT INTO collection (name) VALUES ('To Read');
                    INSERT INTO collectionBook (collectionId, bookId) VALUES (1, 1);
                    INSERT INTO operationBatch (label, createdAt) VALUES ('Import 1 Book', '2025-01-02 03:04:05.000');
                    INSERT INTO operationMove (batchId, fromPath, toPath, wasCopy) VALUES (1, '/from', '/to', 0);
                    INSERT INTO libraryNote (key, value) VALUES ('k', 'v');
                    """)
                let hasFolders = try db.tableExists("watchFolder")
                let hasLedger = try db.tableExists("inboxEntry")
                #expect(!hasFolders && !hasLedger)
                before = try contents(db)
                schemaBefore = try schema(db)
            }
            try queue.close()
        }

        let store = try LibraryStore(libraryRoot: root)
        let service = LibraryService(store: store)

        #expect(try service.watchFolders().isEmpty)
        let after = try store.dbQueue.read { db in try contents(db) }
        let schemaAfter = try store.dbQueue.read { db in try schema(db) }
        #expect(after == before)
        #expect(schemaAfter == schemaBefore)
        #expect(try store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inboxEntry") } == 0)
        #expect(before.values.allSatisfy { $0.count == 1 })
        #expect(try store.books().map(\.title) == ["Old Book"])

        // The upgraded catalogue takes a watch folder.
        let watched = root.deletingLastPathComponent()
            .appendingPathComponent("watched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        let added = try service.addWatchFolder(watched, now: now)
        #expect(try service.watchFolders() == [added])
    }

    @Test func IB7_theLedgerHoldsOnlyTheThreeStatesAndOneEntryPerFile() throws {
        let f = try F()
        let added = try f.service.addWatchFolder(try folder(f, "Watched"), now: now)
        func insert(_ path: String, _ state: String, folder: Int64) throws {
            try f.store.dbQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO inboxEntry (folderId, path, size, modifiedAt, state) VALUES (?, ?, 1, 1.0, ?)",
                    arguments: [folder, path, state])
            }
        }
        try insert("/x/a.m4b", "dismissed", folder: added.id)
        #expect(throws: DatabaseError.self) { try insert("/x/a.m4b", "imported", folder: added.id) }
        #expect(throws: DatabaseError.self) { try insert("/x/b.m4b", "seen", folder: added.id) }
        #expect(throws: DatabaseError.self) { try insert("/x/c.m4b", "baseline", folder: 999) }
        #expect(throws: DatabaseError.self) {
            try f.store.dbQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO watchFolder (path, mode, isEnabled, includesPDFs, addedAt) VALUES (?, 'move', 1, 0, 0.0)",
                    arguments: [added.path])
            }
        }
        #expect(try entryCount(f) == 1)
    }

    // MARK: IB8

    @Test func IB8_noneOfItIsJournaledOrChangesWhatUndoWouldDo() throws {
        let f = try F()
        let book = try f.makeM4B("spy.m4b", tags: F.meta("A Perfect Spy", "John le Carré"))
        _ = try f.importNew([book], F.meta("A Perfect Spy", "John le Carré"))
        let label = try #require(try f.service.undoLabel())
        let batch = try #require(try f.store.lastBatch())
        let hidden = f.hiddenTree()
        func expectUntouched(sourceLocation: SourceLocation = #_sourceLocation) throws {
            #expect(try f.service.undoLabel() == label, sourceLocation: sourceLocation)
            #expect(try f.store.lastBatch() == batch, sourceLocation: sourceLocation)
            #expect(f.hiddenTree() == hidden, sourceLocation: sourceLocation)
        }

        var added = try folderWithEveryState(f)
        try expectUntouched()
        added.mode = .copy
        added.includesPDFs = true
        try f.service.updateWatchFolder(added)
        try expectUntouched()
        try f.service.scanExisting(inWatchFolder: added.id)
        try expectUntouched()
        _ = try? f.service.addWatchFolder(f.root, now: now)
        try expectUntouched()
        try f.service.removeWatchFolder(id: added.id)
        try expectUntouched()

        // And undo still does what it would have done.
        #expect(try f.service.undoLast() == label)
        #expect(f.inboxTree() == ["spy.m4b"])
    }

    /// With no operation recorded, none appears.
    @Test func IB8_withNothingToUndoThereIsStillNothing() throws {
        let f = try F()
        let added = try folderWithEveryState(f)
        try f.service.updateWatchFolder(added)
        try f.service.scanExisting(inWatchFolder: added.id)
        try f.service.removeWatchFolder(id: added.id)

        #expect(try f.service.undoLabel() == nil)
        #expect(try f.store.lastBatch() == nil)
    }
}
