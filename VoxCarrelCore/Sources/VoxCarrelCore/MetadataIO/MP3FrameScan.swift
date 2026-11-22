import Foundation

/// Measures an MP3 file by walking its MPEG audio frames, without trusting the length
/// header in its first frame.
///
/// Nothing here decodes audio or changes a file. A file is read in chunks; the whole of
/// it is never held in memory.
enum MP3FrameScan {
    /// Why a file could not be measured. A length is never guessed.
    enum Failure: Error, Equatable {
        /// The file could not be opened or read.
        case unreadable
        /// No MPEG audio was found where the audio should begin.
        case noAudio
        /// A "free format" stream: the length of its frames is not stated in them.
        case freeFormat
        /// More bytes that are not audio lie between or after the frames than is tolerated.
        case syncLost
    }

    /// Bytes that are not audio frames, in the whole file, that a measurement tolerates
    /// (before the first frame, between frames, and after the last).
    static let junkTolerance = 64 * 1024
    /// The most whole tags, one straight after another, that are stepped over between
    /// frames. Files joined end to end have one or two; more are not tags.
    static let embeddedTagLimit = 64

    /// The encoder's own record after a Xing/Info header, as LAME and FFmpeg write it.
    struct LAMEExtension: Equatable {
        /// For example "LAME3.100".
        var encoder: String
        /// Whether the tag's checksum is right for the first frame as it is.
        var crcIsValid: Bool
    }

    /// A Xing (variable bitrate) or Info (constant bitrate) header.
    struct XingHeader: Equatable {
        var isInfo: Bool
        /// Where the four letters are, from the start of the first frame.
        var offsetInFrame: Int
        /// 1 frame count, 2 byte count, 4 seek table, 8 quality.
        var flags: UInt32
        var statedFrames: UInt32?
        var statedBytes: UInt32?
        var hasTOC: Bool
        var lame: LAMEExtension?
        /// Whether the frame has room for a frame count, a byte count and a seek table
        /// without anything else in it being moved or overwritten.
        var hasRoomForRepair: Bool
    }

    enum VBRHeader: Equatable {
        case none
        case xing(XingHeader)
        case vbri(statedFrames: UInt32, statedBytes: UInt32)

        var xing: XingHeader? {
            if case .xing(let header) = self { return header }
            return nil
        }

        var statedBytes: UInt32? {
            switch self {
            case .none: nil
            case .xing(let header): header.statedBytes
            case .vbri(_, let bytes): bytes
            }
        }

        var statedFrames: UInt32? {
            switch self {
            case .none: nil
            case .xing(let header): header.statedFrames
            case .vbri(let frames, _): frames
            }
        }
    }

    /// What the start and the end of a file say, read without walking the frames.
    struct Opening: Equatable {
        var fileSize: UInt64
        /// The first MPEG frame: the header frame when the file has a length header.
        var firstFrame: Range<UInt64>
        var sampleRate: Int
        var samplesPerFrame: Int
        var vbrHeader: VBRHeader
        /// Where the tags at the end of the file begin (ID3v1, APE, Lyrics3); the file's
        /// size when it has none.
        var tailStart: UInt64
        /// Bytes passed over before the first frame that were not a tag.
        var leadingJunk: Int
        /// The average bitrate of the audio in kbit/s, estimated from frames read at a
        /// few places spread over it (`samplePoints`); nil when it was not estimated, or
        /// frames were found at too few of the places.
        var sampledKbps: Double?
        /// The first frame's header, and which of its bits every frame must share.
        fileprivate var firstHeader: UInt32

        /// From the first frame to the tags at the end: the most the audio can be.
        var audioBytes: UInt64 { tailStart - firstFrame.lowerBound }

        /// The length the header's own frame count amounts to; nil when it states none.
        /// Players that trust the header play this much.
        var headerSeconds: Double? {
            guard let frames = vbrHeader.statedFrames, frames > 0 else { return nil }
            return Double(frames) * Double(samplesPerFrame) / Double(sampleRate)
        }
    }

