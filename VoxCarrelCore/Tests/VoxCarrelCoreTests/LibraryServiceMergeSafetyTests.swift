import Foundation
import GRDB
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// Merging entries: what is not the merge's own is never replaced, removed or lost.
@Suite struct LibraryServiceMergeSafetyTests {
    typealias F = LibraryFixture

    /// Every file under a folder, by its path there, with its bytes.
    private func contents(of folder: URL) throws -> [String: Data] {
        var found: [String: Data] = [:]
        let base = folder.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        else { return found }
        for case let url as URL in walker {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard !path.contains("/.voxcarrel/"), !path.hasPrefix(base + "/" + LibraryStore.databaseFileName)
            else { continue }
            found[String(path.dropFirst(base.count + 1))] = try Data(contentsOf: url)
        }
        return found
    }

    private func ebookAndNotes(_ f: F) throws -> (ebook: Int64, notes: Int64) {
        let ebook = try f.importNew([try f.makeEPUB("dune.epub")], F.meta("Dune", "Frank Herbert"))
        let notes = try f.importNew([try f.makePDF("notes.pdf")], F.meta("Dune Notes", "Frank Herbert"))
        return (ebook, notes)
    }

    private func undoData(_ f: F) -> [String] {
        f.hiddenTree().filter { $0.hasPrefix("undo/") }
    }

    // MARK: The page count

    @Test func thePageCountIsNotTakenFromAnEntryWhoseFileBecomesAnExtra() throws {
        let f = try F()
        let audio = try f.importNew(
            [try f.makeM4B("mom.m4b", tags: BookMetadata())], F.meta("Mind Over Markets", "James Dalton"))
        let companion = try f.importNew(
            [try f.makePDF("companion.pdf", pages: 2)], F.meta("Mind Over Markets [B09WXN61GL]", "James Dalton"))
        let text = try f.importNew([try f.makePDF("text.pdf", pages: 7)], F.meta("Mind Over Markets Text", "James Dalton"))
        #expect(try f.store.book(id: companion)?.pageCount == 2)

        // The companion is chosen before the book's own text.
        let plan = try f.service.planMerge(bookIds: [audio, companion, text], keep: audio)
        #expect(plan.files.map(\.role) == [.audio, .extra, .ebook])
        try f.service.mergeBooks([audio, companion, text], keep: audio, roles: [:])
        #expect(try f.store.book(id: audio)?.pageCount == 7)

        // With no ebook at all, an audiobook has no pages to count.
        let f2 = try F()
        let audio2 = try f2.importNew(
            [try f2.makeM4B("mom.m4b", tags: BookMetadata())], F.meta("Mind Over Markets", "James Dalton"))
        let companion2 = try f2.importNew(
            [try f2.makePDF("companion.pdf", pages: 2)], F.meta("Mind Over Markets [B09WXN61GL]", "James Dalton"))
        try f2.service.mergeBooks([audio2, companion2], keep: audio2, roles: [:])
        #expect(try f2.store.book(id: audio2)?.pageCount == nil)
    }

    // MARK: Files as they were

    @Test func aFilePutBackWholeIsNotWrittenIntoAgainWhereDatesCannotTellItFromTheWrittenOne() throws {
        let f = try F()
        let file = try f.makePDF("x/book.pdf")
        let details = F.meta("Dune", "Frank Herbert")
        try f.io.write(details, to: file)
        let asItWas = try f.bytes(file)
        let token = UUID().uuidString
        var original = try f.service.saveOriginal(of: file, token: token)
        // As a write leaves the file on a disk that keeps dates to the second: of the
        // same size, and with the date it had.
        try Data(repeating: 0x20, count: asItWas.count).write(to: file)
        original.before.setTime(ofFileAt: file)
        original.written = FileStamp(fileAt: file)
        #expect(original.written == original.before)
        var state = FileState(
            pathAfter: file.path, metadataBefore: details, part: nil, trackBefore: nil, coverBefore: nil)
        state.original = original

        try f.service.restoreFile(state, at: file.path, token: token)
        #expect(try f.bytes(file) == asItWas)

        // The undo is made again, as after a catalogue that could not be written: the
        // file is already the one that was kept.
        try f.service.restoreFile(state, at: file.path, token: token)
        #expect(try f.bytes(file) == asItWas)
    }
}
