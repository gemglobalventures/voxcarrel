import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// HL14–HL21: a book's highlights as the rows, the inspector, the sheet, the sidebar and
/// the search have them. Nothing here reaches the network or the real clipboard.
@MainActor
@Suite struct HighlightsOnBooksTests {
    typealias S = HighlightSamples

    private static let rivers = "Quiet Rivers"

    private func row(_ h: Harness, _ title: String) throws -> BookRow {
        let id = try h.id(title)
        return try #require(h.model.rows.first { $0.id == id })
    }

    // MARK: Counts and the inspector

    @Test func HL14_rowsAndTheInspectorSayHowManyHighlightsABookHas() async throws {
        let h = try await Harness.demo()
        let rivers = try h.id(Self.rivers)
        #expect(h.model.highlightCount(for: rivers) == 0)
        #expect(try row(h, Self.rivers).highlightCount == 0)
        #expect(try row(h, Self.rivers).highlightCountText == "")
        // Nothing selected: nothing to say.
        #expect(h.model.inspectedHighlights == nil)

        try await h.select(Self.rivers)
        var summary = try #require(h.model.inspectedHighlights)
        #expect(summary.countText == "No highlights")
        #expect(summary.first.isEmpty && !summary.hasMore)

        try await h.highlight(Self.rivers, [S.incoming("a", "The river runs slow.", location: 20)])
        summary = try #require(h.model.inspectedHighlights)
        #expect(summary.countText == "1 highlight")
        #expect(summary.first.map(\.text) == ["The river runs slow."])
        #expect(!summary.hasMore)
        #expect(try row(h, Self.rivers).highlightCount == 1)

        try await h.highlight(Self.rivers, [
            S.incoming("b", "Second.", location: 30), S.incoming("c", "Third.", location: 40),
            S.incoming("d", "First of all.", location: 10),
        ])
        summary = try #require(h.model.inspectedHighlights)
        #expect(summary.countText == "4 highlights")
        // The first three, in the order of the book.
        #expect(summary.first.map(\.text) == ["First of all.", "The river runs slow.", "Second."])
        #expect(summary.hasMore)
        #expect(h.model.highlightCount(for: rivers) == 4)
        #expect(try row(h, Self.rivers).highlightCount == 4)
        #expect(try row(h, Self.rivers).highlightCountText == "4")
        // Every other row has none, and nothing was asked row by row.
        #expect(h.model.rows.filter { $0.id != rivers }.allSatisfy { $0.highlightCount == 0 })
        #expect(h.detail?.row.highlightCount == 4)

        // Several books selected: nothing to say.
        try await h.select([Self.rivers, "Salt Road"])
        #expect(h.model.inspectedHighlights == nil)
    }

    @Test func HL15_aHighlightSaysItsPlaceItsDayAndWhereItCameFrom() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let locale = Locale(identifier: "en_GB")
        func row(_ change: (inout Highlight) -> Void) -> HighlightRow {
            var highlight = Highlight(bookId: 1, source: .readwise, sourceId: "x", text: "Words.")
            highlight.id = 7
            change(&highlight)
            return HighlightRow(highlight, calendar: calendar, locale: locale)
        }
        func place(_ location: Double?, _ kind: HighlightLocationKind?, end: Double? = nil) -> String? {
            row {
                $0.location = location
                $0.locationKind = kind
                $0.endLocation = end
            }.placeText
        }
        #expect(place(1204, .location) == "Location 1,204")
        #expect(place(87, .page) == "Page 87")
        #expect(place(1, .page) == "Page 1")
        let late = Double(16 * 3600 + 54 * 60 + 12)
        #expect(place(late, .time) == "at 16 h 54 min")
        #expect(place(late, .time, end: late + 30) == "at 16 h 54 min, 30 seconds long")
        #expect(place(late, .time, end: late + 1) == "at 16 h 54 min, 1 second long")
        #expect(place(late, .time, end: late + 150) == "at 16 h 54 min, 2 min 30 sec long")
        #expect(place(late, .time, end: late + 120) == "at 16 h 54 min, 2 min long")
        #expect(place(3600, .time) == "at 1 h 0 min")
        #expect(place(125, .time) == "at 2 min")
        #expect(place(42, .time) == "at 42 sec")
        // An end that is no end says nothing.
        #expect(place(late, .time, end: late) == "at 16 h 54 min")
        // A place in the source's own order is no place to name, and none is none.
        #expect(place(3, .order) == nil)
        #expect(place(nil, nil) == nil)
        #expect(place(12, nil) == nil)

