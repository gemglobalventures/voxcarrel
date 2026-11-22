import Foundation

/// Decides how long an MP3 is: the length its header states, or, when that cannot be
/// right, the length of its frames counted one by one.
enum MP3Length {
    typealias Scan = @Sendable (URL) throws -> MP3FrameScan.Measurement

    static let standardScan: Scan = { try MP3FrameScan.measure($0) }

    /// MP3 audio runs from 8 to 320 kbit/s (448 for Layer I). A stated length that puts
    /// the file's average outside these bounds cannot be right.
    static let plausibleKbps = 6.0...400.0
    /// How far a header's byte count may be from the audio the file holds.
    static let byteCountTolerance = 0.03
    /// How far the bitrate a header's length amounts to may be from the bitrate of the
    /// frames sampled across the file. An Info header is that of a constant bitrate, where
    /// the two agree closely; a variable bitrate is only known roughly from a sample.
    static let constantBitrateTolerance = 0.02
    static let variableBitrateTolerance = 0.25

    /// Whether a stated length is believable for this many bytes of audio.
    static func isPlausible(seconds: Double, audioBytes: UInt64) -> Bool {
        guard seconds > 0, audioBytes > 0 else { return false }
        return plausibleKbps.contains(Double(audioBytes) * 8 / seconds / 1000)
    }

    /// Whether the frames must be counted: a stated length is implausible for the audio
    /// the file holds, its header counts a different number of bytes, or the header's
    /// length would need another bitrate than the frames sampled across the file have.
    ///
    /// The last catches a header that is wrong by a factor too small to be implausible:
    /// half the true length at 128 kbit/s is 256 kbit/s, which an MP3 can be.
    ///
    /// Two lengths are stated: the one the tag library reads (`statedSeconds`) and the
    /// one the header's own frame count amounts to. They differ when the tag library
    /// sets a header aside that other players go by.
    static func needsScan(statedSeconds: Double, opening: MP3FrameScan.Opening) -> Bool {
        let audioBytes = opening.audioBytes
        if !isPlausible(seconds: statedSeconds, audioBytes: audioBytes) { return true }
        if let seconds = opening.headerSeconds, !isPlausible(seconds: seconds, audioBytes: audioBytes) { return true }
        if let stated = opening.vbrHeader.statedBytes, stated > 0 {
            let difference = abs(Double(stated) - Double(audioBytes))
            if difference > Double(audioBytes) * byteCountTolerance { return true }
        }
        if let seconds = opening.headerSeconds, let sampled = opening.sampledKbps, sampled > 0 {
            let implied = Double(audioBytes) * 8 / seconds / 1000
            let tolerance = opening.vbrHeader.xing?.isInfo == true
                ? constantBitrateTolerance : variableBitrateTolerance
            if abs(implied - sampled) > sampled * tolerance { return true }
        }
        return false
    }

    /// Whether a measured length differs from a stated one by enough to matter: more
    /// than a second and more than one part in a hundred.
    static func differs(stated: Double, measured: Double) -> Bool {
        abs(stated - measured) > max(1, measured * 0.01)
    }

    /// The file's length, and what is wrong with its header if it states another.
    ///
    /// A healthy file costs a few small reads: at its start, its end, and a few places in
    /// between. A file that cannot be measured (free format, or sync lost) keeps its
    /// stated length and reports no problem.
    static func resolve(_ url: URL, statedSeconds: Double, scan: Scan) -> (seconds: Double, problem: LengthProblem?) {
        guard let opening = try? MP3FrameScan.open(url), needsScan(statedSeconds: statedSeconds, opening: opening),
              let measured = try? scan(url)
        else { return (statedSeconds, nil) }
        let trueSeconds = measured.durationSeconds
        // What the header says comes first: it is what a player that stops early goes by.
        let wrong = [opening.headerSeconds, statedSeconds].compactMap { $0 }
            .first { differs(stated: $0, measured: trueSeconds) }
        guard let wrong else { return (trueSeconds, nil) }
        return (
            trueSeconds,
            LengthProblem(
                statedSeconds: wrong, trueSeconds: trueSeconds,
                repairable: measured.vbrHeader.xing?.hasRoomForRepair == true)
        )
    }
}
