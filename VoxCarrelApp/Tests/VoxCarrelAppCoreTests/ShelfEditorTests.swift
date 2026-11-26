import Foundation
import Testing
import VoxCarrelCore

@testable import VoxCarrelAppCore

/// The editor of a smart shelf. SH19 onwards.
///
/// The demo library has three finished books, one of them ("The Lighthouse Keeper") by
/// Eleanor Marsh, and begins with the three starter shelves.
@MainActor
@Suite struct ShelfEditorTests {
    private func newEditor(_ h: Harness) async throws -> ShelfEditor {
        h.model.beginNewShelf()
        await h.model.settle()
        return try #require(h.model.shelfEditor)
    }

    private func row(_ editor: ShelfEditor, _ kind: ShelfConditionKind) throws -> ShelfConditionRow {
        try #require(editor.conditions.last { $0.kind == kind }, "no condition of kind \(kind)")
    }

    /// SH19: a new shelf begins with no name and no conditions, and cannot be saved.
    @Test func SH19_aNewShelfBeginsEmpty() async throws {
        let h = try await Harness.demo()
        #expect(h.model.canBeginShelf)
        let editor = try await newEditor(h)
        #expect(editor.title == "New Smart Shelf")
        #expect(editor.name == "")
        #expect(editor.matchesAll)
        #expect(editor.matchChoices.map(\.title) == ["All of these", "Any of these"])
        #expect(editor.matchChoices.map(\.matchesAll) == [true, false])
        #expect(editor.conditions.isEmpty)
        #expect(!editor.canSave)
        #expect(editor.matchText == "No books match")
        #expect(h.model.windowSheet(progressDue: false)?.id == "shelfEditor")
        #expect(
            editor.kinds.map(\.title) == [
                "Format", "Status", "Genre", "Genre group", "Author", "Narrator", "Series", "Tag", "Rating", "Length",
                "Year", "Added", "On Audible", "In a series",
            ])
        editor.cancel()
        #expect(h.model.shelfEditor == nil)
        #expect(h.model.shelves.count == 3)
    }

    /// SH20: each kind of condition begins with a sensible value, in words the sheet shows.
    /// Pages: fewer or more than a number of them, in steps of fifty.
    @Test func SH20b_pagesAreFewerOrMoreThanANumber() async throws {
        let h = try await Harness.demo()
        let editor = try await newEditor(h)
        editor.addCondition(.pages)
        var pages = try row(editor, .pages)
        #expect(ShelfConditionKind.pages.title == "Pages")
        #expect(pages.choices.map(\.title) == ["Fewer than", "More than"])
        #expect(pages.showsNumber && !pages.showsText && pages.numberIsWhole && pages.numberStep == 50)
        #expect(pages.number == 300 && pages.unit == "pages" && pages.condition == .fewerPagesThan(300))
        editor.setChoice(pages.choices[1].id, for: pages.id)
        editor.setNumber(1, for: pages.id)
        pages = try row(editor, .pages)
        #expect(pages.condition == .morePagesThan(1) && pages.unit == "page")
        // Out of range, or not whole: brought to what is allowed.
        editor.setNumber(0.4, for: pages.id)
        #expect(try row(editor, .pages).condition == .morePagesThan(1))
        editor.setNumber(250.6, for: pages.id)
        #expect(try row(editor, .pages).condition == .morePagesThan(251))
        // A stored condition comes back as the same row.
        let stored = ShelfConditionRow(id: 9, condition: .fewerPagesThan(120)) { _ in [] }
        #expect(stored.kind == .pages && stored.number == 120 && stored.condition == .fewerPagesThan(120))
    }

    @Test func SH20_aNewConditionHasASensibleValue() async throws {
        let h = try await Harness.demo()
        let editor = try await newEditor(h)
        for kind in ShelfConditionKind.allCases { editor.addCondition(kind) }
        #expect(editor.conditions.map(\.kind) == ShelfConditionKind.allCases)
        #expect(Set(editor.conditions.map(\.id)).count == ShelfConditionKind.allCases.count)

        let format = try row(editor, .format)
        #expect(format.choices.map(\.title) == ["Audiobook", "Ebook", "Audiobook and ebook"])
        #expect(format.condition == .format(.audiobook))
        let status = try row(editor, .status)
        #expect(status.choices.map(\.title) == ["Unread", "In Progress", "Finished"])
        #expect(status.condition == .status(.unread))
        #expect(try row(editor, .genreGroup).choices.count == GenreGroup.allCases.count)
        #expect(try row(editor, .genreGroup).condition == .genreGroup(GenreGroup.allCases[0]))

        // A name is typed, or picked from the library's own.
        for kind in [ShelfConditionKind.genre, .author, .narrator, .series, .tag] {
            let name = try row(editor, kind)
            #expect(name.showsText && !name.showsNumber && name.choices.isEmpty)
            #expect(name.text == "")
            #expect(name.condition == nil)
        }
        #expect(try row(editor, .author).suggestions.contains("Eleanor Marsh"))
        #expect(try row(editor, .series).suggestions == ["Tidewater Chronicles"])
        #expect(try row(editor, .genre).suggestions == h.model.sidebar.browse[.genre])
        #expect(try row(editor, .tag).suggestions == h.model.sidebar.tags)
        #expect(!h.model.sidebar.tags.isEmpty)

        let rating = try row(editor, .rating)
        #expect(rating.choices.map(\.title) == ["Rated", "Not rated"])
        #expect(rating.showsNumber && rating.number == 4 && rating.unit == "stars or more")
        #expect(rating.condition == .ratingAtLeast(4))
        let length = try row(editor, .length)
        #expect(length.choices.map(\.title) == ["Shorter than", "Longer than"])
        #expect(length.number == 6 && length.unit == "hours")
        #expect(length.condition == .shorterThan(hours: 6))
        let year = try row(editor, .year)
        #expect(year.choices.map(\.title) == ["From", "Up to"])
        #expect(year.condition == .yearFrom(2000))
        let added = try row(editor, .added)
        #expect(added.choices.isEmpty && added.prefix == "In the last" && added.unit == "days")
        #expect(added.condition == .addedWithin(days: 30))
        #expect(try row(editor, .onAudible).choices.map(\.title) == ["On Audible", "Not on Audible"])
        #expect(try row(editor, .onAudible).condition == .onAudible(true))
        #expect(try row(editor, .inASeries).choices.map(\.title) == ["In a series", "Not in a series"])
        #expect(try row(editor, .inASeries).condition == .inASeries(true))
    }

    /// SH21: the values are set through the editor, which keeps them in bounds.
    @Test func SH21_valuesAreSetAndKeptInBounds() async throws {
        let h = try await Harness.demo()
        let editor = try await newEditor(h)
        editor.addCondition(.rating)
        let id = try row(editor, .rating).id
        editor.setNumber(9, for: id)
        #expect(try row(editor, .rating).condition == .ratingAtLeast(5))
        editor.setNumber(1, for: id)
        #expect(try row(editor, .rating).unit == "star or more")
        editor.setChoice("unrated", for: id)
        #expect(try row(editor, .rating).condition == .unrated)
        #expect(try !row(editor, .rating).showsNumber)
        editor.setChoice("no such choice", for: id)
        #expect(try row(editor, .rating).condition == .unrated)

        // Another kind in the same place, with that kind's own first value.
        editor.setKind(.length, for: id)
        #expect(editor.conditions.map(\.id) == [id])
        editor.setChoice("longer", for: id)
        editor.setNumber(1.5, for: id)
        #expect(try row(editor, .length).condition == .longerThan(hours: 1.5))
        editor.setNumber(1, for: id)
        #expect(try row(editor, .length).unit == "hour")
        editor.setNumber(-3, for: id)
        #expect(try row(editor, .length).number > 0)

        editor.setKind(.year, for: id)
        editor.setChoice("to", for: id)
        editor.setNumber(1999.6, for: id)
        #expect(try row(editor, .year).condition == .yearTo(2000))
        editor.setKind(.added, for: id)
        editor.setNumber(0, for: id)
        #expect(try row(editor, .added).condition == .addedWithin(days: 1))
        #expect(try row(editor, .added).unit == "day")
        editor.setKind(.onAudible, for: id)
        editor.setChoice("no", for: id)
        #expect(try row(editor, .onAudible).condition == .onAudible(false))
        editor.setKind(.author, for: id)
        editor.setText("  Lena Voss ", for: id)
        #expect(try row(editor, .author).condition == .author("Lena Voss"))

        editor.removeCondition(id)
        #expect(editor.conditions.isEmpty)
    }

    /// SH22: a shelf can be saved when it has a name and a condition that is complete.
    @Test func SH22_aShelfNeedsANameAndACompleteCondition() async throws {
        let h = try await Harness.demo()
        let editor = try await newEditor(h)
        editor.name = "By Marsh"
        #expect(!editor.canSave)
        editor.addCondition(.author)
        #expect(!editor.canSave)
        editor.setText("   ", for: try row(editor, .author).id)
        #expect(!editor.canSave)
        editor.setText("Eleanor Marsh", for: try row(editor, .author).id)
        #expect(editor.canSave)
        editor.name = "   "
        #expect(!editor.canSave)
        // A name another shelf has is allowed.
        editor.name = "Short Listens"
        #expect(editor.canSave)
        // A condition that is not complete does not stand in the way of one that is.
        editor.addCondition(.tag)
        #expect(editor.canSave)
    }

    /// SH23: the sheet says how many books the shelf would hold now, after each change.
    @Test func SH23_theEditorSaysHowManyBooksMatch() async throws {
        let h = try await Harness.demo()
        let editor = try await newEditor(h)
        editor.addCondition(.status)
        editor.setChoice(ReadStatus.finished.rawValue, for: try row(editor, .status).id)
        // Until the library has answered, the last answer stays.
        #expect(editor.matchText == "No books match")
        await h.model.settle()
        #expect(editor.matchText == "3 books match")

        editor.addCondition(.author)
        await h.model.settle()
        // A condition that is not complete asks nothing.
        #expect(editor.matchText == "3 books match")
        editor.setText("eleanor marsh", for: try row(editor, .author).id)
        await h.model.settle()
        #expect(editor.matchText == "1 book matches")

        editor.matchesAll = false
        await h.model.settle()
        #expect(editor.matchText == "3 books match")
        editor.matchesAll = true
        editor.setText("Nobody at All", for: try row(editor, .author).id)
        await h.model.settle()
        #expect(editor.matchText == "No books match")
        editor.removeCondition(try row(editor, .author).id)
        await h.model.settle()
        #expect(editor.matchText == "3 books match")
        // Nothing was stored by any of this.
        #expect(h.model.shelves.count == 3)
    }

    /// SH24: saving a new shelf stores it, lists it, shows its books and closes the sheet.
    @Test func SH24_savingANewShelfStoresAndShowsIt() async throws {
        let h = try await Harness.demo()
        let editor = try await newEditor(h)
        editor.name = "  Finished by Marsh "
        editor.addCondition(.status)
        editor.setChoice(ReadStatus.finished.rawValue, for: try row(editor, .status).id)
        editor.addCondition(.author)
        editor.setText("Eleanor Marsh", for: try row(editor, .author).id)
        editor.addCondition(.narrator)
        await editor.save()

        #expect(h.model.shelfEditor == nil)
        #expect(h.model.alert == nil)
        #expect(h.model.busyLabel == nil)
        #expect(h.model.shelves.map(\.name).last == "Finished by Marsh")
        let saved = try #require(h.model.shelves.last)
        #expect(saved.count == 1)
        #expect(h.model.sidebarSelection == saved.item)
        #expect(h.titles == ["The Lighthouse Keeper"])
        let stored = try #require(try h.store().smartShelves().last)
        #expect(stored.id == saved.id)
        #expect(stored.matchesAll)
        // The condition that was not complete is left out.
        #expect(stored.conditions == [.status(.finished), .author("Eleanor Marsh")])
        #expect(h.model.undoMenuTitle == "Undo \(Harness.demoUndoLabel)")
    }

    /// SH25: an existing shelf opens as it is stored, and is saved in its own place.
    @Test func SH25_editingAShelfChangesItInPlace() async throws {
        let h = try await Harness.demo()
        let short = try #require(h.model.shelves.first { $0.name == "Short Listens" })
        h.model.beginEditShelf(9_999)
        #expect(h.model.shelfEditor == nil)
        h.model.beginEditShelf(short.id)
        let editor = try #require(h.model.shelfEditor)
        #expect(editor.title == "Edit Smart Shelf")
        #expect(editor.name == "Short Listens")
        #expect(editor.matchesAll)
        #expect(editor.conditions.map(\.kind) == [.format, .status, .length])
        #expect(editor.conditions.map(\.condition) == [.format(.audiobook), .status(.unread), .shorterThan(hours: 6)])
        #expect(editor.canSave)
        await h.model.settle()
        #expect(editor.matchText == (short.count == 1 ? "1 book matches" : "\(short.count) books match"))

        editor.name = "Finished or Marsh"
        editor.matchesAll = false
        editor.removeCondition(try row(editor, .format).id)
        editor.removeCondition(try row(editor, .length).id)
        editor.setChoice(ReadStatus.finished.rawValue, for: try row(editor, .status).id)
        editor.addCondition(.author)
        editor.setText("Eleanor Marsh", for: try row(editor, .author).id)
        await editor.save()

        #expect(h.model.shelfEditor == nil)
        #expect(h.model.shelves.map(\.name) == ["Finished or Marsh", "Recently Added", "Finished, Not Rated"])
        #expect(h.model.shelves.first?.id == short.id)
        #expect(h.model.shelves.first?.count == 3)
        #expect(h.model.sidebarSelection == .shelf(short.id))
        let stored = try #require(try h.store().smartShelves().first)
        #expect(!stored.matchesAll)
        #expect(stored.conditions == [.status(.finished), .author("Eleanor Marsh")])
    }

    /// SH26: every condition a shelf can hold is shown as a row that says the same.
    @Test func SH26_everyConditionOpensAsItWasStored() async throws {
        let h = try await Harness.demo()
        let all: [ShelfCondition] = [
            .format(.both), .status(.inProgress), .genre("Fantasy"), .genreGroup(GenreGroup.allCases[1]),
            .author("Lena Voss"), .narrator("Marcus Lindqvist"), .series("Tidewater Chronicles"), .tag("favourite"),
            .ratingAtLeast(3), .unrated, .shorterThan(hours: 2.5), .longerThan(hours: 12), .yearFrom(1990),
            .yearTo(2010), .addedWithin(days: 7), .onAudible(false), .inASeries(false),
        ]
        let saved = try #require(
            try LibraryService(store: try h.store()).saveSmartShelf(
                SmartShelf(name: "Everything", matchesAll: false, conditions: all)))
        await h.model.reloadAll()
        h.model.beginEditShelf(try #require(saved.id))
        let editor = try #require(h.model.shelfEditor)
        #expect(!editor.matchesAll)
        #expect(editor.conditions.map(\.condition) == all)
        #expect(editor.shelf.conditions == all)
    }

    /// SH27: one shelf sheet at a time, and never with another sheet of the window.
    @Test func SH27_theEditorDoesNotOpenOverAnotherSheet() async throws {
        let h = try await Harness.demo()
        let first = try await newEditor(h)
        h.model.beginNewShelf()
        #expect(h.model.shelfEditor === first)
        #expect(!h.model.canBeginShelf)
        let anyShelf = try #require(h.model.shelves.first)
        #expect(!h.model.canDeleteShelf(anyShelf.id))
        // Nor a sheet about genres while it is open.
        #expect(!h.model.canManageGenres)
        h.model.beginManageGenres()
        #expect(h.model.genreManager == nil)
        h.model.closeShelfEditor()
        #expect(h.model.shelfEditor == nil)

        h.model.beginManageGenres()
        #expect(h.model.genreManager != nil)
        #expect(!h.model.canBeginShelf)
        h.model.beginNewShelf()
        h.model.beginEditShelf(anyShelf.id)
        #expect(h.model.shelfEditor == nil)
        h.model.closeManageGenres()

        // Nor while a question is waiting.
        h.model.deleteShelf(anyShelf.id)
        h.model.beginNewShelf()
        #expect(h.model.shelfEditor == nil)
        h.model.prompt = nil
        h.model.beginNewShelf()
        #expect(h.model.shelfEditor != nil)

        // Another library is another library's shelves.
        await h.model.retryLibrary()
        #expect(h.model.shelfEditor == nil)
    }
}
