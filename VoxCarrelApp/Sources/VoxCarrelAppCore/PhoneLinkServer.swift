import Darwin
import Foundation
import Network

/// Serves one file, once, to a caller on the local network who has the link's secret,
/// and nothing to anyone else.
///
/// It listens on one local address only, on a port the system picks. The file is opened
/// once, when the link starts, and read from there a piece at a time. Every connection
/// carries at most one request and is then closed. The link ends when the whole file
/// has been fetched, when its time runs out, on `stop()`, or when the server is released;
/// nothing listens afterwards.
public final class PhoneLinkServer: PhoneLinking, @unchecked Sendable {
    /// The server's limits. Tests shorten the waits.
    struct Settings: Sendable {
        /// How long a caller has to send its request; one that sends nothing is dropped then.
        var requestTimeout: TimeInterval = 10
        /// How long a refused caller is listened to (and ignored) so that it can read the refusal.
        var lingerTimeout: TimeInterval = 2
        /// How long the connection has to take the goodbye once the last byte has gone.
        var closeTimeout: TimeInterval = 5
        /// How long a fetch may make no headway before it is given up.
        var stallTimeout: TimeInterval = 60
        /// How long `start` waits for the system to say it is listening.
        var listenTimeout: TimeInterval = 5
        /// How much of the file is read and sent at a time.
        var chunkBytes = 256 * 1024
        var maxConnections = 4
    }

    /// Runs an action on the main actor after that many seconds.
    typealias Scheduler = @MainActor @Sendable (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void

    private let addresses: @Sendable () -> [String]
    private let schedule: Scheduler
    private let clock: @Sendable () -> Date
    private let watchPath: PathWatcher
    private let settings: Settings
    private let lock = NSLock()
    private var session: LinkSession?
    /// The watch on the network kept for `session`.
    private var watch: PathWatch?

    public convenience init() {
        self.init(
            addresses: { LocalAddress.current() },
            schedule: { seconds, action in
                // By the time of day: a timer that counts only the time the Mac is awake
                // would let a link outlast a sleep.
                DispatchQueue.main.asyncAfter(wallDeadline: .now() + seconds) { MainActor.assumeIsolated { action() } }
            })
    }

    /// - Parameters:
    ///   - addresses: The local addresses to choose from; the first is listened on.
    ///   - schedule: How the link's expiry is timed.
    ///   - watchPath: Says when the Mac's network connections change: a link whose
    ///     address is then no longer among `addresses` ends.
    ///   - clock: The time of day, by which a link is over ten minutes after it began
    ///     even if the timer has not said so (the Mac slept meanwhile, say).
    init(
        addresses: @escaping @Sendable () -> [String], schedule: @escaping Scheduler,
        clock: @escaping @Sendable () -> Date = { Date() },
        watchPath: @escaping PathWatcher = { SystemPathWatch(onChange: $0) }, settings: Settings = Settings()
    ) {
        self.watchPath = watchPath
        self.addresses = addresses
        self.schedule = schedule
        self.clock = clock
        self.settings = settings
    }

    deinit {
        watch?.cancel()
        session?.end(waitingForListener: false)
    }

    @MainActor public func start(
        file: URL, fileName: String, now: Date, onEvent: @escaping @MainActor (PhoneLinkEvent) -> Void
    ) throws -> PhoneLinkOffer {
        stop()
        guard PhoneLinkText.isUsableFileName(fileName) else { throw PhoneLinkError.badFileName }
        guard let address = addresses().first, LocalAddress.ipv4Parts(address) != nil else {
            throw PhoneLinkError.noLocalAddress
        }
        guard let token = PhoneLinkText.makeToken() else { throw PhoneLinkError.cannotListen }

        let clock = clock
        let endsAt = clock().addingTimeInterval(PhoneLinkText.lifetime)
        let new = try LinkSession(
            file: file, fileName: fileName, token: token, address: address, settings: settings,
            isPastItsTime: { clock() >= endsAt }, onEvent: onEvent)
        let port: Int
        do {
            port = try new.listen()
        } catch {
            new.end(waitingForListener: true)
            throw error
        }
        guard let offer = PhoneLinkText.offer(
            file: file, fileName: fileName, token: token, address: address, port: port, now: now)
        else {
            new.end(waitingForListener: true)
            throw PhoneLinkError.cannotListen
        }
        lock.withLock { session = new }
        schedule(PhoneLinkText.lifetime) { [weak new] in new?.expire() }
        let watching = watchPath { [weak self, weak new] in
            guard let self, let new else { return }
            self.pathChanged(for: new, address: address)
        }
        let isCurrent = lock.withLock { () -> Bool in
            guard session === new else { return false }
            watch = watching
            return true
        }
        if !isCurrent { watching.cancel() }
        return offer
    }

    /// The Mac's network connections changed. A link whose address is no longer one of
    /// this Mac's cannot be reached by the phone it was shown to, and might be by
    /// others on whatever network has that address now: it ends.
    private func pathChanged(for linked: LinkSession, address: String) {
        guard !addresses().contains(address) else { return }
        let watching = lock.withLock { () -> PathWatch? in
            guard session === linked else { return nil }
            let watching = watch
            watch = nil
            return watching
        }
        watching?.cancel()
        linked.networkChanged()
    }

    @MainActor public func stop() {
        let (old, watching) = lock.withLock { () -> (LinkSession?, PathWatch?) in
            let old = (session, watch)
            session = nil
            watch = nil
            return old
        }
        watching?.cancel()
        old?.end(waitingForListener: true)
    }

    @MainActor public var isServing: Bool {
        lock.withLock { session }?.isLive ?? false
    }
}

// MARK: - The network path

/// Something that is watching the Mac's network connections until it is cancelled.
protocol PathWatch: AnyObject, Sendable {
    func cancel()
}

/// Starts watching: the action is run, on any thread, whenever the connections change.
typealias PathWatcher = @Sendable (@escaping @Sendable () -> Void) -> PathWatch

/// Watches with the system's own monitor of the network path.
final class SystemPathWatch: PathWatch, @unchecked Sendable {
    private let monitor = NWPathMonitor()

