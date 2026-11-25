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

    /// As `text(seconds:)`, but a length under a minute is given in seconds: "42s".
    public static func exact(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0s" }
        return seconds < 59.5 ? "\(Int(seconds.rounded()))s" : text(seconds: seconds) ?? "0s"
    }

    /// What is wrong with a file whose length header states the wrong length. A header
    /// that states too little makes players stop early; one that states too much only
    /// makes them show the wrong length.
    public static func problem(_ problem: LengthProblem) -> String {
        let effect = problem.statedSeconds < problem.trueSeconds
            ? "Some players will stop early." : "Some players will show the wrong length."
        let text = "Length header is wrong: the file says \(exact(seconds: problem.statedSeconds)) but holds "
            + "\(exact(seconds: problem.trueSeconds)). \(effect)"
        return problem.repairable ? text : text + " This kind of header cannot be repaired here."
    }

    /// Said of a file whose length had to be measured and could not be.
    public static let unmeasured =
        "VoxCarrel could not measure this file's length; the length shown comes from the file's own header."
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

// K10: what kind of edition a book is, in words.
extension EditionKindNote {
    /// "Abridged", "Probably unabridged": the kind, said as probable when it is only
    /// an estimate.
    public var title: String {
        isProbable ? "Probably \(kind.title.lowercased())" : kind.title
    }

    /// The small label a book carries: "Abridged", "Probably abridged", "Dramatised".
    /// Nil for an unabridged book, which is what a book is taken to be, unless its
    /// files say so or the user did.
    public var label: String? {
        switch (kind, basis) {
        // The user's own "not known" is nothing to show.
        case (.notKnown, _): nil
        case (.unabridged, .stated), (.unabridged, .setByHand): title
        case (.unabridged, _): nil
        default: title
        }
    }

    /// How it is known: "The file’s tags say so."
    public var basisText: String {
        switch basis {
        case .stated(let source):
            switch source {
            case EditionKindGuess.namesSource: "The file’s name says so."
            case EditionKindGuess.titleSource: "The title says so."
            default: "The file’s tags say so."
            }
        case .matched(let source): "Matched with a result from \(source)."
        case .inferred: "Worked out from its running time."
        case .estimated: "Estimated from the length of the printed book."
        case .setByHand: "Set by you."
        }
    }

    /// For the label's tooltip: the reason when there is one, and how it is known.
    public var helpText: String {
        guard let reason = reason?.trimmedOrNil else { return basisText }
        // What the files say is its own account of how it is known.
        if case .stated = basis { return reason }
        return "\(reason) \(basisText)"
    }
}

// What the grid and the list write about a book.
extension BookRow {
    /// K10: the book's edition label, "Abridged", "Probably abridged" or "Dramatised";
    /// nil when there is nothing to show.
    public var editionLabel: String? {
        book.editionKind?.label
    }

    /// K10: the label's tooltip; nil when there is no label.
    public var editionHelpText: String? {
        book.editionKind.flatMap { $0.label == nil ? nil : $0.helpText }
    }

    /// K10: the tooltip where the label may be shown as a symbol alone: the label, and
    /// how it is known: "Abridged. Set by you." Nil when there is no label.
    public var editionBadgeHelpText: String? {
        guard let editionLabel, let editionHelpText else { return nil }
        return "\(editionLabel). \(editionHelpText)"
    }

    /// Empty when the book has no length.
    public var lengthText: String {
        LengthText.text(seconds: book.durationSeconds) ?? ""
    }

    public var authorsText: String {
        book.authors.joined(separator: ", ")
    }

