import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// A better copy offered as a swap in the import review.
@MainActor
@Suite struct SwapAudioAppTests {
    @Test func theTwoCopiesAreDescribedSideBySide() {
        #expect(AudioCopyText.text(formats: [], urls: [], seconds: 10) == nil)
        #expect(AudioCopyText.text(formats: [.mp3, .mp3, .mp3], urls: [], seconds: nil) == "MP3, 3 files")
        #expect(AudioCopyText.text(formats: [.m4b], urls: [], seconds: 3600) == "M4B, 1 file")
    }

    @Test func aBetterCopyIsOfferedInPlaceOfTheAudioABookHas() async throws {
        let h = try await Harness.demo()
        // A demo audiobook, and another copy of it arriving as one M4B.
        let row = try #require(h.model.rows.first { $0.hasAudio && $0.hasFiles && $0.book.title == "Salt Road" })
        let inbox = try Harness.inbox()
        let file = inbox.appendingPathComponent("Better/Salt Road.m4b")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let seconds = max(4, (row.book.durationSeconds ?? 4) + 1)
        try MediaFixtures.makeChapteredM4B(at: file, seconds: seconds, chapters: [(0, "One")])
        let tagged = BookMetadata(title: row.book.title, authors: row.book.authors)
        _ = try FileMetadataIO().write(tagged, cover: .keep, to: file)

        await h.model.beginImport([file])
        await h.model.settle()
        var review = try #require(h.model.review)
        var entry = try #require(review.entries.first)
        #expect(entry.existingMatch?.id == row.id)
        if !entry.addToExisting { h.model.updateReview { $0.setAddToExisting(true, for: entry.id) } }
        review = try #require(h.model.review)
        entry = try #require(review.entries.first)
        #expect(entry.offersReplaceAudio && !entry.replacesAudio)
        // Left off, it is added beside what the book has, as ever.
        if case .existing(let id) = try #require(review.items().first).target { #expect(id == row.id) } else { Issue.record("not added") }
        let off = try #require(review.replaceAudioText(of: entry.id))
        #expect(off.contains("It has: ") && off.contains("This copy: M4B, 1 file") && off.contains("beside the audio it has"))

        h.model.updateReview { $0.setReplacesAudio(true, for: entry.id) }
        review = try #require(h.model.review)
        #expect(try #require(review.items().first).target == .replacingAudio(of: row.id))
        #expect(review.replaceAudioText(of: entry.id)?.contains("goes to the Trash once this copy is in") == true)

        await h.model.confirmImport()
        await h.model.settle()
        let after = try #require(h.model.rows.first { $0.id == row.id })
        #expect(after.formats == [.m4b] || after.formats.filter { $0 == .m4b }.count == 1)
        #expect(h.model.rows.filter { $0.book.title == "Salt Road" }.count == 1)
        #expect(after.book.series == row.book.series && after.book.readStatus == row.book.readStatus)
    }
}
