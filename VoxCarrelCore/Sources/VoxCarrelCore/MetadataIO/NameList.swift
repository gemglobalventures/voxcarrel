import Foundation

/// Stores several people (authors, narrators) in one text tag.
enum NameList {
    static let separator = "; "

    /// Nil when there are no names, so the tag is removed.
    static func join(_ names: [String]) -> String? {
        names.isEmpty ? nil : names.joined(separator: separator)
    }

    /// Splits a tag value into names. Semicolons always separate. Otherwise " & "
    /// does. Otherwise ", " does, but only when every piece contains a space, so
    /// "Andy Weir, Ray Porter" is two people and "Tolkien, J. R. R." is one.
    static func split(_ joined: String?) -> [String] {
        guard let joined else { return [] }
        let parts: [String]
        if joined.contains(";") {
            parts = joined.components(separatedBy: ";")
        } else if joined.contains(" & ") {
            parts = joined.components(separatedBy: " & ")
        } else {
            let byComma = joined.components(separatedBy: ", ")
            let isList = byComma.count > 1 && byComma.allSatisfy {
                $0.trimmingCharacters(in: .whitespaces).contains(" ")
            }
            parts = isList ? byComma : [joined]
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