        let plain = row { _ in }
        #expect(plain.id == 7 && plain.text == "Words." && plain.note == nil)
        #expect(plain.dateText == nil && plain.link == nil)
        #expect(plain.sourceText == "Readwise" && !plain.isOwn && !plain.isEmptyMark && plain.markText == nil)
        let dated = row {
            $0.madeAt = Date(timeIntervalSince1970: 1_462_330_921)
            $0.link = "https://readwise.io/open/7"
            $0.note = "  mine  "
        }
        #expect(dated.dateText == "4 May 2016")
        #expect(dated.link == URL(string: "https://readwise.io/open/7"))
        #expect(dated.note == "mine")
        // Only an address that is encrypted is one to open.
        #expect(row { $0.link = "http://readwise.io/open/7" }.link == nil)
        #expect(row { $0.link = "file:///etc/passwd" }.link == nil)
        #expect(row { $0.source = .audible }.sourceText == "Audible")
        let own = row { $0.source = .own }
        #expect(own.sourceText == "Added here" && own.isOwn)
        // A mark with no words and no note.
        let mark = row {
            $0.source = .audible
            $0.text = " "
            $0.note = ""
        }
        #expect(mark.isEmptyMark && mark.markText == "Marked while listening" && mark.note == nil)
        #expect(!row { $0.text = ""; $0.note = "a thought" }.isEmptyMark)

