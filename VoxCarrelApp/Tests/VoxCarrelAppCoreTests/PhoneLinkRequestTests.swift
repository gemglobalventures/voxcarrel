import Foundation
import Testing

@testable import VoxCarrelAppCore

/// PH2 and PH3 against the request reader itself: every byte of a request is hostile.
@Suite struct PhoneLinkRequestTests {
    typealias R = PhoneLinkRequest
    static let token = "q7fX2mB_c1-ZpLk09sTtUuVvWwXxYyZz0123456789a"
    static let host = "192.168.1.20:50123"

    static func resource(_ name: String = "Dune.m4b", size: Int64 = 1000) -> PhoneLinkResource {
        PhoneLinkResource(token: token, fileName: name, size: size, authority: host)
    }

    static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// A request with this request line and a correct `Host`, then these header lines.
    static func request(_ line: String, _ headers: [String] = [], host: String? = PhoneLinkRequestTests.host) -> [UInt8] {
        let all = [line] + (host.map { ["Host: \($0)"] } ?? []) + headers
        return bytes(all.joined(separator: "\r\n") + "\r\n\r\n")
    }

    static func good(_ method: String = "GET", name: String = "Dune.m4b", _ headers: [String] = []) -> [UInt8] {
        request("\(method) /\(token)/\(name) HTTP/1.1", headers)
    }

    static func good(_ headers: [String]) -> [UInt8] {
        good("GET", headers)
    }

    func answer(_ bytes: [UInt8], _ resource: PhoneLinkResource = PhoneLinkRequestTests.resource()) -> R.Answer {
        R.answer(bytes, for: resource)
    }

    func answer(_ text: String) -> R.Answer {
        answer(Self.bytes(text))
    }

    // MARK: PH2 The one resource

    @Test func ph2_getAndHeadOfTheTokenAndNameAreServed() {
        #expect(answer(Self.good()) == .serve(headOnly: false, rangeFrom: nil))
        #expect(answer(Self.good("HEAD")) == .serve(headOnly: true, rangeFrom: nil))
        // HTTP/1.0 has no Host.
        #expect(answer("GET /\(Self.token)/Dune.m4b HTTP/1.0\r\n\r\n") == .serve(headOnly: false, rangeFrom: nil))
        // Header names in any case, with other headers about.
        let busy = Self.request(
            "GET /\(Self.token)/Dune.m4b HTTP/1.1",
            ["User-Agent: BookPlayer/5 CFNetwork", "Accept: */*", "Accept-Encoding: gzip, deflate", "Connection: keep-alive"],
            host: nil) + []
        #expect(answer(busy) == .notFound)  // no Host on HTTP/1.1
        let withHost = Self.bytes(
            "GET /\(Self.token)/Dune.m4b HTTP/1.1\r\nhOsT:  \(Self.host) \r\nUser-Agent: x\r\nAccept: */*\r\n\r\n")
        #expect(answer(withHost) == .serve(headOnly: false, rangeFrom: nil))
    }

    @Test func ph2_aWrongOrMissingTokenIsNotFound() {
        let name = "Dune.m4b"
        var wrongLast = Self.token
        wrongLast.removeLast()
        wrongLast.append("b")
        var wrongFirst = Self.token
        wrongFirst.removeFirst()
        for token in [
            "", "x", wrongLast, "A" + wrongFirst, String(Self.token.dropLast()), Self.token + "a", Self.token.uppercased(),
            String(repeating: "a", count: 43), Self.token + "%00",
            // The token is compared as sent: an encoded form of it is another string.
            "%71" + Self.token.dropFirst(),
        ] {
            #expect(answer(Self.request("GET /\(token)/\(name) HTTP/1.1")) == .notFound, "\(token.count) characters")
        }
        #expect(answer(Self.request("GET /\(name) HTTP/1.1")) == .notFound)
        #expect(answer(Self.request("GET //\(name) HTTP/1.1")) == .notFound)
    }

