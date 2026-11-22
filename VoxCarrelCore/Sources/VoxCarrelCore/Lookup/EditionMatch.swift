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
    /// The same for a result whose length is a catalogue's round figure ("18 hr.").
    static let nominalLengthShare = 0.10
    static let nominalLengthSeconds = 2700.0

    /// How a result's title stands to the book's.
    enum TitleRelation: Equatable {
        /// The same title.
        case same
        /// One is the other with a subtitle after it: "Salt Road: A Novel", "Salt Road (Unabridged)".
        case withSubtitle
        /// Anything else, a title that only begins with the other included: "Dune Messiah".
        case different
    }

    /// What a comparison came to, with what it rests on.
    struct Judgement: Equatable {
        var verdict: EditionVerdict
        /// True when both lengths are known and agree.
        var lengthMatches: Bool
    }

    /// `book`: the details the book has now; `bookSeconds`: its measured audio length,
    /// nil without audio files; `bookIsAbridged`: nil when that is not known.
    public static func verdict(
        candidate: LookupCandidate, book: BookMetadata, bookSeconds: Double?, bookIsAbridged: Bool?
    ) -> EditionVerdict {
        judgement(candidate: candidate, book: book, bookSeconds: bookSeconds, bookIsAbridged: bookIsAbridged).verdict
    }

    /// The verdict, and whether it rests on the length.
    ///
    /// A result is the book's own edition only when it is the same work (the same
    /// title, or one with a subtitle) by the same author, nothing contradicts, and the
    /// lengths agree. The same reader alone is enough only for the very same title of a
    /// book whose own length is known, when the result gives no length: a reader reads
    /// sequels and abridgements too.
    static func judgement(
        candidate: LookupCandidate, book: BookMetadata, bookSeconds: Double?, bookIsAbridged: Bool?
    ) -> Judgement {
        var reasons: [String] = []
        var narratorMatches = false
        var lengthMatches = false

        // M1: who reads it. "Full Cast" is nobody.
        let theirs = people(candidate.metadata.narrators), ours = people(book.narrators)
        if !theirs.isEmpty, !ours.isEmpty {
            if theirs.contains(where: { name in ours.contains { LookupText.samePerson(name, $0) } }) {
                narratorMatches = true
            } else {
                reasons.append("read by \(list(theirs)), not \(list(ours))")
            }
        }

        // M2: how long it is.
        let ownLength = length(bookSeconds)
        if let found = length(candidate.metadata.durationSeconds), let own = ownLength {
            let nominal = candidate.edition.lengthIsNominal
            let share = nominal ? nominalLengthShare : lengthShare
            let seconds = nominal ? nominalLengthSeconds : lengthSeconds
            let apart = abs(found - own)
            if apart > own * share, apart > seconds {
                reasons.append("\(label(found)); yours is \(label(own))")
            } else {
                lengthMatches = true
            }
        }

        // M3: whether it is abridged.
        if let found = candidate.edition.abridged, let own = bookIsAbridged, found != own {
            reasons.append("\(word(found)); yours is \(word(own))")
        }

        // M4
        if !reasons.isEmpty {
            return Judgement(verdict: .differentEdition(reasons: reasons), lengthMatches: false)
        }
        let relation = titleRelation(candidate.metadata.title, book.title)
        guard relation != .different, sharesAnAuthor(candidate.metadata, book) else {
            return Judgement(verdict: .unknown, lengthMatches: false)
        }
        if lengthMatches { return Judgement(verdict: .sameEdition, lengthMatches: true) }
        // The reader alone: the very same title, of a book whose own length is known.
        let same = narratorMatches && relation == .same && ownLength != nil
        return Judgement(verdict: same ? .sameEdition : .unknown, lengthMatches: false)
    }

    /// What may stand between a title and its subtitle.
    private static let subtitleMarks = [":", " - ", " – ", " — ", "(", "[", ";"]

    /// A title without anything after the first mark that begins a subtitle.
    private static func head(_ title: String) -> String? {
        let cuts = subtitleMarks.compactMap { title.range(of: $0)?.lowerBound }
        guard let cut = cuts.min() else { return nil }
        return String(title[..<cut])
    }

    /// The same title; one that is the other with a subtitle after a colon, a dash or
    /// in brackets; or a different one. A title that merely goes on with more words is
    /// a different one. A title that is missing is taken to be the same.
    static func titleRelation(_ first: String, _ second: String) -> TitleRelation {
        let a = LookupText.comparable(first), b = LookupText.comparable(second)
        if a.isEmpty || b.isEmpty || a == b { return .same }
        let headA = head(first).map { LookupText.comparable($0) }, headB = head(second).map { LookupText.comparable($0) }
        if let headA, !headA.isEmpty, headA == b || headA == headB { return .withSubtitle }
        if let headB, !headB.isEmpty, headB == a { return .withSubtitle }
        return .different
    }

    /// False when both name authors and share none. Whatever is missing rules nothing out.
    static func sharesAnAuthor(_ found: BookMetadata, _ book: BookMetadata) -> Bool {
        let their = found.authors.compactMap(\.nonBlank), our = book.authors.compactMap(\.nonBlank)
        guard !their.isEmpty, !our.isEmpty else { return true }
        return their.contains { name in our.contains { LookupText.samePerson(name, $0) } }
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
