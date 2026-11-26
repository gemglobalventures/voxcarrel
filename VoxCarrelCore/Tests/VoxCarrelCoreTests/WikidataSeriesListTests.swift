import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// WL1–WL2: Wikidata's list of a series kept for a series of the library.
@Suite struct WikidataSeriesListTests {
    typealias F = LibraryFixture

    private func imported(_ f: F, _ title: String, number: String) throws -> Int64 {
        var tags = BookMetadata(title: title, authors: ["Ines Calloway"])
        tags.series = "Tidewater"
        tags.seriesNumber = number
        let file = try f.makeM4B("\(title).m4b", tags: tags)
        let result = try f.service.importItems([ImportItem(candidate: f.candidate([file], tags))])
        return try f.importedId(result.outcomes[0])
    }

    private var list: WikidataSeries {
        WikidataSeries(id: "Q200", title: "Tidewater Chronicles", about: "series of novels", books: [
            WikidataSeriesBook(id: "Q201", title: "Salt Road", number: "1", authors: ["Ines Calloway"]),
            WikidataSeriesBook(id: "Q202", title: "The Drowned Bell", number: "2", authors: ["Ines Calloway"]),
            WikidataSeriesBook(id: "Q203", title: "Harbour of Glass", number: "3", authors: ["Ines Calloway"]),
            WikidataSeriesBook(id: "Q205", title: "A Tidewater Companion", number: nil, authors: ["Ines Calloway"]),
        ])
    }

    // WL1: the list is kept as Wikidata's; the library's books are matched to it by
    // title; what it lacks is missing, in order, the unnumbered one last; a book the
    // owner numbers otherwise is said to be numbered differently.
    @Test func WL1_wikidatasListIsKeptAndMatchedByTitle() throws {
        let f = try F()
        let salt = try imported(f, "Salt Road", number: "1")
        let harbour = try imported(f, "Harbour of Glass", number: "4")
        #expect(try f.service.seriesCompleteness(forSeries: "Tidewater") == nil)
        try f.service.saveSeriesList(list, forSeries: "Tidewater", now: Date(timeIntervalSince1970: 1_800_000_000))
        let state = try #require(try f.service.seriesCompleteness(forSeries: "Tidewater"))
        #expect(state.link.source == .wikidata && state.link.audibleSeriesId == "Q200")
        #expect(state.link.audibleSeriesTitle == "Tidewater Chronicles")
        #expect(state.ownedCount == 2 && state.totalCount == 4)
        #expect(state.missing.map(\.entry.preferred.title) == ["The Drowned Bell", "A Tidewater Companion"])
        #expect(state.missing.map(\.entry.number) == ["2", nil] && state.missing.map(\.entry.preferred.asin) == ["Q202", "Q205"])
        #expect(state.numberDifferences == [harbour: "3"] && state.notInList.isEmpty)
        _ = salt
        // The owner's numbers can be made the list's, as with any source.
        #expect(try f.service.editsUsingAudibleNumbers(forSeries: "Tidewater").map(\.metadata.seriesNumber) == ["3"])
    }

    // WL2: a list from another source takes the place of the one kept, and an entry
    // hidden under one source's list is not kept hidden by its number under another's.
    @Test func WL2_oneSourceTakesThePlaceOfAnother() throws {
        let f = try F()
        _ = try imported(f, "Salt Road", number: "1")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let audible = AudibleSeriesList(
            ref: AudibleSeriesRef(id: "B0SERIES01", title: "Tidewater", number: nil, store: .us),
            editions: [
                AudibleSeriesEdition(asin: "B000000001", title: "Salt Road", number: "1", sort: 1),
                AudibleSeriesEdition(asin: "B000000002", title: "The Drowned Bell", number: "2", sort: 2),
            ])
        try f.service.saveSeriesList(audible, forSeries: "Tidewater", now: now)
        var state = try #require(try f.service.seriesCompleteness(forSeries: "Tidewater"))
        #expect(state.link.source == .audible && state.missing.count == 1)
        try f.service.setMissingEntry(id: state.missing[0].id, hidden: true)

        try f.service.saveSeriesList(list, forSeries: "Tidewater", now: now)
        state = try #require(try f.service.seriesCompleteness(forSeries: "Tidewater"))
        #expect(state.link.source == .wikidata && state.missing.count == 3 && state.missing.allSatisfy { !$0.isHidden })
        try f.service.unlinkSeries(named: "Tidewater")
        #expect(try f.service.seriesCompleteness(forSeries: "Tidewater") == nil)
        #expect(SeriesSource.wikidata.title == "Wikidata" && SeriesSource.audible.title == "Audible")
    }
}