    @Test func ph2_aWrongNameIsNotFound() {
        for name in ["", "dune.m4b", "Dune.m4", "Dune.m4bx", "Dune", "Other.m4b", "Dune.m4b%20", "%20Dune.m4b", "Dune%2Em4b%00"] {
            #expect(answer(Self.request("GET /\(Self.token)/\(name) HTTP/1.1")) == .notFound, "\(name)")
        }
    }

    @Test func ph2_theNameIsComparedAfterPercentDecodingExactly() {
        let name = "Dune – “Messiah” & Co #1?.m4b"
        let resource = Self.resource(name)
        let encoded = PhoneLinkText.percentEncoded(name)
        #expect(answer(Self.good(name: encoded), resource) == .serve(headOnly: false, rangeFrom: nil))
        // Any encoding of the same bytes will do, in either case of the digits.
        #expect(answer(Self.good(name: "%44une.m4b")) == .serve(headOnly: false, rangeFrom: nil))
        #expect(answer(Self.good(name: "Dune%2em4b")) == .serve(headOnly: false, rangeFrom: nil))
        // The same letters composed differently are other bytes: not the name.
        let composed = Self.resource("Caf\u{00E9}.m4b")
        #expect(answer(Self.good(name: "Caf%C3%A9.m4b"), composed) == .serve(headOnly: false, rangeFrom: nil))
        #expect(answer(Self.good(name: "Cafe%CC%81.m4b"), composed) == .notFound)
    }

    @Test func ph2_doubleEncodingIsDecodedOnce() {
        // "%2541" is "%41" once decoded, never "A".
        #expect(answer(Self.good(name: "%2544une.m4b")) == .notFound)
        #expect(answer(Self.good(name: "Dune%252Em4b")) == .notFound)
        // A file really named with a percent sign is reached by encoding that sign.
        let odd = Self.resource("100%2Fsure.m4b")
        #expect(answer(Self.good(name: "100%252Fsure.m4b"), odd) == .serve(headOnly: false, rangeFrom: nil))
        #expect(answer(Self.good(name: "100%2Fsure.m4b"), odd) == .notFound)
    }

    @Test func ph2_everyOtherPathIsNotFound() {
        let t = Self.token
        for target in [
            "/", "/\(t)", "/\(t)/", "/\(t)//Dune.m4b", "/\(t)/Dune.m4b/", "/\(t)/Dune.m4b/x", "/x/\(t)/Dune.m4b",
            "/\(t)/sub/Dune.m4b", "/index.html", "/favicon.ico", "/.well-known/x", "/\(t)/.", "/\(t)/..",
            // Dot segments, plain and encoded.
            "/\(t)/../\(t)/Dune.m4b", "/\(t)/./Dune.m4b", "/../\(t)/Dune.m4b", "/\(t)/..%2FDune.m4b",
            "/\(t)/%2e%2e/Dune.m4b", "/\(t)/%2E%2E%2FDune.m4b", "/\(t)/Dune.m4b/..", "/\(t)/Dune.m4b/%2e%2e",
            "/\(t)/..%2f..%2f..%2fetc%2fpasswd", "/\(t)/../../../etc/passwd", "/etc/passwd",
            // An encoded slash or NUL, in the name or in place of the separator.
            "/\(t)%2FDune.m4b", "/\(t)/Dune%2F.m4b", "/\(t)/%2FDune.m4b", "/\(t)/Dune.m4b%2F", "/\(t)/Dune.m4b%00",
            "/\(t)/Dune%00.m4b", "/\(t)/%00", "/\(t)%00/Dune.m4b", "/\(t)/Dune.m4b%00.jpg",
            // Encoded twice.
            "/\(t)/%252e%252e/Dune.m4b", "/\(t)%252FDune.m4b",
            // A broken encoding.
            "/\(t)/Dune.m4b%", "/\(t)/Dune.m4b%4", "/\(t)/Dune%zz.m4b", "/\(t)/%G0une.m4b", "/\(t)/Dune.m4b%2",
            // A query, a fragment, a backslash.
            "/\(t)/Dune.m4b?", "/\(t)/Dune.m4b?x=1", "/\(t)/Dune.m4b?token=\(t)", "/?\(t)/Dune.m4b",
            "/\(t)/Dune.m4b#x", "/\(t)\\Dune.m4b", "/\(t)/Dune.m4b\\", "/\(t)/..\\Dune.m4b",
            "/\(t)/Dune.m4b;x=1",
        ] {
            #expect(answer(Self.request("GET \(target) HTTP/1.1")) == .notFound, "\(target.dropFirst(t.count + 1))")
            #expect(answer(Self.request("HEAD \(target) HTTP/1.1")) == .notFound, "\(target.dropFirst(t.count + 1))")
        }
    }

