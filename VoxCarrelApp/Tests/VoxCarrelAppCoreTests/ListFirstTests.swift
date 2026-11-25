import Foundation
import Observation
import Testing
@testable import VoxCarrelAppCore

/// LF1–LF3: a library's list is shown before the library is checked against the disk.
@MainActor @Suite struct ListFirstTests {
    /// What the window showed at the moment the check began.
    final class Seen: @unchecked Sendable {
        var began = 0
        var busyLabel: String??
        var rows = -1
        var counted = -1
    }

    /// Notes what the model shows each time the check is about to begin.
    private func watch(_ model: AppModel, _ seen: Seen) {
        withObservationTracking {
            _ = model.isCheckingLibrary
        } onChange: {
            // Called just before the value changes: false here means it is about to begin.
            MainActor.assumeIsolated {
                if !model.isCheckingLibrary {
                    seen.began += 1
                    seen.busyLabel = model.busyLabel
                    seen.rows = model.rowsLoaded ? model.rows.count : -1
                    seen.counted = model.sidebar.counts[.allBooks] ?? -1
                }
                self.watch(model, seen)
            }
        }
    }

    @Test func LF1_theListIsThereAndTheWindowIsFreeBeforeTheCheckBegins() async throws {
        let h = try await Harness.demo(start: false)
        let seen = Seen()
        watch(h.model, seen)
        #expect(!h.model.isCheckingLibrary)

        await h.model.startIfNeeded()

        // When the check began the books were listed and counted, and nothing was in the way.
        #expect(seen.began == 1)
        #expect(seen.busyLabel == .some(nil))
        #expect(seen.rows == h.model.rows.count && seen.rows > 0)
        #expect(seen.counted == seen.rows)
        // And when it is over the window says so no more.
        #expect(!h.model.isCheckingLibrary && h.model.busyLabel == nil)
        #expect(h.model.statusBar?.library.hasPrefix("Library: ") == true)
    }

    @Test func LF2_theStatusBarSaysTheLibraryIsBeingCheckedWhileItIs() async throws {
        let h = try await Harness.demo()
        let plain = try #require(h.model.statusBar?.library)
        h.model.isCheckingLibrary = true
        #expect(h.model.statusBar?.library == "Checking the library… · \(plain)")
        h.model.isCheckingLibrary = false
        #expect(h.model.statusBar?.library == plain)
    }

    @Test func LF3_whatTheCheckFindsIsStillToldAndAnotherLibraryOpenedMeanwhileIsNotToldOfIt() async throws {
        // A file gone from the disk is found by the check that now runs behind the list.
        let h = try await Harness.demo(start: false)
        let lost = try #require(try FileManager.default.subpathsOfDirectory(atPath: h.root.path)
            .first { $0.hasSuffix(".m4b") || $0.hasSuffix(".mp3") })
        try FileManager.default.removeItem(at: h.root.appendingPathComponent(lost))
        await h.model.startIfNeeded()
        #expect(h.model.libraryCheck?.booksWithMissingFiles.isEmpty == false)
        #expect(!h.model.missingFileTitles.isEmpty && !h.model.isCheckingLibrary)

        // A check that comes back for a library that is no longer the one open says nothing.
        let other = try await Harness.demo()
        let worker = try #require(h.model.worker)
        other.model.libraryCheck = nil
        await other.model.runLibraryCheck(with: worker)
        #expect(other.model.libraryCheck == nil && other.model.missingFileTitles.isEmpty)
    }
}
