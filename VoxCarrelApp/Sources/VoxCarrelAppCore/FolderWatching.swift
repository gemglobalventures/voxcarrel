import CoreServices
import Foundation

/// Tells the app when something changes under a set of folders. The app's own implementation
/// listens to the file system; tests use one they fire by hand.
public protocol FolderWatching: AnyObject, Sendable {
    /// Replaces the watched set. `onChange` is called on the main actor, at most
    /// once per second, after anything changes under any of the folders.
    @MainActor func watch(_ folders: [URL], onChange: @escaping @MainActor () -> Void)
    @MainActor func stop()
}

/// Runs actions later. The app's own implementation waits for real; tests use one that
/// runs an action when told to.
public protocol Ticking: AnyObject, Sendable {
    /// Runs the action once, on the main actor, after that many seconds.
    @MainActor func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void)
    /// Prevents every scheduled action that has not yet run.
    @MainActor func cancelAll()
}

// MARK: - The file system watcher

/// Watches folders, and everything under them, with a file system event stream.
///
/// It says only that something changed, never what: whoever listens looks for itself.
/// A callback that holds the watcher's owner strongly keeps both alive until `stop()`.
public final class FSEventsFolderWatcher: FolderWatching, @unchecked Sendable {
    /// The shortest time between two calls of `onChange`.
    static let interval: TimeInterval = 1

    private let lock = NSLock()
    private var session: WatchSession?

    public init() {}

    deinit {
        session?.end()
    }

    @MainActor public func watch(_ folders: [URL], onChange: @escaping @MainActor () -> Void) {
        let new = WatchSession(folders: folders, interval: Self.interval, onChange: onChange)
        replaceSession(with: new)
    }

    @MainActor public func stop() {
        replaceSession(with: nil)
    }

    private func replaceSession(with new: WatchSession?) {
        let old = lock.withLock { () -> WatchSession? in
            let old = session
            session = new
            return old
        }
        old?.end()
    }
}

/// One running event stream and the reports it gives rise to.
private final class WatchSession: @unchecked Sendable {
    private let relay: ChangeRelay
    /// The stream's events arrive here; ending the session on the same queue means none
    /// is half-delivered when the stream is released.
    private let queue = DispatchQueue(label: "VoxCarrel.FolderWatcher")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    init(folders: [URL], interval: TimeInterval, onChange: @escaping @MainActor () -> Void) {
        relay = ChangeRelay(interval: interval, onChange: onChange)
        guard !folders.isEmpty else { return }

        // The stream keeps the relay alive through these two for as long as it exists, and
        // holds nothing else: neither this session nor the watcher.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(relay).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<ChangeRelay>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<ChangeRelay>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let paths = folders.map { $0.resolvingSymlinksInPath().path } as CFArray
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<ChangeRelay>.fromOpaque(info).takeUnretainedValue().eventsArrived()
            },
            &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
            FSEventStreamCreateFlags(flags))
        guard let created else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        if FSEventStreamStart(created) {
            stream = created
        } else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
        }
    }

    deinit {
        end()
    }

    /// Stops the stream and silences the relay. Nothing is reported afterwards, even for
    /// events that had already arrived. Safe to call more than once and from any thread.
    func end() {
        relay.cancel()
        let ending = lock.withLock { () -> FSEventStreamRef? in
            let ending = stream
            stream = nil
            return ending
        }
        guard let ending else { return }
        queue.sync {
            FSEventStreamStop(ending)
            FSEventStreamInvalidate(ending)
            FSEventStreamRelease(ending)
        }
    }
}

/// Turns a flood of events into calls of `onChange` on the main actor, no two of them less
/// than `interval` apart: the first event is reported at once, and any that follow within
/// the interval are reported together when it ends.
private final class ChangeRelay: @unchecked Sendable {
    private let interval: TimeInterval
    private let lock = NSLock()
    private var onChange: (@MainActor () -> Void)?
    private var isScheduled = false
    private var lastReport: DispatchTime?

    init(interval: TimeInterval, onChange: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.onChange = onChange
    }

    /// Called on the stream's queue each time events are delivered.
    func eventsArrived() {
        let deadline = lock.withLock { () -> DispatchTime? in
            guard onChange != nil, !isScheduled else { return nil }
            isScheduled = true
            let now = DispatchTime.now()
            guard let lastReport else { return now }
            return max(now, lastReport + interval)
        }
        guard let deadline else { return }
        DispatchQueue.main.asyncAfter(deadline: deadline) { [self] in
            MainActor.assumeIsolated { report() }
        }
    }

    @MainActor private func report() {
        let action = lock.withLock { () -> (@MainActor () -> Void)? in
            isScheduled = false
            lastReport = .now()
            return onChange
        }
        action?()
    }

    /// Lets go of the callback; nothing is reported from now on.
    func cancel() {
        // The callback is released outside the lock: releasing it may release its owner.
        let dropped = lock.withLock { () -> (@MainActor () -> Void)? in
            let dropped = onChange
            onChange = nil
            return dropped
        }
        _ = dropped
    }
}

// MARK: - The ticker

/// Runs each action once on the main actor when its time comes. Releasing the ticker
/// cancels whatever has not yet run.
public final class TimerTicker: Ticking, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Int: DispatchWorkItem] = [:]
    private var nextId = 0

    public init() {}

    deinit {
        cancelPending()
    }

    @MainActor public func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        let id = lock.withLock { () -> Int in
            nextId += 1
            return nextId
        }
        let item = DispatchWorkItem { [weak self] in
            // Taken out first: an action that was cancelled in the meantime is gone.
            guard let self, self.lock.withLock({ self.pending.removeValue(forKey: id) }) != nil else { return }
            MainActor.assumeIsolated { action() }
        }
        lock.withLock { pending[id] = item }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds), execute: item)
    }

    @MainActor public func cancelAll() {
        cancelPending()
    }

    private func cancelPending() {
        let items = lock.withLock { () -> [DispatchWorkItem] in
            let items = Array(pending.values)
            pending = [:]
            return items
        }
        items.forEach { $0.cancel() }
    }
}
