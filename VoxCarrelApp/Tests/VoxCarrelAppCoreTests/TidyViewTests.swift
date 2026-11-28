import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// The Tidy list in the app: what the sidebar lists, what a check shows, and letting
/// books off it.
@MainActor
@Suite struct TidyViewTests {
    @Test func aCheckListsItsBooksAndLetsThemOff() async throws {
        let h = try await Harness.demo()
        // The demo library has a book with no author, one with no year, and several
        // with no description; nothing else is untidy about it.
        #expect(h.model.showsTidy)
        #expect(h.model.sidebar.tidy.map(\.check) == [.noAuthor, .noYear, .noDescription])
        let undescribed = try #require(h.model.sidebar.tidy.last?.count)
        #expect(h.model.tidyCount == 2 + undescribed && h.model.tidyHeader == nil)

        h.model.sidebarSelection = .tidy(.noYear)
        await h.model.settle()
        #expect(h.model.windowTitle == "No Year" && h.model.rows.count == 1)
        var header = try #require(h.model.tidyHeader)
        #expect(header.title == "No Year" && header.countText == "1 book" && !header.canMarkFine)
        #expect(header.explanation == TidyCheck.noYear.explanation)
        // A missing year is answered by a lookup, of one book: off until one is selected.
        #expect(header.commands.map(\.kind) == [.lookUp] && header.commands[0].isEnabled == false)

        // The one book is fine as it is: the check finds nothing more and its line goes.
        let id = try #require(h.model.rows.first?.id)
        h.model.click(id, modifiers: [])
        await h.model.settle()
        #expect(h.model.tidyHeader?.canMarkFine == true)
        let lookUp = try #require(h.model.tidyHeader?.commands.first)
        #expect(lookUp.title == "Look Up…" && lookUp.isEnabled == h.model.canLookUp)
        await h.model.markSelectionFine()
        #expect(h.model.alert == nil && h.model.busyLabel == nil)
        // Its line stays, with no count, for as long as the book can be put back.
        #expect(h.model.sidebar.tidy.map(\.check) == [.noAuthor, .noYear, .noDescription])
        #expect(h.model.sidebar.tidy[1].count == 0 && h.model.sidebar.tidy[1].letOff == 1)
        #expect(h.model.sidebarSelection == .tidy(.noYear) && h.model.rows.isEmpty)
        #expect(h.model.tidyHeader?.putBackTitle == "List the 1 Let Off Again")
        await h.model.putBackLetOff()
        await h.model.settle()
        #expect(h.model.rows.map(\.id) == [id] && h.model.tidyHeader?.putBackTitle == nil)
        #expect(h.model.sidebar.tidy[1].count == 1)

        // Of a longer list, the ones let off go and the rest stay listed.
        h.model.sidebarSelection = .tidy(.noDescription)
        await h.model.settle()
        header = try #require(h.model.tidyHeader)
        #expect(header.countText == "\(undescribed) books" && h.model.rows.count == undescribed)
        let first = try #require(h.model.rows.first?.id)
        h.model.click(first, modifiers: [])
        await h.model.settle()
        await h.model.markSelectionFine()
        await h.model.settle()
        #expect(h.model.sidebarSelection == .tidy(.noDescription))
        #expect(h.model.rows.count == undescribed - 1 && !h.model.rows.contains { $0.id == first })
        #expect(h.model.sidebar.tidy.last?.count == undescribed - 1)
        // The book itself is as it was.
        let summary = try h.book(first).summary ?? ""
        #expect(summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// An action that is for one check only, and counts how often it was begun.
    final class CountingAction: TidyActionExtension {
        let id = "counting"
        var enabled = true
        var runs: [TidyCheck] = []

        func title(for check: TidyCheck, in model: AppModel) -> String? { check == .noYear ? "Do Them All…" : nil }
        func isEnabled(for check: TidyCheck, in model: AppModel) -> Bool { enabled }
        func run(for check: TidyCheck, in model: AppModel) { runs.append(check) }
    }

    @Test func anExtensionsActionIsOfferedAboveTheCheckItIsFor() async throws {
        let h = try await Harness.demo()
        let action = CountingAction()
        h.model.extensions.tidyActions.append(action)
        h.model.sidebarSelection = .tidy(.noYear)
        await h.model.settle()
        #expect(h.model.tidyHeader?.actions == [ExtensionCommandItem(id: "counting", title: "Do Them All…", isEnabled: true)])
        h.model.runTidyAction("counting")
        h.model.runTidyAction("no such action")
        #expect(action.runs == [.noYear])
        action.enabled = false
        #expect(h.model.tidyHeader?.actions.first?.isEnabled == false)
        h.model.runTidyAction("counting")
        #expect(action.runs == [.noYear])

        // When the books are put right by other means, the check's line goes, and the
        // list with it: All Books is shown.
        let undated = try #require(h.model.rows.first?.id)
        var book = try h.book(undated)
        book.year = 2001
        try h.store().update(book)
        await h.model.reloadAll()
        await h.model.settle()
        #expect(h.model.sidebarSelection == .allBooks && h.model.tidyHeader == nil)
        h.model.sidebarSelection = .tidy(.noDescription)
        await h.model.settle()
        // Not for this check: nothing is offered, and nothing is begun.
        h.model.sidebarSelection = .tidy(.noDescription)
        await h.model.settle()
        #expect(h.model.tidyHeader?.actions.isEmpty == true)
        h.model.runTidyAction("counting")
        #expect(action.runs == [.noYear])
    }

    /// Each check has above its books the commands its explanation points at.
    @Test func everyCheckOffersTheCommandsItsWordsPointAt() {
        let expected: [TidyCheck: [TidyCommand.Kind]] = [
            .noAuthor: [.lookUp], .noYear: [.lookUp], .noDescription: [.lookUp],
            .noCover: [.lookUp], .smallCover: [.lookUp],
            .seriesNoNumber: [.showSeries], .seriesGap: [.showSeries],
            .seriesSameNumber: [.showSeries, .linkEditions],
            .sameBookTwice: [.merge], .formsApart: [.merge],
            .editionsNotLinked: [.linkEditions],
            .outsideLibrary: [.bringInCopy, .bringInMove],
            .oldFormat: [.convert],
            .nameSpellings: [], .titleExtras: [], .manyAudioFiles: [],
        ]
        // Every check is in this table: a new one has to say what it offers.
        #expect(Set(expected.keys) == Set(TidyCheck.allCases))
        for (check, kinds) in expected {
            #expect(AppModel.tidyCommandKinds(for: check) == kinds, "\(check)")
        }
        // The words of a check that names a command name one that is offered.
        #expect(TidyCheck.sameBookTwice.explanation.contains("Merge Books"))
        #expect(TidyCheck.editionsNotLinked.explanation.contains(AppModel.linkEditionsTitle))
    }

    @Test func aCommandIsOffUntilItAppliesAndOneNotOfferedIsNotRun() async throws {
        let h = try await Harness.demo()
        h.model.sidebarSelection = .tidy(.noDescription)
        await h.model.settle()
        let inSeries = h.model.rows.first { ($0.book.series ?? "").isEmpty == false }
        let row = try #require(inSeries ?? h.model.rows.first)
        h.model.click(row.id, modifiers: [])
        await h.model.settle()
        // Showing the series is for one book that is in one; merging is for two or more.
        let commands = h.model.tidyCommands(for: .seriesGap, chosen: [row.id])
        #expect(commands.map(\.kind) == [.showSeries])
        #expect(commands[0].isEnabled == (inSeries != nil))
        let merge = h.model.tidyCommands(for: .sameBookTwice, chosen: [row.id])
        #expect(merge[0].isEnabled == false)
        // A command the shown check does not offer is not run.
        await h.model.runTidyCommand(.showSeries)
        #expect(h.model.sidebarSelection == .tidy(.noDescription))
    }

    /// A series check leads from one of its books to the whole series, where Check
    /// Series is; with none or several selected it leads nowhere.
    @Test func aSeriesCheckShowsTheSeriesOfTheSelectedBook() async throws {
        let h = try await Harness.demo()
        // "Salt Road" loses its number: its series now has a book that sorts last.
        let salt = try h.id("Salt Road")
        var book = try h.book(salt)
        let series = try #require(book.series)
        book.seriesNumber = nil
        try h.store().update(book)
        await h.model.reloadAll()
        #expect(h.model.sidebar.tidy.contains { $0.check == .seriesNoNumber })

        h.model.sidebarSelection = .tidy(.seriesNoNumber)
        await h.model.settle()
        #expect(h.model.rows.map(\.id) == [salt])
        var command = try #require(h.model.tidyHeader?.commands.first)
        #expect(command.kind == .showSeries && command.title == "Show the Series" && !command.isEnabled)
        // Off, it does nothing.
        await h.model.runTidyCommand(.showSeries)
        #expect(h.model.sidebarSelection == .tidy(.seriesNoNumber))

        h.model.click(salt, modifiers: [])
        await h.model.settle()
        command = try #require(h.model.tidyHeader?.commands.first)
        #expect(command.isEnabled)
        await h.model.runTidyCommand(.showSeries)
        await h.model.settle()
        #expect(h.model.sidebarSelection == .browse(.series, series))
        // The series is what is shown: its header, with Check Series, and its books.
        #expect(h.model.seriesHeader != nil && h.model.tidyHeader == nil)
        #expect(h.model.rows.contains { $0.id == salt })
    }

    /// Someone who has chosen no library yet is not told theirs will open again.
    @Test func theDemoNoticeFitsSomeoneWithNoLibraryYet() {
        #expect(DemoLibraryText.whatItIs.contains("Your own library opens again"))
        #expect(!DemoLibraryText.whatItIsAtFirst.contains("opens again"))
        #expect(DemoLibraryText.whatItIsAtFirst.contains("Settings ▸ General"))
    }

    /// An action for audiobooks in many files, which can stop offering itself.
    final class PartsAction: TidyActionExtension {
        let id = "parts"
        var offers = true
        var runs = 0

        func title(for check: TidyCheck, in model: AppModel) -> String? {
            offers && check == .manyAudioFiles ? "Make One File…" : nil
        }
        func isEnabled(for check: TidyCheck, in model: AppModel) -> Bool { true }
        func run(for check: TidyCheck, in model: AppModel) { runs += 1 }
    }

    /// A check that names no fault is listed only while something offers to act on it:
    /// nobody is shown a list they can do nothing about.
    @Test func aCheckShownOnlyWhereActedOnAppearsWithItsActionAndGoesWithIt() async throws {
        let h = try await Harness.demo()
        // The demo library has an audiobook in several parts; the app alone has nothing for it.
        let inParts = try h.store().books().compactMap(\.id).filter { id in
            (try? h.store().files(bookId: id).filter { $0.role == .audio }.count) ?? 0 > 1
        }
        #expect(!inParts.isEmpty)
        #expect(!h.model.sidebar.tidy.contains { $0.check == .manyAudioFiles })
        #expect(h.model.tidyChecksActedOn.isEmpty)
        let before = h.model.sidebar.tidy.map(\.check)

        // Something offers to act on it: it is listed, after the others, with its books and the action above them.
        let action = PartsAction()
        h.model.extensions.tidyActions.append(action)
        #expect(h.model.tidyChecksActedOn == [.manyAudioFiles])
        await h.model.reloadAll()
        await h.model.settle()
        #expect(h.model.sidebar.tidy.map(\.check) == before + [.manyAudioFiles])
        #expect(h.model.sidebar.tidy.last?.count == inParts.count)
        h.model.sidebarSelection = .tidy(.manyAudioFiles)
        await h.model.settle()
        #expect(Set(h.model.rows.map(\.id)) == Set(inParts) && h.model.windowTitle == "Audio in Parts")
        let header = try #require(h.model.tidyHeader)
        #expect(header.actions == [ExtensionCommandItem(id: "parts", title: "Make One File…", isEnabled: true)])
        // The app has no command of its own for it.
        #expect(header.commands.isEmpty && header.explanation == TidyCheck.manyAudioFiles.explanation)
        h.model.runTidyAction("parts")
        #expect(action.runs == 1)

        // A book that is fine in parts is let off, and can be put back.
        let one = try #require(inParts.first)
        h.model.click(one, modifiers: [])
        await h.model.settle()
        await h.model.markSelectionFine()
        await h.model.settle()
        #expect(!h.model.rows.contains { $0.id == one })
        #expect(h.model.sidebar.tidy.last?.letOff == 1 && h.model.sidebar.tidy.last?.count == inParts.count - 1)
        await h.model.putBackLetOff()
        await h.model.settle()
        #expect(h.model.sidebar.tidy.last?.count == inParts.count)

        // The offer is withdrawn: at the next reading of the library the check is gone, and All Books is shown.
        action.offers = false
        await h.model.reloadAll()
        await h.model.settle()
        #expect(h.model.sidebar.tidy.map(\.check) == before)
        #expect(h.model.sidebarSelection == .allBooks && h.model.tidyHeader == nil)
    }
}
