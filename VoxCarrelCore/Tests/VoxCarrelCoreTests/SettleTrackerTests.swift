import Foundation
import Testing
@testable import VoxCarrelCore

/// When a file in a watched folder has finished arriving (rules IB20–IB26).
/// No test waits: every moment is a date passed in.
@Suite struct SettleTrackerTests {
    /// The moment of the first observation in each test.
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let interval = SettleTracker.settleInterval

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func file(_ path: String, size: Int64 = 100, modified: TimeInterval = 700_000_000.25) -> ListedFile {
        ListedFile(
            url: URL(fileURLWithPath: "/Watched/" + path), size: size,
            modifiedAt: Date(timeIntervalSinceReferenceDate: modified))
    }

    private func names(_ files: [ListedFile]) -> [String] {
        files.map { String($0.url.path.dropFirst("/Watched/".count)) }
    }

    // MARK: IB20

    @Test func theIntervalIsTenSeconds() {
        #expect(SettleTracker.settleInterval == 10)
    }

    @Test func IB20_aFileSeenUnchangedAfterTheIntervalIsReady() {
        var tracker = SettleTracker()
        let book = file("a.m4b")

        #expect(tracker.observe([book], at: start).isEmpty)
        #expect(tracker.observe([book], at: at(interval)) == [book])
        // And stays ready for as long as it stays the same.
        #expect(tracker.observe([book], at: at(interval + 1)) == [book])
        #expect(tracker.observe([book], at: at(3_600)) == [book])
    }

    @Test func IB20_justShortOfTheIntervalIsNotEnough() {
        var tracker = SettleTracker()
        let book = file("a.m4b")

        _ = tracker.observe([book], at: start)

        #expect(tracker.observe([book], at: at(interval - 0.001)).isEmpty)
        #expect(tracker.observe([book], at: at(interval)) == [book])
    }

    /// The earlier observation need not be the one before: any that is old enough counts.
    @Test func IB20_anEarlierObservationOldEnoughSettlesAFileWhateverCameBetween() {
        var tracker = SettleTracker()
        let book = file("a.m4b")

        #expect(tracker.observe([book], at: start).isEmpty)
        #expect(tracker.observe([book], at: at(4)).isEmpty)
        #expect(tracker.observe([book], at: at(8)).isEmpty)
        #expect(tracker.observe([book], at: at(12)) == [book])
    }

    @Test func IB20_readyFilesAreReturnedSortedByPath() {
        var tracker = SettleTracker()
        let files = [file("b.m4b"), file("Sub/z.epub"), file("a.m4b"), file("Sub/a.epub")]

        _ = tracker.observe(files, at: start)
        let ready = tracker.observe(files.reversed(), at: at(11))

        #expect(names(ready) == ["Sub/a.epub", "Sub/z.epub", "a.m4b", "b.m4b"])
    }

    @Test func IB20_withNothingListedNothingIsReady() {
        var tracker = SettleTracker()

        #expect(tracker.observe([], at: start).isEmpty)
        #expect(tracker.observe([], at: at(11)).isEmpty)
        #expect(!tracker.hasUnsettled)
    }

    // MARK: IB21

    @Test func IB21_aChangedSizeStartsAgain() {
        var tracker = SettleTracker()

        _ = tracker.observe([file("a.m4b", size: 100)], at: start)
        #expect(tracker.observe([file("a.m4b", size: 200)], at: at(11)).isEmpty)
        // Ten seconds from the change, not from the first sight.
        #expect(tracker.observe([file("a.m4b", size: 200)], at: at(20.999)).isEmpty)
        #expect(names(tracker.observe([file("a.m4b", size: 200)], at: at(21))) == ["a.m4b"])
    }

