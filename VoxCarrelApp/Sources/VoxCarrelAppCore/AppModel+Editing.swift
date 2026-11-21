import Foundation
import VoxCarrelCore

extension AppModel {
    // MARK: Drafts

    /// Changes the draft of the one selected book. Nothing is written until `save()`.
    public func updateDraft(_ change: (inout BookDraft) -> Void) {
        guard case .one(let detail, var draft) = inspecting else { return }
        change(&draft)
        inspecting = .one(detail, draft)
    }

    /// Changes the draft for the several selected books. Nothing is written until `save()`.
    public func updateBulkDraft(_ change: (inout BulkDraft) -> Void) {
        guard case .many(var draft) = inspecting else { return }
        change(&draft)
        inspecting = .many(draft)
    }

    public var hasUnsavedChanges: Bool {
        switch inspecting {
        case .nothing: false
        case .one(_, let draft): draft.isDirty
        case .many(let draft): draft.isDirty
        }
    }

    /// A10: writes the draft. A draft with a problem is not written; `alert` says what
    /// the first problem is.
    public func save() async {
        guard busyLabel == nil, worker != nil else { return }
        let edits: [BookEdit]
        switch inspecting {
        case .nothing:
            return
        case .one(_, let draft):
            guard draft.isDirty else { return }
            if let problem = draft.problems.first {
                alert = problem
                return
            }
            guard let edit = draft.makeEdit() else { return }
            edits = [edit]
        case .many(let draft):
            guard draft.isDirty else { return }
            if let problem = draft.problems.first {
                alert = problem
                return
            }
            guard let all = draft.makeEdits() else { return }
            edits = all
        }

        let label = edits.count == 1 ? "Saving…" : "Saving \(edits.count) books…"
        guard let worker = await begin(label) else { return }
        do {
            let outcomes = try await worker.save(edits)
            let titles = Dictionary(edits.map { ($0.bookId, $0.metadata.title) }) { first, _ in first }
            let summary = UserMessage.summary(of: outcomes, titles: titles)
            if !summary.isClean { result = summary }
        } catch {
            show(error)
        }
        await finish()
    }

    /// Puts the draft back to the book's own values.
    public func discardChanges() {
        switch inspecting {
        case .nothing: break
        case .one(let detail, _): inspecting = .one(detail, BookDraft(book: detail.row.book))
        case .many(let draft): inspecting = .many(BulkDraft(books: draft.books))
        }
    }

    /// A8: the answer to `.unsavedChanges`.
    public func resolveUnsaved(_ choice: UnsavedChoice) async {
        guard storedPrompt == .unsavedChanges else { return }
        let change = pending
        switch choice {
        case .cancel:
            cancelPending()
            storedPrompt = nil
        case .discard:
            pending = nil
            storedPrompt = nil
            discardChanges()
            await applyPending(change)
        case .save:
            storedPrompt = nil
            await save()
            if hasUnsavedChanges {
                // The save did not go through: the request is forgotten, as for Cancel.
                cancelPending()
            } else {
                pending = nil
                await applyPending(change)
            }
        }
    }
}
