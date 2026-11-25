import Foundation
import VoxCarrelCore

// Hidden books. HD1 onwards.
//
// A book the owner hides is left out of every list, count and search. Hidden books are
// seen again only in the Hidden list, which is in the sidebar while they are being
// shown: that is asked for in the View menu, and the owner proves who they are first.

extension AppModel {
    enum HiddenKeys {
        /// Set once the owner has been told where hidden books go.
        static let explained = "hiddenBooksExplained"
    }

    /// What is said the first time books are hidden, and never again.
    static let hiddenBooksExplanation =
        "Hidden books are left out of every list and search. To see them, choose View > Show Hidden Books…"

    /// What the system is given as the reason for its check: it says "VoxCarrel is
    /// trying to show hidden books".
    static let ownerCheckReason = "show hidden books"

    // MARK: The sidebar

    /// How many books the Hidden list has; zero while hidden books are not being shown,
    /// whatever the library holds.
    public var hiddenBookCount: Int {
        showsHiddenBooks ? sidebar.hiddenCount : 0
    }

    // MARK: Hide and Unhide

    /// Whether these books are all hidden ones that are shown: the command then
    /// brings them back.
    private func areHidden(_ ids: Set<Int64>) -> Bool {
        let chosen = rows.filter { ids.contains($0.id) }
        return !chosen.isEmpty && chosen.allSatisfy(\.book.isHidden)
    }

    /// What the command says for these books: "Unhide" in the Hidden list, "Hide"
    /// everywhere else.
    public func hideTitle(for ids: Set<Int64>) -> String {
        areHidden(ids) ? "Unhide" : "Hide"
    }

    /// Whether these books can be hidden, or brought back, now: they are books of the
    /// library that are shown, and nothing is running or in the way. Not while there
    /// are unsaved changes: the books leave the list, and the changes would go with them.
    public func canHide(_ ids: Set<Int64>) -> Bool {
        isLibraryOpen && !ids.isEmpty && !holdsMissing(ids) && busyLabel == nil && layoutPreview == nil
            && sendSession == nil && mergeSession == nil && !hasUnsavedChanges
            && rows.contains { ids.contains($0.id) }
    }

    /// Hides these books, or in the Hidden list brings them back. They leave the list
    /// that is shown, and are no longer selected. No file is touched, and it is not
    /// something Undo reverses.
    ///
    /// The first time ever that books are hidden, `alert` says where they have gone.
    public func toggleHidden(for ids: Set<Int64>) async {
        guard canHide(ids) else { return }
        let hiding = !areHidden(ids)
        let changing = rows.filter { ids.contains($0.id) && $0.book.isHidden != hiding }.map(\.id)
        guard !changing.isEmpty else { return }
        var done = false
        await perform("Updating…") { worker in
            try await worker.setHidden(hiding, for: changing)
            done = true
        }
        guard done else { return }
        // Whatever of them is still selected (they are no longer among the rows) is let go.
        let left = selection.subtracting(changing)
        if left != selection {
            applySelection(left, anchor: nil)
            await latestInspectorRefresh?.value
        }
        if hiding, !defaults.bool(forKey: HiddenKeys.explained) {
            defaults.set(true, forKey: HiddenKeys.explained)
            alert = Self.hiddenBooksExplanation
        }
    }

    public func toggleHiddenForSelection() async {
        await toggleHidden(for: selection)
    }

    // MARK: Showing hidden books

    /// The View menu's item: what choosing it would do now.
    public var hiddenBooksMenuTitle: String {
        showsHiddenBooks ? "Stop Showing Hidden Books" : "Show Hidden Books…"
    }

    /// Whether hidden books can be shown, or put out of sight again, now: a library is
    /// open, nothing is running, no question is waiting, no sheet of the window is up,
    /// and the owner is not being asked already. Not while there are unsaved changes:
    /// either way the list that is shown changes.
    public var canToggleHiddenBooks: Bool {
        isLibraryOpen && busyLabel == nil && storedPrompt == nil && !isCheckingOwner && !hasUnsavedChanges
            && windowSheet(progressDue: false) == nil
    }

    /// Shows the hidden books once the owner has proved who they are, or stops showing them.
    public func toggleHiddenBooks() async {
        if showsHiddenBooks {
            await stopShowingHiddenBooks()
        } else {
            await showHiddenBooks()
        }
    }

    /// Asks the owner to prove who they are (Touch ID, or the Mac's password), then
    /// puts the Hidden list in the sidebar and selects it, with no search in the way.
    /// On a Mac that cannot ask (it has no password) they are shown without. A check
    /// that is cancelled or fails shows nothing, and says nothing.
    public func showHiddenBooks() async {
        guard canToggleHiddenBooks, !showsHiddenBooks, let asked = worker else { return }
        isCheckingOwner = true
        let result = await ownerCheck.confirm(reason: Self.ownerCheckReason)
        isCheckingOwner = false
        // The answer is for the library that was open when it was asked for.
        guard result != .refused, worker === asked else { return }
        showsHiddenBooks = true
        searchText = ""
        sidebarSelection = .hidden
        await latestReload?.value
    }

    /// Takes the Hidden list out of the sidebar. When it was the list shown, All Books
    /// is shown in its place, and no hidden book is left selected or in the inspector.
    public func stopShowingHiddenBooks() async {
        guard showsHiddenBooks, canToggleHiddenBooks else { return }
        showsHiddenBooks = false
        guard sidebarSelection == .hidden || shown.item == .hidden else { return }
        // At once, before the library has answered: nothing of a hidden book stays in view.
        applySelection([], anchor: nil)
        forgetShownRows()
        sidebarSelection = .allBooks
        await latestReload?.value
        await latestInspectorRefresh?.value
    }
}
