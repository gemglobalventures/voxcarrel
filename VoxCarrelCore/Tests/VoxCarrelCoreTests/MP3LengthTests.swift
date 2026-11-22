import AVFoundation
import CTagBridge
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// Counts the scans made of the files it is given to.
final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var scans = 0

    var count: Int { lock.withLock { scans } }

    var scan: MP3Length.Scan {
        { url in
            self.lock.withLock { self.scans += 1 }
            return try MP3FrameScan.measure(url)
        }
    }
}

@Suite struct MP3LengthTests {
    typealias Options = MediaFixtures.MP3Options

    func write(_ options: Options, name: String = "book.mp3") throws -> URL {
        let url = try makeTempDir().appendingPathComponent(name)
        try MediaFixtures.makeMP3(options).data.write(to: url)
        return url
    }

    /// 60 s of audio is 2297 frames of 1152 samples at 44.1 kHz; 100 frames are 2.6 s.
    static let trueSeconds = 2297.0 * 1152 / 44_100
    static let statedSeconds = 100.0 * 1152 / 44_100

    // MARK: The fault as other readers see it

    @Test func theFixtureReproducesTheFault() async throws {
        let url = try write(.wrongHeader())
        #expect(abs(try CTBTagFile.readMP3(atPath: url.path).durationSeconds - Self.statedSeconds) < 0.01)
        #expect(abs(try await MediaFixtures.avDuration(url) - Self.statedSeconds) < 0.01)
        // Apple's decoder stops where the header says the audio ends.
        #expect(Double(try MediaFixtures.decodedFrameCount(url)) / 44_100 < 4)
    }

    // MARK: Reading

    @Test func aWrongXingHeaderGivesTheTrueLengthAndSaysSo() throws {
        let url = try write(.wrongHeader())
        let counter = ScanCounter()
        let contents = try AudioTagIO.read(url, scan: counter.scan)
        #expect(counter.count == 1)
        #expect(abs(try #require(contents.metadata.durationSeconds) - Self.trueSeconds) < 0.001)
        let problem = try #require(contents.lengthProblem)
        #expect(abs(problem.statedSeconds - Self.statedSeconds) < 0.01)
        #expect(abs(problem.trueSeconds - Self.trueSeconds) < 0.001)
        #expect(problem.repairable)
        // The one entry point the rest of the engine uses gives the same.
        #expect(try FileMetadataIO().read(url) == contents)
        #expect(try FileMetadataIO().readMetadata(at: url).durationSeconds == contents.metadata.durationSeconds)
    }

    @Test func aHealthyFileIsNotScanned() throws {
        let counter = ScanCounter()
        let tag = MediaFixtures.id3v23Tag(frames: [
            ("TIT2", MediaFixtures.id3Text("Title")),
            ("APIC", MediaFixtures.id3Picture(MediaFixtures.makeImage(.png, size: 1024), mime: "image/png", type: 3)),
        ])
        let healthy: [Options] = [
            Options(), Options(header: .info), Options(header: .vbri), Options(header: .none),
            Options(lameExtension: true), Options(mpeg2: true), Options(variableBitrate: true),
            Options(id3v1: true),
            // A short file with a large cover in front: the picture is not audio.
            Options(seconds: 2, prefix: tag), Options(seconds: 2, header: .none, prefix: tag),
        ]
        for options in healthy {
            let url = try write(options)
            let contents = try AudioTagIO.read(url, scan: counter.scan)
            #expect(contents.lengthProblem == nil)
            #expect(contents.metadata.durationSeconds == (try CTBTagFile.readMP3(atPath: url.path).durationSeconds))
        }
        let plain = try makeTempDir().appendingPathComponent("plain.mp3")
        try MediaFixtures.makeSilentMP3(seconds: 3, id3v23Title: "Title").write(to: plain)
        #expect(try AudioTagIO.read(plain, scan: counter.scan).lengthProblem == nil)
        #expect(counter.count == 0)
    }

    @Test func aFileWithoutAnMP3ExtensionIsNeverScanned() throws {
        let url = try makeTempDir().appendingPathComponent("book.m4b")
        try MediaFixtures.makeAAC(at: url, seconds: 1)
        let counter = ScanCounter()
        #expect(try AudioTagIO.read(url, scan: counter.scan).lengthProblem == nil)
        #expect(counter.count == 0)
    }

