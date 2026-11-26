import Foundation

/// What a folder pattern can name a folder after.
public enum FolderToken: String, CaseIterable, Sendable {
    case author = "Author", series = "Series", number = "Number", title = "Title",
         narrator = "Narrator", year = "Year", genre = "Genre", publisher = "Publisher",
         language = "Language", kind = "Kind"
}

extension FolderToken {
    /// What the token stands for, in words: "series number".
    public var noun: String {
        switch self {
        case .number: "series number"
        default: rawValue.lowercased()
        }
    }
}

/// Why a text cannot be used as a folder pattern.
public enum FolderPatternProblem: Error, Equatable, Sendable {
    /// Nothing but spaces, in the whole pattern or in one of its alternatives.
    case empty
    /// `{…}` that is not a token, braces included: "{Auther}".
    case unknownToken(String)
    case unclosedBrace, unclosedBracket, nestedBracket, strayClosing
    /// "a//b", a leading or trailing "/", or a level of fixed text that leaves no name.
    case emptyLevel
    /// More than `FolderPattern.maxLevels` levels; the number found.
    case tooManyLevels(Int)
    /// `{Title}` is missing from the last level, or is only inside brackets there.
    case lastLevelNeedsTitle
    /// A level that is "." or "..".
    case dotLevel
    /// The pattern text itself is over `FolderPattern.maxTextLength` characters.
    case tooLong
    /// More than `FolderPattern.maxAlternatives` alternatives separated by "|".
    case tooManyAlternatives
}

/// What a book gives each token: every value already made safe for a folder name.
public struct FolderPatternValues: Equatable, Sendable {
    private var values: [FolderToken: String] = [:]

    /// - Parameter hasAudio: Whether the book has any audio file (once the operation
    ///   asking is done): what `{Kind}` goes by.
    ///   - titleSuffix: For an edition that shares its title with another edition of
    ///     the same work: what follows the title, in brackets, wherever the pattern
    ///     has the title ("Dune (German)").
    public init(metadata: BookMetadata, hasAudio: Bool, titleSuffix: String? = nil) {
        func set(_ token: FolderToken, _ raw: String?) {
            let value = PathBuilder.sanitise(raw ?? "")
            if !value.isEmpty { values[token] = value }
        }
        set(.author, metadata.authors.first)
        let suffix = titleSuffix?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        set(.title, suffix.isEmpty || title.isEmpty ? metadata.title : "\(title) (\(suffix))")
        set(.series, metadata.series)
        // A number says nothing without the series it counts in.
        if values[.series] != nil { set(.number, metadata.seriesNumber) }
        set(.narrator, metadata.narrators.first)
        if let year = metadata.year, (1...9999).contains(year) {
            let digits = String(year)
            set(.year, String(repeating: "0", count: 4 - digits.count) + digits)
        }
        // The first genre is the main one.
        set(.genre, metadata.genres.first)
        set(.publisher, metadata.publisher)
        set(.language, metadata.language)
        set(.kind, hasAudio ? "Audiobooks" : "Ebooks")
    }

    /// The token's value, or "" when the book has none.
    func value(for token: FolderToken) -> String {
        values[token] ?? ""
    }
}

/// How book folders are arranged in a library: levels separated by "/", made of fixed
/// text and `{Token}`s; `[…]` is a part left out when a token inside it has no value;
/// "|" separates alternatives, the first that can be rendered being used.
public struct FolderPattern: Equatable, Hashable, Sendable {
    public static let maxLevels = 6
    public static let maxTextLength = 500
    public static let maxAlternatives = 3

    /// `{Author}/[{Series}/][{Number} - ]{Title}`
    public static let standard = preset("{Author}/[{Series}/][{Number} - ]{Title}")

    public static let presets: [(name: String, pattern: FolderPattern)] = [
        ("Author / Series / Title", standard),
        ("Author / Title", preset("{Author}/{Title}")),
        ("Series / Title", preset("{Series}/[{Number} - ]{Title}|{Author}/{Title}")),
        ("Kind / Author / Series / Title", preset("{Kind}/{Author}/[{Series}/][{Number} - ]{Title}")),
    ]

    private static func preset(_ text: String) -> FolderPattern {
        do {
            return try FolderPattern(text)
        } catch {
            preconditionFailure("The built-in folder pattern \(text) does not parse: \(error)")
        }
    }

    /// The pattern as given, without the spaces around it.
    public let text: String
    /// `text` with every token name spelled as `FolderToken` spells it: what equality goes by.
    private let canonical: String
    private let alternatives: [Alternative]

