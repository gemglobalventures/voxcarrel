import Darwin
import Foundation
import os
import Testing
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// A `PhoneLinking` that listens to nothing: a test says what happened to the link, with `fire`.
@MainActor
final class FakePhoneLinking: PhoneLinking {
    struct Start: Equatable {
        var file: URL
        var fileName: String
        var now: Date
    }

    /// Every call of `start` that got as far as making a link.
    private(set) var starts: [Start] = []
    private(set) var stopCount = 0
    /// The offer of the link now being served; nil when none is.
    private(set) var offer: PhoneLinkOffer?
    /// Set to make `start` throw it.
    var startError: Error?
    var address = "192.168.1.20"
    var port = 50123
    private var tokenCount = 0
    private var onEvent: (@MainActor (PhoneLinkEvent) -> Void)?

    var isServing: Bool { onEvent != nil }

    func start(
        file: URL, fileName: String, now: Date, onEvent: @escaping @MainActor (PhoneLinkEvent) -> Void
    ) throws -> PhoneLinkOffer {
        self.onEvent = nil
        offer = nil
        if let startError { throw startError }
        tokenCount += 1
        let token = "fake_token-\(tokenCount)"
        guard let offer = PhoneLinkText.offer(
            file: file, fileName: fileName, token: token, address: address, port: port, now: now)
        else { throw PhoneLinkError.badFileName }
        starts.append(Start(file: file, fileName: fileName, now: now))
        self.offer = offer
        self.onEvent = onEvent
        return offer
    }

    func stop() {
        stopCount += 1
        onEvent = nil
        offer = nil
    }

    /// Reports an event, as the server would. One that ends the link ends it here too.
    /// Does nothing when no link is being served.
    func fire(_ event: PhoneLinkEvent) {
        guard let onEvent else { return }
        if event.endsLink {
            self.onEvent = nil
            offer = nil
        }
        onEvent(event)
    }
}

/// The actions a server asked to have run later; a test runs them when it likes.
@MainActor
final class LinkTimers {
    private(set) var delays: [TimeInterval] = []
    private var actions: [@MainActor @Sendable () -> Void] = []

    nonisolated init() {}

    var schedule: PhoneLinkServer.Scheduler {
        { [weak self] seconds, action in
            self?.delays.append(seconds)
            self?.actions.append(action)
        }
    }

    /// Runs the action scheduled `index`-th, as if its time had come.
    func fire(_ index: Int) {
        actions[index]()
    }
}

/// The time of day a server is told it is; a test moves it on by hand.
final class LinkClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSinceReferenceDate: 800_000_000)

    var now: Date { lock.withLock { date } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(seconds) }
    }
}

/// The addresses a server is told this Mac has; a test changes them by hand.
final class LinkAddresses: @unchecked Sendable {
    private let lock = NSLock()
    private var addresses = ["127.0.0.1"]

    var all: [String] { lock.withLock { addresses } }

    func set(_ new: [String]) {
        lock.withLock { addresses = new }
    }
}

/// Watches nothing: a test says when the Mac's network connections changed.
final class LinkPaths: @unchecked Sendable {
    private final class Watch: PathWatch, @unchecked Sendable {
        let onCancel: @Sendable () -> Void
        init(onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }
        func cancel() { onCancel() }
    }

    private let lock = NSLock()
    private var actions: [Int: @Sendable () -> Void] = [:]
    private var started = 0
    private var ended = 0

    /// How many watches have been started, and how many of them cancelled.
    var startCount: Int { lock.withLock { started } }
    var cancelCount: Int { lock.withLock { ended } }

    var watcher: PathWatcher {
        { [self] action in
            let id = lock.withLock { () -> Int in
                started += 1
                actions[started] = action
                return started
            }
            return Watch { [self] in
                lock.withLock {
                    if actions.removeValue(forKey: id) != nil { ended += 1 }
                }
            }
        }
    }

    /// The connections changed: every watch that has not been cancelled is told.
    func change() {
        let now = lock.withLock { Array(actions.values) }
        now.forEach { $0() }
    }
}

/// What a server reported, with a way to wait for a report.
@MainActor
final class LinkEvents {
    private(set) var all: [PhoneLinkEvent] = []

    nonisolated init() {}

    func note(_ event: PhoneLinkEvent) {
        all.append(event)
    }