    init(onChange: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { _ in onChange() }
        monitor.start(queue: DispatchQueue(label: "VoxCarrel.PhoneLink.Path"))
    }

    func cancel() {
        monitor.cancel()
    }
}

// MARK: - Reporting

/// Passes a link's events to the main actor, in order, until the link is over.
private final class EventRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var onEvent: (@MainActor (PhoneLinkEvent) -> Void)?
    private var over = false

    init(onEvent: @escaping @MainActor (PhoneLinkEvent) -> Void) {
        self.onEvent = onEvent
    }

    /// False once an event that ends the link has been reported, or after `silence()`.
    var isLive: Bool { lock.withLock { !over } }

    /// Nothing is reported from now on, not even what was already on its way.
    func silence() {
        lock.withLock {
            onEvent = nil
            over = true
        }
    }

    func report(_ event: PhoneLinkEvent) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let handler = self.lock.withLock { () -> (@MainActor (PhoneLinkEvent) -> Void)? in
                    let handler = self.onEvent
                    if event.endsLink {
                        self.onEvent = nil
                        self.over = true
                    }
                    return handler
                }
                handler?(event)
            }
        }
    }
}

// MARK: - One link

/// One link from start to end: the open file, the listener and its connections.
/// Everything it does after `init` happens on its own queue.
private final class LinkSession: @unchecked Sendable {
    /// One caller.
    final class Caller {
        enum Phase { case reading, answering, sending, closing, done }

        let connection: NWConnection
        /// Its place among all the callers the link has had: lower is earlier.
        let order: Int
        var phase = Phase.reading
        /// True once it has been answered with the refusal.
        var refused = false
        var received: [UInt8] = []
        var timer: DispatchWorkItem?
        /// Set while this caller is being sent the file: where its part starts, how long
        /// it is, and how much of it the connection has reported as sent.
        var transfer: (start: Int64, length: Int64, sent: Int64)?
        var discarded = 0
        /// True once the caller has said it will send nothing more.
        var inputEnded = false

