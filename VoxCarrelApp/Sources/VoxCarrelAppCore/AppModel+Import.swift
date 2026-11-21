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

    /// - Parameter untracked: True when the files are those the launch check found
    ///   loose in the library folder.
    private func beginImport(_ urls: [URL], untracked: Bool) async {
        guard !urls.isEmpty, review == nil, let worker = await begin("Reading files…") else { return }
        do {
            let scan = try await untracked ? worker.prepareImport(untracked: urls) : worker.prepareImport(urls)
            if scan.seeds.isEmpty {
                alert = Self.nothingFound(skipped: scan.skipped.count)
            } else {
                // Files that are in the library already are moved into place: a copy
                // would leave the originals behind to be found again at the next launch.
                let files = scan.seeds.flatMap(\.candidate.files).map(\.url)
                let moveOnly = await worker.areInsideLibrary(files)
                let opened = ImportReview(
                    seeds: scan.seeds, skipped: scan.skipped, copyInsteadOfMove: copyOnImport, moveOnly: moveOnly)
                review = opened
                reviewBeganCopying = opened.copyInsteadOfMove
                reviewIsOfUntracked = untracked
                await fillDestinations()
            }
            // Reading changes nothing in the library, so there is nothing to reload.
            busyLabel = nil
        } catch {
            show(error)
            await finish()
        }
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
            guard let metadata = review?.entries.first(where: { $0.id == id })?.candidate.metadata else { continue }
            let folder = await worker.plannedFolder(for: metadata)
            // Ignored by the review if the entry's details have changed again meanwhile.
            review?.setDestination(folder, for: id, matchingMetadata: metadata)
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
        // with; a review that could only move says nothing about that choice.
        if review.offersCopy, review.copyInsteadOfMove != reviewBeganCopying {
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
            && check.strandedFiles.isEmpty
        libraryCheck = nothingLeft ? nil : check
    }
}
