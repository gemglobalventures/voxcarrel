import Foundation
import Testing
@testable import VoxCarrelCore

/// The filing rule exactly as it was released before folders followed a pattern, with
/// none of the later corrections. Never to be edited: it says where the books of
/// existing libraries are.
enum ShippedFilingRule {
    static let maxComponentLength = 200

    static func sanitise(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })
        var s = String(scalars)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        s = String(s.prefix(maxComponentLength))
        while let first = s.first, first == "." || first == " " { s.removeFirst() }
        while let last = s.last, last == "." || last == " " { s.removeLast() }
        return s
    }

    private static func capped(_ sanitised: String, to length: Int) -> String {
        var s = String(sanitised.prefix(max(length, 1)))
        while let last = s.last, last == "." || last == " " { s.removeLast() }
        return s
    }

    static func bookFolder(metadata: BookMetadata) -> String? {
        let title = sanitise(metadata.title)
        let author = sanitise(metadata.authors.first ?? "")
        guard !title.isEmpty, !author.isEmpty else { return nil }

        var parts = [author]
        let series = sanitise(metadata.series ?? "")
        if series.isEmpty {
            parts.append(title)
        } else {
            parts.append(series)
            let number = sanitise(metadata.seriesNumber ?? "")
            parts.append(
                number.isEmpty ? title : capped("\(number) - \(title)", to: maxComponentLength))
        }
        return parts.joined(separator: "/")
    }
}

/// FP7, held to what was released: the standard pattern files a book where the released
/// rule filed it, scalar for scalar, except a book the released rule filed wrongly (a
/// "/" or ":" that reached the disk, or a name beginning with a dot or a space).
@Suite struct ShippedFilingRuleTests {
    static let pieces: [String] = [
        "a", "B", " ", ".", "/", ":", "-", "\u{0}", "\n", "é", "e", "\u{301}", "\u{308}", "字", "🙂", "1", "t",
        "\u{200D}", "\u{FE0F}", "\u{20DD}", "\u{200B}", "\u{AD}", "\u{FEFF}", "\u{1F3FB}", "👩", "\u{FF0F}",
        "\u{FF1A}", "\u{2215}", "\u{2236}", "\u{37E}", "ä", "a\u{308}", "\u{E0020}", "\u{1160}", "ᄀ", "\u{93F}",
        "क", "\u{600}", "\u{903}", "\u{D}", "\u{85}", "\u{2028}", "\u{202E}",
    ]

    static func value(using rng: inout SeededGenerator) -> String {
        switch Int.random(in: 0..<10, using: &rng) {
        case 0...2:
            return FolderPatternTests.value(using: &rng)
        case 3:
            let length = [190, 198, 199, 200, 201, 202, 230].randomElement(using: &rng) ?? 200
            return (0..<length).map { _ in pieces.randomElement(using: &rng) ?? "" }.joined()
        default:
            return (0..<Int.random(in: 0...10, using: &rng)).map { _ in pieces.randomElement(using: &rng) ?? "" }.joined()
        }
    }

    private static func scalars(_ text: String?) -> [UInt32]? {
        text.map { $0.unicodeScalars.map(\.value) }
    }

    @Test func theStandardPatternFilesWhereTheReleasedRuleDidUnlessThatRuleWasWrong() {
        var rng = SeededGenerator(seed: 0x51A9_9ED0_F11E_2026)
        var same = 0, corrected = 0
        for _ in 0..<20_000 {
            var m = BookMetadata()
            m.title = Self.value(using: &rng)
            m.authors = (0..<Int.random(in: 0...2, using: &rng)).map { _ in Self.value(using: &rng) }
            if Int.random(in: 0..<3, using: &rng) > 0 { m.series = Self.value(using: &rng) }
            if Int.random(in: 0..<3, using: &rng) > 0 { m.seriesNumber = Self.value(using: &rng) }
            let released = ShippedFilingRule.bookFolder(metadata: m)
            let now = FolderPattern.standard.folder(for: FolderPatternValues(metadata: m, hasAudio: true))
            if Self.scalars(released) == Self.scalars(now) {
                same += 1
                continue
            }
            corrected += 1
            // A difference is only ever a value the released rule left unsafe.
            let values = [m.title, m.authors.first ?? "", m.series ?? "", m.seriesNumber ?? ""]
            let unsafe = values.map(ShippedFilingRule.sanitise).contains { old in
                old.unicodeScalars.contains("/") || old.unicodeScalars.contains(":")
                    || old.unicodeScalars.first == "." || old.unicodeScalars.first == " "
            }
            #expect(unsafe, "\(values.map(\.debugDescription)): \(String(describing: released)) became \(String(describing: now))")
        }
        #expect(same > 10_000)
        #expect(corrected > 500)
    }

    /// Values without a "/", ":" or leading dot or space joined to a following mark are
    /// made safe exactly as they were.
    @Test func sanitiseIsTheReleasedOneForEveryValueTheReleasedOneMadeSafe() {
        var rng = SeededGenerator(seed: 7)
        var checked = 0
        for _ in 0..<20_000 {
            let value = Self.value(using: &rng)
            let old = ShippedFilingRule.sanitise(value)
            guard !old.unicodeScalars.contains("/"), !old.unicodeScalars.contains(":"),
                  old.unicodeScalars.first != ".", old.unicodeScalars.first != " "
            else { continue }
            checked += 1
            #expect(Self.scalars(PathBuilder.sanitise(value)) == Self.scalars(old), "\(value.debugDescription)")
        }
        #expect(checked > 10_000)
    }
}
