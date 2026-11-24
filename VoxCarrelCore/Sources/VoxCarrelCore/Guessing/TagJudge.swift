import Foundation

/// Says when what a file's tags give for the title or the author is not to be believed:
/// what a program left there when the file was made, not what the book is called.
public enum TagJudge {
    /// Endings of a title that is the name of the document it was made from.
    static let documentEndings: [String] = [
        ".doc", ".docx", ".pdf", ".indd", ".qxd", ".qxp", ".dvi", ".ps", ".rtf", ".txt", ".p65", ".pmd", ".fm",
        ".tex", ".wpd", ".ppt", ".pptx", ".xls",
    ]

    /// Titles that say nothing, compared without regard to case.
    static let emptyTitles: Set<String> = [
        "untitled", "untitled document", "unknown", "no title", "table of contents", "front matter",
    ]

    /// Authors that are whoever was logged in, not who wrote the book.
    static let emptyAuthors: Set<String> = [
        "unknown", "unknown author", "author", "user", "owner", "admin", "administrator", "preferred customer",
        "valued customer", "customer", "trader", "default", "none", "anonymous", "ed", "pc", "home", "test",
    ]

    /// True for a title a program left behind: "Microsoft Word - sfft.doc", "ebook.indd",
    /// "1", "CHAPTER 1", "Track  1", "PII: S1386-4181(00)00007-0", or nothing.
    public static func isJunkTitle(_ title: String) -> Bool {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        guard !lower.isEmpty else { return true }
        if lower.hasPrefix("microsoft word - ") || lower.hasPrefix("microsoft powerpoint - ") || lower.hasPrefix("pii:") {
            return true
        }
        if documentEndings.contains(where: { lower.hasSuffix($0) }) { return true }
        if emptyTitles.contains(lower) { return true }
        // A page number. ("1984" is a book.)
        if !text.contains(where: \.isLetter), text.count <= 2 { return true }
        // "Chapter 1", "Track  12", "Part 3", "Disc 2", "CD1".
        let words = lower.split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" }).map(String.init)
        let counters: Set<String> = ["chapter", "track", "part", "disc", "disk", "cd", "section", "page", "file"]
        if words.count == 2, counters.contains(words[0]), words[1].allSatisfy(\.isNumber) { return true }
        if words.count == 1, let word = words.first,
           let counter = counters.first(where: { word.hasPrefix($0) }),
           !word.dropFirst(counter.count).isEmpty, word.dropFirst(counter.count).allSatisfy(\.isNumber) {
            return true
        }
        return false
    }

    /// The author as it can be believed: nil for a login name or a stand-in ("maryam",
    /// "b1cspra", "Preferred Customer", "."), and without a leading "By ".
    public static func author(_ author: String) -> String? {
        var text = author.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, last == ";" || last == "," { text.removeLast() }
        if text.lowercased().hasPrefix("by "), text.count > 3 {
            text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        let lower = text.lowercased()
        guard text.contains(where: \.isLetter), !emptyAuthors.contains(lower) else { return nil }
        // One word with a digit in it, or one word all in small letters, is a login name.
        if !text.contains(" ") {
            if text.contains(where: \.isNumber) { return nil }
            if text == lower { return nil }
        }
        // "KevinH [ MCKAY ]", "Mark Torrey (bysoundalone.net)": the name before the bracket.
        if let bracket = text.firstIndex(where: { $0 == "[" || $0 == "(" }) {
            let before = text[..<bracket].trimmingCharacters(in: .whitespaces)
            return before.contains(" ") ? before : nil
        }
        return text
    }

    /// The words of a name that tell something: four letters or more, letters only.
    static func tellingWords(_ text: String) -> Set<String> {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let words = folded.split(whereSeparator: { !$0.isLetter }).map(String.init)
        return Set(words.filter { $0.count >= 4 })
    }

    /// True when a file's name says enough to be believed over a tag that shares
    /// nothing with it: three telling words or more.
    public static func nameIsTelling(_ name: String) -> Bool {
        tellingWords(name).count >= 3
    }

    /// True when a title from a tag and a file's name have a telling word in common.
    public static func agree(tagTitle: String, fileName: String) -> Bool {
        !tellingWords(tagTitle).isDisjoint(with: tellingWords(fileName))
    }
}