    struct Measurement: Equatable {
        /// Audio frames; a frame that only carries a length header is not one.
        var frameCount: Int
        var totalSamples: Int64
        var sampleRate: Int
        var durationSeconds: Double
        /// From the first byte of the first frame (the header frame when there is one) to
        /// the end of the last audio frame: what a length header's byte count describes.
        var audioRange: Range<UInt64>
        var firstFrame: Range<UInt64>
        var vbrHeader: VBRHeader
        /// Bytes that were neither audio nor a tag, wherever they were.
        var junkBytes: Int
        /// Bytes of whole tags found between frames, as in files joined end to end.
        /// They are not counted as junk: a tag says how long it is.
        var embeddedTagBytes: Int = 0
        /// Where each audio frame begins; empty unless asked for.
        var frameOffsets: [UInt64] = []
    }

    // MARK: Entry points

    /// The cheap look: a few small reads at the start and the end of the file, and one at
    /// each of `samplePoints` places in between to estimate the bitrate.
    /// - Parameter onRead: Called with the number of bytes of each read made of the file.
    static func open(_ url: URL, onRead: ((Int) -> Void)? = nil) throws -> Opening {
        let file = try ChunkedFile(url, chunk: 16 * 1024, onRead: onRead)
        var opening = try opening(of: file)
        opening.sampledKbps = try sampledKbps(of: file, opening: opening)
        return opening
    }

    /// How many places in the audio the cheap look reads frames at.
    static let samplePoints = 8
    /// How far from such a place a frame is looked for: two of the longest frames.
    private static let sampleSearch: UInt64 = 2882
    /// The most frames, and bytes of frames, read at one place: one buffer's worth.
    private static let sampleFrames = 96
    private static let sampleBytes = 12 * 1024

    /// The average bitrate, from runs of frames at places spread evenly over the bytes of
    /// the audio.
    ///
    /// The places are spread by bytes, so the stretches at a high bitrate get more of them
    /// than their share of the time: what is averaged is therefore the time a byte lasts
    /// at each place, which comes out right however the bitrate varies.
    private static func sampledKbps(of file: ChunkedFile, opening: Opening) throws -> Double? {
        let mask = Header.sameStreamMask
        let wanted = opening.firstHeader & mask
        let end = opening.tailStart
        let from = opening.vbrHeader == .none ? opening.firstFrame.lowerBound : opening.firstFrame.upperBound
        guard end > from else { return nil }
        let stride = (end - from) / UInt64(samplePoints)

        /// The length of the frame of this stream at `offset`, or nil.
        func frame(at offset: UInt64) throws -> Int? {
            guard offset + 4 <= end, let header = try file.header(at: offset), header & mask == wanted,
                  let length = Header.frameLength(header), offset + UInt64(length) <= end
            else { return nil }
            return length
        }

        var secondsPerByte = 0.0
        var places = 0
        for point in 0..<samplePoints {
            // A frame that is followed by another, or that ends where the audio does.
            var position = from + stride * UInt64(point) + stride / 2
            let limit = position + sampleSearch
            var found = false
            while position < limit {
                if let length = try frame(at: position) {
                    let next = position + UInt64(length)
                    found = try next == end || frame(at: next) != nil
                    if found { break }
                }
                position += 1
            }
            guard found else { continue }
            var frames = 0
            var bytes = 0
            while frames < sampleFrames, bytes < sampleBytes, let length = try frame(at: position) {
                frames += 1
                bytes += length
                position += UInt64(length)
            }
            let seconds = Double(frames * opening.samplesPerFrame) / Double(opening.sampleRate)
            secondsPerByte += seconds / Double(bytes)
            places += 1
        }
        guard places * 2 >= samplePoints, secondsPerByte > 0 else { return nil }
        return 8 / (secondsPerByte / Double(places)) / 1000
    }

