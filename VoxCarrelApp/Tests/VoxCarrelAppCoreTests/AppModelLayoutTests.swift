import Foundation
import Testing
import VoxCarrelFixtures

@testable import VoxCarrelAppCore
@testable import VoxCarrelCore

/// Everything in a folder, by path from it, leaving out the catalogue's own files.
func layoutTree(_ root: URL) -> [String] {
    ((FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String]) ?? [])
        .filter { !$0.hasPrefix(LibraryStore.databaseFileName) }
        .sorted()
}

/// The folder layout setting and its preview in the app model (folder layout plan,
/// Task 4). FL1–FL10, and FL14.
@MainActor
@Suite struct AppModelLayoutTests {
    static let authorTitle = "Author / Title"
    static let standardName = "Author / Series / Title"
    static let kindName = "Kind / Author / Series / Title"
    static let narratorPattern = "{Narrator}/{Title}"

    /// A demo library whose model has the "Author / Title" preset chosen and previewed:
    /// it moves the three books of the one series.
    private func previewed() async throws -> Harness {
        let h = try await Harness.demo()
        h.model.chooseLayout(Self.authorTitle)
        await h.model.previewLayoutChange()
        return h
    }

    // MARK: FL1 The choices

    @Test func fl1_aLibraryOnTheStandardLayoutHasItsPresetChosen() async throws {
        let h = try await Harness.demo()
        #expect(h.model.layoutChoices == LayoutText.choices)
        #expect(h.model.layoutChoices.map(\.name).last == "Custom")
        #expect(h.model.layoutChoiceId == Self.standardName)
        #expect(!h.model.layoutIsCustom)
        #expect(h.model.layoutDraftText == "{Author}/[{Series}/][{Number} - ]{Title}")
    }

    @Test func fl1_aLibraryOnAnotherPresetHasThatOneChosen() async throws {
        let h = try await Harness.demo(start: false)
        // Token names in other capitals are the same pattern.
        try h.store().setFolderPatternText("{author}/{title}")
        await h.model.start()
        #expect(h.model.layoutChoiceId == Self.authorTitle)
        #expect(h.model.layoutDraftText == "{author}/{title}")
    }

    @Test func fl1_aLibraryOnNoPresetHasCustomChosenWithItsPatternInTheDraft() async throws {
        let h = try await Harness.demo(start: false)
        try h.store().setFolderPatternText(Self.narratorPattern)
        await h.model.start()
        #expect(h.model.layoutChoiceId == LayoutText.customId)
        #expect(h.model.layoutIsCustom)
        #expect(h.model.layoutDraftText == Self.narratorPattern)
    }

    @Test func fl1_choosingAPresetFillsTheDraftAndChoosingCustomKeepsIt() async throws {
        let h = try await Harness.demo()
        h.model.chooseLayout(Self.kindName)
        #expect(h.model.layoutChoiceId == Self.kindName)
        #expect(h.model.layoutDraftText == "{Kind}/{Author}/[{Series}/][{Number} - ]{Title}")

        // Custom starts from what was there, and stays chosen whatever is typed.
        h.model.chooseLayout(LayoutText.customId)
        #expect(h.model.layoutChoiceId == LayoutText.customId)
        #expect(h.model.layoutDraftText == "{Kind}/{Author}/[{Series}/][{Number} - ]{Title}")
        h.model.layoutDraftText = "{Author}/{Title}"
        #expect(h.model.layoutChoiceId == LayoutText.customId)
        h.model.layoutDraftText = "{Author}/{Tit"
        #expect(h.model.layoutChoiceId == LayoutText.customId)
        #expect(h.model.layoutDraftText == "{Author}/{Tit")

        h.model.chooseLayout(Self.authorTitle)
        #expect(h.model.layoutChoiceId == Self.authorTitle)
        #expect(h.model.layoutDraftText == "{Author}/{Title}")
        // A choice that does not exist changes nothing.
        h.model.chooseLayout("no such layout")
        #expect(h.model.layoutChoiceId == Self.authorTitle)
        #expect(h.model.layoutDraftText == "{Author}/{Title}")
    }

    // MARK: FL2 What is wrong with the draft

    @Test func fl2_theProblemWithTheDraftIsSaidInWords() async throws {
        let h = try await Harness.demo()
        #expect(h.model.layoutProblemText == nil)
        h.model.chooseLayout(LayoutText.customId)
        h.model.layoutDraftText = "{Auther}/{Title}"
        #expect(h.model.layoutProblemText == "{Auther} is not something a folder can be named after.")
        h.model.layoutDraftText = "{Author}/{Series}"
        #expect(h.model.layoutProblemText == "The last folder must include {Title}.")
        h.model.layoutDraftText = ""
        #expect(h.model.layoutProblemText == "Type a layout, such as {Author}/{Title}.")
        h.model.layoutDraftText = "{Author}/{Title}"
        #expect(h.model.layoutProblemText == nil)
    }

