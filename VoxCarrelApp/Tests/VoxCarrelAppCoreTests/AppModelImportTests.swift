import CoreGraphics
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
        // The offer stays until the import is confirmed.
        #expect(h.model.libraryCheck?.untrackedFiles.count == 1)
        let review = try #require(h.model.review)
        #expect(review.entries.count == 1)
        #expect(review.entries.first?.candidate.files.map(\.url.lastPathComponent) == ["Stray.epub"])
        // The files are in the library already: they are moved into place, never copied.
        #expect(review.copyInsteadOfMove == false)

        await h.model.confirmImport()
        #expect(h.model.alert == nil)
        // Nothing else to tell, so the check is over.
        #expect(h.model.libraryCheck == nil)
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
        #expect(h.model.review?.entries.count == 1)
        await h.model.confirmImport()
        let check = try #require(h.model.libraryCheck)
        #expect(check.untrackedFiles.isEmpty)
        #expect(check.booksWithMissingFiles == [quiet])
    }

    /// The check made on demand says so when everything is in place, and shows what
    /// it finds as the launch check does, without saying it was made at opening.
    @Test func theLibraryIsCheckedOnDemand() async throws {
        let h = try await Harness.demo()
        #expect(h.model.libraryCheck == nil && h.model.canCheckLibraryNow)
        await h.model.checkLibraryNow()
        let clean = try #require(h.model.libraryCheckSummary)
        #expect(clean.intro == "VoxCarrel looked over the library folder. Everything is where the library expects it, and nothing has been changed.")
        #expect(clean.untracked == nil && clean.missing == nil)
        // One check at a time.
        #expect(!h.model.canCheckLibraryNow)
        h.model.dismissLibraryCheck()
        #expect(h.model.libraryCheckSummary == nil)

        _ = try MediaFixtures.makeEPUB3(in: h.root, name: "Stray.epub")
        let quiet = try h.id("Quiet Rivers")
        try FileManager.default.removeItem(at: try #require(try h.fileURLs(quiet).first))
        await h.model.checkLibraryNow()
        let found = try #require(h.model.libraryCheckSummary)
        #expect(found.untracked?.lines.count == 1 && found.missing?.lines.map(\.text) == ["Quiet Rivers"])
        #expect(found.intro == "VoxCarrel looked over the library folder. Nothing has been changed.")
        #expect(h.model.busyLabel == nil)
    }

    /// A22: cancelling the review leaves the offer where it was.
    @Test func cancellingAnImportOfUntrackedFilesKeepsTheOffer() async throws {
        let h = try await Harness.demo(start: false)
        let stray = try MediaFixtures.makeEPUB3(in: h.root, name: "Stray.epub")
        await h.model.start()
        await h.model.importUntracked()
        h.model.cancelImport()
        #expect(h.model.libraryCheck?.untrackedFiles.map(\.lastPathComponent) == ["Stray.epub"])
        #expect(h.model.libraryCheckSummary?.untracked != nil)
        #expect(exists(stray))
        // And it can be taken up again.
        await h.model.importUntracked()
        #expect(h.model.review?.entries.count == 1)
    }

    /// A22: a file left out of the import, or one that could not be imported, is still on offer.
    @Test func untrackedFilesThatWereNotImportedStayOnTheCheck() async throws {
        let h = try await Harness.demo(start: false)
        // Two different books: a file that is a copy of another would be set aside.
        let stray = try MediaFixtures.makeEPUB2(in: h.root)
        try FileManager.default.moveItem(at: stray, to: h.root.appendingPathComponent("Stray.epub"))
        _ = try MediaFixtures.makeEPUB3(in: h.root, name: "Other.epub")
        await h.model.start()
        await h.model.importUntracked()
        let review = try #require(h.model.review)
        #expect(review.entries.count == 2)
        let leftOut = try #require(review.entries.first { $0.candidate.files.first?.url.lastPathComponent == "Other.epub" })
        h.model.updateReview { $0.update(leftOut.id) { $0.included = false } }
        await h.model.confirmImport()
        #expect(h.model.libraryCheck?.untrackedFiles.map(\.lastPathComponent) == ["Other.epub"])
    }

    /// A22: a book in several parts, left loose in the library, is one book in the review
    /// as it would be in any import, and is imported as one.
    @Test func anUntrackedBookInSeveralPartsIsOneEntry() async throws {
        let inbox = try Harness.inbox()
        let root = try makeTempDir()
        let h = try Harness(root: root)
        let loose = root.appendingPathComponent("Night Train to Vostok", isDirectory: true)
        try FileManager.default.copyItem(at: inbox.appendingPathComponent("Night Train to Vostok"), to: loose)
        await h.model.start()
        #expect(h.model.libraryCheck?.untrackedFiles.count == 4)

        await h.model.importUntracked()
        let review = try #require(h.model.review)
        #expect(review.entries.count == 1)
        #expect(review.entries.first?.candidate.files.count == 4)
        #expect(review.entries.first?.candidate.files.allSatisfy { $0.role == .audio } == true)

        await h.model.confirmImport()
        #expect(h.model.result == nil)
        #expect(h.model.alert == nil)
        #expect(h.titles == ["Night Train to Vostok"])
        let files = try h.fileURLs(try h.id("Night Train to Vostok")).map(\.lastPathComponent)
        #expect(files == (1...4).map { "0\($0) - Night Train to Vostok.mp3" })
        #expect(!exists(loose))
        #expect(h.model.libraryCheck == nil)
        await h.model.start()
        #expect(h.model.libraryCheck == nil)
    }

    /// A22: loose files beside a library book's own files are imported one by one, and
    /// the book's files are not offered again.
    @Test func untrackedFilesBesideALibraryBooksFilesAreTakenAlone() async throws {
        let h = try await Harness.demo(start: false)
        let folder = try #require(try h.fileURLs(try h.id("Quiet Rivers")).first).deletingLastPathComponent()
        _ = try MediaFixtures.makeEPUB3(in: folder, name: "Stray.epub")
        await h.model.start()
        await h.model.importUntracked()
        let review = try #require(h.model.review)
        #expect(review.entries.flatMap(\.candidate.files).map(\.url.lastPathComponent) == ["Stray.epub"])
    }

    /// A22, A21: files that are in the library already are moved, whatever is ticked or
    /// remembered, and that says nothing about what the user wants next time.
    @Test func filesInsideTheLibraryAreNeverCopied() async throws {
        let inbox = try Harness.inbox()
        let root = try makeTempDir()
        // The sample audiobooks all hold the same silence: this library does not set
        // aside files it already has, or the second would be taken for the first.
        try LibraryStore(libraryRoot: root).setKnowsFilesAgain(false)
        let h = try Harness(root: root)
        let loose = root.appendingPathComponent("The Lighthouse Keeper.m4b")
        try FileManager.default.copyItem(at: inbox.appendingPathComponent("The Lighthouse Keeper.m4b"), to: loose)
        await h.model.start()
        await h.model.importUntracked()
        #expect(h.model.review?.moveOnly == true)
        #expect(h.model.review?.offersCopy == false)
        h.model.updateReview { $0.copyInsteadOfMove = true }
        await h.model.confirmImport()
        #expect(!exists(loose))
        #expect(h.model.copyOnImport == false)
        #expect(try h.fileURLs(try h.id("The Lighthouse Keeper")).count == 1)
        await h.model.start()
        #expect(h.model.libraryCheck == nil)

        // The same for a file of the library folder that is dragged in by hand.
        let again = root.appendingPathComponent("Quiet Rivers.epub")
        try FileManager.default.copyItem(at: quietRivers(inbox), to: again)
        h.model.copyOnImport = true
        await h.model.beginImport([again])
        #expect(h.model.review?.moveOnly == true)
        await h.model.confirmImport()
        #expect(!exists(again))
        #expect(h.model.copyOnImport == true)

        // Files from anywhere else may be copied.
        await h.model.beginImport([tidewater(inbox)])
        #expect(h.model.review?.moveOnly == false)
        #expect(h.model.review?.copyInsteadOfMove == true)
    }

    // MARK: A23 The book already in the library follows the details

    /// A23: retitled so that it no longer matches, an entry is imported as the book it now is.
    @Test func retitlingAnEntryStopsItJoiningTheBookItMatched() async throws {
        let h = try await Harness.demo()
        let inbox = try Harness.inbox()
        let before = try h.fileURLs(try h.id("The Lighthouse Keeper"))
        await h.model.beginImport([inbox.appendingPathComponent("The Lighthouse Keeper.m4b")])
        let id = try entry(h, "The Lighthouse Keeper").id
        #expect(h.model.review?.entry(id)?.isAddedToExisting == true)

        h.model.updateReview { $0.setText("Another Book", for: .title, of: id) }
        await h.model.settle()
        let changed = try #require(h.model.review?.entry(id))
        #expect(changed.existingMatch == nil)
        #expect(!changed.isAddedToExisting)
        #expect(changed.destination == "Eleanor Marsh/Another Book")

        await h.model.confirmImport()
        #expect(try h.fileURLs(try h.id("The Lighthouse Keeper")) == before)
        let files = try h.fileURLs(try h.id("Another Book"))
        #expect(files.map(\.lastPathComponent) == ["Another Book.m4b"])
        #expect(try FileMetadataIO().read(files[0]).metadata.title == "Another Book")
    }

    /// A23: retitled so that it matches a library book, an entry is offered to it, switched on.
    @Test func retitlingAnEntryToMatchALibraryBookOffersThatBook() async throws {
        let h = try await Harness.demo()
        let inbox = try Harness.inbox()
        let stray = inbox.appendingPathComponent("Stray.epub")
        try FileManager.default.copyItem(at: quietRivers(inbox), to: stray)
        try FileManager.default.removeItem(at: quietRivers(inbox))
        await h.model.beginImport([stray])
        let id = try entry(h, "Quiet Rivers").id
        h.model.updateReview { $0.setText("Quiet Streams", for: .title, of: id) }
        await h.model.settle()
        #expect(h.model.review?.entry(id)?.existingMatch == nil)

        h.model.updateReview { $0.setText("quiet rivers", for: .title, of: id) }
        await h.model.settle()
        let matched = try #require(h.model.review?.entry(id))
        #expect(matched.existingMatch?.id == (try h.id("Quiet Rivers")))
        #expect(matched.isAddedToExisting)
        #expect(matched.destination == (try h.book(try h.id("Quiet Rivers")).folderPath))
    }

    // MARK: IH1–IH8 Guessing (plan 14)

    private static let untaggedName = "Mind Over Markets_ Power Tradin - James F. Dalton.pdf"
    private static let companionName =
        "Mind Over Markets\u{A789} Power Trading with Market Generated Information, Updated Edition [B09WXN61GL].pdf"
    private static let audiobookTitle = "Mind Over Markets (Unabridged)"
    private static let askedAbout =
        "Looks like “Mind Over Markets (Unabridged)”, which is already in your library. Add these files to it?"

    /// A started model on a library that holds one audiobook, imported from a real file:
    /// "Mind Over Markets (Unabridged)" by James F. Dalton, Audible ID B09WXN61GL.
    private func ownersLibrary() async throws -> (h: Harness, audiobook: Int64) {
        let h = try await Harness.empty()
        var tags = BookMetadata(title: Self.audiobookTitle, authors: ["James F. Dalton"])
        tags.asin = "B09WXN61GL"
        let audio = try makeAudiobook("library.m4b", tags: tags, in: try makeTempDir())
        await h.model.beginImport([audio])
        await h.model.confirmImport()
        let id = try h.id(Self.audiobookTitle)
        #expect(try h.book(id).asin == "B09WXN61GL")
        #expect(try h.fileURLs(id).count == 1)
        return (h, id)
    }

    private func makeAudiobook(_ name: String, tags: BookMetadata, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try MediaFixtures.makeAAC(at: url, seconds: 1)
        try FileMetadataIO().write(tags, cover: .keep, to: url)
        return url
    }

    /// A PDF with nothing in its information dictionary.
    private func makeUntaggedPDF(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    /// The PDF that came with the audiobook: its name has the Audible ID, its tags name
    /// another title and author.
    private func makeCompanionPDF(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(Self.companionName)
        MediaFixtures.makePDF(at: url)
        return url
    }

    /// What IH1–IH6 say of the untagged PDF and the companion PDF, whichever way they came.
    private func expectTheOwnersPDFs(_ h: Harness, audiobook: Int64) throws {
        let review = try #require(h.model.review)
        let folder = try h.book(audiobook).folderPath

        // The tagless PDF: read as "Title - Author", offered the audiobook, switched off.
        let untagged = try entry(h, "Mind Over Markets: Power Tradin")
        #expect(untagged.candidate.metadata.authors == ["James F. Dalton"])
        #expect(untagged.existingMatch?.id == audiobook)
        #expect(untagged.matchStrength == .possible)
        #expect(!untagged.addToExisting)
        #expect(!untagged.isAddedToExisting)
        #expect(untagged.existingMatchText == Self.askedAbout)
        #expect(untagged.candidate.files.map(\.role) == [.ebook])
        #expect(untagged.destination != nil)
        #expect(untagged.destination != folder)
        #expect(review.guessNote(of: untagged.id) == "Read from the file name as “Title - Author”.")
        #expect(!review.offersProminentSwap(of: untagged.id))
        #expect(
            review.question(of: untagged.id)
                == "This may be “Mind Over Markets (Unabridged)”, which is already in your library.")

        // The companion PDF: joins by the Audible ID in its name, as an extra.
        // (Its PDF title shares no word with so telling a name, so the name is read.)
        let companion = try entry(h, "Mind Over Markets: Power Trading with Market Generated Information, Updated Edition")
        #expect(companion.candidate.metadata.asin == "B09WXN61GL")
        #expect(companion.existingMatch?.id == audiobook)
        #expect(companion.matchStrength == .audibleID)
        #expect(companion.addToExisting)
        #expect(companion.isAddedToExisting)
        #expect(companion.existingMatchText == "Add to the existing book \"Mind Over Markets (Unabridged)\"")
        #expect(companion.candidate.files.map(\.role) == [.extra])
        #expect(companion.destination == folder)
        #expect(review.guessNote(of: companion.id) == "Read from the file name.")
        #expect(review.guessedAudibleIDText(of: companion.id) == "Audible ID B09WXN61GL")
        #expect(review.audibleIDNote(of: companion.id) == "The Audible ID was read from the file name.")
        #expect(review.question(of: companion.id) == nil)
    }

    /// IH1, IH3, IH4, IH6: the three files that prompted the plan, through the review.
    @Test func IH_theOwnersThreeFilesInTheReview() async throws {
        let (h, audiobook) = try await ownersLibrary()
        let inbox = try makeTempDir()
        let untagged = try makeUntaggedPDF(Self.untaggedName, in: inbox)
        let companion = try makeCompanionPDF(in: inbox)
        let audio = try makeAudiobook(
            "download.m4b", tags: BookMetadata(title: "Mind Over Markets", authors: ["James F. Dalton"]), in: inbox)

        await h.model.beginImport([untagged, companion, audio])
        let review = try #require(h.model.review)
        #expect(review.entries.count == 3)
        try expectTheOwnersPDFs(h, audiobook: audiobook)

        // The audiobook tagged without the edition word: surely the same book.
        let tagged = try entry(h, "Mind Over Markets")
        #expect(tagged.existingMatch?.id == audiobook)
        #expect(tagged.matchStrength == .sure)
        #expect(tagged.addToExisting)
        #expect(tagged.guessNotes == [])
        #expect(review.guessNote(of: tagged.id) == nil)
        #expect(review.question(of: tagged.id) == nil)

        #expect(review.questionsText == "1 book has a question to check.")
        #expect(review.countText == "3 of 3 books will be imported")
        #expect(review.canImport)
    }

    /// IH8, and the plan's first principle: left as offered, the doubtful PDF becomes a
    /// book of its own and the companion joins the audiobook as an extra.
    @Test func IH8_importingTheOwnersFilesAsOfferedJoinsOnlyWhatIsSure() async throws {
        let (h, audiobook) = try await ownersLibrary()
        let inbox = try makeTempDir()
        let untagged = try makeUntaggedPDF(Self.untaggedName, in: inbox)
        let companion = try makeCompanionPDF(in: inbox)
        await h.model.beginImport([untagged, companion])
        #expect(h.model.review?.entries.count == 2)

        await h.model.confirmImport()

        let store = try h.store()
        #expect(Set(try store.books().map(\.title)) == [Self.audiobookTitle, "Mind Over Markets: Power Tradin"])
        #expect(try store.files(bookId: audiobook).map(\.role) == [.audio, .extra])
        #expect(try store.files(bookId: audiobook).map(\.format) == [.m4b, .pdf])
        let own = try h.id("Mind Over Markets: Power Tradin")
        #expect(try h.book(own).authors == ["James F. Dalton"])
        #expect(try store.files(bookId: own).map(\.role) == [.ebook])
    }

    /// IH1, IH3: the owner's yes to the possible match adds the PDF to the audiobook, as its ebook.
    @Test func IH1_sayingYesToThePossibleMatchJoinsTheBook() async throws {
        let (h, audiobook) = try await ownersLibrary()
        let untagged = try makeUntaggedPDF(Self.untaggedName, in: try makeTempDir())
        await h.model.beginImport([untagged])
        let id = try entry(h, "Mind Over Markets: Power Tradin").id

        h.model.updateReview { $0.setAddToExisting(true, for: id) }
        await h.model.settle()
        let joined = try #require(h.model.review?.entry(id))
        #expect(joined.isAddedToExisting)
        #expect(joined.destination == (try h.book(audiobook).folderPath))
        #expect(h.model.review?.question(of: id) == nil)
        #expect(h.model.review?.questionsText == nil)

        await h.model.confirmImport()
        #expect(try h.store().books().count == 1)
        #expect(try h.store().files(bookId: audiobook).map(\.role) == [.audio, .ebook])
    }

    /// IH2: a file with a title and no author is offered the book of that title, off;
    /// once the owner types the author the match is sure and the switch goes on.
    @Test func IH2_typingTheAuthorMakesAPossibleMatchSure() async throws {
        let (h, audiobook) = try await ownersLibrary()
        // "Downloads" is a place, not an author.
        let downloads = try makeTempDir().appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let pdf = try makeUntaggedPDF("Mind Over Markets.pdf", in: downloads)
        await h.model.beginImport([pdf])
        let before = try entry(h, "Mind Over Markets")
        #expect(before.candidate.metadata.authors == [])
        #expect(before.existingMatch?.id == audiobook)
        #expect(before.matchStrength == .possible)
        #expect(!before.addToExisting)
        #expect(h.model.review?.guessNote(of: before.id) == "Read from the file name.")

        h.model.updateReview { $0.setText("James F. Dalton", for: .authors, of: before.id) }
        await h.model.settle()
        let sure = try #require(h.model.review?.entry(before.id))
        #expect(sure.existingMatch?.id == audiobook)
        #expect(sure.matchStrength == .sure)
        #expect(sure.addToExisting)
        #expect(sure.existingMatchText == "Add to the existing book \"Mind Over Markets (Unabridged)\"")
        #expect(h.model.review?.question(of: before.id) == nil)
        #expect(h.model.review?.guessNote(of: before.id) == nil)

        // Another author: no longer that book at all.
        h.model.updateReview { $0.setText("Somebody Else", for: .authors, of: before.id) }
        await h.model.settle()
        #expect(h.model.review?.entry(before.id)?.existingMatch == nil)
    }

    /// IH2: the owner's own setting of the switch is not undone when the same book is found again.
    @Test func IH2_aSwitchSetByHandIsKeptWhenTheSameBookIsFoundAgain() async throws {
        let (h, audiobook) = try await ownersLibrary()
        let downloads = try makeTempDir().appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let pdf = try makeUntaggedPDF("Mind Over Markets.pdf", in: downloads)
        await h.model.beginImport([pdf])
        let id = try entry(h, "Mind Over Markets").id

        // Looked at, and refused.
        h.model.updateReview { $0.setAddToExisting(true, for: id) }
        h.model.updateReview { $0.setAddToExisting(false, for: id) }
        h.model.updateReview { $0.setText("James F. Dalton", for: .authors, of: id) }
        await h.model.settle()
        let entry = try #require(h.model.review?.entry(id))
        #expect(entry.existingMatch?.id == audiobook)
        #expect(entry.matchStrength == .sure)
        #expect(!entry.addToExisting)
        #expect(entry.destination == "James F. Dalton/Mind Over Markets")
    }

    /// IH7: arrivals reviewed from the Inbox come with the same strengths, notes and guesses.
    @Test func IH7_arrivalsFromTheInboxAreGuessedAboutTheSameWay() async throws {
        let (h, audiobook) = try await ownersLibrary()
        let folder = try makeTempDir()
        await h.model.addWatchFolder(folder)
        await h.model.settle()
        let row = try #require(h.model.watchFolderRows.first)
        await h.model.setWatchFolder(row.id, includesPDFs: true)
        await h.model.settle()
        _ = try makeUntaggedPDF(Self.untaggedName, in: folder)
        _ = try makeCompanionPDF(in: folder)
        // The watcher reports; a settle interval later the second look is taken.
        h.watcher.fire()
        await h.model.settle()
        h.clock.now += 11
        #expect(h.ticker.run(delay: 11), "no check was scheduled 11 seconds on")
        await h.model.settle()
        #expect(h.model.inboxRows.count == 2)

        await h.model.reviewInbox(opening: Set(h.model.inboxRows.map(\.id)))
        let review = try #require(h.model.review)
        #expect(review.isFromInbox)
        #expect(review.entries.count == 2)
        try expectTheOwnersPDFs(h, audiobook: audiobook)
        #expect(review.questionsText == "1 book has a question to check.")
    }

    /// A22
    @Test func importingUntrackedFilesNeedsSome() async throws {
        let h = try await Harness.demo()
        h.recordBusyLabels()
        await h.model.importUntracked()
        #expect(h.busyLabels.isEmpty)
        #expect(h.model.review == nil)
    }

    // MARK: Two items of one import bound for the same folder

    /// An audiobook and its ebook that the scan kept apart, because one title carried a
    /// subtitle, are offered as one book once they would share a folder, and imported
    /// as one. Before, the second was refused only after the first had gone in.
    @Test func twoItemsBoundForOneFolderAreJoinedAsOneBook() async throws {
        let h = try await Harness.empty()
        let inbox = try Harness.inbox()
        let audio = inbox.appendingPathComponent("river audio.mp3")
        try MediaFixtures.makeSilentMP3(seconds: 2, id3v23Title: "Quiet Rivers: Forty Years on the Water").write(to: audio)

        await h.model.beginImport([quietRivers(inbox), audio])
        var review = try #require(h.model.review)
        // Two items: the titles differ by a subtitle, which the scan does not take to be one book.
        #expect(review.entries.count == 2)
        let spoken = try #require(review.entries.first { $0.candidate.hasAudio })
        let written = try #require(review.entries.first { !$0.candidate.hasAudio })
        #expect(review.joinableEarlier(of: spoken.id) == nil && review.joinableEarlier(of: written.id) == nil)
        #expect(review.items().count == 2)

        // Given the same title and author here, they are bound for one folder.
        let author = written.candidate.metadata.authors.joined(separator: "; ")
        h.model.updateReview {
            $0.setText("Quiet Rivers", for: .title, of: spoken.id)
            $0.setText(author, for: .authors, of: spoken.id)
        }
        await h.model.settle()
        review = try #require(h.model.review)
        let folders = Set(review.entries.compactMap(\.destination))
        #expect(folders.count == 1)
        // The later of the two is offered to join the earlier, and does so unless told otherwise.
        let later = try #require(review.entries.last)
        let earlier = try #require(review.entries.first)
        #expect(review.joinableEarlier(of: later.id)?.id == earlier.id && review.joinableEarlier(of: earlier.id) == nil)
        #expect(review.isJoinedToEarlier(later.id) && review.sameFolderProblem(of: later.id) == nil)
        let choice = try #require(review.joinEarlierChoice(of: later.id))
        #expect(choice.join == "Add to “Quiet Rivers” above, as one book" && choice.apart == ImportReview.separateBookTitle)
        #expect(review.joinEarlierNote(of: later.id)?.contains("one book") == true)
        // What is imported is one book with both files, the audio first.
        var items = review.items()
        #expect(items.count == 1 && items[0].candidate.files.map(\.role) == [.audio, .ebook])

        // Told to import it apart, it is its own item again, and the review says what that needs.
        h.model.updateReview { $0.setJoinsEarlier(false, for: later.id) }
        review = try #require(h.model.review)
        #expect(!review.isJoinedToEarlier(later.id) && review.items().count == 2)
        #expect(review.joinEarlierNote(of: later.id)?.contains("cannot share a folder") == true)
        h.model.updateReview { $0.setJoinsEarlier(true, for: later.id) }

        // Unticked, the earlier one is no book to join; ticked again, it is.
        func tick(_ on: Bool) {
            h.model.updateReview { review in
                if let index = review.entries.firstIndex(where: { $0.id == earlier.id }) { review.entries[index].included = on }
            }
        }
        tick(false)
        #expect(h.model.review?.joinableEarlier(of: later.id) == nil)
        tick(true)
        items = try #require(h.model.review).items()
        #expect(items.count == 1)

        await h.model.confirmImport()
        await h.model.settle()
        #expect(h.model.alert == nil)
        let store = try h.store()
        let books = try store.books().filter { $0.title == "Quiet Rivers" }
        #expect(books.count == 1)
        let files = try store.files(bookId: try #require(books.first?.id))
        #expect(Set(files.map(\.role)) == [.audio, .ebook] && files.count == 2)
    }

    /// Two audiobooks bound for one folder are not joined: the review says so before anything is imported.
    @Test func twoAudiobooksBoundForOneFolderAreSaidToClash() async throws {
        let h = try await Harness.empty()
        let inbox = try Harness.inbox()
        let one = inbox.appendingPathComponent("first.mp3")
        let two = inbox.appendingPathComponent("second.mp3")
        try MediaFixtures.makeSilentMP3(seconds: 2, id3v23Title: "Night Ferry").write(to: one)
        try MediaFixtures.makeSilentMP3(seconds: 3, id3v23Title: "Night Ferry: The Longer Cut").write(to: two)
        await h.model.beginImport([one, two])
        var review = try #require(h.model.review)
        #expect(review.entries.count == 2)
        for entry in review.entries {
            h.model.updateReview {
                $0.setText("Night Ferry", for: .title, of: entry.id)
                $0.setText("Ann Author", for: .authors, of: entry.id)
            }
        }
        await h.model.settle()
        review = try #require(h.model.review)
        let later = try #require(review.entries.last)
        #expect(review.earlierInSameFolder(as: later.id) != nil && review.joinableEarlier(of: later.id) == nil)
        #expect(!review.isJoinedToEarlier(later.id) && review.joinEarlierChoice(of: later.id) == nil)
        #expect(review.sameFolderProblem(of: later.id)?.contains("two books cannot share one") == true)
        #expect(review.items().count == 2)
    }
}
