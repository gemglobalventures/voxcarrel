import Foundation
import VoxCarrelCore

// Linking an Audible account, and bringing its library in. AL10 onwards.
//
// The owner signs in on Amazon's own page, in their browser; the app never has the
// password. What the app keeps is the keys of a device registered with the account, in
// the Mac's Keychain. They let it read the account's library as the phone app can.
// Nothing is bought, changed or removed at Audible by anything here.

extension AppModel {
    // MARK: The link

    public var isAudibleLinked: Bool {
        audibleAccount != nil
    }

    /// "Linked as Ann's 2nd Audible for iPhone · United States"; nil when no account
    /// is linked.
    public var audibleAccountSummary: String? {
        guard let account = audibleAccount else { return nil }
        let device = account.deviceName?.trimmedOrNil ?? "an Audible device"
        return "Linked as \(device) · \(account.store.title)"
    }

    /// What the settings say while no account is linked.
    public var audibleSettingsText: String {
        "Link your Audible account to bring in the books you own there. You sign in on Amazon's own page; "
            + "VoxCarrel never sees your password."
    }

    /// Reads the linked account from where its keys are kept.
    func readAudibleKeys() {
        audibleAccount = audibleKeys.load()
    }

    /// Whether an account can be linked now: none is, nothing is running, no question
    /// is waiting, and no sheet of the window is up. It needs no library.
    public var canBeginAudibleLink: Bool {
        !isAudibleLinked && busyLabel == nil && storedPrompt == nil && windowSheet(progressDue: false) == nil
    }

    /// Opens Link Audible Account. Nothing is asked of Amazon by opening it.
    public func beginAudibleLink() {
        guard canBeginAudibleLink else { return }
        audibleLink = AudibleLinkSession(model: self)
    }

    public func closeAudibleLink() {
        audibleLink = nil
    }

    /// Keeps a newly linked account. Throws when its keys could not be kept.
    func keepAudibleAccount(_ account: AudibleAccount) throws {
        try audibleKeys.save(account)
        audibleAccount = account
    }

    // MARK: Unlinking

    public var canUnlinkAudible: Bool {
        // Nor while Import Highlights or Import Kindle Library is open: either may be
        // reading with the account's keys.
        isAudibleLinked && busyLabel == nil && storedPrompt == nil && audibleImport == nil && highlightsImport == nil
            && kindleImport == nil
    }

    /// Asks whether to unlink: `prompt` becomes `.unlinkAudible`. Nothing is done until
    /// `confirmUnlinkAudible`.
    public func unlinkAudible() {
        guard canUnlinkAudible, let account = audibleAccount else { return }
        raise(.unlinkAudible(deviceName: account.deviceName))
    }

    /// The answer "unlink" to `.unlinkAudible`: Amazon is asked to remove the device,
    /// and the keys are forgotten whatever it answers. When it did not confirm, `alert`
    /// says where the owner removes the device themselves.
    public func confirmUnlinkAudible() async {
        guard busyLabel == nil, case .unlinkAudible = storedPrompt, let account = audibleAccount else { return }
        storedPrompt = nil
        busyLabel = "Unlinking your Audible account…"
        await beforeOperation?()
        let confirmed = (try? await AudibleLink.unregister(account, transport: audibleTransport)) ?? false
        audibleKeys.remove()
        audibleAccount = nil
        busyLabel = nil
        if !confirmed { alert = UserMessage.audibleUnlinkNotConfirmed }
    }

    // MARK: Importing the library

    /// Whether the account's library can be brought in now: an account is linked, a
    /// library is open, nothing is running, no question is waiting, and no sheet of the
    /// window is up. One sheet at a time.
    public var canImportAudibleLibrary: Bool {
        isAudibleLinked && isLibraryOpen && busyLabel == nil && storedPrompt == nil
            && windowSheet(progressDue: false) == nil
    }

    /// Opens Import Audible Library, which reads the account's library at once.
    /// Nothing in this library changes until the owner chooses Import.
    public func beginAudibleImport() {
        guard canImportAudibleLibrary, let account = audibleAccount, let worker else { return }
        let session = AudibleImportSession(model: self, account: account, worker: worker)
        audibleImport = session
        session.read()
    }

    public func closeAudibleImport() {
        audibleImport?.stopReading()
        audibleImport = nil
    }

    // MARK: The Library menu

