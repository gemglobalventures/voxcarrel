import CTagBridge
import CryptoKit
import Foundation

/// What undo needs to put one repaired file back: the first frame as it was.
struct HeaderRepairState: Codable, Equatable {
    /// Absolute path of the file.
    var pathAfter: String
    /// Where the first frame begins in the file.
    var frameOffset: UInt64
    /// The whole first frame before the repair.
    var originalFrame: Data
    /// SHA-256 of the whole file before the repair, in hexadecimal.
    var originalSHA256: String
}

/// Rewrites the length header of an MP3 whose header states the wrong length: the frame
/// count, the byte count and the seek table of the Xing/Info header in its first frame,
/// and the checksum of a LAME extension that had a valid one. Nothing else in the file
/// changes, and the file is never changed in place (`SafeFileUpdate`).
struct MP3HeaderRepair {
    /// Why a file's header cannot be repaired, in words that follow "cannot be repaired: ".
    struct Refusal: Error, Equatable {
        var reason: String

        static let noHeader = Refusal(reason: "it is not of a kind that can be rewritten")
        static let noRoom = Refusal(reason: "it has no room for the right values")
        static let unmeasurable = Refusal(reason: "the audio could not be measured")
    }

    /// The new first frame, worked out before anything is written.
    struct Plan: Equatable {
        var firstFrame: Range<UInt64>
        var original: Data
        var patched: Data
        /// The only bytes of the frame that may differ afterwards, as offsets within it.
        var changeable: [Range<Int>]
        var frameCount: Int
        var audioBytes: UInt64
    }

    // Each step can be replaced, so that a test can make any one of the checks fail.

    /// Writes the plan's frame into the working copy.
    var change: (_ copy: URL, _ plan: Plan) throws -> Void = MP3HeaderRepair.write
    var read: (URL) throws -> FileContents = { try AudioTagIO.read($0) }
    var measure: (URL) throws -> MP3FrameScan.Measurement = { try MP3FrameScan.measure($0, recordingOffsets: true) }
    /// How long the system's players say the file is; nil when they cannot say.
    var playbackSeconds: (URL) -> Double? = { url in
        let seconds = CTBMediaProbe.preciseDuration(atPath: url.path)
        return seconds >= 0 ? seconds : nil
    }

    // MARK: Repair

    /// Repairs the header of the file at `url`.
    ///
    /// The working copy replaces the file only when all of this has been shown:
    /// 1. every byte outside the first frame is the same as in the original, and in the
    ///    first frame only the header's fields, its seek table and the checksum differ;
    /// 2. the tags, the cover, the chapters and the track tags read back the same;
    /// 3. the frames count the same as before, and the header now states that count and
    ///    the right number of bytes, so the tag library reads the true length;
    /// 4. AVFoundation gives a length within 1% or one second of the measured one.
    ///
    /// - Returns: What undo needs; nil when the header already states the right length
    ///   and nothing was changed.
    /// - Throws: `Refusal` for a file that cannot be repaired;
    ///   `MetadataIOError.verificationFailed` when a check fails; what `SafeFileUpdate`
    ///   throws for a file that may not be changed. In every case the file is untouched.
    func repair(_ url: URL) throws -> HeaderRepairState? {
        let before = try read(url)
        let trackBefore = try AudioTagIO.readTrackTags(url)
        let measured: MP3FrameScan.Measurement
        do {
            measured = try measure(url)
        } catch {
            throw Refusal.unmeasurable
        }
        // A header that states the right counts and has a seek table is left alone,
        // whatever its seek table says: the encoder's own is as good as any.
        if let xing = measured.vbrHeader.xing, xing.hasTOC,
           xing.statedFrames.map(Int.init) == measured.frameCount,
           xing.statedBytes.map(Int.init) == measured.audioRange.count {
            return nil
        }
        let frame = try Self.bytes(of: url, in: measured.firstFrame)
        let plan = try Self.plan(for: measured, frame: frame)
        guard plan.patched != plan.original else { return nil }

        var originalHash = ""
        try SafeFileUpdate.update(url) { copy in
            try change(copy, plan)
        } verify: { copy in
            originalHash = try Self.checkBytes(original: url, copy: copy, plan: plan)
            try checkTags(of: copy, before: before, trackBefore: trackBefore)
            try checkFrames(of: copy, before: measured)
            try checkPlayback(of: copy, seconds: measured.durationSeconds)
        }
        return HeaderRepairState(
            pathAfter: url.path, frameOffset: plan.firstFrame.lowerBound, originalFrame: plan.original,
            originalSHA256: originalHash)
    }