    @Test func IB21_aChangedDateStartsAgainEvenWithTheSameSize() {
        var tracker = SettleTracker()

        _ = tracker.observe([file("a.m4b", modified: 1_000)], at: start)
        #expect(tracker.observe([file("a.m4b", modified: 1_000.000001)], at: at(11)).isEmpty)
        #expect(names(tracker.observe([file("a.m4b", modified: 1_000.000001)], at: at(21))) == ["a.m4b"])
    }

    @Test func IB21_aReadyFileThatChangesIsNoLongerReady() {
        var tracker = SettleTracker()

        _ = tracker.observe([file("a.m4b")], at: start)
        #expect(tracker.observe([file("a.m4b")], at: at(11)).count == 1)

        #expect(tracker.observe([file("a.m4b", size: 101)], at: at(22)).isEmpty)
        #expect(tracker.hasUnsettled)
        #expect(tracker.observe([file("a.m4b", size: 101)], at: at(32)).count == 1)
    }

    /// The old state seen long ago does not count for a file that has gone back to it.
    @Test func IB21_aFileThatChangesAndChangesBackStartsAgain() {
        var tracker = SettleTracker()

        _ = tracker.observe([file("a.m4b", size: 100)], at: start)
        _ = tracker.observe([file("a.m4b", size: 200)], at: at(5))

        #expect(tracker.observe([file("a.m4b", size: 100)], at: at(11)).isEmpty)
        #expect(tracker.observe([file("a.m4b", size: 100)], at: at(20.5)).isEmpty)
        #expect(tracker.observe([file("a.m4b", size: 100)], at: at(21)).count == 1)
    }

    @Test func IB21_aFileGrowingAcrossThreeObservationsIsReadyOnlyOnceItStops() {
        var tracker = SettleTracker()

        #expect(tracker.observe([file("a.m4b", size: 1_000, modified: 1)], at: start).isEmpty)
        #expect(tracker.observe([file("a.m4b", size: 2_000, modified: 12)], at: at(11)).isEmpty)
        #expect(tracker.observe([file("a.m4b", size: 3_000, modified: 23)], at: at(22)).isEmpty)
        #expect(tracker.hasUnsettled)

        let done = file("a.m4b", size: 3_000, modified: 23)
        #expect(tracker.observe([done], at: at(33)) == [done])
        #expect(!tracker.hasUnsettled)
    }

    // MARK: IB22

    @Test func IB22_aSettledFileWaitsForTheOthersInItsDirectory() {
        var tracker = SettleTracker()
        let one = file("Book/1.mp3")

        _ = tracker.observe([one, file("Book/2.mp3", size: 5)], at: start)

        #expect(tracker.observe([one, file("Book/2.mp3", size: 6)], at: at(11)).isEmpty)
        #expect(tracker.hasUnsettled)
        #expect(names(tracker.observe([one, file("Book/2.mp3", size: 6)], at: at(22))) == ["Book/1.mp3", "Book/2.mp3"])
    }

    @Test func IB22_aPartThatAppearsLaterHoldsBackTheSettledParts() {
        var tracker = SettleTracker()
        let one = file("Book/1.mp3")
        let two = file("Book/2.mp3")

        _ = tracker.observe([one], at: start)
        #expect(tracker.observe([one, two], at: at(11)).isEmpty)
        #expect(tracker.observe([one, two], at: at(21)) == [one, two])
    }

    @Test func IB22_inATenPartFolderWithTheNinthStillChangingNoPartIsReady() {
        var tracker = SettleTracker()
        func parts(ninth size: Int64) -> [ListedFile] {
            (1...10).map { file("Book/part \($0).mp3", size: $0 == 9 ? size : 1_000) }
        }

        _ = tracker.observe(parts(ninth: 100), at: start)
        #expect(tracker.observe(parts(ninth: 200), at: at(11)).isEmpty)
        #expect(tracker.observe(parts(ninth: 300), at: at(22)).isEmpty)
        #expect(tracker.hasUnsettled)

        // The ninth stops; the whole book arrives together.
        let ready = tracker.observe(parts(ninth: 300), at: at(33))
        #expect(ready.count == 10)
        #expect(Set(ready) == Set(parts(ninth: 300)))
        #expect(!tracker.hasUnsettled)
    }

