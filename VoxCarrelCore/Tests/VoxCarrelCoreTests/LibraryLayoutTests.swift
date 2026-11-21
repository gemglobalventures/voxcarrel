import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

@Suite struct LibraryLayoutTests {
    /// A library root with its symlinks resolved, so paths compare exactly.
    func makeRoot() throws -> URL {
        try makeTempDir().resolvingSymlinksInPath()
    }

    func mkdir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @Test func hiddenFoldersSitUnderDotVoxcarrel() throws {
        let root = try makeRoot()
        let layout = LibraryLayout(root: root)
        #expect(layout.root == root)
        #expect(layout.hiddenFolder.path == root.path + "/.voxcarrel")
        #expect(layout.coversFolder.path == root.path + "/.voxcarrel/covers")
        #expect(layout.undoFolder.path == root.path + "/.voxcarrel/undo")
        // Asking for the paths creates nothing.
        #expect(tree(root).isEmpty)
    }

    // L1: the plan's own example.
    @Test func existingDifferentlyCasedAuthorFolderIsAdopted() throws {
        let root = try makeRoot()
        try mkdir(root.appendingPathComponent("andy weir"))
        let layout = LibraryLayout(root: root)

        let adopted = layout.adoptingExistingCapitalisation(
            root.appendingPathComponent("Andy Weir/New Book/New Book.epub"))

        // L1: the author folder takes the disk's spelling; the deeper components,
        // which do not exist yet, are kept as given.
        #expect(adopted.path == root.path + "/andy weir/New Book/New Book.epub")
    }

