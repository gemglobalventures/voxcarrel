import Foundation

/// How two titles stand to each other.
public enum TitleRelation: Equatable, Sendable {
    /// The same title, edition words aside.
    case same
    /// One is the other with a subtitle after it: "Dune" and "Dune: Messiah".
    case sameUpToSubtitle
    case different
}

/// Compares titles to tell whether two things are the same book.
public enum TitleMatch {
    /// Words that say which edition a recording is, not what the book is called.
    static let editionWords: [String] = [
        "unabridged", "abridged", "audiobook", "audio book", "audio edition", "dramatized", "dramatised",
        "full cast",
    ]

    /// The title for comparing: edition words at its end dropped, then lower-cased words
    /// without accents, punctuation or a leading article, as the lookup compares titles.
    /// A "+" or "#" written on to a word is kept, as a word: "C++" is not "C".
    ///
    /// An edition word is dropped when it stands alone in round or square brackets at
    /// the end, or after a final " - " or ", "; never from the middle of a title, and
    /// never when nothing else would be left ("Unabridged" is then the title).
    public static func core(_ title: String) -> String {
        parts(title).core
    }

    /// `.same` when the cores are equal; `.sameUpToSubtitle` when one title, cut at its
    /// first subtitle separator, has the other's core; otherwise `.different`. A title
    /// with nothing to compare is different from every title, another such one included.
    public static func relation(_ a: String, _ b: String) -> TitleRelation {
        relation(parts(a), parts(b))
    }

    /// A title read from a file name, as it was probably written: "_ " after a word,
    /// which is how a colon is often saved, becomes ": "; any other "_" becomes a space;
    /// "꞉" (U+A789, which file systems write for a colon) becomes ":", closed up to the
    /// word before it; then runs of spaces are made one and those at the ends go. Text
    /// with neither an underscore nor that colon is returned as it is.
    ///
    /// For text taken from a name only: what tags say is never changed.
    public static func tidyFromFileName(_ text: String) -> String {
        guard text.contains(where: { $0 == "_" || $0 == fileSystemColon }) else { return text }
        let characters = Array(text)
        var out: [Character] = []
        out.reserveCapacity(characters.count)
        for (index, character) in characters.enumerated() {
            if character == fileSystemColon {
                while out.last == " " { out.removeLast() }
                out.append(":")
                continue
            }
            guard character == "_" else {
                out.append(character)
                continue
            }
            let afterAWord = index > 0 && characters[index - 1] != " " && characters[index - 1] != "_"
            let beforeASpace = index + 1 < characters.count && characters[index + 1] == " "
            out.append(afterAWord && beforeASpace ? ":" : " ")
        }
        return String(out).split(separator: " ").joined(separator: " ")
    }

    /// U+A789, the letter that stands for a colon in a file's name.
    static let fileSystemColon: Character = "\u{A789}"

    // MARK: Compared many times

    /// What of a title is compared, worked out once.
    struct Parts: Equatable, Sendable {
        /// `core(_:)` of the title.
        var core: String
        /// The core of what stands before the first subtitle separator; nil when the
        /// title has no separator or nothing to compare stands before it.
        var head: String?
    }

    static func parts(_ title: String) -> Parts {
        let characters = Array(title)
        var head: String?
        if let cut = firstSeparator(in: characters) {
            let before = comparable(characters[..<cut])
            if !before.isEmpty { head = before }
        }
        return Parts(core: comparable(characters[...]), head: head)
    }

    static func relation(_ a: Parts, _ b: Parts) -> TitleRelation {
        guard !a.core.isEmpty, !b.core.isEmpty else { return .different }
        if a.core == b.core { return .same }
        if a.head == b.core || b.head == a.core { return .sameUpToSubtitle }
        return .different
    }