    @Test func ph2_aTargetThatIsNotAPathIsNotFound() {
        let t = Self.token
        for target in [
            "http://\(Self.host)/\(t)/Dune.m4b", "HTTP://\(Self.host)/\(t)/Dune.m4b", "https://\(Self.host)/\(t)/Dune.m4b",
            "//\(Self.host)/\(t)/Dune.m4b", "\(Self.host)", "*", "\(t)/Dune.m4b", "file:///etc/passwd",
            "http://evil.example/\(t)/Dune.m4b",
        ] {
            #expect(answer(Self.request("GET \(target) HTTP/1.1")) == .notFound, "\(target.prefix(12))")
        }
    }

    @Test func ph2_everyOtherMethodIsNotFound() {
        for method in [
            "POST", "PUT", "DELETE", "OPTIONS", "PATCH", "TRACE", "CONNECT", "PROPFIND", "get", "Get", "head", "GETS",
            "GE", "G", "", "HEADER", "GET\t", "\tGET", "PRI",
        ] {
            #expect(answer(Self.request("\(method) /\(Self.token)/Dune.m4b HTTP/1.1")) == .notFound, "\(method)")
        }
    }

    @Test func ph2_aRequestLineOfAnotherShapeIsNotFound() {
        let path = "/\(Self.token)/Dune.m4b"
        for line in [
            // HTTP/0.9: no version at all.
            "GET \(path)", "GET \(path) ",
            "GET \(path) HTTP/2.0", "GET \(path) HTTP/2", "GET \(path) HTTP/0.9", "GET \(path) HTTP/1.2",
            "GET \(path) http/1.1", "GET \(path) HTTP/1.1 ", "GET \(path) HTTP/1.1 x", "GET \(path)  HTTP/1.1",
            "GET  \(path) HTTP/1.1", " GET \(path) HTTP/1.1", "GET\t\(path)\tHTTP/1.1", "GET \(path)\tHTTP/1.1",
            "GET /\(Self.token)/Du ne.m4b HTTP/1.1", "GET", "", " ", "GET HTTP/1.1", "\(path)",
        ] {
            #expect(answer(Self.request(line)) == .notFound, "\(line.suffix(24))")
        }
        // The HTTP/2 preface.
        #expect(answer("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n") == .notFound)
        // A TLS hello, and other noise.
        #expect(answer([0x16, 0x03, 0x01, 0x02, 0x00, 0x01, 0x00, 0x01, 0xFC, 0x03, 0x03]) == .notFound)
        #expect(answer([0xFF, 0xFE, 0x00, 0x00]) == .notFound)
        #expect(answer("\r\n\r\n") == .notFound)
        #expect(answer("\r\n" + String(decoding: Self.good(), as: UTF8.self)) == .notFound)
    }

