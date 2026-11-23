import Foundation
import VoxCarrelCore

// Merge Books in the app model (merge books plan, Task 2). MG1–MG7.
//
// Entries that are really one book become one entry. The sheet shows what the library
// would do (which entry is kept, what each file will be to it, where the book will be,
// what stands in the way) and lets the owner choose the entry to keep and each file's
// role. Every choice is planned again by the library; nothing is changed until Merge,
// which is one operation that Undo reverses.

/// One of the entries being merged, as the sheet lists it.
public struct MergeEntryRow: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var title: String
    /// The first author; empty when there is none.
    public var author: String
    /// What the entry has: "Audiobook, 1 file".
    public var contents: String
    /// Whether this is the entry that stays.
    public var isKept: Bool

    /// The line under the title: "James Dalton · Audiobook, 1 file", or what the entry
    /// has alone when it has no author.
    public var subtitle: String {
        author.isEmpty ? contents : "\(author) · \(contents)"
    }
}

/// One file of the entries being merged, as the sheet lists it.
public struct MergeFileRow: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var name: String
    /// The title of the entry the file belongs to now.
    public var entryTitle: String
    /// What the file will be to the kept book.
    public var role: FileRole
    /// The roles the file's format may take.
    public var allowedRoles: [FileRole]
    /// Whether the owner has given the file another role than the library would.
    public var isChanged: Bool

    /// The line under the name: "From “Mind Over Markets”".
    public var sourceText: String {
        "From “\(entryTitle)”"
    }
}

/// One reason a book needs attention, with what the inspector offers under it.
public struct AttentionLine: Identifiable, Equatable, Sendable {
    public var text: String
    /// MG5: the merge to offer under this reason; nil for none.
    public var offer: MergeOffer?

    public var id: String { text }

    public init(text: String, offer: MergeOffer? = nil) {
        self.text = text
        self.offer = offer
    }
}

extension BookDetail {
    /// `attentionReasons`, each with what is offered under it. MG5: the merge is
    /// offered under the reason it answers, that another book has this book's folder.
    public var attentionLines: [AttentionLine] {
        attentionReasons.map { reason in
            AttentionLine(text: reason, offer: reason == unfiledReason ? mergeOffer : nil)
        }
    }
}

/// What the Merge Books sheet shows.
public struct MergeSheetState: Equatable, Sendable {
    /// The entries, in the order they were chosen.
    public var entries: [MergeEntryRow]
    /// Every file of every entry, the kept entry's first.
    public var files: [MergeFileRow]
    /// Why the merge cannot be made, each a sentence; empty when it can.
    public var blockers: [String]
    /// What the merge will do, where the book will be filed, and, plainly, when files
    /// will be moved into the library folder from outside it and when the book will
    /// still need attention afterwards.
    public var summary: String
    /// Whether the summary warns that the book will still need attention.
    public var willNeedAttention: Bool
    /// What the sheet is doing now ("Merging books…"); nil when it is doing nothing.
    public var busyText: String?
    /// Whether the entry to keep and the files' roles can be changed, and the sheet closed.
    public var canChange: Bool
    public var canMerge: Bool
}

/// MG5: the merge the inspector offers for a book whose folder is another book's.
public struct MergeOffer: Equatable, Sendable {
    /// The book that has the folder.
    public var bookId: Int64
    public var title: String

    public init(bookId: Int64, title: String) {
        self.bookId = bookId
        self.title = title
    }

    /// What the button says: "Merge with “Mind Over Markets”…".
    public var actionTitle: String {
        "Merge with “\(MergeText.shownTitle(title))”…"
    }
}

/// What the sheet says of one entry, read with the plan.
public struct MergeEntryFacts: Equatable, Sendable {
    public var id: Int64
    public var title: String
    public var authors: [String]
    /// The roles of the entry's files as they are now.
    public var roles: [FileRole]

    public init(id: Int64, title: String, authors: [String], roles: [FileRole]) {
        self.id = id
        self.title = title
        self.authors = authors
        self.roles = roles
    }
}

/// A plan for a merge with what the sheet says of each entry, read in one turn.
public struct MergeReading: Equatable, Sendable {
    public var plan: MergePlan
    /// The entries that are in the library, in the order they were asked about.
    public var entries: [MergeEntryFacts]

    public init(plan: MergePlan, entries: [MergeEntryFacts]) {
        self.plan = plan
        self.entries = entries
    }
}

