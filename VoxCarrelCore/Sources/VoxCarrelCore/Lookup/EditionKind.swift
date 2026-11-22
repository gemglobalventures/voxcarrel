import Foundation

/// What kind of recording an audiobook is: the whole text, a shortened one, or a play
/// made of it.
public enum EditionKind: String, Codable, Sendable, CaseIterable {
    case unabridged, abridged, dramatised

    public var title: String {
        switch self {
        case .unabridged: "Unabridged"
        case .abridged: "Abridged"
        case .dramatised: "Dramatised"
        }
    }

    /// For comparing with a result that says whether it is abridged. A dramatisation is
    /// neither, and is not compared.
    public var isAbridged: Bool? {
        switch self {
        case .unabridged: false
        case .abridged: true
        case .dramatised: nil
        }
    }
}

/// What kind of edition a book is, with how that is known.
public struct EditionKindNote: Codable, Equatable, Sendable {
    /// How it is known, strongest last but for `setByHand`, which nothing replaces.
    public enum Basis: Equatable, Sendable {
        /// Worked out from a printed edition's page count: only ever probable.
        case estimated
        /// Worked out from the running time against other editions.
        case inferred
        /// A lookup result judged to be this very edition says so. With the source's name.
        case matched(String)
        /// The book's own files say so. With where: "the file's tags".
        case stated(String)
        /// The user chose it.
        case setByHand
    }

    public var kind: EditionKind
    public var basis: Basis
    /// One plain sentence shown with it: "3h 12m; unabridged editions run about 18h."
    public var reason: String?

    public init(kind: EditionKind, basis: Basis, reason: String? = nil) {
        self.kind = kind
        self.basis = basis
        self.reason = reason
    }

    /// True when it is only a likelihood, to be worded "Probably abridged".
    public var isProbable: Bool {
        basis == .estimated
    }

    public var isSetByHand: Bool {
        basis == .setByHand
    }

    private var strength: Int {
        switch basis {
        case .estimated: 0
        case .inferred: 1
        case .matched: 2
        case .stated: 3
        case .setByHand: 4
        }
    }

    /// Whether this, newly worked out, should take the place of what the book has:
    /// stated beats matched beats inferred beats estimated, a newer finding of the same
    /// strength replaces an older, and what was set by hand is never replaced.
    public func mayReplace(_ existing: EditionKindNote?) -> Bool {
        guard let existing else { return true }
        guard !existing.isSetByHand else { return false }
        return strength >= existing.strength
    }

    /// The stronger of the two; the first when they are equally strong. Nil when both are.
    public static func stronger(_ first: EditionKindNote?, _ second: EditionKindNote?) -> EditionKindNote? {
        guard let first else { return second }
        guard let second else { return first }
        return second.strength > first.strength ? second : first
    }

    // Stored as one flat object: {"kind": "abridged", "basis": "stated", "source": "…", "reason": "…"}.

    private enum CodingKeys: String, CodingKey {
        case kind, basis, source, reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(EditionKind.self, forKey: .kind)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        let source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        let name = try c.decode(String.self, forKey: .basis)
        switch name {
        case "estimated": basis = .estimated
        case "inferred": basis = .inferred
        case "matched": basis = .matched(source)
        case "stated": basis = .stated(source)
        case "setByHand": basis = .setByHand
        default:
            throw DecodingError.dataCorruptedError(forKey: .basis, in: c, debugDescription: "unknown basis \(name)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(reason, forKey: .reason)
        switch basis {
        case .estimated: try c.encode("estimated", forKey: .basis)
        case .inferred: try c.encode("inferred", forKey: .basis)
        case .matched(let source):
            try c.encode("matched", forKey: .basis)
            try c.encode(source, forKey: .source)
        case .stated(let source):
            try c.encode("stated", forKey: .basis)
            try c.encode(source, forKey: .source)
        case .setByHand: try c.encode("setByHand", forKey: .basis)
        }
    }
}

/// What a look at a book's edition came to: a verdict, or none, and anything worth
/// saying when there is none.
public struct EditionKindAssessment: Equatable, Sendable {
    public var note: EditionKindNote?
    /// Said when no verdict could be reached and there is a reason worth giving:
    /// "13h 0m; shorter than the unabridged editions (18h 10m), so it may be abridged or incomplete."
    public var remark: String?

    public init(note: EditionKindNote? = nil, remark: String? = nil) {
        self.note = note
        self.remark = remark
    }
}

/// Works out what kind of edition a book is, from its own files and from what lookups found.
public enum EditionKindGuess {
    public static let tagsSource = "the file's tags"
    public static let namesSource = "the file's name"

    /// Within this share of an unabridged edition's length, a book is that edition's length.
    static let sameLengthShare = 0.12
    /// Under this share of the shortest unabridged edition, a book is abridged.
    static let abridgedShare = 0.60
    /// Pages read aloud in an hour: about 275 words a page at about 155 words a minute.
    static let pagesAnHour = 34.0
    static let probablyAbridgedShare = 0.40
    static let probablyUnabridgedShares = 0.70...1.40

