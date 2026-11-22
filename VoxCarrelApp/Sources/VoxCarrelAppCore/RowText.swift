import Foundation
import VoxCarrelCore

/// A length of time as the list shows it: "7h 42m".
public enum LengthText {
    /// Hours and minutes to the nearest minute; minutes alone under an hour; "<1m" for
    /// less than half a minute. Nil for no length, and for one that is not above zero.
    public static func text(seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        let minutes = Int((seconds / 60).rounded())
        if minutes == 0 { return "<1m" }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

/// The day a book was added, as the list shows it.
public enum AddedDateText {
    /// Short enough for a narrow column: the day and the month for a day in the year that
    /// `now` is in ("22 Nov"), the month and the year for any other ("Nov 2025"), as the
    /// locale writes them.
    public static func compact(
        _ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let thisYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        return date.formatted(thisYear ? style.day().month(.abbreviated) : style.month(.abbreviated).year())
    }

    /// The whole date, for the tooltip: "22 November 2026".
    public static func full(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        date.formatted(
            Date.FormatStyle(
                date: .long, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
    }
}

extension ReadStatus {
    public var title: String {
        switch self {
        case .unread: "Unread"
        case .inProgress: "In Progress"
        case .finished: "Finished"
        }
    }
}

// What the grid and the list write about a book.
extension BookRow {
    /// Empty when the book has no length.
    public var lengthText: String {
        LengthText.text(seconds: book.durationSeconds) ?? ""
    }

    public var authorsText: String {
        book.authors.joined(separator: ", ")
    }

    /// The first author that is not blank; empty when there is none.
    public var firstAuthorText: String {
        book.authors.lazy.compactMap(\.trimmedOrNil).first ?? ""
    }

    /// "Tidewater Chronicles #2"; the series alone when it has no number; empty with no series.
    public var seriesText: String {
        guard let series = book.series?.trimmedOrNil else { return "" }
        guard let number = book.seriesNumber?.trimmedOrNil else { return series }
        return "\(series) #\(number)"
    }

    /// "M4B, EPUB"
    public var formatsText: String {
        formats.map { $0.rawValue.uppercased() }.joined(separator: ", ")
    }

    /// For the tooltip of the list's format symbols, which stand without words:
    /// "Audiobook and ebook: M4B, EPUB". Empty when the book has no files.
    public var formatsHelpText: String {
        [formsText, formatsText.trimmedOrNil].compactMap { $0 }.joined(separator: ": ")
    }

    /// What there is to open; nil when the book has neither.
    public var formsText: String? {
        switch (hasAudio, hasEbook) {
        case (true, true): "Audiobook and ebook"
        case (true, false): "Audiobook"
        case (false, true): "Ebook"
        case (false, false): nil
        }
    }

    /// What the warning triangle is for; nil when it is not shown.
    public var warningText: String? {
        var parts: [String] = []
        if book.needsAttention { parts.append("Needs attention") }
        if hasWriteProblem { parts.append("Tags could not be written to a file") }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }

    /// For a grid cell's tooltip: the whole title, the authors, and what the badges mean.
    public var summaryText: String {
        var badges: [String] = []
        if let formsText { badges.append(formsText) }
        if book.readStatus != .unread { badges.append(book.readStatus.title) }
        if let warningText { badges.append(warningText) }
        return [book.title, authorsText, badges.joined(separator: " · ")]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: Placeholder cover

    /// The letters shown in place of a missing cover (`PlaceholderCover.initials`).
    public var coverInitials: String {
        PlaceholderCover.initials(for: book.title)
    }

    /// The tint of the placeholder cover, from 0 up to 1: the same for a title every time.
    public var placeholderHue: Double {
        PlaceholderCover.hue(for: book.title)
    }
}

/// What stands in for a cover a book does not have, worked out from its title.
public enum PlaceholderCover {
    private static let articles: Set<String> = ["the", "a", "an"]

    /// The first letter or digit of each of the title's first two words, in capitals,
    /// leaving out a leading "The", "A" or "An" when more follows. "?" when the title
    /// has no letter or digit.
    public static func initials(for title: String) -> String {
        var words = title
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        if words.count > 1, let first = words.first, articles.contains(first.lowercased()) {
            words.removeFirst()
        }
        let initials = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
        return initials.isEmpty ? "?" : initials
    }

    /// The tint, from 0 up to 1: the same for a title every time.
    public static func hue(for title: String) -> Double {
        var sum: UInt64 = 0
        for scalar in title.unicodeScalars {
            sum = (sum &* 31 &+ UInt64(scalar.value)) % 360
        }
        return Double(sum) / 360
    }
}