    /// Walks every frame.
    /// - Parameter recordingOffsets: Also return where each audio frame begins (eight
    ///   bytes a frame), for building a seek table.
    static func measure(_ url: URL, recordingOffsets: Bool = false) throws -> Measurement {
        let file = try ChunkedFile(url, chunk: 512 * 1024)
        let opening = try opening(of: file)
        let mask = Header.sameStreamMask
        let wanted = opening.firstHeader & mask
        let end = opening.tailStart

        var junk = opening.leadingJunk
        var tagBytes = 0
        var count = 0
        var offsets: [UInt64] = []
        // A length header's frame holds no audio.
        var position = opening.vbrHeader == .none ? opening.firstFrame.lowerBound : opening.firstFrame.upperBound
        var audioEnd = opening.firstFrame.upperBound
        /// Up to here every byte is a frame, a tag, or junk already counted.
        var accounted = audioEnd
        /// Where runs of tags that led nowhere passed through: a run that reaches one of
        /// these places leads nowhere either, and is not walked again.
        var deadEnds = Set<UInt64>()

        /// The length of the frame of this stream that begins at `offset`, or nil.
        /// - Parameter expected: The frame before ended here, so a header that gives no
        ///   length is a free-format frame and not a chance pattern among other bytes.
        func frame(at offset: UInt64, expected: Bool = false) throws -> Int? {
            guard offset + 4 <= end, let header = try file.header(at: offset), header & mask == wanted else {
                return nil
            }
            if expected, Header.isFreeFormat(header) { throw Failure.freeFormat }
            return Header.frameLength(header)
        }

        while position + 4 <= end {
            if let length = try frame(at: position, expected: true) {
                // A last frame cut short is not audio that can be played.
                guard position + UInt64(length) <= end else { break }
                count += 1
                if recordingOffsets { offsets.append(position) }
                position += UInt64(length)
                audioEnd = position
                accounted = position
                continue
            }
            // Whole tags between frames (the file was joined from several) are stepped
            // over, when a frame or the end of the audio follows them.
            var afterTags = position
            var steps: [UInt64] = []
            var leadsNowhere = false
            while let length = try embeddedTagLength(at: afterTags, in: file), afterTags + length <= end {
                afterTags += length
                if steps.count == embeddedTagLimit || deadEnds.contains(afterTags) {
                    leadsNowhere = true
                    break
                }
                steps.append(afterTags)
            }
            if !leadsNowhere, afterTags > position, try afterTags == end || frame(at: afterTags) != nil {
                tagBytes += Int(afterTags - position)
                position = afterTags
                accounted = position
                continue
            }
            deadEnds.formUnion(steps)
            // Sync is lost: look for the next frame that is followed by another, or that
            // ends where the audio does.
            var candidate = position + 1
            var found = false
            while candidate + 4 <= end, junk + Int(candidate - position) <= junkTolerance {
                if let length = try frame(at: candidate) {
                    let next = candidate + UInt64(length)
                    if next == end { found = true } else if next < end, try frame(at: next) != nil { found = true }
                    if found { break }
                }
                candidate += 1
            }
            guard found else { break }
            junk += Int(candidate - position)
            position = candidate
        }
        // Whatever lies between the last frame and the tags at the end.
        junk += Int(end - accounted)
        guard junk <= junkTolerance else { throw Failure.syncLost }
        guard count > 0 else { throw Failure.noAudio }

        let samples = Int64(count) * Int64(opening.samplesPerFrame)
        return Measurement(
            frameCount: count, totalSamples: samples, sampleRate: opening.sampleRate,
            durationSeconds: Double(samples) / Double(opening.sampleRate),
            audioRange: opening.firstFrame.lowerBound..<audioEnd, firstFrame: opening.firstFrame,
            vbrHeader: opening.vbrHeader, junkBytes: junk, embeddedTagBytes: tagBytes, frameOffsets: offsets)
    }

    /// The length of the ID3v2 tag (header, body and footer) or ID3v1 tag that begins at
    /// `offset`; nil when none does.
    private static func embeddedTagLength(at offset: UInt64, in file: ChunkedFile) throws -> UInt64? {
        let id3v2 = try file.withBytes(at: offset, count: 10) { tag -> UInt64? in
            guard tag[0] == 0x49, tag[1] == 0x44, tag[2] == 0x33, tag[3] < 0xFF, tag[4] < 0xFF,
                  tag[6] < 0x80, tag[7] < 0x80, tag[8] < 0x80, tag[9] < 0x80
            else { return nil }
            let size = Int(tag[6]) << 21 | Int(tag[7]) << 14 | Int(tag[8]) << 7 | Int(tag[9])
            return UInt64(10 + size + (tag[5] & 0x10 != 0 ? 10 : 0))
        }
        if let length = id3v2 ?? nil { return length }
        let id3v1 = try file.withBytes(at: offset, count: 3) { tag in
            tag[0] == 0x54 && tag[1] == 0x41 && tag[2] == 0x47  // "TAG"
        }
        return id3v1 == true ? 128 : nil
    }

    // MARK: The start and the end

