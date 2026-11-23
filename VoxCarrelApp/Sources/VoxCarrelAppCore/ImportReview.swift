import Foundation
import VoxCarrelCore

/// The books of one import while the user reviews them, before anything is imported.
///
/// A plain value: it reads no file and calls nothing. Everything it answers
/// (`readiness`, `canImport`, `entriesNeedingDestination`, `items()`) is worked out from
/// the entries as they are at that moment, so a view may change an entry directly.
public struct ImportReview: Equatable, Sendable {
    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var candidate: CandidateBook
        public var included: Bool
        /// Shown, and sent as the cover when `coverChanged`.
        public var cover: CoverImage?
        public var coverChanged: Bool
        public var existingMatch: Book?
        /// Only meaningful when `existingMatch` is not nil. Starts true.
        public var addToExisting: Bool
        /// The measured length of the one audio file the entry came with, when it came
        /// with one and its length could be measured.
        var measuredAudio: MeasuredAudio?

        /// The folder last worked out for this entry as a new book, and the details it
        /// was worked out for. `computedFor` is nil until there has been an answer.
        var computedDestination: String?
        var computedFor: DestinationDetails?

        /// The title, first author and Audible ID `existingMatch` was looked up for; nil
        /// when it has yet to be looked up.
        var matchedFor: MatchDetails?

        /// For a match that has no files (`matchHasNoFiles`): the folder that book will
        /// be filed in when it is given its first files, and the book it was worked out
        /// for. `matchDestinationFor` is nil until there has been an answer.
        var matchDestination: String?
        var matchDestinationFor: Book?

        /// True when the files will go into `existingMatch` and not into a new book.
        public var isAddedToExisting: Bool {
            addToExisting && existingMatch?.id != nil
        }

        /// R9: true when the matched book has no files yet: it is in the library only
        /// as owned elsewhere (on Audible), and is in no folder. Its first files are
        /// filed from its own details, as a new book's would be.
        public var matchHasNoFiles: Bool {
            guard let match = existingMatch, match.id != nil else { return false }
            return match.folderPath == nil && match.isOwnedElsewhere && !match.needsAttention
        }

        /// Relative folder it will be filed in; nil when it cannot be filed, or when
        /// that has not been worked out yet. For an entry added to an existing book it
        /// is that book's folder; for a book that has no files yet, the folder it will
        /// be filed in.
        public var destination: String? {
            guard isAddedToExisting else { return computedDestination }
            return matchHasNoFiles ? matchDestination : existingMatch?.folderPath
        }

        /// True when the folder a match with no files will be filed in has not been
        /// worked out for that book as it is now.
        var needsMatchDestination: Bool {
            isAddedToExisting && matchHasNoFiles && matchDestinationFor != existingMatch
        }

        /// True when the folder of this new book has not been worked out for its
        /// details and files as they are now.
        func needsDestination(under pattern: FolderPattern) -> Bool {
            !isAddedToExisting
                && computedFor != DestinationDetails(candidate.metadata, hasAudio: hasAudio, pattern: pattern)
        }