        init(_ connection: NWConnection, order: Int) {
            self.connection = connection
            self.order = order
        }
    }

    private let queue = DispatchQueue(label: "VoxCarrel.PhoneLink")
    private let settings: PhoneLinkServer.Settings
    private let relay: EventRelay
    private let fileName: String
    private let address: String
    private let size: Int64
    /// When the file was last written to, as it was when the link began.
    private let modified: timespec
    private let token: String
    /// Whether the link's ten minutes are over, by the time of day.
    private let isPastItsTime: @Sendable () -> Bool
    private let listenerCancelled = DispatchSemaphore(value: 0)

    // Touched on the queue only.
    private var descriptor: Int32
    private var resource: PhoneLinkResource?
    private var listener: NWListener?
    private var listenerStopped = false
    private var callers: [ObjectIdentifier: Caller] = [:]
    private var callersSoFar = 0
    private var transfers = 0
    /// The parts of the file that connections have reported as sent, merged and in order.
    private var covered: [Range<Int64>] = []
    private var lastPercent = -1
    private var expiring = false
    private var ended = false
    private var listenerIsGone = false
    /// The event that ends the link, held until the system has let go of the port.
    private var lastEvent: PhoneLinkEvent?

    /// Opens the file, once: everything served comes from this descriptor, whatever is
    /// later put at the path. A link, a folder or anything else that is not a plain
    /// file is refused.
    init(
        file: URL, fileName: String, token: String, address: String, settings: PhoneLinkServer.Settings,
        isPastItsTime: @escaping @Sendable () -> Bool, onEvent: @escaping @MainActor (PhoneLinkEvent) -> Void
    ) throws {
        let opened = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard opened >= 0 else { throw PhoneLinkError.fileUnreadable }
        var info = stat()
        guard fstat(opened, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(opened)
            throw PhoneLinkError.fileUnreadable
        }
        descriptor = opened
        size = Int64(info.st_size)
        modified = info.st_mtimespec
        self.fileName = fileName
        self.token = token
        self.address = address
        self.settings = settings
        self.isPastItsTime = isPastItsTime
        relay = EventRelay(onEvent: onEvent)
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    var isLive: Bool { relay.isLive }

    // MARK: Listening

    /// Starts listening on the link's address and returns the port the system chose.
    func listen() throws -> Int {
        guard let host = IPv4Address(address) else { throw PhoneLinkError.cannotListen }
        let parameters = NWParameters.tcp
        // This address only: never every interface.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(host), port: .any)
        parameters.includePeerToPeer = false
        guard let listener = try? NWListener(using: parameters) else { throw PhoneLinkError.cannotListen }

        let ready = DispatchSemaphore(value: 0)
        let chosen = PortBox()
        listener.stateUpdateHandler = { [weak self, listenerCancelled] state in
            switch state {
            case .ready:
                if let self, let port = self.listener?.port?.rawValue, port != 0, self.resource == nil {
                    self.resource = PhoneLinkResource(
                        token: self.token, fileName: PhoneLinkText.alias(for: self.fileName), size: self.size,
                        authority: "\(self.address):\(port)")
                    chosen.set(Int(port))
                }
                ready.signal()
            case .failed, .waiting:
                ready.signal()
                self?.finish(.failed("The link stopped working."))
            case .cancelled:
                ready.signal()
                listenerCancelled.signal()
                self?.listenerWentAway()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.accept(connection)
        }
        queue.sync { self.listener = listener }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + settings.listenTimeout)
        guard let port = chosen.value else { throw PhoneLinkError.cannotListen }
        return port
    }

    /// On the queue: the system has let go of the port.
    private func listenerWentAway() {
        listenerIsGone = true
        if let event = lastEvent {
            lastEvent = nil
            relay.report(event)
        }
    }

    private func stopListening() {
        guard !listenerStopped else { return }
        listenerStopped = true
        listener?.cancel()
    }

    // MARK: Ending

    /// Ends the link at once and silently: the listener, every connection, the file.
    /// Safe to call more than once and from any thread but the session's own queue.
    /// - Parameter waitingForListener: Whether to wait (briefly) until the system has
    ///   let go of the port.
    func end(waitingForListener: Bool) {
        relay.silence()
        let hadListener = queue.sync { () -> Bool in
            let had = listener != nil && !ended
            shutDown()
            return had
        }
        if hadListener, waitingForListener {
            _ = listenerCancelled.wait(timeout: .now() + 2)
        }
    }

    /// The link's time is up. A fetch under way is allowed to finish; nothing new is.
    func expire() {
        queue.async { self.timeIsUp() }
    }

    /// The link's address is no longer this Mac's: the link ends at once, with any
    /// fetch under way.
    func networkChanged() {
        queue.async { self.finish(.failed(PhoneLinkText.networkChanged)) }
    }

    /// On the queue: the same.
    private func timeIsUp() {
        guard !ended else { return }
        if transfers > 0 {
            expiring = true
            stopListening()
            for caller in Array(callers.values) where caller.transfer == nil { drop(caller) }
        } else {
            finish(.expired)
        }
    }

    /// On the queue: ends the link and reports why.
    /// The report is made once nothing is listening any more.
    private func finish(_ event: PhoneLinkEvent) {
        guard !ended else { return }
        shutDown()
        if listener == nil || listenerIsGone {
            relay.report(event)
        } else {
            lastEvent = event
            // Should the system never say so, the report is still made.
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.listenerWentAway() }
        }
    }

