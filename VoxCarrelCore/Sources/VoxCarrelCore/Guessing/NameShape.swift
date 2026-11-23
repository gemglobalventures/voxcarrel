import Foundation

/// Judges whether a piece of text is shaped like a person's name. Shape only: it knows
/// no names, so "Slow Horses" is as name-shaped as "Mick Herron".
public enum NameShape {
    /// The longest text that is taken for a name.
    static let longest = 40

    /// Words that stand inside a name without a capital: "John le Carré".
    static let particles: Set<String> = [
        "de", "del", "della", "van", "von", "der", "den", "le", "la", "du", "da", "dos", "bin", "ibn",
        "al", "ap", "mac", "mc", "o'", "st.",
    ]

    /// Words that begin or join titles and are hardly ever part of a person's name. A
    /// text with one of them is not a name. Kept short and to words that are not names
    /// themselves: "King", "Rose" and "Child" are not here.
    static let titleWords: Set<String> = [
        "the", "a", "an", "of", "in", "on", "at", "to", "for", "with", "and", "or", "how", "why", "what",
        "my", "your",
        "over", "under", "from", "by", "into", "about", "after", "before", "between", "through",
        "without", "against", "is", "are", "was", "not", "this", "that", "these", "those", "we", "our",
        "his", "her", "their", "its", "as", "but", "if", "when", "where", "who", "vs", "vs.",
        "project", "book", "volume", "vol", "vol.", "part", "edition", "guide", "handbook",
        "introduction", "history", "story", "stories", "complete", "collected", "chapter", "series",
        "trilogy", "audiobook", "unabridged", "abridged",
    ]

    /// True when the text is shaped like one person's name, or several joined by "&" or
    /// "and": two to four words, each beginning with a capital, or an initial ("F.",
    /// "J.R.R."), or a particle ("le", "van"), with at least one whole word among them;
    /// no digits; none of the words that mark a title; at most 40 characters.
    /// "Surname, Given" counts as well.
    ///
    /// Read once, in time that grows with the length of the text.
    public static func looksLikePerson(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= longest, !trimmed.contains(where: \.isNumber) else {
            return false
        }
        let words = trimmed.split(separator: " ").map(String.init)
        let people = words.split(omittingEmptySubsequences: false) { $0 == "&" || $0.lowercased() == "and" }
        return people.allSatisfy { isOnePerson(Array($0)) }
    }

    private enum Word { case whole, initial, particle }

    private static func isOnePerson(_ given: [String]) -> Bool {
        var words = given
        // "Dalton, James F." is "James F. Dalton".
        let commas = words.filter { $0.contains(",") }
        if !commas.isEmpty {
            guard commas.count == 1, let at = words.firstIndex(where: { $0.hasSuffix(",") }),
                  words[at].count > 1, !words[at].dropLast().contains(","), at + 1 < words.count
            else { return false }
            words[at].removeLast()
            words = Array(words[(at + 1)...] + words[...at])
        }
        guard (2...4).contains(words.count) else { return false }
        var wholeWords = 0
        for word in words {
            guard let kind = kind(of: word) else { return false }
            if kind == .whole { wholeWords += 1 }
        }
        return wholeWords > 0
    }

    /// Nil for a word that no name has.
    private static func kind(of word: String) -> Word? {
        let lowered = word.lowercased()
        if titleWords.contains(lowered) { return nil }
        if isInitials(word) { return .initial }
        if particles.contains(lowered) { return .particle }
        // A capital, then letters, apostrophes and hyphens; a full stop may end it ("Jr.").
        var letters = Substring(word)
        if letters.hasSuffix(".") { letters.removeLast() }
        guard let first = letters.first, first.isLetter, first.isUppercase,
              letters.dropFirst().allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" })
        else { return nil }
        return .whole
    }

    /// "F.", "J.R.R.", or one capital on its own.
    private static func isInitials(_ word: String) -> Bool {
        let characters = Array(word)
        if characters.count == 1 { return characters[0].isLetter && characters[0].isUppercase }
        guard characters.count % 2 == 0 else { return false }
        for (index, character) in characters.enumerated() {
            if index % 2 == 0 {
                guard character.isLetter, character.isUppercase else { return false }
            } else if character != "." {
                return false
            }
        }
        return true
    }
}
