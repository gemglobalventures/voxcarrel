import Foundation
import Security
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// HL22–HL33: the Readwise token, and Import Highlights as its session decides it.
/// Nothing here reaches Readwise, Amazon, the Keychain or the home folder.
@MainActor
@Suite struct HighlightsImportTests {
    typealias S = HighlightSamples
    typealias T = HighlightsImportText

    private static let token = "tok_abc123"

    /// A started demo library whose model has a Readwise token saved.
    private func withToken() async throws -> Harness {
        let h = try await Harness.demo()
        try h.readwiseTokens.save(Self.token)
        h.model.readReadwiseToken()
        return h
    }

    /// Adds a book that is on Audible, with no files, and has the model read everything again.
    @discardableResult
    private func addAudibleBook(_ h: Harness, _ title: String, asin: String) async throws -> Int64 {
        let outcome = try h.service().addExternalBook(
            metadata: BookMetadata(title: title, authors: ["Nell Listener"]), cover: nil,
            copy: ExternalCopy(kind: .audible, form: .audio, store: "us", itemId: asin))
        await h.model.reloadAll()
        guard case .added(let id) = outcome else {
            Issue.record("the book was not added")
            return -1
        }
        return id
    }

    private func marksAsked(_ h: Harness) -> [String] {
        h.audible.asked.compactMap(\.url).filter { $0.path.hasSuffix("/sidecar") }.compactMap(\.query)
    }

    // MARK: The token

    @Test func HL22_theTokenIsKeptGivenBackAndRemoved() throws {
        let store = InMemoryReadwiseTokenStore()
        #expect(store.load() == nil)
        try store.save("one")
        #expect(store.load() == "one")
        try store.save("two")
        #expect(store.load() == "two")
        store.remove()
        #expect(store.load() == nil)
    }

    @Test func HL22_aTokenInAFileIsReadableOnlyByTheOwner() throws {
        let url = try makeTempDir().appendingPathComponent("VoxCarrel/readwise-token")
        let store = FileReadwiseTokenStore(url: url)
        #expect(store.load() == nil)
        try store.save(Self.token)
        #expect(store.load() == Self.token)
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        #expect(mode.int16Value & 0o777 == 0o600)
        // Saved again, it is replaced, and private still.
        try store.save("another")
        #expect(store.load() == "another")
        let again = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        #expect(again.int16Value & 0o777 == 0o600)
        store.remove()
        #expect(store.load() == nil && !FileManager.default.fileExists(atPath: url.path))
        // A file with nothing in it holds no token; one with a line end holds the token alone.
        try Data(" \n".utf8).write(to: url)
        #expect(store.load() == nil)
        try Data("  tok\n".utf8).write(to: url)
        #expect(store.load() == "tok")
    }

