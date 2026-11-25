import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// RA1–RA5: one new file made a book's audio, in place of the files it had.
@Suite struct ReplaceAudioTests {
    typealias F = LibraryFixture

    /// A book of three MP3 parts and an ebook, imported; and a list that takes what is sent to the Trash.
    private func book(_ f: F, trashed: Trash) throws -> Int64 {
        let tags = F.meta("The Long Road", "Ann Author")
        let parts = try f.makeMP3Parts(folder: "road", tags: tags, count: 3, seconds: 2)
        let ebook = try f.makeEPUB("road/road.epub")
        let result = try f.service.importItems([ImportItem(candidate: f.candidate(parts + [ebook], tags))])
        f.service.trashItem = { url in
            trashed.urls.append(url)
            try FileManager.default.removeItem(at: url)
        }
        return try f.importedId(result.outcomes[0])
    }

    final class Trash: @unchecked Sendable { var urls: [URL] = [] }

    private func staged(_ f: F, seconds: Double = 6, name: String = "joined.m4b") throws -> URL {
        let url = f.base.appendingPathComponent(name)
        try MediaFixtures.makeAAC(at: url, seconds: seconds)
        return url
    }

    @Test func RA1_theNewFileBecomesTheBooksAudioWithItsDetailsAndThePartsGoToTheTrash() throws {
        let f = try F()
        let trash = Trash()
        let id = try book(f, trashed: trash)
        let before = try f.store.files(bookId: id)
        #expect(before.filter { $0.role == .audio }.count == 3 && before.count == 4)
        let partURLs = before.filter { $0.role == .audio }.map { f.store.url(for: $0) }
        let new = try staged(f)

        let done = try f.service.replaceAudio(ofBook: id, with: new)
        #expect(done.leftBehind.isEmpty && done.file.format == .m4b && done.file.role == .audio && done.file.position == 0)
        let after = try f.store.files(bookId: id)
        #expect(after.map(\.role) == [.audio, .ebook] && after.map(\.position) == [0, 1])
        #expect(after[1].path == before.first { $0.role == .ebook }?.path)
        let url = f.store.url(for: after[0])
        #expect(url.lastPathComponent == "The Long Road.m4b" && FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: new.path))
        // In the book's own folder, with the book's details inside.
        let book = try #require(try f.store.book(id: id))
        #expect(url.deletingLastPathComponent() == f.store.url(forFolder: try #require(book.folderPath)))
        let tags = try f.tags(url)
        #expect(tags.title == "The Long Road" && tags.authors == ["Ann Author"])
        #expect(abs((book.durationSeconds ?? 0) - 6) < 0.2 && after[0].contentPrint != nil)
        // The parts are in the Trash and nowhere else.
        #expect(Set(trash.urls) == Set(partURLs))
        #expect(partURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        // The library is whole: nothing missing, nothing stray.
        let report = try f.service.reconcile()
        #expect(report.booksWithMissingFiles.isEmpty && report.untrackedFiles.isEmpty)
        // What was recorded for undo spoke of files that are gone.
        #expect(try f.service.undoLabel() == nil)
    }

    @Test func RA2_aFileThatIsNotAnAudiobookOrIsTooShortChangesNothing() throws {
        let f = try F()
        let trash = Trash()
        let id = try book(f, trashed: trash)
        let before = try f.store.files(bookId: id)
        let bookBefore = try f.store.book(id: id)

        let missing = f.base.appendingPathComponent("nothing.m4b")
        #expect(throws: ReplaceAudioError.notAnAudiobook) { try f.service.replaceAudio(ofBook: id, with: missing) }
        let ebook = try f.makeEPUB("other.epub")
        #expect(throws: ReplaceAudioError.notAnAudiobook) { try f.service.replaceAudio(ofBook: id, with: ebook) }
        let empty = f.base.appendingPathComponent("empty.m4b")
        try Data("not sound".utf8).write(to: empty)
        #expect(throws: (any Error).self) { try f.service.replaceAudio(ofBook: id, with: empty) }
        // Half the length of what it would replace.
        let short = try staged(f, seconds: 3, name: "short.m4b")
        #expect(throws: ReplaceAudioError.self) { try f.service.replaceAudio(ofBook: id, with: short) }
        #expect(FileManager.default.fileExists(atPath: short.path))
        #expect(throws: LibraryError.self) { try f.service.replaceAudio(ofBook: 999, with: short) }

        #expect(try f.store.files(bookId: id) == before && f.store.book(id: id) == bookBefore && trash.urls.isEmpty)
        #expect(before.allSatisfy { FileManager.default.fileExists(atPath: f.store.url(for: $0).path) })
    }

    @Test func RA3_aBookWithNoAudioOfItsOwnHasNothingToReplace() throws {
        let f = try F()
        var owned = Book(metadata: BookMetadata(title: "Elsewhere", authors: ["A"]), folderPath: nil, needsAttention: false, dateAdded: Date())
        owned.externalCopies = [ExternalCopy(kind: .audible, form: .audio, itemId: "B0X")]
        let id = try #require(try f.store.insert(owned, files: []).id)
        let new = try staged(f)
        #expect(throws: ReplaceAudioError.nothingToReplace) { try f.service.replaceAudio(ofBook: id, with: new) }
        let ebook = try f.makeEPUB("only.epub")
        let result = try f.service.importItems([ImportItem(candidate: f.candidate([ebook], F.meta("Only Words", "A")))])
        let ebookId = try f.importedId(result.outcomes[0])
        #expect(throws: ReplaceAudioError.nothingToReplace) { try f.service.replaceAudio(ofBook: ebookId, with: new) }
        #expect(FileManager.default.fileExists(atPath: new.path))
    }

    @Test func RA4_aNameAlreadyTakenInTheFolderIsNotWrittenOver() throws {
        let f = try F()
        let trash = Trash()
        let id = try book(f, trashed: trash)
        let folder = f.store.url(forFolder: try #require(try f.store.book(id: id)?.folderPath))
        let squatter = folder.appendingPathComponent("the long road.M4B")
        try Data("mine".utf8).write(to: squatter)
        let done = try f.service.replaceAudio(ofBook: id, with: try staged(f))
        #expect(f.store.url(for: done.file).lastPathComponent == "The Long Road 2.m4b")
        #expect(try Data(contentsOf: squatter) == Data("mine".utf8))
    }

    @Test func RA5_aPartThatWillNotGoToTheTrashIsNamedAndACatalogueThatWillNotChangeLeavesAllAsItWas() throws {
        let f = try F()
        let trash = Trash()
        let id = try book(f, trashed: trash)
        let before = try f.store.files(bookId: id)
        struct Refused: Error {}
        // The catalogue refuses: the new file goes back, the parts stay the book's.
        f.service.beforeCommit = { throw Refused() }
        let new = try staged(f)
        #expect(throws: Refused.self) { try f.service.replaceAudio(ofBook: id, with: new) }
        #expect(try f.store.files(bookId: id) == before && trash.urls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: new.path))
        f.service.beforeCommit = nil
        // The Trash refuses one part: it is named, and the rest is done.
        let stubborn = f.store.url(for: before[1])
        f.service.trashItem = { url in
            if url == stubborn { throw Refused() }
            try FileManager.default.removeItem(at: url)
        }
        let done = try f.service.replaceAudio(ofBook: id, with: new)
        #expect(done.leftBehind == [stubborn] && FileManager.default.fileExists(atPath: stubborn.path))
        #expect(try f.store.files(bookId: id).map(\.role) == [.audio, .ebook])
    }
}
