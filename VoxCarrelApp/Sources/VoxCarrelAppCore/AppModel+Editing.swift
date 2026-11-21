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
        // Edits that were written are the book's own values now. Edits that were not
        // stay in the draft, to be tried again or discarded.
        var everyBookSaved = false
        do {
            let outcomes = try await worker.save(edits)
            let titles = Dictionary(edits.map { ($0.bookId, $0.metadata.title) }) { first, _ in first }
            let summary = UserMessage.summary(of: outcomes, titles: titles)
            if !summary.isClean { result = summary }
            everyBookSaved = !outcomes.contains {
                if case .failed = $0 { true } else { false }
            }
        } catch {
            show(error)
        }
        await finish(keepEdits: !everyBookSaved)
    }

    /// Puts the draft back to the book's own values.
    public func discardChanges() {
        switch inspecting {
        case .nothing: break
        case .one(let detail, _): inspecting = .one(detail, BookDraft(book: detail.row.book))
        case .many(let draft): inspecting = .many(BulkDraft(books: draft.books))
        }
        // A book that was kept selected only for its unsaved edits is let go.
        let shownIds = selection.intersection(rows.map(\.id))
        if shownIds != selection { applySelection(shownIds, anchor: nil) }
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

extension AppModel {
    // MARK: Covers

    /// A12: makes the image in this file the draft's cover. Only a JPEG or PNG is taken.
    public func setCover(from url: URL) {
        guard case .one = inspecting else { return }
        let name = "\"\(url.lastPathComponent)\""
        guard let data = try? Data(contentsOf: url) else {
            alert = "\(name) could not be read."
            return
        }
        setCover(data, called: name)
    }

    /// A12: the same for image data, as dropped or pasted.
    public func setCover(data: Data) {
        setCover(data, called: "That image")
    }

    private func setCover(_ data: Data, called name: String) {
        guard case .one = inspecting else { return }
        // Judged by its bytes, whatever the file is called.
        guard let mime = CoverImage.sniffedMIME(data), mime == "image/jpeg" || mime == "image/png" else {
            alert = "\(name) is not a JPEG or PNG image, so it cannot be used as a cover."
            return
        }
        updateDraft { $0.cover = .set(CoverImage(data: data, mime: mime)) }
    }

    /// A12. For a book that has no cover this only takes back a cover just chosen.
    public func removeCover() {
        guard case .one(let detail, _) = inspecting else { return }
        let hasCover = detail.row.coverURL != nil
        updateDraft { $0.cover = hasCover ? .remove : .keep }
    }

    // MARK: Changes made at once

    public func setRole(_ role: FileRole, forFile id: Int64) async {
        await perform("Changing file…") { worker in
            try await worker.setRole(role, forFile: id)
        }
    }

    /// Writes the selected books' details into their files again.
    public func rewriteTags() async {
        await rewriteTags(for: selection)
    }

    /// The same for these books, which need not be the selection.
    public func rewriteTags(for ids: Set<Int64>) async {
        let ids = ordered(ids)
        guard !ids.isEmpty else { return }
        let titles = Dictionary(rows.map { ($0.id, $0.book.title) }) { first, _ in first }
        await perform("Rewriting tags…") { worker in
            let summary = UserMessage.summary(of: try await worker.rewriteTags(for: ids), titles: titles)
            if !summary.isClean { self.result = summary }
        }
    }

    /// Uses the file at `url` in place of a file that has gone missing.
    public func locate(fileId: Int64, at url: URL) async {
        await perform("Locating file…") { worker in
            try await worker.locateFile(fileId: fileId, at: url)
        }
    }

    /// Dated now.
    public func setReadStatus(_ status: ReadStatus, for ids: Set<Int64>) async {
        let ids = ordered(ids)
        guard !ids.isEmpty else { return }
        await perform("Updating…") { worker in
            try await worker.setReadStatus(status, for: ids)
        }
    }

    // MARK: Removing

    /// A15: asks whether to remove these books (those of them that are shown).
    public func requestRemove(_ ids: Set<Int64>) {
        guard busyLabel == nil, worker != nil else { return }
        let books = rows.filter { ids.contains($0.id) }
        guard !books.isEmpty else { return }
        storedPrompt = .removeBooks(ids: books.map(\.id), titles: books.map(\.book.title))
    }

    /// A15: the answer to `.removeBooks`. The files go to the Trash, or stay where they are.
    public func confirmRemove(moveFilesToTrash: Bool) async {
        guard busyLabel == nil, case .removeBooks(let ids, let titles) = storedPrompt else { return }
        storedPrompt = nil
        await perform(ids.count == 1 ? "Removing book…" : "Removing \(ids.count) books…") { worker in
            let failures = await worker.removeBooks(ids: ids, moveFilesToTrash: moveFilesToTrash)
            guard !failures.isEmpty else { return }
            let titleOf = Dictionary(zip(ids, titles)) { first, _ in first }
            let removed = ids.count - failures.count
            let failed = "\(failures.count)\(removed > 0 ? "" : Self.books(failures.count)) could not be removed"
            self.result = ResultSummary(
                headline: removed > 0 ? "\(removed)\(Self.books(removed)) removed, \(failed)" : failed,
                problems: failures.map { failure in
                    .init(title: titleOf[failure.id]?.trimmedOrNil ?? "Untitled book", detail: failure.reason)
                },
                isClean: false)
        }
    }

    private static func books(_ count: Int) -> String {
        count == 1 ? " book" : " books"
    }

    // MARK: Opening and revealing

    /// A14: opens the audiobook if the book has one, otherwise the ebook.
    public func open(_ id: Int64) {
        spawn { await self.openFile(of: id, role: nil) }
    }

    public func listen(_ id: Int64) {
        spawn { await self.openFile(of: id, role: .audio) }
    }

    public func read(_ id: Int64) {
        spawn { await self.openFile(of: id, role: .ebook) }
    }

    private func openFile(of id: Int64, role: FileRole?) async {
        guard let worker else { return }
        do {
            guard let detail = try await worker.detail(bookId: id) else { throw LibraryError.bookNotFound(id) }
            let file: FileRow?
            let none: String
            switch role {
            case .audio?:
                file = detail.files.first { $0.file.role == .audio }
                none = "This book has no audiobook file."
            case .ebook?:
                file = detail.files.first { $0.file.role == .ebook }
                none = "This book has no ebook file."
            default:
                file = detail.files.first { $0.file.role == .audio } ?? detail.files.first { $0.file.role == .ebook }
                none = "This book has no audiobook or ebook file to open."
            }
            guard let file else {
                alert = none
                return
            }
            guard !file.isMissing else {
                alert = "\"\(file.name)\" cannot be found. It was expected here: \(file.url.path)"
                return
            }
            opener.open(file.url)
        } catch {
            show(error)
        }
    }

    /// A14: shows each book in the Finder: its folder, or for a book left where it was
    /// found, its first file.
    public func reveal(_ ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        spawn { await self.revealBooks(self.ordered(ids)) }
    }

    public func reveal(file: FileRow) {
        opener.reveal([file.url])
    }

    private func revealBooks(_ ids: [Int64]) async {
        guard let worker else { return }
        do {
            var urls: [URL] = []
            for id in ids {
                guard let detail = try await worker.detail(bookId: id) else { continue }
                if let folderPath = detail.row.book.folderPath {
                    urls.append(Self.folder(folderPath, of: detail.files, root: worker.libraryRoot))
                } else if let file = detail.files.first {
                    urls.append(file.url)
                }
            }
            if !urls.isEmpty { opener.reveal(urls) }
        } catch {
            show(error)
        }
    }

    /// Where a filed book's folder is. Worked out from one of its files when it has
    /// any, because their locations are spelled the way the catalogue spells the library
    /// folder, which may not be how `root` spells it.
    private static func folder(_ folderPath: String, of files: [FileRow], root: URL) -> URL {
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        for file in files where file.file.path.hasPrefix(prefix) {
            var url = file.url
            for _ in file.file.path.dropFirst(prefix.count).split(separator: "/") {
                url = url.deletingLastPathComponent()
            }
            return url
        }
        return folderPath.hasPrefix("/")
            ? URL(fileURLWithPath: folderPath, isDirectory: true)
            : root.appendingPathComponent(folderPath, isDirectory: true)
    }

    // MARK: Collections

    /// Makes a collection and puts these books in it. A blank name, or one another
    /// collection has, is refused with a sentence in `alert`.
    public func createCollection(name: String, adding ids: Set<Int64>) async {
        guard busyLabel == nil, worker != nil, let name = collectionName(name, for: nil) else { return }
        let ids = ordered(ids)
        await perform("Creating collection…") { worker in
            let collection = try await worker.createCollection(name: name)
            if let id = collection.id, !ids.isEmpty {
                try await worker.add(bookIds: ids, toCollection: id)
            }
        }
    }

    public func renameCollection(id: Int64, to name: String) async {
        guard busyLabel == nil, worker != nil, let name = collectionName(name, for: id) else { return }
        await perform("Renaming collection…") { worker in
            try await worker.renameCollection(id: id, to: name)
        }
    }

    /// The books stay in the library. If the collection is the one being looked at, the
    /// sidebar goes back to all books.
    public func deleteCollection(id: Int64) async {
        await perform("Deleting collection…") { worker in
            try await worker.deleteCollection(id: id)
        }
    }

    public func add(_ ids: Set<Int64>, toCollection id: Int64) async {
        let ids = ordered(ids)
        guard !ids.isEmpty else { return }
        await perform("Updating…") { worker in
            try await worker.add(bookIds: ids, toCollection: id)
        }
    }

    public func remove(_ ids: Set<Int64>, fromCollection id: Int64) async {
        let ids = ordered(ids)
        guard !ids.isEmpty else { return }
        await perform("Updating…") { worker in
            try await worker.remove(bookIds: ids, fromCollection: id)
        }
    }

    /// The name without the spaces around it; nil, with `alert` saying why, when it is
    /// blank or another collection (not `id`) already has it, ignoring case.
    private func collectionName(_ name: String, for id: Int64?) -> String? {
        guard let name = name.trimmedOrNil else {
            alert = "A collection needs a name."
            return nil
        }
        let taken = sidebar.collections.first { $0.id != id && $0.name.trimmed.lowercased() == name.lowercased() }
        if let taken {
            alert = "There is already a collection named \"\(taken.name)\"."
            return nil
        }
        return name
    }
}
