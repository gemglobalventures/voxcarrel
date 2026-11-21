import Foundation
import Testing
import VoxCarrelAppCore
import VoxCarrelCore
import VoxCarrelFixtures

@Suite struct LibraryLocationTests {
    /// Runs `body` with preferences of its own. Never `.standard`.
    ///
    /// A suite named by a path keeps its file there, in a temporary folder, and puts
    /// nothing in the user's Preferences folder.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = try makeTempDir().appendingPathComponent("preferences").path
        let defaults = try #require(UserDefaults(suiteName: suite))
        try body(defaults)
    }

    /// P1
    @Test func noStoredPathIsNotChosen() throws {
        try withDefaults { defaults in
            let location = LibraryLocation(defaults: defaults)
            #expect(location.url == nil)
            #expect(location.status() == .notChosen)
        }
    }

    /// P1
    @Test func storedWritableFolderIsAvailable() throws {
        try withDefaults { defaults in
            let folder = try makeTempDir()
            let location = LibraryLocation(defaults: defaults)
            location.url = folder
            #expect(defaults.string(forKey: LibraryLocation.defaultsKey) == folder.path)
            #expect(LibraryLocation.defaultsKey == "libraryPath")
            // Another value over the same preferences sees it.
            #expect(LibraryLocation(defaults: defaults).url?.path == folder.path)
            #expect(location.status() == .available(folder))
        }
    }

    /// P1: a folder that has gone, a file, and a folder that cannot be written to.
    @Test func anythingElseIsUnavailable() throws {
        try withDefaults { defaults in
            let location = LibraryLocation(defaults: defaults)
            let parent = try makeTempDir()

            let gone = parent.appendingPathComponent("Gone", isDirectory: true)
            location.url = gone
            #expect(location.status() == .unavailable(gone))

            let file = try touch(parent.appendingPathComponent("file.txt"))
            location.url = file
            guard case .unavailable(let reported) = location.status(), reported.path == file.path else {
                Issue.record("a file is not a library: \(location.status())")
                return
            }

            let locked = parent.appendingPathComponent("Locked", isDirectory: true)
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
            location.url = locked
            #expect(location.status() == .unavailable(locked))
        }
    }

    /// P1
    @Test func clearingTheURLForgetsTheLibrary() throws {
        try withDefaults { defaults in
            let location = LibraryLocation(defaults: defaults)
            location.url = try makeTempDir()
            location.url = nil
            #expect(defaults.object(forKey: LibraryLocation.defaultsKey) == nil)
            #expect(location.status() == .notChosen)
        }
    }

    /// P2
    @Test func inspectRecognisesAnExistingLibrary() throws {
        let folder = try makeTempDir()
        _ = try LibraryStore(libraryRoot: folder)
        try touch(folder.appendingPathComponent("Author/Book/Book.m4b"))
        #expect(LibraryLocation.inspect(folder) == .existingLibrary)
    }

    /// P2: hidden files do not count as "other files".
    @Test func inspectTreatsAFolderWithOnlyHiddenFilesAsEmpty() throws {
        let folder = try makeTempDir()
        #expect(LibraryLocation.inspect(folder) == .empty)
        try touch(folder.appendingPathComponent(".DS_Store"))
        try touch(folder.appendingPathComponent(".hidden/inner.txt"))
        #expect(LibraryLocation.inspect(folder) == .empty)
    }

    /// P2
    @Test func inspectCountsOtherFiles() throws {
        let folder = try makeTempDir()
        try touch(folder.appendingPathComponent(".DS_Store"))
        try touch(folder.appendingPathComponent("notes.txt"))
        try touch(folder.appendingPathComponent("Some Folder/inside.txt"))
        #expect(LibraryLocation.inspect(folder) == .hasOtherFiles(count: 2, bookFiles: 0))
    }

    /// P2
    @Test func inspectRejectsWhatIsNotAWritableFolder() throws {
        let parent = try makeTempDir()
        func isNotUsable(_ kind: FolderKind) -> Bool {
            if case .notUsable(let why) = kind { return !why.isEmpty }
            return false
        }
        #expect(isNotUsable(LibraryLocation.inspect(try touch(parent.appendingPathComponent("file.txt")))))
        #expect(isNotUsable(LibraryLocation.inspect(parent.appendingPathComponent("Missing"))))

        let locked = parent.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        #expect(isNotUsable(LibraryLocation.inspect(locked)))
    }

    // MARK: P3 Folders that must not become the library

    private func refusal(_ kind: FolderKind) -> String? {
        if case .notUsable(let why) = kind { return why }
        return nil
    }

    /// A pretend home folder with the standard folders in it, and the places made from it.
    private func pretendHome() throws -> (home: URL, places: ProtectedPlaces) {
        let home = try makeTempDir().appendingPathComponent("home", isDirectory: true)
        for name in ProtectedPlaces.standardFolderNames {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        return (home, ProtectedPlaces(home: home, systemFolders: [], isVolumeRoot: { _ in false }))
    }

    /// P3
    @Test func theHomeFolderIsRefused() throws {
        let (home, places) = try pretendHome()
        let why = try #require(refusal(LibraryLocation.inspect(home, places: places)))
        #expect(why.contains("home folder"))
        #expect(why.contains("Choose or create a folder just for your library"))
    }

    /// P3: the standard folders themselves are refused; a folder inside one is fine.
    @Test func theStandardFoldersAreRefusedButNotFoldersInsideThem() throws {
        let (home, places) = try pretendHome()
        for name in ["Desktop", "Documents", "Downloads", "Music", "Movies", "Pictures", "Library", "Public", "Applications"] {
            let why = try #require(refusal(LibraryLocation.inspect(home.appendingPathComponent(name), places: places)), "\(name)")
            #expect(why.contains("\"\(name)\""))
            #expect(why.contains("Choose or create a folder just for your library"))
        }
        let inside = home.appendingPathComponent("Documents/VoxCarrel Library", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        #expect(LibraryLocation.inspect(inside, places: places) == .empty)
    }

    /// P3: however the folder is spelled.
    @Test func aProtectedFolderIsKnownHoweverItIsSpelled() throws {
        let (home, places) = try pretendHome()
        let roundabout = home.appendingPathComponent("Documents/../Documents/", isDirectory: true)
        #expect(refusal(LibraryLocation.inspect(roundabout, places: places)) != nil)
    }

    /// P3
    @Test func systemFoldersAndVolumeRootsAreRefused() throws {
        let parent = try makeTempDir()
        let system = parent.appendingPathComponent("System", isDirectory: true)
        let volume = parent.appendingPathComponent("Disk", isDirectory: true)
        let fine = parent.appendingPathComponent("Fine", isDirectory: true)
        for folder in [system, volume, fine] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let volumePath = volume.resolvingSymlinksInPath().path
        let places = ProtectedPlaces(
            home: parent.appendingPathComponent("nobody"), systemFolders: [system],
            isVolumeRoot: { $0.resolvingSymlinksInPath().path == volumePath })
        #expect(refusal(LibraryLocation.inspect(system, places: places)) != nil)
        let why = try #require(refusal(LibraryLocation.inspect(volume, places: places)))
        #expect(why.contains("top level"))
        #expect(LibraryLocation.inspect(fine, places: places) == .empty)
    }

    /// P3: the real places are known too.
    @Test func theRealHomeAndDiskAreProtected() {
        let places = ProtectedPlaces.system
        #expect(places.refusal(for: FileManager.default.homeDirectoryForCurrentUser) != nil)
        #expect(places.refusal(for: URL(fileURLWithPath: "/")) != nil)
        #expect(places.refusal(for: URL(fileURLWithPath: "/Users")) != nil)
        #expect(places.refusal(for: URL(fileURLWithPath: "/Applications")) != nil)
        #expect(places.refusal(for: URL(fileURLWithPath: "/Volumes/Some Disk")) != nil)
        #expect(places.refusal(for: URL(fileURLWithPath: "/Volumes/Some Disk/Books")) == nil)
        #expect(
            places.refusal(for: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents"))
                != nil)
    }

    /// P3: a folder inside a library is part of that library.
    @Test func aFolderInsideALibraryIsRefused() throws {
        let library = try makeTempDir()
        _ = try LibraryStore(libraryRoot: library)
        let inner = library.appendingPathComponent("Ann Author/Atlas", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let why = try #require(refusal(LibraryLocation.inspect(inner)))
        #expect(why.contains("inside the VoxCarrel library"))
        #expect(why.contains(library.lastPathComponent))
    }

    /// P3: a folder with a library somewhere below it would swallow that library's books.
    @Test func aFolderThatHoldsALibraryIsRefused() throws {
        let parent = try makeTempDir()
        let library = parent.appendingPathComponent("Media/Books/Library", isDirectory: true)
        _ = try LibraryStore(libraryRoot: library)
        let why = try #require(refusal(LibraryLocation.inspect(parent)))
        #expect(why.contains("already holds a VoxCarrel library"))
        #expect(why.contains("Media/Books/Library"))
    }

    /// P3: hidden folders and packages are not looked inside, and the search is not deep.
    @Test func theSearchForALibraryBelowIsBounded() throws {
        let parent = try makeTempDir()
        _ = try LibraryStore(libraryRoot: parent.appendingPathComponent(".hidden/Library"))
        _ = try LibraryStore(libraryRoot: parent.appendingPathComponent("Thing.app/Library"))
        _ = try LibraryStore(libraryRoot: parent.appendingPathComponent("a/b/c/d/e/Library"))
        #expect(refusal(LibraryLocation.inspect(parent)) == nil)
    }

    /// P2: the book files a folder already holds are counted, wherever they are in it.
    @Test func inspectCountsTheBookFilesInside() throws {
        let folder = try makeTempDir()
        try touch(folder.appendingPathComponent("notes.txt"))
        try touch(folder.appendingPathComponent("One.epub"))
        try touch(folder.appendingPathComponent("Author/Book/Book.M4B"))
        try touch(folder.appendingPathComponent("Author/Book/cover.jpg"))
        try touch(folder.appendingPathComponent(".hidden/Hidden.pdf"))
        #expect(LibraryLocation.inspect(folder) == .hasOtherFiles(count: 3, bookFiles: 2))
    }

    /// P2: counting stops once there are more than the limit.
    @Test func countingBookFilesStopsAtTheLimit() throws {
        let folder = try makeTempDir()
        for number in 1...7 { try touch(folder.appendingPathComponent("Book \(number).pdf")) }
        #expect(LibraryLocation.bookFileCount(in: folder, limit: 5) == 6)
        #expect(LibraryLocation.bookFileCount(in: folder, limit: 1000) == 7)
    }
}
