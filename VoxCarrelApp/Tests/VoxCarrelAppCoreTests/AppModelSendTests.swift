import Foundation
import Testing
import VoxCarrelFixtures

@testable import VoxCarrelAppCore
@testable import VoxCarrelCore

/// Send to Phone in the app model (send to phone plan, Task 3). PH20–PH30.
///
/// The demo library's "The Lighthouse Keeper" is one M4B with an upright cover inside it;
/// "Night Train to Vostok" is four MP3s with a square one; "Quiet Rivers" is an ebook.
@MainActor
@Suite struct AppModelSendTests {
    static let lighthouse = "The Lighthouse Keeper"
    static let train = "Night Train to Vostok"
    static let rivers = "Quiet Rivers"

    /// A demo library with Send to Phone open on the book.
    private func sending(_ title: String = "The Lighthouse Keeper") async throws -> (h: Harness, id: Int64) {
        let h = try await Harness.demo()
        let id = try await h.beginSend(title)
        return (h, id)
    }

    /// A library whose one book, "Long Book", is two MP3s with a wrong length header.
    private func wrongLength() async throws -> (h: Harness, id: Int64) {
        let (h, id) = try AppModelLengthTests().library()
        await h.model.start()
        return (h, id)
    }

    // MARK: PH20 Whether a book can be sent

    @Test func ph20_exactlyOneSelectedBookCanBeSent() async throws {
        let h = try await Harness.demo()
        #expect(!h.model.canSendToPhone)

        let id = try await h.select(Self.lighthouse)
        #expect(h.model.canSendToPhone)
        #expect(h.model.canSendToPhone([id]))

        try await h.select([Self.lighthouse, Self.train])
        #expect(!h.model.canSendToPhone)
        // A context menu opened on one book is for that book, whatever is selected.
        #expect(h.model.canSendToPhone([id]))
        #expect(!h.model.canSendToPhone([]))
    }

    @Test func ph20_aRowForABookTheLibraryDoesNotHaveCannotBeSent() async throws {
        let h = try await Harness.demo()
        #expect(!h.model.canSendToPhone([-3]))
        #expect(!h.model.canSendToPhone([0]))
        h.recordBusyLabels()

        await h.model.beginSendToPhone(for: [-3])

        #expect(h.model.sendSheet == nil)
        #expect(h.busyLabels.isEmpty)
        #expect(h.model.worker?.strayIds.withLock { $0 } == [])
    }

    @Test func ph20_notWithoutALibrary() async throws {
        let h = try Harness(root: try makeTempDir(), choose: false)
        await h.model.start()
        #expect(!h.model.canSendToPhone([1]))
        await h.model.beginSendToPhone(for: [1])
        #expect(h.model.sendSheet == nil)
    }

    @Test func ph20_notWhileAnOperationASheetAQuestionOrAnUnresolvedLayoutChangeIsInTheWay() async throws {
        let h = try await Harness.demo()
        try await h.select(Self.lighthouse)
        #expect(h.model.canSendToPhone)

        h.model.busyLabel = "Working…"
        #expect(!h.model.canSendToPhone)
        h.model.busyLabel = nil

        h.model.result = ResultSummary(headline: "Done", problems: [], isClean: false)
        #expect(!h.model.canSendToPhone)
        h.model.result = nil

        h.model.prompt = .stopLayoutRecovery
        #expect(!h.model.canSendToPhone)
        h.model.prompt = nil

        h.model.layoutChangeIsUnresolved = true
        #expect(!h.model.canSendToPhone)
        h.model.layoutChangeIsUnresolved = false

        h.model.chooseLayout(AppModelLayoutTests.authorTitle)
        await h.model.previewLayoutChange()
        #expect(h.model.layoutPreview != nil)
        #expect(!h.model.canSendToPhone)
        h.model.cancelLayoutChange()

        #expect(h.model.canSendToPhone)
        await h.model.beginSendToPhone()
        // The sheet that is open is itself in the way of another.
        #expect(!h.model.canSendToPhone)
    }

    @Test func ph20_unsavedEditsOpenTheSheetWithSaveFirstAndSavingChecksTheBook() async throws {
        let h = try await Harness.demo()
        let id = try await h.edit(Self.lighthouse, newTitle: "The Lamp")
        #expect(h.model.canSendToPhone)
        h.recordBusyLabels()

        await h.model.beginSendToPhone()

        var sheet = try #require(h.model.sendSheet)
        #expect(sheet.title == Self.lighthouse)
        #expect(sheet.blockers == ["Save your changes first."])
        #expect(sheet.blockerFix == .save)
        #expect(!sheet.canShare)
        #expect(!sheet.canShowLink)
        #expect(sheet.sizeText.isEmpty)
        // Nothing was asked of the library, and nothing can be sent yet.
        #expect(h.busyLabels.isEmpty)
        #expect(await h.model.shareItems().isEmpty)
        await h.model.showPhoneLink()
        #expect(h.phoneLink.starts.isEmpty)

        await h.model.sendSave()

        #expect(try h.book(id).title == "The Lamp")
        #expect(!h.model.hasUnsavedChanges)
        sheet = try #require(h.model.sendSheet)
        #expect(sheet.title == "The Lamp")
        #expect(sheet.blockers.isEmpty)
        #expect(sheet.blockerFix == nil)
        #expect(sheet.canShare)
        #expect(h.busyLabels == ["Saving…", "Checking the book…"])
    }

    @Test func ph20_aSaveThatDoesNotGoThroughLeavesTheSheetAsking() async throws {
        let h = try await Harness.demo()
        try await h.edit(Self.lighthouse, newTitle: "   ")
        await h.model.beginSendToPhone()

        await h.model.sendSave()

        #expect(h.model.alert != nil)
        #expect(h.model.hasUnsavedChanges)
        #expect(h.model.sendSheet?.blockers == ["Save your changes first."])
    }

    @Test func ph20_editsOnAnotherBookDoNotStandInTheWayOfSendingThisOne() async throws {
        let h = try await Harness.demo()
        try await h.edit(Self.train, newTitle: "Night Bus")
        let id = try h.id(Self.lighthouse)

        await h.model.beginSendToPhone(for: [id])

        #expect(h.model.sendSheet?.title == Self.lighthouse)
        #expect(h.model.sendSheet?.blockers == [])
        #expect(h.model.hasUnsavedChanges)
    }

    // MARK: PH21 The check

