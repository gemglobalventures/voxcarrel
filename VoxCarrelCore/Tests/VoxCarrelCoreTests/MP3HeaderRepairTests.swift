import AVFoundation
import CTagBridge
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import VoxCarrelCore
import VoxCarrelFixtures

@Suite struct MP3HeaderRepairTests {
    typealias Options = MediaFixtures.MP3Options

    struct Sample {
        var url: URL
        var built: MediaFixtures.BuiltMP3
        /// The file as it was written, tags included.
        var bytes: Data
    }

    /// A fixture on disk, with tags and a cover written into it when asked.
    func sample(_ options: Options, tagged: Bool = false) throws -> Sample {
        let url = try makeTempDir().appendingPathComponent("book.mp3")
        let built = MediaFixtures.makeMP3(options)
        try built.data.write(to: url)
        if tagged {
            var metadata = BookMetadata(title: "The Book", authors: ["An Author"])
            metadata.narrators = ["A Narrator"]
            metadata.summary = "What it is about."
            let cover = CoverImage(data: MediaFixtures.makeImage(.jpeg, size: 128), mime: "image/jpeg")
            try AudioTagIO.write(metadata, cover: .set(cover), part: PartPosition(index: 2, count: 5), to: url)
        }
        return Sample(url: url, built: built, bytes: try Data(contentsOf: url))
    }

    func isWorkingCopy(_ url: URL) -> Bool { url.lastPathComponent.hasPrefix(".voxcarrel-") }

    /// Nothing but the file itself is in its folder: no working copy was left behind.
    func expectAlone(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(names == [url.lastPathComponent], sourceLocation: sourceLocation)
    }

    /// The repair is refused with a failed check whose reason contains `text`, and the file is untouched.
    func expectCheckFails(
        _ repair: MP3HeaderRepair, _ s: Sample, _ text: String, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        do {
            _ = try repair.repair(s.url)
            Issue.record("the repair went through", sourceLocation: sourceLocation)
        } catch MetadataIOError.verificationFailed(let reason) {
            #expect(reason.contains(text), "\(reason)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
        }
        #expect(try Data(contentsOf: s.url) == s.bytes, sourceLocation: sourceLocation)
        try expectAlone(s.url, sourceLocation: sourceLocation)
    }

    // MARK: What a repair does

    @Test func aRepairedFileIsReadAtItsTrueLengthByEveryone() async throws {
        let s = try sample(Options(statedFrames: 100, statedBytes: 41_700, id3v1: true), tagged: true)
        let before = try AudioTagIO.read(s.url)
        let trackBefore = try AudioTagIO.readTrackTags(s.url)
        let trueSeconds = s.built.seconds
        #expect(before.lengthProblem?.repairable == true)

        let state = try #require(try MP3HeaderRepair().repair(s.url))

        // The tag library, AVFoundation and Apple's decoder all agree with the frames now.
        #expect(abs(try CTBTagFile.readMP3(atPath: s.url.path).durationSeconds - trueSeconds) < 0.01)
        #expect(abs(try await MediaFixtures.avDuration(s.url) - trueSeconds) < 0.05)
        #expect(abs(Double(try MediaFixtures.decodedFrameCount(s.url)) / 44_100 - trueSeconds) < 0.1)

        // Read as before, but for the problem.
        let after = try AudioTagIO.read(s.url)
        #expect(after.lengthProblem == nil)
        #expect(after.cover == before.cover)
        #expect(after.metadata.title == "The Book")
        #expect(abs(try #require(after.metadata.durationSeconds) - trueSeconds) < 0.01)
        #expect(try AudioTagIO.readTrackTags(s.url) == trackBefore)

        // Only bytes of the first frame differ, and only the header's fields in it.
        let now = try Data(contentsOf: s.url)
        let measured = try MP3FrameScan.measure(s.url)
        let frame = Int(measured.firstFrame.lowerBound)..<Int(measured.firstFrame.upperBound)
        #expect(now.count == s.bytes.count)
        #expect(now[..<frame.lowerBound] == s.bytes[..<frame.lowerBound])
        #expect(now[frame.upperBound...] == s.bytes[frame.upperBound...])
        let differing = frame.filter { now[$0] != s.bytes[$0] }.map { $0 - frame.lowerBound }
        #expect(!differing.isEmpty)
        #expect(differing.allSatisfy { (21 + 8..<21 + 116).contains($0) })
        #expect(now[frame.lowerBound..<frame.lowerBound + 21] == s.bytes[frame.lowerBound..<frame.lowerBound + 21])

        let xing = try #require(measured.vbrHeader.xing)
        #expect(xing.statedFrames == UInt32(s.built.frameCount))
        #expect(xing.statedBytes == UInt32(s.built.audioRange.count))
        #expect(xing.flags == 0x0F)

        // What undo is given.
        #expect(state.pathAfter == s.url.path)
        #expect(state.frameOffset == measured.firstFrame.lowerBound)
        #expect(state.originalFrame == s.bytes[frame])
        #expect(state.originalFrame.count == 417)
        let original = try makeTempDir().appendingPathComponent("original.bin")
        try s.bytes.write(to: original)
        #expect(state.originalSHA256 == (try MP3HeaderRepair.sha256(of: original)))
        #expect(state.originalSHA256.count == 64)
    }

