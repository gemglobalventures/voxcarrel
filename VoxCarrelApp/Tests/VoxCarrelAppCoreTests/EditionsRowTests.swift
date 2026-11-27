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
            row(3, "Solo", work: "v"), row(4, "Solo", work: "v"), row(5, "Alone"),
        ]
        let items = SeriesGrouping.items(from: rows, sort: BookSort(), grouped: true, editions: true)
        #expect(Set(labels(items)) == ["s:1,2", "e:3,4", "b5"])
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

        // The grid: each edition a cover of its own.
        h.model.viewMode = .grid
        h.model.select([])
        #expect(!h.model.isGrouping && h.model.items.count == books)

        h.model.viewMode = .list
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

    @Test func aCheckOfTheLibrarysTidinessListsEachBook() {
        #expect(!AppModel.allowsGrouping(.tidy(.noCover), search: ""))
        #expect(AppModel.allowsGrouping(.allBooks, search: ""))
    }
}
