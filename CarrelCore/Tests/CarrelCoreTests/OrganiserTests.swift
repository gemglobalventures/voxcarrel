import Foundation
import Testing
@testable import CarrelCore

@Suite struct OrganiserTests {
    @Test func planPutsAudioEbookAndExtrasInOneBookFolder() throws {
        let library = URL(fileURLWithPath: "/Library", isDirectory: true)
        var m = BookMetadata(title: "Dune", authors: ["Frank Herbert"])
        m.series = "Dune"
        m.seriesNumber = "1"
        let files = [
            CandidateFile(url: URL(fileURLWithPath: "/in/a.MP3"), role: .audio),
            CandidateFile(url: URL(fileURLWithPath: "/in/b.mp3"), role: .audio),
            CandidateFile(url: URL(fileURLWithPath: "/in/dune.epub"), role: .ebook),
            CandidateFile(url: URL(fileURLWithPath: "/in/Maps.pdf"), role: .extra),
        ]

        let moves = try #require(Organiser.plan(files: files, metadata: m, libraryRoot: library))

        #expect(moves.map(\.from) == files.map(\.url))
        #expect(moves.map(\.to.path) == [
            "/Library/Frank Herbert/Dune/1 - Dune/01 - Dune.mp3",
            "/Library/Frank Herbert/Dune/1 - Dune/02 - Dune.mp3",
            "/Library/Frank Herbert/Dune/1 - Dune/Dune.epub",
            "/Library/Frank Herbert/Dune/1 - Dune/Extras/Maps.pdf",
        ])
    }

    @Test func planIsNilWhenBookCannotBeFiled() {
        let moves = Organiser.plan(
            files: [CandidateFile(url: URL(fileURLWithPath: "/in/a.epub"), role: .ebook)],
            metadata: BookMetadata(title: "No Author"),
            libraryRoot: URL(fileURLWithPath: "/Library"))
        #expect(moves == nil)
    }

    @Test func moveTransfersFilesAndRecordsThem() throws {
        let root = try makeTempDir()
        let src = try touch(root.appendingPathComponent("in/a.m4b"), "audio")
        let dst = root.appendingPathComponent("lib/A/T/T.m4b")

        let records = try Organiser().transfer([PlannedMove(from: src, to: dst)], mode: .move)

        #expect(!exists(src))
        #expect(try String(contentsOf: dst, encoding: .utf8) == "audio")
        #expect(records == [MoveRecord(from: src.path, to: dst.path, wasCopy: false)])
    }

    @Test func copyLeavesTheOriginal() throws {
        let root = try makeTempDir()
        let src = try touch(root.appendingPathComponent("in/a.epub"))
        let dst = root.appendingPathComponent("lib/a.epub")

        let records = try Organiser().transfer([PlannedMove(from: src, to: dst)], mode: .copy)

        #expect(exists(src))
        #expect(exists(dst))
        #expect(records.first?.wasCopy == true)
    }

    @Test func neverOverwritesAnExistingFile() throws {
        let root = try makeTempDir()
        let src = try touch(root.appendingPathComponent("in/a.epub"), "new")
        let dst = try touch(root.appendingPathComponent("lib/a.epub"), "old")

        #expect(throws: OrganiserError.destinationExists(dst.path)) {
            try Organiser().transfer([PlannedMove(from: src, to: dst)], mode: .move)
        }
        #expect(exists(src))
        #expect(try String(contentsOf: dst, encoding: .utf8) == "old")
    }

    @Test func twoFilesMayNotShareADestination() throws {
        let root = try makeTempDir()
        let a = try touch(root.appendingPathComponent("in/a.epub"))
        let b = try touch(root.appendingPathComponent("in/b.epub"))
        let dst = root.appendingPathComponent("lib/same.epub")

        #expect(throws: OrganiserError.destinationExists(dst.path)) {
            try Organiser().transfer(
                [PlannedMove(from: a, to: dst), PlannedMove(from: b, to: dst)], mode: .move)
        }
        #expect(exists(a))
        #expect(exists(b))
    }

    @Test func missingSourceIsReportedBeforeAnythingMoves() throws {
        let root = try makeTempDir()
        let a = try touch(root.appendingPathComponent("in/a.mp3"))
        let ghost = root.appendingPathComponent("in/ghost.mp3")

        #expect(throws: OrganiserError.sourceMissing(ghost.path)) {
            try Organiser().transfer([
                PlannedMove(from: a, to: root.appendingPathComponent("lib/1.mp3")),
                PlannedMove(from: ghost, to: root.appendingPathComponent("lib/2.mp3")),
            ], mode: .move)
        }
        #expect(exists(a))
    }

    @Test func failureMidBookRollsBackCompletedMoves() throws {
        let root = try makeTempDir()
        let a = try touch(root.appendingPathComponent("in/a.mp3"))
        let b = try touch(root.appendingPathComponent("in/b.mp3"))
        // A regular file where a folder is needed makes the second move fail.
        try touch(root.appendingPathComponent("lib/blocker"))
        let moves = [
            PlannedMove(from: a, to: root.appendingPathComponent("lib/ok/1.mp3")),
            PlannedMove(from: b, to: root.appendingPathComponent("lib/blocker/2.mp3")),
        ]

        #expect(throws: (any Error).self) {
            try Organiser().transfer(moves, mode: .move)
        }
        #expect(exists(a))
        #expect(exists(b))
        #expect(!exists(root.appendingPathComponent("lib/ok/1.mp3")))
    }

    @Test func movesToTheSamePathAreSkipped() throws {
        let root = try makeTempDir()
        let a = try touch(root.appendingPathComponent("lib/a.epub"))

        let records = try Organiser().transfer([PlannedMove(from: a, to: a)], mode: .move)

        #expect(records.isEmpty)
        #expect(exists(a))
    }

    @Test func emptySourceFoldersInsideThePruneRootAreRemoved() throws {
        let root = try makeTempDir()
        let lib = root.appendingPathComponent("lib", isDirectory: true)
        let src = try touch(lib.appendingPathComponent("Old Author/Title/Extras/Map.pdf"))
        try touch(lib.appendingPathComponent("Old Author/Title/.DS_Store"))
        let dst = lib.appendingPathComponent("New Author/Title/Extras/Map.pdf")

        _ = try Organiser().transfer([PlannedMove(from: src, to: dst)], mode: .move, pruneRoot: lib)

        #expect(exists(dst))
        #expect(!exists(lib.appendingPathComponent("Old Author")))
        #expect(exists(lib))
    }

    @Test func foldersOutsideThePruneRootAreLeftAlone() throws {
        let root = try makeTempDir()
        let lib = root.appendingPathComponent("lib", isDirectory: true)
        let src = try touch(root.appendingPathComponent("in/a.epub"))

        _ = try Organiser().transfer(
            [PlannedMove(from: src, to: lib.appendingPathComponent("a.epub"))],
            mode: .move, pruneRoot: lib)

        #expect(exists(root.appendingPathComponent("in")))
    }

    @Test func undoPutsMovedFilesBackAndDeletesCopies() throws {
        let root = try makeTempDir()
        let lib = root.appendingPathComponent("lib", isDirectory: true)
        let moved = try touch(root.appendingPathComponent("in/moved.epub"))
        let copied = try touch(root.appendingPathComponent("in/copied.epub"))
        let organiser = Organiser()
        let r1 = try organiser.transfer(
            [PlannedMove(from: moved, to: lib.appendingPathComponent("A/moved.epub"))], mode: .move)
        let r2 = try organiser.transfer(
            [PlannedMove(from: copied, to: lib.appendingPathComponent("B/copied.epub"))], mode: .copy)

        try organiser.undo(r1 + r2, pruneRoot: lib)

        #expect(exists(moved))
        #expect(exists(copied))
        #expect(!exists(lib.appendingPathComponent("A")))
        #expect(!exists(lib.appendingPathComponent("B")))
    }

    @Test func undoRefusesToOverwriteAFileAtTheOriginalLocation() throws {
        let root = try makeTempDir()
        let src = try touch(root.appendingPathComponent("in/a.epub"))
        let dst = root.appendingPathComponent("lib/a.epub")
        let records = try Organiser().transfer([PlannedMove(from: src, to: dst)], mode: .move)
        try touch(src, "someone put a new file here")

        #expect(throws: OrganiserError.destinationExists(src.path)) {
            try Organiser().undo(records)
        }
        #expect(exists(dst))
    }
}