        /// What the entry's book gives a folder pattern (`hasAudio` is what `{Kind}` goes by).
        var patternValues: FolderPatternValues {
            FolderPatternValues(metadata: candidate.metadata, hasAudio: hasAudio)
        }
    }

    /// The details that decide which folder a new book is filed in under a folder
    /// pattern: the text of each detail the pattern names, as it is written, and
    /// whether the book has audio when the pattern files by that. Under the standard
    /// pattern: the title, the first author, the series and the series number.
    struct DestinationDetails: Equatable, Sendable {
        var texts: [FolderToken: String?] = [:]

        init(_ metadata: BookMetadata, hasAudio: Bool, pattern: FolderPattern) {
            var used = pattern.usedTokens
            // A number only counts inside its series.
            if used.contains(.number) { used.insert(.series) }
            for token in used {
                texts[token] =
                    switch token {
                    case .title: metadata.title
                    case .author: metadata.authors.first
                    case .series: metadata.series
                    case .number: metadata.seriesNumber
                    case .narrator: metadata.narrators.first
                    case .year: metadata.year.map(String.init)
                    case .genre: metadata.genre
                    case .publisher: metadata.publisher
                    case .language: metadata.language
                    case .kind: hasAudio ? "audio" : "no audio"
                    }
            }
        }
    }

    /// The details that decide which library book an entry matches: the title, the
    /// first author and the Audible ID, without the spaces around them and ignoring
    /// capitals, as the library compares them.
    struct MatchDetails: Equatable, Sendable {
        var title: String
        var firstAuthor: String
        var asin: String

        init(_ metadata: BookMetadata) {
            title = metadata.title.trimmed.lowercased()
            firstAuthor = (metadata.authors.first ?? "").trimmed.lowercased()
            asin = (metadata.asin ?? "").trimmed.lowercased()
        }
    }

    public enum Readiness: Equatable, Sendable {
        case ready
        /// Lacks something the library's folder pattern needs (under the standard
        /// pattern, a title or an author): catalogued, left in place.
        case willNeedAttention
        /// Cannot be imported as it stands.
        case blocked(String)
    }

    public var entries: [Entry]
    public var skipped: [URL]
    public var copyInsteadOfMove: Bool
    /// How the library the books are going into files its books. The review reads
    /// nothing, so whoever makes it for a library gives it that library's pattern.
    public var folderPattern: FolderPattern = .standard
    /// True when every file is inside the library folder already. Such files are
    /// always moved into place: a copy would leave the original loose in the library,
    /// to be found again and imported twice.
    public let moveOnly: Bool
    /// True when the books are ones that arrived in the watch folders and were sent
    /// for review from the Inbox.
    public let isFromInbox: Bool
    /// WF19: said beside the Copy tick when it was preset for a reason worth telling;
    /// nil otherwise.
    public let inboxNote: String?

    /// Said when the books come from watch folders that do not agree on Move or Copy.
    public static let mixedModesNote = "These books come from folders set to Move and to Copy, so Copy is ticked."

    public init(
        seeds: [ImportSeed], skipped: [URL], copyInsteadOfMove: Bool, moveOnly: Bool = false,
        isFromInbox: Bool = false, inboxNote: String? = nil
    ) {
        self.isFromInbox = isFromInbox
        self.inboxNote = inboxNote
        entries = seeds.map { seed in
            Entry(
                id: UUID(), candidate: seed.candidate, included: true, cover: seed.cover, coverChanged: false,
                existingMatch: seed.existingMatch, addToExisting: true, measuredAudio: seed.measuredAudio,
                // The seed's match was looked up for the details it came with.
                matchedFor: MatchDetails(seed.candidate.metadata))
        }
        self.skipped = skipped
        self.moveOnly = moveOnly
        self.copyInsteadOfMove = copyInsteadOfMove && !moveOnly
    }

    /// Whether "copy, leave originals in place" is a choice the user has.
    public var offersCopy: Bool { !moveOnly }

    // MARK: Readiness

    public func readiness(of id: UUID) -> Readiness {
        guard let entry = entries.first(where: { $0.id == id }) else {
            return .blocked("Not in this import")
        }
        return readiness(of: entry)
    }

    private func readiness(of entry: Entry) -> Readiness {
        // The engine refuses an item with no files, whatever it is added to.
        guard !entry.candidate.files.isEmpty else { return .blocked("No files") }
        // Extras may join a book that is already there, and that book has its own details.
        guard !entry.isAddedToExisting else { return .ready }
        // The engine would file this as a book with nothing to listen to or read.
        guard entry.candidate.files.contains(where: { $0.role != .extra }) else {
            return .blocked("A book needs at least one audiobook or ebook file")
        }
        // Exactly the engine's test for a book it catalogues without filing.
        return PathBuilder.bookFolder(values: entry.patternValues, pattern: folderPattern) == nil
            ? .willNeedAttention : .ready
    }

    public var includedCount: Int {
        entries.filter(\.included).count
    }

    public var canImport: Bool {
        let included = entries.filter(\.included)
        return !included.isEmpty && !included.contains {
            if case .blocked = readiness(of: $0) { return true } else { return false }
        }
    }

    // MARK: Files

    public mutating func setRole(_ role: FileRole, file: URL, in id: UUID) {
        guard let entry = entries.firstIndex(where: { $0.id == id }),
              let index = Self.index(of: file, in: entries[entry]),
              let format = FileFormat(url: file),
              FileRow.allowedRoles(for: format).contains(role)
        else { return }
        entries[entry].candidate.files[index].role = role
    }

    /// Takes one file out into a new entry placed directly after its old one.
    public mutating func detach(file: URL, from id: UUID) {
        guard let entry = entries.firstIndex(where: { $0.id == id }),
              entries[entry].candidate.files.count > 1,
              let index = Self.index(of: file, in: entries[entry])
        else { return }
        var detached = entries[entry].candidate.files.remove(at: index)
        // An extra cannot be a book by itself.
        if detached.role == .extra, let format = FileFormat(url: detached.url) {
            detached.role = format.defaultRole
        }
        // Same details, so the folder already worked out for them holds for the new book too.
        let source = entries[entry]
        entries.insert(
            Entry(
                id: UUID(),
                candidate: CandidateBook(files: [detached], metadata: source.candidate.metadata),
                included: true, cover: nil, coverChanged: false, existingMatch: nil, addToExisting: true,
                computedDestination: source.computedDestination, computedFor: source.computedFor,
                // Moved out to be a book of its own: it is not offered to the library's
                // book again unless its title or author is changed.
                matchedFor: MatchDetails(source.candidate.metadata)),
            at: entry + 1)
    }

    /// Merges the entries into the first of them (in list order).
    public mutating func merge(_ ids: Set<UUID>) {
        let merging = entries.filter { ids.contains($0.id) }
        guard merging.count >= 2, let survivor = entries.firstIndex(where: { ids.contains($0.id) }) else {
            return
        }

        var seen = Set<String>()
        let files = merging.flatMap(\.candidate.files).filter {
            seen.insert($0.url.standardizedFileURL.path).inserted
        }
        entries[survivor].candidate.files = [FileRole.audio, .ebook, .extra].flatMap { role in
            files.filter { $0.role == role }
        }
        // A cover the user chose for the other entry must still be sent, so it comes
        // with its flag.
        if entries[survivor].cover == nil, let other = merging.dropFirst().first(where: { $0.cover != nil }) {
            entries[survivor].cover = other.cover
            entries[survivor].coverChanged = other.coverChanged
        }
        let survivorId = entries[survivor].id
        entries.removeAll { ids.contains($0.id) && $0.id != survivorId }
    }

    private static func index(of file: URL, in entry: Entry) -> Int? {
        let path = file.standardizedFileURL.path
        return entry.candidate.files.firstIndex { $0.url.standardizedFileURL.path == path }
    }

    // MARK: Destinations

    /// Entries whose details changed since `destination` was computed.
    public var entriesNeedingDestination: [UUID] {
        entries.filter { $0.needsDestination(under: folderPattern) }.map(\.id)
    }

    /// Records where a new book would be filed. Ignored when the details that decide
    /// the folder are no longer the ones the answer was worked out for, and for an
    /// entry that is added to an existing book.
    /// - Parameter hasAudio: Whether the answer was worked out for a book with audio;
    ///   nil when it was worked out for the entry's files as they are now.
    public mutating func setDestination(
        _ folder: String?, for id: UUID, matchingMetadata: BookMetadata, hasAudio: Bool? = nil
    ) {
        guard let entry = entries.firstIndex(where: { $0.id == id }),
              !entries[entry].isAddedToExisting
        else { return }
        let current = entries[entry].hasAudio
        let details = DestinationDetails(matchingMetadata, hasAudio: hasAudio ?? current, pattern: folderPattern)
        guard details == DestinationDetails(
            entries[entry].candidate.metadata, hasAudio: current, pattern: folderPattern)
        else { return }
        entries[entry].computedDestination = folder
        entries[entry].computedFor = details
    }

    /// R9: entries that join a book with no files, whose folder has not been worked out
    /// for that book as it is now.
    public var entriesNeedingMatchDestination: [UUID] {
        entries.filter(\.needsMatchDestination).map(\.id)
    }

    /// R9: records where a matched book that has no files will be filed (nil when it
    /// cannot be: it has no author). Ignored when `matchedBook` is no longer the entry's
    /// match as it is now, and for a match that has files.
    public mutating func setMatchDestination(_ folder: String?, for id: UUID, matchedBook: Book) {
        guard let entry = entries.firstIndex(where: { $0.id == id }),
              entries[entry].matchHasNoFiles, entries[entry].existingMatch == matchedBook
        else { return }
        entries[entry].matchDestination = folder
        entries[entry].matchDestinationFor = matchedBook
    }

    // MARK: The book already in the library

    /// Entries whose title, first author or Audible ID changed since `existingMatch`
    /// was looked up.
    public var entriesNeedingMatch: [UUID] {
        entries.filter { $0.matchedFor != MatchDetails($0.candidate.metadata) }.map(\.id)
    }

    /// Records which library book an entry's details (its Audible ID, else its title and
    /// first author) match, or that none does. Ignored when they are no longer the ones the answer was looked up for.
    /// A book other than the one offered before is offered switched on; the same book
    /// leaves the switch as the user has it.
    public mutating func setExistingMatch(_ book: Book?, for id: UUID, matchingMetadata: BookMetadata) {
        guard let entry = entries.firstIndex(where: { $0.id == id }) else { return }
        let details = MatchDetails(matchingMetadata)
        guard details == MatchDetails(entries[entry].candidate.metadata) else { return }
        if book?.id != entries[entry].existingMatch?.id { entries[entry].addToExisting = true }
        entries[entry].existingMatch = book
        entries[entry].matchedFor = details
    }

    // MARK: Importing

    /// The details as they are sent: text without the spaces around it, nothing where
    /// there is only space, and no empty names.
    private static func tidied(_ metadata: BookMetadata) -> BookMetadata {
        var tidy = metadata
        tidy.title = metadata.title.trimmed
        tidy.subtitle = metadata.subtitle?.trimmedOrNil
        tidy.authors = metadata.authors.compactMap(\.trimmedOrNil)
        tidy.narrators = metadata.narrators.compactMap(\.trimmedOrNil)
        tidy.series = metadata.series?.trimmedOrNil
        tidy.seriesNumber = metadata.seriesNumber?.trimmedOrNil
        tidy.genre = metadata.genre?.trimmedOrNil
        tidy.publisher = metadata.publisher?.trimmedOrNil
        tidy.summary = metadata.summary?.trimmedOrNil
        tidy.language = metadata.language?.trimmedOrNil
        tidy.isbn = metadata.isbn?.trimmedOrNil
        tidy.asin = metadata.asin?.trimmedOrNil
        return tidy
    }

    public func items() -> [ImportItem] {
        entries.filter(\.included).map { entry in
            var target = ImportTarget.newBook
            if entry.isAddedToExisting, let bookId = entry.existingMatch?.id {
                target = .existing(bookId: bookId)
            }
            var cover = CoverChange.keep
            if entry.coverChanged, let image = entry.cover { cover = .set(image) }
            var candidate = entry.candidate
            candidate.metadata = Self.tidied(candidate.metadata)
            return ImportItem(candidate: candidate, target: target, cover: cover)
        }
    }

    public var options: ImportOptions {
        ImportOptions(mode: copyInsteadOfMove && !moveOnly ? .copy : .move)
    }
}
