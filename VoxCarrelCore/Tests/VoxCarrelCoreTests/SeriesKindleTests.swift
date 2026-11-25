import Foundation
import Testing
@testable import VoxCarrelCore

/// SK1–SK3: a series made up of books owned in different places.
@Suite struct SeriesKindleTests {
    typealias F = LibraryFixture
    static let series = "Jack Ryan"

    @discardableResult
    private func add(
        _ f: F, _ title: String, author: String = "Tom Clancy", number: String? = nil, series: String? = SeriesKindleTests.series,
        asin: String? = nil, copies: [ExternalCopy] = []
    ) throws -> Int64 {
        var metadata = BookMetadata(title: title, authors: [author])
        metadata.series = series
        metadata.seriesNumber = number
        metadata.asin = asin
        var book = Book(metadata: metadata)
        book.externalCopies = copies
        return try #require(try f.store.insert(book, files: []).id)
    }

    private func checked(_ f: F) throws -> SeriesCompleteness {
        try f.service.saveSeriesList(SeriesStoreTests.list(SeriesStoreTests.four), forSeries: Self.series, now: Date())
        return try #require(try f.service.seriesCompleteness(forSeries: Self.series))
    }

    @Test func SK1_aSeriesIsCompleteWithBooksOwnedOnThisMacOnAudibleAndOnKindle() throws {
        let f = try F()
        try add(f, "The Hunt for Red October", number: "1", asin: "B000000001")
        try add(f, "Patriot Games", number: "2", copies: [ExternalCopy(kind: .audible, form: .audio, itemId: "B000000002")])
        try add(f, "The Cardinal of the Kremlin", number: "3", copies: [ExternalCopy(kind: .kindle, form: .ebook, itemId: "B00KINDLE03")])
        try add(f, "Clear and Present Danger", number: "4", copies: [ExternalCopy(kind: .kindle, form: .ebook, itemId: "B00KINDLE04")])
        let result = try checked(f)
        #expect(result.ownedCount == 4 && result.totalCount == 4 && result.missing.isEmpty)
    }

    @Test func SK2_aKindleBookWithNoSeriesOfItsOwnStillCountsWhenItIsSurelyTheSameBook() throws {
        let f = try F()
        try add(f, "The Hunt for Red October", number: "1", asin: "B000000001")
        // As the Kindle library gives it: the right title and author, and no series.
        let kindle = try add(
            f, "Patriot Games", series: nil, copies: [ExternalCopy(kind: .kindle, form: .ebook, itemId: "B00KINDLE02")])
        // The same title by somebody else is another book.
        try add(f, "The Cardinal of the Kremlin", author: "Somebody Else", series: nil)
        let result = try checked(f)
        #expect(result.ownedCount == 2 && result.missing.map(\.entry.preferred.title) == ["The Cardinal of the Kremlin", "Clear and Present Danger"])
        // It is counted, and stays where it is filed.
        #expect(try f.store.book(id: kindle)?.series == nil)
    }

    @Test func SK3_aBookFiledUnderAnotherSeriesOrHiddenIsNotCountedAndAHiddenOneIsNotNamed() throws {
        let f = try F()
        try add(f, "The Hunt for Red October", number: "1", asin: "B000000001")
        // The same title and author, filed under another series: another book.
        try add(f, "Patriot Games", series: "Something Else")
        let hidden = try add(f, "The Cardinal of the Kremlin", series: nil, copies: [ExternalCopy(kind: .kindle, form: .ebook, itemId: "B00K3")])
        try f.store.setHidden(true, bookIds: [hidden])
        let all = try checked(f)
        // Seen whole, the hidden one is a book like any other.
        #expect(all.ownedCount == 2 && all.missing.map(\.entry.preferred.title) == ["Patriot Games", "Clear and Present Danger"])
        let shown = try #require(try BookScope.visible { () throws -> SeriesCompleteness? in try f.service.seriesCompleteness(forSeries: Self.series) })
        #expect(shown.ownedCount == 1 && shown.missing.map(\.entry.preferred.title) == ["Patriot Games", "Clear and Present Danger"])
    }
}