    @Test func ph21_aBookOfOneFileIsCheckedOnTheWorkerAndShown() async throws {
        let h = try await Harness.demo()
        let id = try await h.select(Self.lighthouse)
        h.recordBusyLabels()

        await h.model.beginSendToPhone()

        #expect(h.busyLabels == ["Checking the book…"])
        #expect(h.model.busyLabel == nil)
        let sheet = try #require(h.model.sendSheet)
        let bytes = try #require(
            try FileManager.default.attributesOfItem(atPath: try h.fileURLs(id)[0].path)[.size] as? Int64)
        #expect(sheet.title == Self.lighthouse)
        #expect(sheet.blockers.isEmpty)
        #expect(sheet.blockerFix == nil)
        #expect(sheet.warnings.isEmpty)
        #expect(sheet.sizeText == "1 file, \(SendText.size(bytes))")
        #expect(sheet.canShare)
        #expect(sheet.canShowLink)
        #expect(sheet.linkUnavailableText == nil)
        #expect(sheet.busyText == nil)
        #expect(sheet.link == nil)
        #expect(sheet.shareNote == nil)
        #expect(sheet.coverNote == nil)
        // The cover inside the file is upright.
        #expect(sheet.showsSquareCover)
        #expect(sheet.squareCover)
        #expect(h.model.alert == nil)
    }

    @Test func ph21_aBookInSeveralPartsGoesAsOneZip() async throws {
        let (h, id) = try await sending(Self.train)
        let sheet = try #require(h.model.sendSheet)
        let bytes = try h.fileURLs(id).reduce(Int64(0)) {
            $0 + ((try FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int64) ?? 0)
        }
        #expect(sheet.sizeText == "4 files, \(SendText.size(bytes)), sent as one zip")
        #expect(sheet.blockers.isEmpty)
        // Its cover is square already: there is nothing to offer.
        #expect(!sheet.showsSquareCover)
    }

    @Test func ph21_aBookThatCannotBeSentSaysWhyAndOffersNoWayToSend() async throws {
        let (h, _) = try await sending(Self.rivers)
        var sheet = try #require(h.model.sendSheet)
        #expect(sheet.blockers == ["This book has no audiobook files to send."])
        #expect(sheet.blockerFix == nil)
        #expect(sheet.warnings.isEmpty)
        #expect(sheet.sizeText.isEmpty)
        #expect(!sheet.canShare)
        #expect(!sheet.canShowLink)
        #expect(sheet.linkUnavailableText == nil)
        #expect(!sheet.showsSquareCover)

        // Asking all the same makes nothing and starts nothing.
        #expect(await h.model.shareItems().isEmpty)
        await h.model.showPhoneLink()
        #expect(h.phoneLink.starts.isEmpty)
        #expect(h.sendFolders.isEmpty)
        await h.model.cancelSendToPhone()

        let id = try h.id(Self.lighthouse)
        let file = try h.fileURLs(id)[0]
        try FileManager.default.removeItem(at: file)
        await h.model.beginSendToPhone(for: [id])
        sheet = try #require(h.model.sendSheet)
        #expect(sheet.blockers == ["\"\(file.lastPathComponent)\" cannot be found."])
        #expect(!sheet.canShare)
    }

    @Test func ph21_aWarningWithAFixCarriesIt() async throws {
        let (h, _) = try await wrongLength()
        try await h.beginSend("Long Book")
        let sheet = try #require(h.model.sendSheet)
        #expect(sheet.blockers.isEmpty)
        #expect(sheet.canShare)
        #expect(
            sheet.warnings.first
                == SendWarningRow(
                    id: 0, text: "2 files have a wrong length header. Some players will stop early.", fix: .repair))
        // The fixture's files hold no cover, which nothing here can put right.
        #expect(
            sheet.warnings.dropFirst().map(\.text) == ["The audio has no cover inside it, so the phone will show none."])
        #expect(sheet.warnings.dropFirst().allSatisfy { $0.fix == nil })
        #expect(sheet.warnings.map(\.id) == [0, 1])
    }

    @Test func ph21_aHeaderThatCannotBeRepairedHereIsWarnedOfWithoutTheFix() async throws {
        let (h, _) = try AppModelLengthTests().library([AppModelLengthTests.vbri])
        await h.model.start()
        try await h.beginSend("Long Book")
        let warning = try #require(h.model.sendSheet?.warnings.first)
        #expect(warning.text == "1 file has a wrong length header. Some players will stop early.")
        #expect(warning.fix == nil)

        h.recordBusyLabels()
        await h.model.sendRepair()
        #expect(h.busyLabels.isEmpty)
    }

    @Test func ph21_anEarlierSendIsWarnedOf() async throws {
        let h = try await Harness.demo()
        let id = try h.id(Self.lighthouse)
        let earlier = h.clock.now.addingTimeInterval(-86_400)
        try LibraryService(store: try h.store()).recordSent(
            bookId: id, method: .share, fingerprint: SendFingerprint(files: []), at: earlier)

        try await h.beginSend(Self.lighthouse)

        #expect(h.model.sendSheet?.warnings.map(\.text) == [SendText.warning(.sentBefore(earlier), now: h.clock.now)])
    }

    @Test func ph21_aCheckThatFailsOpensNoSheetAndSaysWhy() async throws {
        let h = try await Harness.demo()
        let id = try await h.select(Self.lighthouse)
        // The book goes from the library behind the model's back.
        try LibraryService(store: try h.store()).removeBook(id: id, moveFilesToTrash: false)

        await h.model.beginSendToPhone()

        #expect(h.model.sendSheet == nil)
        #expect(h.model.alert == "That book is no longer in the library.")
        #expect(h.model.busyLabel == nil)
    }

    // MARK: PH22 Repair

    @Test func ph22_repairRunsTheOrdinaryRepairThenChecksAgainAndTheSheetStaysOpen() async throws {
        let (h, id) = try await wrongLength()
        try await h.beginSend("Long Book")
        let undoBefore = h.model.undoLabel
        h.recordBusyLabels()

        await h.model.sendRepair()

        #expect(h.busyLabels == ["Repairing 2 files…", "Checking the book…"])
        let sheet = try #require(h.model.sendSheet)
        #expect(sheet.warnings.map(\.text) == ["The audio has no cover inside it, so the phone will show none."])
        #expect(sheet.canShare)
        // An ordinary repair: Undo reverses it.
        #expect(h.model.undoLabel == "Repair length headers in 2 files")
        #expect(h.model.undoLabel != undoBefore)
        #expect(h.model.rows.first { $0.id == id }?.repairableLengthFiles == 0)
        #expect(h.model.alert == nil)

        // There is nothing left to repair: asking again does nothing.
        h.recordBusyLabels()
        await h.model.sendRepair()
        #expect(h.busyLabels == ["Repairing 2 files…", "Checking the book…"])
    }

    // MARK: PH23 Sharing

    /// The file a link serves is the library's own when the book is one file: nothing
    /// rewrites it while the link is showing.
    @Test func ph22_nothingIsRepairedWhileALinkIsShowing() async throws {
        let (h, id) = try await wrongLength()
        try await h.beginSend("Long Book")
        #expect(h.model.sendSheet?.canFix == true)
        await h.model.showPhoneLink()
        #expect(h.model.sendSheet?.link != nil)
        let undoBefore = h.model.undoLabel
        h.recordBusyLabels()

        #expect(h.model.sendSheet?.canFix == false)
        await h.model.sendRepair()

        #expect(h.busyLabels == [])
        #expect(h.model.undoLabel == undoBefore)
        #expect(h.model.rows.first { $0.id == id }?.repairableLengthFiles == 2)
        #expect(h.phoneLink.stopCount == 0)
        #expect(h.model.sendSheet?.link?.isLive == true)
    }

    @Test func ph23_aSingleFileWithNothingToChangeIsSharedAsItIsAndRecordedWhenDone() async throws {
        let (h, id) = try await sending()
        h.model.sendSquareCover = false
        let file = try h.fileURLs(id)[0]
        h.recordBusyLabels()

        let items = await h.model.shareItems()

        #expect(items.map { $0.resolvingSymlinksInPath() } == [file.resolvingSymlinksInPath()])
        #expect(h.busyLabels == ["Preparing the book…"])
        #expect(h.model.busyLabel == nil)
        // Nothing is recorded until the share sheet says it went.
        #expect(try h.sent(id).isEmpty)
        #expect(h.model.sendSheet?.shareNote == nil)

        await h.model.shareFinished(completed: true)

        let records = try h.sent(id)
        #expect(records.count == 1)
        #expect(records.first?.method == .share)
        #expect(records.first?.sentAt == h.clock.now)
        let bytes = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64)
        #expect(records.first?.fingerprint.files.map(\.name) == [file.lastPathComponent])
        #expect(records.first?.fingerprint.files.map(\.bytes) == [bytes])
        #expect(h.model.sendSheet?.shareNote == "Shared.")
        // The sheet is still open: it is the owner who closes it.
        #expect(h.model.sendSheet != nil)

        // Told a second time, nothing more is recorded.
        await h.model.shareFinished(completed: true)
        #expect(try h.sent(id).count == 1)
    }

    @Test func ph23_aShareThatWasNotCompletedRecordsNothing() async throws {
        let (h, id) = try await sending()
        _ = await h.model.shareItems()

        await h.model.shareFinished(completed: false)

        #expect(try h.sent(id).isEmpty)
        #expect(h.model.sendSheet?.shareNote == nil)
        // Nor does a later word that it went, with nothing handed over since.
        await h.model.shareFinished(completed: true)
        #expect(try h.sent(id).isEmpty)
    }

    /// A share can outlast the sheet it was begun from: what it says then is about the
    /// book it was handed, not about whatever is being shared by the time it says it.
    @Test(arguments: [true, false])
    func ph23_wordOfAnEarlierShareIsNotTakenForTheOneUnderWay(earlierWentThrough: Bool) async throws {
        let (h, train) = try await sending(Self.train)
        let earlier = await h.model.shareItems()
        #expect(earlier.count == 1)
        await h.model.cancelSendToPhone()
        let lighthouse = try await h.beginSend(Self.lighthouse)
        let present = await h.model.shareItems()
        #expect(present.count == 1)
        #expect(present != earlier)

        await h.model.shareFinished(completed: earlierWentThrough, items: earlier)

        #expect(try h.sent(lighthouse).isEmpty)
        #expect(try h.sent(train).isEmpty)
        #expect(h.model.sendSheet?.shareNote == nil)
        // The share under way is still heard when it reports.
        await h.model.shareFinished(completed: true, items: present)
        #expect(try h.sent(lighthouse).map(\.method) == [.share])
        #expect(try h.sent(train).isEmpty)
        #expect(h.model.sendSheet?.shareNote == "Shared.")
    }

    @Test func ph23_severalFilesAreSharedAsAZipInAFreshTemporaryFolderThatLastsUntilTheSheetCloses() async throws {
        let (h, id) = try await sending(Self.train)

        let first = await h.model.shareItems()

        #expect(first.count == 1)
        let zip = try #require(first.first)
        #expect(zip.lastPathComponent == "Night Train to Vostok.zip")
        #expect(FileManager.default.fileExists(atPath: zip.path))
        let folder = zip.deletingLastPathComponent()
        #expect(h.isSendFolder(folder))
        // The one parent is the app's own, and nobody else's to look into.
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: h.sendParent.path)[.posixPermissions] as? Int)
        #expect(mode == 0o700)

        // The share sheet may still be reading it when it reports.
        await h.model.shareFinished(completed: true)
        #expect(FileManager.default.fileExists(atPath: zip.path))
        #expect(try h.sent(id).first?.fingerprint.files.count == 4)

        // Each attempt has a folder of its own.
        let second = await h.model.shareItems()
        #expect(second.count == 1)
        #expect(second.first?.deletingLastPathComponent() != folder)
        #expect(FileManager.default.fileExists(atPath: zip.path))
        #expect(h.sendFolders.count == 2)

        await h.model.cancelSendToPhone()

        #expect(h.sendFolders.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: zip.path))
        #expect(FileManager.default.fileExists(atPath: h.sendTemp.path))
    }

    @Test func ph23_withTheTickOnACopyWithASquareCoverIsSharedAndItIsTheCopyThatIsRecorded() async throws {
        let (h, id) = try await sending()
        let original = try h.fileURLs(id)[0]
        #expect(h.model.sendSheet?.squareCover == true)

        let items = await h.model.shareItems()

        let copy = try #require(items.first)
        #expect(items.count == 1)
        #expect(copy.lastPathComponent == original.lastPathComponent)
        #expect(h.isSendFolder(copy.deletingLastPathComponent()))
        #expect(copy.resolvingSymlinksInPath() != original.resolvingSymlinksInPath())
        let cover = try #require(try FileMetadataIO().read(copy).cover)
        #expect(CoverSquaring.isSquare(cover) == true)
        #expect(h.model.sendSheet?.coverNote == nil)

        await h.model.shareFinished(completed: true)
        let copyBytes = try #require(try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? Int64)
        #expect(try h.sent(id).first?.fingerprint.files.map(\.bytes) == [copyBytes])

        // Closing removes the copy and never the library's file.
        await h.model.cancelSendToPhone()
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test func ph23_closingAfterSharingTheLibrarysOwnFileLeavesThatFileAlone() async throws {
        let (h, id) = try await sending()
        h.model.sendSquareCover = false
        let file = try h.fileURLs(id)[0]
        let before = try libraryState(h.root)

        let items = await h.model.shareItems()
        #expect(items.first?.resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
        await h.model.shareFinished(completed: true)
        await h.model.cancelSendToPhone()

        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try libraryState(h.root) == before)
        #expect(h.sendFolders.isEmpty)
    }

    @Test func theSquareCoverChoiceIsRememberedAndOnToBeginWith() async throws {
        let (h, _) = try await sending()
        #expect(h.model.sendSquareCover)
        #expect(h.model.sendSheet?.squareCover == true)

        h.model.sendSquareCover = false

        #expect(h.model.sendSheet?.squareCover == false)
        // Still offered: it is the owner's to turn back on.
        #expect(h.model.sendSheet?.showsSquareCover == true)
        #expect(h.defaults.object(forKey: "sendSquareCover") as? Bool == false)
        #expect(!h.relaunched().sendSquareCover)
    }

    // MARK: PH24 The link

    @Test func ph24_showingALinkMakesThePackageStartsTheLinkAndShowsIt() async throws {
        let (h, id) = try await sending(Self.train)
        h.recordBusyLabels()

        await h.model.showPhoneLink()

        #expect(h.busyLabels == ["Preparing the book…"])
        let start = try #require(h.phoneLink.starts.first)
        #expect(h.phoneLink.starts.count == 1)
        #expect(start.fileName == "Night Train to Vostok.zip")
        #expect(start.file.lastPathComponent == "Night Train to Vostok.zip")
        #expect(h.isSendFolder(start.file.deletingLastPathComponent()))
        #expect(FileManager.default.fileExists(atPath: start.file.path))
        #expect(start.now == h.clock.now)

        let offer = try #require(h.phoneLink.offer)
        let link = try #require(h.model.sendSheet?.link)
        #expect(link.linkText == offer.bookPlayerLink.absoluteString)
        #expect(link.linkText.hasPrefix("bookplayer://download?url=http://192.168.1.20:50123/"))
        #expect(link.statusText == "Waiting for the phone…")
        #expect(!link.isFinished)
        #expect(!link.canMakeNewLink)
        #expect(link.isLive)
        // Nothing is recorded for a link nobody has fetched from.
        #expect(try h.sent(id).isEmpty)
        #expect(h.model.alert == nil)
    }

    @Test func ph24_theRealFileNameOfASingleFileIsWhatTheLinkIsGiven() async throws {
        let (h, id) = try await sending()
        h.model.sendSquareCover = false
        let file = try h.fileURLs(id)[0]

        await h.model.showPhoneLink()

        #expect(h.phoneLink.starts.first?.fileName == file.lastPathComponent)
        #expect(h.phoneLink.starts.first?.file.resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
    }

    @Test func ph24_eventsUpdateTheStatusAndFinishingRecordsTheSend() async throws {
        let (h, id) = try await sending()
        await h.model.showPhoneLink()
        let file = try #require(h.phoneLink.starts.first?.file)
        let bytes = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64)

        #expect(h.model.sendSheet?.showsNetwork == true)
        h.phoneLink.fire(.started(bytesTotal: 3000))
        #expect(h.model.sendSheet?.link?.statusText == "Sending… 0%")
        #expect(h.model.sendSheet?.showsNetwork == true)
        h.phoneLink.fire(.progress(bytesSent: 1000))
        #expect(h.model.sendSheet?.link?.statusText == "Sending… 33%")
        h.phoneLink.fire(.progress(bytesSent: 2999))
        #expect(h.model.sendSheet?.link?.statusText == "Sending… 99%")
        #expect(h.model.sendSheet?.link?.isFinished == false)

        h.phoneLink.fire(.finished)
        await h.model.settle()

        let link = try #require(h.model.sendSheet?.link)
        #expect(link.statusText == "Sent.")
        #expect(link.isFinished)
        #expect(!link.canMakeNewLink)
        #expect(!link.isLive)
        // Nothing more will cross the network: the warning about it has had its day.
        #expect(h.model.sendSheet?.showsNetwork == false)
        let records = try h.sent(id)
        #expect(records.count == 1)
        #expect(records.first?.method == .link)
        #expect(records.first?.sentAt == h.clock.now)
        // What was served: the copy with the square cover.
        #expect(records.first?.fingerprint.files.map(\.bytes) == [bytes])
        // The sheet stays, saying so, until it is closed.
        #expect(h.model.sendSheet != nil)

        // The book has gone: no other link is made in this sheet, and nothing is shared from it.
        await h.model.showPhoneLink()
        #expect(h.phoneLink.starts.count == 1)
        await h.model.cancelSendToPhone()
        #expect(h.model.sendSheet == nil)
        #expect(try h.sent(id).count == 1)
    }

    @Test func ph24_anInterruptedTransferGoesBackToWaitingAndCanStartAgain() async throws {
        let (h, _) = try await sending()
        await h.model.showPhoneLink()

        h.phoneLink.fire(.started(bytesTotal: 100))
        h.phoneLink.fire(.progress(bytesSent: 60))
        h.phoneLink.fire(.interrupted)
        #expect(h.model.sendSheet?.link?.statusText == "Waiting for the phone…")
        #expect(h.model.sendSheet?.link?.isLive == true)
        #expect(h.model.sendSheet?.link?.canMakeNewLink == false)

        // The phone tries again, from where it had got to.
        h.phoneLink.fire(.started(bytesTotal: 100))
        h.phoneLink.fire(.progress(bytesSent: 80))
        #expect(h.model.sendSheet?.link?.statusText == "Sending… 80%")
    }

    @Test func ph24_anExpiredLinkSaysSoAndANewOneCanBeMade() async throws {
        let (h, id) = try await sending(Self.train)
        await h.model.showPhoneLink()
        let first = try #require(h.model.sendSheet?.link?.linkText)
        let firstFile = try #require(h.phoneLink.starts.first?.file)

        h.phoneLink.fire(.expired)

        var link = try #require(h.model.sendSheet?.link)
        #expect(link.statusText == "The link has expired.")
        #expect(!link.isFinished)
        #expect(link.canMakeNewLink)
        #expect(!link.isLive)
        #expect(try h.sent(id).isEmpty)
        // Another link can be made, over the same network.
        #expect(h.model.sendSheet?.showsNetwork == true)

        await h.model.showPhoneLink()

        link = try #require(h.model.sendSheet?.link)
        #expect(h.phoneLink.starts.count == 2)
        #expect(link.statusText == "Waiting for the phone…")
        #expect(link.linkText != first)
        #expect(link.linkText == h.phoneLink.offer?.bookPlayerLink.absoluteString)
        #expect(link.isLive)
        // A fresh package in a fresh folder.
        #expect(h.phoneLink.starts.last?.file.deletingLastPathComponent() != firstFile.deletingLastPathComponent())
    }

    @Test func ph24_aLinkThatFailsSaysWhyAndANewOneCanBeMade() async throws {
        let (h, id) = try await sending()
        await h.model.showPhoneLink()
        h.phoneLink.fire(.started(bytesTotal: 100))

        h.phoneLink.fire(.failed("The link stopped working."))
        await h.model.settle()

        let link = try #require(h.model.sendSheet?.link)
        #expect(link.statusText == "The book could not be sent. The link stopped working.")
        #expect(link.canMakeNewLink)
        #expect(!link.isFinished)
        #expect(try h.sent(id).isEmpty)
    }

    @Test func ph24_aLinkThatCannotBeStartedSaysWhyAndShowsNone() async throws {
        let (h, _) = try await sending()
        h.phoneLink.startError = PhoneLinkError.cannotListen

        await h.model.showPhoneLink()

        #expect(h.model.sendSheet?.link == nil)
        #expect(h.model.alert == "This Mac could not start listening for the phone.")
        #expect(h.model.busyLabel == nil)
        #expect(!h.sleepGuard.isActive)
        // The sheet is as it was: another way to send can be chosen.
        #expect(h.model.sendSheet?.canShare == true)
        #expect(h.model.sendSheet?.canShowLink == true)
    }

    @Test func ph24_withNoLocalAddressNoLinkIsOfferedAndTheSheetSaysWhy() async throws {
        let h = try await Harness.demo()
        h.network.localAddresses = []
        try await h.beginSend(Self.lighthouse)

        let sheet = try #require(h.model.sendSheet)
        #expect(sheet.canShare)
        #expect(!sheet.canShowLink)
        #expect(sheet.linkUnavailableText == "This Mac has no address on a local network.")

        await h.model.showPhoneLink()
        #expect(h.phoneLink.starts.isEmpty)
        #expect(h.sendFolders.isEmpty)
        #expect(h.model.sendSheet?.link == nil)
    }

    @Test func ph24_nothingCanBeSharedWhileALinkIsShowing() async throws {
        let (h, _) = try await sending()
        await h.model.showPhoneLink()
        #expect(h.model.sendSheet?.canShare == false)
        #expect(h.model.sendSheet?.canShowLink == false)
        let folders = h.sendFolders.count

        #expect(await h.model.shareItems().isEmpty)
        await h.model.showPhoneLink()

        #expect(h.sendFolders.count == folders)
        #expect(h.phoneLink.starts.count == 1)
    }

    @Test func ph24_theLinkIsNeverWrittenToThePreferencesTheCatalogueOrAMessage() async throws {
        let (h, id) = try await sending()
        h.model.setOwnNetwork(true)
        await h.model.showPhoneLink()
        let offer = try #require(h.phoneLink.offer)
        h.phoneLink.fire(.started(bytesTotal: 10))
        h.phoneLink.fire(.finished)
        await h.model.settle()
        await h.model.cancelSendToPhone()

        let secrets = [offer.token, offer.httpURL.absoluteString, offer.bookPlayerLink.absoluteString, "bookplayer:"]
        let preferences = h.defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("send") }
        #expect(!preferences.isEmpty)
        let kept = "\(preferences) \(try h.sent(id)) \(h.model.alert ?? "") \(String(describing: h.model.result))"
        for secret in secrets {
            #expect(!kept.contains(secret))
        }
        // Nor anywhere in the catalogue's files.
        for name in try FileManager.default.contentsOfDirectory(atPath: h.root.path)
        where name.hasPrefix(LibraryStore.databaseFileName) {
            let data = try Data(contentsOf: h.root.appendingPathComponent(name))
            #expect(data.range(of: Data(offer.token.utf8)) == nil)
        }
    }

    // MARK: PH25 Staying awake

    @Test func ph25_theMacIsKeptAwakeFromTheFirstByteUntilTheTransferFinishes() async throws {
        let (h, _) = try await sending()
        #expect(h.sleepGuard.begins == 0)
        await h.model.showPhoneLink()
        // A link that is only waiting keeps nothing awake.
        #expect(!h.sleepGuard.isActive)
        #expect(h.sleepGuard.begins == 0)

        h.phoneLink.fire(.started(bytesTotal: 100))
        #expect(h.sleepGuard.isActive)
        #expect(h.sleepGuard.begins == 1)
        #expect(h.sleepGuard.reasons == ["Sending a book to the phone"])
        h.phoneLink.fire(.progress(bytesSent: 50))
        #expect(h.sleepGuard.isActive)
        #expect(h.sleepGuard.begins == 1)

        h.phoneLink.fire(.finished)
        #expect(!h.sleepGuard.isActive)
        #expect(h.sleepGuard.ends == 1)
        await h.model.settle()

        // Closing afterwards has nothing to end.
        await h.model.cancelSendToPhone()
        #expect(h.sleepGuard.ends == 1)
    }

    @Test func ph25_anInterruptedTransferLetsTheMacSleepUntilItStartsAgain() async throws {
        let (h, _) = try await sending()
        await h.model.showPhoneLink()

        h.phoneLink.fire(.started(bytesTotal: 100))
        // A second connection of the same fetch is not a second reason to stay awake.
        h.phoneLink.fire(.started(bytesTotal: 100))
        #expect(h.sleepGuard.begins == 1)
        h.phoneLink.fire(.interrupted)
        #expect(!h.sleepGuard.isActive)
        #expect(h.sleepGuard.ends == 1)

        h.phoneLink.fire(.started(bytesTotal: 100))
        #expect(h.sleepGuard.isActive)
        #expect(h.sleepGuard.begins == 2)
    }

    @Test(arguments: [PhoneLinkEvent.expired, .failed("The link stopped working.")])
    func ph25_aLinkThatEndsWithoutFinishingLetsTheMacSleep(_ end: PhoneLinkEvent) async throws {
        let (h, _) = try await sending()
        await h.model.showPhoneLink()
        h.phoneLink.fire(.started(bytesTotal: 100))
        #expect(h.sleepGuard.isActive)

        h.phoneLink.fire(end)

        #expect(!h.sleepGuard.isActive)
        #expect(h.sleepGuard.begins == 1)
        #expect(h.sleepGuard.ends == 1)
    }

    @Test func ph25_cancellingDuringATransferLetsTheMacSleep() async throws {
        let (h, _) = try await sending()
        await h.model.showPhoneLink()
        h.phoneLink.fire(.started(bytesTotal: 100))
        #expect(h.sleepGuard.isActive)

        await h.model.cancelSendToPhone()

        #expect(!h.sleepGuard.isActive)
        #expect(h.sleepGuard.ends == 1)
    }

    @Test func ph25_sharingKeepsNothingAwake() async throws {
        let (h, _) = try await sending(Self.train)
        _ = await h.model.shareItems()
        await h.model.shareFinished(completed: true)
        await h.model.cancelSendToPhone()
        #expect(h.sleepGuard.begins == 0)
        #expect(h.sleepGuard.ends == 0)
    }

    // MARK: PH26 Closing

    @Test func ph26_cancelStopsTheLinkRemovesThePackageAndClosesTheSheet() async throws {
        let (h, id) = try await sending(Self.train)
        await h.model.showPhoneLink()
        let zip = try #require(h.phoneLink.starts.first?.file)
        #expect(h.phoneLink.isServing)
        #expect(h.phoneLink.stopCount == 0)

        await h.model.cancelSendToPhone()

        #expect(h.phoneLink.stopCount == 1)
        #expect(!h.phoneLink.isServing)
        #expect(!h.sleepGuard.isActive)
        #expect(!FileManager.default.fileExists(atPath: zip.path))
        #expect(h.sendFolders.isEmpty)
        #expect(h.model.sendSheet == nil)
        #expect(h.model.windowSheet(progressDue: true) == nil)
        #expect(try h.sent(id).isEmpty)
        // The book can be sent again.
        #expect(h.model.canSendToPhone)

        // Closed already: nothing more to stop.
        await h.model.cancelSendToPhone()
        #expect(h.phoneLink.stopCount == 1)
    }

    @Test func ph26_aSheetThatNeverShowedALinkStopsNone() async throws {
        let (h, _) = try await sending()
        await h.model.cancelSendToPhone()
        #expect(h.model.sendSheet == nil)
        #expect(h.phoneLink.stopCount == 0)
    }

    @Test func ph26_choosingAnotherLibraryEndsTheSend() async throws {
        let (h, _) = try await sending(Self.train)
        await h.model.showPhoneLink()
        h.phoneLink.fire(.started(bytesTotal: 100))
        let zip = try #require(h.phoneLink.starts.first?.file)

        await h.model.chooseLibrary(try makeTempDir())

        #expect(h.model.sendSheet == nil)
        #expect(h.phoneLink.stopCount == 1)
        #expect(!h.sleepGuard.isActive)
        #expect(!FileManager.default.fileExists(atPath: zip.path))
        #expect(h.sendFolders.isEmpty)
        #expect(h.model.isLibraryOpen)
    }

    @Test func ph26_aLibraryThatClosesEndsTheSend() async throws {
        let (h, _) = try await sending(Self.train)
        await h.model.showPhoneLink()
        // The library's folder goes (its disk is unplugged, say), and the app looks again.
        try FileManager.default.removeItem(at: h.root)

        await h.model.retryLibrary()

        #expect(!h.model.isLibraryOpen)
        #expect(h.model.sendSheet == nil)
        #expect(h.phoneLink.stopCount == 1)
        #expect(h.sendFolders.isEmpty)
    }

    @Test func ph26_quittingEndsTheSend() async throws {
        let (h, _) = try await sending(Self.train)
        await h.model.showPhoneLink()
        h.phoneLink.fire(.started(bytesTotal: 100))

        let answer = h.model.requestQuit { _ in }

        guard case .now = answer else {
            Issue.record("the app should quit at once")
            return
        }
        #expect(h.phoneLink.stopCount == 1)
        #expect(!h.sleepGuard.isActive)
        #expect(h.sendFolders.isEmpty)
        #expect(h.model.sendSheet == nil)
    }

    @Test func ph26_whatAnEarlierRunLeftBehindIsRemovedAfterTheStartAndNothingElseIs() async throws {
        let h = try await Harness.demo(start: false)
        let fm = FileManager.default
        try fm.createDirectory(at: h.sendParent, withIntermediateDirectories: true)
        let leftover = h.sendParent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("zip".utf8).write(to: leftover.appendingPathComponent("Book.zip"))
        // A plain file in the parent is not a folder of the app's making.
        let plain = h.sendParent.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: plain)
        // Nor is a link, wherever it leads: what it leads to is not touched.
        let target = try makeTempDir()
        try Data("keep".utf8).write(to: target.appendingPathComponent("file"))
        let link = h.sendParent.appendingPathComponent(UUID().uuidString)
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        // Nothing beside the parent is looked at: not another folder, and not a folder
        // of the naming an earlier version used.
        let other = h.sendTemp.appendingPathComponent("Something Else", isDirectory: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: other.appendingPathComponent("file"))
        let old = h.sendTemp.appendingPathComponent("VoxCarrelSend-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)

        await h.model.start()
        await h.sendCleanupDone()

        #expect(!fm.fileExists(atPath: leftover.path))
        #expect(fm.fileExists(atPath: plain.path))
        #expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil)
        #expect(fm.fileExists(atPath: target.appendingPathComponent("file").path))
        #expect(fm.fileExists(atPath: other.appendingPathComponent("file").path))
        #expect(fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: h.sendParent.path))
    }

    /// The defect of the first real launch: the clean-up took minutes, and the library
    /// waited for it.
    @Test func ph26_theLibraryOpensAndShowsItsBooksWhileTheCleanUpIsHeld() async throws {
        let h = try await Harness.demo(start: false)
        let fm = FileManager.default
        let leftover = h.sendParent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: leftover, withIntermediateDirectories: true)
        let gate = Gate()
        h.model.beforeSendCleanup = { await gate.wait() }

        await h.model.start()

        // The clean-up has not got anywhere, and the library is open all the same.
        #expect(h.model.isLibraryOpen)
        #expect(h.model.rows.count == 12)
        #expect(h.model.sidebar.counts[.allBooks] == 12)
        #expect(h.model.busyLabel == nil)
        #expect(h.model.canImport)
        await gate.arrival()
        #expect(fm.fileExists(atPath: leftover.path))

        // A send begun meanwhile makes its folder, which the clean-up then leaves alone.
        try await h.beginSend(Self.train)
        let zip = try #require(await h.model.shareItems().first)

        await gate.release()
        await h.sendCleanupDone()

        #expect(!fm.fileExists(atPath: leftover.path))
        #expect(fm.fileExists(atPath: zip.path))
        #expect(h.sendFolders.count == 1)
    }

    @Test func ph26_withNoLibraryChosenTheCleanUpStillRunsAndStartDoesNotWaitForIt() async throws {
        let h = try Harness(root: try makeTempDir(), choose: false)
        let leftover = h.sendParent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        let gate = Gate()
        h.model.beforeSendCleanup = { await gate.wait() }

        await h.model.start()
        #expect(!h.model.isLibraryOpen)
        #expect(FileManager.default.fileExists(atPath: leftover.path))

        await gate.release()
        await h.sendCleanupDone()
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    @Test(arguments: [true, false])
    func ph26_aParentThatIsALinkOrAFileIsNeverCleanedThroughOrWrittenThrough(isLink: Bool) async throws {
        let h = try await Harness.demo(start: false)
        let fm = FileManager.default
        // Someone else's folder, with a folder in it named as an attempt's is.
        let target = try makeTempDir()
        let theirs = target.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: theirs, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: theirs.appendingPathComponent("file"))
        if isLink {
            try fm.createSymbolicLink(at: h.sendParent, withDestinationURL: target)
        } else {
            try Data("a file".utf8).write(to: h.sendParent)
        }

        await h.model.start()
        await h.sendCleanupDone()
        #expect(fm.fileExists(atPath: theirs.appendingPathComponent("file").path))

        // Nor is a package made there: the send says it could not be, and nothing is written.
        try await h.beginSend(Self.train)
        #expect(await h.model.shareItems().isEmpty)
        #expect(h.model.alert == "VoxCarrel could not make a temporary folder for the copy to send.")
        #expect(h.model.busyLabel == nil)
        #expect(try fm.contentsOfDirectory(atPath: target.path) == [theirs.lastPathComponent])
        if !isLink { #expect(try Data(contentsOf: h.sendParent) == Data("a file".utf8)) }
        await h.model.cancelSendToPhone()
        #expect(h.model.sendSheet == nil)
    }

    /// The copies made for a send are the owner's books: no other user of the Mac is
    /// let into the folder they are made in, wherever the temporary folder is.
    @Test func ph26_theFolderOfPackagesIsTheOwnersAlone() async throws {
        let h = try await Harness.demo()
        let fm = FileManager.default
        func mode() throws -> Int? {
            (try fm.attributesOfItem(atPath: h.sendParent.path)[.posixPermissions] as? NSNumber)?.intValue
        }

        // Made by the app: for this user only.
        try await h.beginSend(Self.train)
        #expect(await h.model.shareItems().count == 1)
        #expect(try mode() == 0o700)
        await h.model.cancelSendToPhone()

        // Found open to everyone: closed to them before anything is made in it.
        try fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: h.sendParent.path)
        try await h.beginSend(Self.train)
        let zip = try #require(await h.model.shareItems().first)
        #expect(try mode() == 0o700)
        #expect(fm.fileExists(atPath: zip.path))
        await h.model.cancelSendToPhone()
        #expect(h.sendFolders.isEmpty)
    }

    // MARK: PH27 The network

    @Test func ph27_aNetworkThatIsNotMarkedGetsTheStrongerNote() async throws {
        let (h, _) = try await sending()
        let sheet = try #require(h.model.sendSheet)
        #expect(!sheet.isOwnNetwork)
        #expect(sheet.canMarkOwnNetwork)
        #expect(
            sheet.networkNote
                == "Your phone must be on the same network as this Mac. Anyone else on this network could see "
                + "the book being sent. Use the link only on a network you trust.")
        // Never a refusal.
        #expect(sheet.canShowLink)
    }

    @Test func ph27_markingTheNetworkIsRememberedForThatNetworkOnly() async throws {
        let (h, _) = try await sending()

        h.model.setOwnNetwork(true)

        #expect(h.model.sendSheet?.isOwnNetwork == true)
        #expect(h.model.sendSheet?.networkNote == "Your phone must be on the same network as this Mac.")
        await h.model.cancelSendToPhone()

        // After quitting and opening the app again, on the same network.
        let again = h.relaunched()
        await again.start()
        again.click(try h.id(Self.lighthouse), modifiers: [])
        await again.settle()
        await again.beginSendToPhone()
        #expect(again.sendSheet?.isOwnNetwork == true)
        await again.cancelSendToPhone()

        // On another network the mark does not hold.
        h.network.network = NetworkIdentity(router: "10.0.0.1", hardware: "00:11:22:33:44:55", name: "Cafe")
        await again.beginSendToPhone()
        #expect(again.sendSheet?.isOwnNetwork == false)
        #expect(again.sendSheet?.networkNote == SendText.otherNetwork)
        await again.cancelSendToPhone()

        // Nor on one that only shares the router's address.
        h.network.network = NetworkIdentity(router: "192.168.1.1", hardware: "a4:5e:60:c1:02:9f", name: "Hotel")
        await again.beginSendToPhone()
        #expect(again.sendSheet?.isOwnNetwork == false)
        await again.cancelSendToPhone()

        // Back home, and the mark can be taken off.
        h.network.network = NetworkIdentity(router: "192.168.1.1", hardware: "a4:5e:60:c1:02:9f", name: "Home")
        await again.beginSendToPhone()
        #expect(again.sendSheet?.isOwnNetwork == true)
        again.setOwnNetwork(false)
        #expect(again.sendSheet?.isOwnNetwork == false)
        #expect(again.sendSheet?.networkNote == SendText.otherNetwork)
        #expect((h.defaults.array(forKey: "sendOwnNetworks") as? [String]) == [])
    }

    /// Most routers of one make have the same address: "192.168.1.1" alone says little.
    @Test func ph27_anotherNetworkWhoseRouterHasTheSameAddressIsNotTheOwners() async throws {
        let h = try await Harness.demo()
        h.network.network = NetworkIdentity(router: "192.168.1.1", hardware: "a4:5e:60:c1:02:9f")
        try await h.beginSend(Self.lighthouse)
        h.model.setOwnNetwork(true)
        #expect(h.model.sendSheet?.isOwnNetwork == true)
        await h.model.cancelSendToPhone()

        // Elsewhere: the same address, another router, and no name to be read.
        h.network.network = NetworkIdentity(router: "192.168.1.1", hardware: "00:11:22:33:44:55")
        await h.model.beginSendToPhone()
        #expect(h.model.sendSheet?.isOwnNetwork == false)
        #expect(h.model.sendSheet?.networkNote == SendText.otherNetwork)
        await h.model.cancelSendToPhone()

        // At home again.
        h.network.network = NetworkIdentity(router: "192.168.1.1", hardware: "a4:5e:60:c1:02:9f")
        await h.model.beginSendToPhone()
        #expect(h.model.sendSheet?.isOwnNetwork == true)
    }

    /// A mark kept before the router's hardware address was part of it is not honoured.
    @Test func ph27_aMarkThatNamesOnlyTheRoutersAddressIsNotHonoured() async throws {
        let h = try await Harness.demo()
        h.defaults.set(["192.168.1.1", "192.168.1.1\tHome"], forKey: "sendOwnNetworks")
        try await h.beginSend(Self.lighthouse)
        #expect(h.model.sendSheet?.isOwnNetwork == false)
        #expect(h.model.sendSheet?.networkNote == SendText.otherNetwork)
    }

    @Test func ph27_aNetworkKnownOnlyByItsRouterIsMarkedByThat() async throws {
        let h = try await Harness.demo()
        h.network.network = NetworkIdentity(router: "192.168.4.1", hardware: "0c:8d:db:10:20:30")
        try await h.beginSend(Self.lighthouse)
        #expect(h.model.sendSheet?.canMarkOwnNetwork == true)

        h.model.setOwnNetwork(true)

        #expect(h.model.sendSheet?.isOwnNetwork == true)
        #expect(h.defaults.array(forKey: "sendOwnNetworks") as? [String] == ["192.168.4.1\t0c:8d:db:10:20:30"])
        // Marked twice, it is kept once.
        h.model.setOwnNetwork(true)
        #expect(h.defaults.array(forKey: "sendOwnNetworks") as? [String] == ["192.168.4.1\t0c:8d:db:10:20:30"])
    }

    @Test func ph27_aNetworkThatCannotBeToldApartIsNeverTreatedAsMarked() async throws {
        let h = try await Harness.demo()
        h.network.network = nil
        try await h.beginSend(Self.lighthouse)
        #expect(h.model.sendSheet?.canMarkOwnNetwork == false)
        #expect(h.model.sendSheet?.isOwnNetwork == false)

        h.model.setOwnNetwork(true)

        #expect(h.model.sendSheet?.isOwnNetwork == false)
        #expect(h.model.sendSheet?.networkNote == SendText.otherNetwork)
        #expect(h.defaults.object(forKey: "sendOwnNetworks") == nil)
        // The link is still offered: the warning is all there is.
        #expect(h.model.sendSheet?.canShowLink == true)
    }

    @Test func ph27_theNetworkIsLookedAtAgainWhenALinkIsAskedFor() async throws {
        let (h, _) = try await sending()
        #expect(h.model.sendSheet?.canShowLink == true)
        // The Mac leaves the network while the sheet is open.
        h.network.localAddresses = []

        await h.model.showPhoneLink()

        #expect(h.phoneLink.starts.isEmpty)
        #expect(h.model.sendSheet?.canShowLink == false)
        #expect(h.model.sendSheet?.linkUnavailableText == "This Mac has no address on a local network.")
    }

    // MARK: PH28 One sheet, and nothing else meanwhile

    @Test func ph28_theSheetIsOneOfTheWindowsSheetsAfterTheOthers() async throws {
        let (h, _) = try await sending()
        let sheet = try #require(h.model.sendSheet)
        #expect(h.model.windowSheet(progressDue: false) == .sendToPhone(sheet))
        #expect(WindowSheet.sendToPhone(sheet).id == "sendToPhone")
        #expect(Set([WindowSheet.sendToPhone(sheet).id, WindowSheet.progress("").id, WindowSheet.seriesChoice([]).id]).count == 3)

        // A result (of a repair the sheet ran, say) comes first, and the sheet is back after it.
        let result = ResultSummary(headline: "Done", problems: [], isClean: false)
        h.model.result = result
        #expect(h.model.windowSheet(progressDue: false) == .result(result))
        h.model.result = nil
        #expect(h.model.windowSheet(progressDue: false) == .sendToPhone(sheet))

        // What the sheet itself is doing is shown in the sheet, not in place of it.
        h.model.busyLabel = "Preparing the book…"
        let working = try #require(h.model.sendSheet)
        #expect(working.busyText == "Preparing the book…")
        #expect(!working.canShare)
        #expect(!working.canShowLink)
        #expect(h.model.windowSheet(progressDue: true) == .sendToPhone(working))
        h.model.busyLabel = nil
    }

    @Test func ph28_whileTheSheetIsOpenNoOtherOperationCanStart() async throws {
        let (h, id) = try await sending()
        let other = try h.id(Self.train)
        let statusBefore = try h.book(other).readStatus
        let newStatus: ReadStatus = statusBefore == .finished ? .unread : .finished
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
        #expect(!h.model.canUndo)
        #expect(!h.model.canImport)
        #expect(!h.model.canSave)
        #expect(!h.model.canChangeLayout)
        #expect(!h.model.canChangeFiles)
        #expect(!h.model.canAddAudibleBook)
        let commands = h.model.commands(for: [id])
        #expect(!commands.mark)
        #expect(!commands.rewriteTags)
        #expect(!commands.repairLengthHeaders)
        #expect(!commands.remove)
        #expect(!commands.addToCollection)
        h.recordBusyLabels()

        await h.model.undo()
        await h.model.setReadStatus(newStatus, for: [other])
        await h.model.rewriteTags(for: [other])
        await h.model.beginImport([try Harness.inbox()])
        await h.model.createCollection(name: "New", adding: [other])
        h.model.requestRemove([other])
        await h.model.previewLayoutChange()
        await h.model.beginSendToPhone(for: [other])

        #expect(h.busyLabels.isEmpty)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
        #expect(h.model.review == nil)
        #expect(h.model.prompt == nil)
        #expect(h.model.layoutPreview == nil)
        #expect(try h.book(other).readStatus == statusBefore)
        #expect(h.model.sendSheet?.title == Self.lighthouse)

        // When it has closed, everything can again.
        await h.model.cancelSendToPhone()
        #expect(h.model.canUndo)
        #expect(h.model.canImport)
        #expect(h.model.commands(for: [id]).mark)
        await h.model.setReadStatus(newStatus, for: [other])
        #expect(try h.book(other).readStatus == newStatus)
    }

    @Test func ph28_filesTheAppIsAskedToOpenWaitUntilTheSheetHasClosed() async throws {
        let (h, _) = try await sending()
        let inbox = try Harness.inbox()

        await h.model.openFiles([inbox])
        await h.model.settle()
        #expect(h.model.review == nil)
        #expect(h.model.alert == nil)
        #expect(h.model.sendSheet != nil)

        await h.model.cancelSendToPhone()
        await h.model.settle()
        #expect(h.model.review != nil)
    }

    // MARK: What the sheet's controls are told

    @Test func theSheetSaysWhichOfItsControlsApplyAndWhatItsCloseButtonSays() async throws {
        let (h, _) = try await sending()
        var sheet = try #require(h.model.sendSheet)
        #expect(sheet.canClose)
        #expect(sheet.canFix)
        #expect(sheet.canChangeSquareCover)
        #expect(sheet.closeTitle == "Cancel")

        // While the sheet is doing something, nothing else can be begun from it, and it stays.
        h.model.busyLabel = "Preparing the book…"
        sheet = try #require(h.model.sendSheet)
        #expect(!sheet.canClose)
        #expect(!sheet.canFix)
        #expect(!sheet.canChangeSquareCover)
        await h.model.cancelSendToPhone()
        #expect(h.model.sendSheet != nil)
        h.model.busyLabel = nil

        // A link is of the copy as it was made: the choice of cover is no longer open.
        await h.model.showPhoneLink()
        sheet = try #require(h.model.sendSheet)
        #expect(!sheet.canChangeSquareCover)
        #expect(sheet.canClose)
        #expect(sheet.closeTitle == "Cancel")

        // Once the book has gone, closing is no longer cancelling anything.
        h.phoneLink.fire(.started(bytesTotal: 10))
        h.phoneLink.fire(.finished)
        await h.model.settle()
        #expect(h.model.sendSheet?.closeTitle == "Done")
    }

    @Test func afterAShareThatWentThroughTheCloseButtonSaysDone() async throws {
        let (h, _) = try await sending()
        _ = await h.model.shareItems()
        #expect(h.model.sendSheet?.closeTitle == "Cancel")
        await h.model.shareFinished(completed: true)
        #expect(h.model.sendSheet?.closeTitle == "Done")
    }

    @Test func aBookThatCannotBeSentHasNoChoiceOfCoverAndNothingToFix() async throws {
        let (h, _) = try await sending(Self.rivers)
        let sheet = try #require(h.model.sendSheet)
        #expect(!sheet.canChangeSquareCover)
        #expect(sheet.canClose)
        #expect(sheet.closeTitle == "Cancel")
    }

    /// PH23: AirDrop that cannot be used is a share that did not go through, and says so.
    @Test func ph23_airDropThatIsNotAvailableRecordsNothingAndSaysSo() async throws {
        let (h, id) = try await sending()
        _ = await h.model.shareItems()

        await h.model.shareUnavailable(.airDrop)

        #expect(h.model.alert == "AirDrop is not available on this Mac just now. Check that Wi-Fi and Bluetooth are on.")
        #expect(try h.sent(id).isEmpty)
        #expect(h.model.sendSheet?.shareNote == nil)
        // The share is over: a later word that it went records nothing.
        await h.model.shareFinished(completed: true)
        #expect(try h.sent(id).isEmpty)
        #expect(h.model.sendSheet != nil)
    }

    // MARK: PH29 The inspector

    @Test func ph29_theInspectorSaysWhenTheBookWasLastSent() async throws {
        let (h, _) = try await sending()
        #expect(h.detail?.lastSent == nil)
        #expect(h.detail?.sentToPhoneText() == nil)

        await h.model.showPhoneLink()
        h.phoneLink.fire(.started(bytesTotal: 10))
        h.phoneLink.fire(.finished)
        await h.model.settle()

        // At once, with the sheet still open.
        #expect(h.detail?.lastSent == h.clock.now)
        #expect(h.detail?.sentToPhoneText(now: h.clock.now) == SendText.sentLine(h.clock.now, now: h.clock.now))

        // A later share is the newer date.
        await h.model.cancelSendToPhone()
        h.clock.now = h.clock.now.addingTimeInterval(3 * 86_400)
        await h.model.beginSendToPhone()
        _ = await h.model.shareItems()
        await h.model.shareFinished(completed: true)
        #expect(h.detail?.lastSent == h.clock.now)
    }

    @Test func ph29_theLineIsWordedWithTheDay() async throws {
        let h = try await Harness.demo()
        try await h.select(Self.lighthouse)
        var detail = try #require(h.detail)
        #expect(detail.sentToPhoneText() == nil)
        detail.lastSent = SendTextTests.date(2026, 11, 23)
        #expect(
            detail.sentToPhoneText(
                now: SendTextTests.date(2026, 11, 30), locale: SendTextTests.british, timeZone: SendTextTests.london)
                == "Sent to phone 23 Nov")
    }

    // MARK: PH30 Nothing is changed

    @Test func ph30_sendingChangesNoLibraryFileNoDetailAndNothingUndoWouldReverse() async throws {
        let h = try await Harness.demo()
        let before = try libraryState(h.root)
        let booksBefore = try h.store().books()

        for title in [Self.lighthouse, Self.train] {
            try await h.beginSend(title)
            _ = await h.model.shareItems()
            await h.model.shareFinished(completed: true)
            await h.model.showPhoneLink()
            h.phoneLink.fire(.started(bytesTotal: 10))
            h.phoneLink.fire(.progress(bytesSent: 5))
            h.phoneLink.fire(.finished)
            await h.model.settle()
            await h.model.cancelSendToPhone()
        }

        #expect(try libraryState(h.root) == before)
        #expect(try h.store().books() == booksBefore)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
        #expect(try LibraryService(store: try h.store()).undoLabel() == Harness.demoUndoLabel)
        #expect(h.model.alert == nil)
        #expect(h.model.result == nil)
        #expect(!h.model.hasUnsavedChanges)
        #expect(h.sendFolders.isEmpty)
        #expect(Set(try h.sent(try h.id(Self.lighthouse)).map(\.method)) == [.link, .share])
        #expect(try h.sent(try h.id(Self.train)).count == 2)
    }
}
