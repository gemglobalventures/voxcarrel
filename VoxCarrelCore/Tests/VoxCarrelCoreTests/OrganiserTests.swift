import Foundation
import Testing
@testable import VoxCarrelCore

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

    // MARK: Review fixes

    @Test func undoCanBeRetriedAfterPartOfItWasAlreadyDone() throws {
        let root = try makeTempDir()
        let a = try touch(root.appendingPathComponent("in/a.mp3"), "A")
        let b = try touch(root.appendingPathComponent("in/b.mp3"), "B")
        let c = try touch(root.appendingPathComponent("in/c.epub"), "C")
        let organiser = Organiser()
        let moved = try organiser.transfer([
            PlannedMove(from: a, to: root.appendingPathComponent("lib/1.mp3")),
            PlannedMove(from: b, to: root.appendingPathComponent("lib/2.mp3")),
        ], mode: .move)
        let copied = try organiser.transfer(
            [PlannedMove(from: c, to: root.appendingPathComponent("lib/c.epub"))], mode: .copy)
        // An earlier undo got as far as putting b back and deleting the copy.
        try FileManager.default.moveItem(at: root.appendingPathComponent("lib/2.mp3"), to: b)
        try FileManager.default.removeItem(at: root.appendingPathComponent("lib/c.epub"))

        try organiser.undo(moved + copied)

        #expect(try read(a) == "A")
        #expect(try read(b) == "B")
        #expect(try read(c) == "C")
        #expect(tree(root.appendingPathComponent("lib")).isEmpty)
    }

    @Test func undoThatFailsUpFrontCanBeRetriedOnceTheObstacleIsGone() throws {
        let root = try makeTempDir()
        let a = try touch(root.appendingPathComponent("in/a.mp3"), "A")
        let b = try touch(root.appendingPathComponent("in/b.mp3"), "B")
        let records = try Organiser().transfer([
            PlannedMove(from: a, to: root.appendingPathComponent("lib/1.mp3")),
            PlannedMove(from: b, to: root.appendingPathComponent("lib/2.mp3")),
        ], mode: .move)
        try touch(a, "obstacle")

        #expect(throws: OrganiserError.destinationExists(a.path)) {
            try Organiser().undo(records)
        }
        try FileManager.default.removeItem(at: a)
        try Organiser().undo(records)

        #expect(try read(a) == "A")
        #expect(try read(b) == "B")
    }

    @Test func undoReportsAMissingFileThatIsInNeitherPlace() throws {
        let root = try makeTempDir()
        let a = try touch(root.appendingPathComponent("in/a.mp3"))
        let dst = root.appendingPathComponent("lib/1.mp3")
        let records = try Organiser().transfer([PlannedMove(from: a, to: dst)], mode: .move)
        try FileManager.default.removeItem(at: dst)

        #expect(throws: OrganiserError.sourceMissing(dst.path)) {
            try Organiser().undo(records)
        }
    }

    @Test func rollbackTriesEveryRecordAndReportsTheOnesItCouldNotReverse() throws {
        let root = try makeTempDir()
        let a = try touch(root.appendingPathComponent("in/a.mp3"), "A")
        let b = try touch(root.appendingPathComponent("in/b.mp3"), "B")
        let c = try touch(root.appendingPathComponent("in/c.mp3"), "C")
        let fm = FailingFileManager()
        // The third move fails; during rollback, b (reversed first) cannot go back.
        fm.failMovesTo = [root.appendingPathComponent("lib/3.mp3").path, b.path]
        let moves = [
            PlannedMove(from: a, to: root.appendingPathComponent("lib/1.mp3")),
            PlannedMove(from: b, to: root.appendingPathComponent("lib/2.mp3")),
            PlannedMove(from: c, to: root.appendingPathComponent("lib/3.mp3")),
        ]

        var thrown: OrganiserError?
        do {
            _ = try Organiser(fileManager: fm).transfer(moves, mode: .move)
        } catch {
            thrown = error as? OrganiserError
        }

        guard case .rollbackIncomplete(let cause, let outstanding) = thrown else {
            Issue.record("expected rollbackIncomplete, got \(String(describing: thrown))")
            return
        }
        #expect(!cause.isEmpty)
        #expect(outstanding == [
            MoveRecord(from: b.path, to: root.appendingPathComponent("lib/2.mp3").path, wasCopy: false)
        ])
        #expect(try read(a) == "A")  // reversed even though b, tried before it, failed
        #expect(exists(c))
        #expect(tree(root.appendingPathComponent("lib")) == ["2.mp3"])
        // The outstanding records finish the job once the cause is gone.
        try Organiser().undo(outstanding)
        #expect(try read(b) == "B")
    }

    @Test func filesCanSwapPlacesInOneBatchAndUndoSwapsThemBack() throws {
        let root = try makeTempDir()
        let one = try touch(root.appendingPathComponent("lib/01 - T.mp3"), "first")
        let two = try touch(root.appendingPathComponent("lib/02 - T.mp3"), "second")

        let records = try Organiser().transfer(
            [PlannedMove(from: one, to: two), PlannedMove(from: two, to: one)], mode: .move)

        #expect(try read(one) == "second")
        #expect(try read(two) == "first")
        #expect(records == [
            MoveRecord(from: one.path, to: two.path, wasCopy: false),
            MoveRecord(from: two.path, to: one.path, wasCopy: false),
        ])
        #expect(tree(root) == ["lib", "lib/01 - T.mp3", "lib/02 - T.mp3"])

        try Organiser().undo(records)

        #expect(try read(one) == "first")
        #expect(try read(two) == "second")
        #expect(tree(root) == ["lib", "lib/01 - T.mp3", "lib/02 - T.mp3"])
    }

    @Test func partsCanBeRenumberedIntoEachOthersNames() throws {
        let root = try makeTempDir()
        let one = try touch(root.appendingPathComponent("lib/01.mp3"), "1")
        let two = try touch(root.appendingPathComponent("lib/02.mp3"), "2")
        let three = root.appendingPathComponent("lib/03.mp3")

        let records = try Organiser().transfer(
            [PlannedMove(from: one, to: two), PlannedMove(from: two, to: three)], mode: .move)

        #expect(tree(root) == ["lib", "lib/02.mp3", "lib/03.mp3"])
        #expect(try read(two) == "1")
        #expect(try read(three) == "2")

        try Organiser().undo(records)

        #expect(tree(root) == ["lib", "lib/01.mp3", "lib/02.mp3"])
        #expect(try read(one) == "1")
        #expect(try read(two) == "2")
    }

    @Test func aFailedSwapIsRolledBackWithNothingLeftBehind() throws {
        let root = try makeTempDir()
        let one = try touch(root.appendingPathComponent("lib/01.mp3"), "1")
        let two = try touch(root.appendingPathComponent("lib/02.mp3"), "2")
        let other = try touch(root.appendingPathComponent("lib/other.epub"), "o")
        try touch(root.appendingPathComponent("lib/blocker"))
        let moves = [
            PlannedMove(from: one, to: two),
            PlannedMove(from: two, to: one),
            PlannedMove(from: other, to: root.appendingPathComponent("lib/blocker/other.epub")),
        ]
        let before = tree(root)

        #expect(throws: (any Error).self) {
            try Organiser().transfer(moves, mode: .move)
        }

        #expect(tree(root) == before)
        #expect(try read(one) == "1")
        #expect(try read(two) == "2")
    }

    @Test func copyingOntoAnotherSourceIsStillAClash() throws {
        let root = try makeTempDir()
        let one = try touch(root.appendingPathComponent("in/1.mp3"), "1")
        let two = try touch(root.appendingPathComponent("in/2.mp3"), "2")

        #expect(throws: OrganiserError.destinationExists(two.path)) {
            try Organiser().transfer(
                [PlannedMove(from: one, to: two), PlannedMove(from: two, to: one)], mode: .copy)
        }
        #expect(try read(one) == "1")
        #expect(try read(two) == "2")
    }

    @Test func aFailedTransferLeavesNoFoldersBehind() throws {
        let root = try makeTempDir()
        let a = try touch(root.appendingPathComponent("in/a.mp3"))
        let b = try touch(root.appendingPathComponent("in/b.mp3"))
        try touch(root.appendingPathComponent("lib/Author/blocker"))
        let moves = [
            PlannedMove(from: a, to: root.appendingPathComponent("lib/Author/Title/Deep/1.mp3")),
            PlannedMove(from: b, to: root.appendingPathComponent("lib/Author/blocker/2.mp3")),
        ]
        let before = tree(root)

        #expect(throws: (any Error).self) {
            try Organiser().transfer(moves, mode: .move)
        }

        #expect(tree(root) == before)
    }

    @Test func copyModeFailureRemovesTheCopiesAlreadyMade() throws {
        let root = try makeTempDir()
        let a = try touch(root.appendingPathComponent("in/a.mp3"))
        let b = try touch(root.appendingPathComponent("in/b.mp3"))
        try touch(root.appendingPathComponent("lib/blocker"))
        let moves = [
            PlannedMove(from: a, to: root.appendingPathComponent("lib/ok/1.mp3")),
            PlannedMove(from: b, to: root.appendingPathComponent("lib/blocker/2.mp3")),
        ]
        let before = tree(root)

        #expect(throws: (any Error).self) {
            try Organiser().transfer(moves, mode: .copy)
        }

        #expect(tree(root) == before)
    }

    @Test func copyNeverOverwritesAnExistingFile() throws {
        let root = try makeTempDir()
        let src = try touch(root.appendingPathComponent("in/a.epub"), "new")
        let dst = try touch(root.appendingPathComponent("lib/a.epub"), "old")

        #expect(throws: OrganiserError.destinationExists(dst.path)) {
            try Organiser().transfer([PlannedMove(from: src, to: dst)], mode: .copy)
        }
        #expect(try read(src) == "new")
        #expect(try read(dst) == "old")
    }

    @Test func aHalfWrittenDestinationIsRemovedWhenACopyFails() throws {
        let root = try makeTempDir()
        let src = try touch(root.appendingPathComponent("in/a.m4b"), "whole file")
        let dst = root.appendingPathComponent("lib/A/T/T.m4b")
        let fm = FailingFileManager()
        fm.partialCopiesTo = [dst.path]

        #expect(throws: (any Error).self) {
            try Organiser(fileManager: fm).transfer([PlannedMove(from: src, to: dst)], mode: .copy)
        }

        #expect(try read(src) == "whole file")
        #expect(tree(root) == ["in", "in/a.m4b"])
    }

    @Test func undoingACopyRefusesToDeleteAnythingButAPlainFile() throws {
        let root = try makeTempDir()
        let src = try touch(root.appendingPathComponent("in/a.epub"))
        let dst = root.appendingPathComponent("lib/a.epub")
        let records = try Organiser().transfer([PlannedMove(from: src, to: dst)], mode: .copy)
        try FileManager.default.removeItem(at: dst)
        let keep = try touch(dst.appendingPathComponent("user/important.txt"))

        #expect(throws: OrganiserError.notARegularFile(dst.path)) {
            try Organiser().undo(records)
        }
        #expect(exists(keep))
    }

    @Test func pruningKeepsAFolderThatStillHoldsOtherFiles() throws {
        let root = try makeTempDir()
        let lib = root.appendingPathComponent("lib", isDirectory: true)
        let src = try touch(lib.appendingPathComponent("Author/One/One.epub"))
        let sibling = try touch(lib.appendingPathComponent("Author/Two/Two.epub"))
        let leftover = try touch(lib.appendingPathComponent("Author/One/cover.jpg"))
        let second = try touch(lib.appendingPathComponent("Author/Three/Three.epub"))

        _ = try Organiser().transfer([
            PlannedMove(from: src, to: lib.appendingPathComponent("New/One/One.epub")),
            PlannedMove(from: second, to: lib.appendingPathComponent("New/Three/Three.epub")),
        ], mode: .move, pruneRoot: lib)

        #expect(exists(leftover))  // folder with another file is kept
        #expect(exists(sibling))  // parent with another book is kept
        #expect(!exists(lib.appendingPathComponent("Author/Three")))  // emptied folder goes
    }

    @Test func pruningStopsAtARootWhoseNameIsOnlyAPrefix() throws {
        let root = try makeTempDir()
        let lib = root.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let src = try touch(root.appendingPathComponent("lib2/Old/a.epub"))

        _ = try Organiser().transfer(
            [PlannedMove(from: src, to: lib.appendingPathComponent("a.epub"))],
            mode: .move, pruneRoot: lib)

        #expect(exists(root.appendingPathComponent("lib2/Old")))
    }

    // A copy is only deleted while the original it was made from still exists.
    @Test func undoingACopyWhoseOriginalIsGoneMovesTheCopyBack() throws {
        let tmp = try makeTempDir()
        let original = try touch(tmp.appendingPathComponent("in/sub/a.txt"), "only copy")
        let kept = try touch(tmp.appendingPathComponent("in/b.txt"), "still here")
        let lib = tmp.appendingPathComponent("lib", isDirectory: true)
        let records = try Organiser().transfer([
            PlannedMove(from: original, to: lib.appendingPathComponent("A/a.txt")),
            PlannedMove(from: kept, to: lib.appendingPathComponent("B/b.txt")),
        ], mode: .copy)
        try FileManager.default.removeItem(at: tmp.appendingPathComponent("in/sub"))

        try Organiser().undo(records, pruneRoot: lib)

        // The copy whose original is gone went back to where the original was...
        #expect(try read(original) == "only copy")
        // ...the other copy was deleted, its original untouched.
        #expect(try read(kept) == "still here")
        #expect(tree(lib).isEmpty)
        // Doing it again changes nothing.
        try Organiser().undo(records, pruneRoot: lib)
        #expect(try read(original) == "only copy")
    }

    // A copy the organiser makes can be written and removed even when the original is locked.
    @Test func copyClearsTheUserImmutableFlagOnTheCopyOnly() throws {
        let tmp = try makeTempDir()
        let original = try touch(tmp.appendingPathComponent("in/a.txt"), "locked")
        #expect(chflags(original.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(original.path, 0) }
        let copy = tmp.appendingPathComponent("lib/a.txt")

        let records = try Organiser().transfer([PlannedMove(from: original, to: copy)], mode: .copy)

        #expect(try copy.resourceValues(forKeys: [.isUserImmutableKey]).isUserImmutable == false)
        #expect(try original.resourceValues(forKeys: [.isUserImmutableKey]).isUserImmutable == true)
        try Organiser().undo(records)
        #expect(!exists(copy))
        #expect(try read(original) == "locked")
    }

    // The check finds what would stop an undo, and a blocked undo changes nothing at all.
    @Test func undoThatCannotFinishChangesNothing() throws {
        let tmp = try makeTempDir()
        let a = try touch(tmp.appendingPathComponent("in/a.txt"), "a")
        let b = try touch(tmp.appendingPathComponent("in/b.txt"), "b")
        let movedTo = tmp.appendingPathComponent("lib/a.txt")
        let copiedTo = tmp.appendingPathComponent("lib/b.txt")
        let moved = try Organiser().transfer([PlannedMove(from: a, to: movedTo)], mode: .move)
        let copied = try Organiser().transfer([PlannedMove(from: b, to: copiedTo)], mode: .copy)
        let records = moved + copied
        try Organiser().checkUndo(records)  // nothing in the way yet

        // The copy becomes undeletable.
        #expect(chflags(copiedTo.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(copiedTo.path, 0) }
        #expect(throws: OrganiserError.cannotBeChanged(copiedTo.path)) { try Organiser().checkUndo(records) }
        #expect(throws: OrganiserError.cannotBeChanged(copiedTo.path)) { try Organiser().undo(records) }
        #expect(try read(movedTo) == "a")
        #expect(!exists(a))
        #expect(try read(copiedTo) == "b")

        // A moved file that is itself locked is found too.
        _ = chflags(copiedTo.path, 0)
        #expect(chflags(movedTo.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(movedTo.path, 0) }
        #expect(throws: OrganiserError.cannotBeChanged(movedTo.path)) { try Organiser().undo(records) }
        #expect(try read(copiedTo) == "b")

        _ = chflags(movedTo.path, 0)
        try Organiser().undo(records)
        #expect(try read(a) == "a")
        #expect(!exists(copiedTo))
    }

    // A failure after the check (here: a move that the file system refuses) puts back what
    // this attempt had already done, copies included.
    @Test func undoThatFailsPartWayPutsEverythingBack() throws {
        let tmp = try makeTempDir()
        let a = try touch(tmp.appendingPathComponent("in/a.txt"), "a")
        let b = try touch(tmp.appendingPathComponent("in/b.txt"), "b")
        let movedTo = tmp.appendingPathComponent("lib/a.txt")
        let copiedTo = tmp.appendingPathComponent("lib/b.txt")
        let records = try Organiser().transfer([PlannedMove(from: a, to: movedTo)], mode: .move)
            + Organiser().transfer([PlannedMove(from: b, to: copiedTo)], mode: .copy)
        let failing = FailingFileManager()
        failing.failMovesTo = [a.path]

        #expect(throws: (any Error).self) { try Organiser(fileManager: failing).undo(records) }

        #expect(try read(movedTo) == "a")
        #expect(!exists(a))
        #expect(try read(copiedTo) == "b")
        #expect(tree(tmp.appendingPathComponent("lib")) == ["a.txt", "b.txt"])
    }
}
