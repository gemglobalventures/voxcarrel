import Foundation

/// The one thing a link serves, and what a request must say to be given it.
struct PhoneLinkResource: Equatable, Sendable {
    /// The secret, as the bytes of its text.
    var token: [UInt8]
    /// The file's name as UTF-8, not percent-encoded.
    var fileName: [UInt8]
    /// The file's size in bytes.
    var size: Int64
    /// The address and port the link listens on, as "192.168.1.20:50123".
    var authority: String

    init(token: String, fileName: String, size: Int64, authority: String) {
        self.token = Array(token.utf8)
        self.fileName = Array(fileName.utf8)
        self.size = size
        self.authority = authority
    }
}

/// Reads what a caller sent and decides the answer. Works on bytes alone, and takes every
/// one of them to be hostile: there is exactly one request it accepts, and anything it
/// does not recognise in full is refused.
enum PhoneLinkRequest {
    /// The most a request line and its headers may come to, with the blank line that
    /// ends them.
    static let maxHeadBytes = 8192
    static let maxHeaders = 64

    struct Header: Equatable, Sendable {
        /// In lower case.
        var name: String
        /// Without the spaces around it.
        var value: String
    }

    /// A request line and headers that are well formed. Nothing here says the request is
    /// for the file.
    struct Head: Equatable, Sendable {
        /// True for HEAD; otherwise it is GET.
        var isHeadOnly: Bool
        /// The request target exactly as sent: it starts with "/" and holds only visible
        /// ASCII characters.
        var target: [UInt8]
        var isHTTP10: Bool
        var headers: [Header]

        func values(_ name: String) -> [String] {
            headers.filter { $0.name == name }.map(\.value)
        }
    }

    enum Parsed: Equatable, Sendable {
        /// The headers have not ended yet, and nothing so far is wrong.
        case incomplete
        /// Not a request this server takes; nothing more need be read.
        case rejected
        case head(Head)
    }

    enum Answer: Equatable, Sendable {
        /// Read more before deciding.
        case needMore
        /// 404, with nothing in it, and the connection closed.
        case notFound
        /// The file, or only its headers; from `rangeFrom` to the end (206) when set.
        case serve(headOnly: Bool, rangeFrom: Int64?)
    }

    // MARK: Parsing

    private static let cr = UInt8(ascii: "\r")
    private static let lf = UInt8(ascii: "\n")
    private static let space = UInt8(ascii: " ")
    private static let tab = UInt8(ascii: "\t")

    /// Reads a request line and headers from the start of `bytes`. Whatever follows the
    /// blank line that ends them is not looked at: one connection, one request.
    ///
    /// Lines end with CR LF and nothing else. A control character anywhere (NUL
    /// included), a bare LF or CR, a header continued over two lines, a method other
    /// than GET or HEAD, a version other than HTTP/1.0 or 1.1, a target that is not a
    /// path, or more than `maxHeadBytes` before the blank line: all rejected, as soon as
    /// they can be seen.
    static func parse(_ bytes: [UInt8]) -> Parsed {
        var lineStart = 0
        var lines: [Range<Int>] = []
        var end: Int?
        var index = 0
        let limit = min(bytes.count, maxHeadBytes)
        while index < limit {
            let byte = bytes[index]
            if byte == lf {
                // Only ever as the second half of a line ending.
                guard index > 0, bytes[index - 1] == cr else { return .rejected }
                let line = lineStart..<(index - 1)
                if line.isEmpty {
                    guard !lines.isEmpty else { return .rejected }
                    end = index + 1
                    break
                }
                // The request line is judged as soon as it is whole.
                if lines.isEmpty, requestLine(bytes[line]) == nil { return .rejected }
                lines.append(line)
                guard lines.count <= maxHeaders + 1 else { return .rejected }
                lineStart = index + 1
            } else if byte == cr {
                if index + 1 < bytes.count, bytes[index + 1] != lf { return .rejected }
            } else if byte < 0x20 && byte != tab || byte == 0x7F {
                return .rejected
            }
            index += 1
        }
        guard end != nil else {
            return bytes.count >= maxHeadBytes ? .rejected : .incomplete
        }
        guard let first = lines.first, var head = requestLine(bytes[first]) else { return .rejected }
        for line in lines.dropFirst() {
            guard let header = header(bytes[line]) else { return .rejected }
            head.headers.append(header)
        }
        return .head(head)
    }

