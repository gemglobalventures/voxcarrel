import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// KD1 onwards: Send to Kindle, as the app's model decides it. Nothing is opened: what
/// stands in for Amazon's app and for the mail program is the harness's own, which only
/// records what it was handed. Every copy is made in the harness's own temporary folder.
@MainActor
@Suite struct SendToKindleTests {
    static let address = "reader@example.com"

    /// A started model on a library of this test's own: "Dune: Messiah" (an EPUB and a
    /// PDF), "Paper Only" (a PDF), "Old Format" (a MOBI), "Spoken" (an audiobook),
    /// "Quiet Book" (an EPUB) and "Elsewhere", which is owned on Kindle and has no
    /// files here.
    private func library() async throws -> Harness {
        let root = try makeTempDir()
        let inbox = try makeTempDir()
        let store = try LibraryStore(libraryRoot: root)
        try store.setKnowsFilesAgain(false)
        let service = LibraryService(store: store)

        func add(_ title: String, _ files: [(url: URL, role: FileRole)]) throws {
            let candidate = CandidateBook(
                files: files.map { CandidateFile(url: $0.url, role: $0.role) },
                metadata: BookMetadata(title: title, authors: ["Ann Author"]))
            let result = try service.importItems([ImportItem(candidate: candidate)], options: ImportOptions())
            guard case .imported = try #require(result.outcomes.first) else {
                Issue.record("\(title) was not imported")
                return
            }
        }
        func pdf(_ name: String) -> URL {
            let url = inbox.appendingPathComponent(name)
            MediaFixtures.makePDF(at: url)
            return url
        }
        try add("Dune: Messiah", [(pdf("dune.pdf"), .ebook), (try MediaFixtures.makeEPUB3(in: inbox, name: "dune.epub"), .ebook)])
        try add("Paper Only", [(pdf("paper.pdf"), .ebook)])
        let mobi = inbox.appendingPathComponent("old.mobi")
        try Data("the words of an old format".utf8).write(to: mobi)
        try add("Old Format", [(mobi, .ebook)])
        let mp3 = inbox.appendingPathComponent("spoken.mp3")
        try MediaFixtures.makeSilentMP3(seconds: 1).write(to: mp3)
        try add("Spoken", [(mp3, .audio)])
        try add("Quiet Book", [(try MediaFixtures.makeEPUB3(in: inbox, name: "quiet.epub"), .ebook)])
        _ = try service.addExternalBook(
            metadata: BookMetadata(title: "Elsewhere", authors: ["Ann Author"]), cover: nil,
            copy: ExternalCopy(kind: .kindle, form: .ebook, itemId: "B00KINDLE2"))

