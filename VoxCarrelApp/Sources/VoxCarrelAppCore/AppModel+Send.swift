import Foundation
import VoxCarrelCore

// Send to Phone in the app model (send to phone plan, Task 3). PH20–PH30.
//
// The sheet checks one audiobook and sends it one of two ways: through the system's
// sharing (AirDrop, or the share picker), or by a link that BookPlayer on the phone
// fetches the book from. What is sent is the book's own file, or a copy or a zip made in
// a temporary folder of the app's own; no file of the library is changed by any of it.
// The link's address is a secret while it lasts: it is shown, and held in memory, and
// never written anywhere.

/// What the Send to Phone sheet shows.
public struct SendSheetState: Equatable, Sendable {
    /// The book's title.
    public var title: String
    /// Why nothing can be sent, each a sentence; empty when the book can be sent.
    public var blockers: [String]
    /// What puts the blockers right, when the sheet can: saving the unsaved changes.
    public var blockerFix: SendFix?
    public var warnings: [SendWarningRow]
    /// "1 file, 412 MB" or "4 files, 1.2 GB, sent as one zip"; empty when nothing can be sent.
    public var sizeText: String
    /// Whether the tick for a square cover is offered: the cover in the audio is not square.
    public var showsSquareCover: Bool
    /// Whether the cover is to be made square on the copy that is sent.
    public var squareCover: Bool
    /// Said when the last copy made would not take the square cover; nil otherwise.
    public var coverNote: String?
    /// What the sheet is doing now ("Preparing the book…"); nil when it is doing nothing.
    /// Nothing else can be begun from the sheet meanwhile.
    public var busyText: String?
    /// Whether AirDrop and Share can be begun.
    public var canShare: Bool
    /// Whether a link can be shown.
    public var canShowLink: Bool
    /// Why no link is offered though the book can be sent; nil when one is.
    public var linkUnavailableText: String?
    /// The sentence about the network, stronger when it is not marked as the owner's.
    public var networkNote: String
    public var isOwnNetwork: Bool
    /// Whether the network can be told from others, so that it can be marked.
    public var canMarkOwnNetwork: Bool
    /// "Shared." once a share has gone through; nil otherwise.
    public var shareNote: String?
    /// Not nil once a link is showing.
    public var link: SendLinkState?
    /// Whether the sheet can be closed: not in the middle of something.
    public var canClose = false
    /// Whether what the blockers and warnings offer (Save, Repair) can be begun.
    public var canFix = false
    /// Whether the tick for a square cover can be changed: nothing has been made to send yet
    /// that a link is showing for, and nothing is being made.
    public var canChangeSquareCover = false
    /// What the button that closes the sheet says: "Cancel", or "Done" once the book has gone.
    public var closeTitle = ""
}

/// A way of sharing that the system could not offer.
public enum UnavailableShare: Sendable {
    case airDrop
}

/// The link the sheet shows, and how the phone is getting on with it.
public struct SendLinkState: Equatable, Sendable {
    /// What the QR code holds, and what Copy Link copies.
    public var linkText: String
    /// "Waiting for the phone…", "Sending… 40%", "Sent.", "The link has expired."
    public var statusText: String
    /// The phone has the whole book.
    public var isFinished: Bool
    /// The link is gone without the book having been sent: another can be made.
    public var canMakeNewLink: Bool
    /// Whether the link can still be fetched from: the code is worth showing.
    public var isLive: Bool
}

/// The send that is open: what the sheet's state is worked out from.
struct SendSession {
    var bookId: Int64
    var title: String
    /// PH20: the book has edits that are not saved, and has not been checked.
    var needsSave = false
    var check: SendCheck?
    /// Whether the book has a file whose length header Repair can put right.
    var canRepair = false
    /// The network as it was when last looked at.
    var hasAddress = false
    var network: NetworkIdentity?
    /// PH27: whether the owner has marked that network as their own.
    var isOwnNetwork = false
    /// Every temporary folder made for this send, to be removed when it closes.
    var folders: [URL] = []
    var coversNotSquared = 0
    /// What was handed to the share sheet and has not been heard of since.
    var sharing: SendFingerprint?
    var shared = false
    var link: Link?

