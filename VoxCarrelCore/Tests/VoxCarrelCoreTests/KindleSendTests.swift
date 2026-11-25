import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// KS1–KS2: which of a book's files is sent to a Kindle, and the copy that is made of it.
@Suite struct KindleSendTests {
    typealias F = LibraryFixture

    /// A file of this name in the inbox, holding a few bytes that say what it is.
    private func loose(_ f: F, _ name: String) throws -> URL {
        let url = f.inbox.appendingPathComponent(name)
        try Data("the contents of \(name)".utf8).write(to: url)
        return url
    }

    /// The names of everything under the folder the copies are made in.
    private func staged(in root: URL) -> [String] {
        tree(root.appendingPathComponent(LibraryService.kindleStagingFolderName))
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .filter { UUID(uuidString: $0) == nil }
    }

    // MARK: KS1 What is sent

    @Test func KS1_theEPUBIsChosenBeforeThePDFWhateverTheirOrder() throws {
        let f = try F()
        let id = try f.importNew([try f.makePDF("road.pdf"), try f.makeEPUB("road.epub")], F.meta("The Long Road", "Ann Author"))
        let files = try f.store.files(bookId: id)
        #expect(files.map(\.format) == [.pdf, .epub])
        #expect(try f.service.kindleChoice(ofBook: id) == .file(files[1]))
    }

    @Test func KS1_aBookWithOnlyAPDFSendsThePDF() throws {
        let f = try F()
        let id = try f.importNew([try f.makePDF("road.pdf")], F.meta("The Long Road", "Ann Author"))
        let files = try f.store.files(bookId: id)
        #expect(try f.service.kindleChoice(ofBook: id) == .file(files[0]))
    }