    @Test func everyRepairableKindIsRepaired() async throws {
        let kinds: [Options] = [
            Options(header: .info, statedFrames: 100, statedBytes: 41_700),
            Options(statedFrames: 100, statedBytes: 20_800, mpeg2: true),
            Options(statedFrames: 100, statedBytes: 41_700, variableBitrate: true),
            Options(statedFrames: 4_000_000),
            Options(statedFrames: 100, xingFlags: 0x01),
            Options(statedFrames: 100, statedBytes: 41_700, xingFlags: 0x03),
            Options(statedFrames: 100, statedBytes: 41_700, junk: (afterFrame: 300, bytes: Data(repeating: 0x55, count: 900))),
        ]
        for options in kinds {
            let s = try sample(options, tagged: true)
            #expect(try AudioTagIO.read(s.url).lengthProblem?.repairable == true)
            #expect(try MP3HeaderRepair().repair(s.url) != nil)
            #expect(try AudioTagIO.read(s.url).lengthProblem == nil)
            #expect(abs(try CTBTagFile.readMP3(atPath: s.url.path).durationSeconds - s.built.seconds) < 0.01)
            let av = try await MediaFixtures.avDuration(s.url)
            // AVFoundation drops a few frames around bytes that are not audio.
            #expect(abs(av - s.built.seconds) < 0.5)
            let xing = try #require(try MP3FrameScan.measure(s.url).vbrHeader.xing)
            #expect(xing.isInfo == (options.header == .info))
            #expect(xing.flags == options.xingFlags | 0x07)
            try expectAlone(s.url)
        }
    }

    @Test func aFileJoinedFromPartsIsRepairedOrLeftExactlyAsItWas() async throws {
        let picture = Data(repeating: 0x37, count: 100_000)
        let tag = MediaFixtures.id3v23Tag(frames: [
            ("APIC", MediaFixtures.id3Picture(picture, mime: "image/jpeg", type: 3)),
        ])
        let s = try sample(
            Options(statedFrames: 100, statedBytes: 41_700, junk: (afterFrame: 1000, bytes: tag)), tagged: true)
        let problem = try #require(try AudioTagIO.read(s.url).lengthProblem)
        #expect(abs(problem.trueSeconds - s.built.seconds) < 0.001)
        do {
            _ = try #require(try MP3HeaderRepair().repair(s.url))
            // Repaired only because every reader then agreed.
            #expect(abs(try await MediaFixtures.avDuration(s.url) - s.built.seconds) < 1)
            #expect(try AudioTagIO.read(s.url).lengthProblem == nil)
        } catch is MetadataIOError {
            // A system whose players cannot read such a file through: nothing is changed.
            #expect(try Data(contentsOf: s.url) == s.bytes)
        }
        try expectAlone(s.url)
    }

