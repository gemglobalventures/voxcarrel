import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// A book imported as another edition of one already in the library.
@MainActor
@Suite struct EditionImportTests {
    @Test func theReviewOffersAnotherEditionAndFilesItApart() async throws {
        let h = try await Harness.demo()
        let salt = try h.id("Salt Road")
        let saltFolder = try #require(try h.book(salt).folderPath)
        let before = h.model.rows.count
        let downloads = try makeTempDir().appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let epub = try MediaFixtures.makeEPUB3(in: downloads, name: "salzstrasse.epub")

        await h.model.beginImport([epub])
        let id = try #require(h.model.review?.entries.first?.id)
        h.model.updateReview { $0.setText("Salt Road", for: .title, of: id) }
        h.model.updateReview { $0.setText("Ines Calloway", for: .authors, of: id) }
        h.model.updateReview { $0.setText("Another Reader", for: .narrators, of: id) }
        await h.model.settle()
        var entry = try #require(h.model.review?.entry(id))
        #expect(entry.existingMatch?.id == salt)

        // Not added to that book, but kept as another edition of it.
        h.model.updateReview { $0.setAddToExisting(false, for: id) }
        entry = try #require(h.model.review?.entry(id))
        #expect(entry.offersEdition && !entry.isImportedAsEdition)
        h.model.updateReview { $0.setAsEdition(true, for: id) }
        entry = try #require(h.model.review?.entry(id))
        #expect(entry.isImportedAsEdition)
        #expect(h.model.review?.destinationText(of: id).hasPrefix("Will be a book of its own, linked to “Salt Road”") == true)
        #expect(h.model.review?.items().first?.target == .edition(of: salt))
        #expect(h.model.review?.canImport == true)

        await h.model.confirmImport()
        #expect(h.model.alert == nil)
        await h.model.settle()
        #expect(h.model.rows.count == before + 1)
        let store = try h.store()
        let editions = try store.books().filter { $0.title == "Salt Road" }
        #expect(editions.count == 2 && Set(editions.compactMap(\.workKey)).count == 1)
        let german = try #require(editions.first { $0.id != salt })
        // Its folder says what sets it apart from the first.
        #expect(german.folderPath?.contains("Salt Road (") == true && german.editionSuffix != nil)
        // The first edition's folder now says what sets it apart too, or is as it was
        // when nothing about it does.
        let first = try h.book(salt)
        #expect(first.folderPath != german.folderPath)
        #expect(first.folderPath != saltFolder && first.folderPath?.contains("Salt Road (read by ") == true)
        #expect(try store.files(bookId: try #require(german.id)).allSatisfy {
            FileManager.default.fileExists(atPath: store.url(for: $0).path)
        })
    }
}
