import Foundation
import VoxCarrelCore

// A library's catalogue kept on this Mac, apart from its books. The books may be on a
// NAS, an external drive or a synced folder; with the catalogue here the library opens
// and can be looked through whether or not they can be reached. Moving it is the
// owner's choice, made in Settings, and a backup is taken first.

public enum CatalogueText {
    /// Said in the status bar while the books' drive is away.
    public static let awayMark = "Drive not connected"
    public static let heading = "Catalogue"
    public static let inFolder =
        "The catalogue is kept inside the library folder, with the books. If that folder is on a NAS, an external "
        + "drive or a synced folder, keep the catalogue on this Mac instead: the library then opens and can be "
        + "looked through while the drive is away, and a synced folder cannot damage it."
    public static let onMac =
        "The catalogue is kept on this Mac, apart from the books. The library opens and can be looked through "
        + "while the books' drive is away; anything that touches the files waits until it is back."
    public static let away =
        "The drive the books are on is not connected. The library is shown as it was left. It is opened afresh when "
        + "the drive comes back."
    public static let demo = "The demo library keeps its catalogue with its books."
    public static let catchingUpLabel = "Writing the changes made while the drive was away…"

    /// "3 books with changes waiting"
    public static func waiting(_ count: Int) -> String {
        count == 1 ? "1 book with changes waiting" : "\(count) books with changes waiting"
    }

    public static func waitingNote(_ count: Int) -> String {
        (count == 1 ? "1 book has" : "\(count) books have")
            + " changes that are in the catalogue and not yet in the files. They are written when the drive is back."
    }

    public static func caughtUp(_ result: HeldEditsResult) -> String {
        let done = result.caughtUp == 1
            ? "The changes made to 1 book while its drive was away are now in its files."
            : "The changes made to \(result.caughtUp) books while their drive was away are now in their files."
        return ([done] + result.problems).joined(separator: "\n")
    }
    public static let moveTitle = "Keep the Catalogue on This Mac…"
    public static let moveBackTitle = "Move It Back to the Library Folder…"
    public static let movingLabel = "Moving the catalogue…"
    public static let confirmMove = "Keep this library's catalogue on this Mac?"
    public static let confirmMoveMessage =
        "The catalogue and the covers are copied to this Mac, and the copy inside the library folder is set aside "
        + "there, not deleted. A backup is made first. No book is moved or changed. Other Macs that open this "
        + "folder will not see the catalogue: it is for a library used from this Mac."
    public static let confirmBack = "Move the catalogue back into the library folder?"
    public static let confirmBackMessage =
        "The catalogue and the covers are copied back beside the books and removed from this Mac. A backup is made "
        + "first. No book is moved or changed."
    public static let moveButton = "Move"
    public static let moved = "The catalogue is now kept on this Mac."
    public static let movedBack = "The catalogue is back inside the library folder."

    static func failure(_ error: Error) -> String {
        switch error as? CatalogueHome.Problem {
        case .booksNotReachable: "The drive the books are on is not connected, so the catalogue was not moved."
        case .alreadyThere: "The catalogue is already there."
        case .noCatalogue: "The catalogue could not be read, so it was not moved. Nothing was changed."
        case nil: "The catalogue could not be moved. \(UserMessage.text(for: error)) Nothing was changed."
        }
    }
}

extension AppModel {
    /// What Settings says of where the catalogue is.
    public var catalogueStatusText: String {
        if isShowingDemoLibrary { return CatalogueText.demo }
        let waiting = heldEditCount > 0 ? " " + CatalogueText.waitingNote(heldEditCount) : ""
        if libraryIsAway { return CatalogueText.away + waiting }
        return (catalogueIsOnMac ? CatalogueText.onMac : CatalogueText.inFolder) + waiting
    }

    /// Whether the catalogue can be moved now: a library that is not the demo is open,
    /// its books can be reached, nothing is running, and no edit is waiting.
    public var canMoveCatalogue: Bool {
        isLibraryOpen && !isShowingDemoLibrary && !libraryIsAway && canShowExtensionSheet && !hasUnsavedChanges
    }

    /// Moves the open library's catalogue to this Mac, or back inside its folder, and
    /// opens the library again. A backup is made first. One that cannot be moved says
    /// why in `alert`, and the library is opened as it was.
    public func moveCatalogue(toMac: Bool) async {
        guard canMoveCatalogue, toMac != catalogueIsOnMac, worker != nil, case .available(let root) = status else { return }
        busyLabel = CatalogueText.movingLabel
        // Held only for as long as the backup takes: nothing may hold the catalogue
        // while it is moved.
        if let open = worker {
            await backUpBefore(toMac ? "before move to mac" : "before move back", with: open)
        }
        self.worker = nil
        var failure: Error?
        do {
            try await Task.detached {
                if toMac {
                    try CatalogueHome.moveToMac(libraryAt: root, libraries: CatalogueHome.standardFolder)
                } else {
                    try CatalogueHome.moveBack(libraryAt: root, libraries: CatalogueHome.standardFolder)
                }
            }.value
        } catch {
            failure = error
        }
        busyLabel = nil
        await openLibrary()
        alert = failure.map(CatalogueText.failure) ?? (toMac ? CatalogueText.moved : CatalogueText.movedBack)
    }

    /// Writes into the files what was changed while their drive was away, when
    /// anything is waiting. Part of opening the library; what happened is said in `alert`.
    func catchUpHeldEdits(with worker: LibraryWorker) async {
        guard heldEditCount > 0, !libraryIsAway else { return }
        let was = busyLabel
        busyLabel = CatalogueText.catchingUpLabel
        let result = try? await worker.applyHeldEdits()
        busyLabel = was
        guard self.worker === worker else { return }
        await reloadAll()
        if let result, result.caughtUp > 0 || !result.problems.isEmpty { alert = CatalogueText.caughtUp(result) }
    }

    /// While the books' drive is away: looks for it every few seconds, and opens the
    /// library afresh when it is back, so that it is checked and everything is offered
    /// again. Stops when another library is opened.
    func waitForBooksToReturn(with worker: LibraryWorker) {
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: Self.awayPollNanoseconds)
                guard let self, self.worker === worker, self.libraryIsAway else { return }
                if await worker.booksAreReachable() {
                    // Not while something is being answered or edited: the next look will do.
                    guard self.busyLabel == nil, !self.hasUnsavedChanges, self.canShowExtensionSheet else { continue }
                    await self.openLibrary()
                    return
                }
            }
        }
    }

    /// How often a drive that is away is looked for. Tests make it short.
    nonisolated(unsafe) static var awayPollNanoseconds: UInt64 = 4_000_000_000
}
