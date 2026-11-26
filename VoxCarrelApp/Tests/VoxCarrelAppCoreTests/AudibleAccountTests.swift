import Foundation
import Security
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// AL10 onwards: linking an Audible account and bringing in its library, as the app's
/// model and its two sheets decide them. Nothing here reaches Amazon, the Keychain,
/// the clipboard or the home folder.
@MainActor
@Suite struct AudibleAccountTests {
    // MARK: Keeping the keys

    @Test func AL10_theKeysAreKeptAndGivenBackAndRemoved() throws {
        let store = InMemoryAudibleKeyStore()
        #expect(store.load() == nil)
        let account = AudibleSamples.account(.uk)
        try store.save(account)
        #expect(store.load() == account)
        try store.save(AudibleSamples.account(.de))
        #expect(store.load()?.store == .de)
        store.remove()
        #expect(store.load() == nil)
    }

    @Test func AL10_theKeychainItemIsThisDevicesOnlyAndNeverSynchronised() {
        // What the item is asked for by, without asking for it.
        let query = KeychainAudibleKeyStore.item
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "app.voxcarrel.VoxCarrel.audible")
        #expect(query[kSecAttrAccount as String] as? String == "device")
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(
            KeychainAudibleKeyStore.whenReadable as String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    @Test func AL10_keysInAFileAreReadableOnlyByTheOwnerAndComeBackAsTheyWere() throws {
        let url = try makeTempDir().appendingPathComponent("VoxCarrel/audible-account.json")
        let store = FileAudibleKeyStore(url: url)
        #expect(store.load() == nil)
        let account = AudibleAccount(
            store: .uk, serial: "S", adpToken: "{adp}", devicePrivateKey: "KEY", accessToken: "A", refreshToken: "R",
            deviceName: "Ann's 2nd Audible for iPhone")
        try store.save(account)
        #expect(store.load() == account)
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        #expect(mode.int16Value & 0o777 == 0o600)
        // Saved again, it is replaced, and private still.
        var other = account
        other.deviceName = "Another"
        try store.save(other)
        #expect(store.load() == other)
        store.remove()
        #expect(store.load() == nil && !FileManager.default.fileExists(atPath: url.path))
        // What is no account reads as none.
        try Data("not json".utf8).write(to: url)
        #expect(store.load() == nil)
        // A build made here carries no team's signature, so its keys go in a file.
        #expect(!AudibleKeyStores.isSignedByADeveloper)
    }

    @Test func AL10_aTestsModelNeverHasTheKeychainTheClipboardOrTheHomeFolder() async throws {
        let h = try await Harness.empty()
        #expect(h.model.audibleKeys is InMemoryAudibleKeyStore)
        #expect(h.relaunched().audibleKeys is InMemoryAudibleKeyStore)
        #expect(h.model.audibleTransport is FakeAudibleTransport)
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config").path
        #expect(!h.model.audibleLinkFile.path.hasPrefix(home))
        #expect(!h.model.isAudibleLinked)
        #expect(h.model.audibleAccountSummary == nil)
        // The keys are in no preference.
        try h.link()
        let stored = h.defaults.dictionaryRepresentation().description
        #expect(!stored.contains("{adp-token}") && !stored.contains(AudibleSamples.testKey))
    }

    // MARK: Linking

    @Test func AL11_theLinkSheetSaysWhatLinkingDoesAndOpensAmazonsOwnSignInPage() async throws {
        let h = try await Harness.empty()
        h.model.audibleStore = .uk
        #expect(h.model.canBeginAudibleLink)
        h.model.beginAudibleLink()
        let session = try #require(h.model.audibleLink)
        #expect(h.model.windowSheet(progressDue: false) == .audibleLink(SheetObject(session)))
        #expect(session.title == "Link Audible Account")
        #expect(session.phase == .start)
        #expect(session.problem == nil)
        // The store the lookup settings use, to begin with; any other can be chosen.
        #expect(session.store == .uk)
        #expect(Set(session.storeChoices.map(\.store)) == Set(AudibleStore.allCases))
        #expect(session.storeChoices.first { $0.store == .de }?.title == "Germany")
        let said = session.explanation.joined(separator: " ")
        #expect(said.contains("Amazon's own page"))
        #expect(said.contains("never sees your password"))
        #expect(said.contains("Audible for iPhone"))
        #expect(said.contains("kept on this Mac"))
        #expect(said.contains("Nothing is bought"))
        #expect(said.contains("not an official Amazon interface"))
        #expect(!session.offersExistingLink)
        #expect(session.openSignInTitle == "Open Amazon Sign-In")
        #expect(session.copiedTitle == "I've Copied the Address")
        #expect(!session.canReadCopiedAddress)

        session.store = .de
        session.openSignIn()
        #expect(session.phase == .waitingForAddress)
        let opened = try #require(h.opener.openedWeb.last)
        #expect(opened.host == "www.amazon.de" && opened.path == "/ap/signin" && opened.scheme == "https")
        #expect(session.steps.count == 4)
        #expect(session.steps[1].contains("looks broken"))
        #expect(session.steps[3].contains("I've Copied the Address"))
        #expect(session.canReadCopiedAddress)
        // The store is the attempt's now.
        session.store = .us
        #expect(session.store == .de)
        // Nothing has been asked of Amazon, and the clipboard has not been read.
        #expect(h.audible.asked.isEmpty && h.clipboard.readCount == 0)

        session.cancel()
        #expect(h.model.audibleLink == nil)
        #expect(!h.model.isAudibleLinked)
    }

    @Test func AL12_whatIsNotAmazonsAddressIsSaidSoAndNothingIsSent() async throws {
        let h = try await Harness.empty()
        h.model.audibleStore = .us
        h.model.beginAudibleLink()
        let session = try #require(h.model.audibleLink)
        session.openSignIn()
        let wording = "What is on the clipboard is not the address of the page Amazon sent you to. Copy it from the "
            + "browser's address bar and try again."
        for text in [nil, "", "hello", "https://example.com/?openid.oa2.authorization_code=X", AudibleSamples.landing(.uk)] {
            h.clipboard.text = text
            await session.readCopiedAddress()
            #expect(session.problem == wording)
            #expect(session.phase == .waitingForAddress)
        }
        #expect(h.audible.asked.isEmpty)
        #expect(h.audibleKeys.load() == nil)
    }

    @Test func AL13_theCopiedAddressLinksTheAccountAndTheKeysAreKept() async throws {
        let h = try await Harness.empty()
        h.model.audibleStore = .us
        h.audible.registers(as: "Ann's 2nd Audible for iPhone")
        h.model.beginAudibleLink()
        let session = try #require(h.model.audibleLink)
        session.openSignIn()
        h.clipboard.text = "  " + AudibleSamples.landing(.us, code: "ONE-TIME") + "\n"

        // While Amazon is asked, the sheet says so.
        let gate = Gate()
        h.audible.gate = gate
        let reading = Task { await session.readCopiedAddress() }
        await gate.arrival()
        #expect(session.phase == .registering)
        #expect(!session.canReadCopiedAddress && !session.canCancel)
        await gate.release()
        await reading.value

        #expect(session.phase == .done("Ann's 2nd Audible for iPhone"))
        #expect(session.problem == nil)
        #expect(session.doneText == "Linked as Ann's 2nd Audible for iPhone.")
        let sent = try #require(h.audible.asked.first)
        #expect(sent.url?.absoluteString == "https://api.amazon.com/auth/register")
        let sentBody = try #require(sent.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
        #expect((body["auth_data"] as? [String: Any])?["authorization_code"] as? String == "ONE-TIME")

        let kept = try #require(h.audibleKeys.load())
        #expect(kept.store == .us && kept.adpToken == "{adp}" && kept.refreshToken == "REFRESH")
        #expect(h.model.isAudibleLinked)
        #expect(h.model.audibleAccountSummary == "Linked as Ann's 2nd Audible for iPhone · United States")
        #expect(!h.model.canBeginAudibleLink)

        h.model.closeAudibleLink()
        #expect(h.model.audibleLink == nil)
        // The link is there the next time the app is opened.
        #expect(h.relaunched().audibleAccountSummary == "Linked as Ann's 2nd Audible for iPhone · United States")
    }

    @Test func AL14_whyAnAccountCouldNotBeLinkedIsSaidPlainly() async throws {
        let h = try await Harness.empty()
        h.model.audibleStore = .us
        h.model.beginAudibleLink()
        let session = try #require(h.model.audibleLink)
        session.openSignIn()
        h.clipboard.text = AudibleSamples.landing()

        // Amazon refuses: the code has been used, say.
        h.audible.answer("/auth/register", with: ["response": ["error": ["code": "InvalidValue"]]], status: 400)
        await session.readCopiedAddress()
        #expect(session.problem == "Amazon did not register the device. Start again from Open Amazon Sign-In.")
        #expect(session.phase == .start)
        #expect(!h.model.isAudibleLinked)

        // No network.
        session.openSignIn()
        #expect(session.problem == nil)
        h.audible.fails = true
        await session.readCopiedAddress()
        #expect(session.problem == "Amazon could not be reached. Check your internet connection.")
        #expect(session.phase == .waitingForAddress)

        #expect(UserMessage.audibleLinkProblem(AudibleAccountError.unreadable) == "The account could not be linked.")
        #expect(UserMessage.audibleLinkProblem(CocoaError(.fileNoSuchFile)) == "The account could not be linked.")
        #expect(h.audibleKeys.load() == nil)
    }

    @Test func AL15_aLinkMadeEarlierOnThisMacCanBeUsed() async throws {
        let h = try await Harness.empty()
        let file: [String: Any] = [
            "country": "uk", "serial": "S1", "adp_token": "{adp-file}", "device_private_key": AudibleSamples.testKey,
            "access_token": "A", "refresh_token": "R", "device_name": "Ann's Audible for iPhone",
        ]
        let written = try JSONSerialization.data(withJSONObject: file)
        try written.write(to: h.audibleLinkFile)

        h.model.beginAudibleLink()
        let session = try #require(h.model.audibleLink)
        #expect(session.offersExistingLink)
        #expect(session.existingLinkTitle == "Use the link already on this Mac")
        session.useExistingLink()
        #expect(session.phase == .done("Ann's Audible for iPhone"))
        #expect(h.audibleKeys.load() == AudibleAccount(
            store: .uk, serial: "S1", adpToken: "{adp-file}", devicePrivateKey: AudibleSamples.testKey,
            accessToken: "A", refreshToken: "R", deviceName: "Ann's Audible for iPhone"))
        #expect(h.model.audibleAccountSummary == "Linked as Ann's Audible for iPhone · United Kingdom")
        // The file is left as it is, and nothing was asked of Amazon.
        #expect(try Data(contentsOf: h.audibleLinkFile) == written)
        #expect(h.audible.asked.isEmpty)

