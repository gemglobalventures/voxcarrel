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
}
