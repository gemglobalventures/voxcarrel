import Foundation

/// A book's genres as the one genre tag of a file, and back.
public enum GenreTag {
    /// What parts one genre from the next in a tag. Other apps split a genre tag at
    /// semicolons and never at commas.
    public static let separator = "; "

    /// The tag that holds these genres: their names in order, joined. Nil when there
    /// are none, so the tag is removed. The names are written as they are given.
    public static func text(_ genres: [String]) -> String? {
        let names = genres.filter { !$0.isEmpty }
        return names.isEmpty ? nil : names.joined(separator: separator)
    }

    /// The genres a file's tag gives in a library whose list holds `listed`.
    ///
    /// A tag made only of names of the list (the built-in ones and `listed`), parted by
    /// semicolons, is taken as it is written, in the list's spelling: it is what the
    /// app writes, and reads back as the same genres in the same order. Any other tag
    /// goes to the mapping, whole.
    public static func genres(from tag: String?, listed: [String] = []) -> [String] {
        guard let tag, !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        if let written = written(tag, listed: listed) { return written }
        return GenreName.spelled(GenreMapping.map(.text(tag)).names, as: listed)
    }

    /// The names of a tag that holds only names of the list; nil for any other tag.
    private static func written(_ tag: String, listed: [String]) -> [String]? {
        let known = listed + BuiltInGenre.all.map(\.name)
        var names: [String] = []
        for piece in tag.split(separator: ";") {
            let tidy = GenreName.tidied(String(piece))
            if tidy.isEmpty { continue }
            guard let name = known.first(where: { GenreName.same($0, tidy) }) else { return nil }
            names.append(name)
        }
        return names.isEmpty ? nil : GenreName.distinct(names)
    }
}

extension GenreName {
    /// A book's genres as they are kept: each name tidied, empty ones left out, and no
    /// name twice (compared without regard to case; the first stays).
    public static func distinct(_ names: [String]) -> [String] {
        var kept: [String] = []
        for name in names.map(tidied) where !name.isEmpty {
            if !kept.contains(where: { same($0, name) }) { kept.append(name) }
        }
        return kept
    }

    /// The names without repeats, each spelled as the list spells it where the list
    /// has it.
    public static func spelled(_ names: [String], as listed: [String]) -> [String] {
        distinct(distinct(names).map { name in listed.first { same($0, name) } ?? name })
    }
}