    @Test func ph2_linesMustEndWithCRLF() {
        let path = "/\(Self.token)/Dune.m4b"
        // Bare LF throughout, or anywhere.
        #expect(answer("GET \(path) HTTP/1.1\nHost: \(Self.host)\n\n") == .notFound)
        #expect(answer("GET \(path) HTTP/1.1\r\nHost: \(Self.host)\n\r\n") == .notFound)
        #expect(answer("GET \(path) HTTP/1.1\nHost: \(Self.host)\r\n\r\n") == .notFound)
        #expect(answer("GET \(path) HTTP/1.1\r\nHost: \(Self.host)\r\n\n") == .notFound)
        #expect(answer("\n") == .notFound)
        // A bare CR.
        #expect(answer("GET \(path) HTTP/1.1\rHost: \(Self.host)\r\r") == .notFound)
        #expect(answer("GET \(path) HTTP/1.1\r\nHost: \(Self.host)\r\r\n\r\n") == .notFound)
        #expect(answer("GET \(path)\rx HTTP/1.1\r\nHost: \(Self.host)\r\n\r\n") == .notFound)
        // No line ending at all yet: more is needed, and nothing is served meanwhile.
        #expect(answer("GET \(path) HTTP/1.1") == .needMore)
        #expect(answer("GET \(path) HTTP/1.1\r") == .needMore)
        #expect(answer("GET \(path) HTTP/1.1\r\n") == .needMore)
        #expect(answer("GET \(path) HTTP/1.1\r\nHost: \(Self.host)\r\n") == .needMore)
        #expect(answer("GET \(path) HTTP/1.1\r\nHost: \(Self.host)\r\n\r") == .needMore)
        #expect(answer("") == .needMore)
    }

    @Test func ph2_aNulOrOtherControlCharacterAnywhereIsNotFound() {
        let good = Self.good(["Accept: */*"])
        #expect(answer(good) == .serve(headOnly: false, rangeFrom: nil))
        for control: UInt8 in [0x00, 0x01, 0x07, 0x08, 0x0B, 0x0C, 0x1B, 0x1F, 0x7F] {
            // Put in place of each byte in turn: never served, whatever it replaces.
            for index in good.indices {
                var bad = good
                bad[index] = control
                #expect(answer(bad) != .serve(headOnly: false, rangeFrom: nil), "\(control) at \(index)")
            }
            // Inserted at the end of the name, of the token and of a header.
            var inName = Array("GET /\(Self.token)/Dune.m4b".utf8)
            inName.append(control)
            inName += Array(" HTTP/1.1\r\nHost: \(Self.host)\r\n\r\n".utf8)
            #expect(answer(inName) == .notFound)
            #expect(answer(Self.bytes("GET /\(Self.token)/Dune.m4b HTTP/1.1\r\nHost: \(Self.host)\r\nX: a") + [control]) == .notFound)
        }
        // A NUL seen before the request is whole is already enough.
        #expect(answer([0x47, 0x45, 0x54, 0x00]) == .notFound)
        #expect(answer([0x00]) == .notFound)
        // Bytes that are not ASCII never belong in the request line.
        #expect(answer(Self.request("GET /\(Self.token)/Dune\u{00E9}.m4b HTTP/1.1")) == .notFound)
    }

