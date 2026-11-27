import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// A book's highlights exported as one Markdown note.
@MainActor
@Suite struct HighlightsMarkdownTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func row(_ text: String, note: String? = nil, location: Double? = nil, kind: HighlightLocationKind? = nil,
                     source: HighlightSource = .kindle, link: String? = nil) -> HighlightRow {
        let highlight = Highlight(
            bookId: 1, source: source, sourceId: UUID().uuidString, text: text, note: note, location: location,
            locationKind: kind, madeAt: Date(timeIntervalSince1970: 1_741_000_000), link: link)
        return HighlightRow(highlight, calendar: utc, locale: Locale(identifier: "en_GB"))
    }

    @Test func theNoteSaysWhatTheBookIsThenEachHighlight() throws {
        var details = BookMetadata(title: "Salt Road: A \"Coastal\" Tale", authors: ["Ines Calloway", "Second Writer"])
        details.series = "Tidewater Chronicles"
        details.seriesNumber = "1"
        details.year = 2021
        let book = Book(metadata: details)
        let rows = [
            row("The map is not the coast,\nonly a promise of it.", note: "For the talk", location: 180, kind: .location),
            row("", location: 3_600, kind: .time, source: .audible),
            row("A line from Readwise.", source: .readwise, link: "https://readwise.io/open/7"),
        ]
        let note = HighlightsMarkdown.note(for: book, highlights: rows, now: Date(timeIntervalSince1970: 1_795_000_000), calendar: utc)
        #expect(note == """
            ---
            title: "Salt Road: A \\"Coastal\\" Tale"
            author: ["Ines Calloway", "Second Writer"]
            series: "Tidewater Chronicles"
            series_number: "1"
            year: 2021
            highlights: 3
            exported: 2026-11-18
            ---

            # Salt Road: A "Coastal" Tale

            Ines Calloway, Second Writer

            ## Highlights

            > The map is not the coast,
            > only a promise of it.

            **Note:** For the talk

            Location 180 · 3 Mar 2025 · Kindle

            *Marked while listening*

            at 1 h 0 min · 3 Mar 2025 · Audible

            > A line from Readwise.

            [3 Mar 2025 · Readwise](https://readwise.io/open/7)

            """)
        #expect(HighlightsMarkdown.fileName(for: book) == "Salt Road A \"Coastal\" Tale highlights.md")
        #expect(HighlightsMarkdown.fileName(for: Book(metadata: BookMetadata(title: " ", authors: []))) == "Untitled book highlights.md")
    }

    @Test func theSheetExportsWhatItShows() async throws {
        let h = try await Harness.demo()
        let quiet = try h.id("Quiet Rivers")
        let store = try h.store()
        let service = LibraryService(store: store)
        try service.addHighlight(text: "Rivers do not hurry.", note: "Slow down", toBook: quiet)
        try service.addHighlight(text: "Stones stay.", note: nil, toBook: quiet)
        await h.model.reloadAll()
        try await h.select("Quiet Rivers")
        let session = try await h.highlightsSheet()
        #expect(session.canExport && session.exportFileName == "Quiet Rivers highlights.md")
        let all = try #require(session.markdown)
        #expect(all.contains("> Rivers do not hurry.") && all.contains("**Note:** Slow down") && all.contains("> Stones stay."))
        #expect(all.contains("title: \"Quiet Rivers\"") && all.contains("· Added here"))

        // Narrowed, only what is shown is exported; and the file is written as said.
        session.filterText = "stones"
        let url = try makeTempDir().appendingPathComponent("note.md")
        #expect(session.export(to: url))
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("> Stones stay.") && !written.contains("Rivers do not hurry") && written.contains("highlights: 1"))
        session.filterText = "nothing matches this"
        #expect(!session.canExport && session.markdown == nil && !session.export(to: url))
        // The library is as it was.
        #expect(try store.highlights(forBook: quiet).count == 2)
    }

    @Test func aNoteForBearHasNoPropertiesAndGoesInBearsOwnAddress() throws {
        var book = Book(metadata: BookMetadata(title: "Dune & More + Notes", authors: ["Frank Herbert"]))
        book.id = 7
        var one = Highlight(bookId: 7, source: .own, sourceId: "a", text: "Fear is the mind-killer.")
        one.id = 1
        let rows = [HighlightRow(one)]
        let plain = HighlightsMarkdown.note(for: book, highlights: rows, dated: false, properties: false)
        #expect(plain.hasPrefix("# Dune & More + Notes\n") && !plain.contains("title: ") && plain.contains("> Fear is the mind-killer."))
        // With them, as a file has it.
        #expect(HighlightsMarkdown.note(for: book, highlights: rows, dated: false).hasPrefix("---\ntitle: "))

        let url = try #require(BearNote.url(text: plain))
        #expect(url.scheme == "bear" && url.host == "x-callback-url" && url.path == "/create")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "text" }?.value == plain)
        #expect(items.first { $0.name == "tags" }?.value == "books/highlights" && items.first { $0.name == "open_note" }?.value == "yes")
        // An ampersand and a plus in the text do not break the address.
        #expect(url.absoluteString.contains("%26") && url.absoluteString.contains("%2B") && !url.absoluteString.contains("+"))
        #expect(BearNote.url(text: "") == nil && BearNote.url(text: String(repeating: "x", count: BearNote.longest + 1)) == nil)
    }
}