    /// `GET /path HTTP/1.1`: three parts with one space between each, and nothing else.
    private static func requestLine(_ line: ArraySlice<UInt8>) -> Head? {
        let parts = line.split(separator: space, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let isHeadOnly: Bool
        switch Array(parts[0]) {
        case Array("GET".utf8): isHeadOnly = false
        case Array("HEAD".utf8): isHeadOnly = true
        default: return nil
        }
        let isHTTP10: Bool
        switch Array(parts[2]) {
        case Array("HTTP/1.1".utf8): isHTTP10 = false
        case Array("HTTP/1.0".utf8): isHTTP10 = true
        default: return nil
        }
        // A path, never a whole address ("http://…") or "*", of visible ASCII only.
        let target = Array(parts[1])
        guard target.first == UInt8(ascii: "/"), target.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { return nil }
        return Head(isHeadOnly: isHeadOnly, target: target, isHTTP10: isHTTP10, headers: [])
    }

    /// `Name: value`. The name is a token with the colon straight after it; a line that
    /// starts with a space (a continuation of the one before) is not a header.
    private static func header(_ line: ArraySlice<UInt8>) -> Header? {
        guard let colon = line.firstIndex(of: UInt8(ascii: ":")) else { return nil }
        let name = line[line.startIndex..<colon]
        guard !name.isEmpty, name.allSatisfy(isTokenCharacter) else { return nil }
        var value = line[(colon + 1)...]
        while let first = value.first, first == space || first == tab { value = value.dropFirst() }
        while let last = value.last, last == space || last == tab { value = value.dropLast() }
        return Header(
            name: String(decoding: name, as: UTF8.self).lowercased(), value: String(decoding: value, as: UTF8.self))
    }

    private static func isTokenCharacter(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            true
        default: "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }

    // MARK: Deciding

    /// What to answer to what has been read so far.
    ///
    /// The file is served to a GET or HEAD of `/<token>/<fileName>` and to nothing else:
    /// the token as it is, the name percent-decoded once and then equal byte for byte.
    /// A query, a fragment, a third segment, an encoded slash or NUL, a `Host` that is
    /// not this link's address, or a request with a body: 404, as for anything
    /// `parse` rejects. The token and the name are both always compared, so that the
    /// answer and the time it takes say nothing of which was wrong.
    static func answer(_ bytes: [UInt8], for resource: PhoneLinkResource) -> Answer {
        let head: Head
        switch parse(bytes) {
        case .incomplete: return .needMore
        case .rejected: return .notFound
        case .head(let parsed): head = parsed
        }

        // The caller must be talking to this address: a page that reaches the Mac under
        // some other name is not served.
        let hosts = head.values("host")
        let hostIsRight: Bool
        switch hosts.count {
        case 0: hostIsRight = head.isHTTP10
        case 1: hostIsRight = hosts[0].lowercased() == resource.authority.lowercased()
        default: hostIsRight = false
        }
        // No request for the file has a body.
        let hasBody = !head.values("transfer-encoding").isEmpty
            || head.values("content-length").contains { $0 != "0" }

        let segments = head.target.dropFirst().split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        let isPlainPath = segments.count == 2
            && !head.target.contains { $0 == UInt8(ascii: "?") || $0 == UInt8(ascii: "#") || $0 == UInt8(ascii: "\\") }
        let tokenSent = segments.count > 0 ? Array(segments[0]) : []
        let nameSent = segments.count > 1 ? percentDecoded(segments[1]) : nil

        let tokenIsRight = PhoneLinkText.constantTimeEquals(secret: resource.token, candidate: tokenSent)
        let nameIsRight = PhoneLinkText.constantTimeEquals(secret: resource.fileName, candidate: nameSent ?? [])
        guard tokenIsRight, nameIsRight, nameSent != nil, isPlainPath, hostIsRight, !hasBody else {
            return .notFound
        }
        return .serve(headOnly: head.isHeadOnly, rangeFrom: rangeStart(head, size: resource.size))
    }

    /// The bytes a path segment stands for, each `%XX` decoded once. Nil when a `%` is
    /// not followed by two hexadecimal digits, or when what comes out holds a NUL or a
    /// slash: neither can be part of a name.
    static func percentDecoded(_ segment: ArraySlice<UInt8>) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(segment.count)
        var index = segment.startIndex
        while index < segment.endIndex {
            var byte = segment[index]
            if byte == UInt8(ascii: "%") {
                guard index + 2 < segment.endIndex, let high = hexValue(segment[index + 1]),
                      let low = hexValue(segment[index + 2])
                else { return nil }
                byte = high << 4 | low
                index += 2
            }
            guard byte != 0, byte != UInt8(ascii: "/") else { return nil }
            out.append(byte)
            index += 1
        }
        return out
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    /// Where a `Range: bytes=N-` asks to start, when N is inside the file. Every other
    /// form of range (an end, a suffix, several ranges, several headers, one that
    /// depends on `If-Range`) is ignored, and the whole file is sent.
    private static func rangeStart(_ head: Head, size: Int64) -> Int64? {
        let ranges = head.values("range")
        guard ranges.count == 1, head.values("if-range").isEmpty else { return nil }
        let prefix = "bytes="
        let value = ranges[0]
        guard value.hasPrefix(prefix), value.hasSuffix("-") else { return nil }
        let digits = value.dropFirst(prefix.count).dropLast()
        guard !digits.isEmpty, digits.count <= 18, digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let start = Int64(digits), start < size
        else { return nil }
        return start
    }

    // MARK: Responses

    /// The one answer to everything that is not a good request for the file.
    static let notFound = Array("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)

    /// The headers of the answer that carries the file, or the part of it from `rangeFrom`.
    static func fileHeaders(fileName: String, size: Int64, rangeFrom: Int64?) -> [UInt8] {
        var lines: [String] = []
        if let rangeFrom {
            lines.append("HTTP/1.1 206 Partial Content")
            lines.append("Content-Range: bytes \(rangeFrom)-\(size - 1)/\(size)")
            lines.append("Content-Length: \(size - rangeFrom)")
        } else {
            lines.append("HTTP/1.1 200 OK")
            lines.append("Content-Length: \(size)")
        }
        lines.append("Content-Type: application/octet-stream")
        lines.append("Content-Disposition: \(contentDisposition(fileName))")
        lines.append("Accept-Ranges: bytes")
        lines.append("Cache-Control: no-store")
        lines.append("X-Content-Type-Options: nosniff")
        lines.append("Connection: close")
        return Array((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// `attachment` with the name twice: in plain ASCII, with anything else (and
    /// anything that could end the quotation or the line) as "_", and in full, encoded.
    static func contentDisposition(_ fileName: String) -> String {
        let plain = String(String.UnicodeScalarView(fileName.unicodeScalars.map { scalar in
            scalar.value >= 0x20 && scalar.value < 0x7F && scalar != "\"" && scalar != "\\" && scalar != "%"
                ? scalar : "_"
        }))
        return "attachment; filename=\"\(plain)\"; filename*=UTF-8''\(PhoneLinkText.percentEncoded(fileName))"
    }
}
