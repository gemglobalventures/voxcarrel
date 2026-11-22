import Foundation
import VoxCarrelCore

// Books owned on Audible (plan 6, Tasks 3 and 4). R7, R8; N1–N8.
//
// Marking a book changes only the catalogue: no file is opened, moved or written, and it
// is not an operation Undo reverses. Taking the mark away again is the way back. Adding
// an Audible book writes its stored cover and nothing else, and is not undone either:
// removing the book is the way back.

extension AppModel {
    // MARK: R8 Marking

    /// R8: marks these books as owned on Audible, or takes the mark away. Applied at
    /// once, with no Save, and unsaved edits are kept (as for read status).
    ///
    /// Marking gives each book that is not on Audible yet an Audible copy, as an
    /// audiobook, in the store of the settings, with the book's ASIN when it has one. A
    /// book that is marked already is left exactly as it is.
    ///
    /// Unmarking a book that has no files would leave an empty entry: it stays marked,
    /// and `alert` names it and says to remove it instead.
    public func setOnAudible(_ on: Bool, for ids: Set<Int64>) async {
        // SV7: a book the library does not have is added, not marked.
        guard !holdsMissing(ids) else { return }
        let ids = ordered(ids)
        guard !ids.isEmpty else { return }
        let store = audibleStore
        var refused: [Int64] = []
        await perform("Updating…") { worker in
            refused = try await worker.setOnAudible(on, for: ids, store: store)
        }
        guard !refused.isEmpty else { return }
        if refused.count == 1 {
            let title = rows.first { $0.id == refused[0] }?.book.title.trimmedOrNil
            let book = title.map { "“\($0)”" } ?? "This book"
            alert = "\(book) has no files, so it would vanish from the library. Remove it instead."
        } else {
            alert = "\(refused.count) books have no files, so they would vanish from the library. "
                + "Remove them instead."
        }
    }

    /// R8: whether the selected books can be marked or unmarked now: a library is open,
    /// there is a selection, and nothing is running.
    public var canMarkOnAudible: Bool {
        canMarkOnAudible(for: selection)
    }

    /// The same for these books: for a context menu.
    public func canMarkOnAudible(for ids: Set<Int64>) -> Bool {
        // SV7
        isLibraryOpen && busyLabel == nil && !ids.isEmpty && !holdsMissing(ids)
    }

    /// R8: what the menu item says: "Unmark as on Audible" when every selected book is
    /// on Audible already, "Mark as on Audible" otherwise.
    public var markOnAudibleTitle: String {
        markOnAudibleTitle(for: selection)
    }

    /// The same for these books: for a context menu.
    public func markOnAudibleTitle(for ids: Set<Int64>) -> String {
        areAllOnAudible(ids) ? "Unmark as on Audible" : "Mark as on Audible"
    }

    /// R8: does what `markOnAudibleTitle` says, for the selection.
    public func toggleOnAudible() async {
        await toggleOnAudible(for: selection)
    }

    /// The same for these books: for a context menu.
    public func toggleOnAudible(for ids: Set<Int64>) async {
        await setOnAudible(!areAllOnAudible(ids), for: ids)
    }

    /// True when there are books and every one of them is shown and on Audible.
    private func areAllOnAudible(_ ids: Set<Int64>) -> Bool {
        let chosen = rows.filter { ids.contains($0.id) }
        return !ids.isEmpty && chosen.count == ids.count && chosen.allSatisfy(\.isOnAudible)
    }

    // MARK: R7 The inspector

    /// R7: where the one inspected book is owned other than as files:
    /// "On Audible (United Kingdom) · not on this Mac". Nil when it is not on Audible,
    /// and when one book is not what is inspected.
    public var inspectorOwnershipText: String? {
        guard case .one(let detail, _) = inspecting else { return nil }
        return detail.ownershipText
    }

    /// R7: whether the inspector's "On Audible" switch is on: the one inspected book is
    /// marked. Changed with `setOnAudible`.
    public var inspectorIsOnAudible: Bool {
        guard case .one(let detail, _) = inspecting else { return false }
        return detail.row.isOnAudible
    }
}

extension AppModel {
    // MARK: Plan 6, V3–V5 What the screens say