    /// Puts the first frame back as it was before a repair. The file is replaced only
    /// when it is then, byte for byte, the file the repair started from.
    /// - Throws: `MetadataIOError.verificationFailed` when the file has been changed since
    ///   the repair; the file is then left as it is.
    func restore(_ state: HeaderRepairState, at url: URL) throws {
        try SafeFileUpdate.update(url) { copy in
            let size = (try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? UInt64) ?? 0
            guard state.frameOffset + UInt64(state.originalFrame.count) <= size else {
                throw MetadataIOError.verificationFailed("the file has changed since its header was repaired")
            }
            try Self.write(state.originalFrame, at: state.frameOffset, in: copy)
        } verify: { copy in
            guard try Self.sha256(of: copy) == state.originalSHA256 else {
                throw MetadataIOError.verificationFailed("the file has changed since its header was repaired")
            }
        }
    }

    // MARK: The plan

    /// The first frame with a header that says what was measured.
    /// - Parameter frame: The first frame as it is.
    static func plan(for measured: MP3FrameScan.Measurement, frame: Data) throws -> Plan {
        guard let xing = measured.vbrHeader.xing else { throw Refusal.noHeader }
        guard xing.hasRoomForRepair, frame.count == measured.firstFrame.count,
              measured.frameOffsets.count == measured.frameCount, measured.frameCount > 0,
              let frames = UInt32(exactly: measured.frameCount),
              let bytes = UInt32(exactly: measured.audioRange.count)
        else { throw Refusal.noRoom }

        var out = [UInt8](frame)
        let at = xing.offsetInFrame
        func put(_ value: UInt32, at offset: Int) {
            out[offset] = UInt8(value >> 24)
            out[offset + 1] = UInt8(value >> 16 & 0xFF)
            out[offset + 2] = UInt8(value >> 8 & 0xFF)
            out[offset + 3] = UInt8(value & 0xFF)
        }
        // The fields come in a fixed order, each present only when its flag is set:
        // frame count, byte count, seek table, quality.
        let hadAll = xing.flags & 0x07 == 0x07
        var quality: [UInt8]?
        if xing.flags & 0x08 != 0 {
            let was = at + 8 + (xing.flags & 1 != 0 ? 4 : 0) + (xing.flags & 2 != 0 ? 4 : 0)
                + (xing.flags & 4 != 0 ? 100 : 0)
            quality = Array(out[was..<was + 4])
        }
        put(xing.flags | 0x07, at: at + 4)
        put(frames, at: at + 8)
        put(bytes, at: at + 12)
        // Seek table: where, as a 256th of the stream's bytes, each hundredth of its
        // frames begins.
        let start = measured.audioRange.lowerBound
        for entry in 0..<100 {
            let index = min(measured.frameCount - 1, entry * measured.frameCount / 100)
            let position = measured.frameOffsets[index] - start
            out[at + 16 + entry] = UInt8(min(255, position * 256 / UInt64(bytes)))
        }
        var changeable = [at + 4..<at + 116]
        if let quality, !hadAll {
            // The quality follows the seek table: it moves along into bytes that were empty.
            out.replaceSubrange(at + 116..<at + 120, with: quality)
            changeable = [at + 4..<at + 120]
        }
        // A checksum that was right is made right again; one that was not is left alone.
        if let lame = xing.lame, lame.crcIsValid {
            let crc = MP3FrameScan.crc16(out[..<(at + 154)])
            out[at + 154] = UInt8(crc >> 8)
            out[at + 155] = UInt8(crc & 0xFF)
            changeable.append(at + 154..<at + 156)
        }
        return Plan(
            firstFrame: measured.firstFrame, original: frame, patched: Data(out), changeable: changeable,
            frameCount: measured.frameCount, audioBytes: UInt64(bytes))
    }

    // MARK: Checks

