import Foundation
import Testing

@testable import VoxCarrelAppCore

/// The parts of the link that need no connection: the secret, the addresses, and which
/// of the Mac's addresses is offered.
@Suite struct PhoneLinkTextTests {
    // MARK: PH1 The token

    @Test func ph1_theTokenIs32RandomBytesAsURLSafeBase64WithoutPadding() throws {
        var seen = Set<String>()
        for _ in 0..<200 {
            let token = try #require(PhoneLinkText.makeToken())
            #expect(token.count == 43)
            #expect(token.utf8.allSatisfy { PhoneLinkText.isUnreserved($0) && $0 != UInt8(ascii: ".") && $0 != UInt8(ascii: "~") })
            let standard = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
            #expect(Data(base64Encoded: standard)?.count == 32)
            seen.insert(token)
        }
        #expect(seen.count == 200)
    }

    @Test func ph1_theEncodingUsesTheURLSafeAlphabet() {
        #expect(PhoneLinkText.urlSafeBase64([0xFB, 0xFF, 0xFE]) == "-__-")
        #expect(PhoneLinkText.urlSafeBase64([0xFF]) == "_w")
        #expect(PhoneLinkText.urlSafeBase64([UInt8](repeating: 0, count: 32)) == String(repeating: "A", count: 43))
    }

    // MARK: PH8 The address

    func interface(
        _ name: String, _ address: String, up: Bool = true, loopback: Bool = false, tunnel: Bool = false, wired: Bool = true
    ) -> NetworkInterface {
        NetworkInterface(
            name: name, address: address, isUp: up, isLoopback: loopback, isPointToPoint: tunnel, isEthernetOrWiFi: wired)
    }

    @Test func ph8_privateIPv4AddressesAreCandidates() {
        let all = [
            interface("en0", "192.168.1.20"), interface("en1", "10.0.0.5"), interface("en2", "172.16.0.1"),
            interface("en3", "172.31.255.254"), interface("en4", "10.255.255.255"), interface("en5", "192.168.0.0"),
        ]
        #expect(LocalAddress.candidates(from: all) == all.map(\.address))
    }

    @Test func ph8_everythingElseIsLeftOut() {
        let all = [
            // Public, link-local, loopback, and just outside the private ranges.
            interface("en0", "8.8.8.8"), interface("en0", "169.254.10.20"), interface("lo0", "127.0.0.1", loopback: true),
            interface("en0", "172.15.0.1"), interface("en0", "172.32.0.1"), interface("en0", "192.169.1.1"),
            interface("en0", "11.0.0.1"), interface("en0", "100.64.0.1"), interface("en0", "192.167.1.1"),
            // IPv6, of every kind.
            interface("en0", "fe80::1%en0"), interface("en0", "fd00::1"), interface("en0", "2001:db8::1"),
            interface("lo0", "::1", loopback: true), interface("en0", "::ffff:192.168.1.20"),
            // Not up; loopback even with a private address; a tunnel, which is what a VPN is.
            interface("en0", "192.168.1.30", up: false), interface("lo0", "10.0.0.1", loopback: true),
            interface("utun3", "10.8.0.2", tunnel: true, wired: false), interface("ppp0", "192.168.50.2", tunnel: true),
            // Not an address written plainly.
            interface("en0", ""), interface("en0", "192.168.1"), interface("en0", "192.168.1.20.5"),
            interface("en0", "192.168.1.256"), interface("en0", "192.168.01.20"), interface("en0", "192.168.1.20 "),
            interface("en0", "192.168.1.-2"), interface("en0", "192.168.1.2/24"), interface("en0", "0xC0.168.1.1"),
            interface("en0", "192.168.1.٢"), interface("en0", "192.168..1"), interface("en0", "10.0.0.1:80"),
        ]
        #expect(LocalAddress.candidates(from: all) == [])
        #expect(LocalAddress.candidates(from: []) == [])
    }

    @Test func ph8_ethernetAndWiFiComeFirstAndEachAddressOnce() {
        let all = [
            interface("bridge100", "192.168.64.1", wired: false), interface("en0", "192.168.1.20"),
            interface("vmnet1", "172.16.5.1", wired: false), interface("en5", "10.0.0.7"),
            interface("en0", "192.168.1.20"), interface("bridge100", "192.168.64.1", wired: false),
        ]
        #expect(LocalAddress.candidates(from: all) == ["192.168.1.20", "10.0.0.7", "192.168.64.1", "172.16.5.1"])
    }

    @Test func ph8_theSystemsInterfacesCanBeListed() {
        let interfaces = LocalAddress.systemInterfaces()
        // Every Mac has a loopback interface, and it is never a candidate.
        let loopback = interfaces.filter { $0.address == "127.0.0.1" }
        #expect(loopback.count == 1)
        #expect(loopback.first?.isLoopback == true)
        #expect(loopback.first?.isEthernetOrWiFi == false)
        let current = LocalAddress.current()
        #expect(current == LocalAddress.candidates(from: interfaces))
        #expect(!current.contains("127.0.0.1"))
        for address in current {
            let parts = LocalAddress.ipv4Parts(address)
            #expect(parts.map(LocalAddress.isPrivate) == true)
        }
    }

    // MARK: PH9 The link

    /// What BookPlayer makes of a link: everything after "url=", percent-decoded once.
    func asBookPlayerReadsIt(_ link: URL) throws -> String {
        let text = link.absoluteString
        let range = try #require(text.range(of: "url="))
        return try #require(String(text[range.upperBound...]).removingPercentEncoding)
    }

