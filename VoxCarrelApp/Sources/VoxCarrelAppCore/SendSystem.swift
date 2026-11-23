import CoreWLAN
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

/// PH27: what tells the network the Mac is on from another: its router's address and,
/// where the system gives it without asking the owner for anything, its Wi-Fi name.
public struct NetworkIdentity: Equatable, Sendable {
    /// The default router's address, as "192.168.1.1".
    public var router: String
    /// The Wi-Fi network's name; nil when it is not Wi-Fi, or the name cannot be read.
    public var name: String?

    public init(router: String, name: String? = nil) {
        self.router = router
        self.name = name
    }

    /// Whether this may be the network `other` is: the same router, and the same name
    /// wherever both have one. A name that could not be read rules nothing out.
    public func matches(_ other: NetworkIdentity) -> Bool {
        guard router == other.router else { return false }
        guard let name, let otherName = other.name else { return true }
        return name == otherName
    }

    /// As it is kept in the preferences: the router, then a tab and the name when there is one.
    var stored: String {
        name.map { "\(router)\t\($0)" } ?? router
    }

    init?(stored: String) {
        let parts = stored.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard let router = parts.first, !router.isEmpty else { return nil }
        self.router = String(router)
        name = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
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
/// Wi-Fi name is read only if the system hands it over as things are, and is otherwise
/// left out.
public final class SystemLocalNetwork: LocalNetworkReading, Sendable {
    public init() {}

    @MainActor public func addresses() -> [String] {
        LocalAddress.current()
    }

    @MainActor public func identity() -> NetworkIdentity? {
        guard let router = Self.defaultRouter() else { return nil }
        let name = CWWiFiClient.shared().interface()?.ssid().flatMap { $0.isEmpty ? nil : $0 }
        return NetworkIdentity(router: router, name: name)
    }

    /// The IPv4 router of the Mac's main network connection, as the system's own
    /// network settings state it.
    private static func defaultRouter() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "VoxCarrel" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let router = global["Router"] as? String, !router.isEmpty
        else { return nil }
        return router
    }
}
