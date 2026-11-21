import Foundation

/// Several names typed in one text field, separated by semicolons:
/// `Terry Pratchett; Neil Gaiman`. Commas are not separators, because names such as
/// "Le Guin, Ursula K." contain them.
public enum NameListText {
    /// "A; B" -> ["A", "B"]. Splits on ";" only. Each name is trimmed, empty names are
    /// dropped, and a name already seen (ignoring case) is dropped.
    public static func names(from text: String) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for piece in text.split(separator: ";", omittingEmptySubsequences: true) {
            let name = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            names.append(name)
        }
        return names
    }

    /// The names joined with "; ".
    public static func text(from names: [String]) -> String {
        names.joined(separator: "; ")
    }
}

/// What a year field holds.
enum YearText: Equatable {
    case blank
    case year(Int)
    case invalid

    static let problem = "Year must be a number such as 1984."

    /// Blank, or a whole number from 1 to 9999 written in digits only.
    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            self = .blank
        } else if trimmed.allSatisfy({ $0.isASCII && $0.isNumber }), let year = Int(trimmed), (1...9999).contains(year) {
            self = .year(year)
        } else {
            self = .invalid
        }
    }
}

extension String {
    /// Without the spaces and line breaks around it.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Trimmed, or nil when nothing is left.
    var trimmedOrNil: String? {
        let text = trimmed
        return text.isEmpty ? nil : text
    }
}
