import Foundation
import VoxCarrelCore

extension GenreGroup {
    /// The group's heading, wherever genres are shown by group.
    public var title: String {
        switch self {
        case .fiction: "Fiction"
        case .nonFiction: "Non-fiction"
        case .children: "Children & Young Adult"
        case .other: "Other"
        }
    }
}

/// One genre the field offers.
public struct GenreSuggestion: Identifiable, Equatable, Sendable {
    public var name: String
    public var group: GenreGroup

    public var id: String { name }
}

/// The genres of one group that the field offers.
public struct GenreSuggestionGroup: Identifiable, Equatable, Sendable {
    public var group: GenreGroup
    public var title: String
    public var genres: [GenreSuggestion]

    public var id: GenreGroup { group }
}

/// G21, G22: what the genre field offers for what has been typed into it.
public struct GenreSuggestions: Equatable, Sendable {
    /// The genres that match, by group: the built-in ones in their own order, then the
    /// owner's own by name. A group with none is left out.
    public var groups: [GenreSuggestionGroup] = []
    /// The name a new genre would have, when what was typed is no genre yet and could
    /// be one; nil otherwise. Making it asks for its group (`createGroups`).
    public var createName: String?
    /// Why what was typed cannot be a genre's name; nil when it can, or names one.
    public var problem: String?

    /// What the offer to make the genre says: `Create "Cold War"`.
    public var createTitle: String? {
        createName.map { "Create \"\($0)\"" }
    }

    /// The groups a new genre can be put in, in the order they are offered.
    public static let createGroups = GenreGroup.allCases

    /// Why a name with a separator in it is refused.
    public static let separatorProblem = "A genre's name cannot have a comma, a semicolon or a slash in it."
}

/// The library's list of genres as the app last read it: what a typed name comes to in
/// it, and what to offer as the owner types. A plain value; it asks the library nothing.
public struct GenreCatalogue: Equatable, Sendable {
    /// Every genre of the list, those merged away included, in the list's order.
    public var entries: [GenreEntry]

    public init(_ entries: [GenreEntry] = []) {
        self.entries = entries
    }

    /// The genres that are shown: all but the built-in ones that were merged away.
    public var shown: [GenreEntry] {
        entries.filter { !$0.isHidden }
    }

    /// The group a genre of this name is in; nil when the list has none.
    public func group(of name: String) -> GenreGroup? {
        entry(named: name)?.group
    }

    /// The name the library keeps for this one: the genre that has it, spelled as the
    /// list spells it; a renamed built-in genre by its new name; one merged away by the
    /// genre it went into. Nil for a name the list lacks.
    public func listed(_ name: String) -> String? {
        entry(named: name).map { standing(for: $0).name }
    }

    /// The genre of the list that typed text is, without asking: the genre of that
    /// name, or the built-in genre the mapping knows the text as a name for ("Sci-Fi").
    /// Nil when it is neither: it is then a new name.
    public func listedGenre(forTyped text: String) -> String? {
        if let listed = listed(text) { return listed }
        let mapped = GenreMapping.map(.text(text))
        guard mapped.unknown.isEmpty, mapped.builtIn.count == 1 else { return nil }
        return listed(mapped.builtIn[0])
    }

    /// Genres as the library keeps them on a book: each as `listed` gives it, a name
    /// the list lacks as it is, and none twice.
    public func names(_ names: [String]) -> [String] {
        GenreName.distinct(GenreName.distinct(names).map { listed($0) ?? $0 })
    }

    /// G21, G22: what to offer for `typed`, leaving out the genres in `excluding` (the
    /// ones the book has already).
    ///
    /// With nothing typed, every genre that is shown. Otherwise the genres whose names
    /// hold the text, whatever its capitals, and the genre the text is a source's name
    /// for. Text that is no genre and could be the name of one is offered to be made;
    /// text that could not be is refused with the reason.
    public func suggestions(for typed: String, excluding: [String] = []) -> GenreSuggestions {
        let text = typed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let meant = text.isEmpty ? nil : listedGenre(forTyped: text)
        func isExcluded(_ name: String) -> Bool {
            excluding.contains { GenreName.same($0, name) }
        }
        var offered = GenreSuggestions()
        for group in GenreGroup.allCases {
            let genres = shown.filter { entry in
                guard entry.group == group, !isExcluded(entry.name) else { return false }
                if text.isEmpty { return true }
                if let meant, GenreName.same(meant, entry.name) { return true }
                return entry.name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            guard !genres.isEmpty else { continue }
            offered.groups.append(
                GenreSuggestionGroup(
                    group: group, title: group.title,
                    genres: genres.map { GenreSuggestion(name: $0.name, group: group) }))
        }
        guard !text.isEmpty, meant == nil else { return offered }
        if let name = GenreName.valid(text) {
            offered.createName = name
        } else {
            offered.problem = GenreSuggestions.separatorProblem
        }
        return offered
    }

    /// The genre a name is: the one that has it now, or failing that the built-in one
    /// that shipped under it. Capitalisation does not count.
    private func entry(named name: String) -> GenreEntry? {
        let tidy = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return entries.first { GenreName.same($0.name, tidy) }
            ?? entries.first { entry in entry.builtInName.map { GenreName.same($0, tidy) } ?? false }
    }

    /// Where a genre's books are: the genre itself, or for one merged away the genre it
    /// went into, however many merges on.
    private func standing(for entry: GenreEntry) -> GenreEntry {
        var current = entry
        var seen: Set<String> = [entry.name.lowercased()]
        while current.isHidden, let next = current.mergedInto,
              let target = entries.first(where: { GenreName.same($0.name, next) }) {
            guard seen.insert(target.name.lowercased()).inserted else { return entry }
            current = target
        }
        return current
    }
}

/// A book's genres as chips: one added, one taken away, one moved. G1: no genre is
/// there twice, whatever its capitals.
public enum GenreChips {
    /// With `name` at the end, unless it is there already.
    public static func adding(_ name: String, to genres: [String]) -> [String] {
        genres.contains { GenreName.same($0, name) } ? genres : genres + [name]
    }

    public static func removing(_ name: String, from genres: [String]) -> [String] {
        genres.filter { !GenreName.same($0, name) }
    }

    /// With the genre at `source` put at `destination`, both places in the list as it
    /// is. A place that is not in the list changes nothing.
    public static func moving(_ genres: [String], from source: Int, to destination: Int) -> [String] {
        guard genres.indices.contains(source), genres.indices.contains(destination), source != destination
        else { return genres }
        var moved = genres
        moved.insert(moved.remove(at: source), at: destination)
        return moved
    }

    /// G37: the genres on one line, in the book's order: "Thrillers & Spies, Crime & Mystery".
    public static func shown(_ genres: [String]) -> String {
        genres.joined(separator: ", ")
    }
}
