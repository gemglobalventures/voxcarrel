import DemoContent
import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// Looking a book up online (plan 5, Task 5). A1–A8. Every model here looks things up in
/// the harness's `FakeLookup`: nothing reaches the network.
@MainActor
@Suite struct AppModelLookupTests {
    private let png = MediaFixtures.makeImage(.png)

    /// What Audible finds for Salt Road: a few values the demo book lacks, some it has.
    private func saltRoadOnAudible(cover: Bool = true) -> LookupCandidate {
        foundBook(.audible, "us:B0SALTROAD", title: "Salt Road", authors: ["Ines Calloway"], cover: cover) {
            $0.narrators = ["Marcus Lindqvist", "Someone Else"]
            $0.publisher = "Tidewater Audio"
            $0.summary = "A road, and salt."
            $0.asin = "B0SALTROAD"
            $0.year = 2019
            // Not the book's length, but near enough to be the same edition.
            $0.durationSeconds = 300
            $0.pageCount = 321
        }
    }

    private func saltRoadOnOpenLibrary() -> LookupCandidate {
        foundBook(.openLibrary, "/works/OL1W", title: "Salt Road", authors: ["Ines Calloway"], moreDetails: true) {
            $0.publisher = "Harbour Press"
        }
    }

    /// A demo library with Salt Road selected and its lookup open and answered.
    private func lookedUp(_ candidates: [LookupCandidate]) async throws -> (Harness, Int64) {
        let h = try await Harness.demo()
        h.lookup.find(.audible, candidates.filter { $0.source == .audible })
        h.lookup.find(.openLibrary, candidates.filter { $0.source == .openLibrary })
        let id = try await h.select("Salt Road")
        h.model.beginLookup()
        await h.model.settle()
        return (h, id)
    }

    /// An empty library with the inbox's files under review.
    private func reviewing(_ names: [String], demo: Bool = false) async throws -> Harness {
        let h = demo ? try await Harness.demo() : try await Harness.empty()
        let inbox = try Harness.inbox()
        await h.model.beginImport(names.map { inbox.appendingPathComponent($0) })
        await h.model.settle()
        return h
    }

    private func entry(_ h: Harness, _ title: String) throws -> ImportReview.Entry {
        try #require(h.model.review?.entries.first { $0.candidate.metadata.title == title }, "no entry titled \(title)")
    }