    /// Returns true once an event satisfying `wanted` has come, or false after 30 seconds.
    func wait(for wanted: (PhoneLinkEvent) -> Bool) async -> Bool {
        for _ in 0..<3000 {
            if all.contains(where: wanted) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return all.contains(where: wanted)
    }

    func wait(for event: PhoneLinkEvent) async -> Bool {
        await wait { $0 == event }
    }

    /// Lets everything already on its way to the main actor arrive.
    func settle() async {
        for _ in 0..<5 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// A plain TCP connection to the loopback address, made with the system calls themselves
/// so that a test can send anything at all. Every wait has a limit of 30 seconds.
final class RawConnection: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var isClosed = false
    private static let work = DispatchQueue(label: "RawConnection", attributes: .concurrent)
    private static let failure = OSAllocatedUnfairLock(initialState: Int32(0))
    private static let silent = OSAllocatedUnfairLock(initialState: Set<Int>())
    /// The ports on which a read gave up after 30 seconds of nothing: the other side
    /// neither sent nor closed. No test expects that.
    static var portsThatSaidNothing: Set<Int> { silent.withLock { $0 } }
    private static let silences = OSAllocatedUnfairLock(initialState: [Int: [String]]())
    /// For each such port, what each read that gave up had been asked for and had got:
    /// said when a test fails for it, so that the read at fault can be told.
    static func silences(on port: Int) -> [String] { silences.withLock { $0[port] ?? [] } }
    private let port: Int

    /// Why the last connection that could not be made could not be: an `errno` value.
    static var lastFailure: Int32 { failure.withLock { $0 } }

    /// Connects to `127.0.0.1` (or `::1`) on this port; nil when nothing accepts there.
    /// - Parameter first: Bytes to send the moment the connection is made, with nothing
    ///   in between that could be held up: for tests of how long a caller may take.
    init?(port: Int, ipv6: Bool = false, sending first: [UInt8] = []) {
        self.port = port
        let made = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard made >= 0 else {
            Self.failure.withLock { $0 = errno }
            return nil
        }
        var on: Int32 = 1
        setsockopt(made, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(made, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(made, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        let result: Int32
        if ipv6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(port).bigEndian
            address.sin6_addr = in6addr_loopback
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(made, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(made, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard result == 0 else {
            Self.failure.withLock { $0 = errno }
            Darwin.close(made)
            return nil
        }
        if !first.isEmpty {
            let wrote = first.withUnsafeBytes { Darwin.send(made, $0.baseAddress!, first.count, 0) }
            guard wrote == first.count else {
                Self.failure.withLock { $0 = errno }
                Darwin.close(made)
                return nil
            }
        }
        descriptor = made
    }

    deinit {
        close()
    }

    private func onWorkQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Self.work.async { continuation.resume(returning: body()) }
        }
    }

    /// Sends all of `bytes`; false when the connection would not take them.
    @discardableResult
    func send(_ bytes: [UInt8]) async -> Bool {
        let descriptor = descriptor
        return await onWorkQueue { Self.send(bytes, on: descriptor) }
    }

    private static func send(_ bytes: [UInt8], on descriptor: Int32) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let wrote = bytes.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress! + sent, bytes.count - sent, 0) }
            if wrote < 0, errno == EINTR { continue }
            guard wrote > 0 else { return false }
            sent += wrote
        }
        return true
    }

    /// Sends `text` and reads until the other side closes, and says how long the two
    /// took together. Both are done on one thread of their own, so that the time is the
    /// other side's: none of it is spent waiting for the test's actor, which a busy
    /// suite can keep for many seconds.
    func exchange(_ text: String) async -> (bytes: [UInt8], seconds: Double) {
        let descriptor = descriptor
        let port = port
        return await onWorkQueue {
            let clock = ContinuousClock()
            let began = clock.now
            _ = Self.send(Array(text.utf8), on: descriptor)
            let bytes = Self.read(upTo: .max, on: descriptor, port: port).bytes
            let took = clock.now - began
            return (bytes, Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18)
        }
    }

    @discardableResult
    func send(_ text: String) async -> Bool {
        await send(Array(text.utf8))
    }

    /// Reads exactly `count` bytes, or fewer when the other side closes, fails or says
    /// nothing for 30 seconds.
    func read(_ count: Int) async -> [UInt8] {
        await read(upTo: count).bytes
    }

    /// Reads until the other side closes: `closedCleanly` is false when the connection
    /// was cut instead, or nothing came for 30 seconds.
    func readToEnd() async -> (bytes: [UInt8], closedCleanly: Bool) {
        await read(upTo: .max)
    }

    private func read(upTo count: Int) async -> (bytes: [UInt8], closedCleanly: Bool) {
        let descriptor = descriptor
        let port = port
        return await onWorkQueue { Self.read(upTo: count, on: descriptor, port: port) }
    }

    private static func read(upTo count: Int, on descriptor: Int32, port: Int) -> (bytes: [UInt8], closedCleanly: Bool) {
        var all: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65536)
        while all.count < count {
            let want = min(buffer.count, count - all.count)
            let got = recv(descriptor, &buffer, want, 0)
            if got < 0, errno == EINTR { continue }
            if got == 0 { return (all, true) }
            guard got > 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    _ = silent.withLock { $0.insert(port) }
                    let asked = count == .max ? "to the end" : "\(count) bytes"
                    silences.withLock { $0[port, default: []].append("asked for \(asked), had \(all.count), on socket \(descriptor)") }
                }
                return (all, false)
            }
            all.append(contentsOf: buffer[0..<got])
        }
        return (all, true)
    }

    /// Says that nothing more will be sent, and goes on reading.
    func finishSending() {
        shutdown(descriptor, SHUT_WR)
    }

    func close() {
        let wasClosed = lock.withLock { () -> Bool in
            let was = isClosed
            isClosed = true
            return was
        }
        if !wasClosed { Darwin.close(descriptor) }
    }

    /// Cuts the connection without a goodbye, as a phone going out of range does.
    func abort() {
        var hard = linger(l_onoff: 1, l_linger: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_LINGER, &hard, socklen_t(MemoryLayout<linger>.size))
        close()
    }
}

