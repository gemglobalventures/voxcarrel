import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// A26: files and folders the app is asked to open (dropped on its Dock icon, or opened
/// with it from the Finder) are imported, and are never lost without a word.
@MainActor
@Suite struct AppModelOpenFilesTests {
    private func quietRivers(_ inbox: URL) -> URL { inbox.appendingPathComponent("Quiet Rivers.epub") }
    private func tidewater(_ inbox: URL) -> URL { inbox.appendingPathComponent("Tidewater Chronicles") }

    private func titles(_ h: Harness) -> Set<String> {
        Set(h.model.review?.entries.map(\.candidate.metadata.title) ?? [])
    }

    @Test func openingFilesBeginsAnImportOfThem() async throws {
        let h = try await Harness.empty()
        let inbox = try Harness.inbox()
        await h.model.openFiles([quietRivers(inbox), tidewater(inbox)])
        #expect(titles(h) == ["Quiet Rivers", "Salt Road", "The Drowned Bell", "Harbour of Glass"])
        #expect(h.model.alert == nil)
        #expect(h.model.busyLabel == nil)
    }

    /// Q13, as for a drop on the window.
    @Test func onlyFilesAndFoldersAreTaken() async throws {
        let h = try await Harness.empty()
        h.recordBusyLabels()
        await h.model.openFiles([])
        await h.model.openFiles([try #require(URL(string: "https://example.com/book.epub"))])
        await h.model.settle()
        #expect(h.busyLabels.isEmpty)
        #expect(h.model.review == nil)
        #expect(h.model.alert == nil)
    }

    /// The app was launched by opening the files: they arrive before the library is open.
    @Test func filesOpenedBeforeTheLibraryIsOpenAreImportedOnceItIs() async throws {
        let h = try await Harness.demo(start: false)
        let inbox = try Harness.inbox()
        await h.model.openFiles([quietRivers(inbox)])
        await h.model.openFiles([tidewater(inbox)])
        #expect(h.model.review == nil)
        #expect(h.model.alert == nil)

        await h.model.start()
        await h.model.settle()
        #expect(titles(h) == ["Quiet Rivers", "Salt Road", "The Drowned Bell", "Harbour of Glass"])
        #expect(h.model.alert == nil)
        #expect(h.model.rows.count == 12)

        // Imported once only: nothing is begun again when the next operation ends.
        h.model.cancelImport()
        await h.model.setReadStatus(.finished, for: [try h.id("Harbour of Glass")])
        await h.model.settle()
        #expect(h.model.review == nil)
    }

    @Test func filesOpenedWithNoLibraryChosenAreNotTakenAndTheUserIsTold() async throws {
        let h = try Harness(root: try makeTempDir(), choose: false)
        let inbox = try Harness.inbox()

        // At launch: held until it is known that there is no library.
        await h.model.openFiles([quietRivers(inbox)])
        #expect(h.model.alert == nil)
        await h.model.start()
        await h.model.settle()
        #expect(h.model.alert == AppModel.openedWithNoLibraryChosen)
        #expect(h.model.review == nil)

        // Later.
        h.model.alert = nil
        await h.model.openFiles([tidewater(inbox)])
        #expect(h.model.alert == AppModel.openedWithNoLibraryChosen)
        #expect(h.model.wantsToBeSeen)

        // They were not kept for the library that is chosen next.
        h.model.alert = nil
        await h.model.chooseLibrary(h.root)
        await h.model.settle()
        #expect(h.model.isLibraryOpen)
        #expect(h.model.review == nil)
        #expect(h.model.alert == nil)
        #expect(exists(quietRivers(inbox)))
    }

    @Test func filesOpenedWhileTheLibraryCannotBeOpenedAreNotTakenAndTheUserIsTold() async throws {
        let h = try Harness(root: try makeTempDir().appendingPathComponent("gone"))
        let inbox = try Harness.inbox()
        await h.model.openFiles([quietRivers(inbox)])
        await h.model.start()
        await h.model.settle()
        #expect(h.model.alert == AppModel.openedWithLibraryNotOpen)
        #expect(h.model.review == nil)
    }

    /// A16: nothing begins while an operation runs; the files wait for it to end.
    @Test func filesOpenedWhileAnOperationRunsAreImportedWhenItEnds() async throws {
        let h = try await Harness.demo()
        let inbox = try Harness.inbox()
        let gate = Gate()
        h.model.beforeOperation = { await gate.wait() }
        let harbour = try h.id("Harbour of Glass")
        let running = Task { await h.model.setReadStatus(.finished, for: [harbour]) }
        await gate.arrival()

        await h.model.openFiles([quietRivers(inbox)])
        #expect(h.model.review == nil)
        #expect(h.model.alert == nil)

        await gate.release()
        await running.value
        await h.model.settle()
        #expect(titles(h) == ["Quiet Rivers"])
        #expect(h.model.alert == nil)
        #expect(try h.book(harbour).readStatus == .finished)
    }

    /// A19: an open review is not replaced; the user is told why nothing happened.
    @Test func filesOpenedDuringAReviewAreNotTakenAndTheUserIsTold() async throws {
        let h = try await Harness.empty()
        let inbox = try Harness.inbox()
        await h.model.openFiles([quietRivers(inbox)])
        let review = try #require(h.model.review)

        await h.model.openFiles([tidewater(inbox)])
        await h.model.settle()
        #expect(h.model.review == review)
        #expect(h.model.alert == AppModel.openedDuringReview)

        // They were not kept for later.
        h.model.alert = nil
        h.model.cancelImport()
        await h.model.settle()
        #expect(h.model.review == nil)
        #expect(h.model.alert == nil)
    }

    /// Files opened while an import is being confirmed wait for it, like any operation.
    @Test func filesOpenedWhileAnImportRunsAreReviewedAfterIt() async throws {
        let h = try await Harness.empty()
        let inbox = try Harness.inbox()
        await h.model.openFiles([quietRivers(inbox)])
        let gate = Gate()
        h.model.beforeOperation = { await gate.wait() }
        let importing = Task { await h.model.confirmImport() }
        await gate.arrival()

        await h.model.openFiles([tidewater(inbox)])
        await gate.release()
        await importing.value
        await h.model.settle()
        #expect(h.titles == ["Quiet Rivers"])
        #expect(titles(h) == ["Salt Road", "The Drowned Bell", "Harbour of Glass"])
        #expect(h.model.alert == nil)
    }
}
