import Foundation

/// What a source said, before it is mapped.
public enum GenreSource: Equatable, Sendable, Codable {
    /// A file's genre tag, or wording typed by hand.
    case text(String)
    /// Audible's category paths, top name first.
    case paths([[String]])
    /// Open Library's subjects.
    case subjects([String])
}

/// The genres a source's wording comes to. Together they are never more than five.
public struct MappedGenres: Equatable, Sendable {
    /// Names from `BuiltInGenre.all`, most specific first.
    public var builtIn: [String]
    /// Tidied wording the mapping does not know, to become genres of the owner's own.
    /// Always empty for subjects.
    public var unknown: [String]

    public init(builtIn: [String] = [], unknown: [String] = []) {
        self.builtIn = builtIn
        self.unknown = unknown
    }

    /// The genres in order: built in, then the owner's own; at most five.
    public var names: [String] {
        Array((builtIn + unknown).prefix(GenreMapping.most))
    }
}

/// Turns what files and catalogues say into genres of the list.
public enum GenreMapping {
    /// The most genres kept from one source.
    static let most = 5

    public static func map(_ source: GenreSource) -> MappedGenres {
        var found = Found()
        switch source {
        case .text(let text):
            if let written = writtenList(text) { return written }
            read(text, into: &found)
        case .paths(let paths):
            for path in paths { read(path: path, into: &found) }
        case .subjects(let subjects):
            for subject in subjects { read(subject, into: &found) }
            found.unknown = []
        }
        return settle(found)
    }

    /// The wording to keep as the book's source wording: the text itself, paths joined
    /// with " > " and "; ", subjects joined with "; ". Nil when there is nothing.
    public static func wording(of source: GenreSource) -> String? {
        let wording: String
        switch source {
        case .text(let text):
            wording = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .paths(let paths):
            wording = paths
                .map { $0.map(GenreName.tidied).filter { !$0.isEmpty }.joined(separator: " > ") }
                .filter { !$0.isEmpty }
                .joined(separator: "; ")
        case .subjects(let subjects):
            wording = subjects.map(GenreName.tidied).filter { !$0.isEmpty }.joined(separator: "; ")
        }
        return wording.isEmpty ? nil : wording
    }

    // MARK: What a source gives

    /// One known name found in a source.
    private struct Hit {
        var genre: String
        /// How specific the name is: its depth in its path, or in the catalogue.
        var level: Int
        /// The key of the top name this is, when it is a top name standing alone.
        var top: String?
        /// The keys of the top names it sits under.
        var under: [String]
    }

    private struct Found {
        var hits: [Hit] = []
        var unknown: [String] = []
    }

    /// A tag holding only the list's own names, parted by semicolons, is taken as it is
    /// written: it is what the app writes, and reads back as the same genres in the
    /// same order.
    private static func writtenList(_ text: String) -> MappedGenres? {
        var names: [String] = []
        for piece in text.split(separator: ";") {
            let tidy = GenreName.tidied(String(piece))
            if tidy.isEmpty { continue }
            guard let genre = BuiltInGenre.all.first(where: { GenreName.same($0.name, tidy) }) else { return nil }
            if !names.contains(genre.name) { names.append(genre.name) }
        }
        return names.isEmpty ? nil : MappedGenres(builtIn: Array(names.prefix(most)))
    }

    /// Drops a top name where a name beneath it was found, and general genres where
    /// there are others; then orders what is left and keeps five.
    private static func settle(_ found: Found) -> MappedGenres {
        var hits = found.hits

        let sitUnder = Set(hits.flatMap(\.under))
        let specific = hits.filter { hit in hit.top.map { !sitUnder.contains($0) } ?? true }
        if !specific.isEmpty { hits = specific }

        let general = Set(BuiltInGenre.all.filter(\.isGeneral).map(\.name))
        if hits.contains(where: { !general.contains($0.genre) }) {
            hits.removeAll { general.contains($0.genre) }
        }

        // The most specific first; the sort keeps the source's order within a level.
        let ordered = hits.enumerated().sorted { a, b in
            a.element.level != b.element.level ? a.element.level > b.element.level : a.offset < b.offset
        }
        var builtIn: [String] = []
        for (_, hit) in ordered where !builtIn.contains(hit.genre) { builtIn.append(hit.genre) }

        var unknown: [String] = []
        for name in found.unknown where !unknown.contains(where: { GenreName.same($0, name) }) {
            unknown.append(name)
        }

        builtIn = Array(builtIn.prefix(most))
        unknown = Array(unknown.prefix(most - builtIn.count))
        return MappedGenres(builtIn: builtIn, unknown: unknown)
    }

    // MARK: Text

    /// A piece of text between separators, and the mark that stood before it.
    private struct Piece {
        var text: String
        var key: String
        /// "," or "/"; nil for the first piece after a semicolon or the start.
        var joinedBy: Character?
    }

