import Foundation
import VoxCarrelCore

// What the review sheet writes about an import, and the changes it makes by an entry's
// id (plan Task 11). Q1–Q9. An entry is always found by its id: merging and moving a
// file out change the list.

extension ImportReview {
    // MARK: Q1 Changing an entry by its id

    public func entry(_ id: UUID) -> Entry? {
        entries.first { $0.id == id }
    }

    /// Q1: changes the entry with this id; nothing when it is no longer there.
    ///
    /// IH2–IH4: what the change means is taken account of: a title, authors or Audible
    /// ID that were changed are no longer guesses, a changed switch is the owner's choice,
    /// and the roles of the entry's PDFs follow the switch.
    public mutating func update(_ id: UUID, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let before = entries[index]
        change(&entries[index])
        entries[index].noteChanges(since: before)
    }

    // MARK: Q2 The fields

    /// The details that can be typed in the review.
    public enum Field: Sendable {
        case title, authors, narrators, series, seriesNumber
    }

    /// Q2: what a field's box says. Several names are separated by semicolons.
    public func text(for field: Field, of id: UUID) -> String {
        guard let metadata = entry(id)?.candidate.metadata else { return "" }
        switch field {
        case .title: return metadata.title
        case .authors: return NameListText.text(from: metadata.authors)
        case .narrators: return NameListText.text(from: metadata.narrators)
        case .series: return metadata.series ?? ""
        case .seriesNumber: return metadata.seriesNumber ?? ""
        }
    }

    /// Q2: takes the text of a field's box as the entry's value. Text is kept as it was
    /// typed; an emptied series or number is none.
    public mutating func setText(_ text: String, for field: Field, of id: UUID) {
        guard !isLocked(field, of: id) else { return }
        update(id) { entry in
            switch field {
            case .title: entry.candidate.metadata.title = text
            case .authors: entry.candidate.metadata.authors = NameListText.names(from: text)
            case .narrators: entry.candidate.metadata.narrators = NameListText.names(from: text)
            case .series: entry.candidate.metadata.series = text.isEmpty ? nil : text
            case .seriesNumber: entry.candidate.metadata.seriesNumber = text.isEmpty ? nil : text
            }
        }
    }

    /// MG6: whether the entry has a title or an author to put in the other's place.
    public func canSwapTitleAndAuthor(of id: UUID) -> Bool {
        guard let metadata = entry(id)?.candidate.metadata else { return false }
        return !metadata.title.trimmed.isEmpty || metadata.authors.contains { !$0.trimmed.isEmpty }
    }

    /// MG6: exchanges the entry's title with its first author; any other authors stay
    /// after it. The folder and the library book worked out for the entry were for
    /// the details it had, so both are due again (`entriesNeedingDestination`,
    /// `entriesNeedingMatch`). A title that holds a semicolon is still one author, also
    /// when the authors are typed again as they are shown (`NameListText.oneName`).
    /// With no title, the first author becomes the title and is an author no more;
    /// with no author, the title becomes the author and the title is left empty.
    /// Nothing when both are blank.
    public mutating func swapTitleAndAuthor(for id: UUID) {
        guard canSwapTitleAndAuthor(of: id) else { return }
        update(id) { entry in
            var names = entry.candidate.metadata.authors.compactMap(\.trimmedOrNil)
            let old = entry.candidate.metadata.title.trimmed
            entry.candidate.metadata.title = names.isEmpty ? "" : names.removeFirst()
            entry.candidate.metadata.authors = (old.isEmpty ? [] : [NameListText.oneName(old)]) + names
        }
    }

    /// Whether a field cannot be typed in: an entry that joins a book already in the
    /// library takes that book's details, so its own are not used. The title and the
    /// authors can always be typed, because they decide which book that is.
    public func isLocked(_ field: Field, of id: UUID) -> Bool {
        guard let entry = entry(id), entry.isAddedToExisting else { return false }
        return field != .title && field != .authors
    }

