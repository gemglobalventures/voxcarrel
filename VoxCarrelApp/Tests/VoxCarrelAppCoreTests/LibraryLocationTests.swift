import Foundation
import Testing
import VoxCarrelAppCore
import VoxCarrelCore
import VoxCarrelFixtures

@Suite struct LibraryLocationTests {
    /// Runs `body` with preferences of its own, removed afterwards. Never `.standard`.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "voxcarrel-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
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
        #expect(LibraryLocation.inspect(folder) == .hasOtherFiles(count: 2))
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
}
