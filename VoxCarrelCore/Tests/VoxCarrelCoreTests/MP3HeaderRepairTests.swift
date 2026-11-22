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
            // Two channels: the header is further into the frame (36 and 21 bytes).
            Options(statedFrames: 100, statedBytes: 41_700, channels: .stereo),
            Options(statedFrames: 100, statedBytes: 41_700, lameExtension: true, channels: .jointStereo),
            Options(statedFrames: 100, statedBytes: 20_800, mpeg2: true, channels: .stereo),
            Options(header: .info, statedFrames: 100, statedBytes: 20_800, mpeg2: true, channels: .jointStereo),
            // Frames with a checksum, the header in the usual place.
            Options(statedFrames: 100, statedBytes: 41_700, crcProtected: true),
            Options(statedFrames: 100, statedBytes: 41_700, channels: .stereo, crcProtected: true),
            Options(statedFrames: 100, statedBytes: 20_800, mpeg2: true, channels: .jointStereo, crcProtected: true),
        ]
        for options in kinds {
            let s = try sample(options, tagged: true)
            #expect(try AudioTagIO.read(s.url).lengthProblem?.repairable == true)
            // Players go by the wrong header, wherever in the frame it is.
            if options.statedFrames == 100 { #expect(try await MediaFixtures.avDuration(s.url) < 5) }
            #expect(try MP3HeaderRepair().repair(s.url) != nil)
            try expectOnlyTheHeaderChanged(s)
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

    /// Only bytes of the first frame differ from the file as it was, and only from the
    /// header's flags to the end of its seek table.
    func expectOnlyTheHeaderChanged(_ s: Sample, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let now = try Data(contentsOf: s.url)
        let frame = Int(try MP3FrameScan.measure(s.url).firstFrame.lowerBound)
        let at = try #require(s.built.headerOffset, sourceLocation: sourceLocation)
        #expect(now.count == s.bytes.count, sourceLocation: sourceLocation)
        let differing = now.indices.filter { now[$0] != s.bytes[$0] }.map { $0 - frame }
        #expect(!differing.isEmpty, sourceLocation: sourceLocation)
        // The fields and seek table, and a LAME extension's music length and checksum.
        let allowed = [at + 4..<at + 120, at + 148..<at + 152, at + 154..<at + 156]
        #expect(differing.allSatisfy { offset in allowed.contains { $0.contains(offset) } }, sourceLocation: sourceLocation)
    }

    // A frame with a checksum can carry the header two bytes further on, after the
    // checksum. The tag library finds it there; AVFoundation does not look there, and
    // plays the file through. Both read the true length once it is repaired.
    @Test func aHeaderPutAfterAFramesChecksumIsRepairedWhereItIs() async throws {
        for options in [
            Options(statedFrames: 100, statedBytes: 41_700, crcProtected: true, headerAfterCRC: true),
            Options(statedFrames: 100, statedBytes: 41_700, lameExtension: true, channels: .stereo,
                    crcProtected: true, headerAfterCRC: true),
            Options(statedFrames: 100, statedBytes: 20_800, mpeg2: true, channels: .jointStereo,
                    crcProtected: true, headerAfterCRC: true),
        ] {
            let s = try sample(options, tagged: true)
            let at = try #require(s.built.headerOffset)
            let found = try #require(try MP3FrameScan.measure(s.url).vbrHeader.xing)
            #expect(found.offsetInFrame == at)
            #expect(found.statedFrames == 100)
            #expect(abs(try CTBTagFile.readMP3(atPath: s.url.path).durationSeconds - 100 * s.built.seconds / Double(s.built.frameCount)) < 0.01)
            #expect(try AudioTagIO.read(s.url).lengthProblem?.repairable == true)

            #expect(try MP3HeaderRepair().repair(s.url) != nil)

            try expectOnlyTheHeaderChanged(s)
            let xing = try #require(try MP3FrameScan.measure(s.url).vbrHeader.xing)
            #expect(xing.offsetInFrame == at)
            #expect(xing.statedFrames == UInt32(s.built.frameCount))
            #expect(xing.statedBytes == UInt32(s.built.audioRange.count))
            #expect(xing.lame?.crcIsValid != false)
            #expect(try AudioTagIO.read(s.url).lengthProblem == nil)
            #expect(abs(try CTBTagFile.readMP3(atPath: s.url.path).durationSeconds - s.built.seconds) < 0.01)
            #expect(abs(try await MediaFixtures.avDuration(s.url) - s.built.seconds) < 0.5)
            // And it goes back byte for byte.
            let healthy = try sample(options)
            let state = try #require(try MP3HeaderRepair().repair(healthy.url))
            try MP3HeaderRepair().restore(state, at: healthy.url)
            #expect(try Data(contentsOf: healthy.url) == healthy.bytes)
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
        // The music length said what the byte count said, and says what it says now.
        let musicAt = offset + 21 + 148
        #expect([UInt8](s.bytes[musicAt..<musicAt + 4]) == [0, 0, 0xA2, 0xE4])  // 41,700
        #expect(data[musicAt..<musicAt + 4] == data[offset + 21 + 12..<offset + 21 + 16])
        #expect(data[musicAt..<musicAt + 4].reduce(0) { $0 << 8 | Int($1) } == s.built.audioRange.count)
        // The rest of the extension is as it was, and the checksum covers all of it.
        #expect(data[offset + 21 + 116..<musicAt] == s.bytes[offset + 21 + 116..<musicAt])
        #expect(data[musicAt + 4..<crcAt] == s.bytes[musicAt + 4..<crcAt])
        #expect(MediaFixtures.crc16(data[offset..<crcAt]) == UInt16(data[crcAt]) << 8 | UInt16(data[crcAt + 1]))
    }

    // A music length that is not the header's byte count counts something else: what it
    // should be cannot be told, so it stays.
    @Test func aMusicLengthOfItsOwnIsLeftAlone() throws {
        for own in [900_000, 0] as [UInt32] {
            let s = try sample(
                Options(statedFrames: 100, statedBytes: 41_700, lameExtension: true, lameMusicLength: own))
            _ = try #require(try MP3HeaderRepair().repair(s.url))
            let data = try Data(contentsOf: s.url)
            #expect(data[21 + 148..<21 + 152] == s.bytes[21 + 148..<21 + 152])
            #expect(data[21 + 12..<21 + 16].reduce(0) { $0 << 8 | Int($1) } == s.built.audioRange.count)
            // The checksum is right for the frame as it now is.
            #expect(try MP3FrameScan.measure(s.url).vbrHeader.xing?.lame?.crcIsValid == true)
        }
        // A byte count that was right already is not a reason to touch the music length:
        // here only the frame count was wrong.
        let s = try sample(Options(statedFrames: 100, lameExtension: true))
        _ = try #require(try MP3HeaderRepair().repair(s.url))
        let data = try Data(contentsOf: s.url)
        #expect(data[21 + 148..<21 + 152] == s.bytes[21 + 148..<21 + 152])
        // And a music length that is put right with a checksum that was wrong leaves the checksum.
        var built = MediaFixtures.makeMP3(Options(statedFrames: 100, statedBytes: 41_700, lameExtension: true))
        built.data[21 + 154] ^= 0xFF
        let url = try makeTempDir().appendingPathComponent("book.mp3")
        try built.data.write(to: url)
        _ = try #require(try MP3HeaderRepair().repair(url))
        let after = try Data(contentsOf: url)
        #expect(after[21 + 148..<21 + 152] == after[21 + 12..<21 + 16])
        #expect(after[21 + 154..<21 + 156] == built.data[21 + 154..<21 + 156])
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

    // The checks after the first are there for what the first cannot see. To show each
    // of them catching real damage, the comparison of bytes is switched off and the
    // working copy really is damaged: the checks themselves are the real ones.

    /// A repair that does not compare bytes, and whose change also does `damage` to the
    /// working copy (after writing the planned frame, unless `writingThePlan` is false).
    func unguarded(
        writingThePlan: Bool = true, _ damage: @escaping (URL, MP3HeaderRepair.Plan) throws -> Void
    ) -> MP3HeaderRepair {
        var repair = MP3HeaderRepair()
        repair.compareBytes = { original, _, _ in try MP3HeaderRepair.sha256(of: original) }
        repair.change = { copy, plan in
            if writingThePlan { try MP3HeaderRepair.write(copy, plan) }
            try damage(copy, plan)
        }
        return repair
    }

    @Test func tagsReallyChangedInTheCopyFailTheRepair() throws {
        let s = try sample(.wrongHeader(), tagged: true)
        var other = BookMetadata(title: "Another Title", authors: ["An Author"])
        other.narrators = ["A Narrator"]
        other.summary = "What it is about."

        let retitled = unguarded { copy, _ in
            try AudioTagIO.writeInPlace(other, cover: .keep, part: PartPosition(index: 2, count: 5), to: copy)
        }
        try expectCheckFails(retitled, s, "the tags or the cover changed")

        other.title = "The Book"
        let uncovered = unguarded { copy, _ in
            try AudioTagIO.writeInPlace(other, cover: .remove, part: PartPosition(index: 2, count: 5), to: copy)
        }
        try expectCheckFails(uncovered, s, "the tags or the cover changed")

        let renumbered = unguarded { copy, _ in
            try AudioTagIO.writeInPlace(other, cover: .keep, part: PartPosition(index: 3, count: 5), to: copy)
        }
        try expectCheckFails(renumbered, s, "the tags or the cover changed")

        let notAudio = unguarded { copy, _ in try Data(repeating: 0x20, count: s.bytes.count).write(to: copy) }
        try expectCheckFails(notAudio, s, "no longer reads as audio")

        // Nothing written at all: the header in the copy is as wrong as it was.
        try expectCheckFails(unguarded(writingThePlan: false) { _, _ in }, s, "still wrong")
        // And a frame count that is still far out.
        let farOut = unguarded { copy, plan in
            try MP3HeaderRepair.write(Data([0, 0, 0, 200]), at: plan.firstFrame.lowerBound + 21 + 8, in: copy)
        }
        try expectCheckFails(farOut, s, "still wrong")
    }

    // What the comparison of what was read cannot be made to see by damaging an MP3:
    // chapters, which the fixtures do not carry.
    @Test func chaptersThatReadBackDifferentlyFailTheRepair() throws {
        let s = try sample(.wrongHeader(), tagged: true)
        var repair = MP3HeaderRepair()
        repair.read = { url in
            var contents = try AudioTagIO.read(url)
            if isWorkingCopy(url) { contents.chapters = [Chapter(start: 0, title: "One")] }
            return contents
        }
        try expectCheckFails(repair, s, "the tags or the cover changed")
    }

    @Test func framesReallyChangedInTheCopyFailTheRepair() throws {
        let s = try sample(.wrongHeader(), tagged: true)
        let frame = 417

        // Ten frames fewer: a quarter of a second, too little for the header to be
        // called wrong, but not the audio that was there.
        let shorter = unguarded { copy, _ in
            let handle = try FileHandle(forWritingTo: copy)
            try handle.truncate(atOffset: UInt64(s.bytes.count - 10 * frame))
            try handle.close()
        }
        try expectCheckFails(shorter, s, "no longer measures the same")

        // The same number of bytes, but a frame in the middle is no frame any more.
        let broken = unguarded { copy, plan in
            let at = plan.firstFrame.upperBound + UInt64(1000 * frame)
            try MP3HeaderRepair.write(Data(repeating: 0x55, count: frame), at: at, in: copy)
        }
        try expectCheckFails(broken, s, "no longer measures the same")

        // More bytes that are not audio than a measurement tolerates.
        let unmeasurable = unguarded { copy, plan in
            let at = plan.firstFrame.upperBound + UInt64(1000 * frame)
            try MP3HeaderRepair.write(Data(repeating: 0x55, count: 200 * frame), at: at, in: copy)
        }
        try expectCheckFails(unmeasurable, s, "no longer measures the same")

        // A frame count five short of the frames: near enough not to be called wrong
        // when read, and not what was measured.
        let nearly = unguarded { copy, plan in
            let count = UInt32(plan.frameCount - 5)
            let bytes = Data([UInt8(count >> 24), UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)])
            try MP3HeaderRepair.write(bytes, at: plan.firstFrame.lowerBound + 21 + 8, in: copy)
        }
        try expectCheckFails(nearly, s, "does not state what was measured")

        // The seek table gone from the flags.
        let noTable = unguarded { copy, plan in
            try MP3HeaderRepair.write(Data([0, 0, 0, 0x03]), at: plan.firstFrame.lowerBound + 21 + 4, in: copy)
        }
        try expectCheckFails(noTable, s, "does not state what was measured")
    }

    // With the comparison of bytes on, as it always is, the same damage is caught first.
    @Test func theSameDamageIsCaughtByTheComparisonOfBytes() throws {
        let s = try sample(.wrongHeader(), tagged: true)
        let other = BookMetadata(title: "Another Title", authors: ["An Author"])
        let retitled = damaging { copy, _ in
            try AudioTagIO.writeInPlace(other, cover: .keep, part: nil, to: copy)
        }
        try expectCheckFails(retitled, s, "changed")
        let broken = damaging { copy, plan in
            try MP3HeaderRepair.write(
                Data(repeating: 0x55, count: 417), at: plan.firstFrame.upperBound + 417_000, in: copy)
        }
        try expectCheckFails(broken, s, "outside the first frame")
    }

    // The two files are compared a mebibyte at a time. Here the first frame lies across
    // the end of the first mebibyte, with the header's seek table on both sides of it.
    @Test func aFirstFrameAcrossTheEndOfAChunkIsComparedAsAnyOther() throws {
        let chunk = 1 << 20
        func tag(picture: Int) -> Data {
            MediaFixtures.id3v23Tag(frames: [
                ("APIC", MediaFixtures.id3Picture(Data(repeating: 0x37, count: picture), mime: "image/jpeg", type: 3)),
            ])
        }
        // The frame begins 60 bytes before the end of the chunk: the header's fields run
        // from byte 25 to byte 137 of it.
        let overhead = tag(picture: 0).count
        let prefix = tag(picture: chunk - 60 - overhead)
        #expect(prefix.count == chunk - 60)
        let s = try sample(Options(statedFrames: 100, statedBytes: 41_700, lameExtension: true, prefix: prefix))
        let start = UInt64(chunk - 60)
        #expect(try MP3FrameScan.measure(s.url).firstFrame == start..<start + 417)

        // Bytes that may not change, on either side of the end of the chunk.
        for offset in [2, 10, 22, 24, 21 + 121, 300, 416] as [UInt64] {
            let repair = damaging { copy, _ in try flip(start + offset, in: copy) }
            try expectCheckFails(repair, s, "other than the length header's fields")
        }
        // Fields that may change, but not to anything: on either side too.
        for offset in [21 + 11, 21 + 30, 21 + 50, 21 + 110] as [UInt64] {
            let repair = damaging { copy, _ in try flip(start + offset, in: copy) }
            try expectCheckFails(repair, s, "not as it was meant to be")
        }
        // The last byte of the first chunk and the first of the second, outside the frame.
        for offset in [start - 1, start + 417] {
            let repair = damaging { copy, _ in try flip(offset, in: copy) }
            try expectCheckFails(repair, s, "outside the first frame")
        }

        // And the repair itself goes through, and back.
        let state = try #require(try MP3HeaderRepair().repair(s.url))
        let repaired = try Data(contentsOf: s.url)
        #expect(repaired != s.bytes)
        let differing = repaired.indices.filter { repaired[$0] != s.bytes[$0] }
        #expect(differing.contains { $0 < chunk } && differing.contains { $0 >= chunk })
        #expect(try AudioTagIO.read(s.url).lengthProblem == nil)
        try MP3HeaderRepair().restore(state, at: s.url)
        #expect(try Data(contentsOf: s.url) == s.bytes)
    }

    // The one result of counting the frames that damage to the copy cannot produce while
    // the bytes are compared: kept to show the comparison of the two measurements.
    @Test func aMeasurementThatDiffersFailsTheRepair() throws {
        let s = try sample(.wrongHeader(), tagged: true)
        for what in ["count", "range"] {
            var repair = MP3HeaderRepair()
            repair.measure = { url in
                var measured = try MP3FrameScan.measure(url, recordingOffsets: true)
                guard isWorkingCopy(url) else { return measured }
                if what == "count" {
                    measured.frameCount += 1
                } else {
                    measured.audioRange = measured.audioRange.lowerBound..<measured.audioRange.upperBound - 417
                }
                return measured
            }
            try expectCheckFails(repair, s, "no longer measures the same")
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