    /// The menu's one command: importing when an account is linked, and linking when
    /// none is, so that the way in can be found.
    public var audibleMenuTitle: String {
        isAudibleLinked ? "Import Audible Library…" : "Link Audible Account…"
    }

    public var canUseAudibleMenu: Bool {
        isAudibleLinked ? canImportAudibleLibrary : canBeginAudibleLink
    }

    public func audibleMenuCommand() {
        if isAudibleLinked { beginAudibleImport() } else { beginAudibleLink() }
    }

    // MARK: Covers

    /// How many covers are stored between one reading of the rows and the next.
    static let audibleCoversPerReload = 20

    /// Whether an address is one a cover may be fetched from: Amazon's own image
    /// hosts, over an encrypted connection.
    static func isAudibleCoverAddress(_ url: URL) -> Bool {
        AudibleCoverDownload.allows(url, hosts: AudibleCoverDownload.amazonHosts)
    }

    /// Fetches, one at a time and behind everything else, the covers of the books owned
    /// on Audible that have none, from the addresses Audible gave for them. A cover that
    /// cannot be had is passed over. It stops when another library is opened.
    ///
    /// - Parameter addresses: The cover's address for each Audible ID, in capitals.
    func fetchAudibleCovers(_ addresses: [String: URL], with worker: LibraryWorker) {
        fetchCovers(addresses, hosts: AudibleCoverDownload.amazonHosts, with: worker) { worker in
            (try? await worker.audibleBooksWithoutCover())?.map { ($0.bookId, [$0.asin.uppercased()]) }
        }
    }

    /// The same for any books owned elsewhere: a cover for each of the wanted books
    /// that has an address under one of its IDs, when the address is on one of `hosts`.
    ///
    /// - Parameter wanted: The books that have no cover, each with the IDs it is known
    ///   by where it is owned, in capitals; nil when they could not be read.
    func fetchCovers(
        _ addresses: [String: URL], hosts: [String], with worker: LibraryWorker,
        wanted: @escaping @Sendable (LibraryWorker) async -> [(bookId: Int64, itemIds: [String])]?
    ) {
        audibleCovers?.cancel()
        let fetch = audibleCoverFetch
        audibleCovers = Task { [weak self] in
            guard let wanted = await wanted(worker) else { return }
            var unseen = 0
            for (bookId, itemIds) in wanted {
                guard let url = itemIds.lazy.compactMap({ addresses[$0] }).first,
                      AudibleCoverDownload.allows(url, hosts: hosts)
                else { continue }
                guard !Task.isCancelled, self?.worker === worker else { return }
                guard let data = await fetch(url), data.count <= AudibleCoverDownload.limit,
                      let mime = CoverImage.sniffedMIME(data), mime == "image/jpeg" || mime == "image/png"
                else { continue }
                guard !Task.isCancelled, self?.worker === worker else { return }
                guard (try? await worker.setCoverIfNone(CoverImage(data: data, mime: mime), for: bookId)) == true
                else { continue }
                unseen += 1
                if unseen == Self.audibleCoversPerReload {
                    unseen = 0
                    await self?.showAudibleCovers(of: worker)
                }
            }
            if unseen > 0 { await self?.showAudibleCovers(of: worker) }
        }
    }

    /// Reads the rows again so that covers just stored are shown. While an operation
    /// runs it is left to that operation, which reads everything again when it ends.
    private func showAudibleCovers(of worker: LibraryWorker) async {
        guard self.worker === worker, busyLabel == nil, !Task.isCancelled else { return }
        await reloadAll()
    }
}

/// The download of one cover: nothing kept, no cookies, and no redirect followed.
enum AudibleCoverDownload {
    /// The most a cover may weigh, in bytes.
    static let limit = 5_000_000

    /// Amazon's own image hosts: where Audible's covers are.
    static let amazonHosts = ["media-amazon.com", "ssl-images-amazon.com"]
    /// Where the covers of highlighted books are: Amazon's hosts, and Readwise's own.
    static let highlightHosts = amazonHosts + ["readwise.io"]

    /// Whether an address is one a cover may be fetched from: one of these hosts, or
    /// a host within one, over an encrypted connection.
    static func allows(_ url: URL, hosts: [String]) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static let fetch: @Sendable (URL) async -> Data? = { url in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let (bytes, response) = try? await session.bytes(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              response.expectedContentLength <= Int64(limit)
        else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                // More than a cover: the rest is not waited for.
                if data.count > limit { return nil }
            }
        } catch {
            return nil
        }
        return data
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? { nil }
    }
}
