import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

// What Send to Phone asks of the system: keeping the Mac awake, and which network the
// Mac is on. Each is behind a protocol; tests give fakes.

// MARK: - Staying awake

/// PH25: keeps the Mac from going to sleep while a book is on its way to the phone.
public protocol SleepGuarding: AnyObject, Sendable {
    /// From now the Mac does not sleep for being idle. Asked again before `end`, it changes nothing.
    @MainActor func begin(reason: String)
    /// The Mac may sleep again. Safe to call when nothing was begun.
    @MainActor func end()
}

/// Asks the system not to sleep for being idle. The display may still sleep, and closing
/// the lid still puts the Mac to sleep. Releasing the guard ends what it began.
public final class SystemSleepGuard: SleepGuarding, @unchecked Sendable {
    private let lock = NSLock()
    private var activity: NSObjectProtocol?

    public init() {}

    deinit {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    @MainActor public func begin(reason: String) {
        lock.withLock {
            guard activity == nil else { return }
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: reason)
        }
    }

    @MainActor public func end() {
        let ended = lock.withLock { () -> NSObjectProtocol? in
            let ended = activity
            activity = nil
            return ended
        }
        if let ended { ProcessInfo.processInfo.endActivity(ended) }
    }
}

// MARK: - The network

/// PH27: what tells the network the Mac is on from another: its router's two addresses
/// (the one it is reached at, and the one built into it) and, where the system gives it
/// without asking the owner for anything, its Wi-Fi name.
///
/// The router's address alone says little: most routers of one make are at the same
/// one. Its hardware address is its own.
public struct NetworkIdentity: Equatable, Sendable {
    /// The default router's address, as "192.168.1.1".
    public var router: String
    /// The default router's hardware address, as "a4:5e:60:c1:02:9f".
    public var hardware: String
    /// The Wi-Fi network's name; nil when it is not Wi-Fi, or the name cannot be read.
    public var name: String?

    public init(router: String, hardware: String, name: String? = nil) {
        self.router = router
        self.hardware = hardware
        self.name = name
    }

    /// Whether this may be the network `other` is: the same router, by both of its
    /// addresses, and the same name wherever both have one. A name that could not be
    /// read rules nothing out.
    public func matches(_ other: NetworkIdentity) -> Bool {
        guard router == other.router, hardware == other.hardware else { return false }
        guard let name, let otherName = other.name else { return true }
        return name == otherName
    }

    /// As it is kept in the preferences: the router's two addresses with a tab between
    /// them, then a tab and the name when there is one.
    var stored: String {
        "\(router)\t\(hardware)" + (name.map { "\t\($0)" } ?? "")
    }

    /// Nil for anything that does not hold both of the router's addresses.
    init?(stored: String) {
        let parts = stored.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts[0].isEmpty, Self.isHardwareAddress(parts[1]) else { return nil }
        router = String(parts[0])
        hardware = String(parts[1])
        name = parts.count > 2 && !parts[2].isEmpty ? String(parts[2]) : nil
    }

    /// Whether `text` is six bytes in lower-case hexadecimal with colons between them.
    static func isHardwareAddress(_ text: some StringProtocol) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 17 else { return false }
        return bytes.enumerated().allSatisfy { index, byte in
            index % 3 == 2
                ? byte == UInt8(ascii: ":")
                : (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
        }
    }
}

/// The local network as Send to Phone needs to know it.
public protocol LocalNetworkReading: AnyObject, Sendable {
    /// This Mac's addresses that a phone on the same network can reach; empty when it has none.
    @MainActor func addresses() -> [String]
    /// The network the Mac is on; nil when that cannot be told.
    @MainActor func identity() -> NetworkIdentity?
}

/// Reads the network from the system. Nothing here asks the owner for a permission: the
/// router's hardware address is read from the system's own table of the neighbours it
/// has talked to, and the Wi-Fi name only if the system hands it over as things are.
public final class SystemLocalNetwork: LocalNetworkReading, Sendable {
    public init() {}

    @MainActor public func addresses() -> [String] {
        LocalAddress.current()
    }

    @MainActor public func identity() -> NetworkIdentity? {
        // The network is known by the router of the main connection: that says nothing
        // of a link offered on another interface's network.
        guard let route = DefaultRoute.current(),
              LocalAddress.offersOnMain(LocalAddress.systemInterfaces(), main: route.interface)
        else { return nil }
        let name = CWWiFiClient.shared().interface()?.ssid().flatMap { $0.isEmpty ? nil : $0 }
        let index = route.interface.map { Int(if_nametoindex($0)) }.flatMap { $0 > 0 ? $0 : nil }
        return Self.identity(router: route.router, interface: index, neighbours: NeighbourTable.system(), name: name)
    }