    struct Link {
        var text: String
        var fingerprint: SendFingerprint
        var phase: Phase = .waiting
        var bytesTotal: Int64 = 0

        enum Phase: Equatable {
            case waiting
            case sending(Int64)
            case finished
            case expired
            case failed(String)

            /// The link is gone without the book having been sent.
            var isGoneUnsent: Bool {
                switch self {
                case .expired, .failed: true
                case .waiting, .sending, .finished: false
                }
            }
        }
    }
}

extension AppModel {
    // MARK: PH20 Whether a book can be sent

    /// PH20: whether Send to Phone applies to the selection: exactly one book of the
    /// library is selected, and no operation, sheet, question or unresolved change of
    /// folder layout is in the way. Unsaved edits are not in the way: the sheet opens
    /// and asks for them to be saved first.
    public var canSendToPhone: Bool {
        canSendToPhone(selection)
    }

    /// The same for these books, which need not be the selection: for a context menu.
    public func canSendToPhone(_ ids: Set<Int64>) -> Bool {
        // A row that stands for a book the library does not have has an id of zero or less.
        guard ids.count == 1, let id = ids.first, id > 0 else { return false }
        return isLibraryOpen && busyLabel == nil && storedPrompt == nil && sendSession == nil
            && !layoutChangeIsUnresolved && layoutPreview == nil && review == nil && result == nil
            && libraryCheck == nil && seriesChoice == nil && lookup == nil
    }

    // MARK: PH21 The check

    /// PH21: checks the one selected book and opens the sheet. Does nothing unless
    /// `canSendToPhone`.
    public func beginSendToPhone() async {
        await beginSendToPhone(for: selection)
    }

    /// The same for the book a context menu was opened on.
    ///
    /// The check is an operation: it reads the files' tags, and may read an MP3 through.
    /// When it cannot be made no sheet opens and `alert` says why. PH20: a book with
    /// edits that are not saved is not checked until they are (`sendSave`).
    public func beginSendToPhone(for ids: Set<Int64>) async {
        guard canSendToPhone(ids), let id = ids.first else { return }
        var session = SendSession(bookId: id, title: sendTitle(of: id) ?? "")
        if editedBookIds.contains(id) {
            session.needsSave = true
            sendSession = session
            readSendNetwork()
            return
        }
        guard let worker = await begin(SendText.checkingLabel) else { return }
        do {
            session.check = try await worker.sendCheck(for: id)
            session.canRepair = canRepairLength(of: id)
            sendSession = session
            readSendNetwork()
        } catch {
            show(error)
        }
        // A check changes nothing in the library, so there is nothing to read again.
        busyLabel = nil
    }

    /// Checks the open send's book again, after something about it was put right. If the
    /// check cannot be made the sheet closes and `alert` says why.
    private func checkSendAgain() async {
        guard let id = sendSession?.bookId else { return }
        sendIsActing = true
        let worker = await begin(SendText.checkingLabel)
        sendIsActing = false
        guard let worker else { return }
        do {
            let check = try await worker.sendCheck(for: id)
            if var session = sendSession, session.bookId == id {
                session.needsSave = false
                session.check = check
                session.canRepair = canRepairLength(of: id)
                session.title = sendTitle(of: id) ?? session.title
                session.coversNotSquared = 0
                sendSession = session
            }
        } catch {
            show(error)
            endSend()
        }
        busyLabel = nil
    }

    /// The book's title as it is saved; nil when the book is not among those shown or inspected.
    private func sendTitle(of id: Int64) -> String? {
        if let row = rows.first(where: { $0.id == id }) { return row.book.title }
        if case .one(let detail, _) = inspecting, detail.row.id == id { return detail.row.book.title }
        return nil
    }

