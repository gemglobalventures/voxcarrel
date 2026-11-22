import Foundation

/// Whether a result is the edition the user has.
public enum EditionVerdict: Equatable, Sendable {
    case sameEdition
    /// Plainly another edition, with why: "read by Rory Kinnear, not Frank Muller".
    case differentEdition(reasons: [String])
    /// Not enough is known to say.
    case unknown

    /// Why the result is another edition; empty for any other verdict.
    public var reasons: [String] {
        if case .differentEdition(let reasons) = self { return reasons }
        return []
    }

    public var isDifferent: Bool {
        if case .differentEdition = self { return true }
        return false
    }
}

/// The book a lookup is for, as far as it helps to tell its edition from another.
public struct LookupBookContext: Equatable, Sendable {
    /// The details the book has now.
    public var metadata: BookMetadata
    /// The measured length of its audio files; nil for a book with none. A length that
    /// was typed or came from a catalogue is not evidence and is not given here.
    public var audioSeconds: Double?
    /// Whether the book is known to be abridged; nil when that is not known.
    public var isAbridged: Bool?

    public init(metadata: BookMetadata, audioSeconds: Double? = nil, isAbridged: Bool? = nil) {
        self.metadata = metadata
        self.audioSeconds = audioSeconds
        self.isAbridged = isAbridged
    }
}

/// Judges whether a result is the same edition as a book: by who reads it, how long it
/// is, and whether it is abridged.
public enum EditionMatch {
    /// A length differs when it is more than this share of the book's away, and more
    /// than this many seconds.
    static let lengthShare = 0.05
    static let lengthSeconds = 600.0

    /// `book`: the details the book has now; `bookSeconds`: its measured audio length,
    /// nil without audio files; `bookIsAbridged`: nil when that is not known.
    public static func verdict(
        candidate: LookupCandidate, book: BookMetadata, bookSeconds: Double?, bookIsAbridged: Bool?
    ) -> EditionVerdict {
        var reasons: [String] = []
        var matches = false

        // M1: who reads it. "Full Cast" is nobody.
        let theirs = people(candidate.metadata.narrators), ours = people(book.narrators)
        if !theirs.isEmpty, !ours.isEmpty {
            if theirs.contains(where: { name in ours.contains { LookupText.samePerson(name, $0) } }) {
                matches = true
            } else {
                reasons.append("read by \(list(theirs)), not \(list(ours))")
            }
        }

        // M2: how long it is.
        if let found = length(candidate.metadata.durationSeconds), let own = length(bookSeconds) {
            let apart = abs(found - own)
            if apart > own * lengthShare, apart > lengthSeconds {
                reasons.append("\(label(found)); yours is \(label(own))")
            } else {
                matches = true
            }
        }

        // M3: whether it is abridged.
        if let found = candidate.edition.abridged, let own = bookIsAbridged, found != own {
            reasons.append("\(word(found)); yours is \(word(own))")
        }

        // M4
        if !reasons.isEmpty { return .differentEdition(reasons: reasons) }
        return matches ? .sameEdition : .unknown
    }

    public static func verdict(candidate: LookupCandidate, book: LookupBookContext) -> EditionVerdict {
        verdict(
            candidate: candidate, book: book.metadata, bookSeconds: book.audioSeconds, bookIsAbridged: book.isAbridged)
    }

    /// True for "Full Cast" in any case: a credit, not a person.
    public static func isFullCast(_ name: String) -> Bool {
        LookupText.comparable(name, droppingArticle: false) == ["full", "cast"]
    }

    /// The names that are people.
    private static func people(_ names: [String]) -> [String] {
        names.compactMap(\.nonBlank).filter { !isFullCast($0) }
    }

    /// A length worth comparing: known, and more than nothing.
    private static func length(_ seconds: Double?) -> Double? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    static func label(_ seconds: Double) -> String {
        LookupText.lengthLabel(minutes: Int((seconds / 60).rounded()))
    }

    private static func word(_ abridged: Bool) -> String {
        abridged ? "abridged" : "unabridged"
    }

    /// "A", "A and B", "A, B and C"; past three names, "A, B and 2 others".
    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2, 3: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        default: "\(names[0]), \(names[1]) and \(names.count - 2) others"
        }
    }
}
