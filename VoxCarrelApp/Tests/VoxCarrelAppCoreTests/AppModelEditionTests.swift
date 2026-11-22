import DemoContent
import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

    /// What a store lists: an edition of this title, saying whether it is abridged.
private func edition(
    _ title: String, author: String, key: String, narrators: [String] = [], seconds: Double?, abridged: Bool?
) -> LookupCandidate {
    var candidate = foundBook(.audible, key, title: title, authors: [author]) {
        $0.narrators = narrators
        $0.durationSeconds = seconds
    }
    candidate.edition = EditionFacts(format: .digital, abridged: abridged)
    return candidate
}

/// Abridged, unabridged or dramatised (plan 7, Task 5b). K8–K10. Every lookup here goes
/// to the harness's `FakeLookup`: nothing reaches the network.
@MainActor
@Suite struct AppModelEditionTests {
    private let byHand = EditionKindNote(kind: .abridged, basis: .setByHand)

    private func setKind(_ h: Harness, _ id: Int64, _ kind: EditionKindNote?) async throws {
        var book = try h.book(id)
        book.editionKind = kind
        try h.store().update(book)
        await h.model.reloadAll()
    }

    // MARK: K9 by hand, in the inspector

    @Test func K9_theChoicesAreTheThreeKindsAndNotKnown() {
        #expect(AppModel.editionKindChoices.map(\.title) == ["Unabridged", "Abridged", "Dramatised", "Not known"])
        #expect(AppModel.editionKindChoices.map(\.kind) == [.unabridged, .abridged, .dramatised, nil])
        #expect(Set(AppModel.editionKindChoices.map(\.id)).count == 4)
    }

    @Test func K9_aKindSetByHandIsSavedWithTheBookAndUndone() async throws {
        let h = try await Harness.demo()
        let id = try await h.select("Salt Road")
        let files = try h.fileURLs(id)
        let bytes = try files.map { try Data(contentsOf: $0) }
        #expect(h.model.showsEditionKind)
        #expect(h.model.inspectorEditionKind == nil)
        #expect(h.model.inspectorEditionLabel == nil)
        #expect(h.model.inspectorEditionHelp == nil)
        #expect(!h.model.editionKindIsAppOnly)
        #expect(!h.model.hasUnsavedChanges)

        h.model.setEditionKind(.abridged)
        #expect(h.model.inspectorEditionKind == .abridged)
        #expect(h.model.hasUnsavedChanges)
        // K9: marked as saved in the app only, because it was set by hand.
        #expect(h.model.editionKindIsAppOnly)
        #expect(h.model.inspectorEditionLabel == "Abridged")
        #expect(h.model.inspectorEditionHelp == "Set by you.")
        // Nothing is written before Save.
        #expect(try h.book(id).editionKind == nil)

        await h.model.save()
        #expect(try h.book(id).editionKind == byHand)
        #expect(!h.model.hasUnsavedChanges)
        #expect(h.model.inspectorEditionKind == .abridged)
        #expect(h.model.rows.first { $0.id == id }?.editionLabel == "Abridged")
        // K9: in the catalogue only: no file was written.
        #expect(try files.map { try Data(contentsOf: $0) } == bytes)
        #expect(h.model.undoLabel == "Edit Salt Road")

        await h.model.undo()
        #expect(try h.book(id).editionKind == nil)
        #expect(h.model.inspectorEditionKind == nil)
    }

