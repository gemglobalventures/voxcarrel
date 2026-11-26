import CoreGraphics
import Foundation
import ImageIO
import Testing
import VoxCarrelCore
@testable import VoxCarrelAppCore

/// MC1–MC4: the cover made for a book that has none, saved as the book's own.
@MainActor @Suite struct MadeCoverTests {
    // MC1: the picture is a JPEG of a paperback's shape, and the same book gives the
    // same one; a book with no title gives none.
    @Test func MC1_thePictureIsAJPEGOfAPaperbacksShape() throws {
        let wording = PlaceholderCover.Wording(title: "Salt Road", author: "Ines Calloway")
        let image = try #require(MadeCover.image(wording: wording, hue: 0.3))
        #expect(image.mime == "image/jpeg" && CoverImage.sniffedMIME(image.data) == "image/jpeg")
        let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
        let picture = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(picture.width == 1000 && picture.height == 1500)
        #expect(MadeCover.image(wording: wording, hue: 0.3) == image)
        // Another colour is another picture; so are other words.
        #expect(MadeCover.image(wording: wording, hue: 0.8) != image)
        #expect(MadeCover.image(wording: .init(title: "Quiet Rivers", author: ""), hue: 0.3) != image)
        #expect(MadeCover.image(wording: .init(title: "", author: "Ines Calloway"), hue: 0.3) == nil)
        // A very long title still fits a picture of the same size.
        let long = PlaceholderCover.wording(title: Array(repeating: "meadowlands", count: 40).joined(separator: " "), authors: ["A", "B", "C"])
        let crowded = try #require(MadeCover.image(wording: long, hue: 0.1))
        #expect(crowded.data.count > 10_000)
    }

    // MC2: the colours are those the app draws with.
    @Test func MC2_coloursFollowTheHue() {
        let red = MadeCover.rgb(hue: 0, saturation: 1, brightness: 1)
        #expect(red.r == 1 && red.g == 0 && red.b == 0)
        let green = MadeCover.rgb(hue: 1.0 / 3, saturation: 1, brightness: 1)
        #expect(abs(green.g - 1) < 0.001 && green.r < 0.001 && green.b < 0.001)
        let grey = MadeCover.rgb(hue: 0.6, saturation: 0, brightness: 0.5)
        #expect(grey.r == 0.5 && grey.g == 0.5 && grey.b == 0.5)
        // A hue of one whole turn is the hue it began at.
        #expect(MadeCover.rgb(hue: 1, saturation: 1, brightness: 1).r == 1)
    }

    // MC3: saving it gives the book a cover, in its file and in the library, and Undo
    // takes it back. A book that has a cover is not offered and not touched.
    @Test func MC3_savingMakesItTheBooksCoverAndUndoTakesItBack() async throws {
        let h = try await Harness.demo()
        // One of the demo's books loses its cover first.
        let stripped = try #require(h.model.rows.first { $0.coverURL != nil && $0.hasFiles })
        let worker = try #require(h.model.worker)
        _ = try await worker.save([BookEdit(book: stripped.book, cover: .remove)])
        await h.model.reloadAll()
        let bare = try #require(h.model.rows.first { $0.id == stripped.id })
        #expect(bare.coverURL == nil)
        let covered = try #require(h.model.rows.first { $0.coverURL != nil })
        #expect(bare.canKeepMadeCover && !covered.canKeepMadeCover)
        #expect(h.model.commands(for: [bare.id]).keepMadeCover)
        #expect(!h.model.commands(for: [covered.id]).keepMadeCover)
        let coveredBefore = try #require(covered.coverURL.flatMap { try? Data(contentsOf: $0) })

        await h.model.keepMadeCovers(for: [bare.id, covered.id])
        let now = try #require(h.model.rows.first { $0.id == bare.id })
        let stored = try Data(contentsOf: try #require(now.coverURL))
        #expect(stored == MadeCover.image(wording: bare.madeCoverWording, hue: bare.placeholderHue)?.data)
        #expect(!now.canKeepMadeCover && !h.model.commands(for: [bare.id]).keepMadeCover)
        #expect(try Data(contentsOf: try #require(h.model.rows.first { $0.id == covered.id }?.coverURL)) == coveredBefore)

        await h.model.undo()
        #expect(h.model.rows.first { $0.id == bare.id }?.coverURL == nil)
    }

    // MC4: what is said afterwards.
    @Test func MC4_whatIsSaid() {
        #expect(MadeCover.result(saved: 0, appOnly: 0, failed: []) == nil)
        #expect(MadeCover.result(saved: 1, appOnly: 0, failed: []) == "The made cover is now the book's cover.")
        #expect(MadeCover.result(saved: 1, appOnly: 1, failed: [])
            == "The made cover is now the book's cover. Its files cannot all hold a cover, so it is kept in VoxCarrel as well.")
        #expect(MadeCover.result(saved: 3, appOnly: 2, failed: [("Salt Road", "the file is locked")])
            == "The made covers are now the covers of 3 books. The files of 2 books cannot all hold a cover, so theirs are kept in VoxCarrel as well. Not saved: “Salt Road” (the file is locked).")
        #expect(MadeCover.busy(count: 1) == "Saving the made cover…" && MadeCover.busy(count: 4) == "Saving 4 made covers…")
    }
}
