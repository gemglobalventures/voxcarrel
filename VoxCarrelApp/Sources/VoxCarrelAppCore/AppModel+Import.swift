import Foundation
import VoxCarrelCore

extension AppModel {
    /// A19: scans what was dropped or chosen and opens the review. Does nothing while a
    /// review is already open.
    ///
    /// Q13: only files and folders are taken; a link (dragged from a browser, say) is not.
    public func beginImport(_ urls: [URL]) async {
        await beginImport(urls.filter(\.isFileURL), untracked: false)
    }

    /// A26: the app has been asked to open these files and folders, by a drop on its
    /// Dock icon or from the Finder: they are imported like files dropped on the window.
    ///
    /// The user is not looking at the window, so nothing is refused without a word.
    /// Before the library has been opened, and while an operation runs, the files are
    /// held and imported when that is over. With no library open, or with an import
    /// already being reviewed, they are not taken and `alert` says what to do.
    public func openFiles(_ urls: [URL]) async {
        // Q13
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        // FL8: nor while a change of folder layout is previewed.
        // PH28: nor while Send to Phone is open.
        guard hasTriedLibrary, busyLabel == nil, layoutPreview == nil, sendSession == nil else {
            heldFiles += files
            return
        }
        guard isLibraryOpen else {
            alert = status == .notChosen ? Self.openedWithNoLibraryChosen : Self.openedWithLibraryNotOpen
            return
        }
        guard review == nil else {
            alert = Self.openedDuringReview
            return
        }
        // FL12
        guard !layoutChangeIsUnresolved else {
            alert = Self.openedWhileLayoutUnresolved
            return
        }
        await beginImport(files)
    }

    static let openedWithNoLibraryChosen =
        "Choose a library folder first, then open the files with VoxCarrel again."
    static let openedWithLibraryNotOpen =
        "The library is not open, so nothing was imported. Open the files with VoxCarrel again when it is."
    static let openedWhileLayoutUnresolved =
        "Nothing can be imported until the interrupted change of folder layout is resolved. "
        + "Open the library again to see what can be done."
    static let openedDuringReview =
        "Finish or cancel the import you are reviewing, then open the files with VoxCarrel again."

    /// A26: takes up the held files again, now that the library has been looked for or
    /// an operation has ended.
    func importHeldFiles() {
        guard !heldFiles.isEmpty else { return }
        spawn {
            let files = self.heldFiles
            self.heldFiles = []
            await self.openFiles(files)
        }
    }

    /// - Parameter untracked: True when the files are those the launch check found
    ///   loose in the library folder.
    private func beginImport(_ urls: [URL], untracked: Bool) async {
        // FL12: the import itself would be refused.
        guard !urls.isEmpty, review == nil, !layoutChangeIsUnresolved,
              let worker = await begin("Reading files…")
        else { return }
        do {
            let scan = try await untracked ? worker.prepareImport(untracked: urls) : worker.prepareImport(urls)
            if scan.seeds.isEmpty {
                alert = Self.nothingFound(skipped: scan.skipped.count)
            } else {
                // Files that are in the library already are moved into place: a copy
                // would leave the originals behind to be found again at the next launch.
                let files = scan.seeds.flatMap(\.candidate.files).map(\.url)
                let moveOnly = await worker.areInsideLibrary(files)
                reviewIsOfUntracked = untracked
                await openReview(
                    ImportReview(
                        seeds: scan.seeds, skipped: scan.skipped, copyInsteadOfMove: copyOnImport,
                        moveOnly: moveOnly))
            }
            // Reading changes nothing in the library, so there is nothing to reload.
            busyLabel = nil
        } catch {
            show(error)
            await finish()
        }
    }

    /// Shows a review that has just been made, and works out where its books would be filed.
    func openReview(_ opened: ImportReview) async {
        var opened = opened
        // FP20: the review marks and words its books by the library's own folder pattern.
        if let pattern = try? await worker?.folderPattern() { opened.folderPattern = pattern }
        review = opened
        reviewBeganCopying = opened.copyInsteadOfMove
        await fillDestinations()
    }

    private static func nothingFound(skipped: Int) -> String {
        let found = "No audiobooks or ebooks were found."
        switch skipped {
        case 0: return found
        case 1: return found + " 1 item was skipped because VoxCarrel cannot import it."
        default: return found + " \(skipped) items were skipped because VoxCarrel cannot import them."
        }
    }

    /// Changes the review. A20: the folders of the entries the change affects are worked
    /// out again, and arrive a moment later.
    public func updateReview(_ change: (inout ImportReview) -> Void) {
        guard var changed = review else { return }
        change(&changed)
        review = changed
        spawn { await self.fillDestinations() }
    }