        let h = try Harness(root: root)
        await h.model.start()
        return h
    }

    /// The book's file of this kind in the library.
    private func file(_ h: Harness, _ id: Int64, _ kind: String) throws -> URL {
        try #require(try h.fileURLs(id).first { $0.pathExtension == kind })
    }

    /// Every path under the library folder, with what each file holds.
    private func libraryContents(_ h: Harness) -> [String: Data] {
        var found: [String: Data] = [:]
        for path in (FileManager.default.enumerator(atPath: h.root.path)?.allObjects as? [String]) ?? [] {
            // The catalogue's own files are written as it is read.
            guard !path.contains(".voxcarrel"), !path.hasSuffix(".sqlite"), !path.contains(".sqlite-") else { continue }
            if let data = try? Data(contentsOf: h.root.appendingPathComponent(path), options: []) { found[path] = data }
        }
        return found
    }

    /// The folder every copy is made in.
    private func stagingFolder(_ h: Harness) -> URL {
        h.sendTemp.appendingPathComponent(LibraryService.kindleStagingFolderName, isDirectory: true)
    }

    /// Whether `url` is in a folder of its own in the harness's folder of copies.
    private func isStaged(_ url: URL, in h: Harness) -> Bool {
        url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
            == stagingFolder(h).standardizedFileURL.path
    }

    // MARK: When the command applies

    @Test func KD1_theCommandIsForOneBookWithAnEbookOnThisMac() async throws {
        let h = try await library()
        #expect(KindleText.commandTitle == "Send to Kindle…")
        // Nothing chosen.
        #expect(!h.model.canSendToKindle([]))
        let expected = [
            "Dune: Messiah": true, "Paper Only": true, "Quiet Book": true,
            // The engine says what to do about a format a Kindle does not take.
            "Old Format": true,
            "Spoken": false, "Elsewhere": false,
        ]
        for (title, applies) in expected {
            #expect(h.model.canSendToKindle([try h.id(title)]) == applies, "\(title)")
        }
        // Two books are not sent at once.
        #expect(!h.model.canSendToKindle(try h.ids(["Dune: Messiah", "Quiet Book"])))
        // Nor a book that is not shown, or a row that stands for no book.
        #expect(!h.model.canSendToKindle([9_999]) && !h.model.canSendToKindle([-1]))
        // Not while something else runs.
        let id = try h.id("Quiet Book")
        h.model.busyLabel = "Working…"
        #expect(!h.model.canSendToKindle([id]))
        await h.model.sendToKindle(for: [id])
        h.model.busyLabel = nil
        #expect(h.model.canSendToKindle([id]))
        // Deciding it handed nothing over, and made nothing.
        #expect(h.kindleSender.toApp.isEmpty && h.kindleSender.emails.isEmpty && h.model.alert == nil)
        #expect(!exists(stagingFolder(h)))
    }

    @Test func KD2_aBookThatCannotBeSentIsNotSentWhateverIsAsked() async throws {
        let h = try await library()
        h.kindleSender.isAppInstalled = true
        await h.model.sendToKindle(for: [try h.id("Spoken")])
        await h.model.sendToKindle(for: [try h.id("Elsewhere")])
        await h.model.sendToKindle(for: try h.ids(["Dune: Messiah", "Quiet Book"]))
        #expect(h.kindleSender.toApp.isEmpty && h.model.alert == nil && !exists(stagingFolder(h)))
    }

    // MARK: Amazon's app

    @Test func KD3_withAmazonsAppACopyNamedByTheTitleIsHandedToItAndNothingIsSaid() async throws {
        let h = try await library()
        h.kindleSender.isAppInstalled = true
        // An address is not used while the app is there.
        h.model.kindleAddress = Self.address
        let id = try await h.select("Dune: Messiah")
        let epub = try file(h, id, "epub")
        let bytes = try Data(contentsOf: epub)
        let before = libraryContents(h)
        h.recordBusyLabels()

        await h.model.sendToKindle()

        #expect(h.model.alert == nil && h.model.busyLabel == nil)
        #expect(h.kindleSender.emails.isEmpty && h.kindleSender.toApp.count == 1)
        let handed = try #require(h.kindleSender.toApp.first)
        // The EPUB, not the PDF, under the book's title made safe for a file name.
        #expect(handed.file.lastPathComponent == "Dune- Messiah.epub" && handed.bytes == bytes)
        // A copy in the temporary folder: never the library's own file.
        #expect(isStaged(handed.file, in: h) && !handed.file.path.hasPrefix(h.root.path))
        #expect(libraryContents(h) == before && before.count >= 6)
        #expect(h.model.selection == [id])
    }

    @Test func KD4_aSecondSendRemovesTheCopyOfTheFirst() async throws {
        let h = try await library()
        h.kindleSender.isAppInstalled = true
        await h.model.sendToKindle(for: [try h.id("Quiet Book")])
        let paper = try h.id("Paper Only")
        await h.model.sendToKindle(for: [paper])

        #expect(h.kindleSender.toApp.map(\.file.lastPathComponent) == ["Quiet Book.epub", "Paper Only.pdf"])
        #expect(h.kindleSender.toApp[1].bytes == (try Data(contentsOf: try file(h, paper, "pdf"))))
        #expect(!exists(h.kindleSender.toApp[0].file) && exists(h.kindleSender.toApp[1].file))
        #expect(try FileManager.default.contentsOfDirectory(atPath: stagingFolder(h).path).count == 1)
    }

    @Test func KD5_anAppThatWillNotOpenIsSaid() async throws {
        let h = try await library()
        h.kindleSender.isAppInstalled = true
        h.kindleSender.appOpens = false
        await h.model.sendToKindle(for: [try h.id("Quiet Book")])
        #expect(h.kindleSender.toApp.count == 1)
        #expect(h.model.alert == "Amazon's Send to Kindle app could not be opened.")
    }

    // MARK: Email

    @Test func KD6_withoutTheAppAMessageToTheKindlesAddressIsWrittenWithTheCopyAttached() async throws {
        let h = try await library()
        h.model.kindleAddress = "  \(Self.address) "
        let id = try h.id("Dune: Messiah")
        let bytes = try Data(contentsOf: try file(h, id, "epub"))
        let before = libraryContents(h)

        await h.model.sendToKindle(for: [id])

        #expect(h.model.alert == nil && h.kindleSender.toApp.isEmpty && h.kindleSender.emails.count == 1)
        let message = try #require(h.kindleSender.emails.first)
        // The subject is the title as it is; the file's name is the title made safe.
        #expect(message.address == Self.address && message.subject == "Dune: Messiah")
        #expect(message.file.lastPathComponent == "Dune- Messiah.epub" && message.bytes == bytes)
        #expect(isStaged(message.file, in: h) && libraryContents(h) == before)
    }

    @Test func KD7_withNoMailProgramItIsSaid() async throws {
        let h = try await library()
        h.model.kindleAddress = Self.address
        h.kindleSender.mailWorks = false
        await h.model.sendToKindle(for: [try h.id("Quiet Book")])
        #expect(h.kindleSender.emails.count == 1)
        #expect(h.model.alert
            == "No mail program could be opened to send the book. Install Amazon's Send to Kindle app, or set up Mail.")
    }

    @Test func KD8_withNeitherTheAppNorAnAddressItSaysWhatToDo() async throws {
        let h = try await library()
        await h.model.sendToKindle(for: [try h.id("Quiet Book")])
        #expect(h.model.alert
            == "To send to Kindle, install Amazon's Send to Kindle app, or enter your Kindle's email address in "
            + "Settings > General.")
        #expect(h.kindleSender.toApp.isEmpty && h.kindleSender.emails.isEmpty && !exists(stagingFolder(h)))
    }

    // MARK: What is not sent

    @Test func KD9_aBookWhoseEbookHasGoneFromTheDiskHasNothingToSend() async throws {
        let h = try await library()
        h.kindleSender.isAppInstalled = true
        let id = try h.id("Quiet Book")
        // The row still lists the EPUB: the command is on, and the library is asked.
        try FileManager.default.removeItem(at: try file(h, id, "epub"))
        #expect(h.model.canSendToKindle([id]))
        await h.model.sendToKindle(for: [id])
        #expect(h.model.alert == "This book has no ebook on this Mac to send.")
        #expect(h.kindleSender.toApp.isEmpty && !exists(stagingFolder(h)))
    }

    @Test func KD10_aFormatAKindleDoesNotTakeIsToBeConvertedFirst() async throws {
        let h = try await library()
        h.kindleSender.isAppInstalled = true
        await h.model.sendToKindle(for: [try h.id("Old Format")])
        #expect(h.model.alert
            == "Kindle takes EPUB and PDF. Convert this book to EPUB first (Book > Convert to EPUB), then send it.")
        #expect(h.kindleSender.toApp.isEmpty && !exists(stagingFolder(h)) && h.converter.asked.isEmpty)
    }

    @Test func KD11_aFileOverAmazonsLimitIsNotSentByEitherRoute() async throws {
        // The limits are the model's to be told: these are a few bytes, so that no
        // large file has to be made. The sentences name Amazon's own limits.
        #expect(KindleLimits.amazons == KindleLimits(any: 200_000_000, byEmail: 50_000_000))
        let h = try await library()
        let id = try h.id("Quiet Book")
        let epub = try file(h, id, "epub")
        let size = Int64(try Data(contentsOf: epub).count)
        let said = SendText.size(size)

        // Over the limit for any route: said whether the app is there or not.
        h.model.kindleLimits = KindleLimits(any: size - 1, byEmail: size - 1)
        for installed in [true, false] {
            h.kindleSender.isAppInstalled = installed
            h.model.alert = nil
            await h.model.sendToKindle(for: [id])
            #expect(h.model.alert == "“Quiet Book.epub” is \(said), which is more than Amazon accepts (200 MB).")
        }

        // Over the limit for a message only: the app takes it, a message does not.
        h.model.kindleLimits = KindleLimits(any: size, byEmail: size - 1)
        h.model.kindleAddress = Self.address
        h.kindleSender.isAppInstalled = false
        h.model.alert = nil
        await h.model.sendToKindle(for: [id])
        #expect(h.model.alert
            == "“Quiet Book.epub” is \(said), which is more than Amazon accepts by email (50 MB). "
            + "Install Amazon's Send to Kindle app to send it.")
        #expect(h.kindleSender.toApp.isEmpty && h.kindleSender.emails.isEmpty && !exists(stagingFolder(h)))

        h.kindleSender.isAppInstalled = true
        h.model.alert = nil
        await h.model.sendToKindle(for: [id])
        #expect(h.model.alert == nil && h.kindleSender.toApp.count == 1)

        // A file of exactly the limit goes by a message too.
        h.model.kindleLimits = KindleLimits(any: size, byEmail: size)
        h.kindleSender.isAppInstalled = false
        await h.model.sendToKindle(for: [id])
        #expect(h.model.alert == nil && h.kindleSender.emails.count == 1)
    }

    @Test func KD12_aCopyThatCannotBeMadeIsSaidAndNothingIsHandedOver() async throws {
        let h = try await library()
        h.kindleSender.isAppInstalled = true
        // Something that is not a folder is where the folder of copies goes.
        try touch(stagingFolder(h))
        await h.model.sendToKindle(for: [try h.id("Quiet Book")])
        #expect(h.model.alert == "A copy of the book could not be made to send." && h.model.busyLabel == nil)
        #expect(h.kindleSender.toApp.isEmpty)
    }

    // MARK: A hidden book

    @Test func KD13_aHiddenBookShownInTheHiddenListCanBeSent() async throws {
        let h = try await library()
        h.kindleSender.isAppInstalled = true
        let id = try await h.select("Quiet Book")
        await h.model.toggleHidden(for: [id])
        await h.model.settle()
        h.model.alert = nil
        // Out of sight, it is not offered.
        #expect(!h.model.canSendToKindle([id]))

        await h.model.showHiddenBooks()
        #expect(h.model.sidebarSelection == .hidden && h.titles == ["Quiet Book"])
        #expect(h.model.canSendToKindle([id]))
        await h.model.sendToKindle(for: [id])

        #expect(h.model.alert == nil)
        #expect(h.kindleSender.toApp.map(\.file.lastPathComponent) == ["Quiet Book.epub"])
        h.model.sidebarSelection = .allBooks
    }

    // MARK: The address

    @Test func KD14_theAddressIsKeptTrimmedWhenItCouldBeOneAndNotOtherwise() async throws {
        let h = try await library()
        #expect(KindleText.addressTitle == "Kindle email address")
        #expect(KindleText.addressHelp
            == "Used only when Amazon's Send to Kindle app is not installed. Find the address in your Amazon "
            + "account under Devices, and add the address you send from to its approved list.")
        #expect(h.model.kindleAddress == "" && h.model.kindleAddressProblem == nil)
        #expect(h.defaults.string(forKey: "kindleAddress") == nil)

        // Not yet an address: said, and not kept.
        for typed in ["reader", "reader example.com", "re ader@example.com", "reader@example. com"] {
            h.model.kindleAddress = typed
            #expect(h.model.kindleAddress == typed, "\(typed)")
            #expect(h.model.kindleAddressProblem == "That does not look like an email address.", "\(typed)")
            #expect(h.defaults.string(forKey: "kindleAddress") == nil, "\(typed)")
        }

        // An address, with space around it: kept without the space.
        h.model.kindleAddress = "  \(Self.address)\t"
        #expect(h.model.kindleAddressProblem == nil)
        #expect(h.defaults.string(forKey: "kindleAddress") == Self.address)
        #expect(h.relaunched().kindleAddress == Self.address)

        // Spoiled, the one kept before stays, and the next launch shows that one.
        h.model.kindleAddress = "reader@example com"
        #expect(h.model.kindleAddressProblem == "That does not look like an email address.")
        #expect(h.defaults.string(forKey: "kindleAddress") == Self.address)
        let again = h.relaunched()
        #expect(again.kindleAddress == Self.address && again.kindleAddressProblem == nil)

        // Emptied, none is kept, and nothing is wrong with that.
        h.model.kindleAddress = "   "
        #expect(h.model.kindleAddressProblem == nil && h.defaults.string(forKey: "kindleAddress") == nil)
        #expect(h.relaunched().kindleAddress == "")
        await h.model.sendToKindle(for: [try h.id("Quiet Book")])
        #expect(h.model.alert == KindleText.noRoute && h.kindleSender.emails.isEmpty)
    }

    @Test func KD15_somethingInThePreferencesThatIsNoAddressIsNotTaken() async throws {
        let h = try await library()
        h.defaults.set("not an address", forKey: "kindleAddress")
        let again = h.relaunched()
        #expect(again.kindleAddress == "" && again.kindleAddressProblem == nil)
    }
}
