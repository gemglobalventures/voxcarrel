import Foundation

/// Finds an Audible ID written into a file's or folder's name, as download tools that
/// name files "Title [B09WXN61GL]" leave it.
public enum AudibleIDInName {
    /// The first Audible ID in the name, and the name without it.
    ///
    /// An ID is "B0" and eight more capitals or digits, standing as a whole word: no
    /// letter or digit directly before or after it, so a longer run that holds one is
    /// not an ID, and nor is an ISBN. Brackets around it go with it; what is left has
    /// its runs of spaces made one, loses a "-" left dangling at either end, and keeps
    /// one "-" where the ID stood between two.
    ///
    /// Read once, in time that grows with the length of the name.
    public static func find(in name: String) -> (id: String, cleaned: String)? {
        let characters = Array(name)
        guard let at = firstID(in: characters) else { return nil }
        var from = at, to = at + length

        // Its own brackets, with any spaces inside them.
        var before = from - 1, after = to
        while before >= 0, characters[before] == " " { before -= 1 }
        while after < characters.count, characters[after] == " " { after += 1 }
        if before >= 0, after < characters.count,
           (characters[before] == "[" && characters[after] == "]")
            || (characters[before] == "(" && characters[after] == ")") {
            from = before
            to = after + 1
        }

        let rest = String(characters[..<from]) + " " + String(characters[to...])
        // Where the ID stood between two dashes, one of them is left.
        var words: ArraySlice<Substring> = []
        for word in rest.split(separator: " ") where !(word == "-" && words.last == "-") { words.append(word) }
        while words.last == "-" { words.removeLast() }
        while words.first == "-" { words.removeFirst() }
        return (String(characters[at..<(at + length)]), words.joined(separator: " "))
    }

    private static let length = 10

    private static func firstID(in characters: [Character]) -> Int? {
        func isWordCharacter(_ character: Character) -> Bool { character.isLetter || character.isNumber }
        func isIDCharacter(_ character: Character) -> Bool {
            character.isASCII && (character.isUppercase || character.isNumber)
        }
        guard characters.count >= length else { return nil }
        for start in 0...(characters.count - length) where characters[start] == "B" && characters[start + 1] == "0" {
            if start > 0, isWordCharacter(characters[start - 1]) { continue }
            let end = start + length
            if end < characters.count, isWordCharacter(characters[end]) { continue }
            if characters[(start + 2)..<end].allSatisfy(isIDCharacter) { return start }
        }
        return nil
    }
}
