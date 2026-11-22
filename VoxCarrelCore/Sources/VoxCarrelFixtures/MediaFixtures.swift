import AVFoundation
import AppKit
import CTagBridge
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

/// Media files generated in code, so no binary fixtures are committed.
public enum MediaFixtures {
    // MARK: AAC in MP4 (.m4a / .m4b), no external tools

    /// Encodes a quiet sine tone to AAC with AVAudioFile. The container is identical for .m4a and
    /// .m4b, so the file is written as .m4a and then renamed to whatever `url` asks for.
    public static func makeAAC(at url: URL, seconds: Double) throws {
        let sampleRate = 44_100.0
        let pcm = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let scratch = url.deletingPathExtension().appendingPathExtension("tmp.m4a")
        do {
            let file = try AVAudioFile(forWriting: scratch, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ])
            let total = AVAudioFrameCount(seconds * sampleRate)
            let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: total)!
            buffer.frameLength = total
            let samples = buffer.floatChannelData![0]
            for i in 0..<Int(total) { samples[i] = 0.1 * sinf(Float(i) * 2 * .pi * 440 / Float(sampleRate)) }
            try file.write(from: buffer)
        } // AVAudioFile finalises the file when it is deallocated
        try FileManager.default.moveItem(at: scratch, to: url)
    }

    /// An M4B with a QuickTime chapter track, for read tests.
    public static func makeChapteredM4B(at url: URL, seconds: Double, chapters: [(start: Double, title: String)]) throws {
        try makeAAC(at: url, seconds: seconds)
        let list = chapters.map { CTBChapter(startSeconds: $0.start, title: $0.title) }
        try CTBTagFile.setMP4Chapters(list, quickTime: true, atPath: url.path)
    }

    // MARK: MP3 without an encoder

    /// A valid, silent MPEG-1 Layer III stream built by hand. macOS has no MP3 encoder.
    ///
    /// Each frame is a 4-byte header followed by zeros. Header FF FB 90 C4 means: sync, MPEG-1,
    /// Layer III, no CRC, 128 kbit/s, 44.1 kHz, no padding, mono. Frame length is
    /// floor(144 * 128000 / 44100) = 417 bytes. All-zero side info says "main_data_begin 0, every
    /// granule has part2_3_length 0", which decodes as digital silence, 1152 samples per frame.
    public static func makeSilentMP3(seconds: Double, id3v23Title: String? = nil) -> Data {
        let frameLength = 144 * 128_000 / 44_100 // 417
        var frame = Data([0xFF, 0xFB, 0x90, 0xC4])
        frame.append(Data(count: frameLength - 4))
        let frames = Int((seconds * 44_100 / 1152).rounded(.up))
        var out = Data()
        if let title = id3v23Title { out.append(id3v23Tag(title: title)) }
        for _ in 0..<frames { out.append(frame) }
        return out
    }

    /// Minimal ID3v2.3 tag holding one Latin-1 TIT2 frame, to prove an existing 2.3 tag stays 2.3.
    public static func id3v23Tag(title: String) -> Data {
        var body = Data([0x00]) // text encoding: ISO-8859-1
        body.append(title.data(using: .isoLatin1)!)
        var frame = Data("TIT2".utf8)
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { frame.append(contentsOf: $0) } // v2.3: plain 32-bit size
        frame.append(contentsOf: [0x00, 0x00]) // frame flags
        frame.append(body)
        var tag = Data("ID3".utf8)
        tag.append(contentsOf: [0x03, 0x00, 0x00]) // version 2.3.0, no flags
        let n = frame.count // tag size is 28-bit "synchsafe": 7 bits per byte
        tag.append(contentsOf: [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)])
        tag.append(frame)
        return tag
    }

    /// An ID3v2.3 tag built from raw frames, for cases the bridge cannot write itself.
    public static func id3v23Tag(frames: [(id: String, body: Data)]) -> Data {
        var all = Data()
        for frame in frames {
            all.append(Data(frame.id.utf8))
            withUnsafeBytes(of: UInt32(frame.body.count).bigEndian) { all.append(contentsOf: $0) }
            all.append(contentsOf: [0x00, 0x00])
            all.append(frame.body)
        }
        var tag = Data("ID3".utf8)
        tag.append(contentsOf: [0x03, 0x00, 0x00])
        let n = all.count
        tag.append(contentsOf: [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)])
        tag.append(all)
        return tag
    }

    /// Body of a Latin-1 text frame.
    public static func id3Text(_ text: String) -> Data {
        var body = Data([0x00])
        body.append(text.data(using: .isoLatin1)!)
        return body
    }

    /// Body of an APIC frame: Latin-1, the given MIME string, picture type, empty description.
    public static func id3Picture(_ image: Data, mime: String, type: UInt8) -> Data {
        var body = Data([0x00])
        body.append(Data(mime.utf8))
        body.append(contentsOf: [0x00, type, 0x00])
        body.append(image)
        return body
    }

    // MARK: MP3 with a length header

    /// How `makeMP3(_:)` builds its file.
    public struct MP3Options: Sendable {
        public enum LengthHeader: Sendable { case none, xing, info, vbri }

        /// Length of the audio itself, not counting the header frame.
        public var seconds: Double
        public var header: LengthHeader
        /// The frame count the header states; nil states the true one.
        public var statedFrames: UInt32?
        /// The byte count the header states; nil states the true one.
        public var statedBytes: UInt32?
        /// Xing/Info only: which fields the header has (1 frames, 2 bytes, 4 seek table, 8 quality).
        public var xingFlags: UInt32
        /// Xing/Info only: a LAME extension with a valid info-tag CRC after the header.
        public var lameExtension: Bool
        /// MPEG-2 at 22.05 kHz and 64 kbit/s instead of MPEG-1 at 44.1 kHz and 128 kbit/s.
        public var mpeg2: Bool
        /// The second half of the audio at a quarter of the bitrate, so that time and
        /// bytes do not run in step.
        public var variableBitrate: Bool
        /// Bytes that are not audio, put after this many audio frames.
        public var junk: (afterFrame: Int, bytes: Data)?
        /// Put in front of the audio as it is: an ID3v2 tag.
        public var prefix: Data
        /// A 128-byte ID3v1 tag after the audio.
        public var id3v1: Bool

        public init(
            seconds: Double = 60, header: LengthHeader = .xing, statedFrames: UInt32? = nil,
            statedBytes: UInt32? = nil, xingFlags: UInt32 = 0x0F, lameExtension: Bool = false,
            mpeg2: Bool = false, variableBitrate: Bool = false, junk: (afterFrame: Int, bytes: Data)? = nil,
            prefix: Data = Data(), id3v1: Bool = false
        ) {
            self.seconds = seconds
            self.header = header
            self.statedFrames = statedFrames
            self.statedBytes = statedBytes
            self.xingFlags = xingFlags
            self.lameExtension = lameExtension
            self.mpeg2 = mpeg2
            self.variableBitrate = variableBitrate
            self.junk = junk
            self.prefix = prefix
            self.id3v1 = id3v1
        }

        /// A header that states 100 frames (under three seconds) and 41,700 bytes, whatever the file holds.
        public static func wrongHeader(seconds: Double = 60) -> MP3Options {
            MP3Options(seconds: seconds, statedFrames: 100, statedBytes: 41_700)
        }
    }

    /// What `makeMP3(_:)` built, for tests to compare a measurement with.
    public struct BuiltMP3: Sendable {
        public var data: Data
        /// Audio frames, not counting the header frame.
        public var frameCount: Int
        public var sampleRate: Int
        public var samplesPerFrame: Int
        /// From the first byte of the first frame (the header frame when there is one) to
        /// the end of the last frame.
        public var audioRange: Range<Int>
        /// The first frame of the stream.
        public var firstFrame: Range<Int>
        /// Where each audio frame begins.
        public var frameOffsets: [Int]

        public var seconds: Double { Double(frameCount * samplesPerFrame) / Double(sampleRate) }
    }

    /// A silent, mono Layer III stream of many frames, with the length header asked for
    /// in a first frame of its own. See `makeSilentMP3` for why all-zero frames are valid.
    public static func makeMP3(_ options: MP3Options = MP3Options()) -> BuiltMP3 {
        // MPEG-1: FF FB, 128 kbit/s at 44.1 kHz (417 bytes), 1152 samples a frame, header at 21.
        // MPEG-2: FF F3, 64 kbit/s at 22.05 kHz (208 bytes), 576 samples a frame, header at 13.
        let sampleRate = options.mpeg2 ? 22_050 : 44_100
        let samplesPerFrame = options.mpeg2 ? 576 : 1152
        let versionByte: UInt8 = options.mpeg2 ? 0xF3 : 0xFB
        func frame(bitrateIndex: UInt8, kbps: Int) -> Data {
            let length = (options.mpeg2 ? 72 : 144) * kbps * 1000 / sampleRate
            // Third byte: bitrate index, then sample-rate index 0, no padding.
            var frame = Data([0xFF, versionByte, bitrateIndex << 4, 0xC4])
            frame.append(Data(count: length - 4))
            return frame
        }
        let full = options.mpeg2 ? frame(bitrateIndex: 8, kbps: 64) : frame(bitrateIndex: 9, kbps: 128)
        let quarter = options.mpeg2 ? frame(bitrateIndex: 2, kbps: 16) : frame(bitrateIndex: 1, kbps: 32)
        let frameCount = Int((options.seconds * Double(sampleRate) / Double(samplesPerFrame)).rounded(.up))

        var audio = Data()
        var relativeOffsets: [Int] = []
        for index in 0..<frameCount {
            if let junk = options.junk, junk.afterFrame == index { audio.append(junk.bytes) }
            relativeOffsets.append(audio.count)
            audio.append(options.variableBitrate && index >= frameCount / 2 ? quarter : full)
        }

        var headerFrame = Data()
        if options.header != .none {
            headerFrame = full
            let total = headerFrame.count + audio.count
            let frames = options.statedFrames ?? UInt32(frameCount)
            let bytes = options.statedBytes ?? UInt32(total)
            func put(_ value: UInt32, at offset: Int) {
                withUnsafeBytes(of: value.bigEndian) { headerFrame.replaceSubrange(offset..<offset + 4, with: $0) }
            }
            if options.header == .vbri {
                // Always 32 bytes after the frame header.
                headerFrame.replaceSubrange(36..<40, with: Data("VBRI".utf8))
                headerFrame[41] = 1 // version
                put(bytes, at: 46)
                put(frames, at: 50)
            } else {
                let at = options.mpeg2 ? 13 : 21 // after the side information of a mono frame
                headerFrame.replaceSubrange(at..<at + 4, with: Data((options.header == .info ? "Info" : "Xing").utf8))
                put(options.xingFlags, at: at + 4)
                var field = at + 8
                if options.xingFlags & 1 != 0 { put(frames, at: field); field += 4 }
                if options.xingFlags & 2 != 0 { put(bytes, at: field); field += 4 }
                if options.xingFlags & 4 != 0 {
                    // A straight-line seek table: right only for a constant bitrate.
                    for entry in 0..<100 { headerFrame[field + entry] = UInt8(entry * 256 / 100) }
                    field += 100
                }
                if options.xingFlags & 8 != 0 { put(57, at: field); field += 4 }
                if options.lameExtension {
                    headerFrame.replaceSubrange(at + 120..<at + 129, with: Data("LAME3.100".utf8))
                    headerFrame[at + 129] = 0x04 // tag revision 0, VBR method 4
                    put(bytes, at: at + 148) // music length
                    let crc = crc16(headerFrame.prefix(at + 154))
                    headerFrame[at + 154] = UInt8(crc >> 8)
                    headerFrame[at + 155] = UInt8(crc & 0xFF)
                }
            }
        }

        var data = options.prefix
        let start = data.count
        data.append(headerFrame)
        data.append(audio)
        let end = data.count
        if options.id3v1 {
            var tag = Data("TAG".utf8)
            tag.append(Data("Old Title".utf8))
            tag.append(Data(count: 128 - tag.count))
            data.append(tag)
        }
        return BuiltMP3(
            data: data, frameCount: frameCount, sampleRate: sampleRate, samplesPerFrame: samplesPerFrame,
            audioRange: start..<end, firstFrame: start..<start + (headerFrame.isEmpty ? full.count : headerFrame.count),
            frameOffsets: relativeOffsets.map { start + headerFrame.count + $0 })
    }

    /// CRC-16 as LAME computes it for its info tag (polynomial 0x8005 reflected, start value 0).
    public static func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }

    // MARK: Images

    public static func makeImage(_ type: UTType, size: Int = 64, red: CGFloat = 0.8) -> Data {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: red, green: 0.3, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    // MARK: Checks through AVFoundation, independent of TagLib

    public static func avDuration(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        return try await asset.load(.duration).seconds
    }

    /// Decodes the whole file to PCM and returns the number of frames produced.
    public static func decodedFrameCount(_ url: URL) throws -> Int64 {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536)!
        var total: Int64 = 0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            total += Int64(buffer.frameLength)
        }
        return total
    }

    public static func avChapters(_ url: URL) async throws -> [(start: Double, title: String)] {
        let asset = AVURLAsset(url: url)
        let languages = try await asset.load(.availableChapterLocales).map(\.identifier)
        let groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: languages.isEmpty ? ["en"] : languages)
        var out: [(Double, String)] = []
        for group in groups {
            var title = ""
            for item in group.items where item.commonKey == .commonKeyTitle {
                title = try await item.load(.stringValue) ?? ""
            }
            out.append((group.timeRange.start.seconds, title))
        }
        return out
    }

    // MARK: EPUB

    public static let container = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    public static let opf3 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id" xml:lang="en">
      <!-- a comment that must survive -->
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
        <dc:identifier id="pub-id">urn:uuid:12345678-1234-1234-1234-123456789abc</dc:identifier>
        <dc:identifier>urn:isbn:9780000000001</dc:identifier>
        <dc:title id="t1">Original Title</dc:title>
        <meta refines="#t1" property="title-type">main</meta>
        <dc:creator id="a1">First Author</dc:creator>
        <meta refines="#a1" property="role" scheme="marc:relators">aut</meta>
        <meta refines="#a1" property="file-as">Author, First</meta>
        <dc:creator id="e1">Some Editor</dc:creator>
        <meta refines="#e1" property="role" scheme="marc:relators">edt</meta>
        <dc:language>en</dc:language>
        <dc:publisher>Original Press</dc:publisher>
        <dc:date>2019-03-01</dc:date>
        <dc:description>Original &lt;b&gt;description&lt;/b&gt; &amp; more</dc:description>
        <dc:subject>Fantasy</dc:subject>
        <dc:subject>Adventure</dc:subject>
        <dc:rights>All rights reserved</dc:rights>
        <meta property="dcterms:modified">2020-01-01T00:00:00Z</meta>
        <meta property="belongs-to-collection" id="c1">Original Series</meta>
        <meta refines="#c1" property="collection-type">series</meta>
        <meta refines="#c1" property="group-position">2</meta>
        <meta name="cover" content="cover-img"/>
        <meta name="custom:thing" content="keep me"/>
        <x:unknown xmlns:x="http://example.com/x" attr='single "quoted"'>opaque <![CDATA[<raw>]]></x:unknown>
      </metadata>
      <manifest>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
        <item id="cover-img" href="images/cover%20art.jpg" media-type="image/jpeg" properties="cover-image"/>
      </manifest>
      <spine page-progression-direction="ltr">
        <itemref idref="ch1"/>
      </spine>
      <guide>
        <reference type="text" href="ch1.xhtml" title="Start"/>
      </guide>
    </package>
    """

    public static let opf2 = """
    <?xml version='1.0' encoding='utf-8'?>
    <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uuid_id">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf" xmlns:calibre="http://calibre.kovidgoyal.net/2009/metadata">
        <dc:identifier opf:scheme="uuid" id="uuid_id">abcdef</dc:identifier>
        <dc:identifier opf:scheme="ISBN">9780000000002</dc:identifier>
        <dc:title>Calibre Book</dc:title>
        <dc:creator opf:role="aut" opf:file-as="Author, First">First Author</dc:creator>
        <dc:creator opf:role="aut">Second Author</dc:creator>
        <dc:contributor opf:role="bkp">calibre (7.0) [https://calibre-ebook.com]</dc:contributor>
        <dc:language>en</dc:language>
        <dc:date>2011-06-01T00:00:00+00:00</dc:date>
        <meta name="calibre:series" content="Calibre Series"/>
        <meta name="calibre:series_index" content="3.0"/>
        <meta name="calibre:timestamp" content="2024-01-01T00:00:00+00:00"/>
      </metadata>
      <manifest>
        <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
        <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
      </manifest>
      <spine toc="ncx">
        <itemref idref="ch1"/>
      </spine>
    </package>
    """

    public static let chapter = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title></head><body><h1>One</h1><p>Text.</p></body></html>
    """
    public static let nav = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Nav</title></head>
    <body><nav epub:type="toc"><ol><li><a href="ch1.xhtml">One</a></li></ol></nav></body></html>
    """
    public static let ncx = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="abcdef"/></head>
    <docTitle><text>Calibre Book</text></docTitle><navMap><navPoint id="n1" playOrder="1"><navLabel><text>One</text></navLabel><content src="ch1.xhtml"/></navPoint></navMap></ncx>
    """

    /// Builds an EPUB with ZIPFoundation. `mimetype` goes in first and uncompressed.
    public static func makeEPUB(at url: URL, files: [(path: String, data: Data)]) throws {
        let archive = try Archive(url: url, accessMode: .create)
        func add(_ path: String, _ data: Data, _ method: CompressionMethod) throws {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: method) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        try add("mimetype", Data("application/epub+zip".utf8), .none)
        try add("META-INF/container.xml", Data(container.utf8), .deflate)
        for file in files { try add(file.path, file.data, .deflate) }
    }

    public static func makeEPUB3(in dir: URL, name: String = "book3.epub") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try makeEPUB(at: url, files: [
            ("OEBPS/content.opf", Data(opf3.utf8)), ("OEBPS/nav.xhtml", Data(nav.utf8)),
            ("OEBPS/ch1.xhtml", Data(chapter.utf8)), ("OEBPS/images/cover art.jpg", makeImage(.jpeg)),
        ])
        return url
    }

    public static func makeEPUB2(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("book2.epub")
        try makeEPUB(at: url, files: [
            ("OEBPS/content.opf", Data(opf2.utf8)), ("OEBPS/toc.ncx", Data(ncx.utf8)), ("OEBPS/ch1.xhtml", Data(chapter.utf8)),
        ])
        return url
    }

    // MARK: PDF

    /// A three-page PDF drawn with Core Graphics, with Info-dictionary metadata.
    public static func makePDF(at url: URL, pages: Int = 3) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info: [CFString: Any] = [
            kCGPDFContextTitle: "Original Title", kCGPDFContextAuthor: "Original Author",
            kCGPDFContextKeywords: ["alpha", "beta"], kCGPDFContextSubject: "Original Subject",
            kCGPDFContextCreator: "FixtureMaker",
        ]
        let ctx = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary)!
        for page in 1...pages {
            ctx.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: "Page \(page) of the fixture", attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 24, nil)]))
            ctx.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

}