    /// On the queue: stops listening, cuts every connection and closes the file.
    private func shutDown() {
        guard !ended else { return }
        ended = true
        stopListening()
        for caller in Array(callers.values) {
            retire(caller)
            caller.connection.forceCancel()
        }
        transfers = 0
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        // Its timer may not have fired (the Mac slept): nobody is served past the time.
        if !ended, isPastItsTime() {
            connection.cancel()
            return timeIsUp()
        }
        guard !ended, !listenerStopped else {
            connection.cancel()
            return
        }
        if callers.count >= settings.maxConnections {
            // Whoever holds the places without asking for the file cannot keep the phone
            // out: the oldest caller that has sent no good request makes way. One that is
            // being sent the file, or has been answered with its headers, never does.
            let idle = callers.values.filter { $0.transfer == nil && ($0.phase == .reading || $0.refused) }
            guard let oldest = idle.min(by: { $0.order < $1.order }) else {
                connection.cancel()
                return
            }
            drop(oldest)
        }
        callersSoFar += 1
        let caller = Caller(connection, order: callersSoFar)
        callers[ObjectIdentifier(caller)] = caller
        connection.stateUpdateHandler = { [weak self, weak caller] state in
            guard let self, let caller else { return }
            switch state {
            case .failed, .cancelled: self.lost(caller)
            default: break
            }
        }
        setTimer(caller, after: settings.requestTimeout) { [weak self] in
            guard let self, caller.phase == .reading else { return }
            // One that said nothing is dropped; one that began and did not finish is refused.
            if caller.received.isEmpty { self.drop(caller) } else { self.refuse(caller) }
        }
        connection.start(queue: queue)
        read(caller)
    }