    @Test func IB22_aBookFolderBesideALooseFileDoesNotHoldItBackNorIsHeldBack() {
        var tracker = SettleTracker()
        let loose = file("loose.epub")
        func book(_ size: Int64) -> [ListedFile] { [file("Book/1.mp3"), file("Book/2.mp3", size: size)] }

        _ = tracker.observe([loose] + book(1), at: start)
        // The folder is still being written; the loose file beside it is done.
        #expect(tracker.observe([loose] + book(2), at: at(11)) == [loose])
        #expect(tracker.hasUnsettled)

        // And the other way: the folder done, the loose file changing.
        let changed = file("loose.epub", size: 999)
        #expect(names(tracker.observe([changed] + book(2), at: at(22))) == ["Book/1.mp3", "Book/2.mp3"])
        #expect(tracker.hasUnsettled)
    }

    @Test func IB22_subDirectoriesAndParentsDoNotHoldEachOtherBack() {
        var tracker = SettleTracker()
        let outer = file("Series/cover-book.epub")
        let inner = file("Series/Book 1/a.mp3")
        let deep = file("Series/Book 1/Disc 2/b.mp3")
        // A directory whose name only starts the same is another directory.
        let near = file("Series/Book 10/c.mp3")

        _ = tracker.observe([outer, inner, deep, near], at: start)

        let innerChanged = file("Series/Book 1/a.mp3", size: 7)
        #expect(tracker.observe([outer, innerChanged, deep, near], at: at(11)) == [near, deep, outer].sorted { $0.url.path < $1.url.path })

        let outerChanged = file("Series/cover-book.epub", size: 7)
        #expect(tracker.observe([outerChanged, innerChanged, deep, near], at: at(22)) == [innerChanged, deep, near].sorted { $0.url.path < $1.url.path })
    }

    // MARK: IB23

    @Test func IB23_aFileThatGoesAndReturnsStartsAgain() {
        var tracker = SettleTracker()
        let book = file("a.m4b")

        _ = tracker.observe([book], at: start)
        #expect(tracker.observe([], at: at(5)).isEmpty)
        #expect(!tracker.hasUnsettled)

        // Back exactly as it was, long after its first sighting: counted from now.
        #expect(tracker.observe([book], at: at(11)).isEmpty)
        #expect(tracker.observe([book], at: at(20.9)).isEmpty)
        #expect(tracker.observe([book], at: at(21)) == [book])
    }

    @Test func IB23_aReadyFileThatGoesAndReturnsStartsAgain() {
        var tracker = SettleTracker()
        let book = file("a.m4b")

        _ = tracker.observe([book], at: start)
        #expect(tracker.observe([book], at: at(11)) == [book])
        _ = tracker.observe([], at: at(12))

        #expect(tracker.observe([book], at: at(30)).isEmpty)
        #expect(tracker.observe([book], at: at(40)) == [book])
    }

    @Test func IB23_aMissingPartNoLongerHoldsBackTheRest() {
        var tracker = SettleTracker()
        let one = file("Book/1.mp3")

        _ = tracker.observe([one, file("Book/2.mp3.tmp-renamed.mp3", size: 1)], at: start)
        #expect(tracker.observe([one, file("Book/2.mp3.tmp-renamed.mp3", size: 2)], at: at(11)).isEmpty)

        #expect(tracker.observe([one], at: at(12)) == [one])
    }

    // MARK: IB24

    @Test func IB24_manyObservationsCloseTogetherNeverSettleAFile() {
        var tracker = SettleTracker()
        let book = file("a.m4b")

        // Two hundred looks inside ten seconds.
        for step in 0..<200 {
            #expect(tracker.observe([book], at: at(Double(step) * 0.0499)).isEmpty)
            #expect(tracker.hasUnsettled)
        }
        // It is time since the first sight that counts, not the number of sights.
        #expect(tracker.observe([book], at: at(interval)) == [book])
    }

