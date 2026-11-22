import Foundation

/// Tidying what lookup sources send, and judging how well a result matches.
public enum LookupText {
    // MARK: HTML

    /// The most of a piece of HTML that is read; what is past it is dropped and the text ends "…".
    static let htmlCharacterLimit = 50_000

    /// The text of a piece of HTML: `<p>` and `<br>` become line breaks, every other tag goes,
    /// entities are decoded and spacing is tidied. Text with no tags and no entities is only
    /// trimmed. Does not use the system HTML importer, so it is safe off the main thread.
    ///
    /// Read once from start to end, in time that grows with its length whatever it holds.
    /// Only the first `htmlCharacterLimit` characters are read.
    public static func plainText(fromHTML html: String) -> String {
        var html = html
        var cut = false
        if html.utf8.count > htmlCharacterLimit, html.count > htmlCharacterLimit {
            html = String(html.prefix(htmlCharacterLimit))
            cut = true
        }
        var scanner = HTMLScanner(Array(html.utf8))
        scanner.scan()
        guard scanner.changed else {
            let text = html.lookupTrimmed
            return cut ? text + "…" : text
        }
        let text = String(decoding: scanner.out, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let tidy = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{A0}" }).joined(separator: " ")
            // At most one blank line in a row, and none at the start.
            if tidy.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(tidy)
        }
        let tidy = lines.joined(separator: "\n").lookupTrimmed
        return cut ? tidy + "…" : tidy
    }

    /// Reads HTML as bytes, once. Every search ahead that fails is remembered, so the
    /// same stretch is never searched twice: hostile text cannot make it slow.
    struct HTMLScanner {
        let bytes: [UInt8]
        var out: [UInt8] = []
        /// True once a tag, a comment or an entity has been found.
        var changed = false
        private var index = 0
        private var noMoreGreaterThan = false
        private var noMoreCommentEnds = false
        private var noMoreClosings: Set<String> = []

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
            out.reserveCapacity(bytes.count)
        }

        private static let lessThan = UInt8(ascii: "<"), greaterThan = UInt8(ascii: ">")
        private static let slash = UInt8(ascii: "/"), ampersand = UInt8(ascii: "&"), semicolon = UInt8(ascii: ";")
        private static let newline = UInt8(ascii: "\n")

        private static func isLetter(_ byte: UInt8) -> Bool {
            (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
        }

        private static func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }

        private static func isSpace(_ byte: UInt8) -> Bool {
            byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 12
        }

        private static func lowered(_ byte: UInt8) -> UInt8 {
            byte >= 65 && byte <= 90 ? byte + 32 : byte
        }

        mutating func scan() {
            while index < bytes.count {
                let byte = bytes[index]
                if byte == Self.lessThan, skipMarkup() { continue }
                if byte == Self.ampersand, decodeEntity() { continue }
                out.append(byte)
                index += 1
            }
        }

        /// True when a comment or a tag began at `index` and has been dealt with.
        private mutating func skipMarkup() -> Bool {
            if matches("<!--", at: index) {
                guard !noMoreCommentEnds else { return false }
                guard let end = find("-->", from: index + 4) else {
                    noMoreCommentEnds = true
                    return false
                }
                index = end + 3
                changed = true
                return true
            }
            var nameStart = index + 1
            let closing = nameStart < bytes.count && bytes[nameStart] == Self.slash
            if closing { nameStart += 1 }
            guard nameStart < bytes.count, Self.isLetter(bytes[nameStart]) else { return false }
            var nameEnd = nameStart
            while nameEnd < bytes.count, Self.isLetter(bytes[nameEnd]) || Self.isDigit(bytes[nameEnd]) { nameEnd += 1 }
            guard !noMoreGreaterThan else { return false }
            guard let tagEnd = bytes[nameEnd...].firstIndex(of: Self.greaterThan) else {
                noMoreGreaterThan = true
                return false
            }
            let name = String(decoding: bytes[nameStart..<nameEnd].map(Self.lowered), as: UTF8.self)
            changed = true
            index = tagEnd + 1
            switch name {
            case "script", "style":
                // What is inside is not text. Without an end, only the tag goes.
                if !closing, let after = endOfClosing(name, from: index) { index = after }
            case "br":
                if !closing { out.append(Self.newline) }
            case "p":
                out.append(Self.newline)
                out.append(Self.newline)
            default:
                break
            }
            return true
        }

