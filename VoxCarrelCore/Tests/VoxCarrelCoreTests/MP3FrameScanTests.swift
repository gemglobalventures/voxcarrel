import CTagBridge
import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

@Suite struct MP3FrameScanTests {
    typealias Options = MediaFixtures.MP3Options

    /// Writes the fixture and returns where it is with what was built.
    func make(_ options: Options, name: String = "book.mp3") throws -> (url: URL, built: MediaFixtures.BuiltMP3) {
        let url = try makeTempDir().appendingPathComponent(name)
        let built = MediaFixtures.makeMP3(options)
        try built.data.write(to: url)
        return (url, built)
    }

    func write(_ data: Data) throws -> URL {
        let url = try makeTempDir().appendingPathComponent("book.mp3")
        try data.write(to: url)
        return url
    }

    /// The measurement agrees with what the fixture was built from.
    func expectAccurate(
        _ options: Options, sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> MP3FrameScan.Measurement {
        let (url, built) = try make(options)
        let measured = try MP3FrameScan.measure(url, recordingOffsets: true)
        #expect(measured.frameCount == built.frameCount, sourceLocation: sourceLocation)
        #expect(measured.totalSamples == Int64(built.frameCount * built.samplesPerFrame), sourceLocation: sourceLocation)
        #expect(measured.sampleRate == built.sampleRate, sourceLocation: sourceLocation)
        #expect(abs(measured.durationSeconds - built.seconds) < 0.001, sourceLocation: sourceLocation)
        #expect(
            measured.audioRange == UInt64(built.audioRange.lowerBound)..<UInt64(built.audioRange.upperBound),
            sourceLocation: sourceLocation)
        #expect(
            measured.firstFrame == UInt64(built.firstFrame.lowerBound)..<UInt64(built.firstFrame.upperBound),
            sourceLocation: sourceLocation)
        #expect(measured.frameOffsets == built.frameOffsets.map(UInt64.init), sourceLocation: sourceLocation)
        return measured
    }

    // MARK: Every kind of file

    @Test func xingHeaderWithWrongCountsIsMeasuredByItsFrames() throws {
        let measured = try expectAccurate(.wrongHeader())
        #expect(measured.frameCount == 2297)  // 60 s at 1152 samples a frame, 44.1 kHz
        let xing = try #require(measured.vbrHeader.xing)
        #expect(!xing.isInfo)
        #expect(xing.flags == 0x0F)
        #expect(xing.statedFrames == 100)
        #expect(xing.statedBytes == 41_700)
        #expect(xing.hasTOC)
        #expect(xing.lame == nil)
        #expect(xing.hasRoomForRepair)
        #expect(xing.offsetInFrame == 21)
        #expect(measured.junkBytes == 0)
    }

    @Test func correctXingHeaderAgreesWithTheFrames() throws {
        let measured = try expectAccurate(Options())
        let xing = try #require(measured.vbrHeader.xing)
        #expect(xing.statedFrames == UInt32(measured.frameCount))
        #expect(xing.statedBytes == UInt32(measured.audioRange.count))
    }

    @Test func infoHeaderOfAConstantBitrateFile() throws {
        let measured = try expectAccurate(Options(header: .info, statedFrames: 7))
        let xing = try #require(measured.vbrHeader.xing)
        #expect(xing.isInfo)
        #expect(xing.statedFrames == 7)
    }

    @Test func lameExtensionAndItsChecksumAreRecognised() throws {
        let measured = try expectAccurate(Options(statedFrames: 100, lameExtension: true))
        let lame = try #require(measured.vbrHeader.xing?.lame)
        #expect(lame.encoder == "LAME3.100")
        #expect(lame.crcIsValid)
    }

    @Test func aChecksumThatIsWrongIsReportedAsSuch() throws {
        var built = MediaFixtures.makeMP3(Options(lameExtension: true))
        built.data[21 + 154] ^= 0xFF
        let url = try makeTempDir().appendingPathComponent("book.mp3")
        try built.data.write(to: url)
        #expect(try MP3FrameScan.measure(url).vbrHeader.xing?.lame?.crcIsValid == false)
    }

    @Test func vbriHeader() throws {
        let measured = try expectAccurate(Options(header: .vbri, statedFrames: 100, statedBytes: 41_700))
        #expect(measured.vbrHeader == .vbri(statedFrames: 100, statedBytes: 41_700))
    }

    @Test func noHeaderCountsTheFirstFrameAsAudio() throws {
        let measured = try expectAccurate(Options(header: .none))
        #expect(measured.vbrHeader == .none)
    }

    @Test func id3v2TagWithACoverInFront() throws {
        let cover = MediaFixtures.makeImage(.jpeg, size: 256)
        let tag = MediaFixtures.id3v23Tag(frames: [
            ("TIT2", MediaFixtures.id3Text("Title")), ("APIC", MediaFixtures.id3Picture(cover, mime: "image/jpeg", type: 3)),
        ])
        let measured = try expectAccurate(Options(statedFrames: 100, statedBytes: 41_700, prefix: tag))
        #expect(measured.audioRange.lowerBound == UInt64(tag.count))
    }

    @Test func id3v1TagAtTheEndIsNotAudio() throws {
        let (url, built) = try make(Options(statedFrames: 100, id3v1: true))
        let measured = try MP3FrameScan.measure(url)
        #expect(measured.frameCount == built.frameCount)
        #expect(measured.audioRange.upperBound == UInt64(built.data.count - 128))
        #expect(measured.junkBytes == 0)
        #expect(try MP3FrameScan.open(url).tailStart == UInt64(built.data.count - 128))
    }

    @Test func apeAndLyricsTagsAtTheEndAreNotAudio() throws {
        var built = MediaFixtures.makeMP3(Options(seconds: 5, header: .none))
        let audioEnd = built.data.count
        // APE: header, one item's worth of bytes, footer; then Lyrics3 v2; then ID3v1.
        var footer = Data("APETAGEX".utf8)
        footer.append(contentsOf: [0xD0, 0x07, 0, 0])  // version 2000
        footer.append(contentsOf: [32 + 20, 0, 0, 0])  // size: items and footer
        footer.append(contentsOf: [1, 0, 0, 0])
        footer.append(contentsOf: [0, 0, 0, 0x80])  // has a header
        footer.append(Data(count: 8))
        built.data.append(footer)  // stands in for the header: same size
        built.data.append(Data(repeating: 0x41, count: 20))
        built.data.append(footer)
        let lyrics = Data("LYRICSBEGININD0000200".utf8)
        built.data.append(lyrics)
        built.data.append(Data(String(format: "%06dLYRICS200", lyrics.count).utf8))
        var id3v1 = Data("TAG".utf8)
        id3v1.append(Data(count: 125))
        built.data.append(id3v1)
        let url = try makeTempDir().appendingPathComponent("book.mp3")
        try built.data.write(to: url)

        let measured = try MP3FrameScan.measure(url)
        #expect(measured.frameCount == built.frameCount)
        #expect(measured.audioRange.upperBound == UInt64(audioEnd))
        #expect(measured.junkBytes == 0)
    }

    @Test func mpeg2At22kHz() throws {
        let measured = try expectAccurate(Options(statedFrames: 100, statedBytes: 20_800, mpeg2: true))
        #expect(measured.sampleRate == 22_050)
        #expect(measured.frameCount == 2297)  // 576 samples a frame
        #expect(measured.vbrHeader.xing?.offsetInFrame == 13)
        #expect(measured.vbrHeader.xing?.hasRoomForRepair == true)
    }

    @Test func framesOfDifferentBitrates() throws {
        let measured = try expectAccurate(Options(statedFrames: 100, variableBitrate: true))
        #expect(measured.audioRange.count < 2298 * 417)
    }

    @Test func junkBetweenFramesIsSteppedOver() throws {
        // The junk holds a lone frame header, which must not be taken for a frame.
        var junk = Data(repeating: 0x55, count: 700)
        junk.replaceSubrange(100..<104, with: [0xFF, 0xFB, 0x90, 0xC4])
        let (url, built) = try make(Options(statedFrames: 100, junk: (afterFrame: 500, bytes: junk)))
        let measured = try MP3FrameScan.measure(url, recordingOffsets: true)
        #expect(measured.frameCount == built.frameCount)
        #expect(measured.junkBytes == 700)
        #expect(measured.frameOffsets == built.frameOffsets.map(UInt64.init))
        #expect(measured.audioRange.upperBound == UInt64(built.audioRange.upperBound))
    }

    /// Files joined end to end carry each part's tags, and its cover, in the middle.
    @Test func wholeTagsBetweenFramesAreSteppedOverWhateverTheirSize() throws {
        let picture = Data(repeating: 0x37, count: 3 * MP3FrameScan.junkTolerance)
        var tags = MediaFixtures.id3v23Tag(frames: [
            ("TIT2", MediaFixtures.id3Text("Part 2")), ("APIC", MediaFixtures.id3Picture(picture, mime: "image/jpeg", type: 3)),
        ])
        let id3v2 = tags.count
        var id3v1 = Data("TAG".utf8)
        id3v1.append(Data(count: 125))
        // The first part's ID3v1 tag, then the second part's ID3v2 tag.
        tags = id3v1 + tags
        let (url, built) = try make(Options(statedFrames: 100, statedBytes: 41_700, junk: (afterFrame: 500, bytes: tags)))

        let measured = try MP3FrameScan.measure(url, recordingOffsets: true)

        #expect(measured.frameCount == built.frameCount)
        #expect(measured.frameOffsets == built.frameOffsets.map(UInt64.init))
        #expect(measured.junkBytes == 0)
        #expect(measured.embeddedTagBytes == id3v2 + 128)
        #expect(measured.audioRange == UInt64(built.audioRange.lowerBound)..<UInt64(built.audioRange.upperBound))
    }

    /// Frames in pairs, each pair behind a tag header whose size reaches into one long
    /// run of empty tags that ends in nothing: every pair sends the scan down the run.
    static func tagMaze(groups: Int, emptyTags: Int) -> Data {
        var frame = Data([0xFF, 0xFB, 0x90, 0xC4])
        frame.append(Data(count: 413))
        var data = frame + frame
        let group = 10 + 2 * frame.count
        let run = data.count + groups * group
        for index in 0..<groups {
            let size = run - (2 * frame.count + index * group + 10)
            data.append(Data("ID3".utf8))
            data.append(contentsOf: [3, 0, 0] + [21, 14, 7, 0].map { UInt8(size >> $0 & 0x7F) })
            data.append(frame + frame)
        }
        let empty = Data("ID3".utf8) + Data([3, 0, 0, 0, 0, 0, 0])
        data.reserveCapacity(data.count + emptyTags * empty.count + 16)
        for _ in 0..<emptyTags { data.append(empty) }
        data.append(Data(repeating: 0x55, count: 16))
        return data
    }

    // Before runs of tags were limited and remembered this took a time that grew with
    // groups times tags: a minute for this file.
    @Test func aRunOfTagsThatLeadsNowhereIsWalkedOnce() throws {
        let url = try write(Self.tagMaze(groups: 800, emptyTags: 400_000))
        let started = Date()
        #expect(throws: MP3FrameScan.Failure.syncLost) { try MP3FrameScan.measure(url) }
        #expect(Date().timeIntervalSince(started) < 20)
    }

    @Test func tagsOneAfterAnotherAreSteppedOverUpToALimit() throws {
        let built = MediaFixtures.makeMP3(Options(seconds: 4))
        let empty = Data("ID3".utf8) + Data([3, 0, 0, 0, 0, 0, 0])
        func file(tags: Int) -> Data {
            var data = built.data
            data.insert(contentsOf: Data((0..<tags).flatMap { _ in empty }), at: built.frameOffsets[50])
            return data
        }
        let within = try MP3FrameScan.measure(try write(file(tags: MP3FrameScan.embeddedTagLimit)))
        #expect(within.frameCount == built.frameCount)
        #expect(within.embeddedTagBytes == MP3FrameScan.embeddedTagLimit * 10)
        #expect(within.junkBytes == 0)
        // One more, and they are bytes that are not audio like any others.
        let beyond = try MP3FrameScan.measure(try write(file(tags: MP3FrameScan.embeddedTagLimit + 1)))
        #expect(beyond.frameCount == built.frameCount)
        #expect(beyond.embeddedTagBytes == 0)
        #expect(beyond.junkBytes == (MP3FrameScan.embeddedTagLimit + 1) * 10)
    }

    @Test func somethingThatOnlyLooksLikeATagIsJunk() throws {
        // "ID3" and a size, but no frame where the tag would end.
        var junk = Data("ID3".utf8)
        junk.append(contentsOf: [3, 0, 0, 0, 0, 2, 0])
        junk.append(Data(repeating: 0x55, count: 600))
        let (url, built) = try make(Options(junk: (afterFrame: 500, bytes: junk)))
        let measured = try MP3FrameScan.measure(url)
        #expect(measured.frameCount == built.frameCount)
        #expect(measured.junkBytes == 610)
        #expect(measured.embeddedTagBytes == 0)
    }

    @Test func aLastFrameCutShortIsNotCounted() throws {
        var built = MediaFixtures.makeMP3(Options(seconds: 10, header: .none))
        built.data.removeLast(100)
        let url = try makeTempDir().appendingPathComponent("book.mp3")
        try built.data.write(to: url)
        let measured = try MP3FrameScan.measure(url)
        #expect(measured.frameCount == built.frameCount - 1)
        #expect(measured.junkBytes == 317)
    }

    // MARK: Files that cannot be measured

    @Test func tooMuchJunkCannotBeMeasured() throws {
        let junk = Data(repeating: 0x55, count: MP3FrameScan.junkTolerance + 1)
        let (url, _) = try make(Options(junk: (afterFrame: 500, bytes: junk)))
        #expect(throws: MP3FrameScan.Failure.syncLost) { try MP3FrameScan.measure(url) }
    }

    @Test func aLongTailThatIsNotAudioCannotBeMeasured() throws {
        var built = MediaFixtures.makeMP3(Options(seconds: 10))
        built.data.append(Data(repeating: 0, count: MP3FrameScan.junkTolerance + 1))
        let url = try makeTempDir().appendingPathComponent("book.mp3")
        try built.data.write(to: url)
        #expect(throws: MP3FrameScan.Failure.syncLost) { try MP3FrameScan.measure(url) }
    }

    @Test func freeFormatIsRefused() throws {
        // Bitrate index 0: the frame does not say how long it is.
        var data = Data()
        for _ in 0..<50 {
            data.append(contentsOf: [0xFF, 0xFB, 0x00, 0xC4])
            data.append(Data(count: 413))
        }
        let url = try makeTempDir().appendingPathComponent("free.mp3")
        try data.write(to: url)
        #expect(throws: MP3FrameScan.Failure.freeFormat) { try MP3FrameScan.measure(url) }
        #expect(throws: MP3FrameScan.Failure.freeFormat) { try MP3FrameScan.open(url) }
    }

    @Test func aFileThatIsNotAudioIsRefused() throws {
        let dir = try makeTempDir()
        let text = dir.appendingPathComponent("text.mp3")
        try Data(repeating: 0x20, count: 5000).write(to: text)
        #expect(throws: MP3FrameScan.Failure.noAudio) { try MP3FrameScan.measure(text) }
        let empty = dir.appendingPathComponent("empty.mp3")
        try Data().write(to: empty)
        #expect(throws: MP3FrameScan.Failure.noAudio) { try MP3FrameScan.measure(empty) }
        #expect(throws: MP3FrameScan.Failure.unreadable) {
            try MP3FrameScan.measure(dir.appendingPathComponent("missing.mp3"))
        }
        #expect(throws: MP3FrameScan.Failure.unreadable) { try MP3FrameScan.measure(dir) }
    }

    // MARK: Other layers

    @Test func layerIAndLayerIIFramesAreMeasuredByTheirOwnRules() throws {
        // Layer II, MPEG-1, 192 kbit/s, 44.1 kHz: 144 * 192000 / 44100 = 626 bytes, 1152 samples.
        var layer2 = Data()
        for _ in 0..<40 {
            layer2.append(contentsOf: [0xFF, 0xFD, 0xA0, 0xC4])
            layer2.append(Data(count: 622))
        }
        // Layer I, MPEG-1, 128 kbit/s, 44.1 kHz: (12 * 128000 / 44100) * 4 = 136 bytes, 384 samples.
        var layer1 = Data()
        for _ in 0..<40 {
            layer1.append(contentsOf: [0xFF, 0xFF, 0x40, 0xC4])
            layer1.append(Data(count: 132))
        }
        let dir = try makeTempDir()
        let second = dir.appendingPathComponent("two.mp3")
        let first = dir.appendingPathComponent("one.mp3")
        try layer2.write(to: second)
        try layer1.write(to: first)

        let two = try MP3FrameScan.measure(second)
        #expect(two.frameCount == 40)
        #expect(two.totalSamples == 40 * 1152)
        #expect(two.audioRange == 0..<UInt64(layer2.count))
        let one = try MP3FrameScan.measure(first)
        #expect(one.frameCount == 40)
        #expect(one.totalSamples == 40 * 384)
        #expect(one.audioRange == 0..<UInt64(layer1.count))
    }

    @Test func headerArithmetic() {
        typealias Header = MP3FrameScan.Header
        #expect(Header.frameLength(0xFFFB_90C4) == 417)
        #expect(Header.frameLength(0xFFFB_92C4) == 418)  // padded
        #expect(Header.frameLength(0xFFF3_80C4) == 208)  // MPEG-2, 64 kbit/s, 22.05 kHz
        #expect(Header.frameLength(0xFFE3_80C4) == 417)  // MPEG-2.5, 64 kbit/s, 11.025 kHz
        #expect(Header.frameLength(0xFFFB_F0C4) == nil)  // bitrate index 15
        #expect(Header.frameLength(0xFFFB_9CC4) == nil)  // sample-rate index 3
        #expect(Header.frameLength(0xFFEB_90C4) == nil)  // reserved version
        #expect(Header.frameLength(0xFFF9_90C4) == nil)  // reserved layer
        #expect(Header.frameLength(0x7FFB_90C4) == nil)  // no sync
        #expect(Header.samplesPerFrame(0xFFF3_80C4) == 576)
        #expect(Header.sideInfoLength(0xFFFB_9004) == 32)  // MPEG-1 stereo
        #expect(Header.sideInfoLength(0xFFF3_8004) == 17)  // MPEG-2 stereo
    }

    @Test func checksumIsTheOneLAMEUses() {
        // CRC-16/ARC of "123456789" is 0xBB3D.
        #expect(MP3FrameScan.crc16(Array("123456789".utf8)) == 0xBB3D)
        #expect(MediaFixtures.crc16(Data("123456789".utf8)) == 0xBB3D)
    }

    // MARK: Size

    /// A file of the size the fault was found on: 49.5 MB, 72.8 minutes.
    @Test func aFiftyMegabyteFileIsMeasuredQuickly() throws {
        let (url, built) = try make(.wrongHeader(seconds: 72.8 * 60))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(built.data.count > 49_000_000)
        let started = Date()
        let measured = try MP3FrameScan.measure(url)
        let took = Date().timeIntervalSince(started)
        #expect(measured.frameCount == built.frameCount)
        #expect(took < 20)
        print("MP3FrameScan: \(built.data.count) bytes, \(measured.frameCount) frames in \(Int(took * 1000)) ms")
    }
}
