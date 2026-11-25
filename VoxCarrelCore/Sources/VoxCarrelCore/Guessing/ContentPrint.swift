import CryptoKit
import Foundation
import PDFKit
import ZIPFoundation

/// What tells a book file from every other by what it holds, its tags aside: the
/// sound of an audiobook, the text of an ebook. Writing a title, an author, a genre or
/// a cover into a file leaves its content print as it was, so a file the library has
/// tagged is still known for the file it came from.
///
/// A print reads "kind:measure:digest". The first two parts (`ContentPrint.Key`) are
/// cheap to find and say which files could be the same at all; the digest is worked
/// out only for those.
public enum ContentPrint {
    /// The cheap part of a print, and how to finish it.
    public struct Key {
        /// "mp3:36043271", "m4b:1:35990012", "epub:14:820331", "pdf:212".
        public let prefix: String
        fileprivate let finish: () -> String?

        /// The whole print; nil when the file's contents could not be read through.
        public func full() -> String? {
            finish().map { "\(prefix):\($0)" }
        }
    }

    /// The whole print of a file; nil for a file this cannot be worked out for.
    public static func of(_ url: URL) -> String? {
        key(of: url)?.full()
    }

    /// The part of a print that says which files could be the same; nil for a format
    /// that has no tags to set aside (its bytes are its print: `BookScanner.fingerprint`),
    /// for a file that is not what its name says, and for one that cannot be read.
    public static func key(of url: URL) -> Key? {
        switch FileFormat(url: url) {
        case .mp3: mp3(url)
        case .m4b, .m4a: mp4(url)
        case .epub: epub(url)
        case .pdf: pdf(url)
        default: nil
        }
    }

    /// The prefix of a stored print: all of it but the digest.
    public static func prefix(of print: String) -> String? {
        guard let cut = print.lastIndex(of: ":") else { return nil }
        return String(print[..<cut])
    }

    // MARK: Stretches of a file

    /// As much of a stretch is read as tells it from any other: all of it up to this
    /// size, and beyond that its two ends.
    static let whole: UInt64 = 32 * 1024 * 1024
    static let edge: UInt64 = 4 * 1024 * 1024

    struct Stretch: Equatable {
        var start: UInt64
        var length: UInt64
    }