/// One answer read off a raw connection, split into its parts.
struct RawAnswer {
    var statusLine: String
    var headers: [String: String]
    var body: [UInt8]
    var closedCleanly: Bool
    var raw: [UInt8]

    init(_ bytes: [UInt8], closedCleanly: Bool) {
        raw = bytes
        self.closedCleanly = closedCleanly
        let separator: [UInt8] = [13, 10, 13, 10]
        var split = bytes.count
        if bytes.count >= 4 {
            for index in 0...(bytes.count - 4) where Array(bytes[index..<(index + 4)]) == separator {
                split = index
                break
            }
        }
        let lines = String(decoding: bytes[0..<split], as: UTF8.self).components(separatedBy: "\r\n")
        statusLine = lines.first ?? ""
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers
        body = split + 4 <= bytes.count ? Array(bytes[(split + 4)...]) : []
    }

    /// Whether this is the one refusal, to the byte, with the connection then closed.
    var isTheRefusal: Bool {
        raw == PhoneLinkRequest.notFound && closedCleanly
    }
}

enum LinkProbe {
    /// Sends `bytes` on a new connection, says nothing more, and reads the whole answer.
    static func exchange(_ bytes: [UInt8], port: Int, finish: Bool = true) async throws -> RawAnswer {
        let made = RawConnection(port: port)
        let connection = try #require(made, "nothing accepts on port \(port): error \(RawConnection.lastFailure)")
        await connection.send(bytes)
        if finish { connection.finishSending() }
        let (all, clean) = await connection.readToEnd()
        connection.close()
        return RawAnswer(all, closedCleanly: clean)
    }

    static func exchange(_ text: String, port: Int, finish: Bool = true) async throws -> RawAnswer {
        try await exchange(Array(text.utf8), port: port, finish: finish)
    }

    /// True once nothing accepts connections on the port, on either loopback address;
    /// false if something still does after 10 seconds.
    static func portIsClosed(_ port: Int) async -> Bool {
        for _ in 0..<500 {
            let v4 = RawConnection(port: port)
            let v6 = RawConnection(port: port, ipv6: true)
            v4?.close()
            v6?.close()
            if v4 == nil, v6 == nil { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// Bytes that differ from place to place, so that a part of them from the wrong
    /// offset is never taken for the right one.
    static func contents(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var state: UInt32 = 0x2545_F491
        var index = 0
        while index < count {
            state = state &* 1_664_525 &+ 1_013_904_223
            bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
            index += 1
        }
        return bytes
    }
}