    /// What to say under the details of an entry that joins a book already in the
    /// library; nil for any other entry. R9: for a book that has no files yet, that its
    /// details are kept and what it lacks is filled in from the files.
    public func keptDetailsNote(of id: UUID) -> String? {
        guard let entry = entry(id), entry.isAddedToExisting, let match = entry.existingMatch else { return nil }
        if entry.matchHasNoFiles {
            // R9: the book has no files yet, so what these say is not thrown away.
            let title = match.title.trimmedOrNil.map { "“\($0)”" } ?? "the book in the library"
            return "These files join \(title), which keeps its own details. "
                + "What it lacks is filled in from the files, and nothing in them is lost."
        }
        let title = match.title.trimmedOrNil.map { "\"\($0)\"" } ?? "the existing book"
        return "These files join \(title), which keeps its own details. "
            + "Change the title or author to import them as a different book."
    }


    // MARK: IH1, IH2 The switch

    /// IH2: the owner sets the switch that adds the entry's files to the book already in
    /// the library. It is their choice for that book from then on: looking the book up
    /// again does not undo it. IH3: the roles of the entry's PDFs follow.
    /// The owner's choice to keep an entry as another edition of the book it matches.
    public mutating func setAsEdition(_ on: Bool, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].asEdition = on
    }

    public static let editionOffer =
        "Keep it as another edition of that book (another language, another narrator, or a dramatisation)"

    public mutating func setAddToExisting(_ add: Bool, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].addToExisting = add
        if let book = entries[index].existingMatch?.id { entries[index].switchChoices[book] = add }
        entries[index].applyRoleGuess()
    }

    // MARK: IH4 What was guessed

    /// IH4: one line for under the title and the authors, saying what of them was read
    /// from a file's name; nil when nothing was, or once they have been changed by hand.
    public func guessNote(of id: UUID) -> String? {
        entry(id)?.guessNote
    }

    /// IH4: "Audible ID B09WXN61GL", for an ID that was read from a file's name; nil
    /// for any other.
    public func guessedAudibleIDText(of id: UUID) -> String? {
        guard let entry = entry(id), entry.guessNotes.contains(.audibleIDFromName),
              let asin = entry.candidate.metadata.asin?.trimmedOrNil
        else { return nil }
        return "Audible ID \(asin)"
    }

    /// IH4: what to say beside that ID; nil when `guessedAudibleIDText` is.
    public func audibleIDNote(of id: UUID) -> String? {
        guessedAudibleIDText(of: id) == nil ? nil : "The Audible ID was read from the file name."
    }

    // MARK: IH5 Swap

    /// IH5: whether Swap Title and Author is to stand out: the title and the author may
    /// be in each other's place, and Swap has something to move (MG6).
    public func offersProminentSwap(of id: UUID) -> Bool {
        guard let entry = entry(id) else { return false }
        return (entry.orderIsInQuestion || entry.guessNotes.contains(.titleLooksLikePerson))
            && canSwapTitleAndAuthor(of: id)
    }

    // MARK: IH6 Questions

    /// IH6: the caution mark of an entry that has a question: the one a status that
    /// does not stop the import has.
    public static let questionSymbol = Status(text: "", isBlocking: false).symbol

    /// IH6: what the owner is asked to check about an entry, for the tooltip of its
    /// caution mark; nil when there is nothing to check.
    public func question(of id: UUID) -> String? {
        entry(id)?.question
    }

    /// "2 books have a question to check."; nil when no book that will be imported has
    /// one. A question never stops the import.
    public var questionsText: String? {
        let count = entries.filter { $0.included && $0.question != nil }.count
        switch count {
        case 0: return nil
        case 1: return "1 book has a question to check."
        default: return "\(count) books have a question to check."
        }
    }

    // MARK: What was set aside, skipped, or is not here yet

    /// What the owner should know about the scan before importing, one line each:
    /// copies set aside, files still in iCloud, and book files of kinds that cannot
    /// be imported. Empty when there is nothing to say.
    public var tidyingLines: [String] {
        var lines: [String] = []
        if alreadyInLibrary == 1 {
            lines.append("1 file is already in your library and is left where it is.")
        } else if alreadyInLibrary > 1 {
            lines.append("\(Self.count(alreadyInLibrary)) files are already in your library and are left where they are.")
        }
        let copies = entries.reduce(0) { $0 + $1.candidate.copies.count }
        if copies == 1 {
            lines.append("1 file is a copy of another and is left where it is.")
        } else if copies > 1 {
            lines.append("\(copies) files are copies of others and are left where they are.")
        }
        let away = entries.reduce(0) { $0 + $1.candidate.filesNotOnThisMac }
        if away == 1 {
            lines.append("1 file is in iCloud and not on this Mac. Its details come from its name, and importing fetches it.")
        } else if away > 1 {
            lines.append(
                "\(away) files are in iCloud and not on this Mac. Their details come from their names, and importing fetches them, which can take a while.")
        }
        let kinds = Self.bookKindsNotImported(skipped)
        if !kinds.isEmpty {
            lines.append("Not imported, as VoxCarrel cannot read them yet: \(kinds.joined(separator: ", ")).")
        }
        if let calibre {
            if calibre.withoutFiles == 1 {
                lines.append("1 book calibre lists has no file VoxCarrel keeps and is left out.")
            } else if calibre.withoutFiles > 1 {
                lines.append("\(Self.count(calibre.withoutFiles)) books calibre lists have no file VoxCarrel keeps and are left out.")
            }
            let kinds = calibre.formatsLeftOut.filter { $0.value > 0 }.sorted { $0.key < $1.key }
            if !kinds.isEmpty {
                lines.append("Left out by kind: \(kinds.map { "\($0.key) \(Self.count($0.value))" }.joined(separator: ", ")).")
            }
        }
        return lines
    }

    /// Said in place of the choice between moving and copying, for books from a
    /// calibre library; nil for any other import.
    public var calibreNote: String? {
        guard calibre != nil else { return nil }
        return leavesInPlace ? Self.leftInCalibre : Self.copiedFromCalibre
    }

    public static let leftInCalibre =
        "Catalogued where they are: nothing in your calibre library is moved, copied or changed."

    public static let copiedFromCalibre = "Copied from your calibre library, which is left as it is."

    /// What is said when every file that was read is in the library already.
    public static func allAlreadyInLibrary(_ files: Int) -> String {
        files == 1
            ? "That file is already in your library. Nothing was imported."
            : "All \(count(files)) of those files are already in your library. Nothing was imported."
    }

    static func count(_ value: Int) -> String { StatusBarText.number(value) }

    // MARK: Showing only some of the entries

    /// Which entries the list shows.
    public enum Filter: String, CaseIterable, Sendable {
        case all, questions, ready

        public var title: String {
            switch self {
            case .all: "All"
            case .questions: "To Check"
            case .ready: "Ready"
            }
        }
    }

    /// True for an entry there is something to check about: it has a question, or a
    /// status that is not simply ready.
    public func needsALook(_ id: UUID) -> Bool {
        question(of: id) != nil || status(of: id) != nil
    }

    /// The entries the list shows under `filter`, in their order.
    public var shownEntries: [Entry] {
        switch filter {
        case .all: entries
        case .questions: entries.filter { needsALook($0.id) }
        case .ready: entries.filter { !needsALook($0.id) }
        }
    }

    /// "All (106)", "To Check (10)", "Ready (96)".
    public func title(of filter: Filter) -> String {
        let number: Int
        switch filter {
        case .all: number = entries.count
        case .questions: number = entries.filter { needsALook($0.id) }.count
        case .ready: number = entries.filter { !needsALook($0.id) }.count
        }
        return "\(filter.title) (\(Self.count(number)))"
    }

    /// The filter is worth showing once there are enough entries to lose one's place
    /// in, and something to tell apart.
    public var offersFilter: Bool {
        entries.count >= 8 && entries.contains { needsALook($0.id) }
    }

    /// Ticks or unticks every entry the list shows, and no other.
    public mutating func setIncluded(_ included: Bool, forShown: Void = ()) {
        let shown = Set(shownEntries.map(\.id))
        for index in entries.indices where shown.contains(entries[index].id) { entries[index].included = included }
    }

    /// Endings of book files VoxCarrel cannot import, with what to call them.    /// Endings of book files VoxCarrel cannot import, with what to call them.
    static let unreadableBookKinds: [(ending: String, name: String)] = [
        ("doc", "Word"), ("docx", "Word"), ("rtf", "RTF"), ("cbz", "comic"), ("cbr", "comic"), ("kfx", "KFX"),
        ("flac", "FLAC"), ("ogg", "Ogg"), ("opus", "Opus"), ("wma", "WMA"), ("aax", "Audible AAX"),
    ]

    /// "5 DjVu files", "2 Word files": the skipped files that are books, counted by kind.
    static func bookKindsNotImported(_ skipped: [URL]) -> [String] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for url in skipped {
            let ending = url.pathExtension.lowercased()
            guard let kind = unreadableBookKinds.first(where: { $0.ending == ending }) else { continue }
            if counts[kind.name] == nil { order.append(kind.name) }
            counts[kind.name, default: 0] += 1
        }
        return order.map { name in
            let count = counts[name] ?? 0
            return count == 1 ? "1 \(name) file" : "\(count) \(name) files"
        }
    }

    /// "2 copies of this book's files were found and left where they are."; nil when
    /// the entry has none.
    public func copiesText(of id: UUID) -> String? {
        guard let count = entry(id)?.candidate.copies.count, count > 0 else { return nil }
        return count == 1
            ? "1 copy of this book's files was found and left where it is."
            : "\(count) copies of this book's files were found and left where they are."
    }

    // MARK: Q3 Status

    /// What a row says about an entry that is not simply ready.
    public struct Status: Equatable, Sendable {
        public var text: String
        /// True when the entry stops the import as it stands.
        public var isBlocking: Bool

        public init(text: String, isBlocking: Bool) {
            self.text = text
            self.isBlocking = isBlocking
        }

        /// The SF Symbol that stands before the text, so that the two kinds can be told
        /// apart where colour cannot be used: on a selected row.
        public var symbol: String {
            isBlocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
        }
    }

    /// Q3: nil for an entry that is ready; "Needs attention: no author" for one that
    /// will be catalogued and left where it is; otherwise why it cannot be imported.
    public func status(of id: UUID) -> Status? {
        switch readiness(of: id) {
        case .ready:
            return nil
        case .willNeedAttention:
            let names = (entry(id).map(lacks) ?? []).map(\.noun)
            let what =
                switch names.count {
                case 0: "the folder layout leaves it no folder name"
                case 1: "no \(names[0])"
                default: "no \(names.dropLast().joined(separator: ", ")) or \(names[names.count - 1])"
                }
            return Status(text: "Needs attention: \(what)", isBlocking: false)
        case .blocked(let why):
            return Status(text: why, isBlocking: true)
        }
    }

    /// What the library's folder pattern needs and the entry's book lacks, judged as
    /// the engine judges it: the title first, then the author, then the rest in the
    /// pattern's order.
    private func lacks(_ entry: Entry) -> [FolderToken] {
        let missing = folderPattern.missingTokens(for: entry.patternValues)
        let first: [FolderToken] = [.title, .author]
        return first.filter(missing.contains) + missing.filter { !first.contains($0) }
    }

    // MARK: Q4 Where it will go

    /// Q4: one line saying what importing will do with the entry's files.
    public func destinationText(of id: UUID) -> String {
        guard let entry = entry(id) else { return "" }
        guard entry.included else { return "Will not be imported" }
        switch readiness(of: id) {
        case .blocked(let why):
            return "Cannot be imported: \(why)"
        case .willNeedAttention:
            let names = lacks(entry).map { ($0 == .author ? "an " : "a ") + $0.noun }
            switch names.count {
            case 0: return "Will stay where it is: the folder layout leaves it no folder name"
            case 1: return "Will stay where it is until it has \(names[0])"
            default:
                return "Will stay where it is until it has "
                    + "\(names.dropLast().joined(separator: ", ")) and \(names[names.count - 1])"
            }
        case .ready:
            if entry.isAddedToExisting, entry.matchHasNoFiles {
                // R9: the book is filed now, from its own details, as a new book would be.
                if let folder = entry.destination { return "Will be filed in: \(folder)" }
                guard entry.matchDestinationFor != nil else { return "Working out where it will be filed…" }
                // FL14: the folder it belongs in is another book's.
                if let refusal = entry.matchRefusal { return "Cannot be added yet. \(refusal)" }
                let title = entry.existingMatch?.title.trimmedOrNil.map { "“\($0)”" } ?? "The book"
                // What the library's folder pattern needs and the book lacks. The files
                // have been read by now, and did not supply it either.
                let names = (entry.existingMatch.map { match in
                    folderPattern.missingTokens(
                        for: FolderPatternValues(metadata: match.metadata, hasAudio: entry.hasAudio))
                } ?? []).map(\.noun)
                let what =
                    switch names.count {
                    case 0: "author"
                    case 1: names[0]
                    default: "\(names.dropLast().joined(separator: ", ")) or \(names[names.count - 1])"
                    }
                return "Cannot be added yet: \(title) has no \(what) in the library, and neither have these files"
            }
            if entry.isAddedToExisting {
                return entry.destination.map { "Will be added to: \($0)" } ?? "Will be added to the existing book"
            }
            // Another edition has a folder of its own, named when it is imported.
            if entry.isImportedAsEdition {
                let title = entry.existingMatch?.title.trimmedOrNil.map { "“\($0)”" } ?? "that book"
                return "Will be a book of its own, linked to \(title). Where the two share a title, "
                    + "each folder says what sets it apart."
            }
            // FP41: the folder it belongs in is another book's; the import would refuse it.
            if entry.destination == nil, !entry.needsDestination(under: folderPattern),
               let refusal = entry.destinationRefusal {
                return "Cannot be imported yet. \(refusal)"
            }
            return entry.destination.map { "Will be filed in: \($0)" } ?? "Working out where it will be filed…"
        }
    }

    // MARK: Q5 How many

    /// Q5: "11 of 12 books will be imported"
    public var countText: String {
        "\(includedCount) of \(entries.count) \(entries.count == 1 ? "book" : "books") will be imported"
    }

    // MARK: Q6 The selection

    /// What the sheet's right-hand side is for.
    public enum Selected: Equatable, Sendable {
        case none
        case one(Entry)
        /// "3 books selected"
        case many(headline: String)
    }

    /// Q6: what a selection comes to. Ids of entries that are no longer in the review
    /// (merged away, say) do not count.
    public func selected(_ ids: Set<UUID>) -> Selected {
        let chosen = entries.filter { ids.contains($0.id) }
        switch chosen.count {
        case 0: return .none
        case 1: return .one(chosen[0])
        default: return .many(headline: "\(chosen.count) books selected")
        }
    }

    /// Q6: whether Merge into One Book applies: two or more of these are entries.
    public func canMerge(_ ids: Set<UUID>) -> Bool {
        entries.filter { ids.contains($0.id) }.count >= 2
    }

    // MARK: Q7 Files

    /// One file of an entry as the sheet shows it.
    public struct FileLine: Identifiable, Equatable, Sendable {
        public var url: URL
        /// Last path component.
        public var name: String
        public var role: FileRole
        /// Roles this file's format may take.
        public var allowedRoles: [FileRole]
        /// False for a book's only file, which has nowhere to go.
        public var canDetach: Bool

        public var id: URL { url }
    }

    /// Q7: the entry's files in order.
    public func files(of id: UUID) -> [FileLine] {
        guard let files = entry(id)?.candidate.files else { return [] }
        return files.map { file in
            FileLine(
                url: file.url, name: file.url.lastPathComponent, role: file.role,
                allowedRoles: FileFormat(url: file.url).map(FileRow.allowedRoles) ?? [file.role],
                canDetach: files.count > 1)
        }
    }

    // MARK: Q9 Skipped

    /// Something that was dropped or chosen and cannot be imported.
    public struct SkippedLine: Identifiable, Equatable, Sendable {
        public var id: Int
        /// Last path component.
        public var name: String
        public var path: String
    }

    /// Q9: "Skipped (3)"; nil when nothing was skipped.
    public var skippedTitle: String? {
        skipped.isEmpty ? nil : "Skipped (\(skipped.count))"
    }

    /// Q9
    public var skippedLines: [SkippedLine] {
        skipped.enumerated().map { SkippedLine(id: $0.offset, name: $0.element.lastPathComponent, path: $0.element.path) }
    }
}