    /// V4: what the Listen menu item says for these books: "Open on Audible" when there
    /// is one book and listening to it opens its page on the Audible website, "Listen"
    /// otherwise.
    public func listenTitle(for ids: Set<Int64>) -> String {
        let one = ids.count == 1 ? rows.first { ids.contains($0.id) } : nil
        return (one?.opensOnAudible ?? false) ? "Open on Audible" : "Listen"
    }

    /// V5: what the window's progress sheet says: what is being done, or nil when
    /// nothing is. Nil, too, while an Audible book is being added: the add sheet shows
    /// that itself and stays up until the book is in the library, so the progress sheet
    /// must not take its place.
    public var progressSheetLabel: String? {
        addAudibleLookup?.phase == .applying ? nil : busyLabel
    }
}

extension BookDetail {
    /// Plan 6, V3: what the inspector's Files section says of a book that has no files;
    /// nil for a book that has some.
    public var noFilesText: String? {
        row.hasFiles ? nil : "This book has no files on this Mac."
    }

    /// R7: "On Audible (United Kingdom)", with " · not on this Mac" for a book that has
    /// no files. The store is the one the book's Audible copy names; when it names none
    /// (or one this version does not know) no country is given. Nil for a book that is
    /// not on Audible.
    public var ownershipText: String? {
        guard let copy = row.book.externalCopies.first(where: { $0.kind == .audible }) else { return nil }
        var text = "On \(copy.kind.title)"
        if let store = copy.store.flatMap(AudibleStore.init(rawValue:)) { text += " (\(store.title))" }
        return row.hasFiles ? text : text + " · not on this Mac"
    }
}

extension AppModel {
    // MARK: N1 Beginning to add an Audible book

    /// N1: whether an Audible book can be added now: a library is open, nothing is
    /// running, and no question, sheet or unsaved edit is in the way. No selection is
    /// needed. (Unsaved edits are in the way because the added book becomes the selection.)
    /// A8b: nor while Audible is off as a lookup source (`addAudibleBookDisabledReason`).
    public var canAddAudibleBook: Bool {
        isQuietForLookup && lookupSources.contains(.audible) && review == nil && result == nil
            && libraryCheck == nil && seriesChoice == nil && !hasUnsavedChanges
    }

    /// N1: opens the lookup sheet for adding an Audible book: nothing to search for yet,
    /// and nothing is asked until the user searches. Only Audible is ever asked. Does
    /// nothing unless `canAddAudibleBook`.
    public func beginAddAudibleBook() {
        guard canAddAudibleBook else { return }
        open(LookupSession(target: .newAudibleBook, current: BookMetadata(), hasCover: false, hasAudio: true))
    }

    /// The lookup when it is for adding an Audible book: its sheet belongs to the window.
    public var addAudibleLookup: LookupSession? {
        lookup?.isAddMode == true ? lookup : nil
    }

    // MARK: N3 Adding

    static let addedWithoutCover = "The book was added, but its cover could not be downloaded."

    /// N3: the sheet's Add button. Adds the selected result to the library as a book that
    /// is on Audible and has no files here: with the result's details and cover, and an
    /// Audible copy with the result's ASIN, in the store that ASIN belongs to (A9: the
    /// stores searched each have their own). The sheet
    /// closes, and the book is selected; when it is not among the books shown, the
    /// sidebar moves to On Audible (and a search that still hides it is cleared).
    ///
    /// N4: when the library has the book already, that book is marked as also on Audible
    /// and selected, nothing else about it changes, and `alert` says so.
    ///
    /// A cover that cannot be downloaded does not stop the book being added; `alert`
    /// says it has none. Does nothing unless `lookup.canAdd`. While the book is being
    /// added `lookup.phase` is `.applying`; if the sheet closes meanwhile nothing is
    /// added, the cover's download is cancelled, and nothing is busy from that moment.
    public func addLookupSelection() async {
        guard let session = lookup, session.canAdd, let candidate = session.selected else { return }
        await addAudibleBook(candidate.metadata, coverOf: candidate, store: candidate.audibleStore ?? audibleStore)
    }

