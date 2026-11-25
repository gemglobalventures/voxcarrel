import Foundation
import VoxCarrelCore

// Bringing in the Kindle library of the linked account. KI1 onwards.
//
// There is no link of Kindle's own: the list is read from Amazon's Kindle web reader
// with the link made for Audible, which is a link to the same Amazon account. Nothing
// is bought, changed or removed at Amazon by anything here.

extension AppModel {
    // MARK: Importing the library

    /// Whether the account's Kindle library can be brought in now: an account is
    /// linked, a library is open, nothing is running, no question is waiting, and no
    /// sheet of the window is up. One sheet at a time.
    public var canImportKindleLibrary: Bool {
        canImportAudibleLibrary
    }

    /// Opens Import Kindle Library, which reads the account's Kindle library at once.
    /// Nothing in this library changes until the owner chooses Import.
    public func beginKindleImport() {
        guard canImportKindleLibrary, let account = audibleAccount, let worker else { return }
        let session = KindleImportSession(model: self, account: account, worker: worker)
        kindleImport = session
        session.read()
    }

    public func closeKindleImport() {
        kindleImport?.stopReading()
        kindleImport = nil
    }

    // MARK: The Library menu

    public var kindleMenuTitle: String {
        "Import Kindle Library…"
    }

    // MARK: Covers

    /// Fetches, behind everything else, the covers of the books owned on Kindle that
    /// have none, from the addresses Amazon gave for them: its own image hosts only.
    ///
    /// - Parameter addresses: The cover's address for each Kindle ID, in capitals.
    func fetchKindleCovers(_ addresses: [String: URL], with worker: LibraryWorker) {
        guard !addresses.isEmpty else { return }
        fetchCovers(addresses, hosts: AudibleCoverDownload.amazonHosts, with: worker) { worker in
            try? await worker.kindleBooksWithoutCover()
        }
    }
}