    /// A20, A23: first which library book each changed entry matches, since an entry
    /// that joins a book has that book's folder; then the folders of the rest.
    ///
    /// R9: a matched book that has no files yet (it is on Audible only) is in no folder:
    /// the folder it will be filed in is worked out from its own details, and from the
    /// files for what those lack.
    private func fillDestinations() async {
        guard let worker else { return }
        for id in review?.entriesNeedingMatch ?? [] {
            guard let metadata = review?.entries.first(where: { $0.id == id })?.candidate.metadata else { continue }
            guard let match = try? await worker.existingMatch(for: metadata) else {
                review?.setExistingMatch(nil, for: id, matchingMetadata: metadata)
                continue
            }
            // Ignored by the review if the entry's details have changed again meanwhile.
            review?.setExistingMatch(match, for: id, matchingMetadata: metadata)
        }
        for id in review?.entriesNeedingDestination ?? [] {
            guard let entry = review?.entries.first(where: { $0.id == id }) else { continue }
            let metadata = entry.candidate.metadata
            let hasAudio = entry.hasAudio
            // FP41: a folder that is another book's is not named: the import would refuse it.
            let planned = await worker.plannedNewFiling(for: metadata, hasAudio: hasAudio)
            // Ignored by the review if the entry's details or files have changed again meanwhile.
            review?.setDestination(
                planned.folder, for: id, matchingMetadata: metadata, hasAudio: hasAudio, refusal: planned.refusal)
        }
        for id in review?.entriesNeedingMatchDestination ?? [] {
            guard let entry = review?.entries.first(where: { $0.id == id }), let match = entry.existingMatch
            else { continue }
            // What the book lacks (an author, a series) it takes from these files.
            // FL14: a folder that is another book's is not named: the import would refuse it.
            let planned = await worker.plannedFirstFiling(for: match, firstFiles: entry.candidate.files)
            // Ignored by the review if the entry has another match by now.
            review?.setMatchDestination(planned.folder, for: id, matchedBook: match, refusal: planned.refusal)
        }
    }

    /// A21: imports the review's included books. Does nothing unless `review.canImport`.
    public func confirmImport() async {
        guard busyLabel == nil, worker != nil, let review, review.canImport else { return }
        let items = review.items()
        let titles = review.entries.filter(\.included).map(\.candidate.metadata.title)
        let options = review.options
        let wasOfUntracked = reviewIsOfUntracked
        self.review = nil
        reviewIsOfUntracked = false
        // Remembered when it is the user's choice, not merely what the review began
        // with; a review that could only move says nothing about that choice. Nor does
        // one from the Inbox (WF19): its tick began as its watch folder's setting.
        if review.offersCopy, !review.isFromInbox, review.copyInsteadOfMove != reviewBeganCopying {
            copyOnImport = review.copyInsteadOfMove
        }

        let label = items.count == 1 ? "Importing 1 book…" : "Importing \(items.count) books…"
        guard let worker = await begin(label) else { return }
        var imported = Set<Int64>()
        var summary: ResultSummary?
        do {
            let outcome = try await worker.importItems(items, options: options)
            for case .imported(let id, _) in outcome.outcomes { imported.insert(id) }
            for case .needsAttention(let id) in outcome.outcomes { imported.insert(id) }
            summary = UserMessage.summary(of: outcome, titles: titles)
            if wasOfUntracked {
                // A22: the files that are now a book's are no longer on offer.
                var taken = Set<String>()
                for (item, result) in zip(items, outcome.outcomes) {
                    if case .failed = result { continue }
                    taken.formUnion(item.candidate.files.map(\.url.standardizedFileURL.path))
                }
                forgetUntracked { taken.contains($0.standardizedFileURL.path) }
            }
            if review.isFromInbox {
                // WF20: not the files of a book that failed: it is still waiting.
                var taken: [URL] = []
                for (item, result) in zip(items, outcome.outcomes) {
                    if case .failed = result { continue }
                    taken += item.candidate.files.map(\.url)
                }
                await recordInboxImport(of: taken, with: worker)
            }
        } catch {
            show(error)
        }
        await reloadAll()
        // The imported books that are shown become the selection, unless that would
        // take the inspector away from unsaved edits.
        imported.formIntersection(rows.map(\.id))
        if !imported.isEmpty, !hasUnsavedChanges {
            applySelection(imported, anchor: nil)
            await latestInspectorRefresh?.value
        }
        if let summary, !summary.isClean { result = summary }
        busyLabel = nil
    }

    public func cancelImport() {
        review = nil
        reviewIsOfUntracked = false
    }

    /// A22: begins an import of the files the launch check found in the library folder
    /// that no book uses. They stay on the check until that import is confirmed.
    public func importUntracked() async {
        guard busyLabel == nil, worker != nil, review == nil,
              let check = libraryCheck, !check.untrackedFiles.isEmpty
        else { return }
        await beginImport(check.untrackedFiles, untracked: true)
    }

    /// Takes files off the launch check's list of those no book uses, and closes the
    /// check when nothing is left to tell.
    private func forgetUntracked(where isTaken: (URL) -> Bool) {
        guard var check = libraryCheck else { return }
        check.untrackedFiles.removeAll(where: isTaken)
        let nothingLeft = check.untrackedFiles.isEmpty && check.booksWithMissingFiles.isEmpty
            && check.strandedFiles.isEmpty && check.strandedFolders.isEmpty
        libraryCheck = nothingLeft ? nil : check
    }
}
