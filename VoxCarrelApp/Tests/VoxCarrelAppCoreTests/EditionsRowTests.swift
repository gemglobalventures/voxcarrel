import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// The editions of one work as one item of the list.
@Suite struct EditionsGroupingTests {
    private func row(_ id: Int64, _ title: String, work: String? = nil, series: String? = nil) -> BookRow {
        var metadata = BookMetadata(title: title, authors: ["Someone"])
        metadata.series = series
        var book = Book(metadata: metadata, dateAdded: Date(timeIntervalSinceReferenceDate: 0))
        book.id = id
        book.workKey = work
        return BookRow(id: id, book: book, hasAudio: true, hasEbook: false, formats: [.m4b], coverURL: nil, hasWriteProblem: false)
    }

    private func labels(_ items: [LibraryItem]) -> [String] {
        items.map {
            switch $0 {
            case .book(let row): "b\(row.id)"
            case .series(let group): "\(group.kind == .editions ? "e" : "s"):" + group.books.map { "\($0.id)" }.joined(separator: ",")
            }
        }
    }

    @Test func editionsAreOneItemWhereTheFirstStood() {
        let rows = [row(1, "Apple"), row(2, "Dune", work: "w"), row(3, "Emma"), row(4, "Dune", work: "w"), row(5, "Zed", work: "x")]
        let items = SeriesGrouping.items(from: rows, sort: BookSort(), grouped: false, editions: true)
        // A work with one edition here is a book like any other.
        #expect(labels(items) == ["b1", "e:2,4", "b3", "b5"])
        #expect(SeriesGrouping.hasEditions(among: rows))
        #expect(!SeriesGrouping.hasEditions(among: [rows[0], rows[1], rows[4]]))
        // Not asked for: each a book, as ever.
        #expect(labels(SeriesGrouping.items(from: rows, sort: BookSort(), grouped: false)) == ["b1", "b2", "b3", "b4", "b5"])
    }

    @Test func theGroupSpeaksAsOneBookInSeveralEditions() throws {
        let rows = [row(2, "Dune", work: "w", series: "Dune Saga"), row(4, "Dune", work: "w", series: "Dune Saga"), row(6, "Dune", work: "w")]
        let items = SeriesGrouping.items(from: [rows[0], rows[2]], sort: BookSort(), grouped: false, editions: true)
        guard case .series(let group) = try #require(items.first) else {
            Issue.record("not a group")
            return
        }
        #expect(group.titleText == "Dune" && group.countText == "2 editions" && group.seriesText == "Dune Saga")
        #expect(group.name == SeriesGroup.editionsName(workKey: "w"))
        #expect(items[0].titleSortKey == "Dune")
        #expect(!group.summaryText.contains("books"))
    }

    @Test func aSeriesGroupKeepsItsEditionsAsBooksOfTheSeries() {
        // Grouped by series as well: the series takes its books; editions outside one are a group.
        let rows = [
            row(1, "One", work: "w", series: "Saga"), row(2, "One", work: "w", series: "Saga"),
            row(6, "Two", series: "Saga"),
            row(3, "Solo", work: "v"), row(4, "Solo", work: "v"), row(5, "Alone"),
        ]
        let items = SeriesGrouping.items(from: rows, sort: BookSort(), grouped: true, editions: true)
        #expect(Set(labels(items)) == ["s:1,2,6", "e:3,4", "b5"])
        // Inside the series' row its editions are a row of their own, and one book of it.
        let found = items.compactMap { item -> SeriesGroup? in
            if case .series(let group) = item, group.kind == .series { return group }
            return nil
        }
        let saga = found[0]
        #expect(labels(saga.inner) == ["e:1,2", "b6"] && saga.countText == "2 books")
        #expect(saga.editionGroups.map(\.countText) == ["2 editions"] && saga.editionGroups[0].editionGroups.isEmpty)
    }
}

/// The editions row in the model: in the list, never in the grid; it opens in place.
@MainActor
@Suite struct EditionsRowTests {
    @Test func linkedEditionsAreOneRowOfTheListThatOpens() async throws {
        let h = try await Harness.demo()
        let salt = try h.id("Salt Road")
        let rivers = try h.id("Quiet Rivers")
        await h.model.linkEditions(for: [salt, rivers])
        let books = h.model.rows.count

        // The grid: the editions are one stack. Opening it shows the list with their row open.
        h.model.viewMode = .grid
        h.model.select([])
        #expect(h.model.isGrouping && h.model.items.count == books - 1)
        let stack = try #require(h.model.groups.first)
        h.model.openItems([stack.id])
        #expect(h.model.viewMode == .list && h.model.openGroups.contains(stack.name))
        h.model.setGroup(stack.name, open: false)

        #expect(h.model.isGrouping && h.model.items.count == books - 1)
        let group = try #require(h.model.groups.first)
        #expect(group.kind == .editions && Set(group.books.map(\.id)) == [salt, rivers])
        #expect(!h.model.groupsBySeries)

        // The row stands for both; opening it is done in place, and no series is shown.
        let shown = h.model.sidebarSelection
        h.model.selectItems([group.id])
        #expect(h.model.selection == [salt, rivers])
        h.model.openItems([group.id])
        #expect(h.model.openGroups.contains(group.name) && h.model.sidebarSelection == shown)
        h.model.openItems([group.id])
        #expect(!h.model.openGroups.contains(group.name))

        // One edition selected alone is never out of sight.
        h.model.select([salt])
        #expect(h.model.openGroups.contains(group.name))

        // Unlinked: two books again.
        await h.model.unlinkEdition(for: [salt])
        #expect(!h.model.isGrouping && h.model.items.count == books)
    }

    @Test func editionsInsideASeriesAreARowOfTheirOwnThere() async throws {
        let h = try await Harness.demo()
        h.model.viewMode = .list
        h.model.groupsBySeries = true
        // Two books of the demo's series, linked as editions of one work.
        let series = try #require(h.model.groups.first { $0.kind == .series && $0.books.count >= 3 })
        let pair = Array(series.books.prefix(2).map(\.id))
        let third = series.books[2].id
        await h.model.linkEditions(for: Set(pair))
        let after = try #require(h.model.group(named: series.name))
        let nested = try #require(after.editionGroups.first)
        #expect(Set(nested.books.map(\.id)) == Set(pair) && h.model.group(named: nested.name) == nested)
        #expect(after.countText == "\(series.books.count - 1) books")

        // The nested row stands for its editions, opens in place, and one edition
        // selected alone opens both rows so that it is in sight.
        h.model.setGroup(after.name, open: true)
        h.model.selectItems([nested.id])
        #expect(h.model.selection == Set(pair))
        h.model.openItems([nested.id])
        #expect(h.model.openGroups.contains(nested.name) && h.model.sidebarSelection == .allBooks)
        h.model.setGroup(nested.name, open: false)
        h.model.setGroup(after.name, open: false)
        h.model.select([pair[0]])
        #expect(h.model.openGroups.isSuperset(of: [after.name, nested.name]))
        // The series' row selected whole names every book of it, editions included.
        h.model.selectItems([after.id])
        #expect(h.model.selection == Set(after.books.map(\.id)) && h.model.selection.contains(third))
        #expect(h.model.itemSelection.contains(nested.id))
    }

    @Test func aCheckOfTheLibrarysTidinessListsEachBook() {
        #expect(!AppModel.allowsGrouping(.tidy(.noCover), search: ""))
        #expect(AppModel.allowsGrouping(.allBooks, search: ""))
    }
}
