import DemoContent
import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// A19–A22: the import flow.
@MainActor
@Suite struct AppModelImportTests {
    /// The inbox's ebook of poems, and its folder of three audiobooks in a series.
    private func quietRivers(_ inbox: URL) -> URL { inbox.appendingPathComponent("Quiet Rivers.epub") }
    private func tidewater(_ inbox: URL) -> URL { inbox.appendingPathComponent("Tidewater Chronicles") }
    /// The audiobook with no author, which can be catalogued but not filed.
    private func attic(_ inbox: URL) -> URL { inbox.appendingPathComponent("Downloads") }

    private func entry(_ h: Harness, _ title: String) throws -> ImportReview.Entry {
        try #require(h.model.review?.entries.first { $0.candidate.metadata.title == title }, "no entry titled \(title)")
    }

    // MARK: A19 Beginning

    /// A19
    @Test func beginningWithNothingDoesNothing() async throws {
        let h = try await Harness.empty()
        h.recordBusyLabels()
        await h.model.beginImport([])
        #expect(h.busyLabels.isEmpty)
        #expect(h.model.review == nil)
        #expect(h.model.alert == nil)
    }

    /// A19, A20: the scan becomes a review, with the remembered copy setting and every destination worked out.
    @Test func beginningScansAndOpensTheReview() async throws {
        let h = try await Harness.empty()
        h.recordBusyLabels()
        h.model.copyOnImport = true
        let inbox = try Harness.inbox()
        let notes = try touch(inbox.appendingPathComponent("notes.txt"))

        await h.model.beginImport([quietRivers(inbox), tidewater(inbox), attic(inbox), notes])
        #expect(h.busyLabels == ["Reading files…"])
        #expect(h.model.busyLabel == nil)
        #expect(h.model.alert == nil)
        let review = try #require(h.model.review)
        #expect(Set(review.entries.map(\.candidate.metadata.title)) == [
            "Quiet Rivers", "Salt Road", "The Drowned Bell", "Harbour of Glass", "Voices from the Attic",
        ])
        #expect(review.skipped.map(\.lastPathComponent) == ["notes.txt"])
        #expect(review.copyInsteadOfMove == true)
        #expect(review.entries.allSatisfy { $0.included && $0.cover != nil })
        #expect(review.canImport)

        // Destinations: where the engine would file each, and none for the one it cannot file.
        #expect(review.entriesNeedingDestination.isEmpty)
        let service = LibraryService(store: try h.store())
        for entry in review.entries {
            #expect(entry.destination == service.plannedFolder(for: entry.candidate.metadata))
        }
        #expect(try entry(h, "Quiet Rivers").destination != nil)
        #expect(try entry(h, "Voices from the Attic").destination == nil)
        #expect(review.readiness(of: try entry(h, "Voices from the Attic").id) == .willNeedAttention)

        // Nothing has been imported yet.
        #expect(h.model.rows.isEmpty)
        #expect(exists(quietRivers(inbox)))
    }

    /// A19
    @Test func aScanThatFindsNoBooksSaysSoAndOpensNoSheet() async throws {
        let h = try await Harness.empty()
        let folder = try makeTempDir()
        let notes = try touch(folder.appendingPathComponent("notes.txt"))
        let list = try touch(folder.appendingPathComponent("list.txt"))

        await h.model.beginImport([notes, list])
        #expect(h.model.review == nil)
        #expect(h.model.alert == "No audiobooks or ebooks were found. 2 items were skipped because VoxCarrel cannot import them.")
        #expect(h.model.busyLabel == nil)

        await h.model.beginImport([notes])
        #expect(h.model.alert == "No audiobooks or ebooks were found. 1 item was skipped because VoxCarrel cannot import it.")

        await h.model.beginImport([try makeTempDir()])
        #expect(h.model.alert == "No audiobooks or ebooks were found.")
        #expect(h.model.review == nil)
    }

    /// A19: a book already in the library is offered as the place for its files.
    @Test func beginningFindsBooksAlreadyInTheLibrary() async throws {
        let h = try await Harness.demo()
        let inbox = try Harness.inbox()
        await h.model.beginImport([quietRivers(inbox)])
        let entry = try entry(h, "Quiet Rivers")
        #expect(entry.existingMatch?.id == (try h.id("Quiet Rivers")))
        #expect(entry.isAddedToExisting)
        #expect(entry.destination == (try h.book(try h.id("Quiet Rivers")).folderPath))
        #expect(h.model.review?.entriesNeedingDestination.isEmpty == true)
    }

    /// A19: files dropped while a review is open do not replace it.
    @Test func beginningAgainKeepsTheOpenReview() async throws {
        let h = try await Harness.empty()
        let inbox = try Harness.inbox()
        await h.model.beginImport([quietRivers(inbox)])
        let review = try #require(h.model.review)
        await h.model.beginImport([tidewater(inbox)])
        #expect(h.model.review == review)
    }

    // MARK: A20 Destinations

    /// A20
    @Test func destinationsFollowTheReview() async throws {
        let h = try await Harness.empty()
        let inbox = try Harness.inbox()
        await h.model.beginImport([quietRivers(inbox), tidewater(inbox)])
        let quiet = try entry(h, "Quiet Rivers")
        let salt = try entry(h, "Salt Road")
        let before = try #require(quiet.destination)

        h.model.updateReview { review in
            let index = review.entries.firstIndex { $0.id == quiet.id }!
            review.entries[index].candidate.metadata.authors = ["Someone Else"]
            let other = review.entries.firstIndex { $0.id == salt.id }!
            review.entries[other].candidate.metadata.authors = []
        }
        // The change itself is immediate; the folders follow.
        #expect(h.model.review?.entries.first { $0.id == quiet.id }?.candidate.metadata.authors == ["Someone Else"])
        await h.model.settle()

        let review = try #require(h.model.review)
        #expect(review.entriesNeedingDestination.isEmpty)
        let moved = try #require(review.entries.first { $0.id == quiet.id })
        #expect(moved.destination != before)
        #expect(moved.destination == LibraryService(store: try h.store()).plannedFolder(for: moved.candidate.metadata))
        #expect(moved.destination?.contains("Someone Else") == true)
        // No author: it cannot be filed, so it has no folder.
        #expect(review.entries.first { $0.id == salt.id }?.destination == nil)
        #expect(review.readiness(of: salt.id) == .willNeedAttention)
    }

    /// A20: with no review open there is nothing to change.
    @Test func updatingWithNoReviewDoesNothing() async throws {
        let h = try await Harness.empty()
        h.model.updateReview { $0.copyInsteadOfMove = true }
        await h.model.settle()
        #expect(h.model.review == nil)
    }

    // MARK: A21 Importing

    /// A21, A11
    @Test func confirmingImportsReloadsAndSelects() async throws {
        let h = try await Harness.empty()
        h.recordBusyLabels()
        let inbox = try Harness.inbox()
        await h.model.beginImport([quietRivers(inbox), tidewater(inbox)])

        await h.model.confirmImport()
        #expect(h.busyLabels == ["Reading files…", "Importing 4 books…"])
        #expect(h.model.busyLabel == nil)
        #expect(h.model.review == nil)
        #expect(h.model.alert == nil)
        #expect(h.model.result == nil)
        #expect(h.titles == ["Harbour of Glass", "Quiet Rivers", "Salt Road", "The Drowned Bell"])
        #expect(h.model.sidebar.counts[.allBooks] == 4)
        #expect(h.model.sidebar.counts[.audiobooks] == 3)
        #expect(h.model.undoLabel == "Import 4 books")
        #expect(h.model.selection == Set(h.model.rows.map(\.id)))
        #expect(h.bulkDraft?.books.count == 4)
        // Moved, the default.
        #expect(!exists(quietRivers(inbox)))
        #expect(h.model.copyOnImport == false)
    }

    /// A21
    @Test func importingOneBookShowsItInTheInspector() async throws {
        let h = try await Harness.empty()
        h.recordBusyLabels()
        let inbox = try Harness.inbox()
        await h.model.beginImport([quietRivers(inbox)])
        await h.model.confirmImport()
        #expect(h.busyLabels.last == "Importing 1 book…")
        let id = try h.id("Quiet Rivers")
        #expect(h.model.selection == [id])
        #expect(h.detail?.files.map(\.name) == (try h.fileURLs(id).map(\.lastPathComponent)))
        #expect(h.draft?.title == "Quiet Rivers")
    }

    /// A21: only what is included is imported, and nothing at all when the review cannot be imported.
    @Test func confirmingNeedsAReviewThatCanBeImported() async throws {
        let h = try await Harness.empty()
        h.recordBusyLabels()
        await h.model.confirmImport()
        #expect(h.busyLabels.isEmpty)

        let inbox = try Harness.inbox()
        await h.model.beginImport([quietRivers(inbox), tidewater(inbox)])
        h.model.updateReview { review in
            for index in review.entries.indices { review.entries[index].included = false }
        }
        #expect(h.model.review?.canImport == false)
        await h.model.confirmImport()
        #expect(h.model.review != nil)
        #expect(h.busyLabels == ["Reading files…"])
        #expect(h.model.rows.isEmpty)

        let quiet = try entry(h, "Quiet Rivers").id
        h.model.updateReview { review in
            review.entries[review.entries.firstIndex { $0.id == quiet }!].included = true
        }
        await h.model.confirmImport()
        #expect(h.titles == ["Quiet Rivers"])
        #expect(exists(tidewater(inbox).appendingPathComponent("Salt Road.m4b")))
    }

    /// A21, A6: copying is remembered for the next import.
    @Test func theCopyChoiceIsRemembered() async throws {
        let h = try await Harness.empty()
        let inbox = try Harness.inbox()
        await h.model.beginImport([quietRivers(inbox)])
        h.model.updateReview { $0.copyInsteadOfMove = true }

        await h.model.confirmImport()
        #expect(h.titles == ["Quiet Rivers"])
        #expect(exists(quietRivers(inbox)))
        #expect(h.model.copyOnImport == true)
        #expect(h.defaults.object(forKey: "copyOnImport") as? Bool == true)

        await h.model.beginImport([tidewater(inbox)])
        #expect(h.model.review?.copyInsteadOfMove == true)
        h.model.updateReview { $0.copyInsteadOfMove = false }
        await h.model.confirmImport()
        #expect(h.model.copyOnImport == false)
        #expect(!exists(tidewater(inbox).appendingPathComponent("Salt Road.m4b")))
    }

    /// A21: a book that needs attention is worth a result sheet.
    @Test func anImportThatIsNotCleanSetsTheResult() async throws {
        let h = try await Harness.empty()
        let inbox = try Harness.inbox()
        await h.model.beginImport([quietRivers(inbox), attic(inbox)])
        await h.model.confirmImport()
        let result = try #require(h.model.result)
        #expect(result.headline == "1 book imported, 1 needs attention")
        #expect(!result.isClean)
        #expect(h.model.rows.count == 2)
        #expect(h.model.selection.count == 2)
        #expect(h.model.sidebar.counts[.needsAttention] == 1)
    }

    /// A21: only the imported books that the rows show are selected.
    @Test func onlyVisibleImportedBooksAreSelected() async throws {
        let h = try await Harness.empty()
        h.model.sidebarSelection = .ebooks
        await h.model.settle()
        let inbox = try Harness.inbox()
        await h.model.beginImport([quietRivers(inbox), tidewater(inbox)])
        await h.model.confirmImport()
        #expect(h.titles == ["Quiet Rivers"])
        #expect(h.model.selection == [try h.id("Quiet Rivers")])
        #expect(try h.store().books().count == 4)
    }

    /// A21, A13: an import does not take the inspector away from unsaved edits.
    @Test func importingKeepsUnsavedEdits() async throws {
        let h = try await Harness.demo()
        let salt = try await h.edit("Salt Road", newTitle: "Saltier Road")
        let inbox = try makeTempDir()
        let stray = try MediaFixtures.makeEPUB3(in: inbox, name: "New Arrival.epub")

        await h.model.beginImport([stray])
        await h.model.confirmImport()
        #expect(h.model.alert == nil)
        #expect(h.model.rows.count == 13)
        #expect(h.model.selection == [salt])
        #expect(h.draft?.title == "Saltier Road")
        #expect(h.model.prompt == nil)
    }

    /// A21
    @Test func cancellingImportsNothing() async throws {
        let h = try await Harness.empty()
        let inbox = try Harness.inbox()
        await h.model.beginImport([quietRivers(inbox)])
        h.model.updateReview { $0.copyInsteadOfMove = true }
        h.model.cancelImport()
        await h.model.settle()
        #expect(h.model.review == nil)
        #expect(h.model.rows.isEmpty)
        #expect(exists(quietRivers(inbox)))
        #expect(h.model.copyOnImport == false)

        await h.model.confirmImport()
        #expect(h.model.rows.isEmpty)
    }

    /// A16: no import starts, and none is confirmed, while something else runs.
    @Test func importingWaitsForARunningOperation() async throws {
        let h = try await Harness.demo(start: false)
        _ = try MediaFixtures.makeEPUB3(in: h.root, name: "Stray.epub")
        await h.model.start()
        let inbox = try Harness.inbox()
        await h.model.beginImport([tidewater(inbox)])
        let review = try #require(h.model.review)
        let check = try #require(h.model.libraryCheck)

        let gate = Gate()
        h.model.beforeOperation = { await gate.wait() }
        let harbour = try h.id("Harbour of Glass")
        let running = Task { await h.model.setReadStatus(.finished, for: [harbour]) }
        await gate.arrival()

        await h.model.confirmImport()
        #expect(h.model.review == review)
        h.model.cancelImport()
        await h.model.beginImport([quietRivers(inbox)])
        await h.model.importUntracked()
        #expect(h.model.review == nil)
        #expect(h.model.libraryCheck == check)

        await gate.release()
        await running.value
        #expect(h.model.rows.count == 12)
        #expect(exists(tidewater(inbox).appendingPathComponent("Salt Road.m4b")))
    }

    // MARK: A22 Files the launch check found

    /// A22
    @Test func importingUntrackedFilesBeginsAnImportOfThem() async throws {
        let h = try await Harness.demo(start: false)
        let stray = try MediaFixtures.makeEPUB3(in: h.root, name: "Stray.epub")
        h.model.copyOnImport = true
        await h.model.start()
        #expect(h.model.libraryCheck?.untrackedFiles.count == 1)

        await h.model.importUntracked()
        // Nothing else to tell, so the check is over.
        #expect(h.model.libraryCheck == nil)
        let review = try #require(h.model.review)
        #expect(review.entries.count == 1)
        #expect(review.entries.first?.candidate.files.map(\.url.lastPathComponent) == ["Stray.epub"])
        // The files are in the library already: they are moved into place, never copied.
        #expect(review.copyInsteadOfMove == false)

        await h.model.confirmImport()
        #expect(h.model.alert == nil)
        #expect(h.model.rows.count == 13)
        #expect(!exists(stray))
        // That it was a move this once is not remembered as the user's choice.
        #expect(h.model.copyOnImport == true)

        // A second launch check has nothing to say.
        await h.model.start()
        #expect(h.model.libraryCheck == nil)
    }

    /// A22: the rest of what the check found stays.
    @Test func importingUntrackedFilesKeepsTheRestOfTheCheck() async throws {
        let h = try await Harness.demo(start: false)
        _ = try MediaFixtures.makeEPUB3(in: h.root, name: "Stray.epub")
        let quiet = try h.id("Quiet Rivers")
        try FileManager.default.removeItem(at: try #require(try h.fileURLs(quiet).first))
        await h.model.start()

        await h.model.importUntracked()
        let check = try #require(h.model.libraryCheck)
        #expect(check.untrackedFiles.isEmpty)
        #expect(check.booksWithMissingFiles == [quiet])
        #expect(h.model.review?.entries.count == 1)
    }

    /// A22
    @Test func importingUntrackedFilesNeedsSome() async throws {
        let h = try await Harness.demo()
        h.recordBusyLabels()
        await h.model.importUntracked()
        #expect(h.busyLabels.isEmpty)
        #expect(h.model.review == nil)
    }
}
