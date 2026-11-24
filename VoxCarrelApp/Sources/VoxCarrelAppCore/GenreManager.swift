import Foundation
import Observation
import VoxCarrelCore

/// One genre as Manage Genres lists it.
public struct GenreManagerRow: Identifiable, Equatable, Sendable {
    public var name: String
    public var group: GenreGroup
    /// How many books have it.
    public var count: Int
    /// True for a genre the app ships with, whatever it is called now.
    public var isBuiltIn: Bool
    /// The name a built-in genre shipped under, when it has been renamed.
    public var shippedAs: String?

    public var id: String { name }

    /// "3 books", "1 book", "No books".
    public var countText: String {
        switch count {
        case 0: "No books"
        case 1: "1 book"
        default: "\(count) books"
        }
    }

    /// G26: Delete is offered for the owner's own genres only.
    public var canDelete: Bool { !isBuiltIn }

    /// For a built-in genre that has been renamed: `Built in as "Fantasy"`.
    public var builtInNote: String? {
        shippedAs.map { "Built in as \"\($0)\"" }
    }
}

/// The genres of one group, as Manage Genres lists them.
public struct GenreManagerGroup: Identifiable, Equatable, Sendable {
    public var group: GenreGroup
    public var title: String
    public var rows: [GenreManagerRow]

    public var id: GenreGroup { group }
}

/// A group a genre can be moved to.
public struct GenreMoveTarget: Identifiable, Equatable, Sendable {
    public var group: GenreGroup
    public var title: String

    public var id: GenreGroup { group }
}

/// The genres of one group that a genre can be merged into.
public struct GenreMergeTargets: Identifiable, Equatable, Sendable {
    public var group: GenreGroup
    public var title: String
    public var genres: [String]

    public var id: GenreGroup { group }
}

/// A question Manage Genres puts before it changes anything.
public struct GenreQuestion: Equatable, Sendable {
    public var title: String
    public var message: String
    /// What the button that goes ahead says.
    public var confirmTitle: String
    /// What a yes does.
    var change: GenreListChange
}

/// G23–G27: the state of Manage Genres. It decides everything the sheet shows; every
/// change is made by the model, as one operation that Undo reverses, and no file is
/// written by any of them.
@MainActor @Observable
public final class GenreManager {
    @ObservationIgnored private unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    public let title = "Manage Genres"
    public let resetTitle = "Reset to Built-in Names"

    // MARK: The list

    /// G23: every genre that is shown, by group, with its number of books: the
    /// built-in ones in their own order, then the owner's own by name. A group with no
    /// genre is left out.
    public var groups: [GenreManagerGroup] {
        let shown = model.genreCatalogue.shown
        return GenreGroup.allCases.compactMap { group in
            let rows = shown.filter { $0.group == group }.map { entry in
                GenreManagerRow(
                    name: entry.name, group: group, count: entry.bookCount, isBuiltIn: entry.builtInName != nil,
                    shippedAs: entry.builtInName.flatMap { $0 == entry.name ? nil : $0 })
            }
            return rows.isEmpty ? nil : GenreManagerGroup(group: group, title: group.title, rows: rows)
        }
    }

    /// True while a change is being made: nothing else can be begun.
    public var isBusy: Bool {
        model.busyLabel != nil
    }

    /// Why the last change was refused, as a sentence; nil when it was not.
    public private(set) var problem: String?

    /// G27: said while files hold other genre tags than the library would write.
    public var filesNote: String? {
        let count = model.genreFilesToUpdate
        guard count > 0 else { return nil }
        let files = count == 1 ? "The files of 1 book now hold" : "The files of \(count) books now hold"
        return "\(files) other genre tags. Choose Update files… in the sidebar to write them."
    }

    // MARK: Rename

    /// The genre being renamed; nil when none is.
    public private(set) var renaming: String?
    /// What its name field holds.
    public var renameText = "" {
        didSet {
            if renameText != oldValue { problem = nil }
        }
    }

    /// G24: begins renaming a genre: its name field holds its name.
    public func beginRename(_ name: String) {
        guard question == nil, row(name) != nil else { return }
        renaming = name
        renameText = name
        problem = nil
    }

    public func cancelRename() {
        renaming = nil
        renameText = ""
        problem = nil
    }

    /// Whether there is another name to give it.
    public var canCommitRename: Bool {
        guard let renaming, !isBusy else { return false }
        let typed = renameText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return !typed.isEmpty && typed != renaming
    }

    /// G24: gives the genre the name in the field. A name that cannot be a genre's is
    /// refused with the reason, and the field stays. A name another genre has is a
    /// merge, and is asked about first (`question`): nothing merges without a yes.
    public func commitRename() async {
        guard let name = renaming, canCommitRename else { return }
        switch await model.changeGenreList(.rename(name, to: renameText)) {
        case .done:
            ownChange = GenreListChange.rename(name, to: renameText).undoLabel
            cancelRename()
        case .nameInUse(let other):
            question = mergeQuestion(name, into: other)
        case .refused(let why):
            problem = why
        case .notTried:
            break
        }
    }