    @Test func K9_notKnownClearsItAndChoosingTheSameAgainChangesNothing() async throws {
        let h = try await Harness.demo()
        let id = try await h.select("Salt Road")
        try await setKind(h, id, byHand)
        #expect(h.model.inspectorEditionKind == .abridged)

        h.model.setEditionKind(.abridged)
        #expect(!h.model.hasUnsavedChanges)
        h.model.setEditionKind(.dramatised)
        #expect(h.model.hasUnsavedChanges)
        // Back to what the book has: not an edit.
        h.model.setEditionKind(.abridged)
        #expect(!h.model.hasUnsavedChanges)

        // "Not known" is the user's word too: it is kept, shows nothing, and nothing
        // worked out afterwards takes its place.
        h.model.setEditionKind(nil)
        #expect(h.model.inspectorEditionKind == nil)
        #expect(h.model.inspectorEditionLabel == nil)
        #expect(!h.model.editionKindIsAppOnly)
        #expect(h.model.hasUnsavedChanges)
        await h.model.save()
        #expect(try h.book(id).editionKind == .notKnownByHand)
        #expect(h.model.rows.first { $0.id == id }?.editionLabel == nil)
        #expect(h.model.inspectorEditionKind == nil)
        // Chosen again: nothing to save.
        h.model.setEditionKind(nil)
        #expect(!h.model.hasUnsavedChanges)

        // Check Edition asks nothing about it and leaves it.
        let seconds = try #require(try h.book(id).durationSeconds)
        let same = edition("Salt Road", author: "Ines Calloway", key: "uk:B0SALTROAD", narrators: ["Marcus Lindqvist"], seconds: seconds, abridged: true)
        h.lookup.find(.audible, [same])
        let asked = h.lookup.asked.count
        await h.model.checkEdition()
        #expect(h.lookup.asked.count == asked)
        #expect(try h.book(id).editionKind == .notKnownByHand)

        // Look Up offers what it finds, but does not tick it.
        h.model.alert = nil
        h.model.beginLookup()
        await h.model.settle()
        #expect(h.model.lookup?.editionOffer?.found == "Abridged")
        #expect(h.model.lookup?.editionOffer?.ticked == false)
        h.model.cancelLookup()

        // A book nothing was ever known of has no kind to keep unknown.
        try await setKind(h, id, nil)
        h.model.setEditionKind(.abridged)
        h.model.setEditionKind(nil)
        #expect(!h.model.hasUnsavedChanges)
    }

    // MARK: Sources that do not answer

    /// A book for which a source did not answer is not written: the rest is only part
    /// of the evidence. The summary says how many were passed over, and why.
    @Test func checkingWritesNothingForABookASourceDidNotAnswerFor() async throws {
        let h = try await Harness.demo()
        let salt = try h.id("Salt Road")
        let keeper = try h.id("The Lighthouse Keeper")
        let seconds = try #require(try h.book(salt).durationSeconds)
        let keeperSeconds = try #require(try h.book(keeper).durationSeconds)
        h.lookup.search(.audible) { query in
            if query.title == "Salt Road" { throw LookupError.refused(status: 503) }
            return [edition("The Lighthouse Keeper", author: "Eleanor Marsh", key: "uk:B0LIGHTHSE", seconds: keeperSeconds, abridged: true)]
        }
        // Open Library answers for both, and by itself would have Salt Road "probably unabridged".
        h.lookup.search(.openLibrary) { query in
            guard query.title == "Salt Road" else { return [] }
            return [foundBook(.openLibrary, "/works/OL1W", title: "Salt Road", authors: ["Ines Calloway"]) {
                $0.pageCount = Int(seconds / 3600 * 34)
            }]
        }
        try await h.select(["Salt Road", "The Lighthouse Keeper"])
        await h.model.checkEdition()
        #expect(try h.book(salt).editionKind == nil)
        #expect(try h.book(keeper).editionKind?.kind == .abridged)
        #expect(h.model.alert == "“Salt Road” was skipped because Audible could not be reached.")
        #expect(h.model.undoLabel == "Check edition of The Lighthouse Keeper")

        // Both passed over, for different sources.
        await h.model.undo()
        h.model.alert = nil
        h.lookup.search(.openLibrary) { query in
            if query.title != "Salt Road" { throw LookupError.notReachable }
            return []
        }
        await h.model.checkEdition()
        #expect(try h.book(keeper).editionKind == nil)
        #expect(h.model.alert == "2 books were skipped because Open Library and Audible could not be reached.")
    }

    /// With no source to be reached at all, the lookups are given up at the first
    /// book and it is said plainly.
    @Test func checkingOfflineSaysSoAndAsksNoFurther() async throws {
        let h = try await Harness.demo()
        h.lookup.fail(.audible, .notReachable)
        h.lookup.fail(.openLibrary, .notReachable)
        let before = h.model.undoLabel
        try await h.select(["Salt Road", "The Lighthouse Keeper"])
        await h.model.checkEdition()
        // Asked once of each source, for the first book only.
        #expect(h.lookup.asked.count == 2)
        #expect(h.model.alert == "No lookup source could be reached. 2 books were skipped.")
        #expect(h.model.undoLabel == before)
        #expect(try h.book(try h.id("Salt Road")).editionKind == nil)

        h.model.alert = nil
        try await h.select("Salt Road")
        await h.model.checkEdition()
        #expect(h.model.alert == "No lookup source could be reached.")
    }