    @Test func IB24_theSameMomentTwiceSettlesNothing() {
        var tracker = SettleTracker()
        let book = file("a.m4b")

        #expect(tracker.observe([book], at: start).isEmpty)
        #expect(tracker.observe([book], at: start).isEmpty)
        #expect(tracker.observe([book], at: start).isEmpty)
    }

    // MARK: IB25

    @Test func IB25_whenTheClockGoesBackEveryFileStartsAgain() {
        var tracker = SettleTracker()
        let ready = file("ready.m4b")
        let waiting = file("waiting.m4b")

        _ = tracker.observe([ready], at: start)
        #expect(tracker.observe([ready], at: at(11)) == [ready])
        #expect(tracker.observe([ready, waiting], at: at(15)) == [])

        // An hour earlier than the last look.
        let back = at(15 - 3_600)
        #expect(tracker.observe([ready, waiting], at: back).isEmpty)
        #expect(tracker.hasUnsettled)
        // Counted from the new clock: not ready because the old first sight is far off.
        #expect(tracker.observe([ready, waiting], at: back.addingTimeInterval(9.9)).isEmpty)
        #expect(tracker.observe([ready, waiting], at: back.addingTimeInterval(10)) == [ready, waiting])
        #expect(!tracker.hasUnsettled)
    }

    @Test func IB25_aClockThatGoesBackByAMomentIsEnough() {
        var tracker = SettleTracker()
        let book = file("a.m4b")

        _ = tracker.observe([book], at: start)
        _ = tracker.observe([book], at: at(9.5))

        #expect(tracker.observe([book], at: at(9.25)).isEmpty)
        // Ten seconds from the first sight by the old clock, but not by the new.
        #expect(tracker.observe([book], at: at(10)).isEmpty)
        #expect(tracker.observe([book], at: at(19.25)) == [book])
    }

    // MARK: IB26

    @Test func IB26_hasUnsettledIsFalseBeforeAnythingIsObserved() {
        #expect(!SettleTracker().hasUnsettled)
    }

    @Test func IB26_hasUnsettledFollowsTheLastObservation() {
        var tracker = SettleTracker()
        let book = file("a.m4b")
        let late = file("late.epub")

        _ = tracker.observe([book], at: start)
        #expect(tracker.hasUnsettled)

        _ = tracker.observe([book], at: at(11))
        #expect(!tracker.hasUnsettled)

        // A newcomer in the same directory: nothing is returned, so both are unsettled.
        #expect(tracker.observe([book, late], at: at(12)).isEmpty)
        #expect(tracker.hasUnsettled)

        #expect(tracker.observe([book, late], at: at(22)).count == 2)
        #expect(!tracker.hasUnsettled)

        // Everything gone: nothing listed, so nothing unsettled.
        _ = tracker.observe([], at: at(23))
        #expect(!tracker.hasUnsettled)
    }

    /// A settled file held back by its directory counts as unsettled: it was listed
    /// and not returned, and another look is needed.
    @Test func IB26_aSettledFileHeldBackByItsDirectoryCountsAsUnsettled() {
        var tracker = SettleTracker()
        let one = file("Book/1.mp3")

        _ = tracker.observe([one], at: start)
        let ready = tracker.observe([one, file("Book/2.mp3")], at: at(11))

        #expect(ready.isEmpty)
        #expect(tracker.hasUnsettled)
    }

    /// A lister never reports a path twice; if a caller does, it is one file.
    @Test func aPathListedTwiceIsOneFile() {
        var tracker = SettleTracker()
        let book = file("a.m4b")

        _ = tracker.observe([book, book], at: start)

        #expect(tracker.observe([book, book], at: at(11)) == [book])
        #expect(!tracker.hasUnsettled)
    }
}
