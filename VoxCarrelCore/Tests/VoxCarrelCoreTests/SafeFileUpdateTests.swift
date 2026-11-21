import Foundation
import Testing
@testable import VoxCarrelCore

@Suite struct SafeFileUpdateTests {
    struct Boom: Error {}

    func leftovers(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix(".voxcarrel-") }
    }

    @Test func successfulUpdateReplacesTheFile() throws {
        let dir = try makeTempDir()
        let file = try touch(dir.appendingPathComponent("book.epub"), "old")

        try SafeFileUpdate.update(file) { copy in
            try Data("new".utf8).write(to: copy)
        } verify: { copy in
            let text = try String(contentsOf: copy, encoding: .utf8)
            #expect(text == "new")
        }

        #expect(try String(contentsOf: file, encoding: .utf8) == "new")
        #expect(try leftovers(in: dir).isEmpty)
    }

    @Test func failureWhileChangingLeavesTheOriginalUntouched() throws {
        let dir = try makeTempDir()
        let file = try touch(dir.appendingPathComponent("book.epub"), "old")

        #expect(throws: Boom.self) {
            try SafeFileUpdate.update(file) { copy in
                try Data("half-written".utf8).write(to: copy)
                throw Boom()
            } verify: { _ in }
        }

        #expect(try String(contentsOf: file, encoding: .utf8) == "old")
        #expect(try leftovers(in: dir).isEmpty)
    }

    @Test func failedVerificationLeavesTheOriginalUntouched() throws {
        let dir = try makeTempDir()
        let file = try touch(dir.appendingPathComponent("book.epub"), "old")

        #expect(throws: Boom.self) {
            try SafeFileUpdate.update(file) { copy in
                try Data("new".utf8).write(to: copy)
            } verify: { _ in throw Boom() }
        }

        #expect(try String(contentsOf: file, encoding: .utf8) == "old")
        #expect(try leftovers(in: dir).isEmpty)
    }

    @Test func theCopyKeepsTheFileExtension() throws {
        let dir = try makeTempDir()
        let file = try touch(dir.appendingPathComponent("Book.M4B"), "x")
        var seen: URL?

        try SafeFileUpdate.update(file) { copy in seen = copy } verify: { _ in }

        #expect(seen?.pathExtension == "M4B")
        #expect(seen?.deletingLastPathComponent().path == dir.path)
    }

    // MARK: Things that are not plain, writable files

    @Test func symlinksAreRefusedAndTheirTargetIsNeverTouched() throws {
        let dir = try makeTempDir()
        let store = dir.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let real = try touch(store.appendingPathComponent("real.epub"), "old")

        for (name, destination) in [("relative.epub", "store/real.epub"), ("absolute.epub", real.path)] {
            let link = dir.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
            var changeRan = false
            #expect(throws: MetadataIOError.notARegularFile(name)) {
                try SafeFileUpdate.update(link) { copy in
                    changeRan = true
                    try Data("new".utf8).write(to: copy)
                } verify: { _ in }
            }
            #expect(!changeRan, "\(name)")
            #expect(try String(contentsOf: real, encoding: .utf8) == "old", "\(name)")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == destination)
        }
        #expect(try leftovers(in: dir).isEmpty)
        #expect(try leftovers(in: store).isEmpty)
    }

    @Test func foldersAreRefused() throws {
        let dir = try makeTempDir()
        let folder = dir.appendingPathComponent("Book.epub", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try touch(folder.appendingPathComponent("mimetype"), "application/epub+zip")

        #expect(throws: MetadataIOError.notARegularFile("Book.epub")) {
            try SafeFileUpdate.update(folder) { _ in } verify: { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["mimetype"])
        #expect(try leftovers(in: dir).isEmpty)
    }

    @Test func readOnlyFilesAreLocked() throws {
        let dir = try makeTempDir()
        let file = try touch(dir.appendingPathComponent("book.epub"), "old")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        var changeRan = false

        #expect(throws: MetadataIOError.locked("book.epub")) {
            try SafeFileUpdate.update(file) { copy in
                changeRan = true
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path)
                try Data("new".utf8).write(to: copy)
            } verify: { _ in }
        }
        #expect(!changeRan)
        #expect(try String(contentsOf: file, encoding: .utf8) == "old")
        #expect(try leftovers(in: dir).isEmpty)
    }

    @Test func finderLockedFilesAreLockedAndLeaveNothingBehind() throws {
        let dir = try makeTempDir()
        let file = try touch(dir.appendingPathComponent("book.epub"), "old")
        #expect(chflags(file.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(file.path, 0) }

        #expect(throws: MetadataIOError.locked("book.epub")) {
            try SafeFileUpdate.update(file) { copy in try Data("new".utf8).write(to: copy) } verify: { _ in }
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "old")
        #expect(try leftovers(in: dir).isEmpty)
    }

    @Test func filesInAReadOnlyFolderAreLocked() throws {
        let dir = try makeTempDir()
        let file = try touch(dir.appendingPathComponent("book.epub"), "old")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        #expect(throws: MetadataIOError.locked("book.epub")) {
            try SafeFileUpdate.update(file) { copy in try Data("new".utf8).write(to: copy) } verify: { _ in }
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "old")
    }

    // MARK: Cleanup

    @Test func aCopyThatBecameImmutableIsStillCleanedUp() throws {
        let dir = try makeTempDir()
        let file = try touch(dir.appendingPathComponent("book.epub"), "old")

        #expect(throws: Boom.self) {
            try SafeFileUpdate.update(file) { copy in
                try Data("half-written".utf8).write(to: copy)
                #expect(chflags(copy.path, UInt32(UF_IMMUTABLE)) == 0)
                throw Boom()
            } verify: { _ in }
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "old")
        #expect(try leftovers(in: dir).isEmpty)
    }

    @Test func aCopyThatCannotBeRemovedIsReportedByPath() throws {
        let dir = try makeTempDir()
        let file = try touch(dir.appendingPathComponent("book.epub"), "old")
        var copyPath = ""
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        do {
            try SafeFileUpdate.update(file) { copy in
                copyPath = copy.path
                // Nothing can be deleted from a folder that is not writable.
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
                throw Boom()
            } verify: { _ in }
            Issue.record("update should have thrown")
        } catch {
            #expect(error as? MetadataIOError == .cleanupFailed(copyPath))
        }
        #expect(!copyPath.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "old")
    }
}