/// The merge that is open: what the sheet's state is worked out from.
struct MergeSession {
    /// The entries, in the order they were chosen.
    var bookIds: [Int64]
    /// MG3: only the roles the owner set, by file id. Everything else is the library's guess.
    var roles: [Int64: FileRole] = [:]
    var reading: MergeReading
}

/// The words of Merge Books.
enum MergeText {
    static let planningLabel = "Reading the books…"
    static let mergingLabel = "Merging books…"

    static func shownTitle(_ title: String) -> String {
        title.trimmedOrNil ?? "Untitled book"
    }

    /// "Audiobook, 1 file", "Audiobook and ebook, 3 files", "Extras only, 2 files", "No files".
    static func contents(roles: [FileRole]) -> String {
        guard !roles.isEmpty else { return "No files" }
        let files = roles.count == 1 ? "1 file" : "\(roles.count) files"
        let kind: String =
            switch (roles.contains(.audio), roles.contains(.ebook)) {
            case (true, true): "Audiobook and ebook"
            case (true, false): "Audiobook"
            case (false, true): "Ebook"
            case (false, false): "Extras only"
            }
        return "\(kind), \(files)"
    }

    /// MG2: one plain sentence for a blocker. `titles`: the entries' titles by id.
    static func blocker(_ blocker: MergeBlocker, titles: [Int64: String]) -> String {
        guard case .bothHaveAudio(let ids) = blocker else { return LibraryService.describe(blocker) + "." }
        let names = ids.map { "“\(shownTitle(titles[$0] ?? ""))”" }
        guard names.count != 2 else {
            return "\(names[0]) and \(names[1]) both have audiobook files, so they are treated as two editions "
                + "and cannot be merged."
        }
        let listed = names.count > 2
            ? "\(names.dropLast().joined(separator: ", ")) and \(names[names.count - 1])" : names.joined()
        return "\(listed) all have audiobook files, so they are treated as separate editions and cannot be merged."
    }

    /// MG2: what the merge will do, and where the book will be afterwards.
    /// - Parameters:
    ///   - incoming: How many files come in from the entries that are removed.
    ///   - title: The kept book's title.
    ///   - removed: How many entries are removed.
    ///   - folder: The folder the book is in afterwards, relative to the library.
    ///   - attention: Why the book will still need attention; nil when it will not.
    ///   - fromOutside: How many of the files that move are outside the library folder now.
    static func summary(
        incoming: Int, title: String, removed: Int, folder: String?, attention: MergeAttention?,
        fromOutside: Int = 0
    ) -> String {
        let book = "“\(shownTitle(title))”"
        var sentences: [String] = []
        switch incoming {
        case 0: sentences.append("No files need to move into \(book).")
        case 1: sentences.append("1 file will move into \(book).")
        default: sentences.append("\(incoming) files will move into \(book).")
        }
        sentences.append(removed == 1 ? "1 entry will be removed." : "\(removed) entries will be removed.")
        // Said plainly: these leave the folders they are in, which are not the library's.
        switch fromOutside {
        case 0: break
        case 1: sentences.append("1 file is outside the library folder and will be moved into it.")
        default: sentences.append("\(fromOutside) files are outside the library folder and will be moved into it.")
        }
        let stay = folder.map { "it will stay in “\($0)”" } ?? "it will stay where it is"
        switch attention {
        case nil:
            if let folder { sentences.append("The book will be filed in “\(folder)”.") }
        case .folderTaken:
            sentences.append(
                "Another book uses the folder this book belongs in, so \(stay) and will still need attention.")
        case .cannotBeFiled:
            sentences.append(
                "The folder layout cannot file this book yet, so \(stay) and will still need attention.")
        case .fileMissing:
            sentences.append("Some of this book's files are missing, so \(stay) and will still need attention.")
        case .asBefore:
            sentences.append("The book will still need attention.")
        }
        return sentences.joined(separator: " ")
    }
}

extension AppModel {
    // MARK: MG1 Whether books can be merged

    /// MG1: whether Merge Books applies to the selection: two or more books of the
    /// library are selected, and no operation, sheet, question, unsaved edit or
    /// unresolved change of folder layout is in the way.
    public var canMergeBooks: Bool {
        canMergeBooks(selection)
    }

    /// The same for these books, which need not be the selection: for a context menu.
    public func canMergeBooks(_ ids: Set<Int64>) -> Bool {
        // SV7: a row that stands for a book the library does not have is no book to merge.
        ids.count >= 2 && !holdsMissing(ids) && isQuietForMerge
    }