    private func canRepairLength(of id: Int64) -> Bool {
        (rows.first { $0.id == id }?.repairableLengthFiles ?? 0) > 0
    }

    /// What the sheet shows; nil when it is not open.
    public var sendSheet: SendSheetState? {
        guard let session = sendSession else { return nil }
        let check = session.needsSave ? nil : session.check
        let sendable = check.map { $0.blockers.isEmpty && !$0.files.isEmpty } ?? false
        // PH28: one thing at a time, and one way of sending at a time.
        let free = sendable && busyLabel == nil && session.link == nil
        let now = inboxNow()
        return SendSheetState(
            title: session.title.trimmedOrNil ?? "Untitled book",
            blockers: session.needsSave ? [SendText.saveFirst] : (check?.blockers ?? []).map(SendText.blocker),
            blockerFix: session.needsSave ? .save : nil,
            warnings: (check?.warnings ?? []).enumerated().map { index, warning in
                var fix: SendFix?
                if case .wrongLengthHeader = warning, session.canRepair { fix = .repair }
                return SendWarningRow(id: index, text: SendText.warning(warning, now: now), fix: fix)
            },
            sizeText: check.flatMap {
                sendable
                    ? SendText.sizeLine(files: $0.files.count, bytes: $0.totalBytes, asZip: $0.needsPackage) : nil
            } ?? "",
            showsSquareCover: sendable && check?.coverIsSquare == false,
            squareCover: storedSendSquareCover,
            coverNote: SendText.coverNotSquared(files: session.coversNotSquared),
            busyText: busyLabel,
            canShare: free,
            canShowLink: free && session.hasAddress,
            linkUnavailableText: sendable && !session.hasAddress
                ? PhoneLinkError.noLocalAddress.errorDescription : nil,
            networkNote: SendText.networkNote(isOwn: session.isOwnNetwork),
            isOwnNetwork: session.isOwnNetwork,
            canMarkOwnNetwork: session.network != nil,
            shareNote: session.shared ? SendText.shared : nil,
            link: session.link.map(Self.linkState),
            canClose: busyLabel == nil,
            canFix: busyLabel == nil,
            canChangeSquareCover: free,
            closeTitle: session.shared || session.link?.phase == .finished ? SendText.done : SendText.cancel)
    }

    private static func linkState(_ link: SendSession.Link) -> SendLinkState {
        let status: String
        var isLive = false
        var canMakeNew = false
        switch link.phase {
        case .waiting:
            status = SendText.waiting
            isLive = true
        case .sending(let sent):
            status = SendText.sending(bytesSent: sent, of: link.bytesTotal)
            isLive = true
        case .finished:
            status = SendText.sent
        case .expired:
            status = SendText.expired
        case .failed(let why):
            status = SendText.failed(why)
        }
        canMakeNew = link.phase.isGoneUnsent
        return SendLinkState(
            linkText: link.text, statusText: status, isFinished: link.phase == .finished,
            canMakeNewLink: canMakeNew, isLive: isLive)
    }

    /// Whether the cover is made square on the copy that is sent, when it is not
    /// square already. Remembered; on to begin with.
    public var sendSquareCover: Bool {
        get { storedSendSquareCover }
        set {
            guard newValue != storedSendSquareCover else { return }
            storedSendSquareCover = newValue
            defaults.set(newValue, forKey: SendKeys.squareCover)
        }
    }

    // MARK: PH22 What the sheet offers to put right

    /// PH22: repairs the book's wrong length headers, as Repair Length Headers does (an
    /// operation that Undo reverses), then checks the book again. The sheet stays open.
    /// Does nothing unless a warning offers the repair.
    public func sendRepair() async {
        guard let session = sendSession, busyLabel == nil,
              sendSheet?.warnings.contains(where: { $0.fix == .repair }) == true
        else { return }
        sendIsActing = true
        await repairLengthHeaders(for: [session.bookId])
        sendIsActing = false
        await checkSendAgain()
    }