    private func setTimer(_ caller: Caller, after seconds: TimeInterval, _ action: @escaping () -> Void) {
        caller.timer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.ended, caller.phase != .done else { return }
            action()
        }
        caller.timer = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// Reads until the request can be judged, and never past its headers.
    private func read(_ caller: Caller) {
        caller.connection.receive(minimumIncompleteLength: 1, maximumLength: PhoneLinkRequest.maxHeadBytes) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.ended, caller.phase == .reading else { return }
            if let data { caller.received.append(contentsOf: data) }
            if isComplete { caller.inputEnded = true }
            guard let resource = self.resource else { return self.refuse(caller) }
            switch PhoneLinkRequest.answer(caller.received, for: resource) {
            case .needMore:
                if error != nil || isComplete {
                    if caller.received.isEmpty { self.drop(caller) } else { self.refuse(caller) }
                } else {
                    self.read(caller)
                }
            case .notFound:
                self.refuse(caller)
            case .serve(let headOnly, let rangeFrom):
                self.serve(caller, headOnly: headOnly, rangeFrom: rangeFrom)
            }
        }
    }

    /// The same empty 404 whatever was wrong, then the connection is closed.
    private func refuse(_ caller: Caller) {
        guard caller.phase == .reading else { return }
        caller.phase = .answering
        caller.refused = true
        sendLast(Data(PhoneLinkRequest.notFound), to: caller)
    }

    /// Sends `data`, says that nothing more will come, and closes once the caller has
    /// closed its side or `lingerTimeout` has passed. What the caller goes on sending
    /// is read and thrown away, so that the answer is not lost to it.
    private func sendLast(_ data: Data, to caller: Caller) {
        setTimer(caller, after: settings.lingerTimeout) { [weak self] in self?.drop(caller) }
        caller.connection.send(
            content: data, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self, !self.ended, caller.phase != .done else { return }
                if error != nil { return self.drop(caller) }
                self.discard(caller) { [weak self] _ in self?.drop(caller) }
            })
    }

    /// Reads and throws away what the caller sends until it closes its side (`then`
    /// with true), fails (false) or has sent a megabyte (false).
    private func discard(_ caller: Caller, then: @escaping (Bool) -> Void) {
        // It may have closed its side already, with its request: nothing more will come.
        if caller.inputEnded { return then(true) }
        caller.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.ended, caller.phase != .done else { return }
            caller.discarded += data?.count ?? 0
            if error != nil || caller.discarded > 1_048_576 { return then(false) }
            if isComplete {
                caller.inputEnded = true
                return then(true)
            }
            self.discard(caller, then: then)
        }
    }

    /// Closes a connection that is not, or no longer, being sent the file.
    private func drop(_ caller: Caller) {
        guard caller.phase != .done else { return }
        if caller.transfer != nil { return stopTransfer(caller, complete: false) }
        retire(caller)
        caller.connection.cancel()
    }

    /// Takes a caller off the books; its connection is the next thing to be cancelled.
    private func retire(_ caller: Caller) {
        caller.phase = .done
        caller.timer?.cancel()
        caller.timer = nil
        callers[ObjectIdentifier(caller)] = nil
        caller.connection.stateUpdateHandler = nil
    }

    /// The connection failed or was closed under us.
    private func lost(_ caller: Caller) {
        guard !ended, caller.phase != .done else { return }
        // Every byte had been reported sent: that is the file, however the goodbye went.
        if caller.phase == .closing { return stopTransfer(caller, complete: true) }
        if caller.transfer != nil { stopTransfer(caller, complete: false) } else { drop(caller) }
    }

    // MARK: Sending the file

    private func serve(_ caller: Caller, headOnly: Bool, rangeFrom: Int64?) {
        let headers = Data(PhoneLinkRequest.fileHeaders(fileName: fileName, size: size, rangeFrom: rangeFrom))
        if headOnly {
            caller.phase = .answering
            return sendLast(headers, to: caller)
        }
        let start = rangeFrom ?? 0
        caller.phase = .sending
        caller.transfer = (start: start, length: size - start, sent: 0)
        transfers += 1
        relay.report(.started(bytesTotal: size))
        armStallTimer(caller)
        caller.connection.send(content: headers, completion: .contentProcessed { [weak self] error in
            guard let self, !self.ended, caller.phase == .sending else { return }
            if error != nil { return self.stopTransfer(caller, complete: false) }
            self.sendNextPiece(caller)
        })
    }

    private func armStallTimer(_ caller: Caller) {
        setTimer(caller, after: settings.stallTimeout) { [weak self] in
            self?.stopTransfer(caller, complete: false)
        }
    }

    /// Reads the next piece of the file and sends it; the one after is read only when
    /// the connection reports this one sent, so no more than a piece is ever held.
    private func sendNextPiece(_ caller: Caller) {
        guard let transfer = caller.transfer else { return }
        let remaining = transfer.length - transfer.sent
        guard remaining > 0 else { return sendEnd(caller) }
        let count = Int(min(remaining, Int64(settings.chunkBytes)))
        guard let piece = readFile(at: transfer.start + transfer.sent, count: count) else {
            return finish(.failed(PhoneLinkText.fileChanged))
        }
        caller.connection.send(content: piece, completion: .contentProcessed { [weak self] error in
            guard let self, !self.ended, caller.phase == .sending else { return }
            if error != nil { return self.stopTransfer(caller, complete: false) }
            // Counted only now that the connection says it has gone.
            caller.transfer?.sent += Int64(count)
            self.armStallTimer(caller)
            self.reportProgress(transfer.start + transfer.sent + Int64(count))
            self.sendNextPiece(caller)
        })
    }

    /// Exactly `count` bytes of the file from `offset`; nil when they cannot be read,
    /// as when the file has been cut short.
    private func readFile(at offset: Int64, count: Int) -> Data? {
        guard descriptor >= 0 else { return nil }
        var data = Data(count: count)
        var filled = 0
        while filled < count {
            let got = data.withUnsafeMutableBytes { buffer in
                pread(descriptor, buffer.baseAddress! + filled, count - filled, off_t(offset) + off_t(filled))
            }
            if got < 0, errno == EINTR { continue }
            guard got > 0 else { return nil }
            filled += got
        }
        return data
    }

    private func reportProgress(_ position: Int64) {
        let percent = size > 0 ? Int(position * 100 / size) : 100
        guard percent != lastPercent else { return }
        lastPercent = percent
        relay.report(.progress(bytesSent: position))
    }

    /// Every byte has been reported sent without error: that is the whole transfer. The
    /// connection is closed from this side, without waiting for the caller, which may
    /// well mean to keep it open.
    private func sendEnd(_ caller: Caller) {
        caller.phase = .closing
        setTimer(caller, after: settings.closeTimeout) { [weak self] in
            self?.stopTransfer(caller, complete: true)
        }
        caller.connection.send(
            content: nil, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                guard let self, !self.ended, caller.phase == .closing else { return }
                self.stopTransfer(caller, complete: true)
            })
    }

    /// A fetch is over: whole (`complete`) or cut short. What it sent is remembered
    /// either way, so that fetches which together reached the end count as the file.
    private func stopTransfer(_ caller: Caller, complete: Bool) {
        guard !ended, caller.phase != .done, let transfer = caller.transfer else { return }
        caller.transfer = nil
        transfers -= 1
        noteCovered(transfer.start..<(transfer.start + transfer.sent))
        retire(caller)
        if complete { caller.connection.cancel() } else { caller.connection.forceCancel() }

        if complete, covered == [0..<size] || size == 0 {
            // What was fetched is the file that was checked only if nothing wrote to it meanwhile.
            finish(fileIsAsItWas() ? .finished : .failed(PhoneLinkText.fileChanged))
        } else if transfers == 0 {
            if expiring { finish(.expired) } else { relay.report(.interrupted) }
        }
    }

    /// Whether the file has the size and the date of last writing it had when the link began.
    private func fileIsAsItWas() -> Bool {
        var info = stat()
        guard descriptor >= 0, fstat(descriptor, &info) == 0 else { return false }
        return Int64(info.st_size) == size && info.st_mtimespec.tv_sec == modified.tv_sec
            && info.st_mtimespec.tv_nsec == modified.tv_nsec
    }

    private func noteCovered(_ range: Range<Int64>) {
        guard !range.isEmpty else { return }
        var merged: [Range<Int64>] = []
        var new = range
        for old in covered {
            if old.upperBound < new.lowerBound {
                merged.append(old)
            } else if new.upperBound < old.lowerBound {
                merged.append(new)
                new = old
            } else {
                new = min(old.lowerBound, new.lowerBound)..<max(old.upperBound, new.upperBound)
            }
        }
        merged.append(new)
        covered = merged
    }
}

/// The port a listener reported, handed from its queue to whoever waits for it.
private final class PortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var port: Int?

    var value: Int? { lock.withLock { port } }

    func set(_ port: Int) {
        lock.withLock { self.port = port }
    }
}
