import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// Backups of the catalogue in the app: one as the library opens, one when asked, and
/// a restore that puts the catalogue back and opens the library again.
@MainActor
@Suite struct BackupsTests {
    @Test func aTestNeverGetsTheAppsOwnFolder() {
        // Read before anything sets it: the default itself is a temporary folder here.
        let own = FileAudibleKeyStore.standardURL.deletingLastPathComponent().path
        #expect(!AppModel.backupsFolderByDefault.path.hasPrefix(own))
        #expect(!TestBackups.folder.path.hasPrefix(own))
    }

    @Test func theLibraryIsBackedUpAsItOpensAndRestored() async throws {
        let h = try await Harness.demo()
        // Never in the app's own folder while testing.
        #expect(h.model.backupsFolder == TestBackups.folder)
        #expect(h.model.keepsBackups && h.model.backups.count == 1)
        let first = try #require(h.model.backups.first)
        let books = h.model.rows.count
        #expect(first.text.contains("\(books) books") && h.model.backupStatusText == "Last backup: \(first.text)")

        // A second the same day only when asked.
        await h.model.backUpIfDue()
        #expect(h.model.backups.count == 1)
        await h.model.backUpNow()
        #expect(h.model.alert == nil && h.model.backups.count == 2)

        // Something changes; then the catalogue goes back to the first backup.
        let id = try h.id("Salt Road")
        do {
            var book = try h.book(id)
            book.title = "Changed Since"
            try h.store().update(book)
        }
        await h.model.reloadAll()
        await h.model.settle()
        #expect(h.model.rows.contains { $0.book.title == "Changed Since" })
        h.model.select([])
        #expect(h.model.canRestoreBackup)
        await h.model.restoreBackup(first.id)
        await h.model.settle()
        #expect(h.model.isLibraryOpen && h.model.rows.count == books)
        #expect(h.model.rows.contains { $0.book.title == "Salt Road" })
        #expect(h.model.alert?.hasPrefix("The catalogue is as it was at the backup of ") == true)
        // The catalogue that was replaced is kept, so the restore can be taken back.
        #expect(h.model.backups.contains { $0.text.hasSuffix("before restore") })

        // A backup that is not there restores nothing.
        h.model.alert = nil
        await h.model.restoreBackup("catalogue-19990101-000000.sqlite")
        #expect(h.model.alert == nil && h.model.rows.count == books)
    }
}