    @Test func KS1_aPDFThatIsAnExtraIsNotTheBook() throws {
        let f = try F()
        let audio = try f.makeM4B("road.m4b", tags: F.meta("The Long Road", "Ann Author"))
        let extra = try f.makePDF("map.pdf")
        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([audio, extra], F.meta("The Long Road", "Ann Author"), roles: [extra: .extra])),
        ])
        let id = try f.importedId(result.outcomes[0])
        #expect(try f.service.kindleChoice(ofBook: id) == .nothing)
    }

    @Test func KS1_aBookWithOnlyAMOBIIsToBeConvertedFirst() throws {
        let f = try F()
        let id = try f.importNew([try loose(f, "road.mobi")], F.meta("The Long Road", "Ann Author"))
        let files = try f.store.files(bookId: id)
        #expect(try f.service.kindleChoice(ofBook: id) == .convertFirst(files[0]))
    }

    @Test func KS1_anAudiobookHasNothingToSend() throws {
        let f = try F()
        let meta = F.meta("The Long Road", "Ann Author")
        let id = try f.importNew([try f.makeM4B("road.m4b", tags: meta)], meta)
        #expect(try f.service.kindleChoice(ofBook: id) == .nothing)
    }

    @Test func KS1_aBookOwnedElsewhereHasNothingToSend() throws {
        let f = try F()
        let outcome = try f.service.addExternalBook(
            metadata: F.meta("The Glass Tide", "Ines Calloway"), cover: nil,
            copy: ExternalCopy(kind: .kindle, form: .ebook, itemId: "B00KINDLE2"))
        guard case .added(let id) = outcome else {
            Issue.record("expected .added, got \(outcome)")
            return
        }
        #expect(try f.service.kindleChoice(ofBook: id) == .nothing)
    }

    @Test func KS1_aFileThatIsNotOnDiskIsPassedOver() throws {
        let f = try F()
        let id = try f.importNew([try f.makeEPUB("road.epub"), try f.makePDF("road.pdf")], F.meta("The Long Road", "Ann Author"))
        let files = try f.store.files(bookId: id)
        #expect(files.map(\.format) == [.epub, .pdf])
        // Without its EPUB on disk the PDF is what there is to send.
        try FileManager.default.removeItem(at: f.store.url(for: files[0]))
        #expect(try f.service.kindleChoice(ofBook: id) == .file(files[1]))
        // Without either there is nothing.
        try FileManager.default.removeItem(at: f.store.url(for: files[1]))
        #expect(try f.service.kindleChoice(ofBook: id) == .nothing)
    }

    @Test func KS1_anIdThatIsNoBooksIsRefused() throws {
        let f = try F()
        #expect(throws: LibraryError.self) { try f.service.kindleChoice(ofBook: 987_654) }
    }

    // MARK: KS2 The copy

    @Test func KS2_theCopyHasTheFilesBytesAndTheBooksTitleAndTheOriginalIsAsItWas() throws {
        let f = try F()
        let id = try f.importNew([try f.makeEPUB("road.epub")], F.meta("The Long Road", "Ann Author"))
        let file = try f.store.files(bookId: id)[0]
        let original = f.store.url(for: file)
        let bytes = try Data(contentsOf: original)
        let libraryBefore = f.libraryTree()
        let root = try makeTempDir()

        let copy = try f.service.stageForKindle(file, title: "Dune: Messiah / Part 1", under: root)

        #expect(copy.lastPathComponent == "Dune- Messiah - Part 1.epub")
        #expect(try Data(contentsOf: copy) == bytes)
        // In a folder of its own, in VoxCarrel's folder, in the temporary folder given.
        let parent = copy.deletingLastPathComponent().deletingLastPathComponent()
        #expect(parent.standardizedFileURL.path
            == root.appendingPathComponent(LibraryService.kindleStagingFolderName).standardizedFileURL.path)
        #expect(f.service.layout.relativeComponents(of: copy) == nil)
        // The library is as it was.
        #expect(try Data(contentsOf: original) == bytes && f.libraryTree() == libraryBefore)
        #expect(try f.store.files(bookId: id) == [file])
    }

    @Test func KS2_aSecondCopyRemovesTheFirst() throws {
        let f = try F()
        let id = try f.importNew([try f.makeEPUB("road.epub"), try f.makePDF("road.pdf")], F.meta("The Long Road", "Ann Author"))
        let files = try f.store.files(bookId: id)
        let root = try makeTempDir()

        let first = try f.service.stageForKindle(files[0], title: "The Long Road", under: root)
        #expect(staged(in: root) == ["The Long Road.epub"])
        let second = try f.service.stageForKindle(files[1], title: "Another Title", under: root)

        #expect(!exists(first) && !exists(first.deletingLastPathComponent()))
        #expect(exists(second) && staged(in: root) == ["Another Title.pdf"])
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent(LibraryService.kindleStagingFolderName).path).count == 1)
    }

    @Test func KS2_aTitleThatLeavesNoNameStillMakesAFile() throws {
        let f = try F()
        let id = try f.importNew([try f.makePDF("road.pdf")], F.meta("The Long Road", "Ann Author"))
        let file = try f.store.files(bookId: id)[0]
        let copy = try f.service.stageForKindle(file, title: " .. ", under: try makeTempDir())
        #expect(copy.lastPathComponent == "Book.pdf" && exists(copy))
    }

    @Test func KS2_aLinkWhereTheFolderOfCopiesGoesIsNotFollowed() throws {
        let f = try F()
        let id = try f.importNew([try f.makeEPUB("road.epub")], F.meta("The Long Road", "Ann Author"))
        let file = try f.store.files(bookId: id)[0]
        let root = try makeTempDir()
        let elsewhere = try makeTempDir()
        try touch(elsewhere.appendingPathComponent("keep.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(LibraryService.kindleStagingFolderName), withDestinationURL: elsewhere)

        #expect(throws: KindleSendError.stagingFolderIsNotOurs) {
            try f.service.stageForKindle(file, title: "The Long Road", under: root)
        }
        #expect(tree(elsewhere) == ["keep.txt"])
    }

    @Test func KS2_aFileThatHasGoneIsRefusedAndNothingIsLeft() throws {
        let f = try F()
        let id = try f.importNew([try f.makeEPUB("road.epub")], F.meta("The Long Road", "Ann Author"))
        let file = try f.store.files(bookId: id)[0]
        try FileManager.default.removeItem(at: f.store.url(for: file))
        let root = try makeTempDir()
        #expect(throws: KindleSendError.notARegularFile("The Long Road.epub")) {
            try f.service.stageForKindle(file, title: "The Long Road", under: root)
        }
        #expect(tree(root).isEmpty)
    }
}