    private static func opening(of file: ChunkedFile) throws -> Opening {
        let tailStart = try tailStart(of: file)

        // ID3v2 tags at the start (nearly always one).
        var start: UInt64 = 0
        while true {
            let length = try file.withBytes(at: start, count: 10) { tag -> UInt64? in
                guard tag[0] == 0x49, tag[1] == 0x44, tag[2] == 0x33,
                      tag[6] < 0x80, tag[7] < 0x80, tag[8] < 0x80, tag[9] < 0x80
                else { return nil }
                let size = Int(tag[6]) << 21 | Int(tag[7]) << 14 | Int(tag[8]) << 7 | Int(tag[9])
                return UInt64(10 + size + (tag[5] & 0x10 != 0 ? 10 : 0))
            }
            guard let length = length ?? nil else { break }
            start += length
        }

        // The first frame: one whose header is valid and that is followed by another of
        // the same stream, or that ends where the audio does.
        var position = start
        while position + 4 <= tailStart, Int(position - start) <= junkTolerance {
            if let header = try file.header(at: position), Header.isValid(header) {
                if Header.isFreeFormat(header) {
                    // Only where audio is expected: elsewhere it is as likely to be junk.
                    if position == start { throw Failure.freeFormat }
                } else if let length = Header.frameLength(header) {
                    let next = position + UInt64(length)
                    var confirmed = next == tailStart
                    if !confirmed, next + 4 <= tailStart, let following = try file.header(at: next) {
                        confirmed = following & Header.sameStreamMask == header & Header.sameStreamMask
                    }
                    if confirmed {
                        guard let bytes = try file.bytes(at: position, count: length) else { throw Failure.unreadable }
                        return Opening(
                            fileSize: file.size, firstFrame: position..<next,
                            sampleRate: Header.sampleRate(header), samplesPerFrame: Header.samplesPerFrame(header),
                            vbrHeader: vbrHeader(in: bytes, header: header), tailStart: tailStart,
                            leadingJunk: Int(position - start), firstHeader: header)
                    }
                }
            }
            position += 1
        }
        throw Int(position - start) > junkTolerance ? Failure.syncLost : Failure.noAudio
    }

    /// Where the tags at the end begin: ID3v1 last, with Lyrics3 and APE tags before it in
    /// either order.
    private static func tailStart(of file: ChunkedFile) throws -> UInt64 {
        var end = file.size
        if end >= 128, let tag = try file.bytes(at: end - 128, count: 3), tag == Array("TAG".utf8) {
            end -= 128
        }
        for _ in 0..<3 {
            // Lyrics3 v2: "...<six digits>LYRICS200", the digits being the size before them.
            if end >= 15, let footer = try file.bytes(at: end - 15, count: 15),
               Array(footer[6...]) == Array("LYRICS200".utf8),
               let size = UInt64(String(decoding: footer[..<6], as: UTF8.self)), size + 15 <= end {
                end -= size + 15
                continue
            }
            // APE: a 32-byte footer whose size counts the items and the footer; bit 31 of
            // the flags says a 32-byte header precedes them.
            if end >= 32, let footer = try file.bytes(at: end - 32, count: 32),
               Array(footer[..<8]) == Array("APETAGEX".utf8) {
                let size = UInt64(footer[12]) | UInt64(footer[13]) << 8 | UInt64(footer[14]) << 16
                    | UInt64(footer[15]) << 24
                let whole = size + (footer[23] & 0x80 != 0 ? 32 : 0)
                if size >= 32, whole <= end {
                    end -= whole
                    continue
                }
            }
            break
        }
        return end
    }

