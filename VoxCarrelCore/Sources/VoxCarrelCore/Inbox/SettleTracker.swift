import Foundation

/// Decides when a file in a watch folder has finished arriving, from nothing but what
/// repeated listings show: a file that has kept its size and modification date for
/// long enough is taken as written. It needs no knowledge of who is writing; when a
/// listing does say that a file is still being written, the file waits until it no
/// longer says so. Long enough is longer for a file on a disk that is not this Mac's own.
///
/// Holds what earlier listings showed. Time is always given, never read.
public struct SettleTracker: Sendable {
    /// How long a file must stay the same to count as settled, in seconds.
    public static let settleInterval: TimeInterval = 10
    /// The same for a file that is not on one of this Mac's own disks: a copy over a
    /// network may stand still for a while and then go on.
    public static let remoteSettleInterval: TimeInterval = 60

    /// One file as it has been since `since`.
    private struct Sighting: Sendable {
        var size: Int64
        var modifiedAt: Date
        /// The first observation, in an unbroken run of them, that saw the file
        /// with this size and date.
        var since: Date
        /// How long it must stay the same, by the disk it is on.
        var interval: TimeInterval
    }

    /// The files of the last observation, by path.
    private var sightings: [String: Sighting] = [:]
    private var lastObservation: Date?

    /// Whether any file seen at the last observation was not yet ready: another look,
    /// a settle interval on, may find more.
    public private(set) var hasUnsettled = false

    public init() {}

    /// Records what is there now and returns the files that are ready, sorted by path.
    ///
    /// A file is ready when it has been seen unchanged, and not marked as being written,
    /// for the settle interval of its disk and so
    /// has every other listed file in its directory, so that a book in parts arrives
    /// whole. A file that changes, or goes and comes back, starts again from `now`; so
    /// does every file when `now` is earlier than the last observation.
    public mutating func observe(_ files: [ListedFile], at now: Date) -> [ListedFile] {
        // The clock went back: nothing seen before says anything about how long ago.
        if let lastObservation, now < lastObservation { sightings = [:] }
        lastObservation = now

        var current: [String: Sighting] = [:]
        var listed: [String: ListedFile] = [:]
        for file in files {
            let path = file.url.path
            var sighting = Sighting(
                size: file.size, modifiedAt: file.modifiedAt, since: now,
                interval: file.isOnLocalVolume ? Self.settleInterval : Self.remoteSettleInterval)
            // A file still being written starts again at every look.
            if !file.isBeingWritten, let before = sightings[path], before.size == file.size,
                before.modifiedAt == file.modifiedAt
            {
                sighting.since = before.since
            }
            current[path] = sighting
            listed[path] = file
        }
        sightings = current

        var unsettledDirectories: Set<String> = []
        for (path, sighting) in current where now.timeIntervalSince(sighting.since) < sighting.interval {
            unsettledDirectories.insert(Self.directory(of: path))
        }
        let ready = listed.filter { !unsettledDirectories.contains(Self.directory(of: $0.key)) }
        hasUnsettled = ready.count < listed.count
        return ready.sorted { $0.key < $1.key }.map(\.value)
    }

    /// The path of the directory holding the file at `path`.
    private static func directory(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }
}