    /// Whether a context menu for these books has Merge Books in it: it is for several books.
    public func offersMergeBooks(for ids: Set<Int64>) -> Bool {
        ids.count > 1
    }

    /// Nothing is in the way of opening the sheet.
    private var isQuietForMerge: Bool {
        isLibraryOpen && busyLabel == nil && storedPrompt == nil && filesCanChange && review == nil
            && result == nil && libraryCheck == nil && seriesChoice == nil && lookup == nil
            && !hasUnsavedChanges
    }

    // MARK: MG2 Beginning

    /// MG2: plans the merge of the selected books and opens the sheet. Does nothing
    /// unless `canMergeBooks`.
    public func beginMergeBooks() async {
        await beginMergeBooks(for: selection)
    }

    /// The same for the books a context menu was opened on.
    public func beginMergeBooks(for ids: Set<Int64>) async {
        guard canMergeBooks(ids) else { return }
        await openMerge(ordered(ids))
    }

    /// MG5: whether the inspector's offer can be taken up now.
    public var canAcceptMergeOffer: Bool {
        mergeOffer != nil && isQuietForMerge
    }

    /// MG5: opens the sheet for the inspected book and `otherId`, the book that has its
    /// folder, keeping the one the library suggests (the one with audio). Does nothing
    /// unless one book is inspected and nothing is in the way.
    public func beginMerge(with otherId: Int64) async {
        guard case .one(let detail, _) = inspecting, isQuietForMerge, otherId > 0, otherId != detail.row.id
        else { return }
        await openMerge([detail.row.id, otherId])
    }

    /// Planning is an operation: it looks at every file's place on the disk. When the
    /// plan cannot be made no sheet opens and `alert` says why.
    private func openMerge(_ ids: [Int64]) async {
        guard let worker = await begin(MergeText.planningLabel) else { return }
        do {
            let reading = try await worker.planMerge(bookIds: ids, keep: nil, roles: [:])
            mergeSession = MergeSession(bookIds: ids, reading: reading)
        } catch {
            show(error)
        }
        // A plan changes nothing in the library, so there is nothing to read again.
        busyLabel = nil
    }

    /// What the sheet shows; nil when it is not open.
    public var mergeSheet: MergeSheetState? {
        guard let session = mergeSession else { return nil }
        let plan = session.reading.plan
        let entries = session.reading.entries
        let titles = Dictionary(entries.map { ($0.id, $0.title) }) { first, _ in first }
        let incoming = plan.files.filter { $0.bookId != plan.keepId }.count
        return MergeSheetState(
            entries: entries.map { entry in
                MergeEntryRow(
                    id: entry.id, title: MergeText.shownTitle(entry.title),
                    author: entry.authors.lazy.compactMap(\.trimmedOrNil).first ?? "",
                    contents: MergeText.contents(roles: entry.roles), isKept: entry.id == plan.keepId)
            },
            files: plan.files.map { file in
                MergeFileRow(
                    id: file.fileId, name: file.name,
                    entryTitle: MergeText.shownTitle(titles[file.bookId] ?? ""), role: file.role,
                    allowedRoles: Self.mergeRoles(for: file), isChanged: file.role != file.guessedRole)
            },
            blockers: plan.blockers.map { MergeText.blocker($0, titles: titles) },
            summary: MergeText.summary(
                incoming: incoming, title: titles[plan.keepId] ?? "", removed: max(entries.count - 1, 0),
                folder: plan.resultFolder, attention: plan.attention, fromOutside: plan.filesFromOutside),
            willNeedAttention: plan.attention != nil,
            busyText: busyLabel,
            canChange: busyLabel == nil,
            canMerge: busyLabel == nil && plan.blockers.isEmpty && entries.count >= 2)
    }

    /// The roles a file may be given: its format's, as for a file of a book.
    private static func mergeRoles(for file: MergeFilePlan) -> [FileRole] {
        guard let format = FileFormat(url: URL(fileURLWithPath: file.name)) else { return [file.role] }
        return FileRow.allowedRoles(for: format)
    }

    // MARK: MG3 Changing the plan

    /// MG3: keeps this entry in place of the one kept now, and plans again.
    public func setMergeKeep(_ id: Int64) async {
        guard let session = mergeSession, busyLabel == nil, session.bookIds.contains(id),
              id != session.reading.plan.keepId
        else { return }
        await planMergeAgain(keep: id, roles: session.roles)
    }

