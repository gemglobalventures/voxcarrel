import Foundation
import Testing
import UniformTypeIdentifiers
@testable import VoxCarrelCore
import VoxCarrelFixtures

@Suite struct CoverStoreTests {
    let jpeg = MediaFixtures.makeImage(.jpeg)
    let png = MediaFixtures.makeImage(.png)

    func makeStore() throws -> (root: URL, layout: LibraryLayout, covers: CoverStore) {
        let root = try makeTempDir()
        let layout = LibraryLayout(root: root)
        return (root, layout, CoverStore(layout: layout))
    }

    func coverFiles(_ layout: LibraryLayout) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: layout.coversFolder.path)) ?? []).sorted()
    }

    @Test func aBookWithNoCoverHasNone() throws {
        let (root, layout, covers) = try makeStore()
        #expect(covers.url(for: 1) == nil)
        #expect(covers.image(for: 1) == nil)
        // Asking does not create the folder.
        #expect(!exists(layout.hiddenFolder))
        #expect(tree(root).isEmpty)
    }

    // C1: the folder is made on demand and the extension follows the bytes, not the label.
    @Test func setCreatesTheFolderAndNamesTheFileByItsType() throws {
        let (_, layout, covers) = try makeStore()

        try covers.set(CoverImage(data: jpeg, mime: "image/png"), for: 7)  // mislabelled

        #expect(coverFiles(layout) == ["7.jpg"])
        let url = try #require(covers.url(for: 7))
        #expect(url.path == layout.coversFolder.appendingPathComponent("7.jpg").path)
        #expect(try Data(contentsOf: url) == jpeg)

        try covers.set(CoverImage(data: png, mime: "image/png"), for: 8)
        #expect(coverFiles(layout) == ["7.jpg", "8.png"])
    }

    // C1
    @Test func jpgThenPngLeavesOnlyThePng() throws {
        let (_, layout, covers) = try makeStore()
        try covers.set(CoverImage(data: jpeg, mime: "image/jpeg"), for: 3)
        try covers.set(CoverImage(data: jpeg, mime: "image/jpeg"), for: 30)  // another book

        try covers.set(CoverImage(data: png, mime: "image/png"), for: 3)

        #expect(coverFiles(layout) == ["3.png", "30.jpg"])
        #expect(covers.url(for: 3)?.lastPathComponent == "3.png")
        #expect(covers.image(for: 3) == CoverImage(data: png, mime: "image/png"))
        #expect(covers.image(for: 30)?.data == jpeg)
    }

    // C1: same type again replaces in place.
    @Test func settingTheSameTypeReplacesTheImage() throws {
        let (_, layout, covers) = try makeStore()
        let other = MediaFixtures.makeImage(.jpeg, red: 0.1)
        #expect(other != jpeg)
        try covers.set(CoverImage(data: jpeg, mime: "image/jpeg"), for: 3)
        try covers.set(CoverImage(data: other, mime: "image/jpeg"), for: 3)
        #expect(coverFiles(layout) == ["3.jpg"])
        #expect(covers.image(for: 3)?.data == other)
    }

    // C1, C2: other image types and unrecognised bytes are kept as .img.
    @Test func otherAndUnknownTypesAreStoredAsImg() throws {
        let (_, layout, covers) = try makeStore()
        let gif = MediaFixtures.makeImage(.gif)
        let junk = Data("not an image at all".utf8)

        try covers.set(CoverImage(data: png, mime: "image/png"), for: 1)
        try covers.set(CoverImage(data: gif, mime: "image/jpeg"), for: 1)  // mislabelled
        try covers.set(CoverImage(data: junk, mime: "image/png"), for: 2)

        #expect(coverFiles(layout) == ["1.img", "2.img"])
        #expect(covers.image(for: 1) == CoverImage(data: gif, mime: "image/gif"))
        #expect(covers.image(for: 2) == CoverImage(data: junk, mime: "application/octet-stream"))

        // And an .img is cleared away when a jpg replaces it.
        try covers.set(CoverImage(data: jpeg, mime: "image/jpeg"), for: 1)
        #expect(coverFiles(layout) == ["1.jpg", "2.img"])
    }

    // C2: the bytes come back with the type they really are.
    @Test func imageReturnsBytesWithSniffedType() throws {
        let (_, _, covers) = try makeStore()
        try covers.set(CoverImage(data: jpeg, mime: "image/png"), for: 5)
        #expect(covers.image(for: 5) == CoverImage(data: jpeg, mime: "image/jpeg"))
        try covers.set(CoverImage(data: png, mime: "text/plain"), for: 6)
        #expect(covers.image(for: 6) == CoverImage(data: png, mime: "image/png"))
    }

    // C2
    @Test func removeDeletesTheCoverAndIsHarmlessWithoutOne() throws {
        let (root, layout, covers) = try makeStore()
        // Nothing stored, not even the folder: no error, nothing created.
        try covers.remove(for: 9)
        #expect(tree(root).isEmpty)

        try covers.set(CoverImage(data: jpeg, mime: "image/jpeg"), for: 9)
        try covers.set(CoverImage(data: png, mime: "image/png"), for: 10)
        try covers.remove(for: 9)

        #expect(covers.url(for: 9) == nil)
        #expect(covers.image(for: 9) == nil)
        #expect(coverFiles(layout) == ["10.png"])
        try covers.remove(for: 9)  // again: nothing to do
        #expect(coverFiles(layout) == ["10.png"])
    }

    // C3: an atomic write leaves no temporary file beside the cover.
    @Test func writesLeaveNothingButTheCover() throws {
        let (root, _, covers) = try makeStore()
        try covers.set(CoverImage(data: jpeg, mime: "image/jpeg"), for: 1)
        try covers.set(CoverImage(data: png, mime: "image/png"), for: 1)
        #expect(tree(root) == [".voxcarrel", ".voxcarrel/covers", ".voxcarrel/covers/1.png"])
    }

    // C1, C3: when the new cover cannot be written, the old one is still there.
    @Test func failedSetKeepsThePreviousCover() throws {
        let (_, layout, covers) = try makeStore()
        try covers.set(CoverImage(data: jpeg, mime: "image/jpeg"), for: 4)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: layout.coversFolder.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: layout.coversFolder.path)
        }

        #expect(throws: (any Error).self) {
            try covers.set(CoverImage(data: png, mime: "image/png"), for: 4)
        }

        #expect(coverFiles(layout) == ["4.jpg"])
        #expect(covers.image(for: 4)?.data == jpeg)
    }

    // Decision "Hidden library data": the scanner never sees stored covers.
    @Test func coversFolderIsHiddenAndIgnoredByTheScanner() throws {
        let (root, layout, covers) = try makeStore()
        try covers.set(CoverImage(data: jpeg, mime: "image/jpeg"), for: 1)
        try covers.set(CoverImage(data: Data("junk".utf8), mime: "image/png"), for: 2)
        // Even a book-like file inside the hidden folder is not picked up.
        try touch(layout.undoFolder.appendingPathComponent("stray.epub"))
        try touch(root.appendingPathComponent("Andy Weir/Artemis/Artemis.epub"))

        #expect(layout.hiddenFolder.lastPathComponent.hasPrefix("."))
        #expect(layout.coversFolder.path.hasPrefix(layout.hiddenFolder.path + "/"))
        #expect(layout.undoFolder.path.hasPrefix(layout.hiddenFolder.path + "/"))

        let result = BookScanner().scan([root])

        #expect(result.candidates.count == 1)
        let mentioned = result.skipped.map(\.path)
        #expect(!mentioned.contains { $0.contains(".voxcarrel") })
        #expect(!String(describing: result.candidates).contains(".voxcarrel"))
    }

    // C1: an old cover that cannot be removed does not fail the new one, which is then the cover.
    @Test func anOldCoverThatCannotBeRemovedDoesNotFailTheNewOne() throws {
        let (_, layout, covers) = try makeStore()
        try covers.set(CoverImage(data: jpeg, mime: "image/jpeg"), for: 3)
        let old = layout.coversFolder.appendingPathComponent("3.jpg")
        // An old date, and locked so that it cannot be deleted.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        #expect(chflags(old.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(old.path, 0) }

        try covers.set(CoverImage(data: png, mime: "image/png"), for: 3)

        #expect(coverFiles(layout) == ["3.jpg", "3.png"])
        #expect(covers.url(for: 3)?.lastPathComponent == "3.png")
        #expect(covers.image(for: 3)?.data == png)

        // Whichever extension it has, the newest file is the cover.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -7200)],
            ofItemAtPath: layout.coversFolder.appendingPathComponent("3.png").path)
        #expect(covers.url(for: 3)?.lastPathComponent == "3.jpg")

        // Once it can be removed, the next set leaves one file again.
        _ = chflags(old.path, 0)
        try covers.set(CoverImage(data: png, mime: "image/png"), for: 3)
        #expect(coverFiles(layout) == ["3.png"])
    }
}