    /// A digest of stretches of a file, each with its length; nil when one cannot be read.
    static func digest(of url: URL, _ stretches: [Stretch]) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        func feed(from start: UInt64, count: UInt64) -> Bool {
            guard (try? handle.seek(toOffset: start)) != nil else { return false }
            var left = count
            while left > 0 {
                guard let chunk = try? handle.read(upToCount: Int(min(left, 1024 * 1024))), !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                left -= UInt64(chunk.count)
            }
            return true
        }
        for stretch in stretches {
            var length = stretch.length.littleEndian
            hasher.update(data: Data(bytes: &length, count: 8))
            if stretch.length <= whole {
                guard feed(from: stretch.start, count: stretch.length) else { return nil }
            } else {
                guard feed(from: stretch.start, count: edge),
                      feed(from: stretch.start + stretch.length - edge, count: edge)
                else { return nil }
            }
        }
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) -> Data? {
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: count),
              data.count == count
        else { return nil }
        return data
    }

    // MARK: MP3

    /// The sound of an MP3: what lies between the tags at its start (ID3v2, however
    /// many) and the tags at its end (ID3v1, APE, and an ID3v2 written last).
    static func mp3Sound(_ url: URL) -> Stretch? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        var start: UInt64 = 0
        // Tags at the start.
        while start + 10 <= size, let head = read(handle, at: start, count: 10), head.starts(with: [0x49, 0x44, 0x33]) {
            let bytes = [UInt8](head)
            guard bytes[6] < 0x80, bytes[7] < 0x80, bytes[8] < 0x80, bytes[9] < 0x80 else { break }
            let body = UInt64(bytes[6]) << 21 | UInt64(bytes[7]) << 14 | UInt64(bytes[8]) << 7 | UInt64(bytes[9])
            let footer: UInt64 = bytes[5] & 0x10 != 0 ? 10 : 0
            start += 10 + body + footer
        }
        guard start < size else { return nil }
        var end = size
        // Tags at the end, whichever order they were written in.
        var found = true
        while found {
            found = false
            if end >= start + 128, let tail = read(handle, at: end - 128, count: 3), tail.elementsEqual([0x54, 0x41, 0x47]) {
                end -= 128
                found = true
            }
            if end >= start + 32, let foot = read(handle, at: end - 32, count: 32),
               foot.prefix(8).elementsEqual(Array("APETAGEX".utf8)) {
                let bytes = [UInt8](foot)
                let body = UInt64(bytes[12]) | UInt64(bytes[13]) << 8 | UInt64(bytes[14]) << 16 | UInt64(bytes[15]) << 24
                let hasHeader = bytes[23] & 0x80 != 0
                let all = body + (hasHeader ? 32 : 0)
                if all >= 32, end >= start + all {
                    end -= all
                    found = true
                }
            }
            if end >= start + 10, let foot = read(handle, at: end - 10, count: 10), foot.starts(with: [0x33, 0x44, 0x49]) {
                let bytes = [UInt8](foot)
                let body = UInt64(bytes[6]) << 21 | UInt64(bytes[7]) << 14 | UInt64(bytes[8]) << 7 | UInt64(bytes[9])
                if end >= start + body + 20 {
                    end -= body + 20
                    found = true
                }
            }
        }
        guard end > start else { return nil }
        return Stretch(start: start, length: end - start)
    }

    private static func mp3(_ url: URL) -> Key? {
        guard let sound = mp3Sound(url) else { return nil }
        return Key(prefix: "mp3:\(sound.length)") { digest(of: url, [sound]) }
    }

    // MARK: M4B and M4A

    /// The sound of an MPEG-4 file: the contents of its `mdat` boxes, in order.
    static func mp4Sound(_ url: URL) -> [Stretch]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 8 else { return nil }
        var offset: UInt64 = 0
        var found: [Stretch] = []
        var sawFileType = false
        var boxes = 0
        while offset + 8 <= size {
            boxes += 1
            guard boxes < 10_000, let head = read(handle, at: offset, count: 8) else { return nil }
            let bytes = [UInt8](head)
            var length = UInt64(bytes[0]) << 24 | UInt64(bytes[1]) << 16 | UInt64(bytes[2]) << 8 | UInt64(bytes[3])
            let kind = String(decoding: bytes[4..<8], as: UTF8.self)
            var headLength: UInt64 = 8
            if length == 1 {
                guard let wide = read(handle, at: offset + 8, count: 8) else { return nil }
                length = [UInt8](wide).reduce(0) { $0 << 8 | UInt64($1) }
                headLength = 16
            } else if length == 0 {
                length = size - offset
            }
            guard length >= headLength, offset + length <= size else { return nil }
            if kind == "ftyp" { sawFileType = true }
            if kind == "mdat", length > headLength {
                found.append(Stretch(start: offset + headLength, length: length - headLength))
            }
            offset += length
        }
        return sawFileType && !found.isEmpty ? found : nil
    }

    private static func mp4(_ url: URL) -> Key? {
        guard let sound = mp4Sound(url) else { return nil }
        let total = sound.reduce(UInt64(0)) { $0 + $1.length }
        return Key(prefix: "m4b:\(sound.count):\(total)") { digest(of: url, sound) }
    }

    // MARK: EPUB

    /// Endings of what an EPUB holds besides its text: the pictures (the cover among
    /// them, which may be replaced) and what describes the book.
    private static let notText: Set<String> = ["opf", "jpg", "jpeg", "png", "gif", "svg", "webp", "ncx"]

    /// The text of an EPUB: its content files by name, each with the check sum and
    /// size the archive records for it. Nothing is unpacked.
    private static func epub(_ url: URL) -> Key? {
        guard let archive = try? Archive(url: url, accessMode: .read) else { return nil }
        var parts: [(path: String, sum: UInt32, size: UInt64)] = []
        var count = 0
        for entry in archive {
            count += 1
            guard count < 50_000 else { return nil }
            guard entry.type == .file else { continue }
            let path = entry.path
            let ending = (path as NSString).pathExtension.lowercased()
            if notText.contains(ending) || path == "mimetype" || path.hasPrefix("META-INF/") { continue }
            parts.append((path, entry.checksum, UInt64(entry.uncompressedSize)))
        }
        guard !parts.isEmpty else { return nil }
        parts.sort { $0.path < $1.path }
        let total = parts.reduce(UInt64(0)) { $0 + $1.size }
        return Key(prefix: "epub:\(parts.count):\(total)") {
            var hasher = SHA256()
            for part in parts { hasher.update(data: Data("\(part.path)\u{0}\(part.sum)\u{0}\(part.size)\n".utf8)) }
            return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
        }
    }

    // MARK: PDF

    /// The least text the sampled pages must hold for a PDF to have a print: a
    /// scanned book has none, and two of those must never be taken for one.
    static let leastPDFText = 200

    /// The text of a PDF: its number of pages, and the words of its first three pages,
    /// its middle page and its last. Nil for a locked file and for one with too
    /// little text to tell it by.
    private static func pdf(_ url: URL) -> Key? {
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else { return nil }
        let pages = document.pageCount
        return Key(prefix: "pdf:\(pages)") {
            var wanted = Array(0..<min(3, pages))
            for index in [pages / 2, pages - 1] where !wanted.contains(index) { wanted.append(index) }
            var hasher = SHA256()
            var letters = 0
            for index in wanted {
                // Spaces and line ends are laid out again when the file is re-saved.
                let text = (document.page(at: index)?.string ?? "").filter { !$0.isWhitespace }
                letters += text.count
                hasher.update(data: Data("\(index)\u{0}\(text)\n".utf8))
            }
            guard letters >= leastPDFText else { return nil }
            return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
        }
    }
}