    /// MG3: gives a file a role, and plans again: what the library guesses for the
    /// other files follows from it, and the roles the owner set stay as they were set.
    public func setMergeRole(_ role: FileRole, forFile id: Int64) async {
        guard let session = mergeSession, busyLabel == nil,
              let file = session.reading.plan.files.first(where: { $0.fileId == id }),
              Self.mergeRoles(for: file).contains(role), role != file.role
        else { return }
        var roles = session.roles
        roles[id] = role
        await planMergeAgain(keep: session.reading.plan.keepId, roles: roles)
    }

    /// Plans the open merge with these choices. When the plan cannot be made the sheet
    /// stays as it was and `alert` says why.
    private func planMergeAgain(keep: Int64, roles: [Int64: FileRole]) async {
        guard let session = mergeSession else { return }
        mergeIsActing = true
        let worker = await begin(MergeText.planningLabel)
        mergeIsActing = false
        guard let worker else { return }
        do {
            let reading = try await worker.planMerge(bookIds: session.bookIds, keep: keep, roles: roles)
            mergeSession?.reading = reading
            mergeSession?.roles = roles
        } catch {
            show(error)
        }
        // MG7: files the app was asked to open meanwhile go on waiting for the sheet to
        // close (`openFiles`).
        busyLabel = nil
    }

    // MARK: MG4 Merging

    /// MG4: makes the merge as one operation that Undo reverses, selects the kept book
    /// and closes the sheet. If the merge is refused or fails nothing has changed,
    /// `alert` says why, and the sheet stays with the merge planned again.
    public func confirmMerge() async {
        guard let session = mergeSession, mergeSheet?.canMerge == true else { return }
        let keep = session.reading.plan.keepId
        mergeIsActing = true
        let worker = await begin(MergeText.mergingLabel)
        mergeIsActing = false
        guard let worker else { return }
        do {
            let kept = try await worker.mergeBooks(session.bookIds, keep: keep, roles: session.roles)
            // The removed entries are gone: the kept book is what is selected.
            selection = [kept]
            anchor = kept
            await reloadAll(keepEdits: false)
            mergeSession = nil
        } catch {
            show(error)
            await reloadAll()
            // What is in the way now is said in the sheet. Roles are by file id, and a
            // plan that no longer knows a file is made without them.
            if let reading = try? await worker.planMerge(bookIds: session.bookIds, keep: keep, roles: session.roles) {
                mergeSession?.reading = reading
            } else if let reading = try? await worker.planMerge(bookIds: session.bookIds, keep: nil, roles: [:]) {
                mergeSession?.reading = reading
                mergeSession?.roles = [:]
            } else {
                mergeSession = nil
            }
        }
        busyLabel = nil
    }

    /// Closes the sheet. Nothing has been changed. Not while the sheet is in the
    /// middle of something.
    public func cancelMerge() {
        guard mergeSession != nil, busyLabel == nil else { return }
        mergeSession = nil
        // MG7: files the app was asked to open meanwhile.
        importHeldFiles()
    }

    // MARK: MG5 The offer

    /// MG5: for the one inspected book, the merge to offer under the reason "Another
    /// book uses the folder this book belongs in.": with the book that has the folder.
    /// Nil when the book is not flagged for that reason, or one book is not what is inspected.
    public var mergeOffer: MergeOffer? {
        guard case .one(let detail, _) = inspecting else { return nil }
        return detail.mergeOffer
    }

    // MARK: MG6 Swap Title and Author

    /// MG6: whether the inspected book's draft has a title and an author to exchange.
    public var canSwapTitleAndAuthor: Bool {
        guard case .one(_, let draft) = inspecting else { return false }
        return draft.canSwapTitleAndAuthor
    }

    /// MG6: exchanges the title and the first author in the inspected book's draft. An
    /// edit like any other: nothing is written until it is saved.
    public func swapTitleAndAuthor() {
        updateDraft { $0.swapTitleAndAuthor() }
    }

    /// MG6: whether this entry of the import being reviewed has a title and an author to exchange.
    public func canSwapReviewTitleAndAuthor(for id: UUID) -> Bool {
        review?.canSwapTitleAndAuthor(of: id) ?? false
    }

    /// MG6: the same exchange for an entry of the import being reviewed. Its folder and
    /// the library book it matches are worked out again, and arrive a moment later.
    public func swapReviewTitleAndAuthor(for id: UUID) {
        guard canSwapReviewTitleAndAuthor(for: id) else { return }
        updateReview { $0.swapTitleAndAuthor(for: id) }
    }
}