    /// The network whose router is at `router`, reached through the interface of that
    /// number: nil unless the table of neighbours gives that router exactly one
    /// hardware address there. A network that cannot be told from others is never one
    /// the owner has marked.
    static func identity(
        router: String, interface: Int?, neighbours: [NeighbourTable.Entry], name: String?
    ) -> NetworkIdentity? {
        let found = Set(
            neighbours.filter { $0.address == router && (interface == nil || $0.interface == interface) }
                .map(\.hardware))
        guard found.count == 1, let hardware = found.first else { return nil }
        return NetworkIdentity(router: router, hardware: hardware, name: name)
    }

}

/// The Mac's main network connection, as the system's own network settings state it.
enum DefaultRoute {
    /// The IPv4 router of the main connection, and the name of the interface it is
    /// reached through ("en0") when the system gives one. Nil when there is no router.
    static func current() -> (router: String, interface: String?)? {
        guard let store = SCDynamicStoreCreate(nil, "VoxCarrel" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let router = global["Router"] as? String, !router.isEmpty
        else { return nil }
        return (router, (global["PrimaryInterface"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// The system's table of the neighbours on the local network that it has talked to:
/// each one's address and the hardware address it answered from. Reading it asks the
/// owner for nothing and sends nothing.
enum NeighbourTable {
    struct Entry: Equatable, Sendable {
        /// As "192.168.1.1".
        var address: String
        /// As "a4:5e:60:c1:02:9f".
        var hardware: String
        /// The number of the interface the neighbour is on.
        var interface: Int
    }

    /// The length of what comes before the addresses in each of the table's messages.
    static let headerBytes = MemoryLayout<rt_msghdr>.size

    /// The table as it is now; empty when it cannot be read.
    static func system() -> [Entry] {
        var request: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var needed = 0
        guard sysctl(&request, u_int(request.count), nil, &needed, nil, 0) == 0, needed > 0, needed < 16_777_216
        else { return [] }
        // It may have grown since it was measured.
        var table = [UInt8](repeating: 0, count: needed + 4096)
        var size = table.count
        guard sysctl(&request, u_int(request.count), &table, &size, nil, 0) == 0, size <= table.count else {
            return []
        }
        return entries(in: Array(table[0..<size]))
    }

    /// The neighbours in a table as the system gives it: a run of messages, each a
    /// header and then the neighbour's address and its hardware address. A message that
    /// is cut short, or holds anything else, is left out; one whose length is wrong
    /// ends the reading.
    static func entries(in table: [UInt8]) -> [Entry] {
        var found: [Entry] = []
        var start = 0
        while start + headerBytes <= table.count {
            let length = Int(table[start]) | Int(table[start + 1]) << 8
            guard length >= headerBytes, start + length <= table.count else { break }
            if let entry = entry(Array(table[(start + headerBytes)..<(start + length)])) { found.append(entry) }
            start += length
        }
        return found
    }

    /// One neighbour, from the addresses of its message: an IPv4 address, then a
    /// link-level one of six bytes that are not all zero.
    private static func entry(_ addresses: [UInt8]) -> Entry? {
        guard addresses.count >= 8, Int32(addresses[1]) == AF_INET else { return nil }
        let address = addresses[4..<8].map(String.init).joined(separator: ".")
        // Each address is padded to a multiple of four bytes.
        let link = addresses[0] == 0 ? 4 : (Int(addresses[0]) + 3) & ~3
        guard link + 8 <= addresses.count, Int32(addresses[link + 1]) == AF_LINK else { return nil }
        let interface = Int(addresses[link + 2]) | Int(addresses[link + 3]) << 8
        let nameLength = Int(addresses[link + 5])
        let first = link + 8 + nameLength
        guard addresses[link + 6] == 6, first + 6 <= addresses.count else { return nil }
        let bytes = addresses[first..<(first + 6)]
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        let digits = Array("0123456789abcdef")
        let hardware = bytes.map { String([digits[Int($0 >> 4)], digits[Int($0 & 15)]]) }.joined(separator: ":")
        return Entry(address: address, hardware: hardware, interface: interface)
    }
}
