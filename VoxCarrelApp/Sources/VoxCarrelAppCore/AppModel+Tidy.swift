import Foundation
import VoxCarrelCore

// The Tidy list: what is untidy about the library, found across all of it. Each check
// that finds something is a line of the sidebar; choosing it lists its books in the
// ordinary list, where every command for books applies to them. A book that is fine
// as it is can be let off a check, and is then no longer listed under it.

/// What is said above the books of one check.
public struct TidyHeader: Equatable, Sendable {
    public var title: String
    /// What the check means and what can be done about it.
    public var explanation: String
    /// "12 books", or "1 book".
    public var countText: String
    /// Whether the selected books can be let off the check now.
    public var canMarkFine: Bool
    public let markFineTitle = "These Are Fine as They Are"
    public let markFineHelp = "Stop listing the selected books under this check"
}

extension AppModel {
    /// The check the sidebar shows; nil when it shows anything else.
    var selectedTidyCheck: TidyCheck? {
        if case .tidy(let check) = sidebarSelection { return check }
        return nil
    }

    /// Whether the sidebar has anything to list under Tidy.
    public var showsTidy: Bool { !sidebar.tidy.isEmpty }

    /// How many books all the checks find between them, a book counted once for each
    /// check that finds it.
    public var tidyCount: Int { sidebar.tidy.reduce(0) { $0 + $1.count } }

    /// What is said above the books while a check is what the sidebar shows.
    public var tidyHeader: TidyHeader? {
        guard let check = selectedTidyCheck else { return nil }
        let count = rows.count
        let chosen = selection.filter { $0 > 0 }
        return TidyHeader(
            title: check.title, explanation: check.explanation,
            countText: count == 1 ? "1 book" : "\(count) books",
            canMarkFine: !chosen.isEmpty && busyLabel == nil && isLibraryOpen)
    }

    /// Lets the selected books off the check shown: they are no longer listed under
    /// it. Nothing about the books changes.
    public func markSelectionFine() async {
        guard let check = selectedTidyCheck, tidyHeader?.canMarkFine == true else { return }
        let ids = selection.filter { $0 > 0 }.sorted()
        await perform("Updating…") { worker in
            try await worker.setTidyIgnored(true, check: check, bookIds: ids)
        }
        // A check that finds nothing more has no line to stay on.
        if !sidebar.tidy.contains(where: { $0.check == check }) { sidebarSelection = .allBooks }
    }
}
