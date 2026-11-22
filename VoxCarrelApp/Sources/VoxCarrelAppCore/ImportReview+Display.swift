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
    public mutating func update(_ id: UUID, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
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
            let lacks = entry(id).map { Self.lacks($0.candidate.metadata) } ?? (title: false, author: false)
            let what =
                switch (lacks.title, lacks.author) {
                case (true, true): "no title or author"
                case (true, false): "no title"
                default: "no author"
                }
            return Status(text: "Needs attention: \(what)", isBlocking: false)
        case .blocked(let why):
            return Status(text: why, isBlocking: true)
        }
    }

    /// Which of the two details a book is filed by are unusable, judged as the engine
    /// judges them.
    private static func lacks(_ metadata: BookMetadata) -> (title: Bool, author: Bool) {
        (
            title: PathBuilder.sanitise(metadata.title).isEmpty,
            author: PathBuilder.sanitise(metadata.authors.first ?? "").isEmpty
        )
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
            let lacks = Self.lacks(entry.candidate.metadata)
            let what =
                switch (lacks.title, lacks.author) {
                case (true, true): "a title and an author"
                case (true, false): "a title"
                default: "an author"
                }
            return "Will stay where it is until it has \(what)"
        case .ready:
            if entry.isAddedToExisting, entry.matchHasNoFiles {
                // R9: the book is filed now, from its own details, as a new book would be.
                if let folder = entry.destination { return "Will be filed in: \(folder)" }
                guard entry.matchDestinationFor != nil else { return "Working out where it will be filed…" }
                let title = entry.existingMatch?.title.trimmedOrNil.map { "“\($0)”" } ?? "The book"
                return "Cannot be added yet: \(title) has no author in the library, and neither have these files"
            }
            if entry.isAddedToExisting {
                return entry.destination.map { "Will be added to: \($0)" } ?? "Will be added to the existing book"
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

    /// Q8: the switch that adds the files to a book already in the library; nil when
    /// no such book was found. R9: a book that is there only as owned on Audible is
    /// named as that.
    public var existingMatchText: String? {
        guard let match = existingMatch, match.id != nil else { return nil }
        // R9
        if matchHasNoFiles, match.isOwned(on: .audible) {
            return "Add to “\(match.title)”, which is on Audible"
        }
        return "Add to the existing book \"\(match.title)\""
    }
}
