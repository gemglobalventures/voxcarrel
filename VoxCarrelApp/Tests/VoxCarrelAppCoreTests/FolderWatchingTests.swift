import Foundation
import Testing
import VoxCarrelAppCore
import VoxCarrelFixtures

/// Counts the reports of a watcher or the runs of a ticker, and lets a test wait for the next.
@MainActor
private final class Reports {
    private struct Waiter {
        var id: Int
        var above: Int
        var continuation: CheckedContinuation<Bool, Never>
    }

    private(set) var count = 0
    /// When each report came.
    private(set) var times: [ContinuousClock.Instant] = []
    private var waiters: [Waiter] = []
    private var nextId = 0

    func note() {
        count += 1
        times.append(.now)
        let satisfied = waiters.filter { count > $0.above }
        waiters.removeAll { count > $0.above }
        satisfied.forEach { $0.continuation.resume(returning: true) }
    }

    /// Returns true once there have been more than `above` reports, or false after 20 seconds.
    func wait(above: Int) async -> Bool {
        if count > above { return true }
        let id = nextId
        nextId += 1
        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(id: id, above: above, continuation: continuation))
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                MainActor.assumeIsolated { self?.giveUp(id) }
            }
        }
    }

    private func giveUp(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    /// Does `change` and waits for a report that comes after it.
    func expectReport(
        _ what: Comment, sourceLocation: SourceLocation = #_sourceLocation, after change: () throws -> Void
    ) async throws {
        let before = count
        try change()
        let reported = await wait(above: before)
        #expect(reported, what, sourceLocation: sourceLocation)
    }
}

/// A temporary folder as FSEvents names it (under `/private`), removed by `remove()`.
private struct WatchedFolder {
    let url: URL