        #expect(HighlightsSummary(count: 0, highlights: []).countText == "No highlights")
        #expect(HighlightsSummary(count: 1, highlights: []).countText == "1 highlight")
        #expect(HighlightsSummary(count: 12, highlights: []).countText == "12 highlights")
        #expect(HighlightsSummary(count: 1204, highlights: []).countText == "1,204 highlights")
    }

    // MARK: The sheet

    /// A demo library whose "Quiet Rivers" has three highlights from Readwise and a
    /// bare mark from Audible, with that book selected.
    private func withHighlights() async throws -> Harness {
        let h = try await Harness.demo()
        try await h.highlight(Self.rivers, [
            S.incoming("a", "The river runs slow.", note: "Slow!", location: 20, link: "https://readwise.io/open/1"),
            S.incoming("b", "Stones under water.", location: 10),
            S.incoming("c", "No place for this one."),
        ])
        try await h.highlight(Self.rivers, source: .audible, [S.incoming("m", "", location: 5, kind: .time)])
        try await h.select(Self.rivers)
        return h
    }

    @Test func HL16_theSheetListsTheBooksHighlightsAndNarrowsCopiesAndOpensThem() async throws {
        let h = try await withHighlights()
        #expect(h.model.canShowHighlights)
        let session = try await h.highlightsSheet()
        #expect(h.model.windowSheet(progressDue: false) == .highlights(SheetObject(session)))
        #expect(session.title == Self.rivers)
        #expect(session.countText == "4 highlights")
        #expect(!session.isAdding)
        // In the order of the book: by place, then those with none.
        #expect(session.rows.map(\.text) == ["", "Stones under water.", "The river runs slow.", "No place for this one."])
        #expect(session.rows.first?.markText == "Marked while listening")
        #expect(session.rows.first?.placeText == "at 5 sec")

        session.filterText = "slow"
        #expect(session.rows.map(\.text) == ["The river runs slow."])
        // Words in any order, in the passage or the note, whatever their case.
        session.filterText = "SLOW! river"
        #expect(session.rows.map(\.text) == ["The river runs slow."])
        session.filterText = "stones slow"
        #expect(session.rows.isEmpty)
        #expect(session.emptyText == "No highlights match.")
        session.filterText = "   "
        #expect(session.rows.count == 4)
        #expect(session.emptyText == nil)

        let slow = try #require(session.rows.first { $0.note == "Slow!" })
        let stones = try #require(session.rows.first { $0.text.hasPrefix("Stones") })
        let mark = try #require(session.rows.first)
        session.copy(slow)
        session.copy(stones)
        #expect(h.clipboardWriter.written == ["The river runs slow.\nSlow!", "Stones under water."])
        // A bare mark has no words to copy.
        #expect(!session.canCopy(mark) && session.canCopy(slow))
        session.copy(mark)
        #expect(h.clipboardWriter.written.count == 2)

        session.open(slow)
        #expect(h.opener.openedWeb == [try #require(URL(string: "https://readwise.io/open/1"))])
        session.open(stones)
        #expect(h.opener.openedWeb.count == 1)

        session.close()
        #expect(h.model.highlights == nil)
        #expect(h.model.windowSheet(progressDue: false) == nil)
    }

    @Test func HL17_aHighlightOfTheOwnersOwnIsAddedToAnyBook() async throws {
        let h = try await Harness.demo()
        #expect(!h.model.canAddHighlight && !h.model.canShowHighlights)
        h.model.beginHighlights(adding: true)
        #expect(h.model.highlights == nil)
        // A book with audio files and no ebook: any book of the library will do.
        let audio = try #require(h.model.rows.first { $0.hasAudio && !$0.hasEbook && $0.hasFiles })
        h.model.click(audio.id, modifiers: [])
        await h.model.settle()
        #expect(h.model.canAddHighlight)

        let session = try await h.highlightsSheet(adding: true)
        #expect(session.isAdding)
        #expect(session.rows.isEmpty && session.emptyText == "This book has no highlights yet.")
        #expect(!session.canAdd)
        session.newText = "  \n "
        #expect(!session.canAdd)
        session.newNote = "a thought of my own"
        #expect(session.canAdd)
        h.recordBusyLabels()
        await session.add()
        #expect(h.busyLabels == ["Adding highlight…"])
        #expect(h.model.alert == nil)
        var added = try #require(session.rows.first)
        #expect(session.rows.count == 1)
        #expect(added.text == "" && added.note == "a thought of my own")
        #expect(added.isOwn && added.sourceText == "Added here" && added.dateText != nil && !added.isEmptyMark)
        // The form is put away, and empty for the next.
        #expect(!session.isAdding && session.newText == "" && session.newNote == "")
        #expect(h.model.highlightCount(for: audio.id) == 1)
        #expect(h.model.inspectedHighlights?.countText == "1 highlight")
        #expect(try h.store().highlights(forBook: audio.id).map(\.source) == [.own])

        session.beginAdd()
        #expect(session.isAdding)
        session.newText = "  A passage worth keeping.  "
        #expect(session.canAdd)
        await session.add()
        #expect(session.rows.count == 2)
        added = try #require(session.rows.first { $0.text == "A passage worth keeping." })
        #expect(added.note == nil)
        // Begun and thought better of: nothing is added, and what was typed goes.
        session.beginAdd()
        session.newText = "Not this."
        session.cancelAdd()
        #expect(!session.isAdding && session.newText == "")
        await session.add()
        #expect(session.rows.count == 2)

        // Two books selected: no one book to add to.
        session.close()
        try await h.select([Self.rivers, "Salt Road"])
        #expect(!h.model.canAddHighlight)
    }

    @Test func HL18_aNoteIsWrittenOnAHighlightChangedAndTakenAway() async throws {
        let h = try await withHighlights()
        let session = try await h.highlightsSheet()
        let slow = try #require(session.rows.first { $0.note == "Slow!" })
        session.editNote(slow)
        #expect(session.editing?.id == slow.id)
        #expect(session.noteDraft == "Slow!")
        session.noteDraft = "  Slower still.  "
        await session.saveNote()
        #expect(session.editing == nil)
        #expect(session.rows.first { $0.id == slow.id }?.note == "Slower still.")
        #expect(session.rows.first { $0.id == slow.id }?.text == "The river runs slow.")
        #expect(h.model.inspectedHighlights?.first.contains { $0.note == "Slower still." } == true)

        // Begun and put away: the note stays as it was.
        let stones = try #require(session.rows.first { $0.text.hasPrefix("Stones") })
        session.editNote(stones)
        #expect(session.noteDraft == "")
        session.noteDraft = "never kept"
        session.cancelEditNote()
        #expect(session.editing == nil)
        await session.saveNote()
        #expect(session.rows.first { $0.id == stones.id }?.note == nil)

        // A blank note takes the note away.
        session.editNote(try #require(session.rows.first { $0.id == slow.id }))
        session.noteDraft = "   "
        await session.saveNote()
        #expect(session.rows.first { $0.id == slow.id }?.note == nil)
        #expect(session.rows.count == 4)
    }

    @Test func HL19_deletingAsksFirstAndSaysWhenAHighlightWillComeBack() async throws {
        let h = try await withHighlights()
        let rivers = try h.id(Self.rivers)
        let session = try await h.highlightsSheet(adding: true)
        session.newText = "My own."
        await session.add()
        #expect(session.rows.count == 5)

        let fromReadwise = try #require(session.rows.first { $0.text.hasPrefix("Stones") })
        session.delete(fromReadwise)
        #expect(session.deleting?.id == fromReadwise.id)
        #expect(session.deleteTitle == "Delete this highlight?")
        #expect(session.deleteMessage == "It will come back the next time highlights are imported from Readwise.")
        // Not yet.
        #expect(session.rows.count == 5)
        session.cancelDelete()
        #expect(session.deleting == nil && session.deleteMessage == nil)
        await session.confirmDelete()
        #expect(session.rows.count == 5)

        session.delete(fromReadwise)
        await session.confirmDelete()
        #expect(session.deleting == nil)
        #expect(session.rows.count == 4 && !session.rows.contains { $0.id == fromReadwise.id })
        #expect(h.model.highlightCount(for: rivers) == 4)

        let mark = try #require(session.rows.first { $0.isEmptyMark })
        session.delete(mark)
        #expect(session.deleteMessage == "It will come back the next time highlights are imported from Audible.")
        session.cancelDelete()

        let own = try #require(session.rows.first { $0.isOwn })
        session.delete(own)
        #expect(session.deleteMessage == "It is one you added here, and cannot be brought back.")
        await session.confirmDelete()
        #expect(session.rows.count == 3 && !session.rows.contains(where: \.isOwn))
        #expect(try h.store().highlights(forBook: rivers).count == 3)
    }

    // MARK: The sidebar and the search

    @Test func HL20_highlightsIsInTheSidebarWhileAnyBookHasOne() async throws {
        let h = try await Harness.demo()
        #expect(!h.model.showsHighlights && h.model.highlightedBookCount == 0)
        #expect(h.model.title(of: .highlights) == "Highlights")
        #expect(!SidebarItem.fixed.contains(.highlights))
        h.model.sidebarSelection = .highlights
        await h.model.settle()
        await h.model.reloadAll()
        #expect(h.model.sidebarSelection == .allBooks)

        try await h.highlight("Salt Road", [S.incoming("s1", "Salt."), S.incoming("s2", "Road.")])
        try await h.highlight(Self.rivers, [S.incoming("r1", "A kingfisher, once.", note: "halcyon days")])
        #expect(h.model.showsHighlights)
        // Books, not highlights.
        #expect(h.model.highlightedBookCount == 2)
        h.model.sidebarSelection = .highlights
        await h.model.settle()
        #expect(h.titles == [Self.rivers, "Salt Road"])
        #expect(h.model.windowTitle == "Highlights")

        // The last highlight gone, so is the item.
        let service = try h.service()
        for book in try h.ids([Self.rivers, "Salt Road"]) {
            for highlight in try service.highlights(forBook: book) {
                try service.deleteHighlight(id: try #require(highlight.id))
            }
        }
        await h.model.reloadAll()
        #expect(!h.model.showsHighlights)
        #expect(h.model.sidebarSelection == .allBooks)
    }

    /// The search leaves highlights out until it is told in Settings to look in them.
    @Test func HL20b_theSearchLeavesHighlightsOutUntilToldOtherwise() async throws {
        let h = try await Harness.demo()
        try await h.highlight(Self.rivers, [S.incoming("r1", "A kingfisher, once.", note: "halcyon days")])
        // Off to begin with: a search finds books by their own details alone.
        #expect(!h.model.searchFindsHighlights)
        h.model.searchText = "kingfisher"
        await h.model.settle()
        #expect(h.titles.isEmpty)
        // Turned on in Settings, the words of a highlight find their book.
        h.model.searchFindsHighlights = true
        for _ in 0..<200 where h.titles != [Self.rivers] { try? await Task.sleep(nanoseconds: 5_000_000) }
        #expect(h.titles == [Self.rivers])

        h.model.searchFindsHighlights = false
        for _ in 0..<200 where !h.titles.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        await h.model.settle()
        #expect(h.titles.isEmpty)
        // Nor in a narrower list.
        h.model.sidebarSelection = .ebooks
        await h.model.settle()
        #expect(h.titles.isEmpty)
        h.model.sidebarSelection = .allBooks
        // A book's own details are found as ever, and its highlights are still its own.
        h.model.searchText = "salt"
        await h.model.settle()
        #expect(h.titles.contains("Salt Road"))
        h.model.searchText = "Quiet Rivers"
        await h.model.settle()
        #expect(h.titles.contains(Self.rivers) && h.model.showsHighlights)

        // On again, the words of a highlight find their book again.
        h.model.searchFindsHighlights = true
        h.model.searchText = "kingfisher"
        for _ in 0..<200 where h.titles != [Self.rivers] { try? await Task.sleep(nanoseconds: 5_000_000) }
        #expect(h.titles == [Self.rivers])
    }

    @Test func HL20_aSearchFindsABookByTheWordsOfItsHighlights() async throws {
        let h = try await Harness.demo()
        try await h.highlight(Self.rivers, [S.incoming("r1", "A kingfisher, once.", note: "halcyon days")])
        // It is a setting, off to begin with: here it is on.
        h.model.searchFindsHighlights = true
        try? await Task.sleep(nanoseconds: 100_000_000)
        await h.model.settle()
        h.model.searchText = "kingfisher"
        await h.model.settle()
        #expect(h.titles == [Self.rivers])
        // By the words of a note, too, in any order.
        h.model.searchText = "days halcyon"
        await h.model.settle()
        #expect(h.titles == [Self.rivers])
        // Beside what a search always found.
        h.model.searchText = "salt"
        await h.model.settle()
        #expect(h.titles.contains("Salt Road") && !h.titles.contains(Self.rivers))
        // Only in the list that is shown.
        h.model.searchText = "kingfisher"
        h.model.sidebarSelection = .audiobooks
        await h.model.settle()
        #expect(h.titles.isEmpty)
        h.model.sidebarSelection = .ebooks
        await h.model.settle()
        #expect(h.titles == [Self.rivers])
        h.model.searchText = "no such words anywhere"
        await h.model.settle()
        #expect(h.titles.isEmpty)
    }

    // MARK: One sheet at a time

    @Test func HL21_theHighlightsSheetsOpenOnlyWhenNothingElseIsInTheWay() async throws {
        let h = try await Harness.demo()
        try h.link()
        #expect(h.model.canImportHighlights)
        #expect(!h.model.canShowHighlights)
        try await h.select(Self.rivers)
        #expect(h.model.canShowHighlights && h.model.canAddHighlight)

        // A question is waiting.
        h.model.requestRemoveSelection()
        #expect(h.model.prompt != nil)
        #expect(!h.model.canShowHighlights && !h.model.canAddHighlight && !h.model.canImportHighlights)
        h.model.beginHighlights()
        h.model.beginHighlightsImport()
        #expect(h.model.highlights == nil && h.model.highlightsImport == nil)
        h.model.prompt = nil

        // The highlights sheet is up: nothing else opens.
        let session = try await h.highlightsSheet()
        #expect(!h.model.canImportHighlights && !h.model.canImportAudibleLibrary && !h.model.canShowHighlights)
        h.model.beginHighlightsImport()
        h.model.beginAudibleImport()
        #expect(h.model.highlightsImport == nil && h.model.audibleImport == nil)
        #expect(h.model.windowSheet(progressDue: false) == .highlights(SheetObject(session)))
        // What it does itself is shown in it: the progress sheet does not take its place.
        h.model.busyLabel = "Adding highlight…"
        #expect(h.model.windowSheet(progressDue: true) == .highlights(SheetObject(session)))
        h.model.busyLabel = nil
        session.close()

        // Import Highlights is up: the book's sheet does not open, nor Audible's.
        h.model.beginHighlightsImport()
        let importing = try #require(h.model.highlightsImport)
        #expect(h.model.windowSheet(progressDue: false) == .highlightsImport(SheetObject(importing)))
        #expect(!h.model.canShowHighlights && !h.model.canAddHighlight && !h.model.canImportAudibleLibrary)
        #expect(!h.model.canUnlinkAudible)
        h.model.beginHighlights()
        #expect(h.model.highlights == nil)
        importing.cancel()
        #expect(h.model.highlightsImport == nil)
        #expect(h.model.canShowHighlights)

        // Something is running.
        h.model.busyLabel = "Working…"
        #expect(!h.model.canShowHighlights && !h.model.canImportHighlights)
        h.model.busyLabel = nil

        // Another library is another library's books: both sheets go.
        _ = try await h.highlightsSheet()
        await h.model.chooseLibrary(try makeTempDir())
        #expect(h.model.highlights == nil && h.model.highlightsImport == nil)
        #expect(!h.model.canShowHighlights)
        #expect(h.model.canImportHighlights)
    }
}