    @Test func theSeekTableFollowsTheRealFramePositions() throws {
        // The second half of the frames is a quarter of the size of the first.
        let s = try sample(Options(statedFrames: 100, statedBytes: 41_700, variableBitrate: true))
        _ = try #require(try MP3HeaderRepair().repair(s.url))

        let data = try Data(contentsOf: s.url)
        let table = [UInt8](data[21 + 16..<21 + 116])
        let total = s.built.audioRange.count
        for entry in 0..<100 {
            let index = min(s.built.frameCount - 1, entry * s.built.frameCount / 100)
            let expected = (s.built.frameOffsets[index] - s.built.audioRange.lowerBound) * 256 / total
            #expect(Int(table[entry]) == min(255, expected), "entry \(entry)")
        }
        #expect(table[0] == 0)
        // Half the time is four fifths of the bytes: far from the straight line it was.
        #expect((200...208).contains(table[50]))
        #expect(table == table.sorted())
    }

    @Test func aQualityFieldMovesAlongWithItsValue() throws {
        // Frame count and quality only: the quality sits where the byte count must go.
        let s = try sample(Options(statedFrames: 100, xingFlags: 0x09))
        #expect([UInt8](s.bytes[21 + 12..<21 + 16]) == [0, 0, 0, 57])
        _ = try #require(try MP3HeaderRepair().repair(s.url))
        let data = try Data(contentsOf: s.url)
        #expect([UInt8](data[21 + 4..<21 + 8]) == [0, 0, 0, 0x0F])
        #expect([UInt8](data[21 + 116..<21 + 120]) == [0, 0, 0, 57])
        #expect(try AudioTagIO.read(s.url).lengthProblem == nil)
    }

    @Test func aValidChecksumIsMadeValidAgain() throws {
        let s = try sample(Options(statedFrames: 100, statedBytes: 41_700, lameExtension: true), tagged: true)
        let offset = Int(try MP3FrameScan.measure(s.url).firstFrame.lowerBound)
        _ = try #require(try MP3HeaderRepair().repair(s.url))

        let lame = try #require(try MP3FrameScan.measure(s.url).vbrHeader.xing?.lame)
        #expect(lame.crcIsValid)
        #expect(lame.encoder == "LAME3.100")
        let data = try Data(contentsOf: s.url)
        let crcAt = offset + 21 + 154
        #expect(data[crcAt..<crcAt + 2] != s.bytes[crcAt..<crcAt + 2])
        // The rest of the extension is as it was.
        #expect(data[offset + 21 + 116..<crcAt] == s.bytes[offset + 21 + 116..<crcAt])
        #expect(MediaFixtures.crc16(data[offset..<crcAt]) == UInt16(data[crcAt]) << 8 | UInt16(data[crcAt + 1]))
    }

    @Test func aChecksumThatWasWrongIsLeftAlone() throws {
        var built = MediaFixtures.makeMP3(Options(statedFrames: 100, statedBytes: 41_700, lameExtension: true))
        built.data[21 + 154] ^= 0xFF
        let url = try makeTempDir().appendingPathComponent("book.mp3")
        try built.data.write(to: url)
        _ = try #require(try MP3HeaderRepair().repair(url))
        let data = try Data(contentsOf: url)
        #expect(data[21 + 154..<21 + 156] == built.data[21 + 154..<21 + 156])
        #expect(try AudioTagIO.read(url).lengthProblem == nil)
    }

    @Test func aHeaderThatIsRightAlreadyIsNotTouched() throws {
        // Its counts are right; its seek table, a straight line, is the encoder's business.
        let s = try sample(Options(variableBitrate: true), tagged: true)
        #expect(try MP3HeaderRepair().repair(s.url) == nil)
        #expect(try Data(contentsOf: s.url) == s.bytes)
        try expectAlone(s.url)
        // And a file that has been repaired has nothing left to repair.
        let wrong = try sample(.wrongHeader())
        _ = try #require(try MP3HeaderRepair().repair(wrong.url))
        let repaired = try Data(contentsOf: wrong.url)
        #expect(try MP3HeaderRepair().repair(wrong.url) == nil)
        #expect(try Data(contentsOf: wrong.url) == repaired)
    }

