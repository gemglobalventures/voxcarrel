import Foundation
import VoxCarrelCore

extension AppModel {
    /// A19: scans what was dropped or chosen and opens the review. Does nothing while a
    /// review is already open.
    ///
    /// Q13: only files and folders are taken; a link (dragged from a browser, say) is not.
    public func beginImport(_ urls: [URL]) async {
        await beginImport(urls.filter(\.isFileURL), copying: copyOnImport)
    }

    private func beginImport(_ urls: [URL], copying: Bool) async {
        guard !urls.isEmpty, review == nil, let worker = await begin("Reading files…") else { return }
        do {
            let scan = try await worker.prepareImport(urls)
            if scan.seeds.isEmpty {
                alert = Self.nothingFound(skipped: scan.skipped.count)
            } else {
                review = ImportReview(seeds: scan.seeds, skipped: scan.skipped, copyInsteadOfMove: copying)
                reviewBeganCopying = copying
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

    /// A20
    private func fillDestinations() async {
        guard let worker else { return }
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
        self.review = nil
        // Remembered when it is the user's choice, not merely what the review began with.
        if review.copyInsteadOfMove != reviewBeganCopying { copyOnImport = review.copyInsteadOfMove }

        let label = items.count == 1 ? "Importing 1 book…" : "Importing \(items.count) books…"
        guard let worker = await begin(label) else { return }
        var imported = Set<Int64>()
        var summary: ResultSummary?
        do {
            let outcome = try await worker.importItems(items, options: options)
            for case .imported(let id, _) in outcome.outcomes { imported.insert(id) }
            for case .needsAttention(let id) in outcome.outcomes { imported.insert(id) }
            summary = UserMessage.summary(of: outcome, titles: titles)
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
    }

    /// A22: begins an import of the files the launch check found in the library folder
    /// that no book uses, and takes them off the check.
    public func importUntracked() async {
        guard busyLabel == nil, worker != nil, review == nil,
              var check = libraryCheck, !check.untrackedFiles.isEmpty
        else { return }
        let files = check.untrackedFiles
        check.untrackedFiles = []
        libraryCheck = check.booksWithMissingFiles.isEmpty && check.strandedFiles.isEmpty ? nil : check
        // They are inside the library already, so they are moved into place: a copy
        // would leave the originals behind to be found again at the next launch.
        await beginImport(files, copying: false)
    }
}