    /// Every file under the library folder with its size and when it was last changed,
    /// but for the catalogue's own files, which reading may touch.
    private func filesOnDisk(_ h: Harness) throws -> [String: String] {
        var files: [String: String] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let all = try #require(FileManager.default.enumerator(at: h.root, includingPropertiesForKeys: keys))
        for case let url as URL in all {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(h.root.standardizedFileURL.path.count))
            let isCatalogue = path.hasPrefix("/.voxcarrel/") && !path.hasPrefix("/.voxcarrel/covers/")
                && !path.hasPrefix("/.voxcarrel/undo/")
            if isCatalogue { continue }
            files[path] = "\(values.fileSize ?? -1) \(values.contentModificationDate?.timeIntervalSinceReferenceDate ?? -1)"
        }
        return files
    }

    /// The cover the library keeps for the book, as saved.
    private func savedCover(_ h: Harness, _ id: Int64) throws -> Data? {
        LibraryService(store: try h.store()).covers.image(for: id)?.data
    }

    // MARK: A1 Beginning, for the inspected book

    /// A1: the draft's values, unsaved typing included, are what is searched with and compared against.
    @Test func A1_beginningUsesTheDraftAndSearchesAtOnce() async throws {
        let h = try await Harness.demo()
        h.lookup.find(.audible, [saltRoadOnAudible()])
        h.recordBusyLabels()
        let id = try await h.select("Salt Road")
        h.model.updateDraft {
            $0.title = "Salt Roads"
            $0.publisher = "Typed Press"
        }
        #expect(h.model.canLookUp)

        h.model.beginLookup()
        let opened = try #require(h.model.lookup)
        #expect(opened.target == .book(id))
        // Plan 7: the book's first narrator goes with the search, and its audio editions are wanted.
        #expect(opened.query == LookupQuery(
            title: "Salt Roads", author: "Ines Calloway", narrator: "Marcus Lindqvist", wantsAudioEditions: true))
        #expect(opened.current.title == "Salt Roads")
        #expect(opened.current.publisher == "Typed Press")
        #expect(opened.current.narrators == ["Marcus Lindqvist"])
        #expect(opened.hasAudio)
        #expect(opened.preferAudio)
        #expect(opened.hasCover)
        // A3: the search has begun already, and is the sheet's own business.
        #expect(opened.phase == .searching)
        #expect(h.model.busyLabel == nil)
        #expect(!h.model.canLookUp)

        await h.model.settle()
        let session = try #require(h.model.lookup)
        #expect(session.phase == .results)
        #expect(session.candidates == [saltRoadOnAudible()])
        #expect(session.selectedId == saltRoadOnAudible().id)
        #expect(h.lookup.asked.count == 2)
        #expect(Set(h.lookup.asked.map(\.source)) == [.openLibrary, .audible])
        #expect(h.lookup.asked.allSatisfy { $0.query == opened.query })
        // The typed title and publisher are what the found ones are compared with.
        #expect(session.offers.first { $0.id == .title }?.current == "Salt Roads")
        #expect(session.offers.first { $0.id == .publisher }?.current == "Typed Press")
        #expect(h.busyLabels.isEmpty)
        // Beginning again while it is open does nothing.
        h.model.beginLookup()
        #expect(h.model.lookup == session)
        #expect(h.lookup.asked.count == 2)
    }

    /// A1: an ebook is not an audiobook; a cover taken away in the draft is no cover.
    @Test func A1_theBooksKindAndCoverAreTheDrafts() async throws {
        let h = try await Harness.demo()
        try await h.select("Quiet Rivers")
        h.model.removeCover()
        h.model.beginLookup()
        let session = try #require(h.model.lookup)
        #expect(!session.hasAudio)
        #expect(!session.preferAudio)
        #expect(!session.hasCover)
        h.model.cancelLookup()

        h.model.setCover(data: png)
        h.model.beginLookup()
        #expect(h.model.lookup?.hasCover == true)
    }

    /// A1: with nothing to search for, the sheet opens and waits.
    @Test func A1_anEmptyQueryOpensWithoutSearching() async throws {
        let h = try await Harness.demo()
        try await h.select("Salt Road")
        h.model.updateDraft {
            $0.title = " "
            $0.authors = ""
            $0.isbn = ""
            $0.asin = ""
        }
        h.model.beginLookup()
        await h.model.settle()
        let session = try #require(h.model.lookup)
        #expect(session.query.isEmpty)
        #expect(session.phase == .idle)
        #expect(h.lookup.asked.isEmpty)

        // Searching for nothing asks nothing.
        await h.model.searchLookup()
        #expect(h.model.lookup?.phase == .idle)
        #expect(h.lookup.asked.isEmpty)
    }

    /// A1: one book, a library, and nothing running.
    @Test func A1_canLookUpNeedsOneBookAndAQuietLibrary() async throws {
        let h = try await Harness.demo()
        #expect(!h.model.canLookUp)
        h.model.beginLookup()
        #expect(h.model.lookup == nil)

        try await h.select(["Salt Road", "Quiet Rivers"])
        #expect(!h.model.canLookUp)
        h.model.beginLookup()
        #expect(h.model.lookup == nil)

        try await h.select("Salt Road")
        #expect(h.model.canLookUp)

        h.model.busyLabel = "Saving…"
        #expect(!h.model.canLookUp)
        h.model.beginLookup()
        #expect(h.model.lookup == nil)
        h.model.busyLabel = nil
        #expect(h.model.canLookUp)

        // One question, one sheet: not while a question waits or an import is reviewed.
        h.model.requestRemoveSelection()
        #expect(h.model.prompt != nil)
        #expect(!h.model.canLookUp)
        h.model.beginLookup()
        #expect(h.model.lookup == nil)
        h.model.prompt = nil
        #expect(h.model.canLookUp)

        h.model.result = ResultSummary(headline: "1 book saved", problems: [], isClean: false)
        #expect(!h.model.canLookUp)
        h.model.result = nil

        let inbox = try Harness.inbox()
        await h.model.beginImport([inbox.appendingPathComponent("Quiet Rivers.epub")])
        #expect(h.model.review != nil)
        #expect(!h.model.canLookUp)
        h.model.beginLookup()
        #expect(h.model.lookup == nil)
        h.model.cancelImport()
        #expect(h.model.canLookUp)
        #expect(h.lookup.asked.isEmpty)
    }

    /// A1
    @Test func A1_noLibraryNoLookup() async throws {
        let h = try Harness(root: try makeTempDir(), choose: false)
        await h.model.start()
        #expect(!h.model.canLookUp)
        h.model.beginLookup()
        h.model.beginLookup(forEntry: UUID())
        #expect(h.model.lookup == nil)
        #expect(!h.model.canLookUpEntry(UUID()))
    }

    // MARK: A2 Beginning, for an import entry

    /// A2
    @Test func A2_beginningForAnEntryUsesItsDetailsAndCover() async throws {
        let h = try await reviewing(["Quiet Rivers.epub", "Tidewater Chronicles"])
        h.lookup.find(.openLibrary, [saltRoadOnOpenLibrary()])
        let ebook = try entry(h, "Quiet Rivers")
        let audio = try entry(h, "Salt Road")
        #expect(h.model.canLookUpEntry(ebook.id))
        #expect(!h.model.canLookUpEntry(UUID()))
        // The inspector's own lookup is not offered while the import sheet is up.
        #expect(!h.model.canLookUp)

        h.model.beginLookup(forEntry: UUID())
        #expect(h.model.lookup == nil)

        h.model.beginLookup(forEntry: ebook.id)
        var session = try #require(h.model.lookup)
        #expect(session.target == .importEntry(ebook.id))
        #expect(session.query == LookupQuery(title: "Quiet Rivers", author: "Amara Okafor"))
        #expect(session.current == ebook.candidate.metadata)
        #expect(session.hasCover == (ebook.cover != nil))
        #expect(!session.hasAudio)
        #expect(session.phase == .searching)
        #expect(h.model.importLookup == session)
        #expect(h.model.inspectorLookup == nil)
        #expect(!h.model.canLookUpEntry(audio.id))
        await h.model.settle()
        #expect(h.model.lookup?.phase == .results)
        #expect(h.lookup.asked.map(\.query.title) == ["Quiet Rivers", "Quiet Rivers"])
        h.model.cancelLookup()
        // The review is as it was.
        #expect(h.model.review?.entry(ebook.id) == ebook)

        h.model.updateReview { $0.update(audio.id) { $0.cover = nil } }
        h.model.beginLookup(forEntry: audio.id)
        session = try #require(h.model.lookup)
        #expect(session.hasAudio)
        #expect(session.preferAudio)
        #expect(!session.hasCover)
        await h.model.settle()
    }

    /// A2: not while something runs or a question waits.
    /// An entry's length is held against a result only when it is the measured length
    /// of its one audio file, as a library book's is only when its files were measured.
    @Test func A2_anEntrysLengthIsComparedOnlyWhenItWasMeasured() async throws {
        let one = URL(fileURLWithPath: "/inbox/Salt Road.m4b"), two = URL(fileURLWithPath: "/inbox/Salt Road 2.m4b")
        var metadata = BookMetadata(title: "Salt Road", authors: ["Ines Calloway"])
        // What the scan read from the first file.
        metadata.durationSeconds = 1_800
        func seed(_ files: [URL], measured: MeasuredAudio?) -> ImportSeed {
            ImportSeed(
                candidate: CandidateBook(files: files.map { CandidateFile(url: $0, role: .audio) }, metadata: metadata),
                cover: nil, existingMatch: nil, measuredAudio: measured)
        }
        var review = ImportReview(
            seeds: [
                seed([one], measured: MeasuredAudio(file: one, seconds: 1_800)),
                // Several parts: the first part's length is not the book's.
                seed([one, two], measured: nil),
                // Its length could not be measured.
                seed([one], measured: nil),
                // Measured, but not the file the entry has.
                seed([one], measured: MeasuredAudio(file: two, seconds: 1_800)),
                seed([one], measured: MeasuredAudio(file: one, seconds: 0)),
            ], skipped: [], copyInsteadOfMove: false)
        #expect(review.entries.map(\.measuredAudioSeconds) == [1_800, nil, nil, nil, nil])
        // A file taken out to be a book of its own was not measured as one.
        let whole = review.entries[1].id
        review.detach(file: two, from: whole)
        #expect(review.entries.allSatisfy { $0.id == review.entries[0].id || $0.measuredAudioSeconds == nil })

        // In the model: the lookup for an entry is given that length and no other.
        let h = try await reviewing(["Tidewater Chronicles"])
        let audio = try entry(h, "Salt Road")
        let parts = audio.candidate.files.filter { $0.role == .audio }.count
        #expect((audio.measuredAudioSeconds != nil) == (parts == 1))
        h.model.beginLookup(forEntry: audio.id)
        #expect(h.model.lookup?.audioSeconds == audio.measuredAudioSeconds)
        #expect(h.model.lookup?.bookContext?.audioSeconds == audio.measuredAudioSeconds)
        h.model.cancelLookup()
    }

    @Test func A2_notWhileBusy() async throws {
        let h = try await reviewing(["Quiet Rivers.epub"])
        let id = try entry(h, "Quiet Rivers").id
        h.model.busyLabel = "Importing 1 book…"
        #expect(!h.model.canLookUpEntry(id))
        h.model.beginLookup(forEntry: id)
        #expect(h.model.lookup == nil)
        h.model.busyLabel = nil
        #expect(h.model.canLookUpEntry(id))
    }

    // MARK: A3 Searching

    /// A3: the search is the sheet's own: no `busyLabel`, and the library still answers.
    @Test func A3_searchingBlocksNothingElse() async throws {
        let h = try await Harness.demo()
        let gate = Gate()
        h.lookup.hold(.audible, at: gate, then: [saltRoadOnAudible()])
        h.lookup.find(.openLibrary, [saltRoadOnOpenLibrary()])
        h.recordBusyLabels()
        try await h.select("Salt Road")
        h.model.beginLookup()
        await gate.arrival()
        #expect(h.model.lookup?.phase == .searching)
        #expect(h.model.busyLabel == nil)

        // The library is read, and changed, while Audible has yet to answer.
        let worker = try #require(h.model.worker)
        #expect(try await worker.sidebar().counts[.allBooks] == 12)
        await h.model.setReadStatus(.unread, for: try h.ids(["Quiet Rivers"]))
        #expect(try h.book(try h.id("Quiet Rivers")).readStatus == .unread)
        // The lookup is still open on the same book, still waiting.
        #expect(h.model.lookup?.phase == .searching)
        #expect(h.busyLabels == ["Updating…"])

        await gate.release()
        await h.model.settle()
        let session = try #require(h.model.lookup)
        #expect(session.phase == .results)
        #expect(Set(session.candidates.map(\.id)) == [saltRoadOnAudible().id, saltRoadOnOpenLibrary().id])
        #expect(h.busyLabels == ["Updating…"])
    }

    /// A3: a newer search supersedes an older one, whichever answers last.
    @Test func A3_aNewerSearchSupersedesAnOlderOne() async throws {
        let h = try await Harness.demo()
        let first = Gate()
        let second = Gate()
        let old = foundBook(.audible, "us:OLD", title: "Salt Road")
        let new = foundBook(.audible, "us:NEW", title: "Pepper Road")
        h.lookup.search(.audible) { query in
            if query.title == "Salt Road" {
                await first.wait()
                return [old]
            }
            await second.wait()
            return [new]
        }
        try await h.select("Salt Road")
        h.model.beginLookup()
        await first.arrival()

        h.model.updateLookupQuery { $0.title = "Pepper Road" }
        #expect(h.model.lookup?.query.title == "Pepper Road")
        #expect(h.model.lookup?.phase == .idle)
        let search = Task { await h.model.searchLookup() }
        await second.arrival()
        #expect(h.model.lookup?.phase == .searching)

        // The newer answers first, then the older arrives late.
        await second.release()
        await search.value
        #expect(h.model.lookup?.candidates == [new])
        await first.release()
        await h.model.settle()
        #expect(h.model.lookup?.candidates == [new])
        #expect(h.model.lookup?.phase == .results)
    }

    /// A3: the same when the older answers first: it is not shown in passing.
    @Test func A3_anOlderAnswerIsNeverShown() async throws {
        let h = try await Harness.demo()
        let first = Gate()
        let second = Gate()
        let old = foundBook(.audible, "us:OLD", title: "Salt Road")
        let new = foundBook(.audible, "us:NEW", title: "Salt Road")
        let calls = Counter()
        h.lookup.search(.audible) { _ in
            if await calls.next() == 1 {
                await first.wait()
                return [old]
            }
            await second.wait()
            return [new]
        }
        try await h.select("Salt Road")
        h.model.beginLookup()
        await first.arrival()
        // The same query, searched again.
        let search = Task { await h.model.searchLookup() }
        await second.arrival()

        await first.release()
        // Give the older answer every chance to be used.
        for _ in 0..<20 { await Task.yield() }
        #expect(h.model.lookup?.phase == .searching)
        #expect(h.model.lookup?.candidates.isEmpty == true)

        await second.release()
        await search.value
        await h.model.settle()
        #expect(h.model.lookup?.candidates == [new])
    }

    /// A3: a query changed while its search runs leaves the sheet waiting for Search, and
    /// the answer for the old query is ignored (K2).
    @Test func A3_editingTheQueryLeavesTheRunningSearchBehind() async throws {
        let h = try await Harness.demo()
        let gate = Gate()
        h.lookup.hold(.audible, at: gate, then: [saltRoadOnAudible()])
        try await h.select("Salt Road")
        h.model.beginLookup()
        await gate.arrival()

        h.model.updateLookupQuery { $0.author = "" }
        #expect(h.model.lookup?.phase == .idle)
        await gate.release()
        await h.model.settle()
        #expect(h.model.lookup?.phase == .idle)
        #expect(h.model.lookup?.candidates.isEmpty == true)
        #expect(h.lookup.cancelledSearches == 1)

        // A change that changes nothing disturbs nothing.
        h.lookup.find(.audible, [saltRoadOnAudible()])
        await h.model.searchLookup()
        let found = try #require(h.model.lookup)
        h.model.updateLookupQuery { $0.author = "" }
        #expect(h.model.lookup == found)
        #expect(h.lookup.asked.last?.query
            == LookupQuery(title: "Salt Road", narrator: "Marcus Lindqvist", wantsAudioEditions: true))
    }

    /// A3, K2: a source that fails is named; the other's results still show.
    @Test func A3_oneSourceFailingKeepsTheOthersResults() async throws {
        let h = try await Harness.demo()
        h.lookup.fail(.audible, .notReachable)
        h.lookup.find(.openLibrary, [saltRoadOnOpenLibrary()])
        try await h.select("Salt Road")
        h.model.beginLookup()
        await h.model.settle()
        var session = try #require(h.model.lookup)
        #expect(session.phase == .results)
        #expect(session.candidates.map(\.id) == [saltRoadOnOpenLibrary().id])
        #expect(session.failureText == "Audible could not be reached.")
        #expect(h.model.alert == nil)

        h.lookup.fail(.openLibrary, .refused(status: 500))
        await h.model.searchLookup()
        session = try #require(h.model.lookup)
        #expect(session.phase == .noResults)
        #expect(session.failureText == "Open Library answered with an error. Audible could not be reached.")
        #expect(h.model.alert == nil)
    }

    /// A3: results are preferred in the Mac's language, and Audible's for an audiobook.
    @Test func A3_theMacsLanguageAndTheBooksKindOrderTheResults() async throws {
        let h = try await Harness.demo()
        let french = foundBook(.audible, "us:FR", title: "Salt Road", authors: ["Ines Calloway"]) { $0.language = "fr" }
        let english = foundBook(.audible, "us:EN", title: "Salt Road", authors: ["Ines Calloway"]) { $0.language = "en" }
        h.lookup.find(.audible, [french, english])
        h.lookup.find(.openLibrary, [saltRoadOnOpenLibrary()])
        try await h.select("Salt Road")
        h.model.beginLookup()
        await h.model.settle()
        // An audiobook: Audible first; the harness's language is English.
        #expect(h.model.lookup?.candidates.map(\.id) == [english.id, french.id, saltRoadOnOpenLibrary().id])

        h.model.lookupLanguage = "fr"
        h.model.updateLookupQuery { $0.author = "Calloway" }
        await h.model.searchLookup()
        #expect(h.model.lookup?.candidates.map(\.id) == [french.id, english.id, saltRoadOnOpenLibrary().id])

        // An ebook: Open Library first.
        h.model.cancelLookup()
        try await h.select("Quiet Rivers")
        h.model.beginLookup()
        await h.model.settle()
        #expect(h.model.lookup?.candidates.first?.source == .openLibrary)
    }

    /// A3: the candidate selected, at first or by the user, has its details fetched (K7).
    @Test func A3_selectingFetchesDetails() async throws {
        let h = try await Harness.demo()
        let other = foundBook(.openLibrary, "/works/OL2W", title: "Salt Road", authors: ["Ines Calloway"], moreDetails: true)
        h.lookup.find(.openLibrary, [saltRoadOnOpenLibrary(), other])
        h.lookup.details { candidate in
            var detailed = candidate
            detailed.metadata.summary = "About \(candidate.id)."
            detailed.hasMoreDetails = false
            return detailed
        }
        try await h.select("Quiet Rivers")
        h.model.updateDraft {
            $0.title = "Salt Road"
            $0.authors = "Ines Calloway"
        }
        h.model.beginLookup()
        await h.model.settle()
        // The first is selected by the search, and its details came with it.
        var session = try #require(h.model.lookup)
        #expect(session.selectedId == saltRoadOnOpenLibrary().id)
        #expect(h.lookup.detailsAsked == [saltRoadOnOpenLibrary().id])
        #expect(session.selected?.metadata.summary == "About openLibrary:/works/OL1W.")
        #expect(session.selected?.hasMoreDetails == false)
        #expect(session.offers.map(\.id) == [.publisher, .summary])

        await h.model.selectLookupCandidate(other.id)
        session = try #require(h.model.lookup)
        #expect(session.selectedId == other.id)
        #expect(h.lookup.detailsAsked == [saltRoadOnOpenLibrary().id, other.id])
        #expect(session.offers.map(\.found) == ["About openLibrary:/works/OL2W."])

        // What is already complete is not asked for again.
        await h.model.selectLookupCandidate(saltRoadOnOpenLibrary().id)
        #expect(h.lookup.detailsAsked.count == 2)
        #expect(h.model.lookup?.offers.map(\.id) == [.publisher, .summary])

        await h.model.selectLookupCandidate(nil)
        #expect(h.model.lookup?.selectedId == nil)
        #expect(h.lookup.detailsAsked.count == 2)
    }

    /// A3: details that cannot be fetched are simply not there.
    @Test func A3_detailsThatFailAreNotAProblem() async throws {
        let h = try await Harness.demo()
        h.lookup.find(.openLibrary, [saltRoadOnOpenLibrary()])
        h.lookup.details { _ in throw LookupError.notReachable }
        try await h.select("Salt Road")
        h.model.beginLookup()
        await h.model.settle()
        let session = try #require(h.model.lookup)
        #expect(session.phase == .results)
        #expect(session.selected == saltRoadOnOpenLibrary())
        #expect(session.offers.map(\.id) == [.publisher])
        #expect(h.model.alert == nil)
    }

    /// K4, K5 through the model.
    @Test func tickingThroughTheModel() async throws {
        let (h, _) = try await lookedUp([saltRoadOnAudible()])
        // The demo book has a narrator, a year and a cover; it has no publisher, description or ASIN.
        #expect(h.model.lookup?.tickedFields == [.publisher, .summary, .asin])
        h.model.setLookupTicked(true, for: .narrators)
        h.model.setLookupTicked(false, for: .publisher)
        #expect(h.model.lookup?.tickedFields == [.narrators, .summary, .asin])
        // Offers never include what describes the files.
        #expect(h.model.lookup?.offers.map(\.id) == [.narrators, .year, .publisher, .summary, .asin, .cover])
    }

    // MARK: A4 Applying

    /// A4: ticked values go into the book and are saved at once, as one operation that
    /// Undo reverses; nothing else changes.
    @Test func A4_applyingSavesTheTickedValues() async throws {
        let (h, id) = try await lookedUp([saltRoadOnAudible()])
        let before = try h.book(id)
        h.recordBusyLabels()
        h.model.setLookupTicked(true, for: .narrators)
        #expect(h.model.lookup?.canApply == true)

        await h.model.applyLookup()
        #expect(h.model.lookup == nil)
        #expect(h.model.alert == nil)
        #expect(h.model.result == nil)
        #expect(h.busyLabels == ["Saving…"])
        #expect(h.model.busyLabel == nil)
        let saved = try h.book(id)
        #expect(saved.narrators == ["Marcus Lindqvist", "Someone Else"])
        #expect(saved.publisher == "Tidewater Audio")
        #expect(saved.summary == "A road, and salt.")
        #expect(saved.asin == "B0SALTROAD")
        // Not ticked: the year, which the book has, and the cover. Not on offer: the title and the author, which are the same.
        #expect(saved.year == 2014)
        #expect(saved.title == "Salt Road")
        #expect(saved.authors == ["Ines Calloway"])
        #expect(saved.series == "Tidewater Chronicles")
        #expect(h.lookup.coverURLs.isEmpty)
        // Nothing is left to save: the draft is the book as it is now.
        #expect(h.draft == BookDraft(book: saved))
        #expect(!h.model.hasUnsavedChanges)
        #expect(!h.model.canSave)
        #expect(h.model.rows.first { $0.id == id }?.book == saved)
        // The tags are in the file.
        let url = try #require(try h.fileURLs(id).first)
        #expect(try FileMetadataIO().read(url).metadata.publisher == "Tidewater Audio")

        // One operation, and Undo takes all of it back.
        #expect(h.model.undoLabel == "Edit Salt Road")
        await h.model.undo()
        #expect(try h.book(id) == before)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
        #expect(try FileMetadataIO().read(try #require(try h.fileURLs(id).first)).metadata.publisher == before.publisher)
    }

    /// Edits typed before the lookup are saved with what it applies: one save, one undo step.
    @Test func A4_handEditsAreSavedWithWhatIsApplied() async throws {
        let h = try await Harness.demo()
        h.lookup.find(.audible, [saltRoadOnAudible()])
        h.recordBusyLabels()
        let id = try await h.select("Salt Road")
        let before = try h.book(id)
        h.model.updateDraft { $0.genres = ["Sea Stories"] }
        h.model.beginLookup()
        await h.model.settle()

        await h.model.applyLookup()
        #expect(h.busyLabels == ["Saving…"])
        #expect(try h.book(id).genres == ["Sea Stories"])
        #expect(try h.book(id).publisher == "Tidewater Audio")
        #expect(!h.model.hasUnsavedChanges)
        #expect(h.model.undoLabel == "Edit Salt Road")

        await h.model.undo()
        #expect(try h.book(id) == before)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
    }

    /// An applied title files the book again under its new name.
    @Test func A4_anAppliedTitleRefilesTheBook() async throws {
        let h = try await Harness.demo()
        h.lookup.find(.audible, [foundBook(.audible, "us:B0SALT", title: "The Salt Road", authors: ["Ines Calloway"])])
        let id = try await h.select("Salt Road")
        let folderBefore = try #require(try h.book(id).folderPath)
        let filesBefore = try h.fileURLs(id)
        h.model.beginLookup()
        await h.model.settle()
        h.model.setLookupTicked(true, for: .title)

        await h.model.applyLookup()
        #expect(h.model.alert == nil)
        #expect(h.model.result == nil)
        let saved = try h.book(id)
        #expect(saved.title == "The Salt Road")
        #expect(saved.folderPath != folderBefore)
        #expect(saved.folderPath?.contains("The Salt Road") == true)
        let filesNow = try h.fileURLs(id)
        #expect(filesNow != filesBefore)
        #expect(filesNow.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(h.detail?.files.map(\.url.path) == filesNow.map(\.path))

        await h.model.undo()
        #expect(try h.book(id).folderPath == folderBefore)
        #expect(try h.fileURLs(id) == filesBefore)
        #expect(filesBefore.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    /// A draft that cannot be saved: the applied values stay in it, unsaved, and the alert says why.
    @Test func A4_aDraftWithAProblemKeepsWhatWasAppliedUnsaved() async throws {
        let h = try await Harness.demo()
        h.lookup.find(.audible, [saltRoadOnAudible()])
        h.recordBusyLabels()
        let id = try await h.select("Salt Road")
        let before = try h.book(id)
        // Searched for by its ASIN, so that the title can be blank.
        h.model.updateDraft {
            $0.title = " "
            $0.asin = "B0SALTROAD"
        }
        let problem = try #require(h.draft?.problems.first)
        h.model.beginLookup()
        await h.model.settle()
        h.model.setLookupTicked(false, for: .title)
        #expect(h.model.lookup?.tickedFields.contains(.publisher) == true)

        await h.model.applyLookup()
        #expect(h.model.lookup == nil)
        #expect(h.model.alert == problem)
        #expect(h.busyLabels.isEmpty)
        #expect(h.draft?.publisher == "Tidewater Audio")
        #expect(h.draft?.title == " ")
        #expect(h.model.hasUnsavedChanges)
        #expect(try h.book(id) == before)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)

        // Put right, Save saves it all.
        h.model.alert = nil
        h.model.updateDraft { $0.title = "Salt Road" }
        await h.model.save()
        #expect(try h.book(id).publisher == "Tidewater Audio")
        #expect(!h.model.hasUnsavedChanges)
    }

    /// Something else running: the values are applied and left unsaved, and the alert says so.
    @Test func A4_whileSomethingRunsWhatIsAppliedIsLeftUnsaved() async throws {
        let (h, id) = try await lookedUp([saltRoadOnAudible()])
        let before = try h.book(id)
        h.model.busyLabel = "Updating…"

        await h.model.applyLookup()
        #expect(h.model.lookup == nil)
        #expect(h.model.alert == "The details were applied but not saved, because something else was running. Press Save to save them.")
        #expect(h.model.busyLabel == "Updating…")
        #expect(h.draft?.publisher == "Tidewater Audio")
        #expect(h.model.hasUnsavedChanges)
        #expect(try h.book(id) == before)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)

        h.model.busyLabel = nil
        h.model.alert = nil
        await h.model.save()
        #expect(try h.book(id).publisher == "Tidewater Audio")
    }

    /// A save that fails for the book: the result says why, and what was applied stays unsaved.
    @Test func A4_aSaveThatFailsKeepsWhatWasAppliedUnsaved() async throws {
        let (h, id) = try await lookedUp([saltRoadOnAudible()])
        let before = try h.book(id)
        // Nothing can be kept for Undo, so nothing is changed.
        let undo = h.root.appendingPathComponent(".voxcarrel/undo")
        try FileManager.default.createDirectory(at: undo, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: undo.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: undo.path) }

        await h.model.applyLookup()
        #expect(h.model.lookup == nil)
        #expect(h.model.busyLabel == nil)
        let result = try #require(h.model.result)
        #expect(!result.isClean)
        #expect(result.headline == "1 book could not be saved")
        #expect(h.draft?.publisher == "Tidewater Audio")
        #expect(h.model.hasUnsavedChanges)
        #expect(try h.book(id) == before)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
    }

    /// A file whose tags cannot be written: the book is saved, and the result names the file's problem.
    @Test func A4_aFileProblemGoesToTheResult() async throws {
        let h = try await Harness.demo()
        h.lookup.find(.openLibrary, [foundBook(.openLibrary, "/works/OL5W", title: "Quiet Rivers") { $0.publisher = "Harbour Press" }])
        let id = try await h.select("Quiet Rivers")
        // No longer an EPUB, so its tags cannot be written.
        try Data("not a book".utf8).write(to: try #require(try h.fileURLs(id).first))
        h.model.beginLookup()
        await h.model.settle()
        h.model.setLookupTicked(true, for: .publisher)

        await h.model.applyLookup()
        #expect(h.model.lookup == nil)
        let result = try #require(h.model.result)
        #expect(result.problems.map(\.title) == ["Quiet Rivers"])
        #expect(h.model.alert == nil)
        #expect(try h.book(id).publisher == "Harbour Press")
        #expect(!h.model.hasUnsavedChanges)
    }

    /// The sheet has closed before the save begins: one progress indicator at a time, and no second apply.
    @Test func A4_theSheetClosesBeforeTheSaveRuns() async throws {
        let (h, id) = try await lookedUp([saltRoadOnAudible()])
        let gate = Gate()
        h.model.beforeOperation = { await gate.wait() }
        let applying = Task { await h.model.applyLookup() }
        await gate.arrival()
        #expect(h.model.busyLabel == "Saving…")
        #expect(h.model.lookup == nil)
        // Apply again, and Save, while it runs: nothing more happens.
        await h.model.applyLookup()
        await h.model.save()
        #expect(!h.model.canLookUp)

        await gate.release()
        await applying.value
        #expect(h.model.busyLabel == nil)
        #expect(try h.book(id).publisher == "Tidewater Audio")
        #expect(h.model.undoLabel == "Edit Salt Road")
        await h.model.undo()
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
    }

    /// A4: with nothing ticked there is nothing to apply, and the sheet stays.
    @Test func A4_nothingTickedAppliesNothing() async throws {
        let (h, _) = try await lookedUp([saltRoadOnAudible()])
        for field in MetadataField.allCases { h.model.setLookupTicked(false, for: field) }
        #expect(h.model.lookup?.canApply == false)
        await h.model.applyLookup()
        #expect(h.model.lookup != nil)
        #expect(h.draft?.isDirty == false)

        h.model.cancelLookup()
        await h.model.applyLookup()
        #expect(h.draft?.isDirty == false)
    }

    /// A4: a ticked cover is downloaded when applied, and saved as the book's cover as a chosen one is.
    @Test func A4_aTickedCoverIsDownloadedAndSaved() async throws {
        let (h, id) = try await lookedUp([saltRoadOnAudible()])
        h.lookup.cover(png)
        #expect(h.lookup.coverURLs.isEmpty)
        for field in MetadataField.allCases { h.model.setLookupTicked(false, for: field) }
        h.model.setLookupTicked(true, for: .cover)

        await h.model.applyLookup()
        #expect(h.lookup.coverURLs == [try #require(saltRoadOnAudible().coverURL)])
        #expect(h.model.lookup == nil)
        #expect(h.model.alert == nil)
        #expect(try savedCover(h, id) == png)
        #expect(h.draft?.cover == .keep)
        #expect(h.model.draftCover == .stored)
        #expect(try h.book(id).publisher == nil)
        #expect(!h.model.hasUnsavedChanges)
    }

    /// A4: a cover that cannot be fetched does not stop the other values.
    @Test func A4_aCoverThatCannotBeFetchedLeavesTheRest() async throws {
        let (h, id) = try await lookedUp([saltRoadOnAudible()])
        let coverBefore = try savedCover(h, id)
        // Not reachable, which is what the fake answers until told otherwise.
        h.model.setLookupTicked(true, for: .cover)
        await h.model.applyLookup()
        #expect(h.model.lookup == nil)
        #expect(h.draft?.cover == .keep)
        #expect(h.model.alert == "The cover could not be downloaded. The other details were applied.")
        // The rest is saved all the same, and the cover is the one the book had.
        #expect(try h.book(id).publisher == "Tidewater Audio")
        #expect(try savedCover(h, id) == coverBefore)
        #expect(!h.model.hasUnsavedChanges)
        #expect(h.model.undoLabel == "Edit Salt Road")

        // Something that is not an image is no cover either; with nothing else ticked,
        // only that is said, and nothing is saved.
        h.model.alert = nil
        h.recordBusyLabels()
        h.lookup.cover(Data("<html>".utf8))
        h.model.beginLookup()
        await h.model.settle()
        for field in MetadataField.allCases { h.model.setLookupTicked(false, for: field) }
        h.model.setLookupTicked(true, for: .cover)
        await h.model.applyLookup()
        #expect(h.model.lookup == nil)
        #expect(h.draft?.isDirty == false)
        #expect(h.model.alert == "The cover could not be downloaded.")
        #expect(h.busyLabels.isEmpty)
    }

    /// A cover that cannot be fetched and a draft that cannot be saved: both are said.
    @Test func A4_aCoverThatFailsAndADraftWithAProblemAreBothSaid() async throws {
        let h = try await Harness.demo()
        h.lookup.find(.audible, [saltRoadOnAudible()])
        try await h.select("Salt Road")
        h.model.updateDraft { $0.year = "19x4" }
        let problem = try #require(h.draft?.problems.first)
        h.model.beginLookup()
        await h.model.settle()
        h.model.setLookupTicked(true, for: .cover)
        await h.model.applyLookup()
        #expect(h.model.alert == "The cover could not be downloaded. The other details were applied. \(problem)")
        #expect(h.draft?.publisher == "Tidewater Audio")
        #expect(h.model.hasUnsavedChanges)
    }

    /// A3, A4: while the cover is on its way the sheet says so, and Apply cannot be pressed again.
    @Test func A4_applyingTwiceIsImpossible() async throws {
        let (h, id) = try await lookedUp([saltRoadOnAudible()])
        h.recordBusyLabels()
        let gate = Gate()
        let png = png
        h.lookup.cover { _ in
            await gate.wait()
            return (png, 200)
        }
        h.model.setLookupTicked(true, for: .cover)
        let applying = Task { await h.model.applyLookup() }
        await gate.arrival()
        #expect(h.model.lookup?.phase == .applying)
        #expect(h.model.lookup?.canApply == false)
        #expect(h.model.busyLabel == nil)

        // A second Apply, and anything else in the sheet, does nothing.
        await h.model.applyLookup()
        h.model.setLookupTicked(false, for: .publisher)
        h.model.updateLookupQuery { $0.title = "Other" }
        await h.model.searchLookup()
        await h.model.selectLookupCandidate(nil)
        #expect(h.model.lookup?.phase == .applying)
        #expect(h.model.lookup?.query.title == "Salt Road")
        #expect(h.lookup.coverURLs.count == 1)
        #expect(h.draft?.isDirty == false)

        await gate.release()
        await applying.value
        #expect(h.model.lookup == nil)
        #expect(h.lookup.coverURLs.count == 1)
        // Saved, once.
        #expect(h.busyLabels == ["Saving…"])
        #expect(try savedCover(h, id) == png)
        #expect(try h.book(id).publisher == "Tidewater Audio")
        #expect(!h.model.hasUnsavedChanges)
    }

    /// A4: for an import entry the ticked values go into the entry, and its cover is marked as chosen.
    @Test func A4_applyingToAnImportEntry() async throws {
        let h = try await reviewing(["Tidewater Chronicles"])
        h.lookup.find(.audible, [saltRoadOnAudible()])
        h.lookup.cover(png)
        let before = try entry(h, "Salt Road")
        let others = try #require(h.model.review?.entries.filter { $0.id != before.id })
        #expect(!before.coverChanged)

        h.model.beginLookup(forEntry: before.id)
        await h.model.settle()
        // The entry has a narrator, a year and a cover of its own; none is pre-ticked.
        #expect(h.model.lookup?.tickedFields == [.publisher, .summary, .asin])
        h.model.setLookupTicked(true, for: .cover)
        h.model.setLookupTicked(true, for: .narrators)
        await h.model.applyLookup()
        await h.model.settle()

        #expect(h.model.lookup == nil)
        #expect(h.model.alert == nil)
        let after = try #require(h.model.review?.entry(before.id))
        var expected = before.candidate.metadata
        expected.narrators = ["Marcus Lindqvist", "Someone Else"]
        expected.publisher = "Tidewater Audio"
        expected.summary = "A road, and salt."
        expected.asin = "B0SALTROAD"
        // The length and page count are the files' own.
        #expect(after.candidate.metadata == expected)
        #expect(after.candidate.files == before.candidate.files)
        #expect(after.cover == CoverImage(data: png, mime: "image/png"))
        #expect(after.coverChanged)
        #expect(after.included)
        #expect(h.model.review?.entries.filter { $0.id != before.id } == others)
        // Nothing is imported until the user says so.
        #expect(h.model.rows.isEmpty)
        #expect(h.model.review?.items().first { $0.candidate.metadata.title == "Salt Road" }?.cover
            == .set(CoverImage(data: png, mime: "image/png")))
    }

    /// A4: without a ticked cover the entry's cover is left as it was.
    @Test func A4_anEntrysCoverIsLeftAloneUnlessTicked() async throws {
        let h = try await reviewing(["Tidewater Chronicles"])
        h.lookup.find(.audible, [saltRoadOnAudible()])
        let before = try entry(h, "Salt Road")
        h.model.beginLookup(forEntry: before.id)
        await h.model.settle()
        await h.model.applyLookup()
        let after = try #require(h.model.review?.entry(before.id))
        #expect(after.cover == before.cover)
        #expect(!after.coverChanged)
        #expect(after.candidate.metadata.publisher == "Tidewater Audio")
        #expect(h.lookup.coverURLs.isEmpty)

        // A cover that cannot be fetched: the rest is applied, and the entry's cover stays.
        h.lookup.find(.audible, [foundBook(.audible, "us:B2", title: "Salt Road", cover: true) { $0.genres = ["Sea stories"] }])
        h.model.beginLookup(forEntry: before.id)
        await h.model.settle()
        h.model.setLookupTicked(true, for: .cover)
        h.model.setLookupTicked(true, for: .genre)
        await h.model.applyLookup()
        let last = try #require(h.model.review?.entry(before.id))
        #expect(last.candidate.metadata.genres == ["Sea stories"])
        #expect(last.cover == before.cover)
        #expect(!last.coverChanged)
        #expect(h.model.alert == "The cover could not be downloaded. The other details were applied.")
    }

    /// A4, A20, A23: a title applied to an entry is a title typed: where it will be filed,
    /// and which library book it matches, are worked out again.
    @Test func A4_anAppliedTitleRefilesAndRematchesTheEntry() async throws {
        let h = try await reviewing(["Quiet Rivers.epub"], demo: true)
        let before = try entry(h, "Quiet Rivers")
        #expect(before.existingMatch?.title == "Quiet Rivers")
        #expect(before.isAddedToExisting)
        h.lookup.find(.openLibrary, [foundBook(.openLibrary, "/works/OL9W", title: "Loud Rivers", authors: ["Amara Okafor"])])
        // To be a book of its own: only then can it be looked up.
        h.model.updateReview { $0.update(before.id) { $0.addToExisting = false } }
        await h.model.settle()

        h.model.beginLookup(forEntry: before.id)
        await h.model.settle()
        #expect(h.model.lookup?.offers.map(\.id) == [.title])
        h.model.setLookupTicked(true, for: .title)
        await h.model.applyLookup()
        await h.model.settle()

        let after = try #require(h.model.review?.entry(before.id))
        #expect(after.candidate.metadata.title == "Loud Rivers")
        #expect(after.existingMatch == nil)
        #expect(!after.isAddedToExisting)
        #expect(h.model.review?.entriesNeedingMatch.isEmpty == true)
        #expect(h.model.review?.entriesNeedingDestination.isEmpty == true)
        let planned = LibraryService(store: try h.store()).plannedFolder(for: after.candidate.metadata)
        #expect(planned != nil)
        #expect(after.destination == planned)
    }

    // MARK: A5 Closing when what it was for has gone

    /// A5: another book, several books or none in the inspector closes the lookup; nothing is applied.
    @Test func A5_theInspectedBookChangingClosesTheLookup() async throws {
        let (h, _) = try await lookedUp([saltRoadOnAudible()])
        #expect(h.model.lookup?.canApply == true)
        #expect(h.model.inspectorLookup != nil)
        #expect(h.model.importLookup == nil)
        try await h.select("Quiet Rivers")
        #expect(h.model.lookup == nil)
        #expect(h.draft?.isDirty == false)
        await h.model.applyLookup()
        #expect(h.draft?.isDirty == false)

        h.model.beginLookup()
        await h.model.settle()
        #expect(h.model.lookup != nil)
        try await h.select(["Quiet Rivers", "Salt Road"])
        #expect(h.model.lookup == nil)

        try await h.select("Salt Road")
        h.model.beginLookup()
        await h.model.settle()
        h.model.select([])
        await h.model.settle()
        #expect(h.model.lookup == nil)
    }

    /// A5: the same book shown afresh (after a change elsewhere) keeps the lookup open.
    @Test func A5_theSameBookReadAgainKeepsTheLookup() async throws {
        let (h, id) = try await lookedUp([saltRoadOnAudible()])
        let session = try #require(h.model.lookup)
        await h.model.reloadAll()
        #expect(h.model.lookup == session)
        await h.model.setReadStatus(.inProgress, for: [id])
        #expect(h.model.lookup == session)
    }

    /// A5: an answer that arrives after the lookup closed goes nowhere, not even into the next lookup.
    @Test func A5_aLateAnswerIsNotUsedByAnotherLookup() async throws {
        let h = try await Harness.demo()
        let gate = Gate()
        h.lookup.hold(.audible, at: gate, then: [saltRoadOnAudible()])
        try await h.select("Salt Road")
        h.model.beginLookup()
        await gate.arrival()

        // (Not `h.select`, which would wait for the search that is being held.)
        h.model.click(try h.id("Quiet Rivers"), modifiers: [])
        await h.model.latestInspectorRefresh?.value
        #expect(h.model.lookup == nil)
        h.lookup.find(.audible, [])
        h.model.beginLookup()
        await gate.release()
        await h.model.settle()
        let session = try #require(h.model.lookup)
        #expect(session.target == .book(try h.id("Quiet Rivers")))
        #expect(session.candidates.isEmpty)
        #expect(session.phase == .noResults)
    }

    /// A5: the book changing while the cover is fetched: nothing is applied to either book.
    @Test func A5_closingWhileApplyingAppliesNothing() async throws {
        let (h, _) = try await lookedUp([saltRoadOnAudible()])
        let gate = Gate()
        let png = png
        h.lookup.cover { _ in
            await gate.wait()
            return (png, 200)
        }
        h.model.setLookupTicked(true, for: .cover)
        let applying = Task { await h.model.applyLookup() }
        await gate.arrival()
        try await h.select("Quiet Rivers")
        #expect(h.model.lookup == nil)
        // Another lookup, for the other book, is open when the cover arrives.
        h.model.beginLookup()
        await h.model.settle()
        let other = try #require(h.model.lookup)

        await gate.release()
        await applying.value
        #expect(h.model.lookup == other)
        #expect(h.draft?.original.title == "Quiet Rivers")
        #expect(h.draft?.isDirty == false)
        #expect(h.model.alert == nil)
    }

    /// A5: the review closing, or the entry going, closes the lookup.
    @Test func A5_theReviewClosingOrTheEntryGoingClosesTheLookup() async throws {
        let h = try await reviewing(["Tidewater Chronicles"])
        h.lookup.find(.audible, [saltRoadOnAudible()])
        let pair = try #require(h.model.review?.entries.filter {
            ["Salt Road", "The Drowned Bell"].contains($0.candidate.metadata.title)
        })
        #expect(pair.count == 2)
        // Merging keeps the first in the list.
        let (salt, bell) = (pair[0], pair[1])

        // Merged into another entry: it is no longer there.
        h.model.beginLookup(forEntry: bell.id)
        await h.model.settle()
        #expect(h.model.lookup?.target == .importEntry(bell.id))
        h.model.updateReview { $0.merge([salt.id, bell.id]) }
        #expect(h.model.review?.entry(bell.id) == nil)
        #expect(h.model.lookup == nil)
        await h.model.applyLookup()

        // A change to the review that leaves the entry there leaves the lookup.
        h.model.beginLookup(forEntry: salt.id)
        await h.model.settle()
        h.model.updateReview { $0.copyInsteadOfMove.toggle() }
        await h.model.settle()
        #expect(h.model.lookup?.target == .importEntry(salt.id))

        h.model.cancelImport()
        #expect(h.model.lookup == nil)
        #expect(h.model.review == nil)

        // Confirmed: the review closes, and so does the lookup.
        let again = try await reviewing(["Quiet Rivers.epub"])
        let rivers = try entry(again, "Quiet Rivers")
        again.model.beginLookup(forEntry: rivers.id)
        await again.model.settle()
        #expect(again.model.lookup != nil)
        await again.model.confirmImport()
        #expect(again.model.lookup == nil)
        #expect(again.titles == ["Quiet Rivers"])
    }

    /// A5: another library closes the lookup.
    @Test func A5_theLibraryChangingClosesTheLookup() async throws {
        let (h, _) = try await lookedUp([saltRoadOnAudible()])
        #expect(h.model.lookup != nil)
        await h.model.chooseLibrary(try makeTempDir())
        #expect(h.model.lookup == nil)
        #expect(h.model.rows.isEmpty)

        let other = try await reviewing(["Quiet Rivers.epub"])
        other.model.beginLookup(forEntry: try entry(other, "Quiet Rivers").id)
        await other.model.settle()
        #expect(other.model.lookup != nil)
        await other.model.retryLibrary()
        #expect(other.model.lookup == nil)
    }

    // MARK: A6 Cancelling

    /// A6
    @Test func A6_cancellingClosesAndAppliesNothing() async throws {
        let (h, id) = try await lookedUp([saltRoadOnAudible()])
        let before = try h.book(id)
        h.model.setLookupTicked(true, for: .narrators)
        h.model.cancelLookup()
        #expect(h.model.lookup == nil)
        #expect(h.draft?.isDirty == false)
        #expect(try h.book(id) == before)
        #expect(h.model.canLookUp)
        // Cancelling when nothing is open is nothing.
        h.model.cancelLookup()
        #expect(h.model.lookup == nil)
    }

    /// A6: a search still running is cancelled, and its answer is never shown.
    @Test func A6_cancellingCancelsARunningSearch() async throws {
        let h = try await Harness.demo()
        let gate = Gate()
        h.lookup.hold(.audible, at: gate, then: [saltRoadOnAudible()])
        try await h.select("Salt Road")
        h.model.beginLookup()
        await gate.arrival()
        #expect(h.lookup.cancelledSearches == 0)

        h.model.cancelLookup()
        #expect(h.model.lookup == nil)
        await gate.release()
        await h.model.settle()
        #expect(h.lookup.cancelledSearches == 1)
        #expect(h.model.lookup == nil)
        #expect(h.draft?.isDirty == false)
    }

    // MARK: A7 The Audible store

    /// A7: remembered under `audibleStore`; the default is the region's.
    @Test func A7_theStoreIsRememberedAndDefaultsFromTheRegion() async throws {
        let h = try Harness(root: try makeTempDir())
        #expect(h.model.audibleStore == AudibleStore.forRegion(Locale.current.region?.identifier))
        #expect(h.defaults.object(forKey: "audibleStore") == nil)

        h.model.audibleStore = .de
        #expect(h.model.audibleStore == .de)
        #expect(h.defaults.string(forKey: "audibleStore") == "de")
        #expect(h.relaunched().audibleStore == .de)

        // Something that is no store is no choice.
        h.defaults.set("atlantis", forKey: "audibleStore")
        #expect(h.relaunched().audibleStore == AudibleStore.forRegion(Locale.current.region?.identifier))
    }

    /// A7: changing it rebuilds the service the worker looks things up with.
    @Test func A7_changingTheStoreRebuildsTheLookupService() async throws {
        let h = try Harness(root: try makeTempDir())
        h.model.audibleStore = .us
        // No library is open yet: there is nothing to rebuild.
        #expect(h.lookup.builtFor.isEmpty)
        await h.model.start()
        #expect(h.lookup.builtFor == [.us])

        h.model.audibleStore = .uk
        #expect(h.lookup.builtFor == [.us, .uk])
        // Choosing what is chosen already rebuilds nothing.
        h.model.audibleStore = .uk
        #expect(h.lookup.builtFor == [.us, .uk])

        let inbox = try Harness.inbox()
        await h.model.beginImport([inbox.appendingPathComponent("Quiet Rivers.epub")])
        h.model.beginLookup(forEntry: try entry(h, "Quiet Rivers").id)
        await h.model.settle()
        #expect(h.lookup.asked.map(\.store) == [.uk, .uk])

        // Changed while a lookup is open: the next search is of the new store.
        h.model.audibleStore = .au
        await h.model.searchLookup()
        #expect(h.lookup.asked.map(\.store) == [.uk, .uk, .au, .au])

        // A library opened later has the store as it is then.
        h.model.cancelLookup()
        h.model.cancelImport()
        await h.model.retryLibrary()
        #expect(h.lookup.builtFor.last == .au)
    }

    /// A7, V4, V7: what the sheet and the settings say about the sources.
    @Test func A7_theSourcesInWords() async throws {
        let h = try Harness(root: try makeTempDir())
        h.model.audibleStore = .uk
        // Plan 7, A8: the user's own store first, then the others that are searched.
        #expect(h.model.lookupSourcesText == "Results from Open Library and Audible (UK, US, Australia)")
        h.model.audibleStore = .us
        #expect(h.model.lookupSourcesText == "Results from Open Library and Audible (US, UK, Australia)")
        // One store alone is named in full, as before.
        h.model.otherAudibleStores = []
        #expect(h.model.lookupSourcesText == "Results from Open Library and Audible (United States)")
        h.model.audibleStore = .uk
        #expect(h.model.lookupSourcesText == "Results from Open Library and Audible (United Kingdom)")

        let choices = AppModel.audibleStoreChoices
        #expect(Set(choices.map(\.store)) == Set(AudibleStore.allCases))
        #expect(choices.count == AudibleStore.allCases.count)
        #expect(choices.map(\.title) == [
            "Australia", "Brazil", "Canada", "France", "Germany", "India", "Italy", "Japan", "Spain",
            "United Kingdom", "United States",
        ])
        #expect(choices.allSatisfy { $0.title == $0.store.title && $0.id == $0.store })
    }

    // MARK: A8 Nothing is written until Apply

    /// A8: nothing on disk and nothing in the journal changes while a lookup is begun,
    /// searched, selected in, ticked or cancelled. Applying writes exactly what was ticked,
    /// to the files and the catalogue, as one operation; Undo puts all of it back.
    @Test func A8_aLookupWritesNothingUntilItIsApplied() async throws {
        let h = try await Harness.demo()
        h.lookup.find(.audible, [saltRoadOnAudible()])
        h.lookup.find(.openLibrary, [saltRoadOnOpenLibrary()])
        h.lookup.details { candidate in
            var detailed = candidate
            detailed.metadata.summary = "From Open Library."
            detailed.hasMoreDetails = false
            return detailed
        }
        h.lookup.cover(png)
        h.recordBusyLabels()
        let id = try await h.select("Salt Road")
        let files = try filesOnDisk(h)
        let book = try h.book(id)
        let coverBefore = try savedCover(h, id)
        let tagsBefore = try FileMetadataIO().read(try #require(try h.fileURLs(id).first)).metadata
        #expect(!files.isEmpty)
        #expect(coverBefore != png)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)

        func expectUntouched(_ step: Comment) throws {
            let filesNow = try filesOnDisk(h)
            let bookNow = try h.book(id)
            let journalNow = try LibraryService(store: try h.store()).undoLabel()
            #expect(filesNow == files, step)
            #expect(bookNow == book, step)
            #expect(h.model.undoLabel == Harness.demoUndoLabel, step)
            #expect(journalNow == Harness.demoUndoLabel, step)
        }

        h.model.beginLookup()
        await h.model.settle()
        try expectUntouched("after beginning and searching")
        h.model.updateLookupQuery { $0.author = "" }
        await h.model.searchLookup()
        try expectUntouched("after searching again")
        await h.model.selectLookupCandidate(saltRoadOnOpenLibrary().id)
        await h.model.selectLookupCandidate(saltRoadOnAudible().id)
        h.model.setLookupTicked(true, for: .cover)
        h.model.setLookupTicked(true, for: .narrators)
        h.model.setLookupTicked(true, for: .year)
        try expectUntouched("after selecting and ticking")
        h.model.cancelLookup()
        #expect(!h.model.hasUnsavedChanges)
        try expectUntouched("after cancelling")
        #expect(h.busyLabels.isEmpty)

        // Applying writes exactly what was ticked.
        h.model.beginLookup()
        await h.model.settle()
        h.model.setLookupTicked(true, for: .cover)
        h.model.setLookupTicked(true, for: .narrators)
        h.model.setLookupTicked(true, for: .year)
        try expectUntouched("after another lookup, not yet applied")
        await h.model.applyLookup()
        #expect(h.model.lookup == nil)
        #expect(h.model.alert == nil)
        #expect(h.model.result == nil)
        #expect(h.busyLabels == ["Saving…"])
        let saved = try h.book(id)
        #expect(saved.narrators == ["Marcus Lindqvist", "Someone Else"])
        #expect(saved.publisher == "Tidewater Audio")
        #expect(saved.summary == "A road, and salt.")
        #expect(saved.asin == "B0SALTROAD")
        #expect(saved.year == 2019)
        #expect(saved.title == book.title)
        #expect(saved.authors == book.authors)
        // What describes the files is the files' own.
        #expect(saved.durationSeconds == book.durationSeconds)
        #expect(saved.pageCount == book.pageCount)
        #expect(try savedCover(h, id) == png)
        #expect(!h.model.hasUnsavedChanges)
        #expect(try filesOnDisk(h) != files)
        let tags = try FileMetadataIO().read(try #require(try h.fileURLs(id).first)).metadata
        #expect(tags.narrators == ["Marcus Lindqvist", "Someone Else"])
        #expect(tags.publisher == "Tidewater Audio")
        #expect(tags.year == 2019)
        // One operation in the journal.
        #expect(h.model.undoLabel == "Edit Salt Road")
        #expect(try LibraryService(store: try h.store()).undoLabel() == "Edit Salt Road")

        // And one Undo takes all of it back: the catalogue, the cover and the file's tags.
        await h.model.undo()
        #expect(try h.book(id) == book)
        #expect(try savedCover(h, id) == coverBefore)
        let tagsAfter = try FileMetadataIO().read(try #require(try h.fileURLs(id).first)).metadata
        #expect(tagsAfter.narrators == tagsBefore.narrators)
        #expect(tagsAfter.publisher == tagsBefore.publisher)
        #expect(tagsAfter.year == tagsBefore.year)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
        #expect(h.busyLabels == ["Saving…", "Undoing…"])
    }

    /// A8: the same for an import entry: nothing is imported or written by a lookup.
    @Test func A8_aLookupForAnEntryWritesNothing() async throws {
        let h = try await reviewing(["Quiet Rivers.epub"], demo: true)
        h.lookup.find(.openLibrary, [foundBook(.openLibrary, "/works/OL9W", title: "Loud Rivers", cover: true)])
        h.lookup.cover(png)
        let files = try filesOnDisk(h)
        let id = try entry(h, "Quiet Rivers").id
        let source = try #require(try entry(h, "Quiet Rivers").candidate.files.first?.url)
        let sourceData = try Data(contentsOf: source)
        h.model.updateReview { $0.update(id) { $0.addToExisting = false } }
        await h.model.settle()

        h.model.beginLookup(forEntry: id)
        await h.model.settle()
        h.model.setLookupTicked(true, for: .title)
        h.model.setLookupTicked(true, for: .cover)
        await h.model.applyLookup()
        await h.model.settle()
        #expect(h.model.review?.entry(id)?.candidate.metadata.title == "Loud Rivers")
        #expect(try filesOnDisk(h) == files)
        #expect(try Data(contentsOf: source) == sourceData)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
        #expect(h.model.rows.count == 12)
    }

    // MARK: Return, and searching again

    /// A3: searching again for what has just been answered asks nothing and keeps the
    /// selection and the ticks; a changed query, or another store, is searched.
    @Test func A3_searchingAgainForTheSameThingDoesNothing() async throws {
        let other = foundBook(.audible, "us:B0OTHER000", title: "Salt Road", authors: ["Ines Calloway"])
        let (h, _) = try await lookedUp([saltRoadOnAudible(), other])
        await h.model.selectLookupCandidate(other.id)
        await h.model.selectLookupCandidate(saltRoadOnAudible().id)
        h.model.setLookupTicked(true, for: .narrators)
        h.model.setLookupTicked(false, for: .publisher)
        let before = try #require(h.model.lookup)
        let asked = h.lookup.asked.count
        #expect(!before.canSearch)

        await h.model.searchLookup()
        #expect(h.model.lookup == before)
        #expect(h.lookup.asked.count == asked)

        // Typing something and taking it back is still the same query.
        h.model.updateLookupQuery { $0.author = "x" }
        h.model.updateLookupQuery { $0.author = before.query.author }
        await h.model.searchLookup()
        #expect(h.model.lookup == before)
        #expect(h.lookup.asked.count == asked)

        h.model.updateLookupQuery { $0.author = "" }
        #expect(h.model.lookup?.canSearch == true)
        await h.model.searchLookup()
        #expect(h.lookup.asked.count == asked + 2)
        #expect(h.model.lookup?.query.author == "")

        // Another store's catalogue is another answer.
        #expect(h.model.lookup?.canSearch == false)
        h.model.audibleStore = h.model.audibleStore == .de ? .fr : .de
        #expect(h.model.lookup?.canSearch == true)
        await h.model.searchLookup()
        #expect(h.lookup.asked.count == asked + 4)
    }

    /// A3: a search that found nothing, or that a source did not answer, can be made again as it is.
    @Test func A3_aSearchThatFellShortCanBeMadeAgain() async throws {
        let h = try await Harness.demo()
        try await h.select("Salt Road")
        h.model.beginLookup()
        await h.model.settle()
        #expect(h.model.lookup?.phase == .noResults)
        #expect(h.lookup.asked.count == 2)
        await h.model.searchLookup()
        #expect(h.lookup.asked.count == 4)

        h.lookup.find(.audible, [saltRoadOnAudible()])
        h.lookup.fail(.openLibrary, .notReachable)
        await h.model.searchLookup()
        #expect(h.model.lookup?.phase == .results)
        #expect(h.lookup.asked.count == 6)
        await h.model.searchLookup()
        #expect(h.lookup.asked.count == 8)
    }

    // MARK: What each source found, in words

    /// What each source made of the search is said once it has finished.
    @Test func theSourcesSayWhatTheyFound() async throws {
        let other = foundBook(.audible, "us:B0OTHER000", title: "Salt Road", authors: ["Ines Calloway"])
        let h = try await Harness.demo()
        h.model.audibleStore = .us
        let gate = Gate()
        h.lookup.hold(.audible, at: gate, then: [saltRoadOnAudible(), other])
        try await h.select("Salt Road")
        h.model.beginLookup()
        await gate.arrival()
        // Still searching: only where from.
        #expect(h.model.lookupSourcesText == "Results from Open Library and Audible (US, UK, Australia)")
        await gate.release()
        await h.model.settle()
        #expect(h.model.lookupSourcesText == "Open Library: no matches · Audible (US, UK, Australia): 2 matches")

        h.lookup.find(.audible, [saltRoadOnAudible()])
        h.lookup.fail(.openLibrary, .notReachable)
        h.model.updateLookupQuery { $0.author = "" }
        await h.model.searchLookup()
        #expect(h.model.lookupSourcesText == "Open Library: could not be reached · Audible (US, UK, Australia): 1 match")

        h.lookup.fail(.openLibrary, .refused(status: 500))
        h.lookup.fail(.audible, .unreadable)
        await h.model.searchLookup()
        #expect(h.model.lookupSourcesText
            == "Open Library: answered with an error · Audible (US, UK, Australia): sent an answer VoxCarrel could not read")

        // Another store: what was found is no longer that store's.
        h.model.audibleStore = .uk
        #expect(h.model.lookupSourcesText == "Results from Open Library and Audible (UK, US, Australia)")
        h.model.cancelLookup()
        #expect(h.model.lookupSourcesText == "Results from Open Library and Audible (UK, US, Australia)")
    }

    // MARK: An import arriving, and entries that join a book

    /// An import to review closes a lookup for the inspected book, with nothing applied,
    /// and its entries can then be looked up.
    @Test func anImportToReviewClosesTheInspectorsLookup() async throws {
        let (h, _) = try await lookedUp([saltRoadOnAudible()])
        #expect(h.model.lookup != nil)
        let inbox = try Harness.inbox()
        await h.model.openFiles([inbox.appendingPathComponent("Tidewater Chronicles")])
        await h.model.settle()
        let review = try #require(h.model.review)
        #expect(h.model.lookup == nil)
        #expect(!h.model.hasUnsavedChanges)
        // The demo library has these books already: one is made a book of its own.
        let free = try #require(review.entries.first)
        h.model.updateReview { $0.update(free.id) { $0.addToExisting = false } }
        #expect(h.model.canLookUpEntry(free.id))
        h.model.beginLookup(forEntry: free.id)
        #expect(h.model.importLookup != nil)
        // A change to the review does not close the entry's own lookup.
        h.model.updateReview { $0.copyInsteadOfMove.toggle() }
        #expect(h.model.importLookup != nil)
    }

    /// An entry whose files join a book already in the library keeps that book's
    /// details: it is not looked up until it is to be a book of its own.
    @Test func anEntryThatJoinsABookIsNotLookedUp() async throws {
        let h = try await reviewing(["Quiet Rivers.epub"], demo: true)
        let joined = try entry(h, "Quiet Rivers")
        #expect(joined.isAddedToExisting)
        #expect(!h.model.canLookUpEntry(joined.id))
        #expect(h.model.lookUpHelp(forEntry: joined.id).contains("Switch off “Add to the existing book”"))
        h.model.beginLookup(forEntry: joined.id)
        #expect(h.model.lookup == nil)
        #expect(h.lookup.asked.isEmpty)

        h.model.updateReview { $0.update(joined.id) { $0.addToExisting = false } }
        #expect(h.model.canLookUpEntry(joined.id))
        #expect(h.model.lookUpHelp(forEntry: joined.id) == h.model.lookUpHelp)
        h.model.beginLookup(forEntry: joined.id)
        #expect(h.model.importLookup != nil)
    }

    // MARK: More about a result

    /// Changing the query while more about the selected result is on its way does not lose it.
    @Test func A3_editingTheQueryDoesNotLoseTheDetails() async throws {
        let h = try await Harness.demo()
        let gate = Gate()
        h.lookup.find(.openLibrary, [saltRoadOnOpenLibrary()])
        h.lookup.details { candidate in
            await gate.wait()
            // What a real request does when its task is cancelled.
            try Task.checkCancellation()
            var detailed = candidate
            detailed.metadata.summary = "From Open Library."
            detailed.hasMoreDetails = false
            return detailed
        }
        try await h.select("Salt Road")
        h.model.beginLookup()
        await gate.arrival()
        #expect(h.model.lookup?.phase == .results)

        h.model.updateLookupQuery { $0.author = "" }
        await gate.release()
        await h.model.settle()
        #expect(h.model.lookup?.selected?.metadata.summary == "From Open Library.")
        #expect(h.model.lookup?.offers.contains { $0.id == .summary } == true)
        #expect(h.lookup.detailsAsked.count == 1)
    }

    /// More that could not be fetched is asked for again when the result is next selected,
    /// and is asked for once however often it is selected meanwhile.
    @Test func A3_detailsThatFailedAreAskedForAgain() async throws {
        let h = try await Harness.demo()
        let other = foundBook(.openLibrary, "/works/OL2W", title: "Salt Road", authors: ["Ines Calloway"])
        h.lookup.find(.openLibrary, [saltRoadOnOpenLibrary(), other])
        h.lookup.details { _ in throw LookupError.notReachable }
        try await h.select("Salt Road")
        h.model.beginLookup()
        await h.model.settle()
        #expect(h.lookup.detailsAsked == [saltRoadOnOpenLibrary().id])
        #expect(h.model.lookup?.offers.contains { $0.id == .summary } == false)

        let gate = Gate()
        h.lookup.details { candidate in
            await gate.wait()
            var detailed = candidate
            detailed.metadata.summary = "From Open Library."
            detailed.hasMoreDetails = false
            return detailed
        }
        await h.model.selectLookupCandidate(other.id)
        async let first: Void = h.model.selectLookupCandidate(saltRoadOnOpenLibrary().id)
        await gate.arrival()
        async let second: Void = h.model.selectLookupCandidate(saltRoadOnOpenLibrary().id)
        await gate.release()
        _ = await (first, second)
        await h.model.settle()
        #expect(h.lookup.detailsAsked == [saltRoadOnOpenLibrary().id, saltRoadOnOpenLibrary().id])
        #expect(h.model.lookup?.offers.contains { $0.id == .summary } == true)

        // Closing takes what is on its way with it.
        h.model.cancelLookup()
        #expect(h.model.lookupDetailLoads.isEmpty)
    }

    // MARK: The row's picture and the cover

    private func withBothPictures() -> LookupCandidate {
        foundBook(.audible, "us:B0SALTROAD", title: "Salt Road", authors: ["Ines Calloway"], cover: true, thumbnail: true)
    }

    /// The row shows the smaller picture; Apply fetches the cover itself.
    @Test func V6_theRowsPictureIsTheSmallerOne() async throws {
        let jpeg = MediaFixtures.makeImage(.jpeg)
        let candidate = withBothPictures()
        let (h, id) = try await lookedUp([candidate])
        let png = png
        h.lookup.cover { url in (url == candidate.thumbnailURL ? jpeg : png, 200) }
        #expect(await h.model.lookupThumbnail(for: candidate) == jpeg)
        #expect(h.lookup.coverURLs == [try #require(candidate.thumbnailURL)])
        #expect(h.model.cachedLookupThumbnail(for: candidate) == jpeg)

        h.model.setLookupTicked(true, for: .cover)
        await h.model.applyLookup()
        #expect(h.lookup.coverURLs == [try #require(candidate.thumbnailURL), try #require(candidate.coverURL)])
        #expect(try savedCover(h, id) == png)
        #expect(h.model.alert == nil)
    }

    /// When the row's picture is the cover itself it is not fetched a second time.
    @Test func A4_aCoverAlreadyFetchedForItsRowIsNotFetchedAgain() async throws {
        let candidate = saltRoadOnAudible()
        #expect(candidate.thumbnailURL == nil)
        let (h, id) = try await lookedUp([candidate])
        h.lookup.cover(png)
        #expect(await h.model.lookupThumbnail(for: candidate) == png)
        h.model.setLookupTicked(true, for: .cover)
        await h.model.applyLookup()
        #expect(h.lookup.coverURLs.count == 1)
        #expect(h.model.lookup == nil)
        #expect(try savedCover(h, id) == png)
        #expect(h.model.alert == nil)
    }

    /// A cover that cannot be downloaded: the smaller picture already fetched is used, and nothing is said.
    @Test func A4_aCoverThatFailsFallsBackToTheRowsPicture() async throws {
        let jpeg = MediaFixtures.makeImage(.jpeg)
        let candidate = withBothPictures()
        let (h, id) = try await lookedUp([candidate])
        h.lookup.cover { url in
            guard url == candidate.thumbnailURL else { throw LookupError.notReachable }
            return (jpeg, 200)
        }
        #expect(await h.model.lookupThumbnail(for: candidate) == jpeg)
        h.model.setLookupTicked(true, for: .cover)
        await h.model.applyLookup()
        #expect(h.lookup.coverURLs.count == 2)
        #expect(try savedCover(h, id) == jpeg)
        #expect(h.model.alert == nil)
        #expect(h.model.lookup == nil)
    }

    /// With no picture fetched for the row either, the alert says so as before.
    @Test func A4_aCoverThatFailsWithNoRowPictureIsReported() async throws {
        let (h, id) = try await lookedUp([withBothPictures()])
        let coverBefore = try savedCover(h, id)
        h.model.setLookupTicked(true, for: .cover)
        for field in h.model.lookup?.tickedFields ?? [] where field != .cover { h.model.setLookupTicked(false, for: field) }
        await h.model.applyLookup()
        #expect(h.model.draftCover == .stored)
        #expect(try savedCover(h, id) == coverBefore)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
        #expect(h.model.alert == "The cover could not be downloaded.")
    }

    // MARK: What is typed but is no year

    /// A1, K4: a year box holding something that is no year is not written over unasked.
    @Test func A1_aYearThatIsNotAYearIsNotWrittenOverUnasked() async throws {
        let h = try await Harness.demo()
        h.lookup.find(.audible, [saltRoadOnAudible()])
        try await h.select("Salt Road")
        h.model.updateDraft { $0.year = "19x4" }
        h.model.beginLookup()
        await h.model.settle()
        let year = try #require(h.model.lookup?.offers.first { $0.id == .year })
        #expect(year.current == "19x4")
        #expect(year.currentText == "Now: 19x4")
        #expect(!year.ticked)
        let problem = try #require(h.draft?.problems.first)
        await h.model.applyLookup()
        guard case .one(_, let draft) = h.model.inspecting else {
            Issue.record("no book inspected")
            return
        }
        #expect(draft.year == "19x4")
        // Nothing can be saved while the year is no year: what was applied waits in the draft.
        #expect(h.model.alert == problem)
        #expect(draft.publisher == "Tidewater Audio")
        #expect(h.model.hasUnsavedChanges)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)

        // An empty box is a gap, filled by default.
        h.model.updateDraft { $0.year = "" }
        h.model.beginLookup()
        await h.model.settle()
        #expect(h.model.lookup?.offers.first { $0.id == .year }?.ticked == true)
    }

    // MARK: The worker

    /// The worker looks things up with the service it was given, or was given since.
    @Test func theWorkerLooksUpWithItsService() async throws {
        let first = FakeLookup()
        first.find(.audible, [saltRoadOnAudible()])
        let worker = try LibraryWorker(libraryRoot: try makeTempDir(), lookup: first.service(store: .us))
        let query = LookupQuery(title: "Salt Road")
        let results = await worker.lookUp(query, preferAudio: true, language: "en")
        #expect(results.candidates == [saltRoadOnAudible()])
        #expect(results.searched == [.openLibrary, .audible])
        #expect(first.asked.map(\.store) == [.us, .us])

        first.details { candidate in
            var detailed = candidate
            detailed.metadata.summary = "More."
            return detailed
        }
        #expect(try await worker.lookupDetails(for: saltRoadOnAudible()).metadata.summary == "More.")
        first.cover(png)
        #expect(try await worker.lookupCover(for: saltRoadOnAudible()) == CoverImage(data: png, mime: "image/png"))
        await #expect(throws: LookupError.unreadable) {
            _ = try await worker.lookupCover(for: saltRoadOnAudible(cover: false))
        }

        let second = FakeLookup()
        worker.setLookupService(second.service(store: .uk))
        _ = await worker.lookUp(query, preferAudio: true, language: nil)
        #expect(first.asked.count == 2)
        #expect(second.asked.map(\.store) == [.uk, .uk])
    }
}

/// Counts calls from several tasks.
private actor Counter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}