    @Test func HL22_theKeychainItemIsThisDevicesOnlyAndABuildNobodySignedUsesAFile() {
        let query = KeychainReadwiseTokenStore.item
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "app.voxcarrel.VoxCarrel.readwise")
        #expect(query[kSecAttrAccount as String] as? String == "token")
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        // A build made here carries no team's signature. Neither is asked for anything.
        #expect(ReadwiseTokenStores.standard() is FileReadwiseTokenStore)
        #expect(FileReadwiseTokenStore.standardURL.path.hasSuffix("Application Support/VoxCarrel/readwise-token"))
    }

    @Test func HL22_aTestsModelNeverHasTheRealTokenStoresOrTheHomeFolder() async throws {
        let h = try await Harness.empty()
        #expect(h.model.readwiseTokens is InMemoryReadwiseTokenStore)
        #expect(h.relaunched().readwiseTokens is InMemoryReadwiseTokenStore)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(!h.model.readwiseTokenFile.path.hasPrefix(home + "/.config"))
        #expect(!h.relaunched().readwiseTokenFile.path.hasPrefix(home + "/.config"))
        #expect(!h.model.hasReadwiseToken)
    }

    @Test func HL23_theSettingsSaveATokenAndNeverShowItAgain() async throws {
        let h = try await Harness.empty()
        #expect(!h.model.hasReadwiseToken)
        #expect(h.model.readwiseSavedText == "A Readwise token is saved.")
        #expect(h.model.readwiseSettingsText.contains("readwise.io/access_token"))
        #expect(!h.model.canSaveReadwiseToken && !h.model.canRemoveReadwiseToken)
        h.model.readwiseTokenDraft = "   "
        #expect(!h.model.canSaveReadwiseToken)
        // What could be no token is not taken for one.
        h.model.readwiseTokenDraft = "two words"
        #expect(!h.model.canSaveReadwiseToken)
        h.model.saveReadwiseToken()
        #expect(!h.model.hasReadwiseToken && h.readwiseTokens.load() == nil)

        h.model.readwiseTokenDraft = "  \(Self.token) \n"
        #expect(h.model.canSaveReadwiseToken)
        h.model.saveReadwiseToken()
        #expect(h.model.hasReadwiseToken && h.model.canRemoveReadwiseToken)
        #expect(h.readwiseTokens.load() == Self.token)
        // What was typed is gone from the field, and is in no preference.
        #expect(h.model.readwiseTokenDraft == "")
        #expect(!h.defaults.dictionaryRepresentation().description.contains(Self.token))
        #expect(h.model.alert == nil)
        // The app opened again has it still.
        #expect(h.relaunched().hasReadwiseToken)

        h.model.removeReadwiseToken()
        #expect(!h.model.hasReadwiseToken && h.readwiseTokens.load() == nil)
    }

    @Test func HL23_aTokenAlreadyOnThisMacIsOfferedAndUsed() async throws {
        let h = try await Harness.empty()
        #expect(!h.model.offersReadwiseTokenOnThisMac)
        #expect(h.model.useReadwiseTokenTitle == "Use the token already on this Mac")
        h.model.useReadwiseTokenOnThisMac()
        #expect(!h.model.hasReadwiseToken)

        try Data("file_token_9\n".utf8).write(to: h.readwiseTokenFile)
        #expect(h.model.offersReadwiseTokenOnThisMac)
        h.model.useReadwiseTokenOnThisMac()
        #expect(h.model.hasReadwiseToken)
        #expect(h.readwiseTokens.load() == "file_token_9")
        // Nothing more to offer once one is saved, and the file is as it was.
        #expect(!h.model.offersReadwiseTokenOnThisMac)
        #expect(try String(contentsOf: h.readwiseTokenFile, encoding: .utf8) == "file_token_9\n")

        // A file that holds no token is not offered.
        h.model.removeReadwiseToken()
        try Data("\n".utf8).write(to: h.readwiseTokenFile)
        #expect(!h.model.offersReadwiseTokenOnThisMac)
    }

    // MARK: What will be read

    @Test func HL24_withNoTokenAndNoAccountTheSheetSaysWhatIsNeeded() async throws {
        let h = try await Harness.demo()
        #expect(h.model.canImportHighlights)
        h.model.beginHighlightsImport()
        let session = try #require(h.model.highlightsImport)
        #expect(h.model.windowSheet(progressDue: false) == .highlightsImport(SheetObject(session)))
        #expect(session.title == "Import Highlights")
        #expect(session.phase == .ready)
        #expect(session.sources.isEmpty)
        #expect(session.problem == "Add a Readwise token or link your Audible account in Settings first.")
        #expect(!session.canStart && !session.canImport)
        #expect(session.closeTitle == "Close")
        session.start()
        #expect(session.phase == .ready && session.reading == nil)
        #expect(h.audible.asked.isEmpty)
        session.cancel()
        #expect(h.model.highlightsImport == nil)
    }

    @Test func HL24_theSheetSaysWhichSourcesItWillRead() async throws {
        let h = try await withToken()
        h.model.beginHighlightsImport()
        var session = try #require(h.model.highlightsImport)
        #expect(session.sources == ["Readwise (your Kindle highlights)"])
        #expect(session.problem == nil && session.canStart)
        #expect(session.startTitle == "Read Highlights" && session.closeTitle == "Cancel")
        // Nothing is asked of anyone until it is started.
        #expect(h.audible.asked.isEmpty)
        session.cancel()

        try h.link()
        h.model.beginHighlightsImport()
        session = try #require(h.model.highlightsImport)
        #expect(session.sources == ["Readwise (your Kindle highlights)", "Audible (marks you made while listening)"])
        session.cancel()

        h.model.removeReadwiseToken()
        h.model.beginHighlightsImport()
        session = try #require(h.model.highlightsImport)
        #expect(session.sources == ["Audible (marks you made while listening)"])
        #expect(session.canStart)
    }

    @Test func HL25_whileItReadsItSaysWhatItIsReading() async throws {
        #expect(T.readingReadwise == "Reading from Readwise…")
        #expect(T.readingMarks(12, of: 217) == "Reading marks from Audible, 12 of 217…")

        let h = try await withToken()
        let gate = Gate()
        h.audible.gate = gate
        h.audible.readwiseHolds([])
        h.model.beginHighlightsImport()
        let session = try #require(h.model.highlightsImport)
        #expect(session.progressText == nil)
        session.start()
        await gate.arrival()
        #expect(session.phase == .reading)
        #expect(session.progressText == "Reading from Readwise…")
        #expect(!session.canStart && !session.canImport)
        // The token goes to Readwise, and to nobody else.
        let asked = try #require(h.audible.asked.first)
        #expect(asked.url?.host == "readwise.io" && asked.url?.scheme == "https")
        #expect(asked.value(forHTTPHeaderField: "Authorization") == "Token \(Self.token)")
        await gate.release()
        await session.reading?.value
        #expect(session.phase == .review)
        #expect(h.audible.asked.count == 1)
    }

    @Test func HL25_marksAreReadOneBookAtATimeAndCounted() async throws {
        let h = try await Harness.demo()
        try h.link()
        try await addAudibleBook(h, "First Listen", asin: "B0AUDIO001")
        try await addAudibleBook(h, "Second Listen", asin: "B0AUDIO002")
        let gate = Gate()
        h.audible.gate = gate
        h.model.beginHighlightsImport()
        let session = try #require(h.model.highlightsImport)
        session.start()
        await gate.arrival()
        #expect(session.progressText == "Reading marks from Audible, 1 of 2…")
        #expect(h.audible.asked.count == 1)
        await gate.release()
        await session.reading?.value
        #expect(session.phase == .review)
        // Only the books that are on Audible, each by its Audible ID, and signed as the account.
        #expect(marksAsked(h) == ["type=AUDI&key=B0AUDIO001", "type=AUDI&key=B0AUDIO002"])
        #expect(h.audible.asked.allSatisfy { $0.url?.host == "cde-ta-g7g.amazon.com" })
        #expect(h.audible.asked.allSatisfy { $0.value(forHTTPHeaderField: "x-adp-token") == "{adp-token}" })
    }

    // MARK: The review

    /// Readwise holds two Kindle books the library lacks, one it has, and one that is
    /// owned nowhere the app knows.
    private func readwiseAnswer(_ h: Harness) {
        h.audible.readwiseHolds([
            S.readwiseBook("Deep Work", author: "Cal Newport", asin: "B00KINDLE01", highlights: [
                S.readwiseHighlight(1, "Focus.", location: 10), S.readwiseHighlight(2, "Quit.", location: 20),
            ]),
            S.readwiseBook("Zen Mind", author: "Shunryu Suzuki", asin: "B00KINDLE02", highlights: [
                S.readwiseHighlight(3, "Sit.", location: 5),
            ]),
            S.readwiseBook("Quiet Rivers", author: "Amara Okafor", asin: nil, source: "ibooks", highlights: [
                S.readwiseHighlight(4, "The river.", location: 1),
            ]),
            S.readwiseBook("Quotes", author: "Nobody", asin: nil, source: "manual", highlights: [
                S.readwiseHighlight(5, "Loose.", location: 1),
            ]),
        ])
    }

    @Test func HL26_theReviewSaysWhatImportingWouldDoAndChangesNothing() async throws {
        let h = try await withToken()
        readwiseAnswer(h)
        let before = try h.store().books().count
        let session = try await h.highlightsImportRead()
        #expect(session.phase == .review && session.problem == nil)
        #expect(session.summary == "5 highlights on 4 books.")
        #expect(session.lines == [
            "2 books will be added as books you own on Kindle.",
            "1 book you already have will get highlights.",
            "1 book is owned nowhere VoxCarrel knows and is left out: Quotes.",
        ])
        #expect(session.titlesToAdd == ["Deep Work", "Zen Mind"])
        #expect(session.moreToAdd == nil)
        #expect(session.addTitle == "To be added")
        #expect(session.note == "No file is added or changed.")
        #expect(session.canImport && session.importTitle == "Import" && session.closeTitle == "Cancel")
        // Nothing has changed.
        #expect(try h.store().books().count == before)
        #expect(try h.store().highlightCounts().isEmpty)
        #expect(!h.model.showsHighlights)

        session.cancel()
        #expect(h.model.highlightsImport == nil)
        #expect(try h.store().books().count == before)
    }

    @Test func HL26_everyLineOfTheReviewInOneAndInMany() {
        var report = HighlightsReport()
        report.booksAdded = (1...86).map { "Book \($0)" }
        report.booksMatched = 9
        report.booksGaining = 3
        report.added = 751
        report.changed = 12
        report.removed = 2
        report.booksLeftOut = ["Quotes", "High Output Management", "Third", "Fourth"]
        #expect(T.summary(highlights: 751, books: 86, report: report) == "751 highlights on 86 books.")
        #expect(T.lines(for: report) == [
            "86 books will be added as books you own on Kindle.",
            "3 books you already have will get highlights.",
            "751 highlights are new.",
            "12 highlights have changed and will be updated.",
            "2 highlights were deleted at the source and will be removed.",
            "4 books are owned nowhere VoxCarrel knows and are left out: Quotes, High Output Management, Third "
                + "and 1 more.",
        ])

        var one = HighlightsReport()
        one.booksAdded = ["Deep Work"]
        one.booksGaining = 1
        one.added = 2
        one.changed = 1
        one.removed = 1
        one.booksLeftOut = ["Quotes"]
        #expect(T.summary(highlights: 1, books: 1, report: one) == "1 highlight on 1 book.")
        // Where some of what was read is here already, how many are new is said.
        #expect(T.lines(for: one) == [
            "1 book will be added as a book you own on Kindle.",
            "1 book you already have will get highlights.",
            "2 highlights are new.",
            "1 highlight has changed and will be updated.",
            "1 highlight was deleted at the source and will be removed.",
            "1 book is owned nowhere VoxCarrel knows and is left out: Quotes.",
        ])
        one.added = 1
        #expect(T.lines(for: one).contains("1 highlight is new."))
        // All of it new: the summary has said how many.
        var first = HighlightsReport()
        first.booksAdded = ["Deep Work", "Zen Mind"]
        first.added = 3
        #expect(T.lines(for: first) == ["2 books will be added as books you own on Kindle."])
        one.booksLeftOut = ["A", "B", "C"]
        #expect(T.lines(for: one).last == "3 books are owned nowhere VoxCarrel knows and are left out: A, B, C.")
        one.booksLeftOut = ["A", "B", "C", "D", "E", "F"]
        #expect(
            T.lines(for: one).last
                == "6 books are owned nowhere VoxCarrel knows and are left out: A, B, C and 3 more.")

        // Nothing read, and nothing to do.
        #expect(T.summary(highlights: 0, books: 0, report: HighlightsReport()) == "No highlights were found.")
        var same = HighlightsReport()
        same.booksMatched = 3
        same.unchanged = 40
        #expect(T.summary(highlights: 40, books: 3, report: same) == "40 highlights on 3 books. Everything is already here.")
        #expect(T.lines(for: same).isEmpty)

        // A long list shows its first 500 titles.
        let many = (1...620).map { "Book \($0)" }
        #expect(T.shown(many).count == 500 && T.shown(many).last == "Book 500")
        #expect(T.more(many) == "and 120 more")
        #expect(T.more(Array(many.prefix(500))) == nil)
    }

    @Test func HL27_withEverythingHereAlreadyThereIsNothingToImport() async throws {
        let h = try await withToken()
        readwiseAnswer(h)
        var session = try await h.highlightsImportRead()
        await session.apply()
        h.model.alert = nil

        session = try await h.highlightsImportRead()
        #expect(session.phase == .review)
        #expect(session.summary == "5 highlights on 4 books. Everything is already here.")
        // What is left out is still said.
        #expect(session.lines == ["1 book is owned nowhere VoxCarrel knows and is left out: Quotes."])
        #expect(session.titlesToAdd.isEmpty)
        #expect(!session.canImport)
        #expect(session.closeTitle == "Close")
        await session.apply()
        #expect(h.model.highlightsImport === session && h.model.alert == nil)
    }

    // MARK: Importing

    @Test func HL28_importingAddsTheBooksAndHighlightsAndSaysSo() async throws {
        let h = try await withToken()
        readwiseAnswer(h)
        let before = try h.store().books().count
        let session = try await h.highlightsImportRead()
        h.recordBusyLabels()
        await session.apply()
        #expect(h.busyLabels == ["Importing highlights…"])
        #expect(h.model.highlightsImport == nil)
        #expect(h.model.alert == "Added 4 highlights and 2 books.")
        #expect(h.model.busyLabel == nil)

        let store = try h.store()
        #expect(try store.books().count == before + 2)
        let onKindle = try store.books(ownedOn: .kindle)
        #expect(onKindle.map(\.title) == ["Deep Work", "Zen Mind"])
        #expect(onKindle.allSatisfy { $0.folderPath == nil && !$0.needsAttention })
        #expect(try store.files(bookId: try h.id("Deep Work")).isEmpty)
        #expect(try store.highlights(forBook: try h.id("Deep Work")).map(\.text) == ["Focus.", "Quit."])
        #expect(try store.highlights(forBook: try h.id("Quiet Rivers")).map(\.text) == ["The river."])
        // And the model shows them.
        #expect(h.model.showsOnKindle && h.model.onKindleCount == 2)
        #expect(h.model.showsHighlights && h.model.highlightedBookCount == 3)
        #expect(h.model.highlightCount(for: try h.id("Deep Work")) == 2)
        await h.model.audibleCovers?.value

        // Read again after Readwise changed one and deleted another.
        h.audible.readwiseHolds([
            S.readwiseBook("Deep Work", author: "Cal Newport", asin: "B00KINDLE01", highlights: [
                S.readwiseHighlight(1, "Focus harder.", location: 10), S.readwiseHighlight(2, "Quit.", deleted: true),
            ])
        ])
        let again = try await h.highlightsImportRead()
        #expect(again.summary == "1 highlight on 1 book.")
        #expect(again.lines == [
            "1 highlight has changed and will be updated.",
            "1 highlight was deleted at the source and will be removed.",
        ])
        #expect(again.canImport)
        await again.apply()
        #expect(h.model.alert == "Updated 1 highlight. Removed 1 highlight.")
        #expect(try store.highlights(forBook: try h.id("Deep Work")).map(\.text) == ["Focus harder."])
    }

    @Test func HL28_theOutcomeLeavesOutWhatIsNothing() {
        var report = HighlightsReport()
        report.added = 751
        report.booksAdded = (1...86).map { "Book \($0)" }
        #expect(T.outcome(of: report) == "Added 751 highlights and 86 books.")
        report.changed = 12
        report.removed = 2
        #expect(T.outcome(of: report) == "Added 751 highlights and 86 books. Updated 12 highlights. Removed 2 highlights.")
        report.added = 1
        report.booksAdded = ["One"]
        report.changed = 1
        report.removed = 1
        #expect(T.outcome(of: report) == "Added 1 highlight and 1 book. Updated 1 highlight. Removed 1 highlight.")
        report.booksAdded = []
        report.changed = 0
        report.removed = 0
        #expect(T.outcome(of: report) == "Added 1 highlight.")
        report.added = 5
        #expect(T.outcome(of: report) == "Added 5 highlights.")
        report.added = 0
        report.removed = 2
        #expect(T.outcome(of: report) == "Removed 2 highlights.")
        #expect(T.outcome(of: HighlightsReport()) == "Everything is already here.")
    }

    @Test func HL29_marksMadeOnAudibleBecomeHighlightsOfTheLibrarysOwnBook() async throws {
        let h = try await Harness.demo()
        try h.link()
        let first = try await addAudibleBook(h, "First Listen", asin: "B0AUDIO001")
        let second = try await addAudibleBook(h, "Second Listen", asin: "B0AUDIO002")
        // A book with files here that is marked as on Audible, with the book's own ID.
        let lighthouse = try h.id("The Lighthouse Keeper")
        var edit = BookEdit(book: try h.book(lighthouse))
        edit.metadata.asin = "B0LIGHT003"
        _ = try h.service().save([edit])
        try h.service().setExternalCopies([ExternalCopy(kind: .audible, form: .audio, store: "us")], for: lighthouse)
        await h.model.reloadAll()
        h.audible.holdsMarks([
            S.mark("m1", at: 60), S.mark("m2", at: 3600, end: 3630, note: "Remember this"),
            ["type": "audible.last_heard", "startPosition": "5000"],
        ], for: "B0AUDIO001")
        h.audible.holdsMarks([S.mark("m3", at: 30)], for: "B0LIGHT003")
        let before = try h.store().books().count

        let session = try await h.highlightsImportRead()
        #expect(Set(marksAsked(h)) == ["type=AUDI&key=B0AUDIO001", "type=AUDI&key=B0AUDIO002", "type=AUDI&key=B0LIGHT003"])
        #expect(session.phase == .review)
        #expect(session.summary == "3 highlights on 2 books.")
        #expect(session.lines == ["2 books you already have will get highlights."])
        #expect(session.titlesToAdd.isEmpty)
        await session.apply()
        #expect(h.model.alert == "Added 3 highlights.")
        // No book is added: the marks sit on the books that were asked about.
        #expect(try h.store().books().count == before)
        let marks = try h.store().highlights(forBook: first)
        #expect(marks.map(\.source) == [.audible, .audible])
        #expect(marks.map(\.location) == [60, 3600])
        #expect(marks.map(\.note) == [nil, "Remember this"])
        #expect(try h.store().highlights(forBook: second).isEmpty)
        #expect(try h.store().highlights(forBook: lighthouse).count == 1)
        let rows = marks.map { HighlightRow($0) }
        #expect(rows.map(\.placeText) == ["at 1 min", "at 1 h 0 min, 30 seconds long"])
        #expect(rows.first?.isEmptyMark == true && rows.last?.isEmptyMark == false)
    }

    // MARK: When it goes wrong

    @Test func HL30_whatWentWrongWithReadwiseIsSaidInPlainWords() async throws {
        #expect(UserMessage.highlightsProblem(ReadwiseError.refused) == "Readwise did not accept the token. Check it in Settings.")
        #expect(
            UserMessage.highlightsProblem(ReadwiseError.notReachable)
                == "Readwise could not be reached. Check your internet connection.")
        #expect(
            UserMessage.highlightsProblem(ReadwiseError.busy)
                == "Readwise asked to be left alone for a while. Try again in a few minutes.")
        #expect(UserMessage.highlightsProblem(ReadwiseError.unreadable) == "Your highlights could not be read.")
        #expect(UserMessage.highlightsProblem(CocoaError(.fileNoSuchFile)) == "Your highlights could not be read.")

        func failure(_ arrange: (Harness) -> Void) async throws -> HighlightsImportSession {
            let h = try await withToken()
            arrange(h)
            let session = try await h.highlightsImportRead()
            #expect(session.phase == .failed)
            #expect(!session.canImport && !session.canStart && session.closeTitle == "Close")
            #expect(session.summary == nil && session.lines.isEmpty)
            #expect(try h.store().highlightCounts().isEmpty)
            return session
        }
        var session = try await failure { $0.audible.answer("/api/v2/export", with: ["detail": "Invalid token."], status: 401) }
        #expect(session.problem == "Readwise did not accept the token. Check it in Settings.")
        session = try await failure { $0.audible.fails = true }
        #expect(session.problem == "Readwise could not be reached. Check your internet connection.")
        // Asked to slow down again and again; no test waits for it.
        session = try await failure { $0.audible.answer("/api/v2/export", with: [:], status: 429) }
        #expect(session.problem == "Readwise asked to be left alone for a while. Try again in a few minutes.")
        session = try await failure { $0.audible.answer("/api/v2/export", with: ["nothing": "useful"], status: 500) }
        #expect(session.problem == "Your highlights could not be read.")
    }

    @Test func HL31_anAudibleAccountThatIsRefusedStopsOnlyTheAudiblePart() async throws {
        let h = try await withToken()
        try h.link()
        try await addAudibleBook(h, "First Listen", asin: "B0AUDIO001")
        try await addAudibleBook(h, "Second Listen", asin: "B0AUDIO002")
        readwiseAnswer(h)
        h.audible.answer("/FionaCDEServiceEngine/sidecar", with: [:], status: 403)

        let session = try await h.highlightsImportRead()
        // The first refusal is the last thing asked of Audible.
        #expect(marksAsked(h) == ["type=AUDI&key=B0AUDIO001"])
        #expect(session.phase == .review && session.problem == nil)
        #expect(session.summary == "5 highlights on 4 books.")
        #expect(
            session.lines.last
                == "Your marks on Audible were not read: Audible no longer accepts this link. Unlink the account "
                + "in Settings and link it again.")
        #expect(session.lines.count == 4)
        // What Readwise gave can still be brought in.
        #expect(session.canImport)
        await session.apply()
        #expect(h.model.alert == "Added 4 highlights and 2 books.")
    }

    @Test func HL31_aBookWhoseMarksCannotBeReadIsPassedOver() async throws {
        let h = try await Harness.demo()
        try h.link()
        try await addAudibleBook(h, "First Listen", asin: "B0AUDIO001")
        try await addAudibleBook(h, "Second Listen", asin: "B0AUDIO002")
        // One answers with something that is no answer; the other has a mark.
        h.audible.answer("/FionaCDEServiceEngine/sidecar", query: "type=AUDI&key=B0AUDIO001", with: [:], status: 500)
        h.audible.holdsMarks([S.mark("m1", at: 60)], for: "B0AUDIO002")
        var session = try await h.highlightsImportRead()
        #expect(marksAsked(h).count == 2)
        #expect(session.phase == .review)
        #expect(session.summary == "1 highlight on 1 book.")
        #expect(session.lines == ["1 book you already have will get highlights."])
        session.cancel()

        // Audible cannot be reached at all: that is said, and there is nothing to import.
        h.audible.fails = true
        session = try await h.highlightsImportRead()
        #expect(session.phase == .review)
        #expect(session.summary == "No highlights were found.")
        #expect(session.lines == [
            "Your marks on Audible were not read: Audible could not be reached. Check your internet connection."
        ])
        #expect(!session.canImport && session.closeTitle == "Close")
    }

    // MARK: Covers

    @Test func HL32_coversAreFetchedOnlyFromAmazonsAndReadwisesOwnHosts() async throws {
        let hosts = AudibleCoverDownload.highlightHosts
        func allowed(_ address: String) -> Bool {
            AudibleCoverDownload.allows(URL(string: address)!, hosts: hosts)
        }
        #expect(allowed("https://m.media-amazon.com/images/I/x.jpg"))
        #expect(allowed("https://images-na.ssl-images-amazon.com/images/I/x.jpg"))
        #expect(allowed("https://readwise.io/static/cover.png"))
        #expect(allowed("https://covers.readwise.io/cover.png"))
        #expect(!allowed("http://m.media-amazon.com/images/I/x.jpg"))
        #expect(!allowed("https://notreadwise.io/x.jpg"))
        #expect(!allowed("https://readwise.io.example.com/x.jpg"))
        #expect(!allowed("https://example.com/readwise.io/x.jpg"))
        // Audible's own covers come from Amazon alone, as before.
        #expect(!AppModel.isAudibleCoverAddress(URL(string: "https://readwise.io/static/cover.png")!))
        #expect(AppModel.isAudibleCoverAddress(URL(string: "https://m.media-amazon.com/images/I/x.jpg")!))

        let h = try await withToken()
        let one = [S.readwiseHighlight(1, "One.")]
        h.audible.readwiseHolds([
            S.readwiseBook("From Amazon", asin: "B00COVER01", cover: "https://m.media-amazon.com/images/I/a.jpg", highlights: one),
            S.readwiseBook(
                "From Readwise", asin: "B00COVER02", cover: "https://readwise.io/static/b.jpg",
                highlights: [S.readwiseHighlight(2, "Two.")]),
            S.readwiseBook(
                "From Elsewhere", asin: "B00COVER03", cover: "https://example.com/c.jpg",
                highlights: [S.readwiseHighlight(3, "Three.")]),
            S.readwiseBook(
                "Not Encrypted", asin: "B00COVER04", cover: "http://m.media-amazon.com/images/I/d.jpg",
                highlights: [S.readwiseHighlight(4, "Four.")]),
            // A book the library has, with a cover of its own: none is fetched for it.
            S.readwiseBook(
                "Quiet Rivers", author: "Amara Okafor", asin: "B00COVER05",
                cover: "https://m.media-amazon.com/images/I/e.jpg", highlights: [S.readwiseHighlight(5, "Five.")]),
        ])
        let session = try await h.highlightsImportRead()
        await session.apply()
        await h.model.audibleCovers?.value
        #expect(Set(h.covers.asked.map(\.absoluteString)) == [
            "https://m.media-amazon.com/images/I/a.jpg", "https://readwise.io/static/b.jpg",
        ])
        h.model.sidebarSelection = .onKindle
        await h.model.settle()
        let covered = h.model.rows.filter { $0.coverURL != nil }.map(\.book.title)
        #expect(covered == ["From Amazon", "From Readwise"])
        #expect(h.model.rows.count == 4)
    }

    // MARK: Stopping

    @Test func HL33_closedWhileItReadsNothingIsBroughtIn() async throws {
        let h = try await withToken()
        try h.link()
        try await addAudibleBook(h, "First Listen", asin: "B0AUDIO001")
        readwiseAnswer(h)
        let gate = Gate()
        h.audible.gate = gate
        h.model.beginHighlightsImport()
        let session = try #require(h.model.highlightsImport)
        session.start()
        await gate.arrival()
        #expect(session.closeTitle == "Cancel")
        session.cancel()
        #expect(h.model.highlightsImport == nil)
        await gate.release()
        await session.reading?.value
        // What was on its way is not wanted: Audible is not asked, and nothing is shown or stored.
        #expect(marksAsked(h).isEmpty)
        #expect(session.phase == .reading && session.summary == nil)
        #expect(try h.store().highlightCounts().isEmpty)
        await session.apply()
        #expect(h.model.alert == nil)
        #expect(h.model.canImportHighlights)
    }
}
