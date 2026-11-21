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
}