    /// One piece of an alternative, in reading order.
    private struct Piece: Sendable {
        enum Kind: Sendable {
            case literal(String)
            case token(FolderToken)
            /// The "/" between two levels.
            case separator
        }
        var kind: Kind
        /// The optional part the piece is inside, if any.
        var group: Int?
    }

    private struct Alternative: Sendable {
        var pieces: [Piece] = []

        /// The tokens outside brackets, in order, each once.
        var required: [FolderToken] {
            var seen = Set<FolderToken>()
            return pieces.compactMap { piece in
                guard piece.group == nil, case .token(let token) = piece.kind,
                      seen.insert(token).inserted
                else { return nil }
                return token
            }
        }

        func missing(for values: FolderPatternValues) -> [FolderToken] {
            required.filter { values.value(for: $0).isEmpty }
        }

        func folder(for values: FolderPatternValues) -> String? {
            guard missing(for: values).isEmpty else { return nil }
            // An optional part goes whole when any token inside it has no value.
            var dropped = Set<Int>()
            for piece in pieces {
                if let group = piece.group, case .token(let token) = piece.kind,
                   values.value(for: token).isEmpty {
                    dropped.insert(group)
                }
            }
            var levels = [""]
            for piece in pieces {
                if let group = piece.group, dropped.contains(group) { continue }
                switch piece.kind {
                case .literal(let text): levels[levels.count - 1] += text
                case .token(let token): levels[levels.count - 1] += values.value(for: token)
                case .separator: levels.append("")
                }
            }
            // Each level is made safe as a whole, which also caps its length.
            let names = levels.map(PathBuilder.sanitise)
            guard let last = names.last, !last.isEmpty else { return nil }
            return names.filter { !$0.isEmpty }.joined(separator: "/")
        }
    }

    public static func == (a: FolderPattern, b: FolderPattern) -> Bool {
        a.canonical == b.canonical
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(canonical)
    }

