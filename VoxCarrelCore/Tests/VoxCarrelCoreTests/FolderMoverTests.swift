import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// Moving whole folders inside a library, all or nothing (folder layout plan, FP33–FP36).
@Suite struct FolderMoverTests {
    /// A folder standing in for a library, with a mover on it.
    final class Ground {
        let root: URL
        var mover: FolderMover
        /// The renames asked for, in order.
        var renames: [(from: String, to: String)] = []

        init() throws {
            root = try makeTempDir().appendingPathComponent("Library", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(".voxcarrel"), withIntermediateDirectories: true)
            mover = FolderMover(
                root: root, parking: root.appendingPathComponent(".voxcarrel/moving", isDirectory: true),
                naming: VolumeNaming.of(root))
        }

        func url(_ path: String) -> URL { root.appendingPathComponent(path) }

        /// A folder holding one file named after it, and any others asked for.
        func make(_ folder: String, extra files: [String] = []) throws {
            for name in ["own.txt"] + files {
                let file = url(folder).appendingPathComponent(name)
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("\(folder)|\(name)".utf8).write(to: file)
            }
        }

        func put(_ path: String, _ text: String = "x") throws {
            try FileManager.default.createDirectory(
                at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url(path))
        }

        func moves(_ pairs: [(String, String)]) -> [PlannedMove] {
            pairs.map { PlannedMove(from: url($0.0), to: url($0.1)) }
        }

        /// Every path in the library, with the bytes of every file.
        func contents() -> [String: String] {
            var result: [String: String] = [:]
            for path in tree(root) {
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url(path).path, isDirectory: &isDirectory)
                result[path] = isDirectory.boolValue ? "<folder>" : (try? read(url(path))) ?? "<unreadable>"
            }
            return result
        }