    /// The length header in a first frame, if it has one.
    static func vbrHeader(in frame: [UInt8], header: UInt32) -> VBRHeader {
        func word(_ at: Int) -> UInt32 {
            UInt32(frame[at]) << 24 | UInt32(frame[at + 1]) << 16 | UInt32(frame[at + 2]) << 8 | UInt32(frame[at + 3])
        }
        func tag(_ text: String, at offset: Int) -> Bool {
            offset + 4 <= frame.count && Array(frame[offset..<offset + 4]) == Array(text.utf8)
        }
        guard Header.layer(header) == 3 else { return .none }

        // Xing/Info: straight after the side information. In a frame that carries a
        // checksum, the two bytes of it come before the side information: most readers
        // look in the usual place all the same, and some encoders put the header two
        // bytes further on. The usual place is looked at first.
        func isHeader(_ offset: Int) -> Bool { tag("Xing", at: offset) || tag("Info", at: offset) }
        var at = Header.sideInfoLength(header) + 4
        if !isHeader(at), Header.hasChecksum(header), isHeader(at + 2) { at += 2 }
        if isHeader(at), at + 8 <= frame.count {
            let flags = word(at + 4)
            var field = at + 8
            var complete = true
            func take(_ flag: UInt32, _ size: Int) -> Int? {
                guard flags & flag != 0 else { return nil }
                guard field + size <= frame.count else {
                    complete = false
                    return nil
                }
                defer { field += size }
                return field
            }
            let frames = take(1, 4).map(word)
            let bytes = take(2, 4).map(word)
            let hasTOC = take(4, 100) != nil
            let quality = take(8, 4)

            // A repair writes: flags, frame count, byte count, seek table, then the quality
            // where it was or, moved along, into bytes that are empty now.
            let needed = at + 8 + 108 + (quality == nil ? 0 : 4)
            let hasRoom = complete && needed <= frame.count
                && (field..<max(field, needed)).allSatisfy { frame[$0] == 0 }

            var lame: LAMEExtension?
            let extensionAt = at + 120
            if complete, flags & 0x0F == 0x0F, extensionAt + 36 <= frame.count {
                let name = frame[extensionAt..<extensionAt + 9]
                let isName = name.prefix(4).allSatisfy {
                    (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0)
                }
                if isName {
                    let stored = UInt16(frame[extensionAt + 34]) << 8 | UInt16(frame[extensionAt + 35])
                    lame = LAMEExtension(
                        encoder: String(decoding: name.prefix { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self),
                        crcIsValid: crc16(frame[..<(extensionAt + 34)]) == stored)
                }
            }
            return .xing(XingHeader(
                isInfo: tag("Info", at: at), offsetInFrame: at, flags: flags, statedFrames: frames,
                statedBytes: bytes, hasTOC: hasTOC, lame: lame, hasRoomForRepair: hasRoom))
        }
        // VBRI (Fraunhofer): always 32 bytes after the frame header.
        if tag("VBRI", at: 36), 36 + 18 <= frame.count {
            return .vbri(statedFrames: word(36 + 14), statedBytes: word(36 + 10))
        }
        return .none
    }

    /// CRC-16 as LAME computes it for its info tag: polynomial 0x8005 reflected, start value 0.
    static func crc16<Bytes: Sequence>(_ bytes: Bytes) -> UInt16 where Bytes.Element == UInt8 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }

    // MARK: Frame headers

    /// The four bytes every MPEG audio frame begins with, as one big-endian number.
    enum Header {
        /// Sync, version, layer and sample rate: what every frame of one stream shares.
        static let sameStreamMask: UInt32 = 0xFFFE_0C00

        private static let bitrates: [[Int]] = [
            [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],  // MPEG-1 Layer I
            [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],  // MPEG-1 Layer II
            [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],  // MPEG-1 Layer III
            [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],  // MPEG-2/2.5 Layer I
            [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],  // MPEG-2/2.5 Layer II and III
        ]
        private static let sampleRates: [[Int]] = [
            [11_025, 12_000, 8000],  // MPEG-2.5
            [],
            [22_050, 24_000, 16_000],  // MPEG-2
            [44_100, 48_000, 32_000],  // MPEG-1
        ]

        @inline(__always) private static func version(_ h: UInt32) -> Int { Int(h >> 19) & 3 }  // 3 is MPEG-1
        @inline(__always) private static func bitrateIndex(_ h: UInt32) -> Int { Int(h >> 12) & 15 }
        @inline(__always) private static func rateIndex(_ h: UInt32) -> Int { Int(h >> 10) & 3 }

        /// 1, 2 or 3; 0 for the reserved value.
        @inline(__always) static func layer(_ h: UInt32) -> Int { (4 - (Int(h >> 17) & 3)) & 3 }

        /// Sync bits set and no reserved value for version, layer, bitrate or sample rate.
        @inline(__always) static func isValid(_ h: UInt32) -> Bool {
            h & 0xFFE0_0000 == 0xFFE0_0000 && version(h) != 1 && layer(h) != 0 && bitrateIndex(h) != 15
                && rateIndex(h) != 3
        }

        @inline(__always) static func isFreeFormat(_ h: UInt32) -> Bool { bitrateIndex(h) == 0 }

