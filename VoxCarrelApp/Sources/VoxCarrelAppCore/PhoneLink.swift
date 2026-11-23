import Darwin
import Foundation
import Security

/// A link the phone can fetch one file from, while it lasts.
public struct PhoneLinkOffer: Equatable, Sendable {
    /// What will be served.
    public var file: URL
    /// The name in the address.
    public var fileName: String
    /// The secret in the address: whoever has it can fetch the file.
    public var token: String
    /// This Mac's address on the local network, as "192.168.1.20".
    public var address: String
    public var port: Int
    public var expiresAt: Date
    /// `http://address:port/token/fileName`.
    public var httpURL: URL
    /// `bookplayer://download?url=` followed by the whole of `httpURL`, percent-encoded.
    public var bookPlayerLink: URL

    public init(
        file: URL, fileName: String, token: String, address: String, port: Int, expiresAt: Date, httpURL: URL,
        bookPlayerLink: URL
    ) {
        self.file = file
        self.fileName = fileName
        self.token = token
        self.address = address
        self.port = port
        self.expiresAt = expiresAt
        self.httpURL = httpURL
        self.bookPlayerLink = bookPlayerLink
    }
}

/// What happens to a link after it is started.
public enum PhoneLinkEvent: Equatable, Sendable {
    /// A fetch of the file has begun; the file's size.
    case started(bytesTotal: Int64)
    /// How far into the file the fetch has got.
    case progress(bytesSent: Int64)
    /// A fetch ended without the whole file having been fetched, and none is under way.
    /// The link is still there: the phone can try again until it expires.
    case interrupted
    /// The whole file has been fetched. The link is gone.
    case finished
    /// The link's time ran out. The link is gone.
    case expired
    /// The link stopped working; a plain sentence saying so. The link is gone.
    case failed(String)

    /// Whether the link is gone once this has been reported.
    public var endsLink: Bool {
        switch self {
        case .finished, .expired, .failed: true
        case .started, .progress, .interrupted: false
        }
    }
}

/// Why a link could not be started.
public enum PhoneLinkError: Error, Equatable, LocalizedError {
    /// This Mac has no address on a local network.
    case noLocalAddress
    /// The name the file is to go under cannot be put in an address.
    case badFileName
    /// The file is not there, cannot be read, or is not a plain file.
    case fileUnreadable
    /// Nothing could be set up to listen for the phone.
    case cannotListen

    public var errorDescription: String? {
        switch self {
        case .noLocalAddress: "This Mac has no address on a local network."
        case .badFileName: "The file's name cannot be used in a link."
        case .fileUnreadable: "The file to send could not be opened."
        case .cannotListen: "This Mac could not start listening for the phone."
        }
    }
}

/// Offers one file to the phone over the local network. The app's own implementation
/// listens for real; tests use one whose events they fire by hand.
public protocol PhoneLinking: AnyObject, Sendable {
    /// Starts offering `file` under `fileName`, for ten minutes from `now` or until it
    /// has been fetched whole once. A link already being offered is stopped first.
    /// `onEvent` is called on the main actor, and never after `stop()`.
    @MainActor func start(
        file: URL, fileName: String, now: Date, onEvent: @escaping @MainActor (PhoneLinkEvent) -> Void
    ) throws -> PhoneLinkOffer
    /// Ends the link at once, with any fetch under way. Safe to call repeatedly.
    @MainActor func stop()
    /// True from `start` until `stop` or an event that ends the link.
    @MainActor var isServing: Bool { get }
}

// MARK: - The link's text

/// The secret, the addresses and the comparisons of a link.
public enum PhoneLinkText {
    /// How long a link lasts.
    public static let lifetime: TimeInterval = 600

    /// A new secret: 32 bytes from the system's secure generator, as URL-safe base64
    /// without padding (43 characters). Nil when the generator fails.
    static func makeToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return urlSafeBase64(bytes)
    }

    static func urlSafeBase64(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Whether two byte strings are the same, in a time that depends only on the length
    /// of `secret`: never on where, or whether, `candidate` differs from it.
    static func constantTimeEquals(secret: [UInt8], candidate: [UInt8]) -> Bool {
        var difference = UInt8(secret.count == candidate.count ? 0 : 1)
        for index in secret.indices {
            // Past its end, the candidate is compared as if it went on with zeros; the
            // lengths have already been told apart above.
            let other = index < candidate.count ? candidate[index] : 0
            difference |= secret[index] ^ other
        }
        return difference == 0
    }

    /// Whether a file can be offered under this name: one path component, of no more
    /// than 255 bytes, with no control character in it.
    static func isUsableFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255 else { return false }
        return !name.unicodeScalars.contains { $0 == "/" || $0.value < 0x20 || $0.value == 0x7F }
    }

    /// Every byte but the letters, digits and `-._~` as `%XX`: what is left has one
    /// meaning wherever in an address it stands.
    static func percentEncoded(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            if isUnreserved(byte) {
                out.unicodeScalars.append(UnicodeScalar(byte))
            } else {
                out += "%" + hex(byte >> 4) + hex(byte & 0x0F)
            }
        }
        return out
    }

    static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
            true
        default: false
        }
    }

    private static func hex(_ nibble: UInt8) -> String {
        String(UnicodeScalar(nibble < 10 ? UInt8(ascii: "0") + nibble : UInt8(ascii: "A") + nibble - 10))
    }

    /// The address the file is fetched from: `http://address:port/token/fileName`.
    static func httpURL(address: String, port: Int, token: String, fileName: String) -> URL? {
        URL(string: "http://\(address):\(port)/\(percentEncoded(token))/\(percentEncoded(fileName))")
    }

    /// The link that makes BookPlayer fetch `httpURL`: the whole address is the value of
    /// `url`, percent-encoded, so that nothing in it is taken for a part of this link.
    static func bookPlayerLink(for httpURL: URL) -> URL? {
        URL(string: "bookplayer://download?url=" + percentEncoded(httpURL.absoluteString))
    }

    /// The offer for a link that is listening.
    static func offer(
        file: URL, fileName: String, token: String, address: String, port: Int, now: Date
    ) -> PhoneLinkOffer? {
        guard let http = httpURL(address: address, port: port, token: token, fileName: fileName),
              let link = bookPlayerLink(for: http)
        else { return nil }
        return PhoneLinkOffer(
            file: file, fileName: fileName, token: token, address: address, port: port,
            expiresAt: now.addingTimeInterval(lifetime), httpURL: http, bookPlayerLink: link)
    }
}

