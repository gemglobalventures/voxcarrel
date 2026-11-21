import Foundation
import Testing
import VoxCarrelAppCore

/// A22: what is handed to the scan when the launch check's loose files are imported.
@Suite struct UntrackedInputsTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }
    private let root = URL(fileURLWithPath: "/lib", isDirectory: true)

    private func grouped(_ untracked: [String], tracked: [String] = []) -> [String] {
        UntrackedInputs.grouped(untracked: untracked.map(url), tracked: tracked.map(url), root: root).map(\.path)
    }

    /// A folder none of whose files belongs to a book is scanned as a folder, once.
    @Test func aFolderOfLooseFilesIsPassedWhole() {
        #expect(grouped(["/lib/Night Train/1.mp3", "/lib/Night Train/2.mp3"]) == ["/lib/Night Train"])
    }

    /// The highest such folder is the one passed, so an author's folder of books is scanned as it lies.
    @Test func theHighestFolderWithNoBookFilesOfTheLibraryIsPassed() {
        #expect(
            grouped(["/lib/New Author/Book/Parts/1.mp3", "/lib/New Author/Other.epub", "/lib/Else/x.pdf"])
                == ["/lib/New Author", "/lib/Else"])
    }

    /// The library folder itself is never passed.
    @Test func filesDirectlyInTheLibraryArePassedOneByOne() {
        #expect(grouped(["/lib/Loose.epub", "/lib/Other.m4b"]) == ["/lib/Loose.epub", "/lib/Other.m4b"])
        #expect(!grouped(["/lib/Loose.epub", "/lib/A/1.mp3"]).contains("/lib"))
    }

    /// A folder that holds a library book's files, however deep, is not passed: its loose files go alone.
    @Test func foldersWithALibraryBooksFilesAreNotPassed() {
        let result = grouped(
            ["/lib/Ann/Atlas/Extra.pdf", "/lib/Ann/Loose.epub", "/lib/Ann/New Book/1.mp3", "/lib/Ann/New Book/2.mp3"],
            tracked: ["/lib/Ann/Atlas/Atlas.m4b"])
        #expect(result == ["/lib/Ann/Atlas/Extra.pdf", "/lib/Ann/Loose.epub", "/lib/Ann/New Book"])
    }

    /// Capitals in a path are not a difference, as on the Mac's disks.
    @Test func capitalsDoNotHideALibraryBooksFile() {
        #expect(grouped(["/lib/ann/Atlas/Extra.pdf"], tracked: ["/lib/Ann/atlas/Atlas.m4b"]) == ["/lib/ann/Atlas/Extra.pdf"])
    }

    /// A file that is not in the library folder is passed as it is.
    @Test func filesOutsideTheLibraryArePassedAsTheyAre() {
        #expect(grouped(["/elsewhere/Book/1.mp3"]) == ["/elsewhere/Book/1.mp3"])
        #expect(grouped([]) == [])
    }
}