    // MARK: From the files

    private static let markers: [(kind: EditionKind, pattern: String)] = [
        // "Unabridged" first: it holds the word "abridged".
        (.unabridged, "unabridged"),
        (.abridged, "abridged"),
        (.dramatised, "full[\\s_.\\-]*cast"),
        (.dramatised, "dramati[sz]ation"),
        (.dramatised, "dramati[sz]ed"),
        (.dramatised, "radio[\\s_.\\-]*play"),
        (.dramatised, "bbc[\\s_.\\-]*radio"),
    ]

    /// From what the files and their names say, with no network: the words "unabridged"
    /// or "abridged" as whole words, in any case; "full cast", "dramatisation", "radio
    /// play" or "BBC Radio" for a dramatisation. Nothing is taken out of the title.
    ///
    /// `fileNames`: the names of the files and of their folders.
    public static func fromFiles(
        title: String, subtitle: String?, comment: String?, fileNames: [String]
    ) -> EditionKindNote? {
        let tagged: [(text: String?, place: String)] = [
            (title, "The title"), (subtitle, "The subtitle"), (comment, "The description"),
        ]
        for marker in markers {
            for (text, place) in tagged {
                if let said = word(marker.pattern, in: text) {
                    return EditionKindNote(kind: marker.kind, basis: .stated(tagsSource), reason: "\(place) says “\(said)”.")
                }
            }
            for name in fileNames {
                if let said = word(marker.pattern, in: name) {
                    return EditionKindNote(
                        kind: marker.kind, basis: .stated(namesSource), reason: "A file or folder name says “\(said)”.")
                }
            }
        }
        return nil
    }

    /// The marker as the text has it, when it stands there as a whole word.
    private static func word(_ pattern: String, in text: String?) -> String? {
        guard let text = text.map({ String($0.prefix(LookupText.summaryLimit)) }),
              let expression = try? NSRegularExpression(
                  pattern: "(?<![\\p{L}])\(pattern)(?![\\p{L}])", options: [.caseInsensitive]),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else { return nil }
        return String(text[range]).replacingOccurrences(of: "[\\s_.\\-]+", with: " ", options: .regularExpression)
    }

    /// True when the words say a dramatisation.
    static func saysDramatised(_ texts: [String?]) -> Bool {
        markers.contains { marker in marker.kind == .dramatised && texts.contains { word(marker.pattern, in: $0) != nil } }
    }

    // MARK: From lookup results

    /// From lookup results for the same title and author, given the book's measured
    /// length (nil when it has none that can be relied on).
    public static func fromResults(
        _ candidates: [LookupCandidate], book: BookMetadata, bookSeconds: Double?
    ) -> EditionKindNote? {
        assess(candidates, book: book, bookSeconds: bookSeconds).note
    }

