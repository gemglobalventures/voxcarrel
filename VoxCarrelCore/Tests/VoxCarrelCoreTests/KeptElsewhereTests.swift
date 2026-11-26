import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// KE1–KE5: library files kept elsewhere (in iCloud, say) and not on this Mac are not
/// missing, and nothing done behind the owner's back opens them.
@Suite struct KeptElsewhereTests {
    typealias F = LibraryFixture

    /// The paths the service has been told are kept elsewhere.
    final class Away: @unchecked Sendable {
        var paths = Set<String>()
    }

    private func away(_ f: F) -> Away {
        let away = Away()
        f.service.isKeptElsewhere = { away.paths.contains($0.path) }
        return away
    }

    private func mixedBook(_ f: F) throws -> Int64 {
        let tags = F.meta("Mixed Book", "An Author")
        let urls = try f.makeBuiltMP3s(
            folder: "Mixed", tags: tags, parts: [.init(), .init(), .wrongHeader()])
        return try f.importNew(urls, tags)
    }

    // KE1: the launch check does not open the audio of a book that has a file kept
    // elsewhere, does not flag it as missing, and says how many books wait. It looks
    // again once the files are here.
    @Test func KE1_theLaunchCheckLeavesBooksKeptElsewhereAlone() throws {
        let f = try F()
        let id = try mixedBook(f)
        let files = try f.store.files(bookId: id).map { f.store.url(for: $0) }
        // As a version that knew nothing of length headers recorded it.
        let ids = try f.store.files(bookId: id).compactMap(\.id)
        try f.store.setMeasuredLength(
            bookId: id, durationSeconds: 1, lengthProblems: Dictionary(uniqueKeysWithValues: ids.map { ($0, nil) }))
        try f.store.dbQueue.write { db in try db.execute(sql: "DELETE FROM libraryNote") }

        let away = away(f)
        away.paths = [files[0].path]
        var opened = 0
        var headers = 0
        f.service.willMeasure = { _ in opened += 1 }
        f.service.didReadHeader = { _, _ in headers += 1 }
        let report = try f.service.reconcile()
        #expect(opened == 0 && headers == 0)
        #expect(report.booksKeptElsewhere == 1 && report.booksWithMissingFiles.isEmpty)
        #expect(report.correctedLengths == 0 && report.filesWithWrongLength == 0)
        #expect(try f.store.book(id: id)?.needsAttention == false)
        // The library is not noted as looked over, so the book is looked at later.
        #expect(try f.store.note(LibraryService.lengthHeadersNote) == nil)

        away.paths = []
        let later = try f.service.reconcile()
        #expect(later.booksKeptElsewhere == 0 && later.filesWithWrongLength == 1 && later.correctedLengths == 1)
        #expect(try f.store.note(LibraryService.lengthHeadersNote) != nil)
    }

    // KE2: an EPUB kept elsewhere is not counted, and does not hold up the others.
    @Test func KE2_wordsAreNotCountedFromAFileKeptElsewhere() throws {
        let f = try F()
        let one = try f.importNew([try f.makeEPUB("one.epub")], F.meta("One", "Ann Author"))
        let two = try f.importNew([try f.makeEPUB("two.epub")], F.meta("Two", "Ann Author"))
        let away = away(f)
        away.paths = [f.store.url(for: try #require(try f.store.files(bookId: one).first)).path]
        #expect(try f.service.countWords() == 1)
        #expect(try f.store.book(id: one)?.wordCount == nil && f.store.book(id: two)?.wordCount != nil)
        #expect(try f.service.countWords() == 0)
    }

    // KE3: a content print is not worked out from a file kept elsewhere.
    @Test func KE3_noContentPrintIsTakenFromAFileKeptElsewhere() throws {
        let f = try F()
        let id = try f.importNew([try f.makeEPUB("one.epub")], F.meta("One", "Ann Author"))
        let file = try #require(try f.store.files(bookId: id).first)
        try f.store.dbQueue.write { db in try db.execute(sql: "UPDATE bookFile SET contentPrint = NULL") }
        let away = away(f)
        away.paths = [f.store.url(for: file).path]
        #expect(try f.service.fillInContentPrints() == 0)
        away.paths = []
        #expect(try f.service.fillInContentPrints() == 1)
    }

    // KE4: a file on this Mac's own disk is not kept elsewhere; nor is one that is not there.
    @Test func KE4_anOrdinaryFileIsOnThisMac() throws {
        let f = try F()
        let url = try f.makeEPUB("plain.epub")
        #expect(!BookScanner.isKeptElsewhere(url) && BookScanner.isOnThisMac(url))
        #expect(!BookScanner.isKeptElsewhere(f.base.appendingPathComponent("no such file.epub")))
    }
}
