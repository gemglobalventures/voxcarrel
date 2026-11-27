import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

private let seriesName = "Tidewater Chronicles"

/// A series checked against Wikidata's list of it. The demo library has three books
/// of "Tidewater Chronicles", numbered 1 to 3. Nothing reaches the network.
@MainActor
@Suite struct SeriesWikidataTests {
    private static let search = #"{"search":[{"id":"Q200","label":"Tidewater Chronicles","description":"series of novels"}]}"#

    private static func row(_ book: String, _ label: String, _ ordinal: String?) -> String {
        let place = ordinal.map { ",\"ordinal\":{\"value\":\"\($0)\"}" } ?? ""
        return "{\"s\":{\"value\":\"http://www.wikidata.org/entity/Q200\"},\"book\":{\"value\":\"http://www.wikidata.org/entity/\(book)\"},"
            + "\"bookLabel\":{\"value\":\"\(label)\"},\"authorLabel\":{\"value\":\"Ines Calloway\"}\(place)}"
    }

    private static let books = "{\"results\":{\"bindings\":[" + [
        row("Q201", "Salt Road", "1"), row("Q202", "The Drowned Bell", "2"), row("Q203", "Harbour of Glass", "3"),
        row("Q204", "The Glass Tide", "4"), row("Q205", "Lantern Reef", "5"),
    ].joined(separator: ",") + "]}}"

    /// A demo library showing its series, with Wikidata allowed. Audible lists
    /// `audible`; Wikidata knows the series unless `known` is false.
    private func shown(audible: [FakeCatalogue.Series] = [], known: Bool = true) async throws -> Harness {
        let h = try await Harness.demo(start: false)
        h.model.audibleStore = .us
        h.model.otherAudibleStores = []
        h.lookup.catalogue.set(audible)
        if known { h.lookup.catalogue.setWikidata(search: Self.search, books: Self.books) }
        await h.model.start()
        h.model.asksWikidataForSeries = true
        h.model.sidebarSelection = .browse(.series, seriesName)
        await h.model.settle()
        return h
    }

    private var onAudible: FakeCatalogue.Series {
        FakeCatalogue.Series(id: "B0TIDEWATR", title: seriesName, members: [
            .init(asin: "B0SALTROAD", title: "Salt Road", number: "1"),
            .init(asin: "B0DROWNBEL", title: "The Drowned Bell", number: "2"),
            .init(asin: "B0HARBOURG", title: "Harbour of Glass", number: "3"),
            .init(asin: "B0GLASSTID", title: "The Glass Tide", number: "4"),
        ])
    }

    // When Audible lists no series, Check Series asks Wikidata, and its list is kept
    // and said to be Wikidata's.
    @Test func whenAudibleHasNoListWikidataIsAsked() async throws {
        let h = try await shown()
        #expect(h.model.seriesHeader?.canCheck == true && h.model.seriesHeader?.canCheckWikidata == true)
        await h.model.checkSeries()
        #expect(h.model.alert == nil && h.model.busyLabel == nil)
        let header = try #require(h.model.seriesHeader)
        #expect(header.summary == "3 of 5 on Wikidata's list" && header.isLinked)
        #expect(header.source?.hasPrefix("Tidewater Chronicles · Wikidata · checked ") == true)
        #expect(header.numbersTitle == "Use Wikidata's Numbers")
        #expect(h.model.rows.filter(\.isMissing).map(\.book.title) == ["The Glass Tide", "Lantern Reef"])
        #expect(h.lookup.catalogue.wikidataRequests.count == 2)

        // A missing book of Wikidata's list can be shown there and hidden, not added as an Audible book.
        let row = try #require(h.model.rows.first { $0.isMissing && $0.book.title == "The Glass Tide" })
        let actions = try #require(h.model.missingActions(for: [row.id]))
        #expect(!actions.canAdd && actions.canShow && actions.canSetHidden && actions.showTitle == "Show on Wikidata")
        h.model.showMissingOnAudible(for: [row.id])
        #expect(h.opener.openedWeb.last?.absoluteString == "https://www.wikidata.org/wiki/Q204")
        await h.model.addMissingAsAudibleBook(for: [row.id])
        #expect(h.model.rows.filter(\.isMissing).count == 2)
        await h.model.setMissingHidden(true, for: [row.id])
        #expect(h.model.rows.filter(\.isMissing).map(\.book.title) == ["Lantern Reef"])
    }

