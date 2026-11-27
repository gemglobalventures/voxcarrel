import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// CB1–CB5: dated copies of the catalogue, kept away from the library, and restoring one.
@Suite struct CatalogueBackupTests {
    typealias F = LibraryFixture

    private func add(_ f: F, _ title: String) throws -> Int64 {
        try #require(try f.store.insert(Book(metadata: BookMetadata(title: title, authors: ["Ines Calloway"])), files: []).id)
    }

    private func day(_ number: Int, hour: Int = 9) -> Date {
        Date(timeIntervalSince1970: 1_799_971_200 + Double(number) * 86_400 + Double(hour) * 3_600)
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // CB1: a backup is a whole catalogue, named for when it was made, and listed newest first.
    @Test func CB1_aBackupIsAWholeDatedCopy() throws {
        let f = try F()
        _ = try add(f, "One")
        let folder = try makeTempDir().appendingPathComponent("Backups/library")
        #expect(CatalogueBackups.list(in: folder).isEmpty)
        let first = try f.service.backUpCatalogue(to: folder, now: day(0))
        #expect(first.bookCount == 1 && first.bytes > 0 && first.reason == nil && first.date == day(0))
        #expect(first.url.lastPathComponent == "catalogue-" + CatalogueBackups.stamp(day(0)) + ".sqlite")
        _ = try add(f, "Two")
        let second = try f.service.backUpCatalogue(to: folder, now: day(1), reason: "Before layout!")
        #expect(second.bookCount == 2 && second.reason == "before layout")
        #expect(CatalogueBackups.list(in: folder).map(\.bookCount) == [2, 1])
        // Two in one second are two files.
        let again = try f.service.backUpCatalogue(to: folder, now: day(0))
        #expect(again.url != first.url && CatalogueBackups.list(in: folder).count == 3)
        // Nothing half made is left behind, and other files are not taken for backups.
        try Data("x".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(!names.contains { $0.hasPrefix(".making") } && CatalogueBackups.list(in: folder).count == 3)
        #expect(CatalogueBackups.parse(name: "catalogue-garbage.sqlite") == nil)
    }

    // CB2: one a day, and no more unless asked.
    @Test func CB2_oneADay() throws {
        let f = try F()
        let folder = try makeTempDir()
        #expect(try f.service.backUpCatalogueIfDue(to: folder, now: day(0), calendar: utc) != nil)
        #expect(try f.service.backUpCatalogueIfDue(to: folder, now: day(0, hour: 20), calendar: utc) == nil)
        // One made for a reason is not the day's own.
        try f.service.backUpCatalogue(to: folder, now: day(1, hour: 8), reason: "before restore")
        #expect(try f.service.backUpCatalogueIfDue(to: folder, now: day(1), calendar: utc) != nil)
        #expect(CatalogueBackups.list(in: folder).count == 3)
    }

    // CB3: the oldest go beyond those kept; those made for a reason are counted apart.
    @Test func CB3_theOldestGo() throws {
        let f = try F()
        let folder = try makeTempDir()
        try f.service.backUpCatalogue(to: folder, now: day(0), reason: "before restore")
        for number in 1...(CatalogueBackups.kept + 3) { try f.service.backUpCatalogue(to: folder, now: day(number)) }
        let left = CatalogueBackups.list(in: folder)
        #expect(left.filter { $0.reason == nil }.count == CatalogueBackups.kept && left.filter { $0.reason != nil }.count == 1)
        #expect(left.first?.date == day(CatalogueBackups.kept + 3) && left.filter { $0.reason == nil }.last?.date == day(4))
        #expect(CatalogueBackups.prune(in: folder, keeping: 2) == CatalogueBackups.kept - 2)
    }

    // CB4: a library has an id of its own, made once and kept, and a backup carries it.
    @Test func CB4_aLibraryHasAnIdOfItsOwn() throws {
        let f = try F()
        let id = try f.store.libraryId()
        let again = try f.store.libraryId()
        #expect(!id.isEmpty && again == id)
        #expect(try LibraryStore(libraryRoot: f.store.libraryRoot).libraryId() == id)
        let backup = try f.service.backUpCatalogue(to: try makeTempDir(), now: day(0))
        #expect(CatalogueBackups.libraryId(of: backup.url) == id)
        #expect(try F().store.libraryId() != id)
    }

    // CB5: a restore puts the catalogue back as it was, after keeping the one it
    // replaces; another library's backup and a file that is no catalogue are refused.
    @Test func CB5_restoringPutsTheCatalogueBack() throws {
        let base = try makeTempDir()
        let root = base.appendingPathComponent("Library", isDirectory: true)
        let folder = base.appendingPathComponent("Backups")
        var backup: CatalogueBackup
        do {
            let store = try LibraryStore(libraryRoot: root)
            _ = try store.insert(Book(metadata: BookMetadata(title: "Kept", authors: ["A"])), files: [])
            backup = try LibraryService(store: store).backUpCatalogue(to: folder, now: day(0))
            _ = try store.insert(Book(metadata: BookMetadata(title: "Added Later", authors: ["A"])), files: [])
            #expect(try store.books().count == 2)
        }
        try CatalogueBackups.restore(backup.url, toLibraryAt: root, backups: folder, now: day(2))
        let restored = try LibraryStore(libraryRoot: root)
        #expect(try restored.books().map(\.title) == ["Kept"])
        // The backup is still there, and so is the catalogue it replaced.
        let all = CatalogueBackups.list(in: folder)
        #expect(all.map(\.reason) == ["before restore", nil] && all.first?.bookCount == 2)
        // Taken back: restore the one kept before the restore.
        try CatalogueBackups.restore(try #require(all.first).url, toLibraryAt: root, backups: folder, now: day(3))
        #expect(try LibraryStore(libraryRoot: root).books().count == 2)

        let other = try F()
        let foreign = try other.service.backUpCatalogue(to: try makeTempDir(), now: day(0))
        #expect(throws: CatalogueBackupError.anotherLibrary) {
            try CatalogueBackups.restore(foreign.url, toLibraryAt: root, backups: folder, now: day(4))
        }
        let junk = base.appendingPathComponent("catalogue-20270101-000000.sqlite")
        try Data("not a catalogue".utf8).write(to: junk)
        #expect(throws: CatalogueBackupError.notACatalogue) {
            try CatalogueBackups.restore(junk, toLibraryAt: root, backups: folder, now: day(4))
        }
        #expect(try LibraryStore(libraryRoot: root).books().count == 2)
    }
}