    /// Only a kind that is well founded is held against a result when a book is checked.
    @Test func aGuessedKindIsNotHeldAgainstAResult() async throws {
        let h = try await Harness.demo()
        let id = try await h.select("Salt Road")
        let seconds = try #require(try h.book(id).durationSeconds)
        // Guessed unabridged from its length; the result that is this very edition says abridged.
        try await setKind(h, id, EditionKindNote(kind: .unabridged, basis: .inferred))
        h.lookup.find(.audible, [edition("Salt Road", author: "Ines Calloway", key: "uk:B0SALTROAD", narrators: ["Marcus Lindqvist"], seconds: seconds, abridged: true)])
        h.model.beginLookup()
        await h.model.settle()
        let found = try #require(h.model.lookup?.candidates.first)
        #expect(h.model.lookup?.bookContext?.isAbridged == nil)
        #expect(h.model.lookupBadgeText(for: found) == "Your edition")
        h.model.cancelLookup()

        // Said by the user, it is held against it.
        try await setKind(h, id, EditionKindNote(kind: .unabridged, basis: .setByHand))
        h.model.beginLookup()
        await h.model.settle()
        #expect(h.model.lookupBadgeText(for: found) == "Different edition")
    }

    /// K9: a kind that was worked out is not marked; confirming it by hand makes it the user's.
    @Test func K9_onlyAKindSetByHandIsMarkedAppOnly() async throws {
        let h = try await Harness.demo()
        let id = try await h.select("Salt Road")
        let inferred = EditionKindNote(kind: .abridged, basis: .inferred, reason: "3h 12m; unabridged editions run about 18h.")
        try await setKind(h, id, inferred)
        #expect(h.model.inspectorEditionKind == .abridged)
        #expect(!h.model.editionKindIsAppOnly)
        #expect(h.model.appOnlyMarkers.isEmpty)
        #expect(h.model.inspectorEditionHelp == "3h 12m; unabridged editions run about 18h. Worked out from its running time.")

        h.model.setEditionKind(.abridged)
        #expect(h.model.hasUnsavedChanges)
        #expect(h.model.editionKindIsAppOnly)
        await h.model.save()
        #expect(try h.book(id).editionKind == byHand)
        // The fields the files cannot hold are a different list, and this is not in it.
        #expect(try h.book(id).appOnlyFields == [])
    }

    @Test func K9_theDraftCarriesTheChoiceThroughAReload() async throws {
        let h = try await Harness.demo()
        let id = try await h.select("Salt Road")
        h.model.setEditionKind(.dramatised)
        // The book changes underneath: the choice is kept as an unsaved edit.
        await h.model.setReadStatus(.finished, for: [id])
        #expect(h.model.inspectorEditionKind == .dramatised)
        #expect(h.model.hasUnsavedChanges)
        h.model.discardChanges()
        #expect(h.model.inspectorEditionKind == nil)

        let draft = BookDraft(book: try h.book(id))
        #expect(draft.makeEdit()?.editionKind == nil)
        var changed = draft
        changed.chooseEditionKind(.unabridged)
        #expect(changed.isDirty)
        #expect(changed.makeEdit()?.editionKind == EditionKindNote(kind: .unabridged, basis: .setByHand))
        #expect(changed.reapplied(onto: try h.book(id)).editionKind?.kind == .unabridged)
        #expect(changed.reapplied(changedSince: draft, onto: try h.book(id)).editionKind?.kind == .unabridged)
        #expect(draft.reapplied(changedSince: draft, onto: try h.book(id)).editionKind == nil)
    }

    @Test func K9_anEbookHasNoEditionControl() async throws {
        let h = try await Harness.demo()
        try await h.select("Quiet Rivers")
        #expect(!h.model.showsEditionKind)
        try await h.select(["Quiet Rivers", "Salt Road"])
        #expect(!h.model.showsEditionKind)
        #expect(h.model.inspectorEditionKind == nil)
    }

    // MARK: K10 the label