    /// PH20: saves the unsaved changes, as Save does, then checks the book. When the
    /// save does not go through the sheet still asks for it.
    public func sendSave() async {
        guard let session = sendSession, session.needsSave, busyLabel == nil else { return }
        sendIsActing = true
        await save()
        sendIsActing = false
        guard !editedBookIds.contains(session.bookId) else { return }
        await checkSendAgain()
    }

    // MARK: PH27 The network

    /// The Mac's own networks, as the owner marked them.
    private var ownNetworks: [NetworkIdentity] {
        (defaults.array(forKey: SendKeys.ownNetworks) as? [String] ?? []).compactMap(NetworkIdentity.init(stored:))
    }

    /// Looks at the network as it is now, for the open send.
    private func readSendNetwork() {
        guard var session = sendSession else { return }
        session.hasAddress = !network.addresses().isEmpty
        session.network = network.identity()
        // With no identity readable the network is never treated as marked.
        session.isOwnNetwork = session.network.map { now in ownNetworks.contains { $0.matches(now) } } ?? false
        sendSession = session
    }

    /// PH27: marks the network the Mac is on now as the owner's own, or takes the mark
    /// off. Remembered for that network. Does nothing when the network cannot be told
    /// from others.
    public func setOwnNetwork(_ own: Bool) {
        guard sendSession != nil else { return }
        readSendNetwork()
        guard let identity = sendSession?.network else { return }
        var marked = ownNetworks.filter { !$0.matches(identity) }
        if own { marked.append(identity) }
        defaults.set(marked.map(\.stored), forKey: SendKeys.ownNetworks)
        sendSession?.isOwnNetwork = own
    }

    // MARK: PH23 Sharing

    /// The one folder every send's package goes under: VoxCarrel's own, inside the
    /// temporary folder. Each attempt has a folder of its own in it, named by a UUID.
    nonisolated static let sendParentName = "VoxCarrelSend"

    nonisolated static func sendParent(in root: URL) -> URL {
        root.appendingPathComponent(sendParentName, isDirectory: true)
    }