    // MARK: Files that are not repaired

    @Test func filesWithoutAHeaderThatCanBeRewrittenAreRefused() throws {
        let cases: [(Options, MP3HeaderRepair.Refusal)] = [
            (Options(header: .vbri, statedFrames: 100, statedBytes: 41_700), .noHeader),
            (Options(header: .none), .noHeader),
        ]
        for (options, refusal) in cases {
            let s = try sample(options, tagged: true)
            #expect(throws: refusal) { try MP3HeaderRepair().repair(s.url) }
            #expect(try Data(contentsOf: s.url) == s.bytes)
            try expectAlone(s.url)
        }
    }

    @Test func aHeaderWithNoRoomForTheFieldsIsRefused() throws {
        // Frame count only, and something else where the byte count and seek table would go.
        var built = MediaFixtures.makeMP3(Options(statedFrames: 100, xingFlags: 0x01))
        built.data[21 + 60] = 0x7F
        let url = try makeTempDir().appendingPathComponent("book.mp3")
        try built.data.write(to: url)
        let problem = try #require(try AudioTagIO.read(url).lengthProblem)
        #expect(!problem.repairable)
        #expect(throws: MP3HeaderRepair.Refusal.noRoom) { try MP3HeaderRepair().repair(url) }
        #expect(try Data(contentsOf: url) == built.data)
    }

    @Test func aFileThatCannotBeMeasuredIsRefused() throws {
        let junk = Data(repeating: 0x55, count: MP3FrameScan.junkTolerance + 1)
        let s = try sample(Options(statedFrames: 100, junk: (afterFrame: 300, bytes: junk)))
        #expect(throws: MP3HeaderRepair.Refusal.unmeasurable) { try MP3HeaderRepair().repair(s.url) }
        #expect(try Data(contentsOf: s.url) == s.bytes)
    }