    @Test func fl2_theTokensAreListedForTheHelpLine() async throws {
        let h = try await Harness.demo()
        #expect(h.model.layoutTokensText
            == "{Author} {Series} {Number} {Title} {Narrator} {Year} {Genre} {Publisher} {Language} {Kind}")
        #expect(h.model.layoutBracketsText.contains("[square brackets]"))
        #expect(h.model.layoutBracketsText.contains("|"))
    }

    // MARK: FL3 The example

    @Test func fl3_withNothingSelectedTheExampleIsTheFirstBookThatHasASeries() async throws {
        let h = try await Harness.demo()
        #expect(h.model.selection.isEmpty)
        #expect(h.model.layoutExampleText == "Ines Calloway/Tidewater Chronicles/3 - Harbour of Glass")
        h.model.chooseLayout(Self.authorTitle)
        #expect(h.model.layoutExampleText == "Ines Calloway/Harbour of Glass")
        h.model.chooseLayout(Self.kindName)
        #expect(h.model.layoutExampleText == "Audiobooks/Ines Calloway/Tidewater Chronicles/3 - Harbour of Glass")
    }

    @Test func fl3_theExampleIsTheSelectedBookWhenOneIsSelected() async throws {
        let h = try await Harness.demo()
        try await h.select("Quiet Rivers")
        #expect(h.model.layoutExampleText == "Amara Okafor/Quiet Rivers")
        h.model.chooseLayout(Self.kindName)
        #expect(h.model.layoutExampleText == "Ebooks/Amara Okafor/Quiet Rivers")
        h.model.chooseLayout(LayoutText.customId)
        h.model.layoutDraftText = Self.narratorPattern
        #expect(h.model.layoutExampleText == "This book could not be filed: no narrator.")
        // A draft that cannot be used has no example.
        h.model.layoutDraftText = "{Narrator}/{Titel}"
        #expect(h.model.layoutExampleText == nil)

        try await h.select("The Lighthouse Keeper")
        h.model.layoutDraftText = "{Kind}/{Narrator}/{Title}"
        #expect(h.model.layoutExampleText == "Audiobooks/Tom Hale/The Lighthouse Keeper")
        // Several selected books are no one book: the library's own example again.
        try await h.select(["Quiet Rivers", "The Lighthouse Keeper"])
        #expect(h.model.layoutExampleText == "Audiobooks/Marcus Lindqvist/Harbour of Glass")
    }

    /// FL3, FL5, FL6: the example, the preview and the change itself agree: every book
    /// the change moves ends up in the folder its example named, and the preview's
    /// moves are among them.
    @Test func fl3_theExampleIsWhereThePreviewAndTheChangePutTheBook() async throws {
        let h = try await Harness.demo()
        h.model.chooseLayout(Self.kindName)
        var examples: [Int64: String] = [:]
        var foldersBefore: [Int64: String] = [:]
        for row in h.model.rows where row.hasFiles {
            h.model.click(row.id, modifiers: [])
            await h.model.settle()
            examples[row.id] = h.model.layoutExampleText
            foldersBefore[row.id] = try h.book(row.id).folderPath
        }
        h.model.select([])
        await h.model.settle()

        await h.model.previewLayoutChange()
        let preview = try #require(h.model.layoutPreview)
        await h.model.applyLayoutChange()

        var moved: [String: String] = [:]
        for (id, before) in foldersBefore {
            let after = try #require(try h.book(id).folderPath)
            guard after != before else { continue }
            moved[before] = after
            #expect(after == examples[id])
        }
        #expect(moved.count > 3)
        #expect(!preview.examples.isEmpty)
        for example in preview.examples {
            #expect(moved[example.from] == example.to)
        }
        #expect(preview.heading == "\(moved.count) books will move")
    }

    @Test func fl3_aLibraryWithNoSeriesIsShownTheBuiltInSample() async throws {
        let h = try await Harness.empty()
        #expect(h.model.layoutExampleText == "Tom Clancy/Jack Ryan/3 - Red Rabbit")
        await h.model.beginImport([try Harness.inbox().appendingPathComponent("Quiet Rivers.epub")])
        await h.model.confirmImport()
        // The book just imported is selected, and is the example.
        #expect(h.model.layoutExampleText == "Amara Okafor/Quiet Rivers")
        h.model.select([])
        await h.model.settle()
        #expect(h.model.layoutExampleText == "Tom Clancy/Jack Ryan/3 - Red Rabbit")
    }

    @Test func fl3_theExampleNeverLooksAtTheDisk() async throws {
        let h = try await Harness.demo()
        // The library folder is gone: the example is worked out all the same, and as
        // the pattern spells it, not as a folder on the disk is spelled.
        try FileManager.default.removeItem(at: h.root)
        h.model.chooseLayout(LayoutText.customId)
        h.model.layoutDraftText = "{Narrator}/{Author} - {Title}"
        #expect(h.model.layoutExampleText == "Marcus Lindqvist/Ines Calloway - Harbour of Glass")
    }

    // MARK: FL4 Whether the layout can be changed

    @Test func fl4_theLayoutCanBeChangedWhenTheDraftIsAnotherUsablePattern() async throws {
        let h = try await Harness.demo()
        // The draft is the library's own pattern: that can be previewed too, to re-file
        // books that are not where it files them.
        #expect(h.model.canChangeLayout)
        h.model.chooseLayout(Self.authorTitle)
        #expect(h.model.canChangeLayout)

        h.model.chooseLayout(LayoutText.customId)
        h.model.layoutDraftText = "{Author}/{Titel}"
        #expect(!h.model.canChangeLayout)
        // The library's own pattern, however it is typed.
        h.model.layoutDraftText = "  {author}/[{series}/][{number} - ]{title} "
        #expect(h.model.canChangeLayout)
        h.model.layoutDraftText = Self.narratorPattern
        #expect(h.model.canChangeLayout)
    }

    /// The library's own pattern can be previewed too: books left behind by an earlier
    /// change, or moved since, are re-filed by it.
    @Test func fl4_theLibrarysOwnLayoutCanBeAppliedAgainToRefileBooksThatAreNotInPlace() async throws {
        let h = try await Harness.demo()
        h.model.chooseLayout(Self.authorTitle)
        await h.model.previewLayoutChange()
        await h.model.applyLayoutChange()
        h.model.result = nil
        // The library files by the standard pattern again, with three books left where
        // "Author / Title" put them.
        try h.store().setFolderPatternText(nil)
        await h.model.reloadAll()
        #expect(h.model.layoutChoiceId == Self.standardName)
        #expect(try h.book(try h.id("Salt Road")).folderPath == "Ines Calloway/Salt Road")

        #expect(h.model.canChangeLayout)
        await h.model.previewLayoutChange()
        let preview = try #require(h.model.layoutPreview)
        #expect(preview.heading == "3 books will move")
        #expect(preview.canApply)
        await h.model.applyLayoutChange()
        #expect(h.model.alert == nil)
        #expect(try h.book(try h.id("Salt Road")).folderPath == "Ines Calloway/Tidewater Chronicles/1 - Salt Road")
        #expect(h.model.undoMenuTitle == "Undo Change Folder Layout")
    }

    @Test func fl4_whenTheLibrarysOwnLayoutWouldMoveNothingThePreviewSaysSoAndCannotBeApplied() async throws {
        // Every book in place.
        let empty = try await Harness.empty()
        await empty.model.beginImport([try Harness.inbox().appendingPathComponent("Quiet Rivers.epub")])
        await empty.model.confirmImport()
        #expect(empty.model.canChangeLayout)
        await empty.model.previewLayoutChange()
        var preview = try #require(empty.model.layoutPreview)
        #expect(preview.heading == "Every book is already in place")
        #expect(preview.lines == ["1 is already in place"])
        #expect(!preview.canApply)
        let tree = layoutTree(empty.root)
        await empty.model.applyLayoutChange()
        #expect(empty.model.layoutPreview == preview)
        #expect(layoutTree(empty.root) == tree)
        empty.model.cancelLayoutChange()
        #expect(empty.model.layoutPreview == nil)

        // A book that cannot be filed is not in place: it is said to stay.
        let h = try await Harness.demo()
        await h.model.previewLayoutChange()
        preview = try #require(h.model.layoutPreview)
        #expect(preview.heading == "No book will move")
        #expect(preview.lines == ["1 book stays where it is", "11 are already in place"])
        #expect(!preview.canApply)
    }

    // MARK: A saved layout that cannot be read

    @Test func aSavedLayoutThatCannotBeReadIsSaidAndCanBeReplaced() async throws {
        let h = try await Harness.demo()
        #expect(h.model.layoutUnreadableText == nil)
        try h.store().setFolderPatternText("{Auther}/{Title")
        await h.model.reloadAll()
        #expect(h.model.layoutUnreadableText
            == "The library's saved folder layout could not be read, so books are being filed by the standard "
            + "layout. Choose a layout and press Change Layout… to save one that can be read.")
        // The standard layout is what is in use, and is shown.
        #expect(h.model.layoutChoiceId == Self.standardName)
        #expect(h.model.canChangeLayout)

        await h.model.previewLayoutChange()
        let preview = try #require(h.model.layoutPreview)
        #expect(preview.heading == "No book will move")
        #expect(preview.lines.last == "New books will be filed by this layout")
        #expect(preview.canApply)
        await h.model.applyLayoutChange()
        #expect(h.model.alert == nil)
        #expect(try h.store().folderPatternText() == FolderPattern.standard.text)
        #expect(h.model.layoutUnreadableText == nil)

        // Another library has its own.
        try h.store().setFolderPatternText("{Auther}/{Title")
        await h.model.reloadAll()
        #expect(h.model.layoutUnreadableText != nil)
        await h.model.chooseLibrary(try makeTempDir())
        #expect(h.model.layoutUnreadableText == nil)
    }

    // MARK: FP41 A new book and a folder that is taken

    @Test func theImportSheetSaysWhenANewBooksFolderIsAnotherBooks() async throws {
        let h = try await Harness.empty()
        let inbox = try Harness.inbox()
        await h.model.beginImport([inbox.appendingPathComponent("Quiet Rivers.epub")])
        await h.model.confirmImport()
        h.model.result = nil

        // An audiobook given the same title and author, kept as a book of its own.
        let audio = inbox.appendingPathComponent("The Lighthouse Keeper.m4b")
        await h.model.beginImport([audio])
        h.model.updateReview {
            $0.entries[0].candidate.metadata.title = "Quiet Rivers"
            $0.entries[0].candidate.metadata.authors = ["Amara Okafor"]
        }
        await h.model.settle()
        var review = try #require(h.model.review)
        var entry = try #require(review.entries.first)
        // The offer to add it to the book that is there is as it was.
        #expect(entry.existingMatch?.id == (try h.id("Quiet Rivers")))
        #expect(entry.isAddedToExisting)
        #expect(review.destinationText(of: entry.id) == "Will be added to: Amara Okafor/Quiet Rivers")

        h.model.updateReview { $0.entries[0].addToExisting = false }
        await h.model.settle()
        review = try #require(h.model.review)
        entry = try #require(review.entries.first)
        #expect(entry.destination == nil)
        #expect(review.destinationText(of: entry.id)
            == "Cannot be imported yet. Another book already uses the folder this book belongs in. "
            + "Add these files to that book instead, or change one book's details.")

        // With other details the folder is named again.
        h.model.updateReview { $0.entries[0].candidate.metadata.title = "Quiet Rivers Aloud" }
        await h.model.settle()
        review = try #require(h.model.review)
        #expect(review.destinationText(of: review.entries[0].id) == "Will be filed in: Amara Okafor/Quiet Rivers Aloud")

        // Imported all the same under the taken name, the item fails and nothing moves.
        h.model.updateReview { $0.entries[0].candidate.metadata.title = "Quiet Rivers" }
        await h.model.settle()
        h.model.updateReview { $0.entries[0].addToExisting = false }
        await h.model.settle()
        #expect(h.model.review?.entries.first?.isAddedToExisting == false)
        await h.model.confirmImport()
        #expect(FileManager.default.fileExists(atPath: audio.path))
        #expect(try h.store().books().count == 1)
        #expect(h.model.result?.problems.first?.detail
            == "Another book already uses the folder this book belongs in. Add these files to that book instead, "
            + "or change one book's details.")
    }

    @Test func fl4_notWhileAnythingIsInTheWay() async throws {
        let h = try await Harness.demo()
        h.model.chooseLayout(Self.authorTitle)
        #expect(h.model.canChangeLayout)

        h.model.busyLabel = "Working…"
        #expect(!h.model.canChangeLayout)
        h.model.busyLabel = nil

        h.model.result = ResultSummary(headline: "Done", problems: [], isClean: false)
        #expect(!h.model.canChangeLayout)
        h.model.result = nil

        h.model.libraryCheck = ReconcileReport(untrackedFiles: [h.root.appendingPathComponent("x.epub")])
        #expect(!h.model.canChangeLayout)
        h.model.dismissLibraryCheck()

        h.model.requestRemove([try h.id("Quiet Rivers")])
        #expect(h.model.prompt != nil)
        #expect(!h.model.canChangeLayout)
        h.model.prompt = nil

        await h.model.beginImport([try Harness.inbox().appendingPathComponent("Quiet Rivers.epub")])
        #expect(h.model.review != nil)
        #expect(!h.model.canChangeLayout)
        h.model.cancelImport()

        try await h.select("Quiet Rivers")
        h.model.beginLookup()
        #expect(h.model.lookup != nil)
        #expect(!h.model.canChangeLayout)
        h.model.cancelLookup()
        #expect(h.model.canChangeLayout)

        // Unsaved edits: the change reads every book again.
        h.model.updateDraft { $0.title = "Quieter Rivers" }
        #expect(!h.model.canChangeLayout)
        h.model.discardChanges()
        #expect(h.model.canChangeLayout)
    }

    @Test func fl4_notWithoutALibrary() async throws {
        let h = try Harness(root: try makeTempDir(), choose: false)
        await h.model.start()
        h.model.chooseLayout(Self.authorTitle)
        #expect(!h.model.isLibraryOpen)
        #expect(!h.model.canChangeLayout)
        await h.model.previewLayoutChange()
        #expect(h.model.layoutPreview == nil)
    }

    // MARK: FL5 The preview

    @Test func fl5_thePreviewSaysWhatWouldMoveAndChangesNothing() async throws {
        let h = try await Harness.demo()
        let tree = layoutTree(h.root)
        h.recordBusyLabels()
        h.model.chooseLayout(Self.authorTitle)
        #expect(h.model.layoutPreview == nil)

        await h.model.previewLayoutChange()

        let preview = try #require(h.model.layoutPreview)
        #expect(preview.heading == "3 books will move")
        #expect(preview.lines == ["1 book stays where it is", "8 are already in place"])
        #expect(preview.examples == [
            LayoutExample(
                id: 0, title: "Harbour of Glass", from: "Ines Calloway/Tidewater Chronicles/3 - Harbour of Glass",
                to: "Ines Calloway/Harbour of Glass"),
            LayoutExample(
                id: 1, title: "Salt Road", from: "Ines Calloway/Tidewater Chronicles/1 - Salt Road",
                to: "Ines Calloway/Salt Road"),
            LayoutExample(
                id: 2, title: "The Drowned Bell", from: "Ines Calloway/Tidewater Chronicles/2 - The Drowned Bell",
                to: "Ines Calloway/The Drowned Bell"),
        ])
        #expect(preview.staying == [
            LayoutStayRow(id: 0, title: "Voices from the Attic", reason: "No author, which the folder layout needs."),
        ])
        #expect(preview.canApply)
        #expect(preview.pattern.text == "{Author}/{Title}")

        // Planning is shown as work, and changes nothing: not the folders, not the
        // catalogue, not what Undo would reverse.
        #expect(h.busyLabels == ["Working out the new layout…"])
        #expect(h.model.busyLabel == nil)
        #expect(h.model.alert == nil)
        #expect(layoutTree(h.root) == tree)
        #expect(try h.store().folderPatternText() == nil)
        #expect(h.model.undoMenuTitle == "Undo \(Harness.demoUndoLabel)")
        #expect(h.model.layoutChoiceId == Self.authorTitle)
    }

    @Test func fl5_aPreviewIsNotMadeWhenTheLayoutCannotBeChanged() async throws {
        let h = try await Harness.demo()
        h.recordBusyLabels()
        // (The library's own layout can be previewed: books not in place are re-filed by it.)
        h.model.chooseLayout(LayoutText.customId)
        h.model.layoutDraftText = "{Author}/{Titel}"
        await h.model.previewLayoutChange()
        #expect(h.model.layoutPreview == nil)
        #expect(h.busyLabels.isEmpty)
        #expect(h.model.alert == nil)
    }

    @Test func fl5_anEmptyLibraryCanBeGivenALayoutBeforeItHasBooks() async throws {
        let h = try await Harness.empty()
        h.model.chooseLayout(Self.kindName)
        await h.model.previewLayoutChange()
        let preview = try #require(h.model.layoutPreview)
        #expect(preview.heading == "No book will move")
        #expect(preview.lines == ["New books will be filed by this layout"])
        #expect(preview.canApply)

        await h.model.applyLayoutChange()
        #expect(h.model.alert == nil)
        #expect(h.model.layoutPreview == nil)
        #expect(h.model.layoutChoiceId == Self.kindName)
        #expect(try h.store().folderPatternText() == "{Kind}/{Author}/[{Series}/][{Number} - ]{Title}")
    }

    // MARK: FL6 Changing

    @Test func fl6_theChangeMovesTheFoldersAndCanBeUndone() async throws {
        let h = try await previewed()
        h.recordBusyLabels()
        let salt = try h.id("Salt Road")

        await h.model.applyLayoutChange()

        #expect(h.busyLabels == ["Changing the folder layout…"])
        #expect(h.model.busyLabel == nil)
        #expect(h.model.layoutPreview == nil)
        #expect(h.model.alert == nil)
        #expect(h.model.undoMenuTitle == "Undo Change Folder Layout")
        #expect(h.model.canUndo)
        #expect(try h.store().folderPatternText() == "{Author}/{Title}")
        #expect(try h.book(salt).folderPath == "Ines Calloway/Salt Road")
        #expect(FileManager.default.fileExists(atPath: h.root.appendingPathComponent("Ines Calloway/Salt Road/Salt Road.m4b").path))
        #expect(!FileManager.default.fileExists(atPath: h.root.appendingPathComponent("Ines Calloway/Tidewater Chronicles").path))

        // The book that stayed is said, in the result sheet.
        let result = try #require(h.model.result)
        #expect(result.headline == "3 books moved, 1 stayed where it was")
        #expect(result.problems == [
            ResultSummary.Line(title: "Voices from the Attic", detail: "No author, which the folder layout needs."),
        ])
        #expect(h.model.windowSheet(progressDue: false) == .result(result))
    }

    @Test func fl6_nothingIsReportedWhenEveryBookMoved() async throws {
        let h = try await Harness.demo()
        // Without the one book that cannot be filed.
        h.model.requestRemove([try h.id("Voices from the Attic")])
        await h.model.confirmRemove(moveFilesToTrash: false)
        h.model.chooseLayout(Self.authorTitle)
        await h.model.previewLayoutChange()
        #expect(h.model.layoutPreview?.lines == ["8 are already in place"])
        await h.model.applyLayoutChange()
        #expect(h.model.result == nil)
        #expect(h.model.alert == nil)
        #expect(h.model.layoutPreview == nil)
        #expect(h.model.undoMenuTitle == "Undo Change Folder Layout")
    }

    @Test func fl6_aChangeThatFailsLeavesEverythingAsItWasAndSaysWhy() async throws {
        let h = try await previewed()
        let tree = layoutTree(h.root)
        // The series folder cannot be changed, so no book folder can be moved out of it.
        let series = h.root.appendingPathComponent("Ines Calloway/Tidewater Chronicles")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: series.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: series.path) }

        await h.model.applyLayoutChange()

        let alert = try #require(h.model.alert)
        #expect(alert.contains("could not be moved, so the folder layout was not changed."))
        #expect(alert.contains("Every folder is where it was."))
        #expect(h.model.busyLabel == nil)
        #expect(h.model.result == nil)
        #expect(layoutTree(h.root) == tree)
        #expect(try h.store().folderPatternText() == nil)
        #expect(h.model.undoMenuTitle == "Undo \(Harness.demoUndoLabel)")
        // The preview is closed, and the draft is still what was chosen, to try again.
        #expect(h.model.layoutPreview == nil)
        #expect(h.model.layoutChoiceId == Self.authorTitle)
        #expect(h.model.layoutDraftText == "{Author}/{Title}")
        h.model.alert = nil
        #expect(h.model.canChangeLayout)
    }

    @Test func fl6_theChangeIsOnlyMadeFromAPreview() async throws {
        let h = try await Harness.demo()
        h.recordBusyLabels()
        h.model.chooseLayout(Self.authorTitle)
        await h.model.applyLayoutChange()
        #expect(h.busyLabels.isEmpty)
        #expect(try h.store().folderPatternText() == nil)
    }

    // MARK: FL7 Cancelling

    @Test func fl7_cancellingClosesThePreviewAndKeepsTheDraft() async throws {
        let h = try await Harness.demo()
        h.model.chooseLayout(LayoutText.customId)
        h.model.layoutDraftText = Self.narratorPattern
        await h.model.previewLayoutChange()
        #expect(h.model.layoutPreview != nil)
        let tree = layoutTree(h.root)

        h.model.cancelLayoutChange()

        #expect(h.model.layoutPreview == nil)
        #expect(h.model.layoutDraftText == Self.narratorPattern)
        #expect(h.model.layoutChoiceId == LayoutText.customId)
        #expect(h.model.canChangeLayout)
        #expect(layoutTree(h.root) == tree)
        #expect(try h.store().folderPatternText() == nil)
    }

    // MARK: FL8 While the preview is open

    @Test func fl8_thePreviewIsTheWindowsSheet() async throws {
        let h = try await previewed()
        let preview = try #require(h.model.layoutPreview)
        #expect(h.model.windowSheet(progressDue: false) == .layoutPreview(preview))
        #expect(h.model.windowSheet(progressDue: true) == .layoutPreview(preview))
        #expect(WindowSheet.layoutPreview(preview).id == "layoutPreview")
        #expect(h.model.layoutPreviewNote == "Only folders move. You can undo this from the Edit menu.")
        // The window that shows it comes forward, from behind Settings.
        #expect(h.model.wantsToBeSeen)

        // While the change runs, its progress is the sheet.
        h.model.busyLabel = "Changing the folder layout…"
        #expect(h.model.windowSheet(progressDue: true) == .progress("Changing the folder layout…"))
        #expect(h.model.windowSheet(progressDue: false) == .layoutPreview(preview))
        h.model.busyLabel = nil

        // In the one-sheet-at-a-time order it comes after the launch check and a result.
        h.model.libraryCheck = ReconcileReport(untrackedFiles: [h.root.appendingPathComponent("x.epub")])
        #expect(h.model.windowSheet(progressDue: false)?.id == "check")
        let result = ResultSummary(headline: "Done", problems: [], isClean: false)
        h.model.result = result
        #expect(h.model.windowSheet(progressDue: false) == .result(result))
        h.model.result = nil
        h.model.dismissLibraryCheck()
        #expect(h.model.windowSheet(progressDue: false) == .layoutPreview(preview))

        h.model.cancelLayoutChange()
        #expect(h.model.windowSheet(progressDue: false) == nil)
        #expect(!h.model.wantsToBeSeen)
    }

    @Test func fl8_noCommandAppliesWhileThePreviewIsOpen() async throws {
        let h = try await Harness.demo()
        let rivers = try await h.select("Quiet Rivers")
        #expect(h.model.canUndo)
        #expect(h.model.canImport)
        #expect(h.model.canLookUp)
        #expect(h.model.canAddAudibleBook)
        #expect(h.model.canChooseLibrary)
        #expect(h.model.canChangeFiles)
        #expect(h.model.commands(for: [rivers]).remove)

        h.model.chooseLayout(Self.authorTitle)
        await h.model.previewLayoutChange()
        #expect(h.model.layoutPreview != nil)

        #expect(!h.model.canChangeLayout)
        #expect(!h.model.canUndo)
        #expect(!h.model.canImport)
        #expect(!h.model.canReviewInbox)
        #expect(!h.model.canSave)
        #expect(!h.model.canLookUp)
        #expect(!h.model.canAddAudibleBook)
        #expect(!h.model.canMarkOnAudible(for: [rivers]))
        #expect(!h.model.canCheckEdition(for: [try h.id("Salt Road")]))
        #expect(!h.model.canChooseLibrary)
        #expect(!h.model.canChangeFiles)
        let commands = h.model.commands(for: [rivers])
        #expect(!commands.remove)
        #expect(!commands.rewriteTags)
        #expect(!commands.mark)
        // Looking is not stopped.
        #expect(commands.open)
        #expect(commands.reveal)
    }

    @Test func fl8_nothingElseCanStartAnOperationWhileThePreviewIsOpen() async throws {
        let h = try await previewed()
        let preview = h.model.layoutPreview
        let tree = layoutTree(h.root)
        let rivers = try h.id("Quiet Rivers")
        let status = try h.book(rivers).readStatus
        h.recordBusyLabels()

        await h.model.undo()
        await h.model.beginImport([try Harness.inbox().appendingPathComponent("Quiet Rivers.epub")])
        await h.model.rewriteTags(for: [rivers])
        await h.model.setReadStatus(status == .finished ? .unread : .finished, for: [rivers])
        await h.model.createCollection(name: "New", adding: [rivers])
        h.model.requestRemove([rivers])
        await h.model.previewLayoutChange()
        await h.model.chooseLibrary(try makeTempDir())

        #expect(h.busyLabels.isEmpty)
        #expect(h.model.review == nil)
        #expect(h.model.prompt == nil)
        #expect(h.model.layoutPreview == preview)
        #expect(h.model.undoMenuTitle == "Undo \(Harness.demoUndoLabel)")
        #expect(try h.book(rivers).readStatus == status)
        #expect(layoutTree(h.root) == tree)
        #expect(h.model.libraryFolder == h.root)
        // Choosing a folder was done in a panel, so it is answered with a sentence.
        #expect(h.model.alert == "Finish or cancel the change of folder layout first, then choose the library folder again.")
    }

    @Test func fl8_filesOpenedWhileThePreviewIsOpenAreImportedWhenItCloses() async throws {
        let h = try await previewed()
        await h.model.openFiles([try Harness.inbox().appendingPathComponent("Quiet Rivers.epub")])
        await h.model.settle()
        #expect(h.model.review == nil)
        #expect(h.model.alert == nil)
        #expect(h.model.layoutPreview != nil)

        h.model.cancelLayoutChange()
        await h.model.settle()
        #expect(h.model.review?.entries.count == 1)
    }

    // MARK: FL9 The setting follows the library

    @Test func fl9_afterAChangeAndAfterUndoingItTheSettingFollowsTheLibrary() async throws {
        let h = try await previewed()
        let salt = try h.id("Salt Road")
        await h.model.applyLayoutChange()
        h.model.result = nil
        #expect(h.model.layoutChoiceId == Self.authorTitle)
        #expect(h.model.layoutDraftText == "{Author}/{Title}")
        // It is the library's own layout now: that is what the setting shows.
        #expect(h.model.libraryPattern.text == "{Author}/{Title}")
        #expect(h.model.layoutExampleText == "Ines Calloway/Harbour of Glass")

        await h.model.undo()
        #expect(h.model.alert == nil)
        #expect(h.model.layoutChoiceId == Self.standardName)
        #expect(h.model.layoutDraftText == "{Author}/[{Series}/][{Number} - ]{Title}")
        #expect(h.model.libraryPattern == .standard)
        #expect(try h.book(salt).folderPath == "Ines Calloway/Tidewater Chronicles/1 - Salt Road")
        // The library remembers one operation to undo, and that was it.
        #expect(h.model.undoMenuTitle == "Undo")
        #expect(!h.model.canUndo)
    }

    @Test func fl9_aCustomLayoutStaysCustomOnceItIsTheLibrarys() async throws {
        let h = try await Harness.demo()
        h.model.chooseLayout(LayoutText.customId)
        h.model.layoutDraftText = "  {narrator}/{Title} "
        await h.model.previewLayoutChange()
        await h.model.applyLayoutChange()
        #expect(h.model.alert == nil)
        #expect(h.model.layoutChoiceId == LayoutText.customId)
        // As the library has it: without the spaces around it.
        #expect(h.model.layoutDraftText == "{narrator}/{Title}")
        #expect(try h.store().folderPatternText() == "{narrator}/{Title}")

        // A preset typed as a custom layout is that preset once it is the library's.
        h.model.result = nil
        h.model.layoutDraftText = "{Author}/{Title}"
        #expect(h.model.layoutChoiceId == LayoutText.customId)
        await h.model.previewLayoutChange()
        await h.model.applyLayoutChange()
        #expect(h.model.layoutChoiceId == Self.authorTitle)
    }

    @Test func fl9_aDraftBeingTypedIsKeptWhenSomethingElseChangesTheLibrary() async throws {
        let h = try await Harness.demo()
        h.model.chooseLayout(LayoutText.customId)
        h.model.layoutDraftText = "{Narrator}/{Tit"
        await h.model.setReadStatus(.finished, for: [try h.id("Quiet Rivers")])
        #expect(h.model.layoutDraftText == "{Narrator}/{Tit")
        #expect(h.model.layoutChoiceId == LayoutText.customId)
    }

    @Test func fl9_anotherLibraryBringsItsOwnLayout() async throws {
        let h = try await previewed()
        await h.model.applyLayoutChange()
        h.model.result = nil
        h.model.chooseLayout(Self.kindName)
        let other = try makeTempDir()
        await h.model.chooseLibrary(other)
        #expect(h.model.libraryFolder == other)
        #expect(h.model.layoutChoiceId == Self.standardName)
        #expect(h.model.layoutDraftText == FolderPattern.standard.text)
        #expect(h.model.layoutPreview == nil)
    }

    // MARK: FL10 What is shown follows the layout

    @Test func fl10_theImportSheetFilesByTheLayoutJustChosen() async throws {
        let h = try await Harness.empty()
        h.model.chooseLayout(Self.kindName)
        await h.model.previewLayoutChange()
        await h.model.applyLayoutChange()

        await h.model.beginImport([try Harness.inbox().appendingPathComponent("Quiet Rivers.epub")])
        let review = try #require(h.model.review)
        let entry = try #require(review.entries.first)
        #expect(review.destinationText(of: entry.id) == "Will be filed in: Ebooks/Amara Okafor/Quiet Rivers")
        await h.model.confirmImport()
        #expect(try h.book(try h.id("Quiet Rivers")).folderPath == "Ebooks/Amara Okafor/Quiet Rivers")
    }

    @Test func fl10_theInspectorsReasonFollowsTheLayoutJustChosen() async throws {
        let h = try await Harness.demo()
        try await h.select("Quiet Rivers")
        #expect(h.detail?.attentionReasons == [])
        h.model.chooseLayout(LayoutText.customId)
        h.model.layoutDraftText = Self.narratorPattern
        await h.model.previewLayoutChange()
        #expect(h.model.layoutPreview?.staying.contains {
            $0.title == "Quiet Rivers" && $0.reason == "No narrator, which the folder layout needs."
        } == true)
        await h.model.applyLayoutChange()
        h.model.result = nil

        // The book has no narrator, which the layout now needs: it stayed, and says so.
        #expect(h.detail?.row.book.needsAttention == true)
        #expect(h.detail?.attentionReasons == ["No narrator, which the folder layout needs."])
        #expect(try h.book(try h.id("Quiet Rivers")).folderPath == "Amara Okafor/Quiet Rivers")

        await h.model.undo()
        #expect(h.detail?.attentionReasons == [])
    }

    // MARK: FL14 A folder that is another book's

    @Test func fl14_theInspectorSaysWhenAnotherBookUsesTheFolder() async throws {
        let h = try await Harness.demo()
        // Given the title and number of another book of its series, the book belongs
        // in that book's folder: it is not moved there, and is flagged.
        try await h.select("The Drowned Bell")
        h.model.updateDraft {
            $0.title = "Salt Road"
            $0.seriesNumber = "1"
        }
        await h.model.save()
        #expect(h.model.alert == nil)

        let detail = try #require(h.detail)
        #expect(detail.row.book.needsAttention)
        #expect(detail.row.book.folderPath == "Ines Calloway/Tidewater Chronicles/2 - The Drowned Bell")
        #expect(detail.unfiledReason == "Another book uses the folder this book belongs in.")
        #expect(detail.attentionReasons == ["Another book uses the folder this book belongs in."])
    }

    @Test func fl14_theInspectorsReasonsIncludeWhatTheLibrarySays() {
        var book = Book(metadata: BookMetadata(title: "Atlas", authors: ["Ann"]), folderPath: "Ann/Old", needsAttention: true)
        book.id = 1
        let row = BookRow(
            id: 1, book: book, hasAudio: true, hasEbook: false, formats: [], coverURL: nil, hasWriteProblem: false)
        var file = BookFile(path: "Ann/Old/Atlas.m4b", format: .m4b, role: .audio, position: 0)
        file.id = 1
        let url = URL(fileURLWithPath: "/library/Ann/Old/Atlas.m4b")
        func reasons(missing: [FolderToken]?, said: String?, fileMissing: Bool = false, flagged: Bool = true) -> [String] {
            var row = row
            row.book.needsAttention = flagged
            var detail = BookDetail(
                row: row,
                files: [FileRow(id: 1, file: file, url: url, name: "Atlas.m4b", isMissing: fileMissing, allowedRoles: [.audio])],
                chapterCount: 0, collectionIds: [])
            detail.missingForFiling = missing
            detail.unfiledReason = said
            return detail.attentionReasons
        }
        let taken = "Another book uses the folder this book belongs in."
        #expect(reasons(missing: [], said: taken) == [taken])
        #expect(reasons(missing: [], said: taken, fileMissing: true) == [taken, "Some files are missing"])
        // What the layout needs is said once, in the inspector's own words.
        #expect(reasons(missing: [.narrator], said: "No narrator, which the folder layout needs.")
            == ["No narrator, which the folder layout needs."])
        #expect(reasons(missing: [.author], said: "No author, which the folder layout needs.")
            == ["Add an author to file this book"])
        #expect(reasons(missing: [], said: "The folder layout leaves no name for its folder.")
            == ["The folder layout leaves no name for its folder."])
        // Nothing in the way, and a book that is not flagged, say nothing.
        #expect(reasons(missing: [], said: nil) == [])
        #expect(reasons(missing: [], said: taken, flagged: false) == [])
    }

    @Test func fl14_theImportSheetDoesNotNameAFolderAnotherBookHas() async throws {
        let h = try await Harness.empty()
        let inbox = try Harness.inbox()
        await h.model.beginImport([inbox.appendingPathComponent("Quiet Rivers.epub")])
        await h.model.confirmImport()
        let ebook = try h.id("Quiet Rivers")
        // The same title on Audible, as a book of its own with no files: its first
        // files belong in the folder the ebook has.
        let store = try h.store()
        var stored = try h.book(ebook)
        stored.needsAttention = true  // so that the Audible book is not taken for the same book
        try store.update(stored)
        var metadata = BookMetadata(title: "Quiet Rivers", authors: ["Amara Okafor"])
        metadata.asin = "B0TESTASIN"
        guard case .added(let owned) = try LibraryService(store: store).addExternalBook(
            metadata: metadata, cover: nil, copy: ExternalCopy(kind: .audible, form: .audio))
        else {
            Issue.record("the Audible book was not added as a book of its own")
            return
        }
        stored.needsAttention = false
        try store.update(stored)

        await h.model.beginImport([inbox.appendingPathComponent("The Lighthouse Keeper.m4b")])
        h.model.updateReview { $0.entries[0].candidate.metadata.asin = "B0TESTASIN" }
        await h.model.settle()

        let review = try #require(h.model.review)
        let entry = try #require(review.entries.first)
        #expect(entry.existingMatch?.id == owned)
        #expect(entry.isAddedToExisting)
        #expect(entry.matchHasNoFiles)
        #expect(entry.destination == nil)
        #expect(review.destinationText(of: entry.id)
            == "Cannot be added yet. Another book uses the folder this book belongs in.")

        // With the folder free, the folder is named.
        h.model.cancelImport()
        h.model.click(ebook, modifiers: [])
        await h.model.settle()
        h.model.updateDraft { $0.title = "Quiet Rivers Ebook" }
        await h.model.save()
        await h.model.beginImport([inbox.appendingPathComponent("The Lighthouse Keeper.m4b")])
        h.model.updateReview { $0.entries[0].candidate.metadata.asin = "B0TESTASIN" }
        await h.model.settle()
        let again = try #require(h.model.review)
        #expect(again.destinationText(of: again.entries[0].id) == "Will be filed in: Amara Okafor/Quiet Rivers")
    }

    @Test func fl14_aRefusalIsKeptOnlyForTheBookItWasWorkedOutFor() {
        var match = Book(metadata: BookMetadata(title: "Atlas", authors: ["Ann Author"]), folderPath: nil)
        match.id = 7
        match.externalCopies = [ExternalCopy(kind: .audible, form: .audio)]
        let url = URL(fileURLWithPath: "/inbox/a.m4b")
        var seed = ImportSeed(
            candidate: CandidateBook(
                files: [CandidateFile(url: url, role: .audio)], metadata: BookMetadata(title: "Atlas", authors: ["Ann Author"])),
            cover: nil, existingMatch: nil)
        seed.existingMatch = match
        var review = ImportReview(seeds: [seed], skipped: [], copyInsteadOfMove: false)
        let id = review.entries[0].id
        #expect(review.destinationText(of: id) == "Working out where it will be filed…")

        let taken = "Another book uses the folder this book belongs in."
        review.setMatchDestination(nil, for: id, matchedBook: match, refusal: taken)
        #expect(review.destinationText(of: id) == "Cannot be added yet. \(taken)")
        #expect(review.entries[0].destination == nil)

        // Worked out again without a refusal, the folder is named.
        review.setMatchDestination("Ann Author/Atlas", for: id, matchedBook: match)
        #expect(review.destinationText(of: id) == "Will be filed in: Ann Author/Atlas")

        // An answer for the book as it was is not taken.
        var changed = match
        changed.title = "Atlas II"
        review.setMatchDestination(nil, for: id, matchedBook: changed, refusal: taken)
        #expect(review.destinationText(of: id) == "Will be filed in: Ann Author/Atlas")
    }
}