// MARK: - This Mac's address

/// One address of one of this Mac's network interfaces.
public struct NetworkInterface: Equatable, Sendable {
    /// The interface's name, as "en0".
    public var name: String
    /// The address as text: "192.168.1.20", or an IPv6 address.
    public var address: String
    public var isUp: Bool
    public var isLoopback: Bool
    /// True for a tunnel, which is what a VPN is.
    public var isPointToPoint: Bool
    /// True for an Ethernet or Wi-Fi interface.
    public var isEthernetOrWiFi: Bool

    public init(
        name: String, address: String, isUp: Bool, isLoopback: Bool, isPointToPoint: Bool, isEthernetOrWiFi: Bool
    ) {
        self.name = name
        self.address = address
        self.isUp = isUp
        self.isLoopback = isLoopback
        self.isPointToPoint = isPointToPoint
        self.isEthernetOrWiFi = isEthernetOrWiFi
    }
}

/// Which of this Mac's addresses a phone on the same network can reach.
public enum LocalAddress {
    /// The private IPv4 addresses (10/8, 172.16/12, 192.168/16) of interfaces that are
    /// up and are neither loopback nor point-to-point, those of Ethernet and Wi-Fi
    /// first; otherwise in the order given, each once.
    public static func candidates(from interfaces: [NetworkInterface]) -> [String] {
        let usable = interfaces.filter { interface in
            guard interface.isUp, !interface.isLoopback, !interface.isPointToPoint,
                  let parts = ipv4Parts(interface.address)
            else { return false }
            return isPrivate(parts)
        }
        var seen = Set<String>()
        return (usable.filter(\.isEthernetOrWiFi) + usable.filter { !$0.isEthernetOrWiFi })
            .map(\.address).filter { seen.insert($0).inserted }
    }

    /// The candidates among this Mac's interfaces as they are now.
    public static func current() -> [String] {
        candidates(from: systemInterfaces())
    }

    /// The four numbers of a dotted IPv4 address written plainly ("192.168.1.20"); nil
    /// for anything else.
    static func ipv4Parts(_ address: String) -> [UInt8]? {
        let fields = address.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4 else { return nil }
        var parts: [UInt8] = []
        for field in fields {
            guard !field.isEmpty, field.count <= 3, field.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  field.count == 1 || field.first != "0", let value = UInt8(field)
            else { return nil }
            parts.append(value)
        }
        return parts
    }

    static func isPrivate(_ parts: [UInt8]) -> Bool {
        switch (parts[0], parts[1]) {
        case (10, _), (192, 168): true
        case (172, 16...31): true
        default: false
        }
    }

    /// Every IPv4 and IPv6 address of every interface, as the system lists them.
    static func systemInterfaces() -> [NetworkInterface] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }

        // The link-level entry of each interface says what kind it is.
        var ethernet = Set<String>()
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, Int32(address.pointee.sa_family) == AF_LINK,
                  let data = entry.pointee.ifa_data
            else { continue }
            if data.assumingMemoryBound(to: if_data.self).pointee.ifi_type == UInt8(IFT_ETHER) {
                ethernet.insert(String(cString: entry.pointee.ifa_name))
            }
        }

        var found: [NetworkInterface] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(address.pointee.sa_len)
            guard getnameinfo(address, length, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            let name = String(cString: entry.pointee.ifa_name)
            let flags = Int32(entry.pointee.ifa_flags)
            found.append(NetworkInterface(
                name: name, address: String(cString: text),
                isUp: flags & IFF_UP != 0 && flags & IFF_RUNNING != 0,
                isLoopback: flags & IFF_LOOPBACK != 0,
                isPointToPoint: flags & IFF_POINTOPOINT != 0,
                isEthernetOrWiFi: ethernet.contains(name)))
        }
        return found
    }
}
