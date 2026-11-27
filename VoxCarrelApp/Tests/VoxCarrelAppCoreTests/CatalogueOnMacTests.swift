import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// The catalogue kept on this Mac, in the app: moving it, the library with its drive
/// away, the drive coming back, and moving it back.
@MainActor
@Suite(.serialized) struct CatalogueOnMacTests {
    @Test func theCatalogueMovesTheDriveGoesAndComesBack() async throws {
        AppModel.awayPollNanoseconds = 50_000_000
        defer { AppModel.awayPollNanoseconds = 4_000_000_000 }
        let h = try await Harness.demo()
        let root = try #require(h.model.libraryFolder)
        let books = h.model.rows.count
        let flagged = h.model.sidebar.counts[.needsAttention] ?? 0
        let salt = try h.id("Salt Road")
        #expect(!h.model.catalogueIsOnMac && !h.model.libraryIsAway && h.model.canMoveCatalogue)
        #expect(h.model.catalogueStatusText == CatalogueText.inFolder)

        await h.model.moveCatalogue(toMac: true)
        await h.model.settle()
        #expect(h.model.alert == CatalogueText.moved && h.model.catalogueIsOnMac && h.model.isLibraryOpen)
        #expect(h.model.rows.count == books && h.model.catalogueStatusText == CatalogueText.onMac)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("VoxCarrel.sqlite").path))
        // A backup was made first.
        #expect(h.model.backups.contains { $0.text.hasSuffix("before move to mac") })
        h.model.alert = nil

        // The drive goes: the folder the books are in is no longer there.
        let parked = root.deletingLastPathComponent().appendingPathComponent("Unplugged-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: root, to: parked)
        await h.model.openLibrary()
        await h.model.settle()
        #expect(h.model.isLibraryOpen && h.model.libraryIsAway && h.model.rows.count == books)
        #expect(h.model.statusBar?.library.hasPrefix("Drive not connected · ") == true)
        #expect(h.model.catalogueStatusText == CatalogueText.away && !h.model.canMoveCatalogue)
        // No book is flagged for it, and its files are not called missing.
        #expect((h.model.sidebar.counts[.needsAttention] ?? 0) == flagged)
        h.model.click(salt, modifiers: [])
        await h.model.settle()
        #expect(h.detail?.row.book.title == "Salt Road")
        #expect(h.detail?.files.contains(where: \.isMissing) == false)
        // The check is not run, and what touches files says why it cannot.
        await h.model.checkLibraryNow()
        #expect(h.model.libraryCheck == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        h.model.select([])
        await h.model.settle()

        // The drive comes back: the library is opened afresh by itself.
        try FileManager.default.moveItem(at: parked, to: root)
        for _ in 0..<200 where h.model.libraryIsAway {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        await h.model.settle()
        #expect(!h.model.libraryIsAway && h.model.catalogueIsOnMac && h.model.rows.count == books)

        await h.model.moveCatalogue(toMac: false)
        await h.model.settle()
        #expect(h.model.alert == CatalogueText.movedBack && !h.model.catalogueIsOnMac && h.model.rows.count == books)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("VoxCarrel.sqlite").path))
    }
}
