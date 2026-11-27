import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// The ebook and the companion PDFs sent with an audiobook through AirDrop and Share.
@MainActor
@Suite struct SendCompanionsTests {
    @Test func theEbookGoesWithTheAudiobookWhenAskedFor() async throws {
        let h = try await Harness.demo()
        // A demo book that is both an audiobook and an ebook on this Mac.
        let row = try #require(h.model.rows.first { $0.hasFiles && $0.formats.contains(.epub) && $0.formats.contains { $0 != .epub && $0 != .pdf } })
        let files = try h.fileURLs(row.id)
        let ebook = try #require(files.first { $0.pathExtension.lowercased() == "epub" })
        h.model.sendSquareCover = false
        await h.model.beginSendToPhone(for: [row.id])
        await h.model.settle()
        var sheet = try #require(h.model.sendSheet)
        #expect(sheet.ebookOffer?.hasPrefix("Also send the ebook (EPUB, ") == true && !sheet.alsoEbook)
        #expect(sheet.pdfOffer == nil)

        // Not asked for: the audiobook alone, as ever.
        var items = await h.model.shareItems()
        #expect(items.count == 1 && items[0].pathExtension.lowercased() != "epub")
        await h.model.shareFinished(completed: false, items: items)

        h.model.setSendAlso(ebook: true)
        sheet = try #require(h.model.sendSheet)
        #expect(sheet.alsoEbook)
        items = await h.model.shareItems()
        #expect(items.count == 2)
        #expect(items[1].resolvingSymlinksInPath() == ebook.resolvingSymlinksInPath())
        // The share is still recorded, by its audiobook.
        await h.model.shareFinished(completed: true, items: items)
        #expect(try h.sent(row.id).count == 1 && h.model.sendSheet?.shareNote == "Shared.")
        // The ebook is the library's own file, and is where it was.
        #expect(FileManager.default.fileExists(atPath: ebook.path))
    }

    @Test func theOfferSaysWhatAndHowMuch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("send-offer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let one = folder.appendingPathComponent("Maps.pdf"), two = folder.appendingPathComponent("Charts.pdf")
        try Data(count: 2_000_000).write(to: one)
        try Data(count: 1_000_000).write(to: two)
        #expect(SendText.alsoOffer("companion PDF", files: []) == nil)
        #expect(SendText.alsoOffer("companion PDF", files: [one]) == "Also send the companion PDF (2 MB)")
        #expect(SendText.alsoOffer("companion PDF", files: [one, two]) == "Also send the companion PDFs (2 files, 3 MB)")
        let book = folder.appendingPathComponent("Book.epub")
        try Data(count: 1_500_000).write(to: book)
        #expect(SendText.alsoOffer("ebook", files: [book]) == "Also send the ebook (EPUB, 2 MB)")
    }
}
