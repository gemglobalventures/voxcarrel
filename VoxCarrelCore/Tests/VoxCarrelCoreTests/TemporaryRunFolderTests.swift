import Foundation
import Testing

@testable import VoxCarrelFixtures

/// The folder a run of the tests keeps everything it makes in, and what becomes of the
/// folders of runs that ended without removing theirs.
@Suite struct TemporaryRunFolderTests {
    /// The id of a process that has ended.
    private func endedProcess() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    @Test func everythingMadeIsInsideThisRunsOwnFolder() throws {
        let run = TemporaryRunFolder.url
        #expect(run.lastPathComponent.hasPrefix("voxcarrel-run-\(ProcessInfo.processInfo.processIdentifier)-"))
        let made = try makeTempDir()
        #expect(made.deletingLastPathComponent().path == run.path)
        #expect(TemporaryRunFolder.processOfRun(named: run.lastPathComponent) == ProcessInfo.processInfo.processIdentifier)
    }

    /// A run that crashed or was stopped never removed its folder: the next run does.
    @Test func theFolderOfARunThatHasEndedIsRemovedAndNothingElseIs() throws {
        let fm = FileManager.default
        let parent = try makeTempDir()
        func entry(_ name: String) -> URL { parent.appendingPathComponent(name) }
        let ended = try endedProcess()

        let stale = entry("voxcarrel-run-\(ended)-\(UUID().uuidString)")
        try fm.createDirectory(at: stale.appendingPathComponent("voxcarrel-x/Library"), withIntermediateDirectories: true)
        try Data("left".utf8).write(to: stale.appendingPathComponent("voxcarrel-x/Library/book.m4b"))
        // A run that is still going: this one.
        let live = entry("voxcarrel-run-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try fm.createDirectory(at: live, withIntermediateDirectories: true)
        // Names that are not a run's.
        let others = [
            "voxcarrel-run-\(ended)", "voxcarrel-run-\(ended)-not-a-uuid", "voxcarrel-run--\(UUID().uuidString)",
            "voxcarrel-run-x\(ended)-\(UUID().uuidString)", "voxcarrel-\(UUID().uuidString)",
            "other-run-\(ended)-\(UUID().uuidString)", "voxcarrel-run-0-\(UUID().uuidString)",
            "voxcarrel-run-1-\(UUID().uuidString)", "voxcarrel-run--1-\(UUID().uuidString)",
        ]
        for name in others { try fm.createDirectory(at: entry(name), withIntermediateDirectories: true) }
        // A file, and a link, with the name of an ended run's folder: neither is one.
        let file = entry("voxcarrel-run-\(ended)-\(UUID().uuidString)")
        try Data("keep".utf8).write(to: file)
        let target = try makeTempDir()
        try Data("keep".utf8).write(to: target.appendingPathComponent("file"))
        let link = entry("voxcarrel-run-\(ended)-\(UUID().uuidString)")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        TemporaryRunFolder.removeFoldersOfEndedRuns(in: parent)

        #expect(!fm.fileExists(atPath: stale.path))
        #expect(fm.fileExists(atPath: live.path))
        for name in others { #expect(fm.fileExists(atPath: entry(name).path), "\(name)") }
        #expect(fm.fileExists(atPath: file.path))
        #expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil)
        #expect(fm.fileExists(atPath: target.appendingPathComponent("file").path))
    }

    @Test func aParentThatIsNotThereIsNoTrouble() throws {
        TemporaryRunFolder.removeFoldersOfEndedRuns(in: try makeTempDir().appendingPathComponent("nowhere"))
    }
}