    /// G37: the book's genres on one line, in the book's order; empty when it has none.
    public var genreText: String {
        GenreChips.shown(book.genres)
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
    /// "Audiobook and ebook: M4B, EPUB", with ". Also on Audible" for a book that is
    /// there too. For a book with no files, where it is: "On Audible, not on this Mac".
    /// Empty when there is nothing to say.
    public var formatsHelpText: String {
        guard hasFiles else { return whereaboutsText ?? formsText ?? "" }
        let files = [formsText, formatsText.trimmedOrNil].compactMap { $0 }.joined(separator: ": ")
        return [files.trimmedOrNil, whereaboutsText].compactMap { $0 }.joined(separator: ". ")
    }

    // MARK: Owned elsewhere

    public var externalCopies: [ExternalCopy] {
        book.externalCopies
    }

    public var isOnAudible: Bool {
        book.isOwned(on: .audible)
    }

    public var isOnKindle: Bool {
        book.isOwned(on: .kindle)
    }

    /// The places the book is owned other than as files, each once: Audible, then Kindle.
    public var ownedKinds: [ExternalKind] {
        ExternalKind.allCases.filter(book.isOwned(on:))
    }

    /// Whether the book has an ebook file here.
    var hasEbookFile: Bool {
        formats.contains { $0.defaultRole == .ebook }
    }

    /// The book in Kindle on the web, for a Kindle book whose copy has its ID; nil for
    /// any other book, and for an ID that is not one.
    public var kindleAddress: URL? {
        guard let id = book.externalCopies.lazy.filter({ $0.kind == .kindle }).compactMap({ $0.itemId?.trimmedOrNil }).first,
              id.count <= 20, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return URL(string: "https://read.amazon.com/?asin=\(id)")
    }

    /// Whether reading the book opens it in Kindle on the web: it is on Kindle, with
    /// its ID, and has no ebook file here.
    public var opensOnKindle: Bool {
        kindleAddress != nil && !hasEbookFile
    }

    /// Whether there is an ebook to open: a file here, or the book in Kindle on the
    /// web. A book that is only on Kindle, with no ID to open it by, has none.
    public var canRead: Bool {
        guard hasEbook else { return false }
        if hasEbookFile || kindleAddress != nil { return true }
        return book.externalCopies.contains { $0.form == .ebook && $0.kind != .kindle }
    }

    /// What the button that opens the ebook says: "Open on Kindle" when that opens
    /// the book in Kindle on the web, "Read" otherwise.
    public var readTitle: String {
        opensOnKindle ? "Open on Kindle" : "Read"
    }

    /// The same button's tooltip.
    public var readHelpText: String {
        opensOnKindle ? "Open this book in Kindle on the web" : "Open the ebook"
    }

    /// The book's Audible copy as an audiobook: what Listen opens when there is no audio file.
    var audibleAudioCopy: ExternalCopy? {
        book.externalCopies.first { $0.kind == .audible && $0.form == .audio }
    }

    /// Whether the book has an audio file here.
    var hasAudioFile: Bool {
        formats.contains { $0.defaultRole == .audio }
    }

    /// The length of the book's audio files, when they have been measured: what a
    /// lookup result's length is compared with. Nil for a book with no audio file here
    /// (a length that was typed or came from a catalogue is not evidence), and when
    /// the length of any file could not be measured.
    public var measuredAudioSeconds: Double? {
        guard hasAudioFile, unmeasuredLengthFiles == 0, let seconds = book.durationSeconds, seconds.isFinite, seconds > 0
        else { return nil }
        return seconds
    }

    /// Whether listening to the book opens its page on the Audible website: it is on
    /// Audible as an audiobook and has no audio file here. (Plain opening goes there
    /// only when the book has no ebook file here either.)
    public var opensOnAudible: Bool {
        audibleAudioCopy != nil && !hasAudioFile
    }

    /// Plan 6, V3: what the button that opens the audiobook says: "Open on Audible"
    /// when that opens its page on the Audible website, "Listen" otherwise.
    public var listenTitle: String {
        opensOnAudible ? "Open on Audible" : "Listen"
    }

    /// The same button's tooltip.
    public var listenHelpText: String {
        opensOnAudible ? "Open this book’s page on the Audible website" : "Open the audiobook"
    }

    /// Where the book is, for a book that is owned elsewhere: "On Audible, not on this
    /// Mac" when it has no files, "Also on Audible" when it has; "On Kindle" for a
    /// Kindle book, and "On Audible and Kindle" for a book on both. Nil for any other book.
    public var whereaboutsText: String? {
        whereaboutsText(of: ownedKinds)
    }

    /// The same for one place, when the book is owned there: what its own symbol says.
    public func whereaboutsText(on kind: ExternalKind) -> String? {
        whereaboutsText(of: ownedKinds.filter { $0 == kind })
    }

    private func whereaboutsText(of kinds: [ExternalKind]) -> String? {
        guard !kinds.isEmpty else { return nil }
        let places = kinds.map(\.title).joined(separator: " and ")
        return hasFiles ? "Also on \(places)" : "On \(places), not on this Mac"
    }

    /// Plan 9: the word on the row of a book that is on Audible's list of the series
    /// and not in the library; nil for a book of the library.
    public var missingLabel: String? {
        isMissing ? "Missing" : nil
    }

    /// Plan 9: what that word means, in full; nil for a book of the library.
    public var missingText: String? {
        isMissing ? "On Audible's list, not in your library" : nil
    }

    /// Plan 9: the day the book was added, for the list's Added column; nil for a book
    /// the library does not have, which was never added.
    public var addedDate: Date? {
        isMissing ? nil : book.dateAdded
    }

    /// Plan 9: the book's read status, for the list's Status column; nil for a book the
    /// library does not have, which has none.
    public var shownReadStatus: ReadStatus? {
        isMissing ? nil : book.readStatus
    }

    /// How much of the cover shows where the covers of books that are not on this Mac
    /// are dimmed (the grid and the list): all of it for a book with files, less for a
    /// book with none, and less again for a book the library does not have at all.
    public var dimmedCoverOpacity: Double {
        if isMissing { return 0.35 }
        return hasFiles ? 1 : 0.6
    }

    /// What there is to open, here or on Audible; nil when the book has neither.
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
        if lengthProblemFiles > 0 {
            parts.append(
                lengthProblemFiles == 1
                    ? "A file states the wrong length: some players will stop early"
                    : "\(lengthProblemFiles) files state the wrong length: some players will stop early")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }

    /// For a grid cell's tooltip: the whole title, the authors, and what the badges mean.
    public var summaryText: String {
        var badges: [String] = []
        // A book with no files is said to be on Audible, which says it is an audiobook too.
        if hasFiles || whereaboutsText == nil, let formsText { badges.append(formsText) }
        if let whereaboutsText { badges.append(whereaboutsText) }
        if let missingText { badges.append(missingText) }
        if let seriesNote { badges.append(seriesNote) }
        if let editionLabel { badges.append(editionLabel) }
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
