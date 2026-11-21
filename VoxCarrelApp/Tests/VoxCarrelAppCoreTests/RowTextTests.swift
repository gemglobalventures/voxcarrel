import Foundation
import Testing
import VoxCarrelAppCore
import VoxCarrelCore

/// What the grid and the list write about a book (plan Task 9). T1–T6.
@Suite struct RowTextTests {
    private func row(
        _ title: String = "Salt Road", authors: [String] = ["Ines Calloway"], audio: Bool = true,
        ebook: Bool = false, formats: [FileFormat] = [.m4b], change: (inout Book) -> Void = { _ in }
    ) -> BookRow {
        var book = Book(metadata: BookMetadata(title: title, authors: authors))
        book.id = 1
        change(&book)
        return BookRow(
            id: 1, book: book, hasAudio: audio, hasEbook: ebook, formats: formats, coverURL: nil,
            hasWriteProblem: false)
    }

    // MARK: T1 Length

    /// T1: hours and minutes, to the nearest minute.
    @Test func lengthIsHoursAndMinutes() {
        #expect(LengthText.text(seconds: 7 * 3600 + 42 * 60) == "7h 42m")
        #expect(LengthText.text(seconds: 7 * 3600 + 42 * 60 + 29) == "7h 42m")
        #expect(LengthText.text(seconds: 7 * 3600 + 42 * 60 + 30) == "7h 43m")
        #expect(LengthText.text(seconds: 3600) == "1h 0m")
        #expect(LengthText.text(seconds: 3599) == "1h 0m")
        #expect(LengthText.text(seconds: 125 * 3600) == "125h 0m")
    }

    /// T1: under an hour there are only minutes; under half a minute, "<1m".
    @Test func shortLengthsHaveNoHours() {
        #expect(LengthText.text(seconds: 42 * 60) == "42m")
        #expect(LengthText.text(seconds: 60) == "1m")
        #expect(LengthText.text(seconds: 30) == "1m")
        #expect(LengthText.text(seconds: 2) == "<1m")
    }

    /// T1: no length, or one that is not a length, is no text.
    @Test func noLengthIsNoText() {
        #expect(LengthText.text(seconds: nil) == nil)
        #expect(LengthText.text(seconds: 0) == nil)
        #expect(LengthText.text(seconds: -5) == nil)
        #expect(LengthText.text(seconds: .nan) == nil)
        #expect(LengthText.text(seconds: .infinity) == nil)
        #expect(row().lengthText == "")
        #expect(row { $0.durationSeconds = 5400 }.lengthText == "1h 30m")
    }

    // MARK: T2 Authors, series, formats

    /// T2
    @Test func authorsAreJoinedAndTheFirstStandsAlone() {
        let two = row(authors: ["Priya Nair", "Daniel Brandt"])
        #expect(two.authorsText == "Priya Nair, Daniel Brandt")
        #expect(two.firstAuthorText == "Priya Nair")
        let none = row(authors: [])
        #expect(none.authorsText == "")
        #expect(none.firstAuthorText == "")
        #expect(row(authors: ["  ", "Real Name"]).firstAuthorText == "Real Name")
    }

    /// T2
    @Test func seriesComesWithItsNumber() {
        #expect(row().seriesText == "")
        #expect(row { $0.series = "Tidewater Chronicles" }.seriesText == "Tidewater Chronicles")
        let numbered = row {
            $0.series = "Tidewater Chronicles"
            $0.seriesNumber = "2.5"
        }
        #expect(numbered.seriesText == "Tidewater Chronicles #2.5")
        // A number with no series says nothing.
        #expect(row { $0.seriesNumber = "3" }.seriesText == "")
        #expect(row { $0.series = "  " }.seriesText == "")
    }

    /// T2
    @Test func formatsAreNamedInCapitals() {
        #expect(row(formats: [.m4b, .epub]).formatsText == "M4B, EPUB")
        #expect(row(formats: []).formatsText == "")
    }

    // MARK: T3 Badges

    /// T3
    @Test func formsSayWhatThereIsToOpen() {
        #expect(row(audio: true, ebook: false).formsText == "Audiobook")
        #expect(row(audio: false, ebook: true).formsText == "Ebook")
        #expect(row(audio: true, ebook: true).formsText == "Audiobook and ebook")
        #expect(row(audio: false, ebook: false).formsText == nil)
    }

    /// T3: the warning triangle is for a book that needs attention or has a file whose tags were not written.
    @Test func warningCoversNeedsAttentionAndWriteProblems() {
        #expect(row().warningText == nil)
        #expect(row { $0.needsAttention = true }.warningText == "Needs attention")
        var troubled = row()
        troubled.hasWriteProblem = true
        #expect(troubled.warningText == "Tags could not be written to a file")
        troubled.book.needsAttention = true
        #expect(troubled.warningText == "Needs attention. Tags could not be written to a file")
    }

    /// T3
    @Test func readStatusesHaveNames() {
        #expect(ReadStatus.allCases.map(\.title) == ["Unread", "In Progress", "Finished"])
    }

    // MARK: T4 The cell's tooltip

    /// T4: the whole title, the authors, and what the badges mean.
    @Test func summaryNamesTheBookAndItsBadges() {
        #expect(row().summaryText == "Salt Road\nInes Calloway\nAudiobook")
        let busy = row(authors: [], audio: true, ebook: true) {
            $0.setReadStatus(.inProgress)
            $0.needsAttention = true
        }
        #expect(busy.summaryText == "Salt Road\nAudiobook and ebook · In Progress · Needs attention")
        // Nothing to say about its files or status: the title alone.
        #expect(row(authors: [], audio: false, ebook: false).summaryText == "Salt Road")
        #expect(row { $0.setReadStatus(.finished) }.summaryText == "Salt Road\nInes Calloway\nAudiobook · Finished")
    }

    // MARK: T5 Placeholder cover

    /// T5: the first letters of the first two words, leaving out a leading article.
    @Test func initialsComeFromTheTitle() {
        #expect(row("The Lighthouse Keeper").coverInitials == "LK")
        #expect(row("Quiet Rivers").coverInitials == "QR")
        #expect(row("a field guide to small hours").coverInitials == "FG")
        #expect(row("Dune").coverInitials == "D")
        #expect(row("The").coverInitials == "T")
        #expect(row("An").coverInitials == "A")
        #expect(row("“Salt” – road!").coverInitials == "SR")
        #expect(row("1984").coverInitials == "1")
        #expect(row("Émile ou de l’éducation").coverInitials == "ÉO")
    }

    /// T5
    @Test func aTitleWithNoLettersHasAQuestionMark() {
        #expect(row("").coverInitials == "?")
        #expect(row("  — ").coverInitials == "?")
    }

    /// T5: the tint is the same every time for a title, and between 0 and 1.
    @Test func placeholderHueIsSteadyAndInRange() {
        let titles = ["The Lighthouse Keeper", "Quiet Rivers", "Dune", "", "Émile", "Salt Road 1999"]
        for title in titles {
            let hue = row(title).placeholderHue
            #expect(hue >= 0 && hue < 1)
            #expect(row(title).placeholderHue == hue)
        }
        // Known values: the tint must not change from one launch to the next.
        #expect(row("Dune").placeholderHue == Double((((68 * 31 + 117) * 31 + 110) * 31 + 101) % 360) / 360)
        #expect(Set(titles.map { row($0).placeholderHue }).count > 3)
    }
}