    // L1
    @Test func nestedSeriesFolderIsAdopted() throws {
        let root = try makeRoot()
        try mkdir(root.appendingPathComponent("Frank Herbert/DUNE Chronicles/1 - dune"))
        let layout = LibraryLayout(root: root)

        let adopted = layout.adoptingExistingCapitalisation(
            root.appendingPathComponent("frank herbert/Dune Chronicles/1 - Dune/Dune.m4b"))
        #expect(adopted.path == root.path + "/Frank Herbert/DUNE Chronicles/1 - dune/Dune.m4b")

        // A sibling that does not exist keeps its own spelling below the adopted parents.
        let sibling = layout.adoptingExistingCapitalisation(
            root.appendingPathComponent("FRANK HERBERT/dune chronicles/2 - Dune Messiah/Dune Messiah.m4b"))
        #expect(sibling.path
            == root.path + "/Frank Herbert/DUNE Chronicles/2 - Dune Messiah/Dune Messiah.m4b")
    }

    // L1: a path already spelled as on disk comes back the same.
    @Test func matchingCapitalisationIsUnchanged() throws {
        let root = try makeRoot()
        try mkdir(root.appendingPathComponent("Andy Weir/Artemis"))
        let url = root.appendingPathComponent("Andy Weir/Artemis/Artemis.epub")
        #expect(LibraryLayout(root: root).adoptingExistingCapitalisation(url).path == url.path)
    }

    // L1: nothing below a component that does not exist is rewritten, and a plain file
    // with a folder's name is not taken for the folder.
    @Test func componentsThatDoNotExistAreKept() throws {
        let root = try makeRoot()
        try touch(root.appendingPathComponent("andy weir"))  // a file, not a folder
        let layout = LibraryLayout(root: root)

        let underFile = root.appendingPathComponent("Andy Weir/Artemis/Artemis.epub")
        #expect(layout.adoptingExistingCapitalisation(underFile).path == underFile.path)

        let fresh = root.appendingPathComponent("Mary Shelley/Frankenstein/Frankenstein.epub")
        #expect(layout.adoptingExistingCapitalisation(fresh).path == fresh.path)
    }

    // L1
    @Test func urlOutsideTheRootIsUnchanged() throws {
        let base = try makeRoot()
        let root = base.appendingPathComponent("Library")
        try mkdir(root.appendingPathComponent("andy weir"))
        try mkdir(base.appendingPathComponent("elsewhere/andy weir"))
        try mkdir(base.appendingPathComponent("Library Two/andy weir"))
        let layout = LibraryLayout(root: root)

        let outside = base.appendingPathComponent("Elsewhere/Andy Weir/Book.epub")
        #expect(layout.adoptingExistingCapitalisation(outside) == outside)
        // A neighbour whose name merely starts with the root's name is outside too.
        let neighbour = base.appendingPathComponent("Library Two/Andy Weir/Book.epub")
        #expect(layout.adoptingExistingCapitalisation(neighbour) == neighbour)
        // The root itself has no folders below it to rewrite.
        #expect(layout.adoptingExistingCapitalisation(root) == root)
    }

    // L2: the last component is never changed, even when a file of other case exists,
    // and even when it names an existing folder.
    @Test func lastComponentKeepsItsCapitalisation() throws {
        let root = try makeRoot()
        try touch(root.appendingPathComponent("andy weir/artemis/artemis.epub"))
        let layout = LibraryLayout(root: root)

        let file = layout.adoptingExistingCapitalisation(
            root.appendingPathComponent("Andy Weir/Artemis/Artemis.EPUB"))
        #expect(file.path == root.path + "/andy weir/artemis/Artemis.EPUB")

        let folderLast = layout.adoptingExistingCapitalisation(
            root.appendingPathComponent("Andy Weir/Artemis"))
        #expect(folderLast.path == root.path + "/andy weir/Artemis")

        let topLevel = layout.adoptingExistingCapitalisation(root.appendingPathComponent("Andy Weir"))
        #expect(topLevel.path == root.path + "/Andy Weir")
    }

    // L2: looking never creates, renames or removes anything.
    @Test func lookingChangesNothingOnDisk() throws {
        let root = try makeRoot()
        try touch(root.appendingPathComponent("andy weir/artemis/artemis.epub"))
        let before = tree(root)
        let layout = LibraryLayout(root: root)

        _ = layout.adoptingExistingCapitalisation(
            root.appendingPathComponent("Andy Weir/Artemis/Artemis.epub"))
        _ = layout.adoptingExistingCapitalisation(
            root.appendingPathComponent("Nobody/Nothing/Nothing.epub"))

        #expect(tree(root) == before)
        #expect(before == ["andy weir", "andy weir/artemis", "andy weir/artemis/artemis.epub"])
    }

    // L1: the root may be given through a symlinked path (as temp folders are).
    @Test func worksWhenRootIsNotStandardised() throws {
        let root = try makeTempDir()  // /var/folders/..., a symlink to /private/var/...
        try mkdir(root.appendingPathComponent("andy weir"))
        let layout = LibraryLayout(root: root)
        let adopted = layout.adoptingExistingCapitalisation(
            root.appendingPathComponent("Andy Weir/Book/Book.epub"))
        #expect(adopted.path == root.path + "/andy weir/Book/Book.epub")
    }

    @Test func samePathIgnoringCase() {
        let a = URL(fileURLWithPath: "/Library/Andy Weir/Artemis/Artemis.epub")
        #expect(LibraryLayout.samePathIgnoringCase(a, a))
        #expect(LibraryLayout.samePathIgnoringCase(
            a, URL(fileURLWithPath: "/library/andy weir/ARTEMIS/artemis.EPUB")))
        // Folder URLs with and without the trailing slash, and with "." and ".." in them.
        #expect(LibraryLayout.samePathIgnoringCase(
            URL(fileURLWithPath: "/Library/Andy Weir", isDirectory: true),
            URL(fileURLWithPath: "/library/andy weir", isDirectory: false)))
        #expect(LibraryLayout.samePathIgnoringCase(
            a, URL(fileURLWithPath: "/Library/x/../Andy Weir/./artemis/Artemis.epub")))
        // Different locations stay different.
        #expect(!LibraryLayout.samePathIgnoringCase(
            a, URL(fileURLWithPath: "/Library/Andy Weir/Artemis/Artemis.pdf")))
        #expect(!LibraryLayout.samePathIgnoringCase(
            a, URL(fileURLWithPath: "/Library/Andy Weir/Artemis")))
        #expect(!LibraryLayout.samePathIgnoringCase(
            URL(fileURLWithPath: "/Library/Andy Weir"), URL(fileURLWithPath: "/Library/Andy  Weir")))
    }
}