    /// Check 1. Compares the two files from end to end.
    /// - Returns: SHA-256 of the original, in hexadecimal.
    static func checkBytes(original: URL, copy: URL, plan: Plan) throws -> String {
        func failed(_ what: String) -> MetadataIOError { .verificationFailed(what) }
        let a = try FileHandle(forReadingFrom: original)
        defer { try? a.close() }
        let b = try FileHandle(forReadingFrom: copy)
        defer { try? b.close() }
        let frameStart = Int(plan.firstFrame.lowerBound)
        let frameEnd = Int(plan.firstFrame.upperBound)

        var hash = SHA256()
        var position = 0
        var copiedFrame = Data()
        while true {
            let one = try a.read(upToCount: 1 << 20) ?? Data()
            let two = try b.read(upToCount: 1 << 20) ?? Data()
            guard one.count == two.count else { throw failed("the file's size changed") }
            if one.isEmpty { break }
            hash.update(data: one)
            let chunk = position..<position + one.count
            if chunk.upperBound <= frameStart || chunk.lowerBound >= frameEnd {
                guard one == two else { throw failed("bytes outside the first frame changed") }
            } else {
                let within = max(chunk.lowerBound, frameStart) - position..<min(chunk.upperBound, frameEnd) - position
                guard one[..<within.lowerBound] == two[..<within.lowerBound],
                      one[within.upperBound...] == two[within.upperBound...]
                else { throw failed("bytes outside the first frame changed") }
                var (left, right) = ([UInt8](one[within]), [UInt8](two[within]))
                copiedFrame.append(contentsOf: right)
                // Within the frame, the bytes that may differ are set aside.
                let frameOffset = position + within.lowerBound - frameStart
                for range in plan.changeable {
                    for offset in range where left.indices.contains(offset - frameOffset) {
                        left[offset - frameOffset] = 0
                        right[offset - frameOffset] = 0
                    }
                }
                guard left == right else {
                    throw failed("bytes other than the length header's fields changed")
                }
            }
            position += one.count
        }
        guard copiedFrame == plan.patched else { throw failed("the first frame is not as it was meant to be") }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Check 2.
    func checkTags(of copy: URL, before: FileContents, trackBefore: TrackTags) throws {
        let after: FileContents
        let trackAfter: TrackTags
        do {
            after = try read(copy)
            trackAfter = try AudioTagIO.readTrackTags(copy)
        } catch {
            throw MetadataIOError.verificationFailed("the changed copy no longer reads as audio")
        }
        var (was, now) = (before.metadata, after.metadata)
        was.durationSeconds = nil
        now.durationSeconds = nil
        guard was == now, after.cover == before.cover, after.chapters == before.chapters, trackAfter == trackBefore
        else { throw MetadataIOError.verificationFailed("the tags or the cover changed") }
        // With the header right, the length is read without counting the frames.
        guard after.lengthProblem == nil else {
            throw MetadataIOError.verificationFailed("the length header is still wrong")
        }
    }

    /// Check 3.
    func checkFrames(of copy: URL, before: MP3FrameScan.Measurement) throws {
        guard let after = try? measure(copy),
              after.frameCount == before.frameCount, after.audioRange == before.audioRange,
              after.firstFrame == before.firstFrame, after.totalSamples == before.totalSamples
        else { throw MetadataIOError.verificationFailed("the audio no longer measures the same") }
        guard let xing = after.vbrHeader.xing, xing.statedFrames.map(Int.init) == after.frameCount,
              xing.statedBytes.map(Int.init) == after.audioRange.count, xing.hasTOC
        else { throw MetadataIOError.verificationFailed("the length header does not state what was measured") }
        guard let stated = try? CTBTagFile.readMP3(atPath: copy.path).durationSeconds,
              !MP3Length.differs(stated: stated, measured: after.durationSeconds)
        else { throw MetadataIOError.verificationFailed("the tag library still reads another length") }
    }

    /// Check 4.
    func checkPlayback(of copy: URL, seconds: Double) throws {
        guard let plays = playbackSeconds(copy) else {
            throw MetadataIOError.verificationFailed("the system could not say how long the repaired file plays")
        }
        guard abs(plays - seconds) <= max(1, seconds * 0.01) else {
            throw MetadataIOError.verificationFailed("the system still reads another length from the repaired file")
        }
    }

    // MARK: Files

    static func write(_ copy: URL, _ plan: Plan) throws {
        try write(plan.patched, at: plan.firstFrame.lowerBound, in: copy)
    }

    /// Overwrites `data.count` bytes at `offset`. Only ever called on a working copy.
    static func write(_ data: Data, at offset: UInt64, in url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    static func bytes(of url: URL, in range: Range<UInt64>) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: range.lowerBound)
        let data = try handle.read(upToCount: range.count) ?? Data()
        guard data.count == range.count else { throw MetadataIOError.unreadable(url.lastPathComponent) }
        return data
    }

    /// SHA-256 of a whole file, read in chunks, in hexadecimal.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
