import Foundation

/// Tidying what lookup sources send, and judging how well a result matches.
public enum LookupText {
    // MARK: HTML

    /// The text of a piece of HTML: `<p>` and `<br>` become line breaks, every other tag goes,
    /// entities are decoded and spacing is tidied. Text with no tags and no entities is only
    /// trimmed. Does not use the system HTML importer, so it is safe off the main thread.
    public static func plainText(fromHTML html: String) -> String {
        let whole = NSRange(html.startIndex..., in: html)
        guard tag.firstMatch(in: html, range: whole) != nil || entity.firstMatch(in: html, range: whole) != nil else {
            return html.lookupTrimmed
        }
        var text = html.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        text = replace(hidden, in: text, with: "")
        text = replace(lineBreak, in: text, with: "\n")
        text = replace(paragraph, in: text, with: "\n\n")
        text = replace(tag, in: text, with: "")
        text = decodingEntities(text)

        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let tidy = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{A0}" }).joined(separator: " ")
            // At most one blank line in a row, and none at the start.
            if tidy.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(tidy)
        }
        return lines.joined(separator: "\n").lookupTrimmed
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are fixed and known to compile.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static let hidden = regex("<(script|style)\\b[^>]*>.*?</\\1\\s*>|<!--.*?-->")
    private static let lineBreak = regex("<br\\b[^>]*>")
    private static let paragraph = regex("</?p(\\s[^>]*)?>")
    private static let tag = regex("</?[a-z][^>]*>|<!--.*?-->")
    private static let entity = regex("&(#[0-9]{1,8}|#x[0-9a-f]{1,8}|[a-z][a-z0-9]{1,10});")

    private static func replace(_ regex: NSRegularExpression, in text: String, with replacement: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                       withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
    ]

    /// Each entity decoded once, in one pass, so "&amp;lt;" becomes "&lt;" and no further.
    private static func decodingEntities(_ text: String) -> String {
        var out = ""
        var position = text.startIndex
        for match in entity.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let nameRange = Range(match.range(at: 1), in: text) else { continue }
            out += text[position..<range.lowerBound]
            out += decoded(String(text[nameRange])) ?? String(text[range])
            position = range.upperBound
        }
        out += text[position...]
        return out
    }

    private static func decoded(_ name: String) -> String? {
        guard name.hasPrefix("#") else { return namedEntities[name.lowercased()] }
        let digits = name.dropFirst()
        let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
        guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return nil }
        return scalar.value == 0xA0 ? " " : String(Character(scalar))
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