    @Test func lockedFilesAndLinksAreRefusedAsForAnyWrite() throws {
        let s = try sample(.wrongHeader())
        let link = s.url.deletingLastPathComponent().appendingPathComponent("link.mp3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: s.url)
        #expect(throws: MetadataIOError.notARegularFile("link.mp3")) { try MP3HeaderRepair().repair(link) }
        try FileManager.default.removeItem(at: link)

        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: s.url.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: s.url.path) }
        #expect(throws: MetadataIOError.locked("book.mp3")) { try MP3HeaderRepair().repair(s.url) }
        #expect(try Data(contentsOf: s.url) == s.bytes)
    }

    // MARK: Every check, failing

    /// A repair whose change also does `damage` to the working copy.
    func damaging(_ damage: @escaping (URL, MP3HeaderRepair.Plan) throws -> Void) -> MP3HeaderRepair {
        var repair = MP3HeaderRepair()
        repair.change = { copy, plan in
            try MP3HeaderRepair.write(copy, plan)
            try damage(copy, plan)
        }
        return repair
    }

    func flip(_ offset: UInt64, in url: URL) throws {
        let byte = try MP3HeaderRepair.bytes(of: url, in: offset..<offset + 1)
        try MP3HeaderRepair.write(Data([byte[0] ^ 0xFF]), at: offset, in: url)
    }

    @Test func aByteChangedOutsideTheFirstFrameFailsTheRepair() throws {
        let s = try sample(.wrongHeader(), tagged: true)
        // In the audio, in the tag in front, and in the very last byte.
        for place in ["audio", "tag", "end"] {
            let repair = damaging { copy, plan in
                switch place {
                case "audio": try flip(plan.firstFrame.upperBound + 5000, in: copy)
                case "tag": try flip(20, in: copy)
                default: try flip(UInt64(s.bytes.count - 1), in: copy)
                }
            }
            try expectCheckFails(repair, s, "outside the first frame")
        }
    }

    @Test func anyOtherByteChangedInTheFirstFrameFailsTheRepair() throws {
        let s = try sample(Options(statedFrames: 100, statedBytes: 41_700, lameExtension: true), tagged: true)
        // The frame's own header, its side information, the letters "Xing", the encoder's
        // name in the extension, and the audio data after it.
        for offset in [2, 10, 21, 21 + 121, 300] as [UInt64] {
            let repair = damaging { copy, plan in try flip(plan.firstFrame.lowerBound + offset, in: copy) }
            try expectCheckFails(repair, s, "other than the length header's fields")
        }
    }

    @Test func aFileThatChangesSizeFailsTheRepair() throws {
        let s = try sample(.wrongHeader())
        let longer = damaging { copy, _ in
            let handle = try FileHandle(forWritingTo: copy)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0]))
            try handle.close()
        }
        try expectCheckFails(longer, s, "size changed")
        let shorter = damaging { copy, _ in
            let handle = try FileHandle(forWritingTo: copy)
            try handle.truncate(atOffset: UInt64(s.bytes.count - 1))
            try handle.close()
        }
        try expectCheckFails(shorter, s, "size changed")
    }

    @Test func headerFieldsThatAreNotWhatWasPlannedFailTheRepair() throws {
        let s = try sample(.wrongHeader())
        // Within the fields that may change, but not the values worked out.
        let wrongCount = damaging { copy, plan in try flip(plan.firstFrame.lowerBound + 21 + 11, in: copy) }
        try expectCheckFails(wrongCount, s, "not as it was meant to be")
        // And a change that writes nothing at all.
        var nothing = MP3HeaderRepair()
        nothing.change = { _, _ in }
        try expectCheckFails(nothing, s, "not as it was meant to be")
    }

    @Test func tagsThatReadBackDifferentlyFailTheRepair() throws {
        let s = try sample(.wrongHeader(), tagged: true)
        for what in ["title", "cover", "chapters", "unreadable", "problem"] {
            var repair = MP3HeaderRepair()
            repair.read = { url in
                var contents = try AudioTagIO.read(url)
                guard isWorkingCopy(url) else { return contents }
                switch what {
                case "title": contents.metadata.title = "Another Title"
                case "cover": contents.cover = nil
                case "chapters": contents.chapters = [Chapter(start: 0, title: "One")]
                case "unreadable": throw MetadataIOError.unreadable(url.lastPathComponent)
                default: contents.lengthProblem = LengthProblem(statedSeconds: 1, trueSeconds: 60, repairable: true)
                }
                return contents
            }
            let text = what == "unreadable" ? "no longer reads as audio"
                : (what == "problem" ? "still wrong" : "the tags or the cover changed")
            try expectCheckFails(repair, s, text)
        }
    }

    @Test func framesThatMeasureDifferentlyFailTheRepair() throws {
        let s = try sample(.wrongHeader(), tagged: true)
        for what in ["count", "range", "header", "unmeasurable"] {
            var repair = MP3HeaderRepair()
            repair.measure = { url in
                var measured = try MP3FrameScan.measure(url, recordingOffsets: true)
                guard isWorkingCopy(url) else { return measured }
                switch what {
                case "count":
                    measured.frameCount += 1
                case "range":
                    measured.audioRange = measured.audioRange.lowerBound..<measured.audioRange.upperBound - 417
                case "header":
                    var xing = try #require(measured.vbrHeader.xing)
                    xing.statedFrames = 100
                    measured.vbrHeader = .xing(xing)
                default:
                    throw MP3FrameScan.Failure.syncLost
                }
                return measured
            }
            try expectCheckFails(
                repair, s, what == "header" ? "does not state what was measured" : "no longer measures the same")
        }
    }

    @Test func aLengthAVFoundationDoesNotAgreeWithFailsTheRepair() throws {
        let s = try sample(.wrongHeader(), tagged: true)
        var repair = MP3HeaderRepair()
        repair.playbackSeconds = { _ in nil }
        try expectCheckFails(repair, s, "could not say how long")
        repair.playbackSeconds = { _ in 2.6 }
        try expectCheckFails(repair, s, "still reads another length")
        // More than a second and more than one part in a hundred away.
        repair.playbackSeconds = { _ in s.built.seconds + 1.2 }
        try expectCheckFails(repair, s, "still reads another length")
        // Within a second is near enough.
        repair.playbackSeconds = { _ in s.built.seconds + 0.9 }
        #expect(try repair.repair(s.url) != nil)
    }

    @Test func theRealPlaybackCheckSeesAWrongHeader() throws {
        let s = try sample(.wrongHeader())
        let repair = MP3HeaderRepair()
        #expect(abs(try #require(repair.playbackSeconds(s.url)) - 100.0 * 1152 / 44_100) < 0.05)
        #expect(throws: MetadataIOError.self) { try repair.checkPlayback(of: s.url, seconds: s.built.seconds) }
        #expect(repair.playbackSeconds(s.url.deletingLastPathComponent().appendingPathComponent("none.mp3")) == nil)
    }

    // MARK: Putting it back

    @Test func restoringGivesBackTheFileByteForByte() throws {
        let s = try sample(Options(statedFrames: 100, statedBytes: 41_700, lameExtension: true, id3v1: true), tagged: true)
        let state = try #require(try MP3HeaderRepair().repair(s.url))
        #expect(try Data(contentsOf: s.url) != s.bytes)

        try MP3HeaderRepair().restore(state, at: s.url)

        #expect(try Data(contentsOf: s.url) == s.bytes)
        try expectAlone(s.url)
        // And the state survives being saved with an operation.
        let saved = try JSONDecoder().decode(HeaderRepairState.self, from: try JSONEncoder().encode(state))
        #expect(saved == state)
    }

    @Test func aFileChangedSinceItsRepairIsNotRestored() throws {
        let s = try sample(.wrongHeader(), tagged: true)
        let state = try #require(try MP3HeaderRepair().repair(s.url))
        // Its tags are rewritten: the tag in front is another size now.
        var metadata = BookMetadata(title: "A Much Longer Title Than Before", authors: ["An Author"])
        metadata.summary = String(repeating: "More to say. ", count: 400)
        try AudioTagIO.write(metadata, cover: .keep, part: nil, to: s.url)
        let changed = try Data(contentsOf: s.url)

        #expect(throws: MetadataIOError.verificationFailed("the file has changed since its header was repaired")) {
            try MP3HeaderRepair().restore(state, at: s.url)
        }
        #expect(try Data(contentsOf: s.url) == changed)
        try expectAlone(s.url)

        // So too for a file that is shorter than the frame's place in it.
        try Data(changed.prefix(100)).write(to: s.url)
        #expect(throws: MetadataIOError.self) { try MP3HeaderRepair().restore(state, at: s.url) }
        #expect(try Data(contentsOf: s.url) == changed.prefix(100))
    }

    @Test func aTagWriteAfterARepairKeepsTheRepair() async throws {
        let s = try sample(.wrongHeader(), tagged: true)
        _ = try #require(try MP3HeaderRepair().repair(s.url))
        var metadata = BookMetadata(title: "Renamed", authors: ["Someone Else"])
        metadata.summary = String(repeating: "A longer description. ", count: 300)
        let cover = CoverImage(data: MediaFixtures.makeImage(.png, size: 300), mime: "image/png")
        try AudioTagIO.write(metadata, cover: .set(cover), part: nil, to: s.url)

        let contents = try AudioTagIO.read(s.url)
        #expect(contents.metadata.title == "Renamed")
        #expect(contents.lengthProblem == nil)
        #expect(abs(try CTBTagFile.readMP3(atPath: s.url.path).durationSeconds - s.built.seconds) < 0.01)
        #expect(abs(try await MediaFixtures.avDuration(s.url) - s.built.seconds) < 0.05)
        let xing = try #require(try MP3FrameScan.measure(s.url).vbrHeader.xing)
        #expect(xing.statedFrames == UInt32(s.built.frameCount))
    }
}