    @Test func everyKindOfWrongHeaderIsMeasured() throws {
        let cases: [(Options, repairable: Bool)] = [
            (Options(header: .info, statedFrames: 100, statedBytes: 41_700), true),
            (Options(statedFrames: 100, statedBytes: 41_700, lameExtension: true), true),
            (Options(header: .vbri, statedFrames: 100, statedBytes: 41_700), false),
            (Options(statedFrames: 100, statedBytes: 41_700, id3v1: true), true),
            (Options(statedFrames: 100, statedBytes: 41_700, variableBitrate: true), true),
            // Far too long instead of far too short.
            (Options(statedFrames: 4_000_000), true),
        ]
        for (options, repairable) in cases {
            let contents = try AudioTagIO.read(try write(options))
            let problem = try #require(contents.lengthProblem)
            #expect(problem.repairable == repairable)
            #expect(abs(problem.trueSeconds - Self.trueSeconds) < 0.001)
            #expect(contents.metadata.durationSeconds == problem.trueSeconds)
        }
    }

    @Test func mpeg2FileWithAWrongHeader() throws {
        let contents = try AudioTagIO.read(try write(Options(statedFrames: 100, statedBytes: 20_800, mpeg2: true)))
        let problem = try #require(contents.lengthProblem)
        #expect(abs(problem.trueSeconds - 2297.0 * 576 / 22_050) < 0.001)
        #expect(abs(problem.statedSeconds - 100.0 * 576 / 22_050) < 0.01)
        #expect(problem.repairable)
    }

    /// The tag library sets aside a header that has no byte count and works the length out
    /// from the file's size; Apple's players go by the header's frame count all the same.
    @Test func aHeaderTheTagLibraryIgnoresIsStillFound() async throws {
        let url = try write(Options(statedFrames: 100, xingFlags: 1))
        #expect(try CTBTagFile.readMP3(atPath: url.path).durationSeconds > 59)
        #expect(try await MediaFixtures.avDuration(url) < 3)
        let problem = try #require(try AudioTagIO.read(url).lengthProblem)
        #expect(abs(problem.statedSeconds - Self.statedSeconds) < 0.01)
        #expect(abs(problem.trueSeconds - Self.trueSeconds) < 0.001)
        #expect(problem.repairable)
    }

    @Test func aWrongByteCountAloneIsMeasuredButIsNoProblem() throws {
        let url = try write(Options(statedBytes: 500_000))
        let counter = ScanCounter()
        let contents = try AudioTagIO.read(url, scan: counter.scan)
        #expect(counter.count == 1)
        #expect(contents.lengthProblem == nil)
        #expect(abs(try #require(contents.metadata.durationSeconds) - Self.trueSeconds) < 0.001)
    }

    @Test func aFileThatCannotBeMeasuredKeepsItsStatedLength() throws {
        let junk = Data(repeating: 0x55, count: MP3FrameScan.junkTolerance + 1)
        let url = try write(Options(statedFrames: 100, statedBytes: 41_700, junk: (afterFrame: 500, bytes: junk)))
        let counter = ScanCounter()
        let contents = try AudioTagIO.read(url, scan: counter.scan)
        #expect(counter.count == 1)
        #expect(contents.lengthProblem == nil)
        #expect(abs(try #require(contents.metadata.durationSeconds) - Self.statedSeconds) < 0.01)
    }

    // MARK: The decision

    @Test func plausibilityBounds() {
        // 1 MB in 60 s is 133 kbit/s.
        #expect(MP3Length.isPlausible(seconds: 60, audioBytes: 1_000_000))
        #expect(MP3Length.isPlausible(seconds: 20.1, audioBytes: 1_000_000))  // just under 400 kbit/s
        #expect(!MP3Length.isPlausible(seconds: 19.9, audioBytes: 1_000_000))
        #expect(MP3Length.isPlausible(seconds: 1300, audioBytes: 1_000_000))  // just over 6 kbit/s
        #expect(!MP3Length.isPlausible(seconds: 1400, audioBytes: 1_000_000))
        #expect(!MP3Length.isPlausible(seconds: 0, audioBytes: 1_000_000))
        // The file the fault was found on: 49.5 MB said to last 42 s.
        #expect(!MP3Length.isPlausible(seconds: 42, audioBytes: 49_500_000))
        #expect(MP3Length.isPlausible(seconds: 72.8 * 60, audioBytes: 49_500_000))
    }

