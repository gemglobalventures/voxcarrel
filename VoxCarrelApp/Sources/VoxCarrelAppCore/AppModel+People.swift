import Foundation
import VoxCarrelCore

// An author's or a narrator's own page: what is said above their books when the
// sidebar shows one of them, and writing their name another way across the library.

/// What is said above the books of one author or narrator.
public struct PersonHeader: Equatable, Sendable {
    public var name: String
    /// "Narrator" or "Author".
    public var kind: String
    /// "12 books · 143h 20m · 5 finished (61h 5m) · 3 only on Audible"
    public var facts: String
    public var canRename: Bool
    public let renameTitle = "Rename…"
    public var renamePrompt: String { "Write “\(name)” as:" }
    public let renameNote =
        "Every book that names them is changed, in the catalogue and in its files. Give the name another "
        + "person here already has to make the two one. Edit > Undo takes it back."
}

extension AppModel {
    /// The author or narrator the sidebar shows, and which they are; nil for anything else.
    var selectedPerson: (field: BrowseField, name: String)? {
        if case .browse(let field, let name) = sidebarSelection, field == .authors || field == .narrators {
            return (field, name)
        }
        return nil
    }

    /// What is said above the books while an author or a narrator is what the sidebar
    /// shows; nil otherwise, and while a search narrows the list.
    public var personHeader: PersonHeader? {
        guard let person = selectedPerson, searchText.trimmed.isEmpty, rowsLoaded else { return nil }
        let listed = rows.filter { !$0.isMissing }
        func seconds(_ some: [BookRow]) -> Double {
            some.reduce(0) { total, row in
                let length = row.book.durationSeconds ?? 0
                return total + (length.isFinite && length > 0 ? length : 0)
            }
        }
        var facts = [listed.count == 1 ? "1 book" : "\(listed.count) books"]
        if let whole = LengthText.text(seconds: seconds(listed)) { facts.append(whole) }
        let finished = listed.filter { $0.book.readStatus == .finished }
        if !finished.isEmpty {
            let length = LengthText.text(seconds: seconds(finished)).map { " (\($0))" } ?? ""
            facts.append("\(finished.count) finished\(length)")
        }
        let elsewhere = listed.filter { !$0.hasFiles && $0.isOnAudible }.count
        if elsewhere > 0 { facts.append("\(elsewhere) only on Audible") }
        return PersonHeader(
            name: person.name, kind: person.field == .narrators ? "Narrator" : "Author",
            facts: facts.joined(separator: " · "),
            canRename: isLibraryOpen && busyLabel == nil && !libraryIsAway && !hasUnsavedChanges)
    }

    /// Writes the person shown another way on every book that names them, and shows
    /// them under the new name. A name that is empty, or the same, changes nothing.
    public func renamePerson(to newName: String) async {
        guard let person = selectedPerson, personHeader?.canRename == true else { return }
        let new = newName.trimmed
        guard !new.isEmpty, new != person.name else { return }
        var changed = 0
        await perform("Renaming…") { worker in
            changed = try await worker.withService { try $0.renamePerson(person.field, from: person.name, to: new) }
        }
        guard changed > 0 else { return }
        let target = SidebarItem.browse(person.field, new)
        if sidebar.contains(target) { sidebarSelection = target }
    }
}
