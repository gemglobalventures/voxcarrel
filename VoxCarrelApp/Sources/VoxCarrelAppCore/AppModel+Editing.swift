import Foundation
import UniformTypeIdentifiers
import VoxCarrelCore

extension AppModel {
    // MARK: Drafts

    /// Changes the draft of the one selected book. Nothing is written until `save()`
    /// (or until a lookup is applied, which saves).
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

    /// Whether Save applies: there is something to save and nothing is running.
    public var canSave: Bool {
        isLibraryOpen && busyLabel == nil && hasUnsavedChanges
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
        // What is typed from here on was not sent, and is kept as unsaved when the save ends.
        sentDraft = inspecting
        defer { sentDraft = nil }
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

    /// The largest file taken as a cover.
    public static let coverSizeLimit = 50 * 1024 * 1024

    /// A12: makes the image in this file the draft's cover. Only a JPEG or PNG is taken.
    ///
    /// A file that is plainly not a picture (a book, a film) or is larger than
    /// `coverSizeLimit` is refused without being read. Anything else is read, off the
    /// main thread, and judged by its bytes. The cover goes to the book that was being
    /// inspected when it was asked for, and nowhere if another is inspected by then.
    public func setCover(from url: URL) async {
        guard case .one(let detail, _) = inspecting else { return }
        let id = detail.row.id
        let name = "\"\(url.lastPathComponent)\""
        guard !Self.isPlainlyNotAnImage(url) else {
            alert = Self.notAnImage(name)
            return
        }
        let limit = Self.coverSizeLimit
        let read = await Task.detached { () -> CoverFile in
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return .unreadable }
            guard size <= limit else { return .tooLarge }
            guard let data = try? Data(contentsOf: url) else { return .unreadable }
            return .read(data)
        }.value
        await beforeUsingCover?()
        guard case .one(let now, _) = inspecting, now.row.id == id else { return }
        switch read {
        case .unreadable: alert = "\(name) could not be read."
        case .tooLarge: alert = Self.tooLarge(name)
        case .read(let data): setCover(data, called: name)
        }
    }

    /// A12, X1: files dropped on the inspector's cover. One picture file becomes the
    /// draft's cover; anything else (a book, a folder, several files) is imported, as
    /// if it had been dropped anywhere else on the window.
    public func dropOnCover(_ urls: [URL]) async {
        let files = urls.filter(\.isFileURL)
        guard let first = files.first else { return }
        if files.count == 1, Self.isImageFile(first) {
            await setCover(from: first)
        } else {
            await beginImport(files)
        }
    }

    /// Whether the file's name says it is a picture.
    static func isImageFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    private enum CoverFile: Sendable {
        case unreadable, tooLarge
        case read(Data)
    }

    /// True for a file whose name says it is a book, sound, film or archive: the kind of
    /// file that is dropped on the cover by mistake, and far too big to read to find out.
    static func isPlainlyNotAnImage(_ url: URL) -> Bool {
        if FileFormat(url: url) != nil { return true }
        guard let type = UTType(filenameExtension: url.pathExtension), !type.isDynamic else { return false }
        return type.conforms(to: .audiovisualContent) || type.conforms(to: .archive)
            || type.conforms(to: .diskImage) || type.conforms(to: .executable)
    }

    private static func notAnImage(_ name: String) -> String {
        "\(name) is not a JPEG or PNG image, so it cannot be used as a cover."
    }

    private static func tooLarge(_ name: String) -> String {
        "\(name) is too large to be a cover. Choose an image smaller than 50 MB."
    }

    /// A12: the same for image data, as dropped or pasted.
    public func setCover(data: Data) {
        setCover(data, called: "That image")
    }