    /// Where the first of ": ", "꞉ " (the colon of file names), "_ ", " - ", " – " and
    /// " — " begins.
    private static func firstSeparator(in characters: [Character]) -> Int? {
        for index in characters.indices.dropLast() {
            let character = characters[index], next = characters[index + 1]
            if next == " ", character == ":" || character == fileSystemColon || character == "_" { return index }
            if character == " ", next == "-" || next == "–" || next == "—",
               index + 2 < characters.count, characters[index + 2] == " " {
                return index
            }
        }
        return nil
    }

    /// The text without the edition words at its end, as words for comparing.
    private static func comparable(_ characters: ArraySlice<Character>) -> String {
        func words(_ slice: ArraySlice<Character>) -> String {
            LookupText.comparable(spellingOutSigns(slice)).joined(separator: " ")
        }
        let kept = words(characters[characters.startIndex..<endWithoutEditionWords(characters)])
        return kept.isEmpty ? words(characters) : kept
    }

    /// The text with a "+" or "#" that is written on to a word spelled out, so that it
    /// is compared and not dropped as punctuation: "C++" and "C#" are not "C". A sign
    /// that stands apart ("Batman #1", "One + One") is left to be dropped.
    private static func spellingOutSigns(_ characters: ArraySlice<Character>) -> String {
        guard characters.contains(where: { $0 == "+" || $0 == "#" }) else { return String(characters) }
        var out = ""
        var onAWord = false
        for character in characters {
            if onAWord, character == "+" || character == "#" {
                out += character == "+" ? " plus " : " sharp "
                // "++" is two of them; nothing but another sign carries on from a sign.
                continue
            }
            onAWord = character.isLetter || character.isNumber
            out.append(character)
        }
        return out
    }

    /// The text without the edition words at its end, and those words as they were
    /// written: "Tom Clancy (Unabridged)" is "Tom Clancy" and "(Unabridged)". The tail
    /// is empty when there are none.
    static func settingAsideEditionWords(_ text: String) -> (body: String, tail: String) {
        let characters = Array(text)
        let end = endWithoutEditionWords(characters[...])
        let body = String(characters[..<end]).trimmingCharacters(in: .whitespaces)
        // Never when nothing else would be left.
        guard end < characters.count, !body.isEmpty else { return (text, "") }
        return (
            body,
            String(characters[end...]).trimmingCharacters(in: .whitespaces)
        )
    }

    /// The index the text ends at once the edition words at its end are dropped. Each
    /// step looks at no more than the few characters an edition word takes.
    private static func endWithoutEditionWords(_ characters: ArraySlice<Character>) -> Int {
        let start = characters.startIndex
        var end = characters.endIndex
        func isEditionWord(_ range: Range<Int>) -> Bool {
            let text = String(characters[range]).trimmingCharacters(in: .whitespaces).lowercased()
            return editionWords.contains(text)
        }
        let longest = (editionWords.map(\.count).max() ?? 0) + 4

        while true {
            while end > start, characters[end - 1] == " " { end -= 1 }
            guard end > start else { return end }
            let last = characters[end - 1]
            if last == ")" || last == "]" {
                // "(Unabridged)", "[ Audiobook ]"
                let opener: Character = last == ")" ? "(" : "["
                let from = max(start, end - 1 - longest)
                guard let open = characters[from..<(end - 1)].lastIndex(where: { $0 == "(" || $0 == "[" }),
                      characters[open] == opener, isEditionWord((open + 1)..<(end - 1))
                else { return end }
                end = open
                continue
            }
            // " - Unabridged", ", Unabridged"
            var cut: Int?
            for word in editionWords {
                let begins = end - word.count
                guard begins - 2 >= start, isEditionWord(begins..<end), characters[begins - 1] == " " else { continue }
                if characters[begins - 2] == "," {
                    cut = begins - 2
                } else if begins - 3 >= start, characters[begins - 2] == "-", characters[begins - 3] == " " {
                    cut = begins - 3
                }
                if cut != nil { break }
            }
            guard let cut else { return end }
            end = cut
        }
    }
}
