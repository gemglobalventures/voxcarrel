import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// CV1 onwards: Convert to EPUB, as the app's model decides it. No program is run:
/// the converter is the harness's own, which writes a small EPUB or fails as told.
@MainActor
@Suite struct ConvertToEPUBTests {
    /// A started model on a library of this test's own: three books whose only ebook
    /// is in a format that converts ("The Long Road", MOBI; "Second Road", AZW3; "Third
    /// Road", FB2), "Has Both" (MOBI and EPUB), "Paper Only" (PDF), "Spoken" (an
    /// audiobook) and "Elsewhere", which is owned on Audible and has no files here.
    private func library() async throws -> Harness {
        let root = try makeTempDir()
        let inbox = try makeTempDir()
        let store = try LibraryStore(libraryRoot: root)
        try store.setKnowsFilesAgain(false)
        let service = LibraryService(store: store)

        func file(_ name: String) throws -> URL {
            let url = inbox.appendingPathComponent(name)
            try Data("the words of \(name)".utf8).write(to: url)
            return url
        }
        func add(_ title: String, _ files: [(url: URL, role: FileRole)]) throws {
            let candidate = CandidateBook(
                files: files.map { CandidateFile(url: $0.url, role: $0.role) },
                metadata: BookMetadata(title: title, authors: ["Ann Author"]))
            let result = try service.importItems([ImportItem(candidate: candidate)], options: ImportOptions())
            guard case .imported = try #require(result.outcomes.first) else {
                Issue.record("\(title) was not imported")
                return
            }
        }
        try add("The Long Road", [(try file("long.mobi"), .ebook)])
        try add("Second Road", [(try file("second.azw3"), .ebook)])
        try add("Third Road", [(try file("third.fb2"), .ebook)])
        try add("Has Both", [(try file("both.mobi"), .ebook), (try MediaFixtures.makeEPUB3(in: inbox, name: "both.epub"), .ebook)])
        let pdf = inbox.appendingPathComponent("paper.pdf")
        MediaFixtures.makePDF(at: pdf)
        try add("Paper Only", [(pdf, .ebook)])
        let mp3 = inbox.appendingPathComponent("spoken.mp3")
        try MediaFixtures.makeSilentMP3(seconds: 1).write(to: mp3)
        try add("Spoken", [(mp3, .audio)])
        _ = try service.addExternalBook(
            metadata: BookMetadata(title: "Elsewhere", authors: ["Ann Author"]), cover: nil,
            copy: ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: "B0ELSEWHER"))

        let h = try Harness(root: root)
        await h.model.start()
        return h
    }

    private func formats(_ h: Harness, _ id: Int64) throws -> [FileFormat] {
        try #require(h.model.rows.first { $0.id == id }).formats
    }

    // MARK: When the command applies

    @Test func CV1_theCommandAppliesToABookWithAnEbookThatConvertsAndNoEPUB() async throws {
        let h = try await library()
        #expect(ConversionText.commandTitle == "Convert to EPUB")
        #expect(h.titles.count == 7)
        // Nothing selected: the Book menu's command is off.
        #expect(!h.model.selectionCommands.convertToEPUB)

        let expected = [
            "The Long Road": true, "Second Road": true, "Third Road": true,
            "Has Both": false, "Paper Only": false, "Spoken": false, "Elsewhere": false,
        ]
        for (title, applies) in expected {
            let id = try h.id(title)
            // For a context menu, whatever is selected.
            #expect(h.model.commands(for: [id]).convertToEPUB == applies, "\(title)")
            #expect(try #require(h.model.rows.first { $0.id == id }).canConvertToEPUB == applies, "\(title)")
            try await h.select(title)
            #expect(h.model.selectionCommands.convertToEPUB == applies, "\(title), selected")
        }
        // One book that can be converted among others that cannot is enough.
        let mixed = try await h.select(["The Long Road", "Has Both", "Spoken", "Elsewhere"])
        #expect(h.model.selectionCommands.convertToEPUB && h.model.commands(for: mixed).convertToEPUB)
        let none = try h.ids(["Has Both", "Paper Only", "Spoken", "Elsewhere"])
        #expect(!h.model.commands(for: none).convertToEPUB)
        // A book that is not shown is not offered: nothing is known of its files.
        #expect(!h.model.commands(for: [9_999]).convertToEPUB)
        // Deciding it asked the converter nothing.
        #expect(h.converter.asked.isEmpty)
    }

    @Test func CV2_theCommandIsOffWhileAnOperationRunsAndStaysOnWithUnsavedChanges() async throws {
        let h = try await library()
        let id = try await h.select("The Long Road")
        // As Rewrite Tags and Repair Length Headers beside it: edits not yet saved do
        // not turn it off.
        h.model.updateDraft { $0.title = "Changed" }
        #expect(h.model.hasUnsavedChanges)
        #expect(h.model.selectionCommands.convertToEPUB)

        // Converting keeps what was typed.
        await h.model.convertToEPUB()
        #expect(h.draft?.title == "Changed" && h.model.hasUnsavedChanges)
        #expect(try formats(h, id) == [.mobi, .epub])
        h.model.discardChanges()

        // While something runs, nothing else begins.
        let other = try h.id("Second Road")
        h.model.busyLabel = "Working…"
        #expect(!h.model.commands(for: [other]).convertToEPUB)
        await h.model.convertToEPUB(for: [other])
        h.model.busyLabel = nil
        #expect(h.converter.asked.count == 1)
        #expect(try formats(h, other) == [.azw3])
    }

    // MARK: Converting

    @Test func CV3_convertingOneBookAddsTheEPUBBesideTheOriginalAndSaysSo() async throws {
        let h = try await library()
        let id = try await h.select("The Long Road")
        let original = try #require(try h.fileURLs(id).first)
        let bytes = try Data(contentsOf: original)
        h.recordBusyLabels()

        await h.model.convertToEPUB()

        #expect(h.busyLabels == ["Converting “The Long Road” to EPUB…"])
        #expect(h.model.busyLabel == nil)
        #expect(h.model.alert == "Added “The Long Road.epub” to the book. The original file is still there.")
        #expect(h.model.result == nil)
        // The original is where it was, as it was, and the EPUB is beside it.
        let files = try h.fileURLs(id)
        #expect(files.count == 2 && files[0] == original)
        #expect(try Data(contentsOf: original) == bytes)
        #expect(files[1].lastPathComponent == "The Long Road.epub")
        #expect(files[1].deletingLastPathComponent() == original.deletingLastPathComponent())
        #expect(FileManager.default.fileExists(atPath: files[1].path))
        #expect(h.converter.asked.count == 1 && h.converter.asked[0].source == original)
        // The row was read again, and with an EPUB there is no more to convert.
        #expect(try formats(h, id) == [.mobi, .epub])
        #expect(!h.model.selectionCommands.convertToEPUB)
        h.model.alert = nil
        await h.model.convertToEPUB()
        #expect(h.model.alert == nil && h.converter.asked.count == 1)
    }

    @Test func CV4_severalBooksAreConvertedAndTheOthersAmongThemPassedOver() async throws {
        let h = try await library()
        let ids = try await h.select(["The Long Road", "Second Road", "Third Road", "Has Both", "Spoken", "Elsewhere"])
        let before = try h.fileURLs(try h.id("Has Both"))
        h.recordBusyLabels()

        await h.model.convertToEPUB()

        #expect(h.busyLabels == ["Converting 3 books to EPUB…"])
        #expect(h.model.alert == "Converted 3 books to EPUB. The original files are still there.")
        #expect(h.converter.asked.count == 3)
        #expect(try formats(h, try h.id("The Long Road")) == [.mobi, .epub])
        #expect(try formats(h, try h.id("Second Road")) == [.azw3, .epub])
        #expect(try formats(h, try h.id("Third Road")) == [.fb2, .epub])
        #expect(try h.fileURLs(try h.id("Has Both")) == before)
        #expect(try h.fileURLs(try h.id("Spoken")).count == 1)
        #expect(h.model.selection == ids)
    }

    @Test func CV5_aBookThatFailsDoesNotStopTheOthersAndIsNamedWithWhy() async throws {
        let h = try await library()
        try await h.select(["The Long Road", "Second Road", "Third Road"])
        h.converter.failures = ["Second": .protected]

        await h.model.convertToEPUB()

        #expect(
            h.model.alert
                == "Converted 2 of 3 books to EPUB. Not converted: “Second Road” (it is protected against copying).")
        #expect(try formats(h, try h.id("The Long Road")) == [.mobi, .epub])
        #expect(try formats(h, try h.id("Third Road")) == [.fb2, .epub])
        // The book that failed is as it was, and can be tried again.
        let second = try h.id("Second Road")
        #expect(try formats(h, second) == [.azw3])
        #expect(try h.fileURLs(second).count == 1)
        #expect(h.model.commands(for: [second]).convertToEPUB)
    }

    @Test func CV6_oneBookThatFailsIsLeftAsItWasAndTheAlertSaysWhy() async throws {
        let h = try await library()
        let id = try await h.select("The Long Road")
        let before = try h.fileURLs(id)
        let said: [(ConversionError, String)] = [
            (.protected, "it is protected against copying, which calibre's converter cannot read."),
            (.failed("No such input plugin."), "the converter stopped: No such input plugin."),
            (.tookTooLong, "the converter took too long."),
        ]
        for (failure, words) in said {
            h.converter.failure = failure
            h.model.alert = nil
            await h.model.convertToEPUB()
            #expect(h.model.alert == "“The Long Road” could not be converted: \(words)")
            #expect(try h.fileURLs(id) == before)
            #expect(try formats(h, id) == [.mobi])
        }
        #expect(h.converter.asked.count == 3)
    }

    @Test func CV7_withoutCalibreTheAlertSaysWhatIsNeededAndNothingIsConverted() async throws {
        let h = try await library()
        let id = try await h.select("The Long Road")
        h.converter.isAvailable = false
        h.recordBusyLabels()
        // The command is still offered: choosing it is how the owner learns what is needed.
        #expect(h.model.selectionCommands.convertToEPUB)

        await h.model.convertToEPUB()

        #expect(
            h.model.alert
                == "Converting needs calibre installed on this Mac. VoxCarrel uses calibre's own converter, and has "
                + "none of its own. Get calibre from calibre-ebook.com, then try again.")
        #expect(h.busyLabels.isEmpty && h.converter.asked.isEmpty)
        #expect(try h.fileURLs(id).count == 1)

        // A book with nothing to convert says nothing, calibre or no calibre.
        h.model.alert = nil
        await h.model.convertToEPUB(for: [try h.id("Paper Only")])
        #expect(h.model.alert == nil && h.busyLabels.isEmpty)
    }

    @Test func CV8_aHiddenBookIsConvertedLikeAnyOtherFromTheHiddenList() async throws {
        let h = try await library()
        let id = try await h.select("The Long Road")
        await h.model.toggleHidden(for: [id])
        await h.model.settle()
        #expect(!h.titles.contains("The Long Road"))
        #expect(!h.model.commands(for: [id]).convertToEPUB)

        await h.model.showHiddenBooks()
        await h.model.settle()
        #expect(h.model.sidebarSelection == .hidden && h.titles == ["The Long Road"])
        h.model.select([id])
        await h.model.settle()
        #expect(h.model.selectionCommands.convertToEPUB)

        await h.model.convertToEPUB()

        #expect(h.model.alert == "Added “The Long Road.epub” to the book. The original file is still there.")
        #expect(try formats(h, id) == [.mobi, .epub])
        #expect(try h.book(id).isHidden)
    }

    // MARK: Wording

    @Test func CV9_theBusyLabelCountsTheBooks() {
        #expect(ConversionText.busy(titles: ["Dune"]) == "Converting “Dune” to EPUB…")
        #expect(ConversionText.busy(titles: ["A", "B"]) == "Converting 2 books to EPUB…")
        #expect(ConversionText.busy(titles: ["A", "B", "C"]) == "Converting 3 books to EPUB…")
    }

    @Test func CV10_everyResultHasItsSentence() {
        typealias R = EPUBConversionOutcome.Result
        func one(_ result: R) -> String? { ConversionText.result([("Title A", result)]) }
        #expect(ConversionText.result([]) == nil)
        #expect(one(.converted(fileName: "Title A.epub")) == "Added “Title A.epub” to the book. The original file is still there.")
        #expect(
            one(.notConverted(.protected))
                == "“Title A” could not be converted: it is protected against copying, which calibre's converter cannot read.")
        // What the converter said ends the sentence, with one full stop however it ended.
        #expect(one(.notConverted(.failed("It broke."))) == "“Title A” could not be converted: the converter stopped: It broke.")
        #expect(one(.notConverted(.failed("It broke"))) == "“Title A” could not be converted: the converter stopped: It broke.")
        #expect(one(.notConverted(.tookTooLong)) == "“Title A” could not be converted: the converter took too long.")
        #expect(
            one(.notConverted(.notAnEPUB))
                == "“Title A” could not be converted: what the converter made is not an EPUB that can be read.")
        #expect(
            one(.notConverted(.noConverter))
                == "“Title A” could not be converted: calibre's converter was not found on this Mac.")
        #expect(
            one(.notConverted(.nothingToConvert))
                == "“Title A” could not be converted: it has no ebook an EPUB can be made of.")
        #expect(one(.problem("The disk is full.")) == "“Title A” could not be converted. The disk is full.")

        let done = R.converted(fileName: "x.epub")
        #expect(
            ConversionText.result([("A", done), ("B", done)])
                == "Converted 2 books to EPUB. The original files are still there.")
        #expect(
            ConversionText.result([
                ("Title A", .notConverted(.protected)), ("Good", done), ("Title B", .notConverted(.failed("It broke."))),
            ])
                == "Converted 1 of 3 books to EPUB. Not converted: “Title A” (it is protected against copying), "
                + "“Title B” (the converter stopped: It broke).")
        #expect(
            ConversionText.result([
                ("A", .notConverted(.tookTooLong)), ("B", .notConverted(.notAnEPUB)), ("C", .problem("The disk is full.")),
            ])
                == "None of the 3 books was converted to EPUB. Not converted: “A” (the converter took too long), "
                + "“B” (what the converter made is not an EPUB that can be read), “C” (The disk is full).")
    }

    // MARK: The worker

    @Test func CV11_theWorkerPassesOverWhatHasNothingToConvertAndIdsThatAreNoBooks() async throws {
        let h = try await library()
        let worker = try #require(h.model.worker)
        let long = try h.id("The Long Road")
        let outcomes = await worker.convertToEPUB(
            bookIds: [try h.id("Has Both"), long, try h.id("Elsewhere"), -4, try h.id("Paper Only")], with: h.converter)
        #expect(outcomes == [EPUBConversionOutcome(bookId: long, result: .converted(fileName: "The Long Road.epub"))])
        #expect(h.converter.asked.count == 1)
        // What the converter makes that is no EPUB is a failure of that book's.
        let second = try h.id("Second Road")
        h.converter.failure = .notAnEPUB
        #expect(
            await worker.convertToEPUB(bookIds: [second], with: h.converter)
                == [EPUBConversionOutcome(bookId: second, result: .notConverted(.notAnEPUB))])
    }
}