        /// The names in a folder exactly as the disk spells them.
        func names(in folder: String) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: url(folder).path)) ?? []).sorted()
        }

        /// Makes the rename numbered `number` (from 1) fail; the others are made.
        func failRename(_ number: Int) {
            var count = 0
            mover.rename = { from, to in
                count += 1
                if count == number { throw Boom() }
                try FolderMover.renameWithoutReplacing(from, to)
            }
        }

        /// Makes every rename to one of these paths fail.
        func failRenames(to paths: Set<String>) {
            let root = root
            mover.rename = { from, to in
                if paths.contains(where: { root.appendingPathComponent($0).path == to.path }) { throw Boom() }
                try FolderMover.renameWithoutReplacing(from, to)
            }
        }
    }

    static var volumeIgnoresCase: Bool {
        (try? Ground())?.mover.naming.caseSensitive == false
    }

    private func file(_ g: Ground, _ path: String) throws -> String {
        try read(g.url(path))
    }

    // MARK: FP33 A folder moves whole, by a rename

    @Test func fp33_aFolderMovesWholeWithEverythingInIt() throws {
        let g = try Ground()
        try g.make("Ann/Book", extra: ["Extras/map.pdf", ".hidden", "notes.txt"])
        let before = try FileManager.default.attributesOfItem(atPath: g.url("Ann/Book/own.txt").path)

        try g.mover.move(g.moves([("Ann/Book", "Audio/Ann/Book")]))

        #expect(tree(g.root).filter { !$0.hasPrefix(".voxcarrel") } == [
            "Audio", "Audio/Ann", "Audio/Ann/Book", "Audio/Ann/Book/.hidden", "Audio/Ann/Book/Extras",
            "Audio/Ann/Book/Extras/map.pdf", "Audio/Ann/Book/notes.txt", "Audio/Ann/Book/own.txt",
        ])
        #expect(try file(g, "Audio/Ann/Book/Extras/map.pdf") == "Ann/Book|Extras/map.pdf")
        // The same file, not a copy of it.
        let after = try FileManager.default.attributesOfItem(atPath: g.url("Audio/Ann/Book/own.txt").path)
        #expect(after[.systemFileNumber] as? Int == before[.systemFileNumber] as? Int)
        #expect(after[.modificationDate] as? Date == before[.modificationDate] as? Date)
        // Nothing is left of the parking place.
        #expect(tree(g.root.appendingPathComponent(".voxcarrel")).isEmpty)
    }

    @Test func fp33_noMovesDoNothing() throws {
        let g = try Ground()
        try g.make("Ann/Book")
        let before = g.contents()
        try g.mover.move([])
        #expect(g.contents() == before)
    }

    @Test func fp33_theRenameRefusesAnythingAtTheDestinationEvenAnEmptyFolder() throws {
        let g = try Ground()
        try g.make("a")
        try FileManager.default.createDirectory(at: g.url("empty"), withIntermediateDirectories: true)
        try g.put("file")
        for taken in ["empty", "file"] {
            #expect(throws: (any Error).self) { try FolderMover.renameWithoutReplacing(g.url("a"), g.url(taken)) }
        }
        #expect(try file(g, "a/own.txt") == "a|own.txt")
        #expect(g.names(in: "empty").isEmpty)
        #expect(try file(g, "file") == "x")
        try FolderMover.renameWithoutReplacing(g.url("a"), g.url("b"))
        #expect(try file(g, "b/own.txt") == "a|own.txt")
    }

    // MARK: FP34 Moves that depend on each other

    @Test func fp34_twoFoldersSwap() throws {
        let g = try Ground()
        try g.make("X/One")
        try g.make("X/Two")
        try g.mover.move(g.moves([("X/One", "X/Two"), ("X/Two", "X/One")]))
        #expect(try file(g, "X/Two/own.txt") == "X/One|own.txt")
        #expect(try file(g, "X/One/own.txt") == "X/Two|own.txt")
        #expect(tree(g.root).filter { !$0.hasPrefix(".voxcarrel") } == ["X", "X/One", "X/One/own.txt", "X/Two", "X/Two/own.txt"])
        #expect(tree(g.root.appendingPathComponent(".voxcarrel")).isEmpty)
    }

    @Test func fp34_threeFoldersGoRound() throws {
        let g = try Ground()
        for name in ["a", "b", "c"] { try g.make("X/\(name)") }
        try g.mover.move(g.moves([("X/a", "X/b"), ("X/b", "X/c"), ("X/c", "X/a")]))
        #expect(try file(g, "X/b/own.txt") == "X/a|own.txt")
        #expect(try file(g, "X/c/own.txt") == "X/b|own.txt")
        #expect(try file(g, "X/a/own.txt") == "X/c|own.txt")
        #expect(tree(g.root.appendingPathComponent(".voxcarrel")).isEmpty)
    }

    @Test func fp34_aFolderMovesToWhereAnotherIsWhileThatOneMovesAway() throws {
        // In either order of asking.
        for flipped in [false, true] {
            let g = try Ground()
            try g.make("X/a")
            try g.make("X/b")
            let pairs = [("X/a", "X/b"), ("X/b", "Y/c")]
            try g.mover.move(g.moves(flipped ? pairs.reversed() : pairs))
            #expect(try file(g, "X/b/own.txt") == "X/a|own.txt")
            #expect(try file(g, "Y/c/own.txt") == "X/b|own.txt")
            #expect(!FileManager.default.fileExists(atPath: g.url("X/a").path))
        }
    }

    @Test(.enabled(if: FolderMoverTests.volumeIgnoresCase))
    func fp34_aFolderIsRenamedInCapitalisationOnly() throws {
        let g = try Ground()
        try g.make("X/dune")
        try g.mover.move(g.moves([("X/dune", "X/Dune")]))
        #expect(g.names(in: "X") == ["Dune"])
        #expect(try file(g, "X/Dune/own.txt") == "X/dune|own.txt")
        #expect(tree(g.root.appendingPathComponent(".voxcarrel")).isEmpty)
    }

    @Test(.enabled(if: FolderMoverTests.volumeIgnoresCase))
    func fp34_aFolderTakesANameAnotherLeavesThatDiffersOnlyInCapitalisation() throws {
        let g = try Ground()
        try g.make("X/dune")
        try g.make("X/Other")
        try g.mover.move(g.moves([("X/dune", "Y/Elsewhere"), ("X/Other", "X/Dune")]))
        #expect(g.names(in: "X") == ["Dune"])
        #expect(try file(g, "X/Dune/own.txt") == "X/Other|own.txt")
        #expect(try file(g, "Y/Elsewhere/own.txt") == "X/dune|own.txt")
    }

    @Test func fp34_aFolderMovesDeeperAlongItsOwnPath() throws {
        let g = try Ground()
        try g.make("Frank/Dune", extra: ["Extras/map.pdf"])
        // Into a folder of its own name, and a second one through a new level.
        try g.make("Frank/Emperor")
        try g.mover.move(g.moves([("Frank/Dune", "Frank/Dune/1 - Dune"), ("Frank/Emperor", "Frank/Dune/4 - Emperor")]))
        #expect(tree(g.root).filter { !$0.hasPrefix(".voxcarrel") } == [
            "Frank", "Frank/Dune", "Frank/Dune/1 - Dune", "Frank/Dune/1 - Dune/Extras",
            "Frank/Dune/1 - Dune/Extras/map.pdf", "Frank/Dune/1 - Dune/own.txt", "Frank/Dune/4 - Emperor",
            "Frank/Dune/4 - Emperor/own.txt",
        ])
        #expect(try file(g, "Frank/Dune/1 - Dune/own.txt") == "Frank/Dune|own.txt")
    }

    @Test func fp34_aFolderMovesShallowerAlongItsOwnPath() throws {
        let g = try Ground()
        try g.make("Frank/Dune/1 - Dune")
        try g.make("Frank/Dune/2 - Messiah")
        try g.put("Frank/Dune/.DS_Store")
        // The first takes the place of the folder both were in; that folder is left
        // empty by the moves, and only then is its name free.
        try g.mover.move(g.moves([("Frank/Dune/1 - Dune", "Frank/Dune"), ("Frank/Dune/2 - Messiah", "Frank/Messiah")]))
        #expect(tree(g.root).filter { !$0.hasPrefix(".voxcarrel") } == [
            "Frank", "Frank/Dune", "Frank/Dune/own.txt", "Frank/Messiah", "Frank/Messiah/own.txt",
        ])
        #expect(try file(g, "Frank/Dune/own.txt") == "Frank/Dune/1 - Dune|own.txt")
    }

    @Test func fp34_aFolderInsideAnotherThatMovesIsTakenOutFirst() throws {
        let g = try Ground()
        try g.make("Ann/Outer")
        try g.make("Ann/Outer/sub/Inner")
        try g.mover.move(g.moves([("Ann/Outer", "Z/Outer"), ("Ann/Outer/sub/Inner", "Z/Inner")]))
        #expect(tree(g.root).filter { !$0.hasPrefix(".voxcarrel") } == [
            "Z", "Z/Inner", "Z/Inner/own.txt", "Z/Outer", "Z/Outer/own.txt",
        ])
        #expect(try file(g, "Z/Inner/own.txt") == "Ann/Outer/sub/Inner|own.txt")
    }

    @Test func fp34_everyShapeGoesBackTheWayItCame() throws {
        let shapes: [[(String, String)]] = [
            [("X/One", "X/Two"), ("X/Two", "X/One")],
            [("X/a", "X/b"), ("X/b", "X/c"), ("X/c", "X/a")],
            [("Frank/Dune", "Frank/Dune/1 - Dune"), ("Frank/Emperor", "Frank/Dune/4 - Emperor")],
            [("Frank/Dune/1 - Dune", "Frank/Dune"), ("Frank/Dune/2 - Messiah", "Frank/Messiah")],
            [("Ann/Outer", "Z/Outer"), ("Ann/Outer/sub/Inner", "Z/Inner")],
            [("Ann/Book", "Audio/Ann/Book"), ("Bob/Book", "Audio/Bob/Book")],
        ]
        for shape in shapes {
            let g = try Ground()
            for (from, _) in shape { try g.make(from, extra: ["Extras/x.pdf"]) }
            let before = g.contents()
            try g.mover.move(g.moves(shape))
            #expect(g.contents() != before)
            try g.mover.move(g.moves(shape.reversed().map { ($0.1, $0.0) }))
            #expect(g.contents() == before, "\(shape)")
        }
    }

    // MARK: FP35 All or nothing, and nothing is replaced

    @Test func fp35_aDestinationThatExistsStopsEverythingBeforeAnythingMoves() throws {
        for taken in ["folder", "empty folder", "file"] {
            let g = try Ground()
            try g.make("Ann/One")
            try g.make("Ann/Two")
            switch taken {
            case "folder": try g.make("Z/Two")
            case "empty folder": try FileManager.default.createDirectory(at: g.url("Z/Two"), withIntermediateDirectories: true)
            default: try g.put("Z/Two", "a file")
            }
            let before = g.contents()
            g.failRename(0)
            let moves = g.moves([("Ann/One", "Z/One"), ("Ann/Two", "Z/Two")])
            #expect(g.mover.blockers(for: moves) == [1: .destinationExists])
            #expect { try g.mover.move(moves) } throws: { error in
                guard case FolderMoveError.failed(let index, _) = error else { return false }
                return index == 1
            }
            #expect(g.contents() == before, "\(taken)")
        }
    }

    @Test func fp35_aSourceThatIsMissingStopsEverythingBeforeAnythingMoves() throws {
        let g = try Ground()
        try g.make("Ann/One")
        try g.put("Ann/NotAFolder")
        let before = g.contents()
        for missing in ["Ann/Gone", "Ann/NotAFolder"] {
            let moves = g.moves([("Ann/One", "Z/One"), (missing, "Z/Two")])
            #expect(g.mover.blockers(for: moves) == [1: .sourceMissing])
            #expect(throws: FolderMoveError.self) { try g.mover.move(moves) }
            #expect(g.contents() == before)
        }
    }

    @Test func fp35_foldersOutsideTheLibraryOrHiddenAreNeverMoved() throws {
        let g = try Ground()
        try g.make("Ann/One")
        let outside = g.root.deletingLastPathComponent().appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let before = g.contents()
        let cases = [
            PlannedMove(from: g.url("Ann/One"), to: outside.appendingPathComponent("One")),
            PlannedMove(from: outside, to: g.url("In")),
            PlannedMove(from: g.url("Ann/One"), to: g.url(".voxcarrel/One")),
            PlannedMove(from: g.url(".voxcarrel"), to: g.url("Shown")),
            PlannedMove(from: g.root, to: g.url("Ann/Root")),
        ]
        for move in cases {
            #expect(g.mover.blockers(for: [move]) == [0: .outsideLibrary])
            #expect(throws: FolderMoveError.self) { try g.mover.move([move]) }
            #expect(g.contents() == before)
            #expect(FileManager.default.fileExists(atPath: outside.path))
        }
    }

    @Test func fp35_twoMovesToOnePlaceAreRefused() throws {
        let g = try Ground()
        try g.make("Ann/One")
        try g.make("Ann/Two")
        let before = g.contents()
        #expect(throws: FolderMoveError.self) {
            try g.mover.move(g.moves([("Ann/One", "Z/Same"), ("Ann/Two", "Z/Same")]))
        }
        #expect(g.contents() == before)
    }

    @Test(arguments: [1, 2, 3, 4, 5])
    func fp35_aFailureAtAnyRenameOfPlainMovesPutsEverythingBack(failing: Int) throws {
        let g = try Ground()
        let names = ["One", "Two", "Three", "Four", "Five"]
        for name in names { try g.make("Ann/\(name)", extra: ["Extras/x.pdf"]) }
        try g.put("Ann/.DS_Store")
        let before = g.contents()
        g.failRename(failing)
        #expect { try g.mover.move(g.moves(names.map { ("Ann/\($0)", "Audio/Ann/\($0)") })) } throws: { error in
            guard case FolderMoveError.failed = error else { return false }
            return true
        }
        #expect(g.contents() == before)
    }

    @Test(arguments: 1...9)
    func fp35_aFailureAtAnyRenameOfDependentMovesPutsEverythingBack(failing: Int) throws {
        let g = try Ground()
        // A swap, a folder going deeper along its own path, one coming shallower, and a plain move.
        let shape = [
            ("X/One", "X/Two"), ("X/Two", "X/One"), ("Frank/Dune", "Frank/Dune/1 - Dune"),
            ("Herb/Saga/1 - Saga", "Herb/Saga"), ("Ann/Book", "Audio/Ann/Book"),
        ]
        for (from, _) in shape { try g.make(from, extra: ["Extras/x.pdf"]) }
        let before = g.contents()
        g.failRename(failing)
        #expect { try g.mover.move(g.moves(shape)) } throws: { error in
            guard case FolderMoveError.failed = error else { return false }
            return true
        }
        #expect(g.contents() == before, "rename \(failing)")
        // With no failure the same moves are made, in nine renames.
        g.failRename(10)
        try g.mover.move(g.moves(shape))
        #expect(try file(g, "Herb/Saga/own.txt") == "Herb/Saga/1 - Saga|own.txt")
        #expect(try file(g, "Frank/Dune/1 - Dune/own.txt") == "Frank/Dune|own.txt")
    }

    @Test func fp35_aDestinationThatAppearsAfterTheCheckIsNotReplaced() throws {
        let g = try Ground()
        try g.make("Ann/One")
        try g.make("Ann/Two")
        let before = g.contents()
        var count = 0
        let intruder = g.url("Z/Two")
        g.mover.rename = { from, to in
            count += 1
            // Something else makes the second destination just before its rename.
            if count == 2 { try FileManager.default.createDirectory(at: intruder, withIntermediateDirectories: true) }
            try FolderMover.renameWithoutReplacing(from, to)
        }
        #expect(throws: FolderMoveError.self) {
            try g.mover.move(g.moves([("Ann/One", "Z/One"), ("Ann/Two", "Z/Two")]))
        }
        var expected = before
        expected["Z"] = "<folder>"
        expected["Z/Two"] = "<folder>"
        #expect(g.contents() == expected)
    }

    @Test func fp35_aFolderThatCannotBePutBackIsNamedAndNothingIsLost() throws {
        let g = try Ground()
        for name in ["One", "Two", "Three"] { try g.make("Ann/\(name)") }
        // The third move fails, and then the first folder cannot go back.
        g.failRenames(to: ["Z/Three", "Ann/One"])
        #expect { try g.mover.move(g.moves([("Ann/One", "Z/One"), ("Ann/Two", "Z/Two"), ("Ann/Three", "Z/Three")])) } throws: { error in
            guard case FolderMoveError.rollbackIncomplete(let index, _, let outstanding) = error else { return false }
            return index == 2
                && outstanding == [MoveRecord(from: g.url("Ann/One").path, to: g.url("Z/One").path, wasCopy: false)]
        }
        #expect(try file(g, "Z/One/own.txt") == "Ann/One|own.txt")
        #expect(try file(g, "Ann/Two/own.txt") == "Ann/Two|own.txt")
        #expect(try file(g, "Ann/Three/own.txt") == "Ann/Three|own.txt")
    }

    @Test func fp35_aFolderStrandedWhileSetAsideIsLeftWithAListOfWhereItBelongs() throws {
        let g = try Ground()
        try g.make("X/One")
        try g.make("X/Two")
        // Rename 3 puts the first folder in place and fails; then neither folder set
        // aside can go back.
        g.failRenames(to: ["X/Two", "X/One"])
        #expect { try g.mover.move(g.moves([("X/One", "X/Two"), ("X/Two", "X/One")])) } throws: { error in
            guard case FolderMoveError.rollbackIncomplete(_, _, let outstanding) = error else { return false }
            return outstanding.count == 2
        }
        let parked = tree(g.url(".voxcarrel/moving"))
        #expect(parked.count == 6)  // the operation's folder, its list, two folders each with a file
        let token = try #require(parked.first)
        let manifest = try JSONDecoder().decode(
            [FolderMover.ManifestEntry].self, from: Data(contentsOf: g.url(".voxcarrel/moving/\(token)/moves.json")))
        #expect(Set(manifest.map(\.folder)) == ["X/One", "X/Two"])
        for entry in manifest {
            #expect(try file(g, ".voxcarrel/moving/\(token)/\(entry.parkedAs)/own.txt") == "\(entry.folder)|own.txt")
            #expect(entry.movingTo == (entry.folder == "X/One" ? "X/Two" : "X/One"))
        }
    }

    @Test(.enabled(if: FolderMoverTests.volumeIgnoresCase))
    func fp35_aFolderGoesBackToANameThatWasRemadeInAnotherCapitalisation() throws {
        let g = try Ground()
        try g.make("Frank/dune")
        try g.make("Frank/Other")
        let before = g.contents()
        // The first goes deeper along its own path, under a folder spelled "Dune";
        // the third rename fails, and the first must go back to "dune".
        g.failRename(3)
        #expect(throws: FolderMoveError.self) {
            try g.mover.move(g.moves([("Frank/dune", "Frank/Dune/1 - Dune"), ("Frank/Other", "Frank/Dune/2 - Other")]))
        }
        #expect(g.contents() == before)
        #expect(g.names(in: "Frank") == ["Other", "dune"])
    }

    // MARK: FP36 Folders left empty

    @Test func fp36_foldersTheMovesEmptyAreRemovedUpToButNotTheLibrary() throws {
        let g = try Ground()
        try g.make("Ann/Series/Book")
        try g.put("Ann/Series/.DS_Store")
        try g.put("Ann/.DS_Store")
        try g.mover.move(g.moves([("Ann/Series/Book", "Book")]))
        #expect(tree(g.root).filter { !$0.hasPrefix(".voxcarrel") } == ["Book", "Book/own.txt"])
        #expect(FileManager.default.fileExists(atPath: g.root.path))
    }

    @Test func fp36_aFolderThatStillHoldsAnythingIsLeftAlone() throws {
        for kept in ["cover.jpg", ".hidden", "Other/own.txt", "Empty Folder/"] {
            let g = try Ground()
            try g.make("Ann/Series/Book")
            try g.put("Ann/Series/.DS_Store")
            if kept.hasSuffix("/") {
                try FileManager.default.createDirectory(at: g.url("Ann/Series/\(kept)"), withIntermediateDirectories: true)
            } else {
                try g.put("Ann/Series/\(kept)")
            }
            try g.mover.move(g.moves([("Ann/Series/Book", "Z/Book")]))
            let left = tree(g.root).filter { $0.hasPrefix("Ann") }
            #expect(left.contains("Ann/Series/.DS_Store"), "\(kept)")
            #expect(left.contains { $0.hasPrefix("Ann/Series/\(kept.split(separator: "/")[0])") }, "\(kept)")
            #expect(!left.contains("Ann/Series/Book"))
        }
    }

    @Test func fp36_aDestinationThatIsNotLeftEmptyBlocksTheMove() throws {
        for kept in ["cover.jpg", ".hidden", "Other/own.txt", "Empty Folder/"] {
            let g = try Ground()
            try g.make("Frank/Dune/1 - Dune")
            if kept.hasSuffix("/") {
                try FileManager.default.createDirectory(at: g.url("Frank/Dune/\(kept)"), withIntermediateDirectories: true)
            } else {
                try g.put("Frank/Dune/\(kept)")
            }
            let before = g.contents()
            let moves = g.moves([("Frank/Dune/1 - Dune", "Frank/Dune")])
            #expect(g.mover.blockers(for: moves) == [0: .destinationExists], "\(kept)")
            #expect(throws: FolderMoveError.self) { try g.mover.move(moves) }
            #expect(g.contents() == before)
        }
    }

    // MARK: Names

    @Test func namesAreComparedAsTheVolumeComparesThem() {
        let folding = VolumeNaming(caseSensitive: false)
        let exact = VolumeNaming(caseSensitive: true)
        #expect(folding.key("Dune") == folding.key("dune"))
        #expect(exact.key("Dune") != exact.key("dune"))
        // Composed or decomposed, one name on every volume.
        for naming in [folding, exact] {
            #expect(naming.key("\u{E9}cole") == naming.key("e\u{301}cole"))
            #expect(Array(naming.key("e\u{301}cole").unicodeScalars) == Array(naming.key("\u{E9}cole").unicodeScalars))
            #expect(naming.key(["A", "b"]) == [naming.key("A"), naming.key("b")])
        }
        #expect(folding.key("\u{C9}COLE") == folding.key("e\u{301}cole"))
    }

    @Test func theVolumeIsAskedHowItTellsNamesApart() throws {
        let g = try Ground()
        try g.make("probe")
        let alsoThere = FileManager.default.fileExists(atPath: g.url("PROBE").path)
        #expect(VolumeNaming.of(g.root).caseSensitive == !alsoThere)
    }
}