    /// Whether a folder itself is at `url`: never a link to one, nor a file.
    nonisolated static func isRealFolder(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Makes the parent folder if it is not there, for this user alone. Refuses when
    /// something else has its name: a link (which could lead anywhere) or a file.
    nonisolated static func makeSendParent(in root: URL) throws {
        let parent = sendParent(in: root)
        var info = stat()
        if lstat(parent.path, &info) != 0 {
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        guard isRealFolder(parent) else { throw SendFolderError.parentIsNotAFolder }
    }

    /// Makes what is sent for the open send's book, in a temporary folder of its own.
    /// An operation. Nil, with `alert` saying why, when it cannot be made.
    private func prepareSend() async -> PreparedSend? {
        guard let session = sendSession, !session.needsSave, let check = session.check, check.blockers.isEmpty,
              !check.files.isEmpty
        else { return nil }
        sendIsActing = true
        let worker = await begin(SendText.preparingLabel)
        sendIsActing = false
        guard let worker else { return nil }
        // Known to the clean-up before it exists, so that it is never taken for a leftover.
        let name = UUID().uuidString
        sendFoldersMade.note(name)
        let folder = Self.sendParent(in: sendTempRoot).appendingPathComponent(name, isDirectory: true)
        var prepared: PreparedSend?
        do {
            try Self.makeSendParent(in: sendTempRoot)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            sendSession?.folders.append(folder)
        } catch {
            // Said plainly, not as the system says it.
            alert = SendText.noTemporaryFolder
            busyLabel = nil
            return nil
        }
        do {
            let options = SendOptions(squareCover: storedSendSquareCover && check.coverIsSquare == false)
            let made = try await worker.prepareSend(for: check, options: options, in: folder)
            sendSession?.coversNotSquared = made.coversNotSquared
            prepared = made
        } catch {
            show(error)
        }
        // Nothing in the library was changed, so there is nothing to read again.
        busyLabel = nil
        return prepared
    }

    /// PH23: makes what is sent and returns it, as the one item for the system's
    /// sharing to take. Empty when the book cannot be sent now, or the item could not
    /// be made (`alert` says why).
    ///
    /// The item may be the library's own file. It stays where it is until the sheet
    /// closes, whatever the sharing does with it.
    public func shareItems() async -> [URL] {
        guard sendSheet?.canShare == true, let prepared = await prepareSend() else { return [] }
        sendSession?.sharing = prepared.fingerprint
        return [prepared.file]
    }

    /// PH23: the system could not share what `shareItems` gave it in the way that was
    /// asked for. Nothing is recorded.
    public func shareUnavailable(_ share: UnavailableShare) async {
        guard sendSession?.sharing != nil else { return }
        await shareFinished(completed: false)
        switch share {
        case .airDrop: alert = SendText.airDropUnavailable
        }
    }

    /// PH23: the system's sharing is done with what `shareItems` last gave it. When it
    /// went through, the send is recorded; otherwise nothing is.
    public func shareFinished(completed: Bool) async {
        guard let session = sendSession, let fingerprint = session.sharing else { return }
        sendSession?.sharing = nil
        guard completed else { return }
        sendSession?.shared = true
        await recordSend(of: session.bookId, method: .share, fingerprint: fingerprint, with: worker)
    }

    /// Records a send, and shows its date in the inspector (PH29).
    private func recordSend(
        of bookId: Int64, method: SendMethod, fingerprint: SendFingerprint, with worker: LibraryWorker?
    ) async {
        guard let worker else { return }
        do {
            try await worker.recordSent(bookId: bookId, method: method, fingerprint: fingerprint, at: inboxNow())
        } catch {
            show(error)
            return
        }
        // The library that was sent from may have been closed meanwhile.
        if worker === self.worker { await refreshInspector() }
    }

    // MARK: PH24 The link

    /// PH24: makes what is sent, starts a link to it and shows the link. Does nothing
    /// while a link is showing that has not expired or failed, or when the Mac has no
    /// address on a local network. A link that cannot be started shows none, and
    /// `alert` says why.
    public func showPhoneLink() async {
        guard let session = sendSession, busyLabel == nil else { return }
        if let link = session.link {
            // PH24: only in place of a link that is gone without the book having been sent.
            guard link.phase.isGoneUnsent else { return }
            sendSession?.link = nil
        }
        // The Mac may have joined or left a network since the sheet opened.
        readSendNetwork()
        guard sendSheet?.canShowLink == true, let prepared = await prepareSend() else { return }
        do {
            let offer = try phoneLink.start(
                file: prepared.file, fileName: prepared.file.lastPathComponent, now: inboxNow()
            ) { [weak self] event in
                self?.phoneLinkReported(event)
            }
            sendSession?.link = SendSession.Link(
                text: offer.bookPlayerLink.absoluteString, fingerprint: prepared.fingerprint)
        } catch {
            // The server's own errors are plain sentences, and none holds the link.
            alert = (error as? PhoneLinkError)?.errorDescription ?? UserMessage.text(for: error)
        }
    }

    /// PH24, PH25: what happened to the link that is showing.
    private func phoneLinkReported(_ event: PhoneLinkEvent) {
        guard let session = sendSession, var link = session.link else { return }
        switch event {
        case .started(let bytesTotal):
            link.bytesTotal = bytesTotal
            link.phase = .sending(0)
            keepAwake(true)
        case .progress(let bytesSent):
            link.phase = .sending(bytesSent)
            keepAwake(true)
        case .interrupted:
            link.phase = .waiting
            keepAwake(false)
        case .finished:
            link.phase = .finished
            keepAwake(false)
            let worker = worker
            spawn {
                await self.recordSend(
                    of: session.bookId, method: .link, fingerprint: link.fingerprint, with: worker)
            }
        case .expired:
            link.phase = .expired
            keepAwake(false)
        case .failed(let why):
            link.phase = .failed(why)
            keepAwake(false)
        }
        sendSession?.link = link
    }

    /// PH25: keeps the Mac awake, or lets it sleep again. Asked for what already is, it
    /// does nothing.
    private func keepAwake(_ awake: Bool) {
        guard awake != sendKeepsAwake else { return }
        sendKeepsAwake = awake
        if awake {
            sleepGuard.begin(reason: SendText.keepAwakeReason)
        } else {
            sleepGuard.end()
        }
    }

    // MARK: PH26 Closing

    /// PH26: stops any link, lets the Mac sleep, removes what was made to be sent and
    /// closes the sheet. Not while the sheet is in the middle of something.
    public func cancelSendToPhone() async {
        guard sendSession != nil, busyLabel == nil else { return }
        endSend()
        // PH28: files the app was asked to open meanwhile.
        importHeldFiles()
    }

    /// PH26: ends the open send at once: for Cancel, and for when the library is closed
    /// or changed or the app quits. Does nothing when no send is open.
    func endSend() {
        guard let session = sendSession else { return }
        if session.link != nil { phoneLink.stop() }
        keepAwake(false)
        sendSession = nil
        let fm = FileManager.default
        // Only ever the folders made here: what was sent may be a file of the library.
        for folder in session.folders where Self.isSendFolder(folder, in: sendTempRoot) {
            try? fm.removeItem(at: folder)
        }
    }

    /// Whether `folder` is a temporary folder of a send: a folder itself, directly in
    /// the parent folder in `root`, which is a folder itself too.
    nonisolated static func isSendFolder(_ folder: URL, in root: URL) -> Bool {
        let parent = sendParent(in: root)
        return folder.deletingLastPathComponent().standardizedFileURL.path == parent.standardizedFileURL.path
            && isRealFolder(parent) && isRealFolder(folder)
    }

    /// PH26: starts removing the temporary folders an earlier run of the app left behind
    /// (it crashed, or was stopped, with a send open), and does not wait: it runs on its
    /// own, at low priority, and nothing the window shows depends on it.
    ///
    /// Only VoxCarrel's own parent folder is listed, never the temporary folder it is
    /// in. Folders made by this run are left alone, whenever they are made.
    func startSendCleanup() {
        let root = sendTempRoot
        let made = sendFoldersMade
        let before = beforeSendCleanup
        sendCleanup = Task.detached(priority: .utility) {
            await before?()
            Self.removeLeftoverSendFolders(in: root, keeping: made)
        }
    }

    /// Removes every folder directly inside the parent folder in `root` that this run
    /// did not make. Does nothing when the parent is not a folder itself (a link, a
    /// file, or not there). Files and links inside it are left as they are.
    nonisolated static func removeLeftoverSendFolders(in root: URL, keeping made: SendFolderNames) {
        let parent = sendParent(in: root)
        guard isRealFolder(parent) else { return }
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] {
            let folder = parent.appendingPathComponent(name, isDirectory: true)
            // Asked at the last moment: a send may have begun since the folder was listed.
            guard !made.contains(name), isSendFolder(folder, in: root) else { continue }
            try? fm.removeItem(at: folder)
        }
    }
}

/// Why no temporary folder could be made for a send.
enum SendFolderError: Error {
    /// Something that is not a folder has the name of VoxCarrel's folder of packages.
    case parentIsNotAFolder
}

/// The names of the temporary folders this run of the app has made for sends, shared
/// with the clean-up of earlier runs' leftovers so that it never takes one of them.
final class SendFolderNames: @unchecked Sendable {
    private let lock = NSLock()
    private var names = Set<String>()

    func note(_ name: String) {
        lock.withLock { _ = names.insert(name) }
    }

    func contains(_ name: String) -> Bool {
        lock.withLock { names.contains(name) }
    }
}

extension BookDetail {
    /// PH29: "Sent to phone 23 Nov" for a book that has been sent; nil for one that has not.
    public func sentToPhoneText(
        now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current
    ) -> String? {
        lastSent.map { SendText.sentLine($0, now: now, locale: locale, timeZone: timeZone) }
    }
}