    private func setCover(_ data: Data, called name: String) {
        guard case .one = inspecting else { return }
        guard data.count <= Self.coverSizeLimit else {
            alert = Self.tooLarge(name)
            return
        }
        // Judged by its bytes, whatever the file is called.
        guard let mime = CoverImage.sniffedMIME(data), mime == "image/jpeg" || mime == "image/png" else {
            alert = Self.notAnImage(name)
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

    /// Repairs the wrong length headers in the selected books' files.
    public func repairLengthHeaders() async {
        await repairLengthHeaders(for: selection)
    }

    /// The same for these books, which need not be the selection. Does nothing when
    /// none of them has a file that can be repaired.
    public func repairLengthHeaders(for ids: Set<Int64>) async {
        let ids = ordered(ids)
        let files = rows.filter { ids.contains($0.id) }.map(\.repairableLengthFiles).reduce(0, +)
        guard !ids.isEmpty, files > 0 else { return }
        let titles = Dictionary(rows.map { ($0.id, $0.book.title) }) { first, _ in first }
        await perform(files == 1 ? "Repairing 1 file…" : "Repairing \(files) files…") { worker in
            let summary = UserMessage.repairSummary(
                of: try await worker.repairLengthHeaders(for: ids), titles: titles)
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
        raise(
            .removeBooks(
                ids: books.map(\.id), titles: books.map(\.book.title),
                outsideFiles: books.flatMap(\.outsideFiles),
                // R6: a book that is only owned elsewhere has nothing to send to the Trash.
                withoutFiles: books.filter { !$0.hasFiles }.count))
    }

    /// A15: asks whether to remove the selected books: for Delete in the grid or the list.
    public func requestRemoveSelection() {
        requestRemove(selection)
    }

    /// A15: the answer to `.removeBooks`. The files go to the Trash, or stay where they are.
    ///
    /// R6: a book with no files is only taken out of the library, whatever the answer:
    /// the Trash is for the books that have files.
    public func confirmRemove(moveFilesToTrash: Bool) async {
        guard busyLabel == nil, case .removeBooks(let ids, let titles, _, let withoutFiles) = storedPrompt
        else { return }
        storedPrompt = nil
        let moveFilesToTrash = moveFilesToTrash && withoutFiles < ids.count
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
    ///
    /// R4: a file here always comes first: the audiobook, else the ebook. Only a book
    /// with neither, that is on Audible as an audiobook, has its page on the Audible
    /// website opened in the browser. `listen` goes there whenever there is no audio
    /// file here.
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
            let audio = detail.files.first { $0.file.role == .audio }
            let ebook = detail.files.first { $0.file.role == .ebook }
            // R4: the audiobook is on Audible and not here. Listening goes there; plain
            // opening does only when there is no file here to open instead.
            if role != .ebook, audio == nil, role == .audio || ebook == nil, let copy = detail.row.audibleAudioCopy {
                opener.openWeb(audibleAddress(of: detail.row.book, copy: copy))
                return
            }
            let file: FileRow?
            var none: String
            switch role {
            case .audio?:
                file = audio
                none = "This book has no audiobook file."
            case .ebook?:
                file = ebook
                none = "This book has no ebook file."
            default:
                file = audio ?? ebook
                none = "This book has no audiobook or ebook file to open."
            }
            // Owned elsewhere, and not as something that can be opened from here.
            if role != .ebook, detail.files.isEmpty { none = "This book has no files on this Mac." }
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

    /// R4: the book's page on the Audible website, in the store its copy names; a copy
    /// that names none (or one this version does not know) is looked for in the store of
    /// the settings. The page is the one for the copy's own ID, else for the book's
    /// ASIN; with neither it is a search of that store for the title and first author.
    func audibleAddress(of book: Book, copy: ExternalCopy) -> URL {
        let store = copy.store.flatMap(AudibleStore.init(rawValue:)) ?? audibleStore
        return store.webAddress(
            asin: copy.itemId?.trimmedOrNil ?? book.asin?.trimmedOrNil, title: book.title,
            author: book.authors.lazy.compactMap(\.trimmedOrNil).first ?? "")
    }

    /// A14: shows each book in the Finder: its folder, or for a book left where it was
    /// found, its first file. A book with no files has nothing to show.
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

    /// The collection the sidebar is showing the books of; nil when it is showing something else.
    public var shownCollection: BookCollection? {
        guard case .collection(let id) = sidebarSelection else { return nil }
        return sidebar.collections.first { $0.id == id }
    }

    /// What the menus call taking books out of the collection that is shown; nil when
    /// no collection is shown.
    public var removeFromCollectionTitle: String? {
        shownCollection.map { "Remove from \"\($0.name)\"" }
    }

    /// Takes these books out of the collection that is shown. They stay in the library.
    public func removeFromShownCollection(_ ids: Set<Int64>) async {
        guard let id = shownCollection?.id else { return }
        await remove(ids, fromCollection: id)
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