    @Test func ph2_aRequestLineOrHeaderBlockOver8KBIsNotFound() {
        let path = "/\(Self.token)/Dune.m4b"
        // The line alone.
        #expect(answer("GET /" + String(repeating: "a", count: 9000)) == .notFound)
        #expect(answer("GET /" + String(repeating: "a", count: 9000) + " HTTP/1.1\r\n\r\n") == .notFound)
        #expect(answer(String(repeating: "A", count: 8192)) == .notFound)
        #expect(answer(String(repeating: "A", count: 8191)) == .needMore)
        // One long header, and many short ones.
        let start = "GET \(path) HTTP/1.1\r\nHost: \(Self.host)\r\n"
        #expect(answer(start + "X: " + String(repeating: "b", count: 9000) + "\r\n\r\n") == .notFound)
        #expect(answer(start + "X: " + String(repeating: "b", count: 9000)) == .notFound)
        #expect(answer(start + String(repeating: "X: y\r\n", count: 2000) + "\r\n") == .notFound)
        #expect(answer(start + String(repeating: "X: y\r\n", count: 70) + "\r\n") == .notFound)
        #expect(answer(start + String(repeating: "X: y\r\n", count: 60) + "\r\n") == .serve(headOnly: false, rangeFrom: nil))

        // Exactly at the limit is the last that is taken.
        func padded(to total: Int) -> String {
            let fixed = start + "X: " + "\r\n\r\n"
            return start + "X: " + String(repeating: "c", count: total - fixed.utf8.count) + "\r\n\r\n"
        }
        #expect(padded(to: 8192).utf8.count == 8192)
        #expect(answer(padded(to: 8192)) == .serve(headOnly: false, rangeFrom: nil))
        #expect(answer(padded(to: 8193)) == .notFound)
        #expect(R.maxHeadBytes == 8192)
    }

    @Test func ph2_headersMustBeWellFormed() {
        let start = "GET /\(Self.token)/Dune.m4b HTTP/1.1\r\nHost: \(Self.host)\r\n"
        for header in [
            "no colon here", ": no name", "Bad Name: x", "Name : x", " Folded: x", "\tFolded: x", "N\u{00E9}: x", "(x): y",
            "X\"y: z",
        ] {
            #expect(answer(start + header + "\r\n\r\n") == .notFound, "\(header)")
        }
        // A header continued on a second line.
        #expect(answer(start + "X: one\r\n two\r\n\r\n") == .notFound)
        #expect(answer(start + "X: a:b:c\r\nY:\r\nZ: \u{00E9}\r\n\r\n") == .serve(headOnly: false, rangeFrom: nil))
    }

    @Test func ph2_theHostMustBeThisLinksAddress() {
        let line = "GET /\(Self.token)/Dune.m4b HTTP/1.1"
        for host in [
            "evil.example", "evil.example:50123", "192.168.1.20", "192.168.1.20:80", "192.168.1.21:50123", "localhost:50123",
            "", "192.168.1.20:50123.", "192.168.1.20:50123@evil.example", "x@192.168.1.20:50123",
        ] {
            #expect(answer(Self.request(line, host: host)) == .notFound, "\(host)")
        }
        // Two of them, even when both are right.
        #expect(answer(Self.request(line, ["Host: \(Self.host)"])) == .notFound)
        #expect(answer(Self.request(line, ["Host: evil.example"])) == .notFound)
        // None at all, in HTTP/1.1.
        #expect(answer(Self.request(line, host: nil)) == .notFound)
        // HTTP/1.0 with a wrong one.
        #expect(answer("GET /\(Self.token)/Dune.m4b HTTP/1.0\r\nHost: evil.example\r\n\r\n") == .notFound)
    }

    @Test func ph2_aRequestWithABodyIsNotFound() {
        #expect(answer(Self.good(["Content-Length: 5"]) + Self.bytes("hello")) == .notFound)
        #expect(answer(Self.good(["Transfer-Encoding: chunked"])) == .notFound)
        #expect(answer(Self.good(["Content-Length: 0", "Content-Length: 7"])) == .notFound)
        #expect(answer(Self.good(["content-length: 0"])) == .serve(headOnly: false, rangeFrom: nil))
    }

    @Test func ph2_onlyTheFirstRequestOfAConnectionIsRead() {
        // A second request straight after the first: the answer is to the first alone.
        let second = Self.request("GET /etc/passwd HTTP/1.1")
        #expect(answer(Self.good() + second) == .serve(headOnly: false, rangeFrom: nil))
        #expect(answer(Self.good("HEAD") + Self.good()) == .serve(headOnly: true, rangeFrom: nil))
        // A bad first request is not rescued by a good second one.
        #expect(answer(second + Self.good()) == .notFound)
        #expect(answer(Self.request("POST /x HTTP/1.1") + Self.good()) == .notFound)
        // Whatever follows the first request is not even looked at.
        #expect(answer(Self.good() + [0x00, 0x0A, 0xFF]) == .serve(headOnly: false, rangeFrom: nil))
        #expect(answer(Self.good() + [UInt8](repeating: 0x41, count: 20_000)) == .serve(headOnly: false, rangeFrom: nil))
    }