    /// N5: adds an Audible book from what is typed in the search boxes, with no result
    /// chosen: that title and author, the Audible ID when a well-formed one is typed
    /// (it is the book's ASIN and its copy's item ID), and no cover. Otherwise as
    /// `addLookupSelection`. Does nothing unless `lookup.canAddByHand`.
    public func addAudibleBookByHand() async {
        guard let session = lookup, session.canAddByHand else { return }
        var metadata = BookMetadata(
            title: session.query.title.trimmed, authors: session.query.author.trimmedOrNil.map { [$0] } ?? [])
        // An Audible ID typed in its box goes with the book when it is a well-formed one.
        metadata.asin = session.typedAudibleID
        await addAudibleBook(metadata, coverOf: nil, store: audibleStore)
    }

    private func addAudibleBook(
        _ metadata: BookMetadata, coverOf candidate: LookupCandidate?, store: AudibleStore
    ) async {
        guard busyLabel == nil, var session = lookup else { return }
        // N7: from here on nothing in the sheet can be changed, and Add does nothing.
        lookupSearch?.cancel()
        session.beginAdding()
        guard session.phase == .applying else { return }
        lookup = session
        let generation = lookupGeneration
        guard let worker = await begin("Adding book…") else {
            closeLookup()
            return
        }

        var cover: CoverImage?
        let hasCover = candidate?.coverURL != nil
        if let candidate, hasCover {
            // The row's picture, when it is the cover itself, has been fetched already.
            if let url = candidate.coverURL, let data = lookupThumbnails[url] {
                cover = Self.coverImage(data)
            } else {
                // N7: fetched in a task of its own, which closing the sheet cancels.
                let fetch = Task { try? await worker.lookupCover(for: candidate) }
                addCoverFetch = fetch
                cover = await fetch.value
                // N7: the sheet closed meanwhile, whatever is open or running now:
                // nothing is added, and closing it has already ended the operation.
                guard lookupGeneration == generation, lookup != nil, addCoverFetch == fetch else { return }
                addCoverFetch = nil
                // The cover could not be had: the smaller picture of it is better than none.
                if cover == nil, let data = cachedLookupThumbnail(for: candidate) { cover = Self.coverImage(data) }
            }
        }

        let asin = metadata.asin?.trimmedOrNil
        let copy = ExternalCopy(kind: .audible, form: .audio, store: store.rawValue, itemId: asin)
        var outcome: ExternalBookOutcome?
        do {
            outcome = try await worker.addExternalBook(metadata: metadata, cover: cover, copy: copy)
        } catch {
            show(error)
        }
        closeLookup()
        await reloadAll()
        if let outcome {
            let wasThere = await showAdded(outcome, with: worker)
            if !wasThere, hasCover, cover == nil { alert = Self.addedWithoutCover }
        }
        busyLabel = nil
    }

    /// An Audible book has been added, or found to be in the library already, and
    /// everything has been read again: the book becomes the selection, and when it was
    /// there already `alert` says so (N4). Returns whether it was there already.
    @discardableResult
    func showAdded(_ outcome: ExternalBookOutcome, with worker: LibraryWorker) async -> Bool {
        let id: Int64
        var said: String?
        switch outcome {
        case .added(let bookId): id = bookId
        case .markedExisting(let bookId): (id, said) = (bookId, "was already in your library. It is now marked as also on Audible.")
        case .alreadyMarked(let bookId): (id, said) = (bookId, "is already in your library and marked as on Audible.")
        }
        // The book becomes the selection, unless that would take the inspector away
        // from unsaved edits.
        if !hasUnsavedChanges {
            await show(book: id)
        }
        guard let said else { return false }
        // N4
        let title = try? await worker.detail(bookId: id)?.row.book.title.trimmedOrNil
        alert = "\(title.map { "“\($0)”" } ?? "That book") \(said)"
        return true
    }

    /// Selects the book, first making sure it is among the books shown: when it is not,
    /// the sidebar moves to On Audible, and a search that still hides it is cleared.
    func show(book id: Int64) async {
        if !rows.contains(where: { $0.id == id }) {
            sidebarSelection = .onAudible
            await latestReload?.value
        }
        if !rows.contains(where: { $0.id == id }), !searchText.isEmpty {
            searchText = ""
            await latestReload?.value
        }
        guard rows.contains(where: { $0.id == id }) else { return }
        applySelection([id], anchor: id)
        await latestInspectorRefresh?.value
    }
}