    @Test(arguments: [
        (EditionKindNote(kind: .abridged, basis: .stated("the file's tags"), reason: "The title says “Abridged”."),
         "Abridged", "The title says “Abridged”."),
        (EditionKindNote(kind: .abridged, basis: .stated("the file's name"), reason: nil), "Abridged", "The file’s name says so."),
        (EditionKindNote(kind: .abridged, basis: .matched("Audible"), reason: "Audible lists your edition as abridged."),
         "Abridged", "Audible lists your edition as abridged. Matched with a result from Audible."),
        (EditionKindNote(kind: .abridged, basis: .inferred, reason: "3h 12m; unabridged editions run about 18h."),
         "Abridged", "3h 12m; unabridged editions run about 18h. Worked out from its running time."),
        (EditionKindNote(kind: .abridged, basis: .estimated, reason: "3h 0m; a book of 612 pages probably runs about 18h unabridged."),
         "Probably abridged", "3h 0m; a book of 612 pages probably runs about 18h unabridged. Estimated from the length of the printed book."),
        (EditionKindNote(kind: .dramatised, basis: .inferred, reason: nil), "Dramatised", "Worked out from its running time."),
        (EditionKindNote(kind: .dramatised, basis: .setByHand), "Dramatised", "Set by you."),
        (EditionKindNote(kind: .unabridged, basis: .stated("the file's tags"), reason: nil), "Unabridged", "The file’s tags say so."),
        (EditionKindNote(kind: .unabridged, basis: .setByHand), "Unabridged", "Set by you."),
    ])
    func K10_theLabelAndItsTooltip(note: EditionKindNote, label: String, help: String) {
        #expect(note.label == label)
        #expect(note.helpText == help)
        var book = Book(metadata: BookMetadata(title: "A Perfect Spy"))
        book.editionKind = note
        let row = BookRow(id: 1, book: book, hasAudio: true, hasEbook: false, formats: [.m4b], coverURL: nil, hasWriteProblem: false)
        #expect(row.editionLabel == label)
        #expect(row.editionHelpText == help)
        // Where only a symbol stands for the label, the tooltip says the label too.
        #expect(row.editionBadgeHelpText == "\(label). \(help)")
        #expect(row.summaryText.contains(label))
    }

    /// K10: an unabridged book carries no label unless its files, or the user, say so.
    @Test(arguments: [
        EditionKindNote(kind: .unabridged, basis: .matched("Audible"), reason: "Audible lists your edition as unabridged."),
        EditionKindNote(kind: .unabridged, basis: .inferred, reason: "18h 0m; the unabridged edition runs 19h 59m."),
        EditionKindNote(kind: .unabridged, basis: .estimated, reason: nil),
    ])
    func K10_nothingIsShownForAnUnabridgedBookThatDoesNotSaySo(note: EditionKindNote) {
        #expect(note.label == nil)
        var book = Book(metadata: BookMetadata(title: "A Perfect Spy"))
        book.editionKind = note
        let row = BookRow(id: 1, book: book, hasAudio: true, hasEbook: false, formats: [.m4b], coverURL: nil, hasWriteProblem: false)
        #expect(row.editionLabel == nil)
        #expect(row.editionHelpText == nil)
        #expect(row.editionBadgeHelpText == nil)
        #expect(note.title == (note.isProbable ? "Probably unabridged" : "Unabridged"))
    }

    @Test func K10_aBookWithNoKindHasNoLabel() async throws {
        let h = try await Harness.demo()
        let row = try #require(h.model.rows.first { $0.book.title == "Salt Road" })
        #expect(row.editionLabel == nil)
        #expect(row.editionHelpText == nil)
    }