        /// The index just past `</name>` (spaces allowed before `>`), searching from `start`.
        private mutating func endOfClosing(_ name: String, from start: Int) -> Int? {
            guard !noMoreClosings.contains(name) else { return nil }
            let wanted = "</" + name
            var from = start
            while let found = find(wanted, from: from) {
                var after = found + wanted.utf8.count
                while after < bytes.count, Self.isSpace(bytes[after]) { after += 1 }
                if after < bytes.count, bytes[after] == Self.greaterThan { return after + 1 }
                from = found + 1
            }
            noMoreClosings.insert(name)
            return nil
        }

        /// True when an entity began at `index` and its character has been written.
        private mutating func decodeEntity() -> Bool {
            // "&" + up to 11 characters of name + ";"
            let limit = min(bytes.count, index + 13)
            var end = index + 1
            while end < limit, bytes[end] != Self.semicolon {
                let byte = bytes[end]
                guard Self.isLetter(byte) || Self.isDigit(byte) || (byte == UInt8(ascii: "#") && end == index + 1) else {
                    return false
                }
                end += 1
            }
            guard end < limit, end > index + 1 else { return false }
            let name = String(decoding: bytes[(index + 1)..<end], as: UTF8.self)
            guard let text = LookupText.decoded(name) else { return false }
            out.append(contentsOf: Array(text.utf8))
            index = end + 1
            changed = true
            return true
        }

        /// Whether the ASCII `text` is at `position`, ignoring case.
        private func matches(_ text: String, at position: Int) -> Bool {
            let wanted = Array(text.utf8)
            guard position + wanted.count <= bytes.count else { return false }
            for offset in wanted.indices where Self.lowered(bytes[position + offset]) != wanted[offset] { return false }
            return true
        }