    @Test func ph2_aRequestArrivingAByteAtATimeIsNeverServedEarly() {
        let whole = Self.good(["Range: bytes=10-"])
        for count in 0..<whole.count {
            #expect(answer(Array(whole.prefix(count))) == .needMore, "after \(count) bytes")
        }
        #expect(answer(whole) == .serve(headOnly: false, rangeFrom: 10))
    }

    @Test func ph2_noInputIsEverServedThatIsNotTheResource() {
        // Every request made by changing one byte of a good one is either still that
        // request for the same thing, or refused, or unfinished: never something else.
        let good = Self.good()
        var generator = SystemRandomNumberGenerator()
        for index in good.indices {
            for _ in 0..<8 {
                var changed = good
                changed[index] = UInt8.random(in: 0...255, using: &generator)
                switch answer(changed) {
                case .notFound, .needMore: break
                case .serve(let headOnly, let rangeFrom):
                    #expect(rangeFrom == nil)
                    // Only a change that leaves the request meaning the same thing is served.
                    let text = String(decoding: changed, as: UTF8.self)
                    #expect(text.hasPrefix("GET /\(Self.token)/") && !headOnly, "byte \(index) became \(changed[index])")
                    let hosts = text.components(separatedBy: "\r\n").filter { $0.lowercased().hasPrefix("host:") }
                        .map { $0.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }
                    #expect(hosts == [Self.host], "byte \(index) became \(changed[index])")
                    let path = text.dropFirst(5 + Self.token.count + 1).prefix { $0 != " " }
                    #expect(path.removingPercentEncoding == "Dune.m4b", "byte \(index) became \(changed[index])")
                }
            }
        }
        // Noise of every length.
        for length in [1, 2, 3, 17, 255, 1024, 8191, 8192, 8193, 65_536] {
            let noise = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            let result = answer(noise)
            #expect(result == .notFound || result == .needMore)
            if length >= 8192 { #expect(result == .notFound) }
        }
    }

    @Test func ph2_theTokenIsComparedInFullWhateverDiffers() {
        let secret = Array(Self.token.utf8)
        #expect(PhoneLinkText.constantTimeEquals(secret: secret, candidate: secret))
        for index in secret.indices {
            var other = secret
            other[index] ^= 0x01
            #expect(!PhoneLinkText.constantTimeEquals(secret: secret, candidate: other))
        }
        #expect(!PhoneLinkText.constantTimeEquals(secret: secret, candidate: []))
        #expect(!PhoneLinkText.constantTimeEquals(secret: secret, candidate: Array(secret.dropLast())))
        #expect(!PhoneLinkText.constantTimeEquals(secret: secret, candidate: secret + [0]))
        #expect(!PhoneLinkText.constantTimeEquals(secret: secret, candidate: secret + secret))
        #expect(!PhoneLinkText.constantTimeEquals(secret: [0, 0], candidate: [0]))
        #expect(!PhoneLinkText.constantTimeEquals(secret: [], candidate: [1]))
        #expect(PhoneLinkText.constantTimeEquals(secret: [], candidate: []))
    }

    @Test func ph2_theRefusalIsOneFixedAnswerWithNothingInIt() {
        let text = String(decoding: R.notFound, as: UTF8.self)
        #expect(text == "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    }

    // MARK: PH3 Ranges and headers

    @Test func ph3_aRangeFromAnOffsetToTheEndIsHonoured() {
        #expect(answer(Self.good(["Range: bytes=0-"])) == .serve(headOnly: false, rangeFrom: 0))
        #expect(answer(Self.good(["Range: bytes=1-"])) == .serve(headOnly: false, rangeFrom: 1))
        #expect(answer(Self.good(["range:   bytes=999-  "])) == .serve(headOnly: false, rangeFrom: 999))
        #expect(answer(Self.good("HEAD", ["Range: bytes=500-"])) == .serve(headOnly: true, rangeFrom: 500))
    }

    @Test func ph3_everyOtherFormOfRangeGetsTheWholeFile() {
        for range in [
            "bytes=0-99", "bytes=-100", "bytes=0-0,5-", "bytes=5-,10-", "bytes=1000-", "bytes=1001-", "bytes=-",
            "bytes=", "bytes=a-", "bytes=1 -", "bytes= 1-", "bytes=+1-", "bytes=-1-", "bytes=0x10-", "items=5-", "5-",
            "bytes=99999999999999999999999999-", "bytes=9223372036854775807-", "BYTES=5-", "bytes=5--", "bytes=١-", "",
        ] {
            #expect(answer(Self.good(["Range: \(range)"])) == .serve(headOnly: false, rangeFrom: nil), "\(range)")
        }
        // Two Range headers, or one that depends on a validator the server never gave.
        #expect(answer(Self.good(["Range: bytes=5-", "Range: bytes=6-"])) == .serve(headOnly: false, rangeFrom: nil))
        #expect(answer(Self.good(["Range: bytes=5-", "If-Range: \"etag\""])) == .serve(headOnly: false, rangeFrom: nil))
        // An empty file has no offset inside it.
        #expect(answer(Self.good(["Range: bytes=0-"]), Self.resource(size: 0)) == .serve(headOnly: false, rangeFrom: nil))
    }

    @Test func ph3_theHeadersOfAWholeFile() {
        let text = String(decoding: R.fileHeaders(fileName: "Dune.m4b", size: 1234, rangeFrom: nil), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
        let lines = Set(text.components(separatedBy: "\r\n").dropFirst().filter { !$0.isEmpty })
        #expect(lines == [
            "Content-Length: 1234", "Content-Type: application/octet-stream",
            "Content-Disposition: attachment; filename=\"Dune.m4b\"; filename*=UTF-8''Dune.m4b",
            "Accept-Ranges: bytes", "Cache-Control: no-store", "X-Content-Type-Options: nosniff", "Connection: close",
        ])
    }

    @Test func ph3_theHeadersOfAPart() {
        let text = String(decoding: R.fileHeaders(fileName: "Dune.m4b", size: 1234, rangeFrom: 234), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 206 Partial Content\r\n"))
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines.contains("Content-Range: bytes 234-1233/1234"))
        #expect(lines.contains("Content-Length: 1000"))
        #expect(lines.contains("Content-Type: application/octet-stream"))
    }

    @Test func ph3_aNameCannotBreakOutOfItsHeader() {
        for name in ["a\"b.m4b", "a\\b.m4b", "Dune – “Messiah”.m4b", "a;b=c.m4b", "x%0d%0aSet-Cookie: a=b.m4b", "名前.mp3"] {
            let value = R.contentDisposition(name)
            #expect(value.hasPrefix("attachment; filename=\""))
            #expect(value.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F }, "\(name)")
            // One quoted string, closed once, then the encoded name with nothing loose in it.
            let parts = value.components(separatedBy: "\"")
            #expect(parts.count == 3, "\(name)")
            #expect(!parts[1].contains("\\"))
            let encoded = value.components(separatedBy: "filename*=UTF-8''").last
            #expect(encoded?.removingPercentEncoding == name)
            #expect(encoded?.contains(where: { ";\" ,\\".contains($0) }) == false, "\(name)")
            let headers = String(decoding: R.fileHeaders(fileName: name, size: 1, rangeFrom: nil), as: UTF8.self)
            #expect(headers.components(separatedBy: "\r\n").count == 10)
        }
    }
}