    /// K2: a demo book whose file is named "(Unabridged)" was read at import.
    @Test func K2_K10_theFilesNameWasReadAtImport() async throws {
        let h = try await Harness.demo()
        let row = try #require(h.model.rows.first { $0.book.title == "The Clockmaker's Apprentice" })
        #expect(row.book.editionKind == EditionKindNote(
            kind: .unabridged, basis: .stated("the file's name"), reason: "A file or folder name says “Unabridged”."))
        #expect(row.editionLabel == "Unabridged")
        #expect(row.editionHelpText == "A file or folder name says “Unabridged”.")
    }

    @Test func K10_sortingByEdition() {
        func row(_ id: Int64, _ title: String, _ kind: EditionKind?) -> BookRow {
            var book = Book(metadata: BookMetadata(title: title))
            book.editionKind = kind.map { EditionKindNote(kind: $0, basis: .inferred) }
            return BookRow(id: id, book: book, hasAudio: true, hasEbook: false, formats: [.m4b], coverURL: nil, hasWriteProblem: false)
        }
        let rows = [row(1, "D", nil), row(2, "C", .dramatised), row(3, "B", .abridged), row(4, "A", .unabridged), row(5, "E", .abridged)]
        #expect(BookSortKey.allCases.contains(.edition))
        #expect(BookSort(key: .edition).sorted(rows).map(\.id) == [4, 3, 5, 2, 1])
        // Descending reverses it, but a book whose edition is not known still comes last.
        #expect(BookSort(key: .edition, ascending: false).sorted(rows).map(\.id) == [2, 5, 3, 4, 1])
        // The table knows its column again.
        let sort = BookSort(key: .edition, ascending: false)
        #expect(BookSort(tableSortOrder: sort.tableSortOrder) == sort)
        #expect(rows.map(\.editionSortKey) == ["", "dramatised", "abridged", "unabridged", "abridged"])
    }

    // MARK: K8 Check Edition

    @Test func K8_whenItCanBeDone() async throws {
        let h = try await Harness.demo()
        #expect(h.model.checkEditionTitle == "Check Edition")
        #expect(!h.model.checkEditionHelp.isEmpty)
        #expect(!h.model.canCheckEdition)
        try await h.select("Quiet Rivers")
        // An ebook has no edition to check.
        #expect(!h.model.canCheckEdition)
        let ids = try await h.select(["Quiet Rivers", "Salt Road"])
        #expect(h.model.canCheckEdition)
        #expect(h.model.canCheckEdition(for: ids))
        #expect(!h.model.canCheckEdition(for: []))
        h.model.busyLabel = "Busy…"
        #expect(!h.model.canCheckEdition)
        h.model.busyLabel = nil
        // Nothing happens for books that cannot be checked.
        await h.model.checkEdition(for: try h.ids(["Quiet Rivers"]))
        #expect(h.lookup.asked.isEmpty)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
    }

    /// K8: one lookup for each book, one after another, with progress; one operation
    /// that changes only the kind; one Undo.
    @Test func K8_checkingASelectionLooksEachBookUpAndIsOneUndo() async throws {
        let h = try await Harness.demo()
        let salt = try h.id("Salt Road")
        let keeper = try h.id("The Lighthouse Keeper")
        let rivers = try h.id("Quiet Rivers")
        let before = try [salt, keeper, rivers].map { try h.book($0) }
        let filesBefore = try [salt, keeper].flatMap { try h.fileURLs($0) }
        let bytesBefore = try filesBefore.map { try Data(contentsOf: $0) }
        let saltSeconds = try #require(before[0].durationSeconds)

        // What the busy label said while each source was being asked.
        let labels = Labels()
        let model = h.model
        h.lookup.search(.audible) { query in
            await labels.note(await MainActor.run { model.busyLabel })
            switch query.title {
            case "Salt Road":
                // This very edition, by its reader and its length, and it says it is abridged.
                return [edition("Salt Road", author: "Ines Calloway", key: "uk:B0SALTROAD", narrators: ["Marcus Lindqvist"], seconds: saltSeconds, abridged: true)]
            case "The Lighthouse Keeper":
                // Read by someone else and twenty hours long: the book is far shorter.
                return [edition("The Lighthouse Keeper", author: "Eleanor Marsh", key: "uk:B0LIGHTHSE", narrators: ["Another Reader"], seconds: 72_000, abridged: false)]
            default:
                return []
            }
        }
        try await h.select(["Salt Road", "The Lighthouse Keeper", "Quiet Rivers"])
        h.recordBusyLabels()
        #expect(!h.model.isCheckingEdition)

        await h.model.checkEdition()

        // One lookup for each audiobook, in the rows' order, each asking every source; the ebook is passed over.
        let order = h.model.rows.filter { [salt, keeper].contains($0.id) }.map(\.book.title)
        #expect(h.lookup.asked.filter { $0.source == .audible }.map(\.query.title) == order)
        #expect(h.lookup.asked.count == 4)
        let saltQuery = try #require(h.lookup.asked.first { $0.query.title == "Salt Road" }?.query)
        #expect(saltQuery == LookupQuery(title: "Salt Road", author: "Ines Calloway", narrator: "Marcus Lindqvist", wantsAudioEditions: true))
        // Progress.
        #expect(h.busyLabels == ["Checking 1 of 2…"])
        #expect(await labels.all == ["Checking 1 of 2…", "Checking 2 of 2…"])
        #expect(h.model.busyLabel == nil)
        #expect(!h.model.isCheckingEdition)

        // Only the kind changed, and only in the catalogue.
        var expected = before
        expected[0].editionKind = EditionKindNote(kind: .abridged, basis: .matched("Audible"), reason: "Audible lists your edition as abridged.")
        let keeperKind = try #require(try h.book(keeper).editionKind)
        #expect(keeperKind.kind == .abridged)
        #expect(keeperKind.basis == .inferred)
        expected[1].editionKind = keeperKind
        #expect(try [salt, keeper, rivers].map { try h.book($0) } == expected)
        #expect(try filesBefore.map { try Data(contentsOf: $0) } == bytesBefore)
        #expect(h.model.rows.first { $0.id == salt }?.editionLabel == "Abridged")
        #expect(h.model.alert == nil)

        // One operation, undone whole.
        #expect(h.model.undoLabel == "Check edition of 2 books")
        await h.model.undo()
        #expect(try [salt, keeper, rivers].map { try h.book($0) } == before)
        #expect(try filesBefore.map { try Data(contentsOf: $0) } == bytesBefore)
    }

    /// K8, K1: a kind set by hand is never overwritten, and nothing is asked about it.
    @Test func K8_aKindSetByHandIsNeverOverwritten() async throws {
        let h = try await Harness.demo()
        let id = try h.id("Salt Road")
        try await setKind(h, id, EditionKindNote(kind: .unabridged, basis: .setByHand))
        let seconds = try #require(try h.book(id).durationSeconds)
        h.lookup.find(.audible, [edition("Salt Road", author: "Ines Calloway", key: "uk:B0SALTROAD", narrators: ["Marcus Lindqvist"], seconds: seconds, abridged: true)])
        try await h.select("Salt Road")
        let labelBefore = h.model.undoLabel

        await h.model.checkEdition()
        #expect(try h.book(id).editionKind == EditionKindNote(kind: .unabridged, basis: .setByHand))
        #expect(h.lookup.asked.isEmpty)
        #expect(h.model.undoLabel == labelBefore)
        #expect(h.model.alert == nil)
    }

    /// K8: cancelling stops the lookups and writes nothing at all.
    @Test func K8_cancellingWritesNothing() async throws {
        let h = try await Harness.demo()
        let salt = try h.id("Salt Road")
        let seconds = try #require(try h.book(salt).durationSeconds)
        let gate = Gate()
        h.lookup.hold(.audible, at: gate, then: [
            edition("Salt Road", author: "Ines Calloway", key: "uk:B0SALTROAD", narrators: ["Marcus Lindqvist"], seconds: seconds, abridged: true),
        ])
        try await h.select(["Salt Road", "The Lighthouse Keeper"])
        let labelBefore = h.model.undoLabel

        let check = Task { await h.model.checkEdition() }
        await gate.arrival()
        #expect(h.model.isCheckingEdition)
        #expect(h.model.busyLabel == "Checking 1 of 2…")
        // Nothing else can begin meanwhile.
        #expect(!h.model.canCheckEdition)
        #expect(!h.model.canLookUp)

        h.model.cancelEditionCheck()
        await gate.release()
        await check.value

        #expect(!h.model.isCheckingEdition)
        #expect(h.model.busyLabel == nil)
        #expect(try h.book(salt).editionKind == nil)
        #expect(h.model.undoLabel == labelBefore)
        #expect(h.model.alert == nil)
        // The second book was never asked about.
        #expect(Set(h.lookup.asked.map(\.query.title)).count == 1)
        // Cancelling when nothing runs does nothing.
        h.model.cancelEditionCheck()
        #expect(h.model.canCheckEdition)
    }

    /// K8: the progress sheet offers Cancel while books are being looked up, and at no
    /// other time; its Cancel stops the check.
    @Test func K8_theProgressSheetCancelsACheck() async throws {
        let h = try await Harness.demo()
        let salt = try h.id("Salt Road")
        let seconds = try #require(try h.book(salt).durationSeconds)
        let gate = Gate()
        h.lookup.hold(.audible, at: gate, then: [
            edition("Salt Road", author: "Ines Calloway", key: "uk:B0SALTROAD", narrators: ["Marcus Lindqvist"], seconds: seconds, abridged: true),
        ])
        try await h.select(["Salt Road", "The Lighthouse Keeper"])
        #expect(h.model.progressCancelTitle == nil)
        // Nothing is running: there is nothing to cancel.
        h.model.cancelProgress()

        let check = Task { await h.model.checkEdition() }
        await gate.arrival()
        #expect(h.model.progressSheetLabel == "Checking 1 of 2…")
        #expect(h.model.progressCancelTitle == "Cancel")

        h.model.cancelProgress()
        await gate.release()
        await check.value

        #expect(h.model.progressCancelTitle == nil)
        #expect(h.model.busyLabel == nil)
        #expect(try h.book(salt).editionKind == nil)
        #expect(Set(h.lookup.asked.map(\.query.title)).count == 1)
    }

    /// Work that cannot be stopped offers no Cancel.
    @Test func K8_otherWorkOffersNoCancel() async throws {
        let h = try await Harness.demo()
        h.model.busyLabel = "Updating…"
        #expect(h.model.progressSheetLabel == "Updating…")
        #expect(h.model.progressCancelTitle == nil)
        h.model.busyLabel = nil
    }

    @Test func K8_whatIsSaidWhenAnEditionIsStillNotKnown() async throws {
        let h = try await Harness.demo()
        let id = try await h.select("Salt Road")
        await h.model.checkEdition()
        #expect(h.model.alert == "The edition of “Salt Road” could not be worked out.")
        #expect(try h.book(id).editionKind == nil)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)

        let titles: [Int64: String] = [1: "One", 2: "Two"]
        let known = EditionKindNote(kind: .abridged, basis: .inferred)
        #expect(AppModel.editionCheckSummary([EditionCheckOutcome(bookId: 1, kind: known, changed: true)], titles: titles) == nil)
        #expect(AppModel.editionCheckSummary([EditionCheckOutcome(bookId: 1, kind: known, changed: false)], titles: titles) == nil)
        #expect(AppModel.editionCheckSummary(
            [EditionCheckOutcome(bookId: 1, kind: nil, changed: false, remark: "Parts appear to be missing, so the length does not show whether it is abridged.")],
            titles: titles) == "The edition of “One” could not be worked out. Parts appear to be missing, so the length does not show whether it is abridged.")
        #expect(AppModel.editionCheckSummary(
            [EditionCheckOutcome(bookId: 1, kind: known, changed: true), EditionCheckOutcome(bookId: 2, kind: nil, changed: false)],
            titles: titles) == "The edition of 1 of 2 books could not be worked out.")
        #expect(AppModel.editionCheckSummary(
            [EditionCheckOutcome(bookId: 1, kind: nil, changed: false), EditionCheckOutcome(bookId: 2, kind: nil, changed: false)],
            titles: titles) == "The edition of these 2 books could not be worked out.")
        #expect(AppModel.editionCheckSummary([], titles: titles) == nil)
    }

    /// K8: unsaved edits are kept through a check.
    @Test func K8_unsavedEditsAreKept() async throws {
        let h = try await Harness.demo()
        let id = try await h.edit("Salt Road", newTitle: "Salt Roads")
        let seconds = try #require(try h.book(id).durationSeconds)
        h.lookup.find(.audible, [edition("Salt Road", author: "Ines Calloway", key: "uk:B0SALTROAD", narrators: ["Marcus Lindqvist"], seconds: seconds, abridged: true)])
        await h.model.checkEdition()
        #expect(try h.book(id).editionKind?.kind == .abridged)
        #expect(try h.book(id).title == "Salt Road")
        #expect(h.draft?.title == "Salt Roads")
        #expect(h.draft?.editionKind?.kind == .abridged)
        #expect(h.model.hasUnsavedChanges)
    }
}

/// Collects what was seen, in order.
private actor Labels {
    private(set) var all: [String] = []

    func note(_ label: String?) {
        all.append(label ?? "")
    }
}