        // A file that is not such a link is not offered.
        let other = try await Harness.empty()
        try Data("{\"country\": \"uk\"}".utf8).write(to: other.audibleLinkFile)
        other.model.beginAudibleLink()
        #expect(other.model.audibleLink?.offersExistingLink == false)
        other.model.audibleLink?.useExistingLink()
        #expect(!other.model.isAudibleLinked)
    }

    // MARK: Unlinking

    @Test func AL16_unlinkingAsksFirstThenHasAmazonRemoveTheDeviceAndForgetsTheKeys() async throws {
        let h = try await Harness.empty()
        try h.link()
        h.audible.answer("/auth/deregister", with: ["response": ["success": [:] as [String: Any]]])
        #expect(h.model.canUnlinkAudible)
        h.model.unlinkAudible()
        let question = try #require(h.model.prompt)
        #expect(question == .unlinkAudible(deviceName: "Ann's 2nd Audible for iPhone"))
        #expect(question.title == "Unlink your Audible account?")
        #expect(question.message.contains("Ann's 2nd Audible for iPhone"))
        #expect(question.message.contains("stay in your library"))
        #expect(question.unlinkAudibleTitle == "Unlink")
        // Nothing yet.
        #expect(h.model.isAudibleLinked && h.audible.asked.isEmpty)

        // Cancel.
        h.model.prompt = nil
        await h.model.confirmUnlinkAudible()
        #expect(h.model.isAudibleLinked && h.audible.asked.isEmpty)

        h.model.unlinkAudible()
        await h.model.confirmUnlinkAudible()
        #expect(h.model.prompt == nil)
        let sent = try #require(h.audible.asked.first)
        #expect(sent.url?.absoluteString == "https://api.amazon.com/auth/deregister")
        #expect(!h.model.isAudibleLinked)
        #expect(h.model.audibleAccountSummary == nil)
        #expect(h.audibleKeys.load() == nil)
        #expect(h.model.alert == nil)
        #expect(h.model.busyLabel == nil)
        #expect(!h.model.canUnlinkAudible)
    }

    @Test func AL16_theKeysAreForgottenWhateverAmazonAnswers() async throws {
        let wording = "The link was removed from this Mac. Amazon did not confirm removing the device: remove it in "
            + "your Amazon account under Content & Devices."
        // Refused: the keys have run out.
        let refused = try await Harness.empty()
        try refused.link()
        refused.audible.answer("/auth/deregister", with: [:] as [String: Any], status: 401)
        refused.model.unlinkAudible()
        await refused.model.confirmUnlinkAudible()
        #expect(!refused.model.isAudibleLinked && refused.audibleKeys.load() == nil)
        #expect(refused.model.alert == wording)

        // No network.
        let offline = try await Harness.empty()
        try offline.link()
        offline.audible.fails = true
        offline.model.unlinkAudible()
        await offline.model.confirmUnlinkAudible()
        #expect(!offline.model.isAudibleLinked && offline.audibleKeys.load() == nil)
        #expect(offline.model.alert == wording)
    }

    // MARK: Importing the library

    @Test func AL17_theImportSheetReadsTheLibraryAndSaysWhatBringingItInWouldDo() async throws {
        let h = try await Harness.demo()
        try h.link()
        // Marked already.
        var rivers = AudibleOwnedBook(asin: "B0RIVERS", title: "Quiet Rivers")
        rivers.authors = ["Amara Okafor"]
        _ = try LibraryService(store: try h.store()).bringInAudibleLibrary([rivers], store: .us, apply: true)
        await h.model.reloadAll()
        h.audible.holds([
            AudibleSamples.item("B0NEW1", "A New Book", finished: true, percent: 100),
            AudibleSamples.item("B0NEW2", "Another New Book", percent: 40),
            AudibleSamples.item("B0NEW3", "A Third New Book"),
            AudibleSamples.item("B0LIGHT", "The Lighthouse Keeper", author: "Eleanor Marsh"),
            AudibleSamples.item("B0TRAIN", "Night Train to Vostok", author: "Mikhail Orlov", finished: true),
            AudibleSamples.item("B0RIVERS", "Quiet Rivers", author: "Amara Okafor"),
        ])
        let before = try h.store().books().count
        #expect(h.model.canImportAudibleLibrary)

        // While Audible is asked, the sheet says so, and the library is not kept waiting.
        let gate = Gate()
        h.audible.gate = gate
        h.model.beginAudibleImport()
        let session = try #require(h.model.audibleImport)
        #expect(h.model.windowSheet(progressDue: false) == .audibleImport(SheetObject(session)))
        await gate.arrival()
        #expect(session.title == "Import Audible Library")
        #expect(session.phase == .reading)
        #expect(session.readingText == "Reading your Audible library…")
        #expect(!session.canImport)
        #expect(h.model.busyLabel == nil)
        await gate.release()
        await session.reading?.value

        #expect(session.phase == .review)
        #expect(session.problem == nil)
        #expect(session.summary == "6 books in your Audible library.")
        #expect(session.lines == [
            "3 will be added as books you own on Audible.",
            "2 books you already have will be marked as on Audible.",
            "1 is already marked.",
            "3 will have their reading status set from Audible (finished, or being read).",
        ])
        #expect(session.titlesToAdd == ["A New Book", "Another New Book", "A Third New Book"])
        #expect(session.titlesToMark == ["The Lighthouse Keeper", "Night Train to Vostok"])
        #expect(session.note == "No file is added or changed. Books that are added have no files; if you import "
            + "their files later, they join these entries.")
        #expect(session.canImport)
        #expect(session.importTitle == "Import")
        // The requests were signed with the device's key, to the account's store.
        #expect(h.audible.asked.allSatisfy { $0.url?.host == "api.audible.com" })
        #expect(h.audible.asked.allSatisfy { $0.value(forHTTPHeaderField: "x-adp-signature") != nil })
        // Nothing has changed.
        #expect(try h.store().books().count == before)

        session.cancel()
        #expect(h.model.audibleImport == nil)
        #expect(try h.store().books().count == before)
    }

    @Test func AL17_oneOfEachIsSaidAsOne() {
        var report = AudibleLibraryReport()
        report.added = ["One"]
        report.marked = ["Two"]
        report.alreadyThere = 7
        report.statusChanged = 1
        #expect(AudibleImportText.summary(total: 1, report: report) == "1 book in your Audible library.")
        #expect(AudibleImportText.lines(for: report) == [
            "1 will be added as a book you own on Audible.",
            "1 book you already have will be marked as on Audible.",
            "7 are already marked.",
            "1 will have its reading status set from Audible (finished, or being read).",
        ])
        #expect(AudibleImportText.outcome(of: report) == "Added 1 book and marked 1 as on Audible.")

        report.added = (1...190).map { "Book \($0)" }
        report.marked = (1...20).map { "Had \($0)" }
        report.statusChanged = 158
        #expect(AudibleImportText.summary(total: 217, report: report) == "217 books in your Audible library.")
        #expect(AudibleImportText.lines(for: report) == [
            "190 will be added as books you own on Audible.",
            "20 books you already have will be marked as on Audible.",
            "7 are already marked.",
            "158 will have their reading status set from Audible (finished, or being read).",
        ])
        #expect(AudibleImportText.outcome(of: report) == "Added 190 books and marked 20 as on Audible.")
        report.marked = []
        #expect(AudibleImportText.outcome(of: report) == "Added 190 books.")
        report.added = []
        report.marked = ["Two", "Three"]
        #expect(AudibleImportText.outcome(of: report) == "Marked 2 books as on Audible.")
        report.marked = ["Two"]
        #expect(AudibleImportText.outcome(of: report) == "Marked 1 book as on Audible.")
        report.marked = []
        #expect(AudibleImportText.outcome(of: report) == "Set the reading status of 158 books from Audible.")
        report.statusChanged = 0
        #expect(AudibleImportText.outcome(of: report) == "Everything is already in your library.")
    }

    @Test func AL17_aLongListOfTitlesIsCutShort() async throws {
        var report = AudibleLibraryReport()
        report.added = (1...620).map { "Book \($0)" }
        #expect(AudibleImportText.shown(report.added).count == 500)
        #expect(AudibleImportText.more(report.added) == "and 120 more")
        #expect(AudibleImportText.more(Array(report.added.prefix(500))) == nil)
    }

    @Test func AL18_whenEverythingIsThereAlreadyThereIsNothingToImport() async throws {
        let h = try await Harness.empty()
        try h.link()
        h.audible.holds([AudibleSamples.item("B0ONE", "One Book"), AudibleSamples.item("B0TWO", "Two Book")])
        let first = try await h.audibleImportRead()
        await first.apply()
        await h.model.audibleCovers?.value
        h.model.alert = nil

        let session = try await h.audibleImportRead()
        #expect(session.phase == .review)
        #expect(session.summary == "2 books in your Audible library. Everything is already in your library.")
        #expect(session.lines == ["2 are already marked."])
        #expect(session.titlesToAdd.isEmpty && session.titlesToMark.isEmpty)
        #expect(!session.canImport)
        await session.apply()
        #expect(h.model.audibleImport === session)
        #expect(h.model.alert == nil)

        // An account with no books.
        session.cancel()
        h.audible.holds([])
        let none = try await h.audibleImportRead()
        #expect(none.summary == "Your Audible library has no books.")
        #expect(none.lines.isEmpty && !none.canImport)
    }

    @Test func AL19_importingAddsTheBooksMarksTheOnesHeldAndSaysWhatItDid() async throws {
        let h = try await Harness.demo()
        try h.link(AudibleSamples.account(.uk))
        h.audible.holds([
            AudibleSamples.item("B0NEW1", "A New Book", finished: true, percent: 100),
            AudibleSamples.item("B0NEW2", "Another New Book", percent: 40),
            AudibleSamples.item("B0LIGHT", "The Lighthouse Keeper", author: "Eleanor Marsh"),
        ])
        let before = try h.store().books().count
        let session = try await h.audibleImportRead()
        h.recordBusyLabels()
        await session.apply()

        #expect(h.busyLabels == ["Importing your Audible library…"])
        #expect(h.model.audibleImport == nil)
        #expect(h.model.busyLabel == nil)
        #expect(h.model.alert == "Added 2 books and marked 1 as on Audible.")
        #expect(h.model.result == nil)

        let books = try h.store().books()
        #expect(books.count == before + 2)
        let new = try #require(books.first { $0.title == "A New Book" })
        #expect(new.readStatus == .finished && new.asin == "B0NEW1" && new.folderPath == nil)
        #expect(new.externalCopies == [ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: "B0NEW1")])
        #expect(books.first { $0.title == "Another New Book" }?.readStatus == .inProgress)
        let held = try h.book(try h.id("The Lighthouse Keeper"))
        #expect(held.externalCopies.map(\.itemId) == ["B0LIGHT"])
        #expect(try !h.fileURLs(try #require(held.id)).isEmpty)
        // The rows were read again.
        #expect(h.titles.contains("A New Book"))
        await h.model.audibleCovers?.value
    }

    @Test func AL20_whyTheLibraryCouldNotBeReadIsSaidInTheSheet() async throws {
        let h = try await Harness.empty()
        try h.link()

        h.audible.answer("/1.0/library", with: [:] as [String: Any], status: 403)
        let refused = try await h.audibleImportRead()
        #expect(refused.problem == "Audible no longer accepts this link. Unlink the account in Settings and link it again.")
        #expect(refused.phase == .failed)
        #expect(!refused.canImport && refused.summary == nil)
        refused.cancel()
        #expect(h.model.audibleImport == nil)

        h.audible.fails = true
        let offline = try await h.audibleImportRead()
        #expect(offline.problem == "Audible could not be reached. Check your internet connection.")
        #expect(offline.phase == .failed)
        offline.cancel()

        h.audible.fails = false
        h.audible.answer("/1.0/library", with: ["nothing": "useful"])
        let unreadable = try await h.audibleImportRead()
        #expect(unreadable.problem == "Audible answered in a way VoxCarrel does not understand. Nothing was changed. "
            + "If this goes on, look for a newer version of VoxCarrel.")
        #expect(unreadable.phase == .failed)
        unreadable.cancel()

        #expect(UserMessage.audibleLibraryProblem(AudibleAccountError.unusableKey) == "Your Audible library could not be read.")
        #expect(try h.store().books().isEmpty)
    }

    // MARK: Covers

    @Test func AL21_coversComeOnlyFromAmazonsImageHostsAndOnlyForBooksWithoutOne() async throws {
        let h = try await Harness.empty()
        try h.link()
        let good = "https://m.media-amazon.com/images/I/good._SL500_.jpg"
        let alsoGood = "https://images-na.ssl-images-amazon.com/images/I/also.jpg"
        let big = "https://m.media-amazon.com/images/I/big.jpg"
        let notAPicture = "https://m.media-amazon.com/images/I/text.jpg"
        h.audible.holds([
            AudibleSamples.item("B0GOOD", "Good Cover", cover: good),
            AudibleSamples.item("B0ALSO", "Also Good", cover: alsoGood),
            AudibleSamples.item("B0ELSE", "Elsewhere", cover: "https://example.com/images/I/x.jpg"),
            AudibleSamples.item("B0LOOK", "Lookalike", cover: "https://notmedia-amazon.com/x.jpg"),
            AudibleSamples.item("B0TAIL", "Tail", cover: "https://m.media-amazon.com.example.com/x.jpg"),
            AudibleSamples.item("B0BIG", "Too Big", cover: big),
            AudibleSamples.item("B0TEXT", "Not a Picture", cover: notAPicture),
            AudibleSamples.item("B0NONE", "No Cover", cover: nil),
        ])
        h.covers.give(AudibleSamples.jpeg + Data(count: 5_000_001), for: big)
        h.covers.give(Data("<html>".utf8), for: notAPicture)
        let session = try await h.audibleImportRead()
        await session.apply()
        // The owner is not kept waiting for the covers.
        #expect(h.model.busyLabel == nil)
        await h.model.audibleCovers?.value

        #expect(Set(h.covers.asked.map(\.absoluteString)) == [good, alsoGood, big, notAPicture])
        let covers = CoverStore(layout: LibraryLayout(root: h.root))
        #expect(covers.url(for: try h.id("Good Cover")) != nil)
        #expect(covers.url(for: try h.id("Also Good")) != nil)
        for title in ["Elsewhere", "Lookalike", "Tail", "Too Big", "Not a Picture", "No Cover"] {
            #expect(covers.url(for: try h.id(title)) == nil, "\(title) was given a cover")
        }
        // The rows show them.
        #expect(h.model.rows.first { $0.book.title == "Good Cover" }?.coverURL != nil)

        // A book that has a cover is not asked for again.
        let wanted = try await #require(h.model.worker).audibleBooksWithoutCover()
        #expect(!wanted.map(\.asin).contains("B0GOOD"))
        let again = try await h.audibleImportRead()
        #expect(!again.canImport)
        again.cancel()
    }

    @Test func AL21_onlyAddressesOfAmazonsImageHostsAreCoverAddresses() throws {
        func allowed(_ address: String) throws -> Bool {
            AppModel.isAudibleCoverAddress(try #require(URL(string: address)))
        }
        #expect(try allowed("https://m.media-amazon.com/images/I/x.jpg"))
        #expect(try allowed("https://media-amazon.com/x.jpg"))
        #expect(try allowed("https://images-eu.ssl-images-amazon.com/x.jpg"))
        #expect(try !allowed("http://m.media-amazon.com/images/I/x.jpg"))
        #expect(try !allowed("https://evilmedia-amazon.com/x.jpg"))
        #expect(try !allowed("https://m.media-amazon.com.evil.example/x.jpg"))
        #expect(try !allowed("https://www.amazon.com/x.jpg"))
        #expect(try !allowed("file:///m.media-amazon.com/x.jpg"))
    }

    @Test func AL21_theCoversStopWhenAnotherLibraryIsOpened() async throws {
        let h = try await Harness.empty()
        try h.link()
        h.audible.holds([AudibleSamples.item("B0ONE", "One Book"), AudibleSamples.item("B0TWO", "Two Book")])
        let session = try await h.audibleImportRead()
        let gate = Gate()
        let covers = h.covers
        h.model.audibleCoverFetch = { url in
            await gate.wait()
            return await covers.fetch(url)
        }
        await session.apply()
        await gate.arrival()
        let fetching = try #require(h.model.audibleCovers)
        await h.model.chooseLibrary(try makeTempDir())
        await gate.release()
        await fetching.value
        // The one that was on its way, and no more; nothing was stored.
        #expect(h.covers.asked.count == 1)
        let store = CoverStore(layout: LibraryLayout(root: h.root))
        #expect(store.url(for: try h.id("One Book")) == nil)
        #expect(store.url(for: try h.id("Two Book")) == nil)
    }

    // MARK: When it can be done

    @Test func AL22_theLibraryCanBeImportedOnlyWhenLinkedWithALibraryOpenAndNothingElseUp() async throws {
        let h = try await Harness.demo()
        // Not linked: the menu leads to linking.
        #expect(!h.model.canImportAudibleLibrary)
        #expect(h.model.audibleMenuTitle == "Link Audible Account…")
        #expect(h.model.canUseAudibleMenu)
        h.model.beginAudibleImport()
        #expect(h.model.audibleImport == nil)
        h.model.audibleMenuCommand()
        let link = try #require(h.model.audibleLink)
        // One sheet at a time.
        #expect(!h.model.canBeginAudibleLink && !h.model.canUseAudibleMenu)
        #expect(!h.model.canBeginShelf && !h.model.canManageGenres)
        h.model.beginAudibleLink()
        #expect(h.model.audibleLink === link)
        link.cancel()

        try h.link()
        h.audible.holds([AudibleSamples.item("B0ONE", "One Book")])
        #expect(h.model.audibleMenuTitle == "Import Audible Library…")
        #expect(h.model.canImportAudibleLibrary && h.model.canUseAudibleMenu)
        // Linked already: there is nothing to link.
        #expect(!h.model.canBeginAudibleLink)
        h.model.beginAudibleLink()
        #expect(h.model.audibleLink == nil)

        // Another sheet is up.
        h.model.beginNewShelf()
        #expect(!h.model.canImportAudibleLibrary && !h.model.canUseAudibleMenu)
        h.model.beginAudibleImport()
        #expect(h.model.audibleImport == nil)
        h.model.closeShelfEditor()

        // A question is waiting.
        h.model.unlinkAudible()
        #expect(!h.model.canImportAudibleLibrary)
        h.model.prompt = nil

        h.model.audibleMenuCommand()
        let session = try #require(h.model.audibleImport)
        await session.reading?.value
        #expect(!h.model.canImportAudibleLibrary && !h.model.canBeginShelf && !h.model.canUnlinkAudible)
        #expect(!h.model.canManageGenres && !h.model.canFillInGenres)
        h.model.beginAudibleImport()
        #expect(h.model.audibleImport === session)
        session.cancel()
        #expect(h.model.canImportAudibleLibrary)
    }

    @Test func AL22_withNoLibraryOpenAnAccountCanBeLinkedButNothingImported() async throws {
        let h = try Harness(root: try makeTempDir(), choose: false)
        await h.model.start()
        #expect(!h.model.isLibraryOpen)
        #expect(h.model.canBeginAudibleLink)
        try h.link()
        #expect(!h.model.canImportAudibleLibrary)
        #expect(h.model.audibleMenuTitle == "Import Audible Library…" && !h.model.canUseAudibleMenu)
        h.model.beginAudibleImport()
        #expect(h.model.audibleImport == nil)
    }

    @Test func AL22_theImportSheetGoesWhenAnotherLibraryIsOpened() async throws {
        let h = try await Harness.empty()
        try h.link()
        h.audible.holds([AudibleSamples.item("B0ONE", "One Book")])
        _ = try await h.audibleImportRead()
        await h.model.chooseLibrary(try makeTempDir())
        #expect(h.model.audibleImport == nil)
        // The link is the Mac's, not the library's.
        #expect(h.model.isAudibleLinked)
    }
}