extension ImportReview.Entry {
    // MARK: Q7 Files

    public var hasAudio: Bool {
        candidate.files.contains { $0.role == .audio }
    }

    /// The measured length of the entry's audio: what a lookup result's length is
    /// compared with, as a library book's is. Known only for an entry whose audio is
    /// the one file that was measured when it was scanned: the parts of a book in
    /// several files are not measured until it is imported, and a length that could
    /// not be measured is not evidence.
    public var measuredAudioSeconds: Double? {
        let audio = candidate.files.filter { $0.role == .audio }
        guard audio.count == 1, let measured = measuredAudio, measured.file == audio[0].url,
              measured.seconds.isFinite, measured.seconds > 0
        else { return nil }
        return measured.seconds
    }

    public var hasEbook: Bool {
        candidate.files.contains { $0.role == .ebook }
    }

    /// Q7: "M4B · EPUB · 1 extra"; several files of one format are counted: "3 MP3".
    public var filesText: String {
        var formats: [String] = []
        var counts: [String: Int] = [:]
        var extras = 0
        for file in candidate.files {
            guard file.role != .extra else {
                extras += 1
                continue
            }
            let format = (FileFormat(url: file.url)?.rawValue ?? file.url.pathExtension).uppercased()
            if counts[format] == nil { formats.append(format) }
            counts[format, default: 0] += 1
        }
        var parts = formats.map { format in
            let count = counts[format] ?? 1
            return count > 1 ? "\(count) \(format)" : format
        }
        if extras > 0 { parts.append(extras == 1 ? "1 extra" : "\(extras) extras") }
        return parts.joined(separator: " · ")
    }

