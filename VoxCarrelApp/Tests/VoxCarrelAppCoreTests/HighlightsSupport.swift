import Foundation
import Testing
import VoxCarrelCore

@testable import VoxCarrelAppCore

/// What stands in for the clipboard where the app writes to it: it keeps what was put there.
@MainActor
final class FakeClipboardWriter {
    private(set) var written: [String] = []

    func write(_ text: String) {
        written.append(text)
    }
}

enum HighlightSamples {
    /// A highlight as a source gives it.
    static func incoming(
        _ id: String, _ text: String, note: String? = nil, location: Double? = nil, end: Double? = nil,
        kind: HighlightLocationKind? = .location, madeAt: Date? = nil, link: String? = nil
    ) -> IncomingHighlight {
        var highlight = IncomingHighlight(sourceId: id, text: text)
        highlight.note = note
        highlight.location = location
        highlight.endLocation = end
        highlight.locationKind = location == nil ? nil : kind
        highlight.madeAt = madeAt
        highlight.link = link
        return highlight
    }

    /// A book as Readwise names one that was highlighted on a Kindle.
    static func kindleBook(
        _ title: String, author: String = "Ann Author", asin: String? = "B00KINDLE01", cover: String? = nil,
        _ highlights: [IncomingHighlight]
    ) -> HighlightedBook {
        var book = HighlightedBook(title: title, authors: [author], source: .readwise, highlights: highlights)
        book.itemId = asin
        book.ownedOn = .kindle
        book.coverURL = cover.flatMap(URL.init(string:))
        return book
    }

    /// One highlight of Readwise's answer.
    static func readwiseHighlight(
        _ id: Int, _ text: String, location: Int? = nil, note: String = "", deleted: Bool = false
    ) -> [String: Any] {
        var item: [String: Any] = [
            "id": id, "text": text, "note": note, "location_type": "location", "is_deleted": deleted,
            "highlighted_at": "2016-05-04T03:02:01Z", "readwise_url": "https://readwise.io/open/\(id)",
        ]
        if let location { item["location"] = location }
        return item
    }

    /// One book of Readwise's answer.
    static func readwiseBook(
        _ title: String, author: String = "Ann Author", asin: String? = "B00KINDLE01", source: String = "kindle",
        cover: String = "https://m.media-amazon.com/images/I/x.jpg", highlights: [[String: Any]]
    ) -> [String: Any] {
        var item: [String: Any] = [
            "user_book_id": 1, "title": title, "author": author, "category": "books", "source": source,
            "cover_image_url": cover, "highlights": highlights, "is_deleted": false,
        ]
        if let asin { item["asin"] = asin }
        return item
    }

    /// One record of Audible's answer for a book's marks: a bookmark, or a clip when it has an end.
    static func mark(_ id: String, at start: Int, end: Int? = nil, note: String? = nil) -> [String: Any] {
        var record: [String: Any] = [
            "type": end == nil ? "audible.bookmark" : "audible.clip", "annotationId": id,
            "startPosition": String(start * 1000), "creationTime": "2026-09-18 10:21:35.0",
        ]
        if let end { record["endPosition"] = String(end * 1000) }
        if let note { record["metadata"] = ["note": note] }
        return record
    }
}

extension FakeAudibleTransport {
    /// Readwise holds these books. One page of them.
    func readwiseHolds(_ books: [[String: Any]]) {
        answer("/api/v2/export", with: ["count": books.count, "nextPageCursor": NSNull(), "results": books])
    }

    /// Audible holds these marks for the book with this ID.
    func holdsMarks(_ records: [[String: Any]], for asin: String) {
        answer(
            "/FionaCDEServiceEngine/sidecar", query: "type=AUDI&key=\(asin)",
            with: ["payload": ["records": records]])
    }
}

extension Harness {
    /// The library's engine on a connection of the test's own, for setting up.
    func service() throws -> LibraryService {
        LibraryService(store: try store())
    }

    /// Brings highlights into the library behind the model's back, and has the model
    /// read everything again.
    @discardableResult
    func bringIn(_ books: [HighlightedBook]) async throws -> HighlightsReport {
        let report = try service().bringInHighlights(books, apply: true)
        await model.reloadAll()
        return report
    }

    /// Gives a book of the library highlights from a source: Readwise's unless another is named.
    func highlight(
        _ title: String, source: HighlightSource = .readwise, _ highlights: [IncomingHighlight]
    ) async throws {
        let book = try book(try id(title))
        try await bringIn([HighlightedBook(title: book.title, authors: book.authors, source: source, highlights: highlights)])
    }

    /// Opens the sheet of the inspected book's highlights and waits for it to have read them.
    func highlightsSheet(adding: Bool = false) async throws -> HighlightsSession {
        model.beginHighlights(adding: adding)
        let session = try #require(model.highlights)
        await session.reading?.value
        return session
    }

    /// Opens Import Highlights, starts it, and waits for it to have read everything.
    func highlightsImportRead() async throws -> HighlightsImportSession {
        model.beginHighlightsImport()
        let session = try #require(model.highlightsImport)
        session.start()
        await session.reading?.value
        return session
    }
}