    /// - Throws: `FolderPatternProblem`: of everything wrong with the text, the problem
    ///   met first in reading order. (A text that is too long is said before any other.)
    public init(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FolderPatternProblem.empty }
        guard trimmed.count <= Self.maxTextLength else { throw FolderPatternProblem.tooLong }
        var reader = Reader(Array(trimmed))
        reader.read()
        if let first = reader.problems.min(by: { $0.position < $1.position }) {
            throw first.problem
        }
        self.text = trimmed
        canonical = reader.canonical
        alternatives = reader.alternatives
    }

    /// The tokens a book must have a value for whichever alternative files it: those
    /// outside brackets in every alternative.
    public var requiredTokens: Set<FolderToken> {
        var common = Set(alternatives.first?.required ?? [])
        for alternative in alternatives.dropFirst() { common.formIntersection(alternative.required) }
        return common
    }

    /// Every token that appears anywhere in the pattern, inside brackets or out, in any
    /// alternative: all that a book's folder can depend on.
    public var usedTokens: Set<FolderToken> {
        var used = Set<FolderToken>()
        for alternative in alternatives {
            for piece in alternative.pieces {
                if case .token(let token) = piece.kind { used.insert(token) }
            }
        }
        return used
    }

    /// Whether `{Kind}` appears anywhere, so that a book's folder depends on whether
    /// it has audio.
    public var usesKind: Bool {
        usedTokens.contains(.kind)
    }

    /// The name of the preset this pattern is, if it is one.
    public var presetName: String? {
        Self.presets.first { $0.pattern == self }?.name
    }

    /// The book's folder relative to the library, levels joined by "/"; nil when the
    /// book cannot be filed under this pattern.
    public func folder(for values: FolderPatternValues) -> String? {
        alternatives.lazy.compactMap { $0.folder(for: values) }.first
    }

    /// The tokens outside brackets the book has no value for, in pattern order, each
    /// once: of the first alternative that renders (so none), or else of the last.
    public func missingTokens(for values: FolderPatternValues) -> [FolderToken] {
        guard folder(for: values) == nil else { return [] }
        return alternatives.last?.missing(for: values) ?? []
    }

    // MARK: Why a book cannot be filed

    /// Why a book with these values has no folder under this pattern, as a sentence:
    /// "No narrator, which the folder layout needs." Nil when it can be filed.
    public func unfiledReason(for values: FolderPatternValues) -> String? {
        guard folder(for: values) == nil else { return nil }
        return Self.unfiledReason(missing: missingTokens(for: values))
    }

    /// The sentence for a book that lacks these: "No narrator or year, which the folder
    /// layout needs." With none named (every value is there, and still no name is left
    /// for the folder), a sentence saying that.
    public static func unfiledReason(missing: [FolderToken]) -> String {
        guard !missing.isEmpty else { return "The folder layout leaves no name for its folder." }
        let names = missing.map(\.noun)
        let list = names.count == 1
            ? names[0]
            : names.dropLast().joined(separator: ", ") + " or " + names[names.count - 1]
        return "No \(list), which the folder layout needs."
    }

    // MARK: Reading

    /// Reads a pattern in one pass, noting every problem with where it is.
    private struct Reader {
        let characters: [Character]
        var problems: [(position: Int, problem: FolderPatternProblem)] = []
        var alternatives: [Alternative] = []
        var canonical = ""

        // The alternative being read.
        private var pieces: [Piece] = []
        private var alternativeStart = 0
        private var groupCount = 0
        /// Where the open bracket is, while inside one.
        private var bracketStart: Int?
        // The level being read.
        private var levelStart = 0
        private var levelLiteral = ""
        private var levelHasToken = false
        private var levelHasRequiredTitle = false
        /// Where each level after the first starts.
        private var laterLevelStarts: [Int] = []

        init(_ characters: [Character]) {
            self.characters = characters
        }

        private mutating func note(_ problem: FolderPatternProblem, at position: Int) {
            problems.append((position, problem))
        }

        private var group: Int? { bracketStart == nil ? nil : groupCount }

        mutating func read() {
            var index = 0
            while index < characters.count {
                let character = characters[index]
                switch character {
                case "{":
                    index = readToken(at: index)
                    continue
                case "}":
                    note(.strayClosing, at: index)
                case "[":
                    if bracketStart != nil {
                        note(.nestedBracket, at: index)
                    } else {
                        bracketStart = index
                        groupCount += 1
                    }
                case "]":
                    if bracketStart == nil { note(.strayClosing, at: index) }
                    bracketStart = nil
                case "/":
                    endLevel()
                    pieces.append(Piece(kind: .separator, group: group))
                    levelStart = index + 1
                    laterLevelStarts.append(index + 1)
                case "|":
                    endAlternative(at: index)
                    if alternatives.count == FolderPattern.maxAlternatives {
                        note(.tooManyAlternatives, at: index)
                    }
                    alternativeStart = index + 1
                    levelStart = index + 1
                default:
                    levelLiteral.append(character)
                    pieces.append(Piece(kind: .literal(String(character)), group: group))
                }
                canonical.append(character)
                index += 1
            }
            endAlternative(at: characters.count)
        }

        /// Reads `{Name}` starting at the brace; returns where reading goes on.
        private mutating func readToken(at start: Int) -> Int {
            var end = start + 1
            while end < characters.count, !"{}[]/|".contains(characters[end]) { end += 1 }
            guard end < characters.count, characters[end] == "}" else {
                note(.unclosedBrace, at: start)
                canonical.append(contentsOf: characters[start..<end])
                return end
            }
            let name = String(characters[(start + 1)..<end])
            if let token = FolderToken.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) {
                pieces.append(Piece(kind: .token(token), group: group))
                levelHasToken = true
                if token == .title, bracketStart == nil { levelHasRequiredTitle = true }
                canonical += "{\(token.rawValue)}"
            } else {
                note(.unknownToken("{\(name)}"), at: start)
                canonical += "{\(name)}"
            }
            return end + 1
        }

        /// Checks the level just read, and starts the next.
        private mutating func endLevel() {
            if !levelHasToken, PathBuilder.sanitise(levelLiteral).isEmpty {
                let fixed = levelLiteral.trimmingCharacters(in: .whitespacesAndNewlines)
                note(fixed == "." || fixed == ".." ? .dotLevel : .emptyLevel, at: levelStart)
            }
            levelLiteral = ""
            levelHasToken = false
            levelHasRequiredTitle = false
        }

        private mutating func endAlternative(at end: Int) {
            defer {
                alternatives.append(Alternative(pieces: pieces))
                pieces = []
                bracketStart = nil
                laterLevelStarts = []
            }
            let whole = String(characters[alternativeStart..<end])
            guard !whole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                note(.empty, at: alternativeStart)
                endLevelQuietly()
                return
            }
            if let bracketStart { note(.unclosedBracket, at: bracketStart) }
            let levelCount = laterLevelStarts.count + 1
            if levelCount > FolderPattern.maxLevels {
                note(.tooManyLevels(levelCount), at: laterLevelStarts[FolderPattern.maxLevels - 1])
            }
            let lastHasTitle = levelHasRequiredTitle
            endLevel()
            if !lastHasTitle { note(.lastLevelNeedsTitle, at: end) }
        }

        private mutating func endLevelQuietly() {
            levelLiteral = ""
            levelHasToken = false
            levelHasRequiredTitle = false
        }
    }
}