    // MARK: Q8 What a row writes

    /// Q8: the title, or "Untitled" when it is blank.
    public var titleText: String {
        candidate.metadata.title.trimmedOrNil ?? "Untitled"
    }

    /// Q8: the authors with commas between them, or "No author".
    public var authorsText: String {
        let authors = candidate.metadata.authors.compactMap(\.trimmedOrNil)
        return authors.isEmpty ? "No author" : authors.joined(separator: ", ")
    }

    /// Q8: the letters shown in place of a missing cover, as for a book in the library.
    public var coverInitials: String {
        PlaceholderCover.initials(for: candidate.metadata.title)
    }

    /// Q8
    public var placeholderHue: Double {
        PlaceholderCover.hue(for: candidate.metadata.title)
    }


    // MARK: IH4 What was guessed

    /// Whether the order of the title and the author is in question: nothing decided
    /// it, or shape alone turned the name round. A name read the usual way round is
    /// not asked about, or every plain "Author - Title" file would be.
    var orderIsInQuestion: Bool {
        guessNotes.contains(.orderUnsure) || guessNotes.isSuperset(of: [.orderGuessedByShape, .orderSwapped])
    }

    /// IH4: the one line about the title and the authors: the question of their order
    /// first, then a title that looks like a person, then how the name was read.
    var guessNote: String? {
        if orderIsInQuestion {
            return "Read from the file name; check the title and author are the right way round."
        }
        if guessNotes.contains(.titleLooksLikePerson) { return "This title looks like a person's name." }
        if guessNotes.contains(.orderSwapped) { return "Read from the file name as “Title - Author”." }
        if guessNotes.contains(.fromFileName) { return "Read from the file name." }
        return nil
    }