    static let awkwardNames = [
        "Dune.m4b", "Dune Messiah.m4b", "Dune – “Messiah” (Unabridged).zip", "Tom & Jerry.mp3", "Chapter #1.mp3",
        "Who? What?.m4b", "say \"hello\".m4b", "it's 100% true.m4b", "a+b=c.m4b", "名前のない本.m4b",
        "Caf\u{00E9} cr\u{0065}\u{0301}me.m4b", "x;y,z@home:8080.m4b", "url=http%3A%2F%2Fevil.example.m4b",
        "a\\b.m4b", "%2F%2e%2e%00.m4b", "emoji 🎧.m4b", "[brackets] {braces} <angles> |pipe| ^caret^ `tick`.m4b",
    ]

    @Test(arguments: awkwardNames)
    func ph9_theWholeAddressSurvivesAsTheValueOfUrl(name: String) throws {
        let token = try #require(PhoneLinkText.makeToken())
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let file = URL(fileURLWithPath: "/tmp/somewhere/\(name)")
        let offer = try #require(PhoneLinkText.offer(
            file: file, fileName: name, token: token, address: "192.168.1.20", port: 50123, now: now))

        #expect(offer.file == file)
        #expect(offer.fileName == name)
        #expect(offer.token == token)
        #expect(offer.address == "192.168.1.20")
        #expect(offer.port == 50123)
        #expect(offer.expiresAt == now.addingTimeInterval(600))

        // The http address: this host, this port, and a path of exactly the token and the name.
        let http = offer.httpURL
        #expect(http.scheme == "http")
        #expect(http.host == "192.168.1.20")
        #expect(http.port == 50123)
        #expect(http.query == nil)
        #expect(http.fragment == nil)
        #expect(http.user == nil)
        let text = http.absoluteString
        #expect(text.hasPrefix("http://192.168.1.20:50123/\(token)/"))
        let encodedName = String(text.dropFirst("http://192.168.1.20:50123/\(token)/".count))
        #expect(!encodedName.contains("/"))
        #expect(encodedName.removingPercentEncoding == name)
        #expect(encodedName.utf8.allSatisfy { PhoneLinkText.isUnreserved($0) || $0 == UInt8(ascii: "%") })
        // The server, given what a client sends for that address, finds the file.
        let resource = PhoneLinkResource(token: token, fileName: name, size: 10, authority: "192.168.1.20:50123")
        let request = "GET /\(token)/\(encodedName) HTTP/1.1\r\nHost: 192.168.1.20:50123\r\n\r\n"
        #expect(PhoneLinkRequest.answer(Array(request.utf8), for: resource) == .serve(headOnly: false, rangeFrom: nil))

        // The link: BookPlayer's scheme and command, and the address whole as the one value.
        let link = offer.bookPlayerLink
        #expect(link.scheme == "bookplayer")
        #expect(link.host == "download")
        #expect(link.absoluteString.hasPrefix("bookplayer://download?url=http%3A%2F%2F192.168.1.20%3A50123%2F"))
        let value = String(link.absoluteString.dropFirst("bookplayer://download?url=".count))
        #expect(value.utf8.allSatisfy { PhoneLinkText.isUnreserved($0) || $0 == UInt8(ascii: "%") })
        // Read the way BookPlayer reads it, it is the http address again, to the letter.
        let read = try asBookPlayerReadsIt(link)
        #expect(read == text)
        #expect(!read.contains("\""))
        #expect(URL(string: read) == http)
        // Read as an ordinary query, it is one item and the same address.
        let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items == [URLQueryItem(name: "url", value: text)])
    }

    @Test func ph9_aNameThatCannotGoInALinkIsNotUsable() {
        for name in ["", ".", "..", "a/b.m4b", "/etc/passwd", "a\u{0000}b", "a\nb", "a\r\nb", "a\tb", "a\u{007F}b",
                     String(repeating: "x", count: 256), String(repeating: "é", count: 128)] {
            #expect(!PhoneLinkText.isUsableFileName(name), "\(name.prefix(12))")
        }
        for name in ["a", "...", ".hidden", "a b", String(repeating: "x", count: 255), String(repeating: "é", count: 127)] {
            #expect(PhoneLinkText.isUsableFileName(name), "\(name.prefix(12))")
        }
    }

    @Test func ph9_theLongestNameStillFitsInARequest() throws {
        let name = String(repeating: "é", count: 127)
        let token = try #require(PhoneLinkText.makeToken())
        let offer = try #require(PhoneLinkText.offer(
            file: URL(fileURLWithPath: "/tmp/x"), fileName: name, token: token, address: "192.168.100.200", port: 65535,
            now: Date()))
        let path = offer.httpURL.absoluteString.dropFirst("http://192.168.100.200:65535".count)
        #expect(path.utf8.count < 1024)
        #expect(PhoneLinkRequest.maxHeadBytes >= 8 * path.utf8.count)
    }

    @Test func ph2_errorsAndEventsNeverCarryTheToken() {
        for error in [PhoneLinkError.noLocalAddress, .badFileName, .fileUnreadable, .cannotListen] {
            let text = error.localizedDescription
            #expect(!text.isEmpty)
            #expect(!text.contains("Error"))
        }
        #expect(PhoneLinkEvent.finished.endsLink && PhoneLinkEvent.expired.endsLink && PhoneLinkEvent.failed("x").endsLink)
        #expect(!PhoneLinkEvent.started(bytesTotal: 1).endsLink && !PhoneLinkEvent.progress(bytesSent: 1).endsLink)
        #expect(!PhoneLinkEvent.interrupted.endsLink)
    }
}