        static func sampleRate(_ h: UInt32) -> Int { sampleRates[version(h)][rateIndex(h)] }

        static func samplesPerFrame(_ h: UInt32) -> Int {
            switch layer(h) {
            case 1: 384
            case 2: 1152
            default: version(h) == 3 ? 1152 : 576
            }
        }

        /// Whether two bytes of checksum follow the header (the protection bit is clear).
        static func hasChecksum(_ h: UInt32) -> Bool { h & 0x0001_0000 == 0 }

        /// Bytes of side information after the header of a Layer III frame.
        static func sideInfoLength(_ h: UInt32) -> Int {
            let mono = (h >> 6) & 3 == 3
            return version(h) == 3 ? (mono ? 17 : 32) : (mono ? 9 : 17)
        }

        /// The whole frame's length in bytes; nil for an invalid or free-format header.
        @inline(__always) static func frameLength(_ h: UInt32) -> Int? {
            guard isValid(h), !isFreeFormat(h) else { return nil }
            let mpeg1 = version(h) == 3
            let layer = layer(h)
            let table = mpeg1 ? layer - 1 : (layer == 1 ? 3 : 4)
            let bitrate = bitrates[table][bitrateIndex(h)] * 1000
            let rate = sampleRates[version(h)][rateIndex(h)]
            let padding = Int(h >> 9) & 1
            switch layer {
            case 1: return (12 * bitrate / rate + padding) * 4
            case 2: return 144 * bitrate / rate + padding
            default: return (mpeg1 ? 144 : 72) * bitrate / rate + padding
            }
        }
    }
}

/// A file read through one buffer that slides along it.
final class ChunkedFile {
    let size: UInt64
    private let descriptor: Int32
    private let buffer: UnsafeMutableRawBufferPointer
    private var start: UInt64 = 0
    private var filled = 0
    private let onRead: ((Int) -> Void)?

    /// - Parameter onRead: Called with the number of bytes of each read made of the file.
    init(_ url: URL, chunk: Int, onRead: ((Int) -> Void)? = nil) throws {
        self.onRead = onRead
        descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw MP3FrameScan.Failure.unreadable }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw MP3FrameScan.Failure.unreadable
        }
        size = UInt64(info.st_size)
        buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(chunk, 4096), alignment: 16)
    }

    deinit {
        close(descriptor)
        buffer.deallocate()
    }

    /// Makes `count` bytes at `offset` available in the buffer; nil when they lie beyond the end.
    @inline(__always) private func window(_ offset: UInt64, _ count: Int) throws -> UnsafeRawPointer? {
        if offset >= start, offset + UInt64(count) <= start + UInt64(filled) {
            return UnsafeRawPointer(buffer.baseAddress! + Int(offset - start))
        }
        return try refill(offset, count)
    }

    private func refill(_ offset: UInt64, _ count: Int) throws -> UnsafeRawPointer? {
        guard count <= buffer.count, offset + UInt64(count) <= size else { return nil }
        start = offset
        filled = 0
        while filled < count {
            let got = pread(descriptor, buffer.baseAddress! + filled, buffer.count - filled, off_t(offset) + off_t(filled))
            if got < 0 {
                if errno == EINTR { continue }
                throw MP3FrameScan.Failure.unreadable
            }
            if got == 0 { break }  // the file became shorter
            onRead?(got)
            filled += got
        }
        return filled >= count ? UnsafeRawPointer(buffer.baseAddress!) : nil
    }

    /// Four bytes as one big-endian number.
    @inline(__always) func header(at offset: UInt64) throws -> UInt32? {
        guard let p = try window(offset, 4) else { return nil }
        return UInt32(bigEndian: p.loadUnaligned(as: UInt32.self))
    }

    /// Gives `body` the `count` bytes at `offset` where they lie in the buffer, without
    /// copying them; nil when they lie beyond the end. The bytes must not be kept.
    @inline(__always) func withBytes<T>(
        at offset: UInt64, count: Int, _ body: (UnsafeRawBufferPointer) -> T
    ) throws -> T? {
        guard let p = try window(offset, count) else { return nil }
        return body(UnsafeRawBufferPointer(start: p, count: count))
    }

    func bytes(at offset: UInt64, count: Int) throws -> [UInt8]? {
        guard let p = try window(offset, count) else { return nil }
        return Array(UnsafeRawBufferPointer(start: p, count: count))
    }
}