    // MARK: Merge, move, delete, reset

    /// G25: the genres a genre can be merged into: every other one that is shown, by group.
    public func mergeTargets(for name: String) -> [GenreMergeTargets] {
        groups.compactMap { group in
            let genres = group.rows.map(\.name).filter { !GenreName.same($0, name) }
            return genres.isEmpty ? nil : GenreMergeTargets(group: group.group, title: group.title, genres: genres)
        }
    }

    /// G25: moves every book from one genre to another and takes the first off the list.
    public func merge(_ name: String, into other: String) async {
        await make(.merge(name, into: other))
    }

    /// The groups a genre can be moved to: every one but its own.
    public func moveTargets(for name: String) -> [GenreMoveTarget] {
        let own = row(name)?.group
        return GenreGroup.allCases.filter { $0 != own }.map { GenreMoveTarget(group: $0, title: $0.title) }
    }

    /// Puts a genre in another group. No book changes.
    public func move(_ name: String, to group: GenreGroup) async {
        await make(.move(name, to: group))
    }

    /// G26: asks whether to delete a genre of the owner's own, saying how many books
    /// lose it. A built-in genre is never deleted.
    public func requestDelete(_ name: String) {
        guard question == nil, !isBusy, let row = row(name), row.canDelete else { return }
        let message: String
        switch row.count {
        case 0: message = "No book has this genre."
        case 1: message = "1 book loses this genre. Its files are not changed until you update them."
        default: message = "\(row.count) books lose this genre. Their files are not changed until you update them."
        }
        question = GenreQuestion(
            title: "Delete \"\(row.name)\"?", message: message, confirmTitle: "Delete", change: .delete(row.name))
    }

    /// G24: whether any built-in genre has another name than it shipped under, or was
    /// merged away.
    public var canReset: Bool {
        !isBusy && model.genreCatalogue.entries.contains { entry in
            entry.builtInName.map { $0 != entry.name || entry.isHidden } ?? false
        }
    }

    /// G24: puts every built-in name back, and brings back, empty, the built-in genres
    /// that were merged away. The owner's own genres are left alone.
    public func reset() async {
        guard canReset else { return }
        await make(.reset)
    }

    // MARK: Questions

    /// The question waiting for an answer; nil when there is none.
    public private(set) var question: GenreQuestion?

    /// Yes: does what was asked about.
    public func confirmQuestion() async {
        guard let asked = question else { return }
        question = nil
        if case .merge = asked.change { cancelRename() }
        await make(asked.change)
    }

    public func cancelQuestion() {
        question = nil
    }

    /// G24: `Merge "A" into "B"?`
    private func mergeQuestion(_ name: String, into other: String) -> GenreQuestion {
        let source = row(name)
        let books: String
        switch source?.count ?? 0 {
        case 0: books = "It has no books"
        case 1: books = "Its 1 book moves to \"\(other)\""
        case let count: books = "Its \(count) books move to \"\(other)\""
        }
        let after = source?.isBuiltIn == true
            ? "is hidden until you reset the built-in names" : "is taken off the list"
        return GenreQuestion(
            title: "Merge \"\(name)\" into \"\(other)\"?",
            message: "There is already a genre called \"\(other)\". \(books), and \"\(name)\" \(after).",
            confirmTitle: "Merge", change: .merge(name, into: other))
    }

    // MARK: Undo

    /// The undo label of the last change made in this sheet that has not been undone;
    /// nil when there is none.
    private var ownChange: String?

    /// G27: whether the last change can be undone from here: only a change made in
    /// this sheet, while it is still what Undo would reverse. An operation from before
    /// the sheet was opened is not undone from it.
    public var canUndo: Bool {
        model.canUndo && ownChange != nil && ownChange == model.undoLabel
    }

    /// "Undo Rename genre"
    public var undoTitle: String {
        model.undoMenuTitle
    }

    public func undo() async {
        guard canUndo else { return }
        problem = nil
        ownChange = nil
        await model.undo()
    }

    // MARK: Shared

    private func row(_ name: String) -> GenreManagerRow? {
        groups.lazy.flatMap(\.rows).first { GenreName.same($0.name, name) }
    }

    /// Makes a change; what it was refused for is said in `problem`.
    private func make(_ change: GenreListChange) async {
        problem = nil
        switch await model.changeGenreList(change) {
        case .done:
            ownChange = change.undoLabel
        case .notTried:
            break
        case .nameInUse(let other):
            problem = UserMessage.text(for: LibraryService.GenreChangeError.nameInUse(other))
        case .refused(let why):
            problem = why
        }
    }
}
