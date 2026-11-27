import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// SW1–SW3: a better copy of a book takes the place of the audio the book has.
@Suite struct SwapAudioTests {
    final class Trash: @unchecked Sendable { var names: [String] = [] }

    /// A library holding one book in two MP3 parts, with a highlight and a status.
    private func made() throws -> (service: LibraryService, bookId: Int64, base: URL, trash: Trash) {
        let base = try makeTempDir()
        let inbox = base.appendingPathComponent("Inbox/The Long Road", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        for index in 1...2 {
            try MediaFixtures.makeSilentMP3(seconds: 2).write(to: inbox.appendingPathComponent("0\(index).mp3"))
        }
        let trash = Trash()
        let store = try LibraryStore(libraryRoot: base.appendingPathComponent("Library", isDirectory: true))
        let service = LibraryService(store: store, trashItem: { url in
            trash.names.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        })
        var candidate = try #require(service.scan([inbox]).candidates.first)
        candidate.metadata = BookMetadata(title: "The Long Road", authors: ["Ann Author"])
        candidate.metadata.series = "The Saga"
        guard case .imported(let id, _) = try #require(try service.importItems([ImportItem(candidate: candidate)]).outcomes.first)
        else { throw LibraryError.bookNotFound(0) }
        try service.addHighlight(text: "A line worth keeping.", note: nil, toBook: id)
        try service.setReadStatus(.inProgress, for: [id])
        return (service, id, base, trash)
    }

    private func better(_ base: URL, seconds: Double) throws -> URL {
        let file = base.appendingPathComponent("Better/The Long Road.m4b")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MediaFixtures.makeChapteredM4B(at: file, seconds: seconds, chapters: [(0, "One"), (seconds / 2, "Two")])
        return file
    }

    // SW1: the new audio takes the old audio's place; the book is the same entry, with
    // its highlights, series and status; the old files are in the Trash.
    @Test func SW1_aBetterCopyTakesTheOldAudiosPlace() throws {
        let m = try made()
        let file = try better(m.base, seconds: 4)
        let candidate = try #require(m.service.scan([file]).candidates.first)
        let result = try m.service.importItems([ImportItem(candidate: candidate, target: .replacingAudio(of: m.bookId))])
        guard case .imported(let id, _) = try #require(result.outcomes.first) else {
            Issue.record("not swapped: \(result.outcomes)")
            return
        }
        let count = try m.service.store.books().count
        #expect(id == m.bookId && count == 1)
        let files = try m.service.store.files(bookId: id)
        #expect(files.count == 1 && files[0].format == .m4b && files[0].role == .audio)
        // Named as the one file it is, not as a part.
        #expect(files[0].path == "Ann Author/The Saga/The Long Road/The Long Road.m4b")
        #expect(FileManager.default.fileExists(atPath: m.service.store.url(for: files[0]).path))
        #expect(m.trash.names.sorted().count == 2 && m.trash.names.allSatisfy { $0.hasSuffix(".mp3") })
        let book = try #require(try m.service.store.book(id: id))
        #expect(book.series == "The Saga" && book.readStatus == .inProgress && !book.needsAttention)
        #expect(try m.service.highlights(forBook: id).map(\.text) == ["A line worth keeping."])
        let left = try FileManager.default.contentsOfDirectory(atPath: m.service.store.url(forFolder: try #require(book.folderPath)).path)
        #expect(left.filter { $0.hasSuffix(".mp3") }.isEmpty)
        // The library is whole: its check finds nothing missing and nothing untracked.
        let report = try m.service.reconcile()
        #expect(report.booksWithMissingFiles.isEmpty && report.untrackedFiles.isEmpty)
    }

    // SW2: a copy much shorter than what the book has is not put in its place, and
    // nothing changes.
    @Test func SW2_aMuchShorterCopyIsRefused() throws {
        let m = try made()
        let file = try better(m.base, seconds: 1)
        let candidate = try #require(m.service.scan([file]).candidates.first)
        let result = try m.service.importItems([ImportItem(candidate: candidate, target: .replacingAudio(of: m.bookId))])
        guard case .failed(let reason) = try #require(result.outcomes.first) else {
            Issue.record("not refused: \(result.outcomes)")
            return
        }
        #expect(reason.contains("much shorter") && m.trash.names.isEmpty)
        #expect(try m.service.store.files(bookId: m.bookId).count == 2 && FileManager.default.fileExists(atPath: file.path))
    }

    // SW3: there must be audio on both sides.
    @Test func SW3_thereMustBeAudioToReplaceAndAudioToPutInItsPlace() throws {
        let m = try made()
        let file = try better(m.base, seconds: 4)
        let candidate = try #require(m.service.scan([file]).candidates.first)
        let gone = try m.service.importItems([ImportItem(candidate: candidate, target: .replacingAudio(of: 9_999))])
        guard case .failed(let reason) = try #require(gone.outcomes.first) else { return }
        #expect(reason.contains("no longer in the library") && m.trash.names.isEmpty)
    }
}