    // When Wikidata has two series it could be, both by the series' author, the owner
    // is asked which; nothing is kept until one is chosen, and the one that holds more
    // of the library's books is offered first.
    @Test func severalSeriesOnWikidataAreOfferedAsAChoice() async throws {
        let h = try await shown(known: false)
        let search = #"{"search":[{"id":"Q300","label":"Tidewater Chronicles","description":"omnibus editions"},"#
            + #"{"id":"Q200","label":"Tidewater Chronicles","description":"series of novels"}]}"#
        func other(_ book: String, _ label: String) -> String {
            Self.row(book, label, "1").replacingOccurrences(of: "entity/Q200", with: "entity/Q300")
        }
        let books = "{\"results\":{\"bindings\":[" + [
            other("Q301", "Salt Road"), other("Q302", "Something Else"),
            Self.row("Q201", "Salt Road", "1"), Self.row("Q202", "The Drowned Bell", "2"),
            Self.row("Q203", "Harbour of Glass", "3"), Self.row("Q204", "The Glass Tide", "4"),
        ].joined(separator: ",") + "]}}"
        h.lookup.catalogue.setWikidata(search: search, books: books)

        await h.model.checkSeries()
        #expect(h.model.alert == nil && h.model.busyLabel == nil)
        let choices = try #require(h.model.seriesChoices)
        #expect(choices.map(\.id) == ["wikidata:Q200", "wikidata:Q300"])
        #expect(choices[0].detail == "Wikidata · 4 books · series of novels · 3 of your books are here")
        #expect(choices[1].detail == "Wikidata · 2 books · omnibus editions · 1 of your books is here")
        #expect(h.model.seriesChoiceExplanation.hasPrefix("Wikidata has more than one series"))
        #expect(h.model.seriesHeader?.isLinked == false)
        let asked = h.lookup.catalogue.wikidataRequests.count

        await h.model.chooseSeries("wikidata:Q200")
        #expect(h.model.seriesChoices == nil && h.model.alert == nil)
        #expect(h.model.seriesHeader?.summary == "3 of 4 on Wikidata's list")
        // The books came with the choices: nothing more was asked.
        #expect(h.lookup.catalogue.wikidataRequests.count == asked)

        // Cancelled, nothing changes.
        await h.model.checkSeries()
        h.model.cancelSeriesChoice()
        #expect(h.model.seriesChoices == nil && h.model.seriesHeader?.summary == "3 of 4 on Wikidata's list")
    }

    // Audible's list is used when it has one, and Wikidata is not asked; Check on
    // Wikidata then puts Wikidata's list in its place.
    @Test func audibleFirstThenWikidataWhenAsked() async throws {
        let h = try await shown(audible: [onAudible])
        await h.model.checkSeries()
        #expect(h.model.seriesHeader?.summary == "3 of 4 on Audible's list")
        #expect(h.lookup.catalogue.wikidataRequests.isEmpty)
        await h.model.checkSeriesOnWikidata()
        #expect(h.model.alert == nil && h.model.seriesHeader?.summary == "3 of 5 on Wikidata's list")
    }

    // With Wikidata switched off it is never asked; with Audible off, Check Series
    // asks Wikidata itself; and a series neither knows is said to be on neither.
    @Test func theSwitchesAreKept() async throws {
        let h = try await shown()
        h.model.asksWikidataForSeries = false
        #expect(h.model.seriesHeader?.canCheckWikidata == false)
        await h.model.checkSeries()
        #expect(h.model.alert == "Audible does not list a series for these books.")
        await h.model.checkSeriesOnWikidata()
        #expect(h.lookup.catalogue.wikidataRequests.isEmpty)
        h.model.alert = nil

        h.model.asksWikidataForSeries = true
        h.model.setLookupSource(.audible, on: false)
        await h.model.settle()
        #expect(h.model.seriesHeader?.canCheck == true && h.model.seriesHeader?.canCheckWikidata == false)
        let asked = h.lookup.catalogue.requests.count
        await h.model.checkSeries()
        #expect(h.model.seriesHeader?.summary == "3 of 5 on Wikidata's list")
        #expect(h.lookup.catalogue.requests.count == asked + 2 && h.lookup.catalogue.wikidataRequests.count == 2)

        let none = try await shown(known: false)
        await none.model.checkSeries()
        #expect(none.model.alert == "Neither Audible nor Wikidata lists a series for these books.")
        #expect(none.model.seriesHeader?.isLinked == false)
    }
}
