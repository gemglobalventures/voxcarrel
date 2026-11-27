import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// OB1–OB4: books added where their files are, and brought into the library later.
@Suite struct OutsideBooksTests {
    /// A library, and a folder elsewhere holding one book in two MP3 parts.
    private func made() throws -> (service: LibraryService, root: URL, elsewhere: URL) {
        let base = try makeTempDir()
        let root = base.appendingPathComponent("Library", isDirectory: true)
        let elsewhere = base.appendingPathComponent("Drive/Old Rips/salt_road_rip", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        for name in ["01.mp3", "02.mp3"] {
            try MediaFixtures.makeSilentMP3(seconds: 1).write(to: elsewhere.appendingPathComponent(name))
        }
        let store = try LibraryStore(libraryRoot: root)
        return (LibraryService(store: store), LibraryLayout.canonicalFolder(root), elsewhere)
    }

    private func addInPlace(_ m: (service: LibraryService, root: URL, elsewhere: URL), title: String = "Salt Road") throws -> Int64 {
        var candidate = try #require(m.service.scan([m.elsewhere]).candidates.first)
        candidate.metadata = BookMetadata(title: title, authors: ["Ines Calloway"])
        let result = try m.service.importItems([ImportItem(candidate: candidate)], options: ImportOptions(leavesInPlace: true))
        guard case .imported(let id, let problems) = try #require(result.outcomes.first) else {
            Issue.record("not imported: \(result.outcomes)")
            return 0
        }
        #expect(problems.isEmpty)
        return id
    }

    private func bytes(_ folder: URL) throws -> [String: Data] {
        var found: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            found[name] = try Data(contentsOf: folder.appendingPathComponent(name))
        }
        return found
    }

    // OB1: added in place, nothing is moved, copied or written; the book is in the
    // catalogue with the details that were reviewed.
    @Test func OB1_addedWhereItIsNothingIsTouched() throws {
        let m = try made()
        let before = try bytes(m.elsewhere)
        let id = try addInPlace(m)
        #expect(try bytes(m.elsewhere) == before)
        let book = try #require(try m.service.store.book(id: id))
        #expect(book.keptOutside && book.folderPath == nil && !book.needsAttention && book.title == "Salt Road")
        let files = try m.service.store.files(bookId: id)
        #expect(files.count == 2 && files.allSatisfy { $0.path.hasPrefix("/") })
        #expect(try m.service.booksKeptOutside() == [id])
        // Nothing of it is inside the library folder.
        let inside = try FileManager.default.contentsOfDirectory(atPath: m.root.path).filter { !$0.hasPrefix(".") && !$0.hasSuffix(".sqlite") }
        #expect(inside.isEmpty)
        // The check never flags it, even with its files out of sight.
        let parked = m.elsewhere.deletingLastPathComponent().appendingPathComponent("away")
        try FileManager.default.moveItem(at: m.elsewhere, to: parked)
        #expect(try m.service.reconcile().booksWithMissingFiles.isEmpty)
        #expect(try m.service.store.book(id: id)?.needsAttention == false)
        try FileManager.default.moveItem(at: parked, to: m.elsewhere)
    }

    // OB2: an edit to a book kept outside is the catalogue's alone, and can be undone.
    @Test func OB2_anEditIsTheCataloguesAlone() throws {
        let m = try made()
        let id = try addInPlace(m)
        let before = try bytes(m.elsewhere)
        var edit = BookEdit(book: try #require(try m.service.store.book(id: id)))
        edit.metadata.title = "The Salt Road"
        edit.metadata.series = "Tidewater"
        #expect(try m.service.save([edit]) == [.saved(bookId: id, refiled: false, appOnlyFields: [], fileProblems: [])])
        #expect(try bytes(m.elsewhere) == before)
        let saved = try #require(try m.service.store.book(id: id))
        #expect(saved.title == "The Salt Road" && saved.keptOutside && saved.folderPath == nil)
        #expect(try m.service.store.files(bookId: id).count == 2)
        _ = try m.service.undoLast()
        #expect(try m.service.store.book(id: id)?.title == "Salt Road" && m.service.store.files(bookId: id).count == 2)
    }

    // OB3: brought in as a copy, the book is filed in the library with the catalogue's
    // details in its files, and the originals are as they were. Undo puts it back outside.
    @Test func OB3_broughtInAsACopyTheOriginalsStay() throws {
        let m = try made()
        let id = try addInPlace(m)
        var edit = BookEdit(book: try #require(try m.service.store.book(id: id)))
        edit.metadata.narrators = ["Marcus Lindqvist"]
        _ = try m.service.save([edit])
        let before = try bytes(m.elsewhere)

        #expect(try m.service.bringIntoLibrary([id], mode: .copy) == BroughtIn(brought: 1, problems: []))
        #expect(try bytes(m.elsewhere) == before)
        let book = try #require(try m.service.store.book(id: id))
        #expect(!book.keptOutside && book.folderPath == "Ines Calloway/Salt Road")
        let files = try m.service.store.files(bookId: id)
        #expect(files.count == 2 && files.allSatisfy { !$0.path.hasPrefix("/") })
        let first = m.service.store.url(for: files[0])
        #expect(first.path.hasPrefix(m.root.path) && FileManager.default.fileExists(atPath: first.path))
        let written = try FileMetadataIO().read(first).metadata
        #expect(written.title == "Salt Road" && written.narrators == ["Marcus Lindqvist"])
        #expect(try m.service.booksKeptOutside().isEmpty)
        // Once in, it is not brought in again.
        #expect(try m.service.bringIntoLibrary([id], mode: .copy) == BroughtIn(brought: 0, problems: []))

        _ = try m.service.undoLast()
        let back = try #require(try m.service.store.book(id: id))
        #expect(back.keptOutside && back.folderPath == nil)
        #expect(try m.service.store.files(bookId: id).allSatisfy { $0.path.hasPrefix("/") })
        let after = try bytes(m.elsewhere)
        #expect(!FileManager.default.fileExists(atPath: first.path) && after == before)
    }

    // OB4: brought in by moving, the originals are taken; a book whose files cannot be
    // found stays outside, and why is said.
    @Test func OB4_broughtInByMovingAndWhatCannotBeFound() throws {
        let m = try made()
        let id = try addInPlace(m)
        let parked = m.elsewhere.deletingLastPathComponent().appendingPathComponent("away")
        try FileManager.default.moveItem(at: m.elsewhere, to: parked)
        let missing = try m.service.bringIntoLibrary([id], mode: .move)
        #expect(missing.brought == 0 && missing.problems.count == 1 && missing.problems[0].contains("cannot be found"))
        #expect(try m.service.store.book(id: id)?.keptOutside == true)
        try FileManager.default.moveItem(at: parked, to: m.elsewhere)

        #expect(try m.service.bringIntoLibrary([id], mode: .move).brought == 1)
        let left = (try? bytes(m.elsewhere)) ?? [:]
        #expect(left.isEmpty)
        let files = try m.service.store.files(bookId: id)
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: m.service.store.url(for: $0).path) })
        #expect(try m.service.store.book(id: id)?.keptOutside == false)
    }
}