    init() throws {
        url = try makeTempDir().resolvingSymlinksInPath()
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// Changes the folder twice and returns once a watcher of its own has reported each change.
/// Its reports are at least a second apart, so by the time this returns any other running
/// watcher of the folder has long had the first change: a watcher that stayed silent was
/// not watching.
@MainActor
private func changeAndWaitItOut(_ folder: WatchedFolder) async throws {
    let control = FSEventsFolderWatcher()
    let seen = Reports()
    control.watch([folder.url]) { seen.note() }
    defer { control.stop() }
    try await seen.expectReport("the control watcher saw the first change") {
        try touch(folder.file("control-\(UUID().uuidString).mp3"))
    }
    try await seen.expectReport("the control watcher saw the second change") {
        try touch(folder.file("control-\(UUID().uuidString).mp3"))
    }
}

@MainActor
@Suite struct FolderWatchingTests {
    // MARK: WF1

    @Test func wf1_reportsFilesCreatedChangedRenamedAndRemoved() async throws {
        let folder = try WatchedFolder()
        defer { folder.remove() }
        let watcher = FSEventsFolderWatcher()
        let reports = Reports()
        watcher.watch([folder.url]) { reports.note() }
        defer { watcher.stop() }

        let file = folder.file("book.m4b")
        let renamed = folder.file("renamed.m4b")
        try await reports.expectReport("created") { try touch(file, "one") }
        try await reports.expectReport("changed") { try Data("longer contents".utf8).write(to: file) }
        try await reports.expectReport("renamed") { try FileManager.default.moveItem(at: file, to: renamed) }
        try await reports.expectReport("removed") { try FileManager.default.removeItem(at: renamed) }
    }

    @Test func wf1_reportsAFileInASubfolderCreatedAfterWatchingBegan() async throws {
        let folder = try WatchedFolder()
        defer { folder.remove() }
        let watcher = FSEventsFolderWatcher()
        let reports = Reports()
        watcher.watch([folder.url]) { reports.note() }
        defer { watcher.stop() }

        let sub = folder.url.appendingPathComponent("Author/Book", isDirectory: true)
        try await reports.expectReport("sub-folder created") {
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        }
        try await reports.expectReport("file created in the new sub-folder") {
            try touch(sub.appendingPathComponent("part 1.mp3"))
        }
        try await reports.expectReport("file changed in the new sub-folder") {
            try Data("more".utf8).write(to: sub.appendingPathComponent("part 1.mp3"))
        }
    }

    @Test func wf1_reportsFromEveryWatchedFolder() async throws {
        let first = try WatchedFolder()
        let second = try WatchedFolder()
        defer {
            first.remove()
            second.remove()
        }
        let watcher = FSEventsFolderWatcher()
        let reports = Reports()
        watcher.watch([first.url, second.url]) { reports.note() }
        defer { watcher.stop() }

        try await reports.expectReport("first folder") { try touch(first.file("a.epub")) }
        try await reports.expectReport("second folder") { try touch(second.file("b.epub")) }
    }

    @Test func wf1_reportsAreAtLeastASecondApart() async throws {
        let folder = try WatchedFolder()
        defer { folder.remove() }
        let watcher = FSEventsFolderWatcher()
        let reports = Reports()
        watcher.watch([folder.url]) { reports.note() }
        defer { watcher.stop() }

        // Each burst is many changes; the second burst comes straight after the first report.
        try await reports.expectReport("first burst") {
            for index in 0..<20 { try touch(folder.file("first \(index).mp3")) }
        }
        try await reports.expectReport("second burst") {
            for index in 0..<20 { try touch(folder.file("second \(index).mp3")) }
        }
        try await reports.expectReport("third burst") {
            for index in 0..<20 { try touch(folder.file("third \(index).mp3")) }
        }

        #expect(reports.count >= 3)
        let gaps = zip(reports.times, reports.times.dropFirst()).map { $1 - $0 }
        // A little under a second allows for the moment between the watcher noting the time
        // and this test noting it.
        #expect(gaps.allSatisfy { $0 >= .milliseconds(950) }, "gaps were \(gaps)")
    }

    // MARK: WF2

    @Test func wf2_watchAndStopAreSafeToRepeatAndWhenNothingIsWatched() async throws {
        let folder = try WatchedFolder()
        defer { folder.remove() }
        let watcher = FSEventsFolderWatcher()
        let reports = Reports()

        watcher.stop()
        watcher.stop()
        watcher.watch([]) { reports.note() }
        watcher.stop()
        watcher.watch([folder.url]) { reports.note() }
        watcher.watch([folder.url]) { reports.note() }
        watcher.watch([]) { reports.note() }
        watcher.watch([folder.url]) { reports.note() }

        // After all that it still watches what it was last given.
        try await reports.expectReport("still watching") { try touch(folder.file("a.mp3")) }
        watcher.stop()
        watcher.stop()
    }

    @Test func wf2_watchingAgainReplacesTheEarlierFolders() async throws {
        let old = try WatchedFolder()
        let new = try WatchedFolder()
        defer {
            old.remove()
            new.remove()
        }
        // A stream begun just after its folder was made can still be told of the making.
        // Waiting that out first means any report below is of a change made below.
        try await changeAndWaitItOut(new)
        let watcher = FSEventsFolderWatcher()
        let oldReports = Reports()
        let newReports = Reports()
        watcher.watch([old.url]) { oldReports.note() }
        watcher.watch([new.url]) { newReports.note() }
        defer { watcher.stop() }
        let oldBefore = oldReports.count
        let newBefore = newReports.count

        try touch(old.file("ignored.mp3"))
        try await changeAndWaitItOut(old)

        #expect(oldReports.count == oldBefore, "the first callback is no longer called")
        #expect(newReports.count == newBefore, "the first folder is no longer watched")
        try await newReports.expectReport("the new folder is watched") { try touch(new.file("a.mp3")) }
        #expect(oldReports.count == oldBefore)
    }

    @Test func wf2_stopEndsAllReports() async throws {
        let folder = try WatchedFolder()
        defer { folder.remove() }
        let watcher = FSEventsFolderWatcher()
        let reports = Reports()
        watcher.watch([folder.url]) { reports.note() }
        try await reports.expectReport("watching before the stop") { try touch(folder.file("a.mp3")) }

        // More changes, stopped before they can be reported.
        for index in 0..<5 { try touch(folder.file("late \(index).mp3")) }
        watcher.stop()
        let before = reports.count

        try await changeAndWaitItOut(folder)

        #expect(reports.count == before)
    }

    @Test func wf2_aFolderThatDoesNotExistIsAcceptedAndReportsNothing() async throws {
        let folder = try WatchedFolder()
        defer { folder.remove() }
        let missing = folder.url.deletingLastPathComponent()
            .appendingPathComponent("voxcarrel-missing-\(UUID().uuidString)", isDirectory: true)
        let alone = FSEventsFolderWatcher()
        let aloneReports = Reports()
        alone.watch([missing]) { aloneReports.note() }
        defer { alone.stop() }

        // Beside a folder that does exist, the missing one does not stop the other's reports.
        let watcher = FSEventsFolderWatcher()
        let reports = Reports()
        watcher.watch([missing, folder.url]) { reports.note() }
        defer { watcher.stop() }
        try await reports.expectReport("the folder that exists") { try touch(folder.file("a.mp3")) }

        try await changeAndWaitItOut(folder)
        #expect(aloneReports.count == 0)
    }

    // MARK: WF3

    @Test func wf3_releasingTheWatcherStopsItsReports() async throws {
        let folder = try WatchedFolder()
        defer { folder.remove() }
        let reports = Reports()
        var watcher: FSEventsFolderWatcher? = FSEventsFolderWatcher()
        weak let released = watcher
        watcher?.watch([folder.url]) { reports.note() }
        try await reports.expectReport("watching before release") { try touch(folder.file("a.mp3")) }

        // More changes, with the watcher released before they can be reported.
        for index in 0..<5 { try touch(folder.file("late \(index).mp3")) }
        watcher = nil
        let before = reports.count
        #expect(released == nil, "nothing else keeps the watcher alive while it watches")

        try await changeAndWaitItOut(folder)

        #expect(reports.count == before)
    }

    @Test func wf3_aStoppedWatcherLetsGoOfItsCallback() async throws {
        final class Token {}
        let folder = try WatchedFolder()
        defer { folder.remove() }
        let watcher = FSEventsFolderWatcher()
        var token: Token? = Token()
        weak let held = token
        watcher.watch([folder.url]) { [token] in _ = token }
        token = nil
        #expect(held != nil)

        watcher.stop()

        #expect(held == nil, "the callback, and whatever it holds, is released on stop")
    }

    // MARK: WF4

    @Test func wf4_aScheduledActionRunsOnce() async throws {
        let ticker = TimerTicker()
        let first = Reports()
        let later = Reports()
        ticker.schedule(after: 0.05) { first.note() }
        ticker.schedule(after: 0.4) { later.note() }

        #expect(first.count == 0, "not run before its time, and never inside schedule")
        #expect(await first.wait(above: 0))
        #expect(await later.wait(above: 0))
        #expect(first.count == 1)
        #expect(later.count == 1)
    }

    @Test func wf4_cancelAllPreventsEveryActionNotYetRun() async throws {
        let ticker = TimerTicker()
        let cancelled = Reports()
        let after = Reports()
        ticker.cancelAll()
        ticker.schedule(after: 0.05) { cancelled.note() }
        ticker.schedule(after: 0.1) { cancelled.note() }
        ticker.cancelAll()
        ticker.cancelAll()

        // The ticker still works afterwards; this later action outlasts the cancelled ones.
        ticker.schedule(after: 0.5) { after.note() }
        #expect(await after.wait(above: 0))
        #expect(cancelled.count == 0)
    }

    @Test func wf4_releasingTheTickerPreventsItsActions() async throws {
        let cancelled = Reports()
        let after = Reports()
        var ticker: TimerTicker? = TimerTicker()
        ticker?.schedule(after: 0.05) { cancelled.note() }
        ticker = nil

        let other = TimerTicker()
        other.schedule(after: 0.5) { after.note() }
        #expect(await after.wait(above: 0))
        #expect(cancelled.count == 0)
    }

    // MARK: The fakes used by the app model's tests

    @Test func fakeWatcherFiresTheCurrentCallbackOnly() {
        let watcher = FakeFolderWatcher()
        let first = URL(fileURLWithPath: "/tmp/first")
        let second = URL(fileURLWithPath: "/tmp/second")
        var log: [String] = []

        watcher.fire()
        #expect(!watcher.isWatching)

        watcher.watch([first]) { log.append("first") }
        #expect(watcher.folders == [first])
        #expect(watcher.isWatching)
        watcher.fire()

        watcher.watch([second]) { log.append("second") }
        #expect(watcher.folders == [second])
        watcher.fire()
        #expect(watcher.watchCount == 2)

        watcher.stop()
        watcher.fire()
        #expect(watcher.folders.isEmpty)
        #expect(!watcher.isWatching)
        #expect(watcher.stopCount == 1)
        #expect(log == ["first", "second"])
    }

    @Test func fakeTickerRunsPendingActionsSoonestFirst() {
        let ticker = FakeTicker()
        var log: [String] = []
        #expect(!ticker.runNext())

        ticker.schedule(after: 60) { log.append("minute") }
        ticker.schedule(after: 11) { log.append("recheck") }
        ticker.schedule(after: 60) { log.append("second minute") }
        #expect(ticker.pending.map(\.delay) == [60, 11, 60])

        #expect(ticker.runNext())
        #expect(log == ["recheck"])
        #expect(ticker.pending.map(\.delay) == [60, 60])
        #expect(ticker.runNext())
        #expect(log == ["recheck", "minute"])

        // An action may schedule another, as a repeating tick does.
        ticker.schedule(after: 5) { ticker.schedule(after: 7) { log.append("chained") } }
        #expect(ticker.run(delay: 5))
        #expect(!ticker.run(delay: 5))
        #expect(ticker.pending.map(\.delay) == [60, 7])

        ticker.cancelAll()
        #expect(ticker.pending.isEmpty)
        #expect(ticker.cancelCount == 1)
        #expect(!ticker.runNext())
        #expect(log == ["recheck", "minute"])
    }
}