        /// The first place at or after `start` where the lower-case ASCII `text` is, ignoring case.
        private func find(_ text: String, from start: Int) -> Int? {
            let wanted = Array(text.utf8)
            guard let first = wanted.first, start <= bytes.count - wanted.count else { return nil }
            var position = start
            let last = bytes.count - wanted.count
            while position <= last {
                if Self.lowered(bytes[position]) == first, matches(text, at: position) { return position }
                position += 1
            }
            return nil
        }
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
    ]

    /// What the entity called `name` ("amp", "#39", "#x2014") stands for; nil when it is
    /// not an entity. One that stands for a control character stands for nothing.
    private static func decoded(_ name: String) -> String? {
        guard name.hasPrefix("#") else {
            guard name.count >= 2, let first = name.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) else {
                return nil
            }
            return namedEntities[name.lowercased()]
        }
        let digits = name.dropFirst()
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let value: UInt32?
        if digits.first == "x" || digits.first == "X" {
            let hex = digits.dropFirst()
            value = hex.isEmpty || hex.count > 8 ? nil : UInt32(hex, radix: 16)
        } else {
            value = digits.count > 8 ? nil : UInt32(digits, radix: 10)
        }
        guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return nil }
        if scalar.value == 0xA0 { return " " }
        if isUnwanted(scalar), scalar != "\n", scalar != "\t" { return "" }
        return String(Character(scalar))
    }

    // MARK: Cleaning what a source sends

    /// The most characters kept of a title or a name, of any other one-line value, and of a description.
    public static let nameLimit = 500
    public static let lineLimit = 200
    public static let summaryLimit = 50_000

    /// Control characters, and the characters that turn the direction of the text
    /// around them (overrides, embeddings and isolates): never wanted in a book's details.
    static func isUnwanted(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: true
        case 0x202A...0x202E, 0x2066...0x2069: true
        default: false
        }
    }

    /// A value from a source, made safe to keep: no control or direction-turning
    /// characters, no more than `limit` characters, trimmed; nil when nothing is left.
    /// On one line unless `multiline`: line breaks and tabs become single spaces.
    public static func cleaned(_ raw: String?, limit: Int, multiline: Bool = false) -> String? {
        guard let raw else { return nil }
        var scalars = String.UnicodeScalarView()
        var count = 0
        // A little more than is kept is read, so that what is trimmed away does not count.
        let readLimit = limit * 4 + 64
        var pendingSpace = false
        for scalar in raw.unicodeScalars {
            guard count < readLimit else { break }
            let isBreak = scalar == "\n" || scalar == "\r" || scalar.value == 0x2028 || scalar.value == 0x2029
            if multiline {
                if scalar == "\r" { continue }
                if isBreak {
                    scalars.append("\n")
                    count += 1
                    continue
                }
                if scalar == "\t" {
                    scalars.append(" ")
                    count += 1
                    continue
                }
            } else if isBreak || scalar == "\t" || scalar == " " {
                pendingSpace = true
                continue
            }
            if isUnwanted(scalar) { continue }
            if pendingSpace {
                if !scalars.isEmpty { scalars.append(" ") }
                pendingSpace = false
            }
            scalars.append(scalar)
            count += 1
        }
        var text = String(scalars).lookupTrimmed
        if text.count > limit { text = String(text.prefix(limit)).lookupTrimmed }
        return text.isEmpty ? nil : text
    }

    /// Names from a source: each cleaned, empty ones dropped, at most fifty.
    public static func cleanedNames(_ raw: [String]) -> [String] {
        Array(raw.lazy.compactMap { cleaned($0, limit: nameLimit) }.prefix(50))
    }

    /// A year from a source; nil unless it is from 1 to 9999.
    public static func year(_ raw: Int?) -> Int? {
        guard let raw, (1...9999).contains(raw) else { return nil }
        return raw
    }

    // MARK: Languages

    /// "english", "eng", "en-GB", "EN" -> "en". Nil when not recognised.
    public static func languageCode(_ raw: String) -> String? {
        let text = raw.lookupTrimmed.lowercased()
        guard !text.isEmpty else { return nil }
        if let code = languageByName[text] { return code }
        // A code with a region or script: "en-GB", "pt_BR", "zh-Hant-TW".
        guard let first = text.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init),
              first.allSatisfy({ $0.isASCII && $0.isLetter })
        else { return nil }
        switch first.count {
        case 2: return twoLetterCodes.contains(first) ? first : nil
        case 3: return languageByName[first] ?? Locale.LanguageCode(first).identifier(.alpha2).flatMap {
                twoLetterCodes.contains($0) ? $0 : nil
            }
        default: return languageByName[first]
        }
    }

    /// Two-letter code, then every other spelling: English names and three-letter codes of
    /// both families (`fre`/`fra`).
    private static let languages: [(code: String, others: [String])] = [
        ("en", ["english", "eng"]),
        ("fr", ["french", "fre", "fra"]),
        ("de", ["german", "ger", "deu"]),
        ("es", ["spanish", "castilian", "spa"]),
        ("it", ["italian", "ita"]),
        ("pt", ["portuguese", "por"]),
        ("nl", ["dutch", "flemish", "dut", "nld"]),
        ("sv", ["swedish", "swe"]),
        ("da", ["danish", "dan"]),
        ("no", ["norwegian", "nor"]),
        ("fi", ["finnish", "fin"]),
        ("pl", ["polish", "pol"]),
        ("ru", ["russian", "rus"]),
        ("ja", ["japanese", "jpn"]),
        ("zh", ["chinese", "mandarin", "mandarin chinese", "mandarin_chinese", "chi", "zho"]),
        ("ko", ["korean", "kor"]),
        ("tr", ["turkish", "tur"]),
        ("ar", ["arabic", "ara"]),
        ("hi", ["hindi", "hin"]),
        ("cs", ["czech", "cze", "ces"]),
        ("el", ["greek", "gre", "ell"]),
        ("he", ["hebrew", "heb"]),
        ("hu", ["hungarian", "hun"]),
        ("ro", ["romanian", "rum", "ron"]),
        ("uk", ["ukrainian", "ukr"]),
        ("ca", ["catalan", "cat"]),
        ("af", ["afrikaans", "afr"]),
        ("is", ["icelandic", "ice", "isl"]),
        ("la", ["latin", "lat"]),
        ("bg", ["bulgarian", "bul"]),
        ("hr", ["croatian", "hrv"]),
        ("sr", ["serbian", "srp"]),
        ("sk", ["slovak", "slo", "slk"]),
        ("sl", ["slovenian", "slovene", "slv"]),
        ("th", ["thai", "tha"]),
        ("vi", ["vietnamese", "vie"]),
        ("id", ["indonesian", "ind"]),
        ("ta", ["tamil", "tam"]),
        ("te", ["telugu", "tel"]),
        ("bn", ["bengali", "ben"]),
        ("mr", ["marathi", "mar"]),
        ("ur", ["urdu", "urd"]),
        ("fa", ["persian", "farsi", "per", "fas"]),
        ("cy", ["welsh", "wel", "cym"]),
        ("ga", ["irish", "gle"]),
    ]

    private static let languageByName: [String: String] = {
        var table: [String: String] = [:]
        for language in languages {
            for other in language.others { table[other] = language.code }
        }
        return table
    }()

    private static let twoLetterCodes: Set<String> = Set(languages.map(\.code)).union(
        Locale.LanguageCode.isoLanguageCodes.map(\.identifier).filter { $0.count == 2 }
    )

    // MARK: ISBN

    /// Digits and a final X only; nil unless 10 or 13 characters remain.
    public static func isbn(_ raw: String) -> String? {
        var tidy = ""
        for character in raw.lookupTrimmed where character != "-" && character != " " {
            tidy.append(character)
        }
        guard tidy.count == 10 || tidy.count == 13 else { return nil }
        if tidy.count == 10, let last = tidy.last, last == "x" || last == "X" {
            tidy.removeLast()
            tidy.append("X")
        }
        // X is a check digit only at the end of a 10-character ISBN.
        let digits = tidy.count == 10 && tidy.hasSuffix("X") ? tidy.dropLast() : Substring(tidy)
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return tidy
    }

    // MARK: People

    /// A person's name from a library catalogue, in the order it is said:
    /// "Le Carré, John, 1931-2020" -> "John Le Carré". An accent written after its letter
    /// is joined to it; dates, a fuller form in brackets and a final comma or full stop
    /// are dropped. A name already in its natural order is unchanged.
    public static func personName(fromCatalogue raw: String) -> String {
        guard var text = cleaned(raw.precomposedStringWithCanonicalMapping, limit: nameLimit) else { return "" }
        // "(John Ronald Reuel)"
        text = text.replacingOccurrences(of: "\\s*\\([^()]{0,200}\\)", with: "", options: .regularExpression)
        // ", 1931-2020", ", 1951-", ", b. 1951", ", d. 1900" at the end.
        text = text.replacingOccurrences(
            of: "[,\\s]+(?:(?:b|d|fl|ca)\\. ?)?[0-9]{3,4}\\??(?:\\s?-\\s?(?:[0-9]{3,4}\\??)?)?[.,\\s]*$", with: "",
            options: .regularExpression)
        text = withoutFinalPunctuation(text)
        var parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).lookupTrimmed }
        while let last = parts.last, last.isEmpty { parts.removeLast() }
        guard let surname = parts.first, !surname.isEmpty else { return "" }

        var suffix: String?
        if parts.count == 3, isNameSuffix(parts[2]) { suffix = parts.removeLast() }
        var name: String
        if parts.count == 2, !parts[1].isEmpty, !isCompanyWord(parts[1]) {
            name = "\(parts[1]) \(surname)"
        } else {
            name = parts.filter { !$0.isEmpty }.joined(separator: ", ")
        }
        if let suffix { name += " " + suffix }
        return name.lookupTrimmed
    }

    /// Without the commas, spaces and full stop at its end. A full stop that ends an
    /// initial or a suffix stays: "J. R. R.", "Jr.".
    private static func withoutFinalPunctuation(_ text: String) -> String {
        var text = text
        while let last = text.last, last == "." || last == "," || last == " " {
            if last == ".", let word = text.dropLast().split(whereSeparator: { $0 == " " || $0 == "," }).last,
               word.count == 1 || isNameSuffix(String(word)) { break }
            text.removeLast()
        }
        return text
    }

    private static func isNameSuffix(_ word: String) -> Bool {
        ["jr", "sr", "ii", "iii", "iv"].contains(word.lowercased().replacingOccurrences(of: ".", with: ""))
    }

    private static func isCompanyWord(_ word: String) -> Bool {
        ["inc", "ltd", "llc", "co", "corp"].contains(word.lowercased().replacingOccurrences(of: ".", with: ""))
    }

    /// True when the two names are the same person: ignoring case, accents, punctuation,
    /// the full stops and spaces of initials, and the order "Surname, Given". An empty
    /// name is nobody, not even another empty name.
    public static func samePerson(_ a: String, _ b: String) -> Bool {
        let first = nameWords(a), second = nameWords(b)
        guard !first.isEmpty, !second.isEmpty else { return false }
        return first.sorted() == second.sorted() || first.joined() == second.joined()
    }

    /// The words of a name for comparing, initials that stand together joined into one word.
    private static func nameWords(_ name: String) -> [String] {
        var words: [String] = []
        var initials = ""
        for word in comparable(personName(fromCatalogue: name).replacingOccurrences(of: ".", with: " "), droppingArticle: false) {
            if word.count == 1 {
                initials += word
                continue
            }
            if !initials.isEmpty { words.append(initials) }
            initials = ""
            words.append(word)
        }
        if !initials.isEmpty { words.append(initials) }
        return words
    }

    // MARK: Lengths

    /// The most of an extent that is read.
    static let extentCharacterLimit = 500
    /// The longest length believed: 1,000 hours.
    static let longestSeconds = 3_600_000.0

    /// The playing time in a catalogue's description of what a recording is:
    /// "12 sound cassettes (18 hr.)", "9 hr., 30 min." -> seconds. Nil when it gives no
    /// time, a time for each part only, or one that is not from a second to 1,000 hours.
    public static func seconds(fromExtent text: String) -> Double? {
        let text = String(text.prefix(extentCharacterLimit)).lowercased()
        guard !text.contains("each") else { return nil }
        var seconds = 0.0
        var found = false
        // "10 1/2 hr."
        if let parts = firstMatch("(?<![0-9./])(?:([0-9]{1,4}) )?([0-9]{1,2})/([0-9]{1,2}) ?(?:hrs?|hours?)(?![a-z])", in: text),
           let over = Double(parts[2]), let under = Double(parts[3]), under > 0 {
            seconds += ((Double(parts[1]) ?? 0) + over / under) * 3600
            found = true
        } else if let parts = firstMatch("(?<![0-9.,/])([0-9]{1,4}(?:\\.[0-9]{1,2})?) ?(?:hrs?|hours?)(?![a-z])", in: text),
                  let hours = Double(parts[1]) {
            seconds += hours * 3600
            found = true
        }
        if let parts = firstMatch("(?<![0-9.,/])([0-9]{1,6}) ?(?:mins?|minutes?)(?![a-z])", in: text), let minutes = Double(parts[1]) {
            seconds += minutes * 60
            found = true
        }
        if let parts = firstMatch("(?<![0-9.,/])([0-9]{1,6}) ?(?:secs?|seconds?)(?![a-z])", in: text), let more = Double(parts[1]) {
            seconds += more
            found = true
        }
        guard found, seconds >= 1, seconds <= longestSeconds else { return nil }
        return seconds
    }

    /// The whole match and its groups (empty for a group that took no part); nil for no match.
    static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }

    /// "18h 0m", "45m".
    static func lengthLabel(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    // MARK: Matching

    /// 0...1: how well a found title and author match what was asked for. 1 is an exact
    /// title and author, ignoring case, accents, punctuation and a leading article.
    public static func matchScore(title: String, author: String, query: LookupQuery) -> Double {
        titleScore(found: comparable(title), asked: comparable(query.title))
            * (0.7 + 0.3 * authorScore(found: comparable(author, droppingArticle: false),
                                       asked: comparable(query.author, droppingArticle: false)))
    }

    /// Lower-case words without accents or punctuation, and without a leading article.
    static func comparable(_ text: String, droppingArticle: Bool = true) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        var spaced = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                spaced.append(scalar)
            } else if scalar != "'" && scalar != "’" {
                spaced.append(" ")
            }
        }
        var words = String(spaced).split(separator: " ").map(String.init)
        if droppingArticle, words.count > 1, ["the", "a", "an"].contains(words[0]) { words.removeFirst() }
        return words
    }

    private static func titleScore(found: [String], asked: [String]) -> Double {
        if asked.isEmpty { return 1 }
        if found.isEmpty { return 0 }
        if found == asked { return 1 }
        // One begins with the other: a subtitle, a box set, a sequel named after the first book.
        if found.starts(with: asked) || asked.starts(with: found) { return 0.6 }
        let common = Set(found).intersection(asked).count
        let all = Set(found).union(asked).count
        return 0.5 * Double(common) / Double(all)
    }

    private static func authorScore(found: [String], asked: [String]) -> Double {
        if asked.isEmpty { return 1 }
        let foundWords = Set(found), askedWords = Set(asked)
        if foundWords == askedWords { return 1 }   // "Herbert, Frank" is "Frank Herbert"
        let common = askedWords.intersection(foundWords).count
        if common == 0 { return 0 }
        return 0.5 + 0.4 * Double(common) / Double(askedWords.count)
    }
}