    // A header wrong by a factor that leaves the bitrate one an MP3 can have: only the
    // frames themselves, sampled across the file, show it.
    @Test func aWrongHeaderInsideThePlausibleBandIsFound() throws {
        let cases: [(Options, trueSeconds: Double)] = [
            // 128 kbit/s stating half and a third: 256 and 384 kbit/s.
            (Options(seconds: 600, statedFrames: 11_484), 22_969 * 1152.0 / 44_100),
            (Options(seconds: 600, statedFrames: 7_700), 22_969 * 1152.0 / 44_100),
            (Options(seconds: 600, header: .info, statedFrames: 11_484), 22_969 * 1152.0 / 44_100),
            // 64 kbit/s MPEG-2 stating a fifth, and four times too much.
            (Options(seconds: 600, statedFrames: 4_600, mpeg2: true), 22_969 * 576.0 / 22_050),
            (Options(seconds: 600, statedFrames: 91_876, mpeg2: true), 22_969 * 576.0 / 22_050),
            // A variable bitrate stating half.
            (Options(seconds: 600, statedFrames: 11_484, variableBitrate: true), 22_969 * 1152.0 / 44_100),
        ]
        for (options, trueSeconds) in cases {
            let url = try write(options)
            // The stated length is one the file's size allows.
            let stated = try CTBTagFile.readMP3(atPath: url.path).durationSeconds
            let opening = try MP3FrameScan.open(url)
            #expect(MP3Length.isPlausible(seconds: stated, audioBytes: opening.audioBytes))

            let counter = ScanCounter()
            let contents = try AudioTagIO.read(url, scan: counter.scan)
            #expect(counter.count == 1)
            let problem = try #require(contents.lengthProblem)
            #expect(abs(problem.statedSeconds - stated) < 0.01)
            #expect(abs(problem.trueSeconds - trueSeconds) < 0.001)
            #expect(contents.metadata.durationSeconds == problem.trueSeconds)
            #expect(problem.repairable)
        }
    }

    @Test func theSampledBitrateIsTheAverageOverTime() throws {
        // Constant: every frame is 417 bytes of 1152 samples at 44.1 kHz.
        let constant = try #require(try MP3FrameScan.open(try write(Options(seconds: 600))).sampledKbps)
        #expect(abs(constant - 417 * 8 * 44.1 / 1152) < 0.01)
        // Half the time at 128 and half at 32 kbit/s is 80 on average, though four fifths
        // of the bytes are at 128.
        let varying = try #require(
            try MP3FrameScan.open(try write(Options(seconds: 600, variableBitrate: true))).sampledKbps)
        #expect(abs(varying - 80) < 80 * 0.15)
    }

    @Test func aLongHealthyFileIsNotScannedWhateverItsBitrateDoes() throws {
        let counter = ScanCounter()
        for options in [
            Options(seconds: 600), Options(seconds: 600, header: .info), Options(seconds: 600, variableBitrate: true),
            Options(seconds: 600, mpeg2: true, variableBitrate: true), Options(seconds: 600, header: .vbri),
        ] {
            #expect(try AudioTagIO.read(try write(options), scan: counter.scan).lengthProblem == nil)
        }
        #expect(counter.count == 0)
    }

    @Test func theCheapLookReadsLittle() throws {
        // Ten minutes, 9.6 MB, behind a cover of a megabyte.
        let tag = MediaFixtures.id3v23Tag(frames: [
            ("APIC", MediaFixtures.id3Picture(Data(count: 1_000_000), mime: "image/jpeg", type: 3)),
        ])
        let url = try write(Options(seconds: 600, prefix: tag, id3v1: true))
        var reads: [Int] = []
        _ = try MP3FrameScan.open(url) { reads.append($0) }
        #expect(reads.count <= 16)
        #expect(reads.reduce(0, +) <= 200_000)
    }

    @Test func aSmallDifferenceIsNotAProblem() {
        #expect(!MP3Length.differs(stated: 3600, measured: 3630))  // under 1%
        #expect(MP3Length.differs(stated: 3600, measured: 3700))
        #expect(!MP3Length.differs(stated: 10, measured: 10.9))  // under a second
        #expect(MP3Length.differs(stated: 10, measured: 11.5))
    }

    // MARK: Writing tags

    @Test func aTagWriteToAFileWithAWrongHeaderPassesItsChecks() throws {
        let url = try write(.wrongHeader())
        let before = try AudioTagIO.read(url)
        var metadata = BookMetadata(title: "The Book", authors: ["An Author"])
        metadata.summary = String(repeating: "A long description. ", count: 500)
        let cover = CoverImage(data: MediaFixtures.makeImage(.jpeg, size: 512), mime: "image/jpeg")
        try AudioTagIO.write(metadata, cover: .set(cover), part: nil, to: url)

        let after = try AudioTagIO.read(url)
        #expect(after.metadata.title == "The Book")
        #expect(after.cover == cover)
        #expect(after.metadata.durationSeconds == before.metadata.durationSeconds)
        #expect(after.lengthProblem == before.lengthProblem)
        // And again, now that the file has a tag of its own to be replaced.
        metadata.title = "Another Title"
        try AudioTagIO.write(metadata, cover: .remove, part: nil, to: url)
        #expect(try AudioTagIO.read(url).lengthProblem == before.lengthProblem)
    }
}
