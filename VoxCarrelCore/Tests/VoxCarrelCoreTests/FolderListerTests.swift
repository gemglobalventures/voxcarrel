import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// Listing the supported files under a watched folder (rules IB10–IB15).
@Suite struct FolderListerTests {
    private let fm = FileManager.default

    /// Runs `body` with a new temporary folder, in the spelling the catalogue stores
    /// (links resolved), and removes it afterwards.
    private func withFolder(_ body: (URL) throws -> Void) throws {
        let base = try makeTempDir()
        defer { try? fm.removeItem(at: base) }
        try body(LibraryLayout.canonicalFolder(base))
    }

    /// The listed paths, relative to the folder.
    private func names(_ listing: FolderListing, under folder: URL) -> [String] {
        listing.files.map { String($0.url.path.dropFirst(folder.path.count + 1)) }
    }

    private func mkdir(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: IB10

    @Test func IB10_everySupportedFormatIsListedInAnyCapitalsAndAtAnyDepth() throws {
        try withFolder { folder in
            for name in ["a.m4b", "b.M4A", "c.Mp3", "d.epub", "e.MOBI", "f.azw3",
                         "Deep/er/still/g.mp3", "Series/Book/01.mp3", "Series/Book/02.mp3"] {
                try touch(folder.appendingPathComponent(name))
            }
            for name in ["notes.txt", "cover.jpg", "book.flac", "noextension", "Deep/readme.md", "m4b"] {
                try touch(folder.appendingPathComponent(name))
            }

            let listing = FolderLister().list(folder, includePDFs: false)

            #expect(listing.availability == .available)
            #expect(names(listing, under: folder) == [
                "Deep/er/still/g.mp3", "Series/Book/01.mp3", "Series/Book/02.mp3",
                "a.m4b", "b.M4A", "c.Mp3", "d.epub", "e.MOBI", "f.azw3",
            ])
        }
    }

    @Test func IB10_PDFsAreListedOnlyWhenAskedFor() throws {
        try withFolder { folder in
            try touch(folder.appendingPathComponent("a.m4b"))
            try touch(folder.appendingPathComponent("paper.pdf"))
            try touch(folder.appendingPathComponent("Sub/Scan.PDF"))

            let lister = FolderLister()

            #expect(names(lister.list(folder, includePDFs: false), under: folder) == ["a.m4b"])
            #expect(names(lister.list(folder, includePDFs: true), under: folder) == ["Sub/Scan.PDF", "a.m4b", "paper.pdf"])
        }
    }

    /// Every format the model knows is listed: there is no second list to fall behind.
    @Test func IB10_whatIsSupportedIsWhatTheModelSaysIs() throws {
        try withFolder { folder in
            for format in FileFormat.allCases {
                try touch(folder.appendingPathComponent("book.\(format.rawValue)"))
            }

            let listing = FolderLister().list(folder, includePDFs: true)

            #expect(listing.files.count == FileFormat.allCases.count)
            #expect(listing.files.allSatisfy { FileFormat(url: $0.url) != nil })
        }
    }

    @Test func IB10_aFileIsListedWithItsSizeAndItsDateExactly() throws {
        try withFolder { folder in
            let file = try touch(folder.appendingPathComponent("a.m4b"), "twelve bytes")
            let date = Date(timeIntervalSinceReferenceDate: 700_000_000.123456)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: file.path)

            let lister = FolderLister()
            let first = lister.list(folder, includePDFs: false)
            let second = lister.list(folder, includePDFs: false)

            let listed = try #require(first.files.first)
            #expect(listed.size == 12)
            let reported = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            #expect(listed.modifiedAt == reported)
            #expect(abs(listed.modifiedAt.timeIntervalSince(date)) < 0.001)
            // An unchanged file is the same file at every listing, to the last bit.
            #expect(first.files == second.files)
        }
    }

    /// The ledger compares paths as text, so a listed path is the given folder's path
    /// with the names below it added, however the folder was spelled.
    @Test func IB10_listedPathsBeginWithTheFolderAsGiven() throws {
        let base = try makeTempDir()
        defer { try? fm.removeItem(at: base) }
        try touch(base.appendingPathComponent("Sub/a.m4b"))
        try touch(base.appendingPathComponent("b.mp3"))
        let resolved = LibraryLayout.canonicalFolder(base)

        for given in [base, resolved, URL(fileURLWithPath: resolved.path + "/")] {
            let listing = FolderLister().list(given, includePDFs: false)
            let stem = URL(fileURLWithPath: given.path).path
            #expect(listing.files.map(\.url.path) == [stem + "/Sub/a.m4b", stem + "/b.mp3"])
        }
    }

    @Test func IB10_filesAreSortedByPath() throws {
        try withFolder { folder in
            for name in ["b.mp3", "a/z.mp3", "Upper/B.mp3", "a.mp3", "a/a.mp3", "c/a.mp3"] {
                try touch(folder.appendingPathComponent(name))
            }

            let paths = FolderLister().list(folder, includePDFs: false).files.map(\.url.path)

            #expect(paths.count == 6)
            #expect(paths == paths.sorted())
        }
    }

    // MARK: IB11

    @Test func IB11_hiddenFilesAndEverythingUnderAHiddenFolderAreLeftOut() throws {
        try withFolder { folder in
            try touch(folder.appendingPathComponent("seen.m4b"))
            try touch(folder.appendingPathComponent(".hidden.m4b"))
            try touch(folder.appendingPathComponent(".cache/inside.m4b"))
            try touch(folder.appendingPathComponent(".cache/deeper/inside.m4b"))
            // Hidden by its flag, not its name.
            var flagged = try touch(folder.appendingPathComponent("flagged.m4b"))
            var values = URLResourceValues()
            values.isHidden = true
            try flagged.setResourceValues(values)
            var flaggedFolder = folder.appendingPathComponent("Flagged", isDirectory: true)
            try touch(flaggedFolder.appendingPathComponent("inside.m4b"))
            try flaggedFolder.setResourceValues(values)

            #expect(names(FolderLister().list(folder, includePDFs: false), under: folder) == ["seen.m4b"])
        }
    }

    /// Only what is hidden below the watched folder counts: a watched folder that
    /// itself lies under a hidden one is listed.
    @Test func IB11_aWatchedFolderUnderAHiddenFolderIsStillListed() throws {
        try withFolder { base in
            let folder = base.appendingPathComponent(".tucked/Watched", isDirectory: true)
            try touch(folder.appendingPathComponent("a.m4b"))

            #expect(names(FolderLister().list(folder, includePDFs: false), under: folder) == ["a.m4b"])
        }
    }

    @Test func IB11_nothingInsideAPackageIsListed() throws {
        try withFolder { folder in
            try touch(folder.appendingPathComponent("seen.m4b"))
            try touch(folder.appendingPathComponent("Player.app/Contents/Resources/sample.mp3"))
            try touch(folder.appendingPathComponent("Sub/Other.app/sample.mp3"))
            // A folder named like a book file is one item to the importer, not a folder of books.
            try touch(folder.appendingPathComponent("Unpacked.epub/chapter.mp3"))

            let isPackage = try folder.appendingPathComponent("Player.app")
                .resourceValues(forKeys: [.isPackageKey]).isPackage
            #expect(isPackage == true)
            #expect(names(FolderLister().list(folder, includePDFs: false), under: folder) == ["seen.m4b"])
        }
    }

    @Test func IB11_symbolicLinksAreNeitherListedNorFollowed() throws {
        try withFolder { base in
            let folder = base.appendingPathComponent("Watched", isDirectory: true)
            let elsewhere = base.appendingPathComponent("Elsewhere", isDirectory: true)
            try touch(folder.appendingPathComponent("seen.m4b"))
            try touch(elsewhere.appendingPathComponent("far.m4b"))
            try fm.createSymbolicLink(
                at: folder.appendingPathComponent("link.m4b"),
                withDestinationURL: elsewhere.appendingPathComponent("far.m4b"))
            try fm.createSymbolicLink(
                at: folder.appendingPathComponent("LinkedFolder"), withDestinationURL: elsewhere)
            try fm.createSymbolicLink(
                at: folder.appendingPathComponent("broken.m4b"),
                withDestinationURL: base.appendingPathComponent("nothing.m4b"))

            #expect(names(FolderLister().list(folder, includePDFs: false), under: folder) == ["seen.m4b"])
        }
    }

    @Test func IB11_emptyFilesAreLeftOut() throws {
        try withFolder { folder in
            try touch(folder.appendingPathComponent("seen.m4b"))
            try touch(folder.appendingPathComponent("empty.m4b"), "")
            try touch(folder.appendingPathComponent("Sub/empty.epub"), "")

            #expect(names(FolderLister().list(folder, includePDFs: true), under: folder) == ["seen.m4b"])
        }
    }

    @Test(arguments: ["crdownload", "part", "download", "tmp", "partial", "aax", "aaxc"])
    func IB11_unfinishedDownloadsAndProtectedAudibleFilesAreLeftOut(ext: String) throws {
        try withFolder { folder in
            try touch(folder.appendingPathComponent("seen.m4b"))
            try touch(folder.appendingPathComponent("book.\(ext)"))
            try touch(folder.appendingPathComponent("Shouted.\(ext.uppercased())"))
            // The usual shape: the real name with the browser's extension after it.
            try touch(folder.appendingPathComponent("book.m4b.\(ext)"))
            try touch(folder.appendingPathComponent("Sub/book.epub.\(ext)"))

            #expect(names(FolderLister().list(folder, includePDFs: true), under: folder) == ["seen.m4b"])
        }
    }

    // MARK: IB12

    /// A real iCloud placeholder cannot be made in a temporary folder, so the check
    /// "is this file's content on this Mac" is replaced here; the two tests after this
    /// one cover the check itself.
    @Test func IB12_aFileNotDownloadedIsLeftOut() throws {
        try withFolder { folder in
            try touch(folder.appendingPathComponent("here.m4b"))
            try touch(folder.appendingPathComponent("cloud.m4b"))
            try touch(folder.appendingPathComponent("Sub/cloud.epub"))
            try touch(folder.appendingPathComponent("Sub/here.epub"))

            var lister = FolderLister()
            lister.isDownloaded = { !$0.lastPathComponent.hasPrefix("cloud") }

            #expect(names(lister.list(folder, includePDFs: false), under: folder) == ["Sub/here.epub", "here.m4b"])
        }
    }

    @Test func IB12_onlyAFileThatIsCurrentAndNotDatalessCountsAsDownloaded() {
        let dataless = UInt32(SF_DATALESS)
        // An ordinary file outside iCloud has no status at all.
        #expect(FolderLister.isDownloaded(status: nil, flags: 0))
        #expect(FolderLister.isDownloaded(status: .current, flags: 0))
        #expect(FolderLister.isDownloaded(status: .current, flags: UInt32(UF_HIDDEN)))
        #expect(!FolderLister.isDownloaded(status: .notDownloaded, flags: 0))
        // Downloaded, but an older version than iCloud holds.
        #expect(!FolderLister.isDownloaded(status: .downloaded, flags: 0))
        #expect(!FolderLister.isDownloaded(status: nil, flags: dataless))
        #expect(!FolderLister.isDownloaded(status: .current, flags: dataless))
        #expect(!FolderLister.isDownloaded(status: .current, flags: dataless | UInt32(UF_HIDDEN)))
    }

    /// The check as shipped, on real files: an ordinary file is downloaded, and asking
    /// about a file that is not there says no without throwing. That the check reads
    /// attributes only, never contents, is by construction (see `FolderLister.isDownloaded`).
    @Test func IB12_theRealCheckPassesAnOrdinaryFile() throws {
        try withFolder { folder in
            let file = try touch(folder.appendingPathComponent("a.m4b"))

            #expect(FolderLister.isDownloaded(file))
            #expect(!FolderLister.isDownloaded(folder.appendingPathComponent("gone.m4b")))
        }
    }

    // MARK: IB13

    @Test func IB13_aFolderThatDoesNotExistIsMissing() throws {
        try withFolder { base in
            let listing = FolderLister().list(base.appendingPathComponent("Nowhere", isDirectory: true), includePDFs: true)

            #expect(listing.availability == .missing)
            #expect(listing.files.isEmpty)
        }
    }

    @Test func IB13_aFileWhereTheFolderShouldBeIsMissing() throws {
        try withFolder { base in
            let file = try touch(base.appendingPathComponent("book.m4b"))

            let listing = FolderLister().list(file, includePDFs: true)

            #expect(listing.availability == .missing)
            #expect(listing.files.isEmpty)
        }
    }

    @Test func IB13_aFolderThatCannotBeReadIsNotAllowed() throws {
        try withFolder { base in
            let folder = base.appendingPathComponent("Locked", isDirectory: true)
            try touch(folder.appendingPathComponent("a.m4b"))
            try touch(folder.appendingPathComponent("Sub/b.m4b"))
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

            let listing = FolderLister().list(folder, includePDFs: true)

            #expect(listing.availability == .notAllowed)
            #expect(listing.files.isEmpty)
        }
    }

    // MARK: IB14

    @Test func IB14_aSubFolderThatCannotBeReadIsSkippedAndTheRestListed() throws {
        try withFolder { folder in
            try touch(folder.appendingPathComponent("a.m4b"))
            try touch(folder.appendingPathComponent("Open/b.m4b"))
            try touch(folder.appendingPathComponent("Zed/Deep/c.m4b"))
            let locked = folder.appendingPathComponent("Locked", isDirectory: true)
            try touch(locked.appendingPathComponent("secret.m4b"))
            let deepLocked = folder.appendingPathComponent("Open/Locked", isDirectory: true)
            try touch(deepLocked.appendingPathComponent("secret.m4b"))
            for url in [locked, deepLocked] {
                try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            }
            defer {
                for url in [locked, deepLocked] {
                    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                }
            }

            let listing = FolderLister().list(folder, includePDFs: false)

            #expect(listing.availability == .available)
            #expect(names(listing, under: folder) == ["Open/b.m4b", "Zed/Deep/c.m4b", "a.m4b"])
        }
    }

    // MARK: IB15

    @Test func IB15_fiveThousandBooksAmongTwentyThousandOtherFilesAreListedInTime() throws {
        try withFolder { folder in
            let byte = Data([1])
            // 50 folders, each with 100 supported files and 400 others.
            for group in 0..<50 {
                let sub = folder.appendingPathComponent("Shelf \(group)/Book", isDirectory: true)
                try mkdir(sub)
                for index in 0..<500 {
                    let name = index < 100 ? "part \(index).mp3" : "other \(index).\(index % 2 == 0 ? "jpg" : "txt")"
                    try #require(fm.createFile(atPath: sub.appendingPathComponent(name).path, contents: byte))
                }
            }

            let clock = ContinuousClock()
            var listing = FolderListing(availability: .missing, files: [])
            let taken = clock.measure { listing = FolderLister().list(folder, includePDFs: true) }

            #expect(listing.availability == .available)
            #expect(listing.files.count == 5_000)
            #expect(taken < .seconds(20))
        }
    }
}