    // MARK: IH6 Questions

    /// IH6: what there is to check about the entry, each thing once; nil when nothing.
    public var question: String? {
        var asked: [String] = []
        if orderIsInQuestion {
            asked.append("Check that the title and author are the right way round.")
        }
        if guessNotes.contains(.titleLooksLikePerson) { asked.append("This title looks like a person's name.") }
        if isPossibleMatchUnanswered, let match = existingMatch {
            asked.append("This may be “\(match.title)”, which is already in your library.")
        }
        return asked.isEmpty ? nil : asked.joined(separator: " ")
    }

    /// Q8: the switch that adds the files to a book already in the library; nil when
    /// no such book was found. R9: a book that is there only as owned on Audible is
    /// named as that. IH1: a possible match is asked about.
    public var existingMatchText: String? {
        guard let match = existingMatch, match.id != nil else { return nil }
        // IH1
        if matchStrength == .possible {
            return "Looks like “\(match.title)”, which is already in your library. Add these files to it?"
        }
        // R9
        if matchHasNoFiles, let kind = ExternalKind.allCases.first(where: match.isOwned(on:)) {
            return "Add to “\(match.title)”, which is on \(kind.title)"
        }
        return "Add to the existing book \"\(match.title)\""
    }
}

extension ImportReview.Entry {
    /// G19: the genres the book will have, in order: what its file's tag came to in
    /// this library, as the owner has changed them since. They are changed through the
    /// model (`AppModel.addImportGenre`, `removeImportGenre`, `moveImportGenre`).
    public var genres: [String] {
        candidate.metadata.genres
    }
}