    /// Reads text as a tag is written: parted at semicolons, slashes and commas, except
    /// where a comma or slash is part of a name the table knows.
    private static func read(_ text: String, into found: inout Found) {
        for part in text.split(separator: ";") {
            var pieces: [Piece] = []
            var current = ""
            var joinedBy: Character?
            func close() {
                let key = GenreTable.pieceKey(current)
                if !key.isEmpty {
                    pieces.append(
                        Piece(text: GenreName.tidied(current), key: key, joinedBy: pieces.isEmpty ? nil : joinedBy))
                }
                current = ""
            }
            for character in part {
                if character == "," || character == "/" {
                    close()
                    joinedBy = character
                } else {
                    current.append(character)
                }
            }
            close()
            read(pieces[...], into: &found)
        }
    }

    /// Takes the longest known name made of neighbouring pieces first, then reads what
    /// stands before and after it; pieces in no such name are read one at a time.
    private static func read(_ pieces: ArraySlice<Piece>, into found: inout Found) {
        guard !pieces.isEmpty else { return }
        var length = min(pieces.count, GenreTable.index.longestName)
        while length > 1 {
            for start in pieces.startIndex...(pieces.endIndex - length) {
                let run = pieces[start..<(start + length)]
                var key = ""
                for (offset, piece) in run.enumerated() {
                    if offset > 0, let mark = piece.joinedBy { key.append(mark) }
                    key += piece.key
                }
                guard let meaning = GenreTable.meaning(key: key) else { continue }
                read(pieces[..<start], into: &found)
                note(meaning, into: &found)
                read(pieces[(start + length)...], into: &found)
                return
            }
            length -= 1
        }
        for piece in pieces { read(piece: piece.text, key: piece.key, into: &found) }
    }

    /// Reads one piece that holds no separator.
    private static func read(piece: String, key: String, mayBeANumber: Bool = true, into found: inout Found) {
        if let meaning = GenreTable.meaning(key: key) {
            note(meaning, into: &found)
        } else if GenreTable.saysNothing(key: key) {
            return
        } else if mayBeANumber, let number = bareNumber(key) {
            // An ID3 genre given by number is read by its name; any other number says nothing.
            guard GenreTable.id3Names.indices.contains(number) else { return }
            for part in GenreTable.id3Names[number].split(whereSeparator: GenreName.separators.contains) {
                let name = GenreName.tidied(String(part))
                read(piece: name, key: GenreTable.pieceKey(name), mayBeANumber: false, into: &found)
            }
        } else {
            found.unknown.append(piece)
        }
    }

    private static func note(_ meaning: GenreTable.Meaning, into found: inout Found) {
        guard let genre = meaning.genre else { return }
        found.hits.append(Hit(genre: genre, level: meaning.level, top: meaning.top, under: meaning.under))
    }

    /// The number a piece is when it is nothing else: "12" or "(12)".
    private static func bareNumber(_ key: String) -> Int? {
        var digits = Substring(key)
        if digits.hasPrefix("("), digits.hasSuffix(")") {
            digits = digits.dropFirst().dropLast()
        }
        let trimmed = digits.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 9, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        return Int(trimmed)
    }

    // MARK: Paths

    /// Reads one category path: one genre, decided by the deepest name the table knows
    /// beneath the path's top name.
    private static func read(path: [String], into found: inout Found) {
        var names = path.map(GenreName.tidied).filter { !$0.isEmpty }
        var keys = names.map(GenreTable.key)
        // A path may be handed over with a root above its top name.
        if let start = keys.firstIndex(where: { GenreTable.top(key: $0) != nil }), start > 0 {
            names.removeFirst(start)
            keys.removeFirst(start)
        }
        guard let topKey = keys.first, let deepest = names.last else { return }

        guard let (place, top) = GenreTable.top(key: topKey) else {
            // No top name the table knows: each name is read as it would be in a tag.
            for index in keys.indices.reversed() {
                if let genre = GenreTable.meaning(key: keys[index])?.genre {
                    found.hits.append(Hit(genre: genre, level: index + 1, top: nil, under: []))
                    return
                }
            }
            read(deepest, into: &found)
            return
        }

        let rows = GenreTable.index.rows[place]
        let beneath = keys.indices.dropFirst()
        // A name that covers everything beneath it decides before a deeper one does.
        let covering = beneath.first { rows[keys[$0]]?.isWhole == true && rows[keys[$0]]?.genre != nil }
        let deciding = covering ?? beneath.last { rows[keys[$0]]?.genre != nil }
        if let deciding, let genre = rows[keys[deciding]]?.genre {
            found.hits.append(Hit(genre: genre, level: deciding + 1, top: nil, under: [topKey]))
        } else {
            found.hits.append(Hit(genre: top.genre, level: 1, top: topKey, under: []))
        }
    }
}
