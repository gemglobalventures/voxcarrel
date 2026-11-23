import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// Writing a PDF's tags leaves nothing in the system's temporary folder. It matters
/// when the library is on another disk than that folder: run these with
/// `VOXCARREL_TEST_TMP` naming a folder on another volume to see it there.
@Suite(.serialized) struct PDFTemporaryFilesTests {
    typealias F = LibraryFixture

    /// What is in the temporary folder itself that a PDF write could have left: a PDF,
    /// or anything named as a working copy of one of VoxCarrel's is.
    private func leftovers() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { name in
            !name.hasPrefix(TemporaryRunFolder.prefix)
                && (name.lowercased().hasSuffix(".pdf") || name.contains(".voxcarrel-"))
        })
    }

    @Test func writingAPDFsTagsLeavesNothingInTheTemporaryFolder() throws {
        let folder = try makeTempDir()
        let file = folder.appendingPathComponent("book.pdf")
        MediaFixtures.makePDF(at: file, pages: 3)
        let before = leftovers()

        try FileMetadataIO().write(BookMetadata(title: "Dune", authors: ["Frank Herbert"]), to: file)

        #expect(try FileMetadataIO().read(file).metadata.title == "Dune")
        #expect(leftovers().subtracting(before).isEmpty)
        // Nor beside the file.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["book.pdf"])
    }

    @Test func anImportAndAMergeThatTagPDFsLeaveNothingInTheTemporaryFolder() throws {
        let f = try F()
        let before = leftovers()

        // The import writes each PDF's reviewed details into it.
        let kept = try f.importNew([try f.makePDF("dune.pdf")], F.meta("Dune", "Frank Herbert"))
        let other = try f.importNew([try f.makeEPUB("notes.epub")], F.fullMeta("Dune Notes", "Frank Herbert"))
        let third = try f.importNew([try f.makePDF("scan.pdf", pages: 5)], F.meta("Dune Scan", "Frank Herbert"))
        #expect(try f.tags(f.lib("Frank Herbert/Dune/Dune.pdf")).title == "Dune")
        #expect(leftovers().subtracting(before).isEmpty)

        // The merge writes the kept book's details into the PDF that comes in, and
        // into its own; undo puts both back.
        try f.service.mergeBooks([kept, other, third], keep: kept, roles: [try #require(try f.store.files(bookId: third)[0].id): .ebook])
        let rows = try f.store.files(bookId: kept)
        #expect(rows.filter { $0.format == .pdf && $0.writeProblem == nil }.count == 2)
        #expect(leftovers().subtracting(before).isEmpty)
        try f.service.undoLast()
        #expect(leftovers().subtracting(before).isEmpty)
    }
}