    /// As `fromResults`, with what there is to say when no verdict is reached.
    /// `partsAppearMissing`: the book's numbered parts have gaps, so a short length is
    /// no sign of an abridgement.
    public static func assess(
        _ candidates: [LookupCandidate], book: BookMetadata, bookSeconds: Double?, partsAppearMissing: Bool = false
    ) -> EditionKindAssessment {
        // A result that is this very edition and says what it is.
        for candidate in candidates {
            guard EditionMatch.verdict(candidate: candidate, book: book, bookSeconds: bookSeconds, bookIsAbridged: nil)
                == .sameEdition
            else { continue }
            let source = candidate.source.title
            if isDramatisation(candidate) {
                return EditionKindAssessment(note: EditionKindNote(
                    kind: .dramatised, basis: .matched(source),
                    reason: "\(source) lists your edition as a full-cast production."))
            }
            if let abridged = candidate.edition.abridged {
                return EditionKindAssessment(note: EditionKindNote(
                    kind: abridged ? .abridged : .unabridged, basis: .matched(source),
                    reason: "\(source) lists your edition as \(abridged ? "abridged" : "unabridged")."))
            }
        }

        let missing = "Parts appear to be missing, so the length does not show whether it is abridged."
        guard let own = bookSeconds, own.isFinite, own > 0 else {
            return EditionKindAssessment(remark: partsAppearMissing ? missing : nil)
        }
        let ownLabel = EditionMatch.label(own)
        let relevant = candidates.filter { isSameWork($0, as: book) && !isInAnotherLanguage($0, than: book) }

        // By length, against editions that say they are unabridged.
        let lengths = relevant.filter { $0.edition.abridged == false && !isDramatisation($0) }
            .compactMap { length(of: $0) }
        if let shortest = lengths.min() {
            if let nearest = lengths.min(by: { abs($0 - own) < abs($1 - own) }),
               abs(nearest - own) <= nearest * sameLengthShare {
                return EditionKindAssessment(note: EditionKindNote(
                    kind: .unabridged, basis: .inferred,
                    reason: "\(ownLabel); the unabridged edition runs \(EditionMatch.label(nearest))."))
            }
            let usual = "unabridged editions run about \(Int((shortest / 3600).rounded()))h"
            if own < shortest * abridgedShare {
                if partsAppearMissing { return EditionKindAssessment(remark: missing) }
                let fullCast = book.narrators.contains(where: EditionMatch.isFullCast)
                let play = relevant.first { candidate in
                    guard isDramatisation(candidate), let theirs = length(of: candidate) else { return false }
                    return abs(theirs - own) <= theirs * sameLengthShare
                }
                if let play {
                    return EditionKindAssessment(note: EditionKindNote(
                        kind: .dramatised, basis: .inferred,
                        reason: "\(ownLabel); \(play.source.title) lists a dramatisation of that length, and \(usual)."))
                }
                if fullCast {
                    return EditionKindAssessment(note: EditionKindNote(
                        kind: .dramatised, basis: .inferred, reason: "\(ownLabel), read by a full cast; \(usual)."))
                }
                return EditionKindAssessment(note: EditionKindNote(
                    kind: .abridged, basis: .inferred, reason: "\(ownLabel); \(usual)."))
            }
            if own < shortest * (1 - sameLengthShare) {
                return EditionKindAssessment(
                    remark: "\(ownLabel); shorter than the unabridged editions (\(EditionMatch.label(shortest))), "
                        + "so it may be abridged or incomplete.")
            }
            return EditionKindAssessment()
        }

        // No audio edition to go by: a printed edition's page count.
        guard let pages = relevant.lazy.compactMap({ $0.metadata.pageCount }).first(where: { $0 > 0 }) else {
            return EditionKindAssessment(remark: partsAppearMissing ? missing : nil)
        }
        let expected = Double(pages) / pagesAnHour * 3600
        let basis = "\(ownLabel); a book of \(pages) pages probably runs about \(Int((expected / 3600).rounded()))h unabridged."
        if own < expected * probablyAbridgedShare {
            if partsAppearMissing { return EditionKindAssessment(remark: missing) }
            return EditionKindAssessment(note: EditionKindNote(kind: .abridged, basis: .estimated, reason: basis))
        }
        if probablyUnabridgedShares.contains(own / expected) {
            return EditionKindAssessment(note: EditionKindNote(kind: .unabridged, basis: .estimated, reason: basis))
        }
        return EditionKindAssessment()
    }

    /// A full-cast production, or one that calls itself a dramatisation.
    static func isDramatisation(_ candidate: LookupCandidate) -> Bool {
        candidate.metadata.narrators.contains(where: EditionMatch.isFullCast)
            || saysDramatised([candidate.metadata.title, candidate.metadata.subtitle])
    }

    private static func length(of candidate: LookupCandidate) -> Double? {
        guard let seconds = candidate.metadata.durationSeconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    /// The same title and first author. A book with no author is matched by title alone.
    static func isSameWork(_ candidate: LookupCandidate, as book: BookMetadata) -> Bool {
        let title = LookupText.comparable(book.title)
        guard !title.isEmpty, LookupText.comparable(candidate.metadata.title) == title else { return false }
        guard let author = book.authors.lazy.compactMap(\.nonBlank).first else { return true }
        guard let theirs = candidate.metadata.authors.lazy.compactMap(\.nonBlank).first else { return false }
        return LookupText.samePerson(author, theirs)
    }

    /// Known to be in a language the book is known not to be in.
    private static func isInAnotherLanguage(_ candidate: LookupCandidate, than book: BookMetadata) -> Bool {
        guard let theirs = candidate.metadata.language.flatMap(LookupText.languageCode),
              let own = book.language.flatMap(LookupText.languageCode)
        else { return false }
        return theirs != own
    }

    // MARK: Missing parts

    /// Whether the names of a book's audio files are numbered with gaps: 1, 2, 4. Only
    /// when exactly one number in the names changes from file to file.
    public static func partsAppearMissing(fileNames: [String]) -> Bool {
        guard fileNames.count >= 2 else { return false }
        let numbers: [[Int]] = fileNames.map { name in
            let stem = (name as NSString).deletingPathExtension
            return stem.split(whereSeparator: { !$0.isASCII || !$0.isNumber }).compactMap { $0.count <= 6 ? Int($0) : nil }
        }
        guard let count = numbers.first?.count, count > 0, numbers.allSatisfy({ $0.count == count }) else { return false }
        let changing = (0..<count).filter { place in Set(numbers.map { $0[place] }).count > 1 }
        guard changing.count == 1, let place = changing.first else { return false }
        let parts = Set(numbers.map { $0[place] })
        guard parts.count == fileNames.count, let low = parts.min(), let high = parts.max() else { return false }
        return high - low + 1 > parts.count
    }
}
